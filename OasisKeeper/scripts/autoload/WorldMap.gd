extends Node
## Owns every per-tile data layer as flat packed arrays (index = y*width+x).
##
## A data-oriented flat-array grid (rather than one Node per tile) is what
## makes a 180x120+ tile simulation affordable in a script language: no
## per-tile Node overhead, cache-friendly iteration, and trivial to persist.

## Re-exported from Tiles so existing `WorldMap.Structure.X` call sites keep
## working; see scripts/world/Tiles.gd for why the enums live there.
const Terrain = Tiles.Terrain
const Structure = Tiles.Structure

var width: int = 0
var height: int = 0

# Static terrain (set once at generation)
var terrain_type: PackedByteArray = PackedByteArray()
var elevation: PackedFloat32Array = PackedFloat32Array()
var fertility: PackedFloat32Array = PackedFloat32Array()
var wadi_strength: PackedFloat32Array = PackedFloat32Array()
var rare_groundwater: PackedFloat32Array = PackedFloat32Array()

# Aquifer bodies inside the rock. aquifer_id indexes into the per-body arrays.
var aquifer_id: PackedInt32Array = PackedInt32Array()
var aquifer_volume: PackedFloat32Array = PackedFloat32Array()
var aquifer_max_volume: PackedFloat32Array = PackedFloat32Array()
var aquifer_recharge: PackedFloat32Array = PackedFloat32Array()

# Dynamic water layers. One unified `water` layer: covered vs open is a
# property of the *structure*, not a separate parallel network. This is a
# deliberate simplification over the previous two-layer design -- it makes
# the flow model something a player can actually reason about.
var water: PackedFloat32Array = PackedFloat32Array()
var soil_moisture: PackedFloat32Array = PackedFloat32Array()
## Smoothed net flow direction per tile, purely for on-screen arrows.
var flow_x: PackedFloat32Array = PackedFloat32Array()
var flow_y: PackedFloat32Array = PackedFloat32Array()

# Dynamic climate layers
var air_moisture: PackedFloat32Array = PackedFloat32Array()
var shade: PackedFloat32Array = PackedFloat32Array()
var temperature: PackedFloat32Array = PackedFloat32Array()

# Structures
var structure_type: PackedByteArray = PackedByteArray()
var gate_open: PackedByteArray = PackedByteArray() ## 1 = open, 0 = closed; only meaningful where structure_type == GATE

func generate(rng_seed: int = -1) -> void:
	width = GameConfig.MAP_WIDTH
	height = GameConfig.MAP_HEIGHT
	var size: int = width * height
	if rng_seed < 0:
		rng_seed = randi()

	var layers: Dictionary = MapGenerator.generate(width, height, rng_seed)
	terrain_type = layers["terrain_type"]
	elevation = layers["elevation"]
	fertility = layers["fertility"]
	wadi_strength = layers["wadi_strength"]
	rare_groundwater = layers["rare_groundwater"]
	aquifer_id = layers["aquifer_id"]
	aquifer_volume = layers["aquifer_volume"]
	aquifer_max_volume = layers["aquifer_max_volume"]
	aquifer_recharge = layers["aquifer_recharge"]

	water = _new_float_layer(size)
	soil_moisture = _new_float_layer(size)
	flow_x = _new_float_layer(size)
	flow_y = _new_float_layer(size)
	shade = _new_float_layer(size)
	temperature = _new_float_layer(size)

	air_moisture = _new_float_layer(size)
	air_moisture.fill(0.06) # ambient desert humidity baseline

	structure_type = PackedByteArray()
	structure_type.resize(size)
	gate_open = PackedByteArray()
	gate_open.resize(size)

	EventBus.emit_signal("world_generated")

func _new_float_layer(size: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(size)
	return a

func index_of(x: int, y: int) -> int:
	return y * width + x

func coords_of(idx: int) -> Vector2i:
	return Vector2i(idx % width, idx / width)

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height

## Non-allocating orthogonal neighbor lookup for hot simulation loops.
## Writes up to 4 valid neighbor indices into out_buffer, returns count.
func get_neighbors4(idx: int, out_buffer: PackedInt32Array) -> int:
	var x: int = idx % width
	var y: int = idx / width
	var count: int = 0
	if x > 0:
		out_buffer[count] = idx - 1
		count += 1
	if x < width - 1:
		out_buffer[count] = idx + 1
		count += 1
	if y > 0:
		out_buffer[count] = idx - width
		count += 1
	if y < height - 1:
		out_buffer[count] = idx + width
		count += 1
	return count

func is_mountain(idx: int) -> bool:
	return terrain_type[idx] == Terrain.ROCK

func is_plantable_ground(idx: int) -> bool:
	return terrain_type[idx] != Terrain.ROCK

func has_aquifer(idx: int) -> bool:
	return aquifer_id[idx] >= 0

## Fill fraction (0..1) of the aquifer body under this tile, or 0 if none.
func aquifer_fill_fraction(idx: int) -> float:
	var body: int = aquifer_id[idx]
	if body < 0 or body >= aquifer_volume.size():
		return 0.0
	var cap: float = aquifer_max_volume[body]
	if cap <= 0.0:
		return 0.0
	return clampf(aquifer_volume[body] / cap, 0.0, 1.0)

func is_canal(idx: int) -> bool:
	var s: int = structure_type[idx]
	return s == Structure.CANAL_OPEN or s == Structure.CANAL_COVERED or s == Structure.CANAL_MOUNTAIN

## True if water can currently move through this tile.
func conducts_water(idx: int) -> bool:
	var s: int = structure_type[idx]
	match s:
		Structure.CANAL_OPEN, Structure.CANAL_COVERED, Structure.CANAL_MOUNTAIN, \
		Structure.RESERVOIR, Structure.CISTERN, Structure.WELL:
			return true
		Structure.GATE:
			return gate_open[idx] == 1
		_:
			return false

## True if this structure loses water to the sun. The single most important
## distinction in the whole build menu.
func is_open_to_sky(idx: int) -> bool:
	var s: int = structure_type[idx]
	return s == Structure.CANAL_OPEN or s == Structure.RESERVOIR or s == Structure.GATE or s == Structure.WELL

func reset_tile_structure(idx: int) -> void:
	structure_type[idx] = Structure.NONE
	gate_open[idx] = 0
	water[idx] = 0.0
	flow_x[idx] = 0.0
	flow_y[idx] = 0.0

## Water-holding capacity of a tile, which depends on what is built there.
func water_capacity(idx: int) -> float:
	match structure_type[idx]:
		Structure.RESERVOIR:
			return GameConfig.RESERVOIR_CAPACITY
		Structure.CISTERN:
			return GameConfig.CISTERN_CAPACITY
		_:
			return GameConfig.CANAL_CAPACITY

## Elevation of the channel floor. Dug structures sit below grade, which is
## what makes water run downhill along a canal instead of pooling in place.
func floor_elevation(idx: int) -> float:
	if structure_type[idx] == Structure.NONE:
		return elevation[idx]
	return elevation[idx] - GameConfig.CANAL_FLOOR_DEPTH

## Hydraulic head: floor height plus the depth of water standing on it.
func head(idx: int) -> float:
	return floor_elevation(idx) + water[idx]

func terrain_name(idx: int) -> String:
	match terrain_type[idx]:
		Terrain.DUNE_SAND:
			return "Dune sand"
		Terrain.DESERT_PAVEMENT:
			return "Desert pavement"
		Terrain.ALLUVIUM:
			return "Alluvium (fertile)"
		Terrain.SCREE:
			return "Scree slope"
		Terrain.ROCK:
			return "Mountain rock"
		_:
			return "Unknown"

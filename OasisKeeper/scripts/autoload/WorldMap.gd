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
## Tile indices of the natural oasis sinks. The wadi network was grown
## outward from these, so they are the low, fertile, well-watered ground the
## player will most likely want to settle.
var oases: PackedInt32Array = PackedInt32Array()

## Player terraforming, in whole height levels relative to the natural
## ground. Kept separate from `elevation` so the geological heightfield
## stays intact -- generation, hillshading and the wadi network all still
## see the land they produced, and terracing is a clean signed offset on
## top that can be inspected, limited and undone.
var terraform_offset: PackedInt32Array = PackedInt32Array()

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
	oases = layers["oases"]
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

	terraform_offset = PackedInt32Array()
	terraform_offset.resize(size)

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

## Ground height of a tile including any terracing the player has done.
## Everything that cares about height -- water, canal floors, the inspector
## -- goes through this rather than reading `elevation` directly.
func terrain_height(idx: int) -> float:
	return elevation[idx] + float(terraform_offset[idx]) * GameConfig.HEIGHT_STEP

## The same height expressed in whole levels, which is the unit the player
## builds and terraces in.
func height_level(idx: int) -> int:
	return int(round(terrain_height(idx) / GameConfig.HEIGHT_STEP))

## Terraforming is a valley-floor activity. Bare rock and the scree apron of
## the foothills are explicitly excluded: shifting those would let the player
## flatten the ranges themselves, which are meant to be the fixed constraint
## the whole water problem is built around.
func can_terraform(idx: int, delta_levels: int) -> bool:
	if idx < 0 or idx >= width * height:
		return false
	var t: int = terrain_type[idx]
	if t == Terrain.ROCK or t == Terrain.SCREE:
		return false
	if structure_type[idx] != Structure.NONE:
		return false
	if PlantSystem.plants.has(idx):
		return false
	var next_offset: int = terraform_offset[idx] + delta_levels
	return next_offset <= GameConfig.TERRAFORM_MAX_RAISE and next_offset >= -GameConfig.TERRAFORM_MAX_DIG

## Why a terraform was refused, for the build panel.
func terraform_hint(idx: int, delta_levels: int) -> String:
	if idx < 0:
		return ""
	var t: int = terrain_type[idx]
	if t == Terrain.ROCK:
		return "Cannot terraform mountain rock"
	if t == Terrain.SCREE:
		return "Cannot terraform the foothills"
	if structure_type[idx] != Structure.NONE:
		return "Clear the structure first"
	if PlantSystem.plants.has(idx):
		return "Remove the plant first"
	var next_offset: int = terraform_offset[idx] + delta_levels
	if next_offset > GameConfig.TERRAFORM_MAX_RAISE:
		return "Already raised as far as it will go"
	if next_offset < -GameConfig.TERRAFORM_MAX_DIG:
		return "Already dug as deep as it will go"
	return ""

func apply_terraform(idx: int, delta_levels: int) -> bool:
	if not can_terraform(idx, delta_levels):
		return false
	terraform_offset[idx] += delta_levels
	EventBus.emit_signal("terrain_modified", idx)
	EventBus.emit_signal("tile_changed", idx)
	return true

## Elevation of the channel floor. Dug structures sit below grade, which is
## what makes water run downhill along a canal instead of pooling in place.
##
## The two *buried* channel types -- mountain tunnels and covered canals --
## are cut to a gradient rather than following the ground surface, so their
## floor is capped at a datum just above the valley floor. This is the qanat
## principle, and it is load-bearing for the whole game: without it a
## channel driven out of a range would have to climb the ridge crest and
## then the scree apron of the foothills, and water would never reach the
## valley at all. On flat valley ground the cap never binds, so open and
## buried channels behave identically there.
##
## Open canals deliberately do NOT get this: they are trenches, they follow
## the ground, and they cannot cross high land. That is the cost of the
## cheaper tool.
func floor_elevation(idx: int) -> float:
	var s: int = structure_type[idx]
	var ground: float = terrain_height(idx)
	if s == Structure.NONE:
		return ground
	var dug: float = ground - GameConfig.CANAL_FLOOR_DEPTH
	if s == Structure.CANAL_MOUNTAIN or s == Structure.CANAL_COVERED:
		return minf(dug, GameConfig.TUNNEL_DATUM_ELEVATION)
	return dug

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

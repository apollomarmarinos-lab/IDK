extends Node
## Owns every per-tile data layer as flat packed arrays (index = y*width+x).
##
## A data-oriented flat-array grid (rather than one Node per tile) is what
## makes a 200x140+ tile simulation affordable in a script language: no
## per-tile Node overhead, cache-friendly iteration, and trivial to persist.

enum Terrain { SAND = 0, ROCK = 1 }
enum Structure {
	NONE = 0,
	CANAL_OPEN = 1,
	CANAL_UNDERGROUND = 2,
	CANAL_MOUNTAIN_TAP = 3,
	GATE = 4,
	STORAGE_TANK = 5,
	SHADE_STRUCTURE = 6,
	WELL_OUTLET = 7,
}

var width: int = 0
var height: int = 0

# Static terrain (set once at generation)
var terrain_type: PackedByteArray = PackedByteArray()
var elevation: PackedFloat32Array = PackedFloat32Array()
var aquifer_potential: PackedFloat32Array = PackedFloat32Array()
var rare_groundwater: PackedFloat32Array = PackedFloat32Array()

# Dynamic water layers
var surface_water: PackedFloat32Array = PackedFloat32Array()
var underground_water: PackedFloat32Array = PackedFloat32Array()
var soil_moisture: PackedFloat32Array = PackedFloat32Array()

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
	aquifer_potential = layers["aquifer_potential"]
	rare_groundwater = layers["rare_groundwater"]

	surface_water = PackedFloat32Array()
	surface_water.resize(size)
	underground_water = PackedFloat32Array()
	underground_water.resize(size)
	soil_moisture = PackedFloat32Array()
	soil_moisture.resize(size)

	air_moisture = PackedFloat32Array()
	air_moisture.resize(size)
	air_moisture.fill(0.06) # ambient desert humidity baseline

	shade = PackedFloat32Array()
	shade.resize(size)
	temperature = PackedFloat32Array()
	temperature.resize(size)

	structure_type = PackedByteArray()
	structure_type.resize(size)
	gate_open = PackedByteArray()
	gate_open.resize(size)

	EventBus.emit_signal("world_generated")

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

## Convenience allocating version for UI / non-hot-path code.
func neighbors4(idx: int) -> Array[int]:
	var buf := PackedInt32Array([0, 0, 0, 0])
	var count: int = get_neighbors4(idx, buf)
	var result: Array[int] = []
	for i in range(count):
		result.append(buf[i])
	return result

func is_mountain(idx: int) -> bool:
	return terrain_type[idx] == Terrain.ROCK

func is_canal(idx: int) -> bool:
	var s: int = structure_type[idx]
	return s == Structure.CANAL_OPEN or s == Structure.CANAL_UNDERGROUND or s == Structure.CANAL_MOUNTAIN_TAP or s == Structure.GATE

## True if water can currently pass through this tile (open canal semantics).
func conducts_surface_water(idx: int) -> bool:
	var s: int = structure_type[idx]
	if s == Structure.CANAL_OPEN or s == Structure.CANAL_MOUNTAIN_TAP or s == Structure.STORAGE_TANK or s == Structure.WELL_OUTLET:
		return true
	if s == Structure.GATE:
		return gate_open[idx] == 1
	return false

func reset_tile_structure(idx: int) -> void:
	structure_type[idx] = Structure.NONE
	gate_open[idx] = 0

## Effective surface-water holding capacity of a tile, which depends on
## what (if anything) is built there.
func water_capacity(idx: int) -> float:
	if structure_type[idx] == Structure.STORAGE_TANK:
		return GameConfig.STORAGE_TANK_CAPACITY
	return GameConfig.TILE_WATER_CAPACITY

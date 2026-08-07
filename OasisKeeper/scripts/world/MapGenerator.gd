class_name MapGenerator
extends RefCounted
## Procedurally builds the desert valley: two organic mountain ranges
## bracketing a central valley, with noise-driven aquifer veins inside the
## rock and a handful of rare groundwater pockets on the valley floor.
##
## Terrain is generated once at world start; everything that changes during
## play (water, moisture, shade, plants) lives in WorldMap's dynamic layers.

const TERRAIN_SAND: int = 0
const TERRAIN_ROCK: int = 1

static func generate(width: int, height: int, rng_seed: int) -> Dictionary:
	var size: int = width * height
	var terrain_type := PackedByteArray()
	var elevation := PackedFloat32Array()
	var aquifer_potential := PackedFloat32Array()
	var rare_groundwater := PackedFloat32Array()
	terrain_type.resize(size)
	elevation.resize(size)
	aquifer_potential.resize(size)
	rare_groundwater.resize(size)

	var ridge_noise := FastNoiseLite.new()
	ridge_noise.seed = rng_seed
	ridge_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge_noise.frequency = 0.02
	ridge_noise.fractal_octaves = 4

	var meander_left := FastNoiseLite.new()
	meander_left.seed = rng_seed + 101
	meander_left.frequency = 0.01
	var meander_right := FastNoiseLite.new()
	meander_right.seed = rng_seed + 202
	meander_right.frequency = 0.01

	var aquifer_noise := FastNoiseLite.new()
	aquifer_noise.seed = rng_seed + 303
	aquifer_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	aquifer_noise.frequency = 0.045
	aquifer_noise.fractal_octaves = 2
	aquifer_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE

	var groundwater_noise := FastNoiseLite.new()
	groundwater_noise.seed = rng_seed + 404
	groundwater_noise.frequency = 0.03
	groundwater_noise.fractal_octaves = 3

	var micro_noise := FastNoiseLite.new()
	micro_noise.seed = rng_seed + 505
	micro_noise.frequency = 0.15

	var band: float = float(width) * GameConfig.MOUNTAIN_BAND_FRACTION

	for y in range(height):
		var left_center: float = band * 0.5 + meander_left.get_noise_1d(float(y)) * GameConfig.MOUNTAIN_MEANDER_AMPLITUDE
		var right_center: float = float(width) - band * 0.5 + meander_right.get_noise_1d(float(y)) * GameConfig.MOUNTAIN_MEANDER_AMPLITUDE
		for x in range(width):
			var idx: int = y * width + x
			var dist_left: float = absf(float(x) - left_center)
			var dist_right: float = absf(float(x) - right_center)
			var fall_left: float = clampf(1.0 - dist_left / (band * 0.5), 0.0, 1.0)
			var fall_right: float = clampf(1.0 - dist_right / (band * 0.5), 0.0, 1.0)
			var mountain_mask: float = smoothstep(0.0, 1.0, maxf(fall_left, fall_right))

			var ridge: float = (ridge_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			var mountain_elevation: float = GameConfig.VALLEY_BASE_ELEVATION + mountain_mask * ridge * GameConfig.MOUNTAIN_HEIGHT_SCALE

			# Valley floor forms a shallow basin toward the horizontal center
			# between the two ranges, so water naturally gathers mid-valley.
			var valley_center: float = (left_center + right_center) * 0.5
			var valley_half_width: float = maxf(1.0, (right_center - left_center) * 0.5)
			var center_dist: float = absf(float(x) - valley_center) / valley_half_width
			var basin_shape: float = clampf(1.0 - center_dist, 0.0, 1.0)
			var valley_elevation: float = GameConfig.VALLEY_BASE_ELEVATION - GameConfig.VALLEY_BASIN_DEPTH * basin_shape

			var micro: float = micro_noise.get_noise_2d(float(x), float(y)) * 0.6
			var final_elevation: float = lerpf(valley_elevation, mountain_elevation, mountain_mask) + micro

			elevation[idx] = final_elevation
			var is_rock: bool = mountain_mask > 0.55
			terrain_type[idx] = TERRAIN_ROCK if is_rock else TERRAIN_SAND

			if is_rock:
				var raw_aq: float = (aquifer_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
				aquifer_potential[idx] = raw_aq if raw_aq > GameConfig.AQUIFER_NOISE_THRESHOLD else 0.0
			else:
				aquifer_potential[idx] = 0.0

			if not is_rock and mountain_mask < 0.08:
				var raw_gw: float = (groundwater_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
				rare_groundwater[idx] = raw_gw if raw_gw > GameConfig.RARE_GROUNDWATER_THRESHOLD else 0.0
			else:
				rare_groundwater[idx] = 0.0

	return {
		"terrain_type": terrain_type,
		"elevation": elevation,
		"aquifer_potential": aquifer_potential,
		"rare_groundwater": rare_groundwater,
	}

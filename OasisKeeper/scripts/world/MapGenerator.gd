class_name MapGenerator
extends RefCounted
## Procedurally builds the desert valley.
##
## Generation runs as a sequence of geological passes, in the order the real
## landscape would have formed, which is what makes the result read as a
## coherent place rather than layered noise:
##
##   1. Two meandering mountain ranges (ridged multifractal) with a scree
##      apron of foothills falling away from the rock line.
##   2. A valley floor between them: a shallow cross-valley basin plus a
##      gentle slope down the valley's long axis, so the whole map drains
##      toward one outlet and canals have a consistent downhill direction.
##   3. A wadi network -- seasonal drainage channels traced by steepest
##      descent from the foothills to the valley floor, then carved.
##   4. Alluvium: fertile silt deposited either side of each wadi, the
##      classic place a real oasis gets planted.
##   5. Dune fields in the dry ground far from any wadi.
##   6. Aquifers: organic, flood-filled water bodies inside the rock, each
##      with a finite volume and slow recharge.

const TERRAIN_DUNE_SAND: int = 0
const TERRAIN_DESERT_PAVEMENT: int = 1
const TERRAIN_ALLUVIUM: int = 2
const TERRAIN_SCREE: int = 3
const TERRAIN_ROCK: int = 4

## Growth-rate multiplier plants get from each terrain type.
const TERRAIN_FERTILITY := {
	TERRAIN_DUNE_SAND: 0.5,
	TERRAIN_DESERT_PAVEMENT: 0.7,
	TERRAIN_ALLUVIUM: 1.0,
	TERRAIN_SCREE: 0.45,
	TERRAIN_ROCK: 0.0,
}

static func generate(width: int, height: int, rng_seed: int) -> Dictionary:
	var size: int = width * height
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed

	var elevation := PackedFloat32Array()
	var terrain_type := PackedByteArray()
	var fertility := PackedFloat32Array()
	var mountain_mask := PackedFloat32Array()
	var wadi_strength := PackedFloat32Array()
	elevation.resize(size)
	terrain_type.resize(size)
	fertility.resize(size)
	mountain_mask.resize(size)
	wadi_strength.resize(size)

	# --- Pass 1 & 2: ranges, foothills, valley floor -----------------------
	# Generate base terrain at lower resolution then interpolate for speed
	var scale_factor := 2
	var low_width := width / scale_factor
	var low_height := height / scale_factor
	var low_size := low_width * low_height
	
	var low_elevation := PackedFloat32Array()
	var low_mountain_mask := PackedFloat32Array()
	low_elevation.resize(low_size)
	low_mountain_mask.resize(low_size)
	
	var ridge_noise := _make_noise(rng_seed, FastNoiseLite.TYPE_PERLIN, 0.018 * scale_factor, 4)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var detail_noise := _make_noise(rng_seed + 11, FastNoiseLite.TYPE_PERLIN, 0.09 * scale_factor, 2)
	var meander_left := _make_noise(rng_seed + 101, FastNoiseLite.TYPE_PERLIN, 0.008 * scale_factor, 2)
	var meander_right := _make_noise(rng_seed + 202, FastNoiseLite.TYPE_PERLIN, 0.008 * scale_factor, 2)
	var peak_noise_left := _make_noise(rng_seed + 103, FastNoiseLite.TYPE_PERLIN, 0.025 * scale_factor, 3)
	var peak_noise_right := _make_noise(rng_seed + 203, FastNoiseLite.TYPE_PERLIN, 0.025 * scale_factor, 3)
	var slope_noise_left := _make_noise(rng_seed + 104, FastNoiseLite.TYPE_PERLIN, 0.015 * scale_factor, 2)
	var slope_noise_right := _make_noise(rng_seed + 204, FastNoiseLite.TYPE_PERLIN, 0.015 * scale_factor, 2)
	var dune_noise := _make_noise(rng_seed + 303, FastNoiseLite.TYPE_PERLIN, GameConfig.DUNE_FREQUENCY * scale_factor, 2)
	var pavement_noise := _make_noise(rng_seed + 404, FastNoiseLite.TYPE_PERLIN, 0.03 * scale_factor, 2)

	var band: float = float(low_width) * GameConfig.MOUNTAIN_BAND_FRACTION
	var left_centers := PackedFloat32Array()
	var right_centers := PackedFloat32Array()
	left_centers.resize(low_height)
	right_centers.resize(low_height)

	for y in range(low_height):
		left_centers[y] = band * 0.5 + meander_left.get_noise_1d(float(y)) * GameConfig.MOUNTAIN_MEANDER_AMPLITUDE / scale_factor
		right_centers[y] = float(low_width) - band * 0.5 + meander_right.get_noise_1d(float(y)) * GameConfig.MOUNTAIN_MEANDER_AMPLITUDE / scale_factor

	for y in range(low_height):
		var left_center: float = left_centers[y]
		var right_center: float = right_centers[y]
		var long_slope: float = (1.0 - float(y) / float(low_height)) * GameConfig.VALLEY_LONG_SLOPE
		var peak_left: float = (peak_noise_left.get_noise_1d(float(y)) + 1.0) * 0.5
		var peak_right: float = (peak_noise_right.get_noise_1d(float(y)) + 1.0) * 0.5
		var slope_exp_left: float = slope_noise_left.get_noise_1d(float(y)) * 0.3 + 1.0
		var slope_exp_right: float = slope_noise_right.get_noise_1d(float(y)) * 0.3 + 1.0
		for x in range(low_width):
			var idx: int = y * low_width + x
			var fall_left: float = clampf(1.0 - absf(float(x) - left_center) / (band * 0.5), 0.0, 1.0)
			var fall_right: float = clampf(1.0 - absf(float(x) - right_center) / (band * 0.5), 0.0, 1.0)
			var mask: float = smoothstep(0.0, 1.0, maxf(fall_left, fall_right))
			low_mountain_mask[idx] = mask

			var ridge: float = (ridge_noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			ridge = pow(ridge, 1.4)
			
			var peak_mod_left: float = 1.0 + (peak_left - 0.5) * 0.8 * fall_left
			var peak_mod_right: float = 1.0 + (peak_right - 0.5) * 0.8 * fall_right
			var mountain_h: float = mask * ridge * GameConfig.MOUNTAIN_HEIGHT_SCALE
			mountain_h *= maxf(peak_mod_left, peak_mod_right)
                        if fall_left > 0.01:
				var exp_fall_left: float = pow(fall_left, slope_exp_left)
				mountain_h = maxf(mountain_h, exp_fall_left * ridge * GameConfig.MOUNTAIN_HEIGHT_SCALE * 0.7)
			if fall_right > 0.01:
				var exp_fall_right: float = pow(fall_right, slope_exp_right)
				mountain_h = maxf(mountain_h, exp_fall_right * ridge * GameConfig.MOUNTAIN_HEIGHT_SCALE * 0.7)

			var valley_center: float = (left_center + right_center) * 0.5
			var valley_half: float = maxf(1.0, (right_center - left_center) * 0.5)
			var basin: float = clampf(1.0 - absf(float(x) - valley_center) / valley_half, 0.0, 1.0)
			var floor_h: float = GameConfig.VALLEY_BASE_ELEVATION - GameConfig.VALLEY_BASIN_DEPTH * basin + long_slope

			var h: float = floor_h + mountain_h
			var peak_smooth: float = 1.0 - clampf((maxf(fall_left, fall_right) - 0.3) / 0.7, 0.0, 1.0) * 0.4
			h += detail_noise.get_noise_2d(float(x), float(y)) * (0.5 + mask * 3.0) * peak_smooth
			low_elevation[idx] = h
	
	# Upscale low-res terrain to full resolution with bilinear interpolation
	for y in range(height):
		for x in range(width):
			var low_x: float = float(x) / scale_factor
			var low_y: float = float(y) / scale_factor
			var x0: int = int(floorf(low_x))
			var y0: int = int(floorf(low_y))
			var x1: int = mini(x0 + 1, low_width - 1)
			var y1: int = mini(y0 + 1, low_height - 1)
			var fx: float = low_x - x0
			var fy: float = low_y - y0
			
			var idx: int = y * width + x
			var idx00: int = y0 * low_width + x0
			var idx10: int = y0 * low_width + x1
			var idx01: int = y1 * low_width + x0
			var idx11: int = y1 * low_width + x1
			
			var h00: float = low_elevation[idx00]
			var h10: float = low_elevation[idx10]
			var h01: float = low_elevation[idx01]
			var h11: float = low_elevation[idx11]
			
			var h_interp: float = lerp(lerp(h00, h10, fx), lerp(h01, h11, fx), fy)
			
			var m00: float = low_mountain_mask[idx00]
			var m10: float = low_mountain_mask[idx10]
			var m01: float = low_mountain_mask[idx01]
			var m11: float = low_mountain_mask[idx11]
			var m_interp: float = lerp(lerp(m00, m10, fx), lerp(m01, m11, fx), fy)
			
			# Add fine detail at full resolution
			var fine_detail: float = detail_noise.get_noise_2d(float(x), float(y)) * 0.3
			elevation[idx] = h_interp + fine_detail
			mountain_mask[idx] = m_interp

	# --- Pass 3: wadi network ---------------------------------------------
	_carve_wadis(width, height, rng, elevation, mountain_mask, wadi_strength, left_centers, right_centers)

	# --- Pass 4 & 5: dunes, then terrain classification -------------------
	for y in range(height):
		for x in range(width):
			var idx: int = y * width + x
			var mask: float = mountain_mask[idx]
			var wadi: float = wadi_strength[idx]
			# Dunes only pile up on dry ground away from the ranges and wadis.
			if mask < 0.15 and wadi < 0.15:
				var dune: float = (dune_noise.get_noise_2d(float(x), float(y) * 0.45) + 1.0) * 0.5
				dune = pow(dune, 2.0)
				elevation[idx] += dune * GameConfig.DUNE_HEIGHT

			var t: int
			if mask > GameConfig.ROCK_SLOPE_THRESHOLD:
				t = TERRAIN_ROCK
			elif mask > 0.22:
				t = TERRAIN_SCREE
			elif wadi > 0.2:
				t = TERRAIN_ALLUVIUM
			elif pavement_noise.get_noise_2d(float(x), float(y)) > 0.12:
				t = TERRAIN_DESERT_PAVEMENT
			else:
				t = TERRAIN_DUNE_SAND
			terrain_type[idx] = t
			var f: float = TERRAIN_FERTILITY[t]
			# Silt grades off with distance from the channel rather than
			# stopping at a hard edge.
			if t == TERRAIN_ALLUVIUM:
				f *= clampf(0.6 + wadi * 0.6, 0.0, 1.0)
			# Foothills (scree) get slightly higher fertility near the valley floor transition
			if t == TERRAIN_SCREE and mask < 0.35:
				f *= 1.15
			fertility[idx] = f

	# --- Pass 6: aquifers --------------------------------------------------
	var aquifer_result: Dictionary = _generate_aquifers(width, height, rng, terrain_type, elevation)

	# Rare groundwater pockets on the valley floor (wells, not aquifers).
	var gw_noise := _make_noise(rng_seed + 707, FastNoiseLite.TYPE_PERLIN, 0.035, 3)
	var rare_groundwater := PackedFloat32Array()
	rare_groundwater.resize(size)
	for idx in range(size):
		if terrain_type[idx] == TERRAIN_ROCK or terrain_type[idx] == TERRAIN_SCREE:
			continue
		var v: float = (gw_noise.get_noise_2d(float(idx % width), float(idx / width)) + 1.0) * 0.5
		# Shallow groundwater tracks the wadis -- that is where it really sits.
		v += wadi_strength[idx] * 0.15
		if v > 0.85:
			rare_groundwater[idx] = clampf((v - 0.85) / 0.15, 0.0, 1.0)

	return {
		"terrain_type": terrain_type,
		"elevation": elevation,
		"fertility": fertility,
		"wadi_strength": wadi_strength,
		"rare_groundwater": rare_groundwater,
		"aquifer_id": aquifer_result["aquifer_id"],
		"aquifer_volume": aquifer_result["volume"],
		"aquifer_max_volume": aquifer_result["max_volume"],
		"aquifer_recharge": aquifer_result["recharge"],
	}

static func _make_noise(s: int, type: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = s
	n.noise_type = type
	n.frequency = freq
	n.fractal_octaves = octaves
	return n

## Traces drainage lines by steepest descent from the foothills out into the
## valley, then carves each into the heightmap. Because the paths follow the
## terrain they were generated from, the resulting network branches and
## meanders the way real drainage does.
static func _carve_wadis(width: int, height: int, rng: RandomNumberGenerator,
		elevation: PackedFloat32Array, mountain_mask: PackedFloat32Array,
		wadi_strength: PackedFloat32Array, left_centers: PackedFloat32Array,
		right_centers: PackedFloat32Array) -> void:
	var paths: Array[PackedInt32Array] = []
	for i in range(GameConfig.WADI_COUNT):
		var y: int = rng.randi_range(int(height * 0.05), int(height * 0.95))
		var from_left: bool = (i % 2) == 0
		# Start at the foot of the range and run out into the open valley.
		var x: int
		if from_left:
			x = int(left_centers[y] + GameConfig.FOOTHILL_WIDTH * 0.6)
		else:
			x = int(right_centers[y] - GameConfig.FOOTHILL_WIDTH * 0.6)
		x = clampi(x, 1, width - 2)
		var path := _trace_descent(width, height, x, y, elevation, mountain_mask, rng)
		if path.size() > 6:
			paths.append(path)

	for path in paths:
		for i in range(path.size()):
			var idx: int = path[i]
			var px: int = idx % width
			var py: int = idx / width
			# Channels widen and deepen as they gather flow downstream.
			var maturity: float = float(i) / float(max(1, path.size() - 1))
			var w: float = GameConfig.WADI_WIDTH * (0.5 + maturity * 0.9)
			var d: float = GameConfig.WADI_DEPTH * (0.4 + maturity * 0.9)
			var r: int = int(ceil(w + GameConfig.ALLUVIUM_WIDTH))
			for dy in range(-r, r + 1):
				var ny: int = py + dy
				if ny < 0 or ny >= height:
					continue
				for dx in range(-r, r + 1):
					var nx: int = px + dx
					if nx < 0 or nx >= width:
						continue
					var dist: float = sqrt(float(dx * dx + dy * dy))
					var nidx: int = ny * width + nx
					if dist <= w:
						var cut: float = d * (1.0 - dist / w)
						elevation[nidx] -= cut
						wadi_strength[nidx] = maxf(wadi_strength[nidx], 1.0 - dist / w)
					elif dist <= w + GameConfig.ALLUVIUM_WIDTH:
						var t: float = 1.0 - (dist - w) / GameConfig.ALLUVIUM_WIDTH
						wadi_strength[nidx] = maxf(wadi_strength[nidx], t * 0.55)

static func _trace_descent(width: int, height: int, start_x: int, start_y: int,
		elevation: PackedFloat32Array, mountain_mask: PackedFloat32Array,
		rng: RandomNumberGenerator) -> PackedInt32Array:
	var path := PackedInt32Array()
	var x: int = start_x
	var y: int = start_y
	var visited := {}
	for _step in range(width + height):
		var idx: int = y * width + x
		if visited.has(idx):
			break
		visited[idx] = true
		path.append(idx)
		var best_x: int = x
		var best_y: int = y
		var best_h: float = elevation[idx]
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx: int = x + dx
				var ny: int = y + dy
				if nx < 1 or nx >= width - 1 or ny < 1 or ny >= height - 1:
					continue
				# A little jitter keeps channels from running dead straight
				# down the gradient.
				var h: float = elevation[ny * width + nx] + rng.randf_range(-0.12, 0.12)
				if h < best_h:
					best_h = h
					best_x = nx
					best_y = ny
		if best_x == x and best_y == y:
			break # reached a local sink; the channel ends here
		x = best_x
		y = best_y
		if mountain_mask[y * width + x] < 0.02 and path.size() > int(width * 0.25):
			break # far enough out into the open valley
	return path

## Grows organic aquifer bodies inside the rock with a randomized flood fill.
## Each body is a connected blob with its own finite volume and recharge, so
## players must find them (geology overlay), reach them with a tunnel, and
## then manage them -- a small aquifer can genuinely be pumped dry.
static func _generate_aquifers(width: int, height: int, rng: RandomNumberGenerator,
		terrain_type: PackedByteArray, elevation: PackedFloat32Array) -> Dictionary:
	var size: int = width * height
	var aquifer_id := PackedInt32Array()
	aquifer_id.resize(size)
	aquifer_id.fill(-1)

	var volume := PackedFloat32Array()
	var max_volume := PackedFloat32Array()
	var recharge := PackedFloat32Array()

	var rock_tiles := PackedInt32Array()
	for idx in range(size):
		if terrain_type[idx] == TERRAIN_ROCK:
			rock_tiles.append(idx)
	if rock_tiles.is_empty():
		return {"aquifer_id": aquifer_id, "volume": volume, "max_volume": max_volume, "recharge": recharge}

	var body_count: int = rng.randi_range(GameConfig.AQUIFER_COUNT_MIN, GameConfig.AQUIFER_COUNT_MAX)
	for body in range(body_count):
		var target: int = rng.randi_range(GameConfig.AQUIFER_SIZE_MIN, GameConfig.AQUIFER_SIZE_MAX)
		var seed_idx: int = rock_tiles[rng.randi_range(0, rock_tiles.size() - 1)]
		if aquifer_id[seed_idx] != -1:
			continue
		var claimed := _grow_blob(width, height, seed_idx, target, rng, terrain_type, aquifer_id)
		if claimed.size() < GameConfig.AQUIFER_SIZE_MIN / 2:
			# Too cramped to be interesting -- release it and try elsewhere.
			for idx in claimed:
				aquifer_id[idx] = -1
			continue
		var body_index: int = volume.size()
		for idx in claimed:
			aquifer_id[idx] = body_index
		var cap: float = float(claimed.size()) * GameConfig.AQUIFER_VOLUME_PER_TILE
		max_volume.append(cap)
		volume.append(cap * rng.randf_range(0.65, 1.0))
		recharge.append(float(claimed.size()) * GameConfig.AQUIFER_RECHARGE_PER_TILE)

	return {"aquifer_id": aquifer_id, "volume": volume, "max_volume": max_volume, "recharge": recharge}

static func _grow_blob(width: int, height: int, seed_idx: int, target: int,
		rng: RandomNumberGenerator, terrain_type: PackedByteArray,
		aquifer_id: PackedInt32Array) -> PackedInt32Array:
	var claimed := PackedInt32Array()
	var frontier := PackedInt32Array([seed_idx])
	var seen := {seed_idx: true}
	aquifer_id[seed_idx] = -2 # temporary reservation marker
	claimed.append(seed_idx)

	while claimed.size() < target and not frontier.is_empty():
		# Popping a random frontier tile (rather than the oldest) is what
		# gives these blobs irregular, cave-like outlines instead of discs.
		var pick: int = rng.randi_range(0, frontier.size() - 1)
		var idx: int = frontier[pick]
		frontier[pick] = frontier[frontier.size() - 1]
		frontier.resize(frontier.size() - 1)

		var x: int = idx % width
		var y: int = idx / width
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nx: int = x + offset.x
			var ny: int = y + offset.y
			if nx < 0 or nx >= width or ny < 0 or ny >= height:
				continue
			var nidx: int = ny * width + nx
			if seen.has(nidx):
				continue
			if terrain_type[nidx] != TERRAIN_ROCK or aquifer_id[nidx] != -1:
				continue
			if rng.randf() > 0.72:
				continue # ragged edges
			seen[nidx] = true
			aquifer_id[nidx] = -2
			claimed.append(nidx)
			frontier.append(nidx)
			if claimed.size() >= target:
				break
	return claimed

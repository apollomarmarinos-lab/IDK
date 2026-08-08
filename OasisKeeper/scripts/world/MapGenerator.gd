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
##   3. Oasis sinks are chosen on the valley floor, and the wadi network is
##      grown BACKWARDS from each of them -- uphill into the foothills,
##      branching as it climbs -- then carved. See _carve_wadis.
##   4. Alluvium: fertile silt either side of each wadi and spread flat over
##      the oasis plain itself, the classic place a real oasis gets planted.
##   5. Dune fields in the dry ground far from any wadi.
##   6. Aquifers: organic, flood-filled water bodies inside the rock, each
##      with a finite volume and slow recharge.

const TERRAIN_DUNE_SAND: int = 0
const TERRAIN_DESERT_PAVEMENT: int = 1
const TERRAIN_ALLUVIUM: int = 2
const TERRAIN_SCREE: int = 3
const TERRAIN_ROCK: int = 4

## Base headings for the main branches leaving an oasis: toward the western
## range, the eastern range, and up-valley.
const ROOT_HEADINGS: Array[float] = [PI, 0.0, -PI * 0.5, PI * 0.5]

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
			
			# Add fine detail at full resolution. Kept small on purpose: the
			# whole valley only drops VALLEY_LONG_SLOPE (~7) end to end, so
			# large per-tile noise here swamps the regional gradient and the
			# drainage tracer can no longer find its way downhill.
			var fine_detail: float = detail_noise.get_noise_2d(float(x), float(y)) * 0.12
			elevation[idx] = h_interp + fine_detail
			mountain_mask[idx] = m_interp

	# The range centrelines were computed in low-resolution space: indexed by
	# low_y and measured in low_x units. Every later pass works at full
	# resolution, so they must be resampled first -- indexing a
	# low_height-long array with a full-height y both reads out of bounds and
	# places the wadis at half their true x.
	var full_left_centers := PackedFloat32Array()
	var full_right_centers := PackedFloat32Array()
	full_left_centers.resize(height)
	full_right_centers.resize(height)
	for y in range(height):
		var ly: float = float(y) / float(scale_factor)
		var y0: int = clampi(int(floorf(ly)), 0, low_height - 1)
		var y1: int = mini(y0 + 1, low_height - 1)
		var fy: float = ly - float(y0)
		full_left_centers[y] = lerpf(left_centers[y0], left_centers[y1], fy) * scale_factor
		full_right_centers[y] = lerpf(right_centers[y0], right_centers[y1], fy) * scale_factor

	# --- Pass 3: wadi network, grown backwards from the oasis sinks -------
	var oases: PackedInt32Array = _carve_wadis(width, height, rng, elevation, mountain_mask,
		wadi_strength, full_left_centers, full_right_centers)

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
	#
	# The cutoff is a PERCENTILE of the actual field, not a fixed threshold.
	# A fixed one (v > 0.85) depends on how often the noise happens to reach
	# its extremes, which varies with frequency, octaves and map size -- at
	# one point it produced literally zero pockets map-wide, silently making
	# the Well tool impossible to use. Taking the top slice guarantees a
	# sensible number of sites on any map.
	var gw_noise := _make_noise(rng_seed + 707, FastNoiseLite.TYPE_PERLIN, 0.035, 3)
	var rare_groundwater := PackedFloat32Array()
	rare_groundwater.resize(size)

	var gw_values := PackedFloat32Array()
	var gw_indices := PackedInt32Array()
	for idx in range(size):
		if terrain_type[idx] == TERRAIN_ROCK or terrain_type[idx] == TERRAIN_SCREE:
			continue
		var v: float = (gw_noise.get_noise_2d(float(idx % width), float(idx / width)) + 1.0) * 0.5
		# Shallow groundwater tracks the wadis -- that is where it really sits.
		v += wadi_strength[idx] * 0.15
		gw_values.append(v)
		gw_indices.append(idx)

	if not gw_values.is_empty():
		# Aim for roughly one pocket tile per 900 tiles of map, clamped so
		# small maps still get a handful and large ones do not drown in them.
		var target: int = clampi(int(float(size) / 900.0), 20, 400)
		target = mini(target, gw_values.size())
		var sorted_values: PackedFloat32Array = gw_values.duplicate()
		sorted_values.sort()
		var cutoff: float = sorted_values[sorted_values.size() - target]
		var span: float = maxf(0.001, sorted_values[sorted_values.size() - 1] - cutoff)
		for i in range(gw_values.size()):
			if gw_values[i] >= cutoff:
				rare_groundwater[gw_indices[i]] = clampf((gw_values[i] - cutoff) / span, 0.15, 1.0)

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
		"oases": oases,
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
## Grows the wadi network BACKWARDS: from each oasis, uphill into the hills.
##
## Water finds the path of least resistance downhill, carries gravel with it,
## and over millennia cuts a branching valley; an oasis forms at the end of a
## wadi, where the water spreads out and sinks away. Simulating that forwards
## is the obvious approach and the wrong one -- channels traced downhill from
## the hills wander off and miss the oasis, and on a valley floor this flat
## they stall in the first shallow pit.
##
## Growing in reverse fixes both. Starting at the sink and climbing means the
## catchment always converges on the point that matters, and "uphill" is
## unambiguous even where the downhill gradient is smaller than the terrain's
## own roughness. Each step takes the steepest ascent most of the time and a
## random higher neighbour otherwise, and branches occasionally into a
## thinner tributary -- which is what produces the dendritic shape.
static func _carve_wadis(width: int, height: int, rng: RandomNumberGenerator,
		elevation: PackedFloat32Array, mountain_mask: PackedFloat32Array,
		wadi_strength: PackedFloat32Array, left_centers: PackedFloat32Array,
		right_centers: PackedFloat32Array) -> PackedInt32Array:
	var oases: PackedInt32Array = _pick_oasis_sites(width, height, rng, elevation, mountain_mask, left_centers, right_centers)

	# The climb is decided on a SMOOTHED copy of the heightmap. Greedy uphill
	# on the raw field is hopeless here: the per-tile detail noise is larger
	# than the regional gradient, so a branch summits a one-tile bump within a
	# handful of steps and dead-ends. Smoothing exposes the broad shape of the
	# land, which is the shape a catchment actually follows. Carving still
	# writes into the real elevation array.
	var climb_field: PackedFloat32Array = _smooth_field(elevation, width, height, 3)

	for oasis_idx in oases:
		# Nodes of this network, with the branch thickness at each node.
		var node_idx := PackedInt32Array()
		var node_thickness := PackedFloat32Array()
		var visited := {}
		visited[oasis_idx] = true

		# Shared, mutable node budget for this whole network.
		var budget := [GameConfig.WADI_NODE_BUDGET_PER_OASIS]
		for root in range(GameConfig.WADI_ROOTS_PER_OASIS):
			# Send the roots at explicitly opposed headings -- west, east,
			# up-valley. An even fan is not enough: whichever range is
			# marginally closer wins the elevation term for every root, and
			# the whole catchment ends up on one side of the valley.
			var base: float = ROOT_HEADINGS[root % ROOT_HEADINGS.size()]
			var angle: float = base + rng.randf_range(-0.35, 0.35)
			_grow_branch(width, height, oasis_idx, float(GameConfig.WADI_START_THICKNESS), 0,
				Vector2(cos(angle), sin(angle)), rng, elevation, climb_field,
				visited, node_idx, node_thickness, budget)

		_carve_network(width, height, oasis_idx, node_idx, node_thickness, elevation, wadi_strength)
		_lay_down_oasis_plain(width, height, oasis_idx, elevation, wadi_strength)

	_smooth_wadi_shoulders(width, height, elevation, wadi_strength)
	return oases

## One branch, climbing away from the sink until it runs out of rising
## ground, gets too high, or hits the step limit. Recurses to spawn thinner
## tributaries.
##
## Each candidate step is scored on how much it climbs plus how well it keeps
## heading outward. The direction term matters: on the flat valley floor the
## climb term is nearly zero and, without it, the walk mills around near the
## oasis instead of reaching the hills. A small budget of non-climbing steps
## lets a branch cross a flat or a saddle rather than stopping at the first
## one -- the terrain is not monotonic and a real channel head is not either.
static func _grow_branch(width: int, height: int, start_idx: int, thickness: float, depth: int,
		direction: Vector2, rng: RandomNumberGenerator,
		elevation: PackedFloat32Array, climb_field: PackedFloat32Array, visited: Dictionary,
		node_idx: PackedInt32Array, node_thickness: PackedFloat32Array, budget: Array) -> void:
	var current: int = start_idx
	var heading: Vector2 = direction.normalized()
	var stall_budget: int = 25
	var candidates := PackedInt32Array()
	var scores := PackedFloat32Array()

	# Headwaters are short; the trunk is long. Scale branch length by how
	# thick this branch is.
	var max_steps: int = maxi(12, int(float(GameConfig.WADI_MAX_STEPS) * thickness / float(GameConfig.WADI_START_THICKNESS)))
	for step in range(max_steps):
		if budget[0] <= 0:
			return
		budget[0] -= 1
		node_idx.append(current)
		node_thickness.append(thickness)

		var cx: int = current % width
		var cy: int = current / width
		var here: float = climb_field[current]

		candidates.clear()
		scores.clear()
		var best_gain: float = -INF
		for dy in range(-1, 2):
			var ny: int = cy + dy
			if ny < 1 or ny >= height - 1:
				continue
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var nx: int = cx + dx
				if nx < 1 or nx >= width - 1:
					continue
				var nidx: int = ny * width + nx
				if visited.has(nidx):
					continue
				var gain: float = climb_field[nidx] - here
				var stepv := Vector2(float(dx), float(dy)).normalized()
				# The two terms are deliberately close in magnitude. Let the
				# climb dominate and every branch bends toward whichever
				# range is nearest; let the heading dominate and the channels
				# ignore the terrain. This balance keeps them climbing while
				# still honouring the direction they set out in.
				var score: float = gain * 6.0 + heading.dot(stepv) * 1.4
				candidates.append(nidx)
				scores.append(score)
				best_gain = maxf(best_gain, gain)

		if candidates.is_empty():
			return # boxed in by ground already carved

		var next_idx: int
		if rng.randf() < GameConfig.WADI_CLIMB_BIAS:
			next_idx = candidates[0]
			var best: float = scores[0]
			for i in range(1, candidates.size()):
				if scores[i] > best:
					best = scores[i]
					next_idx = candidates[i]
		else:
			next_idx = candidates[rng.randi_range(0, candidates.size() - 1)]

		if best_gain <= 0.0:
			stall_budget -= 1
			if stall_budget <= 0:
				return # genuinely nothing left to climb
		else:
			stall_budget = mini(stall_budget + 1, 25)

		# Ease the heading toward the direction actually taken, so channels
		# curve instead of turning in hard corners.
		var moved := Vector2(float(next_idx % width - cx), float(next_idx / width - cy)).normalized()
		heading = (heading * 0.88 + moved * 0.12).normalized()

		visited[next_idx] = true
		current = next_idx

		if elevation[current] > GameConfig.WADI_MAX_CLIMB_ELEVATION:
			return # up in the high rock; the channel head ends here

		# Occasional split into a thinner tributary, sent off at an angle.
		if thickness > 1.0 and depth < GameConfig.WADI_MAX_BRANCH_DEPTH \
				and rng.randf() < GameConfig.WADI_BRANCH_CHANCE:
			var spread: float = rng.randf_range(0.6, 1.2) * (1.0 if rng.randf() < 0.5 else -1.0)
			_grow_branch(width, height, current, thickness - 1.0, depth + 1,
				heading.rotated(spread), rng, elevation, climb_field,
				visited, node_idx, node_thickness, budget)

## Box-blurs a field. Used to give the climb the broad shape of the land
## rather than its per-tile roughness.
static func _smooth_field(src: PackedFloat32Array, width: int, height: int, radius: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(src.size())
	for y in range(height):
		for x in range(width):
			var total: float = 0.0
			var count: int = 0
			for dy in range(-radius, radius + 1):
				var ny: int = y + dy
				if ny < 0 or ny >= height:
					continue
				var row: int = ny * width
				for dx in range(-radius, radius + 1):
					var nx: int = x + dx
					if nx < 0 or nx >= width:
						continue
					total += src[row + nx]
					count += 1
			out[y * width + x] = total / float(count)
	return out

## Cuts the recorded network into the heightmap. A channel is widest and
## deepest at the oasis end, where the most water has gathered, and narrows
## to a scratch up in the hills -- so both branch thickness and distance from
## the sink feed into the profile.
static func _carve_network(width: int, height: int, oasis_idx: int,
		node_idx: PackedInt32Array, node_thickness: PackedFloat32Array,
		elevation: PackedFloat32Array, wadi_strength: PackedFloat32Array) -> void:
	if node_idx.is_empty():
		return
	var ox: int = oasis_idx % width
	var oy: int = oasis_idx / width

	# Normalise distance against the furthest node this network reached.
	var max_dist: float = 1.0
	for i in range(node_idx.size()):
		var px: int = node_idx[i] % width
		var py: int = node_idx[i] / width
		max_dist = maxf(max_dist, sqrt(float((px - ox) * (px - ox) + (py - oy) * (py - oy))))

	var max_thickness: float = float(GameConfig.WADI_START_THICKNESS)
	for i in range(node_idx.size()):
		var idx: int = node_idx[i]
		var px: int = idx % width
		var py: int = idx / width
		var dist: float = sqrt(float((px - ox) * (px - ox) + (py - oy) * (py - oy)))
		var near_oasis: float = clampf(1.0 - dist / max_dist, 0.0, 1.0)
		var order: float = clampf(node_thickness[i] / max_thickness, 0.0, 1.0)

		# Blend the two so a thick trunk far from the sink is still a real
		# channel, and a thin twig near it is still modest.
		var scale: float = 0.30 + 0.70 * (near_oasis * 0.6 + order * 0.4)
		_carve_at(width, height, px, py,
			GameConfig.WADI_WIDTH * scale, GameConfig.WADI_DEPTH * scale,
			elevation, wadi_strength)

## The sink itself: a flat alluvial plain. Sediment washed down the wadi
## settles here, so the ground is level, slightly proud of the channel floor,
## and the most fertile land on the map.
static func _lay_down_oasis_plain(width: int, height: int, oasis_idx: int,
		elevation: PackedFloat32Array, wadi_strength: PackedFloat32Array) -> void:
	var ox: int = oasis_idx % width
	var oy: int = oasis_idx / width
	var r: int = int(ceil(GameConfig.OASIS_BASIN_RADIUS))

	# Level to the local floor, plus a little, so the plain reads as filled
	# with silt rather than as another hole.
	var floor_h: float = elevation[oasis_idx]
	for dy in range(-r, r + 1):
		var ny: int = oy + dy
		if ny < 0 or ny >= height:
			continue
		for dx in range(-r, r + 1):
			var nx: int = ox + dx
			if nx < 0 or nx >= width:
				continue
			if sqrt(float(dx * dx + dy * dy)) > GameConfig.OASIS_BASIN_RADIUS:
				continue
			floor_h = minf(floor_h, elevation[ny * width + nx])
	var plain_h: float = floor_h + 0.35

	for dy in range(-r, r + 1):
		var ny: int = oy + dy
		if ny < 0 or ny >= height:
			continue
		for dx in range(-r, r + 1):
			var nx: int = ox + dx
			if nx < 0 or nx >= width:
				continue
			var dist: float = sqrt(float(dx * dx + dy * dy))
			if dist > GameConfig.OASIS_BASIN_RADIUS:
				continue
			var nidx: int = ny * width + nx
			var t: float = clampf(1.0 - dist / GameConfig.OASIS_BASIN_RADIUS, 0.0, 1.0)
			elevation[nidx] = lerpf(elevation[nidx], plain_h, t)
			wadi_strength[nidx] = maxf(wadi_strength[nidx], 0.55 + t * 0.45)

## Wadis do not have knife-sharp edges. Blurs elevation only where the
## network actually cut, so the rest of the terrain keeps its definition.
static func _smooth_wadi_shoulders(width: int, height: int,
		elevation: PackedFloat32Array, wadi_strength: PackedFloat32Array) -> void:
	for pass_i in range(GameConfig.WADI_SMOOTH_PASSES):
		var src: PackedFloat32Array = elevation.duplicate()
		for y in range(1, height - 1):
			for x in range(1, width - 1):
				var idx: int = y * width + x
				var w: float = wadi_strength[idx]
				if w <= 0.01:
					continue
				var total: float = 0.0
				for dy in range(-1, 2):
					var row: int = (y + dy) * width
					for dx in range(-1, 2):
						total += src[row + x + dx]
				# Blend toward the local average, strongest in the channel.
				elevation[idx] = lerpf(src[idx], total / 9.0, clampf(w, 0.0, 1.0) * 0.6)

## Cuts a single channel cross-section into the heightmap, with a silt apron
## either side. A wadi is a flat-floored notch with soft shoulders, so the
## profile falls off with distance and the alluvium grades outward past the
## channel edge rather than stopping at it.
static func _carve_at(width: int, height: int, px: int, py: int, w: float, d: float,
		elevation: PackedFloat32Array, wadi_strength: PackedFloat32Array) -> void:
	if w <= 0.0:
		return
	var r: int = int(ceil(w + GameConfig.ALLUVIUM_WIDTH))
	for dy in range(-r, r + 1):
		var ny: int = py + dy
		if ny < 0 or ny >= height:
			continue
		var row: int = ny * width
		for dx in range(-r, r + 1):
			var nx: int = px + dx
			if nx < 0 or nx >= width:
				continue
			var dist: float = sqrt(float(dx * dx + dy * dy))
			var nidx: int = row + nx
			if dist <= w:
				elevation[nidx] -= d * (1.0 - dist / w)
				wadi_strength[nidx] = maxf(wadi_strength[nidx], 1.0 - dist / w)
			elif dist <= w + GameConfig.ALLUVIUM_WIDTH:
				var t: float = 1.0 - (dist - w) / GameConfig.ALLUVIUM_WIDTH
				wadi_strength[nidx] = maxf(wadi_strength[nidx], t * 0.6)

## Picks the sinks. An oasis wants low, flat ground out on the valley floor,
## clear of the ranges and reasonably far from its neighbours.
static func _pick_oasis_sites(width: int, height: int, rng: RandomNumberGenerator,
		elevation: PackedFloat32Array, mountain_mask: PackedFloat32Array,
		left_centers: PackedFloat32Array, right_centers: PackedFloat32Array) -> PackedInt32Array:
	var chosen := PackedInt32Array()
	var bands: int = GameConfig.OASIS_COUNT

	for band in range(bands):
		# Spread the sites down the length of the valley, then search a
		# window around that band for the lowest valley-floor tile.
		var band_centre: float = float(height) * (float(band) + 0.5) / float(bands)
		var best_idx: int = -1
		var best_h: float = INF
		for attempt in range(400):
			var y: int = clampi(int(band_centre + rng.randf_range(-1.0, 1.0) * float(height) / float(bands) * 0.4), 2, height - 3)
			var lo: float = left_centers[y] + GameConfig.FOOTHILL_WIDTH
			var hi: float = right_centers[y] - GameConfig.FOOTHILL_WIDTH
			if hi - lo < 8.0:
				continue
			var x: int = clampi(int(rng.randf_range(lo, hi)), 2, width - 3)
			var idx: int = y * width + x
			if mountain_mask[idx] > 0.12:
				continue
			var too_close: bool = false
			for other in chosen:
				var dx: int = (other % width) - x
				var dy: int = (other / width) - y
				if dx * dx + dy * dy < GameConfig.OASIS_MIN_SEPARATION * GameConfig.OASIS_MIN_SEPARATION:
					too_close = true
					break
			if too_close:
				continue
			if elevation[idx] < best_h:
				best_h = elevation[idx]
				best_idx = idx
		if best_idx >= 0:
			chosen.append(best_idx)
	return chosen


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

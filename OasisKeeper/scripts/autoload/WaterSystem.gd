extends Node
## Moves water through the built network and into the soil.
##
## The model is intentionally simple enough that a player can predict it:
##
##   1. Every built water structure has a *floor* one CANAL_FLOOR_DEPTH below
##      the terrain, and holds a depth of water on top of it.
##   2. Its hydraulic head is floor + depth. Each tick, every pair of
##      connected neighbours moves FLOW_RATE of their head difference from
##      the higher to the lower one. Water therefore genuinely flows from
##      one canal tile to the next, downhill, and pools where the ground
##      levels out.
##   2b. Above that, one hard rule: water never climbs a height level. A
##      tile only ever pushes into a neighbour on its own level or lower,
##      no matter how full it is. Head decides how fast water moves and
##      between which tiles on a level; the level decides whether it may
##      move at all. To get water up a step you terrace the step away.
##   3. A mountain canal tile sitting on an aquifer body draws from that
##      body's finite volume -- this is the only way water enters the map,
##      apart from wells over rare valley groundwater.
##   4. Open structures lose water to evaporation (handled in
##      ClimateSystem); covered ones lose almost none.
##
## Net movement per tile is accumulated into flow_x/flow_y so the renderer
## can draw arrows and the player can *see* which way the water is going.

var _active: Dictionary = {} # idx(int) -> true, tiles currently worth simulating
## Tiles that draw water from the world: mountain canals sitting on an
## aquifer, and wells over groundwater. Evaluated when the structure is
## built rather than every tick, and these never go to sleep -- they are
## what refills a network that has run dry.
var _sources: Dictionary = {} # idx(int) -> true
var _moist_soil: Dictionary = {} # idx(int) -> true, tiles with soil_moisture > epsilon

var _neighbor_buf: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var _flow_accum_x: PackedFloat32Array = PackedFloat32Array()
var _flow_accum_y: PackedFloat32Array = PackedFloat32Array()

const SOIL_EPSILON: float = 0.02
const WATER_EPSILON: float = 0.005

func _ready() -> void:
	EventBus.world_generated.connect(_on_world_generated)
	EventBus.terrain_modified.connect(_on_terrain_modified)

func _on_world_generated() -> void:
	_active.clear()
	_sources.clear()
	_moist_soil.clear()
	var size: int = WorldMap.width * WorldMap.height
	_flow_accum_x = PackedFloat32Array()
	_flow_accum_x.resize(size)
	_flow_accum_y = PackedFloat32Array()
	_flow_accum_y.resize(size)

func register_structure(idx: int) -> void:
	if WorldMap.structure_type[idx] == WorldMap.Structure.NONE:
		unregister_structure(idx)
		return
	_active[idx] = true
	if _has_water_access(idx):
		_sources[idx] = true
	else:
		_sources.erase(idx)

func unregister_structure(idx: int) -> void:
	_active.erase(idx)
	_sources.erase(idx)

## Whether this structure can draw water from the world. Checked once when
## the structure is built, not every tick.
func _has_water_access(idx: int) -> bool:
	var s: int = WorldMap.structure_type[idx]
	if s == WorldMap.Structure.CANAL_MOUNTAIN:
		return WorldMap.has_aquifer(idx)
	if s == WorldMap.Structure.WELL:
		return WorldMap.rare_groundwater[idx] > 0.0
	return false

## Terracing changes hydraulic head, so anything sleeping around the edited
## tile has to be reconsidered.
func _on_terrain_modified(idx: int) -> void:
	if WorldMap.structure_type[idx] != WorldMap.Structure.NONE:
		_active[idx] = true
	var count: int = WorldMap.get_neighbors4(idx, _neighbor_buf)
	for n in range(count):
		var nidx: int = _neighbor_buf[n]
		if WorldMap.structure_type[nidx] != WorldMap.Structure.NONE:
			_active[nidx] = true

func toggle_gate(idx: int) -> void:
	if WorldMap.structure_type[idx] != WorldMap.Structure.GATE:
		return
	WorldMap.gate_open[idx] = 0 if WorldMap.gate_open[idx] == 1 else 1
	EventBus.emit_signal("gate_toggled", idx, WorldMap.gate_open[idx] == 1)

func simulate_tick() -> void:
	if WorldMap.width == 0:
		return
	_recharge_aquifers()
	_tap_sources()
	_flow_pass()
	_irrigate()
	_diffuse_soil()

func _recharge_aquifers() -> void:
	for body in range(WorldMap.aquifer_volume.size()):
		if WorldMap.aquifer_volume[body] < WorldMap.aquifer_max_volume[body]:
			WorldMap.aquifer_volume[body] = minf(
				WorldMap.aquifer_max_volume[body],
				WorldMap.aquifer_volume[body] + WorldMap.aquifer_recharge[body])

## Mountain canal tiles standing on an aquifer draw from it; wells draw from
## rare valley groundwater. Both are rate-limited, and an aquifer that is
## running low yields proportionally less.
func _tap_sources() -> void:
	for idx in _sources.keys():
		var idx_i: int = idx
		_active[idx_i] = true # a source is never idle
		var s: int = WorldMap.structure_type[idx_i]
		var cap: float = WorldMap.water_capacity(idx_i)
		var room: float = cap - WorldMap.water[idx_i]
		if room <= 0.0:
			continue
		if s == WorldMap.Structure.CANAL_MOUNTAIN:
			var body: int = WorldMap.aquifer_id[idx_i]
			if body < 0 or body >= WorldMap.aquifer_volume.size():
				continue
			var pressure: float = pow(WorldMap.aquifer_fill_fraction(idx_i), GameConfig.AQUIFER_PRESSURE_EXPONENT)
			var draw: float = minf(GameConfig.AQUIFER_TAP_RATE * pressure, room)
			draw = minf(draw, WorldMap.aquifer_volume[body])
			if draw <= 0.0:
				continue
			WorldMap.aquifer_volume[body] -= draw
			WorldMap.water[idx_i] += draw
		elif s == WorldMap.Structure.WELL:
			var yield_frac: float = WorldMap.rare_groundwater[idx_i]
			if yield_frac <= 0.0:
				continue
			WorldMap.water[idx_i] += minf(GameConfig.WELL_RECHARGE_RATE * yield_frac, room)

## Moves water one tick.
##
## Each tile with water finds every connected neighbour whose water *surface*
## sits lower than its own, and pushes out at most FLOW_RATE, split between
## them in proportion to how much lower each one is. So a channel that forks
## feeds both forks, weighted by pressure, instead of the whole flow picking
## a single downstream tile.
##
## Two details that matter:
##
##  - A transfer is capped at FLOW_EQUALISE_CAP of the head difference.
##    Water raises the receiving surface as it drops the donating one, so
##    moving more than half the difference overshoots level and the pair
##    ping-pongs water back and forth forever.
##  - Tiles that are dry and have no source go to sleep, and are woken again
##    only when a neighbour pushes water into them. On a large network the
##    great majority of tiles are idle at any moment.
func _flow_pass() -> void:
	_flow_accum_x.fill(0.0)
	_flow_accum_y.fill(0.0)

	var to_sleep: Array[int] = []
	var targets := PackedInt32Array()
	var diffs := PackedFloat32Array()

	for idx in _active.keys():
		var idx_i: int = idx
		if not WorldMap.conducts_water(idx_i):
			continue
		if WorldMap.water[idx_i] <= WATER_EPSILON:
			# Dry, and nothing feeds it: stop paying for this tile.
			if not _sources.has(idx_i):
				to_sleep.append(idx_i)
			continue

		var self_head: float = WorldMap.head(idx_i)
		targets.clear()
		diffs.clear()
		var total_diff: float = 0.0

		var count: int = WorldMap.get_neighbors4(idx_i, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			# Deliberately tested against the structure, NOT against the
			# active set: a sleeping tile is exactly the one we need to be
			# able to push water into, and excluding it would mean a dry
			# network could never be woken again.
			if not WorldMap.conducts_water(nidx):
				continue
			if not WorldMap.water_may_pass(idx_i, nidx):
				continue # basin rim: only inlets exchange with the outside
			# Reservoirs and cisterns are ALWAYS open to connected canals at any level.
			# This allows them to fill from source canals regardless of height difference.
			# Water flows into reservoirs until reaching the target level or source canal level.
			var is_reservoir_dest: bool = WorldMap.is_reservoir_or_cistern(nidx)
			var is_canal_source: bool = WorldMap.is_canal(idx_i)
			# Check if reservoir has reached its target level
			var reservoir_at_target: bool = false
			if is_reservoir_dest:
				var target_level: int = WorldMap.reservoir_target_level[nidx]
				var current_level: int = WorldMap.height_level(nidx)
				var water_depth_levels: float = WorldMap.water[nidx] / GameConfig.CANAL_CAPACITY
				var effective_level: float = float(current_level) + water_depth_levels
				# Stop filling if we have reached the target level (in height units)
				if effective_level >= float(target_level):
					reservoir_at_target = true
			
			# Water never climbs EXCEPT when flowing into a reservoir/cistern.
			# For normal canal-to-canal flow, the no-uphill rule still applies.
			if not is_reservoir_dest:
				if WorldMap.height_differential(idx_i, nidx) < 0:
					continue
			if WorldMap.water[nidx] >= WorldMap.water_capacity(nidx) or reservoir_at_target:
				continue
			var diff: float = self_head - WorldMap.head(nidx)
			if diff <= GameConfig.MIN_FLOW_EPSILON:
				continue
			targets.append(nidx)
			diffs.append(diff)
			total_diff += diff

		if targets.is_empty() or total_diff <= 0.0:
			continue

		# Pressure: a fuller channel pushes harder. Head difference already
		# sets which way water goes and roughly how fast; this adds the
		# separate effect that a brim-full channel drives its outflow harder
		# than a trickle sitting at the same gradient, so a well-fed line
		# delivers noticeably more than a starved one.
		var fill: float = WorldMap.water[idx_i] / maxf(0.001, WorldMap.water_capacity(idx_i))
		var pressure: float = 1.0 + clampf(fill, 0.0, 1.0) * GameConfig.FLOW_PRESSURE_BOOST
		var budget: float = minf(GameConfig.FLOW_RATE * pressure, WorldMap.water[idx_i])
		for t in range(targets.size()):
			var nidx: int = targets[t]
			var share: float = diffs[t] / total_diff
			var amount: float = budget * share
			amount = minf(amount, diffs[t] * GameConfig.FLOW_EQUALISE_CAP)
			amount = minf(amount, WorldMap.water_capacity(nidx) - WorldMap.water[nidx])
			amount = minf(amount, WorldMap.water[idx_i])
			if amount <= GameConfig.MIN_FLOW_EPSILON:
				continue

			WorldMap.water[idx_i] -= amount
			WorldMap.water[nidx] += amount
			_active[nidx] = true # a sleeping tile that receives water wakes up

			var dx: int = (nidx % WorldMap.width) - (idx_i % WorldMap.width)
			var dy: int = (nidx / WorldMap.width) - (idx_i / WorldMap.width)
			_flow_accum_x[idx_i] += float(dx) * amount
			_flow_accum_y[idx_i] += float(dy) * amount
			_flow_accum_x[nidx] += float(dx) * amount
			_flow_accum_y[nidx] += float(dy) * amount

	for idx in to_sleep:
		_active.erase(idx)

	# Smooth the arrows so they don't jitter frame to frame.
	var k: float = GameConfig.FLOW_VECTOR_SMOOTHING
	for idx in _active.keys():
		var idx_i: int = idx
		WorldMap.flow_x[idx_i] = lerpf(WorldMap.flow_x[idx_i], _flow_accum_x[idx_i], k)
		WorldMap.flow_y[idx_i] = lerpf(WorldMap.flow_y[idx_i], _flow_accum_y[idx_i], k)

## Open canals wet the ground beside them. Covered channels deliberately do
## not: a qanat delivers water where you choose to open it, not everywhere
## it passes.
func _irrigate() -> void:
	for idx in _active.keys():
		var idx_i: int = idx
		var s: int = WorldMap.structure_type[idx_i]
		if s == WorldMap.Structure.CANAL_COVERED or s == WorldMap.Structure.CISTERN:
			continue
		if not WorldMap.conducts_water(idx_i):
			continue
		if WorldMap.water[idx_i] <= WATER_EPSILON:
			continue
		var count: int = WorldMap.get_neighbors4(idx_i, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			if WorldMap.structure_type[nidx] != WorldMap.Structure.NONE:
				continue
			if not WorldMap.is_plantable_ground(nidx):
				continue # bare rock holds no irrigable soil
			if WorldMap.height_level(nidx) > WorldMap.height_level(idx_i):
				continue # a canal cannot wet ground terraced above itself
			var room: float = GameConfig.SOIL_WATER_CAPACITY - WorldMap.soil_moisture[nidx]
			if room <= 0.0:
				continue
			# Scaling by the moisture deficit means already-wet ground stops
			# drinking, so a canal saturates its banks and then carries the
			# rest onward instead of bleeding out along its whole length.
			var deficit: float = room / GameConfig.SOIL_WATER_CAPACITY
			var amount: float = minf(WorldMap.water[idx_i] * GameConfig.SOIL_ABSORPTION_RATE * deficit, room)
			if amount <= 0.0:
				continue
			WorldMap.water[idx_i] -= amount
			WorldMap.soil_moisture[nidx] += amount
			_moist_soil[nidx] = true
			if WorldMap.water[idx_i] <= WATER_EPSILON:
				break

func _diffuse_soil() -> void:
	var to_remove: Array[int] = []
	for idx in _moist_soil.keys():
		var idx_i: int = idx
		if WorldMap.soil_moisture[idx_i] <= SOIL_EPSILON:
			to_remove.append(idx_i)
			continue
		var count: int = WorldMap.get_neighbors4(idx_i, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			if nidx <= idx_i:
				continue
			if WorldMap.structure_type[nidx] != WorldMap.Structure.NONE:
				continue
			if not WorldMap.is_plantable_ground(nidx):
				continue
			var diff: float = WorldMap.soil_moisture[idx_i] - WorldMap.soil_moisture[nidx]
			if absf(diff) < 0.05:
				continue
			# Capillary spread obeys the same rule as open water: damp ground
			# wets what is level with it or below it, never a terrace above.
			var step: int = WorldMap.height_differential(idx_i, nidx)
			if (diff > 0.0 and step < 0) or (diff < 0.0 and step > 0):
				continue
			var transfer: float = diff * GameConfig.SOIL_DIFFUSION_RATE
			WorldMap.soil_moisture[idx_i] -= transfer
			WorldMap.soil_moisture[nidx] += transfer
			if WorldMap.soil_moisture[nidx] > SOIL_EPSILON:
				_moist_soil[nidx] = true
	for idx in to_remove:
		_moist_soil.erase(idx)

## Called by ClimateSystem/PlantSystem after they drain soil_moisture, so a
## tile that has dried out drops out of the active diffusion set.
func notify_soil_dried(idx: int) -> void:
	if WorldMap.soil_moisture[idx] <= SOIL_EPSILON:
		_moist_soil.erase(idx)

## Why a water structure is holding on to its water instead of passing it on,
## phrased for the tile inspector. Returns "" when it has somewhere to send it.
## Reading this out is what makes the no-uphill rule teachable rather than
## mysterious: the answer is almost always "grade the route".
func outflow_block_reason(idx: int) -> String:
	if not WorldMap.conducts_water(idx):
		return ""
	var buf := PackedInt32Array([0, 0, 0, 0])
	var count: int = WorldMap.get_neighbors4(idx, buf)
	var connected: int = 0
	var uphill: int = 0
	for n in range(count):
		var nidx: int = buf[n]
		if not WorldMap.conducts_water(nidx):
			continue
		if not WorldMap.water_may_pass(idx, nidx):
			continue
		connected += 1
		if WorldMap.height_differential(idx, nidx) < 0:
			uphill += 1
	if connected == 0:
		return "Dead end - nothing connected to carry the water onward"
	if uphill == connected:
		return "Blocked: every connection leads uphill. Dig the route down to level %d." % WorldMap.water_level(idx)
	return ""

func get_active_tiles() -> Dictionary:
	return _active

func get_moist_soil_tiles() -> Dictionary:
	return _moist_soil

## Total water currently standing in the player's network, for the HUD.
func total_stored_water() -> float:
	var total: float = 0.0
	for idx in _active.keys():
		total += WorldMap.water[idx]
	return total

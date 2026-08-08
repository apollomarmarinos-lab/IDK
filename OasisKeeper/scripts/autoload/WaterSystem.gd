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
##   3. A mountain canal tile sitting on an aquifer body draws from that
##      body's finite volume -- this is the only way water enters the map,
##      apart from wells over rare valley groundwater.
##   4. Open structures lose water to evaporation (handled in
##      ClimateSystem); covered ones lose almost none.
##
## Net movement per tile is accumulated into flow_x/flow_y so the renderer
## can draw arrows and the player can *see* which way the water is going.

var _active: Dictionary = {} # idx(int) -> true, every tile with a water structure
var _moist_soil: Dictionary = {} # idx(int) -> true, tiles with soil_moisture > epsilon

var _neighbor_buf: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])
var _flow_accum_x: PackedFloat32Array = PackedFloat32Array()
var _flow_accum_y: PackedFloat32Array = PackedFloat32Array()

const SOIL_EPSILON: float = 0.02
const WATER_EPSILON: float = 0.005

func _ready() -> void:
	EventBus.world_generated.connect(_on_world_generated)

func _on_world_generated() -> void:
	_active.clear()
	_moist_soil.clear()
	var size: int = WorldMap.width * WorldMap.height
	_flow_accum_x = PackedFloat32Array()
	_flow_accum_x.resize(size)
	_flow_accum_y = PackedFloat32Array()
	_flow_accum_y.resize(size)

func register_structure(idx: int) -> void:
	if WorldMap.structure_type[idx] == WorldMap.Structure.NONE:
		_active.erase(idx)
	else:
		_active[idx] = true

func unregister_structure(idx: int) -> void:
	_active.erase(idx)

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
	for idx in _active.keys():
		var idx_i: int = idx
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

func _flow_pass() -> void:
	_flow_accum_x.fill(0.0)
	_flow_accum_y.fill(0.0)

	for idx in _active.keys():
		var idx_i: int = idx
		if not WorldMap.conducts_water(idx_i):
			continue
		var head_a: float = WorldMap.head(idx_i)
		var count: int = WorldMap.get_neighbors4(idx_i, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			if nidx <= idx_i:
				continue # handle each undirected pair exactly once
			if not _active.has(nidx) or not WorldMap.conducts_water(nidx):
				continue
			var diff: float = head_a - WorldMap.head(nidx)
			if absf(diff) < GameConfig.MIN_FLOW_EPSILON:
				continue
			# Move a fraction of the head difference, clamped so neither side
			# can go negative or overfill. Halved because each pair settles
			# toward the midpoint.
			var transfer: float = diff * GameConfig.FLOW_RATE * 0.5
			if transfer > 0.0:
				transfer = minf(transfer, WorldMap.water[idx_i])
				transfer = minf(transfer, WorldMap.water_capacity(nidx) - WorldMap.water[nidx])
			else:
				transfer = maxf(transfer, -WorldMap.water[nidx])
				transfer = maxf(transfer, -(WorldMap.water_capacity(idx_i) - WorldMap.water[idx_i]))
			if absf(transfer) < GameConfig.MIN_FLOW_EPSILON:
				continue
			WorldMap.water[idx_i] -= transfer
			WorldMap.water[nidx] += transfer
			head_a = WorldMap.head(idx_i)

			# Record the direction water actually moved, for the flow arrows.
			var dx: int = (nidx % WorldMap.width) - (idx_i % WorldMap.width)
			var dy: int = (nidx / WorldMap.width) - (idx_i / WorldMap.width)
			_flow_accum_x[idx_i] += float(dx) * transfer
			_flow_accum_y[idx_i] += float(dy) * transfer
			_flow_accum_x[nidx] += float(dx) * transfer
			_flow_accum_y[nidx] += float(dy) * transfer

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

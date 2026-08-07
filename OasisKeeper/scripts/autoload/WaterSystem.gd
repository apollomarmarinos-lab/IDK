extends Node
## Moves water through the built canal networks and into the soil.
##
## Three canal categories, per the design brief:
##   - CANAL_MOUNTAIN_TAP: dug into the mountain rock, recharges from
##     aquifer_potential (the underground water table the mountains hold).
##   - CANAL_OPEN: open-air channels; exposed to full evaporation and can
##     irrigate adjacent soil directly.
##   - CANAL_UNDERGROUND: qanat-style buried channels; a separate network
##     using the `underground_water` layer, nearly immune to evaporation,
##     which must resurface through a WELL_OUTLET to reach plants.
##
## Flow is a simple mass-conserving cellular automaton (each tick, adjacent
## conducting tiles trade a fraction of their head-height difference) rather
## than a full fluid solver -- the standard, cheap approach used by games in
## this genre. Only tiles that are part of a built network hold surface
## water; the open desert never floods.

var _active_surface: Dictionary = {} # idx(int) -> true
var _active_underground: Dictionary = {} # idx(int) -> true
var _moist_soil: Dictionary = {} # idx(int) -> true, tiles with soil_moisture > epsilon

var _neighbor_buf: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])

const SOIL_EPSILON: float = 0.02
const WATER_EPSILON: float = 0.01

func register_structure(idx: int) -> void:
	var s: int = WorldMap.structure_type[idx]
	match s:
		WorldMap.Structure.CANAL_UNDERGROUND:
			_active_underground[idx] = true
			_active_surface.erase(idx)
		WorldMap.Structure.NONE:
			unregister_structure(idx)
		_:
			_active_surface[idx] = true
			_active_underground.erase(idx)

func unregister_structure(idx: int) -> void:
	_active_surface.erase(idx)
	_active_underground.erase(idx)

func toggle_gate(idx: int) -> void:
	if WorldMap.structure_type[idx] != WorldMap.Structure.GATE:
		return
	WorldMap.gate_open[idx] = 0 if WorldMap.gate_open[idx] == 1 else 1
	EventBus.emit_signal("gate_toggled", idx, WorldMap.gate_open[idx] == 1)

func simulate_tick() -> void:
	_recharge_sources()
	_flow_pass(_active_surface, WorldMap.surface_water, true)
	_flow_pass(_active_underground, WorldMap.underground_water, false)
	_mountain_tap_to_qanat_transfer()
	_well_outlets()
	_irrigate()
	_diffuse_soil()

func _capacity_for(idx: int, is_surface: bool) -> float:
	if is_surface:
		return WorldMap.water_capacity(idx)
	return GameConfig.TILE_WATER_CAPACITY

func _recharge_sources() -> void:
	for idx in _active_surface.keys():
		if WorldMap.structure_type[idx] == WorldMap.Structure.CANAL_MOUNTAIN_TAP:
			var cap: float = WorldMap.water_capacity(idx)
			var gain: float = GameConfig.AQUIFER_RECHARGE_RATE * WorldMap.aquifer_potential[idx]
			WorldMap.surface_water[idx] = minf(cap, WorldMap.surface_water[idx] + gain)

func _flow_pass(active_set: Dictionary, layer: PackedFloat32Array, is_surface: bool) -> void:
	for idx in active_set.keys():
		var idx_i: int = idx
		if is_surface and not WorldMap.conducts_surface_water(idx_i):
			continue
		var count: int = WorldMap.get_neighbors4(idx_i, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			if nidx <= idx_i:
				continue # process each undirected pair once
			if not active_set.has(nidx):
				continue
			if is_surface and not WorldMap.conducts_surface_water(nidx):
				continue
			var level_a: float = WorldMap.elevation[idx_i] + layer[idx_i]
			var level_b: float = WorldMap.elevation[nidx] + layer[nidx]
			var diff: float = level_a - level_b
			if absf(diff) < GameConfig.MIN_FLOW_EPSILON:
				continue
			var transfer: float = diff * GameConfig.FLOW_RATE * 0.5
			if transfer > 0.0:
				transfer = minf(transfer, layer[idx_i])
				transfer = minf(transfer, _capacity_for(nidx, is_surface) - layer[nidx])
			else:
				transfer = maxf(transfer, -layer[nidx])
				transfer = maxf(transfer, -(_capacity_for(idx_i, is_surface) - layer[idx_i]))
			if absf(transfer) < GameConfig.MIN_FLOW_EPSILON:
				continue
			layer[idx_i] -= transfer
			layer[nidx] += transfer

func _mountain_tap_to_qanat_transfer() -> void:
	# A mountain tap standing next to a dug underground segment channels
	# its water down into the qanat network.
	for idx in _active_surface.keys():
		if WorldMap.structure_type[idx] != WorldMap.Structure.CANAL_MOUNTAIN_TAP:
			continue
		if WorldMap.surface_water[idx] <= WATER_EPSILON:
			continue
		var count: int = WorldMap.get_neighbors4(idx, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			if not _active_underground.has(nidx):
				continue
			var room: float = GameConfig.TILE_WATER_CAPACITY - WorldMap.underground_water[nidx]
			var amount: float = minf(WorldMap.surface_water[idx] * 0.5, room)
			amount = maxf(amount, 0.0)
			WorldMap.surface_water[idx] -= amount
			WorldMap.underground_water[nidx] += amount

func _well_outlets() -> void:
	for idx in _active_surface.keys():
		if WorldMap.structure_type[idx] != WorldMap.Structure.WELL_OUTLET:
			continue
		var cap: float = WorldMap.water_capacity(idx)
		if WorldMap.rare_groundwater[idx] > 0.0:
			var gain: float = GameConfig.RARE_WELL_RECHARGE_RATE * WorldMap.rare_groundwater[idx]
			WorldMap.surface_water[idx] = minf(cap, WorldMap.surface_water[idx] + gain)
		elif _active_underground.has(idx) or WorldMap.underground_water[idx] > 0.0:
			var rise: float = minf(WorldMap.underground_water[idx], (cap - WorldMap.surface_water[idx]))
			rise = minf(rise, GameConfig.AQUIFER_RECHARGE_RATE)
			rise = maxf(rise, 0.0)
			WorldMap.underground_water[idx] -= rise
			WorldMap.surface_water[idx] += rise

func _irrigate() -> void:
	for idx in _active_surface.keys():
		var idx_i: int = idx
		if not WorldMap.conducts_surface_water(idx_i):
			continue
		if WorldMap.surface_water[idx_i] <= WATER_EPSILON:
			continue
		var count: int = WorldMap.get_neighbors4(idx_i, _neighbor_buf)
		for n in range(count):
			var nidx: int = _neighbor_buf[n]
			if WorldMap.structure_type[nidx] != WorldMap.Structure.NONE:
				continue
			if WorldMap.terrain_type[nidx] != WorldMap.Terrain.SAND:
				continue # bare rock does not hold irrigable soil moisture
			if WorldMap.soil_moisture[nidx] >= GameConfig.SOIL_WATER_CAPACITY:
				continue
			var amount: float = minf(WorldMap.surface_water[idx_i] * GameConfig.SOIL_ABSORPTION_RATE, GameConfig.SOIL_WATER_CAPACITY - WorldMap.soil_moisture[nidx])
			amount = maxf(amount, 0.0)
			if amount <= 0.0:
				continue
			WorldMap.surface_water[idx_i] -= amount
			WorldMap.soil_moisture[nidx] += amount
			_mark_soil_moist(nidx)
			if WorldMap.surface_water[idx_i] <= WATER_EPSILON:
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
			var diff: float = WorldMap.soil_moisture[idx_i] - WorldMap.soil_moisture[nidx]
			if absf(diff) < 0.05:
				continue
			var transfer: float = diff * GameConfig.SOIL_DIFFUSION_RATE
			WorldMap.soil_moisture[idx_i] -= transfer
			WorldMap.soil_moisture[nidx] += transfer
			if WorldMap.soil_moisture[nidx] > SOIL_EPSILON:
				_mark_soil_moist(nidx)
	for idx in to_remove:
		_moist_soil.erase(idx)

func _mark_soil_moist(idx: int) -> void:
	_moist_soil[idx] = true

## Called by ClimateSystem/PlantSystem after they drain soil_moisture, so a
## tile that has dried out drops out of the active diffusion set.
func notify_soil_dried(idx: int) -> void:
	if WorldMap.soil_moisture[idx] <= SOIL_EPSILON:
		_moist_soil.erase(idx)

func get_active_surface_tiles() -> Dictionary:
	return _active_surface

func get_active_underground_tiles() -> Dictionary:
	return _active_underground

func get_moist_soil_tiles() -> Dictionary:
	return _moist_soil

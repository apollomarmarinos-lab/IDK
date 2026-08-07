extends Node
## Placement rules and construction queue for everything the player can
## build: the three canal categories, gates, storage tanks, well outlets and
## man-made shade structures.
##
## Construction takes a few simulated ticks ("digging time") rather than
## completing instantly -- a small but deliberate management cost that
## exists even though the game has no money economy.

var _pending: Dictionary = {} ## idx(int) -> {"structure": int, "ticks_left": int, "ticks_total": int}

func _ready() -> void:
	EventBus.world_generated.connect(func(): _pending.clear())

func can_place(idx: int, structure: int) -> bool:
	if idx < 0 or idx >= WorldMap.width * WorldMap.height:
		return false
	if _pending.has(idx):
		return false
	match structure:
		WorldMap.Structure.CANAL_MOUNTAIN_TAP:
			return WorldMap.is_mountain(idx) and WorldMap.aquifer_potential[idx] > 0.0 and WorldMap.structure_type[idx] == WorldMap.Structure.NONE
		WorldMap.Structure.CANAL_OPEN:
			# Open channels may be carved through mountain rock to connect a
			# tap down to the valley, or dug anywhere in the open desert.
			return WorldMap.structure_type[idx] == WorldMap.Structure.NONE and not PlantSystem.plants.has(idx)
		WorldMap.Structure.CANAL_UNDERGROUND:
			return WorldMap.structure_type[idx] == WorldMap.Structure.NONE and not PlantSystem.plants.has(idx)
		WorldMap.Structure.GATE:
			var s: int = WorldMap.structure_type[idx]
			return s == WorldMap.Structure.CANAL_OPEN or s == WorldMap.Structure.CANAL_MOUNTAIN_TAP
		WorldMap.Structure.STORAGE_TANK:
			return not WorldMap.is_mountain(idx) and WorldMap.structure_type[idx] == WorldMap.Structure.NONE and not PlantSystem.plants.has(idx)
		WorldMap.Structure.SHADE_STRUCTURE:
			return WorldMap.structure_type[idx] == WorldMap.Structure.NONE and not PlantSystem.plants.has(idx)
		WorldMap.Structure.WELL_OUTLET:
			return not WorldMap.is_mountain(idx) and WorldMap.structure_type[idx] == WorldMap.Structure.NONE and not PlantSystem.plants.has(idx)
		_:
			return false

func dig_ticks_for(structure: int) -> int:
	match structure:
		WorldMap.Structure.CANAL_OPEN, WorldMap.Structure.CANAL_UNDERGROUND, WorldMap.Structure.CANAL_MOUNTAIN_TAP:
			return GameConfig.CANAL_DIG_TICKS
		WorldMap.Structure.GATE:
			return 2
		_:
			return GameConfig.BUILDING_DIG_TICKS

func place(idx: int, structure: int) -> bool:
	if not can_place(idx, structure):
		return false
	if structure == WorldMap.Structure.GATE:
		# Converting an existing canal tile into a gate: clear its current
		# structure immediately (it stays a hole in the ground while the
		# gate mechanism is being built) and queue the gate itself.
		WorldMap.reset_tile_structure(idx)
		WaterSystem.unregister_structure(idx)
	var ticks: int = dig_ticks_for(structure)
	_pending[idx] = {"structure": structure, "ticks_left": ticks, "ticks_total": ticks}
	EventBus.emit_signal("building_placed", idx, structure_name(structure))
	EventBus.emit_signal("tile_changed", idx)
	return true

func cancel(idx: int) -> bool:
	if not _pending.has(idx):
		return false
	_pending.erase(idx)
	EventBus.emit_signal("tile_changed", idx)
	return true

func remove(idx: int) -> bool:
	if _pending.has(idx):
		return cancel(idx)
	if WorldMap.structure_type[idx] == WorldMap.Structure.NONE:
		return false
	WaterSystem.unregister_structure(idx)
	WorldMap.reset_tile_structure(idx)
	EventBus.emit_signal("building_removed", idx)
	EventBus.emit_signal("tile_changed", idx)
	return true

func toggle_gate(idx: int) -> void:
	WaterSystem.toggle_gate(idx)

func is_pending(idx: int) -> bool:
	return _pending.has(idx)

func get_pending_tiles() -> Dictionary:
	return _pending

func get_pending_progress(idx: int) -> float:
	if not _pending.has(idx):
		return 1.0
	var entry: Dictionary = _pending[idx]
	return 1.0 - float(entry["ticks_left"]) / float(maxf(1, entry["ticks_total"]))

func simulate_tick() -> void:
	if _pending.is_empty():
		return
	var finished: Array[int] = []
	for idx in _pending.keys():
		var entry: Dictionary = _pending[idx]
		entry["ticks_left"] -= 1
		if entry["ticks_left"] <= 0:
			finished.append(idx)
		else:
			_pending[idx] = entry
	for idx in finished:
		var entry: Dictionary = _pending[idx]
		var structure: int = entry["structure"]
		_pending.erase(idx)
		WorldMap.structure_type[idx] = structure
		if structure == WorldMap.Structure.GATE:
			WorldMap.gate_open[idx] = 1
		WaterSystem.register_structure(idx)
		EventBus.emit_signal("building_completed", idx, structure_name(structure))
		EventBus.emit_signal("tile_changed", idx)

func structure_name(structure: int) -> StringName:
	match structure:
		WorldMap.Structure.CANAL_OPEN:
			return &"canal_open"
		WorldMap.Structure.CANAL_UNDERGROUND:
			return &"canal_underground"
		WorldMap.Structure.CANAL_MOUNTAIN_TAP:
			return &"canal_mountain_tap"
		WorldMap.Structure.GATE:
			return &"gate"
		WorldMap.Structure.STORAGE_TANK:
			return &"storage_tank"
		WorldMap.Structure.SHADE_STRUCTURE:
			return &"shade_structure"
		WorldMap.Structure.WELL_OUTLET:
			return &"well_outlet"
		_:
			return &"none"

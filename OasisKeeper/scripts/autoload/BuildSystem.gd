extends Node
## Placement rules and construction queue for everything the player builds.
##
## The key ergonomic rule: the player picks *what they want* (an open
## channel, a covered channel), not *what the terrain requires*. Dragging a
## canal from the valley up into the rock automatically turns those tiles
## into mountain tunnel segments -- see `resolve_structure()`. There is no
## separate "tap the mountain" building: a mountain tunnel that reaches an
## aquifer body simply starts drawing from it.

var _pending: Dictionary = {} ## idx(int) -> {"structure": int, "ticks_left": int, "ticks_total": int}

func _ready() -> void:
	EventBus.world_generated.connect(func(): _pending.clear())

## Adapts the requested structure to the ground it is being placed on.
## Any canal dug into mountain rock becomes a tunnel segment.
func resolve_structure(idx: int, requested: int) -> int:
	if requested == WorldMap.Structure.CANAL_OPEN or requested == WorldMap.Structure.CANAL_COVERED:
		if WorldMap.is_mountain(idx):
			return WorldMap.Structure.CANAL_MOUNTAIN
	return requested

func can_place(idx: int, requested: int) -> bool:
	if idx < 0 or idx >= WorldMap.width * WorldMap.height:
		return false
	if _pending.has(idx):
		return false
	var structure: int = resolve_structure(idx, requested)
	var occupied: bool = WorldMap.structure_type[idx] != WorldMap.Structure.NONE
	var planted: bool = PlantSystem.plants.has(idx)
	match structure:
		WorldMap.Structure.CANAL_MOUNTAIN:
			return WorldMap.is_mountain(idx) and not occupied
		WorldMap.Structure.CANAL_OPEN, WorldMap.Structure.CANAL_COVERED:
			return not occupied and not planted
		WorldMap.Structure.GATE:
			# Gates are fitted into an existing channel.
			return WorldMap.is_canal(idx)
		WorldMap.Structure.RESERVOIR, WorldMap.Structure.CISTERN, WorldMap.Structure.SHADE_STRUCTURE:
			return not WorldMap.is_mountain(idx) and not occupied and not planted
		WorldMap.Structure.WELL:
			# Only worth sinking where there is actually groundwater.
			return not WorldMap.is_mountain(idx) and not occupied and not planted \
				and WorldMap.rare_groundwater[idx] > 0.0
		_:
			return false

## Human-readable reason placement failed, shown in the build menu so the
## player is never left guessing why a click did nothing.
func placement_hint(idx: int, requested: int) -> String:
	if idx < 0:
		return ""
	if _pending.has(idx):
		return "Already under construction"
	var structure: int = resolve_structure(idx, requested)
	if WorldMap.structure_type[idx] != WorldMap.Structure.NONE and structure != WorldMap.Structure.GATE:
		return "Tile already occupied"
	if PlantSystem.plants.has(idx):
		return "Remove the plant first"
	match structure:
		WorldMap.Structure.GATE:
			if not WorldMap.is_canal(idx):
				return "Gates must be fitted into a canal"
		WorldMap.Structure.WELL:
			if WorldMap.rare_groundwater[idx] <= 0.0:
				return "No groundwater here (use the Groundwater overlay)"
			if WorldMap.is_mountain(idx):
				return "Cannot sink a well into rock"
		WorldMap.Structure.RESERVOIR, WorldMap.Structure.CISTERN, WorldMap.Structure.SHADE_STRUCTURE:
			if WorldMap.is_mountain(idx):
				return "Cannot build on mountain rock"
	return ""

func dig_ticks_for(structure: int) -> int:
	match structure:
		WorldMap.Structure.CANAL_MOUNTAIN:
			return GameConfig.MOUNTAIN_DIG_TICKS
		WorldMap.Structure.CANAL_OPEN:
			return GameConfig.CANAL_DIG_TICKS
		WorldMap.Structure.CANAL_COVERED:
			return GameConfig.CANAL_DIG_TICKS * 2 # roofing costs extra labour
		WorldMap.Structure.GATE:
			return 2
		_:
			return GameConfig.BUILDING_DIG_TICKS

func place(idx: int, requested: int) -> bool:
	if not can_place(idx, requested):
		return false
	var structure: int = resolve_structure(idx, requested)
	if structure == WorldMap.Structure.GATE:
		# Fitting a gate into a live channel: the segment stops conducting
		# while the mechanism is installed.
		WaterSystem.unregister_structure(idx)
		WorldMap.reset_tile_structure(idx)
	var ticks: int = dig_ticks_for(structure)
	_pending[idx] = {"structure": structure, "ticks_left": ticks, "ticks_total": ticks}
	EventBus.emit_signal("building_placed", idx, structure_name(structure))
	EventBus.emit_signal("tile_changed", idx)
	return true

## Terraforming is queued like any other job so it takes visible labour
## rather than snapping the ground the instant you click.
func queue_terraform(idx: int, delta_levels: int) -> bool:
	if _pending.has(idx):
		return false
	if not WorldMap.can_terraform(idx, delta_levels):
		return false
	_pending[idx] = {
		"structure": -1,
		"terraform": delta_levels,
		"ticks_left": GameConfig.TERRAFORM_TICKS,
		"ticks_total": GameConfig.TERRAFORM_TICKS,
	}
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
	return 1.0 - float(entry["ticks_left"]) / float(max(1, int(entry["ticks_total"])))

func simulate_tick() -> void:
	if _pending.is_empty():
		return
	var finished: Array[int] = []
	for idx in _pending.keys():
		var entry: Dictionary = _pending[idx]
		entry["ticks_left"] = int(entry["ticks_left"]) - 1
		_pending[idx] = entry
		if int(entry["ticks_left"]) <= 0:
			finished.append(idx)
	for idx in finished:
		var entry: Dictionary = _pending[idx]
		var structure: int = entry["structure"]
		_pending.erase(idx)
		if entry.has("terraform"):
			WorldMap.apply_terraform(idx, int(entry["terraform"]))
			continue
		WorldMap.structure_type[idx] = structure
		if structure == WorldMap.Structure.GATE:
			WorldMap.gate_open[idx] = 1
		WaterSystem.register_structure(idx)
		EventBus.emit_signal("building_completed", idx, structure_name(structure))
		EventBus.emit_signal("tile_changed", idx)

func structure_name(structure: int) -> StringName:
	match structure:
		WorldMap.Structure.CANAL_OPEN:
			return &"Open Canal"
		WorldMap.Structure.CANAL_COVERED:
			return &"Covered Canal"
		WorldMap.Structure.CANAL_MOUNTAIN:
			return &"Mountain Tunnel"
		WorldMap.Structure.GATE:
			return &"Gate"
		WorldMap.Structure.RESERVOIR:
			return &"Reservoir"
		WorldMap.Structure.CISTERN:
			return &"Cistern"
		WorldMap.Structure.SHADE_STRUCTURE:
			return &"Shade Structure"
		WorldMap.Structure.WELL:
			return &"Well"
		_:
			return &"None"

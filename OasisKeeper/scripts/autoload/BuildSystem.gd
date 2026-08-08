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
## Footprint currently selected for multi-tile basins, cycled with R.
var basin_size_index: int = 0
## Target water level offset for reservoirs/cisterns (relative to source canal level).
## Adjusted with +/- keys or scroll wheel while placing reservoir/cistern.
var reservoir_level_offset: int = 0

## Footprint of a structure in tiles. Everything not listed is a single tile.
func footprint_of(structure: int) -> Vector2i:
	if structure == WorldMap.Structure.RESERVOIR or structure == WorldMap.Structure.CISTERN:
		return GameConfig.RESERVOIR_SIZES[basin_size_index % GameConfig.RESERVOIR_SIZES.size()]
	return Vector2i.ONE

func cycle_basin_size() -> void:
	basin_size_index = (basin_size_index + 1) % GameConfig.RESERVOIR_SIZES.size()

func adjust_reservoir_level(delta: int) -> void:
	reservoir_level_offset += delta
	# Clamp to reasonable bounds (can't go below 0 or absurdly high)
	reservoir_level_offset = clampi(reservoir_level_offset, 0, 20)

## Tiles a structure placed at `origin` would occupy, or empty if it does not
## fit on the map. The origin is the top-left of the footprint.
func footprint_tiles(origin: int, structure: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var size: Vector2i = footprint_of(structure)
	var c: Vector2i = WorldMap.coords_of(origin)
	for dy in range(size.y):
		for dx in range(size.x):
			var x: int = c.x + dx
			var y: int = c.y + dy
			if not WorldMap.in_bounds(x, y):
				return PackedInt32Array()
			out.append(WorldMap.index_of(x, y))
	return out

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
	# Multi-tile basins must clear their whole footprint.
	if footprint_of(structure) != Vector2i.ONE:
		var tiles: PackedInt32Array = footprint_tiles(idx, structure)
		if tiles.is_empty():
			return false
		for t in tiles:
			if WorldMap.is_mountain(t) or _pending.has(t):
				return false
			if WorldMap.structure_type[t] != WorldMap.Structure.NONE:
				return false
			if PlantSystem.plants.has(t):
				return false
		return true
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
	_pending[idx] = {
		"structure": structure, "ticks_left": ticks, "ticks_total": ticks,
		"footprint": footprint_of(structure),
	}
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
	# Demolishing any tile of a basin removes the whole basin; leaving part
	# of a pool standing would be meaningless.
	var owner: int = WorldMap.structure_owner[idx]
	if owner >= 0:
		var size: int = WorldMap.width * WorldMap.height
		for t in range(size):
			if WorldMap.structure_owner[t] == owner:
				WaterSystem.unregister_structure(t)
				WorldMap.reset_tile_structure(t)
				EventBus.emit_signal("tile_changed", t)
		EventBus.emit_signal("building_removed", idx)
		return true
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

		var size: Vector2i = footprint_of(structure)
		if entry.has("footprint"):
			size = entry["footprint"]
		if size != Vector2i.ONE:
			_complete_basin(idx, structure, size)
		else:
			WorldMap.structure_type[idx] = structure
			if structure == WorldMap.Structure.GATE:
				WorldMap.gate_open[idx] = 1
			WaterSystem.register_structure(idx)
		EventBus.emit_signal("building_completed", idx, structure_name(structure))
		EventBus.emit_signal("tile_changed", idx)

## Fills in a multi-tile basin: every tile becomes part of the pool, and the
## middle tile of each side is marked as an inlet so the rim behaves as a
## bank with defined openings rather than leaking all the way round.
func _complete_basin(origin: int, structure: int, size: Vector2i) -> void:
	var c: Vector2i = WorldMap.coords_of(origin)
	var mid_x: int = size.x / 2
	var mid_y: int = size.y / 2
	for dy in range(size.y):
		for dx in range(size.x):
			var t: int = WorldMap.index_of(c.x + dx, c.y + dy)
			WorldMap.structure_type[t] = structure
			WorldMap.structure_owner[t] = origin
			var on_edge: bool = dx == 0 or dy == 0 or dx == size.x - 1 or dy == size.y - 1
			var side_middle: bool = (dx == mid_x and (dy == 0 or dy == size.y - 1)) \
				or (dy == mid_y and (dx == 0 or dx == size.x - 1))
			WorldMap.is_inlet[t] = 1 if (on_edge and side_middle) else 0
			# Set the target water level for this reservoir/cistern tile
			WorldMap.reservoir_target_level[t] = WorldMap.height_level(origin) + reservoir_level_offset
			WaterSystem.register_structure(t)

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

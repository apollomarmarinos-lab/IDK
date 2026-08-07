extends Node2D
## Entry point: generates the world, then routes mouse input to the
## currently selected tool (inspect / plant / build / demolish). Kept as a
## thin coordinator -- all the actual rules live in the autoload systems.

@onready var world: Node2D = $World
@onready var hud: Control = $UI/HUD
@onready var build_menu: Control = $UI/BuildMenu
@onready var tile_inspector: Control = $UI/TileInspector

var current_tool: StringName = &"inspect"
var selected_plant_id: StringName = &""
var _dragging: bool = false
var _last_painted_tile: int = -1
var _selftest_active: bool = false
var _selftest_tap_idx: int = -1
var _selftest_frame: int = 0
var _selftest_gate_idx: int = -1
var _selftest_gate_placed: bool = false
var _selftest_gate_toggled: bool = false

func _ready() -> void:
	randomize()
	WorldMap.generate()
	build_menu.tool_selected.connect(_on_tool_selected)
	build_menu.plant_selected.connect(_on_plant_selected)
	if OS.get_cmdline_user_args().has("--sim-selftest"):
		_selftest_active = true
		_run_self_test()

func _process(_delta: float) -> void:
	if not _selftest_active:
		return
	_selftest_frame += 1
	if _selftest_frame % 60 == 0 and _selftest_tap_idx >= 0:
		print("SELFTEST t=%d tap_water=%.2f" % [_selftest_frame, WorldMap.surface_water[_selftest_tap_idx]])
	if not _selftest_gate_placed and _selftest_gate_idx >= 0 and WorldMap.structure_type[_selftest_gate_idx] == WorldMap.Structure.CANAL_OPEN:
		_selftest_gate_placed = true
		print("SELFTEST gate placeable=", BuildSystem.can_place(_selftest_gate_idx, WorldMap.Structure.GATE), " -> ", BuildSystem.place(_selftest_gate_idx, WorldMap.Structure.GATE))
	elif _selftest_gate_placed and not _selftest_gate_toggled and WorldMap.structure_type[_selftest_gate_idx] == WorldMap.Structure.GATE:
		_selftest_gate_toggled = true
		var before: bool = WorldMap.gate_open[_selftest_gate_idx] == 1
		BuildSystem.toggle_gate(_selftest_gate_idx)
		var after: bool = WorldMap.gate_open[_selftest_gate_idx] == 1
		print("SELFTEST gate toggled ", before, " -> ", after)
		print("SELFTEST demolish gate -> ", BuildSystem.remove(_selftest_gate_idx))

## Headless smoke test (run with `godot --headless -- --sim-selftest`):
## builds a mountain tap -> open canal -> planted tile chain so the water
## and plant systems get exercised without needing simulated mouse input.
func _run_self_test() -> void:
	var tap_idx: int = -1
	for i in range(WorldMap.width * WorldMap.height):
		if WorldMap.aquifer_potential[i] > 0.0:
			tap_idx = i
			break
	if tap_idx < 0:
		print("SELFTEST: no aquifer tile found")
		return
	print("SELFTEST: mountain tap at ", WorldMap.coords_of(tap_idx))
	_selftest_tap_idx = tap_idx
	assert(BuildSystem.place(tap_idx, WorldMap.Structure.CANAL_MOUNTAIN_TAP))

	var coords: Vector2i = WorldMap.coords_of(tap_idx)
	var tx: int = coords.x
	var ty: int = coords.y
	var step: int = 1 if tx < WorldMap.width / 2 else -1
	var chain: Array[int] = []
	for i in range(1, 40):
		var x: int = tx + step * i
		if not WorldMap.in_bounds(x, ty):
			break
		var idx: int = WorldMap.index_of(x, ty)
		if not BuildSystem.place(idx, WorldMap.Structure.CANAL_OPEN):
			print("SELFTEST: canal placement stopped at step ", i, " tile ", WorldMap.coords_of(idx))
			break
		chain.append(idx)
		if not WorldMap.is_mountain(idx):
			break # reached the open valley, that's a long enough test chain
	print("SELFTEST: canal chain length ", chain.size(), " -> ", chain)

	if chain.size() > 0:
		var last: int = chain[chain.size() - 1]
		var buf := PackedInt32Array([0, 0, 0, 0])
		var n: int = WorldMap.get_neighbors4(last, buf)
		for k in range(n):
			var nidx: int = buf[k]
			if PlantSystem.can_plant(nidx, &"date_palm"):
				if PlantSystem.plant(nidx, &"date_palm"):
					print("SELFTEST: planted date_palm at ", WorldMap.coords_of(nidx))
				break

	EventBus.plant_died.connect(func(idx, id): print("SELFTEST plant_died: ", id, " at ", idx))
	EventBus.plant_harvested.connect(func(idx, id, amount): print("SELFTEST harvested: ", amount, " ", id))
	EventBus.building_completed.connect(func(idx, id): print("SELFTEST building_completed: ", id, " at ", WorldMap.coords_of(idx)))

	# Exercise the remaining structure types away from the canal chain.
	var vx: int = WorldMap.width / 2
	var vy: int = WorldMap.height / 2
	var storage_idx: int = WorldMap.index_of(vx, vy)
	var shade_idx: int = WorldMap.index_of(vx + 2, vy)
	var well_idx: int = WorldMap.index_of(vx + 4, vy)
	var gate_target: int = chain[0] if chain.size() > 0 else -1
	print("SELFTEST storage placeable=", BuildSystem.can_place(storage_idx, WorldMap.Structure.STORAGE_TANK), " -> ", BuildSystem.place(storage_idx, WorldMap.Structure.STORAGE_TANK))
	print("SELFTEST shade placeable=", BuildSystem.can_place(shade_idx, WorldMap.Structure.SHADE_STRUCTURE), " -> ", BuildSystem.place(shade_idx, WorldMap.Structure.SHADE_STRUCTURE))
	print("SELFTEST well placeable=", BuildSystem.can_place(well_idx, WorldMap.Structure.WELL_OUTLET), " -> ", BuildSystem.place(well_idx, WorldMap.Structure.WELL_OUTLET))
	_selftest_gate_idx = gate_target

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover()
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_last_painted_tile = -1
				_apply_tool_at_mouse()
			else:
				_dragging = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			build_menu.select_tool_externally(&"inspect")

func _update_hover() -> void:
	var idx: int = _tile_at_mouse()
	world.set_hovered_tile(idx)
	if idx >= 0:
		tile_inspector.track_tile(idx)
	if _dragging:
		_apply_tool_at_mouse()

func _tile_at_mouse() -> int:
	var world_pos: Vector2 = get_global_mouse_position()
	var tile_size: float = float(GameConfig.TILE_PIXEL_SIZE)
	var tx: int = int(floor(world_pos.x / tile_size))
	var ty: int = int(floor(world_pos.y / tile_size))
	if not WorldMap.in_bounds(tx, ty):
		return -1
	return WorldMap.index_of(tx, ty)

func _apply_tool_at_mouse() -> void:
	var idx: int = _tile_at_mouse()
	if idx < 0 or idx == _last_painted_tile:
		return
	_last_painted_tile = idx
	match current_tool:
		&"inspect":
			world.set_selected_tile(idx)
			tile_inspector.track_tile(idx)
		&"plant":
			if selected_plant_id != &"":
				PlantSystem.plant(idx, selected_plant_id)
		&"demolish":
			if not BuildSystem.remove(idx):
				PlantSystem.remove_plant(idx)
		&"gate":
			if WorldMap.structure_type[idx] == WorldMap.Structure.GATE:
				BuildSystem.toggle_gate(idx)
			else:
				BuildSystem.place(idx, WorldMap.Structure.GATE)
		&"canal_open":
			BuildSystem.place(idx, WorldMap.Structure.CANAL_OPEN)
		&"canal_underground":
			BuildSystem.place(idx, WorldMap.Structure.CANAL_UNDERGROUND)
		&"canal_mountain_tap":
			BuildSystem.place(idx, WorldMap.Structure.CANAL_MOUNTAIN_TAP)
		&"storage_tank":
			BuildSystem.place(idx, WorldMap.Structure.STORAGE_TANK)
		&"shade_structure":
			BuildSystem.place(idx, WorldMap.Structure.SHADE_STRUCTURE)
		&"well_outlet":
			BuildSystem.place(idx, WorldMap.Structure.WELL_OUTLET)

func _on_tool_selected(tool_name: StringName) -> void:
	current_tool = tool_name

func _on_plant_selected(plant_id: StringName) -> void:
	selected_plant_id = plant_id

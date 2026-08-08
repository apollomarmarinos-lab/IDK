extends Node2D
## Entry point: generates the world, then routes mouse input to the
## currently selected tool. Kept as a thin coordinator -- all the actual
## rules live in the autoload systems.

@onready var world: Node2D = $World
@onready var hud: Control = $UI/HUD
@onready var build_menu: Control = $UI/BuildMenu
@onready var tile_inspector: Control = $UI/TileInspector
@onready var loading_screen: Control = $UI/LoadingScreen
@onready var camera: Camera2D = $Camera2D

var current_tool: StringName = &"inspect"
var selected_plant_id: StringName = &""
var _dragging: bool = false
var _painted_this_drag: Dictionary = {}
## Anchor tile of an L-shaped drag, and the path it currently previews.
var _drag_anchor: int = -1
var _drag_path: PackedInt32Array = PackedInt32Array()
## Tools laid out as a line rather than painted tile by tile.
## Canal tools use L-shaped drag placement: click-release to start, click again to commit.
const LINE_TOOLS := [&"canal_open", &"canal_covered", &"raise_ground", &"lower_ground"]
## How far the cursor may travel and still count as a click rather than a drag.
const CLICK_SLOP: float = 6.0
var _right_press_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	randomize()
	# Show loading screen before generation starts
	loading_screen.show_loading("Generating terrain...")
	# Yield to let the loading screen render before blocking with generation
	await get_tree().process_frame
	WorldMap.generate()
	loading_screen.hide_loading()
	build_menu.tool_selected.connect(_on_tool_selected)
	build_menu.plant_selected.connect(_on_plant_selected)
	build_menu.overlay_selected.connect(func(mode): world.set_overlay(mode))
	build_menu.flow_toggled.connect(func(v): world.set_show_flow(v))
	if OS.get_cmdline_user_args().has("--sim-selftest"):
		SelfTest.run(self)
	Screenshotter.install(self)

func _process(_delta: float) -> void:
	var idx: int = _tile_at_mouse()
	world.set_hovered_tile(idx)
	world.set_ghost_structure(build_menu.get_ghost_structure())
	build_menu.update_hint(idx)
	if idx >= 0:
		tile_inspector.track_tile(idx)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		var key_event: InputEventKey = event
		# Handle reservoir/cistern size cycling with R / scroll wheel
		if key_event.keycode == KEY_R:
			_on_cycle_basin_size()
		# Handle height level adjustment for reservoirs/cisterns with +/- keys
		elif key_event.keycode == KEY_EQUAL or key_event.keycode == KEY_PLUS:
			_on_adjust_reservoir_level(1)
		elif key_event.keycode == KEY_MINUS or key_event.keycode == KEY_UNDERSCORE:
			_on_adjust_reservoir_level(-1)
	elif event is InputEventMouseMotion:
		if _dragging:
			if _is_line_tool():
				_update_drag_path()
			else:
				_apply_tool_at_mouse()
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_painted_this_drag.clear()
				if _is_line_tool():
					# Line tools commit on release, so the whole run can be
					# previewed and re-aimed before anything is built.
					_dragging = true
					_drag_anchor = _tile_at_mouse()
					_update_drag_path()
				else:
					# With Inspect up the left button belongs to the camera,
					# so the click still selects a tile but the motion that
					# follows drags the map instead of painting over it.
					_dragging = not _left_drag_pans()
					_apply_tool_at_mouse()
			else:
				_dragging = false
				if _is_line_tool():
					_commit_drag_path()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			# Right-drag pans (the camera handles the motion), so only a right
			# button that has not travelled counts as "put the tool down".
			if mb.pressed:
				_right_press_pos = mb.position
			elif mb.position.distance_to(_right_press_pos) <= CLICK_SLOP:
				build_menu.select_tool_externally(&"inspect")
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			# Scroll up to increase reservoir target level
			if _current_build_tool_is_basin():
				_on_adjust_reservoir_level(1)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# Scroll down to decrease reservoir target level
			if _current_build_tool_is_basin():
				_on_adjust_reservoir_level(-1)

## Returns true if the currently selected tool places a basin (reservoir/cistern).
func _current_build_tool_is_basin() -> bool:
	return current_tool == &"reservoir" or current_tool == &"cistern"

## Cycles through available basin sizes (3x3, 3x5, 5x3).
func _on_cycle_basin_size() -> void:
	if _current_build_tool_is_basin():
		BuildSystem.cycle_basin_size()

## Adjusts the target water level for reservoirs/cisterns.
## This sets the desired fill level relative to the placement height.
func _on_adjust_reservoir_level(delta: int) -> void:
	if _current_build_tool_is_basin():
		BuildSystem.adjust_reservoir_level(delta)

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
	if idx < 0 or _painted_this_drag.has(idx):
		return
	_painted_this_drag[idx] = true
	_apply_tool_to(idx)

func _apply_tool_to(idx: int) -> void:
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
			# Clicking a finished gate toggles it rather than rebuilding it.
			if WorldMap.structure_type[idx] == WorldMap.Structure.GATE:
				BuildSystem.toggle_gate(idx)
			else:
				BuildSystem.place(idx, WorldMap.Structure.GATE)
		&"canal_open":
			BuildSystem.place(idx, WorldMap.Structure.CANAL_OPEN)
		&"canal_covered":
			BuildSystem.place(idx, WorldMap.Structure.CANAL_COVERED)
		&"reservoir":
			BuildSystem.place(idx, WorldMap.Structure.RESERVOIR)
		&"cistern":
			BuildSystem.place(idx, WorldMap.Structure.CISTERN)
		&"well":
			BuildSystem.place(idx, WorldMap.Structure.WELL)
		&"shade_structure":
			BuildSystem.place(idx, WorldMap.Structure.SHADE_STRUCTURE)
		&"raise_ground":
			BuildSystem.queue_terraform(idx, 1)
		&"lower_ground":
			BuildSystem.queue_terraform(idx, -1)

func _is_line_tool() -> bool:
	return LINE_TOOLS.has(current_tool)

## True when nothing is being built, in which case the left button is free to
## grab the map -- the drag most people reach for first.
func _left_drag_pans() -> bool:
	return current_tool == &"inspect"

## Builds the L-shaped route between the drag anchor and the cursor. The
## dominant axis is walked first, which is what makes a drag feel like it
## follows the direction you started in.
func _update_drag_path() -> void:
	_drag_path = PackedInt32Array()
	var target: int = _tile_at_mouse()
	if _drag_anchor < 0 or target < 0:
		world.set_drag_path(_drag_path)
		return
	var a: Vector2i = WorldMap.coords_of(_drag_anchor)
	var b: Vector2i = WorldMap.coords_of(target)
	var horizontal_first: bool = absi(b.x - a.x) >= absi(b.y - a.y)

	var x: int = a.x
	var y: int = a.y
	_drag_path.append(WorldMap.index_of(x, y))
	if horizontal_first:
		while x != b.x:
			x += signi(b.x - x)
			_drag_path.append(WorldMap.index_of(x, y))
		while y != b.y:
			y += signi(b.y - y)
			_drag_path.append(WorldMap.index_of(x, y))
	else:
		while y != b.y:
			y += signi(b.y - y)
			_drag_path.append(WorldMap.index_of(x, y))
		while x != b.x:
			x += signi(b.x - x)
			_drag_path.append(WorldMap.index_of(x, y))
	world.set_drag_path(_drag_path)

func _commit_drag_path() -> void:
	for idx in _drag_path:
		_apply_tool_to(idx)
	_drag_path = PackedInt32Array()
	_drag_anchor = -1
	world.set_drag_path(_drag_path)

func _on_tool_selected(tool_name: StringName) -> void:
	current_tool = tool_name
	camera.build_tool_active = not _left_drag_pans()
	# Dropping a half-drawn line when the tool changes avoids building the
	# previous tool's route with the new tool.
	_drag_path = PackedInt32Array()
	_drag_anchor = -1
	world.set_drag_path(_drag_path)

func _on_plant_selected(plant_id: StringName) -> void:
	selected_plant_id = plant_id

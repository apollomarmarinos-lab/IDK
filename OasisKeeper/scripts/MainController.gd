extends Node2D
## Entry point: generates the world, then routes mouse input to the
## currently selected tool. Kept as a thin coordinator -- all the actual
## rules live in the autoload systems.

@onready var world: Node2D = $World
@onready var hud: Control = $UI/HUD
@onready var build_menu: Control = $UI/BuildMenu
@onready var tile_inspector: Control = $UI/TileInspector

var current_tool: StringName = &"inspect"
var selected_plant_id: StringName = &""
var _dragging: bool = false
var _painted_this_drag: Dictionary = {}

func _ready() -> void:
	randomize()
	WorldMap.generate()
	build_menu.tool_selected.connect(_on_tool_selected)
	build_menu.plant_selected.connect(_on_plant_selected)
	build_menu.overlay_selected.connect(func(mode): world.set_overlay(mode))
	build_menu.flow_toggled.connect(func(v): world.set_show_flow(v))
	if OS.get_cmdline_user_args().has("--sim-selftest"):
		SelfTest.run(self)

func _process(_delta: float) -> void:
	var idx: int = _tile_at_mouse()
	world.set_hovered_tile(idx)
	world.set_ghost_structure(build_menu.get_ghost_structure())
	build_menu.update_hint(idx)
	if idx >= 0:
		tile_inspector.track_tile(idx)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if _dragging:
			_apply_tool_at_mouse()
	elif event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_painted_this_drag.clear()
				_apply_tool_at_mouse()
			else:
				_dragging = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			build_menu.select_tool_externally(&"inspect")

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

func _on_tool_selected(tool_name: StringName) -> void:
	current_tool = tool_name

func _on_plant_selected(plant_id: StringName) -> void:
	selected_plant_id = plant_id

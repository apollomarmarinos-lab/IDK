extends Control
## Left-hand tool palette: inspect, plant (with species submenu), the three
## canal categories, gates, storage, shade structures, wells, and demolish.

signal tool_selected(tool_name: StringName)
signal plant_selected(plant_id: StringName)

const TOOLS: Array[Dictionary] = [
	{"id": &"inspect", "label": "Inspect"},
	{"id": &"plant", "label": "Plant..."},
	{"id": &"canal_open", "label": "Dig Open Canal"},
	{"id": &"canal_mountain_tap", "label": "Tap Mountain Aquifer"},
	{"id": &"canal_underground", "label": "Dig Qanat (Underground)"},
	{"id": &"gate", "label": "Place / Toggle Gate"},
	{"id": &"storage_tank", "label": "Build Storage Tank"},
	{"id": &"shade_structure", "label": "Build Shade Structure"},
	{"id": &"well_outlet", "label": "Dig Well / Outlet"},
	{"id": &"demolish", "label": "Demolish"},
]

var _plant_panel: VBoxContainer
var _tool_buttons: Dictionary = {}
var _underground_toggle: CheckButton

func _ready() -> void:
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_top = 44.0
	offset_right = 220.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	panel.anchor_bottom = 1.0
	panel.anchor_right = 1.0
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var scroller := ScrollContainer.new()
	scroller.anchor_right = 1.0
	scroller.anchor_bottom = 1.0
	panel.add_child(scroller)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroller.add_child(col)

	var title := Label.new()
	title.text = "Build & Plant"
	col.add_child(title)

	for entry in TOOLS:
		var b := Button.new()
		b.text = entry["label"]
		b.toggle_mode = true
		b.pressed.connect(_on_tool_pressed.bind(entry["id"], b))
		col.add_child(b)
		_tool_buttons[entry["id"]] = b

	_underground_toggle = CheckButton.new()
	_underground_toggle.text = "Show underground qanats"
	_underground_toggle.toggled.connect(_on_underground_toggled)
	col.add_child(_underground_toggle)

	var sep := HSeparator.new()
	col.add_child(sep)

	var plant_title := Label.new()
	plant_title.text = "Species"
	col.add_child(plant_title)

	_plant_panel = VBoxContainer.new()
	col.add_child(_plant_panel)
	_populate_plants()
	_plant_panel.visible = false

	_tool_buttons[&"inspect"].button_pressed = true

func _populate_plants() -> void:
	for id in PlantSystem.get_plant_ids():
		var data: PlantData = PlantSystem.get_plant_data(id)
		var b := Button.new()
		b.text = data.display_name
		b.toggle_mode = true
		b.pressed.connect(_on_plant_pressed.bind(id, b))
		_plant_panel.add_child(b)

func _on_tool_pressed(tool_id: StringName, source: Button) -> void:
	for id in _tool_buttons.keys():
		_tool_buttons[id].button_pressed = (id == tool_id)
	_plant_panel.visible = (tool_id == &"plant")
	tool_selected.emit(tool_id)

func _on_plant_pressed(plant_id: StringName, source: Button) -> void:
	for child in _plant_panel.get_children():
		if child is Button:
			child.button_pressed = (child == source)
	plant_selected.emit(plant_id)

func _on_underground_toggled(pressed: bool) -> void:
	var world := get_tree().get_first_node_in_group("world_renderer")
	if world:
		world.set_underground_visible(pressed)

func select_tool_externally(tool_id: StringName) -> void:
	if _tool_buttons.has(tool_id):
		_on_tool_pressed(tool_id, _tool_buttons[tool_id])

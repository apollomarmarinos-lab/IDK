extends Control
## Left-hand build panel: categorised tools, map overlays, and a species
## browser that actually tells the player what each plant needs.
##
## Every tool carries a description explaining the trade-off it represents
## (open vs covered channel, palm shade vs built shade), because those
## trade-offs *are* the game. A live hint line at the bottom explains why
## the tile under the cursor can or cannot take the current tool.

signal tool_selected(tool_id: StringName)
signal plant_selected(plant_id: StringName)
signal overlay_selected(overlay_mode: int)
signal flow_toggled(enabled: bool)

const CATEGORIES: Array = [
	{
		"title": "General",
		"tools": [
			{"id": &"inspect", "label": "Inspect", "key": "1",
			 "desc": "Examine a tile: water, moisture, shade, temperature, geology."},
			{"id": &"demolish", "label": "Demolish", "key": "0",
			 "desc": "Remove a structure or uproot a plant. Cancels queued construction too."},
		],
	},
	{
		"title": "Water - channels",
		"tools": [
			{"id": &"canal_open", "label": "Open Canal", "key": "2",
			 "desc": "Quick to dig and it waters the soil either side of it. Fully exposed, so it loses water to the sun -- worst in summer, in wind, and out of shade.\n\nDug into mountain rock this automatically becomes a Mountain Tunnel."},
			{"id": &"canal_covered", "label": "Covered Canal", "key": "3",
			 "desc": "Twice the digging, but a roofed channel loses almost nothing to evaporation. It does NOT wet the ground beside it -- it only delivers water to where you open it up again.\n\nDug into mountain rock this automatically becomes a Mountain Tunnel."},
			{"id": &"gate", "label": "Gate", "key": "4",
			 "desc": "Fitted into an existing channel. Click a finished gate to open or close it, splitting the network so you can send water where you want it."},
		],
	},
	{
		"title": "Water - storage & sources",
		"tools": [
			{"id": &"reservoir", "label": "Reservoir", "key": "5",
			 "desc": "Large open pond. Holds a lot, but the surface evaporates. Shade it with palms to cut the losses."},
			{"id": &"cistern", "label": "Cistern", "key": "6",
			 "desc": "Covered storage. Holds even more than a reservoir and loses virtually nothing. The right place to bank water for summer."},
			{"id": &"well", "label": "Well", "key": "7",
			 "desc": "Sunk over a rare valley groundwater pocket. Modest, steady yield. Turn on the Groundwater overlay to find a spot."},
		],
	},
	{
		"title": "Structures",
		"tools": [
			{"id": &"shade_structure", "label": "Shade Structure", "key": "8",
			 "desc": "Palm-thatch canopy. Instant shade with no water upkeep, but weaker than a mature date palm -- and it yields nothing."},
			{"id": &"plant", "label": "Plant...", "key": "9",
			 "desc": "Choose a species below, then click ground to plant it."},
		],
	},
]

const OVERLAYS: Array = [
	{"label": "None", "mode": 0},
	{"label": "Aquifers (geology)", "mode": 1},
	{"label": "Groundwater", "mode": 2},
	{"label": "Soil moisture", "mode": 3},
	{"label": "Shade", "mode": 4},
	{"label": "Fertility", "mode": 5},
]

## Maps a tool id to the WorldMap.Structure it would place (-1 = not a build tool).
const TOOL_STRUCTURE := {
	&"canal_open": Tiles.Structure.CANAL_OPEN,
	&"canal_covered": Tiles.Structure.CANAL_COVERED,
	&"gate": Tiles.Structure.GATE,
	&"reservoir": Tiles.Structure.RESERVOIR,
	&"cistern": Tiles.Structure.CISTERN,
	&"well": Tiles.Structure.WELL,
	&"shade_structure": Tiles.Structure.SHADE_STRUCTURE,
}

var _tool_buttons: Dictionary = {}
var _plant_buttons: Dictionary = {}
var _key_to_tool: Dictionary = {}
var _plant_section: VBoxContainer
var _desc_label: RichTextLabel
var _hint_label: Label
var _current_tool: StringName = &"inspect"
var _selected_plant: StringName = &""

func _ready() -> void:
	set_anchors_preset(Control.PRESET_LEFT_WIDE)
	offset_top = 46.0
	offset_right = 278.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	panel.add_child(root)

	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroller)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 3)
	scroller.add_child(col)

	for category in CATEGORIES:
		col.add_child(_make_header(category["title"]))
		for tool in category["tools"]:
			var b := Button.new()
			b.text = "%s  [%s]" % [tool["label"], tool["key"]]
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.toggle_mode = true
			b.tooltip_text = tool["desc"]
			b.pressed.connect(_on_tool_pressed.bind(tool["id"]))
			col.add_child(b)
			_tool_buttons[tool["id"]] = b
			_key_to_tool[tool["key"]] = tool["id"]

	# --- species browser (only visible with the Plant tool active) --------
	_plant_section = VBoxContainer.new()
	_plant_section.add_theme_constant_override("separation", 2)
	col.add_child(_plant_section)
	_plant_section.add_child(_make_header("Species"))
	_populate_plants()
	_plant_section.visible = false

	# --- overlays ---------------------------------------------------------
	col.add_child(_make_header("Map overlay"))
	var overlay_group := ButtonGroup.new()
	for entry in OVERLAYS:
		var ob := Button.new()
		ob.text = entry["label"]
		ob.alignment = HORIZONTAL_ALIGNMENT_LEFT
		ob.toggle_mode = true
		ob.button_group = overlay_group
		ob.pressed.connect(func(): overlay_selected.emit(entry["mode"]))
		col.add_child(ob)
		if entry["mode"] == 0:
			ob.button_pressed = true

	var flow_toggle := CheckButton.new()
	flow_toggle.text = "Show water flow"
	flow_toggle.button_pressed = true
	flow_toggle.toggled.connect(func(v): flow_toggled.emit(v))
	col.add_child(flow_toggle)

	# --- description + live placement hint --------------------------------
	root.add_child(HSeparator.new())
	_desc_label = RichTextLabel.new()
	_desc_label.fit_content = true
	_desc_label.custom_minimum_size = Vector2(0, 132)
	_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_desc_label)

	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_hint_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	root.add_child(_hint_label)

	_select_tool(&"inspect")

func _make_header(text: String) -> Label:
	var l := Label.new()
	l.text = text.to_upper()
	l.add_theme_color_override("font_color", Color(0.95, 0.82, 0.5))
	return l

func _populate_plants() -> void:
	var ids: Array = PlantSystem.get_plant_ids()
	ids.sort_custom(func(a, b):
		var pa: PlantData = PlantSystem.get_plant_data(a)
		var pb: PlantData = PlantSystem.get_plant_data(b)
		if pa.category == pb.category:
			return pa.display_name < pb.display_name
		return pa.category < pb.category)
	var last_category: String = ""
	for id in ids:
		var data: PlantData = PlantSystem.get_plant_data(id)
		if data.category != last_category:
			last_category = data.category
			var sub := Label.new()
			sub.text = "  " + data.category
			sub.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
			_plant_section.add_child(sub)
		var b := Button.new()
		b.text = data.display_name
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.tooltip_text = _plant_description(data)
		b.pressed.connect(_on_plant_pressed.bind(id))
		_plant_section.add_child(b)
		_plant_buttons[id] = b

func _plant_description(data: PlantData) -> String:
	var lines: Array[String] = []
	lines.append(data.display_name + " (" + data.category + ")")
	lines.append("Water: %.1f /day    Heat limit: %.0f C" % [data.water_need_per_day, data.heat_tolerance_c])
	lines.append("Drought tolerance: %.0f days" % data.drought_tolerance_days)
	if data.deep_roots:
		lines.append("Deep roots: reaches water in neighbouring soil.")
	if data.shade_radius > 0.0:
		lines.append("Casts shade: radius %.1f, strength %.0f%%" % [data.shade_radius, data.shade_strength * 100.0])
	else:
		lines.append("Casts no useful shade.")
	var total_days: int = 0
	for d in data.growth_stage_days:
		total_days += d
	lines.append("Matures in ~%d days on fertile ground." % total_days)
	var seasons: Array[String] = []
	for s in data.harvest_seasons:
		seasons.append(GameClock.SEASON_NAMES[s])
	lines.append("Harvest: " + (", ".join(seasons) if not seasons.is_empty() else "none"))
	return "\n".join(lines)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k: String = OS.get_keycode_string(event.keycode)
		if _key_to_tool.has(k):
			_select_tool(_key_to_tool[k])
			get_viewport().set_input_as_handled()

func _on_tool_pressed(tool_id: StringName) -> void:
	_select_tool(tool_id)

func _select_tool(tool_id: StringName) -> void:
	_current_tool = tool_id
	for id in _tool_buttons.keys():
		_tool_buttons[id].button_pressed = (id == tool_id)
	_plant_section.visible = (tool_id == &"plant")
	_desc_label.text = _describe_tool(tool_id)
	tool_selected.emit(tool_id)

func _describe_tool(tool_id: StringName) -> String:
	if tool_id == &"plant" and _selected_plant != &"":
		return _plant_description(PlantSystem.get_plant_data(_selected_plant))
	for category in CATEGORIES:
		for tool in category["tools"]:
			if tool["id"] == tool_id:
				return "[b]%s[/b]\n%s" % [tool["label"], tool["desc"]]
	return ""

func _on_plant_pressed(plant_id: StringName) -> void:
	_selected_plant = plant_id
	for id in _plant_buttons.keys():
		_plant_buttons[id].button_pressed = (id == plant_id)
	_desc_label.text = _plant_description(PlantSystem.get_plant_data(plant_id))
	plant_selected.emit(plant_id)

## Called every frame by MainController with the tile under the cursor, so
## the panel can explain a refused placement instead of silently ignoring it.
func update_hint(tile_index: int) -> void:
	if tile_index < 0 or not TOOL_STRUCTURE.has(_current_tool):
		_hint_label.text = ""
		return
	var structure: int = TOOL_STRUCTURE[_current_tool]
	if BuildSystem.can_place(tile_index, structure):
		var resolved: int = BuildSystem.resolve_structure(tile_index, structure)
		if resolved != structure:
			_hint_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
			_hint_label.text = "Mountain rock: will be dug as a tunnel."
		else:
			_hint_label.text = ""
	else:
		_hint_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
		_hint_label.text = BuildSystem.placement_hint(tile_index, structure)

func get_ghost_structure() -> int:
	return TOOL_STRUCTURE.get(_current_tool, -1)

func select_tool_externally(tool_id: StringName) -> void:
	if _tool_buttons.has(tool_id):
		_select_tool(tool_id)

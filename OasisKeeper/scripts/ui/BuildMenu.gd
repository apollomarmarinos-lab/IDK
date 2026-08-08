extends Control
## The build UI, in two parts:
##
##   - A category bar across the BOTTOM of the screen. Always visible.
##   - A detail panel down the LEFT side that opens when you pick a
##     category, listing that category's items with full descriptions.
##
## Clicking the active category again closes the panel, so the map is never
## permanently obscured. Direct tools (Inspect, Demolish) just select
## themselves and close the panel.

signal tool_selected(tool_id: StringName)
signal plant_selected(plant_id: StringName)
signal overlay_selected(overlay_mode: int)
signal flow_toggled(enabled: bool)

## kind: "tool" selects immediately; "category" opens the left panel;
## "plants" and "overlays" are specially-populated categories.
const CATEGORIES: Array = [
	{
		"id": &"inspect", "label": "Inspect", "key": "1", "kind": "tool",
		"desc": "Examine a tile: water, moisture, shade, temperature, geology.",
	},
	{
		"id": &"channels", "label": "Channels", "key": "2", "kind": "category",
		"blurb": "Move water from the mountains to your fields. It only ever runs downhill.",
		"tools": [
			{"id": &"canal_open", "label": "Open Canal", "key": "Q",
			 "desc": "Quick to dig, and it waters the soil either side of it -- this is how you actually irrigate.\n\nFully exposed, so it loses water to the sun: worst in summer, in wind, and out of shade.\n\nIt follows the ground, so it only carries water along tiles that step down or stay level. Grade the route with Dig Out first.\n\nDug into mountain rock it automatically becomes a Mountain Tunnel."},
			{"id": &"canal_covered", "label": "Covered Canal", "key": "W",
			 "desc": "Twice the digging, but a roofed channel loses almost nothing to evaporation. Use it for the long haul from the mountains.\n\nIt does NOT wet the ground beside it -- it only delivers water to wherever you open it up again.\n\nUnlike an open trench it is bored to a gradient rather than following the surface, so it carries water out under the foothills without needing the ground graded first. That is what gets water off the mountain.\n\nDug into mountain rock it automatically becomes a Mountain Tunnel."},
			{"id": &"gate", "label": "Gate", "key": "E",
			 "desc": "Fitted into an existing channel. Click a finished gate to open or close it, splitting the network so you can send water where you want it."},
		],
	},
	{
		"id": &"storage", "label": "Storage & Wells", "key": "3", "kind": "category",
		"blurb": "Bank water for the dry season, and tap valley groundwater.",
		"tools": [
			{"id": &"reservoir", "label": "Reservoir", "key": "Q",
			 "desc": "A multi-tile open basin -- 3x3 by default. Press R to cycle 3x3 / 3x5 / 5x3.\n\nWater moves freely inside the footprint, so the whole thing behaves as one pool, but the rim is a bank: it only fills and drains through the INLET in the middle of each side. Run a canal into an inlet.\n\nOpen to the sky, so it evaporates. Shade it with palms to cut the losses."},
			{"id": &"cistern", "label": "Cistern", "key": "W",
			 "desc": "The same multi-tile basin, roofed. Press R to cycle the footprint.\n\nHolds more than a reservoir and loses virtually nothing to evaporation. The right place to bank water for summer."},
			{"id": &"well", "label": "Well", "key": "E",
			 "desc": "Sunk over a rare valley groundwater pocket. Modest but steady yield. Switch on the Groundwater overlay to find a spot -- it will refuse to build anywhere else."},
		],
	},
	{
		"id": &"structures", "label": "Structures", "key": "4", "kind": "category",
		"blurb": "Shade without planting a tree.",
		"tools": [
			{"id": &"shade_structure", "label": "Shade Structure", "key": "Q",
			 "desc": "Palm-thatch canopy. Instant shade with no water upkeep, but weaker than a mature date palm -- and it yields nothing. That is the trade-off for not growing a palm."},
		],
	},
	{
		"id": &"terraform", "label": "Terraform", "key": "5", "kind": "category",
		"blurb": "Reshape the valley floor a level at a time. Water never climbs one.",
		"tools": [
			{"id": &"raise_ground", "label": "Raise Ground", "key": "Q",
			 "desc": "Builds the tile up by one height level.\n\nUse it to dam a hollow, or to force a channel to run somewhere else -- water will not climb a rise, however full the channel below it gets."},
			{"id": &"lower_ground", "label": "Dig Out", "key": "W",
			 "desc": "Cuts the tile down by one height level.\n\nThis is how a run is graded. Water only ever moves to a tile on its own level or lower, so a canal stalls at the first step up -- the orange chevrons on a build preview mark exactly those tiles. Drag Dig Out along the same line to cut them down.\n\nWorks on tiles that already carry a canal, so a finished run can be re-graded without tearing it up."},
		],
	},
	{
		"id": &"plants", "label": "Plants", "key": "6", "kind": "plants",
		"blurb": "Pick a species, then click ground to plant it.",
	},
	{
		"id": &"overlays", "label": "Overlays", "key": "7", "kind": "overlays",
		"blurb": "Reveal what the map hides. Aquifers are invisible without this.",
	},
	{
		"id": &"demolish", "label": "Demolish", "key": "0", "kind": "tool",
		"desc": "Remove a structure or uproot a plant. Cancels queued construction too.",
	},
]

const OVERLAYS: Array = [
	{"label": "None", "mode": 0, "desc": "Plain map."},
	{"label": "Aquifers (geology)", "mode": 1, "desc": "Water bodies inside the mountain rock. Cyan = full, red = drained. You cannot find aquifers any other way."},
	{"label": "Groundwater", "mode": 2, "desc": "Rare shallow pockets on the valley floor. The only places a Well will build."},
	{"label": "Soil moisture", "mode": 3, "desc": "How wet the ground is. This is what your plants drink."},
	{"label": "Shade", "mode": 4, "desc": "Canopy and structure cover. Shade slows evaporation dramatically."},
	{"label": "Fertility", "mode": 5, "desc": "Green = alluvium along the wadis, where plants grow fastest."},
]

## Maps a tool id to the structure it places (absent = not a build tool).
const TOOL_STRUCTURE := {
	&"canal_open": Tiles.Structure.CANAL_OPEN,
	&"canal_covered": Tiles.Structure.CANAL_COVERED,
	&"gate": Tiles.Structure.GATE,
	&"reservoir": Tiles.Structure.RESERVOIR,
	&"cistern": Tiles.Structure.CISTERN,
	&"well": Tiles.Structure.WELL,
	&"shade_structure": Tiles.Structure.SHADE_STRUCTURE,
}

## Terraform tools, mapped to the number of levels they move the ground.
const TERRAFORM_DELTA := {
	&"raise_ground": 1,
	&"lower_ground": -1,
}

const ACCENT := Color(0.97, 0.84, 0.52)

var _bottom_bar: PanelContainer
var _left_panel: PanelContainer
var _panel_title: Label
var _panel_items: VBoxContainer
var _desc_label: RichTextLabel
var _hint_label: Label
var _current_label: Label

var _category_buttons: Dictionary = {}
var _item_buttons: Dictionary = {}
var _open_category: StringName = &""
var _current_tool: StringName = &"inspect"
var _selected_plant: StringName = &""
var _overlay_mode: int = 0

func _ready() -> void:
	UILayout.fill(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_left_panel()
	_build_bottom_bar()
	_select_tool(&"inspect")
	_left_panel.visible = false

# ---------------------------------------------------------------------------
# Bottom category bar
# ---------------------------------------------------------------------------

func _build_bottom_bar() -> void:
	_bottom_bar = PanelContainer.new()
	UILayout.bottom_bar(_bottom_bar, GameConfig.UI_BOTTOM_BAR_HEIGHT)
	_bottom_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	UILayout.style_panel(_bottom_bar, 8.0)
	add_child(_bottom_bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_bottom_bar.add_child(row)

	for category in CATEGORIES:
		var b := Button.new()
		b.text = "%s\n[%s]" % [category["label"], category["key"]]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(126, 0)
		b.tooltip_text = category.get("blurb", category.get("desc", ""))
		b.pressed.connect(_on_category_pressed.bind(category["id"]))
		row.add_child(b)
		_category_buttons[category["id"]] = b

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_current_label = Label.new()
	_current_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_current_label.add_theme_color_override("font_color", ACCENT)
	row.add_child(_current_label)

func _on_category_pressed(id: StringName) -> void:
	var category: Dictionary = _find_category(id)
	if category.is_empty():
		return
	if category["kind"] == "tool":
		_open_category = &""
		_left_panel.visible = false
		_select_tool(id)
		_sync_category_buttons()
		return
	# Clicking the open category again closes the panel.
	if _open_category == id:
		_open_category = &""
		_left_panel.visible = false
	else:
		_open_category = id
		_left_panel.visible = true
		_populate_panel(category)
	_sync_category_buttons()

func _sync_category_buttons() -> void:
	for id in _category_buttons.keys():
		var category: Dictionary = _find_category(id)
		var active: bool = (id == _open_category)
		if category.get("kind", "") == "tool":
			active = (_current_tool == id)
		_category_buttons[id].button_pressed = active

func _find_category(id: StringName) -> Dictionary:
	for category in CATEGORIES:
		if category["id"] == id:
			return category
	return {}

# ---------------------------------------------------------------------------
# Left detail panel
# ---------------------------------------------------------------------------

func _build_left_panel() -> void:
	_left_panel = PanelContainer.new()
	UILayout.left_panel(_left_panel, GameConfig.UI_SIDE_PANEL_WIDTH,
		GameConfig.UI_TOP_BAR_HEIGHT, GameConfig.UI_BOTTOM_BAR_HEIGHT)
	_left_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	UILayout.style_panel(_left_panel)
	add_child(_left_panel)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	_left_panel.add_child(root)

	_panel_title = Label.new()
	_panel_title.add_theme_color_override("font_color", ACCENT)
	root.add_child(_panel_title)
	root.add_child(HSeparator.new())

	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroller)

	_panel_items = VBoxContainer.new()
	_panel_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_items.add_theme_constant_override("separation", 3)
	scroller.add_child(_panel_items)

	root.add_child(HSeparator.new())

	_desc_label = RichTextLabel.new()
	_desc_label.bbcode_enabled = true
	_desc_label.fit_content = true
	_desc_label.scroll_active = false
	_desc_label.custom_minimum_size = Vector2(0, 150)
	root.add_child(_desc_label)

	_hint_label = Label.new()
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	root.add_child(_hint_label)

func _clear_panel_items() -> void:
	_item_buttons.clear()
	for child in _panel_items.get_children():
		child.queue_free()
		_panel_items.remove_child(child)

func _populate_panel(category: Dictionary) -> void:
	_clear_panel_items()
	_panel_title.text = String(category["label"]).to_upper()
	_desc_label.text = category.get("blurb", "")
	match category["kind"]:
		"plants":
			_populate_plants()
		"overlays":
			_populate_overlays()
		_:
			for tool in category["tools"]:
				var b := _make_item_button("%s  [%s]" % [tool["label"], tool["key"]], tool["desc"])
				b.pressed.connect(_on_tool_button.bind(tool["id"]))
				_panel_items.add_child(b)
				_item_buttons[tool["id"]] = b
			_sync_item_buttons()

func _make_item_button(text: String, tooltip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.toggle_mode = true
	b.tooltip_text = tooltip
	return b

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
			sub.text = data.category.to_upper()
			sub.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
			_panel_items.add_child(sub)
		var b := _make_item_button(data.display_name, _plant_description(data))
		b.pressed.connect(_on_plant_button.bind(id))
		_panel_items.add_child(b)
		_item_buttons[id] = b
	if _selected_plant != &"":
		_desc_label.text = _plant_description(PlantSystem.get_plant_data(_selected_plant))
	_sync_item_buttons()

func _populate_overlays() -> void:
	for entry in OVERLAYS:
		var b := _make_item_button(entry["label"], entry["desc"])
		b.button_pressed = (_overlay_mode == entry["mode"])
		b.pressed.connect(_on_overlay_button.bind(entry["mode"], entry["desc"]))
		_panel_items.add_child(b)
		_item_buttons[StringName("overlay_%d" % entry["mode"])] = b

	var flow_toggle := CheckButton.new()
	flow_toggle.text = "Show water flow arrows"
	flow_toggle.button_pressed = true
	flow_toggle.toggled.connect(func(v): flow_toggled.emit(v))
	_panel_items.add_child(flow_toggle)

func _sync_item_buttons() -> void:
	for id in _item_buttons.keys():
		var b: Button = _item_buttons[id]
		if _open_category == &"plants":
			b.button_pressed = (id == _selected_plant)
		else:
			b.button_pressed = (id == _current_tool)

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _on_tool_button(tool_id: StringName) -> void:
	_select_tool(tool_id)
	_sync_item_buttons()

func _on_plant_button(plant_id: StringName) -> void:
	_selected_plant = plant_id
	_select_tool(&"plant")
	_desc_label.text = _plant_description(PlantSystem.get_plant_data(plant_id))
	_sync_item_buttons()
	plant_selected.emit(plant_id)

func _on_overlay_button(mode: int, desc: String) -> void:
	_overlay_mode = mode
	for id in _item_buttons.keys():
		var b: Button = _item_buttons[id]
		if String(id).begins_with("overlay_"):
			b.button_pressed = (id == StringName("overlay_%d" % mode))
	_desc_label.text = desc
	overlay_selected.emit(mode)

func _select_tool(tool_id: StringName) -> void:
	_current_tool = tool_id
	var label: String = _tool_label(tool_id)
	_current_label.text = "Active: %s" % label
	var desc: String = _tool_desc(tool_id)
	if desc != "":
		_desc_label.text = "[b]%s[/b]\n%s" % [label, desc]
	_sync_category_buttons()
	tool_selected.emit(tool_id)

func _tool_label(tool_id: StringName) -> String:
	if tool_id == &"plant":
		if _selected_plant != &"":
			return "Plant " + PlantSystem.get_plant_data(_selected_plant).display_name
		return "Plant"
	for category in CATEGORIES:
		if category["id"] == tool_id:
			return category["label"]
		for tool in category.get("tools", []):
			if tool["id"] == tool_id:
				return tool["label"]
	return String(tool_id).capitalize()

func _tool_desc(tool_id: StringName) -> String:
	for category in CATEGORIES:
		if category["id"] == tool_id:
			return category.get("desc", "")
		for tool in category.get("tools", []):
			if tool["id"] == tool_id:
				return tool["desc"]
	return ""

func _plant_description(data: PlantData) -> String:
	var lines: Array[String] = []
	lines.append("[b]%s[/b] (%s)" % [data.display_name, data.category])
	lines.append("Water: %.1f/day    Heat limit: %.0f C" % [data.water_need_per_day, data.heat_tolerance_c])
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

# ---------------------------------------------------------------------------
# Input + external API
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: String = OS.get_keycode_string(event.keycode)
	for category in CATEGORIES:
		if category["key"] == k:
			_on_category_pressed(category["id"])
			get_viewport().set_input_as_handled()
			return
	# R cycles the footprint of multi-tile basins.
	if k == "R" and (_current_tool == &"reservoir" or _current_tool == &"cistern"):
		BuildSystem.cycle_basin_size()
		_desc_label.text = "[b]%s[/b]\nFootprint: %dx%d  (R to cycle)\n%s" % [
			_tool_label(_current_tool),
			BuildSystem.footprint_of(TOOL_STRUCTURE[_current_tool]).x,
			BuildSystem.footprint_of(TOOL_STRUCTURE[_current_tool]).y,
			_tool_desc(_current_tool)]
		get_viewport().set_input_as_handled()
		return
	# Item hotkeys apply only while their category is open.
	if _open_category != &"":
		var category: Dictionary = _find_category(_open_category)
		for tool in category.get("tools", []):
			if tool["key"] == k:
				_select_tool(tool["id"])
				_sync_item_buttons()
				get_viewport().set_input_as_handled()
				return

## Called every frame by MainController with the tile under the cursor, so
## the panel can explain a refused placement instead of the click silently
## doing nothing.
func update_hint(tile_index: int) -> void:
	if not _left_panel.visible:
		return
	if tile_index >= 0 and TERRAFORM_DELTA.has(_current_tool):
		var delta: int = TERRAFORM_DELTA[_current_tool]
		if WorldMap.can_terraform(tile_index, delta):
			_hint_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
			_hint_label.text = "Level %d -> %d" % [WorldMap.height_level(tile_index), WorldMap.height_level(tile_index) + delta]
		else:
			_hint_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
			_hint_label.text = WorldMap.terraform_hint(tile_index, delta)
		return
	if tile_index < 0 or not TOOL_STRUCTURE.has(_current_tool):
		_hint_label.text = ""
		return
	var structure: int = TOOL_STRUCTURE[_current_tool]
	if BuildSystem.can_place(tile_index, structure):
		if BuildSystem.resolve_structure(tile_index, structure) != structure:
			_hint_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
			_hint_label.text = "Mountain rock: will be dug as a tunnel."
		else:
			_hint_label.text = ""
	else:
		_hint_label.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
		_hint_label.text = BuildSystem.placement_hint(tile_index, structure)

func get_ghost_structure() -> int:
	return TOOL_STRUCTURE.get(_current_tool, -1)

## Opens a category panel programmatically (used by the screenshot tool and
## available for tutorials/scripted intros).
func open_category(id: StringName) -> void:
	if _find_category(id).is_empty():
		return
	if _open_category != id:
		_on_category_pressed(id)

func select_tool_externally(tool_id: StringName) -> void:
	_open_category = &""
	_left_panel.visible = false
	_select_tool(tool_id)

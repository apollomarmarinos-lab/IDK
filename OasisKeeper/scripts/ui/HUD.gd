extends Control
## Top status bar: date/season/time, weather readout, speed controls and a
## compact harvest inventory. Built entirely in code so the layout has no
## hand-authored .tscn to go stale.

var _date_label: Label
var _weather_label: Label
var _water_label: Label
var _perf_label: Label
var _inventory_label: Label
var _speed_buttons: Array[Button] = []

func _ready() -> void:
	UILayout.top_bar(self, GameConfig.UI_TOP_BAR_HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = true

	var bar := PanelContainer.new()
	UILayout.fill(bar)
	bar.mouse_filter = Control.MOUSE_FILTER_STOP
	UILayout.style_panel(bar, 8.0)
	add_child(bar)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	bar.add_child(row)

	_date_label = Label.new()
	_date_label.custom_minimum_size = Vector2(260, 0)
	row.add_child(_date_label)

	_weather_label = Label.new()
	_weather_label.custom_minimum_size = Vector2(280, 0)
	row.add_child(_weather_label)

	_perf_label = Label.new()
	_perf_label.custom_minimum_size = Vector2(190, 0)
	_perf_label.add_theme_color_override("font_color", Color(0.65, 0.85, 0.65))
	row.add_child(_perf_label)

	_water_label = Label.new()
	_water_label.custom_minimum_size = Vector2(210, 0)
	row.add_child(_water_label)

	_inventory_label = Label.new()
	_inventory_label.custom_minimum_size = Vector2(360, 0)
	row.add_child(_inventory_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	for entry in [["II", 0.0], ["1x", 1.0], ["2x", 2.0], ["4x", 4.0]]:
		var b := Button.new()
		b.text = entry[0]
		b.toggle_mode = true
		b.pressed.connect(_on_speed_pressed.bind(entry[1], b))
		row.add_child(b)
		_speed_buttons.append(b)
	_speed_buttons[1].button_pressed = true

	EventBus.inventory_changed.connect(_on_inventory_changed)
	_update_inventory_label()

func _process(_delta: float) -> void:
	_date_label.text = "%s, Day %d, Year %d  -  %02d:%02d %s" % [
		GameClock.get_season_name(), GameClock.day, GameClock.year,
		GameClock.hour, int(GameClock.minute) % 60,
		"(Night)" if GameClock.is_night else "(Day)"
	]
	var deg: float = 0.0
	if WorldMap.width > 0:
		var cx: int = WorldMap.width / 2
		var cy: int = WorldMap.height / 2
		deg = ClimateSystem.temperature_at(WorldMap.index_of(cx, cy))
	_weather_label.text = "%.0f C   Wind %.0f%% %s" % [
		deg, ClimateSystem.wind_speed * 100.0, _wind_arrow(ClimateSystem.wind_direction)
	]
	_water_label.text = "Water stored: %.0f" % WaterSystem.total_stored_water()
	# Frame rate plus the cost of the last simulation tick, which is the
	# number that actually moves when the world gets busy.
	_perf_label.text = "%d FPS   tick %.1f ms" % [
		Engine.get_frames_per_second(), GameClock.last_tick_msec]

func _wind_arrow(dir: Vector2) -> String:
	var angle: float = dir.angle()
	var arrows := ["->", "v", "<-", "^"]
	var idx: int = int(round((angle + PI) / (PI * 0.5))) % 4
	return arrows[idx]

func _on_speed_pressed(speed: float, source: Button) -> void:
	for b in _speed_buttons:
		b.button_pressed = (b == source)
	GameClock.set_time_scale(speed)

func _on_inventory_changed(_item: StringName, _amount: float) -> void:
	_update_inventory_label()

func _update_inventory_label() -> void:
	var parts: Array[String] = []
	for item in PlantSystem.inventory.keys():
		parts.append("%s: %.0f" % [String(item).capitalize(), PlantSystem.inventory[item]])
	_inventory_label.text = "Harvest: " + (", ".join(parts) if not parts.is_empty() else "none yet")

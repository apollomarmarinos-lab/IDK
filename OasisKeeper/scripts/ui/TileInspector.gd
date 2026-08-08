extends Control
## Bottom-right readout for the tile under the cursor. This is the main
## window into "why is my oasis dying" -- water levels, flow, air moisture,
## shade and plant health are otherwise invisible numbers.

var _label: RichTextLabel
var _tracked_tile: int = -1

func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	offset_left = -330.0
	offset_top = -300.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = true

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	panel.add_child(_label)
	_label.text = "Hover a tile to inspect it."

func track_tile(idx: int) -> void:
	_tracked_tile = idx

func _process(_delta: float) -> void:
	if _tracked_tile < 0 or WorldMap.width == 0:
		return
	var idx: int = _tracked_tile
	var c: Vector2i = WorldMap.coords_of(idx)
	var lines: Array[String] = []
	lines.append("[b]Tile (%d, %d)[/b]" % [c.x, c.y])
	lines.append("%s   elev %.1f" % [WorldMap.terrain_name(idx), WorldMap.elevation[idx]])
	if WorldMap.fertility[idx] > 0.0:
		lines.append("Fertility: %.0f%%" % (WorldMap.fertility[idx] * 100.0))
	lines.append("%.1f C   Shade %.0f%%   Humidity %.0f%%" % [
		WorldMap.temperature[idx], WorldMap.shade[idx] * 100.0, WorldMap.air_moisture[idx] * 100.0])

	if WorldMap.has_aquifer(idx):
		var body: int = WorldMap.aquifer_id[idx]
		lines.append("[color=#66ddff]Aquifer #%d: %.0f / %.0f (%.0f%%)[/color]" % [
			body, WorldMap.aquifer_volume[body], WorldMap.aquifer_max_volume[body],
			WorldMap.aquifer_fill_fraction(idx) * 100.0])
	if WorldMap.rare_groundwater[idx] > 0.0:
		lines.append("[color=#66ddff]Groundwater pocket: %.0f%%[/color]" % (WorldMap.rare_groundwater[idx] * 100.0))

	if BuildSystem.is_pending(idx):
		lines.append("[color=#ffd24d]Under construction: %.0f%%[/color]" % (BuildSystem.get_pending_progress(idx) * 100.0))
	elif WorldMap.structure_type[idx] != WorldMap.Structure.NONE:
		lines.append("[b]%s[/b]" % BuildSystem.structure_name(WorldMap.structure_type[idx]))
		var cap: float = WorldMap.water_capacity(idx)
		lines.append("Water: %.2f / %.0f  (%.0f%% full)" % [WorldMap.water[idx], cap, WorldMap.water[idx] / cap * 100.0])
		var flow := Vector2(WorldMap.flow_x[idx], WorldMap.flow_y[idx])
		if flow.length() > 0.004:
			lines.append("Flowing %s" % _direction_name(flow))
		else:
			lines.append("[color=#999999]Not flowing (level)[/color]")
		lines.append("Evaporation: %s" % ("exposed to sun" if WorldMap.is_open_to_sky(idx) else "[color=#7fdc7f]covered, negligible[/color]"))
		if WorldMap.structure_type[idx] == WorldMap.Structure.GATE:
			lines.append("Gate is %s" % ("[color=#66dd66]OPEN[/color]" if WorldMap.gate_open[idx] == 1 else "[color=#dd6666]CLOSED[/color]"))
	else:
		lines.append("Soil moisture: %.1f / %.0f" % [WorldMap.soil_moisture[idx], GameConfig.SOIL_WATER_CAPACITY])

	if PlantSystem.plants.has(idx):
		var p: PlantInstance = PlantSystem.plants[idx]
		lines.append("[b]%s[/b] - stage %d/%d (%.0f%% grown)" % [
			p.data.display_name, p.stage_index + 1, p.data.total_stages(), p.get_growth_fraction() * 100.0])
		var health_col: String = "#66dd66" if p.health > 0.6 else ("#ddcc55" if p.health > 0.3 else "#dd5555")
		lines.append("Health: [color=%s]%.0f%%[/color]   Water stress: %.1f d" % [health_col, p.health * 100.0, p.water_stress_days])
	_label.text = "\n".join(lines)

func _direction_name(v: Vector2) -> String:
	if absf(v.x) > absf(v.y):
		return "east" if v.x > 0.0 else "west"
	return "south" if v.y > 0.0 else "north"

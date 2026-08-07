extends Control
## Bottom-right readout panel showing the full simulation state of whichever
## tile is currently hovered (falling back to the last clicked tile). This
## is the main window into "why is my oasis dying" -- water levels, air
## moisture, shade and plant health are otherwise invisible numbers.

var _label: Label
var _tracked_tile: int = -1

func _ready() -> void:
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = -320.0
	offset_top = -260.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var panel := PanelContainer.new()
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	add_child(panel)

	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	panel.add_child(_label)
	_label.text = "Hover a tile to inspect it."

func track_tile(idx: int) -> void:
	_tracked_tile = idx

func _process(_delta: float) -> void:
	if _tracked_tile < 0 or WorldMap.width == 0:
		return
	var idx: int = _tracked_tile
	var x: int = idx % WorldMap.width
	var y: int = idx / WorldMap.width
	var lines: Array[String] = []
	lines.append("Tile (%d, %d)" % [x, y])
	lines.append("Terrain: %s   Elevation: %.1f" % ["Rock" if WorldMap.is_mountain(idx) else "Sand", WorldMap.elevation[idx]])
	lines.append("Temperature: %.1f C   Shade: %.0f%%" % [WorldMap.temperature[idx], WorldMap.shade[idx] * 100.0])
	lines.append("Air moisture: %.0f%%   Wind: %.0f%%" % [WorldMap.air_moisture[idx] * 100.0, ClimateSystem.wind_speed * 100.0])
	lines.append("Surface water: %.1f / %.1f" % [WorldMap.surface_water[idx], WorldMap.water_capacity(idx)])
	lines.append("Underground water: %.1f" % WorldMap.underground_water[idx])
	lines.append("Soil moisture: %.1f / %.1f" % [WorldMap.soil_moisture[idx], GameConfig.SOIL_WATER_CAPACITY])
	if WorldMap.aquifer_potential[idx] > 0.0:
		lines.append("Aquifer potential: %.0f%%" % (WorldMap.aquifer_potential[idx] * 100.0))
	if WorldMap.rare_groundwater[idx] > 0.0:
		lines.append("Rare groundwater pocket: %.0f%%" % (WorldMap.rare_groundwater[idx] * 100.0))
	if BuildSystem.is_pending(idx):
		lines.append("Under construction: %.0f%%" % (BuildSystem.get_pending_progress(idx) * 100.0))
	elif WorldMap.structure_type[idx] != WorldMap.Structure.NONE:
		lines.append("Structure: %s" % BuildSystem.structure_name(WorldMap.structure_type[idx]))
		if WorldMap.structure_type[idx] == WorldMap.Structure.GATE:
			lines.append("Gate is %s" % ("OPEN" if WorldMap.gate_open[idx] == 1 else "CLOSED"))
	if PlantSystem.plants.has(idx):
		var p: PlantInstance = PlantSystem.plants[idx]
		lines.append("Plant: %s (stage %d/%d)" % [p.data.display_name, p.stage_index + 1, p.data.total_stages()])
		lines.append("Health: %.0f%%   Water stress: %.1f d" % [p.health * 100.0, p.water_stress_days])
	_label.text = "\n".join(lines)

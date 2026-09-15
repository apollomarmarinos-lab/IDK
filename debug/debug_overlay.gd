## Debug Overlay for Simulation Visualization
## CanvasLayer that draws debug information over the simulation grid.

extends CanvasLayer

# Toggle states for each debug mode
var _debug_mode: int = -1  # -1 = off, 0-3 = different overlays
const DEBUG_MODES: int = 4

# References to simulation data (set by caller)
var sim_manager: Node = null

# Colors for visualization
const COLOR_WATER_LOW = Color(0.5, 0.5, 1.0, 0.3)
const COLOR_WATER_HIGH = Color(0.0, 0.0, 1.0, 0.8)
const COLOR_HUMIDITY_LOW = Color(0.8, 0.8, 0.2, 0.3)
const COLOR_HUMIDITY_HIGH = Color(0.0, 0.5, 0.0, 0.8)
const COLOR_SHADE_LOW = Color(1.0, 1.0, 1.0, 0.1)
const COLOR_SHADE_HIGH = Color(0.0, 0.0, 0.0, 0.7)
const COLOR_TEMP_COLD = Color(0.0, 0.5, 1.0, 0.5)
const COLOR_TEMP_HOT = Color(1.0, 0.3, 0.0, 0.5)

# Tile size (should match simulation)
var tile_size: int = 32


func _ready() -> void:
	"""Initialize debug overlay."""
	layer = 100  # Render on top of everything
	pass


func _draw() -> void:
	"""Draw the active debug overlay."""
	if _debug_mode < 0 or sim_manager == null:
		return
	
	match _debug_mode:
		0:
			_draw_water_overlay()
		1:
			_draw_humidity_overlay()
		2:
			_draw_shade_overlay()
		3:
			_draw_temperature_overlay()


func _input(event: InputEvent) -> void:
	"""Handle debug toggle input (F1-F4)."""
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_F1:
				_debug_mode = 0 if _debug_mode != 0 else -1
				queue_redraw()
				print("Debug: Water overlay %s" % ["ON" if _debug_mode == 0 else "OFF"])
			KEY_F2:
				_debug_mode = 1 if _debug_mode != 1 else -1
				queue_redraw()
				print("Debug: Humidity overlay %s" % ["ON" if _debug_mode == 1 else "OFF"])
			KEY_F3:
				_debug_mode = 2 if _debug_mode != 2 else -1
				queue_redraw()
				print("Debug: Shade overlay %s" % ["ON" if _debug_mode == 2 else "OFF"])
			KEY_F4:
				_debug_mode = 3 if _debug_mode != 3 else -1
				queue_redraw()
				print("Debug: Temperature overlay %s" % ["ON" if _debug_mode == 3 else "OFF"])


func set_simulation_manager(manager: Node) -> void:
	"""Set reference to simulation manager for data access."""
	sim_manager = manager


func _draw_water_overlay() -> void:
	"""Draw water level visualization (blue gradient)."""
	var water_level = sim_manager.water_level
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			var water = water_level[idx]
			
			if water > 0:
				var intensity = clamp(water / 2.0, 0.0, 1.0)
				var color = lerp(COLOR_WATER_LOW, COLOR_WATER_HIGH, intensity)
				
				var rect = Rect2(x * tile_size, y * tile_size, tile_size, tile_size)
				draw_rect(rect, color)


func _draw_humidity_overlay() -> void:
	"""Draw soil humidity visualization (green/yellow gradient)."""
	var soil_humidity = sim_manager.soil_humidity
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			var humidity = soil_humidity[idx]
			
			if humidity > 0:
				var intensity = clamp(humidity / 100.0, 0.0, 1.0)
				var color = lerp(COLOR_HUMIDITY_LOW, COLOR_HUMIDITY_HIGH, intensity)
				
				var rect = Rect2(x * tile_size, y * tile_size, tile_size, tile_size)
				draw_rect(rect, color)


func _draw_shade_overlay() -> void:
	"""Draw shade percentage visualization (white to black gradient)."""
	var shade_percentage = sim_manager.shade_percentage
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			var shade = shade_percentage[idx]
			
			if shade > 0:
				var color = lerp(COLOR_SHADE_LOW, COLOR_SHADE_HIGH, shade)
				
				var rect = Rect2(x * tile_size, y * tile_size, tile_size, tile_size)
				draw_rect(rect, color)


func _draw_temperature_overlay() -> void:
	"""Draw temperature visualization (blue=cold to red=hot gradient)."""
	var temperature = sim_manager.temperature
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	
	# Assume temperature range 15-50°C for visualization
	var temp_min = 15.0
	var temp_max = 50.0
	
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			var temp = temperature[idx]
			
			var intensity = clamp((temp - temp_min) / (temp_max - temp_min), 0.0, 1.0)
			var color = lerp(COLOR_TEMP_COLD, COLOR_TEMP_HOT, intensity)
			
			var rect = Rect2(x * tile_size, y * tile_size, tile_size, tile_size)
			draw_rect(rect, color)


func cycle_debug_mode() -> void:
	"""Cycle through debug modes sequentially."""
	_debug_mode = (_debug_mode + 1) % (DEBUG_MODES + 1)
	if _debug_mode >= DEBUG_MODES:
		_debug_mode = -1  # Turn off after last mode
	queue_redraw()
	
	if _debug_mode < 0:
		print("Debug: All overlays OFF")
	else:
		var mode_names = ["Water", "Humidity", "Shade", "Temperature"]
		print("Debug: %s overlay ON" % mode_names[_debug_mode])

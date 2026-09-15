extends Node
## SimulationManager Autoload
## Central orchestrator for all simulation systems.
## Manages authoritative state arrays and coordinates tick execution.

# Grid configuration
const GRID_WIDTH: int = 64
const GRID_HEIGHT: int = 64
const TILE_SIZE: int = 32

# Authoritative state arrays (flat arrays for performance)
var water_level: Array[float] = []
var soil_humidity: Array[float] = []
var temperature: Array[float] = []
var shade_percentage: Array[float] = []
var terrain_elevation: Array[float] = []
var tile_data: Array[Dictionary] = []  # Custom metadata per tile (lined, dig_cost, etc.)

# Plant instances
var active_plants: Array[Dictionary] = []

# Global simulation parameters
var global_temperature: float = 35.0  # Base desert temperature
var global_sun_intensity: float = 1.0
var wind_vector: Vector2 = Vector2(1, 0)  # Directional wind
var wind_speed: float = 5.0
var current_rain_intensity: float = 0.0
var season: String = "summer"

# Simulation timing
var tick_accumulator: float = 0.0
const TICK_RATE: float = 0.1  # Simulation ticks per second (10 ticks/sec)

# References to system scripts
var water_system: Script
var microclimate_system: Script
var plant_system: Script
var world_generator: Script


func _ready() -> void:
	"""Initialize the simulation manager and all systems."""
	_initialize_arrays()
	_load_systems()
	print("SimulationManager initialized with grid %dx%d" % [GRID_WIDTH, GRID_HEIGHT])


func _initialize_arrays() -> void:
	"""Initialize all flat arrays for grid state."""
	var total_tiles: int = GRID_WIDTH * GRID_HEIGHT
	
	water_level.resize(total_tiles)
	soil_humidity.resize(total_tiles)
	temperature.resize(total_tiles)
	shade_percentage.resize(total_tiles)
	terrain_elevation.resize(total_tiles)
	tile_data.resize(total_tiles)
	
	for i in range(total_tiles):
		water_level[i] = 0.0
		soil_humidity[i] = 0.0
		temperature[i] = global_temperature
		shade_percentage[i] = 0.0
		terrain_elevation[i] = 0.0
		tile_data[i] = {
			"lined": false,
			"dig_cost": 1.0,
			"walkable": true,
			"buildable": true,
			"tile_type": "sand"
		}


func _load_systems() -> void:
	"""Load system scripts (to be implemented)."""
	# These will be loaded once the system scripts are created
	pass


func _physics_process(delta: float) -> void:
	"""Main simulation loop - orchestrates all system ticks."""
	tick_accumulator += delta
	
	if tick_accumulator >= TICK_RATE:
		_run_simulation_tick(tick_accumulator)
		tick_accumulator = 0.0


func _run_simulation_tick(delta: float) -> void:
	"""Execute one complete simulation tick in strict order."""
	# 1. Water System (flow, seepage, evaporation)
	if water_system:
		water_system.update_water_system(self, delta, wind_vector, current_rain_intensity)
	else:
		_update_water_system_fallback(delta, wind_vector, current_rain_intensity)
	
	# 2. Microclimate System (shade, temperature, humidity aggregation)
	if microclimate_system:
		microclimate_system.update_microclimate(self, delta)
	else:
		_update_microclimate_fallback(delta)
	
	# 3. Plant Health System (stress accumulation, growth, death)
	if plant_system:
		plant_system.update_plant_health(self, delta)
	else:
		_update_plant_health_fallback(delta)
	
	# Reset rain intensity after processing (flash flood mechanic)
	current_rain_intensity = 0.0


func _update_water_system_fallback(delta: float, _wind: Vector2, rain: float) -> void:
	"""Fallback water system implementation (see scripts/systems/water_system.gd)."""
	# Simplified implementation for testing
	if rain > 0:
		for i in range(GRID_WIDTH * GRID_HEIGHT):
			if terrain_elevation[i] > 0.5:  # Mountain tiles
				# Flash flood - water rushes downstream
				var neighbor = _get_downstream_neighbor(i)
				if neighbor != -1:
					water_level[neighbor] += rain * 0.5 * delta
			else:
				# Valley gets gentle rain
				soil_humidity[i] += rain * delta
	
	# Simplified evaporation
	for i in range(GRID_WIDTH * GRID_HEIGHT):
		if water_level[i] > 0:
			var evap_rate = global_sun_intensity * (1.0 - shade_percentage[i]) * 0.1
			water_level[i] = max(0, water_level[i] - evap_rate * delta)


func _update_microclimate_fallback(delta: float) -> void:
	"""Fallback microclimate implementation (see scripts/systems/microclimate_system.gd)."""
	for y in range(GRID_HEIGHT):
		for x in range(GRID_WIDTH):
			var idx = y * GRID_WIDTH + x
			
			# Temperature based on elevation and shade
			var base_temp = global_temperature - (terrain_elevation[idx] * 5.0)
			var sun_exposure = 1.0 - shade_percentage[idx]
			temperature[idx] = base_temp + (sun_exposure * 5.0 * delta)
			
			# Soil humidity from water proximity
			if water_level[idx] > 0:
				soil_humidity[idx] = min(100.0, soil_humidity[idx] + water_level[idx] * 0.5)


func _update_plant_health_fallback(delta: float) -> void:
	"""Fallback plant health implementation (see scripts/systems/plant_system.gd)."""
	var plants_to_remove: Array[int] = []
	
	for i in range(active_plants.size()):
		var plant = active_plants[i]
		var tile_idx = plant.tile_index
		
		# Simple stress calculation
		var stress = 0.0
		if temperature[tile_idx] > 40:
			stress += (temperature[tile_idx] - 40) * 0.01
		if soil_humidity[tile_idx] < 20:
			stress += (20 - soil_humidity[tile_idx]) * 0.005
		
		plant.health -= stress * delta
		plant.growth_progress += 1.0 if stress == 0 else 0.0
		
		if plant.health <= 0:
			plants_to_remove.append(i)
	
	# Remove dead plants (reverse iteration)
	for i in range(plants_to_remove.size() - 1, -1, -1):
		active_plants.remove_at(plants_to_remove[i])


func _get_downstream_neighbor(tile_idx: int) -> int:
	"""Find the lowest neighboring tile for water flow."""
	var x = tile_idx % GRID_WIDTH
	var y = float(tile_idx) / float(GRID_WIDTH)
	var lowest_idx = -1
	var lowest_elev = terrain_elevation[tile_idx]
	
	var directions = [[-1, 0], [1, 0], [0, -1], [0, 1]]
	for dir in directions:
		var nx = x + dir[0]
		var ny = int(y) + dir[1]
		if nx >= 0 and nx < GRID_WIDTH and ny >= 0 and ny < GRID_HEIGHT:
			var n_idx = ny * GRID_WIDTH + nx
			if terrain_elevation[n_idx] < lowest_elev:
				lowest_elev = terrain_elevation[n_idx]
				lowest_idx = n_idx
	
	return lowest_idx


func get_tile_index(x: int, y: int) -> int:
	"""Convert x,y coordinates to flat array index."""
	if x < 0 or x >= GRID_WIDTH or y < 0 or y >= GRID_HEIGHT:
		return -1
	return y * GRID_WIDTH + x


func get_tile_coords(index: int) -> Vector2:
	"""Convert flat array index to x,y coordinates."""
	return Vector2(index % GRID_WIDTH, float(index) / float(GRID_WIDTH))

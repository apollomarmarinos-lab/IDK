## Microclimate System Implementation
## Calculates per-tile shade, temperature, and humidity as a central simulation hub.

class_name MicroclimateSystem
extends RefCounted


const ALTITUDE_COOLING_FACTOR: float = 5.0
const SUN_INTENSITY: float = 8.0
const WATER_COOLING_FACTOR: float = 3.0
const MOISTURE_WICKING_FACTOR: float = 0.5
const SHADE_CALCULATION_RADIUS: int = 3


static func update_microclimate(sim_manager: Node, delta: float) -> void:
	"""
	Update the microclimate layer for one tick.
	
	This is the central hub that aggregates environmental data from:
	- Terrain elevation
	- Water levels
	- Plant canopy (shade)
	- Global weather conditions
	
	Args:
		sim_manager: Reference to SimulationManager with state arrays
		delta: Time elapsed since last tick
	"""
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	var terrain_elevation = sim_manager.terrain_elevation
	var water_level = sim_manager.water_level
	var shade_percentage = sim_manager.shade_percentage
	var temperature = sim_manager.temperature
	var soil_humidity = sim_manager.soil_humidity
	var active_plants = sim_manager.active_plants
	var global_temperature = sim_manager.global_temperature
	
	# Create new arrays for atomic swap
	var new_shade_array: Array[float] = []
	var new_temp_array: Array[float] = []
	var new_humidity_array: Array[float] = []
	new_shade_array.resize(grid_width * grid_height)
	new_temp_array.resize(grid_width * grid_height)
	new_humidity_array.resize(grid_width * grid_height)
	
	# 1. Calculate Shade from plant canopies
	_calculate_shade_layer(
		new_shade_array, active_plants, grid_width, grid_height
	)
	
	# 2. Calculate Temperature based on elevation, sun, shade, and water
	_calculate_temperature_layer(
		new_temp_array, new_shade_array, terrain_elevation, water_level,
		global_temperature, delta, grid_width, grid_height
	)
	
	# 3. Aggregate Soil Humidity from water, transpiration, and base humidity
	_calculate_humidity_layer(
		new_humidity_array, soil_humidity, water_level, active_plants,
		grid_width, grid_height
	)
	
	# Atomically swap arrays to prevent race conditions
	for i in range(shade_percentage.size()):
		shade_percentage[i] = clamp(new_shade_array[i], 0.0, 1.0)
		temperature[i] = new_temp_array[i]
		soil_humidity[i] = clamp(new_humidity_array[i], 0.0, 100.0)


static func _calculate_shade_layer(
	new_shade_array: Array[float],
	active_plants: Array[Dictionary],
	grid_width: int,
	grid_height: int
) -> void:
	"""Calculate shade percentage for each tile from canopy plants."""
	# Initialize shade array
	for i in range(grid_width * grid_height):
		new_shade_array[i] = 0.0
	
	# For each canopy plant, apply shade to surrounding tiles
	for plant in active_plants:
		if not plant.get("is_canopy", false):
			continue
		
		var plant_tile = plant.tile_index
		var shade_radius = plant.get("shade_radius", 3)
		var shade_density = plant.get("shade_density", 0.8)
		
		var plant_x = plant_tile % grid_width
		var plant_y = float(plant_tile) / float(grid_width)
		
		# Apply shade to all tiles within radius
		for dy in range(-shade_radius, shade_radius + 1):
			for dx in range(-shade_radius, shade_radius + 1):
				var tile_x = plant_x + dx
				var tile_y = plant_y + dy
				
				if tile_x < 0 or tile_x >= grid_width or tile_y < 0 or tile_y >= grid_height:
					continue
				
				var distance = sqrt(dx * dx + dy * dy)
				if distance > shade_radius:
					continue
				
				var tile_idx = tile_y * grid_width + tile_x
				
				# Shade decreases with distance from plant
				var shade_falloff = 1.0 - (distance / shade_radius)
				var shade_contribution = shade_density * shade_falloff
				
				new_shade_array[tile_idx] += shade_contribution
	
	# Clamp all values to 0-1 range
	for i in range(grid_width * grid_height):
		new_shade_array[i] = clamp(new_shade_array[i], 0.0, 1.0)


static func _calculate_temperature_layer(
	new_temp_array: Array[float],
	shade_array: Array[float],
	terrain_elevation: Array[float],
	water_level: Array[float],
	global_temp: float,
	delta: float,
	grid_width: int,
	grid_height: int
) -> void:
	"""Calculate temperature for each tile based on multiple factors."""
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			
			# Base temperature from global weather + altitude cooling
			var base_temp = global_temp - (terrain_elevation[idx] * ALTITUDE_COOLING_FACTOR)
			
			# Sun exposure heats the tile, shade cools it
			var sun_exposure = 1.0 - shade_array[idx]
			var heat_gain = sun_exposure * SUN_INTENSITY * delta
			
			# Water has a cooling effect (evaporative cooling / specific heat)
			var water_cooling = 0.0
			if water_level[idx] > 0:
				water_cooling = water_level[idx] * WATER_COOLING_FACTOR
			
			new_temp_array[idx] = base_temp + heat_gain - water_cooling


static func _calculate_humidity_layer(
	new_humidity_array: Array[float],
	base_humidity: Array[float],
	water_level: Array[float],
	active_plants: Array[Dictionary],
	grid_width: int,
	grid_height: int
) -> void:
	"""Calculate soil humidity for each tile from water and plant transpiration."""
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			
			# Start with base humidity (from direct rain)
			var humidity = base_humidity[idx]
			
			# Add moisture from adjacent water (wicking)
			if water_level[idx] > 0:
				humidity += water_level[idx] * MOISTURE_WICKING_FACTOR
			
			# Add transpiration from nearby plants
			var neighbors = _get_neighbors(idx, grid_width, grid_height, 1)
			for neighbor_idx in neighbors:
				var plant = _get_plant_at_tile(active_plants, neighbor_idx)
				if plant != null:
					var transpiration = plant.get("transpiration_rate", 0.5)
					humidity += transpiration
			
			new_humidity_array[idx] = humidity


static func _get_neighbors(
	tile_idx: int,
	grid_width: int,
	grid_height: int,
	radius: int = 1
) -> Array[int]:
	"""Get all neighboring tile indices within given radius."""
	var neighbors: Array[int] = []
	var x = tile_idx % grid_width
	var y = float(tile_idx) / float(grid_width)
	
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue  # Skip the center tile
			
			var nx = x + dx
			var ny = int(y) + dy
			
			if nx >= 0 and nx < grid_width and ny >= 0 and ny < grid_height:
				neighbors.append(ny * grid_width + nx)
	
	return neighbors


static func _get_plant_at_tile(active_plants: Array[Dictionary], tile_idx: int) -> Dictionary:
	"""Find the plant instance at a specific tile index."""
	for plant in active_plants:
		if plant.tile_index == tile_idx:
			return plant
	return null

## Water System Implementation
## Handles water flow, seepage, evaporation, and flash floods.

class_name WaterSystem
extends RefCounted


const FLOW_RATE_CONSTANT: float = 0.5
const SEEPAGE_RATE_CONSTANT: float = 0.1
const WIND_EVAPORATION_MULTIPLIER: float = 0.05
const MOUNTAIN_RUNOFF_MULTIPLIER: float = 2.0


static func update_water_system(sim_manager: Node, delta: float, wind_vector: Vector2, current_rain_intensity: float) -> void:
	"""
	Update the water system for one tick.
	
	Args:
		sim_manager: Reference to SimulationManager with state arrays
		delta: Time elapsed since last tick
		wind_vector: Directional wind vector
		current_rain_intensity: Current rainfall intensity (0 if no rain)
	"""
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	var water_level = sim_manager.water_level
	var soil_humidity = sim_manager.soil_humidity
	var terrain_elevation = sim_manager.terrain_elevation
	var tile_data = sim_manager.tile_data
	var shade_percentage = sim_manager.shade_percentage
	var global_sun_intensity = sim_manager.global_sun_intensity
	var wind_speed = sim_manager.wind_speed
	
	# 1. Handle Rain and Flash Floods
	if current_rain_intensity > 0:
		_handle_rain_and_floods(
			water_level, soil_humidity, terrain_elevation,
			grid_width, grid_height, current_rain_intensity, delta
		)
	
	# 2. Water Flow (Diffusion)
	_update_water_flow(
		water_level, terrain_elevation, tile_data,
		grid_width, grid_height, delta
	)
	
	# 3. Seepage and Evaporation
	_apply_seepage_and_evaporation(
		water_level, soil_humidity, tile_data, shade_percentage,
		global_sun_intensity, wind_speed,
		grid_width, grid_height, delta
	)


static func _handle_rain_and_floods(
	water_level: Array[float],
	soil_humidity: Array[float],
	terrain_elevation: Array[float],
	grid_width: int,
	grid_height: int,
	rain_intensity: float,
	delta: float
) -> void:
	"""Process rainfall and flash flood mechanics."""
	for i in range(grid_width * grid_height):
		if terrain_elevation[i] > 0.5:
			# Mountain tiles generate flash flood water rushing downstream
			var downstream_tile = _find_downstream_neighbor(i, terrain_elevation, grid_width, grid_height)
			if downstream_tile != -1:
				water_level[downstream_tile] += rain_intensity * MOUNTAIN_RUNOFF_MULTIPLIER * delta
		else:
			# Valley tiles get gentle direct rain
			soil_humidity[i] += rain_intensity * delta


static func _update_water_flow(
	water_level: Array[float],
	terrain_elevation: Array[float],
	tile_data: Array[Dictionary],
	grid_width: int,
	grid_height: int,
	delta: float
) -> void:
	"""Simulate water diffusion between connected tiles."""
	var new_water_level = water_level.duplicate()
	
	for y in range(grid_height):
		for x in range(grid_width):
			var tile_idx = y * grid_width + x
			
			if water_level[tile_idx] <= 0:
				continue
			
			var neighbors = _get_connected_neighbors(tile_idx, grid_width, grid_height, tile_data)
			
			for neighbor_idx in neighbors:
				# Calculate total height (terrain + water)
				var height_diff = (terrain_elevation[tile_idx] + water_level[tile_idx]) - \
								  (terrain_elevation[neighbor_idx] + water_level[neighbor_idx])
				
				if height_diff > 0:
					# Lined canals reduce flow slightly but prevent seepage
					var flow_modifier = 0.8 if tile_data[tile_idx].get("lined", false) else 1.0
					
					var transfer_amount = min(
						water_level[tile_idx],
						height_diff * FLOW_RATE_CONSTANT * flow_modifier * delta
					)
					
					new_water_level[tile_idx] -= transfer_amount
					new_water_level[neighbor_idx] += transfer_amount
	
	# Apply changes atomically
	for i in range(water_level.size()):
		water_level[i] = max(0, new_water_level[i])


static func _apply_seepage_and_evaporation(
	water_level: Array[float],
	soil_humidity: Array[float],
	tile_data: Array[Dictionary],
	shade_percentage: Array[float],
	global_sun_intensity: float,
	wind_speed: float,
	grid_width: int,
	grid_height: int,
	delta: float
) -> void:
	"""Apply evaporation and seepage losses to water tiles."""
	for i in range(grid_width * grid_height):
		if water_level[i] <= 0:
			continue
		
		# Evaporation: driven by sun, reduced by shade, increased by wind
		var sun_factor = global_sun_intensity * (1.0 - shade_percentage[i])
		var wind_factor = wind_speed * WIND_EVAPORATION_MULTIPLIER
		var evaporation_loss = (sun_factor + wind_factor) * delta
		
		water_level[i] = max(0, water_level[i] - evaporation_loss)
		
		# Seepage: recharges aquifer/soil if unlined
		if not tile_data[i].get("lined", false):
			var seepage_amount = min(water_level[i], SEEPAGE_RATE_CONSTANT * delta)
			water_level[i] -= seepage_amount
			soil_humidity[i] += seepage_amount


static func _find_downstream_neighbor(
	tile_idx: int,
	terrain_elevation: Array[float],
	grid_width: int,
	grid_height: int
) -> int:
	"""Find the lowest neighboring tile for water flow."""
	var x = tile_idx % grid_width
	var y = float(tile_idx) / float(grid_width)
	var lowest_idx = -1
	var lowest_elev = terrain_elevation[tile_idx]
	
	var directions = [[-1, 0], [1, 0], [0, -1], [0, 1]]
	for dir in directions:
		var nx = x + dir[0]
		var ny = int(y) + dir[1]
		if nx >= 0 and nx < grid_width and ny >= 0 and ny < grid_height:
			var n_idx = ny * grid_width + nx
			if terrain_elevation[n_idx] < lowest_elev:
				lowest_elev = terrain_elevation[n_idx]
				lowest_idx = n_idx
	
	return lowest_idx


static func _get_connected_neighbors(
	tile_idx: int,
	grid_width: int,
	grid_height: int,
	tile_data: Array[Dictionary]
) -> Array[int]:
	"""Get neighboring tiles that are connected for water flow."""
	var neighbors: Array[int] = []
	var x = tile_idx % grid_width
	var y = float(tile_idx) / float(grid_width)
	
	var directions = [[-1, 0], [1, 0], [0, -1], [0, 1]]
	for dir in directions:
		var nx = x + dir[0]
		var ny = int(y) + dir[1]
		if nx >= 0 and nx < grid_width and ny >= 0 and ny < grid_height:
			var n_idx = ny * grid_width + nx
			# Check if tiles are connected (both are water/canal tiles)
			# Simplified: assume all tiles can exchange water
			neighbors.append(n_idx)
	
	return neighbors

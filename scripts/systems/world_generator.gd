## World Generator Implementation
## Procedural terrain generation using FastNoiseLite with geological layers.

class_name WorldGenerator
extends RefCounted


const ELEVATION_THRESHOLD: float = 0.5  # Threshold for mountain/valley split
const ALLUVIAL_FAN_THRESHOLD: float = 0.3  # Slope gradient threshold for alluvial fans


static func generate_world(sim_manager: Node, seed_value: int = -1) -> void:
	"""
	Generate the complete world terrain and hydrological features.
	
	This is a multi-layered process:
	1. Primary elevation map using noise
	2. Secondary moisture layer for landforms
	3. Geological analysis for aquifers and alluvial fans
	4. Tile metadata initialization
	
	Args:
		sim_manager: Reference to SimulationManager
		seed_value: Random seed (-1 for random)
	"""
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	var terrain_elevation = sim_manager.terrain_elevation
	var tile_data = sim_manager.tile_data
	
	print("Generating world: %dx%d grid with seed %d" % [grid_width, grid_height, seed_value if seed_value != -1 else randi()])
	
	# Create noise resources
	var elevation_noise = _create_elevation_noise(seed_value)
	var moisture_noise = _create_moisture_noise(seed_value + 1 if seed_value != -1 else -1)
	
	# Layer 1: Generate primary elevation map
	_generate_elevation_layer(
		terrain_elevation, elevation_noise, moisture_noise,
		grid_width, grid_height
	)
	
	# Layer 2: Analyze geology and set tile metadata
	_analyze_geology_and_set_metadata(
		tile_data, terrain_elevation, grid_width, grid_height
	)
	
	# Layer 3: Initialize water features (rivers, aquifers)
	_initialize_water_features(
		sim_manager.water_level, sim_manager.soil_humidity,
		terrain_elevation, tile_data, grid_width, grid_height
	)
	
	print("World generation complete!")


static func _create_elevation_noise(seed_value: int) -> FastNoiseLite:
	"""Create noise resource for terrain elevation."""
	var noise = FastNoiseLite.new()
	noise.seed = seed_value if seed_value != -1 else randi()
	noise.frequency = 0.02  # Large-scale features
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	return noise


static func _create_moisture_noise(seed_value: int) -> FastNoiseLite:
	"""Create noise resource for moisture/landform variation."""
	var noise = FastNoiseLite.new()
	noise.seed = seed_value if seed_value != -1 else randi()
	noise.frequency = 0.03  # Medium-scale features
	noise.fractal_octaves = 3
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	return noise


static func _generate_elevation_layer(
	terrain_elevation: Array[float],
	elevation_noise: FastNoiseLite,
	moisture_noise: FastNoiseLite,
	grid_width: int,
	grid_height: int
) -> void:
	"""Generate the primary elevation layer with geological features."""
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			
			# Get base elevation from noise
			var elev = elevation_noise.get_noise_2d(x, y)
			
			# Normalize to 0-1 range (noise returns -1 to 1)
			elev = (elev + 1.0) / 2.0
			
			# Add moisture-based variation for alluvial fans
			var moisture = moisture_noise.get_noise_2d(x * 2, y * 2)
			moisture = (moisture + 1.0) / 2.0
			
			# Enhance mountain/valley contrast
			if elev > ELEVATION_THRESHOLD:
				# Mountain region - amplify elevation
				elev = ELEVATION_THRESHOLD + (elev - ELEVATION_THRESHOLD) * 1.5
			else:
				# Valley region - flatten slightly
				elev = elev * 0.8
			
			terrain_elevation[idx] = clamp(elev, 0.0, 1.0)


static func _analyze_geology_and_set_metadata(
	tile_data: Array[Dictionary],
	terrain_elevation: Array[float],
	grid_width: int,
	grid_height: int
) -> void:
	"""Analyze terrain to identify geological features and set tile properties."""
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			var elev = terrain_elevation[idx]
			
			# Determine tile type based on elevation
			if elev > ELEVATION_THRESHOLD:
				tile_data[idx]["tile_type"] = "mountain"
				tile_data[idx]["dig_cost"] = 3.0  # Hard rock
				tile_data[idx]["walkable"] = false
				tile_data[idx]["buildable"] = false
			elif elev > ELEVATION_THRESHOLD * 0.7:
				tile_data[idx]["tile_type"] = "alluvial_fan"
				tile_data[idx]["dig_cost"] = 1.5  # Porous sediment
				tile_data[idx]["walkable"] = true
				tile_data[idx]["buildable"] = true
				# Alluvial fans may contain aquifers
				tile_data[idx]["has_aquifer"] = true
			else:
				tile_data[idx]["tile_type"] = "sand"
				tile_data[idx]["dig_cost"] = 1.0  # Easy to dig
				tile_data[idx]["walkable"] = true
				tile_data[idx]["buildable"] = true
				tile_data[idx]["has_aquifer"] = false
			
			# Calculate slope gradient for alluvial fan detection
			var slope = _calculate_slope(idx, terrain_elevation, grid_width, grid_height)
			if slope > ALLUVIAL_FAN_THRESHOLD and elev > ELEVATION_THRESHOLD * 0.5:
				tile_data[idx]["is_alluvial_apex"] = true


static func _initialize_water_features(
	water_level: Array[float],
	soil_humidity: Array[float],
	terrain_elevation: Array[float],
	tile_data: Array[Dictionary],
	grid_width: int,
	grid_height: int
) -> void:
	"""Initialize natural water features based on terrain."""
	# Find the lowest point in the valley for potential oasis/lake
	var lowest_idx = -1
	var lowest_elev = 1.0
	
	for i in range(grid_width * grid_height):
		if terrain_elevation[i] < lowest_elev and tile_data[i]["tile_type"] == "sand":
			lowest_elev = terrain_elevation[i]
			lowest_idx = i
	
	# Create a small starting water source at the lowest point
	if lowest_idx != -1:
		# Initial water pool
		water_level[lowest_idx] = 0.5
		
		# Higher soil humidity around water source
		var neighbors = _get_neighbors(lowest_idx, grid_width, grid_height, 2)
		for neighbor_idx in neighbors:
			soil_humidity[neighbor_idx] = 30.0
	
	# Add moisture to alluvial fan areas (simulating underground aquifers)
	for i in range(grid_width * grid_height):
		if tile_data[i].get("has_aquifer", false):
			soil_humidity[i] += 10.0


static func _calculate_slope(
	tile_idx: int,
	terrain_elevation: Array[float],
	grid_width: int,
	grid_height: int
) -> float:
	"""Calculate slope gradient at a tile using neighboring elevations."""
	var x = tile_idx % grid_width
	var y = float(tile_idx) / float(grid_width)
	var center_elev = terrain_elevation[tile_idx]
	
	var max_diff = 0.0
	var directions = [[-1, 0], [1, 0], [0, -1], [0, 1]]
	
	for dir in directions:
		var nx = x + dir[0]
		var ny = int(y) + dir[1]
		if nx >= 0 and nx < grid_width and ny >= 0 and ny < grid_height:
			var n_idx = ny * grid_width + nx
			var diff = abs(terrain_elevation[n_idx] - center_elev)
			max_diff = max(max_diff, diff)
	
	return max_diff


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
				continue
			
			var nx = x + dx
			var ny = int(y) + dy
			
			if nx >= 0 and nx < grid_width and ny >= 0 and ny < grid_height:
				neighbors.append(ny * grid_width + nx)
	
	return neighbors

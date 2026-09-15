## Plant Health System Implementation
## Handles stress accumulation, growth, death, and visual feedback for plants.

class_name PlantSystem
extends RefCounted


static func update_plant_health(sim_manager: Node, delta: float) -> void:
	"""
	Update plant health for all active plants.
	
	This system queries the microclimate layer for current conditions,
	compares them against each plant's tolerance thresholds from its
	PlantData resource, and applies stress/growth accordingly.
	
	Args:
		sim_manager: Reference to SimulationManager with state arrays
		delta: Time elapsed since last tick
	"""
	var active_plants = sim_manager.active_plants
	var temperature = sim_manager.temperature
	var soil_humidity = sim_manager.soil_humidity
	var shade_percentage = sim_manager.shade_percentage
	
	var plants_to_remove: Array[int] = []
	
	for i in range(active_plants.size()):
		var plant = active_plants[i]
		var tile_idx = plant.tile_index
		
		# Fetch current conditions from the Microclimate Hub
		var current_temp = temperature[tile_idx]
		var current_humidity = soil_humidity[tile_idx]
		var current_shade = shade_percentage[tile_idx]
		
		# Get plant data resource
		var plant_data = plant.plant_data
		
		# Calculate total stress factor (0.0 = optimal, 1.0 = maximum stress)
		var total_stress = _calculate_total_stress(
			plant_data, current_temp, current_humidity, current_shade
		)
		
		# Apply stress effects or recovery/growth
		if total_stress > 0:
			# Accumulate damage from stress
			var damage = total_stress * plant_data.stress_accumulation_rate * delta
			plant.health -= damage
			
			# Halt growth during stress
			plant.growth_progress = max(0, plant.growth_progress - delta * 0.1)
			
			# Update visual state based on stress level
			plant.visual_state = _get_stress_visual_state(total_stress)
		else:
			# Recover health and grow
			plant.health = min(plant_data.max_health, plant.health + plant_data.recovery_rate * delta)
			plant.growth_progress += plant_data.base_growth_speed * delta
			
			# Optimal conditions - green tint
			plant.visual_state = "healthy"
		
		# Check for death
		if plant.health <= 0:
			plants_to_remove.append(i)
			plant.visual_state = "dead"
		
		# Check for maturity (optional harvest mechanic)
		if plant.growth_progress >= 1.0:
			plant.mature = true
	
	# Remove dead plants (reverse iteration to maintain indices)
	for i in range(plants_to_remove.size() - 1, -1, -1):
		active_plants.remove_at(plants_to_remove[i])


static func _calculate_total_stress(
	plant_data: Resource,
	current_temp: float,
	current_humidity: float,
	current_shade: float
) -> float:
	"""
	Calculate total stress factor using CWSI-inspired model.
	
	Returns a value from 0.0 (optimal) to 1.0 (maximum stress).
	This is an abstraction of real-world Crop Water Stress Index.
	"""
	# 1. Calculate Temperature Stress
	var temp_stress = 0.0
	if current_temp < plant_data.ideal_temp_min:
		temp_stress = (plant_data.ideal_temp_min - current_temp) / plant_data.temp_tolerance_range
	elif current_temp > plant_data.ideal_temp_max:
		temp_stress = (current_temp - plant_data.ideal_temp_max) / plant_data.temp_tolerance_range
	temp_stress = clamp(temp_stress, 0.0, 1.0)
	
	# 2. Calculate Water Stress (too much or too little)
	var water_stress = 0.0
	if current_humidity < plant_data.water_tolerance_min:
		water_stress = (plant_data.water_tolerance_min - current_humidity) / plant_data.water_tolerance_min
	elif current_humidity > plant_data.water_tolerance_max:
		water_stress = (current_humidity - plant_data.water_tolerance_max) / (100.0 - plant_data.water_tolerance_max)
	water_stress = clamp(water_stress, 0.0, 1.0)
	
	# 3. Calculate Light Stress (shade loving vs sun loving)
	var light_stress = 0.0
	if plant_data.is_shade_loving:
		if current_shade < plant_data.min_light_requirement:
			light_stress = (plant_data.min_light_requirement - current_shade) / plant_data.min_light_requirement
	else:
		# Sun-loving plants stressed by too much shade
		if current_shade > 0.7:
			light_stress = (current_shade - 0.7) / 0.3
	light_stress = clamp(light_stress, 0.0, 1.0)
	
	# 4. Aggregate Stress (weighted sum could be used for fine-tuning)
	var total_stress = clamp(temp_stress + water_stress + light_stress, 0.0, 1.0)
	
	return total_stress


static func _get_stress_visual_state(stress_level: float) -> String:
	"""
	Map stress level to stylized visual state.
	
	This provides clear, color-coded feedback to the player:
	- GREEN: Healthy (0-20% stress)
	- YELLOW: Mild stress (20-40%)
	- ORANGE: Severe stress (40-60%)
	- RED: Critical/Dying (60-100%)
	"""
	if stress_level <= 0.2:
		return "healthy"  # Green
	elif stress_level <= 0.4:
		return "mild_stress"  # Yellow
	elif stress_level <= 0.6:
		return "severe_stress"  # Orange
	else:
		return "critical"  # Red


static func create_plant_instance(
	plant_data: Resource,
	tile_index: int,
	is_canopy: bool = false
) -> Dictionary:
	"""
	Create a new plant instance dictionary.
	
	Args:
		plant_data: The PlantData resource for this plant type
		tile_index: The grid tile where the plant is placed
		is_canopy: Whether this plant creates shade (e.g., Date Palm)
	
	Returns:
		Dictionary containing all plant instance state
	"""
	var plant = {
		"plant_data": plant_data,
		"plant_id": plant_data.plant_id,
		"tile_index": tile_index,
		"health": plant_data.max_health,
		"growth_progress": 0.0,
		"mature": false,
		"is_canopy": is_canopy,
		"visual_state": "healthy",
		"transpiration_rate": plant_data.transpiration_rate,
	}
	
	# Add canopy-specific properties if applicable
	if is_canopy and plant_data is CanopyPlantData:
		plant["shade_radius"] = plant_data.shade_radius
		plant["shade_density"] = plant_data.shade_density
	
	return plant

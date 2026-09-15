## Base Plant Data Resource
## Defines static properties for plant types.
## Extend this resource to create specific plant definitions.

class_name BasePlantData
extends Resource

@export_group("Basic Properties")
@export var plant_id: String = "base_plant"
@export var display_name: String = "Base Plant"
@export var description: String = "A basic plant."

@export_group("Growth Parameters")
@export var base_growth_speed: float = 1.0  # Growth units per tick
@export var max_health: float = 100.0
@export var recovery_rate: float = 5.0  # Health recovery per tick when not stressed

@export_group("Environmental Tolerances")
@export var ideal_temp_min: float = 20.0
@export var ideal_temp_max: float = 35.0
@export var temp_tolerance_range: float = 15.0  # How much deviation is acceptable
@export var water_tolerance_min: float = 20.0  # Minimum soil humidity %
@export var water_tolerance_max: float = 80.0  # Maximum soil humidity %

@export_group("Physiological Properties")
@export var transpiration_rate: float = 0.5  # Moisture released back into air
@export var stress_accumulation_rate: float = 0.1  # How quickly stress damages health

@export_group("Light Preferences")
@export var is_shade_loving: bool = false
@export var min_light_requirement: float = 0.3  # Minimum shade percentage (0-1)


func get_stress_factor(current_temp: float, current_humidity: float, current_shade: float) -> float:
	"""Calculate total stress factor (0.0 = optimal, 1.0 = maximum stress)."""
	var temp_stress = _calculate_temp_stress(current_temp)
	var water_stress = _calculate_water_stress(current_humidity)
	var light_stress = _calculate_light_stress(current_shade)
	
	var total_stress = clamp(temp_stress + water_stress + light_stress, 0.0, 1.0)
	return total_stress


func _calculate_temp_stress(current_temp: float) -> float:
	"""Calculate temperature stress (0-1)."""
	if current_temp >= ideal_temp_min and current_temp <= ideal_temp_max:
		return 0.0
	
	if current_temp < ideal_temp_min:
		return clamp((ideal_temp_min - current_temp) / temp_tolerance_range, 0.0, 1.0)
	else:
		return clamp((current_temp - ideal_temp_max) / temp_tolerance_range, 0.0, 1.0)


func _calculate_water_stress(current_humidity: float) -> float:
	"""Calculate water stress (0-1)."""
	if current_humidity >= water_tolerance_min and current_humidity <= water_tolerance_max:
		return 0.0
	
	if current_humidity < water_tolerance_min:
		return clamp((water_tolerance_min - current_humidity) / water_tolerance_min, 0.0, 1.0)
	else:
		return clamp((current_humidity - water_tolerance_max) / (100.0 - water_tolerance_max), 0.0, 1.0)


func _calculate_light_stress(current_shade: float) -> float:
	"""Calculate light stress based on shade preference (0-1)."""
	if is_shade_loving:
		if current_shade >= min_light_requirement:
			return 0.0
		else:
			return clamp((min_light_requirement - current_shade) / min_light_requirement, 0.0, 1.0)
	else:
		# Sun-loving plants stressed by too much shade
		if current_shade <= 0.7:
			return 0.0
		else:
			return clamp((current_shade - 0.7) / 0.3, 0.0, 1.0)

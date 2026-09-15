## Date Palm Data Resource
## The canopy keystone - creates microclimate for other plants.

class_name CanopyPlantData
extends BasePlantData

@export_group("Canopy Properties")
@export var shade_radius: int = 3  # Tiles covered by shade
@export var shade_density: float = 0.8  # 0.0 to 1.0, how much sun is blocked
@export var taproot_depth: float = 2.0  # Ability to access deep aquifers

@export_group("Special Abilities")
@export var moisture_retention_bonus: float = 0.2  # Bonus to soil humidity retention
@export var windbreak_strength: float = 0.5  # Reduces wind speed in area


func _init():
	"""Initialize with Date Palm defaults."""
	plant_id = "date_palm"
	display_name = "Date Palm"
	description = "The canopy keystone. High drought tolerance, deep taproots, massive shade radius."
	base_growth_speed = 0.3  # Slow growing
	ideal_temp_min = 25.0
	ideal_temp_max = 45.0
	temp_tolerance_range = 20.0
	water_tolerance_min = 15.0
	water_tolerance_max = 70.0
	transpiration_rate = 0.8
	stress_accumulation_rate = 0.05  # Very resilient
	is_shade_loving = false

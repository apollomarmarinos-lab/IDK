## Alfalfa Plant Data Resource
## Fast-growing ground cover with high transpiration.

class_name AlfalfaPlantData
extends BasePlantData


func _init():
"""Initialize with Alfalfa defaults."""
plant_id = "alfalfa"
display_name = "Alfalfa"
description = "Fast-growing ground cover. High transpiration rate, fixes nitrogen."
base_growth_speed = 1.5  # Fast growing
ideal_temp_min = 15.0
ideal_temp_max = 30.0
temp_tolerance_range = 10.0
water_tolerance_min = 30.0
water_tolerance_max = 70.0
transpiration_rate = 1.2  # High transpiration (actively cools air)
stress_accumulation_rate = 0.15  # Susceptible to heat without shade
is_shade_loving = true  # Needs protection from midday sun
min_light_requirement = 0.3

class_name PlantData
extends Resource
## Static definition of a plant species. Drop a new .tres built from this
## resource into res://data/plants/ to add a species to the game -- no code
## changes required, PlantSystem scans the directory at startup.

enum SunPreference { FULL_SUN, PARTIAL_SHADE, SHADE_TOLERANT }

@export var id: StringName = &""
@export var display_name: String = ""
@export_enum("Tree", "Shrub", "Herb", "Flower", "Crop") var category: String = "Tree"

@export_group("Water")
## Total water (soil-moisture units) a mature specimen draws per in-game day.
@export var water_need_per_day: float = 4.0
## Deep-rooted plants (trees) tolerate dry spells better than shallow-rooted herbs.
@export var deep_roots: bool = false
## Days of unmet water need the plant can tolerate before health starts dropping.
@export var drought_tolerance_days: float = 3.0

@export_group("Climate")
@export var heat_tolerance_c: float = 44.0
@export_enum("FullSun", "PartialShade", "ShadeTolerant") var sun_preference: String = "FullSun"

@export_group("Shade cast")
@export var shade_radius: float = 0.0
@export var shade_strength: float = 0.0

@export_group("Growth")
## Duration in in-game days of each growth stage (last stage = mature, holds indefinitely).
@export var growth_stage_days: PackedInt32Array = PackedInt32Array([5, 10, 20])
## GameClock.Season indices during which a mature plant can be harvested.
@export var harvest_seasons: PackedInt32Array = PackedInt32Array([1])
@export var yield_item: StringName = &""
@export var yield_amount: float = 1.0

@export_group("Look")
@export var color: Color = Color(0.35, 0.55, 0.3)
@export var mature_scale: float = 1.0

func sun_preference_enum() -> int:
	match sun_preference:
		"PartialShade":
			return SunPreference.PARTIAL_SHADE
		"ShadeTolerant":
			return SunPreference.SHADE_TOLERANT
		_:
			return SunPreference.FULL_SUN

func total_stages() -> int:
	return growth_stage_days.size()

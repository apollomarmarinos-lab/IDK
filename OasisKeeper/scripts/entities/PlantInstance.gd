class_name PlantInstance
extends RefCounted
## Runtime, mutable state for one planted specimen. Lightweight on purpose
## (a RefCounted, not a Node) so a large oasis can hold thousands of plants
## without per-instance scene-tree overhead.

var data: PlantData
var tile_index: int = -1

var age_days: float = 0.0
var stage_index: int = 0
var health: float = 1.0 ## 0..1, 0 = dead
var water_stress_days: float = 0.0
var harvested_this_season: bool = false

func _init(p_data: PlantData = null, p_tile_index: int = -1) -> void:
	data = p_data
	tile_index = p_tile_index

func is_mature() -> bool:
	return stage_index >= data.total_stages() - 1

## 0..1 overall growth completion, used for both visual scale and the
## canopy factor that feeds into shade casting.
func get_growth_fraction() -> float:
	var stages: int = data.total_stages()
	if stages <= 0:
		return 1.0
	if is_mature():
		return 1.0
	var elapsed: float = age_days
	var stage_start: float = 0.0
	for i in range(stages):
		var dur: float = float(max(1, data.growth_stage_days[i]))
		if elapsed < stage_start + dur:
			var within: float = (elapsed - stage_start) / dur
			return (float(i) + within) / float(stages)
		stage_start += dur
	return 1.0

func get_canopy_factor() -> float:
	if health <= 0.0:
		return 0.0
	return get_growth_fraction() * clampf(health + 0.3, 0.0, 1.0)

func advance_day() -> void:
	age_days += 1.0
	_recompute_stage()

func _recompute_stage() -> void:
	var stages: int = data.total_stages()
	var elapsed: float = age_days
	var stage_start: float = 0.0
	for i in range(stages):
		var dur: float = float(max(1, data.growth_stage_days[i]))
		if elapsed < stage_start + dur or i == stages - 1:
			if i != stage_index:
				stage_index = i
			return
		stage_start += dur

func can_harvest_in_season(season: int) -> bool:
	return is_mature() and not harvested_this_season and data.harvest_seasons.has(season)

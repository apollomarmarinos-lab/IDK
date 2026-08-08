extends Node
## Owns every planted specimen, its day-to-day water draw, growth, health,
## and seasonal harvesting. Plant *definitions* live in data-driven
## PlantData resources (res://data/plants/*.tres); this system only holds
## runtime state and the rules for how a plant lives or dies.

const PLANT_DATA_DIR: String = "res://data/plants/"

var plants: Dictionary = {} ## tile_index(int) -> PlantInstance
var database: Dictionary = {} ## id(StringName) -> PlantData
var inventory: Dictionary = {} ## yield_item(StringName) -> float

func _ready() -> void:
	_load_database()
	EventBus.day_passed.connect(_on_day_passed)
	EventBus.season_changed.connect(_on_season_changed)
	EventBus.world_generated.connect(_on_world_generated)

func _on_world_generated() -> void:
	plants.clear()

func _load_database() -> void:
	database.clear()
	var dir := DirAccess.open(PLANT_DATA_DIR)
	if dir == null:
		push_warning("PlantSystem: could not open %s" % PLANT_DATA_DIR)
		return
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var res: Resource = load(PLANT_DATA_DIR + file_name)
			if res is PlantData:
				var pd: PlantData = res
				if pd.id == &"":
					push_warning("PlantSystem: %s has no id, skipping" % file_name)
				else:
					database[pd.id] = pd
		file_name = dir.get_next()
	dir.list_dir_end()

func get_plant_ids() -> Array:
	return database.keys()

func get_plant_data(id: StringName) -> PlantData:
	return database.get(id, null)

func can_plant(idx: int, id: StringName) -> bool:
	if not database.has(id):
		return false
	if idx < 0 or idx >= WorldMap.width * WorldMap.height:
		return false
	if not WorldMap.is_plantable_ground(idx):
		return false
	if WorldMap.structure_type[idx] != WorldMap.Structure.NONE:
		return false
	if plants.has(idx):
		return false
	return true

func plant(idx: int, id: StringName) -> bool:
	if not can_plant(idx, id):
		return false
	var instance := PlantInstance.new(database[id], idx)
	plants[idx] = instance
	EventBus.emit_signal("plant_planted", idx, id)
	EventBus.emit_signal("tile_changed", idx)
	return true

func remove_plant(idx: int) -> void:
	if not plants.has(idx):
		return
	plants.erase(idx)
	EventBus.emit_signal("plant_removed", idx)
	EventBus.emit_signal("tile_changed", idx)

func simulate_tick() -> void:
	var days_per_tick: float = GameConfig.GAME_MINUTES_PER_TICK / (float(GameConfig.HOURS_PER_DAY) * 60.0)
	var dead: Array[int] = []
	for idx in plants.keys():
		var idx_i: int = idx
		var p: PlantInstance = plants[idx_i]
		_consume_water(p, idx_i, days_per_tick)
		_apply_climate_stress(p, idx_i, days_per_tick)
		if p.health <= 0.0:
			dead.append(idx_i)
	for idx in dead:
		var p: PlantInstance = plants[idx]
		EventBus.emit_signal("plant_died", idx, p.data.id)
		remove_plant(idx)

func _consume_water(p: PlantInstance, idx: int, days_per_tick: float) -> void:
	var demand: float = p.data.water_need_per_day * days_per_tick * clampf(p.get_growth_fraction() + 0.2, 0.0, 1.0)
	if demand <= 0.0:
		return
	var available: float = WorldMap.soil_moisture[idx]
	var drawn: float = minf(demand, available)
	if p.data.deep_roots and drawn < demand:
		# Deep roots can pull a little extra from neighboring soil (reaching
		# further underground than shallow-rooted herbs).
		var buf := PackedInt32Array([0, 0, 0, 0])
		var count: int = WorldMap.get_neighbors4(idx, buf)
		for n in range(count):
			if drawn >= demand:
				break
			var nidx: int = buf[n]
			var extra: float = minf(demand - drawn, WorldMap.soil_moisture[nidx] * 0.3)
			extra = maxf(extra, 0.0)
			WorldMap.soil_moisture[nidx] -= extra
			drawn += extra
			WaterSystem.notify_soil_dried(nidx)

	WorldMap.soil_moisture[idx] -= minf(drawn, WorldMap.soil_moisture[idx])
	WaterSystem.notify_soil_dried(idx)
	if drawn > 0.0:
		ClimateSystem.add_transpiration(idx, drawn)

	var shortfall_fraction: float = 1.0 - (drawn / demand)
	if shortfall_fraction > 0.05:
		p.water_stress_days += shortfall_fraction * days_per_tick
	else:
		p.water_stress_days = maxf(0.0, p.water_stress_days - days_per_tick * 2.0)

	if p.water_stress_days > p.data.drought_tolerance_days:
		var overage: float = p.water_stress_days - p.data.drought_tolerance_days
		p.health = clampf(p.health - overage * 0.05, 0.0, 1.0)
	elif p.water_stress_days <= 0.0:
		p.health = clampf(p.health + days_per_tick * 0.5, 0.0, 1.0)

func _apply_climate_stress(p: PlantInstance, idx: int, days_per_tick: float) -> void:
	var temp: float = ClimateSystem.temperature_at(idx)
	if temp > p.data.heat_tolerance_c:
		var shade_relief: float = WorldMap.shade[idx]
		var exceedance: float = (temp - p.data.heat_tolerance_c) * (1.0 - shade_relief * 0.9)
		if exceedance > 0.0:
			p.health = clampf(p.health - exceedance * 0.01 * days_per_tick * 24.0, 0.0, 1.0)

	var pref: int = p.data.sun_preference_enum()
	if pref == PlantData.SunPreference.PARTIAL_SHADE and WorldMap.shade[idx] < 0.1 and temp > p.data.heat_tolerance_c * 0.8:
		p.health = clampf(p.health - days_per_tick * 0.02, 0.0, 1.0)

func _on_day_passed(_day: int, season: int, _year: int) -> void:
	for idx in plants.keys():
		var p: PlantInstance = plants[idx]
		var prev_stage: int = p.stage_index
		# Fertile alluvium grows plants noticeably faster than dune sand,
		# which is why real oases cluster along the wadis.
		var fert: float = lerpf(GameConfig.FERTILITY_GROWTH_FLOOR, 1.0, clampf(WorldMap.fertility[idx], 0.0, 1.0))
		p.advance_day(fert * clampf(p.health + 0.25, 0.3, 1.0))
		if p.stage_index != prev_stage:
			EventBus.emit_signal("plant_stage_changed", idx, p.stage_index)
		if p.can_harvest_in_season(season):
			_harvest(idx, p)

func _harvest(idx: int, p: PlantInstance) -> void:
	p.harvested_this_season = true
	var amount: float = p.data.yield_amount * clampf(p.health, 0.2, 1.0)
	if p.data.yield_item != &"":
		inventory[p.data.yield_item] = inventory.get(p.data.yield_item, 0.0) + amount
		EventBus.emit_signal("inventory_changed", p.data.yield_item, inventory[p.data.yield_item])
	EventBus.emit_signal("plant_harvested", idx, p.data.id, amount)

func _on_season_changed(_season: int) -> void:
	for idx in plants.keys():
		var p: PlantInstance = plants[idx]
		p.harvested_this_season = false

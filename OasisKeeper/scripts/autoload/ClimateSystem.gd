extends Node
## Drives the desert microclimate: wind, temperature, shade, evaporation,
## transpiration and the humidity that a healthy oasis builds up around
## itself.
##
## This is what makes shade a real gameplay lever: water sitting in the sun
## evaporates fast, the same water in shade evaporates much slower, and a
## thriving canopy of date palms measurably cools and humidifies the tiles
## beneath it.

var wind_speed: float = GameConfig.WIND_BASE_SPEED ## normalized 0..1
var wind_direction: Vector2 = Vector2(0, 1) ## unit vector, points where wind blows toward

var _wind_noise_a := FastNoiseLite.new()
var _wind_noise_b := FastNoiseLite.new()
var _wind_time: float = 0.0

var _air_moisture_next: PackedFloat32Array = PackedFloat32Array()
var _neighbor_buf: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])

var _temperature_tick_counter: int = 0
var _moisture_tick_counter: int = 0
## Tiles carrying a shade structure. Maintained incrementally instead of
## rescanning the whole map every tick just to find a handful of them.
var _shade_structures: Dictionary = {}
## Temperature and humidity are whole-map passes over every tile, and both
## change slowly compared to the tick rate, so they run on a stride rather
## than every tick. On a large map these two loops dominate the frame cost.
const TEMPERATURE_UPDATE_EVERY_N_TICKS: int = 4
const MOISTURE_UPDATE_EVERY_N_TICKS: int = 3

func _ready() -> void:
	_wind_noise_a.seed = randi()
	_wind_noise_a.frequency = 1.0
	_wind_noise_b.seed = randi()
	_wind_noise_b.frequency = 1.0
	EventBus.world_generated.connect(_on_world_generated)
	EventBus.building_completed.connect(_on_building_completed)
	EventBus.building_removed.connect(_on_building_removed)

func _on_world_generated() -> void:
	_air_moisture_next = WorldMap.air_moisture.duplicate()
	_shade_structures.clear()

func _on_building_completed(idx: int, _id: StringName) -> void:
	if WorldMap.structure_type[idx] == WorldMap.Structure.SHADE_STRUCTURE:
		_shade_structures[idx] = true

func _on_building_removed(idx: int) -> void:
	_shade_structures.erase(idx)

func simulate_tick() -> void:
	if WorldMap.width == 0:
		return
	_update_wind()
	_temperature_tick_counter += 1
	if _temperature_tick_counter >= TEMPERATURE_UPDATE_EVERY_N_TICKS:
		_temperature_tick_counter = 0
		_update_temperature()
	_update_shade()
	_evaporate_surface()
	_evaporate_soil()
	_moisture_tick_counter += 1
	if _moisture_tick_counter >= MOISTURE_UPDATE_EVERY_N_TICKS:
		_moisture_tick_counter = 0
		_diffuse_air_moisture()

func _update_wind() -> void:
	_wind_time += GameConfig.SIM_TICK_INTERVAL * 0.05
	var gust: float = _wind_noise_a.get_noise_1d(_wind_time)
	wind_speed = clampf(GameConfig.WIND_BASE_SPEED + gust * GameConfig.WIND_GUST_VARIANCE, 0.0, 1.0)
	var lateral: float = _wind_noise_b.get_noise_1d(_wind_time) * 0.6
	# Prevailing wind is channeled along the valley's long axis (north/south
	# between the two ranges), with gentle lateral drift.
	wind_direction = Vector2(lateral, 1.0).normalized()

func _update_temperature() -> void:
	var sun: float = GameClock.get_sun_curve()
	var season: int = GameClock.season
	var peak_temp: float = GameConfig.SEASON_BASE_TEMP[season]
	var night_drop: float = GameConfig.SEASON_NIGHT_DROP[season]
	var base_temp: float = peak_temp - night_drop * (1.0 - sun)

	var w: int = WorldMap.width
	var h: int = WorldMap.height
	for i in range(w * h):
		var t: float = base_temp
		t -= WorldMap.elevation[i] * GameConfig.ELEVATION_LAPSE_RATE
		t -= WorldMap.shade[i] * GameConfig.SHADE_COOLING
		if WorldMap.water[i] > 0.5 or WorldMap.soil_moisture[i] > 1.0:
			t -= GameConfig.WATER_COOLING
		WorldMap.temperature[i] = t

func _update_shade() -> void:
	WorldMap.shade.fill(0.0)
	for idx in PlantSystem.plants.keys():
		var plant: PlantInstance = PlantSystem.plants[idx]
		var canopy: float = plant.get_canopy_factor()
		if canopy <= 0.0:
			continue
		_splat_shade(idx, plant.data.shade_radius, plant.data.shade_strength * canopy)
	for idx in _shade_structures.keys():
		_splat_shade(idx, GameConfig.SHADE_STRUCTURE_RADIUS, GameConfig.SHADE_STRUCTURE_STRENGTH)

func _splat_shade(center_idx: int, radius: float, strength: float) -> void:
	if radius <= 0.0 or strength <= 0.0:
		return
	var cx: int = center_idx % WorldMap.width
	var cy: int = center_idx / WorldMap.width
	var r: int = int(ceil(radius))
	for dy in range(-r, r + 1):
		var y: int = cy + dy
		if y < 0 or y >= WorldMap.height:
			continue
		for dx in range(-r, r + 1):
			var x: int = cx + dx
			if x < 0 or x >= WorldMap.width:
				continue
			var dist: float = Vector2(dx, dy).length()
			if dist > radius:
				continue
			var falloff: float = clampf(1.0 - dist * GameConfig.SHADE_DECAY_PER_TILE / maxf(radius, 0.001), 0.0, 1.0)
			var idx: int = y * WorldMap.width + x
			WorldMap.shade[idx] = clampf(WorldMap.shade[idx] + strength * falloff, 0.0, 1.0)

func _evaporation_multiplier(idx: int) -> float:
	var temp_factor: float = clampf((WorldMap.temperature[idx] - 15.0) / 30.0, 0.05, 2.5)
	var wind_factor: float = 1.0 + wind_speed * GameConfig.WIND_EVAPORATION_FACTOR
	var shade_factor: float = 1.0 - WorldMap.shade[idx] * GameConfig.SHADE_EVAPORATION_SUPPRESSION
	var humidity_factor: float = 1.0 - WorldMap.air_moisture[idx] * GameConfig.HUMIDITY_EVAPORATION_SUPPRESSION
	return temp_factor * wind_factor * shade_factor * humidity_factor

func _evaporate_surface() -> void:
	for idx in WaterSystem.get_active_tiles().keys():
		var idx_i: int = idx
		if WorldMap.water[idx_i] <= 0.0:
			continue
		var lost: float
		if WorldMap.is_open_to_sky(idx_i):
			lost = WorldMap.water[idx_i] * GameConfig.BASE_EVAPORATION_COEFF * _evaporation_multiplier(idx_i)
		else:
			# Covered channels barely lose anything -- that's the whole
			# reason to pay the extra digging cost for them.
			lost = WorldMap.water[idx_i] * GameConfig.COVERED_SEEPAGE_COEFF
		lost = minf(lost, WorldMap.water[idx_i])
		WorldMap.water[idx_i] -= lost
		if WorldMap.is_open_to_sky(idx_i):
			WorldMap.air_moisture[idx_i] = clampf(WorldMap.air_moisture[idx_i] + lost * GameConfig.MOISTURE_RELEASE_COEFF, 0.0, 1.0)

func _evaporate_soil() -> void:
	var moist: Dictionary = WaterSystem.get_moist_soil_tiles()
	for idx in moist.keys():
		var idx_i: int = idx
		if WorldMap.soil_moisture[idx_i] <= 0.0:
			continue
		var mult: float = _evaporation_multiplier(idx_i)
		var lost: float = WorldMap.soil_moisture[idx_i] * GameConfig.SOIL_EVAPORATION_COEFF * mult
		lost = minf(lost, WorldMap.soil_moisture[idx_i])
		WorldMap.soil_moisture[idx_i] -= lost
		WorldMap.air_moisture[idx_i] = clampf(WorldMap.air_moisture[idx_i] + lost * GameConfig.MOISTURE_RELEASE_COEFF * 0.5, 0.0, 1.0)
		WaterSystem.notify_soil_dried(idx_i)

## Called by PlantSystem when a plant draws water from the soil, so the
## transpired portion humidifies the air above its own tile.
func add_transpiration(idx: int, amount: float) -> void:
	WorldMap.air_moisture[idx] = clampf(WorldMap.air_moisture[idx] + amount * GameConfig.MOISTURE_RELEASE_COEFF, 0.0, 1.0)

func _diffuse_air_moisture() -> void:
	var w: int = WorldMap.width
	var h: int = WorldMap.height
	var size: int = w * h
	if _air_moisture_next.size() != size:
		_air_moisture_next.resize(size)
	var src: PackedFloat32Array = WorldMap.air_moisture
	var wind_x: float = wind_direction.x * wind_speed * GameConfig.WIND_ADVECTION_STRENGTH
	var wind_y: float = wind_direction.y * wind_speed * GameConfig.WIND_ADVECTION_STRENGTH

	for y in range(h):
		for x in range(w):
			var idx: int = y * w + x
			var value: float = src[idx]

			# Diffusion: blend toward the average of orthogonal neighbors.
			var count: int = WorldMap.get_neighbors4(idx, _neighbor_buf)
			var avg: float = 0.0
			for n in range(count):
				avg += src[_neighbor_buf[n]]
			if count > 0:
				avg /= float(count)
				value = lerpf(value, avg, GameConfig.AIR_MOISTURE_DIFFUSION)

			# Advection: pull a bit of moisture from the upwind tile so the
			# humid pocket trails downwind of the oasis.
			var upwind_x: int = x - int(round(wind_x))
			var upwind_y: int = y - int(round(wind_y))
			if WorldMap.in_bounds(upwind_x, upwind_y):
				var upwind_value: float = src[WorldMap.index_of(upwind_x, upwind_y)]
				value = lerpf(value, upwind_value, clampf(wind_speed * GameConfig.WIND_ADVECTION_STRENGTH, 0.0, 0.9))

			value = maxf(0.0, value - GameConfig.AIR_MOISTURE_DECAY)
			_air_moisture_next[idx] = value

	var tmp: PackedFloat32Array = WorldMap.air_moisture
	WorldMap.air_moisture = _air_moisture_next
	_air_moisture_next = tmp

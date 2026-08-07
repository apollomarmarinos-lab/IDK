extends Node
## Drives the day/night cycle and the four-season calendar, and runs the
## fixed-rate simulation tick that every other system hooks into.
##
## Decoupling "how often we simulate" from "how often we render" keeps the
## water/climate/plant simulations deterministic and cheap: they only need
## to think about a fixed GameConfig.GAME_MINUTES_PER_TICK step, never about
## frame time.

enum Season { SPRING, SUMMER, AUTUMN, WINTER }

const SEASON_NAMES: Array[String] = ["Spring", "Summer", "Autumn", "Winter"]

var time_scale: float = 1.0 ## 0 = paused, 1/2/4 = speed multipliers
var minute: float = 360.0 ## start at 06:00
var hour: int = 6
var day: int = 1
var season: int = Season.SPRING
var year: int = 1
var is_night: bool = false

## 0..1 fraction through the current day, 0 = midnight.
var day_fraction: float = 0.25

var _tick_accumulator: float = 0.0

func _ready() -> void:
	_update_night_state(true)

func _process(delta: float) -> void:
	if time_scale <= 0.0:
		return
	_tick_accumulator += delta
	while _tick_accumulator >= GameConfig.SIM_TICK_INTERVAL:
		_tick_accumulator -= GameConfig.SIM_TICK_INTERVAL
		_advance_time(GameConfig.GAME_MINUTES_PER_TICK * time_scale)
		_simulate_tick()

func _advance_time(minutes: float) -> void:
	var previous_hour: int = hour
	minute += minutes
	var minutes_per_day: float = float(GameConfig.HOURS_PER_DAY) * 60.0
	while minute >= minutes_per_day:
		minute -= minutes_per_day
		_advance_day()
	hour = int(minute / 60.0)
	day_fraction = minute / minutes_per_day
	_update_night_state(false)
	if hour != previous_hour:
		EventBus.emit_signal("hour_passed", hour)

func _advance_day() -> void:
	day += 1
	if day > GameConfig.DAYS_PER_SEASON:
		day = 1
		season = (season + 1) % GameConfig.SEASONS_PER_YEAR
		if season == Season.SPRING:
			year += 1
		EventBus.emit_signal("season_changed", season)
	EventBus.emit_signal("day_passed", day, season, year)

func _update_night_state(force: bool) -> void:
	# Night runs roughly 20:00 -> 05:30, tracked as a smooth fraction so
	# renderers can lerp a tint rather than hard-cut to black.
	var was_night: bool = is_night
	is_night = day_fraction < 0.229 or day_fraction > 0.833
	if force:
		return
	if is_night and not was_night:
		EventBus.emit_signal("night_started")
	elif was_night and not is_night:
		EventBus.emit_signal("day_started")

func _simulate_tick() -> void:
	ClimateSystem.simulate_tick()
	WaterSystem.simulate_tick()
	PlantSystem.simulate_tick()
	BuildSystem.simulate_tick()

## Smooth 0..1 curve peaking at solar noon (0.5 day_fraction), used by
## ClimateSystem for the temperature curve and by renderers for lighting.
func get_sun_curve() -> float:
	return max(0.0, sin((day_fraction - 0.229) / (0.833 - 0.229) * PI))

func get_season_name() -> String:
	return SEASON_NAMES[season]

func set_time_scale(scale: float) -> void:
	time_scale = scale

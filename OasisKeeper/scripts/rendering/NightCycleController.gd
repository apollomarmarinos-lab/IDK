extends CanvasModulate
## Tints the whole scene through the day/night cycle. Deliberately never
## dips below MIN_NIGHT_TINT -- the brief asks for a night that is visibly
## distinguishable but does not black out the map.

const DAY_COLOR := Color(1.0, 0.98, 0.9)
const DUSK_COLOR := Color(0.85, 0.55, 0.45)
const NIGHT_COLOR := Color(0.32, 0.38, 0.62)

func _process(_delta: float) -> void:
	var sun: float = GameClock.get_sun_curve() # 0 at night, 1 at solar noon
	var df: float = GameClock.day_fraction
	var is_dusk_dawn: bool = (df > 0.15 and df < 0.32) or (df > 0.72 and df < 0.88)
	var target: Color
	if sun <= 0.001:
		target = NIGHT_COLOR
	elif is_dusk_dawn:
		target = NIGHT_COLOR.lerp(DUSK_COLOR, clampf(sun * 3.0, 0.0, 1.0))
	else:
		target = DUSK_COLOR.lerp(DAY_COLOR, clampf(sun, 0.0, 1.0))
	color = color.lerp(target, 0.05)

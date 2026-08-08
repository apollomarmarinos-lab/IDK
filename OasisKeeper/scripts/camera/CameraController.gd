extends Camera2D
## WASD/arrow-key panning and scroll-wheel zoom.

@export var pan_speed: float = 600.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.2 ## zoomed out far enough to see the whole valley
@export var max_zoom: float = 4.0

func _ready() -> void:
	make_current()
	var t: float = float(GameConfig.TILE_PIXEL_SIZE)
	# Open looking at the foot of the western range rather than the middle
	# of an empty dune field: the player should see mountains, foothills and
	# valley floor in the first frame.
	position = Vector2(42.0 * t, float(GameConfig.MAP_HEIGHT) * 0.5 * t)
	# 0.8 keeps tiles large and readable while still showing a range and a
	# stretch of valley at once.
	zoom = Vector2(0.8, 0.8)

func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_action_pressed("ui_left"):
		dir.x -= 1
	if Input.is_action_pressed("ui_right"):
		dir.x += 1
	if Input.is_action_pressed("ui_up"):
		dir.y -= 1
	if Input.is_action_pressed("ui_down"):
		dir.y += 1
	if dir != Vector2.ZERO:
		position += dir.normalized() * pan_speed * delta / zoom.x

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_by(1.0 + zoom_speed)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_by(1.0 - zoom_speed)

func _zoom_by(factor: float) -> void:
	var new_zoom: float = clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(new_zoom, new_zoom)

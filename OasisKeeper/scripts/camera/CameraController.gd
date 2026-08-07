extends Camera2D
## WASD/arrow-key panning and scroll-wheel zoom.

@export var pan_speed: float = 600.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.25
@export var max_zoom: float = 3.0

func _ready() -> void:
	var map_w: float = float(GameConfig.MAP_WIDTH * GameConfig.TILE_PIXEL_SIZE)
	var map_h: float = float(GameConfig.MAP_HEIGHT * GameConfig.TILE_PIXEL_SIZE)
	position = Vector2(map_w, map_h) * 0.5
	zoom = Vector2(0.6, 0.6)

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

extends Camera2D
## Grab-to-drag panning, WASD/arrow keys, edge scrolling and scroll-wheel zoom.
##
## Left-drag grabs the map, which is what the hand expects. It cannot do that
## unconditionally, because left-drag is also how a canal run is laid out, so
## MainController flips `build_tool_active` as the tool changes: with the
## Inspect tool the left button drags the map, with a build tool it builds.
## The right and middle buttons drag the map whatever tool is selected, so the
## map is always grabbable without putting the tool down.

@export var pan_speed: float = 600.0
@export var zoom_speed: float = 0.1
@export var min_zoom: float = 0.2 ## zoomed out far enough to see the whole valley
@export var max_zoom: float = 4.0
## Screen margin, in pixels, where the cursor starts scrolling the map.
@export var edge_scroll_margin: float = 14.0

## Set by MainController whenever the selected tool changes. While a build
## tool is up, the left button belongs to that tool.
var build_tool_active: bool = false

## Which mouse button is currently dragging the map, or -1 for none.
var _pan_button: int = -1

func _ready() -> void:
	make_current()
	var t: float = float(GameConfig.TILE_PIXEL_SIZE)
	# Open on a natural oasis sink -- the low, fertile ground the wadi
	# network drains into, and the obvious place to start building.
	if not WorldMap.oases.is_empty():
		var c: Vector2i = WorldMap.coords_of(WorldMap.oases[0])
		position = Vector2(float(c.x), float(c.y)) * t
	else:
		position = Vector2(float(GameConfig.MAP_WIDTH), float(GameConfig.MAP_HEIGHT)) * 0.5 * t
	# 0.8 keeps tiles large and readable while still showing a range and a
	# stretch of valley at once.
	zoom = Vector2(0.8, 0.8)

func _process(delta: float) -> void:
	var dir := Vector2.ZERO
	dir += _edge_scroll_direction()
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
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if not build_tool_active and not _over_ui(mb.position):
					_pan_button = MOUSE_BUTTON_LEFT
			elif _pan_button == MOUSE_BUTTON_LEFT:
				_pan_button = -1
		elif mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				if not _over_ui(mb.position):
					_pan_button = mb.button_index
			elif _pan_button == mb.button_index:
				_pan_button = -1
	elif event is InputEventMouseMotion and _pan_button >= 0:
		# Divide by zoom so the ground keeps pace with the cursor at any
		# zoom level -- otherwise dragging feels sluggish zoomed out and
		# twitchy zoomed in.
		position -= event.relative / zoom.x

## The top and bottom bars are opaque UI; a drag that starts on one of them is
## the player using the menu, not reaching for the map.
func _over_ui(screen_pos: Vector2) -> bool:
	var vp: Vector2 = get_viewport_rect().size
	return screen_pos.y < GameConfig.UI_TOP_BAR_HEIGHT \
		or screen_pos.y > vp.y - GameConfig.UI_BOTTOM_BAR_HEIGHT

## Cursor near a screen edge nudges the camera that way, the usual RTS
## behaviour. Ignored while dragging, which would fight it.
func _edge_scroll_direction() -> Vector2:
	if _pan_button >= 0:
		return Vector2.ZERO
	var vp: Vector2 = get_viewport_rect().size
	var m: Vector2 = get_viewport().get_mouse_position()
	if m.x < 0.0 or m.y < 0.0 or m.x > vp.x or m.y > vp.y:
		return Vector2.ZERO
	var d := Vector2.ZERO
	if m.x < edge_scroll_margin:
		d.x -= 1.0
	elif m.x > vp.x - edge_scroll_margin:
		d.x += 1.0
	# Leave the top and bottom bars alone, or the map crawls whenever the
	# cursor is anywhere near the build menu.
	if m.y < GameConfig.UI_TOP_BAR_HEIGHT + edge_scroll_margin and m.y > GameConfig.UI_TOP_BAR_HEIGHT:
		d.y -= 1.0
	elif m.y > vp.y - GameConfig.UI_BOTTOM_BAR_HEIGHT - edge_scroll_margin and m.y < vp.y - GameConfig.UI_BOTTOM_BAR_HEIGHT:
		d.y += 1.0
	return d

func _zoom_by(factor: float) -> void:
	var new_zoom: float = clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(new_zoom, new_zoom)

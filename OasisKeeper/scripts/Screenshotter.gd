class_name Screenshotter
extends Node
## Development helper: waits a few frames, grabs the viewport, writes a PNG
## and quits. Run with:
##   xvfb-run godot --path OasisKeeper -- --screenshot /abs/path.png
## Not used by the game itself.

var _path: String = ""
var _frames: int = 0
var _wait_frames: int = 90
const SETTLE_FRAMES: int = 150 ## frames for the day/night tint to ease in

static func install(host: Node) -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var idx: int = args.find("--screenshot")
	if idx < 0 or idx + 1 >= args.size():
		return
	var s := Screenshotter.new()
	s._path = args[idx + 1]
	var wait_idx: int = args.find("--screenshot-frames")
	if wait_idx >= 0 and wait_idx + 1 < args.size():
		s._wait_frames = int(args[wait_idx + 1])
	host.add_child(s)

## Points the camera at whatever the shot is meant to show. With the
## self-test running that is the canal it dug, which is the thing worth
## eyeballing.
func _frame_subject() -> void:
	var cam: Camera2D = get_tree().root.find_child("Camera2D", true, false)
	if cam == null:
		return
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var zi: int = args.find("--screenshot-zoom")
	if zi >= 0 and zi + 1 < args.size():
		var z: float = float(args[zi + 1])
		cam.zoom = Vector2(z, z)
	for i in range(WorldMap.width * WorldMap.height):
		if WorldMap.is_canal(i) and WorldMap.water[i] > 0.5:
			var c: Vector2i = WorldMap.coords_of(i)
			cam.position = Vector2(float(c.x) + 6.0, float(c.y) + 2.0) * float(GameConfig.TILE_PIXEL_SIZE)
			return
	# No canal to look at: either frame an oasis sink, or the whole map.
	if args.has("--screenshot-oasis") and not WorldMap.oases.is_empty():
		var o: Vector2i = WorldMap.coords_of(WorldMap.oases[0])
		cam.position = Vector2(float(o.x), float(o.y)) * float(GameConfig.TILE_PIXEL_SIZE)
		return
	cam.position = Vector2(float(WorldMap.width), float(WorldMap.height)) * 0.5 * float(GameConfig.TILE_PIXEL_SIZE)

## Forces the clock to a given hour and freezes it. Done SETTLE_FRAMES
## before the capture because the day/night tint eases toward its target
## over many frames -- snapping the clock and grabbing the next frame would
## photograph the old lighting.
func _force_hour() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var hi: int = args.find("--screenshot-hour")
	if hi < 0 or hi + 1 >= args.size():
		return
	GameClock.minute = float(args[hi + 1]) * 60.0
	GameClock.hour = int(GameClock.minute / 60.0)
	GameClock.day_fraction = GameClock.minute / (float(GameConfig.HOURS_PER_DAY) * 60.0)
	GameClock.is_night = GameClock.day_fraction < 0.229 or GameClock.day_fraction > 0.833
	GameClock.set_time_scale(0.0)
	var oi: int = args.find("--screenshot-open")
	if oi >= 0 and oi + 1 < args.size():
		var menu: Node = get_tree().root.find_child("BuildMenu", true, false)
		if menu != null:
			menu.open_category(StringName(args[oi + 1]))

func _process(_delta: float) -> void:
	_frames += 1
	if _frames == _wait_frames - SETTLE_FRAMES:
		_force_hour()
	if _frames < _wait_frames:
		return
	_frame_subject()
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img: Image = get_viewport().get_texture().get_image()
	var err: int = img.save_png(_path)
	print("SCREENSHOT %s -> err=%d size=%s" % [_path, err, img.get_size()])
	_dump_ui_tree()
	get_tree().quit()

## Prints the on-screen rect of every Control, which is the fastest way to
## catch a panel that exists but has collapsed to zero size or drifted
## off-screen.
func _dump_ui_tree() -> void:
	var ui: Node = get_tree().root.find_child("UI", true, false)
	if ui == null:
		print("UITREE: no UI node found")
		return
	_dump_node(ui, 0)

func _dump_node(n: Node, depth: int) -> void:
	var pad: String = "  ".repeat(depth)
	if n is Control:
		var c: Control = n
		print("UITREE %s%s [%s] rect=%s visible=%s" % [pad, n.name, n.get_class(), c.get_global_rect(), c.visible])
	else:
		print("UITREE %s%s [%s]" % [pad, n.name, n.get_class()])
	for child in n.get_children():
		_dump_node(child, depth + 1)

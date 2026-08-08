extends Node2D
## Draws the world.
##
## Split by how often each thing changes:
##   - Terrain is baked once into a detailed image (TerrainBaker).
##   - Soil moisture / shade / data overlays are small per-tile images
##     refreshed a few times a second and stretched with linear filtering,
##     so they read as smooth gradients rather than hard squares.
##   - Structures, plants and flow arrows are drawn with the immediate-mode
##     draw API, culled to the visible viewport, so a canal can be drawn as
##     a real connected channel with a visible water level.

enum Overlay { NONE, AQUIFER, GROUNDWATER, MOISTURE, SHADE, FERTILITY }

@onready var terrain_sprite: Sprite2D = $TerrainSprite
@onready var moisture_sprite: Sprite2D = $MoistureSprite
@onready var shade_sprite: Sprite2D = $ShadeSprite
@onready var overlay_sprite: Sprite2D = $OverlaySprite
@onready var structures_layer: Node2D = $StructuresLayer
@onready var plants_layer: Node2D = $PlantsLayer
@onready var flow_layer: Node2D = $FlowLayer
@onready var selection_layer: Node2D = $SelectionLayer
@onready var refresh_timer: Timer = $RefreshTimer

var overlay_mode: int = Overlay.NONE
var show_flow: bool = true
var selected_tile: int = -1
var hovered_tile: int = -1
var ghost_structure: int = -1 ## structure the active build tool would place

const T: float = float(GameConfig.TILE_PIXEL_SIZE)

# Channel geometry, in fractions of a tile.
const CHANNEL_HALF_WIDTH: float = 0.30
const BED_COLOR := Color(0.29, 0.22, 0.15)
const BED_RIM_COLOR := Color(0.17, 0.13, 0.09)
const WATER_SHALLOW := Color(0.42, 0.74, 0.76)
const WATER_DEEP := Color(0.09, 0.35, 0.62)
const COVER_COLOR := Color(0.52, 0.47, 0.40)
const COVER_LINE := Color(0.33, 0.30, 0.26)
const ROCK_CUT_COLOR := Color(0.30, 0.28, 0.27)

var _moisture_data: PackedByteArray = PackedByteArray()
var _shade_data: PackedByteArray = PackedByteArray()
var _overlay_data: PackedByteArray = PackedByteArray()
var _moisture_tex: ImageTexture
var _shade_tex: ImageTexture
var _overlay_tex: ImageTexture
var _neighbor_buf: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])

func _ready() -> void:
	add_to_group("world_renderer")
	terrain_sprite.centered = false
	terrain_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	terrain_sprite.scale = Vector2.ONE * (T / float(GameConfig.TERRAIN_DETAIL))
	for s: Sprite2D in [moisture_sprite, shade_sprite, overlay_sprite]:
		s.centered = false
		# Linear filtering turns the 1px-per-tile data layers into smooth
		# gradients, which is what makes moisture and shade read as fields
		# rather than a grid of coloured boxes.
		s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		s.scale = Vector2.ONE * T

	EventBus.world_generated.connect(_on_world_generated)
	EventBus.tile_changed.connect(_on_tile_changed)
	for sig in [EventBus.plant_planted, EventBus.plant_removed, EventBus.plant_stage_changed]:
		sig.connect(_on_plants_dirty)
	EventBus.day_passed.connect(_on_plants_dirty)
	refresh_timer.timeout.connect(_refresh)
	structures_layer.draw.connect(_draw_structures)
	plants_layer.draw.connect(_draw_plants)
	flow_layer.draw.connect(_draw_flow)
	selection_layer.draw.connect(_draw_selection)

func _on_world_generated() -> void:
	terrain_sprite.texture = ImageTexture.create_from_image(TerrainBaker.bake(WorldMap.width, WorldMap.height))
	var size: int = WorldMap.width * WorldMap.height
	_moisture_data.resize(size * 4)
	_shade_data.resize(size * 4)
	_overlay_data.resize(size * 4)
	_moisture_tex = null
	_shade_tex = null
	_overlay_tex = null
	_refresh()
	plants_layer.queue_redraw()

func _on_tile_changed(_idx: int) -> void:
	structures_layer.queue_redraw()

func _on_plants_dirty(_a = null, _b = null, _c = null) -> void:
	plants_layer.queue_redraw()

func set_overlay(mode: int) -> void:
	overlay_mode = mode
	_refresh()

func set_show_flow(v: bool) -> void:
	show_flow = v
	flow_layer.visible = v

func set_ghost_structure(structure: int) -> void:
	ghost_structure = structure
	selection_layer.queue_redraw()

func set_selected_tile(idx: int) -> void:
	selected_tile = idx
	selection_layer.queue_redraw()

func set_hovered_tile(idx: int) -> void:
	hovered_tile = idx
	selection_layer.queue_redraw()

# ---------------------------------------------------------------------------
# Data-layer images
# ---------------------------------------------------------------------------

func _refresh() -> void:
	if WorldMap.width == 0:
		return
	_rebuild_data_images()
	structures_layer.queue_redraw()
	if show_flow:
		flow_layer.queue_redraw()

func _rebuild_data_images() -> void:
	var size: int = WorldMap.width * WorldMap.height
	for i in range(size):
		var o: int = i * 4

		# Soil moisture: darkens and cools the ground where water has soaked in.
		var m: float = clampf(WorldMap.soil_moisture[i] / GameConfig.SOIL_WATER_CAPACITY, 0.0, 1.0)
		_moisture_data[o] = 60
		_moisture_data[o + 1] = 45
		_moisture_data[o + 2] = 30
		_moisture_data[o + 3] = int(clampf(m, 0.0, 1.0) * 165.0)

		# Shade: a cool blue-grey wash.
		var sh: float = WorldMap.shade[i]
		_shade_data[o] = 14
		_shade_data[o + 1] = 22
		_shade_data[o + 2] = 34
		_shade_data[o + 3] = int(clampf(sh, 0.0, 1.0) * 120.0)

		_write_overlay_pixel(i, o)

	var w: int = WorldMap.width
	var h: int = WorldMap.height
	_moisture_tex = _update_texture(_moisture_tex, moisture_sprite, w, h, _moisture_data)
	_shade_tex = _update_texture(_shade_tex, shade_sprite, w, h, _shade_data)
	_overlay_tex = _update_texture(_overlay_tex, overlay_sprite, w, h, _overlay_data)
	overlay_sprite.visible = overlay_mode != Overlay.NONE

func _write_overlay_pixel(i: int, o: int) -> void:
	var r: int = 0
	var g: int = 0
	var b: int = 0
	var a: int = 0
	match overlay_mode:
		Overlay.AQUIFER:
			if WorldMap.has_aquifer(i):
				# Full bodies read cyan, depleted ones red -- so the player
				# can see at a glance which one they are draining.
				var fill: float = WorldMap.aquifer_fill_fraction(i)
				var c: Color = Color(0.85, 0.25, 0.25).lerp(Color(0.2, 0.85, 0.95), fill)
				r = int(c.r * 255.0)
				g = int(c.g * 255.0)
				b = int(c.b * 255.0)
				a = 170
		Overlay.GROUNDWATER:
			var gw: float = WorldMap.rare_groundwater[i]
			if gw > 0.0:
				r = 60
				g = 190
				b = 220
				a = int(clampf(gw, 0.0, 1.0) * 200.0)
		Overlay.MOISTURE:
			var m: float = clampf(WorldMap.soil_moisture[i] / GameConfig.SOIL_WATER_CAPACITY, 0.0, 1.0)
			r = 40
			g = 120
			b = 200
			a = int(m * 200.0)
		Overlay.SHADE:
			var sh: float = clampf(WorldMap.shade[i], 0.0, 1.0)
			r = 30
			g = 40
			b = 90
			a = int(sh * 200.0)
		Overlay.FERTILITY:
			var f: float = clampf(WorldMap.fertility[i], 0.0, 1.0)
			if f > 0.0:
				r = int(lerpf(150.0, 40.0, f))
				g = int(lerpf(120.0, 190.0, f))
				b = 40
				a = int(lerpf(40.0, 170.0, f))
	_overlay_data[o] = r
	_overlay_data[o + 1] = g
	_overlay_data[o + 2] = b
	_overlay_data[o + 3] = a

func _update_texture(tex: ImageTexture, sprite: Sprite2D, w: int, h: int, data: PackedByteArray) -> ImageTexture:
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)
	if tex == null:
		tex = ImageTexture.create_from_image(img)
		sprite.texture = tex
	else:
		tex.update(img)
	return tex

# ---------------------------------------------------------------------------
# Immediate-mode drawing
# ---------------------------------------------------------------------------

## Tile-space rect currently on screen, so we only draw what is visible.
func _visible_tile_rect(layer: CanvasItem) -> Rect2i:
	var xf: Transform2D = layer.get_global_transform_with_canvas().affine_inverse()
	var vp: Vector2 = layer.get_viewport_rect().size
	var p0: Vector2 = xf * Vector2.ZERO
	var p1: Vector2 = xf * Vector2(vp.x, 0)
	var p2: Vector2 = xf * Vector2(0, vp.y)
	var p3: Vector2 = xf * vp
	var min_x: float = min(min(p0.x, p1.x), min(p2.x, p3.x))
	var max_x: float = max(max(p0.x, p1.x), max(p2.x, p3.x))
	var min_y: float = min(min(p0.y, p1.y), min(p2.y, p3.y))
	var max_y: float = max(max(p0.y, p1.y), max(p2.y, p3.y))
	var x0: int = clampi(int(floor(min_x / T)) - 1, 0, WorldMap.width - 1)
	var y0: int = clampi(int(floor(min_y / T)) - 1, 0, WorldMap.height - 1)
	var x1: int = clampi(int(ceil(max_x / T)) + 1, 0, WorldMap.width - 1)
	var y1: int = clampi(int(ceil(max_y / T)) + 1, 0, WorldMap.height - 1)
	return Rect2i(x0, y0, maxi(0, x1 - x0), maxi(0, y1 - y0))

func _draw_structures() -> void:
	if WorldMap.width == 0:
		return
	var layer: Node2D = structures_layer
	var r: Rect2i = _visible_tile_rect(layer)
	for y in range(r.position.y, r.position.y + r.size.y + 1):
		for x in range(r.position.x, r.position.x + r.size.x + 1):
			var idx: int = y * WorldMap.width + x
			if BuildSystem.is_pending(idx):
				_draw_construction(layer, x, y, BuildSystem.get_pending_progress(idx))
				continue
			var s: int = WorldMap.structure_type[idx]
			if s == WorldMap.Structure.NONE:
				continue
			match s:
				WorldMap.Structure.CANAL_OPEN:
					_draw_canal(layer, idx, x, y, false, false)
				WorldMap.Structure.CANAL_COVERED:
					_draw_canal(layer, idx, x, y, true, false)
				WorldMap.Structure.CANAL_MOUNTAIN:
					_draw_canal(layer, idx, x, y, true, true)
				WorldMap.Structure.GATE:
					_draw_gate(layer, idx, x, y)
				WorldMap.Structure.RESERVOIR:
					_draw_basin(layer, idx, x, y, false)
				WorldMap.Structure.CISTERN:
					_draw_basin(layer, idx, x, y, true)
				WorldMap.Structure.WELL:
					_draw_well(layer, idx, x, y)
				WorldMap.Structure.SHADE_STRUCTURE:
					_draw_shade_structure(layer, x, y)

## True if the tile in this direction is part of the same water network, so
## channels are drawn as continuous runs rather than disconnected squares.
func _connects(idx: int, dx: int, dy: int) -> bool:
	var x: int = idx % WorldMap.width + dx
	var y: int = idx / WorldMap.width + dy
	if not WorldMap.in_bounds(x, y):
		return false
	var nidx: int = WorldMap.index_of(x, y)
	if BuildSystem.is_pending(nidx):
		return true
	return WorldMap.structure_type[nidx] != WorldMap.Structure.NONE \
		and WorldMap.structure_type[nidx] != WorldMap.Structure.SHADE_STRUCTURE

## Draws the channel body as a centre block plus an arm toward each
## connected neighbour, at the given half-width.
func _channel_shape(layer: Node2D, idx: int, x: int, y: int, half: float, color: Color) -> void:
	var ox: float = float(x) * T
	var oy: float = float(y) * T
	var c: float = T * 0.5
	var hw: float = half * T
	layer.draw_rect(Rect2(ox + c - hw, oy + c - hw, hw * 2.0, hw * 2.0), color)
	if _connects(idx, 1, 0):
		layer.draw_rect(Rect2(ox + c, oy + c - hw, c, hw * 2.0), color)
	if _connects(idx, -1, 0):
		layer.draw_rect(Rect2(ox, oy + c - hw, c, hw * 2.0), color)
	if _connects(idx, 0, 1):
		layer.draw_rect(Rect2(ox + c - hw, oy + c, hw * 2.0, c), color)
	if _connects(idx, 0, -1):
		layer.draw_rect(Rect2(ox + c - hw, oy, hw * 2.0, c), color)

func _fill_fraction(idx: int) -> float:
	return clampf(WorldMap.water[idx] / maxf(0.001, WorldMap.water_capacity(idx)), 0.0, 1.0)

func _water_color(fill: float) -> Color:
	return WATER_SHALLOW.lerp(WATER_DEEP, clampf(fill, 0.0, 1.0))

func _draw_canal(layer: Node2D, idx: int, x: int, y: int, covered: bool, mountain: bool) -> void:
	# Bed first, slightly wider, so every channel has a visible bank.
	_channel_shape(layer, idx, x, y, CHANNEL_HALF_WIDTH + 0.06, BED_RIM_COLOR)
	_channel_shape(layer, idx, x, y, CHANNEL_HALF_WIDTH, ROCK_CUT_COLOR if mountain else BED_COLOR)

	# Water: the stream widens *and* deepens in colour as the tile fills, so
	# an empty canal (bare bed) and a full one are unmistakable at a glance.
	var fill: float = _fill_fraction(idx)
	if fill > 0.02:
		var wh: float = CHANNEL_HALF_WIDTH * (0.22 + 0.78 * sqrt(fill))
		_channel_shape(layer, idx, x, y, wh, _water_color(fill))

	if covered:
		_draw_cover(layer, idx, x, y, mountain)

## Covered channels get a slab lid with a joint line and a small inspection
## hatch, so they are instantly distinguishable from open ones.
func _draw_cover(layer: Node2D, idx: int, x: int, y: int, mountain: bool) -> void:
	var ox: float = float(x) * T
	var oy: float = float(y) * T
	var c: float = T * 0.5
	var hw: float = (CHANNEL_HALF_WIDTH + 0.06) * T
	var lid: Color = COVER_COLOR if not mountain else Color(0.38, 0.35, 0.33)
	lid.a = 0.82
	# Lid covers the tile centre; the arms stay open so the run still reads
	# as a connected line.
	layer.draw_rect(Rect2(ox + c - hw, oy + c - hw, hw * 2.0, hw * 2.0), lid)
	var line_col: Color = COVER_LINE
	layer.draw_line(Vector2(ox + c - hw, oy + c - hw * 0.34), Vector2(ox + c + hw, oy + c - hw * 0.34), line_col, maxf(1.0, T * 0.045))
	layer.draw_line(Vector2(ox + c - hw, oy + c + hw * 0.34), Vector2(ox + c + hw, oy + c + hw * 0.34), line_col, maxf(1.0, T * 0.045))
	if mountain:
		# Chisel marks: this segment was cut through rock.
		layer.draw_line(Vector2(ox + c - hw * 0.5, oy + c - hw), Vector2(ox + c - hw * 0.2, oy + c - hw * 0.6), line_col, maxf(1.0, T * 0.035))
		layer.draw_line(Vector2(ox + c + hw * 0.2, oy + c + hw * 0.6), Vector2(ox + c + hw * 0.5, oy + c + hw), line_col, maxf(1.0, T * 0.035))

func _draw_gate(layer: Node2D, idx: int, x: int, y: int) -> void:
	_draw_canal(layer, idx, x, y, false, false)
	var ox: float = float(x) * T
	var oy: float = float(y) * T
	var c: float = T * 0.5
	var open: bool = WorldMap.gate_open[idx] == 1
	var post: Color = Color(0.25, 0.22, 0.2)
	var w: float = maxf(2.0, T * 0.09)
	# Two posts either side, plus a sluice bar drawn across when closed.
	layer.draw_rect(Rect2(ox + c - T * 0.42, oy + c - T * 0.16, w, T * 0.32), post)
	layer.draw_rect(Rect2(ox + c + T * 0.42 - w, oy + c - T * 0.16, w, T * 0.32), post)
	if open:
		layer.draw_rect(Rect2(ox + c - T * 0.42, oy + c - T * 0.24, T * 0.84, maxf(2.0, T * 0.07)), Color(0.3, 0.8, 0.4))
	else:
		layer.draw_rect(Rect2(ox + c - T * 0.42, oy + c - T * 0.1, T * 0.84, T * 0.2), Color(0.75, 0.28, 0.24))

func _draw_basin(layer: Node2D, idx: int, x: int, y: int, covered: bool) -> void:
	var ox: float = float(x) * T
	var oy: float = float(y) * T
	var inset: float = T * 0.08
	var full := Rect2(ox + inset, oy + inset, T - inset * 2.0, T - inset * 2.0)
	layer.draw_rect(full, Color(0.30, 0.26, 0.21))
	layer.draw_rect(full, Color(0.16, 0.13, 0.10), false, maxf(1.0, T * 0.06))
	var fill: float = _fill_fraction(idx)
	if fill > 0.01:
		# A basin fills from the middle outward, area scaling with volume.
		var k: float = sqrt(fill)
		var iw: float = (T - inset * 2.0) * k
		layer.draw_rect(Rect2(ox + T * 0.5 - iw * 0.5, oy + T * 0.5 - iw * 0.5, iw, iw), _water_color(fill))
	if covered:
		var lid := Color(0.52, 0.47, 0.40, 0.85)
		layer.draw_rect(full, lid)
		layer.draw_line(full.position, full.position + full.size, COVER_LINE, maxf(1.0, T * 0.05))
		layer.draw_line(Vector2(full.position.x + full.size.x, full.position.y), Vector2(full.position.x, full.position.y + full.size.y), COVER_LINE, maxf(1.0, T * 0.05))

func _draw_well(layer: Node2D, idx: int, x: int, y: int) -> void:
	var center := Vector2(float(x) * T + T * 0.5, float(y) * T + T * 0.5)
	layer.draw_circle(center, T * 0.38, Color(0.42, 0.38, 0.33))
	var fill: float = _fill_fraction(idx)
	layer.draw_circle(center, T * 0.26 * maxf(0.35, sqrt(fill)), _water_color(fill))
	layer.draw_arc(center, T * 0.38, 0.0, TAU, 20, Color(0.22, 0.19, 0.16), maxf(1.0, T * 0.06))

func _draw_shade_structure(layer: Node2D, x: int, y: int) -> void:
	var ox: float = float(x) * T
	var oy: float = float(y) * T
	var inset: float = T * 0.1
	var rect := Rect2(ox + inset, oy + inset, T - inset * 2.0, T - inset * 2.0)
	layer.draw_rect(rect, Color(0.72, 0.62, 0.38, 0.92))
	# Palm-frond thatch over four corner posts.
	var lc := Color(0.45, 0.37, 0.2, 0.9)
	var steps: int = 4
	for i in range(steps + 1):
		var t: float = float(i) / float(steps)
		layer.draw_line(Vector2(rect.position.x, rect.position.y + rect.size.y * t),
			Vector2(rect.position.x + rect.size.x, rect.position.y + rect.size.y * t), lc, maxf(1.0, T * 0.03))
	var post := Color(0.35, 0.27, 0.16)
	var ps: float = maxf(2.0, T * 0.1)
	for corner in [rect.position, Vector2(rect.end.x - ps, rect.position.y), Vector2(rect.position.x, rect.end.y - ps), rect.end - Vector2(ps, ps)]:
		layer.draw_rect(Rect2(corner, Vector2(ps, ps)), post)

func _draw_construction(layer: Node2D, x: int, y: int, progress: float) -> void:
	var ox: float = float(x) * T
	var oy: float = float(y) * T
	var inset: float = T * 0.16
	var rect := Rect2(ox + inset, oy + inset, T - inset * 2.0, T - inset * 2.0)
	layer.draw_rect(rect, Color(0.95, 0.85, 0.35, 0.25))
	layer.draw_rect(rect, Color(0.95, 0.85, 0.35, 0.8), false, maxf(1.0, T * 0.05))
	layer.draw_rect(Rect2(rect.position.x, rect.end.y - rect.size.y * progress, rect.size.x, rect.size.y * progress),
		Color(0.95, 0.8, 0.25, 0.55))

func _draw_flow() -> void:
	if WorldMap.width == 0 or not show_flow:
		return
	var layer: Node2D = flow_layer
	var r: Rect2i = _visible_tile_rect(layer)
	var arrow_col := Color(1, 1, 1, 0.75)
	for y in range(r.position.y, r.position.y + r.size.y + 1):
		for x in range(r.position.x, r.position.x + r.size.x + 1):
			var idx: int = y * WorldMap.width + x
			if WorldMap.structure_type[idx] == WorldMap.Structure.NONE:
				continue
			var v := Vector2(WorldMap.flow_x[idx], WorldMap.flow_y[idx])
			var mag: float = v.length()
			if mag < 0.004:
				continue
			var dir: Vector2 = v / mag
			var center := Vector2(float(x) * T + T * 0.5, float(y) * T + T * 0.5)
			var len: float = T * 0.3 * clampf(mag * 12.0, 0.35, 1.0)
			var tip: Vector2 = center + dir * len
			var back: Vector2 = center - dir * len
			var perp := Vector2(-dir.y, dir.x)
			var w: float = maxf(1.0, T * 0.05)
			layer.draw_line(back, tip, arrow_col, w)
			layer.draw_line(tip, tip - dir * (len * 0.55) + perp * (len * 0.4), arrow_col, w)
			layer.draw_line(tip, tip - dir * (len * 0.55) - perp * (len * 0.4), arrow_col, w)

# ---------------------------------------------------------------------------
# Plants
# ---------------------------------------------------------------------------

func _draw_plants() -> void:
	if WorldMap.width == 0:
		return
	var layer: Node2D = plants_layer
	var r: Rect2i = _visible_tile_rect(layer)
	for idx in PlantSystem.plants.keys():
		var x: int = idx % WorldMap.width
		var y: int = idx / WorldMap.width
		if x < r.position.x or x > r.position.x + r.size.x or y < r.position.y or y > r.position.y + r.size.y:
			continue
		var p: PlantInstance = PlantSystem.plants[idx]
		_draw_plant(layer, p, x, y)

func _draw_plant(layer: Node2D, p: PlantInstance, x: int, y: int) -> void:
	var center := Vector2(float(x) * T + T * 0.5, float(y) * T + T * 0.5)
	var growth: float = p.get_growth_fraction()
	var s: float = T * 0.5 * lerpf(0.3, p.data.mature_scale, growth)
	# Sick plants brown off toward straw colour.
	var col: Color = p.data.color.lerp(Color(0.58, 0.45, 0.24), 1.0 - p.health)
	var dark: Color = col.darkened(0.35)
	var shadow := Color(0, 0, 0, 0.18)

	match p.data.category:
		"Tree":
			layer.draw_circle(center + Vector2(s * 0.15, s * 0.2), s * 0.75, shadow)
			var trunk := Color(0.38, 0.27, 0.17)
			layer.draw_line(center + Vector2(0, s * 0.45), center, trunk, maxf(1.5, s * 0.18))
			if p.data.id == &"date_palm":
				# Radiating fronds: the silhouette that makes a palm a palm.
				for i in range(9):
					var a: float = TAU * float(i) / 9.0 + growth
					var tipv: Vector2 = center + Vector2(cos(a), sin(a) * 0.75) * s
					layer.draw_line(center, tipv, col if i % 2 == 0 else dark, maxf(1.0, s * 0.14))
					layer.draw_line(tipv, tipv - Vector2(cos(a), sin(a) * 0.75) * (s * 0.3) + Vector2(-sin(a), cos(a)) * (s * 0.18), dark, maxf(1.0, s * 0.08))
			else:
				for off in [Vector2(0, -s * 0.25), Vector2(-s * 0.42, 0), Vector2(s * 0.42, 0), Vector2(0, s * 0.05)]:
					layer.draw_circle(center + off, s * 0.5, col)
				layer.draw_circle(center + Vector2(-s * 0.18, -s * 0.35), s * 0.3, col.lightened(0.12))
		"Shrub":
			layer.draw_circle(center + Vector2(s * 0.1, s * 0.15), s * 0.6, shadow)
			for off in [Vector2(-s * 0.3, s * 0.1), Vector2(s * 0.3, s * 0.1), Vector2(0, -s * 0.2)]:
				layer.draw_circle(center + off, s * 0.42, col)
		"Herb":
			for i in range(5):
				var a: float = -PI * 0.5 + (float(i) - 2.0) * 0.36
				layer.draw_line(center + Vector2(0, s * 0.4), center + Vector2(0, s * 0.4) + Vector2(cos(a), sin(a)) * s * 0.85, col, maxf(1.0, s * 0.13))
		"Flower":
			layer.draw_line(center + Vector2(0, s * 0.5), center, dark, maxf(1.0, s * 0.12))
			for i in range(5):
				var a: float = TAU * float(i) / 5.0
				layer.draw_circle(center + Vector2(cos(a), sin(a)) * s * 0.32, s * 0.25, col)
			layer.draw_circle(center, s * 0.2, col.lightened(0.35))
		_: # Crop
			for i in range(4):
				var bx: float = center.x + (float(i) - 1.5) * s * 0.36
				layer.draw_line(Vector2(bx, center.y + s * 0.45), Vector2(bx, center.y - s * 0.5), col, maxf(1.0, s * 0.14))

# ---------------------------------------------------------------------------
# Cursor / selection
# ---------------------------------------------------------------------------

func _draw_selection() -> void:
	if WorldMap.width == 0:
		return
	var layer: Node2D = selection_layer
	if hovered_tile >= 0:
		var x: int = hovered_tile % WorldMap.width
		var y: int = hovered_tile / WorldMap.width
		var rect := Rect2(float(x) * T, float(y) * T, T, T)
		var col := Color(1, 1, 1, 0.55)
		if ghost_structure >= 0:
			# Green means this tool can build here, red means it cannot --
			# the reason is spelled out in the build menu.
			col = Color(0.35, 0.95, 0.45, 0.85) if BuildSystem.can_place(hovered_tile, ghost_structure) else Color(0.95, 0.3, 0.25, 0.85)
			var resolved: int = BuildSystem.resolve_structure(hovered_tile, ghost_structure)
			if resolved == WorldMap.Structure.CANAL_MOUNTAIN and ghost_structure != WorldMap.Structure.CANAL_MOUNTAIN:
				# Signal the automatic switch to a rock tunnel.
				layer.draw_rect(rect, Color(0.4, 0.75, 0.95, 0.18))
		layer.draw_rect(rect, col, false, maxf(1.5, T * 0.08))
	if selected_tile >= 0:
		var x: int = selected_tile % WorldMap.width
		var y: int = selected_tile / WorldMap.width
		layer.draw_rect(Rect2(float(x) * T, float(y) * T, T, T), Color(1, 0.95, 0.5, 0.95), false, maxf(1.5, T * 0.08))

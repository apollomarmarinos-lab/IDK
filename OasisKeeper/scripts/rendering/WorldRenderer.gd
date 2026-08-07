extends Node2D
## Draws the simulation grid as a handful of low-resolution (one pixel per
## tile) images blown up by GameConfig.TILE_PIXEL_SIZE. This is what makes
## rendering a 200x140+ tile world cheap: painting an Image is a tight loop
## over packed arrays, not thousands of individual Nodes or draw calls.
##
## Layers, bottom to top: terrain (static) -> moisture/water tint -> shade
## tint -> plants (MultiMesh) -> buildings (immediate _draw).

@onready var terrain_sprite: Sprite2D = $TerrainSprite
@onready var water_sprite: Sprite2D = $MoistureWaterSprite
@onready var shade_sprite: Sprite2D = $ShadeSprite
@onready var underground_sprite: Sprite2D = $UndergroundSprite
@onready var plant_multimesh: MultiMeshInstance2D = $PlantMultiMesh
@onready var buildings_layer: Node2D = $BuildingsLayer
@onready var selection_marker: Node2D = $SelectionMarker
@onready var refresh_timer: Timer = $RefreshTimer

var show_underground: bool = false
var selected_tile: int = -1
var hovered_tile: int = -1

var _terrain_image: Image
var _water_image: Image
var _shade_image: Image
var _underground_image: Image

const SAND_COLOR := Color(0.85, 0.72, 0.45)
const ROCK_COLOR := Color(0.42, 0.38, 0.34)
const WET_SOIL_COLOR := Color(0.35, 0.26, 0.15)
const OPEN_WATER_COLOR := Color(0.15, 0.55, 0.75)
const WATER_HOLDING_STRUCTURES: Array[int] = [1, 3, 4, 5, 7] # CANAL_OPEN, CANAL_MOUNTAIN_TAP, GATE, STORAGE_TANK, WELL_OUTLET

func _ready() -> void:
	add_to_group("world_renderer")
	scale = Vector2(GameConfig.TILE_PIXEL_SIZE, GameConfig.TILE_PIXEL_SIZE)
	for s: Sprite2D in [terrain_sprite, water_sprite, shade_sprite, underground_sprite]:
		s.centered = false
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	EventBus.world_generated.connect(_on_world_generated)
	EventBus.tile_changed.connect(_on_tile_changed)
	EventBus.plant_planted.connect(_on_plants_dirty)
	EventBus.plant_removed.connect(_on_plants_dirty)
	EventBus.plant_stage_changed.connect(_on_plants_dirty)
	EventBus.day_passed.connect(_on_plants_dirty)
	refresh_timer.timeout.connect(_refresh_dynamic_layers)
	buildings_layer.draw.connect(_draw_buildings.bind(buildings_layer))
	selection_marker.draw.connect(_draw_selection.bind(selection_marker))

func _on_world_generated() -> void:
	var w: int = WorldMap.width
	var h: int = WorldMap.height
	_terrain_image = Image.create(w, h, false, Image.FORMAT_RGB8)
	_water_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_shade_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
	_underground_image = Image.create(w, h, false, Image.FORMAT_RGBA8)

	for y in range(h):
		for x in range(w):
			var idx: int = y * w + x
			var base: Color = ROCK_COLOR if WorldMap.terrain_type[idx] == WorldMap.Terrain.ROCK else SAND_COLOR
			var elevation_norm: float = clampf(WorldMap.elevation[idx] / (GameConfig.MOUNTAIN_HEIGHT_SCALE + 4.0), -0.3, 1.0)
			var shaded: Color = base.lerp(Color.BLACK, maxf(0.0, elevation_norm) * 0.25)
			shaded = shaded.lerp(Color.WHITE, maxf(0.0, -elevation_norm) * 0.15)
			if WorldMap.aquifer_potential[idx] > 0.0:
				shaded = shaded.lerp(Color(0.3, 0.55, 0.6), 0.15)
			_terrain_image.set_pixel(x, y, shaded)

	terrain_sprite.texture = ImageTexture.create_from_image(_terrain_image)
	_refresh_dynamic_layers()
	_rebuild_plant_multimesh()
	buildings_layer.queue_redraw()

func _on_tile_changed(_idx: int) -> void:
	buildings_layer.queue_redraw()

func _on_plants_dirty(_a = null, _b = null, _c = null) -> void:
	_rebuild_plant_multimesh()

func _refresh_dynamic_layers() -> void:
	if _water_image == null:
		return
	var w: int = WorldMap.width
	var h: int = WorldMap.height
	for y in range(h):
		for x in range(w):
			var idx: int = y * w + x
			# Moisture/water tint: dry sand -> darker wet soil -> open water blue.
			var moisture_frac: float = clampf(WorldMap.soil_moisture[idx] / GameConfig.SOIL_WATER_CAPACITY, 0.0, 1.0)
			var col: Color = Color(0, 0, 0, 0)
			if moisture_frac > 0.01:
				col = WET_SOIL_COLOR
				col.a = moisture_frac * 0.65
			var struct_type: int = WorldMap.structure_type[idx]
			if WATER_HOLDING_STRUCTURES.has(struct_type):
				var cap: float = WorldMap.water_capacity(idx)
				var water_frac: float = clampf(WorldMap.surface_water[idx] / maxf(cap, 0.001), 0.0, 1.0)
				var wcol: Color = OPEN_WATER_COLOR
				wcol.a = 0.35 + water_frac * 0.65
				col = wcol
			_water_image.set_pixel(x, y, col)

			var shade_v: float = WorldMap.shade[idx]
			var scol: Color = Color(0.05, 0.08, 0.12, shade_v * 0.55)
			_shade_image.set_pixel(x, y, scol)

			var ucol: Color = Color(0, 0, 0, 0)
			if struct_type == WorldMap.Structure.CANAL_UNDERGROUND:
				var ufrac: float = clampf(WorldMap.underground_water[idx] / GameConfig.TILE_WATER_CAPACITY, 0.0, 1.0)
				ucol = Color(0.6, 0.45, 0.2, 0.5 + ufrac * 0.4)
			_underground_image.set_pixel(x, y, ucol)

	water_sprite.texture = ImageTexture.create_from_image(_water_image)
	shade_sprite.texture = ImageTexture.create_from_image(_shade_image)
	underground_sprite.texture = ImageTexture.create_from_image(_underground_image)
	underground_sprite.visible = show_underground

func set_underground_visible(v: bool) -> void:
	show_underground = v
	if underground_sprite:
		underground_sprite.visible = v

func _rebuild_plant_multimesh() -> void:
	if plant_multimesh.multimesh == null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_2D
		mm.use_colors = true
		var mesh := QuadMesh.new()
		mesh.size = Vector2(0.9, 0.9)
		mm.mesh = mesh
		plant_multimesh.multimesh = mm
	var mm: MultiMesh = plant_multimesh.multimesh
	var count: int = PlantSystem.plants.size()
	mm.instance_count = count
	var i: int = 0
	for idx in PlantSystem.plants.keys():
		var p: PlantInstance = PlantSystem.plants[idx]
		var x: int = idx % WorldMap.width
		var y: int = idx / WorldMap.width
		var growth: float = p.get_growth_fraction()
		var s: float = lerpf(0.35, p.data.mature_scale, growth)
		var xform := Transform2D(0.0, Vector2(s, s), 0.0, Vector2(float(x) + 0.5, float(y) + 0.5))
		mm.set_instance_transform_2d(i, xform)
		var col: Color = p.data.color.lerp(Color(0.55, 0.4, 0.22), 1.0 - p.health)
		mm.set_instance_color(i, col)
		i += 1

func _draw_buildings(layer: Node2D) -> void:
	for idx in BuildSystem.get_pending_tiles().keys():
		var x: int = idx % WorldMap.width
		var y: int = idx / WorldMap.width
		var progress: float = BuildSystem.get_pending_progress(idx)
		layer.draw_rect(Rect2(float(x) + 0.15, float(y) + 0.15, 0.7, 0.7), Color(1, 1, 1, 0.35), false, 0.08)
		layer.draw_rect(Rect2(float(x) + 0.15, float(y) + 0.75 - 0.6 * progress, 0.7, 0.6 * progress), Color(1, 1, 0.3, 0.5), true)

	var w: int = WorldMap.width
	var h: int = WorldMap.height
	for y in range(h):
		for x in range(w):
			var idx: int = y * w + x
			var s: int = WorldMap.structure_type[idx]
			if s == WorldMap.Structure.NONE:
				continue
			var center := Vector2(float(x) + 0.5, float(y) + 0.5)
			match s:
				WorldMap.Structure.GATE:
					var open: bool = WorldMap.gate_open[idx] == 1
					layer.draw_rect(Rect2(float(x) + 0.2, float(y) + 0.2, 0.6, 0.6), Color(0.2, 0.85, 0.3) if open else Color(0.85, 0.2, 0.2))
				WorldMap.Structure.STORAGE_TANK:
					layer.draw_circle(center, 0.42, Color(0.3, 0.55, 0.75))
					layer.draw_arc(center, 0.42, 0, TAU, 16, Color(0.15, 0.3, 0.4), 0.06)
				WorldMap.Structure.SHADE_STRUCTURE:
					layer.draw_rect(Rect2(float(x) + 0.12, float(y) + 0.12, 0.76, 0.76), Color(0.75, 0.65, 0.35, 0.9))
					layer.draw_line(Vector2(float(x) + 0.12, float(y) + 0.12), Vector2(float(x) + 0.88, float(y) + 0.88), Color(0.4, 0.35, 0.15), 0.05)
					layer.draw_line(Vector2(float(x) + 0.88, float(y) + 0.12), Vector2(float(x) + 0.12, float(y) + 0.88), Color(0.4, 0.35, 0.15), 0.05)
				WorldMap.Structure.WELL_OUTLET:
					var pts := PackedVector2Array([center + Vector2(0, -0.4), center + Vector2(0.4, 0), center + Vector2(0, 0.4), center + Vector2(-0.4, 0)])
					layer.draw_colored_polygon(pts, Color(0.25, 0.75, 0.85))
				WorldMap.Structure.CANAL_MOUNTAIN_TAP:
					layer.draw_rect(Rect2(float(x) + 0.1, float(y) + 0.1, 0.8, 0.8), Color(0.35, 0.65, 0.75, 0.55))

func _draw_selection(layer: Node2D) -> void:
	if selected_tile >= 0:
		var x: int = selected_tile % WorldMap.width
		var y: int = selected_tile / WorldMap.width
		layer.draw_rect(Rect2(x, y, 1, 1), Color(1, 1, 1, 0.9), false, 0.08)
	if hovered_tile >= 0 and hovered_tile != selected_tile:
		var x: int = hovered_tile % WorldMap.width
		var y: int = hovered_tile / WorldMap.width
		layer.draw_rect(Rect2(x, y, 1, 1), Color(1, 1, 1, 0.4), false, 0.05)

func set_selected_tile(idx: int) -> void:
	selected_tile = idx
	selection_marker.queue_redraw()

func set_hovered_tile(idx: int) -> void:
	hovered_tile = idx
	selection_marker.queue_redraw()

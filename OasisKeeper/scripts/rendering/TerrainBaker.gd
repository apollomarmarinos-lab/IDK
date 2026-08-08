class_name TerrainBaker
extends RefCounted
## Bakes the static terrain into one image at TERRAIN_DETAIL sub-pixels per
## tile, so the ground has visible grain instead of reading as flat blocks
## when tiles are drawn 24px across.
##
## Pixels are written into a raw PackedByteArray and handed to
## Image.create_from_data in one go -- roughly an order of magnitude faster
## than calling set_pixel per pixel, which matters at ~350k sub-pixels.

const TERRAIN_BASE_COLORS := {
	Tiles.Terrain.DUNE_SAND: Color(0.88, 0.76, 0.51),
	Tiles.Terrain.DESERT_PAVEMENT: Color(0.74, 0.63, 0.46),
	Tiles.Terrain.ALLUVIUM: Color(0.62, 0.52, 0.36),
	Tiles.Terrain.SCREE: Color(0.56, 0.50, 0.44),
	Tiles.Terrain.ROCK: Color(0.45, 0.42, 0.40),
}

static func bake(width: int, height: int) -> Image:
	var detail: int = GameConfig.TERRAIN_DETAIL
	var img_w: int = width * detail
	var img_h: int = height * detail

	var grain := FastNoiseLite.new()
	grain.seed = 1337
	grain.frequency = 0.35
	var rock_grain := FastNoiseLite.new()
	rock_grain.seed = 4242
	rock_grain.noise_type = FastNoiseLite.TYPE_CELLULAR
	rock_grain.frequency = 0.12

	var data := PackedByteArray()
	data.resize(img_w * img_h * 3)

	# Precompute a cheap hillshade from the elevation gradient so ridges,
	# wadi banks and dune crests are legible as landforms.
	for ty in range(height):
		for tx in range(width):
			var idx: int = ty * width + tx
			var terrain: int = WorldMap.terrain_type[idx]
			var base: Color = TERRAIN_BASE_COLORS[terrain]

			var shade_amount: float = _hillshade(width, height, tx, ty)
			# Wet-looking silt in the wadi bottoms.
			if terrain == Tiles.Terrain.ALLUVIUM:
				base = base.lerp(Color(0.45, 0.38, 0.27), WorldMap.wadi_strength[idx] * 0.5)

			for sy in range(detail):
				for sx in range(detail):
					var px: int = tx * detail + sx
					var py: int = ty * detail + sy
					var fx: float = float(px)
					var fy: float = float(py)
					var g: float
					if terrain == Tiles.Terrain.ROCK or terrain == Tiles.Terrain.SCREE:
						g = rock_grain.get_noise_2d(fx, fy) * 0.10
					else:
						g = grain.get_noise_2d(fx, fy) * 0.05
					var c: Color = base
					c = c.lerp(Color.WHITE, maxf(0.0, shade_amount) * 0.35)
					c = c.lerp(Color.BLACK, maxf(0.0, -shade_amount) * 0.40)
					c.r = clampf(c.r + g, 0.0, 1.0)
					c.g = clampf(c.g + g, 0.0, 1.0)
					c.b = clampf(c.b + g, 0.0, 1.0)
					var o: int = (py * img_w + px) * 3
					data[o] = int(c.r * 255.0)
					data[o + 1] = int(c.g * 255.0)
					data[o + 2] = int(c.b * 255.0)

	return Image.create_from_data(img_w, img_h, false, Image.FORMAT_RGB8, data)

## Lambertian-ish shading from a fixed north-west sun.
static func _hillshade(width: int, height: int, x: int, y: int) -> float:
	var xl: int = maxi(0, x - 1)
	var xr: int = mini(width - 1, x + 1)
	var yu: int = maxi(0, y - 1)
	var yd: int = mini(height - 1, y + 1)
	var dzdx: float = WorldMap.elevation[y * width + xr] - WorldMap.elevation[y * width + xl]
	var dzdy: float = WorldMap.elevation[yd * width + x] - WorldMap.elevation[yu * width + x]
	# Light from the north-west: illumination rises as the slope faces it.
	return clampf((-dzdx - dzdy) * 0.22, -1.0, 1.0)

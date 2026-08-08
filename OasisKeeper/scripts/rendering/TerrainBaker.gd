class_name TerrainBaker
extends RefCounted
## Builds the static terrain visuals.
##
## `bake()` works at TERRAIN_DETAIL sub-pixels per tile and combines three
## things, each solving a different scale of the picture:
##
##   - Large scale: hillshading from the elevation gradient, so ridges, wadi
##     banks and the valley basin are legible as landform.
##   - Mid scale: flat per-tile material colour with a small deterministic
##     per-tile jitter, sampled without interpolation so tiles stay crisply
##     bounded. This is a tile game and it should look like one.
##   - Fine scale: one noise sample per sub-pixel, weighted per material, so
##     rock looks fractured and sand looks rippled.
##
## Everything is written straight into a PackedByteArray. Image.set_pixel
## per sub-pixel is roughly an order of magnitude slower and would make this
## a visible startup hitch.
##
## `make_grain_texture()` additionally supplies a small seamless tile that
## the renderer repeats over the map with multiply blending, which keeps
## texture crisp when the player zooms in past the baked resolution.

const TERRAIN_BASE_COLORS := {
	Tiles.Terrain.DUNE_SAND: Color(0.90, 0.78, 0.54),
	Tiles.Terrain.DESERT_PAVEMENT: Color(0.78, 0.66, 0.47),
	Tiles.Terrain.ALLUVIUM: Color(0.64, 0.54, 0.34),
	Tiles.Terrain.SCREE: Color(0.62, 0.56, 0.49),
	Tiles.Terrain.ROCK: Color(0.46, 0.43, 0.42),
}

const GRAIN_TEXTURE_SIZE: int = 256
## Relief exaggeration. The valley is only a few units deep, so without a
## healthy multiplier its shape is invisible.
const HILLSHADE_STRENGTH: float = 0.24
const HILLSHADE_LIGHT := Vector2(-0.7, -0.7) ## sun from the north-west

static func bake(width: int, height: int) -> Image:
	var detail: int = GameConfig.TERRAIN_DETAIL
	var size: int = width * height

	# --- tile-resolution fields -------------------------------------------
	var cr := PackedFloat32Array()
	var cg := PackedFloat32Array()
	var cb := PackedFloat32Array()
	cr.resize(size)
	cg.resize(size)
	cb.resize(size)
	for idx in range(size):
		var c: Color = TERRAIN_BASE_COLORS[WorldMap.terrain_type[idx]]
		if WorldMap.terrain_type[idx] == Tiles.Terrain.ALLUVIUM:
			c = c.lerp(Color(0.54, 0.44, 0.28), WorldMap.wadi_strength[idx] * 0.5)
		var elev_norm: float = clampf(WorldMap.elevation[idx] / GameConfig.MOUNTAIN_HEIGHT_SCALE, 0.0, 1.0)
		c = c.lerp(Color(0.86, 0.84, 0.80), elev_norm * 0.25)
		cr[idx] = c.r
		cg[idx] = c.g
		cb[idx] = c.b

	var shade := PackedFloat32Array()
	shade.resize(size)
	for y in range(height):
		for x in range(width):
			shade[y * width + x] = _hillshade(width, height, x, y)

	# Per-tile roughness drives how strong the fine grain is.
	var rough := PackedFloat32Array()
	rough.resize(size)
	for idx in range(size):
		match WorldMap.terrain_type[idx]:
			Tiles.Terrain.ROCK:
				rough[idx] = 1.0
			Tiles.Terrain.SCREE:
				rough[idx] = 0.7
			Tiles.Terrain.ALLUVIUM:
				rough[idx] = 0.25
			_:
				rough[idx] = 0.35

	# --- sub-pixel pass ----------------------------------------------------
	var rock_noise := FastNoiseLite.new()
	rock_noise.seed = 4242
	rock_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	rock_noise.frequency = 0.10
	rock_noise.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB

	var img_w: int = width * detail
	var img_h: int = height * detail
	var inv: float = 1.0 / float(detail)
	var data := PackedByteArray()
	data.resize(img_w * img_h * 3)

	var o: int = 0
	for py in range(img_h):
		var ty: int = mini(int(float(py) * inv), height - 1)
		var row: int = ty * width
		for px in range(img_w):
			var tx: int = mini(int(float(px) * inv), width - 1)
			var idx: int = row + tx

			# Deliberately sampled per tile, not interpolated. This is a tile
			# game: flat, crisply-bounded tiles read far better at 24px than
			# a smoothly blended heightfield, which just looks like mush.
			var r: float = cr[idx]
			var g: float = cg[idx]
			var b: float = cb[idx]
			var sh: float = shade[idx]

			# Per-tile jitter so neighbouring tiles of the same material are
			# still individually visible -- gives the ground a mosaic feel.
			var j: float = _tile_jitter(tx, ty) * 0.016
			r += j
			g += j
			b += j

			if sh > 0.0:
				var k: float = sh * 0.45
				r += (1.00 - r) * k
				g += (0.98 - g) * k
				b += (0.90 - b) * k
			else:
				var k2: float = -sh * 0.50
				r += (0.20 - r) * k2
				g += (0.17 - g) * k2
				b += (0.19 - b) * k2

			var n: float = rock_noise.get_noise_2d(float(px), float(py)) * rough[idx] * 0.20
			r = clampf(r + n, 0.0, 1.0)
			g = clampf(g + n, 0.0, 1.0)
			b = clampf(b + n, 0.0, 1.0)

			data[o] = int(r * 255.0)
			data[o + 1] = int(g * 255.0)
			data[o + 2] = int(b * 255.0)
			o += 3

	return Image.create_from_data(img_w, img_h, false, Image.FORMAT_RGB8, data)

## Cheap deterministic per-tile hash in [-1, 1].
static func _tile_jitter(x: int, y: int) -> float:
	var h: int = (x * 73856093) ^ (y * 19349663)
	return float(h & 1023) / 511.5 - 1.0

## Seamless multiply-blend grain: values run from slightly dark up to white,
## so tiling it over the terrain darkens irregularly without tinting it.
static func make_grain_texture() -> ImageTexture:
	var n := FastNoiseLite.new()
	n.seed = 1337
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.frequency = 0.10
	n.fractal_octaves = 3
	var fine := FastNoiseLite.new()
	fine.seed = 99
	fine.frequency = 0.45

	var s: int = GRAIN_TEXTURE_SIZE
	var data := PackedByteArray()
	data.resize(s * s * 3)
	for y in range(s):
		for x in range(s):
			var v: float = _seamless(n, x, y, s) * 0.65 + _seamless(fine, x, y, s) * 0.35
			var lum: float = clampf(0.88 + v * 0.12, 0.0, 1.0)
			var o: int = (y * s + x) * 3
			var b: int = int(lum * 255.0)
			data[o] = b
			data[o + 1] = b
			data[o + 2] = b
	return ImageTexture.create_from_image(Image.create_from_data(s, s, false, Image.FORMAT_RGB8, data))

## Bilinear cross-fade of four wrapped samples, which makes any noise
## function tile seamlessly.
static func _seamless(n: FastNoiseLite, x: int, y: int, s: int) -> float:
	var fx: float = float(x)
	var fy: float = float(y)
	var fs: float = float(s)
	var u: float = fx / fs
	var v: float = fy / fs
	var a: float = n.get_noise_2d(fx, fy)
	var b: float = n.get_noise_2d(fx - fs, fy)
	var c: float = n.get_noise_2d(fx, fy - fs)
	var d: float = n.get_noise_2d(fx - fs, fy - fs)
	return lerpf(lerpf(a, b, u), lerpf(c, d, u), v)

static func _box_blur(src: PackedFloat32Array, width: int, height: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(src.size())
	for y in range(height):
		for x in range(width):
			var total: float = 0.0
			var count: int = 0
			for dy in range(-1, 2):
				var ny: int = y + dy
				if ny < 0 or ny >= height:
					continue
				for dx in range(-1, 2):
					var nx: int = x + dx
					if nx < 0 or nx >= width:
						continue
					total += src[ny * width + nx]
					count += 1
			out[y * width + x] = total / float(count)
	return out

## Lambertian-ish shading from the elevation gradient.
static func _hillshade(width: int, height: int, x: int, y: int) -> float:
	var xl: int = maxi(0, x - 1)
	var xr: int = mini(width - 1, x + 1)
	var yu: int = maxi(0, y - 1)
	var yd: int = mini(height - 1, y + 1)
	var dzdx: float = (WorldMap.elevation[y * width + xr] - WorldMap.elevation[y * width + xl]) * 0.5
	var dzdy: float = (WorldMap.elevation[yd * width + x] - WorldMap.elevation[yu * width + x]) * 0.5
	var lit: float = dzdx * HILLSHADE_LIGHT.x + dzdy * HILLSHADE_LIGHT.y
	return clampf(lit * HILLSHADE_STRENGTH, -1.0, 1.0)

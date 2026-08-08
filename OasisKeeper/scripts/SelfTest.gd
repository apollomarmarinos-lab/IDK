class_name SelfTest
extends Node
## Headless smoke test. Run with:
##   godot --headless --path OasisKeeper --quit-after 3000 -- --sim-selftest
##
## Digs a tunnel from an aquifer body out through the rock, continues as an
## open canal into the valley, plants a date palm beside it, and exercises
## gates and every storage type -- then reports water levels along the run
## so you can verify water actually flows tile to tile and downhill.

var _frame: int = 0
var _chain: PackedInt32Array = PackedInt32Array()
var _covered_chain: PackedInt32Array = PackedInt32Array()
var _source_idx: int = -1
var _aquifer_body: int = -1
var _gate_idx: int = -1
var _gate_placed: bool = false
var _gate_toggled: bool = false

static func run(host: Node) -> void:
	var t := SelfTest.new()
	host.add_child(t)

func _ready() -> void:
	_build()
	EventBus.plant_died.connect(func(idx, id): print("SELFTEST plant_died: ", id))
	EventBus.plant_harvested.connect(func(idx, id, amount): print("SELFTEST harvested %.1f %s" % [amount, id]))

func _build() -> void:
	# 1. Find an aquifer body inside the rock.
	for i in range(WorldMap.width * WorldMap.height):
		if WorldMap.has_aquifer(i):
			_source_idx = i
			_aquifer_body = WorldMap.aquifer_id[i]
			break
	if _source_idx < 0:
		print("SELFTEST FAIL: no aquifer generated")
		return
	var c: Vector2i = WorldMap.coords_of(_source_idx)
	print("SELFTEST aquifer body %d at %s, volume %.0f/%.0f" % [
		_aquifer_body, c, WorldMap.aquifer_volume[_aquifer_body], WorldMap.aquifer_max_volume[_aquifer_body]])

	# 2. Dig from it toward the valley centre. The same canal tool is used
	#    the whole way; BuildSystem auto-morphs rock tiles into tunnel.
	_chain = _dig_chain(c, WorldMap.Structure.CANAL_OPEN, "open")
	if _chain.size() > 2:
		_gate_idx = _chain[_chain.size() - 3]

	# 2b. An identical run a few rows away, but covered, so the two can be
	#     compared directly: same source, same length, only evaporation
	#     differs.
	var alt: Vector2i = _find_aquifer_near_row(c.y + 4)
	if alt.x >= 0:
		_covered_chain = _dig_chain(alt, WorldMap.Structure.CANAL_COVERED, "covered")

	# 3. Plant a date palm beside the downstream end of the canal.
	if _chain.size() > 0:
		var last: int = _chain[_chain.size() - 1]
		var buf := PackedInt32Array([0, 0, 0, 0])
		var n: int = WorldMap.get_neighbors4(last, buf)
		for k in range(n):
			if PlantSystem.can_plant(buf[k], &"date_palm"):
				PlantSystem.plant(buf[k], &"date_palm")
				print("SELFTEST planted date_palm at ", WorldMap.coords_of(buf[k]))
				break

	# 4. Storage + shade, out on the valley floor.
	var vx: int = WorldMap.width / 2
	var vy: int = WorldMap.height / 2
	print("SELFTEST reservoir -> ", BuildSystem.place(WorldMap.index_of(vx, vy), WorldMap.Structure.RESERVOIR))
	print("SELFTEST cistern   -> ", BuildSystem.place(WorldMap.index_of(vx + 2, vy), WorldMap.Structure.CISTERN))
	print("SELFTEST shade     -> ", BuildSystem.place(WorldMap.index_of(vx + 4, vy), WorldMap.Structure.SHADE_STRUCTURE))

	# 5. A well, wherever groundwater actually exists.
	var gw_tiles: int = 0
	var well_placed: bool = false
	for i in range(WorldMap.width * WorldMap.height):
		if WorldMap.rare_groundwater[i] > 0.0:
			gw_tiles += 1
			if not well_placed and BuildSystem.can_place(i, WorldMap.Structure.WELL):
				well_placed = BuildSystem.place(i, WorldMap.Structure.WELL)
				print("SELFTEST well at %s -> %s" % [WorldMap.coords_of(i), well_placed])
	print("SELFTEST groundwater tiles: %d, well placed: %s" % [gw_tiles, well_placed])
	_report_world_stats()

## Digs a run of `requested` canal from `start` outward toward the valley,
## stopping once it is well clear of the range. Returns the tile chain.
func _dig_chain(start: Vector2i, requested: int, label: String) -> PackedInt32Array:
	var chain := PackedInt32Array()
	var step: int = 1 if start.x < WorldMap.width / 2 else -1
	var mountain_tiles: int = 0
	var valley_tiles: int = 0
	for i in range(0, 60):
		var x: int = start.x + step * i
		if not WorldMap.in_bounds(x, start.y):
			break
		var idx: int = WorldMap.index_of(x, start.y)
		if not BuildSystem.place(idx, requested):
			print("SELFTEST %s placement refused at %s: %s" % [
				label, WorldMap.coords_of(idx), BuildSystem.placement_hint(idx, requested)])
			break
		chain.append(idx)
		if WorldMap.is_mountain(idx):
			mountain_tiles += 1
		else:
			valley_tiles += 1
			if valley_tiles > 14:
				break
	print("SELFTEST %s run: %d tiles (%d tunnel through rock, %d in valley)" % [
		label, chain.size(), mountain_tiles, valley_tiles])
	return chain

func _find_aquifer_near_row(row: int) -> Vector2i:
	for dy in range(0, 12):
		for sign in [1, -1]:
			var y: int = row + dy * sign
			if y < 0 or y >= WorldMap.height:
				continue
			for x in range(WorldMap.width):
				var idx: int = WorldMap.index_of(x, y)
				if WorldMap.has_aquifer(idx) and WorldMap.structure_type[idx] == WorldMap.Structure.NONE:
					return Vector2i(x, y)
	return Vector2i(-1, -1)

func _report_world_stats() -> void:
	var counts := {}
	var aquifer_tiles: int = 0
	for i in range(WorldMap.width * WorldMap.height):
		var t: int = WorldMap.terrain_type[i]
		counts[t] = counts.get(t, 0) + 1
		if WorldMap.has_aquifer(i):
			aquifer_tiles += 1
	var names := ["dune sand", "pavement", "alluvium", "scree", "rock"]
	var parts: Array[String] = []
	for t in range(names.size()):
		parts.append("%s %.1f%%" % [names[t], float(counts.get(t, 0)) / float(WorldMap.width * WorldMap.height) * 100.0])
	print("SELFTEST terrain: ", ", ".join(parts))
	print("SELFTEST aquifer bodies: %d covering %d rock tiles" % [WorldMap.aquifer_volume.size(), aquifer_tiles])
	var oasis_list: Array[String] = []
	for o in WorldMap.oases:
		oasis_list.append(str(WorldMap.coords_of(o)))
	print("SELFTEST oases: %d at %s" % [WorldMap.oases.size(), ", ".join(oasis_list)])
	_test_terraform()

## Exercises height levels and terracing: a valley tile should raise and dig,
## rock and foothills should refuse.
func _test_terraform() -> void:
	var valley: int = -1
	var rock: int = -1
	var scree: int = -1
	for i in range(WorldMap.width * WorldMap.height):
		if valley < 0 and WorldMap.terrain_type[i] == WorldMap.Terrain.DUNE_SAND:
			valley = i
		elif rock < 0 and WorldMap.terrain_type[i] == WorldMap.Terrain.ROCK:
			rock = i
		elif scree < 0 and WorldMap.terrain_type[i] == WorldMap.Terrain.SCREE:
			scree = i
		if valley >= 0 and rock >= 0 and scree >= 0:
			break

	if valley >= 0:
		var before: int = WorldMap.height_level(valley)
		var raised: bool = WorldMap.apply_terraform(valley, 1)
		var after_raise: int = WorldMap.height_level(valley)
		WorldMap.apply_terraform(valley, -2)
		var after_dig: int = WorldMap.height_level(valley)
		print("SELFTEST terraform valley %s: ok=%s level %d -> %d -> %d" % [
			WorldMap.coords_of(valley), raised, before, after_raise, after_dig])
		# Walk it to the raise limit and confirm the clamp holds.
		var guard: int = 0
		while WorldMap.apply_terraform(valley, 1) and guard < 100:
			guard += 1
		print("SELFTEST terraform clamp: offset=%d (max %d), refused=%s" % [
			WorldMap.terraform_offset[valley], GameConfig.TERRAFORM_MAX_RAISE,
			WorldMap.terraform_hint(valley, 1)])
	# Terrace a visible staircase beside the first oasis so the repaint path
	# gets exercised and the result can be eyeballed in a screenshot.
	if not WorldMap.oases.is_empty():
		var o: Vector2i = WorldMap.coords_of(WorldMap.oases[0])
		var applied: int = 0
		for step in range(-6, 7):
			for band in range(-3, 4):
				var tx: int = o.x + step
				var ty: int = o.y + 14 + band
				if not WorldMap.in_bounds(tx, ty):
					continue
				var levels: int = step # a ramp from -6 up to +6
				var tidx: int = WorldMap.index_of(tx, ty)
				if WorldMap.can_terraform(tidx, levels) and WorldMap.apply_terraform(tidx, levels):
					applied += 1
		print("SELFTEST terraced staircase near oasis: %d tiles" % applied)

	if rock >= 0:
		print("SELFTEST terraform rock refused: '%s'" % WorldMap.terraform_hint(rock, 1))
	if scree >= 0:
		print("SELFTEST terraform foothill refused: '%s'" % WorldMap.terraform_hint(scree, -1))

func _process(_delta: float) -> void:
	_frame += 1

	# Fit a gate once the canal segment beneath it has finished digging.
	if not _gate_placed and _gate_idx >= 0 and WorldMap.is_canal(_gate_idx):
		_gate_placed = true
		print("SELFTEST gate -> ", BuildSystem.place(_gate_idx, WorldMap.Structure.GATE))
	elif _gate_placed and not _gate_toggled and WorldMap.structure_type[_gate_idx] == WorldMap.Structure.GATE:
		_gate_toggled = true
		BuildSystem.toggle_gate(_gate_idx)
		print("SELFTEST gate closed -> conducts=", WorldMap.conducts_water(_gate_idx))
		BuildSystem.toggle_gate(_gate_idx)
		print("SELFTEST gate reopened -> conducts=", WorldMap.conducts_water(_gate_idx))

	if _frame % 600 != 0 or _chain.is_empty():
		return
	# Sample water depth along the run: it should be highest at the aquifer
	# end and taper downstream, proving tile-to-tile flow.
	print("SELFTEST t=%d  open   %s" % [_frame, _sample(_chain)])
	if not _covered_chain.is_empty():
		print("SELFTEST t=%d  covered %s" % [_frame, _sample(_covered_chain)])
	if _aquifer_body >= 0:
		print("SELFTEST t=%d  aquifer %.0f/%.0f" % [
			_frame, WorldMap.aquifer_volume[_aquifer_body], WorldMap.aquifer_max_volume[_aquifer_body]])

func _sample(chain: PackedInt32Array) -> String:
	var samples: Array[String] = []
	for i in range(0, chain.size(), maxi(1, chain.size() / 6)):
		samples.append("%.2f" % WorldMap.water[chain[i]])
	samples.append("end=%.2f" % WorldMap.water[chain[chain.size() - 1]])
	return "[" + ", ".join(samples) + "]"

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
var _reservoir_origin: int = -1
var _basin_checked: bool = false

var _host: Node = null

static func run(host: Node) -> void:
	var t := SelfTest.new()
	t._host = host
	host.add_child(t)

func _ready() -> void:
	_test_camera_drag()
	_build()
	EventBus.plant_died.connect(func(idx, id): print("SELFTEST plant_died: ", id))
	EventBus.plant_harvested.connect(func(idx, id, amount): print("SELFTEST harvested %.1f %s" % [amount, id]))

## Left-drag has to grab the map with Inspect up, and has to leave the map
## alone once a build tool is selected -- otherwise laying out a canal run
## would fling the camera across the valley. Driving the camera's handler with
## synthesised events tests exactly that, with no window needed.
func _test_camera_drag() -> void:
	if _host == null:
		return
	var cam: Camera2D = _host.get_node_or_null("Camera2D")
	if cam == null:
		print("SELFTEST FAIL: no Camera2D")
		return
	var moved_with_inspect: Vector2 = _drag_camera(cam, false)
	var moved_with_tool: Vector2 = _drag_camera(cam, true)
	print("SELFTEST camera left-drag: inspect moved %s, build tool moved %s -> %s" % [
		moved_with_inspect, moved_with_tool,
		"OK" if moved_with_inspect.length() > 1.0 and moved_with_tool.length() < 0.001 else "FAIL"])

func _drag_camera(cam: Camera2D, build_tool: bool) -> Vector2:
	cam.build_tool_active = build_tool
	var before: Vector2 = cam.position
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(400.0, 300.0)
	cam._unhandled_input(press)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(-40.0, -30.0)
	cam._unhandled_input(motion)
	var moved: Vector2 = cam.position - before
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = press.position
	cam._unhandled_input(release)
	cam.position = before
	return moved

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
	_reservoir_origin = WorldMap.index_of(vx, vy)
	print("SELFTEST reservoir %s -> %s" % [BuildSystem.footprint_of(WorldMap.Structure.RESERVOIR),
		BuildSystem.place(_reservoir_origin, WorldMap.Structure.RESERVOIR)])
	print("SELFTEST cistern   -> ", BuildSystem.place(WorldMap.index_of(vx + 6, vy), WorldMap.Structure.CISTERN))
	print("SELFTEST shade     -> ", BuildSystem.place(WorldMap.index_of(vx + 14, vy), WorldMap.Structure.SHADE_STRUCTURE))

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

	# Once the basin has finished digging, confirm its footprint and inlets.
	if not _basin_checked and _reservoir_origin >= 0 \
			and WorldMap.structure_type[_reservoir_origin] == WorldMap.Structure.RESERVOIR:
		_basin_checked = true
		var tiles: int = 0
		var inlets: int = 0
		for i in range(WorldMap.width * WorldMap.height):
			if WorldMap.structure_owner[i] == _reservoir_origin:
				tiles += 1
				if WorldMap.is_inlet[i] == 1:
					inlets += 1
		print("SELFTEST basin: %d tiles, %d inlets" % [tiles, inlets])
		_test_grading()

	if _frame % 600 != 0 or _chain.is_empty():
		return
	# Sample water depth along the run: it should be highest at the aquifer
	# end and taper downstream, proving tile-to-tile flow.
	print("SELFTEST t=%d  open   %s" % [_frame, _sample(_chain)])
	print("SELFTEST t=%d  levels %s" % [_frame, _levels(_chain)])
	if not _covered_chain.is_empty():
		print("SELFTEST t=%d  covered %s" % [_frame, _sample(_covered_chain)])
		print("SELFTEST t=%d  levels %s" % [_frame, _levels(_covered_chain)])
	if _aquifer_body >= 0:
		print("SELFTEST t=%d  aquifer %.0f/%.0f" % [
			_frame, WorldMap.aquifer_volume[_aquifer_body], WorldMap.aquifer_max_volume[_aquifer_body]])
	_audit_uphill()

## Two consequences of the no-uphill rule that need to hold up in practice:
## how much of a natural route actually steps up (the grading burden), and
## that a channel already in the ground can still be cut down a level, so a
## stalled run can be fixed without demolishing it.
func _test_grading() -> void:
	if _chain.is_empty():
		return
	var steps_up: int = 0
	for i in range(1, _chain.size()):
		if WorldMap.height_level(_chain[i]) > WorldMap.height_level(_chain[i - 1]):
			steps_up += 1
	print("SELFTEST grading burden: %d of %d run tiles step up" % [steps_up, _chain.size()])

	var canal_tile: int = -1
	for idx in _chain:
		# Out on the valley floor: the foothill apron refuses terracing
		# whether or not a channel is on it, which would prove nothing here.
		if WorldMap.structure_type[idx] == WorldMap.Structure.CANAL_OPEN \
				and WorldMap.terrain_type[idx] != WorldMap.Terrain.SCREE:
			canal_tile = idx
			break
	if canal_tile < 0:
		return
	var before: int = WorldMap.height_level(canal_tile)
	var ok: bool = WorldMap.apply_terraform(canal_tile, -1)
	print("SELFTEST regrade a built canal: ok=%s level %d -> %d (hint '%s')" % [
		ok, before, WorldMap.height_level(canal_tile), WorldMap.terraform_hint(canal_tile, -1)])
	if _reservoir_origin >= 0:
		print("SELFTEST regrade a basin refused: '%s'" % WorldMap.terraform_hint(_reservoir_origin, -1))

## Decisive check that water never climbs.
##
## Flood-filling outward from the tiles that draw water from the world, but
## refusing to step up a height level, gives exactly the set of tiles water is
## allowed to reach. Any tile holding water outside that set can only have got
## it by going uphill somewhere, so a non-zero count here is the bug the rule
## exists to prevent.
func _audit_uphill() -> void:
	var size: int = WorldMap.width * WorldMap.height
	var reachable: Dictionary = {}
	var frontier: Array[int] = []
	for i in range(size):
		if not WorldMap.conducts_water(i):
			continue
		var s: int = WorldMap.structure_type[i]
		var is_source: bool = (s == WorldMap.Structure.CANAL_MOUNTAIN and WorldMap.has_aquifer(i)) \
			or (s == WorldMap.Structure.WELL and WorldMap.rare_groundwater[i] > 0.0)
		if is_source:
			reachable[i] = true
			frontier.append(i)

	var buf := PackedInt32Array([0, 0, 0, 0])
	while not frontier.is_empty():
		var idx: int = frontier.pop_back()
		var count: int = WorldMap.get_neighbors4(idx, buf)
		for n in range(count):
			var nidx: int = buf[n]
			if reachable.has(nidx):
				continue
			if not WorldMap.conducts_water(nidx):
				continue
			if not WorldMap.water_may_pass(idx, nidx):
				continue
			if WorldMap.height_differential(idx, nidx) < 0:
				continue
			reachable[nidx] = true
			frontier.append(nidx)

	var wet: int = 0
	var violations: int = 0
	var worst: int = -1
	for i in range(size):
		if not WorldMap.conducts_water(i) or WorldMap.water[i] <= 0.01:
			continue
		wet += 1
		if not reachable.has(i):
			violations += 1
			if worst < 0:
				worst = i
	var detail: String = ""
	if worst >= 0:
		detail = " first at %s (level %d)" % [WorldMap.coords_of(worst), WorldMap.water_level(worst)]
	print("SELFTEST uphill audit: %d wet tiles, %d unreachable without climbing%s -> %s" % [
		wet, violations, detail, "OK" if violations == 0 else "FAIL"])

func _levels(chain: PackedInt32Array) -> String:
	var samples: Array[String] = []
	for i in range(0, chain.size(), maxi(1, chain.size() / 6)):
		samples.append(str(WorldMap.water_level(chain[i])))
	samples.append("end=%d" % WorldMap.water_level(chain[chain.size() - 1]))
	return "[" + ", ".join(samples) + "]"

func _sample(chain: PackedInt32Array) -> String:
	var samples: Array[String] = []
	for i in range(0, chain.size(), maxi(1, chain.size() / 6)):
		samples.append("%.2f" % WorldMap.water[chain[i]])
	samples.append("end=%.2f" % WorldMap.water[chain[chain.size() - 1]])
	return "[" + ", ".join(samples) + "]"

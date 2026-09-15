## Main Game Scene Controller
## Initializes the simulation, handles input, and manages game state.

extends Node2D

# References to key components
@onready var sim_manager: Node = $SimulationManager
@onready var debug_overlay: CanvasLayer = $DebugOverlay
@onready var tile_map: TileMapLayer = $TileMapLayer

# Configuration
@export var initial_seed: int = 12345
@export var enable_debug_overlays: bool = true


func _ready() -> void:
	"""Initialize the game."""
	print("=== Desert Valley Colony Sim ===")
	
	# Get references
	sim_manager = get_node_or_null("SimulationManager")
	tile_map = get_node_or_null("TileMapLayer")
	debug_overlay = get_node_or_null("DebugOverlay")
	
	if sim_manager == null:
		push_error("SimulationManager not found!")
		return
	
	if tile_map == null:
		push_error("TileMapLayer not found!")
		return
	
	# Wait a frame to ensure autoload is ready
	await get_tree().process_frame
	
	# Initialize simulation manager systems
	_initialize_systems()
	
	# Generate the world
	_generate_world()
	
	# Setup debug overlay if enabled
	if enable_debug_overlays and debug_overlay:
		_setup_debug_overlay()
	
	# Create some test plants
	_create_test_plants()
	
	print("Game initialized successfully!")
	print("Press F1-F4 for debug overlays")
	print("Press SPACE to trigger rain event")


func _initialize_systems() -> void:
	"""Load and initialize all simulation systems."""
	# Load system scripts
	sim_manager.water_system = load("res://scripts/systems/water_system.gd")
	sim_manager.microclimate_system = load("res://scripts/systems/microclimate_system.gd")
	sim_manager.plant_system = load("res://scripts/systems/plant_system.gd")
	sim_manager.world_generator = load("res://scripts/systems/world_generator.gd")
	
	print("Systems loaded: Water, Microclimate, Plant, WorldGenerator")


func _generate_world() -> void:
	"""Generate the initial world terrain."""
	var WorldGen = sim_manager.world_generator
	WorldGen.generate_world(sim_manager, initial_seed)
	
	print("World generated with seed %d" % initial_seed)
	
	# Render initial terrain
	_render_terrain()


func _render_terrain() -> void:
	"""Render the terrain based on simulation data."""
	if tile_map == null:
		print("ERROR: TileMapLayer is null!")
		return
	
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	var terrain_elevation = sim_manager.terrain_elevation
	var tile_data = sim_manager.tile_data
	
	# Clear existing tiles
	tile_map.clear()
	
	# Draw terrain tiles with programmer art colors
	for y in range(grid_height):
		for x in range(grid_width):
			var idx = y * grid_width + x
			var tile_type = tile_data[idx].get("tile_type", "sand")
			
			# Simple color coding for programmer art
			var tile_id = 0  # Default sand
			match tile_type:
				"sand":
					tile_id = 0
				"mountain":
					tile_id = 1
				"alluvial_fan":
					tile_id = 2
			
			tile_map.set_cell(Vector2i(x, y), 0, Vector2i(tile_id, 0))
	
	print("Terrain rendered: %dx%d grid" % [grid_width, grid_height])


func _setup_debug_overlay() -> void:
	"""Configure and enable debug overlay."""
	if debug_overlay:
		debug_overlay.set_simulation_manager(sim_manager)
		print("Debug overlay enabled (F1-F4)")


func _create_test_plants() -> void:
	"""Create some test plants to verify simulation."""
	# Load plant data resources
	var date_palm_data = load("res://resources/plants/date_palm_data.tres")
	var alfalfa_data = load("res://resources/plants/alfalfa_data.tres")
	
	if date_palm_data == null:
		print("WARNING: Date Palm data not found, creating programmatically")
		date_palm_data = CanopyPlantData.new()
	
	if alfalfa_data == null:
		print("WARNING: Alfalfa data not found, creating programmatically")
		alfalfa_data = AlfalfaPlantData.new()
	
	# Find a suitable location (valley tile)
	var grid_width = sim_manager.GRID_WIDTH
	var grid_height = sim_manager.GRID_HEIGHT
	var test_tile = -1
	
	for i in range(sim_manager.tile_data.size()):
		if sim_manager.tile_data[i].get("tile_type") == "sand":
			test_tile = i
			break
	
	if test_tile != -1:
		# Create a Date Palm
		var palm = PlantSystem.create_plant_instance(date_palm_data, test_tile, true)
		sim_manager.active_plants.append(palm)
		print("Created test Date Palm at tile %d" % test_tile)
		
		# Create some Alfalfa nearby
		var neighbors = _get_neighbors(test_tile, grid_width, grid_height, 2)
		for neighbor_idx in neighbors:
			if sim_manager.tile_data[neighbor_idx].get("tile_type") == "sand":
				var alfalfa = PlantSystem.create_plant_instance(alfalfa_data, neighbor_idx, false)
				sim_manager.active_plants.append(alfalfa)
		print("Created %d test Alfalfa plants" % neighbors.size())
	else:
		print("WARNING: No suitable tile found for test plants")


func _get_neighbors(
	tile_idx: int,
	grid_width: int,
	grid_height: int,
	radius: int = 1
) -> Array[int]:
	"""Get neighboring tile indices."""
	var neighbors: Array[int] = []
	var x = tile_idx % grid_width
	var y = float(tile_idx) / float(grid_width)
	
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx == 0 and dy == 0:
				continue
			
			var nx = x + dx
			var ny = int(y) + dy
			
			if nx >= 0 and nx < grid_width and ny >= 0 and ny < grid_height:
				neighbors.append(ny * grid_width + nx)
	
	return neighbors


func _input(event: InputEvent) -> void:
	"""Handle game input."""
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				_trigger_rain_event()
			KEY_F5:
				_cycle_debug_mode()


func _trigger_rain_event() -> void:
	"""Trigger a random rain/flash flood event."""
	var rain_intensity = randf_range(0.5, 2.0)
	sim_manager.current_rain_intensity = rain_intensity
	print("Rain event triggered! Intensity: %.2f" % rain_intensity)


func _cycle_debug_mode() -> void:
	"""Cycle through debug overlay modes."""
	if debug_overlay:
		debug_overlay.cycle_debug_mode()


func _process(delta: float) -> void:
	"""Update UI or other per-frame logic."""
	# Could add FPS counter, simulation stats, etc.
	pass

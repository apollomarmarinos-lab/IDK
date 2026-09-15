# Desert Valley Colony Sim

A Godot 4-based desert colony simulation game featuring systemic equilibrium between water logistics, microclimate modeling, plant health, and terrain generation.

## Architecture Overview

This project implements a **data-oriented architecture** with equal emphasis on all core systems:

### Core Systems (Equal Priority)

1. **World Generation** (`scripts/systems/world_generator.gd`)
   - Multi-layered procedural terrain using FastNoiseLite
   - Geological analysis for aquifers and alluvial fans
   - Elevation-based biome distribution (mountains, valleys, alluvial fans)

2. **Water Logistics** (`scripts/systems/water_system.gd`)
   - Flow diffusion between connected tiles
   - Seepage mechanics (unlined vs lined canals)
   - Evaporation driven by sun, shade, and wind
   - Flash flood events from mountain rainfall

3. **Microclimate Modeling** (`scripts/systems/microclimate_system.gd`)
   - Per-tile shade calculation from canopy plants
   - Temperature aggregation (elevation, sun exposure, water cooling)
   - Soil humidity from water proximity and plant transpiration
   - Acts as central hub connecting physical and biological systems

4. **Plant Health** (`scripts/systems/plant_system.gd`)
   - CWSI-inspired stress accumulation model
   - Color-coded visual feedback (green→yellow→orange→red)
   - Growth halts during stress conditions
   - Queries microclimate layer for environmental data

### Data Architecture

- **Custom Resources** (`resources/plants/`): Plant definitions as `.tres` files
- **Flat Arrays**: Simulation state stored in contiguous memory for performance
- **Decoupled Design**: Systems operate on shared data without direct dependencies

### Central Orchestrator

The `SimulationManager` autoload:
- Owns authoritative state arrays
- Orchestrates tick-by-tick execution (Water → Microclimate → Plants)
- Prevents tight coupling between systems

## Project Structure

```
/workspace
├── autoloads/
│   └── simulation_manager.gd      # Central orchestrator
├── resources/
│   └── plants/
│       ├── base_plant_data.gd     # Base Resource class
│       ├── canopy_plant_data.gd   # Date Palm extension
│       └── *.tres                 # Plant data resources
├── scripts/
│   └── systems/
│       ├── water_system.gd        # Water flow & evaporation
│       ├── microclimate_system.gd # Shade, temp, humidity
│       ├── plant_system.gd        # Health & growth
│       └── world_generator.gd     # Terrain generation
├── scenes/
│   └── main_game.gd               # Main scene controller
├── debug/
│   └── debug_overlay.gd           # F1-F4 visualization overlays
└── project.godot                  # Godot 4.2 project config
```

## Implementation Roadmap

### Phase 1: Core Architecture ✅
- [x] SimulationManager autoload with flat arrays
- [x] System script structure (water, microclimate, plant, world)
- [x] Data-oriented Resource classes for plants

### Phase 2: World Generation
- [ ] TileSet with custom data layers
- [ ] TileMapLayer integration
- [ ] Procedural terrain rendering

### Phase 3: Simulation Loop
- [ ] Full water system implementation
- [ ] Complete microclimate calculations
- [ ] Plant stress/growth mechanics

### Phase 4: Programmer Art & Debugging
- [ ] Simple colored tile sprites
- [ ] Geometric plant shapes
- [x] Debug overlay system (F1-F4)

### Phase 5: Content Expansion
- [ ] All four plant types (Date Palm, Alfalfa, Cactus, Barley)
- [ ] Water storage methods (canals, qanats, cisterns)
- [ ] Wind and seasonal dynamics

## Controls

| Key | Action |
|-----|--------|
| F1 | Toggle water level overlay |
| F2 | Toggle soil humidity overlay |
| F3 | Toggle shade percentage overlay |
| F4 | Toggle temperature overlay |
| F5 | Cycle debug modes |
| SPACE | Trigger rain event |

## Key Mechanics

### Plants

| Plant | Role | Water Need | Special Ability |
|-------|------|------------|-----------------|
| Date Palm | Canopy keystone | High | Creates shade radius, deep taproot |
| Alfalfa | Ground cover | Medium | High transpiration (cooling), nitrogen fixation |
| Prickly Pear | Drought survivor | Very Low | Windbreak, minimal shade |
| Barley | Staple grain | Medium | Fast growth, needs palm protection |

### Water Infrastructure

| Method | Cost | Seepage | Evaporation | Special |
|--------|------|---------|-------------|---------|
| Unlined Canal | Low | High (recharges aquifer) | High | Cheap but inefficient |
| Lined Canal | High | None | High | Efficient delivery |
| Qanat | Very High | None | None | Underground, zero loss |
| Cistern | Medium | None | Very Low | Flash flood storage |

## Getting Started

1. Open project in Godot 4.2+
2. Run the main scene (`scenes/main_game.tscn`)
3. Press F1-F4 to view debug overlays
4. Press SPACE to trigger rain events

## Design Principles

1. **Systemic Equilibrium**: All systems treated with equal importance
2. **Engine-Agnostic Logic**: Pseudocode-style algorithms preserve portability
3. **Data-Oriented**: Resources decouple data from behavior
4. **Stylized Realism**: Simplified proxies for complex processes (CWSI → color coding)
5. **Emergent Gameplay**: Cascading effects (palms → shade → understory crops → transpiration)

## License

MIT License

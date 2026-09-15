# Desert Valley Colony Sim - Setup Guide for Godot 4.7

## Quick Start

1. **Open the Project**
   - Launch Godot 4.7
   - Click "Import" and select the `/workspace/project.godot` file
   - Wait for import to complete

2. **Run the Game**
   - Open `scenes/main_game.tscn` in the editor
   - Press F5 or click the Play button
   - You should see:
     - Console output showing initialization messages
     - A grid of colored tiles (yellow=sand, gray=mountain, tan=alluvial fan)
     - Debug overlay controls (F1-F4)

## Troubleshooting: Nothing Shows Up

If you press play and see a blank screen:

### Issue 1: TileSet Not Configured
The TileSet needs actual tile definitions. Follow these steps:

1. In the Godot Editor, open `scenes/main_game.tscn`
2. Select the `TileMapLayer` node
3. In the Inspector, find the "Tile Set" property
4. Click the dropdown and select "New TileSet"
5. Click on the TileSet resource to edit it
6. Add a new atlas source with a simple colored rectangle texture

OR use programmer art:

1. Create a new folder: `res://assets/programmer_art/`
2. Create three 32x32 PNG images:
   - `sand.png` (yellow #D4A749)
   - `mountain.png` (gray #5A5A5A)
   - `alluvial.png` (tan #C4A574)
3. Update the TileSet to use these textures

### Issue 2: Autoload Not Working
Verify the SimulationManager autoload is configured:

1. Go to Project → Project Settings → Autoload
2. Ensure `SimulationManager` is listed with path `res://autoloads/simulation_manager.gd`
3. If not, add it manually

### Issue 3: Missing Plant Resources
The plant .tres files should auto-create, but if they don't:

1. In the FileSystem dock, navigate to `resources/plants/`
2. Right-click → Create New → Resource
3. Select `CanopyPlantData` for Date Palm
4. Configure properties and save as `date_palm_data.tres`
5. Repeat for `AlfalfaPlantData` as `alfalfa_data.tres`

## Expected Console Output

When running correctly, you should see:
```
=== Desert Valley Colony Sim ===
Generating world: 64x64 grid with seed 12345
World generation complete!
Terrain rendered: 64x64 grid
Created test Date Palm at tile XXX
Created XX test Alfalfa plants
Game initialized successfully!
Press F1-F4 for debug overlays
Press SPACE to trigger rain event
```

## Debug Controls

- **F1**: Toggle water level overlay (blue gradient)
- **F2**: Toggle soil humidity overlay (green gradient)
- **F3**: Toggle shade percentage overlay (black/white)
- **F4**: Toggle temperature overlay (blue=cool to red=hot)
- **SPACE**: Trigger random rain event
- **F5**: Cycle through debug modes

## Next Steps

Once the basic simulation is visible:

1. **Add Visual Assets**: Replace programmer art with proper pixel art
2. **Tune Parameters**: Adjust simulation constants in the various system scripts
3. **Add Interaction**: Implement player controls for digging canals, planting crops
4. **Expand Content**: Add more plant types, building types, and seasonal variations

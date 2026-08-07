extends Node
## Global signal bus. Systems communicate through here instead of holding
## direct references to each other, so any system can be swapped out or
## extended without touching the others.

# Time
signal hour_passed(hour: int)
signal day_passed(day: int, season: int, year: int)
signal season_changed(season: int)
signal night_started
signal day_started

# World / tiles
signal tile_changed(tile_index: int)
signal world_generated

# Water & buildings
signal building_placed(tile_index: int, building_id: StringName)
signal building_removed(tile_index: int)
signal building_completed(tile_index: int, building_id: StringName)
signal gate_toggled(tile_index: int, is_open: bool)

# Plants
signal plant_planted(tile_index: int, plant_id: StringName)
signal plant_removed(tile_index: int)
signal plant_stage_changed(tile_index: int, stage: int)
signal plant_harvested(tile_index: int, plant_id: StringName, amount: float)
signal plant_died(tile_index: int, plant_id: StringName)

# Selection / UI
signal tile_selected(tile_index: int)
signal inventory_changed(item_id: StringName, amount: float)

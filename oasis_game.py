"""
OASIS KEEPER
A desert survival and management simulation.
Inspired by Clanfolk, Dwarf Fortress, and RimWorld.

Dependencies: pip install pygame
"""

import pygame
import numpy as np
import math
import random
from enum import Enum
from dataclasses import dataclass
from typing import List, Tuple, Optional

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================

SCREEN_WIDTH = 1200
SCREEN_HEIGHT = 800
TILE_SIZE = 24
MAP_WIDTH = 60
MAP_HEIGHT = 50
FPS = 60

# Colors
C_SAND = (235, 215, 160)
C_SAND_WET = (190, 170, 120)
C_MOUNTAIN = (139, 119, 101)
C_WATER_SURFACE = (64, 164, 223)
C_WATER_DEEP = (41, 128, 185)
C_GRASS = (107, 142, 35)
C_SHADE = (0, 0, 0, 100) # Alpha for shade overlay
C_NIGHT = (20, 24, 40) # Night tint
C_UI_BG = (40, 40, 40)
C_TEXT = (220, 220, 220)

# Simulation Constants
EVAPORATION_RATE_BASE = 0.05
WATER_FLOW_SPEED = 0.3 # Tiles per tick approx
TRANSPIRATION_RATE = 0.08
MAX_AIR_MOISTURE = 100.0
TEMP_DAY_HIGH = 45.0
TEMP_NIGHT_LOW = 15.0
SEASON_LENGTH = 600 # Ticks per season

class TerrainType(Enum):
    SAND = 0
    MOUNTAIN = 1
    WATER_SOURCE = 2 # Aquifer exit
    CANAL_OPEN = 3
    CANAL_COVERED = 4
    STORAGE_TANK = 5

class PlantType(Enum):
    NONE = 0
    DATE_PALM = 1
    OLIVE_TREE = 2
    FIG_TREE = 3
    ROSEMARY = 4
    THYME = 5
    LAVENDER = 6
    ROSE = 7

class Season(Enum):
    SPRING = 0
    SUMMER = 1
    AUTUMN = 2
    WINTER = 3

# Plant Definitions
PLANT_DATA = {
    PlantType.DATE_PALM: {"name": "Date Palm", "shade_radius": 3, "water_need": 0.4, "growth_time": 400, "harvest_season": [Season.AUTUMN], "color": (34, 139, 34)},
    PlantType.OLIVE_TREE: {"name": "Olive Tree", "shade_radius": 2, "water_need": 0.3, "growth_time": 350, "harvest_season": [Season.WINTER], "color": (85, 107, 47)},
    PlantType.FIG_TREE: {"name": "Fig Tree", "shade_radius": 2, "water_need": 0.5, "growth_time": 300, "harvest_season": [Season.SUMMER], "color": (60, 120, 60)},
    PlantType.ROSEMARY: {"name": "Rosemary", "shade_radius": 0, "water_need": 0.1, "growth_time": 100, "harvest_season": [Season.SPRING, Season.SUMMER], "color": (100, 140, 100)},
    PlantType.THYME: {"name": "Thyme", "shade_radius": 0, "water_need": 0.1, "growth_time": 90, "harvest_season": [Season.SPRING], "color": (120, 150, 120)},
    PlantType.LAVENDER: {"name": "Lavender", "shade_radius": 0, "water_need": 0.15, "growth_time": 120, "harvest_season": [Season.SUMMER], "color": (140, 100, 180)},
    PlantType.ROSE: {"name": "Desert Rose", "shade_radius": 0, "water_need": 0.2, "growth_time": 150, "harvest_season": [Season.SPRING, Season.AUTUMN], "color": (200, 50, 50)},
}

# ==============================================================================
# UTILS & GENERATION
# ==============================================================================

def generate_map(width, height):
    """Generates the valley map with mountain ranges and aquifers."""
    terrain = np.full((height, width), TerrainType.SAND, dtype=int)
    elevation = np.zeros((height, width))
    
    # Create two mountain ranges on East and West
    center_x = width // 2
    valley_width = width // 3
    
    for y in range(height):
        for x in range(width):
            dist_from_center = abs(x - center_x)
            # Noise for organic look
            noise = random.uniform(-5, 5)
            
            if dist_from_center > (valley_width + noise):
                elevation[y, x] = 1.0 # Mountain
                terrain[y, x] = TerrainType.MOUNTAIN.value
            else:
                elevation[y, x] = 0.0 # Valley floor
                
    # Create Aquifers (Water sources in mountains flowing down)
    # We place 'sources' high up in the mountains
    aquifer_points = []
    for _ in range(4):
        side = random.choice([-1, 1])
        mx = center_x + (side * (valley_width + random.randint(5, 10)))
        my = random.randint(5, height - 5)
        if 0 <= mx < width and 0 <= my < height:
            if terrain[my, mx] == TerrainType.MOUNTAIN.value:
                aquifer_points.append((mx, my))
                terrain[my, mx] = TerrainType.WATER_SOURCE.value

    return terrain, elevation, aquifer_points

# ==============================================================================
# GAME ENTITIES
# ==============================================================================

@dataclass
class Tile:
    x: int
    y: int
    terrain: TerrainType
    water_level: float = 0.0 # 0.0 to 1.0 (Surface water)
    soil_moisture: float = 0.0 # 0.0 to 1.0 (Groundwater/Soil wetness)
    plant: Optional[PlantType] = None
    plant_growth: float = 0.0 # 0.0 to 1.0
    plant_ready: bool = False
    temperature: float = 25.0
    shade_factor: float = 0.0 # 0.0 (full sun) to 1.0 (full shade)

@dataclass
class AirTile:
    humidity: float = 0.0 # 0 to 100%
    wind_vector: Tuple[float, float] = (0.0, 0.0)

class GameWorld:
    def __init__(self, width, height):
        self.width = width
        self.height = height
        self.tiles: List[List[Tile]] = []
        self.air: List[List[AirTile]] = []
        self.tick_count = 0
        self.season = Season.SPRING
        self.time_of_day = 0.0 # 0.0 to 1.0 (0 = midnight, 0.5 = noon)
        
        # Initialize Map
        t_map, elev, aquifers = generate_map(width, height)
        self.aquifer_sources = aquifers
        
        for y in range(height):
            row_tiles = []
            row_air = []
            for x in range(width):
                t_type = TerrainType(t_map[y, x])
                row_tiles.append(Tile(x, y, t_type))
                row_air.append(AirTile())
            self.tiles.append(row_tiles)
            self.air.append(row_air)
            
        # Seed initial water at aquifer sources
        for ax, ay in self.aquifer_sources:
            self.tiles[ay][ax].water_level = 1.0
            self.tiles[ay][ax].soil_moisture = 1.0

    def get_tile(self, x, y):
        if 0 <= x < self.width and 0 <= y < self.height:
            return self.tiles[y][x]
        return None

    def update_simulation(self):
        self.tick_count += 1
        
        # Time & Season Logic
        self.time_of_day = (self.tick_count / (FPS * 60 * 24)) % 1.0
        season_idx = (self.tick_count // (FPS * 60 * 24 * SEASON_LENGTH)) % 4
        self.season = Season(season_idx)
        
        # Calculate Sun Intensity (0.0 night, 1.0 noon)
        # Simple sine wave for day cycle
        sun_intensity = math.sin(self.time_of_day * 2 * math.pi - math.pi/2)
        sun_intensity = max(0, sun_intensity)
        
        # Base Temperature based on time and season
        base_temp = TEMP_NIGHT_LOW + (TEMP_DAY_HIGH - TEMP_NIGHT_LOW) * sun_intensity
        if self.season == Season.WINTER:
            base_temp *= 0.8
        elif self.season == Season.SUMMER:
            base_temp *= 1.1
            
        # Wind Simulation (Global for now, could be local)
        wind_speed = 0.05 * sun_intensity # Windier during day
        wind_angle = math.sin(self.tick_count * 0.01) * math.pi # Oscillating direction
        global_wind = (math.cos(wind_angle) * wind_speed, math.sin(wind_angle) * wind_speed)

        # Update Tiles
        for y in range(self.height):
            for x in range(self.width):
                tile = self.tiles[y][x]
                air = self.air[y][x]
                
                # 1. Temperature & Shade Calculation
                # Check neighbors for shade (simplified raycast or radius check)
                shade = 0.0
                if tile.plant:
                    p_data = PLANT_DATA[tile.plant]
                    shade = 0.8 # Self shade
                    
                # Check neighbors for tree shade
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        neighbor = self.get_tile(x+dx, y+dy)
                        if neighbor and neighbor.plant:
                            p_data = PLANT_DATA[neighbor.plant]
                            dist = math.sqrt(dx*dx + dy*dy)
                            if dist < p_data["shade_radius"]:
                                shade = max(shade, 0.9 - (dist/p_data["shade_radius"])*0.4)
                
                # Man-made shade (Covered canals provide slight shade to surroundings)
                if tile.terrain == TerrainType.CANAL_COVERED:
                    shade = max(shade, 0.3)
                    
                tile.shade_factor = shade
                
                # Apply temp
                target_temp = base_temp * (1.0 - (shade * 0.4)) # Shade reduces peak temp
                tile.temperature = tile.temperature * 0.95 + target_temp * 0.05
                
                # 2. Water Physics
                
                # Evaporation
                evap_rate = EVAPORATION_RATE_BASE * (tile.temperature / 30.0) * (1.0 - shade)
                if tile.terrain == TerrainType.CANAL_COVERED:
                    evap_rate *= 0.1 # Covered canals evaporate much less
                
                if tile.water_level > 0:
                    loss = evap_rate * 0.1
                    tile.water_level = max(0, tile.water_level - loss)
                    # Add humidity to air
                    air.humidity = min(MAX_AIR_MOISTURE, air.humidity + loss * 10)
                
                # Transpiration (Plants pull water from soil and release to air)
                if tile.plant and tile.plant_growth >= 1.0:
                    p_need = PLANT_DATA[tile.plant]["water_need"]
                    # Plants drink from soil moisture first, then surface water
                    drink = 0
                    if tile.soil_moisture > 0.1:
                        drink = min(p_need, tile.soil_moisture * 0.2)
                        tile.soil_moisture -= drink
                    elif tile.water_level > 0:
                        drink = min(p_need, tile.water_level * 0.2)
                        tile.water_level -= drink
                    
                    if drink > 0:
                        air.humidity = min(MAX_AIR_MOISTURE, air.humidity + drink * 5)
                        
                # Water Flow (Simple cellular automata for surface water)
                if tile.water_level > 0.1:
                    # Flow to neighbors
                    flow_amount = tile.water_level * WATER_FLOW_SPEED
                    directions = [(0,1), (0,-1), (1,0), (-1,0)]
                    random.shuffle(directions)
                    
                    for dx, dy in directions:
                        neighbor = self.get_tile(x+dx, y+dy)
                        if neighbor:
                            # Gravity: prefer lower elevation (not implemented in flat array, assuming flat valley)
                            # Capacity check
                            if neighbor.terrain != TerrainType.MOUNTAIN:
                                if neighbor.water_level < tile.water_level:
                                    transfer = min(flow_amount, (tile.water_level - neighbor.water_level) * 0.5)
                                    if transfer > 0.01:
                                        tile.water_level -= transfer
                                        neighbor.water_level += transfer
                                        
                # Soil Moisture Diffusion
                if tile.soil_moisture > 0.1:
                    for dx, dy in [(-1,0), (1,0), (0,-1), (0,1)]:
                        neighbor = self.get_tile(x+dx, y+dy)
                        if neighbor and neighbor.soil_moisture < tile.soil_moisture:
                            diff = (tile.soil_moisture - neighbor.soil_moisture) * 0.1
                            tile.soil_moisture -= diff
                            neighbor.soil_moisture += diff

                # 3. Plant Growth
                if tile.plant:
                    p_data = PLANT_DATA[tile.plant]
                    # Needs: Water and Temp
                    water_ok = tile.soil_moisture > 0.1 or tile.water_level > 0.1
                    temp_ok = 10 < tile.temperature < 50
                    
                    if water_ok and temp_ok:
                        growth_rate = 1.0 / p_data["growth_time"]
                        if tile.shade_factor > 0.5 and p_data["shade_radius"] == 0:
                            growth_rate *= 1.2 # Bushes like some shade
                        
                        tile.plant_growth += growth_rate
                        
                        if tile.plant_growth >= 1.0 and not tile.plant_ready:
                            if self.season in p_data["harvest_season"]:
                                tile.plant_ready = True
                    else:
                        # Dying logic could go here
                        pass

    def interact(self, x, y, action, tool=None):
        tile = self.get_tile(x, y)
        if not tile: return
        
        if action == "DIG_CANAL":
            if tile.terrain == TerrainType.SAND:
                tile.terrain = TerrainType.CANAL_OPEN
                # If near water source, fill immediately
                for dx, dy in [(-1,0), (1,0), (0,-1), (0,1)]:
                    n = self.get_tile(x+dx, y+dy)
                    if n and n.water_level > 0.5:
                        tile.water_level = 0.5
                        break
                        
        elif action == "COVER_CANAL":
            if tile.terrain == TerrainType.CANAL_OPEN:
                tile.terrain = TerrainType.CANAL_COVERED
                
        elif action == "MAKE_TANK":
            if tile.terrain == TerrainType.SAND:
                tile.terrain = TerrainType.STORAGE_TANK
                tile.soil_moisture = 1.0 # Seal the bottom
                
        elif action == "PLANT":
            if tool and tile.terrain in [TerrainType.SAND, TerrainType.CANAL_OPEN]:
                if tile.plant is None:
                    tile.plant = tool
                    tile.plant_growth = 0.0
                    tile.plant_ready = False
                    # Initial water cost
                    tile.soil_moisture = 0.5
                    
        elif action == "HARVEST":
            if tile.plant and tile.plant_ready:
                tile.plant_ready = False
                tile.plant_growth = 0.0
                # Return yield logic here
                print(f"Harvested {PLANT_DATA[tile.plant]['name']}")

# ==============================================================================
# RENDERER
# ==============================================================================

class Renderer:
    def __init__(self, screen, world):
        self.screen = screen
        self.world = world
        self.font = pygame.font.SysFont("Arial", 14)
        self.shade_surface = pygame.Surface((TILE_SIZE, TILE_SIZE), pygame.SRCALPHA)
        self.shade_surface.fill((0, 0, 0, 60)) # Semi-transparent black
        
    def draw(self, selected_tool):
        self.screen.fill(C_SAND)
        
        cam_x, cam_y = 0, 0 # Simplified, no camera scroll for this snippet
        
        for y in range(self.world.height):
            for x in range(self.world.width):
                tile = self.world.tiles[y][x]
                rect = pygame.Rect(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE)
                
                # 1. Base Terrain
                color = C_SAND
                if tile.terrain == TerrainType.MOUNTAIN:
                    color = C_MOUNTAIN
                elif tile.terrain == TerrainType.CANAL_OPEN:
                    color = C_SAND_WET
                elif tile.terrain == TerrainType.CANAL_COVERED:
                    color = (100, 100, 100) # Stone cover
                elif tile.terrain == TerrainType.STORAGE_TANK:
                    color = (80, 80, 120)
                    
                pygame.draw.rect(self.screen, color, rect)
                
                # 2. Water
                if tile.water_level > 0.05:
                    water_h = int(TILE_SIZE * tile.water_level)
                    water_rect = pygame.Rect(x * TILE_SIZE, y * TILE_SIZE + (TILE_SIZE - water_h), TILE_SIZE, water_h)
                    c_water = C_WATER_SURFACE if tile.terrain == TerrainType.CANAL_OPEN else C_WATER_DEEP
                    pygame.draw.rect(self.screen, c_water, water_rect)
                    
                # 3. Soil Moisture (Visualized as darkening sand if no surface water)
                if tile.water_level <= 0.05 and tile.soil_moisture > 0.2:
                    alpha = int(tile.soil_moisture * 50)
                    s = pygame.Surface((TILE_SIZE, TILE_SIZE), pygame.SRCALPHA)
                    s.fill((0, 0, 0, alpha))
                    self.screen.blit(s, rect)
                
                # 4. Plants
                if tile.plant:
                    p_data = PLANT_DATA[tile.plant]
                    # Growth stage visualization
                    size = int(TILE_SIZE * 0.8 * tile.plant_growth)
                    offset = (TILE_SIZE - size) // 2
                    plant_rect = pygame.Rect(x * TILE_SIZE + offset, y * TILE_SIZE + offset, size, size)
                    
                    if tile.plant_ready:
                        # Fruit color
                        pygame.draw.circle(self.screen, (255, 200, 0), plant_rect.center, size//2)
                    else:
                        pygame.draw.rect(self.screen, p_data["color"], plant_rect)
                        
                # 5. Shade Overlay
                if tile.shade_factor > 0.1:
                    # Draw shade only if it's day (simplified check)
                    # In a real engine, we'd check global sun intensity
                    s_copy = self.shade_surface.copy()
                    s_copy.set_alpha(int(tile.shade_factor * 150))
                    self.screen.blit(s_copy, rect)

        # UI Overlay
        self.draw_ui(selected_tool)
        
        # Night Cycle Overlay
        sun_int = math.sin(self.world.time_of_day * 2 * math.pi - math.pi/2)
        if sun_int < 0:
            night_alpha = int(abs(sun_int) * 180)
            night_surf = pygame.Surface((SCREEN_WIDTH, SCREEN_HEIGHT), pygame.SRCALPHA)
            night_surf.fill((*C_NIGHT, night_alpha))
            self.screen.blit(night_surf, (0,0))

    def draw_ui(self, selected_tool):
        # Top Bar
        pygame.draw.rect(self.screen, C_UI_BG, (0, 0, SCREEN_WIDTH, 40))
        
        # Stats
        season_str = self.world.season.name
        time_str = f"Day {int(self.world.tick_count / (FPS*60*24))}"
        temp_str = f"Avg Temp: {int(sum(t.temperature for row in self.world.tiles for t in row) / (self.world.width*self.world.height))}°C"
        
        info_text = f"Season: {season_str} | {time_str} | {temp_str}"
        text_surf = self.font.render(info_text, True, C_TEXT)
        self.screen.blit(text_surf, (10, 10))
        
        # Tool Selection Info
        tool_name = selected_tool.name if selected_tool else "None"
        tool_text = f"Selected: {tool_name}"
        t_surf = self.font.render(tool_text, True, (255, 255, 100))
        self.screen.blit(t_surf, (SCREEN_WIDTH - 150, 10))
        
        # Instructions
        inst_text = "Left Click: Act | Right Click: Cancel | Keys 1-7: Select Plant | C: Canal | V: Cover | B: Tank"
        i_surf = self.font.render(inst_text, True, (150, 150, 150))
        self.screen.blit(i_surf, (10, SCREEN_HEIGHT - 30))

# ==============================================================================
# MAIN LOOP
# ==============================================================================

def main():
    pygame.init()
    screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
    pygame.display.set_caption("Oasis Keeper")
    clock = pygame.time.Clock()
    
    world = GameWorld(MAP_WIDTH, MAP_HEIGHT)
    renderer = Renderer(screen, world)
    
    running = True
    selected_action = "DIG_CANAL"
    selected_plant = None
    
    while running:
        # Event Handling
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            
            if event.type == pygame.KEYDOWN:
                if event.key == pygame.K_1: selected_plant = PlantType.DATE_PALM; selected_action = "PLANT"
                if event.key == pygame.K_2: selected_plant = PlantType.OLIVE_TREE; selected_action = "PLANT"
                if event.key == pygame.K_3: selected_plant = PlantType.FIG_TREE; selected_action = "PLANT"
                if event.key == pygame.K_4: selected_plant = PlantType.ROSEMARY; selected_action = "PLANT"
                if event.key == pygame.K_5: selected_plant = PlantType.THRYME; selected_action = "PLANT" # Typo fix in next iter
                if event.key == pygame.K_5: selected_plant = PlantType.THYME; selected_action = "PLANT"
                if event.key == pygame.K_6: selected_plant = PlantType.LAVENDER; selected_action = "PLANT"
                if event.key == pygame.K_7: selected_plant = PlantType.ROSE; selected_action = "PLANT"
                
                if event.key == pygame.K_c: selected_action = "DIG_CANAL"; selected_plant = None
                if event.key == pygame.K_v: selected_action = "COVER_CANAL"; selected_plant = None
                if event.key == pygame.K_b: selected_action = "MAKE_TANK"; selected_plant = None
                if event.key == pygame.K_h: selected_action = "HARVEST"; selected_plant = None

            if event.type == pygame.MOUSEBUTTONDOWN:
                mx, my = pygame.mouse.get_pos()
                tx, ty = mx // TILE_SIZE, my // TILE_SIZE
                
                if event.button == 1: # Left Click
                    world.interact(tx, ty, selected_action, selected_plant)
                elif event.button == 3: # Right Click
                    selected_action = None
                    selected_plant = None

        # Update
        world.update_simulation()
        
        # Render
        renderer.draw(selected_plant)
        
        pygame.display.flip()
        clock.tick(FPS)
        
    pygame.quit()

if __name__ == "__main__":
    main()

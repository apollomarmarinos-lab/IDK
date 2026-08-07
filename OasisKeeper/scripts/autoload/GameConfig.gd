extends Node
## Central tuning constants for the whole simulation.
##
## Keeping every "magic number" in one autoload means the simulation can be
## rebalanced without hunting through system scripts, and new contributors
## have one place to look when asking "why does water behave like this?".
##
## Values are not a literal physical model (a tile is ~2m x 2m and one sim
## tick is a fraction of an in-game hour) but their *relative* magnitudes are
## deliberately realistic:
##   - open water evaporates far faster than shaded or underground water
##   - wind and heat multiply evaporation, humidity suppresses it
##   - underground (qanat-style) canals lose only a trickle to seepage
##   - trees draw far more water than herbs, and cast far more shade

# ---------------------------------------------------------------------------
# World / grid
# ---------------------------------------------------------------------------
const MAP_WIDTH: int = 220
const MAP_HEIGHT: int = 140
const TILE_PIXEL_SIZE: int = 8 ## on-screen pixel size of one simulation tile

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------
const HOURS_PER_DAY: int = 24
const DAYS_PER_SEASON: int = 20
const SEASONS_PER_YEAR: int = 4
const REAL_SECONDS_PER_GAME_HOUR: float = 6.0 ## at 1x speed
const SIM_TICK_INTERVAL: float = 0.25 ## seconds of real time between simulation ticks
## In-game minutes simulated per tick (independent of framerate).
const GAME_MINUTES_PER_TICK: float = 10.0

# ---------------------------------------------------------------------------
# Terrain generation
# ---------------------------------------------------------------------------
const MOUNTAIN_BAND_FRACTION: float = 0.22 ## fraction of map width each range's band occupies
const MOUNTAIN_MEANDER_AMPLITUDE: float = 14.0 ## tiles the range centerline can wander
const MOUNTAIN_HEIGHT_SCALE: float = 42.0
const VALLEY_BASE_ELEVATION: float = 2.0
const VALLEY_BASIN_DEPTH: float = 3.5 ## valley center sits slightly lower -> natural water sink
const AQUIFER_NOISE_THRESHOLD: float = 0.42 ## min noise value inside mountains counted as aquifer-bearing rock
const RARE_GROUNDWATER_THRESHOLD: float = 0.86 ## very high percentile -> rare valley-floor pockets

# ---------------------------------------------------------------------------
# Water
# ---------------------------------------------------------------------------
const TILE_WATER_CAPACITY: float = 20.0 ## max surface water an unbuilt tile can hold before overflow
const STORAGE_TANK_CAPACITY: float = 400.0
const AQUIFER_RECHARGE_RATE: float = 1.6 ## units/tick a mountain tap draws, scaled by aquifer_potential
const RARE_WELL_RECHARGE_RATE: float = 0.6
const FLOW_RATE: float = 0.35 ## fraction of head-difference moved per tick (canal "flow speed")
const MIN_FLOW_EPSILON: float = 0.01
const SOIL_ABSORPTION_RATE: float = 0.5 ## fraction of adjacent open-canal water pulled into soil per tick
const SOIL_WATER_CAPACITY: float = 12.0
const SOIL_DIFFUSION_RATE: float = 0.05 ## slow capillary spread between neighboring soil tiles

# ---------------------------------------------------------------------------
# Evaporation / transpiration / humidity
# ---------------------------------------------------------------------------
const BASE_EVAPORATION_COEFF: float = 0.05 ## fraction of surface water lost per tick at reference conditions
const UNDERGROUND_SEEPAGE_COEFF: float = 0.002 ## qanat channels: near-zero evaporation
const SOIL_EVAPORATION_COEFF: float = 0.015
const WIND_EVAPORATION_FACTOR: float = 0.6 ## added evaporation per unit of wind speed (0..1 normalized)
const SHADE_EVAPORATION_SUPPRESSION: float = 0.85 ## full shade cuts evaporation by up to this fraction
const HUMIDITY_EVAPORATION_SUPPRESSION: float = 0.7 ## saturated local air suppresses evaporation
const MOISTURE_RELEASE_COEFF: float = 0.08 ## how much evaporated/transpired water raises local air_moisture
const AIR_MOISTURE_DIFFUSION: float = 0.18 ## blend factor with neighboring tiles per tick
const AIR_MOISTURE_DECAY: float = 0.01 ## humidity bleeds off into the wider desert atmosphere
const WIND_ADVECTION_STRENGTH: float = 0.35 ## how strongly wind carries humidity downwind

# ---------------------------------------------------------------------------
# Temperature (deg C) and wind
# ---------------------------------------------------------------------------
const SEASON_BASE_TEMP: Array[float] = [24.0, 41.0, 27.0, 14.0] ## Spring, Summer, Autumn, Winter (midday peak)
const SEASON_NIGHT_DROP: Array[float] = [10.0, 14.0, 9.0, 8.0] ## how far night temp falls below midday peak
const ELEVATION_LAPSE_RATE: float = 0.09 ## deg C cooler per elevation unit (mountains are cooler)
const SHADE_COOLING: float = 6.0 ## deg C cooler at full shade
const WATER_COOLING: float = 2.5 ## deg C cooler where surface water/moist soil is present
const WIND_BASE_SPEED: float = 0.35 ## normalized 0..1 baseline
const WIND_GUST_VARIANCE: float = 0.25

# ---------------------------------------------------------------------------
# Shade
# ---------------------------------------------------------------------------
const SHADE_DECAY_PER_TILE: float = 0.35 ## how quickly a canopy's shade falls off with distance
const SHADE_STRUCTURE_RADIUS: float = 2.2
const SHADE_STRUCTURE_STRENGTH: float = 0.55 ## weaker than a mature date palm, but instant and low-water

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------
const CANAL_DIG_TICKS: int = 6 ## simulated "labor" delay before a dug segment becomes active
const BUILDING_DIG_TICKS: int = 10

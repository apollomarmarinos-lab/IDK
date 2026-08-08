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
##   - open water evaporates fast; a covered channel loses almost nothing
##   - wind and heat multiply evaporation, humidity suppresses it
##   - trees draw far more water than herbs, and cast far more shade

# ---------------------------------------------------------------------------
# World / grid
# ---------------------------------------------------------------------------
const MAP_WIDTH: int = 180
const MAP_HEIGHT: int = 120
const TILE_PIXEL_SIZE: int = 24 ## on-screen pixel size of one simulation tile
## Sub-pixels per tile in the baked terrain image. 4 gives enough sub-tile
## relief and material texture to read as landform; finer detail at high
## zoom comes from the tiled grain layer in WorldRenderer.
const TERRAIN_DETAIL: int = 4

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------
const HOURS_PER_DAY: int = 24
const DAYS_PER_SEASON: int = 20
const SEASONS_PER_YEAR: int = 4
const SIM_TICK_INTERVAL: float = 0.25 ## seconds of real time between simulation ticks
## In-game minutes simulated per tick (independent of framerate).
## Set so 12 in-game hours = 10 real minutes: 720 game min / (600 real sec / 0.25 sec per tick) = 0.3
const GAME_MINUTES_PER_TICK: float = 0.3

# ---------------------------------------------------------------------------
# Terrain generation
# ---------------------------------------------------------------------------
const MOUNTAIN_BAND_FRACTION: float = 0.24 ## fraction of map width each range's band occupies
const MOUNTAIN_MEANDER_AMPLITUDE: float = 16.0 ## tiles the range centerline can wander
const MOUNTAIN_HEIGHT_SCALE: float = 55.0
const FOOTHILL_WIDTH: float = 14.0 ## tiles of talus/scree apron below the rock line
const VALLEY_BASE_ELEVATION: float = 6.0
const VALLEY_BASIN_DEPTH: float = 2.5 ## cross-valley basin so water gathers mid-valley
const VALLEY_LONG_SLOPE: float = 7.0 ## total elevation drop from north end to south outlet
const ROCK_SLOPE_THRESHOLD: float = 0.62 ## mountain-mask value above which terrain is bare rock

const WADI_COUNT: int = 7 ## seasonal drainage channels carved from the ranges
const WADI_DEPTH: float = 1.8
const WADI_WIDTH: float = 2.6
const ALLUVIUM_WIDTH: float = 5.0 ## fertile silt apron either side of a wadi
const DUNE_FREQUENCY: float = 0.055
const DUNE_HEIGHT: float = 1.6

# ---------------------------------------------------------------------------
# Aquifers (organic bodies inside the rock)
# ---------------------------------------------------------------------------
const AQUIFER_COUNT_MIN: int = 6
const AQUIFER_COUNT_MAX: int = 10
const AQUIFER_SIZE_MIN: int = 70 ## tiles in one aquifer body
const AQUIFER_SIZE_MAX: int = 320
const AQUIFER_VOLUME_PER_TILE: float = 26.0 ## stored water per tile of body
## Per tick, per tile of body. Deliberately far below what a well-built
## channel can carry away, so a heavily tapped aquifer genuinely draws down
## and only recovers over seasons if you ease off it.
const AQUIFER_RECHARGE_PER_TILE: float = 0.0025
const AQUIFER_TAP_RATE: float = 1.8 ## water/tick a single mountain canal tile can draw
## An aquifer this depleted yields proportionally less -- over-tapping a small
## body drains it and it takes a long while to come back.
const AQUIFER_PRESSURE_EXPONENT: float = 0.6

# ---------------------------------------------------------------------------
# Water
# ---------------------------------------------------------------------------
const CANAL_CAPACITY: float = 10.0 ## max water depth a canal tile holds
const CANAL_FLOOR_DEPTH: float = 1.2 ## how far a dug canal floor sits below terrain
## Mountain tunnels are bored on a descending gradient rather than following
## the surface, so their floor never sits above this datum. Set just above
## the valley floor so a tunnel always drains valley-ward. See
## WorldMap.floor_elevation().
const TUNNEL_DATUM_ELEVATION: float = VALLEY_BASE_ELEVATION + 1.5
const RESERVOIR_CAPACITY: float = 260.0
const CISTERN_CAPACITY: float = 340.0
const WELL_RECHARGE_RATE: float = 0.5 ## from rare valley groundwater pockets
## Fraction of the head difference moved between two connected tiles per tick.
## High enough that water visibly runs along a canal within a few seconds.
const FLOW_RATE: float = 0.45
const MIN_FLOW_EPSILON: float = 0.005
## Fraction of a canal tile's water pulled into one adjacent dry soil tile
## per tick. Kept low deliberately: at high values the first few metres of
## channel soak up everything and water never reaches the far end.
const SOIL_ABSORPTION_RATE: float = 0.06
const SOIL_WATER_CAPACITY: float = 12.0
const SOIL_DIFFUSION_RATE: float = 0.05 ## slow capillary spread between neighboring soil tiles
const FLOW_VECTOR_SMOOTHING: float = 0.35 ## smoothing for the on-screen flow arrows

# ---------------------------------------------------------------------------
# Evaporation / transpiration / humidity
# ---------------------------------------------------------------------------
const BASE_EVAPORATION_COEFF: float = 0.035 ## fraction of open surface water lost per tick at reference conditions
const COVERED_SEEPAGE_COEFF: float = 0.0015 ## covered channels: near-zero loss. This is the whole point of building them.
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
# Soil fertility (set by terrain type at generation)
# ---------------------------------------------------------------------------
const FERTILITY_GROWTH_FLOOR: float = 0.45 ## growth-rate multiplier on the poorest plantable ground

# ---------------------------------------------------------------------------
# UI layout
# ---------------------------------------------------------------------------
const UI_TOP_BAR_HEIGHT: float = 46.0
const UI_BOTTOM_BAR_HEIGHT: float = 62.0
const UI_SIDE_PANEL_WIDTH: float = 310.0
const UI_INSPECTOR_WIDTH: float = 340.0
const UI_INSPECTOR_HEIGHT: float = 300.0

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------
const CANAL_DIG_TICKS: int = 5
const MOUNTAIN_DIG_TICKS: int = 14 ## tunnelling through rock is slow
const BUILDING_DIG_TICKS: int = 10

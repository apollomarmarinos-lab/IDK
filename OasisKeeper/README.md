# Oasis Keeper

A desert oasis building and water-management simulation, inspired by
ClanFolk, Dwarf Fortress and RimWorld, but narrowed down to the thing those
games only touch on: **keeping a patch of desert alive with water you have
to move, store and shade yourself.** There is no money and no economy --
the only currency is water and the plants it sustains.

Built with **Godot 4.3 / GDScript**.

## Why Godot + GDScript

Godot gives a 2D scene graph, an editor, and a resource system (`.tres`)
for free, which matters a lot for a data-driven plant/building catalogue.
GDScript, used with static typing and `Packed*Array` grids instead of one
`Node` per tile, is fast enough for a simulation of this size (~30,000
tiles) as long as the *data* is laid out flat and the *systems* iterate it
in tight loops -- which is exactly how this project is structured. If the
simulation ever needs to scale to a much larger map, the systems are
already isolated enough that any one of them (WaterSystem is the obvious
candidate) could be reimplemented as a GDExtension in C++ without touching
anything else, since every system only talks to the world through
`WorldMap`'s flat arrays and the `EventBus` signals.

## Running it

Open `project.godot` in Godot 4.3+, or run headless:

```
godot --path OasisKeeper
```

A smoke test that exercises the whole build/plant/water pipeline without
needing mouse input is available:

```
godot --headless --path OasisKeeper --quit-after 3000 -- --sim-selftest
```

It digs a mountain aquifer tap, carves an open canal from it out into the
valley, plants a date palm, places a gate/storage tank/shade
structure/well outlet, and prints the tap's water level every second so you
can watch the network fill and equilibrate.

## Controls

- **Left click / drag** on the map: apply the selected tool.
- **Right click**: cancel the current tool, back to Inspect.
- **Arrow keys / WASD**: pan camera. **Scroll wheel**: zoom.
- Build palette (left panel): Inspect, Plant, the three canal types, Gate,
  Storage Tank, Shade Structure, Well/Outlet, Demolish.
- Clicking an existing gate with the Gate tool toggles it open/closed
  instead of re-placing it.

## Architecture

```
scripts/
  autoload/        Singletons: the simulation itself
    GameConfig.gd     every tuning constant, in one place
    EventBus.gd        global signals; systems never reference each other directly
    GameClock.gd       day/night + 4-season calendar, drives the fixed sim tick
    WorldMap.gd        flat per-tile data layers (elevation, water, moisture, shade...)
    ClimateSystem.gd   wind, temperature, shade, evaporation, transpiration, humidity
    WaterSystem.gd      canal flow, gates, storage, irrigation
    PlantSystem.gd      plant growth, water draw, health, harvest
    BuildSystem.gd      placement rules + construction queue for everything buildable
  world/
    MapGenerator.gd    procedural terrain (called once by WorldMap.generate)
  entities/
    PlantInstance.gd   lightweight (RefCounted) runtime state for one planted specimen
  resources/
    PlantData.gd       data-driven plant species definition (Resource)
  rendering/
    WorldRenderer.gd         terrain/water/shade images + plant MultiMesh + buildings
    NightCycleController.gd  CanvasModulate day/night tint
  camera/
    CameraController.gd
  ui/
    HUD.gd, BuildMenu.gd, TileInspector.gd   built in code, no hand-authored layouts
  MainController.gd   thin coordinator: input -> tool -> system calls

data/plants/*.tres    14 species as data files -- drop a new one in to add a plant
```

Systems never call each other's *rendering*, and never hold references to
UI. Everything either reads/writes `WorldMap`'s arrays directly (the hot
path) or communicates through `EventBus` signals (the cold path: UI
updates, harvest notifications, construction completion). This is what
makes the game "modular" in a concrete sense: `WaterSystem` doesn't know
`PlantSystem` exists except through `WorldMap.soil_moisture`, so either one
can be rewritten independently.

### Adding a new plant

Drop a new `PlantData` `.tres` resource into `data/plants/`. No code
changes needed -- `PlantSystem` scans the directory at startup. Copy an
existing file (e.g. `data/plants/rosemary.tres`) and adjust the fields; see
`scripts/resources/PlantData.gd` for what each one controls.

### Adding a new building type

1. Add an entry to `WorldMap.Structure` in `scripts/autoload/WorldMap.gd`.
2. Add its placement rule to `BuildSystem.can_place()` and its dig time to
   `BuildSystem.dig_ticks_for()`.
3. Add its behaviour (if any) to `WaterSystem.simulate_tick()`.
4. Add how it's drawn to `WorldRenderer._draw_buildings()`.
5. Add a button for it in `BuildMenu.TOOLS`.

### Tuning the simulation

Every constant that controls flow speed, evaporation rate, shade falloff,
temperature curves, drought tolerance thresholds, etc. lives in
`scripts/autoload/GameConfig.gd`, with a comment on the real-world
intuition behind each one. Nothing else hardcodes a tuning number.

## Simulation design notes

**Water.** Only tiles with a built structure hold surface water -- the
open desert never floods on its own. Three canal categories, matching the
brief:

- **Mountain tap** (`CANAL_MOUNTAIN_TAP`): can only be dug where
  `aquifer_potential > 0`, an organic noise-generated vein inside the
  mountain rock. Recharges every tick proportional to that potential.
- **Open canal** (`CANAL_OPEN`): can be carved through mountain rock (to
  connect a tap down to the valley) or anywhere in the open desert. Full
  evaporation exposure, and the main way water reaches soil -- an open
  canal tile bleeds a fraction of its water into adjacent bare-sand soil
  moisture every tick.
- **Underground/qanat canal** (`CANAL_UNDERGROUND`): a separate network
  using the `underground_water` layer, buried, nearly immune to
  evaporation (`UNDERGROUND_SEEPAGE_COEFF` is ~25x smaller than open
  evaporation). Water has to resurface through a **Well/Outlet** structure
  to reach plants -- a nod to real qanat systems.

Flow between adjacent structure tiles is a mass-conserving cellular
automaton (each tick, connected tiles trade a fraction of their
elevation+water head difference) rather than a fluid solver -- the
standard, cheap approach for this genre. A closed **gate** simply refuses
to conduct in that pass, splitting the network in two.

**Oasis microclimate.** Every open-water and moist-soil tile evaporates
each tick at a rate driven by temperature, wind, local air humidity, and
shade (`ClimateSystem._evaporation_multiplier`) -- shade alone can cut
evaporation by up to 85%. Evaporated and transpired water raises
`air_moisture` on that tile, which then diffuses to neighbors and gets
advected downwind, so a thriving planted area visibly builds up a humid
pocket that trails in the wind's direction. Shade itself is recomputed
every tick from two sources: plant canopies (radius/strength scale with
species and growth stage -- date palms cast the largest, strongest shade)
and man-made shade structures (fixed, weaker than a mature palm, but
available instantly and without the water upkeep of a tree).

**Plants.** Defined entirely in `PlantData` resources: water need, root
depth (deep-rooted trees can pull a little water from neighboring soil,
shallow herbs can't), heat tolerance, sun preference, growth stages,
harvest seasons/yield. `PlantInstance` tracks per-specimen age, growth
stage, health and accumulated water-stress days; sustained underwatering
or uncooled heat above a species' tolerance (mitigated by shade) damages
health, and health reaching zero kills the plant.

**Day/night and seasons.** `GameClock` runs a fixed-rate simulation tick
independent of framerate, a 24-hour day, and four 20-day seasons per year.
`NightCycleController` tints the whole scene via `CanvasModulate` between
a warm day color and a cool night color that never goes below a minimum
brightness -- night is visibly distinct without hiding the map.

## Known simplifications

- Shade is a canopy/structure coverage model, not real-time sun-angle
  shadow casting -- deliberate, for both performance and readability (you
  can see exactly what's shading a tile without reasoning about time of
  day).
- Water flow is a cellular automaton, not a physically simulated fluid.
- One pixel per tile, blown up with nearest-neighbor filtering, is the
  entire rendering strategy for terrain/water/shade -- there is no tile
  art. This keeps the whole grid's visual state cheap to update, and is an
  intentional placeholder look that a future art pass can replace without
  touching any simulation code (`WorldRenderer` is the only file that
  would need to change).

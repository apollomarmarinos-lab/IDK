class_name Tiles
extends RefCounted
## Shared tile enums.
##
## These live on a plain class rather than on the WorldMap autoload so that
## other scripts can use them inside `const` expressions. An autoload is a
## runtime Node instance, so `WorldMap.Structure.GATE` is not a constant and
## cannot appear in a const dictionary -- `Tiles.Structure.GATE` can.

enum Terrain {
	DUNE_SAND = 0,
	DESERT_PAVEMENT = 1,
	ALLUVIUM = 2,
	SCREE = 3,
	ROCK = 4,
}

enum Structure {
	NONE = 0,
	CANAL_OPEN = 1, ## open-air channel: cheap, but evaporates
	CANAL_COVERED = 2, ## roofed/buried channel: costs more digging, almost no evaporation
	CANAL_MOUNTAIN = 3, ## tunnel bored through rock; taps aquifers it touches
	GATE = 4,
	RESERVOIR = 5, ## open storage pond
	CISTERN = 6, ## covered storage
	SHADE_STRUCTURE = 7,
	WELL = 8, ## draws from a rare valley groundwater pocket
}

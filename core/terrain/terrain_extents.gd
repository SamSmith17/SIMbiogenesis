class_name TerrainExtents
extends RefCounted

## The ONE set of rules for a generated map's three sizes, pure and static so
## the selftest can pin them:
##   world  — the lo-res terrain square (base DEM + base imagery)
##   detail — the hi-res DEM + imagery patch in the middle
##   osm    — the square OpenStreetMap buildings / roads / water / veg come from
##
## STORAGE is always the HALF-extent in metres (centre to edge): MapContext,
## MapDefinition, extents_*.json, the world snapshot and every fetch take it.
## THE PLAYER sees the SIDE length (edge to edge). The Terrain options panel
## used to show the half-extent under the label "World size", so typing 80 km
## built a 160 km world and the loading screen (which prints the side) read
## double what was typed — and quadrupled every elevation / imagery request.
## Convert at the UI boundary with side_from_half / half_from_side, nowhere
## else.

const WORLD_HALF_DEFAULT := 15000.0    # 30 km world
const DETAIL_HALF_DEFAULT := 1500.0    # 3 km hi-res patch
const OSM_HALF_DEFAULT := 1500.0       # 3 km of OSM data

## Limits, as SIDE lengths in metres (what the player types).
const WORLD_SIDE_MIN_M := 10000.0
const WORLD_SIDE_MAX_M := 200000.0
const DETAIL_SIDE_MIN_M := 1000.0
const DETAIL_SIDE_MAX_M := 10000.0
const OSM_SIDE_MIN_M := 1000.0
const OSM_SIDE_MAX_M := 16000.0

## Past this world side the base DEM is a coarse global product and the
## first download is slow; the panel says so.
const WORLD_SIDE_SLOW_M := 120000.0


static func side_from_half(half_m: float) -> float:
	return half_m * 2.0


static func half_from_side(side_m: float) -> float:
	return side_m * 0.5


## Clamp three half-extents into their ranges and keep the hi-res patch and
## the OSM square inside the world. A value <= 0 means "not set" and takes the
## default. Returns {world_half_m, detail_half_m, osm_half_m}.
static func sanitize(world_half_m: float, detail_half_m: float, osm_half_m: float) -> Dictionary:
	var w := world_half_m if world_half_m > 0.0 else WORLD_HALF_DEFAULT
	var d := detail_half_m if detail_half_m > 0.0 else DETAIL_HALF_DEFAULT
	var o := osm_half_m if osm_half_m > 0.0 else OSM_HALF_DEFAULT
	w = clampf(w, half_from_side(WORLD_SIDE_MIN_M), half_from_side(WORLD_SIDE_MAX_M))
	d = clampf(d, half_from_side(DETAIL_SIDE_MIN_M), half_from_side(DETAIL_SIDE_MAX_M))
	o = clampf(o, half_from_side(OSM_SIDE_MIN_M), half_from_side(OSM_SIDE_MAX_M))
	d = minf(d, w)
	o = minf(o, w)
	return {"world_half_m": w, "detail_half_m": d, "osm_half_m": o}


## A sharper imagery overlay (hyper, the native site patch, the AI hero patch)
## never reaches past the hi-res patch: outside it the ground is the coarse
## world mesh (~250–700 m between vertices on a big world), so a sharp photo
## draped there sits on the wrong relief and its square edge does not line up
## with the hi-res terrain's.
static func overlay_half(want_half_m: float, detail_half_m: float) -> float:
	if want_half_m <= 0.0:
		return 0.0
	if detail_half_m <= 0.0:
		return want_half_m
	return minf(want_half_m, detail_half_m)


## The part of an ElevationService / ImageryService cache key that names the
## site and the square: both services build their keys as
## "<prefix>_<lat %.4f>_<lon %.4f>_<int half>_<...>".
static func key_token(lat: float, lon: float, half_m: float) -> String:
	return "_%.4f_%.4f_%d_" % [lat, lon, int(half_m)]


## True when a fetch result's key belongs to this site and square. The
## services are autoloads and outlive a scene: a result requested by the
## PREVIOUS load (a different size, or another map) used to be taken by the
## new loader as its own, draping an old-size image over the new terrain.
## An empty key (a caller that does not know it) is accepted.
static func key_matches(key: String, lat: float, lon: float, half_m: float) -> bool:
	if key.is_empty():
		return true
	return key.contains(key_token(lat, lon, half_m))


## One line for the Terrain options panel: what a load at these sizes builds.
static func describe(world_half_m: float, detail_half_m: float, osm_half_m: float) -> String:
	return "Builds a %s world, a %s hi-res patch and %s of map data." % [
		format_side(side_from_half(world_half_m)),
		format_side(side_from_half(detail_half_m)),
		format_side(side_from_half(osm_half_m))]


static func format_side(side_m: float) -> String:
	if side_m >= 10000.0:
		return "%.0f km" % (side_m / 1000.0)
	if side_m >= 1000.0:
		return "%s km" % String.num(side_m / 1000.0, 1)
	return "%.0f m" % side_m

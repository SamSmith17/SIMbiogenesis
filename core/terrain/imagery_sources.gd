class_name ImagerySources
extends RefCounted

## Where terrain imagery comes from, and which source is sharpest at a site.
##
## The default drape is ESRI World Imagery, which is global but stops at z19
## (~0.2 m/px at mid latitudes) and is often UPSAMPLED there from a coarser
## capture. County and state agencies fly their own orthophotos at 3–9 inch
## and many publish them as public ArcGIS tile caches on the same XYZ grid.
## A REGIONAL source listed here is preferred inside its coverage box for the
## sharp layers (hyper + the native "site" patch); ESRI's Clarity layer (a
## sharper, sometimes older capture) is the global second choice, and the
## standard ESRI tile is the last word. The chain is resolved PER TILE: a
## tile a source does not hold (blank PNG, 404, ESRI "Map data not yet
## available" placeholder) falls through to the next source, so a site on
## the edge of a county flight still gets a complete mosaic.
##
## Measured 2026-10-13 at the Mount Vernon (McMurray) site: ESRI z20+ returns
## the placeholder; ESRI z19 is soft; Clarity z19 is crisper; Skagit County's
## 2021 9-inch flight shows individual roof panels at z19. The county's 2021
## 3-inch flight stops at 48.357°N, north of that site, and its 2013/2015
## 4-inch services answer blank tiles there — extent boxes are not footprints,
## which is exactly why the per-tile fallback exists.

const TILE_PX := 256

## id → {label, url (z, y, x), max_zoom, native_m (ground sample distance of
## the capture), bbox (WGS84 degrees, regional only), attribution}.
const SOURCES := {
	"esri": {
		"label": "ESRI World Imagery",
		"url": "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/%d/%d/%d",
		"max_zoom": 19,
		"native_m": 0.3,
		"attribution": "Imagery © Esri, Maxar, Earthstar Geographics, and the GIS User Community",
	},
	"esri_clarity": {
		"label": "ESRI World Imagery (Clarity)",
		"url": "https://clarity.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tile/%d/%d/%d",
		"max_zoom": 19,
		"native_m": 0.3,
		"attribution": "Imagery © Esri, Maxar, Earthstar Geographics, and the GIS User Community",
	},
	# Skagit County GIS, public ArcGIS Server tile cache (no token). 9-inch =
	# 0.229 m ground sample distance. Service published with no license text;
	# credited as county imagery.
	"skagit_2021_9in": {
		"label": "Skagit County 2021 (9-inch)",
		"url": "https://gis.skagitcountywa.gov/arcgis/rest/services/Images/SkagitCounty2021_9inch/ImageServer/tile/%d/%d/%d",
		"max_zoom": 20,
		"native_m": 0.229,
		"bbox": {"west": -122.754128, "east": -121.230661, "south": 48.255492, "north": 48.726428},
		"attribution": "Imagery © Skagit County GIS, 2021 9-inch orthophoto",
	},
}

## Global fallbacks, sharpest first. The standard ESRI tile is always last.
const GLOBAL_CHAIN := ["esri_clarity", "esri"]


## Esri World Imagery Wayback: one source per archived RELEASE, id
## "wayback_<release id>" (WaybackCatalog; ShorelineHistory picks the release).
## The id is the cache-key suffix, so each release caches on its own.
const WAYBACK_PREFIX := "wayback_"
## Capture details per release id, filled by ShorelineHistory as it learns
## them ({date, sensor, provider, res_m, release_date}) — the attribution and
## the native resolution of a Wayback layer.
static var wayback_meta: Dictionary = {}


static func is_wayback(id: String) -> bool:
	return id.begins_with(WAYBACK_PREFIX) and id.substr(WAYBACK_PREFIX.length()).is_valid_int()


static func wayback_id(release: int) -> String:
	return WAYBACK_PREFIX + str(release)


static func has(id: String) -> bool:
	return SOURCES.has(id) or is_wayback(id)


static func info(id: String) -> Dictionary:
	if is_wayback(id):
		var rel := id.substr(WAYBACK_PREFIX.length()).to_int()
		var meta: Dictionary = wayback_meta.get(rel, {})
		return {
			"label": "Wayback " + str(meta.get("date", "release %d" % rel)),
			"url": WaybackCatalog.tile_url_template(rel),
			"max_zoom": WaybackCatalog.MAX_ZOOM,
			"native_m": maxf(float(meta.get("res_m", 0.5)), 0.15),
			"attribution": WaybackCatalog.attribution(meta) if not meta.is_empty()
				else "Imagery © Esri World Imagery Wayback",
		}
	return SOURCES.get(id, SOURCES["esri"]) as Dictionary


static func tile_url(id: String, z: int, x: int, y: int) -> String:
	return str(info(id)["url"]) % [z, y, x]


static func covers(id: String, lat: float, lon: float, margin_deg: float = 0.0) -> bool:
	var s := info(id)
	if not s.has("bbox"):
		return true
	var b: Dictionary = s["bbox"]
	return lon >= float(b["west"]) + margin_deg and lon <= float(b["east"]) - margin_deg \
		and lat >= float(b["south"]) + margin_deg and lat <= float(b["north"]) - margin_deg


## Which capture a world's sharp layers (hyper + site) use. Per world:
## world.json `terrain_imagery.sharp`, read by TerrainLoader.
##   SHARP_SHARPEST — the regional flight / Clarity chain below. Crisper, but
##                    often an OLDER photo than the layers round it.
##   SHARP_NEWEST   — plain ESRI, the capture the detail and base drapes use,
##                    so the whole map is one date. At Bombay Beach Clarity
##                    shows the Salton Sea years higher than the 2024 ESRI
##                    capture beside it, and the shoreline jumps at the edge
##                    of the sharp square.
const SHARP_SHARPEST := "sharpest"
const SHARP_NEWEST := "newest"
const SHARP_CHOICES := [SHARP_SHARPEST, SHARP_NEWEST]


static func sharp_preference(v: Variant) -> String:
	return SHARP_NEWEST if str(v) == SHARP_NEWEST else SHARP_SHARPEST


## The source chain for the sharp layers at a site: every regional source
## that covers it (finest capture first), then the global fallbacks — or
## plain ESRI alone for SHARP_NEWEST.
static func chain_for(lat: float, lon: float, prefer: String = SHARP_SHARPEST) -> Array:
	if prefer == SHARP_NEWEST:
		return default_chain()
	var regional: Array = []
	for id: String in SOURCES.keys():
		if SOURCES[id].has("bbox") and covers(id, lat, lon):
			regional.append(id)
	regional.sort_custom(func(a: String, b: String) -> bool:
		return float(info(a)["native_m"]) < float(info(b)["native_m"]))
	var out: Array = regional.duplicate()
	for g in GLOBAL_CHAIN:
		out.append(g)
	return out


## The standard global chain (detail / base layers): ESRI only, the most
## recent capture everywhere.
static func default_chain() -> Array:
	return ["esri"]


## Web-Mercator ground resolution (m/px) of zoom z at latitude lat.
static func metres_per_px(z: int, lat: float) -> float:
	return 156543.03392 * cos(deg_to_rad(lat)) / float(1 << z)


## Finest zoom worth fetching from the chain's best source: the first zoom
## whose pixels are no larger than the capture's own (times a small slack —
## fetching finer only upsamples), capped by that source's max zoom.
static func native_zoom(chain: Array, lat: float) -> int:
	var id: String = str(chain[0]) if not chain.is_empty() else "esri"
	var s := info(id)
	var gsd := float(s["native_m"])
	var cap := int(s["max_zoom"])
	for z in range(10, cap + 1):
		if metres_per_px(z, lat) <= gsd * 1.15:
			return z
	return cap


## The highest max zoom anywhere in a chain (the zoom ceiling for a layer).
static func chain_max_zoom(chain: Array) -> int:
	var z := 0
	for id in chain:
		z = maxi(z, int(info(str(id))["max_zoom"]))
	return maxi(z, 1)


## A short key for cache file names: "" for the plain ESRI chain, so every
## existing cache file keeps its name.
static func chain_key(chain: Array) -> String:
	if chain.is_empty() or (chain.size() == 1 and str(chain[0]) == "esri"):
		return ""
	return str(chain[0])


## Attribution for every source a mosaic actually used.
static func attribution_for(used: Array) -> String:
	var seen: Dictionary = {}
	var parts: PackedStringArray = []
	for id in used:
		var a := str(info(str(id))["attribution"])
		if not seen.has(a):
			seen[a] = true
			parts.append(a)
	return " · ".join(parts)


## True when a decoded tile holds no imagery: fully transparent (an ArcGIS
## cache's empty tile), or ESRI's "Map data not yet available" placeholder —
## near-uniform (90 % of a 12×12 grid within 0.03 of the median) AND neutral
## grey (mean chroma under PLACEHOLDER_MAX_CHROMA, median luminance inside
## PLACEHOLDER_LUM). The grey test is what keeps real tiles: at z18–19 open
## water, a salt flat or bare sand is just as uniform as the placeholder, and
## treating those as blank sent them to the next source — at Bombay Beach a
## NEWER ESRI capture, with the Salton Sea metres further out, pasted
## tile-by-tile into the older Clarity mosaic. Measured 2026-10-23: the
## placeholder is (204, 204, 204), chroma 0.000; Clarity sea tiles there are
## 99–100 % uniform with chroma 0.05.
const PLACEHOLDER_MAX_CHROMA := 0.02
const PLACEHOLDER_LUM := Vector2(0.6, 0.95)

static func is_blank_tile(img: Image) -> bool:
	if img == null or img.is_empty():
		return true
	var w := img.get_width()
	var h := img.get_height()
	if w < 8 or h < 8:
		return true
	var lums: Array[float] = []
	var any_opaque := false
	var chroma := 0.0
	var has_alpha := img.detect_alpha() != Image.ALPHA_NONE
	for sy in 12:
		for sx in 12:
			var c := img.get_pixel(w * (2 * sx + 1) / 24, h * (2 * sy + 1) / 24)
			if not has_alpha or c.a > 0.05:
				any_opaque = true
			lums.append((c.r + c.g + c.b) / 3.0)
			chroma += maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b))
	if not any_opaque:
		return true
	var sorted := lums.duplicate()
	sorted.sort()
	var med: float = sorted[sorted.size() / 2]
	if chroma / float(lums.size()) >= PLACEHOLDER_MAX_CHROMA \
			or med < PLACEHOLDER_LUM.x or med > PLACEHOLDER_LUM.y:
		return false
	var near := 0
	for l in lums:
		if absf(l - med) < 0.03:
			near += 1
	return float(near) / float(lums.size()) >= 0.9

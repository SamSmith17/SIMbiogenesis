class_name WaybackCatalog
extends RefCounted

## Esri World Imagery Wayback: every archived release of ESRI World Imagery,
## as XYZ tiles on the same grid ImageryService already stitches (pure:
## parsing, the capture dedupe and the capture at a date; the HTTP lives in
## ShorelineHistory).
##
## The release list:
##   https://s3-us-west-2.amazonaws.com/config.maptiles.arcgis.com/waybackconfig.json
## {"<release id>": {itemTitle "World Imagery (Wayback 2014-02-20)", itemURL
## ".../tile/<release>/{level}/{row}/{col}", metadataLayerUrl, ...}} — 197
## releases from 2014-02-20 to 2026-09-24 on 2026-10-23. Release ids do NOT
## sort by date; the date is in the title.
##
## A release is a snapshot of the whole basemap, so most releases repeat the
## photo the one before had. Two endpoints find the distinct ones:
##   tilemap  .../MapServer/tilemap/<release>/<z>/<row>/<col>/1/1 answers
##            {"data":[1], "select":[<release that last changed this tile>]}
##            (no "select" = this release itself changed it). Walking from
##            the newest release to "the release before the selected one"
##            visits each changed tile once: 14 requests over the Bombay Beach
##            shore at z17 instead of 197.
##   metadata <metadataLayerUrl>/<layer>/query at a point: SRC_DATE (the
##            capture date, yyyymmdd), SRC_RES (m), SRC_DESC (sensor),
##            NICE_DESC (provider), MinMapLevel..MaxMapLevel (the zooms that
##            capture is shown at). Layers 0..13 are resolution bands; the
##            first one from LAYER_FIRST whose zoom range covers the drape's
##            zoom names the photo actually drawn.
## Several releases then still show ONE capture (re-processed colour, a
## provider renamed: Maxar → Vantor), so captures are deduped on
## capture date + sensor, keeping the newest release of each.
##
## ⚠ 403s. About half of Wayback's Apache backends refuse Python-urllib's
## default User-Agent (measured 2026-10-23: 30 of 60 requests 403, the same
## URL 200 a moment later). Godot's own "GodotEngine/…" agent and curl were
## 60 of 60. No Referer or token is needed; the earlier "half the releases
## are forbidden" was that User-Agent, not throttling.

const CONFIG_URL := "https://s3-us-west-2.amazonaws.com/config.maptiles.arcgis.com/waybackconfig.json"
const TILE_URL := "https://wayback.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/WMTS/1.0.0/default028mm/MapServer/tile/%d/%%d/%%d/%%d"
const TILEMAP_URL := "https://wayback.maptiles.arcgis.com/arcgis/rest/services/World_Imagery/MapServer/tilemap/%d/%d/%d/%d/1/1"
const META_QUERY := "%s/%d/query?geometry=%.6f,%.6f&geometryType=esriGeometryPoint&inSR=4326&spatialRel=esriSpatialRelIntersects&outFields=SRC_DATE,SRC_RES,SRC_DESC,NICE_DESC,MinMapLevel,MaxMapLevel&returnGeometry=false&f=json"
## Wayback stops at z19 here (z20 is 404 at Bombay Beach in every release).
const MAX_ZOOM := 19
## Metadata layer 4 is the 30 cm band; 13 the coarsest.
const LAYER_FIRST := 4
const LAYER_LAST := 13
const ATTRIBUTION := "Esri World Imagery Wayback"


## Releases from the config JSON, OLDEST first:
## [{id int, date "YYYY-MM-DD" (the release date), title, meta_url}].
static func parse_config(body: String) -> Array:
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for k in (parsed as Dictionary).keys():
		var v: Variant = (parsed as Dictionary)[k]
		if not (v is Dictionary) or not str(k).is_valid_int():
			continue
		var title := str((v as Dictionary).get("itemTitle", ""))
		var date := release_date_of(title)
		if date.is_empty():
			continue
		out.append({"id": int(str(k)), "date": date, "title": title,
			"meta_url": str((v as Dictionary).get("metadataLayerUrl", ""))})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["date"]) < str(b["date"]) or (str(a["date"]) == str(b["date"]) and int(a["id"]) < int(b["id"])))
	return out


## "World Imagery (Wayback 2014-02-20)" → "2014-02-20" ("" when absent).
static func release_date_of(title: String) -> String:
	var re := RegEx.create_from_string("(\\d{4}-\\d{2}-\\d{2})")
	var m := re.search(title)
	return m.get_string(1) if m != null else ""


static func tile_url_template(release: int) -> String:
	return TILE_URL % release


static func tilemap_url(release: int, z: int, x: int, y: int) -> String:
	return TILEMAP_URL % [release, z, y, x]


static func metadata_url(meta_url: String, layer: int, lat: float, lon: float) -> String:
	return META_QUERY % [meta_url, layer, lon, lat]


## A tilemap reply: {ok, has_tile, select (release id; -1 = this one)}.
static func parse_tilemap(body: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return {"ok": false, "has_tile": false, "select": -1}
	var d: Dictionary = parsed
	var data: Array = d.get("data", [])
	var has := not data.is_empty() and int(data[0]) == 1
	var sel := -1
	var s: Array = d.get("select", [])
	if not s.is_empty():
		sel = int(s[0])
	return {"ok": true, "has_tile": has, "select": sel}


## A metadata point query: {ok, date "YYYY-MM-DD", sensor, provider, res_m,
## min_zoom, max_zoom} for the first feature ("ok" false when none).
static func parse_metadata(body: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body)
	if not (parsed is Dictionary):
		return {"ok": false}
	var feats: Array = (parsed as Dictionary).get("features", [])
	if feats.is_empty() or not (feats[0] is Dictionary):
		return {"ok": false}
	var a: Dictionary = (feats[0] as Dictionary).get("attributes", {})
	var raw := str(int(a.get("SRC_DATE", 0)))
	if raw.length() != 8:
		return {"ok": false}
	return {"ok": true,
		"date": "%s-%s-%s" % [raw.substr(0, 4), raw.substr(4, 2), raw.substr(6, 2)],
		"sensor": str(a.get("SRC_DESC", "")).strip_edges(),
		"provider": str(a.get("NICE_DESC", "")).strip_edges(),
		"res_m": snappedf(float(a.get("SRC_RES", 0.0)), 0.01),
		"min_zoom": int(a.get("MinMapLevel", 0)),
		"max_zoom": int(a.get("MaxMapLevel", 23))}


## True when a metadata feature is the photo shown at zoom z.
static func meta_covers_zoom(meta: Dictionary, z: int) -> bool:
	return bool(meta.get("ok", false)) and z >= int(meta.get("min_zoom", 0)) and z <= int(meta.get("max_zoom", 23))


## The release ids the tilemap walk visits, given a function that answers the
## tilemap of a release (release → {has_tile, select}): start at the newest,
## take the release that last changed the tile, then continue from the release
## BEFORE that one. Pure over `answer` so the selftest drives it with a table;
## the runtime walks it one HTTP reply at a time with next_in_walk().
static func walk(releases: Array, answer: Callable) -> Array:
	var visited: Array = []
	var cur := releases.size() - 1
	var guard := 0
	while cur >= 0 and guard < releases.size():
		guard += 1
		var rid := int((releases[cur] as Dictionary)["id"])
		var tm: Dictionary = answer.call(rid)
		var step := next_in_walk(releases, rid, tm)
		if int(step["changed"]) >= 0:
			visited.append(int(step["changed"]))
		cur = int(step["next_index"])
	return visited


## One step of the walk: the release that changed the tile ("changed", -1 when
## the tile does not exist there) and the index of the next release to ask
## ("next_index", -1 at the end).
static func next_in_walk(releases: Array, asked: int, tilemap: Dictionary) -> Dictionary:
	var asked_i := index_of(releases, asked)
	if not bool(tilemap.get("has_tile", false)):
		return {"changed": -1, "next_index": -1}
	var sel := int(tilemap.get("select", -1))
	var changed := asked if sel < 0 else sel
	var ci := index_of(releases, changed)
	if ci < 0 or ci > asked_i:
		ci = asked_i
		changed = asked
	return {"changed": changed, "next_index": ci - 1}


static func index_of(releases: Array, rid: int) -> int:
	for i in releases.size():
		if int((releases[i] as Dictionary)["id"]) == rid:
			return i
	return -1


## Distinct captures from release observations, OLDEST capture first. Each
## observation is {release, release_date, date, sensor, provider, res_m}
## (date = the capture date). Releases showing the same capture date + sensor
## are one capture; the NEWEST release of it is kept (its processing is the
## latest). [{release, release_date, date, sensor, provider, res_m, releases[]}]
static func dedupe(observations: Array) -> Array:
	var groups: Dictionary = {}
	for o_v in observations:
		if not (o_v is Dictionary):
			continue
		var o: Dictionary = o_v
		var date := str(o.get("date", ""))
		if date.is_empty():
			continue
		var key := "%s|%s" % [date, str(o.get("sensor", ""))]
		if not groups.has(key):
			var g := o.duplicate()
			g["releases"] = [int(o["release"])]
			groups[key] = g
			continue
		var g2: Dictionary = groups[key]
		(g2["releases"] as Array).append(int(o["release"]))
		if str(o.get("release_date", "")) > str(g2.get("release_date", "")):
			for k in ["release", "release_date", "provider", "res_m"]:
				g2[k] = o.get(k, g2.get(k))
	var out: Array = groups.values()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["date"]) < str(b["date"]) or (str(a["date"]) == str(b["date"]) and str(a["release_date"]) < str(b["release_date"])))
	return out


## The capture to show on a date ("YYYY-MM-DD"): the latest one taken on or
## before it; before the first capture, the first. {} for an empty list.
static func capture_at(captures: Array, date: String) -> Dictionary:
	if captures.is_empty():
		return {}
	var best: Dictionary = captures[0]
	for c_v in captures:
		var c: Dictionary = c_v
		if str(c["date"]) <= date:
			best = c
		else:
			break
	return best


## The capture of a release id in a list ({} when it is not there).
static func capture_of_release(captures: Array, release: int) -> Dictionary:
	for c_v in captures:
		var c: Dictionary = c_v
		if int(c.get("release", -1)) == release:
			return c
		if (c.get("releases", []) as Array).has(release):
			return c
	return {}


## Picker text: "2016-06-28 · WV02 · 0.5 m (DigitalGlobe)".
static func capture_label(c: Dictionary) -> String:
	var bits: PackedStringArray = [str(c.get("date", "?"))]
	if not str(c.get("sensor", "")).is_empty():
		bits.append(str(c["sensor"]))
	if float(c.get("res_m", 0.0)) > 0.0:
		bits.append("%s m" % String.num(float(c["res_m"]), 2))
	var s := " · ".join(bits)
	if not str(c.get("provider", "")).is_empty():
		s += " (%s)" % str(c["provider"])
	return s


## Attribution for one capture: Wayback + the release + the capture's provider.
static func attribution(c: Dictionary) -> String:
	var s := "Imagery © Esri World Imagery Wayback (release %s)" % str(c.get("release_date", "?"))
	if not str(c.get("provider", "")).is_empty():
		s += ", %s capture %s" % [str(c["provider"]), str(c.get("date", ""))]
	return s

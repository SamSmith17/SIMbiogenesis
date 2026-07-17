class_name OsmRegistration
extends RefCounted

## OSM ↔ imagery registration helpers. Black Rock City is the main case: OSM
## carries the *upcoming* event plan (Golden Spike / The Man) while ESRI World
## Imagery shows scars from a prior year. Both are WGS84-correct; they disagree
## by a few hundred metres year-to-year. A per-map east/north offset slides
## OSM local geometry onto the photo without warping the drape.

## Published Golden Spike coordinates (lat, lon). Newest first.
const BRC_GOLDEN_SPIKES: Array[Dictionary] = [
	{"year": 2026, "lat": 40.783242, "lon": -119.207871},
	{"year": 2025, "lat": 40.786958, "lon": -119.202994},
	{"year": 2024, "lat": 40.786969, "lon": -119.204101},
]

## Local metres: +X east, +Z south (matches GeoMath.lonlat_to_local_m).
static func offset_local_m(p: Vector2, east_m: float, north_m: float) -> Vector2:
	return Vector2(p.x + east_m, p.y - north_m)


static func offset_poly(poly: PackedVector2Array, east_m: float, north_m: float) -> PackedVector2Array:
	if poly.is_empty() or (absf(east_m) < 0.001 and absf(north_m) < 0.001):
		return poly
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		out[i] = offset_local_m(poly[i], east_m, north_m)
	return out


## Deep-shift every `points` / `pos` field in an OSM vectors or vegetation payload.
static func offset_payload(payload: Dictionary, east_m: float, north_m: float) -> Dictionary:
	if payload.is_empty() or (absf(east_m) < 0.001 and absf(north_m) < 0.001):
		return payload
	var out := payload.duplicate(true)
	for key in ["buildings", "roads", "landuse", "water", "solar", "polygons",
			"tree_rows", "hedge_rows", "tree_points"]:
		var arr: Variant = out.get(key, null)
		if not (arr is Array):
			continue
		var shifted: Array = []
		for item in arr:
			if not (item is Dictionary):
				shifted.append(item)
				continue
			var d: Dictionary = (item as Dictionary).duplicate(true)
			if d.has("points") and d["points"] is PackedVector2Array:
				d["points"] = offset_poly(d["points"], east_m, north_m)
			elif d.has("points") and d["points"] is Array:
				var pts := PackedVector2Array()
				for pv in d["points"]:
					if pv is Vector2:
						pts.append(offset_local_m(pv, east_m, north_m))
				d["points"] = pts
			if d.has("pos") and d["pos"] is Vector2:
				d["pos"] = offset_local_m(d["pos"], east_m, north_m)
			shifted.append(d)
		out[key] = shifted
	return out


## Centroid of The Man / Golden Spike footprint in local metres, or INF if absent.
static func find_brc_man_local(payload: Dictionary) -> Vector2:
	var best := Vector2(INF, INF)
	var best_score := -1
	for item in payload.get("buildings", []):
		if not (item is Dictionary):
			continue
		var tags: Dictionary = (item as Dictionary).get("tags", {})
		var name := str(tags.get("name", "")).to_lower()
		var score := 0
		if "golden spike" in name:
			score = 3
		elif name == "the man" or name.begins_with("the man"):
			score = 2
		elif "man pavilion" in name:
			score = 1
		if score <= best_score:
			continue
		var pts: Variant = (item as Dictionary).get("points", null)
		var poly := PackedVector2Array()
		if pts is PackedVector2Array:
			poly = pts
		elif pts is Array:
			for pv in pts:
				if pv is Vector2:
					poly.append(pv)
		if poly.size() < 3:
			continue
		var c := Vector2.ZERO
		for p in poly:
			c += p
		c /= float(poly.size())
		best = c
		best_score = score
	return best


## Suggest east/north metres to slide OSM onto the imagery-era city.
## Picks the published spike nearest the map centre as the photo target (users
## usually click the scar they see), then returns target − OSM Man.
static func suggest_brc_offset_m(center_lat: float, center_lon: float,
		payload: Dictionary) -> Vector2:
	var man_local := find_brc_man_local(payload)
	if not is_finite(man_local.x):
		return Vector2.ZERO
	var best_spike := {}
	var best_d2 := INF
	for spike in BRC_GOLDEN_SPIKES:
		var local := GeoMath.lonlat_to_local_m(
			float(spike["lat"]), float(spike["lon"]), center_lat, center_lon)
		var d2 := local.length_squared()
		if d2 < best_d2:
			best_d2 = d2
			best_spike = spike
	if best_spike.is_empty():
		return Vector2.ZERO
	var target := GeoMath.lonlat_to_local_m(
		float(best_spike["lat"]), float(best_spike["lon"]), center_lat, center_lon)
	# Local delta to add to OSM points: (east, south). Convert south→north for API.
	var d_east := target.x - man_local.x
	var d_south := target.y - man_local.y
	var suggested := Vector2(d_east, -d_south)
	var dist := suggested.length()
	# Year-to-year BRC moves are hundreds of metres; ignore noise / non-BRC.
	if dist < 80.0 or dist > 2500.0:
		return Vector2.ZERO
	return suggested

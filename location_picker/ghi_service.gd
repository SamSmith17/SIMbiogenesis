extends Node
## Autoload singleton `GhiService` — GHI grid, zones, reference cities, population
## (port of energy.ts + ghiGrid.ts + constants.ts).
## NOTE: no `class_name` because the autoload already exposes this script globally as `GhiService`.

const GHI_GRID_PATH: String = "res://data/ghi-grid.json"
const ZONE_POP_PATH: String = "res://data/zone-population.json"

# --- Zones: id 1–6, GHI kWh/m²/d half-open [lo, hi); zone 6 is [6, +inf) ---
const ZONES: Array[Dictionary] = [
	{"id": 1, "range_lo": 0.0, "range_hi": 2.0, "color": Color("#313695"), "label": "Zone 1"},
	{"id": 2, "range_lo": 2.0, "range_hi": 3.0, "color": Color("#74add1"), "label": "Zone 2"},
	{"id": 3, "range_lo": 3.0, "range_hi": 4.0, "color": Color("#fee090"), "label": "Zone 3"},
	{"id": 4, "range_lo": 4.0, "range_hi": 5.0, "color": Color("#fdae61"), "label": "Zone 4"},
	{"id": 5, "range_lo": 5.0, "range_hi": 6.0, "color": Color("#f46d43"), "label": "Zone 5"},
	{"id": 6, "range_lo": 6.0, "range_hi": INF, "color": Color("#a50026"), "label": "Zone 6"},
]

const CITIES: Array[Dictionary] = [
	{"name": "Reykjavik", "country": "Iceland", "lat": 64.1265, "lng": -21.8174, "ghi": 1.8},
	{"name": "Helsinki", "country": "Finland", "lat": 60.1695, "lng": 24.9354, "ghi": 2.1},
	{"name": "Oslo", "country": "Norway", "lat": 59.9139, "lng": 10.7522, "ghi": 2.2},
	{"name": "Stockholm", "country": "Sweden", "lat": 59.3293, "lng": 18.0686, "ghi": 2.3},
	{"name": "London", "country": "UK", "lat": 51.5074, "lng": -0.1278, "ghi": 2.6},
	{"name": "Berlin", "country": "Germany", "lat": 52.52, "lng": 13.405, "ghi": 2.8},
	{"name": "Paris", "country": "France", "lat": 48.8566, "lng": 2.3522, "ghi": 3.1},
	{"name": "Vancouver", "country": "Canada", "lat": 49.2827, "lng": -123.1207, "ghi": 3.2},
	{"name": "Seattle", "country": "USA", "lat": 47.6062, "lng": -122.3321, "ghi": 3.3},
	{"name": "New York", "country": "USA", "lat": 40.7128, "lng": -74.006, "ghi": 3.8},
	{"name": "Beijing", "country": "China", "lat": 39.9042, "lng": 116.4074, "ghi": 4.1},
	{"name": "Tokyo", "country": "Japan", "lat": 35.6762, "lng": 139.6503, "ghi": 3.6},
	{"name": "Madrid", "country": "Spain", "lat": 40.4168, "lng": -3.7038, "ghi": 4.5},
	{"name": "Rome", "country": "Italy", "lat": 41.9028, "lng": 12.4964, "ghi": 4.2},
	{"name": "San Francisco", "country": "USA", "lat": 37.7749, "lng": -122.4194, "ghi": 4.8},
	{"name": "Los Angeles", "country": "USA", "lat": 34.0522, "lng": -118.2437, "ghi": 5.2},
	{"name": "Cairo", "country": "Egypt", "lat": 30.0444, "lng": 31.2357, "ghi": 6.1},
	{"name": "Dubai", "country": "UAE", "lat": 25.2048, "lng": 55.2708, "ghi": 6.4},
	{"name": "Riyadh", "country": "Saudi Arabia", "lat": 24.7136, "lng": 46.6753, "ghi": 6.6},
	{"name": "Mumbai", "country": "India", "lat": 19.076, "lng": 72.8777, "ghi": 5.1},
	{"name": "Bangkok", "country": "Thailand", "lat": 13.7563, "lng": 100.5018, "ghi": 5.0},
	{"name": "Nairobi", "country": "Kenya", "lat": -1.2921, "lng": 36.8219, "ghi": 5.8},
	{"name": "Singapore", "country": "Singapore", "lat": 1.3521, "lng": 103.8198, "ghi": 4.5},
	{"name": "Jakarta", "country": "Indonesia", "lat": -6.2088, "lng": 106.8456, "ghi": 4.6},
	{"name": "Brasilia", "country": "Brazil", "lat": -15.7975, "lng": -47.8919, "ghi": 5.5},
	{"name": "Sydney", "country": "Australia", "lat": -33.8688, "lng": 151.2093, "ghi": 4.8},
	{"name": "Cape Town", "country": "South Africa", "lat": -33.9249, "lng": 18.4241, "ghi": 5.3},
	{"name": "Santiago", "country": "Chile", "lat": -33.4489, "lng": -70.6693, "ghi": 5.1},
	{"name": "Buenos Aires", "country": "Argentina", "lat": -34.6037, "lng": -58.3816, "ghi": 4.4},
	{"name": "Melbourne", "country": "Australia", "lat": -37.8136, "lng": 144.9631, "ghi": 4.1},
	{"name": "Phoenix", "country": "USA", "lat": 33.4484, "lng": -112.074, "ghi": 6.2},
	{"name": "Las Vegas", "country": "USA", "lat": 36.1699, "lng": -115.1398, "ghi": 6.0},
	{"name": "Mexico City", "country": "Mexico", "lat": 19.4326, "lng": -99.1332, "ghi": 5.6},
	{"name": "Lima", "country": "Peru", "lat": -12.0464, "lng": -77.0428, "ghi": 4.2},
	{"name": "Bogota", "country": "Colombia", "lat": 4.711, "lng": -74.0721, "ghi": 4.0},
	{"name": "Lagos", "country": "Nigeria", "lat": 6.5244, "lng": 3.3792, "ghi": 4.8},
	{"name": "Johannesburg", "country": "South Africa", "lat": -26.2041, "lng": 28.0473, "ghi": 5.6},
	{"name": "Perth", "country": "Australia", "lat": -31.9505, "lng": 115.8605, "ghi": 5.8},
	{"name": "Alice Springs", "country": "Australia", "lat": -23.698, "lng": 133.8807, "ghi": 6.8},
	{"name": "Antofagasta", "country": "Chile", "lat": -23.6509, "lng": -70.3975, "ghi": 7.2},
]

var _ghi_source: String = ""
var _ghi_period: String = ""
var _ghi_n_lat: int = 0
var _ghi_n_lng: int = 0
## Row-major, north first (row 0 = 90°N); JSON nulls stored as NaN
var _ghi_values: PackedFloat32Array = PackedFloat32Array()
var _grid_loaded: bool = false

var _pop_year: int = 0
var _pop_world: int = 0
var _pop_by_zone: Dictionary = {}
var _pop_method: String = ""
var _pop_loaded: bool = false

signal ghi_data_ready


func _ready() -> void:
	_load_ghi_grid()
	_load_zone_population()
	ghi_data_ready.emit()


func is_ghi_grid_loaded() -> bool:
	return _grid_loaded


func get_ghi_data_source_line() -> String:
	if _grid_loaded:
		return "NASA POWER GHI (2001–2020) — %s" % _ghi_period
	return "GHI fall back: synthetic model (no grid in res://data/ghi-grid.json)"


## --- NASA POWER bilinear sample (ghiGrid.ts) ---
func sample_ghi_grid(lat: float, lng: float) -> float:
	if _ghi_n_lat < 2 or _ghi_n_lng < 2 or _ghi_values.is_empty():
		return NAN
	var la: float = clampf(lat, -90.0, 90.0)
	var lo: float = _wrap_lng(lng)
	var row_f: float = minf(_ghi_n_lat - 1, maxf(0.0, (90.0 - la) / 180.0 * float(_ghi_n_lat - 1)))
	var col_f: float = (lo + 180.0) / 360.0 * float(_ghi_n_lng)
	if col_f >= _ghi_n_lng:
		col_f = _ghi_n_lng - 1e-9
	var r0: int = int(floor(row_f))
	var r1: int = mini(_ghi_n_lat - 1, r0 + 1)
	var c0: int = int(floor(col_f)) % _ghi_n_lng
	var c1: int = (c0 + 1) % _ghi_n_lng
	var tr: float = row_f - float(r0)
	var tc: float = col_f - floorf(col_f)

	var v00: float = _at(r0, c0)
	var v01: float = _at(r0, c1)
	var v10: float = _at(r1, c0)
	var v11: float = _at(r1, c1)
	if is_nan(v00) or is_nan(v01) or is_nan(v10) or is_nan(v11):
		return NAN
	return (v00 * (1.0 - tc) + v01 * tc) * (1.0 - tr) + (v10 * (1.0 - tc) + v11 * tc) * tr


func _at(r: int, c: int) -> float:
	var cc: int = ((c % _ghi_n_lng) + _ghi_n_lng) % _ghi_n_lng
	return _ghi_values[r * _ghi_n_lng + cc]


func _is_valid_ghi(v: float) -> bool:
	return is_finite(v) and v >= 0.0 and v < 40.0


func estimate_ghi_synthetic(lat: float, lng: float) -> float:
	var abs_lat: float = absf(lat)
	var base: float = 1.0 + 5.5 * pow(cos(deg_to_rad(abs_lat)), 1.5)
	var subtropical_boost: float = 2.5 * exp(-pow(abs_lat - 25.0, 2.0) / 200.0)
	var equatorial_dip: float = 1.2 * exp(-pow(abs_lat, 2.0) / 100.0)
	var estimated: float = base + subtropical_boost - equatorial_dip

	var hotspots: Array[Dictionary] = [
		{"lat": 25.0, "lng": 15.0, "r": 30.0, "boost": 2.0},
		{"lat": 23.0, "lng": 45.0, "r": 25.0, "boost": 1.8},
		{"lat": -24.0, "lng": -69.0, "r": 15.0, "boost": 3.0},
		{"lat": -25.0, "lng": 135.0, "r": 35.0, "boost": 1.8},
		{"lat": 35.0, "lng": -115.0, "r": 20.0, "boost": 1.6},
		{"lat": 33.0, "lng": 85.0, "r": 25.0, "boost": 1.2},
	]
	for h in hotspots:
		var d_lat: float = lat - h["lat"]
		var d_lng: float = fposmod((lng - h["lng"] + 180.0), 360.0) - 180.0
		var dist: float = sqrt(d_lat * d_lat + d_lng * d_lng)
		estimated += h["boost"] * exp(-pow(dist, 2.0) / (h["r"] * h["r"]))

	var coldspots: Array[Dictionary] = [
		{"lat": 0.0, "lng": -65.0, "r": 25.0, "drop": 1.5},
		{"lat": 0.0, "lng": 20.0, "r": 20.0, "drop": 1.4},
		{"lat": 5.0, "lng": 110.0, "r": 30.0, "drop": 1.2},
		{"lat": 60.0, "lng": 15.0, "r": 30.0, "drop": 1.0},
		{"lat": 50.0, "lng": -125.0, "r": 25.0, "drop": 0.8},
	]
	for c in coldspots:
		var d_lat2: float = lat - c["lat"]
		var d_lng2: float = fposmod((lng - c["lng"] + 180.0), 360.0) - 180.0
		var dist2: float = sqrt(d_lat2 * d_lat2 + d_lng2 * d_lng2)
		estimated -= c["drop"] * exp(-pow(dist2, 2.0) / (c["r"] * c["r"]))

	return clampf(estimated, 0.0, 10.0)


func ghi_kwh_per_m2_day(lat: float, lng: float) -> float:
	if _grid_loaded and not _ghi_values.is_empty():
		var v: float = sample_ghi_grid(lat, lng)
		if _is_valid_ghi(v):
			return v
	return estimate_ghi_synthetic(lat, lng)


func get_zone(ghi: float) -> Dictionary:
	for z in ZONES:
		if z["id"] == 6:
			if ghi >= z["range_lo"]:
				return z
		else:
			if ghi >= z["range_lo"] and ghi < z["range_hi"]:
				return z
	return ZONES[ZONES.size() - 1]


func is_opposite_hemisphere(user_lat: float, city_lat: float) -> bool:
	if user_lat > 0.0:
		return city_lat < 0.0
	if user_lat < 0.0:
		return city_lat > 0.0
	return city_lat < 0.0


func _same_city(a: Dictionary, b: Dictionary) -> bool:
	return a.get("name") == b.get("name") and a.get("country") == b.get("country") and \
		is_equal_approx(a.get("lat", 0.0), b.get("lat", 0.0)) and \
		is_equal_approx(a.get("lng", 0.0), b.get("lng", 0.0))


func find_sister_city(user_lat: float, reference_ghi: float) -> Variant:
	var pool: Array[Dictionary] = []
	for c in CITIES:
		if is_opposite_hemisphere(user_lat, c["lat"]):
			pool.append(c)
	if pool.is_empty():
		return null
	var best: Dictionary = pool[0]
	for b in pool:
		if absf(b["ghi"] - reference_ghi) <= absf(best["ghi"] - reference_ghi):
			best = b
	return best


func find_similar_cities(ghi: float, limit: int = 5, exclude: Variant = null) -> Array[Dictionary]:
	var pool: Array[Dictionary] = []
	if exclude is Dictionary and not (exclude as Dictionary).is_empty():
		var ex: Dictionary = exclude
		for c in CITIES:
			if not _same_city(c, ex):
				pool.append(c)
	else:
		pool = CITIES.duplicate()

	if pool.is_empty():
		return []

	# sort high → low by ghi
	var sorted: Array[Dictionary] = pool.duplicate()
	sorted.sort_custom(func(a, b): return a["ghi"] > b["ghi"])

	var closest: Dictionary = pool[0]
	for c in pool:
		if absf(c["ghi"] - ghi) <= absf(closest["ghi"] - ghi):
			closest = c

	var idx: int = -1
	for i in range(sorted.size()):
		if _same_city(sorted[i], closest):
			idx = i
			break
	var mid: int = floori(limit / 2.0)
	var start: int = 0 if idx == -1 else idx - mid
	start = clampi(start, 0, maxi(0, sorted.size() - limit))
	var slice: Array[Dictionary] = []
	for s in range(start, mini(start + limit, sorted.size())):
		slice.append(sorted[s].duplicate())
	var match_index: int = -1
	for i2 in range(slice.size()):
		if _same_city(slice[i2], closest):
			match_index = i2
			break
	var out: Array[Dictionary] = []
	for i3 in range(slice.size()):
		var ent: Dictionary = slice[i3].duplicate()
		ent["is_closest_match"] = (match_index == -1 and i3 == 0 and _same_city(ent, closest)) or (match_index == i3)
		out.append(ent)
	return out


func _zone_typical_ghi(z: Dictionary) -> float:
	if z["id"] == 6:
		return z["range_lo"] + 0.75
	return (z["range_lo"] + z["range_hi"]) * 0.5


func find_cities_in_zone(zone_id: int, limit: int = 5) -> Array[Dictionary]:
	var zone: Dictionary = {}
	for z in ZONES:
		if z["id"] == zone_id:
			zone = z
			break
	if zone.is_empty() or CITIES.is_empty():
		return []

	var in_zone: Array[Dictionary] = []
	for c in CITIES:
		if get_zone(c["ghi"])["id"] == zone_id:
			in_zone.append(c)
	if in_zone.is_empty():
		return []

	var target: float = _zone_typical_ghi(zone)
	var typical: Dictionary = in_zone[0]
	for c in in_zone:
		if absf(c["ghi"] - target) <= absf(typical["ghi"] - target):
			typical = c

	var sorted2: Array[Dictionary] = in_zone.duplicate()
	sorted2.sort_custom(func(a, b): return a["ghi"] > b["ghi"])
	var idx2: int = -1
	for i4 in range(sorted2.size()):
		if _same_city(sorted2[i4], typical):
			idx2 = i4
			break
	var mid2: int = floori(limit / 2.0)
	var start2: int = 0 if idx2 == -1 else idx2 - mid2
	start2 = clampi(start2, 0, maxi(0, sorted2.size() - limit))
	var slice2: Array[Dictionary] = []
	for s2 in range(start2, mini(start2 + limit, sorted2.size())):
		slice2.append(sorted2[s2].duplicate())
	var mi: int = -1
	for i5 in range(slice2.size()):
		if _same_city(slice2[i5], typical):
			mi = i5
			break
	var out2: Array[Dictionary] = []
	for i6 in range(slice2.size()):
		var ent2: Dictionary = slice2[i6].duplicate()
		ent2["is_closest_match"] = (mi == -1 and i6 == floori(slice2.size() / 2.0)) or (mi == i6)
		out2.append(ent2)
	return out2


func zone_ghi_range_label(z: Dictionary) -> String:
	if z["id"] == 6:
		return str(z["range_lo"]).trim_suffix(".0") + "+"
	return "%.0f–%.0f" % [z["range_lo"], z["range_hi"]]


func get_zone_narrative(zone_id: int) -> String:
	var text: Dictionary = {
		1: "This is the lowest band on the map: the sun is relatively weak year-round, so each panel produces less electricity than in sunnier regions. Solar can still offset part of your use—especially with efficient equipment and a good roof—but annual output stays modest compared with the global average.",
		2: "You sit in a “temperate” solar band: there is useful sunshine, but winter months are noticeably weaker than summer. Many systems here are sized to trim bills in the bright half of the year rather than to cover every kilowatt-hour in deep winter without storage.",
		3: "This is a middle-of-the-road band globally—think of typical conditions in many populated areas. Rooftop solar is broadly viable; economics depend more on electricity prices and net metering than on whether the resource is “sunny enough.”",
		4: "Solar resource is solid: horizontal surfaces receive a healthy amount of energy over the year. PV tends to perform well here for homes and businesses, and larger arrays start to look attractive where land or roofs are available.",
		5: "You are in a strong solar band. The sun delivers plenty of energy on average, so photovoltaic systems usually produce generously. This is the kind of climate where solar is often one of the cheapest new sources of electricity.",
		6: "This is among the strongest bands on Earth for horizontal sunshine. Yields per panel are high; utility-scale solar is especially attractive, though heat and soiling can still affect real-world performance.",
	}
	return str(text.get(zone_id, text[1]))


func world_population_total() -> int:
	return _pop_world


func zone_population_by_id(zone_id: int) -> int:
	return int(_pop_by_zone.get(str(zone_id), 0))


func get_population_method_text() -> String:
	return _pop_method


func get_population_year() -> int:
	return _pop_year


func is_population_data_loaded() -> bool:
	return _pop_loaded and _pop_world > 0


func get_zones() -> Array[Dictionary]:
	return ZONES


func get_population_by_zone() -> Dictionary:
	if not _pop_loaded:
		return {}
	return _pop_by_zone.duplicate()


# --- load helpers ---
func _wrap_lng(x: float) -> float:
	var lo: float = x
	while lo < -180.0:
		lo += 360.0
	while lo > 180.0:
		lo -= 360.0
	return lo


func _load_ghi_grid() -> void:
	_grid_loaded = false
	_ghi_values = PackedFloat32Array()
	if not FileAccess.file_exists(GHI_GRID_PATH):
		return
	var f: FileAccess = FileAccess.open(GHI_GRID_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var d: Dictionary = parsed
	var n_lat: int = int(d.get("nLat", 0))
	var n_lng: int = int(d.get("nLng", 0))
	var values: Variant = d.get("values", [])
	if n_lat < 2 or n_lng < 2 or not (values is Array):
		return
	_ghi_n_lat = n_lat
	_ghi_n_lng = n_lng
	_ghi_source = str(d.get("source", ""))
	_ghi_period = str(d.get("period", ""))
	var arr: Array = values
	_ghi_values.resize(arr.size())
	for i in range(arr.size()):
		var v: Variant = arr[i]
		if v == null:
			_ghi_values.set(i, NAN)
		elif v is float or v is int:
			_ghi_values.set(i, float(v))
		else:
			_ghi_values.set(i, NAN)
	if not _ghi_values.is_empty():
		_grid_loaded = true


func _load_zone_population() -> void:
	_pop_loaded = false
	_pop_by_zone = {}
	_pop_world = 0
	if not FileAccess.file_exists(ZONE_POP_PATH):
		return
	var f2: FileAccess = FileAccess.open(ZONE_POP_PATH, FileAccess.READ)
	if f2 == null:
		return
	var p: Variant = JSON.parse_string(f2.get_as_text())
	if not (p is Dictionary):
		return
	var pd: Dictionary = p
	_pop_year = int(pd.get("year", 0))
	_pop_world = int(pd.get("worldTotal", 0))
	_pop_method = str(pd.get("method", ""))
	var bz: Variant = pd.get("byZone", {})
	if bz is Dictionary:
		_pop_by_zone = (bz as Dictionary).duplicate()
		_pop_loaded = not _pop_by_zone.is_empty()

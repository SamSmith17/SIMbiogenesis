class_name FestivalAssigner
extends RefCounted

## Hands placement LOTS to the CAMPS that asked for them — the roster side of
## placement. Largest-first best-fit: the camp that needs the most ground is
## placed first, into the unassigned lot whose usable area is closest to what
## it asked for (never more than 15 % under), that offers every feature it
## requires, and whose zone allows its style. Deterministic: a stable sort and
## no randomness, so re-running on the same roster gives the same map.
##
## Headcounts are DERIVED from the camp style tables rather than guessed:
## each household template is given the number of people it sleeps, and a
## style's people-per-square-metre falls out of its template mix, fill and
## lattice cell — the same numbers the layout generator uses to place tents,
## so a lot's capacity and the households that actually appear in it agree.

## Upper bound of usable m² per size class; XL is everything above L.
const SIZE_CLASS_MAX := {"S": 300.0, "M": 700.0, "L": 1500.0}
const SIZE_CLASSES := ["S", "M", "L", "XL"]
## A lot may be this much smaller than the camp asked for and still fit.
const FIT_SLACK := 0.85
## Candidates within this share of the best fit are "as good" for adjacency.
const ADJACENCY_TOLERANCE := 0.15


## People per square metre a style packs in — fill × (weighted mean people per
## household) ÷ the household cell. `mixed` ≈ 0.027 (≈37 m², ~400 ft² per
## person), `theme_camp` ≈ 0.024, `rv_park` ≈ 0.028.
static func people_per_m2(style_id: String) -> float:
	var st := CampStyles.style(style_id)
	var mix: Dictionary = st.get("templates", {})
	var w_sum := 0.0
	var p_sum := 0.0
	for tid in mix.keys():
		var w := maxf(float(mix[tid]), 0.0)
		w_sum += w
		p_sum += w * float(CampStyles.PEOPLE_PER_TEMPLATE.get(str(tid),
			CampStyles.PEOPLE_PER_MODEL_TEMPLATE))
	if w_sum <= 0.0:
		return 0.0
	var per_household := p_sum / w_sum
	var cell := float(st.get("cell_u", 11.0)) * float(st.get("cell_v", 8.0))
	if cell <= 0.0:
		return 0.0
	return float(st.get("fill", 0.9)) * per_household / cell


static func default_headcount(usable_m2: float, style_id: String) -> int:
	return maxi(int(round(usable_m2 * people_per_m2(style_id))), 0)


static func size_class(usable_m2: float) -> String:
	for cls in ["S", "M", "L"]:
		if usable_m2 < float(SIZE_CLASS_MAX[cls]):
			return cls
	return "XL"


## Usable m² a roster entry wants: its explicit request, else its headcount at
## its style's density, else the middle of its size class.
static func requested_m2(entry: Dictionary) -> float:
	var req := float(entry.get("requested_m2", 0.0))
	if req > 0.0:
		return req
	var hc := int(entry.get("headcount", 0))
	if hc > 0:
		var ppm := people_per_m2(str(entry.get("style", CampStyles.DEFAULT_STYLE)))
		if ppm > 0.0:
			return float(hc) / ppm
	match str(entry.get("size_class", "M")):
		"S": return 200.0
		"M": return 500.0
		"L": return 1100.0
		_: return 2000.0


## lots: the layer's lot records; roster: its roster entries; zones_by_id:
## {zone_id: zone record} for style/feature rules.
## Returns {assignments: {lot_id: assigned_camp}, unplaced: [roster ids],
##          warnings: [String]}. Manual assignments are never touched; lots
## left over get the zone's default style and a derived headcount.
static func assign(lots: Array, roster: Array, zones_by_id: Dictionary) -> Dictionary:
	var out := {"assignments": {}, "unplaced": [], "warnings": []}
	var taken: Dictionary = {}       # lot_id -> true
	var placed_roster: Dictionary = {}  # roster_id -> lot record
	for lot in lots:
		var ac: Dictionary = lot.get("assigned_camp", {})
		if bool(ac.get("manual", false)) and not ac.is_empty():
			taken[str(lot["lot_id"])] = true
			var rid := str(ac.get("roster_id", ""))
			if not rid.is_empty():
				placed_roster[rid] = lot
	var order: Array = []
	for e in roster:
		if e is Dictionary and not placed_roster.has(str((e as Dictionary).get("id", ""))):
			order.append(e)
	order.sort_custom(func(a, b):
		var ra := requested_m2(a)
		var rb := requested_m2(b)
		if absf(ra - rb) > 1e-6:
			return ra > rb
		return str(a.get("id", "")) < str(b.get("id", "")))
	for e in order:
		var entry: Dictionary = e
		var want := requested_m2(entry)
		var reqs: Array = entry.get("requirements", [])
		var style := str(entry.get("style", CampStyles.DEFAULT_STYLE))
		var cands: Array = []   # [diff, lot]
		for lot in lots:
			var lid := str(lot.get("lot_id", ""))
			if lid.is_empty() or taken.has(lid) or bool(lot.get("locked", false)):
				continue
			var usable := float(lot.get("usable_m2", 0.0))
			if usable < want * FIT_SLACK:
				continue
			if not _features_ok(lot, zones_by_id, reqs):
				continue
			if not _style_ok(lot, zones_by_id, style):
				continue
			cands.append([absf(usable - want), lot])
		if cands.is_empty():
			out["unplaced"].append(str(entry.get("id", "")))
			out["warnings"].append("%s (%s, %.0f m²) has no fitting lot" % [
				str(entry.get("name", entry.get("id", "?"))),
				str(entry.get("size_class", size_class(want))), want])
			continue
		cands.sort_custom(func(a, b):
			if absf(float(a[0]) - float(b[0])) > 1e-6:
				return float(a[0]) < float(b[0])
			return str(a[1].get("lot_id", "")) < str(b[1].get("lot_id", "")))
		var pick: Dictionary = cands[0][1]
		var best_diff := float(cands[0][0])
		# Adjacency: among near-equal fits, sit next to a friend already placed.
		var friends: Array = entry.get("adjacent_to", [])
		if not friends.is_empty():
			for c in cands:
				if float(c[0]) > best_diff + ADJACENCY_TOLERANCE * maxf(want, 1.0):
					break
				if _touches_friend(c[1], friends, placed_roster):
					pick = c[1]
					break
		var lid := str(pick["lot_id"])
		taken[lid] = true
		placed_roster[str(entry.get("id", ""))] = pick
		out["assignments"][lid] = {
			"roster_id": str(entry.get("id", "")),
			"name": str(entry.get("name", lid)),
			"style": style,
			"headcount": int(entry.get("headcount", 0)) if int(entry.get("headcount", 0)) > 0 \
				else default_headcount(float(pick.get("usable_m2", 0.0)), style),
			"requirements": reqs.duplicate(),
			"manual": false,
		}
	# Everything left gets the zone default.
	for lot in lots:
		var lid := str(lot.get("lot_id", ""))
		if lid.is_empty() or taken.has(lid) or bool(lot.get("locked", false)) \
				or (out["assignments"] as Dictionary).has(lid):
			continue
		var zone: Dictionary = zones_by_id.get(str(lot.get("zone_id", "")), {})
		var styles: Array = (zone.get("spec", {}) as Dictionary).get("styles", [])
		var style0 := str(styles[0]) if not styles.is_empty() else CampStyles.DEFAULT_STYLE
		out["assignments"][lid] = {
			"roster_id": "", "name": str(lot.get("name", lid)), "style": style0,
			"headcount": default_headcount(float(lot.get("usable_m2", 0.0)), style0),
			"requirements": [], "manual": false,
		}
	return out


static func _features_ok(lot: Dictionary, zones_by_id: Dictionary, reqs: Array) -> bool:
	if reqs.is_empty():
		return true
	var have: Dictionary = {}
	for f in lot.get("features", []):
		have[str(f)] = true
	var zone: Dictionary = zones_by_id.get(str(lot.get("zone_id", "")), {})
	for f in zone.get("features", []):
		have[str(f)] = true
	for r in reqs:
		if not have.has(str(r)):
			return false
	return true


static func _style_ok(lot: Dictionary, zones_by_id: Dictionary, style: String) -> bool:
	var zone: Dictionary = zones_by_id.get(str(lot.get("zone_id", "")), {})
	if zone.is_empty():
		return true
	var styles: Array = (zone.get("spec", {}) as Dictionary).get("styles", [])
	return styles.is_empty() or styles.has(style)


static func _touches_friend(lot: Dictionary, friends: Array, placed: Dictionary) -> bool:
	var grown: Array = Geometry2D.offset_polygon(lot.get("polygon", PackedVector2Array()), 1.0)
	if grown.is_empty():
		return false
	for fid in friends:
		var fl: Dictionary = placed.get(str(fid), {})
		if fl.is_empty():
			continue
		if CampAreaLayer._overlaps(grown[0], fl.get("polygon", PackedVector2Array())):
			return true
	return false

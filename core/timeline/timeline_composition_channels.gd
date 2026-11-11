class_name TimelineCompositionChannels
extends RefCounted
## Water and nutrients as timeline tracks (resource composition plan
## Phase 4). Pure: the systems graph view supplies the readers.
##
## Stock channels (`kind` "stock") are summed over every store's own
## ResourceTimeline (level × capacity × the kind's make-up), so they are
## exact at any instant the tank timelines hold and they scrub backwards.
## Water recovery (`kind` "recovery") comes from ElementHistory's hourly
## bins: recovered ÷ used water, in %.
## A track's source is "composition" and its channel one of the ids below.

const SOURCE := "composition"

const CHANNELS := [
	{"id": "comp_water", "label": "Usable water stored", "kind": "stock", "lens": "water_usable",
		"si": "L", "color": Color(0.22, 0.78, 0.95), "floor_zero": true},
	{"id": "comp_water_bound", "label": "Water in other stores", "kind": "stock", "lens": "water_bound",
		"si": "L", "color": Color(0.40, 0.62, 0.80), "floor_zero": true},
	{"id": "comp_C", "label": "Carbon stored", "kind": "stock", "lens": "C", "si": "kg",
		"color": Color(0.62, 0.66, 0.70), "floor_zero": true},
	{"id": "comp_N", "label": "Nitrogen stored", "kind": "stock", "lens": "N", "si": "kg",
		"color": Color(0.45, 0.58, 1.00), "floor_zero": true},
	{"id": "comp_P", "label": "Phosphorus stored", "kind": "stock", "lens": "P", "si": "kg",
		"color": Color(1.00, 0.68, 0.30), "floor_zero": true},
	{"id": "comp_K", "label": "Potassium stored", "kind": "stock", "lens": "K", "si": "kg",
		"color": Color(0.78, 0.50, 1.00), "floor_zero": true},
	{"id": "comp_recovery", "label": "Water recovery", "kind": "recovery", "si": "%",
		"color": Color(0.36, 0.85, 0.60), "fixed": [0.0, 100.0]},
]

## Stock tracks read the tank timelines every this many hours inside a bin
## (they are on a 1-minute grid; a quarter hour keeps a week's view cheap).
const STOCK_NATIVE_H := 0.25


static func find(id: String) -> Dictionary:
	for c in CHANNELS:
		if str(c["id"]) == id:
			return c
	return {}


static func is_composition(id: String) -> bool:
	return not find(id).is_empty()


## The per-unit amount a store of `kind` contributes to a stock lens:
## element kg, or water kg split usable (clean water kinds) / bound.
static func per_unit(kind: String, lens: String) -> float:
	if not CompositionCatalog.is_material(kind):
		return 0.0
	var emb := CompositionCatalog.embodied(kind, 1.0)
	if not bool(emb["known"]):
		return 0.0
	match lens:
		"water_usable":
			return float(emb["water_kg"]) if CompositionCatalog.is_clean_water(kind) else 0.0
		"water_bound":
			return 0.0 if CompositionCatalog.is_clean_water(kind) else float(emb["water_kg"])
	return float((emb["elements"] as Dictionary).get(lens, 0.0))


## Stores counted by the stock tracks, as [{id, kind, cap, k}] where k is
## the lens amount per unit of capacity-full (level 1.0 × capacity × per
## unit). Same rules as ElementLedger's stocks: no unlimited supplies, no
## outlet sinks, no ghosts.
static func stock_terms(items: Array, lens: String) -> Array:
	var out: Array = []
	for it in items:
		var d: Dictionary = it
		if str(d.get("type", "")) != "resource" or bool(d.get("is_ghost", false)):
			continue
		var sp: Dictionary = d.get("specs", {})
		if bool(sp.get("unlimited_capacity", false)) or bool(sp.get("outlet_sink", false)) \
				or bool(sp.get("allow_negative", false)):
			continue
		var kind := str(sp.get("resource_kind", ""))
		var pu := per_unit(kind, lens)
		if pu <= 0.0:
			continue
		var cap := maxf(float(sp.get("capacity_qty", 100.0)), 0.0)
		out.append({"id": str(d.get("id", "")), "kind": kind, "cap": cap, "k": cap * pu})
	return out


## Zoom-stable bins of a stock: `level_of` = Callable(item id, abs hours)
## -> level 0..1 (NAN unknown).
static func stock_bins(terms: Array, level_of: Callable, w: float, i0: int, n: int) -> Dictionary:
	if terms.is_empty() or not level_of.is_valid():
		return TimelineBinning.empty(w, i0, n)
	var f := func(t: float) -> float:
		var sum := 0.0
		var any := false
		for term in terms:
			var lv := float(level_of.call(str(term["id"]), t))
			if is_nan(lv):
				continue
			any = true
			sum += clampf(lv, 0.0, 1.0) * float(term["k"])
		return sum if any else NAN
	return TimelineBinning.from_function(f, STOCK_NATIVE_H, w, i0, n)


## Zoom-stable bins of water recovery (%) from ElementHistory.recovery_series().
static func recovery_bins(series: Array, w: float, i0: int, n: int, until: float) -> Dictionary:
	if series.size() < 2:
		return TimelineBinning.empty(w, i0, n)
	var times: PackedFloat64Array = series[0]
	var vals: PackedFloat32Array = series[1]
	var pct := PackedFloat32Array()
	pct.resize(vals.size())
	for i in vals.size():
		pct[i] = vals[i] * 100.0
	return TimelineBinning.from_steps(times, pct, w, i0, n, ElementHistory.BIN_H, until)

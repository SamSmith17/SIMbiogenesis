class_name ElementHistory
extends RefCounted

## What moved, element by element, over sim time (resource composition plan
## Phase 4): the windows behind the cycle Sankey and the water-recovery
## timeline track. Pure; the systems graph view feeds it ElementLedger
## results about once a second on the sim clock.
##
## record(abs_h, led) integrates the ledger's RATES (per hour) over the sim
## hours since the last call into hourly bins, the CampFlowMeter way:
##   * clock moving forward (≤ JUMP_H): the rates are held across the gap
##   * clock moved back: every bin after the new time is dropped (a scrub
##     back undoes what it records, like the tank timelines)
##   * a jump of more than JUMP_H: nothing is counted for it (a date change)
## Each bin holds lens vectors (ElementLens.INDEX order, kg or MJ):
##   edges  {key: vec}  per material wire, key "src>tgt|kind"
##   ends   {key: [src, tgt, kind]}
##   node_air_out / node_air_in {node id: vec}  what each node gives to and
##          takes from the air
##   node_dumped {node id: vec}  unwired optional outputs drained off site
##   rain, imports, exports, dumped, cross_in, cross_out, air_out, air_in: vec
##   water_used, water_rec (kg), hours (sim hours counted)
## Bins older than MAX_BINS hours before the newest are dropped.

const BIN_H := 1.0
const JUMP_H := 6.0
const MAX_BINS := 24 * 14

var _bins: Dictionary = {}   # int hour index -> bin
var _last_h := NAN
var _last_led: Dictionary = {}
var names: Dictionary = {}   # item id -> name, from the latest ledger


func clear() -> void:
	_bins.clear()
	_last_h = NAN
	_last_led = {}


func last_hour() -> float:
	return _last_h


func bin_count() -> int:
	return _bins.size()


## Count the ledger's rates up to `abs_h`. The rates counted for a gap are
## the PREVIOUS ledger's (what was flowing during it).
func record(abs_h: float, led: Dictionary) -> void:
	_remember_names(led)
	if is_nan(_last_h):
		_last_h = abs_h
		_last_led = led
		return
	var dt := abs_h - _last_h
	if dt < -1e-9:
		truncate_after(abs_h)
		_last_h = abs_h
		_last_led = led
		return
	if dt > JUMP_H:
		_last_h = abs_h
		_last_led = led
		return
	if dt <= 0.0:
		_last_led = led
		return
	var src_led: Dictionary = _last_led if not _last_led.is_empty() else led
	var t := _last_h
	while t < abs_h - 1e-9:
		var idx := floori(t / BIN_H)
		var t_end := minf(float(idx + 1) * BIN_H, abs_h)
		_add(idx, src_led, t_end - t)
		t = t_end
	_last_h = abs_h
	_last_led = led
	_trim()


## Drop everything counted after `abs_h` (a scrub back).
func truncate_after(abs_h: float) -> void:
	var cut := floori(abs_h / BIN_H)
	for k in _bins.keys():
		var idx := int(k)
		if idx > cut:
			_bins.erase(k)
		elif idx == cut:
			# The bin the clock is now inside: keep only its share up to abs_h.
			var b: Dictionary = _bins[k]
			var keep := clampf(abs_h - float(idx) * BIN_H, 0.0, BIN_H)
			var had := float(b["hours"])
			if had > keep + 1e-9:
				_scale_bin(b, keep / had if had > 0.0 else 0.0)


## The sums over [t0, t1) (abs hours), in the bin layout plus `hours` (the
## sim hours actually counted inside the window). Partial bins count by
## their overlap.
func window(t0: float, t1: float) -> Dictionary:
	var out := _empty_bin()
	if t1 <= t0:
		return out
	for k in _bins.keys():
		var idx := int(k)
		var b0 := float(idx) * BIN_H
		var b1 := b0 + BIN_H
		var ov := minf(b1, t1) - maxf(b0, t0)
		if ov <= 0.0:
			continue
		var b: Dictionary = _bins[k]
		var share := ov / BIN_H
		_merge(out, b, share)
	return out


## A window of the ledger as it is NOW: one hour of its rates (so amounts
## read per hour).
static func from_ledger(led: Dictionary) -> Dictionary:
	var h := ElementHistory.new()
	var b := h._empty_bin()
	h._accumulate(b, led, 1.0)
	return b


## Water recovery per bin, for the timeline: (times, ratios) of bins with
## used water. Ratio = recovered / used, clamped to 0..1.
func recovery_series() -> Array:
	var keys := _bins.keys()
	keys.sort()
	var times := PackedFloat64Array()
	var vals := PackedFloat32Array()
	for k in keys:
		var b: Dictionary = _bins[k]
		var used := float(b["water_used"])
		if used <= 1e-9:
			continue
		times.append(float(int(k)) * BIN_H)
		vals.append(clampf(float(b["water_rec"]) / used, 0.0, 1.0))
	return [times, vals]


# --- internals -----------------------------------------------------------------

static func _vec() -> PackedFloat64Array:
	var v := PackedFloat64Array()
	v.resize(ElementLens.SIZE)
	return v


func _empty_bin() -> Dictionary:
	return {"edges": {}, "ends": {}, "node_air_out": {}, "node_air_in": {}, "node_dumped": {},
		"rain": _vec(), "imports": _vec(), "exports": _vec(), "dumped": _vec(),
		"cross_in": _vec(), "cross_out": _vec(), "air_out": _vec(), "air_in": _vec(),
		"water_used": 0.0, "water_rec": 0.0, "hours": 0.0}


func _add(idx: int, led: Dictionary, h: float) -> void:
	if not _bins.has(idx):
		_bins[idx] = _empty_bin()
	_accumulate(_bins[idx], led, h)


func _accumulate(b: Dictionary, led: Dictionary, h: float) -> void:
	b["hours"] = float(b["hours"]) + h
	var edges: Dictionary = b["edges"]
	var ends: Dictionary = b["ends"]
	for e in led.get("edges", []):
		var ed: Dictionary = e
		var key := "%s>%s|%s" % [str(ed["src"]), str(ed["tgt"]), str(ed["kind"])]
		if not edges.has(key):
			edges[key] = _vec()
			ends[key] = [str(ed["src"]), str(ed["tgt"]), str(ed["kind"])]
		edges[key] = _plus(edges[key], ElementLens.vector(ed["emb"]), h)
	var bd: Dictionary = led.get("boundary", {})
	_add_side(b, "rain", bd.get("rain", {}), h)
	_add_side(b, "imports", bd.get("imports", {}), h)
	_add_side(b, "exports", bd.get("exports", {}), h)
	_add_side(b, "cross_in", bd.get("in", {}), h)
	_add_side(b, "cross_out", bd.get("out", {}), h)
	_add_side(b, "dumped", led.get("dumped", {}), h)
	var air: Dictionary = led.get("air", {})
	_add_side(b, "air_out", air.get("out", {}), h)
	_add_side(b, "air_in", air.get("in", {}), h)
	for id in (led.get("nodes", {}) as Dictionary).keys():
		var n: Dictionary = led["nodes"][id]
		var gases: Dictionary = n.get("air", {})
		for g in gases.keys():
			var kg := float(gases[g])
			if absf(kg) <= 0.0:
				continue
			var ge := CompositionCatalog.component_elements(str(g))
			var gv := _vec()
			for el in ge.keys():
				if ElementLens.INDEX.has(el):
					gv[int(ElementLens.INDEX[el])] = absf(kg) * float(ge[el])
			if str(g) == "H2O":
				gv[int(ElementLens.INDEX["water"])] = absf(kg)
			var into: Dictionary = b["node_air_out"] if kg > 0.0 else b["node_air_in"]
			if not into.has(id):
				into[id] = _vec()
			into[id] = _plus(into[id], gv, h)
		var dmp: Dictionary = n.get("dumped", {})
		if float(dmp.get("kg_h", 0.0)) > 0.0:
			var nd: Dictionary = b["node_dumped"]
			if not nd.has(id):
				nd[id] = _vec()
			nd[id] = _plus(nd[id], ElementLens.vector(dmp), h)
	var w: Dictionary = led.get("water", {})
	b["water_used"] = float(b["water_used"]) + float(w.get("used_kg_h", 0.0)) * h
	b["water_rec"] = float(b["water_rec"]) + float(w.get("recovered_kg_h", 0.0)) * h


func _add_side(b: Dictionary, key: String, side: Dictionary, h: float) -> void:
	if side.is_empty():
		return
	b[key] = _plus(b[key], ElementLens.vector(side), h)


## a + v × h. Packed arrays held in a Dictionary are values: the caller
## assigns the result back.
static func _plus(a: PackedFloat64Array, v: PackedFloat64Array, h: float) -> PackedFloat64Array:
	var r := a
	for i in ElementLens.SIZE:
		r[i] += v[i] * h
	return r


func _merge(out: Dictionary, b: Dictionary, share: float) -> void:
	out["hours"] = float(out["hours"]) + float(b["hours"]) * share
	out["water_used"] = float(out["water_used"]) + float(b["water_used"]) * share
	out["water_rec"] = float(out["water_rec"]) + float(b["water_rec"]) * share
	for key in ["rain", "imports", "exports", "dumped", "cross_in", "cross_out", "air_out", "air_in"]:
		out[key] = _plus(out[key], b[key], share)
	for key2 in ["edges", "node_air_out", "node_air_in", "node_dumped"]:
		var o: Dictionary = out[key2]
		var src: Dictionary = b[key2]
		for k in src.keys():
			o[k] = _plus(o.get(k, _vec()), src[k], share)
	var ends: Dictionary = out["ends"]
	for k2 in (b["ends"] as Dictionary).keys():
		ends[k2] = b["ends"][k2]


func _scale_bin(b: Dictionary, f: float) -> void:
	b["hours"] = float(b["hours"]) * f
	b["water_used"] = float(b["water_used"]) * f
	b["water_rec"] = float(b["water_rec"]) * f
	for key in ["rain", "imports", "exports", "dumped", "cross_in", "cross_out", "air_out", "air_in"]:
		var v: PackedFloat64Array = b[key]
		for i in ElementLens.SIZE:
			v[i] *= f
		b[key] = v
	for key2 in ["edges", "node_air_out", "node_air_in", "node_dumped"]:
		var d: Dictionary = b[key2]
		for k in d.keys():
			var v2: PackedFloat64Array = d[k]
			for i2 in ElementLens.SIZE:
				v2[i2] *= f
			d[k] = v2


func _trim() -> void:
	if _bins.size() <= MAX_BINS:
		return
	var newest := floori(_last_h / BIN_H)
	for k in _bins.keys():
		if int(k) < newest - MAX_BINS:
			_bins.erase(k)


func _remember_names(led: Dictionary) -> void:
	for id in (led.get("nodes", {}) as Dictionary).keys():
		names[str(id)] = str((led["nodes"][id] as Dictionary).get("name", id))
	for s in led.get("stores", []):
		names[str((s as Dictionary)["id"])] = str((s as Dictionary)["name"])

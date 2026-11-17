class_name ScadaHistorian
extends RefCounted
## What every tag did, on the SIM clock (plans/SCADA_PROCESS_PLAN.md, Phase 1).
##
## Change-only samples per tag (absolute sim hours, float32 value); a value
## holds until the next one. Read back through TimelineBinning.from_steps, the
## timeline's own zoom-stable bins, so a trend never changes shape with zoom.
##
## Rules it keeps (the EnergyTimeline's):
##   • a scrub BACK drops everything after the new time (that future is a
##     prediction no longer made);
##   • a jump forward past `MAX_GAP_H` leaves a gap (nothing was simulated);
##   • NAN (unavailable) ends the held value.
##
## Pure and autoload-free. Saved per world as plain arrays (`to_dict`).

const VERSION := 1
## Samples kept per WATCHED tag (one a trend, mimic or alarm uses); the
## oldest half is dropped past it. Every other tag keeps a short history, so
## a trend opened on it is not empty.
const MAX_SAMPLES := 12000
const MAX_SAMPLES_UNWATCHED := 1500
## A reading older than this no longer holds.
const MAX_GAP_H := 6.0
## A change smaller than this share of the tag's seen range is not recorded
## (keeps a noisy sensor from filling the buffer).
const DEADBAND_SHARE := 0.002
## Even an unchanged value is re-recorded this often, so "still 62 %" is known.
const KEEPALIVE_H := 1.0

var _t: Dictionary = {}    # id -> PackedFloat64Array
var _v: Dictionary = {}    # id -> PackedFloat32Array
var _lo: Dictionary = {}
var _hi: Dictionary = {}
var _last_h := NAN
## id -> true: tags kept long and saved with the world.
var watched: Dictionary = {}


## Record every tag's value at `abs_h`. `tags` = ScadaTags dictionaries.
func record(tags: Array, abs_h: float) -> void:
	if is_nan(abs_h):
		return
	if not is_nan(_last_h) and abs_h < _last_h - 1e-6:
		truncate_after(abs_h)
	_last_h = abs_h
	for t in tags:
		if t is Dictionary:
			var v := float(t.get("value", NAN))
			if not bool(t.get("available", false)):
				v = NAN
			add(str(t.get("id", "")), abs_h, v)


func add(id: String, abs_h: float, v: float) -> void:
	if id.is_empty():
		return
	if not _t.has(id):
		if is_nan(v):
			return
		_t[id] = PackedFloat64Array()
		_v[id] = PackedFloat32Array()
		_lo[id] = v
		_hi[id] = v
	var ts: PackedFloat64Array = _t[id]
	var vs: PackedFloat32Array = _v[id]
	var n := ts.size()
	if n > 0:
		if abs_h <= ts[n - 1]:
			return
		var last := vs[n - 1]
		var same := (is_nan(v) and is_nan(last)) or (not is_nan(v) and not is_nan(last)
				and absf(v - last) <= maxf(float(_hi[id]) - float(_lo[id]), 1e-9) * DEADBAND_SHARE)
		if same and abs_h - ts[n - 1] < KEEPALIVE_H:
			return
	if not is_nan(v):
		_lo[id] = minf(float(_lo[id]), v)
		_hi[id] = maxf(float(_hi[id]), v)
	ts.append(abs_h)
	vs.append(v)
	var cap := MAX_SAMPLES if watched.has(id) else MAX_SAMPLES_UNWATCHED
	if ts.size() > cap:
		var cut := ts.size() - cap / 2
		ts = ts.slice(cut)
		vs = vs.slice(cut)
	_t[id] = ts
	_v[id] = vs


## Forget everything after `abs_h` (the clock went back).
func truncate_after(abs_h: float) -> void:
	for id in _t.keys():
		var ts: PackedFloat64Array = _t[id]
		var keep := ts.bsearch(abs_h, false)
		if keep < ts.size():
			_t[id] = ts.slice(0, keep)
			_v[id] = (_v[id] as PackedFloat32Array).slice(0, keep)
	_last_h = abs_h


func clear() -> void:
	_t.clear()
	_v.clear()
	_lo.clear()
	_hi.clear()
	_last_h = NAN


func ids() -> Array:
	return _t.keys()


func size(id: String) -> int:
	return (_t.get(id, PackedFloat64Array()) as PackedFloat64Array).size()


## [first, last] hour recorded, [NAN, NAN] when none (never a Vector2:
## absolute hours need 64 bits).
func range_of(id: String) -> PackedFloat64Array:
	var ts: PackedFloat64Array = _t.get(id, PackedFloat64Array())
	if ts.is_empty():
		return PackedFloat64Array([NAN, NAN])
	return PackedFloat64Array([ts[0], ts[ts.size() - 1]])


## The value held at `abs_h`; NAN before the first sample, in a gap, or
## while unavailable.
func value_at(id: String, abs_h: float) -> float:
	var ts: PackedFloat64Array = _t.get(id, PackedFloat64Array())
	if ts.is_empty():
		return NAN
	var i := ts.bsearch(abs_h, false) - 1
	if i < 0 or abs_h - ts[i] > MAX_GAP_H:
		return NAN
	return (_v[id] as PackedFloat32Array)[i]


## Zoom-stable bins {w, i0, n, mn, mean, mx} of one tag; nothing after `until`.
func bins_exact(id: String, w: float, i0: int, n: int, until: float = INF) -> Dictionary:
	if not _t.has(id):
		return TimelineBinning.empty(w, i0, n)
	var ts: PackedFloat64Array = _t[id]
	var vs: PackedFloat32Array = _v[id]
	# from_steps holds a NAN like any value; cut the series at each NAN so an
	# unavailable stretch is a gap.
	var out := TimelineBinning.empty(w, i0, n)
	var a := 0
	var cnt := ts.size()
	while a < cnt:
		while a < cnt and is_nan(vs[a]):
			a += 1
		var b := a
		while b < cnt and not is_nan(vs[b]):
			b += 1
		if b > a:
			var stop := until if b >= cnt else minf(until, ts[b])
			var part := TimelineBinning.from_steps(ts.slice(a, b), vs.slice(a, b), w, i0, n, MAX_GAP_H, stop)
			_merge(out, part)
		a = b
	return out


static func _merge(into: Dictionary, part: Dictionary) -> void:
	var mn: PackedFloat32Array = into["mn"]
	var me: PackedFloat32Array = into["mean"]
	var mx: PackedFloat32Array = into["mx"]
	var pmn: PackedFloat32Array = part["mn"]
	var pme: PackedFloat32Array = part["mean"]
	var pmx: PackedFloat32Array = part["mx"]
	for i in mn.size():
		if is_nan(pme[i]):
			continue
		if is_nan(me[i]):
			mn[i] = pmn[i]
			me[i] = pme[i]
			mx[i] = pmx[i]
		else:
			mn[i] = minf(mn[i], pmn[i])
			mx[i] = maxf(mx[i], pmx[i])
			me[i] = (me[i] + pme[i]) * 0.5
	into["mn"] = mn
	into["mean"] = me
	into["mx"] = mx


# ── save / load ─────────────────────────────────────────────────────────────

## Plain data for the world's file. `keep_ids` (non-empty) limits it to the
## tags something uses; each is thinned to `max_per_tag` samples.
func to_dict(keep_ids: Array = [], max_per_tag: int = 2000) -> Dictionary:
	var tags := {}
	for id in _t.keys():
		if not keep_ids.is_empty() and not keep_ids.has(id):
			continue
		var ts: PackedFloat64Array = _t[id]
		var vs: PackedFloat32Array = _v[id]
		var step := maxi(1, int(ceil(float(ts.size()) / float(maxi(max_per_tag, 1)))))
		var ta: Array = []
		var va: Array = []
		var i := 0
		while i < ts.size():
			ta.append(ts[i])
			va.append(null if is_nan(vs[i]) else vs[i])
			i += step
		tags[id] = {"t": ta, "v": va}
	return {"version": VERSION, "tags": tags}


func from_dict(d: Dictionary) -> void:
	clear()
	var tags: Dictionary = d.get("tags", {}) as Dictionary if d.get("tags") is Dictionary else {}
	for id in tags:
		var row: Dictionary = tags[id] as Dictionary if tags[id] is Dictionary else {}
		var ta: Array = row.get("t", []) as Array
		var va: Array = row.get("v", []) as Array
		for i in mini(ta.size(), va.size()):
			var v := NAN if va[i] == null else float(va[i])
			if is_nan(v) and not _t.has(str(id)):
				continue
			_force(str(id), float(ta[i]), v)
	for id in _t.keys():
		var ts: PackedFloat64Array = _t[id]
		if not ts.is_empty():
			_last_h = ts[ts.size() - 1] if is_nan(_last_h) else maxf(_last_h, ts[ts.size() - 1])


func _force(id: String, h: float, v: float) -> void:
	if not _t.has(id):
		_t[id] = PackedFloat64Array()
		_v[id] = PackedFloat32Array()
		_lo[id] = v
		_hi[id] = v
	# A packed array fetched from a Dictionary is a copy: append, then put back.
	var ts: PackedFloat64Array = _t[id]
	var vs: PackedFloat32Array = _v[id]
	ts.append(h)
	vs.append(v)
	_t[id] = ts
	_v[id] = vs
	if not is_nan(v):
		_lo[id] = minf(float(_lo[id]), v)
		_hi[id] = maxf(float(_hi[id]), v)

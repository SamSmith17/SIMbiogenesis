class_name FlowHistory
extends RefCounted

## What every wire carried over time, so the Flows lens can show the last
## day or week instead of one instant (plans: now-i-want-to-linked-garden).
## Hourly bins on absolute sim hours, keyed by CONNECTION id, each in the
## wire's own unit (watts, or the resource's unit per hour). A reading is
## held until the next one (the flows are piecewise constant between sim
## steps), integrated exactly across bin edges.
##
## Like ElementHistory: a scrub back drops what came after; a forward jump of
## more than JUMP_H counts nothing (it was skipped, not lived through); kept
## for MAX_BINS hours. Session data, not saved with the world.

const BIN_H := 1.0
const MAX_BINS := 336
const JUMP_H := 6.0

## bin index (floor(h / BIN_H)) → {"hours": covered hours, "w": {cid: [sum, key, max]}}
var bins: Dictionary = {}
var _prev_h: float = NAN
var _prev: Dictionary = {}


func clear() -> void:
	bins.clear()
	_prev_h = NAN
	_prev = {}


## Record what the wires carry at `abs_h`: {conn id: {key, value}}. The
## PREVIOUS reading is credited over [previous hour, abs_h].
func record(abs_h: float, values: Dictionary) -> void:
	if is_nan(abs_h):
		return
	if not is_nan(_prev_h):
		var dt := abs_h - _prev_h
		if dt < -1e-9:
			truncate_after(abs_h)
		elif dt > 0.0 and dt <= JUMP_H:
			_credit(_prev_h, abs_h, _prev)
	_prev_h = abs_h
	_prev = values.duplicate(true)
	_prune()


## Add what wires carried between the previous `record` and `abs_h`, as
## QUANTITIES ({conn id: [quantity, key]}, the flow engine's own ledger):
## spread evenly over that time. Call it BEFORE `record(abs_h, ...)`, and
## leave those wires out of the sampled values, or they count twice.
func add_quantities(abs_h: float, totals: Dictionary) -> void:
	if is_nan(abs_h) or is_nan(_prev_h) or totals.is_empty():
		return
	var dt := abs_h - _prev_h
	if dt <= 1e-9 or dt > JUMP_H:
		return
	var t := _prev_h
	while t < abs_h - 1e-12:
		var bi := int(floor(t / BIN_H))
		var t2 := minf(float(bi + 1) * BIN_H, abs_h)
		var share := (t2 - t) / dt
		var b: Dictionary = bins.get(bi, {})
		if b.is_empty():
			b = {"hours": 0.0, "w": {}}
			bins[bi] = b
		var w: Dictionary = b["w"]
		for cid in totals:
			var q: Array = totals[cid]
			if float(q[0]) <= 0.0:
				continue
			var cur: Array = w.get(cid, [0.0, str(q[1]), 0.0])
			cur[0] = float(cur[0]) + float(q[0]) * share
			cur[2] = maxf(float(cur[2]), float(q[0]) / dt)
			w[cid] = cur
		t = t2


func _credit(h0: float, h1: float, vals: Dictionary) -> void:
	var t := h0
	while t < h1 - 1e-12:
		var bi := int(floor(t / BIN_H))
		var edge := float(bi + 1) * BIN_H
		var t2 := minf(edge, h1)
		var span := t2 - t
		var b: Dictionary = bins.get(bi, {})
		if b.is_empty():
			b = {"hours": 0.0, "w": {}}
			bins[bi] = b
		b["hours"] = float(b["hours"]) + span
		var w: Dictionary = b["w"]
		for cid in vals:
			var rv: Dictionary = vals[cid]
			var v := float(rv.get("value", 0.0))
			if v <= 0.0:
				continue
			var cur: Array = w.get(cid, [0.0, str(rv.get("key", "")), 0.0])
			cur[0] = float(cur[0]) + v * span
			cur[2] = maxf(float(cur[2]), v)
			w[cid] = cur
		t = t2


## Drop everything recorded after `abs_h` (a scrub back).
func truncate_after(abs_h: float) -> void:
	var cut := int(floor(abs_h / BIN_H))
	for bi in bins.keys():
		if int(bi) > cut:
			bins.erase(bi)
	# The bin holding abs_h may hold a little of the future; it is kept, as
	# ElementHistory does: an hour's bin is the finest the windows read.
	_prev_h = NAN
	_prev = {}


func _prune() -> void:
	if bins.size() <= MAX_BINS:
		return
	var ks: Array = bins.keys()
	ks.sort()
	for i in ks.size() - MAX_BINS:
		bins.erase(ks[i])


## Mean (and peak) of every wire over [t0, t1], over the hours actually
## recorded in it: {conn id: {key, mean, max, hours}}.
func window(t0: float, t1: float) -> Dictionary:
	var out := {}
	if t1 <= t0:
		return out
	var covered := 0.0
	var sums := {}
	var b0 := int(floor(t0 / BIN_H))
	var b1 := int(floor(t1 / BIN_H))
	for bi in bins:
		var ib := int(bi)
		if ib < b0 or ib > b1:
			continue
		var b: Dictionary = bins[bi]
		var bs := float(ib) * BIN_H
		var ov := minf(bs + BIN_H, t1) - maxf(bs, t0)
		if ov <= 0.0:
			continue
		var frac := ov / BIN_H
		covered += float(b["hours"]) * frac
		var w: Dictionary = b["w"]
		for cid in w:
			var cur: Array = w[cid]
			var acc: Array = sums.get(cid, [0.0, str(cur[1]), 0.0])
			acc[0] = float(acc[0]) + float(cur[0]) * frac
			acc[2] = maxf(float(acc[2]), float(cur[2]))
			sums[cid] = acc
	if covered <= 0.0:
		return out
	for cid in sums:
		var a: Array = sums[cid]
		out[cid] = {"key": str(a[1]), "mean": float(a[0]) / covered, "max": float(a[2]), "hours": covered}
	return out


## Hours recorded in [t0, t1].
func covered_hours(t0: float, t1: float) -> float:
	var any: Dictionary = window(t0, t1)
	for cid in any:
		return float((any[cid] as Dictionary).get("hours", 0.0))
	return 0.0


func to_dict() -> Dictionary:
	var b := {}
	for k in bins:
		b[str(k)] = bins[k]
	return {"v": 1, "bins": b}


static func from_dict(d: Dictionary) -> FlowHistory:
	var h := FlowHistory.new()
	var b: Dictionary = d.get("bins", {})
	for k in b:
		h.bins[int(str(k))] = (b[k] as Dictionary).duplicate(true)
	return h

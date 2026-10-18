class_name SimRenderCache
extends RefCounted

## What a sim pre-render leaves behind, and the rule for when it is still true.
##
## The battery (EnergyTimeline) and every tank (ResourceTimeline) are EXACT per
## step in their own buffers, and the hydro readouts are re-derived from the
## restored pond levels on replay. This class holds the rest:
##
##   * the RENDERED RANGES `[a, b]` in absolute sim-hours, each stamped with the
##     GraphModel.user_rev it was rendered against — the key a range is valid
##     for. A player edit (user_rev moved) truncates every range at the
##     playhead; a range whose start is already past the playhead is dropped
##     whole (its past never happened on this graph);
##   * KEYFRAMES: sparse spec deltas every KEYFRAME_H sim-hours for what the
##     flow step writes that no timeline records — node states, starved kinds,
##     habitat ideal imports, batch progress, camp power, NPC pop_state, the
##     deficit tanks (they have no ResourceTimeline) — plus the wire flows for
##     the animation. The first keyframe of a range is FULL; later ones carry
##     only the keys that changed, and `apply_at` composes them forward (an
##     incremental cursor makes a forward-moving playhead O(keys changed));
##   * a GUARD against the energy timeline being re-anchored under the cache
##     (`apply_from_graph`, `reanchor_live_battery`, a save load all clear()
##     it): `verify_energy_timeline` drops every range when the SOC the range
##     started from is no longer where it was.
##
## Pure data: no autoloads, no nodes, so it loads under --script.

const KEYFRAME_H := 0.25
const EPS_H := 1e-6

## Spec keys a keyframe never carries, by prefix or exact name: exact in a
## timeline (tank levels / rates — restored by seek), re-derived on replay
## (hydro `live_*`), or live display state the DC throttle rewrites every
## quarter second whatever the playhead does.
const EXCLUDE_EXACT: Array[String] = ["siphon_primed", "current_output_kw", "ha_live",
	"pv_live_w", "pv_offered_kw", "pv_curtail", "sunlight_factor"]
const EXCLUDE_PREFIX: Array[String] = ["live_", "dc_"]
## On a tank WITH a timeline these come back from the seek; a deficit tank
## (allow_negative) keeps them in the keyframe because it has no timeline.
const TANK_TIMELINE_KEYS: Array[String] = ["level", "inflow_rate", "outflow_rate", "stock_l",
	"level_m", "overflowing", "overflow_qty", "node_state", "node_state_reason",
	"node_state_kinds", "budget_rain_lph", "budget_stream_lph", "budget_spill_lph"]

## [{a, b, user_rev}] in time order, non-overlapping.
var ranges: Array = []
## [{t, items: {id: {key: value}}, conns: {id: {rate, active, kind}}, full: bool}]
## in time order across all ranges.
var keyframes: Array = []

## Energy-timeline guard: the SOC and step the most recent range started from.
var _guard_abs_h := NAN
var _guard_soc := NAN

## Incremental apply cursor: the keyframe index last composed and the time it
## was composed for. Reset on any backward move or a cache edit.
var _applied_idx := -1
var _applied_t := NAN
## The previous capture's full snapshot (for the sparse diff).
var _last_snapshot: Dictionary = {}


func clear() -> void:
	ranges.clear()
	keyframes.clear()
	_guard_abs_h = NAN
	_guard_soc = NAN
	_reset_cursor()
	_last_snapshot = {}


func is_empty() -> bool:
	return ranges.is_empty()


## True when `t` lies inside a rendered range (inclusive).
func covers(t: float) -> bool:
	return not range_at(t).is_empty()


func range_at(t: float) -> Dictionary:
	for r in ranges:
		var rd: Dictionary = r
		if t >= float(rd["a"]) - EPS_H and t <= float(rd["b"]) + EPS_H:
			return rd
	return {}


## The rendered range the playhead can run into next (its start at or after
## `t`), or {}.
func next_range_after(t: float) -> Dictionary:
	var best := {}
	for r in ranges:
		var rd: Dictionary = r
		if float(rd["a"]) >= t - EPS_H and (best.is_empty() or float(rd["a"]) < float(best["a"])):
			best = rd
	return best


## Start a range at `a`: everything previously rendered past `a` is superseded
## (the new render is the graph's current truth from the playhead on). The
## range's end grows with `extend_range` as the render proceeds, so a cancelled
## render keeps what it finished.
func begin_range(a: float, user_rev: int, soc_at_a: float = NAN) -> void:
	truncate_after(a)
	ranges.append({"a": a, "b": a, "user_rev": user_rev})
	_guard_abs_h = a
	_guard_soc = soc_at_a
	_last_snapshot = {}
	_reset_cursor()


## Grow the newest range's end to `b` (the render cursor).
func extend_range(b: float) -> void:
	if ranges.is_empty():
		return
	var last: Dictionary = ranges[ranges.size() - 1]
	if b > float(last["b"]):
		last["b"] = b
	# Merge with an older range this one has run into.
	_merge_adjacent()


## Cut every range at `t`: ranges starting after `t` are dropped whole, a
## range spanning `t` ends there, keyframes past `t` go. Returns true when
## anything changed.
func truncate_after(t: float) -> bool:
	var changed := false
	for i in range(ranges.size() - 1, -1, -1):
		var rd: Dictionary = ranges[i]
		if float(rd["a"]) > t + EPS_H:
			ranges.remove_at(i)
			changed = true
		elif float(rd["b"]) > t + EPS_H:
			rd["b"] = t
			changed = true
			if float(rd["b"]) - float(rd["a"]) < EPS_H:
				ranges.remove_at(i)
	for i in range(keyframes.size() - 1, -1, -1):
		if float((keyframes[i] as Dictionary)["t"]) > t + EPS_H:
			keyframes.remove_at(i)
			changed = true
	if changed:
		_reset_cursor()
		# The next capture after a cut must be full again.
		_last_snapshot = {}
	return changed


## Drop every range (the cache can no longer be trusted as a whole: weather
## data arrived, a setting that feeds the physics changed, the energy
## timeline was re-anchored).
func invalidate_all() -> bool:
	if ranges.is_empty() and keyframes.is_empty():
		return false
	clear()
	return true


## Energy-timeline guard: `soc_at(a)` must still be what the range started
## from. Returns true when the cache had to be dropped.
func verify_energy_timeline(timeline: Object) -> bool:
	if ranges.is_empty() or timeline == null or is_nan(_guard_abs_h):
		return false
	var bad := false
	if bool(timeline.call("is_empty")):
		bad = true
	else:
		var s: Dictionary = timeline.call("sample_at", _guard_abs_h)
		if is_nan(_guard_soc):
			bad = false
		elif absf(float(s.get("soc_kwh", NAN)) - _guard_soc) > 1e-4:
			bad = true
		elif float(timeline.call("start_abs_hours")) > _guard_abs_h + 1e-6:
			bad = true
	if bad:
		clear()
	return bad


# ---------------------------------------------------------------------------
# Keyframes
# ---------------------------------------------------------------------------

## Snapshot of the keyframe-worthy specs of every item: {id: {key: value}}.
static func snapshot_items(model: Object) -> Dictionary:
	var out: Dictionary = {}
	if model == null:
		return out
	for it in (model.get("items") as Array):
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		var iid := str(item.get("id", ""))
		if iid.is_empty():
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var is_tank := str(item.get("type", "")) == "resource"
		var has_timeline := is_tank and not bool(specs.get("allow_negative", false))
		var keep: Dictionary = {}
		for k in specs:
			var key := str(k)
			if not keyframe_key(key, has_timeline):
				continue
			var v: Variant = specs[k]
			keep[key] = v.duplicate(true) if (v is Dictionary or v is Array) else v
		if not keep.is_empty():
			out[iid] = keep
	return out


## Whether a spec key belongs in a keyframe.
static func keyframe_key(key: String, has_timeline: bool) -> bool:
	if EXCLUDE_EXACT.has(key):
		return false
	for p in EXCLUDE_PREFIX:
		if key.begins_with(p):
			return false
	if has_timeline and TANK_TIMELINE_KEYS.has(key):
		return false
	return true


## Record a keyframe at `t`: full if it is the range's first, else only the
## keys whose value differs from the previous capture. `conn_flows` is the
## engine's conn_flow_snapshot(); `internal` its internal_state_snapshot()
## (batch progress, demand overrides, per-scope AC …), so the engine resumes
## live from exactly the state it had at that instant when the playhead
## leaves the range or the range is cut.
func capture(model: Object, conn_flows: Dictionary, t: float, internal: Dictionary = {}) -> void:
	var snap := snapshot_items(model)
	var full := _last_snapshot.is_empty()
	var delta: Dictionary = {}
	if full:
		delta = snap
	else:
		for iid in snap:
			var cur: Dictionary = snap[iid]
			var prev: Variant = _last_snapshot.get(iid)
			if not (prev is Dictionary):
				delta[iid] = cur
				continue
			var d: Dictionary = {}
			for k in cur:
				if not (prev as Dictionary).has(k) or (prev as Dictionary)[k] != cur[k]:
					d[k] = cur[k]
			if not d.is_empty():
				delta[iid] = d
	_last_snapshot = snap
	keyframes.append({"t": t, "items": delta, "conns": conn_flows.duplicate(true),
		"internal": internal.duplicate(true), "full": full})
	extend_range(t)


## Is a capture due at `t` (every KEYFRAME_H since the last one)?
func capture_due(t: float) -> bool:
	if keyframes.is_empty():
		return true
	return t - float((keyframes[keyframes.size() - 1] as Dictionary)["t"]) >= KEYFRAME_H - EPS_H


## Compose the keyframes of the range covering `t` up to the last one at or
## before `t`, write the result onto the model's items (the caller wraps this
## in the view's sim-write bracket) and hand the wire flows to the engine.
## Returns false when `t` is not covered or no keyframe applies.
func apply_at(model: Object, flow: Object, t: float) -> bool:
	if model == null:
		return false
	var rd := range_at(t)
	if rd.is_empty():
		return false
	var a := float(rd["a"])
	# Index of the last keyframe at or before t, and the first of this range.
	var first := -1
	var last := -1
	for i in keyframes.size():
		var kt := float((keyframes[i] as Dictionary)["t"])
		if kt < a - EPS_H:
			continue
		if kt > t + EPS_H:
			break
		if first < 0:
			first = i
		last = i
	if last < 0:
		return false
	var start := first
	var incremental := _applied_idx >= first and _applied_idx <= last \
		and not is_nan(_applied_t) and t >= _applied_t
	if incremental:
		# Forward inside the same range: only the keyframes since the last apply.
		start = _applied_idx + 1
	var composed: Dictionary = {}
	for i in range(start, last + 1):
		var items: Dictionary = (keyframes[i] as Dictionary)["items"]
		for iid in items:
			if not composed.has(iid):
				composed[iid] = {}
			var dst: Dictionary = composed[iid]
			var src: Dictionary = items[iid]
			for k in src:
				dst[k] = src[k]
	# A key the sim only STARTED writing later in the range (a node state that
	# appears at step 40) is absent from the composed state before then, but
	# still sits on the item from the last live step — a full (non-incremental)
	# compose therefore erases every key any later keyframe of this range
	# touches and the composed state does not carry.
	var erase: Dictionary = {}
	if not incremental:
		var r_end := float(rd["b"])
		for i in range(last + 1, keyframes.size()):
			var kt := float((keyframes[i] as Dictionary)["t"])
			if kt > r_end + EPS_H:
				break
			var items: Dictionary = (keyframes[i] as Dictionary)["items"]
			for iid in items:
				if not erase.has(iid):
					erase[iid] = {}
				for k in (items[iid] as Dictionary):
					if not composed.has(iid) or not (composed[iid] as Dictionary).has(k):
						(erase[iid] as Dictionary)[k] = true
	var touched: Dictionary = {}
	for iid in composed:
		touched[iid] = true
	for iid in erase:
		touched[iid] = true
	for iid in touched:
		var item: Dictionary = model.call("get_item", str(iid))
		if item.is_empty():
			continue
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(false)
		var dirty := false
		if composed.has(iid):
			var patch: Dictionary = composed[iid]
			for k in patch:
				if not specs.has(k) or specs[k] != patch[k]:
					var v: Variant = patch[k]
					specs[k] = v.duplicate(true) if (v is Dictionary or v is Array) else v
					dirty = true
		if erase.has(iid):
			for k in (erase[iid] as Dictionary):
				if specs.has(k):
					specs.erase(k)
					dirty = true
		if dirty:
			model.call("update_item", str(iid), {"specs": specs})
	if flow != null and flow.has_method("apply_conn_flow_snapshot"):
		flow.call("apply_conn_flow_snapshot", (keyframes[last] as Dictionary)["conns"])
	if flow != null and flow.has_method("restore_internal_state"):
		var internal: Dictionary = (keyframes[last] as Dictionary).get("internal", {}) as Dictionary
		if not internal.is_empty():
			flow.call("restore_internal_state", internal)
	_applied_idx = last
	_applied_t = t
	return true


func keyframe_count() -> int:
	return keyframes.size()


func _reset_cursor() -> void:
	_applied_idx = -1
	_applied_t = NAN


func _merge_adjacent() -> void:
	ranges.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["a"]) < float(y["a"]))
	var i := 0
	while i < ranges.size() - 1:
		var cur: Dictionary = ranges[i]
		var nxt: Dictionary = ranges[i + 1]
		if float(nxt["a"]) <= float(cur["b"]) + EPS_H and int(nxt["user_rev"]) == int(cur["user_rev"]):
			cur["b"] = maxf(float(cur["b"]), float(nxt["b"]))
			ranges.remove_at(i + 1)
		else:
			i += 1

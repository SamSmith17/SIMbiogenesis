class_name ProcessChecks
extends RefCounted
## Design checks for a process picture (plans/SCADA_PROCESS_PLAN.md, Phase
## 3b): what a reviewer would circle on the drawing. Read straight off the
## item / wire dicts (the engines already stamp what a run carries and
## loses), plus ScadaNet's network checks.
##
## run(items, conns) → [{level "error" | "warn", domain "pipes" | "power" |
## "data", text, ids}], errors first. `items` / `conns` = one scope's (the
## network part is asked over the whole graph by the caller and passed in
## as `net_checks`).
##
## Limits and where they come from:
##   voltage drop  3 % on a run (NEC 210.19 informational note)
##   pipe velocity 3 m/s (the Hydro Lab's penstock limit; water hammer and
##                 wear above it)
##   drain slope   1/4 inch per foot = 2.08 % for pipe up to 2.5 inch
##                 (IPC 704.1); checked only on a drain pipe routed in 3D
##
## Pure and autoload-free.

const VDROP_WARN_PCT := 3.0
const PIPE_V_MAX := 3.0
const DRAIN_SLOPE_MIN := 0.0208
const DRAIN_KINDS := ["greywater", "blackwater", "brownwater", "stormwater", "wash_water"]


static func _name(by_id: Dictionary, id: String) -> String:
	var it: Dictionary = by_id.get(id, {}) as Dictionary
	return str((it.get("specs", {}) as Dictionary).get("name", id))


static func _run_name(by_id: Dictionary, c: Dictionary) -> String:
	return "%s → %s" % [_name(by_id, str(c.get("source_item_id", ""))), _name(by_id, str(c.get("target_item_id", "")))]


## The y of a route point, whatever shape it was saved in (NAN = unknown).
static func _pt_y(p: Variant) -> float:
	if p is Vector3:
		return (p as Vector3).y
	if p is Array and (p as Array).size() >= 3:
		return float(p[1])
	if p is Dictionary:
		return float((p as Dictionary).get("y", NAN))
	return NAN


static func run(items: Array, conns: Array, net_checks: Array = []) -> Array:
	var out: Array = []
	var by_id := {}
	for it in items:
		if it is Dictionary and it.has("id"):
			by_id[str(it["id"])] = it
	var powered := {}
	for c in conns:
		if c is Dictionary and str(c.get("polarity", "")) in ["ac", "load", "ac_240"]:
			powered[str(c.get("target_item_id", ""))] = true
			powered[str(c.get("source_item_id", ""))] = true
	for id in by_id:
		var it: Dictionary = by_id[id]
		var specs: Dictionary = it.get("specs", {}) as Dictionary
		var nm := str(specs.get("name", id))
		if BreakerTrip.is_breaker(it) and bool(specs.get("tripped", false)):
			out.append({"level": "error", "domain": "power", "ids": [id],
				"text": "%s %s: it carried %s A on a %s A rating." % [nm, "has blown" if bool(specs.get("fuse", false)) else "has tripped",
					UiText.num(float(specs.get("trip_amps", 0.0)), "", 2), UiText.num(BreakerTrip.rating_a(specs), "", 2)]})
		if str(it.get("type", "")) == "processor" and FlowCtl.is_flowctl(specs):
			var blk := str(specs.get("ctl_block", ""))
			if blk == FlowCtl.BLOCK_UPHILL:
				out.append({"level": "error", "domain": "pipes", "ids": [id],
					"text": "%s is open but the far store is uphill: that line needs a pump." % nm})
			elif blk == FlowCtl.BLOCK_LIFT:
				out.append({"level": "error", "domain": "pipes", "ids": [id],
					"text": "%s cannot lift that high (it lifts %s m)." % [nm, UiText.num(float(specs.get("max_lift_m", 0.0)), "", 2)]})
			if FlowCtl.kind_of(specs) == FlowCtl.KIND_PUMP and not powered.has(id):
				out.append({"level": "warn", "domain": "power", "ids": [id], "text": "%s has no power wire." % nm})
	for c in conns:
		if not (c is Dictionary):
			continue
		var cid := str(c.get("id", ""))
		var pol := str(c.get("polarity", ""))
		if pol == "data":
			continue
		if pol != "resource":
			var over := float(c.get("overload_ratio", 0.0))
			if over > 1.0:
				out.append({"level": "error", "domain": "power", "ids": [cid],
					"text": "%s: the cable carries %d %% of what it is rated for." % [_run_name(by_id, c), int(round(over * 100.0))]})
			var drop := float(c.get("drop_pct", 0.0))
			if drop > VDROP_WARN_PCT:
				out.append({"level": "warn", "domain": "power", "ids": [cid],
					"text": "%s: %s %% of the voltage is lost in the run (3 %% is the usual limit). A thicker or shorter cable fixes it."
						% [_run_name(by_id, c), UiText.num(drop, "", 2)]})
			continue
		# A pipe.
		var ct := str(c.get("conduit_type", ""))
		var kind := ResourceKinds.normalize_kind(str(c.get("resource_type", "")))
		if ct.is_empty() or not ConduitKinds.has_type(ct) or ConduitKinds.is_conceptual_type(ct):
			continue
		var style: Dictionary = c.get("conduit_style", {}) as Dictionary
		var bore := ConduitKinds.inner_diameter_for(ct, style)
		var rate := float(c.get("flow_rate", 0.0))
		if bore > 0.0 and rate > 0.0 and ResourceKinds.default_unit(kind) == "L":
			var v := (rate / 3600.0 / 1000.0) / (PI * bore * bore * 0.25)
			if v > PIPE_V_MAX:
				out.append({"level": "warn", "domain": "pipes", "ids": [cid],
					"text": "%s: the water runs at %s m/s in this pipe (keep it under 3). A bigger pipe fixes it."
						% [_run_name(by_id, c), UiText.num(v, "", 2)]})
		if kind in DRAIN_KINDS and bool(c.get("visible_3d", false)) and float(c.get("route_length_m", 0.0)) > 1.0:
			var route: Array = c.get("route_3d", []) as Array
			var y0 := float(c.get("invert_in_m", NAN))
			var y1 := float(c.get("invert_out_m", NAN))
			if (is_nan(y0) or is_nan(y1)) and route.size() >= 2:
				y0 = _pt_y(route[0])
				y1 = _pt_y(route[route.size() - 1])
			if not is_nan(y0) and not is_nan(y1):
				var slope := (y0 - y1) / float(c.get("route_length_m", 1.0))
				if slope < DRAIN_SLOPE_MIN:
					out.append({"level": "warn", "domain": "pipes", "ids": [cid],
						"text": "%s: this drain falls %s %% (it needs about 2 %% to carry solids)."
							% [_run_name(by_id, c), UiText.num(slope * 100.0, "", 2)]})
	for nc in net_checks:
		if nc is Dictionary:
			var d: Dictionary = (nc as Dictionary).duplicate()
			d["domain"] = "data"
			out.append(d)
	out.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return str(p["level"]) == "error" and str(q["level"]) != "error")
	return out


static func summary(checks: Array) -> String:
	var e := 0
	var w := 0
	for c in checks:
		if str((c as Dictionary).get("level", "")) == "error":
			e += 1
		else:
			w += 1
	if e == 0 and w == 0:
		return "Checks pass"
	var parts := PackedStringArray()
	if e > 0:
		parts.append(UiText.count(e, "problem"))
	if w > 0:
		parts.append(UiText.count(w, "warning"))
	return ", ".join(parts)

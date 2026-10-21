class_name LinkageStepScene
extends RefCounted
## What the Lab's step player shows at (step index, op progress t) — the
## applyBuildStepScene + op-driver half of LinkageLab's build-steps-anim.js
## as a PURE function (LINKAGE_PARITY.md A5). The player node only renders it.
##
## Rules mirrored from the web app:
##   - part status by compute_step_visibility: "future" parts are hidden,
##     "active" ones highlighted; parked parts (parkOffset "beside") are drawn
##     displaced by the offset in force AFTER this step;
##   - the pose: the last view.foldAngleDeg at or before the step (the web's
##     state.foldAngle is sticky across steps), else the design's;
##   - a bench-stage step (cut, drill) HIDES the structure and shows the
##     workbench: one representative beam per group of identical beams on the
##     bench plane at the origin, the saw / drill moving per LinkageBuildOps;
##   - place moves its targets in along their approach (a lift from the parked
##     spot), fasten backs each bolt out along its axis and turns it in.
##
## Units: INCHES, the structure's solver frame (assembly) or the bench frame
## (bench). The renderer converts (x 0.0254, plus the builder's ground offset
## for the structure frame).

## A context for one pose: {fold_deg, data, parts, drill_bolts}. Cached by
## the caller (one per fold angle in use).
static func make_context(p: LinkageParams, fold_deg: float, deployed_deg: float = NAN) -> Dictionary:
	var data := LinkagePartKeys.part_data(p, deg_to_rad(fold_deg))
	var dep := deployed_deg if not is_nan(deployed_deg) else rad_to_deg(LinkageKinematics.optimal_closed_angle(p))
	var drill := LinkageBeamHoles.drill_solve(p, deg_to_rad(dep))
	return {"fold_deg": fold_deg, "data": data, "parts": LinkagePartKeys.collect_parts(data),
		"drill_bolts": drill["bolts"]}


## The pose a step plays at: the last view fold at or before it.
static func fold_for_step(steps: Array, index: int, default_deg: float) -> float:
	for i in range(mini(index, steps.size() - 1), -1, -1):
		var v = (steps[i] as Dictionary).get("view")
		if v is Dictionary and v.get("foldAngleDeg") != null:
			return float(v["foldAngleDeg"])
	return default_deg


static func is_bench(step: Dictionary) -> bool:
	return str(step.get("stage", "")) == "bench" or str(step.get("kind", "")) in ["cut", "drill"]


## The frame at progress t in [0, 1] of step `index`:
##   {index, kind, bench: bool, last: bool, parts: {key: {visible, offset:
##    Vector3 in, active: bool, status}}, tool: {} | {id, frame: "bench"|"structure", xform
##    (Transform3D, inches, unit basis), spin (rad), visible},
##    bench_plane: {} | {center, size} (inches), bench_boxes: [{center, size,
##    kind: "stock"|"keep"|"offcut"|"beam", roll}], holes: [{pos, radius}],
##    focus: {center, radius} (inches, in the frame shown), summary}
static func frame(steps: Array, index: int, t: float, ctx: Dictionary) -> Dictionary:
	var out := {"index": index, "kind": "", "bench": false, "last": index >= steps.size() - 1, "parts": {}, "tool": {}, "bench_plane": {},
		"bench_boxes": [], "holes": [], "focus": {}, "summary": ""}
	if steps.is_empty():
		return out
	index = clampi(index, 0, steps.size() - 1)
	var step: Dictionary = steps[index]
	var kind := str(step.get("kind", "view"))
	out["kind"] = kind
	out["summary"] = LinkageBuildSteps.step_summary(step)
	var parts: Array = ctx["parts"]
	var vis := LinkageBuildSteps.compute_step_visibility(steps, index, parts)
	var status: Dictionary = vis["status"]
	var disp := _resolve_displacement(vis["displacement"], parts)
	var disp_before := _resolve_displacement(vis["displacementBefore"], parts)
	var parts_out := {}
	for rec in parts:
		var key: String = rec["key"]
		var s := str(status.get(key, "unreferenced"))
		parts_out[key] = {"visible": s != "future", "offset": disp.get(key, Vector3.ZERO), "active": s == "active",
			"status": s}
	out["parts"] = parts_out
	var bench := is_bench(step)
	out["bench"] = bench
	var op_ctx := {"data": ctx["data"], "parts": parts, "drill_bolts": ctx["drill_bolts"],
		"park_offset_for": func(key: String): return disp_before.get(key)}
	var plan := LinkageBuildOps.stage(step, op_ctx)
	match kind:
		"place":
			var bounds_items: Array = []
			for e in LinkageBuildOps.place_at(plan, t):
				var key2: String = e["key"]
				if not parts_out.has(key2):
					continue
				var base: Vector3 = Vector3.ZERO if str((step.get("op", {}) as Dictionary).get("from", "")) == "parked" \
					else (parts_out[key2]["offset"] as Vector3)
				parts_out[key2]["offset"] = base + (e["offset"] as Vector3)
				parts_out[key2]["visible"] = bool(e["visible"])
				bounds_items.append(key2)
			out["focus"] = _focus_of(bounds_items, parts, parts_out)
		"fasten":
			var f := LinkageBuildOps.fasten_at(plan, t)
			var entries: Array = plan.get("entries", [])
			var states: Array = f["entries"]
			for i in states.size():
				var key3: String = states[i]["key"]
				if parts_out.has(key3):
					parts_out[key3]["offset"] = (parts_out[key3]["offset"] as Vector3) + (states[i]["offset"] as Vector3)
					parts_out[key3]["visible"] = true
			var focus: Dictionary = f["focus"]
			if not focus.is_empty():
				out["focus"] = {"center": focus["center"], "radius": float(focus["radius"])}
				# The driver on the joint being worked: its first bolt, else its
				# hardware assembly (whose bolt backs out along the joint axis).
				var pick := -1
				for i in entries.size():
					var en0: Dictionary = entries[i]
					if int(en0.get("joint_index", -1)) != int(f["joint"]):
						continue
					if str(en0["kind"]) == "bolt":
						pick = i
						break
					if pick < 0:
						pick = i
				for i in ([pick] if pick >= 0 else []):
					var en: Dictionary = entries[i]
					var mv: Vector3 = en["move_dir"]
					var head: Vector3 = (en["seated"] as Vector3) + (states[i]["offset"] as Vector3) + mv * float(en["len"]) / 2.0
					var drive := -mv.normalized()
					out["tool"] = {"id": "impact_driver", "frame": "structure", "visible": t < 1.0,
						"xform": Transform3D(_basis_down_to(drive), head),
						"spin": float(states[i]["spin"])}
					break
		"cut":
			var c := LinkageBuildOps.cut_at(plan, t)
			_bench_from(out, plan)
			var rows: Array = plan.get("rows", [])
			var kerf := float(plan.get("kerf", 0.125))
			for i in rows.size():
				var item: Dictionary = rows[i]
				var r: Dictionary = c["rows"][i]
				var tt := float(item["t"])
				var w := float(item["w"])
				var y := float(item.get("y", tt / 2.0))
				var x0 := float(item["x0"])
				if bool(r["stock"]):
					var sl := float(item["stockLength"])
					out["bench_boxes"].append({"kind": "stock", "center": Vector3(x0 + sl / 2.0, y, float(item["z"])),
						"size": Vector3(sl, tt, w), "roll": 0.0})
				if bool(r["keep"]):
					var ca := float(item["cutAt"])
					out["bench_boxes"].append({"kind": "keep", "center": Vector3(x0 + ca / 2.0, y, float(item["z"])),
						"size": Vector3(ca, tt, w), "roll": 0.0})
				if bool(r["offcut"]):
					var ol := float(item["stockLength"]) - float(item["cutAt"]) - kerf
					var oc := Vector3(x0 + float(item["cutAt"]) + kerf + ol / 2.0, y, float(item["z"])) + (r["offcut_offset"] as Vector3)
					out["bench_boxes"].append({"kind": "offcut", "center": oc, "size": Vector3(ol, tt, w),
						"roll": float(r["offcut_roll"])})
			var tool: Dictionary = c["tool"]
			out["tool"] = {"id": "circular_saw", "frame": "bench", "visible": bool(tool["visible"]),
				"xform": Transform3D(Basis(), tool["pos"]), "spin": float(tool["blade_angle"])}
		"drill":
			var d := LinkageBuildOps.drill_at(plan, t)
			_bench_from(out, plan)
			var rows2: Array = plan.get("rows", [])
			for i in rows2.size():
				var item2: Dictionary = rows2[i]
				var bl := float(item2["beamLength"])
				var tt2 := float(item2["t"])
				out["bench_boxes"].append({"kind": "beam", "center": Vector3(float(item2["x0"]) + bl / 2.0,
					float(item2.get("y", tt2 / 2.0)), float(item2["z"])), "size": Vector3(bl, tt2, float(item2["w"])), "roll": 0.0})
				var holes: Array = item2["group"]["holes"]
				for hi in mini(int(d["drilled"][i]), holes.size()):
					var h: Dictionary = holes[hi]
					out["holes"].append({"radius": float(h.get("radius", 0.25)), "pos": Vector3(
						float(item2["x0"]) + bl / 2.0 + float(h["pos_l"]), tt2, float(item2["z"]) + float(h.get("pos_w", 0.0)))})
			var dt: Dictionary = d["tool"]
			out["tool"] = {"id": "drill", "frame": "bench", "visible": bool(dt["visible"]),
				"xform": Transform3D(Basis(Vector3.UP, PI), dt["tip"]), "spin": float(dt["bit_angle"])}
		_:
			pass
	if out["focus"].is_empty():
		if bench and not (out["bench_plane"] as Dictionary).is_empty():
			out["focus"] = {"center": out["bench_plane"]["center"], "radius": float(out["bench_plane"]["radius"])}
		else:
			var keys: Array = []
			for k in parts_out:
				if bool(parts_out[k]["active"]):
					keys.append(k)
			out["focus"] = _focus_of(keys, parts, parts_out) if not keys.is_empty() else _structure_focus(parts)
	return out


## A basis turning the tool's -Y (bit / driver axis) onto `dir`.
static func _basis_down_to(dir: Vector3) -> Basis:
	var d := dir.normalized()
	if d.dot(Vector3.DOWN) > 0.9999:
		return Basis()
	if d.dot(Vector3.DOWN) < -0.9999:
		return Basis(Vector3(1, 0, 0), PI)
	return Basis(Quaternion(Vector3.DOWN, d))


static func _bench_from(out: Dictionary, plan: Dictionary) -> void:
	var bp: Dictionary = (plan.get("bench", {}) as Dictionary).get("plane", {})
	var bb: Dictionary = (plan.get("bench", {}) as Dictionary).get("bounds", {})
	if bp.is_empty():
		return
	out["bench_plane"] = {"center": Vector3(float(bp["x"]), -0.75, float(bp["z"])),
		"size": Vector3(float(bp["length"]), 1.5, float(bp["width"])),
		"radius": float(bb.get("radius", 24.0))}


## key -> offset (inches) for the parkOffset specs in force (resolveDisplacement:
## "beside" = past the structure's +X beam extent, on its ground, grouped by
## identical spec).
static func _resolve_displacement(disp: Dictionary, parts: Array) -> Dictionary:
	if disp.is_empty():
		return {}
	var beams: Array = []
	for r in parts:
		var stype := str(r["obj"].get("stack_type", ""))
		if r["kind"] == "beam" and stype != "support-beam" and stype != "support-beam-reciprocal":
			beams.append(r)
	var sb := LinkagePartKeys.parts_bounds(beams)
	var by_spec := {}
	var by_key := {}
	for rec in parts:
		by_key[rec["key"]] = rec
	for key in disp:
		var spec_key := JSON.stringify(disp[key])
		if not by_spec.has(spec_key):
			by_spec[spec_key] = {"spec": disp[key], "items": []}
		if by_key.has(key):
			(by_spec[spec_key]["items"] as Array).append(by_key[key])
	var out := {}
	for sk in by_spec:
		var g: Dictionary = by_spec[sk]
		var off := LinkageBuildSteps.resolve_park_offset(g["spec"], sb, LinkagePartKeys.parts_bounds(g["items"]))
		for rec in g["items"]:
			out[rec["key"]] = off
	return out


static func _focus_of(keys: Array, parts: Array, parts_out: Dictionary) -> Dictionary:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var any := false
	var wanted := {}
	for k in keys:
		wanted[k] = true
	for rec in parts:
		if not wanted.has(rec["key"]):
			continue
		var off: Vector3 = parts_out[rec["key"]]["offset"]
		for p in LinkagePartKeys.part_points(rec["obj"], rec["kind"]):
			var q: Vector3 = (p as Vector3) + off
			lo = lo.min(q)
			hi = hi.max(q)
			any = true
	if not any:
		return _structure_focus(parts)
	return {"center": (lo + hi) / 2.0, "radius": maxf(12.0, (hi - lo).length() / 2.0)}


static func _structure_focus(parts: Array) -> Dictionary:
	var b := LinkagePartKeys.parts_bounds(parts)
	if b.is_empty():
		return {"center": Vector3.ZERO, "radius": 60.0}
	return {"center": b["center"], "radius": maxf(24.0, float(b.get("radius", 60.0)))}

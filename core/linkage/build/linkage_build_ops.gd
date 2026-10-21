class_name LinkageBuildOps
extends RefCounted
## Build-step OPERATIONS as pure functions of progress — port of LinkageLab's
## op drivers (`build-steps-ops.js` place / cut / drill, `build-steps-fasten.js`
## fasten). LINKAGE_PARITY.md A2.
##
## The web app stores a step as {kind, targets, op} only; the tool motion is
## recomputed at playback by drivers that move THREE meshes. Here the same
## motion is a value: `stage(step, ctx)` resolves a step into a PLAN, and
## `place_at` / `cut_at` / `drill_at` / `fasten_at(plan, t)` return where the
## tool is and what every part is doing at progress t in [0, 1]. The Lab's step
## player (A5) and the NPC build timeline (B4) both read these, so a saw in a
## figure's hands and the saw in the Lab are the same saw.
##
## Frames, in INCHES like the solver:
##   - assembly ops (place, fasten): the structure frame (LinkageSolver's).
##   - bench ops (cut, drill): the BENCH frame — the plan_bench layout, beams
##     lying along +X from x0, width across Z, thickness up Y, bench top y = 0.
##
## The ctx dictionary: {data: LinkagePartKeys.part_data, parts:
## collect_parts(data), drill_bolts: Array (LinkageBeamHoles.drill_solve),
## park_offset_for: Callable(key) -> Vector3 (optional)}.

const OVERLAP_PLACE := 0.35
const OVERLAP_FASTEN := 0.25


# ---------------------------------------------------------------------------
# Shared
# ---------------------------------------------------------------------------

## Equal slots over 0..1: {idx, u} for the active slot (build-steps-ops slotOf).
static func slot_of(t: float, count: int) -> Dictionary:
	var n := maxi(1, count)
	var idx := mini(n - 1, int(floor(t * n)))
	return {"idx": idx, "u": clampf(t * n - idx, 0.0, 1.0)}


static func _ease(t: float) -> float:
	return LinkageBuildSteps.ease_in_out_cubic(t)


## A part's seated reference point (the mesh position the JS drivers move).
static func part_center(obj: Dictionary, kind: String) -> Vector3:
	match kind:
		"beam", "bolt", "washer", "panel":
			if obj.get("center") is Vector3:
				return obj["center"]
		"bracket", "placement":
			if obj.get("pos") is Vector3:
				return obj["pos"]
	var pts := LinkagePartKeys.part_points(obj, kind)
	if pts.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / float(pts.size())


## String.localeCompare(b, undefined, {numeric: true}) for part keys: digit
## runs compare as numbers ("panel:2" < "panel:10").
static func natural_less(a: String, b: String) -> bool:
	return a.naturalcasecmp_to(b) < 0


static func _targets_of(step: Dictionary, parts: Array) -> Array:
	var out: Array = []
	var targets: Array = step.get("targets", [])
	if targets.is_empty():
		return out
	for rec in parts:
		for sel in targets:
			if sel is Dictionary and LinkagePartKeys.match_selector(rec["obj"], sel, rec["kind"]):
				out.append(rec)
				break
	return out


## Resolve a step into a plan for its kind ({kind: ...} + kind-specific data).
static func stage(step: Dictionary, ctx: Dictionary) -> Dictionary:
	match str(step.get("kind", "")):
		"place":
			return stage_place(step, ctx)
		"cut":
			return stage_cut(step, ctx)
		"drill":
			return stage_drill(step, ctx)
		"fasten":
			return stage_fasten(step, ctx)
	return {"kind": str(step.get("kind", "view"))}


# ---------------------------------------------------------------------------
# Place: parts travel in along an approach vector and fade to solid
# ---------------------------------------------------------------------------

static func _approach_dir(center: Vector3, obj: Dictionary, approach: String) -> Vector3:
	if approach == "radial":
		var v := Vector3(center.x, 0.0, center.z)
		return Vector3(1, 0, 0) if v.length_squared() < 1e-6 else v.normalized()
	if approach == "axis" and obj.get("axis_z") is Vector3:
		return (obj["axis_z"] as Vector3).normalized()
	return Vector3.UP


static func stage_place(step: Dictionary, ctx: Dictionary) -> Dictionary:
	var op: Dictionary = step.get("op", {})
	var approach := str(op.get("approach", "above")) if op.get("approach") != null else "above"
	var travel := float(op["travelIn"]) if (op.get("travelIn") is float or op.get("travelIn") is int) else 24.0
	var from_parked := str(op.get("from", "")) == "parked"
	var park_for = ctx.get("park_offset_for")
	var entries: Array = []
	for rec in _targets_of(step, ctx["parts"]):
		var c := part_center(rec["obj"], rec["kind"])
		var dir := _approach_dir(c, rec["obj"], approach)
		var dist := travel
		var fade := true
		if from_parked and park_for is Callable:
			var off = park_for.call(rec["key"])
			if off is Vector3:
				dist = (off as Vector3).length()
				dir = (off as Vector3) / dist if dist > 1e-6 else Vector3.UP
				if dist <= 1e-6:
					dist = 0.0
				fade = false
		entries.append({"key": rec["key"], "kind": rec["kind"], "seated": c, "dir": dir, "dist": dist, "fade": fade})
	var sequential := bool(op.get("sequential", false)) and entries.size() > 1
	if sequential:
		entries.sort_custom(func(a, b): return natural_less(str(a["key"]), str(b["key"])))
	return {"kind": "place", "entries": entries, "travel": travel, "sequential": sequential}


## Per entry at progress t: {key, offset: Vector3 (from seated), visible,
## opacity, u (its own progress)}.
static func place_at(plan: Dictionary, t: float) -> Array:
	var out: Array = []
	var entries: Array = plan.get("entries", [])
	var n := entries.size()
	for i in n:
		var en: Dictionary = entries[i]
		var u := t
		if bool(plan.get("sequential", false)):
			u = LinkageBuildSteps.sequence_progress(t, i, n, OVERLAP_PLACE)
		var e := _ease(u)
		out.append({
			"key": en["key"],
			"offset": (en["dir"] as Vector3) * float(en["dist"]) * (1.0 - e),
			"visible": not (bool(plan.get("sequential", false)) and u <= 0.0 and t < 1.0),
			"opacity": 0.25 + 0.75 * e if bool(en["fade"]) else 1.0,
			"u": u,
		})
	return out


# ---------------------------------------------------------------------------
# Cut: a spinning saw crosses the stock at the cut line, then the offcut moves
# ---------------------------------------------------------------------------

static func _target_beams(step: Dictionary, ctx: Dictionary) -> Array:
	var out: Array = []
	for rec in _targets_of(step, ctx["parts"]):
		if rec["kind"] == "beam":
			out.append(rec["obj"])
	return out


static func stage_cut(step: Dictionary, ctx: Dictionary) -> Dictionary:
	var op: Dictionary = step.get("op", {})
	var groups := LinkageBuildSteps.group_beams_for_bench(_target_beams(step, ctx))
	var plan := LinkageBuildSteps.plan_bench(groups, {"stock": true, "stockLengthIn": op.get("stockLengthIn")})
	var kerf_in = op.get("kerfIn")
	var kerf := maxf(0.03, float(kerf_in) if (kerf_in is float or kerf_in is int) and float(kerf_in) != 0.0 else 0.125)
	var max_t := 0.0
	for it in plan["items"]:
		max_t = maxf(max_t, float(it["t"]))
	return {"kind": "cut", "rows": plan["items"], "bench": plan, "kerf": kerf,
		"saw_radius": clampf(max_t + 0.75, 2.25, 4.5)}


## {tool: {visible, pos: Vector3 (blade centre, bench frame), blade_angle
## (RADIANS — the JS driver's `blade.rotation.x = t * 140`), normal: +X},
## rows: [{stock, keep, offcut: bool visible, offcut_offset: Vector3,
## offcut_roll, kerf_len: float (0 = no kerf shown), done}], row: idx}.
static func cut_at(plan: Dictionary, t: float) -> Dictionary:
	var rows: Array = plan.get("rows", [])
	var out_rows: Array = []
	var radius := float(plan.get("saw_radius", 3.0))
	var kerf := float(plan.get("kerf", 0.125))
	var tool := {"visible": false, "pos": Vector3.ZERO, "blade_angle": t * 140.0, "normal": Vector3(1, 0, 0)}
	if rows.is_empty():
		return {"tool": tool, "rows": out_rows, "row": -1}
	var s := slot_of(t, rows.size())
	var idx: int = s["idx"]
	var u: float = s["u"]
	for i in rows.size():
		var item: Dictionary = rows[i]
		var done := i < idx or (i == idx and u >= 0.7) or t >= 1.0
		var active := i == idx and t < 1.0
		var sep := 0.0
		if done:
			sep = 1.0 if (i < idx or t >= 1.0) else _ease((u - 0.7) / 0.3)
		var off_len := float(item["stockLength"]) - float(item["cutAt"]) - kerf
		var r := {"stock": not done, "keep": done, "offcut": done and off_len > 0.25,
			"offcut_offset": Vector3(2.5 + 9.0 * sep, -0.35 * sep, 0.0) if done else Vector3.ZERO,
			"offcut_roll": -0.03 * sep, "kerf_len": 0.0, "done": done}
		# The tool's place is computed for the active row — and for the LAST
		# row at t = 1, where the web hides the saw and so never moves it: a
		# figure holding it must keep holding it where the cut ended.
		if active or (t >= 1.0 and i == rows.size() - 1):
			var z_start := float(item["z"]) - float(item["w"]) / 2.0 - radius - 1.5
			var z_end := float(item["z"]) + float(item["w"]) / 2.0 + radius + 1.5
			var x := float(item["x0"]) + float(item["cutAt"]) + kerf / 2.0
			var y_cut := float(item["t"]) + 0.25
			var y_up := float(item["t"]) + radius + 3.0
			var z := z_start
			var y := y_up
			if u < 0.15:
				y = y_up + (y_cut - y_up) * _ease(u / 0.15)
			elif u < 0.7:
				y = y_cut
				z = z_start + (z_end - z_start) * ((u - 0.15) / 0.55)
			else:
				z = z_end
				y = y_cut + (y_up - y_cut) * _ease((u - 0.7) / 0.3)
			tool["pos"] = Vector3(x, y, z)
			if active and u >= 0.15 and u < 0.7:
				var cut_z0 := float(item["z"]) - float(item["w"]) / 2.0
				r["kerf_len"] = clampf(z - cut_z0, 0.001, float(item["w"]))
		out_rows.append(r)
	tool["visible"] = t < 1.0
	return {"tool": tool, "rows": out_rows, "row": idx}


# ---------------------------------------------------------------------------
# Drill: the bit slides over each hole, plunges, retracts
# ---------------------------------------------------------------------------

## A group's real holes mapped onto its bench beam so every hole is vertical:
## a beam drilled mostly across its WIDTH is laid on its side (benchHolesFor).
static func bench_holes_for(rep: Dictionary, bolts: Array) -> Dictionary:
	var real := LinkageBuildSteps.dedupe_holes(LinkageBeamHoles.intersections(rep, bolts))
	var w_count := 0
	var t_count := 0
	for h in real:
		if str(h["through"]) == "W":
			w_count += 1
		else:
			t_count += 1
	var on_side := w_count > t_count
	var holes: Array = []
	for h in real:
		if (str(h["through"]) == "W") != on_side:
			continue
		holes.append({"pos_l": float(h["pos_l"]),
			"pos_w": float(h["pos_t"]) if on_side else float(h["pos_w"]),
			"pos_t": float(h["pos_w"]) if on_side else float(h["pos_t"]),
			"radius": float(h["radius"]), "through": "T"})
	holes.sort_custom(func(a, b): return float(a["pos_l"]) < float(b["pos_l"]))
	return {"on_side": on_side, "holes": holes,
		"laid_w": float(rep.get("t", 1.5)) if on_side else float(rep.get("w", 1.5)),
		"laid_t": float(rep.get("w", 1.5)) if on_side else float(rep.get("t", 1.5))}


static func stage_drill(step: Dictionary, ctx: Dictionary) -> Dictionary:
	var op: Dictionary = step.get("op", {})
	var bolts: Array = ctx.get("drill_bolts", [])
	var groups := LinkageBuildSteps.group_beams_for_bench(_target_beams(step, ctx))
	var oriented: Array = []
	for g in groups:
		var info := bench_holes_for(g["rep"], bolts)
		var og: Dictionary = (g as Dictionary).duplicate()
		og["w"] = info["laid_w"]
		og["t"] = info["laid_t"]
		og["holes"] = info["holes"]
		og["on_side"] = info["on_side"]
		oriented.append(og)
	var plan := LinkageBuildSteps.plan_bench(oriented, {"stock": false})
	var rows: Array = plan["items"]
	var max_t := 0.0
	var max_dia := 0.0
	var jobs: Array = []
	for ri in rows.size():
		var row: Dictionary = rows[ri]
		max_t = maxf(max_t, float(row["t"]))
		var holes: Array = row["group"]["holes"]
		for hi in holes.size():
			max_dia = maxf(max_dia, float(holes[hi]["radius"]) * 2.0)
			jobs.append({"row": ri, "hole": hi})
	var bit = op.get("bitDiameterIn")
	var dia := float(bit) if (bit is float or bit is int) and float(bit) != 0.0 else (max_dia if max_dia > 0.0 else 0.375)
	return {"kind": "drill", "rows": rows, "bench": plan, "jobs": jobs, "bit_diameter": dia, "bit_length": max_t + 2.5}


## {tool: {visible, tip: Vector3 (bench frame, bit along -Y), bit_angle
## (RADIANS — the JS driver's `bit.rotation.y = t * 220`)},
## drilled: [holes drilled so far, per row], job: idx, focus: Vector3}.
static func drill_at(plan: Dictionary, t: float) -> Dictionary:
	var rows: Array = plan.get("rows", [])
	var jobs: Array = plan.get("jobs", [])
	var tool := {"visible": false, "tip": Vector3.ZERO, "bit_angle": t * 220.0}
	var drilled: Array = []
	for r in rows:
		drilled.append(0)
	if jobs.is_empty():
		return {"tool": tool, "drilled": drilled, "job": -1, "focus": Vector3.ZERO}
	var s := slot_of(t, jobs.size())
	var idx: int = s["idx"]
	var u: float = s["u"]
	for ji in jobs.size():
		if ji < idx or (ji == idx and u >= 0.5) or t >= 1.0:
			drilled[int(jobs[ji]["row"])] += 1
	var hole_xz := func(job: Dictionary) -> Vector2:
		var item: Dictionary = rows[int(job["row"])]
		var h: Dictionary = item["group"]["holes"][int(job["hole"])]
		return Vector2(float(item["x0"]) + float(item["beamLength"]) / 2.0 + float(h["pos_l"]),
			float(item["z"]) + float(h.get("pos_w", 0.0)))
	var job: Dictionary = jobs[idx]
	var item: Dictionary = rows[int(job["row"])]
	var here: Vector2 = hole_xz.call(job)
	var prev: Vector2 = hole_xz.call(jobs[idx - 1]) if idx > 0 else here
	var y_hover := float(item["t"]) + 1.5
	var y_bottom := -0.4
	var x := here.x
	var z := here.y
	var y := y_hover
	if u < 0.15:
		var e := _ease(u / 0.15)
		x = prev.x + (here.x - prev.x) * e
		z = prev.y + (here.y - prev.y) * e
	elif u < 0.5:
		y = y_hover + (y_bottom - y_hover) * _ease((u - 0.15) / 0.35)
	elif u < 0.8:
		y = y_bottom + (y_hover - y_bottom) * _ease((u - 0.5) / 0.3)
	tool["tip"] = Vector3(x, y, z)
	tool["visible"] = t < 1.0
	return {"tool": tool, "drilled": drilled, "job": idx, "focus": Vector3(x, float(item["t"]), z)}


# ---------------------------------------------------------------------------
# Fasten: bolts back out along their axis and turn in, joint by joint
# ---------------------------------------------------------------------------

## Head side of a simple solver bolt (createHorizontalBolt): outer V-stack bolts
## head on the bracket side (-1), everything else +1.
static func bolt_head_side(bolt: Dictionary) -> float:
	if str(bolt.get("bolt_type", "")) == "vstack" and str(bolt.get("bolt_sub_type", "")) == "outer":
		return -1.0
	return 1.0


## Target keys, widened to every module with op.allModules.
static func _fasten_targets(step: Dictionary, ctx: Dictionary) -> Array:
	var op: Dictionary = step.get("op", {})
	if not bool(op.get("allModules", false)):
		return _targets_of(step, ctx["parts"])
	var sels: Array = []
	for sel in step.get("targets", []):
		var s: Dictionary = (sel as Dictionary).duplicate()
		s.erase("moduleIndex")
		s.erase("arrayIndex")
		sels.append(s)
	return _targets_of({"targets": sels}, ctx["parts"])


static func stage_fasten(step: Dictionary, ctx: Dictionary) -> Dictionary:
	var op: Dictionary = step.get("op", {})
	var turns_raw = op.get("turns")
	var turns := maxf(0.25, float(turns_raw) if (turns_raw is float or turns_raw is int) and float(turns_raw) != 0.0 else 3.0)
	var entries: Array = []
	for rec in _fasten_targets(step, ctx):
		var obj: Dictionary = rec["obj"]
		var kind: String = rec["kind"]
		if kind == "bolt":
			var axis: Vector3 = (obj["dir"] as Vector3).normalized()
			var len := float(obj.get("length", 3.0))
			entries.append({"key": rec["key"], "kind": kind, "seated": obj["center"],
				"move_dir": axis * bolt_head_side(obj), "travel": maxf(1.0, len * 0.8),
				"spin_sign": 1.0, "turns": turns, "axis": axis,
				"joint": _joint_or_key(obj, kind, rec["key"]), "len": len})
		elif kind == "placement":
			# A detailed assembly: its bolt backs out along the joint's bolt
			# axis (the per-part stack motion is the Lab player's, A5).
			var axis2: Vector3 = (obj.get("bolt_dir", Vector3.UP) as Vector3).normalized()
			entries.append({"key": rec["key"], "kind": kind, "seated": part_center(obj, kind),
				"move_dir": -axis2, "travel": 2.4, "spin_sign": 1.0, "turns": turns, "axis": axis2,
				"joint": _joint_or_key(obj, kind, rec["key"]), "len": 3.0})
	# Work order: outer pivot, inner pivot, centre link, then by key.
	var by_joint := {}
	for en in entries:
		var id: String = en["joint"]
		if not by_joint.has(id):
			by_joint[id] = []
		(by_joint[id] as Array).append(en)
	var ids: Array = by_joint.keys()
	ids.sort_custom(func(a, b):
		var ra := LinkagePartKeys.joint_role_rank(_role_of(str(a)))
		var rb := LinkagePartKeys.joint_role_rank(_role_of(str(b)))
		if ra != rb:
			return ra < rb
		return str(a) < str(b))
	var joints: Array = []
	for ji in ids.size():
		var list: Array = by_joint[ids[ji]]
		var c := Vector3.ZERO
		var max_len := 0.0
		for en in list:
			en["joint_index"] = ji
			c += en["seated"]
			max_len = maxf(max_len, float(en["len"]))
		c /= float(list.size())
		var spread := 0.0
		for en in list:
			spread = maxf(spread, (en["seated"] as Vector3).distance_to(c))
		joints.append({"id": ids[ji], "center": c, "radius": maxf(8.0, spread + max_len), "count": list.size()})
	return {"kind": "fasten", "entries": entries, "joints": joints,
		"sequential": bool(op.get("sequential", false)) and joints.size() > 1}


static func _joint_or_key(obj: Dictionary, kind: String, key: String) -> String:
	var jk := LinkagePartKeys.joint_key(obj, kind)
	return jk if not jk.is_empty() else key


## The role segment of a joint id ("joint:a0:m0:top:inner[:cap]" -> "inner").
static func _role_of(id: String) -> String:
	var bits := id.split(":")
	var last := bits[bits.size() - 1] if bits.size() > 0 else ""
	if last == "cap" and bits.size() > 1:
		return ""  # JS: `pop().replace(/^cap$/, '')` — a cap joint ranks as "other"
	return last


## Per entry: {key, offset: Vector3, spin: float (radians about its axis),
## u}; plus {joint: active joint index, focus: {center, radius}}.
static func fasten_at(plan: Dictionary, t: float) -> Dictionary:
	var entries: Array = plan.get("entries", [])
	var joints: Array = plan.get("joints", [])
	var n := joints.size()
	var seq := bool(plan.get("sequential", false))
	var out: Array = []
	for en in entries:
		var u := LinkageBuildSteps.sequence_progress(t, int(en["joint_index"]), n, OVERLAP_FASTEN) if seq else t
		var e := _ease(u)
		out.append({"key": en["key"],
			"offset": (en["move_dir"] as Vector3) * float(en["travel"]) * (1.0 - e),
			"spin": float(en["spin_sign"]) * float(en["turns"]) * TAU * (1.0 - e),
			"u": u})
	var active := 0
	if seq:
		for i in n:
			if LinkageBuildSteps.sequence_progress(t, i, n, OVERLAP_FASTEN) > 0.0:
				active = i
	var focus := {}
	if not joints.is_empty():
		focus = joints[mini(active, n - 1)]
	return {"entries": out, "joint": active, "focus": focus}

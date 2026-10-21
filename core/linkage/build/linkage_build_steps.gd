class_name LinkageBuildSteps
extends RefCounted
## Build steps — port of LinkageLab's `js/linkage/build-steps.js`
## (LINKAGE_PARITY.md, phase A2): the step data model, groups (one repeated
## operation shown once), the staging visibility map, workbench planning and
## the auto-generator that writes a complete fabrication + assembly sequence.
##
## Steps are CONFIG data — saved under `buildSteps` in a v30 config and round-
## tripped by `LinkageParams.extra` — so they keep the web app's camelCase keys:
##   {id, kind, title, notes, stage, targets: [selector], view, transitionMs,
##    durationMs, op, groupId}
## Selectors are LinkagePartKeys selectors. Parts (beams, bolts, ...) are the
## game's snake_case dictionaries from `LinkagePartKeys.part_data`.
##
## Two JS behaviours are reproduced on purpose: Array.sort is STABLE in JS
## (GDScript's sort_custom is not — ties carry their insertion index), and
## Number.toFixed rounds an exact tie UP where printf rounds half to even
## (`js_fixed`) — 1/16 and 1/64 inch values hit exact ties.
##
## Pure and static. Pinned per preset against the generated steps in
## core/linkage/testdata/parity/*.json.

const VERSION := 1
const STEP_KINDS := ["view", "place", "fasten", "cut", "drill"]
const STEP_KIND_META := {
	"view": {"label": "View", "icon": "👁", "stage": "assembly", "durationMs": 1500, "hint": "Show the assembly from a saved camera view."},
	"place": {"label": "Place", "icon": "📦", "stage": "assembly", "durationMs": 2000, "hint": "Parts move into their assembled position."},
	"fasten": {"label": "Fasten", "icon": "🔩", "stage": "assembly", "durationMs": 2500, "hint": "Bolts (and optional nuts) turn in and seat."},
	"cut": {"label": "Cut", "icon": "🪚", "stage": "bench", "durationMs": 3000, "hint": "Saw cuts stock to length on the workbench."},
	"drill": {"label": "Drill", "icon": "🛠", "stage": "bench", "durationMs": 3000, "hint": "Drill bit plunges through each hole position."},
}
const DEFAULT_TRANSITION_MS := 800
const REPEAT_MODES := ["skip", "fast"]
## Common lumber stock lengths in inches (8, 10, 12, 16 ft).
const STOCK_LENGTHS_IN := [96.0, 120.0, 144.0, 192.0]
const INTRODUCING_KINDS := ["place", "fasten"]

const STACK_TYPE_SHORT := {
	"horizontal-bottom": "bottom H-beam", "horizontal-top": "top H-beam", "vertical": "V-beam",
	"vertical-cap": "cap V-beam", "fixed-beam": "fixed beam", "fixed-beam-cap": "cap fixed beam",
	"support-beam": "radial support beam", "support-beam-reciprocal": "reciprocal beam",
}

static var _id_counter := 0
static var _group_counter := 0


# ---------------------------------------------------------------------------
# JS number formatting
# ---------------------------------------------------------------------------

## Number.prototype.toFixed: an exact tie rounds to the LARGER magnitude.
static func js_fixed(v: float, digits: int) -> String:
	var m := pow(10.0, digits)
	var n := floorf(absf(v) * m + 0.5)
	var s := ("%." + str(digits) + "f") % (n / m)
	return ("-" + s) if v < 0.0 and n != 0.0 else s


## fmtIn: nearest 1/16 in, two decimals, trailing zeros (and a bare point) trimmed.
static func fmt_in(v: float) -> String:
	var s := js_fixed(roundf(v * 16.0) / 16.0, 2)
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s + " in"



# ---------------------------------------------------------------------------
# Model
# ---------------------------------------------------------------------------

static func default_op_for_kind(kind: String) -> Dictionary:
	match kind:
		"cut":
			return {"stockLengthIn": null, "kerfIn": 0.125}
		"drill":
			return {"bitDiameterIn": null, "holes": "auto"}
		"place":
			return {"approach": "above", "travelIn": 24, "parkOffset": null, "from": null, "sequential": false}
		"fasten":
			return {"bolt": null, "nut": null, "turns": 3, "allModules": false, "axes": null, "sequential": false}
	return {}


static func make_step_id() -> String:
	_id_counter += 1
	return "step-%s-%d-%04x" % [String.num_int64(Time.get_ticks_usec(), 36), _id_counter, randi() & 0xffff]


static func default_settings() -> Dictionary:
	return {"repeatMode": "skip", "fastFactor": 4}


static func normalize_settings(raw) -> Dictionary:
	var d := default_settings()
	if not (raw is Dictionary):
		return d
	if str(raw.get("repeatMode", "")) in REPEAT_MODES:
		d["repeatMode"] = str(raw["repeatMode"])
	var f = raw.get("fastFactor")
	if (f is float or f is int) and float(f) >= 1.0 and float(f) <= 20.0:
		d["fastFactor"] = f
	return d


static func create_default() -> Dictionary:
	return {"version": VERSION, "steps": [], "settings": default_settings()}


static func _clamp_ms(v, fallback: int) -> int:
	if not (v is float or v is int) or float(v) < 0.0 or is_nan(float(v)) or is_inf(float(v)):
		return fallback
	return mini(60000, int(roundf(float(v))))


## A step with defaults for its kind (createStep).
static func create_step(kind: String = "view", partial: Dictionary = {}) -> Dictionary:
	var k := kind if kind in STEP_KINDS else "view"
	var meta: Dictionary = STEP_KIND_META[k]
	var targets: Array = []
	if partial.get("targets") is Array:
		for sel in partial["targets"]:
			if sel is Dictionary:
				targets.append((sel as Dictionary).duplicate(true))
	var op := default_op_for_kind(k)
	if partial.get("op") is Dictionary:
		op.merge((partial["op"] as Dictionary).duplicate(true), true)
	var stage := str(partial.get("stage", ""))
	return {
		"id": str(partial["id"]) if partial.get("id") != null and str(partial.get("id")) != "" else make_step_id(),
		"kind": k,
		"title": str(partial["title"]) if partial.has("title") and partial["title"] != null else "%s step" % meta["label"],
		"notes": str(partial["notes"]) if partial.has("notes") and partial["notes"] != null else "",
		"stage": stage if stage == "bench" or stage == "assembly" else str(meta["stage"]),
		"targets": targets,
		"view": normalize_view(partial["view"]) if partial.get("view") is Dictionary else null,
		"transitionMs": _clamp_ms(partial.get("transitionMs"), DEFAULT_TRANSITION_MS),
		"durationMs": _clamp_ms(partial.get("durationMs"), int(meta["durationMs"])),
		"op": op,
		"groupId": str(partial["groupId"]) if partial.get("groupId") != null and str(partial.get("groupId")) != "" else null,
	}


## A saved camera view (normalizeView). `anchor` is a selector whose bounds
## centre is the look-at point; `foldAngleDeg` the pose (null = keep).
## `frame: "targets"` = close-up framing of the step's parts.
static func normalize_view(v) -> Variant:
	if not (v is Dictionary):
		return null
	var d: Dictionary = v
	var n := func(x, fallback):
		return float(x) if (x is float or x is int) else fallback
	var out := {
		"yaw": n.call(d.get("yaw"), 0.4),
		"pitch": n.call(d.get("pitch"), 0.14),
		"dist": maxf(1.0, n.call(d.get("dist"), 600.0)),
		"panX": n.call(d.get("panX"), 0.0),
		"panY": n.call(d.get("panY"), 0.0),
		"anchor": (d["anchor"] as Dictionary).duplicate(true) if d.get("anchor") is Dictionary else null,
		"foldAngleDeg": null if d.get("foldAngleDeg") == null else n.call(d.get("foldAngleDeg"), null),
	}
	if str(d.get("frame", "")) == "targets":
		out["frame"] = "targets"
		out["radial"] = bool(d.get("radial", false))
		out["padding"] = maxf(1.0, n.call(d.get("padding"), 1.6))
		out["detail"] = d.get("detail") != false
	return out


static func normalize_step(raw) -> Variant:
	if not (raw is Dictionary):
		return null
	return create_step(str(raw.get("kind", "view")), raw)


## Validate a `buildSteps` block loaded from config (normalizeBuildSteps).
static func normalize(raw) -> Dictionary:
	var out := create_default()
	if not (raw is Dictionary or raw is Array):
		return out
	var list: Array = []
	if raw is Dictionary and raw.get("steps") is Array:
		list = raw["steps"]
	elif raw is Array:
		list = raw
	var seen := {}
	for item in list:
		var step = normalize_step(item)
		if step == null:
			continue
		if seen.has(step["id"]):
			step["id"] = make_step_id()
		seen[step["id"]] = true
		(out["steps"] as Array).append(step)
	out["settings"] = normalize_settings(raw.get("settings") if raw is Dictionary else null)
	normalize_groups(out["steps"])
	return out


## For config export; null when there is nothing to save.
static func serialize(build_steps) -> Variant:
	if not (build_steps is Dictionary) or not (build_steps.get("steps") is Array) or (build_steps["steps"] as Array).is_empty():
		return null
	return {"version": VERSION, "steps": (build_steps["steps"] as Array).duplicate(true),
		"settings": normalize_settings(build_steps.get("settings"))}


# ---------------------------------------------------------------------------
# List operations (mutate the given block, return the affected step)
# ---------------------------------------------------------------------------

static func index_by_id(bs: Dictionary, id: String) -> int:
	var steps: Array = bs.get("steps", [])
	for i in steps.size():
		if str(steps[i]["id"]) == id:
			return i
	return -1


static func get_by_id(bs: Dictionary, id: String) -> Variant:
	var i := index_by_id(bs, id)
	return bs["steps"][i] if i >= 0 else null


static func add_step(bs: Dictionary, step: Dictionary, index: int = -1) -> Dictionary:
	var s := step if step.get("id") != null else create_step(str(step.get("kind", "view")), step)
	var steps: Array = bs["steps"]
	if index < 0 or index > steps.size():
		steps.append(s)
	else:
		steps.insert(index, s)
	return s


static func remove_step(bs: Dictionary, id: String) -> Variant:
	var i := index_by_id(bs, id)
	if i < 0:
		return null
	var removed = bs["steps"][i]
	(bs["steps"] as Array).remove_at(i)
	normalize_groups(bs["steps"])
	return removed


static func move_step(bs: Dictionary, from_index: int, to_index: int) -> bool:
	var steps: Array = bs["steps"]
	if from_index < 0 or from_index >= steps.size():
		return false
	var to := clampi(to_index, 0, steps.size() - 1)
	if to == from_index:
		return false
	var s = steps[from_index]
	steps.remove_at(from_index)
	steps.insert(to, s)
	normalize_groups(steps)
	return true


static func duplicate_step(bs: Dictionary, id: String) -> Variant:
	var i := index_by_id(bs, id)
	if i < 0:
		return null
	var src: Dictionary = (bs["steps"][i] as Dictionary).duplicate(true)
	src.erase("id")
	src["title"] = "%s (copy)" % str(src.get("title", ""))
	var copy := create_step(str(src.get("kind", "view")), src)
	(bs["steps"] as Array).insert(i + 1, copy)
	return copy


static func update_step(bs: Dictionary, id: String, patch: Dictionary) -> Variant:
	var s = get_by_id(bs, id)
	if s == null or patch.is_empty():
		return null
	var kind_changed: bool = patch.get("kind") != null and str(patch["kind"]) != str(s["kind"])
	var base: Dictionary = (s as Dictionary).duplicate(true)
	if kind_changed:
		if not patch.has("stage"):
			base.erase("stage")
		if not patch.has("durationMs"):
			base.erase("durationMs")
		base.erase("op")
	base.merge(patch.duplicate(true), true)
	base["id"] = s["id"]
	var merged := create_step(str(patch.get("kind", s["kind"])), base)
	if patch.get("op") is Dictionary:
		var op := default_op_for_kind(str(merged["kind"]))
		if not kind_changed:
			op.merge((s["op"] as Dictionary).duplicate(true), true)
		op.merge((patch["op"] as Dictionary).duplicate(true), true)
		merged["op"] = op
	(s as Dictionary).clear()
	(s as Dictionary).merge(merged)
	return s


# ---------------------------------------------------------------------------
# Groups: contiguous steps sharing a groupId are one repeated operation
# ---------------------------------------------------------------------------

static func make_group_id() -> String:
	_group_counter += 1
	return "grp-%s-%d-%03x" % [String.num_int64(Time.get_ticks_usec(), 36), _group_counter, randi() & 0xfff]


## Keep the first contiguous run (2+ members) of each groupId; clear the rest.
static func normalize_groups(steps: Array) -> Array:
	var runs: Array = []
	var i := 0
	while i < steps.size():
		var gid = steps[i].get("groupId")
		var j := i
		while j < steps.size() and steps[j].get("groupId") == gid:
			j += 1
		if gid != null:
			runs.append({"gid": gid, "start": i, "end": j})
		i = j
	var kept := {}
	for run in runs:
		if int(run["end"]) - int(run["start"]) >= 2 and not kept.has(run["gid"]):
			kept[run["gid"]] = run
	for run in runs:
		if kept.get(run["gid"]) != run:
			for k in range(int(run["start"]), int(run["end"])):
				steps[k]["groupId"] = null
	return steps


static func group_of(steps: Array, index: int) -> Dictionary:
	if index < 0 or index >= steps.size() or steps[index].get("groupId") == null:
		return {"groupId": null, "members": [index], "position": 0, "count": 1,
			"isFirst": true, "isLast": true, "first": index, "last": index}
	var gid = steps[index]["groupId"]
	var first := index
	var last := index
	while first > 0 and steps[first - 1].get("groupId") == gid:
		first -= 1
	while last < steps.size() - 1 and steps[last + 1].get("groupId") == gid:
		last += 1
	var members: Array = range(first, last + 1)
	return {"groupId": gid, "members": members, "position": index - first, "count": members.size(),
		"isFirst": index == first, "isLast": index == last, "first": first, "last": last}


static func group_steps(bs: Dictionary, ids: Array) -> Variant:
	var idx: Array = []
	for id in ids:
		var i := index_by_id(bs, str(id))
		if i >= 0 and not idx.has(i):
			idx.append(i)
	idx.sort()
	if idx.size() < 2:
		return null
	for k in range(1, idx.size()):
		if int(idx[k]) != int(idx[k - 1]) + 1:
			return null
	var gid := make_group_id()
	for i in idx:
		bs["steps"][i]["groupId"] = gid
	normalize_groups(bs["steps"])
	return gid


static func ungroup_steps(bs: Dictionary, ids: Array) -> int:
	var gids := {}
	for id in ids:
		var s = get_by_id(bs, str(id))
		if s != null and s.get("groupId") != null:
			gids[s["groupId"]] = true
	for s in bs["steps"]:
		if gids.has(s.get("groupId")):
			s["groupId"] = null
	return gids.size()


## Index to play after `index`: in "skip" mode a group's first member jumps the
## whole group. -1 at the end.
static func next_index_after(steps: Array, index: int, repeat_mode: String = "skip") -> int:
	if index >= steps.size() - 1:
		return -1
	var g := group_of(steps, index)
	if repeat_mode == "skip" and int(g["count"]) > 1 and bool(g["isFirst"]):
		return -1 if int(g["last"]) >= steps.size() - 1 else int(g["last"]) + 1
	return index + 1


## Group representatives + ungrouped steps: [{step, index, count, members}].
static func representative_steps(steps: Array) -> Array:
	var out: Array = []
	for i in steps.size():
		var g := group_of(steps, i)
		if bool(g["isFirst"]):
			out.append({"step": steps[i], "index": i, "count": g["count"], "members": g["members"]})
	return out


# ---------------------------------------------------------------------------
# Camera views + tween maths
# ---------------------------------------------------------------------------

static func ease_in_out_cubic(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return 4.0 * x * x * x if x < 0.5 else 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0


## Shortest signed angular difference b - a (radians), JS `%` semantics.
static func shortest_angle_delta(a: float, b: float) -> float:
	var d := fmod(b - a, TAU)
	if d > PI:
		d -= TAU
	if d < -PI:
		d += TAU
	return d


static func capture_view(cam: Dictionary, fold_angle_rad = null, anchor = null) -> Variant:
	return normalize_view({"yaw": cam.get("yaw"), "pitch": cam.get("pitch"), "dist": cam.get("dist"),
		"panX": cam.get("panX"), "panY": cam.get("panY"), "anchor": anchor,
		"foldAngleDeg": null if fold_angle_rad == null else rad_to_deg(float(fold_angle_rad))})


static func tween_view(a, b, t: float) -> Variant:
	var e := ease_in_out_cubic(t)
	var va = a if a != null else b
	var vb = b if b != null else a
	if va == null:
		return null
	var lerp_e := func(x, y) -> float:
		return float(x) + (float(y) - float(x)) * e
	var fa = va.get("foldAngleDeg")
	var fb = vb.get("foldAngleDeg")
	var fold = fb if fa == null else (fa if fb == null else lerp_e.call(fa, fb))
	return {
		"yaw": float(va["yaw"]) + shortest_angle_delta(float(va["yaw"]), float(vb["yaw"])) * e,
		"pitch": lerp_e.call(va["pitch"], vb["pitch"]),
		"dist": lerp_e.call(va["dist"], vb["dist"]),
		"panX": lerp_e.call(va.get("panX", 0.0), vb.get("panX", 0.0)),
		"panY": lerp_e.call(va.get("panY", 0.0), vb.get("panY", 0.0)),
		"anchor": vb.get("anchor"),
		"foldAngleDeg": fold,
	}


## Local progress of item i of n running one after another with overlapping
## windows (`overlap` = share of a window shared with the next item).
static func sequence_progress(t: float, i: int, n: int, overlap: float = 0.35) -> float:
	if n <= 1:
		return clampf(t, 0.0, 1.0)
	var win := 1.0 / (n - (n - 1) * overlap)
	var start := i * win * (1.0 - overlap)
	return clampf((t - start) / win, 0.0, 1.0)


## A view framing bounds {center, radius} (autoFrameView).
static func auto_frame_view(bounds: Dictionary, opts: Dictionary = {}) -> Variant:
	var fov := deg_to_rad(float(opts.get("fovDeg", 45.0)))
	var aspect := float(opts.get("aspect", 1.5))
	var padding := float(opts.get("padding", 1.35))
	var radius := float(bounds.get("radius", 100.0)) if not bounds.is_empty() else 100.0
	var v_fit := radius / sin(fov / 2.0)
	var h_fov := 2.0 * atan(tan(fov / 2.0) * aspect)
	var h_fit := radius / sin(h_fov / 2.0)
	var dist := maxf(v_fit, h_fit) * padding
	return normalize_view({"yaw": opts.get("yaw", 0.6), "pitch": opts.get("pitch", 0.35),
		"dist": maxf(12.0, dist), "panX": 0.0, "panY": 0.0, "anchor": opts.get("anchor"),
		"foldAngleDeg": opts.get("foldAngleDeg")})


# ---------------------------------------------------------------------------
# Visibility (assembly staging)
# ---------------------------------------------------------------------------

static func _matches_any(rec: Dictionary, targets: Array) -> bool:
	for sel in targets:
		if sel is Dictionary and LinkagePartKeys.match_selector(rec["obj"], sel, rec["kind"]):
			return true
	return false


## Part status at step `index`: done / active / future / unreferenced, plus the
## parked displacement before and after it (computeStepVisibility).
static func compute_step_visibility(steps: Array, index: int, parts: Array) -> Dictionary:
	var status := {}
	var introduced_any := false
	var idx := clampi(index, 0, maxi(0, steps.size() - 1))
	var first_intro := {}
	for si in steps.size():
		var step: Dictionary = steps[si]
		var targets: Array = step.get("targets", [])
		if not (str(step["kind"]) in INTRODUCING_KINDS) or targets.is_empty():
			continue
		for rec in parts:
			if first_intro.has(rec["key"]):
				continue
			if _matches_any(rec, targets):
				first_intro[rec["key"]] = si
				introduced_any = true
	var active := {}
	if idx < steps.size():
		var cur_targets: Array = steps[idx].get("targets", [])
		if not cur_targets.is_empty():
			for rec in parts:
				if _matches_any(rec, cur_targets):
					active[rec["key"]] = true
	for rec in parts:
		var key: String = rec["key"]
		var s := "unreferenced"
		if first_intro.has(key):
			s = "future" if int(first_intro[key]) > idx else "done"
		if active.has(key):
			s = "active"
		status[key] = s
	return {"status": status, "introducedAny": introduced_any, "activeKeys": active,
		"displacement": compute_displacement(steps, idx, parts),
		"displacementBefore": compute_displacement(steps, idx - 1, parts)}


## key -> parkOffset in effect after step `upto` (inclusive).
static func compute_displacement(steps: Array, upto: int, parts: Array) -> Dictionary:
	var out := {}
	for si in range(0, mini(upto, steps.size() - 1) + 1):
		var step: Dictionary = steps[si]
		var targets: Array = step.get("targets", [])
		if str(step["kind"]) != "place" or targets.is_empty():
			continue
		var park = (step.get("op", {}) as Dictionary).get("parkOffset")
		for rec in parts:
			if not _matches_any(rec, targets):
				continue
			if park != null:
				out[rec["key"]] = park
			else:
				out.erase(rec["key"])
	return out


## A parkOffset spec as a structure-local vector (inches). `{mode: "beside",
## gapIn}` = past the structure's +X extent, resting on its ground level.
static func resolve_park_offset(spec, structure_bounds: Dictionary, parts_bounds: Dictionary) -> Vector3:
	if not (spec is Dictionary):
		return Vector3.ZERO
	if str(spec.get("mode", "")) == "beside":
		var gap := float(spec["gapIn"]) if (spec.get("gapIn") is float or spec.get("gapIn") is int) else 24.0
		if structure_bounds.is_empty() or parts_bounds.is_empty():
			return Vector3.ZERO
		var sb_min: Vector3 = structure_bounds["min"]
		var sb_max: Vector3 = structure_bounds["max"]
		var pb_min: Vector3 = parts_bounds["min"]
		var pb_max: Vector3 = parts_bounds["max"]
		return Vector3((sb_max.x - pb_min.x) + gap, sb_min.y - pb_min.y,
			(sb_min.z + sb_max.z) / 2.0 - (pb_min.z + pb_max.z) / 2.0)
	return Vector3(float(spec.get("x", 0.0)), float(spec.get("y", 0.0)), float(spec.get("z", 0.0)))


static func step_target_bounds(step: Dictionary, data: Dictionary, parts: Array = []) -> Dictionary:
	var targets: Array = step.get("targets", [])
	if targets.is_empty():
		return {}
	var all := parts if not parts.is_empty() else LinkagePartKeys.collect_parts(data)
	var items: Array = []
	for rec in all:
		if _matches_any(rec, targets):
			items.append(rec)
	return LinkagePartKeys.parts_bounds(items)


# ---------------------------------------------------------------------------
# Workbench planning (cut / drill)
# ---------------------------------------------------------------------------

static func round_to(v: float, step: float = 1.0 / 16.0) -> float:
	return roundf(v / step) * step


static func beam_length_in(beam: Dictionary) -> float:
	if not (beam.get("p1") is Vector3) or not (beam.get("p2") is Vector3):
		return 0.0
	return ((beam["p2"] as Vector3) - (beam["p1"] as Vector3)).length()


## True when stock is longer than the beam by more than 1/16 in.
static func needs_cut(beam_len: float, stock_len: float) -> bool:
	return stock_len > beam_len + 1.0 / 16.0


## Smallest standard stock that fits, else the next foot up.
static func stock_length_for(length_in: float, explicit = null) -> float:
	if (explicit is float or explicit is int) and float(explicit) > 0.0:
		return float(explicit)
	for s in STOCK_LENGTHS_IN:
		if float(s) >= length_in - 1e-6:
			return float(s)
	return ceilf(length_in / 12.0) * 12.0


static func stack_type_label(stack_type: String) -> String:
	return str(STACK_TYPE_SHORT.get(stack_type, stack_type if not stack_type.is_empty() else "beam"))


## Physically identical beams (rounded length x width x thickness), longest
## first: [{key, length, w, t, count, beams, rep, stackTypes}].
static func group_beams_for_bench(beams: Array) -> Array:
	var groups := {}
	for beam in beams:
		if not (beam is Dictionary):
			continue
		var length := round_to(beam_length_in(beam))
		var w := round_to(float(beam.get("w", 0.0)))
		var t := round_to(float(beam.get("t", 0.0)))
		var key := "%sx%sx%s" % [js_fixed(length, 4), js_fixed(w, 4), js_fixed(t, 4)]
		if not groups.has(key):
			groups[key] = {"key": key, "length": length, "w": w, "t": t, "count": 0,
				"beams": [], "rep": beam, "stackTypes": [], "_i": groups.size()}
		var g: Dictionary = groups[key]
		g["count"] = int(g["count"]) + 1
		(g["beams"] as Array).append(beam)
		var st := str(beam.get("stack_type", ""))
		if not st.is_empty() and not (g["stackTypes"] as Array).has(st):
			(g["stackTypes"] as Array).append(st)
	var list: Array = groups.values()
	list.sort_custom(func(a, b):
		if float(a["length"]) != float(b["length"]):
			return float(a["length"]) > float(b["length"])
		if float(a["w"]) != float(b["w"]):
			return float(a["w"]) > float(b["w"])
		if float(a["t"]) != float(b["t"]):
			return float(a["t"]) > float(b["t"])
		return int(a["_i"]) < int(b["_i"]))
	return list


## Lay bench groups out side by side (one row per group, rows spaced in Z,
## beams flat on y = 0): {items, bounds, plane}.
static func plan_bench(groups: Array, opts: Dictionary = {}) -> Dictionary:
	var items: Array = []
	var gap := float(opts.get("gapIn", 6.0))
	var z := 0.0
	var max_len := 0.0
	for g in groups:
		var beam_len := float(g["length"])
		var stock_len := stock_length_for(beam_len, opts.get("stockLengthIn")) if bool(opts.get("stock", false)) else beam_len
		var w := float(g["w"]) if float(g["w"]) != 0.0 else 1.5
		var t := float(g["t"]) if float(g["t"]) != 0.0 else 1.5
		var item := {"group": g, "x0": 0.0, "y": t / 2.0, "z": z + w / 2.0, "w": w, "t": t,
			"beamLength": beam_len, "stockLength": maxf(stock_len, beam_len), "cutAt": beam_len,
			"offcut": maxf(0.0, stock_len - beam_len)}
		items.append(item)
		z += w + gap
		max_len = maxf(max_len, float(item["stockLength"]))
	if items.is_empty():
		return {"items": items, "bounds": {}, "plane": {}}
	var depth := z - gap
	var margin := 8.0
	var max_t := 0.0
	for it in items:
		max_t = maxf(max_t, float(it["t"]))
	var bmin := Vector3(-margin, 0.0, -margin)
	var bmax := Vector3(max_len + margin, max_t + margin, depth + margin)
	var dx := bmax.x - bmin.x
	var dz := bmax.z - bmin.z
	return {
		"items": items,
		"bounds": {"min": bmin, "max": bmax,
			"center": Vector3((bmin.x + bmax.x) / 2.0, 0.0, (bmin.z + bmax.z) / 2.0),
			"radius": maxf(4.0, sqrt(dx * dx + dz * dz) / 2.0)},
		"plane": {"x": max_len / 2.0, "z": depth / 2.0, "length": max_len + 2.0 * margin, "width": depth + 2.0 * margin},
	}


static func bench_summary(groups: Array, opts: Dictionary = {}) -> String:
	var lines: PackedStringArray = []
	for g in groups:
		var stock := ""
		if bool(opts.get("stock", false)):
			stock = " from %s in stock" % js_fixed(stock_length_for(float(g["length"]), opts.get("stockLengthIn")), 0)
		var labels: PackedStringArray = []
		for st in g["stackTypes"]:
			labels.append(stack_type_label(str(st)))
		lines.append("%d × %s · %s in%s" % [int(g["count"]),
			"/".join(labels) if not labels.is_empty() else "beam", js_fixed(float(g["length"]), 1), stock])
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# Holes (drill steps)
# ---------------------------------------------------------------------------

## Merge holes landing on the same spot (two bolts sharing one pivot), keeping
## the largest radius. Hole dicts as LinkageBeamHoles.intersections.
static func dedupe_holes(holes: Array, tol: float = 1.0 / 16.0) -> Array:
	var out: Array = []
	for h in holes:
		if not (h is Dictionary):
			continue
		var cross := float(h["pos_t"]) if str(h["through"]) == "W" else float(h["pos_w"])
		var same = null
		for o in out:
			var oc := float(o["pos_t"]) if str(o["through"]) == "W" else float(o["pos_w"])
			if str(o["through"]) == str(h["through"]) and absf(float(o["pos_l"]) - float(h["pos_l"])) <= tol and absf(oc - cross) <= tol:
				same = o
				break
		if same != null:
			if float(h["radius"]) > float(same["radius"]):
				same["radius"] = h["radius"]
			continue
		out.append((h as Dictionary).duplicate())
	return out


static func _hole_signature(holes: Array) -> String:
	var parts: Array = []
	for h in holes:
		var cross := float(h["pos_t"]) if str(h["through"]) == "W" else float(h["pos_w"])
		parts.append("%s:%s:%s:%s" % [str(h["through"]), js_fixed(round_to(float(h["pos_l"])), 4),
			js_fixed(round_to(cross), 4), js_fixed(round_to(float(h["radius"]), 1.0 / 64.0), 4)])
	parts.sort()
	return "|".join(parts)


# ---------------------------------------------------------------------------
# Auto-generation of a default build sequence (generateDefaultBuildSteps)
# ---------------------------------------------------------------------------

## The coarsest selectors matching exactly these beams, falling back to exact
## per-beam selectors.
static func _selectors_for_beam_set(beams: Array, data: Dictionary, parts: Array) -> Array:
	var wanted := {}
	for b in beams:
		wanted[LinkagePartKeys.part_key(b, "beam")] = true
	var covered := {}
	var out: Array = []
	var try_add := func(sel: Dictionary) -> bool:
		var res := LinkagePartKeys.resolve_targets(data, [sel], parts)
		var items: Array = res["items"]
		if items.is_empty():
			return false
		var all_wanted := true
		var all_covered := true
		for r in items:
			if not wanted.has(r["key"]):
				all_wanted = false
			if not covered.has(r["key"]):
				all_covered = false
		if not all_wanted or all_covered:
			return false
		for r in items:
			covered[r["key"]] = true
		out.append(sel)
		return true
	var stack_types: Array = []
	for b in beams:
		var st := str(b.get("stack_type", ""))
		if not stack_types.has(st):
			stack_types.append(st)
	for st in stack_types:
		if try_add.call({"kind": "beam", "stackType": st}):
			continue
		var layers: Array = []
		for b in beams:
			if str(b.get("stack_type", "")) == st:
				var li := int(b.get("layer_index", 0))
				if not layers.has(li):
					layers.append(li)
		layers.sort()
		for li in layers:
			if try_add.call({"kind": "beam", "stackType": st, "layerIndex": li}):
				continue
			var pats: Array = []
			for b in beams:
				if str(b.get("stack_type", "")) == st and int(b.get("layer_index", 0)) == li:
					var pid = b.get("pattern_id")
					pid = null if pid == null or str(pid) == "" else str(pid)
					if not pats.has(pid):
						pats.append(pid)
			for pat in pats:
				if pat != null and try_add.call({"kind": "beam", "stackType": st, "layerIndex": li, "patternId": pat}):
					continue
				for b in beams:
					var bp = b.get("pattern_id")
					bp = null if bp == null or str(bp) == "" else str(bp)
					if str(b.get("stack_type", "")) == st and int(b.get("layer_index", 0)) == li and bp == pat:
						var k := LinkagePartKeys.part_key(b, "beam")
						if not covered.has(k):
							covered[k] = true
							out.append(LinkagePartKeys.selector_for_part(b, "beam"))
	return out


## A complete default fabrication + assembly sequence (generateDefaultBuildSteps).
##
## `data` = LinkagePartKeys.part_data at the deployed pose. `opts`:
##   modules, useFixedBeams, archCapUprights, foldedAngleDeg (module assembly
##   pose), deployedAngleDeg, stockLengthIn, and `intersections_for`, a
##   Callable(beam) -> holes (LinkageBeamHoles.intersections against the
##   drill-solve bolts). See `generate_for` for the one-call version.
static func generate_default(data: Dictionary, opts: Dictionary = {}) -> Array:
	var steps: Array = []
	var parts := LinkagePartKeys.collect_parts(data)
	var beams: Array = data.get("beams", [])
	var bolts: Array = data.get("bolts", [])
	var modules := maxi(1, int(opts.get("modules", 1)))
	var folded = opts.get("foldedAngleDeg")
	var deployed = opts.get("deployedAngleDeg")
	var stock_explicit = opts.get("stockLengthIn")
	var has := func(sel: Dictionary) -> bool:
		return not (LinkagePartKeys.resolve_targets(data, [sel], parts)["items"] as Array).is_empty()
	var mk := func(kind: String, partial: Dictionary) -> void:
		steps.append(create_step(kind, partial))

	# 1. Cut: one step per identical beam group.
	for g in group_beams_for_bench(beams):
		var glen := float(g["length"])
		var stock := stock_length_for(glen, stock_explicit)
		if not needs_cut(glen, stock):
			continue
		var labels: PackedStringArray = []
		for st in g["stackTypes"]:
			labels.append(stack_type_label(str(st)))
		var offcut := (" (from %s stock, %s offcut)" % [fmt_in(stock), fmt_in(stock - glen)]) if stock > glen + 1e-6 else ""
		mk.call("cut", {
			"title": "Cut %d × %s to %s" % [int(g["count"]), " / ".join(labels), fmt_in(glen)],
			"notes": "%d pieces of %s × %s stock, %s long%s." % [int(g["count"]), fmt_in(float(g["w"])), fmt_in(float(g["t"])), fmt_in(glen), offcut],
			"targets": _selectors_for_beam_set(g["beams"], data, parts),
			"op": {"stockLengthIn": stock_explicit if (stock_explicit is float or stock_explicit is int) and float(stock_explicit) > 0.0 else null, "kerfIn": 0.125},
		})

	# 2. Drill: one step per distinct hole pattern.
	var intersections_for = opts.get("intersections_for")
	if intersections_for is Callable and not bolts.is_empty():
		var patterns := {}
		for beam in beams:
			var holes := dedupe_holes(intersections_for.call(beam))
			if holes.is_empty():
				continue
			var blen := round_to(beam_length_in(beam))
			var sig := "%sx%sx%s#%s" % [js_fixed(blen, 4), js_fixed(round_to(float(beam.get("w", 0.0))), 4),
				js_fixed(round_to(float(beam.get("t", 0.0))), 4), _hole_signature(holes)]
			if not patterns.has(sig):
				patterns[sig] = {"beams": [], "holes": holes, "len": blen, "_i": patterns.size()}
			(patterns[sig]["beams"] as Array).append(beam)
		var plist: Array = patterns.values()
		plist.sort_custom(func(a, b):
			if (a["beams"] as Array).size() != (b["beams"] as Array).size():
				return (a["beams"] as Array).size() > (b["beams"] as Array).size()
			if float(a["len"]) != float(b["len"]):
				return float(a["len"]) > float(b["len"])
			return int(a["_i"]) < int(b["_i"]))
		for pt in plist:
			var sts: Array = []
			for b in pt["beams"]:
				if not sts.has(str(b.get("stack_type", ""))):
					sts.append(str(b.get("stack_type", "")))
			var st_labels: PackedStringArray = []
			for st in sts:
				st_labels.append(stack_type_label(st))
			var holes: Array = pt["holes"]
			var positions: Array = []
			for h in holes:
				positions.append(float(h["pos_l"]) + float(pt["len"]) / 2.0)
			positions.sort()
			var pos_txt: PackedStringArray = []
			for v in positions:
				pos_txt.append(fmt_in(v))
			var dia := 0.0
			for h in holes:
				dia = maxf(dia, float(h["radius"]) * 2.0)
			var throughs: Array = []
			for h in holes:
				var tw := "width" if str(h["through"]) == "W" else "thickness"
				if not throughs.has(tw):
					throughs.append(tw)
			mk.call("drill", {
				"title": "Drill %d × %s (%d hole%s)" % [(pt["beams"] as Array).size(), " / ".join(st_labels),
					holes.size(), "" if holes.size() == 1 else "s"],
				"notes": "Holes from the left end: %s. Ø %s through the %s." % [", ".join(pos_txt), fmt_in(dia),
					" and ".join(PackedStringArray(throughs))],
				"targets": _selectors_for_beam_set(pt["beams"], data, parts),
				"op": {"bitDiameterIn": dia if dia != 0.0 else null, "holes": "auto"},
			})

	# 3. Assembly in shop order, operation-major so repeated module steps group:
	#    bottom ring (+ brackets) -> top ring built beside it as a mirror ->
	#    V modules -> attach to the bottom ring -> lift the top ring on ->
	#    secure the top brackets.
	var view_of := func(fold) -> Variant:
		if fold == null:
			return null
		return {"yaw": 0.6, "pitch": 0.35, "dist": 600, "anchor": null, "foldAngleDeg": fold}
	var close_view := func(fold, pitch: float) -> Dictionary:
		return {"yaw": 0.6, "pitch": pitch, "dist": 120, "anchor": null, "foldAngleDeg": fold,
			"frame": "targets", "radial": true, "padding": 1.35, "detail": true}
	var DOWN := 0.75
	var SIDE := 0.3
	var has_placements: bool = has.call({"kind": "placement"})
	var joint_count := func(targets: Array) -> int:
		var keys := {}
		for r in LinkagePartKeys.resolve_targets(data, targets, parts)["items"]:
			var jk := LinkagePartKeys.joint_key(r["obj"], r["kind"])
			if not jk.is_empty():
				keys[jk] = true
		return keys.size()
	var each_module := func(group_key: String, spec_for: Callable) -> int:
		var gid := "auto-" + group_key
		var emitted := 0
		for i in modules:
			var spec: Dictionary = spec_for.call(i, "Module %d" % (i + 1))
			if spec.is_empty():
				continue
			var targets: Array = []
			for sel in spec["targets"]:
				if has.call(sel):
					targets.append(sel)
			if targets.is_empty():
				continue
			var partial := spec.duplicate(true)
			var kind := str(partial["kind"])
			var close = partial.get("close")
			partial.erase("kind")
			partial.erase("close")
			if kind == "fasten":
				var joints: int = joint_count.call(targets)
				var op: Dictionary = (partial.get("op", {}) as Dictionary).duplicate(true)
				op["sequential"] = true
				partial["op"] = op
				partial["durationMs"] = mini(12000, 800 + 1800 * maxi(1, joints))
			# JS quirk, kept for parity: `{ kind, title, notes, close, ...extra }`
			# leaves the spec's UNFILTERED targets in `extra`, which is spread
			# after the filtered list — so a step keeps every selector it was
			# written with. The filtered list only decides whether the step
			# exists and how many joints it times.
			partial["targets"] = spec["targets"]
			partial["view"] = close_view.call(folded, float(close)) if close != null else null
			partial["groupId"] = gid
			mk.call(kind, partial)
			emitted += 1
		return emitted
	var parked := {"mode": "beside", "gapIn": 24}
	var axes_ud = {"axes": ["down", "up"]} if has_placements else {}
	var axes_rl = {"axes": ["right", "left"]} if has_placements else {}

	# Bottom assembly
	each_module.call("bottom-hbeams", func(i, m): return {"kind": "place",
		"title": "%s: set bottom H-beams" % m,
		"notes": "Stack the bottom horizontal beams with their washers between layers.",
		"targets": [{"kind": "beam", "stackType": "horizontal-bottom", "moduleIndex": i}],
		"op": {"approach": "above", "travelIn": 24}})
	each_module.call("bottom-brackets", func(i, m): return {"close": DOWN, "kind": "place",
		"title": "%s: fit the bottom brackets" % m,
		"notes": "Seat the U-brackets on the bottom stack with the hole aligned to the pivot.",
		"targets": [{"kind": "bracket", "moduleIndex": i, "ring": "bottom"}, {"kind": "placement", "moduleIndex": i, "ring": "bottom"}],
		"op": {"approach": "above", "travelIn": 12}})
	each_module.call("bottom-bracket-bolts", func(i, m): return {"close": DOWN, "kind": "fasten",
		"title": "%s: bolt the bottom ring pivots and brackets" % m,
		"notes": "Bolt the H-beam centre pivot, then bolt each bracket down through the bottom H-beam stack.",
		"targets": [{"kind": "bolt", "boltType": "hstack", "moduleIndex": i, "ring": "bottom"},
			{"kind": "bolt", "boltType": "hpivot", "moduleIndex": i, "ring": "bottom"},
			{"kind": "placement", "moduleIndex": i, "ring": "bottom"}],
		"op": axes_ud.duplicate(true)})

	# Top assembly, built on the ground beside the bottom ring as a mirror.
	each_module.call("top-hbeams", func(i, m): return {"kind": "place",
		"title": "%s: set top H-beams (mirror of the bottom ring)" % m,
		"notes": "Build the top ring beside the bottom ring, mirrored, with brackets facing down.",
		"targets": [{"kind": "beam", "stackType": "horizontal-top", "moduleIndex": i}],
		"op": {"approach": "above", "travelIn": 24, "parkOffset": parked.duplicate()}})
	each_module.call("top-brackets", func(i, m): return {"close": DOWN, "kind": "place",
		"title": "%s: fit the top brackets" % m,
		"notes": "Seat the top U-brackets on the top stack, opening downward.",
		"targets": [{"kind": "bracket", "moduleIndex": i, "ring": "top"}, {"kind": "placement", "moduleIndex": i, "ring": "top"}],
		"op": {"approach": "above", "travelIn": 12, "parkOffset": parked.duplicate()}})
	each_module.call("top-bracket-bolts", func(i, m): return {"close": DOWN, "kind": "fasten",
		"title": "%s: bolt the top ring pivots and brackets" % m,
		"notes": "Bolt the top H-beam centre pivot, then bolt each top bracket through the top H-beam stack.",
		"targets": [{"kind": "bolt", "boltType": "hstack", "moduleIndex": i, "ring": "top"},
			{"kind": "bolt", "boltType": "hpivot", "moduleIndex": i, "ring": "top"},
			{"kind": "placement", "moduleIndex": i, "ring": "top"}],
		"op": axes_ud.duplicate(true)})

	# V modules
	var fixed := bool(opts.get("useFixedBeams", false))
	var upright_sel := func(i: int) -> Array:
		if fixed:
			return [{"kind": "beam", "stackType": "fixed-beam", "moduleIndex": i}, {"kind": "beam", "stackType": "fixed-beam-cap", "moduleIndex": i}]
		return [{"kind": "beam", "stackType": "vertical", "moduleIndex": i}, {"kind": "beam", "stackType": "vertical-cap", "moduleIndex": i}]
	each_module.call("v-modules", func(i, m): return {"kind": "place",
		"title": "%s: assemble the V module" % m,
		"notes": "Stand the fixed uprights." if fixed else "Cross the V-beams in their A/B pattern and align the pivot holes.",
		"targets": upright_sel.call(i), "op": {"approach": "radial", "travelIn": 30}})
	each_module.call("v-center-bolts", func(i, m): return {"close": SIDE, "kind": "fasten",
		"title": "%s: bolt the V module centre pivot" % m,
		"notes": "Insert the centre pivot bolt through the crossing; snug, not torqued.",
		"targets": [{"kind": "joint", "moduleIndex": i, "ring": "center"}]})

	# Attach V modules to the bottom ring
	each_module.call("attach-bottom", func(i, m): return {"close": SIDE, "kind": "fasten",
		"title": "%s: attach the V module to the bottom ring" % m,
		"notes": "Slide the V-beam ends into the bottom brackets and insert the pivot bolts.",
		"targets": [{"kind": "bolt", "boltType": "vstack", "moduleIndex": i, "ring": "bottom"}, {"kind": "placement", "moduleIndex": i, "ring": "bottom"}],
		"op": axes_rl.duplicate(true)})

	# Lift the top assembly onto the V modules
	var lift: Array = []
	for sel in [{"kind": "beam", "stackType": "horizontal-top"}, {"kind": "bracket", "ring": "top"}, {"kind": "placement", "ring": "top"}]:
		if has.call(sel):
			lift.append(sel)
	if not lift.is_empty():
		mk.call("place", {"title": "Lift the top assembly onto the V modules",
			"notes": "With helpers on each side, lift the assembled top ring and lower the brackets onto the V-beam ends.",
			"targets": lift, "view": null, "op": {"approach": "above", "travelIn": 24, "from": "parked"}, "durationMs": 3500})

	# Secure the top brackets to the V modules
	each_module.call("secure-top", func(i, m): return {"close": SIDE, "kind": "fasten",
		"title": "%s: secure the top bracket to the V module" % m,
		"notes": "Insert the top pivot bolts and torque every pivot on this module.",
		"targets": [{"kind": "bolt", "boltType": "vstack", "moduleIndex": i, "ring": "top"}, {"kind": "placement", "moduleIndex": i, "ring": "top"}],
		"op": axes_rl.duplicate(true)})

	# Module steps share the assembly pose. Assigned RAW (not normalized),
	# exactly as the JS does — no panX/panY on these views.
	for s in steps:
		if str(s["stage"]) == "assembly" and s["view"] == null:
			s["view"] = view_of.call(folded)

	# 4. Deploy, then support beams, reciprocal bolts, panels (deployed pose).
	var support: bool = has.call({"kind": "beam", "stackType": "support-beam"})
	var rcp: bool = has.call({"kind": "beam", "stackType": "support-beam-reciprocal"})
	var rcp_bolts: bool = has.call({"kind": "bolt", "boltType": ["rcp-ring", "rcp-cross"]})
	var panels: bool = has.call({"kind": "panel"})
	var floor_beams: bool = has.call({"kind": "beam", "stackType": ["floor-beam", "floor-beam-reciprocal"]})
	var floor_deck: bool = has.call({"kind": "wall", "band": "floor"})
	var shade: bool = has.call({"kind": "wall", "band": "roof"})
	var lower_walls: bool = has.call({"kind": "wall", "band": "lower", "coverType": "plywood"})
	var lower_fabric: bool = has.call({"kind": "wall", "band": "lower", "coverType": "fabric"})
	var tables: bool = has.call({"kind": "wall", "band": "table"})
	var upper: bool = has.call({"kind": "wall", "band": "upper"})
	var coverings := lower_walls or lower_fabric or tables or upper or floor_beams or floor_deck or shade
	if deployed != null or support or rcp or panels or coverings:
		mk.call("view", {"title": "Deploy the structure", "notes": "Open the scissor ring to its deployed angle before adding the roof.",
			"targets": [], "view": view_of.call(deployed), "transitionMs": 2500, "durationMs": 800})
	if support:
		mk.call("place", {"title": "Install radial support beams", "notes": "Lay the radial support beams across the top ring.",
			"targets": [{"kind": "beam", "stackType": "support-beam"}], "view": view_of.call(deployed), "op": {"approach": "above", "travelIn": 24}})
	if rcp:
		mk.call("place", {"title": "Install reciprocal beams", "notes": "Weave the reciprocal beams over/under each other and onto the ring anchors.",
			"targets": [{"kind": "beam", "stackType": "support-beam-reciprocal"}], "view": view_of.call(deployed), "op": {"approach": "above", "travelIn": 24}})
	if rcp_bolts:
		mk.call("fasten", {"title": "Bolt the reciprocal beams", "notes": "Through-bolt each crossing and anchor.",
			"targets": [{"kind": "bolt", "boltType": ["rcp-ring", "rcp-cross"]}], "view": close_view.call(deployed, DOWN)})
	if panels:
		var count := (LinkagePartKeys.resolve_targets(data, [{"kind": "panel"}], parts)["items"] as Array).size()
		mk.call("place", {"title": "Mount the solar panels", "notes": "Lift each panel onto the support beams in order and clamp it down.",
			"targets": [{"kind": "panel"}], "view": view_of.call(deployed),
			"op": {"approach": "above", "travelIn": 30, "sequential": true}, "durationMs": mini(12000, maxi(2000, 600 * count + 800))})

	# 5. Raised floor: beams onto the bottom ring, then the deck.
	if floor_beams:
		mk.call("place", {"title": "Lay the floor beams", "notes": "Set the floor beams across the bottom ring, each anchored on its bottom scissor leg, weaving A over B like the roof beams.",
			"targets": [{"kind": "beam", "stackType": ["floor-beam", "floor-beam-reciprocal"]}], "view": view_of.call(deployed), "op": {"approach": "above", "travelIn": 24}})
	if floor_deck:
		mk.call("place", {"title": "Lay the floor deck", "notes": "Screw the plywood deck pieces onto the floor beams, cut edges toward the ring.",
			"targets": [{"kind": "wall", "band": "floor"}], "view": view_of.call(deployed), "op": {"approach": "above", "travelIn": 24}})

	# 6. Coverings go on after the roof, from the outside in.
	var cover_step := func(title: String, notes: String, sel: Dictionary, approach: String) -> void:
		var count := (LinkagePartKeys.resolve_targets(data, [sel], parts)["items"] as Array).size()
		mk.call("place", {"title": title, "notes": notes, "targets": [sel], "view": view_of.call(deployed),
			"op": {"approach": approach, "travelIn": 30, "sequential": true}, "durationMs": mini(12000, maxi(2000, 700 * count + 800))})
	if lower_walls:
		cover_step.call("Install the lower wall panels", "Stand each plywood wall against the outside face of the uprights and screw it to the V-beams; back any seams with a batten.", {"kind": "wall", "band": "lower", "coverType": "plywood"}, "radial")
	if lower_fabric:
		cover_step.call("Hang the lower fabric bands", "Grommet the lower fabric panels and lace them to the uprights, tensioning evenly.", {"kind": "wall", "band": "lower", "coverType": "fabric"}, "radial")
	if tables:
		cover_step.call("Fit the tables", "Drop each table onto the top edge of its lower wall and fix it with cleats on the uprights.", {"kind": "wall", "band": "table"}, "above")
	if upper:
		cover_step.call("Install the upper coverings", "Fit the upper plywood or fabric bands between the lower band and the top ring.", {"kind": "wall", "band": "upper"}, "radial")
	if shade:
		cover_step.call("Spread the shade tarps", "Unroll each tarp over its module from the outer pivots toward the centre, overlapping its neighbours at the middle, and tie the corners down.", {"kind": "wall", "band": "roof"}, "above")
	return steps


## The web app's Auto-generate for a design, in one call (build-steps-ui.js
## buildGenerationInput): parts at the deployed pose, holes against a drill
## solve with legacy bolts, module assembly shown 45 % of the way open.
## Angles may be overridden (degrees) — the selftest passes the JS values.
static func generate_for(p: LinkageParams, folded_deg = null, deployed_deg = null) -> Array:
	var deployed: float = float(deployed_deg) if deployed_deg != null else rad_to_deg(LinkageKinematics.optimal_closed_angle(p))
	var folded: float = float(folded_deg) if folded_deg != null else rad_to_deg(LinkageKinematics.effective_min_fold_angle(p))
	var pose := folded + (deployed - folded) * 0.45
	var data := LinkagePartKeys.part_data(p, deg_to_rad(deployed))
	var drill := LinkageBeamHoles.drill_solve(p, deg_to_rad(deployed))
	var drill_bolts: Array = drill["bolts"]
	return generate_default(data, {
		"modules": p.modules,
		"useFixedBeams": p.use_fixed_beams,
		"archCapUprights": p.arch_cap_uprights,
		"foldedAngleDeg": pose,
		"deployedAngleDeg": deployed,
		"intersections_for": func(beam): return LinkageBeamHoles.intersections(beam, drill_bolts),
	})


## One-line summary for a step list ("Place: V-beam · module 3").
static func step_summary(step: Dictionary) -> String:
	var meta: Dictionary = STEP_KIND_META.get(str(step.get("kind", "")), STEP_KIND_META["view"])
	var labels: PackedStringArray = []
	for sel in step.get("targets", []):
		var l := LinkagePartKeys.selector_label(sel)
		if not l.is_empty():
			labels.append(l)
	if labels.is_empty():
		return str(meta["label"])
	var t := "; ".join(labels.slice(0, 2))
	if labels.size() > 2:
		t += " +%d" % (labels.size() - 2)
	return "%s: %s" % [meta["label"], t]


## Total play time of a sequence in ms.
static func total_duration_ms(bs: Dictionary) -> int:
	var n := 0
	for s in bs.get("steps", []):
		n += int(s.get("transitionMs", 0)) + int(s.get("durationMs", 0))
	return n

class_name TcDesign
extends RefCounted

## THE solved TC design every reader uses (modal, builder, exports):
## `solve(spec)` → {spec (resolved), res (TcAssembly.solve), bom, checks,
## stats, clashes}. Cached by TcSpec.key_of (a small LRU); a mid-drag call
## can use `solve_transient` to skip the cache.

const CACHE_MAX := 24

static var _cache: Dictionary = {}
static var _order: Array = []
static var misses := 0


static func solve(spec: Dictionary) -> Dictionary:
	var key := TcSpec.key_of(spec)
	if _cache.has(key):
		_order.erase(key)
		_order.append(key)
		return _cache[key]
	misses += 1
	var d := solve_transient(spec)
	_cache[key] = d
	_order.append(key)
	while _order.size() > CACHE_MAX:
		_cache.erase(_order.pop_front())
	return d


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()


static func solve_transient(spec: Dictionary) -> Dictionary:
	var s := TcSpec.resolve(spec)
	var res := TcAssembly.solve(s)
	var clashes := TcAssembly.clashes(res)
	var bom := TcBom.compute(s, res)
	var d := {"spec": s, "res": res, "bom": bom, "clashes": clashes}
	d["checks"] = _checks(s, res, clashes)
	d["stats"] = _stats(res, bom)
	return d


static func _stats(res: Dictionary, bom: Dictionary) -> Dictionary:
	var bb := AABB()
	var first := true
	for id in res.get("order", []):
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var b: AABB = (pd["built"] as Dictionary)["bounds"]
		var xf: Transform3D = pd["xf"]
		var wb := xf * b
		bb = wb if first else bb.merge(wb)
		first = false
	return {"bounds_mm": bb, "mass_kg": float(bom["mass_kg"]), "volume_l": float(bom["volume_l"]),
		"parts": (res.get("order", []) as Array).size(), "joints": (res.get("joints", []) as Array).size(),
		"open_ports": (res.get("open", []) as Array).size()}


## {level error | warn | info, text, why, ids (part ids to show)}.
static func _checks(s: Dictionary, res: Dictionary, clashes: Array) -> Array:
	var out: Array = []
	for jd in res.get("joints", []):
		var pa: String = TcAssembly.split_ref(str(jd["a"]))[0]
		var pb: String = TcAssembly.split_ref(str(jd["b"]))[0]
		if not bool(jd["ok"]):
			out.append({"level": "error", "text": "These two ends cannot be joined: %s." % str(jd["why"]),
				"why": "Clamp faces only seal on a face of the same clamp size; threads only on their own size.",
				"ids": [pa, pb]})
		elif bool(jd["closing"]) and (float(jd["err_mm"]) > TcAssembly.CLOSE_OK_MM or float(jd["err_deg"]) > TcAssembly.CLOSE_OK_DEG):
			out.append({"level": "warn",
				"text": "A loop does not close: the faces miss by %.1f mm and %.1f°." % [float(jd["err_mm"]), float(jd["err_deg"])],
				"why": "A run that comes back on itself has to meet exactly or it will not clamp up. Tick Fit length on a spool in the loop, or change a part.",
				"ids": [pa, pb]})
	var names := {}
	for id in res.get("order", []):
		names[id] = str(res["parts"][id]["built"]["label"])
	for c in clashes:
		out.append({"level": "warn", "text": "%s runs into %s (%.0f mm)." % [names.get(c[0], c[0]), names.get(c[1], c[1]), float(c[2])],
			"why": "Two parts take the same space. Turn one (its joint's roll), or move the run.",
			"ids": [c[0], c[1]]})
	var bar := float(s.get("design_bar", 0.0))
	if bar > 0.0:
		var low := INF
		var low_j := {}
		for jd in res.get("joints", []):
			if str(jd["kind"]) != "tc":
				continue
			var r := TcStandards.clamp_rating_bar(str(jd["clamp"]), str(jd["size"]))
			if r < low:
				low = r
				low_j = jd
		if not low_j.is_empty() and low < bar:
			out.append({"level": "error", "text": "The %s clamps are rated about %.0f bar, under the %.1f bar design pressure." % [
					TcStandards.size_label(str(low_j["size"])), low, bar],
				"why": "Clamp ratings fall with size and temperature (these are typical figures — check the clamp's own sheet). Use bolted high-pressure clamps or lower the pressure.",
				"ids": [TcAssembly.split_ref(str(low_j["a"]))[0]]})
	var tc := float(s.get("design_c", 0.0))
	if tc != 0.0:
		for jd in res.get("joints", []):
			if str(jd["kind"]) != "tc":
				continue
			var g: Dictionary = TcStandards.GASKETS[str(jd["gasket"])]
			if tc > float(g["t_max_c"]) or tc < float(g["t_min_c"]):
				out.append({"level": "warn", "text": "%s gaskets are good for %.0f to %.0f °C, not %.0f °C." % [
						str(g["label"]), float(g["t_min_c"]), float(g["t_max_c"]), tc],
					"why": "Typical ranges — PTFE or silicone take steam and hot vapour.",
					"ids": [TcAssembly.split_ref(str(jd["a"]))[0]]})
				break
	var n_open := (res.get("open", []) as Array).size()
	if n_open > 0:
		out.append({"level": "info", "text": "%s still open." % UiText.count(n_open, "port"),
			"why": "Cap an end, or label it as an inlet or outlet so the world can connect to it.", "ids": []})
	return out


## Group of the checks by level (for the badge): [errors, warnings].
static func counts(d: Dictionary) -> Array:
	var e := 0
	var w := 0
	for c in d.get("checks", []):
		match str(c["level"]):
			"error": e += 1
			"warn": w += 1
	return [e, w]


# ---------------------------------------------------------------------------
# The world (Phase 7)
# ---------------------------------------------------------------------------

## Mm shift that stands a solved assembly in the prop's frame: its plan
## centre on the origin, its lowest point on y = 0. The builder, the
## connection ports and the crew-build pieces all use it.
static func world_offset(d: Dictionary) -> Vector3:
	var bb: AABB = (d.get("stats", {}) as Dictionary).get("bounds_mm", AABB())
	if bb.size == Vector3.ZERO:
		return Vector3.ZERO
	return Vector3(-(bb.position.x + bb.size.x * 0.5), -bb.position.y, -(bb.position.z + bb.size.z * 0.5))


## The graph preset a design binds to ({} = none): ComponentPresets by label.
static func bound_preset(spec: Dictionary) -> Dictionary:
	var lab := str(spec.get("binds", ""))
	if lab.is_empty():
		return {}
	return ComponentPresets.find_preset_by_label(lab)


## Labelled open end ref → the bound graph node's handle id. A label's
## "carries" kind meets the preset's first unused output of that kind, else
## its first unused input (res_out_<i> / res_in_<i>, GraphPortService's
## names). Unmatched labels get no handle (the port still shows in 3D).
static func graph_handles(spec: Dictionary) -> Dictionary:
	var preset := bound_preset(spec)
	var out := {}
	if preset.is_empty():
		return out
	var ps: Dictionary = preset.get("specs", {})
	var ins: Array = ps.get("inputs", [])
	var outs: Array = ps.get("outputs", [])
	var used := {}
	var labels: Dictionary = spec.get("labels", {})
	var refs := labels.keys()
	refs.sort()
	for ref in refs:
		var k := ResourceKinds.normalize_kind(str((labels[ref] as Dictionary).get("kind", "")))
		if k.is_empty():
			continue
		var h := ""
		for i in outs.size():
			if ResourceKinds.normalize_kind(str((outs[i] as Dictionary).get("kind", ""))) == k and not used.has("res_out_%d" % i):
				h = "res_out_%d" % i
				break
		if h.is_empty():
			for i in ins.size():
				if ResourceKinds.normalize_kind(str((ins[i] as Dictionary).get("kind", ""))) == k and not used.has("res_in_%d" % i):
					h = "res_in_%d" % i
					break
		if not h.is_empty():
			used[h] = true
			out[str(ref)] = h
	return out


## Every LABELLED open end as a ConnectionPortDefs port in the prop's frame
## (metres): its face centre, its outward axis, the label as its name, the
## carried kind, and the bound node's handle so a 3D conduit ends on it.
static func connection_ports(d: Dictionary) -> Array:
	var spec: Dictionary = d.get("spec", {})
	var labels: Dictionary = spec.get("labels", {})
	var handles := graph_handles(spec)
	var off := world_offset(d)
	var out: Array = []
	for op in (d.get("res", {}) as Dictionary).get("open", []):
		var ref := str(op["ref"])
		if not labels.has(ref):
			continue
		var lab: Dictionary = labels[ref]
		var xf: Transform3D = op["xf"]
		var pos := (xf.origin + off) * 0.001
		var text := str(lab.get("text", ""))
		var port := ConnectionPortDefs.make_port("tc_" + ref.replace(":", "_"), text if not text.is_empty() else ref,
			pos, xf.basis.z, str(handles.get(ref, "")), "", str(lab.get("kind", "")), "", 0.25)
		out.append(port)
	return out


## Order a crew puts the parts on: the vessel first, then outward joint by
## joint (depth from its group's root, which TcAssembly makes the vessel
## when there is one).
static func part_depths(d: Dictionary) -> Dictionary:
	var res: Dictionary = d.get("res", {})
	var pj: Dictionary = res.get("parent_joint", {})
	var joints: Array = res.get("joints", [])
	var depth := {}
	for id in res.get("order", []):
		var dd := 0
		if pj.has(id):
			var jd: Dictionary = joints[int(pj[id])]
			var a: String = TcAssembly.split_ref(str(jd["a"]))[0]
			var b: String = TcAssembly.split_ref(str(jd["b"]))[0]
			var other: String = b if a == id else a
			dd = int(depth.get(other, 0)) + 1
		depth[id] = dd
	return depth


## Estimated clamp mass (kg) from its clamp face OD: a 2" single-pin clamp
## is about 0.25 kg, a 4" about 0.36 kg (catalogue weights vary; an estimate).
static func clamp_kg(size: String) -> float:
	return 0.12 + 0.002 * float(TcStandards.tube(size)["flange"])


## The assembly as PackKitter part rows: the vessel a piece of its own, each
## fitting a piece of its own box, spools as sticks, gaskets + clamps loose.
static func parts_for_packing(d: Dictionary) -> Array:
	var res: Dictionary = d.get("res", {})
	var rows := {}
	for id in res.get("order", []):
		var b: Dictionary = res["parts"][id]["built"]
		var bb: AABB = b["bounds"]
		var s := bb.size * 0.001
		var dims := [s.x, s.y, s.z]
		dims.sort()
		var kind := "stick" if str(b["type"]) == "spool" and dims[2] > 0.4 else "piece"
		var key := "%s|%s|%.3f|%.3f|%.3f" % [str(b["label"]), kind, dims[0], dims[1], dims[2]]
		if not rows.has(key):
			rows[key] = PackKitter.part(str(b["label"]), kind, dims[2], dims[1], dims[0],
				maxf(float(b["mass_kg"]), 0.05), 0, {"round": kind == "stick"})
		rows[key]["qty"] = int(rows[key]["qty"]) + 1
	var out: Array = rows.values()
	var clamps := {}
	for jd in res.get("joints", []):
		if str(jd["kind"]) == "tc":
			var cls := TcStandards.clamp_class(str(jd["size"]))
			clamps[cls] = int(clamps.get(cls, 0)) + 1
	for cls in clamps:
		var f := float(TcStandards.tube(cls)["flange"]) * 0.001
		out.append(PackKitter.part("%s clamp + gasket" % TcStandards.size_label(cls), "loose",
			f * 1.6, f * 1.2, 0.03, clamp_kg(cls) + 0.02, int(clamps[cls])))
	return out


## The shipping spec (PackedSpec shape) for the record's packed form.
static func packed_spec(d: Dictionary) -> Dictionary:
	var env := PackKitter.envelope(PackKitter.kit(parts_for_packing(d)), "crate")
	if env.is_empty():
		return {}
	env["source"] = "computed"
	env["count"] = 1
	return env

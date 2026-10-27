class_name GantryLabAssembly
extends RefCounted

## A machine as a tree of MATED parts, and the one function that turns it
## into GantryLabFrame's layout shape (static / assemblies / loops / links /
## bed / spans / dims / origin …), so the builder, the pose, the belts, the
## design checks, the runtime and the exports read it unchanged.
##
## doc = {kinematics, parts: [part], loops: [loop], links: [link],
##   coax: [[a id, b id, label]], assemblies: {name: {parent, axis}},
##   meta: {moving {x,y,z → assembly}, spans, anchors, bed {size, kind},
##   bead_parent, mirror_x}}
## part = {id, ref, params, mate {to, tf, f, s, anchor, lat, h, turn, auto},
##   xf (a root's pose), asm (a motion mate's assembly), twin, also
##   [{to, tf, f}] (secondary contacts: a bracket's second leg), spin
##   {motor, per_rev_mm, sign}, label, fixed (not draggable), free (a part
##   drawn from `draw` with no catalog entry)}
## loop = {name, motor, sign, belt_w, nodes: [{part, s, kind}]}: the belt
##   plane is the FIRST node's band; any node whose mate is `auto` is moved
##   along its own axis onto that plane (an idler on its spacer stack, a
##   pulley along its shaft), so a belt is always planar by construction.
##
## The player's edits live in spec["assembly"] = {over: {id: {mate…, ref,
## params, removed}}, added: [part], unlinked: [id]}; `build(spec)` lays them
## over the generated doc, so a resized machine keeps every distance the
## player set (a mate's `s` is measured from its `anchor`).

const MOTION_ASM_DEFAULT := ""

static var _cache := {}


# ---------------------------------------------------------------------------
# Building the doc
# ---------------------------------------------------------------------------

static func uses_assembly(kinematics: String) -> bool:
	return kinematics in KINEMATICS


const KINEMATICS := ["bedslinger", "cartesian_xy", "corexy", "hbot"]


static func generate(spec: Dictionary) -> Dictionary:
	match str(spec["kinematics"]):
		"bedslinger", "corexz":
			return GantryLabGenSlinger.doc(spec)
		"cartesian_xy", "corexy", "hbot":
			return GantryLabGenCube.doc(spec)
	return {}


static func edits_of(spec: Dictionary) -> Dictionary:
	var e: Variant = spec.get("assembly", {})
	if not (e is Dictionary):
		return {"over": {}, "added": [], "unlinked": []}
	var d: Dictionary = e
	return {"over": d.get("over", {}), "added": d.get("added", []), "unlinked": d.get("unlinked", [])}


## The generated doc with the player's edits applied.
static func build(spec: Dictionary) -> Dictionary:
	var doc := generate(spec)
	if doc.is_empty():
		return doc
	var ed := edits_of(spec)
	var parts: Array = doc["parts"]
	var by_id := {}
	for p in parts:
		by_id[str((p as Dictionary)["id"])] = p
	for ap in ed["added"]:
		var a: Dictionary = (ap as Dictionary).duplicate(true)
		if not by_id.has(str(a.get("id", ""))) and GantryLabCatalog.has(str(a.get("ref", ""))):
			a["user"] = true
			parts.append(a)
			by_id[str(a["id"])] = a
	var removed := {}
	for id in ed["over"]:
		if not by_id.has(str(id)):
			continue
		var o: Dictionary = ed["over"][id]
		var p: Dictionary = by_id[str(id)]
		if bool(o.get("removed", false)):
			removed[str(id)] = true
			continue
		if o.has("ref") and GantryLabCatalog.has(str(o["ref"])):
			p["ref"] = str(o["ref"])
		if o.has("params"):
			var pp: Dictionary = (p.get("params", {}) as Dictionary).duplicate()
			for k in o["params"]:
				pp[k] = o["params"][k]
			p["params"] = pp
		if o.has("mate"):
			# An auto node keeps following its belt's plane whatever height
			# was stored; the rest of the mate is the player's.
			var m: Dictionary = (p.get("mate", {}) as Dictionary).duplicate()
			for k in o["mate"]:
				m[k] = o["mate"][k]
			p["mate"] = m
	for id in ed["unlinked"]:
		if by_id.has(str(id)):
			var p: Dictionary = by_id[str(id)]
			var tw := str(p.get("twin", ""))
			p["twin"] = ""
			if by_id.has(tw):
				(by_id[tw] as Dictionary)["twin"] = ""
	# Removing a part takes everything mated to it.
	var changed := true
	while changed:
		changed = false
		for p in parts:
			var pd: Dictionary = p
			var id := str(pd["id"])
			if removed.has(id):
				continue
			var to := str((pd.get("mate", {}) as Dictionary).get("to", ""))
			if not to.is_empty() and removed.has(to):
				removed[id] = true
				changed = true
	if not removed.is_empty():
		var keep: Array = []
		for p in parts:
			if not removed.has(str((p as Dictionary)["id"])):
				keep.append(p)
		doc["parts"] = keep
		var loops: Array = []
		for lp in doc.get("loops", []):
			var ok := true
			for nd in (lp as Dictionary)["nodes"]:
				if removed.has(str((nd as Dictionary)["part"])):
					ok = false
			if ok:
				loops.append(lp)
			else:
				doc["issues"] = (doc.get("issues", []) as Array) + [{"level": "warn", "text": "%s has lost a pulley or idler and is not drawn." % str((lp as Dictionary)["name"]), "parts": []}]
		doc["loops"] = loops
		var links: Array = []
		for lk in doc.get("links", []):
			if not removed.has(str((lk as Dictionary)["a"].get("part", ""))) and not removed.has(str((lk as Dictionary)["b"].get("part", ""))):
				links.append(lk)
		doc["links"] = links
	return doc


# ---------------------------------------------------------------------------
# Resolving: every part's pose, the fasteners, the belts
# ---------------------------------------------------------------------------

## {doc, parts: {id: {part, world, asm, boxes (world OBBs), feats}}, order,
##  fasteners: [{…, asm, owner}], issues, loops (resolved), pairs (exempt
##  from clashes)}
static func resolve(doc: Dictionary) -> Dictionary:
	var parts: Array = doc.get("parts", [])
	var by_id := {}
	for p in parts:
		by_id[str((p as Dictionary)["id"])] = p
	var order := _order(parts, by_id)
	var issues: Array = (doc.get("issues", []) as Array).duplicate()
	var world := {}
	_place_all(order, by_id, world, issues)
	# Belts: move every auto node onto the first node's band plane, then
	# place again (descendants follow).
	if _auto_align(doc, by_id, world):
		world.clear()
		_place_all(order, by_id, world, [])
	var asm_of := {}
	for id in order:
		var p: Dictionary = by_id[id]
		var a := str(p.get("asm", ""))
		if a.is_empty():
			var to := str((p.get("mate", {}) as Dictionary).get("to", ""))
			a = str(asm_of.get(to, "")) if not to.is_empty() else ""
		asm_of[id] = a
	var out := {"doc": doc, "parts": {}, "order": order, "fasteners": [], "issues": issues, "pairs": {}, "loops": []}
	for id in order:
		var p: Dictionary = by_id[id]
		if not world.has(id):
			continue
		var w: Transform3D = world[id]
		var obbs: Array = []
		for b in _boxes_of(p):
			var bd: Dictionary = b
			obbs.append({"xf": w * Transform3D(bd.get("b", Basis.IDENTITY), bd["c"]), "s": bd["s"], "thin": bool(bd.get("thin", false)), "holed": bool(bd.get("holed", false))})
		out["parts"][id] = {"part": p, "world": w, "asm": asm_of[id], "boxes": obbs}
	# Fasteners and mate validity.
	for id in order:
		var p: Dictionary = by_id[id]
		var m: Dictionary = p.get("mate", {})
		if m.is_empty() or not world.has(id):
			continue
		var to := str(m.get("to", ""))
		if not world.has(to):
			continue
		var tp: Dictionary = by_id[to]
		var tf := feature_of(tp, str(m.get("tf", "")))
		var cf := feature_of(p, str(m.get("f", "")))
		_pair(out, id, to)
		var fit := GantryLabMates.fits(tf, cf, m)
		if not bool(fit["ok"]):
			issues.append({"level": "error", "text": "%s: %s." % [label_of(p), str(fit["why"])], "parts": [id]})
		var extra := _mate_extra(p, by_id, doc)
		for fz in GantryLabMates.fasteners(world[to], tf, cf, m, extra):
			var fd: Dictionary = fz
			fd["asm"] = asm_of[id]
			fd["owner"] = id
			if str(fd["kind"]) == "wheel" and m.has("motor"):
				fd["spin"] = {"motor": int(m["motor"]), "per_rev_mm": TAU * float(fd.get("r", GantryLabCatalog.WHEEL_R)) * 1000.0, "sign": float(m.get("sign", 1.0))}
			out["fasteners"].append(fd)
		# Secondary contacts: the other leg of a corner bracket.
		for al in p.get("also", []):
			var ad: Dictionary = al
			var to2 := str(ad.get("to", ""))
			if not world.has(to2):
				continue
			_pair(out, id, to2)
			var tf2 := feature_of(by_id[to2], str(ad.get("tf", "")))
			var cf2 := feature_of(p, str(ad.get("f", "")))
			var inf := GantryLabMates.infer(world[to2], tf2, cf2, world[id])
			var m2 := {"s": float(inf["s"]), "lat": float(inf["lat"]), "h": float(inf["h"]), "turn": int(inf["turn"]), "anchor": "start"}
			var ok2 := absf(float(inf["h"])) < 0.0008 and float(inf["err"]) < 0.01 and bool(GantryLabMates.fits(tf2, cf2, m2)["ok"])
			if not ok2:
				issues.append({"level": "warn", "text": "%s does not sit on the %s it should bolt to." % [label_of(p), label_of(by_id[to2])], "parts": [id, to2]})
				continue
			for fz in GantryLabMates.fasteners(world[to2], tf2, cf2, m2, extra):
				var fd: Dictionary = fz
				fd["asm"] = asm_of[id]
				fd["owner"] = id
				out["fasteners"].append(fd)
		# A part the player added has no `also`: bolt every other leg that
		# lands flat on something it fastens to (a joining plate's second
		# beam, a cube connector's other ends).
		if not p.has("also"):
			_auto_legs(out, p, id, m, world, by_id, order, asm_of, extra)
	# Coaxial pairs (a screw through its nut): exempt, and checked.
	for cx in doc.get("coax", []):
		var a := str(cx[0])
		var b := str(cx[1])
		if not world.has(a) or not world.has(b):
			continue
		_pair(out, a, b)
		# The screw also passes through whatever holds the nut.
		var holder := str((by_id[b].get("mate", {}) as Dictionary).get("to", ""))
		if not holder.is_empty():
			_pair(out, a, holder)
		var wa: Transform3D = world[a]
		var wb: Transform3D = world[b]
		var ax := wa.basis.y.normalized()
		var dv := wb.origin - wa.origin
		var off := (dv - ax * dv.dot(ax)).length()
		var tilt := absf(absf(wb.basis.y.normalized().dot(ax)) - 1.0)
		if off > 0.0008 or tilt > 0.002:
			issues.append({"level": "error", "text": "%s is %.1f mm off the %s's axis." % [label_of(by_id[a]), off * 1000.0, label_of(by_id[b])], "parts": [a, b]})
	# Generations: parts mated through a common parent never clash by design
	# (a pulley in a plate's pilot hole, a nut in its tab).
	for id in order:
		var to := str((by_id[id].get("mate", {}) as Dictionary).get("to", ""))
		if to.is_empty():
			continue
		var gp := str((by_id.get(to, {}).get("mate", {}) as Dictionary).get("to", ""))
		if not gp.is_empty():
			_pair(out, id, gp)
	for id in order:
		var tw := str(by_id[id].get("twin", ""))
		if not tw.is_empty() and not by_id.has(tw):
			by_id[id]["twin"] = ""
	out["loops"] = _resolve_loops(doc, by_id, world, asm_of, issues)
	return out


## The secondary contacts of a part's `leg` features: for each leg other
## than the mated one, the first compatible target feature it sits flat on
## with every hole on a slot / grid hole / tapped end gets its fasteners.
static func _auto_legs(out: Dictionary, p: Dictionary, id: String, m: Dictionary, world: Dictionary, by_id: Dictionary,
		order: Array, asm_of: Dictionary, extra: Dictionary) -> void:
	if bool(p.get("free", false)):
		return
	var legs: Array = []
	for fv in GantryLabCatalog.features(str(p["ref"]), p.get("params", {})):
		var cf: Dictionary = fv
		if bool(cf.get("leg", false)) and str(cf["id"]) != str(m.get("f", "")):
			legs.append(cf)
	if legs.is_empty():
		return
	var wc: Transform3D = world[id]
	for cfv in legs:
		var cf: Dictionary = cfv
		var at: Vector3 = wc * (cf["xf"] as Transform3D).origin
		var done := false
		for oid in order:
			if done:
				break
			if oid == id or not world.has(oid) or bool(by_id[oid].get("free", false)):
				continue
			var op: Dictionary = by_id[oid]
			var wo: Transform3D = world[oid]
			for tfv in GantryLabCatalog.features(str(op["ref"]), op.get("params", {})):
				var tf: Dictionary = tfv
				if GantryLabMates.mate_type(cf, tf).is_empty():
					continue
				var fw: Transform3D = wo * (tf["xf"] as Transform3D)
				# Cheap reject: the leg must be on the target's plane.
				if absf((at - fw.origin).dot(fw.basis.y.normalized())) > 0.0008:
					continue
				var inf := GantryLabMates.infer(wo, tf, cf, wc)
				if absf(float(inf["h"])) > 0.0008 or float(inf["err"]) > 0.01:
					continue
				var m2 := {"s": float(inf["s"]), "lat": float(inf["lat"]), "h": 0.0, "turn": int(inf["turn"]), "anchor": "start"}
				if not bool(GantryLabMates.fits(tf, cf, m2)["ok"]):
					continue
				_pair(out, id, str(oid))
				for fz in GantryLabMates.fasteners(wo, tf, cf, m2, extra):
					var fd: Dictionary = fz
					fd["asm"] = asm_of[id]
					fd["owner"] = id
					out["fasteners"].append(fd)
				done = true
				break


static func _pair(out: Dictionary, a: String, b: String) -> void:
	out["pairs"][a + "|" + b] = true
	out["pairs"][b + "|" + a] = true


static func _order(parts: Array, by_id: Dictionary) -> Array:
	var order: Array = []
	var seen := {}
	for p in parts:
		_visit(str((p as Dictionary)["id"]), by_id, order, seen, {})
	return order


static func _visit(id: String, by_id: Dictionary, order: Array, seen: Dictionary, stack: Dictionary) -> void:
	if seen.has(id) or stack.has(id) or not by_id.has(id):
		return
	stack[id] = true
	var to := str(((by_id[id] as Dictionary).get("mate", {}) as Dictionary).get("to", ""))
	if not to.is_empty():
		_visit(to, by_id, order, seen, stack)
	seen[id] = true
	order.append(id)


static func _place_all(order: Array, by_id: Dictionary, world: Dictionary, issues: Array) -> void:
	for id in order:
		var p: Dictionary = by_id[id]
		var m: Dictionary = p.get("mate", {})
		if m.is_empty() or str(m.get("to", "")).is_empty():
			world[id] = p.get("xf", Transform3D.IDENTITY)
			continue
		var to := str(m["to"])
		if not world.has(to):
			issues.append({"level": "error", "text": "%s is mated to a missing part." % label_of(p), "parts": [id]})
			continue
		var tf := feature_of(by_id[to], str(m.get("tf", "")))
		var cf := feature_of(p, str(m.get("f", "")))
		if tf.is_empty() or cf.is_empty() or GantryLabMates.mate_type(cf, tf).is_empty():
			issues.append({"level": "error", "text": "%s cannot fasten there." % label_of(p), "parts": [id]})
			world[id] = world[to]
			continue
		world[id] = GantryLabMates.place(world[to], tf, cf, m)


static func feature_of(p: Dictionary, fid: String) -> Dictionary:
	if bool(p.get("free", false)):
		return {}
	return GantryLabCatalog.feature(str(p["ref"]), p.get("params", {}), fid)


static func _boxes_of(p: Dictionary) -> Array:
	if bool(p.get("free", false)):
		var bs: Array = []
		for dd in p.get("draw", []):
			var d: Dictionary = dd
			if d.has("s"):
				bs.append({"c": d.get("pick_c", d.get("c", Vector3.ZERO)), "s": d["s"], "b": d.get("basis", Basis.IDENTITY)})
		return bs
	return GantryLabCatalog.boxes(str(p["ref"]), p.get("params", {}))


static func label_of(p: Dictionary) -> String:
	if p.has("label") and not str(p["label"]).is_empty():
		return str(p["label"])
	if bool(p.get("free", false)):
		return str(p.get("id", "part"))
	return GantryLabCatalog.label_of(str(p["ref"]), GantryLabCatalog.params_of(str(p["ref"]), p.get("params", {})))


static func _mate_extra(p: Dictionary, by_id: Dictionary, doc: Dictionary) -> Dictionary:
	var pp := GantryLabCatalog.params_of(str(p.get("ref", "")), p.get("params", {}))
	var extra := {"wheelbase": float(pp.get("wheelbase", 0.06)), "wheels": int(pp.get("wheels", 4)), "belt_w": float(pp.get("belt_w", 0.006)),
		"wheel_r": float(pp.get("wheel_r", GantryLabCatalog.WHEEL_R)), "wheel_w": float(pp.get("wheel_w", GantryLabCatalog.WHEEL_W))}
	return extra


## Where a loop node's band centre is (world) and its radius / axis.
static func band_of(p: Dictionary, w: Transform3D) -> Dictionary:
	var f := feature_of(p, "belt")
	if f.is_empty():
		return {"c": w.origin, "r": 0.0, "axis": w.basis.y.normalized()}
	return {"c": w * (f["xf"] as Transform3D).origin, "r": float(f.get("r", 0.0)), "axis": w.basis.y.normalized()}


static func _auto_align(doc: Dictionary, by_id: Dictionary, world: Dictionary) -> bool:
	var moved := false
	for lp in doc.get("loops", []):
		var loop: Dictionary = lp
		var nodes: Array = loop["nodes"]
		if nodes.is_empty() or not by_id.has(str((nodes[0] as Dictionary)["part"])):
			continue
		var p0: Dictionary = by_id[str(nodes[0]["part"])]
		if not world.has(str(p0["id"])):
			continue
		var b0 := band_of(p0, world[str(p0["id"])])
		var n: Vector3 = b0["axis"]
		var plane_c: Vector3 = b0["c"]
		for i in range(1, nodes.size()):
			var id := str((nodes[i] as Dictionary)["part"])
			if not by_id.has(id) or not world.has(id):
				continue
			var p: Dictionary = by_id[id]
			var m: Dictionary = p.get("mate", {})
			var bb := band_of(p, world[id])
			var d: float = ((bb["c"] as Vector3) - plane_c).dot(n)
			if absf(d) < 1e-5:
				continue
			# A clamp reaches the belt by its own size: grow it to the plane.
			if str((nodes[i] as Dictionary).get("kind", "")) == "clamp" and str(p.get("ref", "")) == "belt_clamp":
				var ln: Vector3 = ((world[id] as Transform3D).basis.inverse() * n)
				var pp: Dictionary = GantryLabCatalog.params_of("belt_clamp", p.get("params", {}))
				var grip: Vector2 = pp.get("grip", Vector2.ZERO)
				if absf(ln.y) > 0.9:
					pp["h"] = maxf(0.004, float(pp["h"]) - d / ln.y)
				elif absf(ln.z) > 0.9:
					grip.y -= d / ln.z
				elif absf(ln.x) > 0.9:
					grip.x -= d / ln.x
				pp["grip"] = grip
				p["params"] = pp
				moved = true
				continue
			if not bool(m.get("auto", false)):
				continue
			var to := str(m.get("to", ""))
			if not world.has(to):
				continue
			var tf := feature_of(by_id[to], str(m.get("tf", "")))
			var cf := feature_of(p, str(m.get("f", "")))
			var kind := GantryLabMates.mate_type(cf, tf)
			var fx: Transform3D = (world[to] as Transform3D) * (tf["xf"] as Transform3D)
			var m2 := m.duplicate()
			if kind == "shaft":
				var ax := fx.basis.y.normalized()
				var k := ax.dot(n)
				if absf(k) < 0.5:
					continue
				var sa := GantryLabMates.abs_s(tf, m) - d / k
				m2["s"] = GantryLabMates.rel_s(tf, str(m.get("anchor", "start")), sa)
			else:
				var tn := fx.basis.y.normalized()
				var k2 := tn.dot(n)
				if absf(k2) < 0.5:
					# The node slides in the plane instead (a clamp's height
					# is the generator's business).
					continue
				m2["h"] = maxf(0.0, float(m.get("h", 0.0)) - d / k2)
			p["mate"] = m2
			moved = true
	return moved


static func _resolve_loops(doc: Dictionary, by_id: Dictionary, world: Dictionary, asm_of: Dictionary, issues: Array) -> Array:
	var out: Array = []
	for lp in doc.get("loops", []):
		var loop: Dictionary = lp
		var nodes_in: Array = loop["nodes"]
		var nodes: Array = []
		var n := Vector3.ZERO
		var plane_c := Vector3.ZERO
		var ok := true
		for i in nodes_in.size():
			var nd: Dictionary = nodes_in[i]
			var id := str(nd["part"])
			if not by_id.has(id) or not world.has(id):
				ok = false
				break
			var b := band_of(by_id[id], world[id])
			if i == 0:
				n = b["axis"]
				plane_c = b["c"]
			var c: Vector3 = b["c"]
			var off := (c - plane_c).dot(n)
			if absf(off) > 0.0008:
				issues.append({"level": "error", "text": "%s: the %s sits %.1f mm out of the belt's plane — the belt would twist." % [str(loop["name"]), label_of(by_id[id]), off * 1000.0], "parts": [id]})
			nodes.append({"asm": str(asm_of.get(id, "")), "c": c - n * off, "r": float(b["r"]) if str(nd.get("kind", "")) != "clamp" else 0.0,
				"s": float(nd.get("s", 1.0)), "kind": str(nd.get("kind", "idler")), "part": id})
			# Idlers spin with their belt.
			var p: Dictionary = by_id[id]
			if str(nd.get("kind", "")) == "idler" and not p.has("spin") and float(b["r"]) > 0.0:
				p["spin"] = {"motor": int(loop.get("motor", 0)), "per_rev_mm": TAU * float(b["r"]) * 1000.0, "sign": float(nd.get("s", 1.0)) * float(loop.get("sign", 1.0))}
		if not ok:
			continue
		out.append({"name": str(loop["name"]), "motor": int(loop.get("motor", 0)), "sign": float(loop.get("sign", 1.0)), "belt_w": float(loop.get("belt_w", 0.006)), "n": n, "nodes": nodes})
	return out


# ---------------------------------------------------------------------------
# The layout shape
# ---------------------------------------------------------------------------

## spec → GantryLabFrame layout (cached by the spec's key).
static func layout(spec: Dictionary) -> Dictionary:
	var key := GantryLabSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	var doc := build(spec)
	var res := resolve(doc)
	var lay := to_layout(spec, res)
	if _cache.size() > 16:
		_cache.clear()
	_cache[key] = lay
	return lay


static func clear_cache() -> void:
	_cache.clear()


static func to_layout(spec: Dictionary, res: Dictionary) -> Dictionary:
	var doc: Dictionary = res["doc"]
	var meta: Dictionary = doc.get("meta", {})
	var asms_def: Dictionary = doc.get("assemblies", {})
	var st_beams: Array = []
	var st_parts: Array = []
	var asms := {}
	for name in asms_def:
		var ad: Dictionary = asms_def[name]
		asms[name] = {"parent": str(ad.get("parent", "")), "base": Vector3.ZERO, "beams": [], "parts": [], "mass_kg": 0.0, "axis": str(ad.get("axis", ""))}
	var kg := {}
	var screws: Array = []
	var origin := Vector3.ZERO
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for id in res["order"]:
		if not res["parts"].has(id):
			continue
		var rp: Dictionary = res["parts"][id]
		var p: Dictionary = rp["part"]
		var w: Transform3D = rp["world"]
		var asm := str(rp["asm"])
		var beams: Array = st_beams if asm.is_empty() or not asms.has(asm) else asms[asm]["beams"]
		var plist: Array = st_parts if asm.is_empty() or not asms.has(asm) else asms[asm]["parts"]
		var ref := str(p.get("ref", ""))
		var params := GantryLabCatalog.params_of(ref, p.get("params", {}))
		kg[asm] = float(kg.get(asm, 0.0)) + (float(p.get("kg", 0.0)) if bool(p.get("free", false)) else GantryLabCatalog.mass_kg(ref, params))
		var aabb := _aabb_of(rp["boxes"])
		if aabb.size != Vector3.ZERO:
			lo = lo.min(aabb.position)
			hi = hi.max(aabb.end)
		var draws: Array = p.get("draw", []) if bool(p.get("free", false)) else GantryLabCatalog.draw(ref, params)
		var first := true
		for dd in draws:
			var d: Dictionary = (dd as Dictionary).duplicate()
			if bool(d.get("beam", false)):
				var a := w * (d["a"] as Vector3)
				var b := w * (d["b"] as Vector3)
				beams.append({"a": a, "b": b, "profile": str(d["profile"]), "label": label_of(p), "group": str(p.get("group", "frame")),
					"up": (w.basis * (d.get("up", Vector3.UP) as Vector3)).normalized(), "id": id, "pick_aabb": aabb})
				continue
			var lc: Vector3 = d.get("c", Vector3.ZERO)
			var lb: Basis = d.get("basis", Basis.IDENTITY)
			d["c"] = w * lc
			d["basis"] = w.basis * lb
			d["label"] = label_of(p)
			d["id"] = id
			if first:
				d["pick_aabb"] = aabb
				first = false
			else:
				d["no_pick"] = true
			if p.has("spin"):
				d["spin"] = p["spin"]
			if not d.has("s"):
				d["s"] = Vector3(0.02, 0.02, 0.02)
			plist.append(d)
		if ref == "tr8_screw":
			var ln := float(params["len"])
			screws.append({"a": w.origin, "b": w * Vector3(0, ln, 0), "d_mm": float(params["d"]) * 1000.0, "label": label_of(p), "assembly": asm})
		if ref == "tool":
			origin = w.origin
	# Fasteners: drawn into the owner's assembly (never picked on their own).
	for fz in res["fasteners"]:
		var fd: Dictionary = fz
		var k := str(fd["kind"])
		if k.ends_with("_hidden"):
			continue
		var asm := str(fd.get("asm", ""))
		var plist: Array = st_parts if asm.is_empty() or not asms.has(asm) else asms[asm]["parts"]
		var xf: Transform3D = fd["xf"]
		var d := {"kind": "fastener_" + k if k in ["bolt", "nut", "tnut", "washer", "spacer"] else k, "c": xf.origin, "basis": xf.basis, "label": str(fd.get("label", k)),
			"id": str(fd.get("owner", "")), "no_pick": true, "s": Vector3(0.01, 0.01, 0.01)}
		for key in ["d", "len", "head", "ecc", "r", "w", "h"]:
			if fd.has(key):
				d[key] = fd[key]
		if fd.has("spin"):
			d["spin"] = fd["spin"]
		plist.append(d)
		kg[asm] = float(kg.get(asm, 0.0)) + 0.004
	# Moving masses include their children.
	for name in asms:
		asms[name]["mass_kg"] = _subtree_kg(name, asms, kg)
	var moving := {}
	var mv: Dictionary = meta.get("moving", {})
	for ax in ["x", "y", "z"]:
		moving[ax] = float(asms[mv[ax]]["mass_kg"]) if mv.has(ax) and asms.has(mv[ax]) else 0.0
	var loops: Array = res["loops"]
	var links: Array = []
	for lk in doc.get("links", []):
		var l: Dictionary = lk
		var ea: Dictionary = l["a"]
		var eb: Dictionary = l["b"]
		if not res["parts"].has(str(ea["part"])) or not res["parts"].has(str(eb["part"])):
			continue
		var wa: Transform3D = res["parts"][str(ea["part"])]["world"]
		var wb: Transform3D = res["parts"][str(eb["part"])]["world"]
		links.append({"kind": str(l["kind"]), "a": {"asm": str(res["parts"][str(ea["part"])]["asm"]), "c": wa * (ea.get("at", Vector3.ZERO) as Vector3)},
			"b": {"asm": str(res["parts"][str(eb["part"])]["asm"]), "c": wb * (eb.get("at", Vector3.ZERO) as Vector3)},
			"ta": wa.basis * (l.get("ta", Vector3.DOWN) as Vector3), "tb": wb.basis * (l.get("tb", Vector3.UP) as Vector3), "r": float(l.get("r", 0.002))})
	var dims := (hi - lo) if lo.x < INF else Vector3(0.5, 0.5, 0.5)
	var bed: Dictionary = meta.get("bed", {"size": Vector2(0.22, 0.22), "kind": "heated_pcb"})
	var lay := {
		"kinematics": str(spec["kinematics"]), "dims": dims,
		"origin": origin, "static": {"beams": st_beams, "parts": st_parts},
		"assemblies": asms, "bed": bed, "screws": screws, "loops": loops, "links": links,
		"moving_kg": moving, "spans": meta.get("spans", {}), "anchors": meta.get("anchors", {}),
		"bead_parent": str(meta.get("bead_parent", "")), "bead_origin": meta.get("bead_origin", origin),
		"assembly": res, "issues": res["issues"],
	}
	if (meta.get("bead_origin_from_tool", false) as bool):
		lay["bead_origin"] = origin + (meta.get("bead_offset", Vector3.ZERO) as Vector3)
	return lay


static func _subtree_kg(name: String, asms: Dictionary, kg: Dictionary) -> float:
	var t := float(kg.get(name, 0.0))
	for other in asms:
		if str(asms[other]["parent"]) == name:
			t += _subtree_kg(str(other), asms, kg)
	return t


static func _aabb_of(obbs: Array) -> AABB:
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for ob in obbs:
		var o: Dictionary = ob
		var xf: Transform3D = o["xf"]
		var hs: Vector3 = (o["s"] as Vector3) * 0.5
		for i in 8:
			var c := xf * Vector3(hs.x * (1 if i & 1 else -1), hs.y * (1 if i & 2 else -1), hs.z * (1 if i & 4 else -1))
			lo = lo.min(c)
			hi = hi.max(c)
	if lo.x == INF:
		return AABB()
	return AABB(lo, hi - lo)


# ---------------------------------------------------------------------------
# Editing (the spec's sparse edit layer)
# ---------------------------------------------------------------------------

static func _edits_mut(spec: Dictionary) -> Dictionary:
	var e: Variant = spec.get("assembly", {})
	if not (e is Dictionary):
		e = {}
	var d: Dictionary = e
	if not d.has("over"):
		d["over"] = {}
	if not d.has("added"):
		d["added"] = []
	if not d.has("unlinked"):
		d["unlinked"] = []
	spec["assembly"] = d
	return d


## Set a part's mate fields (and params / ref): on an added part directly,
## on a generated one as an override.
static func set_part(spec: Dictionary, id: String, patch: Dictionary) -> void:
	var ed := _edits_mut(spec)
	for ap in ed["added"]:
		var a: Dictionary = ap
		if str(a["id"]) == id:
			for k in patch:
				if k == "mate" or k == "params":
					var m: Dictionary = (a.get(k, {}) as Dictionary).duplicate()
					for kk in patch[k]:
						m[kk] = patch[k][kk]
					a[k] = m
				else:
					a[k] = patch[k]
			return
	var o: Dictionary = (ed["over"].get(id, {}) as Dictionary).duplicate(true)
	for k in patch:
		if k == "mate" or k == "params":
			var m: Dictionary = (o.get(k, {}) as Dictionary).duplicate()
			for kk in patch[k]:
				m[kk] = patch[k][kk]
			o[k] = m
		else:
			o[k] = patch[k]
	ed["over"][id] = o


static func add_part(spec: Dictionary, part: Dictionary) -> String:
	var ed := _edits_mut(spec)
	var n := 1
	var ids := {}
	for ap in ed["added"]:
		ids[str((ap as Dictionary)["id"])] = true
	while ids.has("u%d" % n):
		n += 1
	var p := part.duplicate(true)
	p["id"] = "u%d" % n
	ed["added"].append(p)
	return str(p["id"])


static func remove_part(spec: Dictionary, id: String) -> void:
	var ed := _edits_mut(spec)
	var keep: Array = []
	var was_added := false
	for ap in ed["added"]:
		if str((ap as Dictionary)["id"]) == id:
			was_added = true
		else:
			keep.append(ap)
	ed["added"] = keep
	if not was_added:
		var o: Dictionary = (ed["over"].get(id, {}) as Dictionary).duplicate()
		o["removed"] = true
		ed["over"][id] = o
	# Added parts mated to it go too.
	var changed := true
	while changed:
		changed = false
		var keep2: Array = []
		for ap in ed["added"]:
			var to := str(((ap as Dictionary).get("mate", {}) as Dictionary).get("to", ""))
			if to == id:
				changed = true
				remove_part(spec, str((ap as Dictionary)["id"]))
				return
			keep2.append(ap)
		ed["added"] = keep2


static func unlink(spec: Dictionary, id: String) -> void:
	var ed := _edits_mut(spec)
	if not (ed["unlinked"] as Array).has(id):
		ed["unlinked"].append(id)


static func has_edits(spec: Dictionary) -> bool:
	var ed := edits_of(spec)
	return not (ed["over"] as Dictionary).is_empty() or not (ed["added"] as Array).is_empty() or not (ed["unlinked"] as Array).is_empty()


## The twin's mate that mirrors `a` (after `a` moved): mirror a's world pose
## across x = mirror_x, then find the twin's turn whose boxes best overlay
## the mirrored boxes, and its slide / offset by the inverse placement.
static func mirror_mate(res: Dictionary, a_id: String, b_id: String) -> Dictionary:
	if not res["parts"].has(a_id) or not res["parts"].has(b_id):
		return {}
	var pa: Dictionary = res["parts"][a_id]["part"]
	var pb: Dictionary = res["parts"][b_id]["part"]
	var mb: Dictionary = pb.get("mate", {})
	if mb.is_empty():
		return {}
	var to := str(mb.get("to", ""))
	if not res["parts"].has(to):
		return {}
	var mx := float((res["doc"].get("meta", {}) as Dictionary).get("mirror_x", 0.0))
	var flip := Transform3D(Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3.BACK), Vector3(2.0 * mx, 0, 0))
	var wa: Transform3D = res["parts"][a_id]["world"]
	var wt: Transform3D = res["parts"][to]["world"]
	var tf := feature_of(res["parts"][to]["part"], str(mb.get("tf", "")))
	var cf := feature_of(pb, str(mb.get("f", "")))
	var want_boxes: Array = []
	for b in _boxes_of(pa):
		var bd: Dictionary = b
		want_boxes.append(flip * (wa * (bd["c"] as Vector3)))
	# The mirrored feature origin gives the slide and offset.
	var cfa := feature_of(pa, str((pa.get("mate", {}) as Dictionary).get("f", "")))
	var fa: Transform3D = wa * ((cfa.get("xf", Transform3D.IDENTITY)) as Transform3D)
	var want_o: Vector3 = flip * fa.origin
	var local: Vector3 = ((wt * (tf["xf"] as Transform3D)).affine_inverse()) * want_o
	var best := {}
	var best_err := INF
	for t in 4:
		var wish := mb.duplicate()
		wish["turn"] = t
		if GantryLabMates.slides_along_y(GantryLabMates.mate_type(cf, tf)):
			wish["s"] = GantryLabMates.rel_s(tf, str(mb.get("anchor", "start")), local.y)
		else:
			wish["s"] = GantryLabMates.rel_s(tf, str(mb.get("anchor", "start")), local.x)
			wish["lat"] = local.z
			wish["h"] = maxf(0.0, local.y) if wish.has("h") or float(mb.get("h", 0.0)) > 0.0 else 0.0
		var sn := GantryLabMates.snap(tf, cf, wish, 0.0)
		if sn.is_empty() or int(sn.get("turn", -1)) != t:
			continue
		var wb := GantryLabMates.place(wt, tf, cf, sn)
		var err := 0.0
		var bxs := _boxes_of(pb)
		for i in mini(bxs.size(), want_boxes.size()):
			err += (wb * ((bxs[i] as Dictionary)["c"] as Vector3)).distance_to(want_boxes[i])
		if err < best_err:
			best_err = err
			best = sn
	return best


# ---------------------------------------------------------------------------
# The editor's queries: where would a part go under the pointer, where does
# a dragged part slide to.
# ---------------------------------------------------------------------------

const TARGET_KINDS := ["face", "grid", "holes", "axis", "end"]


static func _shifted(res: Dictionary, offs: Dictionary, id: String) -> Transform3D:
	var rp: Dictionary = res["parts"][id]
	var w: Transform3D = rp["world"]
	return Transform3D(w.basis, w.origin + (offs.get(str(rp["asm"]), Vector3.ZERO) as Vector3))


## The parts mated (directly or through others) to `id`, and `id` itself.
static func subtree(res: Dictionary, id: String) -> Dictionary:
	var out := {id: true}
	var changed := true
	while changed:
		changed = false
		for pid in res["parts"]:
			if out.has(pid):
				continue
			var to := str(((res["parts"][pid]["part"] as Dictionary).get("mate", {}) as Dictionary).get("to", ""))
			if out.has(to):
				out[pid] = true
				changed = true
	return out


## The best spot for part (ref, params) under a ray in machine space:
## {to, tf, f, mate, world (zero pose), asm, t, why} or {}.
static func candidate(res: Dictionary, offs: Dictionary, ref: String, params: Dictionary, ray_o: Vector3, ray_d: Vector3,
		exclude: Dictionary = {}, wish_turn: int = 0, step: float = 0.001, only_f: String = "") -> Dictionary:
	var rd := ray_d.normalized()
	var child_feats: Array = []
	for f in GantryLabCatalog.features(ref, params):
		var fd: Dictionary = f
		if bool(fd.get("target", false)) or str(fd["kind"]) == "point":
			continue
		if not only_f.is_empty() and str(fd["id"]) != only_f:
			continue
		child_feats.append(fd)
	var best := {}
	var best_t := INF
	for pid in res["parts"]:
		if exclude.has(pid):
			continue
		var tp: Dictionary = res["parts"][pid]["part"]
		if bool(tp.get("free", false)):
			continue
		var wsh := _shifted(res, offs, str(pid))
		for tfv in GantryLabCatalog.features(str(tp["ref"]), tp.get("params", {})):
			var tf: Dictionary = tfv
			if not TARGET_KINDS.has(str(tf["kind"])):
				continue
			if str(tf["kind"]) == "holes" and not bool(tf.get("target", false)):
				continue
			var fw: Transform3D = wsh * (tf["xf"] as Transform3D)
			for cfv in child_feats:
				var cf: Dictionary = cfv
				var kind := GantryLabMates.mate_type(cf, tf)
				if kind.is_empty():
					continue
				var t := INF
				var wish := {"to": str(pid), "tf": str(tf["id"]), "f": str(cf["id"]), "turn": wish_turn, "anchor": "start", "h": 0.0}
				if kind == "run":
					wish["h"] = float(cf.get("gap", 0.0011))
				if str(tf["kind"]) == "axis":
					var ax := fw.basis.y.normalized()
					var sp := LightGizmoMath.axis_param(ray_o, rd, fw.origin, ax)
					if is_nan(sp):
						continue
					sp = clampf(sp, 0.0, maxf(float(tf.get("len", 0.0)), 0.0))
					var pt := fw.origin + ax * sp
					var tt := (pt - ray_o).dot(rd)
					if tt <= 0.0:
						continue
					if (ray_o + rd * tt).distance_to(pt) > 0.02:
						continue
					wish["s"] = sp
					t = tt
				else:
					var n := fw.basis.y.normalized()
					var den := rd.dot(n)
					# A face must face the pointer; a bolt pattern (a motor's
					# square on its mount) is found from either side.
					if den > -0.05 and not (str(tf["kind"]) == "holes" and absf(den) > 0.05):
						continue
					var tt2 := (fw.origin - ray_o).dot(n) / den
					if tt2 <= 0.0:
						continue
					var hit := ray_o + rd * tt2
					var local := fw.affine_inverse() * hit
					match str(tf["kind"]):
						"face":
							if local.x < -0.005 or local.x > float(tf.get("len", 0.0)) + 0.005 or absf(local.z) > float(tf.get("width", 0.02)) * 0.5 + 0.004:
								continue
						"grid":
							if not (tf.get("rect", Rect2()) as Rect2).grow(0.01).has_point(Vector2(local.x, local.z)):
								continue
						"holes", "end":
							if Vector2(local.x, local.z).length() > 0.05:
								continue
					wish["s"] = local.x
					wish["lat"] = local.z
					t = tt2
				var sn := GantryLabMates.snap(tf, cf, wish, step)
				if sn.is_empty():
					continue
				if t < best_t:
					best_t = t
					var wz: Transform3D = res["parts"][pid]["world"]
					best = {"to": str(pid), "tf": str(tf["id"]), "f": str(cf["id"]), "mate": sn, "world": GantryLabMates.place(wz, tf, cf, sn),
						"asm": str(res["parts"][pid]["asm"]), "t": t, "kind": kind}
	return best


## Slide a placed part along its own mate to the point under a ray:
## {mate, off (how far the ray passes from the slide, metres)} or {}.
static func slide(res: Dictionary, offs: Dictionary, id: String, ray_o: Vector3, ray_d: Vector3, step: float = 0.001) -> Dictionary:
	if not res["parts"].has(id):
		return {}
	var p: Dictionary = res["parts"][id]["part"]
	var m: Dictionary = p.get("mate", {})
	var to := str(m.get("to", ""))
	if m.is_empty() or not res["parts"].has(to):
		return {}
	var tf := feature_of(res["parts"][to]["part"], str(m.get("tf", "")))
	var cf := feature_of(p, str(m.get("f", "")))
	var kind := GantryLabMates.mate_type(cf, tf)
	if kind.is_empty() or kind == "pattern":
		return {}
	var fw: Transform3D = _shifted(res, offs, to) * (tf["xf"] as Transform3D)
	var rd := ray_d.normalized()
	var wish := m.duplicate()
	var off := 0.0
	if GantryLabMates.slides_along_y(kind):
		var ax := fw.basis.y.normalized()
		var sp := LightGizmoMath.axis_param(ray_o, rd, fw.origin, ax)
		if is_nan(sp):
			return {}
		var pt := fw.origin + ax * sp
		off = (ray_o + rd * maxf((pt - ray_o).dot(rd), 0.0)).distance_to(pt)
		wish["s"] = GantryLabMates.rel_s(tf, str(m.get("anchor", "start")), sp)
	else:
		var n := fw.basis.y.normalized()
		var den := rd.dot(n)
		var ax2 := fw.basis.x.normalized()
		var sp2 := LightGizmoMath.axis_param(ray_o, rd, fw.origin + fw.basis.z * float(m.get("lat", 0.0)), ax2)
		if is_nan(sp2):
			return {}
		var pt2 := fw.origin + fw.basis.z * float(m.get("lat", 0.0)) + ax2 * sp2
		off = (ray_o + rd * maxf((pt2 - ray_o).dot(rd), 0.0)).distance_to(pt2)
		# Keep the grab point under the pointer: slide by the feature's
		# offset, not its origin.
		wish["s"] = GantryLabMates.rel_s(tf, str(m.get("anchor", "start")), sp2)
		if str(tf["kind"]) == "grid" and absf(den) > 0.05:
			var tt := (fw.origin - ray_o).dot(n) / den
			var local := fw.affine_inverse() * (ray_o + rd * tt)
			wish["s"] = local.x
			wish["lat"] = local.z
			off = 0.0
	var sn := GantryLabMates.snap(tf, cf, wish, step)
	if sn.is_empty():
		return {}
	return {"mate": sn, "off": off}


# ---------------------------------------------------------------------------
# Modules: groups of parts the editor selects, opens and moves as one
# ---------------------------------------------------------------------------

## The resolved doc's modules, by id, with parts the build dropped removed.
static func modules_of(res: Dictionary) -> Dictionary:
	if res.is_empty():
		return {}
	var doc: Dictionary = res["doc"]
	if doc.has("_mods"):
		return doc["_mods"]
	var out := {}
	for mv in doc.get("modules", []):
		var m: Dictionary = (mv as Dictionary).duplicate(true)
		var keep: Array = []
		for pid in m["parts"]:
			if res["parts"].has(str(pid)):
				keep.append(str(pid))
		m["parts"] = keep
		m["parent"] = ""
		out[str(m["id"])] = m
	for id in out:
		for k in out[id]["kids"]:
			if out.has(str(k)):
				out[str(k)]["parent"] = str(id)
	doc["_mods"] = out
	return out


## Every part in a module, through its sub-modules.
static func module_parts(res: Dictionary, mid: String) -> Array:
	var mods := modules_of(res)
	if not mods.has(mid):
		return []
	var out: Array = (mods[mid]["parts"] as Array).duplicate()
	for k in mods[mid]["kids"]:
		out.append_array(module_parts(res, str(k)))
	return out


## The module directly inside `ctx` ("" = the machine) holding part `id`, or
## "" when the part sits in `ctx` on its own. `inside` is false when the part
## is not in `ctx` at all.
static func module_under(res: Dictionary, ctx: String, id: String) -> Dictionary:
	var mods := modules_of(res)
	if not ctx.is_empty() and not module_parts(res, ctx).has(id):
		return {"mod": "", "inside": false}
	var kids: Array = []
	if ctx.is_empty():
		for mid in mods:
			if str(mods[mid]["parent"]).is_empty():
				kids.append(mid)
	else:
		kids = mods[ctx]["kids"]
	for k in kids:
		if module_parts(res, str(k)).has(id):
			return {"mod": str(k), "inside": true}
	return {"mod": "", "inside": true}


static func _mark_subtree(res: Dictionary, id: String, moving: Dictionary) -> void:
	for pid in subtree(res, id):
		moving[pid] = true


## Move a group of parts rigidly by `delta` (world, the zero pose): every part
## whose parent is not moving with it is mated again where the move puts it,
## the rest follow their parents. {ok, why, patches {id: mate fields}}. Fails
## when a part cannot land on its own mate there (a nut on a fixed pattern,
## a bracket off the end of its beam) or a screw would leave its nut.
static func move_group(res: Dictionary, ids: Array, delta: Vector3) -> Dictionary:
	var members := {}
	for i in ids:
		if res["parts"].has(str(i)):
			members[str(i)] = true
	var moving := {}
	var patches := {}
	if delta.length() < 1e-7:
		return {"ok": true, "why": "", "patches": {}}
	for id in res["order"]:
		if not members.has(id) or moving.has(id):
			continue
		var p: Dictionary = res["parts"][id]["part"]
		var m: Dictionary = p.get("mate", {})
		var to := str(m.get("to", ""))
		if m.is_empty() or to.is_empty() or not res["parts"].has(to):
			return {"ok": false, "why": "the %s is fixed in place" % label_of(p).to_lower(), "patches": {}}
		if moving.has(to):
			_mark_subtree(res, id, moving)
			continue
		var tf := feature_of(res["parts"][to]["part"], str(m.get("tf", "")))
		var cf := feature_of(p, str(m.get("f", "")))
		var kind := GantryLabMates.mate_type(cf, tf)
		var w: Transform3D = res["parts"][id]["world"]
		var want := Transform3D(w.basis, w.origin + delta)
		var wt: Transform3D = res["parts"][to]["world"]
		var inf := GantryLabMates.infer(wt, tf, cf, want)
		var nm := m.duplicate()
		var anchor := str(m.get("anchor", "start"))
		nm["s"] = GantryLabMates.rel_s(tf, anchor, float(inf["s"]))
		if not GantryLabMates.slides_along_y(kind):
			nm["lat"] = float(inf["lat"])
		var sn := GantryLabMates.snap(tf, cf, nm, 0.0)
		var why := "the %s cannot follow: it would leave the %s" % [label_of(p).to_lower(), label_of(res["parts"][to]["part"]).to_lower()]
		if sn.is_empty():
			return {"ok": false, "why": why, "patches": {}}
		var got := GantryLabMates.place(wt, tf, cf, sn)
		if got.origin.distance_to(want.origin) > 0.0012 or not bool(GantryLabMates.fits(tf, cf, sn)["ok"]):
			return {"ok": false, "why": why, "patches": {}}
		var keep := {}
		for k in ["s", "lat", "turn", "anchor"]:
			if sn.has(k):
				keep[k] = sn[k]
		patches[id] = keep
		_mark_subtree(res, id, moving)
	for cx in res["doc"].get("coax", []):
		var a := str(cx[0])
		var b := str(cx[1])
		if not res["parts"].has(a) or not res["parts"].has(b) or moving.has(a) == moving.has(b):
			continue
		# One side moving is fine along the shared axis (a nut riding its screw).
		var ax := ((res["parts"][a]["world"] as Transform3D).basis.y).normalized()
		if (delta - ax * delta.dot(ax)).length() > 0.0005:
			return {"ok": false, "why": "the %s would leave the %s's axis — move them together" % [label_of(res["parts"][a]["part"]).to_lower(), label_of(res["parts"][b]["part"]).to_lower()], "patches": {}}
	return {"ok": true, "why": "", "patches": patches}


## Drag a module: slide its anchor along the anchor's own mate to the point
## under the ray, move the whole module by what that moved it, and its twin
## module mirrored. {ok, why, patches, delta}.
static func drag_module(res: Dictionary, offs: Dictionary, mid: String, ray_o: Vector3, ray_d: Vector3, step: float = 0.001) -> Dictionary:
	var mods := modules_of(res)
	if not mods.has(mid):
		return {"ok": false, "why": "no such module", "patches": {}}
	var anchor := str(mods[mid].get("anchor", ""))
	if anchor.is_empty() or not res["parts"].has(anchor):
		return {"ok": false, "why": "the %s does not move as a whole — open it to move its parts" % str(mods[mid]["label"]).to_lower(), "patches": {}}
	var sl := slide(res, offs, anchor, ray_o, ray_d, step)
	if sl.is_empty():
		return {"ok": false, "why": "the %s is bolted where it cannot slide" % label_of(res["parts"][anchor]["part"]).to_lower(), "patches": {}}
	var p: Dictionary = res["parts"][anchor]["part"]
	var m: Dictionary = p["mate"]
	var to := str(m["to"])
	var tf := feature_of(res["parts"][to]["part"], str(m.get("tf", "")))
	var cf := feature_of(p, str(m.get("f", "")))
	var nm: Dictionary = m.duplicate()
	for k in sl["mate"]:
		nm[k] = sl["mate"][k]
	var w2 := GantryLabMates.place(res["parts"][to]["world"], tf, cf, nm)
	var w1: Transform3D = res["parts"][anchor]["world"]
	if not w2.basis.is_equal_approx(w1.basis):
		return {"ok": false, "why": "", "patches": {}}
	var delta := w2.origin - w1.origin
	var r := move_group(res, module_parts(res, mid), delta)
	if not bool(r["ok"]):
		return r
	var tw := str(mods[mid].get("twin", ""))
	if not tw.is_empty() and mods.has(tw):
		var r2 := move_group(res, module_parts(res, tw), Vector3(-delta.x, delta.y, delta.z))
		if not bool(r2["ok"]):
			return {"ok": false, "why": "the mirrored side: " + str(r2["why"]), "patches": {}}
		for k in r2["patches"]:
			r["patches"][k] = r2["patches"][k]
	r["delta"] = delta
	return r


## Apply a group move's patches to the spec (no twin mirroring: the group
## move already moved the twin side).
static func apply_patches(spec: Dictionary, patches: Dictionary) -> void:
	for id in patches:
		set_part(spec, str(id), {"mate": patches[id]})


## How many of each fastener a part's mates add (its card).
static func fasteners_of(res: Dictionary, id: String) -> Dictionary:
	var out := {}
	for fz in res["fasteners"]:
		var fd: Dictionary = fz
		if str(fd.get("owner", "")) != id:
			continue
		var lbl := str(fd.get("label", fd["kind"]))
		out[lbl] = int(out.get(lbl, 0)) + int(fd.get("count", 1))
	return out


## Edit a part and follow the edit on its mirrored twin (unless unlinked):
## the twin swaps to the same part, and its mate is solved from the
## mirror image of the edited part's new pose. Returns the twin's id or "".
static func edit_part(spec: Dictionary, id: String, patch: Dictionary) -> String:
	var before := resolve(build(spec))
	set_part(spec, id, patch)
	if not before["parts"].has(id):
		return ""
	var tw := str((before["parts"][id]["part"] as Dictionary).get("twin", ""))
	if tw.is_empty() or not before["parts"].has(tw):
		return ""
	var tpatch := {}
	if patch.has("ref"):
		tpatch["ref"] = patch["ref"]
	if patch.has("params"):
		tpatch["params"] = patch["params"]
	if not tpatch.is_empty():
		set_part(spec, tw, tpatch)
	if not patch.has("mate"):
		return tw
	var mp: Dictionary = patch["mate"]
	var old_to := str((before["parts"][id]["part"].get("mate", {}) as Dictionary).get("to", ""))
	if mp.has("to") and str(mp["to"]) != old_to:
		var new_to := str(mp["to"])
		var mirror_to := new_to
		if before["parts"].has(new_to):
			var t2 := str((before["parts"][new_to]["part"] as Dictionary).get("twin", ""))
			if not t2.is_empty():
				mirror_to = t2
		set_part(spec, tw, {"mate": {"to": mirror_to, "tf": mirror_feature(before, new_to, str(mp.get("tf", "")), mirror_to), "f": str(mp.get("f", ""))}})
	var after := resolve(build(spec))
	var mm := mirror_mate(after, id, tw)
	if not mm.is_empty():
		var keep := {}
		for k in ["s", "lat", "h", "turn", "anchor"]:
			if mm.has(k):
				keep[k] = mm[k]
		set_part(spec, tw, {"mate": keep})
	return tw


## The feature on `to_part` that mirrors `tf_id` on `from_part`: the same
## kind, its normal closest to the mirror image of the original's.
static func mirror_feature(res: Dictionary, from_part: String, tf_id: String, to_part: String) -> String:
	if not res["parts"].has(from_part) or not res["parts"].has(to_part):
		return tf_id
	var tp: Dictionary = res["parts"][from_part]["part"]
	var tfa := feature_of(tp, tf_id)
	if tfa.is_empty():
		return tf_id
	var wn: Vector3 = ((res["parts"][from_part]["world"] as Transform3D).basis * (tfa["xf"] as Transform3D).basis.y).normalized()
	wn.x = -wn.x
	var mtp: Dictionary = res["parts"][to_part]["part"]
	var best_f := tf_id
	var best_d := -INF
	for fv in GantryLabCatalog.features(str(mtp["ref"]), mtp.get("params", {})):
		var fd: Dictionary = fv
		if str(fd["kind"]) != str(tfa["kind"]) or str(fd["cls"]) != str(tfa["cls"]):
			continue
		var n2: Vector3 = ((res["parts"][to_part]["world"] as Transform3D).basis * (fd["xf"] as Transform3D).basis.y).normalized()
		if n2.dot(wn) > best_d:
			best_d = n2.dot(wn)
			best_f = str(fd["id"])
	return best_f


## Add the mirror image of an added part, linked to it. Returns its id.
static func add_twin(spec: Dictionary, id: String) -> String:
	var r2 := resolve(build(spec))
	if not r2["parts"].has(id):
		return ""
	var p: Dictionary = r2["parts"][id]["part"]
	var mt: Dictionary = p.get("mate", {})
	if mt.is_empty():
		return ""
	var to := str(mt["to"])
	var tw_to := str((r2["parts"][to]["part"] as Dictionary).get("twin", ""))
	if tw_to.is_empty():
		tw_to = to
	var tmate := mt.duplicate()
	tmate["to"] = tw_to
	tmate["tf"] = mirror_feature(r2, to, str(mt["tf"]), tw_to)
	var tid := add_part(spec, {"ref": str(p["ref"]), "params": (p.get("params", {}) as Dictionary).duplicate(true), "mate": tmate, "twin": id})
	set_part(spec, id, {"twin": tid})
	var r3 := resolve(build(spec))
	var mm := mirror_mate(r3, id, tid)
	if not mm.is_empty():
		var keep := {}
		for k in ["s", "lat", "h", "turn", "anchor"]:
			if mm.has(k):
				keep[k] = mm[k]
		set_part(spec, tid, {"mate": keep})
	return tid

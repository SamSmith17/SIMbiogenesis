class_name TcAssembly
extends RefCounted

## Parts + joints → where everything is (mm), pure.
##
## A TC mate puts the two gasket faces together, port axes opposed, with a
## gasket gap between and one free number, the roll about the shared axis:
##   child port frame = parent port frame · T(0, 0, gap) · Rx(180°) · Rz(roll)
## The relation is symmetric (the same formula holds walking the joint the
## other way with the same roll), so joints are undirected.
##
## Each connected group is walked breadth-first from its ROOT (the first part
## in spec order carrying `xf`, else its first part at the origin). A joint
## met again between two parts already placed CLOSES a loop: its error (how
## far the two faces miss, in mm and degrees) is reported, never hidden. A
## spool with `fit` set solves its own length to close the loops it sits in
## (numerically: nudge, measure, step; a loop that needs a sideways move
## stays open and says so).

const FIT_ITER := 6
const FIT_TOL_MM := 0.05
const CLOSE_OK_MM := 1.0
const CLOSE_OK_DEG := 1.0
const CLASH_TOL_MM := 1.5


static func mate_frame(parent_port_world: Transform3D, gap: float, roll_deg: float) -> Transform3D:
	return parent_port_world * Transform3D(Basis.IDENTITY, Vector3(0, 0, gap)) \
		* Transform3D(Basis(Vector3.RIGHT, PI), Vector3.ZERO) \
		* Transform3D(Basis(Vector3.BACK, deg_to_rad(roll_deg)), Vector3.ZERO)


## Where a part goes so that its port `own` mates `target_world` (a port
## frame in assembly mm) with `roll`.
static func place_on(target_world: Transform3D, own_port: Dictionary, gap: float, roll_deg: float) -> Transform3D:
	return mate_frame(target_world, gap, roll_deg) * TcParts.port_xform(own_port).affine_inverse()


static func split_ref(ref: String) -> Array:
	return [ref.get_slice(":", 0), ref.get_slice(":", 1)]


## The solved assembly. `spec` must be resolved (TcSpec.resolve).
static func solve(spec: Dictionary) -> Dictionary:
	var parts: Array = spec.get("parts", [])
	var fit_ids: Array = []
	for p in parts:
		if str(p["type"]) == "spool" and bool((p["params"] as Dictionary).get("fit", false)):
			fit_ids.append(str(p["id"]))
	var lengths := {}
	var res := _solve_raw(spec, lengths)
	if fit_ids.is_empty() or (res["closing"] as Array).is_empty():
		res["fit"] = {}
		return res
	for p in parts:
		if str(p["id"]) in fit_ids:
			lengths[str(p["id"])] = float(p["params"]["length_mm"])
	for _it in FIT_ITER:
		var e0 := _err_vec(res)
		if _norm(e0) < FIT_TOL_MM:
			break
		var moved := false
		for sid in fit_ids:
			if not _in_closing_comp(res, sid):
				continue
			var trial := lengths.duplicate()
			trial[sid] = float(lengths[sid]) + 5.0
			var e1 := _err_vec(_solve_raw(spec, trial))
			if e1.size() != e0.size():
				continue
			var dd := 0.0
			var de := 0.0
			for i in e0.size():
				var d := (e1[i] - e0[i]) / 5.0
				dd += d * d
				de += d * e0[i]
			if dd < 1e-6:
				continue
			var step := -de / dd
			var hub2 := 2.0 * float(TcStandards.ferrule(str(TcSpec.part_of(spec, sid)["size"]))["hub"])
			lengths[sid] = clampf(float(lengths[sid]) + step, hub2, 6000.0)
			moved = true
			res = _solve_raw(spec, lengths)
			e0 = _err_vec(res)
		if not moved:
			break
	res["fit"] = lengths
	return res


static func _in_closing_comp(res: Dictionary, pid: String) -> bool:
	var comp := int((res["parts"][pid] as Dictionary).get("comp", -1)) if (res["parts"] as Dictionary).has(pid) else -1
	for ci in res["closing"]:
		var j: Dictionary = res["joints"][ci]
		if int(j.get("comp", -2)) == comp:
			return true
	return false


static func _err_vec(res: Dictionary) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for ci in res["closing"]:
		var v: Vector3 = (res["joints"][ci] as Dictionary).get("err_vec", Vector3.ZERO)
		out.append(v.x)
		out.append(v.y)
		out.append(v.z)
	return out


static func _norm(a: PackedFloat64Array) -> float:
	var s := 0.0
	for x in a:
		s += x * x
	return sqrt(s)


static func _solve_raw(spec: Dictionary, lengths: Dictionary) -> Dictionary:
	var parts: Array = spec.get("parts", [])
	var built := {}
	var order: Array = []
	for p in parts:
		var id := str(p["id"])
		var params: Dictionary = p["params"]
		if lengths.has(id):
			params = params.duplicate()
			params["length_mm"] = float(lengths[id])
		built[id] = TcParts.build(str(p["type"]), str(p["size"]), params)
		order.append(id)
	var port_of := func(ref: String) -> Dictionary:
		var s := split_ref(ref)
		if not built.has(s[0]):
			return {}
		for q in (built[s[0]] as Dictionary)["ports"]:
			if str(q["id"]) == s[1]:
				return q
		return {}
	var joints: Array = []
	var adj := {}
	for id in order:
		adj[id] = []
	var ji := 0
	for j in spec.get("joints", []):
		var pa: Dictionary = port_of.call(str(j["a"]))
		var pb: Dictionary = port_of.call(str(j["b"]))
		if pa.is_empty() or pb.is_empty():
			continue
		var m := TcParts.can_mate(pa, pb)
		var jd := {"a": str(j["a"]), "b": str(j["b"]), "roll_deg": float(j.get("roll_deg", 0.0)),
			"gasket": str(j.get("gasket", "epdm")), "clamp": str(j.get("clamp", "single_pin")),
			"ok": bool(m["ok"]), "why": str(m["why"]), "gap": TcParts.joint_gap(pa, pb),
			"kind": str(pa["kind"]), "size": str(pa["size"]), "closing": false, "err_mm": 0.0, "err_deg": 0.0,
			"index": ji}
		joints.append(jd)
		var sa := split_ref(str(j["a"]))
		var sb := split_ref(str(j["b"]))
		(adj[sa[0]] as Array).append(ji)
		(adj[sb[0]] as Array).append(ji)
		ji += 1
	var pout := {}
	var comps: Array = []
	var closing: Array = []
	var parent_joint := {}
	var placed := {}
	var used_joint := {}
	# Roots first: a part with xf, in spec order, starts its group.
	var seeds: Array = []
	for p in parts:
		if p.has("xf"):
			seeds.append(str(p["id"]))
	for id in order:
		if not id in seeds:
			seeds.append(id)
	for seed in seeds:
		if placed.has(seed):
			continue
		var comp := comps.size()
		var members: Array = [seed]
		var sp := TcSpec.part_of(spec, seed)
		var root_xf := TcSpec.xf_from_array(sp["xf"]) if sp.has("xf") else Transform3D.IDENTITY
		placed[seed] = root_xf
		pout[seed] = {"xf": root_xf, "built": built[seed], "comp": comp, "root": true}
		var queue: Array = [seed]
		while not queue.is_empty():
			var cur: String = queue.pop_front()
			for jidx in adj[cur]:
				if used_joint.has(jidx):
					continue
				used_joint[jidx] = true
				var jd: Dictionary = joints[jidx]
				jd["comp"] = comp
				var sa := split_ref(str(jd["a"]))
				var sb := split_ref(str(jd["b"]))
				var here: Array = sa if sa[0] == cur else sb
				var there: Array = sb if sa[0] == cur else sa
				var p_here: Dictionary = port_of.call("%s:%s" % here)
				var p_there: Dictionary = port_of.call("%s:%s" % there)
				var f_here: Transform3D = (placed[cur] as Transform3D) * TcParts.port_xform(p_here)
				var want := mate_frame(f_here, float(jd["gap"]), float(jd["roll_deg"]))
				var other: String = there[0]
				if placed.has(other):
					var actual: Transform3D = (placed[other] as Transform3D) * TcParts.port_xform(p_there)
					var ev := want.origin - actual.origin
					jd["closing"] = true
					jd["err_vec"] = ev
					jd["err_mm"] = ev.length()
					var q := (want.basis.orthonormalized().get_rotation_quaternion().inverse()
						* actual.basis.orthonormalized().get_rotation_quaternion())
					jd["err_deg"] = rad_to_deg(q.get_angle()) if q.get_angle() <= PI else 360.0 - rad_to_deg(q.get_angle())
					closing.append(jidx)
				else:
					var xf := want * TcParts.port_xform(p_there).affine_inverse()
					placed[other] = xf
					parent_joint[other] = jidx
					pout[other] = {"xf": xf, "built": built[other], "comp": comp, "root": false}
					members.append(other)
					queue.append(other)
		comps.append(members)
	# Joint hardware frames (gasket plane, +Z along the a side's port).
	for jd in joints:
		var sa := split_ref(str(jd["a"]))
		if not placed.has(sa[0]):
			continue
		var pa: Dictionary = port_of.call(str(jd["a"]))
		var fa: Transform3D = (placed[sa[0]] as Transform3D) * TcParts.port_xform(pa)
		jd["frame"] = fa * Transform3D(Basis.IDENTITY, Vector3(0, 0, float(jd["gap"]) * 0.5))
	# Open ports.
	var mated := {}
	for jd in joints:
		mated[str(jd["a"])] = true
		mated[str(jd["b"])] = true
	var open: Array = []
	for id in order:
		for q in (built[id] as Dictionary)["ports"]:
			var ref := "%s:%s" % [id, str(q["id"])]
			if mated.has(ref):
				continue
			open.append({"ref": ref, "part": id, "port": q,
				"xf": (placed[id] as Transform3D) * TcParts.port_xform(q)})
	return {"parts": pout, "joints": joints, "comps": comps, "closing": closing, "open": open,
		"parent_joint": parent_joint, "order": order}


## Pairs of parts that interpenetrate (capsule bodies closer than their
## radii), skipping parts mated directly. [[id_a, id_b, depth_mm]].
static func clashes(res: Dictionary) -> Array:
	var direct := {}
	for jd in res["joints"]:
		var a: String = split_ref(str(jd["a"]))[0]
		var b: String = split_ref(str(jd["b"]))[0]
		direct["%s|%s" % [a, b]] = true
		direct["%s|%s" % [b, a]] = true
	var caps := {}
	var boxes := {}
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var xf: Transform3D = pd["xf"]
		var list: Array = []
		var bb := AABB()
		var first := true
		for c in (pd["built"] as Dictionary)["capsules"]:
			var a: Vector3 = xf * (c[0] as Vector3)
			var b: Vector3 = xf * (c[1] as Vector3)
			var r := float(c[2])
			# Fittings end in flat faces: pull the capsule's ends in by its
			# radius so its round caps stay inside the part's length (a
			# raw capsule bulged a flange-radius past every face, and two
			# parts a valve apart "touched").
			var ln := a.distance_to(b)
			var k := minf(r, ln * 0.5)
			if ln > 1e-6:
				var dirc := (b - a) / ln
				a += dirc * k
				b -= dirc * k
			list.append([a, b, r])
			var cb := AABB(a.min(b) - Vector3.ONE * r, (a.max(b) - a.min(b)) + Vector3.ONE * 2.0 * r)
			bb = cb if first else bb.merge(cb)
			first = false
		caps[id] = list
		boxes[id] = bb
	var out: Array = []
	# Sweep and prune along x: only parts whose boxes overlap in x are tested
	# further (the all-pairs loop was 17 ms on a 200-part manifold).
	var ids: Array = []
	for id in res["order"]:
		if caps.has(id):
			ids.append(id)
	ids.sort_custom(func(p: String, q: String) -> bool: return (boxes[p] as AABB).position.x < (boxes[q] as AABB).position.x)
	for i in ids.size():
		var a: String = ids[i]
		var ba: AABB = boxes[a]
		var x_end := ba.end.x
		for k in range(i + 1, ids.size()):
			var b: String = ids[k]
			var bbx: AABB = boxes[b]
			if bbx.position.x > x_end:
				break
			if not ba.intersects(bbx) or direct.has("%s|%s" % [a, b]):
				continue
			var sa: Dictionary = (res["parts"][a]["built"] as Dictionary).get("solid", {})
			var sb: Dictionary = (res["parts"][b]["built"] as Dictionary).get("solid", {})
			if not sa.is_empty() or not sb.is_empty():
				# A vessel is a cylinder, not a capsule: a part clashes with it
				# only where its own axis runs inside the shell (a nozzle's
				# fittings stand outside it by construction).
				if not sa.is_empty() and not sb.is_empty():
					continue
				var vid := a if not sa.is_empty() else b
				var oid := b if vid == a else a
				var solid: Dictionary = sa if not sa.is_empty() else sb
				var inv: Transform3D = (res["parts"][vid]["xf"] as Transform3D).affine_inverse()
				var deep := 0.0
				for c in caps[oid]:
					for k2 in 9:
						var q: Vector3 = inv * (c[0] as Vector3).lerp(c[1], float(k2) / 8.0)
						if q.y > float(solid["y0"]) + 2.0 and q.y < float(solid["y1"]) - 2.0:
							deep = maxf(deep, float(solid["r"]) - 2.0 - Vector2(q.x, q.z).length())
				if deep > CLASH_TOL_MM:
					out.append([a, b, deep])
				continue
			var worst := 0.0
			for ca in caps[a]:
				for cb in caps[b]:
					var d := seg_seg_dist(ca[0], ca[1], cb[0], cb[1])
					var depth := float(ca[2]) + float(cb[2]) - d
					worst = maxf(worst, depth)
			if worst > CLASH_TOL_MM:
				out.append([a, b, worst])
	return out


## Closest distance between segments [p1,q1] and [p2,q2] (Ericson 5.1.9).
static func seg_seg_dist(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> float:
	var c := closest_seg_seg(p1, q1, p2, q2)
	return (c[0] as Vector3).distance_to(c[1])


static func closest_seg_seg(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Array:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var t := 0.0
	if a <= 1e-9 and e <= 1e-9:
		return [p1, p2, 0.0, 0.0]
	if a <= 1e-9:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)
		if e <= 1e-9:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var den := a * e - b * b
			s = clampf((b * f - c * e) / den, 0.0, 1.0) if den > 1e-9 else 0.0
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	return [p1 + d1 * s, p2 + d2 * t, s, t]


## What a ray (assembly mm) hits first: {kind "part" | "port" | "joint",
## id (part id / port ref / joint index), t}. Ports and joints beat the
## part body they sit on (within `bias` mm).
static func pick(res: Dictionary, o: Vector3, d: Vector3, bias: float = 25.0) -> Dictionary:
	var dir := d.normalized()
	var far := o + dir * 1.0e6
	var best := {}
	var best_t := INF
	for id in res["order"]:
		var pd: Dictionary = res["parts"].get(id, {})
		if pd.is_empty():
			continue
		var xf: Transform3D = pd["xf"]
		for c in (pd["built"] as Dictionary)["capsules"]:
			var t := _ray_capsule(o, far, xf * (c[0] as Vector3), xf * (c[1] as Vector3), float(c[2]))
			if t < best_t:
				best_t = t
				best = {"kind": "part", "id": id, "t": t}
	var small_t := INF
	var small := {}
	for op in res["open"]:
		var r := float(TcStandards.tube(str(op["port"]["size"]))["r_flange"]) if str(op["port"]["kind"]) == "tc" \
			else TcStandards.npt_od(str(op["port"]["size"])) * 0.6
		var t := _ray_sphere(o, dir, (op["xf"] as Transform3D).origin, maxf(r, 8.0))
		if t < small_t:
			small_t = t
			small = {"kind": "port", "id": str(op["ref"]), "t": t}
	for jd in res["joints"]:
		if not jd.has("frame"):
			continue
		var r := float(TcStandards.tube(str(jd["size"]))["r_flange"]) * 1.15 if str(jd["kind"]) == "tc" else 10.0
		var t := _ray_sphere(o, dir, (jd["frame"] as Transform3D).origin, r)
		if t < small_t:
			small_t = t
			small = {"kind": "joint", "id": int(jd["index"]), "t": t}
	if not small.is_empty() and small_t <= best_t + bias:
		return small
	return best


static func _ray_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc := o - c
	var b := oc.dot(d)
	var cc := oc.dot(oc) - r * r
	var h := b * b - cc
	if h < 0.0:
		return INF
	var t := -b - sqrt(h)
	if t < 0.0:
		t = -b + sqrt(h)
	return t if t >= 0.0 else INF


static func _ray_capsule(o: Vector3, far: Vector3, a: Vector3, b: Vector3, r: float) -> float:
	var c := closest_seg_seg(o, far, a, b)
	var dist := (c[0] as Vector3).distance_to(c[1])
	if dist > r:
		return INF
	var t := float(c[2]) * o.distance_to(far)
	return maxf(t - sqrt(maxf(r * r - dist * dist, 0.0)), 0.0)


# ---------------------------------------------------------------------------
# Edits (pure: each returns a new spec)
# ---------------------------------------------------------------------------

## After any edit: every group keeps exactly one root, placed where the last
## solve had it. `res` is the solve BEFORE the edit (or {}).
static func pin_roots(spec: Dictionary, res: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	var r := _solve_raw(s, {})
	for members in r["comps"]:
		var with_xf: Array = []
		for p in s["parts"]:
			if str(p["id"]) in members and p.has("xf"):
				with_xf.append(p)
		if with_xf.is_empty():
			var first := TcSpec.part_of(s, str(members[0]))
			var xf := Transform3D.IDENTITY
			if res.has("parts") and (res["parts"] as Dictionary).has(str(members[0])):
				xf = res["parts"][str(members[0])]["xf"]
			first["xf"] = TcSpec.xf_to_array(xf)
		else:
			for i in range(1, with_xf.size()):
				(with_xf[i] as Dictionary).erase("xf")
	return s


## Add a part. With `mate` = {target: "pid:port", own: port id, roll} it is
## jointed to the target; otherwise it stands at `xf`. Returns [spec, id].
static func add_part(spec: Dictionary, type: String, size: String, params: Dictionary,
		xf: Transform3D, mate: Dictionary = {}) -> Array:
	var s := spec.duplicate(true)
	var id := TcSpec.new_id(TcSpec.ids_of(s))
	var p := {"id": id, "type": type, "size": size, "params": TcParts.resolve_params(type, size, params)}
	if mate.is_empty():
		p["xf"] = TcSpec.xf_to_array(xf)
	(s["parts"] as Array).append(p)
	if not mate.is_empty():
		(s["joints"] as Array).append({"a": str(mate["target"]), "b": "%s:%s" % [id, str(mate["own"])],
			"roll_deg": float(mate.get("roll", 0.0)), "gasket": str(mate.get("gasket", "epdm")),
			"clamp": str(mate.get("clamp", "single_pin"))})
	return [s, id]


static func remove_part(spec: Dictionary, res: Dictionary, id: String) -> Dictionary:
	var s := spec.duplicate(true)
	var parts: Array = []
	for p in s["parts"]:
		if str(p["id"]) != id:
			parts.append(p)
	s["parts"] = parts
	var joints: Array = []
	for j in s["joints"]:
		if split_ref(str(j["a"]))[0] != id and split_ref(str(j["b"]))[0] != id:
			joints.append(j)
	s["joints"] = joints
	var labels: Dictionary = s.get("labels", {})
	for k in labels.keys():
		if str(k).begins_with(id + ":"):
			labels.erase(k)
	return pin_roots(s, res)


## Break the joint that holds `id` to the rest of its group (toward the
## root) and make `id` the root of what hangs off it, standing where it is.
static func detach(spec: Dictionary, res: Dictionary, id: String) -> Dictionary:
	var s := spec.duplicate(true)
	var pj: Dictionary = res.get("parent_joint", {})
	if pj.has(id):
		var jd: Dictionary = res["joints"][int(pj[id])]
		var joints: Array = []
		for j in s["joints"]:
			if not (str(j["a"]) == str(jd["a"]) and str(j["b"]) == str(jd["b"])):
				joints.append(j)
		s["joints"] = joints
	var p := TcSpec.part_of(s, id)
	if not p.is_empty() and (res["parts"] as Dictionary).has(id):
		p["xf"] = TcSpec.xf_to_array(res["parts"][id]["xf"])
	return pin_roots(s, res)


## The ids in `id`'s group.
static func group_of(res: Dictionary, id: String) -> Array:
	for members in res.get("comps", []):
		if id in members:
			return members
	return []


## Set a root's transform (moves its whole group).
static func set_root_xf(spec: Dictionary, id: String, xf: Transform3D) -> Dictionary:
	var s := spec.duplicate(true)
	var p := TcSpec.part_of(s, id)
	if not p.is_empty():
		p["xf"] = TcSpec.xf_to_array(xf)
	return s


## Joint a root part `id` (with its group) onto `target` (an open port of
## ANOTHER group): its own port `own`. The moving group loses its root so
## the target's group keeps its pose.
static func attach(spec: Dictionary, res: Dictionary, id: String, own: String, target: String, roll: float) -> Dictionary:
	var s := spec.duplicate(true)
	var moving := group_of(res, id)
	for p in s["parts"]:
		if str(p["id"]) in moving:
			p.erase("xf")
	(s["joints"] as Array).append({"a": target, "b": "%s:%s" % [id, own], "roll_deg": roll,
		"gasket": "epdm", "clamp": "single_pin"})
	return pin_roots(s, res)


## Patch one joint (by the a/b refs): roll_deg, gasket, clamp.
static func set_joint(spec: Dictionary, a: String, b: String, patch: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	for j in s["joints"]:
		if str(j["a"]) == a and str(j["b"]) == b:
			for k in patch:
				j[k] = patch[k]
	return s


## Patch one part (size, params); the joints stay (a size change that no
## longer mates is reported by the checks).
static func set_part(spec: Dictionary, id: String, patch: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	var p := TcSpec.part_of(s, id)
	if p.is_empty():
		return s
	if patch.has("size"):
		p["size"] = str(patch["size"])
	if patch.has("params"):
		var params: Dictionary = (p["params"] as Dictionary).duplicate()
		for k in patch["params"]:
			params[k] = patch["params"][k]
		p["params"] = TcParts.resolve_params(str(p["type"]), str(p["size"]), params)
	else:
		p["params"] = TcParts.resolve_params(str(p["type"]), str(p["size"]), p["params"])
	return s

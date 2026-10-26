class_name GantryLabGen
extends RefCounted

## The build-a-machine toolkit the generators use: add a root part, mate a
## part to a feature by a WISH (where its feature should land, which way its
## axes should point) and let GantryLabMates find the real spot, fasten a
## corner bracket into the inside corner of two beams, pair mirrored twins.
## Parts are placed as they are added, so each step can measure the last.


static func new_doc(kinematics: String) -> Dictionary:
	return {"kinematics": kinematics, "parts": [], "loops": [], "links": [], "coax": [], "assemblies": {}, "meta": {"mirror_x": 0.0},
		"issues": [], "_w": {}, "_p": {}}


## Drop the build-time indexes (the doc is then plain data).
static func finish(doc: Dictionary) -> Dictionary:
	doc.erase("_w")
	doc.erase("_p")
	return doc


static func world(doc: Dictionary, id: String) -> Transform3D:
	return doc["_w"].get(id, Transform3D.IDENTITY)


static func part(doc: Dictionary, id: String) -> Dictionary:
	return doc["_p"].get(id, {})


static func feat_world(doc: Dictionary, id: String, fid: String) -> Transform3D:
	var p := part(doc, id)
	var f := GantryLabAssembly.feature_of(p, fid)
	if f.is_empty():
		return world(doc, id)
	return world(doc, id) * (f["xf"] as Transform3D)


static func _add(doc: Dictionary, p: Dictionary, w: Transform3D) -> Dictionary:
	doc["parts"].append(p)
	doc["_p"][str(p["id"])] = p
	doc["_w"][str(p["id"])] = w
	return p


static func root(doc: Dictionary, id: String, ref: String, params: Dictionary, xf: Transform3D, extra: Dictionary = {}) -> Dictionary:
	var p := {"id": id, "ref": ref, "params": params, "xf": xf}
	for k in extra:
		p[k] = extra[k]
	return _add(doc, p, xf)


## A part drawn from detail dicts with no catalog entry (the PSU, the board…).
static func free_part(doc: Dictionary, id: String, label: String, xf: Transform3D, draw: Array, kg: float = 0.0, extra: Dictionary = {}) -> Dictionary:
	var p := {"id": id, "ref": "", "free": true, "label": label, "draw": draw, "kg": kg, "xf": xf, "fixed": true}
	for k in extra:
		p[k] = extra[k]
	return _add(doc, p, xf)


## Mate with explicit numbers (snapped; s stepping off).
static func mate(doc: Dictionary, id: String, ref: String, params: Dictionary, to: String, tf: String, f: String, wish: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var tp := part(doc, to)
	var tfd := GantryLabAssembly.feature_of(tp, tf)
	var cfd := GantryLabCatalog.feature(ref, params, f)
	var w := wish.duplicate()
	w["to"] = to
	w["tf"] = tf
	w["f"] = f
	if not w.has("anchor"):
		w["anchor"] = "start"
	var sn := GantryLabMates.snap(tfd, cfd, w, 0.0)
	if sn.is_empty():
		doc["issues"].append({"level": "error", "text": "build: %s cannot mate to %s.%s" % [id, to, tf], "parts": [id]})
		sn = w
	var p := {"id": id, "ref": ref, "params": params, "mate": sn}
	for k in extra:
		p[k] = extra[k]
	var wc := GantryLabMates.place(world(doc, to), tfd, cfd, sn)
	return _add(doc, p, wc)


## Mate so the child's feature origin lands nearest `at` (world) with its
## local axes as close as possible to `axes` ({local Vector3: world Vector3}).
## `over` sets mate fields outright (h, anchor, auto, motor, sign…).
static func mate_at(doc: Dictionary, id: String, ref: String, params: Dictionary, to: String, tf: String, f: String,
		at: Vector3, axes: Dictionary, over: Dictionary = {}, extra: Dictionary = {}) -> Dictionary:
	var tp := part(doc, to)
	var tfd := GantryLabAssembly.feature_of(tp, tf)
	var cfd := GantryLabCatalog.feature(ref, params, f)
	var fx: Transform3D = world(doc, to) * (tfd["xf"] as Transform3D)
	var local := fx.affine_inverse() * at
	var kind := GantryLabMates.mate_type(cfd, tfd)
	var best := {}
	var best_score := -INF
	for t in 4:
		var wish := {"to": to, "tf": tf, "f": f, "turn": t, "anchor": "start", "h": float(over.get("h", 0.0))}
		if GantryLabMates.slides_along_y(kind):
			wish["s"] = local.y
		else:
			wish["s"] = local.x
			wish["lat"] = local.z
		var sn := GantryLabMates.snap(tfd, cfd, wish, 0.0)
		if sn.is_empty():
			continue
		var wc := GantryLabMates.place(world(doc, to), tfd, cfd, sn)
		var score := 0.0
		for la in axes:
			score += (wc.basis * (la as Vector3)).normalized().dot((axes[la] as Vector3).normalized())
		# Prefer landing where asked.
		score -= (wc * (cfd["xf"] as Transform3D).origin).distance_to(at) * 4.0
		if score > best_score + 1e-6:
			best_score = score
			best = sn
	if best.is_empty():
		doc["issues"].append({"level": "error", "text": "build: %s finds no spot on %s.%s" % [id, to, tf], "parts": [id]})
		best = {"to": to, "tf": tf, "f": f, "s": local.x, "lat": local.z, "turn": 0, "anchor": "start"}
	for k in over:
		best[k] = over[k]
	if not over.has("anchor"):
		best = _auto_anchor(tfd, best)
	var p := {"id": id, "ref": ref, "params": params, "mate": best}
	for k in extra:
		p[k] = extra[k]
	var wc2 := GantryLabMates.place(world(doc, to), tfd, cfd, best)
	return _add(doc, p, wc2)


## Measure from the nearer end so a resize keeps the distance the part
## really keeps (a bracket 13 mm from the corner stays 13 mm from it).
static func _auto_anchor(tf: Dictionary, m: Dictionary) -> Dictionary:
	var L := GantryLabMates.length_of(tf)
	if L <= 0.0:
		return m
	var sa := GantryLabMates.abs_s(tf, m)
	var out := m.duplicate()
	if sa > L * 0.66:
		out["anchor"] = "end"
	elif sa > L * 0.34:
		out["anchor"] = "centre"
	else:
		out["anchor"] = "start"
	out["s"] = GantryLabMates.rel_s(tf, str(out["anchor"]), sa)
	return out


## A cast corner bracket in the inside corner of two beams: leg a on
## beam_a's face_a, leg b on beam_b's face_b, near `at`.
static func corner(doc: Dictionary, id: String, beam_a: String, face_a: String, beam_b: String, face_b: String, at: Vector3, extra: Dictionary = {}) -> Dictionary:
	var ta := GantryLabAssembly.feature_of(part(doc, beam_a), face_a)
	var tb := GantryLabAssembly.feature_of(part(doc, beam_b), face_b)
	var ca := GantryLabCatalog.feature("corner_bracket", {}, "a")
	var cb := GantryLabCatalog.feature("corner_bracket", {}, "b")
	var fxa: Transform3D = world(doc, beam_a) * (ta["xf"] as Transform3D)
	var local := fxa.affine_inverse() * at
	var best := {}
	var best_d := INF
	for t in 4:
		for o in GantryLabMates.lat_options(ta, ca, t):
			var wish := {"to": beam_a, "tf": face_a, "f": "a", "turn": t, "lat": float(o), "anchor": "start", "h": 0.0}
			# The leg's hole sits 13 mm out from the corner: try both sides.
			for ds in [0.0, 0.013, -0.013]:
				wish["s"] = local.x + float(ds)
				var sn := GantryLabMates.snap(ta, ca, wish, 0.0)
				if sn.is_empty():
					continue
				var wc := GantryLabMates.place(world(doc, beam_a), ta, ca, sn)
				var inf := GantryLabMates.infer(world(doc, beam_b), tb, cb, wc)
				var m2 := {"s": float(inf["s"]), "lat": float(inf["lat"]), "h": 0.0, "turn": int(inf["turn"]), "anchor": "start"}
				if absf(float(inf["h"])) > 0.0008 or float(inf["err"]) > 0.01:
					continue
				if not bool(GantryLabMates.fits(tb, cb, m2)["ok"]):
					continue
				var dd := (wc.origin).distance_to(at)
				if dd < best_d:
					best_d = dd
					best = sn
	if best.is_empty():
		doc["issues"].append({"level": "error", "text": "build: corner %s does not fit between %s and %s" % [id, beam_a, beam_b], "parts": [id]})
		best = {"to": beam_a, "tf": face_a, "f": "a", "s": local.x, "lat": 0.0, "turn": 0, "anchor": "start"}
	best = _auto_anchor(ta, best)
	var p := {"id": id, "ref": "corner_bracket", "params": {}, "mate": best, "also": [{"to": beam_b, "tf": face_b, "f": "b"}]}
	for k in extra:
		p[k] = extra[k]
	return _add(doc, p, GantryLabMates.place(world(doc, beam_a), ta, ca, best))


static func twins(doc: Dictionary, a: String, b: String) -> void:
	part(doc, a)["twin"] = b
	part(doc, b)["twin"] = a


## The face of a beam whose outward normal is closest to `dir` (world).
static func face_toward(doc: Dictionary, beam: String, dir: Vector3) -> String:
	var best := "+y"
	var bd := -INF
	for fid in ["+y", "-y", "+z", "-z"]:
		var n := feat_world(doc, beam, fid).basis.y.normalized()
		var d := n.dot(dir.normalized())
		if d > bd:
			bd = d
			best = fid
	return best


## The beam end nearest a world point.
static func end_near(doc: Dictionary, beam: String, at: Vector3) -> String:
	return "e0" if feat_world(doc, beam, "e0").origin.distance_to(at) <= feat_world(doc, beam, "e1").origin.distance_to(at) else "e1"


## A beam's x axis, from a to b, with its h side along `up`.
static func beam_xf(a: Vector3, b: Vector3, up: Vector3) -> Transform3D:
	var x := (b - a).normalized()
	var y := (up - x * up.dot(x)).normalized()
	return Transform3D(Basis(x, y, x.cross(y)), a)


static func spin(motor: int, per_rev_mm: float, sign: float = 1.0) -> Dictionary:
	return {"motor": motor, "per_rev_mm": per_rev_mm, "sign": sign}

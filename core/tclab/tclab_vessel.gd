class_name TcVessel
extends RefCounted

## Vessels and tanks for the TC designer (plan Phase 5): a shell with a
## bottom and top head, an optional removable lid, a steam / water jacket,
## insulation, legs or a skirt, internals (retort cans, baskets, a coil, a
## false bottom), and NOZZLES the player drags round the surface — clamp
## ferrules, NPT bungs or weld stubs — each one a port the rest of the
## assembly joins.
##
## Frame (mm): +Y up, the origin on the axis at the shell's bottom seam; the
## shell runs to y = height, the bottom head hangs below 0, the top head (or
## the lid) sits on y = height. A nozzle on the shell is at `angle_deg`
## round the axis (0 = +Z, 90 = +X) and `h_mm` up the shell, `stub_mm`
## out past the outermost surface there (jacket, insulation), tilted
## `tilt_deg` down. A nozzle on a head is at `angle_deg`, `r_mm` out from
## the axis, pointing straight up (top, lid) or down (bottom).
##
## Heads: flat (a plate), dished (ASME flanged-and-dished look, depth 0.19 D
## by default), ellipsoidal (2:1, depth D/4), conical (depth 0.9 R by
## default). Depth 0 = the kind's default.

const STEEL := "steel"
const KG := TcStandards.STEEL_KG_M3 * 1e-9
const HEADS := ["flat", "dished", "ellipsoidal", "conical"]
const TOPS := ["open", "flat", "dished", "ellipsoidal", "conical"]
const JACKETS := ["none", "full", "band"]
const LEGS := ["none", "legs", "skirt"]
const FACES := ["shell", "top", "bottom", "lid"]
const INTERNALS := ["retort_can", "basket", "coil", "false_bottom"]
const INTERNAL_LABELS := {"retort_can": "Retort can", "basket": "Mesh basket", "coil": "Heating / cooling coil", "false_bottom": "False bottom"}
const NOZZLE_KINDS := ["tc", "npt", "weld"]

const PRESETS := {
	"jacketed_boiler": {"label": "Jacketed boiler (Ø340, steam jacket)", "params": {"od_mm": 340.0, "height_mm": 650.0,
		"bottom": "flat", "top": "open", "lid": true, "lid_od_mm": 516.0, "lid_depth_mm": 59.0,
		"jacket": "full", "jacket_gap_mm": 26.0}},
	"brew_kettle": {"label": "Brew kettle 50 L", "params": {"od_mm": 400.0, "height_mm": 420.0, "bottom": "flat",
		"top": "open", "lid": true, "lid_od_mm": 0.0, "lid_depth_mm": 30.0, "jacket": "none", "legs": "none"}},
	"conical": {"label": "Conical fermenter 60 L", "params": {"od_mm": 380.0, "height_mm": 480.0, "bottom": "conical",
		"bottom_depth_mm": 300.0, "top": "dished", "lid": false, "jacket": "band", "jacket_from_mm": 80.0,
		"jacket_to_mm": 380.0, "legs": "legs", "leg_count": 3, "leg_h_mm": 480.0}},
	"pot_still": {"label": "Pot still boiler 30 L", "params": {"od_mm": 330.0, "height_mm": 360.0, "bottom": "flat",
		"top": "dished", "lid": false, "jacket": "none", "legs": "none"}},
	"storage": {"label": "Storage tank 200 L", "params": {"od_mm": 560.0, "height_mm": 800.0, "bottom": "dished",
		"top": "dished", "lid": false, "jacket": "none", "legs": "legs", "leg_count": 4, "leg_h_mm": 300.0}},
}


static func defaults() -> Dictionary:
	return {"od_mm": 340.0, "height_mm": 500.0, "wall_mm": 2.0,
		"bottom": "flat", "bottom_depth_mm": 0.0, "top": "open", "top_depth_mm": 0.0,
		"lid": true, "lid_od_mm": 0.0, "lid_depth_mm": 0.0, "lid_handles": true,
		"jacket": "none", "jacket_gap_mm": 25.0, "jacket_from_mm": 0.0, "jacket_to_mm": 0.0,
		"insulation_mm": 0.0, "insulation_from_mm": 0.0, "insulation_to_mm": 0.0,
		"legs": "none", "leg_count": 4, "leg_h_mm": 200.0,
		"internals": [], "ports": [], "cutaway": false}


static func resolve(p: Dictionary) -> Dictionary:
	var out := defaults()
	for k in p:
		if out.has(k):
			out[k] = p[k]
	out["od_mm"] = clampf(float(out["od_mm"]), 60.0, 3000.0)
	out["height_mm"] = clampf(float(out["height_mm"]), 40.0, 5000.0)
	out["wall_mm"] = clampf(float(out["wall_mm"]), 0.8, 12.0)
	for key in ["bottom", "top", "jacket", "legs"]:
		var allowed: Array = {"bottom": HEADS, "top": TOPS, "jacket": JACKETS, "legs": LEGS}[key]
		if not str(out[key]) in allowed:
			out[key] = allowed[0] if key != "bottom" else "flat"
	for key in ["bottom_depth_mm", "top_depth_mm", "lid_od_mm", "lid_depth_mm", "jacket_gap_mm", "jacket_from_mm",
			"jacket_to_mm", "insulation_mm", "insulation_from_mm", "insulation_to_mm", "leg_h_mm"]:
		out[key] = maxf(float(out[key]), 0.0)
	out["leg_count"] = clampi(int(out["leg_count"]), 3, 8)
	out["lid"] = bool(out["lid"])
	out["lid_handles"] = bool(out["lid_handles"])
	out["cutaway"] = bool(out["cutaway"])
	var ints: Array = []
	for it in out["internals"]:
		if it is Dictionary and str(it.get("kind", "")) in INTERNALS:
			ints.append({"kind": str(it["kind"]), "od_mm": maxf(float(it.get("od_mm", 200.0)), 10.0),
				"h_mm": maxf(float(it.get("h_mm", 200.0)), 2.0), "z_mm": float(it.get("z_mm", 20.0))})
	out["internals"] = ints
	var ports: Array = []
	var ids := {}
	for q in out["ports"]:
		if not (q is Dictionary):
			continue
		var kind := str(q.get("kind", "tc"))
		if not kind in NOZZLE_KINDS:
			kind = "tc"
		var size := str(q.get("size", "1.5"))
		if kind == "npt" and not TcStandards.NPT_OD.has(size):
			size = "0.5"
		elif kind != "npt" and not TcStandards.has_size(size):
			size = "1.5"
		var id := str(q.get("id", ""))
		if id.is_empty() or ids.has(id):
			id = new_port_id(ids)
		ids[id] = true
		var face := str(q.get("face", "shell"))
		if not face in FACES:
			face = "shell"
		ports.append({"id": id, "kind": kind, "size": size, "face": face,
			"angle_deg": fposmod(float(q.get("angle_deg", 0.0)), 360.0),
			"h_mm": float(q.get("h_mm", float(out["height_mm"]) * 0.5)),
			"r_mm": maxf(float(q.get("r_mm", 0.0)), 0.0),
			"stub_mm": clampf(float(q.get("stub_mm", 30.0)), 0.0, 1000.0),
			"tilt_deg": clampf(float(q.get("tilt_deg", 0.0)), -80.0, 80.0)})
	out["ports"] = ports
	return out


static func new_port_id(taken: Dictionary) -> String:
	var i := taken.size() + 1
	while taken.has("n%d" % i):
		i += 1
	return "n%d" % i


static func label(p: Dictionary) -> String:
	var bits := PackedStringArray(["Vessel Ø%d × %d mm" % [roundi(float(p["od_mm"])), roundi(float(p["height_mm"]))]])
	if str(p["jacket"]) != "none":
		bits.append("jacketed")
	return " ".join(bits)


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------

static func r_out(p: Dictionary) -> float:
	return float(p["od_mm"]) * 0.5


static func head_depth(p: Dictionary, which: String) -> float:
	var kind := str(p[which])
	var d := float(p[which + "_depth_mm"])
	if d > 0.0:
		return d if kind != "flat" else 0.0
	var R := r_out(p)
	match kind:
		"dished": return float(p["od_mm"]) * 0.19
		"ellipsoidal": return float(p["od_mm"]) * 0.25
		"conical": return R * 0.9
	return 0.0


## The head's outer curve: [(r, dz)] from the rim (r = R, dz = 0) to the
## axis (r = 0, dz = depth).
static func head_curve(kind: String, R: float, depth: float, n: int = 16) -> Array:
	var out: Array = []
	match kind:
		"flat", "open":
			out = [Vector2(R, 0.0), Vector2(0.0, 0.0)]
		"conical":
			out = [Vector2(R, 0.0), Vector2(0.0, depth)]
		_:
			for i in n + 1:
				var t := PI * 0.5 * float(i) / float(n)
				out.append(Vector2(R * cos(t), depth * sin(t)))
	return out


## dz of a head curve at radius r (linear between samples).
static func curve_at(curve: Array, r: float) -> float:
	for i in curve.size() - 1:
		var a: Vector2 = curve[i]
		var b: Vector2 = curve[i + 1]
		if r <= a.x and r >= b.x:
			var u := 0.0 if absf(a.x - b.x) < 1e-6 else (a.x - r) / (a.x - b.x)
			return lerpf(a.y, b.y, u)
	return (curve[curve.size() - 1] as Vector2).y


static func lid_od(p: Dictionary) -> float:
	var l := float(p["lid_od_mm"])
	return l if l > 0.0 else float(p["od_mm"]) + 30.0


static func lid_depth(p: Dictionary) -> float:
	var d := float(p["lid_depth_mm"])
	return d if d > 0.0 else lid_od(p) * 0.12


static func has_lid(p: Dictionary) -> bool:
	return str(p["top"]) == "open" and bool(p["lid"])


static func jacket_span(p: Dictionary) -> Vector2:
	if str(p["jacket"]) == "none":
		return Vector2(-1, -1)
	var H := float(p["height_mm"])
	if str(p["jacket"]) == "full":
		return Vector2(0.0, H)
	var to := float(p["jacket_to_mm"])
	return Vector2(clampf(float(p["jacket_from_mm"]), 0.0, H), clampf(to if to > 0.0 else H, 0.0, H))


static func jacket_r(p: Dictionary) -> float:
	return r_out(p) + float(p["jacket_gap_mm"]) + float(p["wall_mm"])


static func insulation_span(p: Dictionary) -> Vector2:
	if float(p["insulation_mm"]) <= 0.0:
		return Vector2(-1, -1)
	var H := float(p["height_mm"])
	var to := float(p["insulation_to_mm"])
	return Vector2(clampf(float(p["insulation_from_mm"]), 0.0, H), clampf(to if to > 0.0 else H, 0.0, H))


## The outermost surface radius at height y (shell, jacket, insulation).
static func r_eff(p: Dictionary, y: float) -> float:
	var r := r_out(p)
	var j := jacket_span(p)
	if j.x >= 0.0 and y >= j.x - 0.01 and y <= j.y + 0.01:
		r = jacket_r(p)
	var ins := insulation_span(p)
	if ins.x >= 0.0 and y >= ins.x - 0.01 and y <= ins.y + 0.01:
		r += float(p["insulation_mm"])
	return r


## Height of a head / lid surface at radius r: {y, up} (up = the nozzle's
## outward direction there).
static func face_y(p: Dictionary, face: String, r: float) -> float:
	var H := float(p["height_mm"])
	match face:
		"bottom":
			var c := head_curve(str(p["bottom"]), r_out(p), head_depth(p, "bottom"))
			return -curve_at(c, minf(r, r_out(p))) - (float(p["wall_mm"]) if str(p["bottom"]) == "flat" else 0.0)
		"top":
			var c2 := head_curve(str(p["top"]), r_out(p), head_depth(p, "top"))
			return H + curve_at(c2, minf(r, r_out(p))) + (float(p["wall_mm"]) if str(p["top"]) == "flat" else 0.0)
		"lid":
			var c3 := head_curve("dished", lid_od(p) * 0.5, lid_depth(p))
			return H + curve_at(c3, minf(r, lid_od(p) * 0.5)) + float(p["wall_mm"])
	return H


## Where a nozzle sits: {base (on the surface), face (port position), dir
## (out), x (roll reference), inner (where its tube starts inside)}.
static func nozzle_frame(p: Dictionary, q: Dictionary) -> Dictionary:
	var a := deg_to_rad(float(q["angle_deg"]))
	var dh := Vector3(sin(a), 0.0, cos(a))
	var face := str(q["face"])
	var stub := float(q["stub_mm"])
	if face == "shell":
		var H := float(p["height_mm"])
		var h := clampf(float(q["h_mm"]), 0.0, H)
		var t := deg_to_rad(float(q["tilt_deg"]))
		var dir := (dh * cos(t) - Vector3.UP * sin(t)).normalized()
		var re := r_eff(p, h)
		var base := Vector3(0, h, 0) + dh * re
		var inner := Vector3(0, h, 0) + dh * (r_out(p) - float(p["wall_mm"]))
		return {"base": base, "face": base + dir * stub, "dir": dir, "x": Vector3.UP, "inner": inner}
	var rr := float(q["r_mm"])
	var lim := (lid_od(p) * 0.5 if face == "lid" else r_out(p)) * 0.88
	rr = minf(rr, lim)
	var y := face_y(p, face, rr)
	var up := Vector3.DOWN if face == "bottom" else Vector3.UP
	var b := Vector3(dh.x * rr, y, dh.z * rr)
	return {"base": b, "face": b + up * stub, "dir": up, "x": dh if rr > 1.0 else Vector3(0, 0, 1),
		"inner": b - up * (float(p["wall_mm"]) + 4.0)}


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

## The vessel into `g`; same return shape as TcParts builders, plus
## `solid` (the body for the clash test) and `nozzles` (frames by port id).
static func build(g: TcGeom, p: Dictionary) -> Dictionary:
	var R := r_out(p)
	var w := float(p["wall_mm"])
	var Ri := R - w
	var H := float(p["height_mm"])
	var up := Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3.ZERO)
	var a0 := 0.0
	var a1 := TAU
	if bool(p["cutaway"]):
		a1 = PI * 1.5
	var n := TcGeom.segs_for(R)
	# Shell.
	g.lathe(STEEL, TcSpecialty._ring(Ri, R, 0.0, H), up, n, a0, a1)
	# Bottom head.
	var db := head_depth(p, "bottom")
	var cb := head_curve(str(p["bottom"]), R, db)
	g.lathe(STEEL, _head_outline(cb, R, Ri, w, str(p["bottom"]), false, 0.0), up, n, a0, a1, true)
	# Top head.
	var dt := head_depth(p, "top")
	if str(p["top"]) != "open":
		var ct := head_curve(str(p["top"]), R, dt)
		g.lathe(STEEL, _head_outline(ct, R, Ri, w, str(p["top"]), true, H), up, n, a0, a1, true)
	# Lid.
	var top_y := H + (dt if str(p["top"]) != "open" else 0.0)
	if has_lid(p):
		var Rl := lid_od(p) * 0.5
		var dl := lid_depth(p)
		var cl := head_curve("dished", Rl, dl)
		var prof: Array = [Vector2(Rl, H - 14.0), Vector2(Rl, H)]
		for i in range(1, cl.size()):
			prof.append(Vector2((cl[i] as Vector2).x, H + w + (cl[i] as Vector2).y))
		for i in range(cl.size() - 1, -1, -1):
			var q: Vector2 = cl[i]
			prof.append(Vector2(maxf(q.x - w, 0.0), H + q.y * (1.0 - w / maxf(dl, w * 2.0))))
		prof.append(Vector2(Rl - w, H - 14.0))
		prof.append(Vector2(Rl, H - 14.0))
		g.lathe(STEEL, _dedupe(prof), up, TcGeom.segs_for(Rl), a0, a1, true)
		top_y = H + w + dl
		if bool(p["lid_handles"]):
			for sgn in [-1.0, 1.0]:
				var rr := Rl * 0.42
				var y0 := face_y(p, "lid", rr)
				var c := Vector3(sgn * rr, y0 + 12.0, 0)
				g.box("dark", Transform3D(Basis.IDENTITY, c), Vector3(5.0, 3.5, 26.0))
				for e in [-1.0, 1.0]:
					g.box("dark", Transform3D(Basis.IDENTITY, Vector3(sgn * rr, y0 + 5.0, e * 22.0)), Vector3(4.0, 7.0, 4.0))
	# Jacket.
	var j := jacket_span(p)
	if j.x >= 0.0:
		var Rj := jacket_r(p)
		g.lathe(STEEL, TcSpecialty._ring(Rj - w, Rj, j.x, j.y), up, TcGeom.segs_for(Rj), a0, a1)
		g.lathe(STEEL, TcSpecialty._ring(R, Rj, j.x, j.x + w), up, TcGeom.segs_for(Rj), a0, a1)
		g.lathe(STEEL, TcSpecialty._ring(R, Rj, j.y - w, j.y), up, TcGeom.segs_for(Rj), a0, a1)
	# Insulation.
	var ins := insulation_span(p)
	if ins.x >= 0.0:
		var r0 := jacket_r(p) if j.x >= 0.0 else R
		g.lathe("insulation", TcSpecialty._ring(r0, r0 + float(p["insulation_mm"]), ins.x, ins.y), up,
			TcGeom.segs_for(r0), a0, a1)
	# Legs / skirt.
	var bottom_y := -db - (w if str(p["bottom"]) == "flat" else 0.0)
	var leg_h := float(p["leg_h_mm"])
	match str(p["legs"]):
		"legs":
			var nl := int(p["leg_count"])
			var rl := R * 0.82
			var y_top := face_y(p, "bottom", rl)
			for k in nl:
				var ang := TAU * float(k) / float(nl) + PI / float(nl)
				var c := Vector3(sin(ang) * rl, 0, cos(ang) * rl)
				g.cylinder(STEEL, c + Vector3(0, y_top + 2.0, 0), c + Vector3(0, bottom_y - leg_h + 8.0, 0), 13.0, 14)
				g.cylinder("dark", c + Vector3(0, bottom_y - leg_h + 8.0, 0), c + Vector3(0, bottom_y - leg_h, 0), 20.0, 16)
			bottom_y -= leg_h
		"skirt":
			var ys := face_y(p, "bottom", R - w)
			g.lathe(STEEL, TcSpecialty._ring(R - w, R, bottom_y - leg_h, ys), up, n, a0, a1)
			bottom_y -= leg_h
	# Internals.
	for it in p["internals"]:
		_internal(g, p, it, up)
	# Nozzles.
	var ports: Array = []
	var nozzles := {}
	for q in p["ports"]:
		var f := nozzle_frame(p, q)
		nozzles[str(q["id"])] = f
		var dir: Vector3 = f["dir"]
		var face: Vector3 = f["face"]
		var inner: Vector3 = f["inner"]
		var run := (face - inner).dot(dir)
		var kind := str(q["kind"])
		var size := str(q["size"])
		var pid := str(q["id"])
		if kind == "npt":
			var od := TcStandards.npt_od(size)
			g.lathe(STEEL, TcSpecialty._ring(od * 0.45, od * 0.5 + 5.0, 0.0, maxf(run, 6.0)),
				TcGeom.frame_along(inner, dir), TcGeom.segs_for(od))
			ports.append(TcParts.port(pid, "npt_f", size, face, dir, f["x"]))
		else:
			var pp := TcParts.port(pid, "tc" if kind == "tc" else "weld", size, face, dir, f["x"])
			var hub := 0.0
			if kind == "tc":
				hub = g.ferrule_end(TcParts.into_xform(pp), size, false, STEEL, minf(float(TcStandards.ferrule(size)["hub"]), maxf(run, 4.0)))
			g.tube_body(TcGeom.frame_along(inner, dir), size, 0.0, maxf(run - hub, 0.0))
			ports.append(pp)
	var mass := (PI * float(p["od_mm"]) * H * w + PI * R * R * w * 2.0) * KG
	if j.x >= 0.0:
		mass += PI * 2.0 * jacket_r(p) * (j.y - j.x) * w * KG
	var vol := PI * Ri * Ri * H
	match str(p["bottom"]):
		"dished", "ellipsoidal": vol += 2.0 / 3.0 * PI * Ri * Ri * db
		"conical": vol += PI * Ri * Ri * db / 3.0
	var Rmax := maxf(r_eff(p, H * 0.5), lid_od(p) * 0.5 if has_lid(p) else 0.0)
	return {"ports": ports, "capsules": [[Vector3(0, bottom_y, 0), Vector3(0, top_y, 0), Rmax]],
		"solid": {"y0": -db, "y1": top_y, "r": R}, "nozzles": nozzles,
		"mass_kg": mass, "volume_l": vol * 1e-6}


static func _dedupe(prof: Array) -> Array:
	var out: Array = []
	for q in prof:
		if out.is_empty() or (out[out.size() - 1] as Vector2).distance_to(q) > 1e-4:
			out.append(q)
	return out


## A head's closed outline (solid on the left) from its outer curve.
static func _head_outline(curve: Array, R: float, Ri: float, w: float, kind: String, top: bool, H: float) -> Array:
	var s := 1.0 if top else -1.0
	var depth := (curve[curve.size() - 1] as Vector2).y
	var outer: Array = []
	var inner: Array = []
	for q in curve:
		var v: Vector2 = q
		if kind == "flat":
			outer.append(Vector2(v.x, H + s * w if top else -w))
			inner.append(Vector2(v.x * Ri / R, H if top else 0.0))
		else:
			outer.append(Vector2(v.x, H + s * v.y))
			var di := maxf(depth - w, 0.0)
			var dy := v.y * (di / maxf(depth, 1e-6))
			inner.append(Vector2(v.x * Ri / R, H + s * dy))
	var out: Array = []
	if top:
		for q in outer:
			out.append(q)
		for i in range(inner.size() - 1, -1, -1):
			out.append(inner[i])
		out.append(outer[0])
	else:
		for q in inner:
			out.append(q)
		for i in range(outer.size() - 1, -1, -1):
			out.append(outer[i])
		out.append(inner[0])
	return _dedupe(out)


static func _internal(g: TcGeom, p: Dictionary, it: Dictionary, up: Transform3D) -> void:
	var r := minf(float(it["od_mm"]) * 0.5, r_out(p) - float(p["wall_mm"]) - 2.0)
	var z := float(it["z_mm"])
	var h := float(it["h_mm"])
	var n := TcGeom.segs_for(r)
	match str(it["kind"]):
		"retort_can":
			g.lathe("can", TcSpecialty._ring(r - 1.2, r, z, z + h), up, n)
			g.lathe("can", TcSpecialty._ring(0.0, r, z, z + 1.5), up, n)
			g.lathe("char", TcSpecialty._ring(0.0, r - 1.2, z + h * 0.9, z + h * 0.9 + 1.0), up, n)
		"basket":
			g.lathe("mesh", TcSpecialty._ring(r - 1.0, r, z, z + h), up, n)
			g.lathe("mesh", TcSpecialty._ring(0.0, r, z, z + 1.0), up, n)
		"false_bottom":
			g.lathe("mesh", TcSpecialty._ring(0.0, r, z, z + 2.0), up, n)
			for k in 3:
				var a := TAU * float(k) / 3.0
				g.cylinder(STEEL, Vector3(sin(a) * r * 0.7, 0, cos(a) * r * 0.7), Vector3(sin(a) * r * 0.7, z, cos(a) * r * 0.7), 4.0, 8)
		"coil":
			var path := PackedVector3Array()
			var turns := maxf(h / 40.0, 1.0)
			var steps := int(turns * 24.0)
			for i in steps + 1:
				var t := float(i) / float(steps)
				var a := TAU * turns * t
				path.append(Vector3(sin(a) * (r - 8.0), z + h * t, cos(a) * (r - 8.0)))
			g.sweep("copper", path, 6.0, true, 10)


# ---------------------------------------------------------------------------
# Dragging a nozzle on the surface
# ---------------------------------------------------------------------------

## A nozzle moved to where the ray (vessel-local mm) meets the surface it
## is on. Returns the updated nozzle dict (unchanged when the ray misses).
static func surface_hit(p: Dictionary, q: Dictionary, o: Vector3, d: Vector3) -> Dictionary:
	var out := q.duplicate()
	var face := str(q["face"])
	if face == "shell":
		var re := r_eff(p, float(q["h_mm"]))
		var ox := Vector2(o.x, o.z)
		var dx := Vector2(d.x, d.z)
		var a := dx.dot(dx)
		if a < 1e-9:
			return out
		var b := 2.0 * ox.dot(dx)
		var c := ox.dot(ox) - re * re
		var disc := b * b - 4.0 * a * c
		if disc < 0.0:
			return out
		var t := (-b - sqrt(disc)) / (2.0 * a)
		if t < 0.0:
			t = (-b + sqrt(disc)) / (2.0 * a)
		if t < 0.0:
			return out
		var hit := o + d * t
		var margin := float(TcStandards.tube(str(q["size"]))["r_flange"]) if str(q["kind"]) != "npt" else 15.0
		out["angle_deg"] = snappedf(fposmod(rad_to_deg(atan2(hit.x, hit.z)), 360.0), 1.0)
		out["h_mm"] = snappedf(clampf(hit.y, margin, float(p["height_mm"]) - margin), 1.0)
		return out
	var y := face_y(p, face, float(q["r_mm"]))
	if absf(d.y) < 1e-6:
		return out
	var t2 := (y - o.y) / d.y
	if t2 < 0.0:
		return out
	var h2 := o + d * t2
	var lim := (lid_od(p) * 0.5 if face == "lid" else r_out(p)) * 0.88
	out["r_mm"] = snappedf(clampf(Vector2(h2.x, h2.z).length(), 0.0, lim), 1.0)
	out["angle_deg"] = snappedf(fposmod(rad_to_deg(atan2(h2.x, h2.z)), 360.0), 1.0)
	return out

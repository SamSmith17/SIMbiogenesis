class_name ConnectorParts
extends RefCounted

## Draws any ConnectorCatalog entry into a BattParts.Geo. `xf` places the
## connector's LOCAL frame (mm; panel surface z = 0, +Z out of the panel, +Y
## up, +X right) in the Geo's frame (mm); its basis must be orthonormal.
##
##   var r := ConnectorParts.build(g, "mc4_panel", xf, {"sex": "male", "polarity": "+"})
##   r.pins    → [{id, label, role, pos, dir}] in the Geo's frame (where a wire lands)
##   r.labels  → [{text, pos, normal, up, size, color}] printed text the caller makes
##               Label3D / decals from (Geo carries no text)
##   r.aabb    → the connector's box in its LOCAL frame (mm)
##
## Every triangle goes through BattParts (wound to its normal).

const DARK := Color(0.025, 0.025, 0.03)
const HOLE := Color(0.01, 0.01, 0.012)


class K:
	var g: BattParts.Geo
	var xf: Transform3D
	var labels: Array = []

	func _init(geo: BattParts.Geo, t: Transform3D) -> void:
		g = geo
		xf = t

	func P(v: Vector3) -> Vector3:
		return xf * v

	func D(v: Vector3) -> Vector3:
		return (xf.basis * v).normalized()

	func box(c: Vector3, size: Vector3, col: Color, fin: String = "plastic") -> void:
		BattParts.obox(g, P(c), D(Vector3.RIGHT), D(Vector3.UP), D(Vector3.BACK), size, col, fin)

	## A box turned by `rot` (a Basis in the local frame).
	func rbox(c: Vector3, rot: Basis, size: Vector3, col: Color, fin: String = "plastic") -> void:
		BattParts.obox(g, P(c), D(rot.x), D(rot.y), D(rot.z), size, col, fin)

	func turn(c: Vector3, axis: Vector3, prof: Array, col: Color, fin: String, sides: int = 16,
			flat: bool = false, phase: float = 0.0) -> void:
		BattParts.lathe(g, P(c), D(axis), prof, col, fin, sides, flat, phase)

	func disc(c: Vector3, axis: Vector3, r: float, th: float, col: Color, fin: String = "plastic", sides: int = 16) -> void:
		BattParts.disc(g, P(c), D(axis), r, th, col, fin, sides)

	func ring(c: Vector3, axis: Vector3, ro: float, ri: float, th: float, col: Color, fin: String = "plastic",
			sides: int = 16) -> void:
		BattParts.annulus(g, P(c), D(axis), ro, ri, th, col, fin, sides)

	func hexp(c: Vector3, axis: Vector3, af: float, h: float, hole: float, col: Color, fin: String = "metal") -> void:
		var rc := af * 0.5 / cos(PI / 6.0)
		turn(c, axis, [Vector2(hole, 0), Vector2(rc, 0), Vector2(rc, h), Vector2(hole, h), Vector2(hole, 0)], col, fin, 6, true)

	func tube(pts: Array, d: float, col: Color, fin: String = "plastic", sides: int = 12) -> void:
		var pp := PackedVector3Array()
		for p in pts:
			pp.append(P(p))
		BattParts.tube(g, pp, d, col, fin, sides)

	## A convex outline (CCW seen from +Z) in the local XY plane at depth z0,
	## extruded out to z0 + h.
	func slab(outline: Array, z0: float, h: float, col: Color, fin: String = "plastic") -> void:
		BattParts.prism(g, P(Vector3(0, 0, z0)), D(Vector3.RIGHT), D(Vector3.UP), D(Vector3.BACK), outline, h, col, fin)

	## A hole: a dark patch just proud of a face facing +Z at depth z.
	func hole_rect(c: Vector2, size: Vector2, z: float) -> void:
		box(Vector3(c.x, c.y, z + 0.06), Vector3(size.x, size.y, 0.1), HOLE, "rubber")

	func hole_disc(c: Vector2, r: float, z: float) -> void:
		disc(Vector3(c.x, c.y, z), Vector3.BACK, r, 0.12, HOLE, "rubber", 14)

	func label(text: String, pos: Vector3, size: float, col: Color = Color(0.92, 0.92, 0.9)) -> void:
		labels.append({"text": text, "pos": P(pos), "normal": D(Vector3.BACK), "up": D(Vector3.UP), "size": size, "color": col})


## A rounded rectangle outline (CCW seen from +Z), centre at origin.
static func rrect(w: float, h: float, r: float, seg: int = 4) -> Array:
	var rr := clampf(r, 0.0, minf(w, h) * 0.5)
	var out: Array = []
	var cs := [Vector2(w * 0.5 - rr, -h * 0.5 + rr), Vector2(w * 0.5 - rr, h * 0.5 - rr),
		Vector2(-w * 0.5 + rr, h * 0.5 - rr), Vector2(-w * 0.5 + rr, -h * 0.5 + rr)]
	for k in 4:
		var a0 := -PI * 0.5 + PI * 0.5 * float(k)
		if rr < 0.01:
			out.append(cs[k])
			continue
		for s in seg + 1:
			var a := a0 + PI * 0.5 * float(s) / float(seg)
			out.append(cs[k] + Vector2(cos(a), sin(a)) * rr)
	return out


static func build(g: BattParts.Geo, id: String, xf: Transform3D, opts: Dictionary = {}) -> Dictionary:
	var e := ConnectorCatalog.resolve(id, opts)
	if e.is_empty():
		return {"pins": [], "labels": [], "aabb": AABB(), "entry": {}}
	var k := K.new(g, xf)
	var o: Dictionary = e["opts"]
	var b: Vector3 = e["body"]
	match str(e["shape"]):
		"mc4": _mc4(k, e, o)
		"powerpole": _powerpole(k, b, o)
		"sb": _sb(k, b, o)
		"xt": _xt(k, b, o)
		"sae": _sae(k, b)
		"barrel": _barrel(k, o)
		"cig": _cig(k)
		"stud": _stud(k, o)
		"binding": _binding(k, o)
		"box_lug": _box_lug(k, b)
		"fuse_t": _fuse_t(k, b, o)
		"fuse_anl": _fuse_anl(k, b, o)
		"nema": _nema(k, b, o)
		"round_ac": _round_ac(k, b, o)
		"bs1363": _bs1363(k, b)
		"asnzs": _asnzs(k, b)
		"iec": _iec(k, b, o)
		"rocker": _rocker(k, b, o)
		"push_breaker": _push_breaker(k, o)
		"terminal_block": _terminal_block(k, e, o)
		"wago": _wago(k, e, o)
		"din_rail": _din_rail(k, b)
		"din_breaker": _din_breaker(k, e, o)
		"bus_bar": _bus_bar(k, e, o)
		"ground_lug": _ground_lug(k)
		"rj_jack": _rj_jack(k, b, o)
		"rj_plug": _rj_plug(k, o)
		"usb": _usb(k, b, o)
		"db9": _db9(k, b)
		"ve_direct": _ve_direct(k, b)
		"antenna": _antenna(k, o)
		"gland": _gland(k, b, o)
		"knockout": _knockout(k, o)
		"led": _led(k, o)
		"lcd": _lcd(k, o)
		"button": _button(k, o)
		"dip": _dip(k, b, o)
	var pins: Array = []
	for p in (e["pins"] as Array):
		pins.append({"id": p["id"], "label": p["label"], "role": p["role"], "pos": k.P(p["pos"]), "dir": k.D(p["dir"])})
	var lo := Vector3(-b.x * 0.5, -b.y * 0.5, 0.0)
	return {"pins": pins, "labels": k.labels, "aabb": AABB(lo, b), "entry": e}


## One connector as its own mesh (look sheets, palette thumbnails).
static func mesh(id: String, opts: Dictionary = {}) -> ArrayMesh:
	var g := BattParts.Geo.new()
	build(g, id, Transform3D.IDENTITY, opts)
	return g.commit()


## Add a Geo's surfaces (already in metres) to an existing mesh.
static func append_to(am: ArrayMesh, g: BattParts.Geo) -> void:
	for k in g.surf:
		var sf: BattParts.Surf = g.surf[k]
		if sf.v.is_empty():
			continue
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = sf.v
		arr[Mesh.ARRAY_NORMAL] = sf.n
		arr[Mesh.ARRAY_COLOR] = sf.c
		am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		am.surface_set_material(am.get_surface_count() - 1, BattParts.material(str(k)))


## A colour given as a Color or as [r, g, b] (JSON-safe specs).
static func _col(v: Variant, fallback: Color) -> Color:
	if v is Color:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Color(float(v[0]), float(v[1]), float(v[2]))
	return fallback


static func _pol_col(o: Dictionary, fallback: Color) -> Color:
	if o.has("color"):
		return _col(o["color"], fallback)
	var pol := str(o.get("polarity", ""))
	if pol == "+":
		return ConnectorCatalog.C_RED
	if pol == "-" or pol == "−":
		return ConnectorCatalog.C_BLACK
	return fallback


static func _pol_label(k: K, o: Dictionary, pos: Vector3, size: float) -> void:
	var pol := str(o.get("polarity", ""))
	if pol == "+":
		k.label("+", pos, size)
	elif pol == "-" or pol == "−":
		k.label("−", pos, size)


# ---------------------------------------------------------------------------
# Solar
# ---------------------------------------------------------------------------

static func _mc4(k: K, e: Dictionary, o: Dictionary) -> void:
	var col := Color(0.05, 0.05, 0.055)
	var male := str(o.get("sex", "female")) == "male"
	var evo := bool(o.get("evo", false))
	var z := Vector3.BACK
	if str(e["mount"]) == "panel":
		# Back nut behind the panel, a hex flange on it, the coupling body out.
		k.turn(Vector3(0, 0, -20), z, [Vector2(0, 0), Vector2(6.0, 0), Vector2(6.0, 18.0), Vector2(0, 18.0)], col, "plastic", 14)
		k.hexp(Vector3(0, 0, -2.5), z, 20.0, 2.5, 6.2, col, "plastic")
		k.hexp(Vector3.ZERO, z, 22.0, 3.5, 0.0, col, "plastic")
		var nose := 7.0 if not evo else 7.6
		k.turn(Vector3(0, 0, 3.5), z, [Vector2(0, 0), Vector2(9.0, 0), Vector2(9.0, 2.5), Vector2(7.8, 3.5),
			Vector2(7.8, 20.0), Vector2(nose, 22.0), Vector2(nose, 26.5), Vector2(0, 26.5)], col, "plastic", 22)
		for zr in ([8.0, 12.0, 16.0] if evo else [9.0, 13.0]):
			k.ring(Vector3(0, 0, 3.5 + zr), z, 8.3, 7.6, 1.2, col.lightened(0.05), "plastic", 22)
		if male:
			k.disc(Vector3(0, 0, 30.0), z, 5.4, 0.1, HOLE, "rubber", 14)
			for s in [-1.0, 1.0]:
				k.box(Vector3(s * 5.2, 0, 32.0), Vector3(1.6, 5.0, 8.0), col)
			k.disc(Vector3(0, 0, 29.5), z, 1.0, 4.0, Color(0.82, 0.83, 0.85), "metal", 10)
		else:
			k.hole_disc(Vector2.ZERO, 5.0, 30.0)
		_pol_label(k, o, Vector3(0, 15.0, 0.2), 6.0)
	else:
		# A cable connector along +Z from its cable entry at z = 0.
		k.turn(Vector3.ZERO, z, [Vector2(0, 0), Vector2(7.6, 0), Vector2(8.2, 1.5), Vector2(8.2, 12.0),
			Vector2(7.4, 13.0), Vector2(7.4, 44.0), Vector2(0, 44.0)], col, "plastic", 20, false)
		for zr in [3.0, 6.0, 9.0]:
			k.ring(Vector3(0, 0, zr), z, 8.6, 8.0, 1.0, col.lightened(0.05), "plastic", 20)
		if male:
			k.turn(Vector3(0, 0, 44.0), z, [Vector2(0, 0), Vector2(5.4, 0), Vector2(5.4, 12.0), Vector2(0, 12.0)], col, "plastic", 16)
			for s in [-1.0, 1.0]:
				k.box(Vector3(s * 5.9, 0, 50.0), Vector3(1.2, 4.6, 10.0), col)
		else:
			k.turn(Vector3(0, 0, 44.0), z, [Vector2(0, 0), Vector2(7.0, 0), Vector2(7.0, 12.0), Vector2(0, 12.0)], col, "plastic", 20)
			k.hole_disc(Vector2.ZERO, 4.2, 56.0)


# ---------------------------------------------------------------------------
# DC power
# ---------------------------------------------------------------------------

static func _powerpole(k: K, b: Vector3, o: Dictionary) -> void:
	var cols: Array = o.get("colors", [ConnectorCatalog.C_RED, ConnectorCatalog.C_BLACK])
	var hw := b.x * 0.25
	var single := bool(o.get("single", false))
	for i in (1 if single else 2):
		var x := 0.0 if single else (-1.0 if i == 0 else 1.0) * hw
		var col := _col(cols[i], ConnectorCatalog.C_RED)
		k.box(Vector3(x, 0, b.z * 0.5), Vector3(b.x * 0.5 - 0.15, b.y, b.z), col)
		# The hood over the contact and its mating opening.
		k.box(Vector3(x, b.y * 0.25, b.z + 0.6), Vector3(b.x * 0.5 - 1.2, b.y * 0.5, 1.2), col.darkened(0.08))
		k.hole_rect(Vector2(x, -b.y * 0.2), Vector2(b.x * 0.5 - 2.4, b.y * 0.4), b.z)
		k.box(Vector3(x, -b.y * 0.2, b.z + 0.1), Vector3(2.0, 1.0, 0.3), Color(0.8, 0.8, 0.78), "metal")


static func _sb(k: K, b: Vector3, o: Dictionary) -> void:
	var col := _col(o.get("color"), Color(0.5, 0.52, 0.54))
	k.box(Vector3(0, 0, b.z * 0.5), Vector3(b.x, b.y * 0.8, b.z), col)
	# Handle hump on top.
	k.box(Vector3(0, b.y * 0.42, b.z * 0.55), Vector3(b.x * 0.55, b.y * 0.2, b.z * 0.6), col.darkened(0.1))
	for s in [-1.0, 1.0]:
		k.hole_rect(Vector2(s * b.x * 0.24, 0), Vector2(b.x * 0.36, b.y * 0.42), b.z)


static func _xt(k: K, b: Vector3, o: Dictionary) -> void:
	var col := _col(o.get("color"), Color(0.92, 0.76, 0.1))
	var c := b.y * 0.3
	var ol := [Vector2(-b.x * 0.5, -b.y * 0.5), Vector2(b.x * 0.5 - c, -b.y * 0.5), Vector2(b.x * 0.5, -b.y * 0.5 + c),
		Vector2(b.x * 0.5, b.y * 0.5), Vector2(-b.x * 0.5, b.y * 0.5)]
	k.slab(ol, 0.0, b.z, col)
	for s in [-1.0, 1.0]:
		k.hole_disc(Vector2(s * b.x * 0.23, 0), b.y * 0.28, b.z)


static func _sae(k: K, b: Vector3) -> void:
	var col := Color(0.05, 0.05, 0.055)
	k.box(Vector3(0, 0, b.z * 0.5), Vector3(b.x, b.y, b.z), col, "rubber")
	k.hole_rect(Vector2(-b.x * 0.2, 0), Vector2(4.0, 4.0), b.z)
	k.disc(Vector3(b.x * 0.2, 0, b.z), Vector3.BACK, 1.2, 3.0, Color(0.85, 0.75, 0.5), "metal", 10)
	k.label("+", Vector3(-b.x * 0.2, b.y * 0.5 + 2.5, b.z * 0.5), 3.0)


static func _barrel(k: K, o: Dictionary) -> void:
	k.hexp(Vector3.ZERO, Vector3.BACK, 11.0, 2.0, 0.0, ConnectorCatalog.C_ZINC)
	k.turn(Vector3(0, 0, 2.0), Vector3.BACK, [Vector2(0, 0), Vector2(4.5, 0), Vector2(4.5, 8.0), Vector2(0, 8.0)],
		ConnectorCatalog.C_ZINC, "metal", 16)
	k.hole_disc(Vector2.ZERO, 2.9, 10.0)
	k.disc(Vector3(0, 0, 10.0), Vector3.BACK, float(o.get("pin_d", 2.1)) * 0.5, 0.3, Color(0.85, 0.75, 0.5), "metal", 10)
	k.turn(Vector3(0, 0, -14.0), Vector3.BACK, [Vector2(0, 0), Vector2(4.0, 0), Vector2(4.0, 14.0), Vector2(0, 14.0)],
		ConnectorCatalog.C_BLACK, "plastic", 12)


static func _cig(k: K) -> void:
	k.ring(Vector3(0, 0, 1.0), Vector3.BACK, 15.0, 11.0, 2.0, ConnectorCatalog.C_BLACK, "plastic", 24)
	k.hole_disc(Vector2.ZERO, 10.6, 1.9)
	k.turn(Vector3(0, 0, -45.0), Vector3.BACK, [Vector2(0, 0), Vector2(11.5, 0), Vector2(11.5, 45.0), Vector2(0, 45.0)],
		ConnectorCatalog.C_STEEL, "metal", 18)
	# The cap, hinged open at the top.
	k.rbox(Vector3(0, 19.0, 6.0), Basis(Vector3.RIGHT, deg_to_rad(-70.0)), Vector3(22.0, 22.0, 3.0), ConnectorCatalog.C_RED)


## A bolt terminal: a shrouded insulating boss, a brass terminal, a stud
## with washer and nut (the Battery Lab's front terminal, moved here).
static func _stud(k: K, o: Dictionary) -> void:
	var st := float(o.get("stud", 8.0))
	var r := float(o.get("boss_r", st * 1.125))
	var col := _pol_col(o, ConnectorCatalog.C_BLACK)
	var zn := Vector3.BACK
	var brass := ConnectorCatalog.C_BRASS
	var bare := bool(o.get("bare", false))
	if bool(o.get("insulator", true)):
		k.turn(Vector3.ZERO, zn, [Vector2(0, 0), Vector2(r + 2.0, 0), Vector2(r + 2.0, 1.5), Vector2(r, 2.5),
			Vector2(r, 9.5), Vector2(r - 1.5, 11.0), Vector2(0, 11.0)], col, "plastic", 28)
	k.disc(zn * 11.0, zn, 8.5 * st / 8.0, 2.5, brass, "metal", 20)
	BattParts.threaded_stud(k.g, k.P(zn * 13.5), k.D(zn), st, 12.0 * st / 8.0 if not bare else 22.0 * st / 8.0, brass.lightened(0.15))
	if not bare:
		var wt := BattParts.washer(k.g, k.P(zn * 13.5), k.D(zn), st)
		BattParts.hex_nut(k.g, k.P(zn * (13.5 + wt)), k.D(zn), st)
	if bool(o.get("inner", false)):
		var ip := Vector3(0, 0, -15.0)
		k.disc(ip, zn, 9.0, 15.0, brass, "metal", 18)
		BattParts.threaded_stud(k.g, k.P(ip), k.D(-zn), st, 11.0, brass.lightened(0.15))
	if bool(o.get("mark", true)):
		var pol := str(o.get("polarity", ""))
		if pol != "":
			var mk := Vector3(0, r + 9.0, 0.3)
			k.box(mk, Vector3(9.0, 2.0, 0.6), col)
			if pol == "+":
				k.box(mk, Vector3(2.0, 9.0, 0.6), col)


static func _binding(k: K, o: Dictionary) -> void:
	var col := _pol_col(o, ConnectorCatalog.C_RED)
	k.ring(Vector3(0, 0, 1.0), Vector3.BACK, 7.0, 3.0, 2.0, col.darkened(0.2), "plastic", 18)
	k.turn(Vector3(0, 0, 2.0), Vector3.BACK, [Vector2(0, 0), Vector2(3.2, 0), Vector2(3.2, 6.0), Vector2(0, 6.0)],
		ConnectorCatalog.C_BRASS, "metal", 12)
	k.turn(Vector3(0, 0, 8.0), Vector3.BACK, [Vector2(0, 0), Vector2(6.5, 0), Vector2(6.5, 12.0), Vector2(5.5, 14.0),
		Vector2(0, 14.0)], col, "plastic", 20)
	k.hole_disc(Vector2.ZERO, 2.0, 22.0)


static func _box_lug(k: K, b: Vector3) -> void:
	var al := Color(0.78, 0.79, 0.8)
	k.box(Vector3(0, -2.0, b.z * 0.5), Vector3(b.x, b.y - 4.0, b.z), al, "tin")
	k.hole_rect(Vector2(0, -2.0), Vector2(b.x * 0.55, b.y * 0.45), b.z)
	k.box(Vector3(0, -b.y * 0.5 + 2.0, b.z * 0.5), Vector3(b.x * 0.62, 0.2, b.z * 0.62), HOLE, "rubber")
	k.disc(Vector3(0, b.y * 0.5 - 4.0, b.z), Vector3.BACK, 3.5, 1.0, ConnectorCatalog.C_STEEL, "metal", 6)
	k.box(Vector3(0, b.y * 0.5 - 4.0, b.z + 1.05), Vector3(2.4, 2.4, 0.1), HOLE, "rubber")


static func _fuse_t(k: K, b: Vector3, o: Dictionary) -> void:
	k.box(Vector3(0, 0, 4.0), Vector3(b.x, b.y, 8.0), Color(0.12, 0.12, 0.13))
	for s in [-1.0, 1.0]:
		k.box(Vector3(s * 52.0, 0, 18.0), Vector3(22.0, 28.0, 20.0), Color(0.12, 0.12, 0.13))
		k.box(Vector3(s * 40.0, 0, 33.0), Vector3(30.0, 18.0, 3.0), ConnectorCatalog.C_BRASS, "metal")
		BattParts.threaded_stud(k.g, k.P(Vector3(s * 52.0, 0, 34.5)), k.D(Vector3.BACK), 10.0, 14.0, ConnectorCatalog.C_STEEL)
	k.turn(Vector3(-25.0, 0, 33.0), Vector3.RIGHT, [Vector2(0, 0), Vector2(10.0, 0), Vector2(10.0, 50.0), Vector2(0, 50.0)],
		Color(0.92, 0.9, 0.84), "plastic", 18)
	k.label("T %d A" % int(o.get("amps", 300)), Vector3(0, 0, 43.5), 5.0, ConnectorCatalog.C_BLACK)


static func _fuse_anl(k: K, b: Vector3, o: Dictionary) -> void:
	k.box(Vector3(0, 0, 8.0), Vector3(b.x, b.y, 16.0), Color(0.1, 0.1, 0.11))
	k.box(Vector3(0, 0, 18.0), Vector3(84.0, 20.0, 2.0), Color(0.8, 0.82, 0.84), "tin")
	k.box(Vector3(0, 0, 19.2), Vector3(22.0, 12.0, 0.4), Color(0.85, 0.85, 0.9, 1.0), "plastic")
	for s in [-1.0, 1.0]:
		BattParts.threaded_stud(k.g, k.P(Vector3(s * 38.0, 0, 19.0)), k.D(Vector3.BACK), 8.0, 14.0, ConnectorCatalog.C_STEEL)
	k.label("ANL %d" % int(o.get("amps", 200)), Vector3(0, -15.0, 16.2), 4.0)


# ---------------------------------------------------------------------------
# AC
# ---------------------------------------------------------------------------

static func _nema_face(k: K, c: Vector2, variant: String, top: float, col: Color) -> void:
	k.slab(rrect(34.0, 40.0, 7.0), top - 2.5, 2.5, col)
	k.hole_rect(Vector2(c.x - 6.35, c.y + 3.0), Vector2(2.0, 7.1), top)
	k.hole_rect(Vector2(c.x + 6.35, c.y + 3.0), Vector2(2.0, 8.7), top)
	if variant == "5-20":
		k.hole_rect(Vector2(c.x + 4.8, c.y + 3.0), Vector2(3.4, 2.0), top)
	k.hole_disc(Vector2(c.x, c.y - 8.5), 2.6, top)


static func _nema(k: K, b: Vector3, o: Dictionary) -> void:
	var col := _col(o.get("color"), Color(0.13, 0.13, 0.14))
	var variant := str(o.get("variant", "5-15"))
	if bool(o.get("duplex", false)):
		k.box(Vector3(0, 0, 1.0), Vector3(b.x, b.y, 2.0), col.darkened(0.1))
		if bool(o.get("gfci", false)):
			_nema_face(k, Vector2(0, 30.0), variant, b.z, col)
			_nema_face(k, Vector2(0, -30.0), variant, b.z, col)
			k.box(Vector3(0, 0, b.z - 0.5), Vector3(20.0, 8.0, 2.0), Color(0.12, 0.12, 0.13))
			k.label("TEST", Vector3(-6.0, 0, b.z + 0.6), 2.4)
			k.label("RESET", Vector3(6.0, 0, b.z + 0.6), 2.4)
		else:
			_nema_face(k, Vector2(0, 22.0), variant, b.z, col)
			_nema_face(k, Vector2(0, -22.0), variant, b.z, col)
	else:
		_nema_face(k, Vector2.ZERO, variant, b.z, col)
	k.box(Vector3(0, 0, -12.0), Vector3(b.x * 0.9, b.y * 0.8, 24.0), col.darkened(0.3))


static func _round_ac(k: K, b: Vector3, o: Dictionary) -> void:
	var col := _col(o.get("color"), Color(0.13, 0.13, 0.14))
	var r := b.x * 0.5
	var variant := str(o.get("variant", "l14_30"))
	k.turn(Vector3.ZERO, Vector3.BACK, [Vector2(0, 0), Vector2(r, 0), Vector2(r, b.z - 1.0), Vector2(r - 1.5, b.z),
		Vector2(0, b.z)], col, "plastic", 28)
	match variant:
		"schuko":
			k.disc(Vector3(0, 0, b.z - 0.1), Vector3.BACK, 19.0, 0.2, HOLE, "rubber", 24)
			for s in [-1.0, 1.0]:
				k.hole_disc(Vector2(s * 9.5, 0), 2.4, b.z + 0.1)
				k.box(Vector3(0, s * 18.0, b.z), Vector3(5.0, 1.5, 1.5), ConnectorCatalog.C_STEEL, "metal")
		"tt_30":
			for s in [-1.0, 1.0]:
				k.rbox(Vector3(s * 8.0, 4.0, b.z + 0.05), Basis(Vector3.BACK, s * deg_to_rad(30.0)), Vector3(2.4, 10.0, 0.1), HOLE, "rubber")
			k.hole_disc(Vector2(0, -10.0), 3.0, b.z)
		_:
			for a in [-60.0, 60.0, 180.0]:
				var ang := deg_to_rad(a)
				k.rbox(Vector3(sin(ang) * 11.0, cos(ang) * 11.0, b.z + 0.05), Basis(Vector3.BACK, -ang),
					Vector3(9.0, 2.2, 0.1), HOLE, "rubber")
			k.box(Vector3(0, 12.0, b.z + 0.05), Vector3(2.2, 6.0, 0.1), HOLE, "rubber")
	k.box(Vector3(0, 0, -12.0), Vector3(b.x * 0.7, b.y * 0.7, 24.0), col.darkened(0.3))


static func _bs1363(k: K, b: Vector3) -> void:
	var col := Color(0.92, 0.92, 0.9)
	k.slab(rrect(b.x, b.y, 3.0), 0.0, b.z, col)
	k.hole_rect(Vector2(0, 12.0), Vector2(4.0, 8.0), b.z)
	for s in [-1.0, 1.0]:
		k.hole_rect(Vector2(s * 11.0, -6.0), Vector2(7.0, 4.0), b.z)


static func _asnzs(k: K, b: Vector3) -> void:
	var col := Color(0.92, 0.92, 0.9)
	k.slab(rrect(b.x, b.y, 4.0), 0.0, b.z, col)
	for s in [-1.0, 1.0]:
		k.rbox(Vector3(s * 7.0, 3.0, b.z + 0.05), Basis(Vector3.BACK, s * deg_to_rad(30.0)), Vector3(2.0, 7.0, 0.1), HOLE, "rubber")
	k.hole_rect(Vector2(0, -8.0), Vector2(2.0, 7.0), b.z)


static func _iec(k: K, b: Vector3, o: Dictionary) -> void:
	var variant := str(o.get("variant", "c14"))
	var col := Color(0.08, 0.08, 0.09)
	k.slab(rrect(b.x + 8.0, b.y + 8.0, 2.0), 0.0, 1.5, col)
	var w := b.x
	var h := b.y
	var ol := [Vector2(-w * 0.5, -h * 0.5 + 4.0), Vector2(-w * 0.5 + 4.0, -h * 0.5), Vector2(w * 0.5 - 4.0, -h * 0.5),
		Vector2(w * 0.5, -h * 0.5 + 4.0), Vector2(w * 0.5, h * 0.5), Vector2(-w * 0.5, h * 0.5)]
	if variant.begins_with("c19") or variant.begins_with("c20"):
		ol = [Vector2(-w * 0.5, -h * 0.5), Vector2(w * 0.5, -h * 0.5), Vector2(w * 0.5, h * 0.5), Vector2(-w * 0.5, h * 0.5)]
	var inlet := variant == "c14" or variant == "c20"
	if inlet:
		k.slab(ol, 1.5, 0.15, HOLE, "rubber")
		for p in [Vector2(-7, -2), Vector2(7, -2), Vector2(0, 4)]:
			k.box(Vector3(p.x, p.y, 4.0), Vector3(1.6 if variant == "c14" else 5.0, 4.0 if variant == "c14" else 1.6, 6.0),
				Color(0.82, 0.8, 0.72), "metal")
	else:
		k.slab(ol, 1.5, b.z - 1.5, col)
		for p in [Vector2(-7, -2), Vector2(7, -2), Vector2(0, 4)]:
			k.hole_rect(p, Vector2(2.0, 4.5), b.z)


static func _rocker(k: K, b: Vector3, o: Dictionary) -> void:
	var col := _col(o.get("color"), Color(0.08, 0.08, 0.09))
	k.box(Vector3(0, 0, 1.0), Vector3(b.x, b.y, 2.0), col.darkened(0.1))
	k.rbox(Vector3(0, 0, 4.0), Basis(Vector3.RIGHT, deg_to_rad(12.0)), Vector3(b.x - 3.0, b.y - 3.0, 4.0), col)
	k.label("I", Vector3(0, 4.0, 6.3), 3.0)
	k.label("O", Vector3(0, -4.0, 5.2), 3.0)


static func _push_breaker(k: K, o: Dictionary) -> void:
	k.hexp(Vector3.ZERO, Vector3.BACK, 16.0, 3.0, 0.0, ConnectorCatalog.C_BLACK, "plastic")
	k.turn(Vector3(0, 0, 3.0), Vector3.BACK, [Vector2(0, 0), Vector2(6.5, 0), Vector2(6.5, 10.0), Vector2(0, 10.0)],
		ConnectorCatalog.C_BLACK, "plastic", 16)
	k.turn(Vector3(0, 0, 13.0), Vector3.BACK, [Vector2(0, 0), Vector2(4.5, 0), Vector2(4.5, 6.0), Vector2(3.5, 7.0),
		Vector2(0, 7.0)], Color(0.92, 0.92, 0.9), "plastic", 16)
	k.box(Vector3(0, 0, -15.0), Vector3(14.0, 20.0, 30.0), ConnectorCatalog.C_BLACK)
	k.label("%d" % int(o.get("amps", 20)), Vector3(0, 0, 20.1), 3.5, ConnectorCatalog.C_BLACK)


# ---------------------------------------------------------------------------
# Terminal strips, DIN gear, bus bars
# ---------------------------------------------------------------------------

static func _terminal_block(k: K, e: Dictionary, o: Dictionary) -> void:
	var b: Vector3 = e["body"]
	var n := (e["pins"] as Array).size()
	var pitch := b.x / float(maxi(n, 1))
	var col := _col(o.get("color"), ConnectorCatalog.C_GREEN_TB)
	for i in n:
		var x := (float(i) - float(n - 1) * 0.5) * pitch
		k.box(Vector3(x, 0, b.z * 0.5), Vector3(pitch - 0.25, b.y, b.z), col)
		# Screw on top (facing out), the wire entry on the lower face.
		var sr := pitch * 0.3
		k.disc(Vector3(x, b.y * 0.12, b.z), Vector3.BACK, sr, 0.6, ConnectorCatalog.C_STEEL, "metal", 14)
		k.box(Vector3(x, b.y * 0.12, b.z + 0.65), Vector3(sr * 1.6, sr * 0.3, 0.1), HOLE, "rubber")
		k.box(Vector3(x, -b.y * 0.5 - 0.05, b.z * 0.55), Vector3(pitch * 0.55, 0.1, b.z * 0.5), HOLE, "rubber")
		var lb := str((e["pins"][i] as Dictionary)["label"])
		k.label(lb, Vector3(x, b.y * 0.5 + maxf(2.5, pitch * 0.35), 0.2), clampf(pitch * 0.45, 2.0, 6.0))


static func _wago(k: K, e: Dictionary, _o: Dictionary) -> void:
	var b: Vector3 = e["body"]
	var n := (e["pins"] as Array).size()
	var pitch := b.x / float(maxi(n, 1))
	k.box(Vector3(0, 0, b.z * 0.5), Vector3(b.x, b.y, b.z), Color(0.78, 0.8, 0.82, 1.0))
	for i in n:
		var x := (float(i) - float(n - 1) * 0.5) * pitch
		k.box(Vector3(x, b.y * 0.5 + 1.0, b.z * 0.6), Vector3(pitch - 1.2, 2.0, b.z * 0.7), Color(0.95, 0.5, 0.1))
		k.hole_disc(Vector2(x, -b.y * 0.1), 1.6, b.z)


static func _din_rail(k: K, b: Vector3) -> void:
	var L := b.x
	var col := ConnectorCatalog.C_ZINC
	k.box(Vector3(0, 0, 0.5), Vector3(L, 27.0, 1.0), col, "metal")
	for s in [-1.0, 1.0]:
		k.box(Vector3(0, s * 13.0, 3.75), Vector3(L, 1.0, 7.5), col, "metal")
		k.box(Vector3(0, s * 15.25, 7.0), Vector3(L, 4.5, 1.0), col, "metal")
	var x := -L * 0.5 + 12.5
	while x < L * 0.5 - 5.0:
		k.box(Vector3(x, 0, 1.05), Vector3(15.0, 5.2, 0.1), HOLE, "rubber")
		x += 25.0


static func _din_breaker(k: K, _e: Dictionary, o: Dictionary) -> void:
	var n := clampi(int(o.get("poles", 2)), 1, 4)
	var w := 17.5 * float(n)
	var body := Color(0.93, 0.93, 0.92)
	var tog := _col(o.get("toggle"), Color(0.16, 0.32, 0.82))
	# Base (on the rail), the raised front, the shoulders with the screws.
	k.box(Vector3(0, 0, 29.0), Vector3(w - 0.4, 85.0, 58.0), body)
	k.box(Vector3(0, 0, 65.0), Vector3(w - 0.4, 45.0, 14.0), body)
	for i in n:
		var x := (float(i) - float(n - 1) * 0.5) * 17.5
		for s in [-1.0, 1.0]:
			k.disc(Vector3(x, s * 33.0, 58.0), Vector3.BACK, 3.0, 0.8, ConnectorCatalog.C_STEEL, "metal", 6)
			k.box(Vector3(x, s * 33.0, 58.85), Vector3(4.0, 0.8, 0.1), HOLE, "rubber")
			k.box(Vector3(x, s * 42.55, 40.0), Vector3(9.0, 0.1, 9.0), HOLE, "rubber")
		k.box(Vector3(x, 15.0, 72.05), Vector3(4.0, 3.0, 0.1), Color(0.15, 0.6, 0.25), "plastic")
	# One toggle across the poles (handle tie), down = off.
	var on := bool(o.get("on", true))
	k.rbox(Vector3(0, -6.0 if not on else 2.0, 76.0), Basis(Vector3.RIGHT, deg_to_rad(-25.0 if on else 25.0)),
		Vector3(w - 3.0, 14.0, 8.0), tog)
	var rating := "%s%d" % [str(o.get("curve", "C")), int(o.get("amps", 50))]
	k.label(rating, Vector3(0, -12.0, 72.1), 4.0, ConnectorCatalog.C_BLACK)
	k.label("line", Vector3(0, 39.0, 58.1), 2.6, ConnectorCatalog.C_BLACK)
	k.label("load", Vector3(0, -39.0, 58.1), 2.6, ConnectorCatalog.C_BLACK)
	var lb := str(o.get("label", ""))
	if lb != "":
		k.label(lb, Vector3(0, -50.0, 0.3), 5.0)


static func _bus_bar(k: K, e: Dictionary, o: Dictionary) -> void:
	var b: Vector3 = e["body"]
	var pins: Array = e["pins"]
	var lb := str(o.get("label", ""))
	var ins := Color(0.1, 0.1, 0.11) if lb != "N" else Color(0.12, 0.25, 0.65)
	if lb == "PE":
		ins = Color(0.15, 0.5, 0.2)
	for s in [-1.0, 1.0]:
		k.box(Vector3(s * (b.x * 0.5 - 4.0), 0, 4.0), Vector3(8.0, 12.0, 8.0), ins)
	k.box(Vector3(0, 0, 11.0), Vector3(b.x - 2.0, b.y, 6.0), ConnectorCatalog.C_BRASS, "metal")
	for p in pins:
		var x := ((p as Dictionary)["pos"] as Vector3).x
		k.disc(Vector3(x, 0, 14.0), Vector3.BACK, 2.6, 0.8, ConnectorCatalog.C_STEEL, "metal", 12)
		k.box(Vector3(x, 0, 14.85), Vector3(3.6, 0.7, 0.1), HOLE, "rubber")
		k.box(Vector3(x, -b.y * 0.5 - 0.05, 11.0), Vector3(3.2, 0.1, 3.2), HOLE, "rubber")
	if lb != "":
		k.label(lb, Vector3(0, -b.y * 0.5 - 8.0, 0.3), 7.0)


static func _ground_lug(k: K) -> void:
	var tin := Color(0.8, 0.8, 0.78)
	k.box(Vector3(0, 0, 1.0), Vector3(14.0, 12.0, 2.0), tin, "tin")
	k.box(Vector3(0, 0, 6.0), Vector3(10.0, 8.0, 8.0), tin, "tin")
	k.hole_rect(Vector2(0, -1.0), Vector2(6.0, 4.0), 10.0)
	k.disc(Vector3(0, 0, 10.0), Vector3.BACK, 3.0, 1.5, Color(0.2, 0.55, 0.25), "metal", 6)


# ---------------------------------------------------------------------------
# Data and I/O
# ---------------------------------------------------------------------------

static func _rj_jack(k: K, b: Vector3, o: Dictionary) -> void:
	k.box(Vector3(0, 0, b.z * 0.5), Vector3(b.x, b.y, b.z), Color(0.7, 0.72, 0.74), "metal")
	k.hole_rect(Vector2(0, -0.5), Vector2(b.x - 4.0, b.y - 4.5), b.z)
	k.box(Vector3(0, b.y * 0.5 - 2.6, b.z + 0.07), Vector3(4.0, 1.4, 0.1), HOLE, "rubber")
	if bool(o.get("leds", false)):
		k.box(Vector3(-b.x * 0.5 + 2.0, b.y * 0.5 - 1.2, b.z + 0.1), Vector3(2.0, 1.4, 0.2), Color(0.2, 0.85, 0.3))
		k.box(Vector3(b.x * 0.5 - 2.0, b.y * 0.5 - 1.2, b.z + 0.1), Vector3(2.0, 1.4, 0.2), Color(0.95, 0.65, 0.1))
	k.box(Vector3(0, 0, -10.0), Vector3(b.x, b.y, 20.0), Color(0.6, 0.62, 0.64), "metal")


## An RJ45 patch plug pushed into a port facing +Z, its boot behind it
## (moved from the Battery Lab's bank builder; same boxes).
static func _rj_plug(k: K, o: Dictionary) -> void:
	var boot := _col(o.get("boot"), Color(0.18, 0.42, 0.85))
	k.box(Vector3(0, 0, 9.0), Vector3(11.7, 8.0, 18.0), Color(0.85, 0.88, 0.9, 1.0), "plastic")
	k.box(Vector3(0, 0, 22.0), Vector3(13.0, 9.5, 12.0), boot, "rubber")
	k.box(Vector3(0, 4.6, 6.0), Vector3(6.0, 1.2, 9.0), Color(0.8, 0.82, 0.85), "plastic")


static func _usb(k: K, b: Vector3, o: Dictionary) -> void:
	var shell := Color(0.78, 0.8, 0.82)
	if str(o.get("kind", "a")) == "c":
		k.slab(rrect(b.x, b.y, b.y * 0.5, 5), 0.0, b.z, shell, "metal")
		k.slab(rrect(b.x - 1.2, b.y - 1.2, (b.y - 1.2) * 0.5, 5), b.z, 0.1, HOLE, "rubber")
		k.box(Vector3(0, 0, b.z + 0.15), Vector3(b.x * 0.62, 0.7, 0.1), Color(0.15, 0.15, 0.16))
	else:
		k.box(Vector3(0, 0, b.z * 0.5), Vector3(b.x, b.y, b.z), shell, "metal")
		k.hole_rect(Vector2.ZERO, Vector2(b.x - 1.0, b.y - 1.0), b.z)
		k.box(Vector3(0, b.y * 0.15, b.z + 0.15), Vector3(b.x - 2.6, b.y * 0.35, 0.1), Color(0.15, 0.3, 0.75))


static func _db9(k: K, b: Vector3) -> void:
	k.box(Vector3(0, 0, 0.5), Vector3(b.x, b.y + 6.0, 1.0), ConnectorCatalog.C_STEEL, "metal")
	var w0 := b.x * 0.55
	var w1 := b.x * 0.48
	var h := b.y * 0.6
	k.slab([Vector2(-w1 * 0.5, -h * 0.5), Vector2(w1 * 0.5, -h * 0.5), Vector2(w0 * 0.5, h * 0.5), Vector2(-w0 * 0.5, h * 0.5)],
		1.0, b.z - 1.0, ConnectorCatalog.C_STEEL, "metal")
	k.slab([Vector2(-w1 * 0.45, -h * 0.4), Vector2(w1 * 0.45, -h * 0.4), Vector2(w0 * 0.45, h * 0.4), Vector2(-w0 * 0.45, h * 0.4)],
		b.z, 0.1, HOLE, "rubber")
	for s in [-1.0, 1.0]:
		k.hexp(Vector3(s * b.x * 0.4, 0, 1.0), Vector3.BACK, 5.0, 4.0, 1.2, ConnectorCatalog.C_STEEL)


static func _ve_direct(k: K, b: Vector3) -> void:
	k.box(Vector3(0, 0, b.z * 0.5), Vector3(b.x, b.y, b.z), Color(0.92, 0.92, 0.9))
	k.hole_rect(Vector2(0, -0.4), Vector2(b.x - 1.6, b.y - 2.0), b.z)


static func _antenna(k: K, o: Dictionary) -> void:
	var L := float(o.get("length", 100.0))
	k.hexp(Vector3.ZERO, Vector3.BACK, 8.0, 3.0, 0.0, ConnectorCatalog.C_BRASS)
	k.turn(Vector3(0, 0, 3.0), Vector3.BACK, [Vector2(0, 0), Vector2(4.5, 0), Vector2(4.5, 8.0), Vector2(3.8, 9.0),
		Vector2(3.8, L - 3.0), Vector2(2.0, L), Vector2(0, L)], ConnectorCatalog.C_BLACK, "rubber", 14)


# ---------------------------------------------------------------------------
# Enclosure fittings
# ---------------------------------------------------------------------------

static func _gland(k: K, b: Vector3, o: Dictionary) -> void:
	var t := float(o.get("thread", 20.0))
	var col := _col(o.get("color"), ConnectorCatalog.C_BLACK)
	var af := t + 6.0
	k.hexp(Vector3.ZERO, Vector3.BACK, af, 4.0, 0.0, col, "plastic")
	k.turn(Vector3(0, 0, 4.0), Vector3.BACK, [Vector2(0, 0), Vector2(t * 0.55, 0), Vector2(t * 0.55, 3.0), Vector2(0, 3.0)],
		col.lightened(0.05), "plastic", 18)
	k.hexp(Vector3(0, 0, 7.0), Vector3.BACK, af - 2.0, b.z * 0.35, 0.0, col, "plastic")
	var top := 7.0 + b.z * 0.35
	k.turn(Vector3(0, 0, top), Vector3.BACK, [Vector2(0, 0), Vector2(af * 0.5, 0), Vector2(af * 0.42, (b.z - top) * 0.6),
		Vector2(t * 0.32, b.z - top), Vector2(0, b.z - top)], col, "plastic", 18)
	k.hole_disc(Vector2.ZERO, t * 0.25, b.z)
	# Locknut inside.
	k.hexp(Vector3(0, 0, -5.0), Vector3.BACK, af, 4.0, t * 0.5, col.lightened(0.04), "plastic")


static func _knockout(k: K, o: Dictionary) -> void:
	var trade := str(o.get("trade", "3/4"))
	var hole := float(ConnectorCatalog.KNOCKOUT_MM.get(trade, 28.6))
	var r := hole * 0.5
	var zinc := ConnectorCatalog.C_ZINC
	# Outside: the connector's body and the locknut (8 lugs).
	k.turn(Vector3.ZERO, Vector3.BACK, [Vector2(r - 1.0, 0), Vector2(r + 4.5, 0), Vector2(r + 4.5, 2.5),
		Vector2(r - 1.0, 2.5), Vector2(r - 1.0, 0)], zinc, "metal", 8, true)
	k.hexp(Vector3(0, 0, 2.5), Vector3.BACK, hole + 7.0, 7.0, r - 1.5, zinc)
	if bool(o.get("conduit", false)):
		var od := float(ConnectorCatalog.CONDUIT_OD.get(trade, 23.4))
		k.turn(Vector3(0, 0, 9.5), Vector3.BACK, [Vector2(od * 0.5 - 1.2, 0), Vector2(od * 0.5, 0), Vector2(od * 0.5, 60.0),
			Vector2(od * 0.5 - 1.2, 60.0), Vector2(od * 0.5 - 1.2, 0)], Color(0.72, 0.74, 0.76), "metal", 20)
	else:
		k.ring(Vector3(0, 0, 10.0), Vector3.BACK, r - 1.5, r - 3.0, 1.0, zinc, "metal", 20)
	# Inside: the plastic bushing with its lip.
	var bush := _col(o.get("bushing"), Color(0.62, 0.62, 0.64))
	k.turn(Vector3(0, 0, -7.0), Vector3.BACK, [Vector2(r - 3.5, 0), Vector2(r + 3.5, 0), Vector2(r + 3.5, 2.0),
		Vector2(r - 0.5, 2.5), Vector2(r - 0.5, 7.0), Vector2(r - 3.5, 7.0), Vector2(r - 3.5, 0)], bush, "plastic", 24)


# ---------------------------------------------------------------------------
# Front panel
# ---------------------------------------------------------------------------

static func _led(k: K, o: Dictionary) -> void:
	var d := float(o.get("d", 5.0))
	var col := _col(o.get("color"), Color(0.2, 0.9, 0.3))
	k.turn(Vector3.ZERO, Vector3.BACK, [Vector2(0, 0), Vector2(d * 0.5, 0), Vector2(d * 0.5, d * 0.3), Vector2(d * 0.35, d * 0.5),
		Vector2(0, d * 0.58)], col, "plastic", 12)


static func _lcd(k: K, o: Dictionary) -> void:
	var w := float(o.get("w", 70.0))
	var h := float(o.get("h", 45.0))
	var bezel := _col(o.get("bezel"), ConnectorCatalog.C_BLACK)
	var screen := _col(o.get("screen"), Color(0.16, 0.32, 0.62))
	if bool(o.get("round", false)):
		var r := sqrt(w * w + h * h) * 0.5 + 10.0
		k.disc(Vector3.ZERO, Vector3.BACK, r, 1.5, bezel, "plastic", 40)
		if o.has("ring"):
			k.ring(Vector3(0, 0, 1.6), Vector3.BACK, r + 1.5, r - 1.5, 0.6, _col(o["ring"], Color.ORANGE), "plastic", 40)
		k.box(Vector3(0, h * 0.2, 1.6), Vector3(w, h, 0.2), screen, "board")
	else:
		k.slab(rrect(w + 8.0, h + 8.0, 3.0), 0.0, 1.5, bezel)
		k.box(Vector3(0, 0, 1.6), Vector3(w, h, 0.2), screen, "board")


static func _button(k: K, o: Dictionary) -> void:
	var d := float(o.get("d", 8.0))
	var col := _col(o.get("color"), Color(0.12, 0.12, 0.13))
	if bool(o.get("round", true)):
		k.turn(Vector3.ZERO, Vector3.BACK, [Vector2(0, 0), Vector2(d * 0.5, 0), Vector2(d * 0.5, 2.0), Vector2(d * 0.42, 3.0),
			Vector2(0, 3.0)], col, "rubber", 16)
	else:
		k.box(Vector3(0, 0, 1.5), Vector3(d, d, 3.0), col, "rubber")


static func _dip(k: K, b: Vector3, o: Dictionary) -> void:
	var n := clampi(int(o.get("poles", 8)), 1, 12)
	var w := 2.54 * float(n) + 2.0
	k.box(Vector3(0, 0, b.z * 0.5), Vector3(w, b.y, b.z), Color(0.75, 0.12, 0.12))
	for i in n:
		var x := (float(i) - float(n - 1) * 0.5) * 2.54
		k.box(Vector3(x, 1.5, b.z + 0.4), Vector3(1.4, 2.4, 0.8), Color(0.95, 0.95, 0.94))

class_name GantryLabDetail
extends RefCounted

## The machine's PARTS as geometry — what the first draft drew as boxes,
## drawn as the things they are, after a high-detail Creality CR-10 S4 model
## (2040 rails, V-wheel plates, Tr8 screws on foot-mounted motors with
## couplers and brass nuts, GT2 pulleys and idlers, microswitch endstops, a
## V6-class hotend under a Bowden tube, a Y belt under the bed, corner
## brackets, rubber feet). Every emitter writes into a SurfaceTool keyed by
## MATERIAL (`sts[key]`), in a LOCAL frame whose origin is the part's seat
## and whose +Y is its axis, through the current `_xf` (set by `emit`). The
## builder turns the material keys into materials and the `spin` parts into
## their own nodes it can turn.
##
## Conventions (metres, local frame):
##   motor       the mounting FACE is at the origin, the shaft points +Y,
##               the body hangs along −Y.
##   pulley / idler / coupler / screw / wheel   revolve about +Y, seated at
##               the origin (a screw runs 0..len along +Y).
##   nut_tr8     flange face at the origin on top of the plate, body −Y.
##   endstop     PCB on the origin plane, switch on top (+Y), lever toward +X.
##   hotend      the nozzle TIP is the origin, +Y up, fan on +X, duct on −Z.
##   extruder    mount face at the origin, +Z out from the carriage, +Y up;
##               the Bowden tube leaves EXTRUDER_OUTLET going −Y.
##   bed         the WORK SURFACE is the origin plane (the tool's z = 0).
##   bracket_l   inside corner at the origin: one leg along +X, one up +Y.

const EXTRUDER_OUTLET := Vector3(0.0, -0.024, 0.012)
const EXTRUDER_INLET := Vector3(0.0, 0.026, 0.012)
const HOTEND_H := 0.062
const WHEEL_R := 0.012
const WHEEL_W := 0.0102
const GT2_PITCH_M := 0.002
const BELT_THICK := 0.0014

static var _xf := Transform3D.IDENTITY
static var _uv := Vector2.ZERO


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

## Draw one part dict into `sts` (material key → SurfaceTool). `local` draws
## the part at the origin in its own frame (how the spin nodes are built);
## otherwise it is seated at part.c with part.basis (identity by default).
static func emit(sts: Dictionary, part: Dictionary, local: bool = false) -> void:
	var c: Vector3 = part.get("c", Vector3.ZERO)
	var b: Basis = part.get("basis", Basis.IDENTITY)
	_xf = Transform3D.IDENTITY if local else Transform3D(b, c)
	match str(part["kind"]):
		"motor":
			_motor(sts, part)
		"pulley":
			_pulley(sts, part)
		"idler":
			_idler(sts, part)
		"coupler":
			_coupler(sts, part)
		"screw":
			_screw(sts, part)
		"nut_tr8":
			_nut_tr8(sts, part)
		"bearing_block":
			_bearing_block(sts, part)
		"endstop":
			_endstop(sts, part)
		"wheel":
			_wheel(sts, part)
		"wheel_axle":
			_wheel_axle(sts, part)
		"plate":
			_plate(sts, part)
		"outline_plate":
			_outline_plate(sts, part)
		"rail":
			_rail(sts, part)
		"rail_block":
			_rail_block(sts, part)
		"rod":
			_rod(sts, part)
		"lm8uu":
			_lm8uu(sts, part)
		"sk_support":
			_sk_support(sts, part)
		"flange_bearing":
			_flange_bearing(sts, part)
		"hotend":
			_hotend(sts, part)
		"extruder":
			_extruder(sts, part)
		"spindle":
			_spindle(sts, part)
		"laser":
			_laser(sts, part)
		"pen":
			_pen(sts, part)
		"clay_extruder":
			_clay_extruder(sts, part)
		"pellet_extruder":
			_pellet_extruder(sts, part)
		"fan":
			_fan(sts, part)
		"psu":
			_psu(sts, part)
		"lcd":
			_lcd(sts, part)
		"board":
			_board(sts, part)
		"foot":
			_foot(sts, part)
		"corner_bracket":
			_corner_bracket(sts, part)
		"bracket_l":
			_bracket_l(sts, part)
		"spring_knob":
			_spring_knob(sts, part)
		"bed":
			_bed(sts, part)
		"spool":
			_spool(sts, part)
		"effector":
			_effector(sts, part)
		"rod_end":
			_rod_end(sts, part)
		"belt_clamp":
			_belt_clamp(sts, part)
		"fastener_bolt":
			_fastener_bolt(sts, part)
		"fastener_nut":
			_fastener_nut(sts, part)
		"fastener_tnut":
			_fastener_tnut(sts, part)
		"fastener_washer":
			_fastener_washer(sts, part)
		"fastener_spacer":
			_fastener_spacer(sts, part)
		"box":
			box(_st(sts, str(part.get("mat", "black"))), Vector3.ZERO, part["s"])
		"panel":
			box(_st(sts, "panel"), Vector3.ZERO, part["s"])
		"tool":
			_tool_block(sts, part)
		"bed_round":
			_bed_round(sts, part)
		_:
			box(_st(sts, "black"), Vector3.ZERO, part.get("s", Vector3(0.02, 0.02, 0.02)))
	_xf = Transform3D.IDENTITY


static func _st(sts: Dictionary, key: String) -> SurfaceTool:
	if not sts.has(key):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		sts[key] = st
	return sts[key]


## A right-handed frame whose +Y is `axis`; `ref` picks the +Z direction when
## it is not parallel to the axis.
static func basis_y(axis: Vector3, ref: Vector3 = Vector3.FORWARD) -> Basis:
	var y := axis.normalized()
	if y.length() < 1e-6:
		y = Vector3.UP
	var r := ref
	if absf(r.normalized().dot(y)) > 0.95:
		r = Vector3.UP if absf(y.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
	var x := r.cross(y).normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


## A frame with +Y = `y` and +Z as close to `z` as the right angle allows.
static func basis_yz(y: Vector3, z: Vector3) -> Basis:
	var yy := y.normalized()
	var zz := (z - yy * z.dot(yy)).normalized()
	if zz.length() < 1e-6:
		return basis_y(yy)
	var xx := yy.cross(zz).normalized()
	return Basis(xx, yy, zz)


# ---------------------------------------------------------------------------
# Primitives (all through _xf; Godot's front face winds clockwise from outside)
# ---------------------------------------------------------------------------

static func tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, n: Vector3, uv0: Vector2 = Vector2.ZERO, uv1: Vector2 = Vector2.ZERO, uv2: Vector2 = Vector2.ZERO) -> void:
	var q0 := _xf * p0
	var q1 := _xf * p1
	var q2 := _xf * p2
	var nn := (_xf.basis * n).normalized()
	var g := (q1 - q0).cross(q2 - q0)
	if g.dot(nn) > 0.0:
		var tmp := q1
		q1 = q2
		q2 = tmp
		var tuv := uv1
		uv1 = uv2
		uv2 = tuv
	st.set_normal(nn)
	st.set_uv(uv0)
	st.add_vertex(q0)
	st.set_normal(nn)
	st.set_uv(uv1)
	st.add_vertex(q1)
	st.set_normal(nn)
	st.set_uv(uv2)
	st.add_vertex(q2)


static func quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, uv0: Vector2 = Vector2.ZERO, uv1: Vector2 = Vector2.ZERO, uv2: Vector2 = Vector2.ZERO, uv3: Vector2 = Vector2.ZERO) -> void:
	tri(st, p0, p1, p2, n, uv0, uv1, uv2)
	tri(st, p0, p2, p3, n, uv0, uv2, uv3)


static func box(st: SurfaceTool, c: Vector3, s: Vector3) -> void:
	var h := s * 0.5
	var p := [c + Vector3(-h.x, -h.y, -h.z), c + Vector3(h.x, -h.y, -h.z), c + Vector3(h.x, h.y, -h.z), c + Vector3(-h.x, h.y, -h.z),
		c + Vector3(-h.x, -h.y, h.z), c + Vector3(h.x, -h.y, h.z), c + Vector3(h.x, h.y, h.z), c + Vector3(-h.x, h.y, h.z)]
	quad(st, p[0], p[1], p[2], p[3], Vector3(0, 0, -1))
	quad(st, p[5], p[4], p[7], p[6], Vector3(0, 0, 1))
	quad(st, p[4], p[0], p[3], p[7], Vector3(-1, 0, 0))
	quad(st, p[1], p[5], p[6], p[2], Vector3(1, 0, 0))
	quad(st, p[3], p[2], p[6], p[7], Vector3(0, 1, 0))
	quad(st, p[4], p[5], p[1], p[0], Vector3(0, -1, 0))


## A box whose span is given by its two extreme corners.
static func box_ab(st: SurfaceTool, a: Vector3, b: Vector3) -> void:
	box(st, (a + b) * 0.5, (b - a).abs())


## Extrude a counter-clockwise outline in the local XZ plane from y0 to y1.
static func prism(st: SurfaceTool, outline: PackedVector2Array, y0: float, y1: float, caps: bool = true) -> void:
	var n := outline.size()
	if n < 3:
		return
	for i in n:
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % n]
		var e := b - a
		var nrm := Vector3(e.y, 0.0, -e.x).normalized()
		quad(st, Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y), nrm)
	if not caps:
		return
	var tris := Geometry2D.triangulate_polygon(outline)
	for t in range(0, tris.size() - 2, 3):
		var c0: Vector2 = outline[tris[t]]
		var c1: Vector2 = outline[tris[t + 1]]
		var c2: Vector2 = outline[tris[t + 2]]
		tri(st, Vector3(c0.x, y0, c0.y), Vector3(c1.x, y0, c1.y), Vector3(c2.x, y0, c2.y), Vector3.DOWN)
		tri(st, Vector3(c0.x, y1, c0.y), Vector3(c2.x, y1, c2.y), Vector3(c1.x, y1, c1.y), Vector3.UP)


## A rectangle outline with chamfered corners (x by z, chamfer k).
static func rect_outline(w: float, d: float, k: float = 0.0) -> PackedVector2Array:
	var hw := w * 0.5
	var hd := d * 0.5
	var kk := clampf(k, 0.0, minf(hw, hd) * 0.9)
	if kk <= 0.0:
		return PackedVector2Array([Vector2(-hw, -hd), Vector2(hw, -hd), Vector2(hw, hd), Vector2(-hw, hd)])
	return PackedVector2Array([Vector2(-hw + kk, -hd), Vector2(hw - kk, -hd), Vector2(hw, -hd + kk), Vector2(hw, hd - kk),
		Vector2(hw - kk, hd), Vector2(-hw + kk, hd), Vector2(-hw, hd - kk), Vector2(-hw, -hd + kk)])


static func ngon_outline(r: float, sides: int, rot: float = 0.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in sides:
		var a := rot + TAU * float(i) / float(sides)
		out.append(Vector2(cos(a) * r, sin(a) * r))
	return out


## Revolve a profile of (radius, y) points about +Y; flat per-segment
## normals; UV = (angle / TAU, y) when `uv` is on (the thread shader's frame).
static func lathe(st: SurfaceTool, prof: PackedVector2Array, sides: int, uv: bool = false) -> void:
	var m := prof.size()
	if m < 2:
		return
	for i in m - 1:
		var p0: Vector2 = prof[i]
		var p1: Vector2 = prof[i + 1]
		var dr := p1.x - p0.x
		var dy := p1.y - p0.y
		var n2 := Vector2(dy, -dr).normalized()
		if n2.length() < 1e-6:
			continue
		for k in sides:
			var a0 := TAU * float(k) / float(sides)
			var a1 := TAU * float(k + 1) / float(sides)
			var c0 := Vector3(cos(a0), 0.0, sin(a0))
			var c1 := Vector3(cos(a1), 0.0, sin(a1))
			var u0 := float(k) / float(sides)
			var u1 := float(k + 1) / float(sides)
			var q00 := c0 * p0.x + Vector3(0, p0.y, 0)
			var q01 := c1 * p0.x + Vector3(0, p0.y, 0)
			var q10 := c0 * p1.x + Vector3(0, p1.y, 0)
			var q11 := c1 * p1.x + Vector3(0, p1.y, 0)
			var nm := (c0 + c1).normalized() * n2.x + Vector3(0, n2.y, 0)
			if p0.x <= 1e-7:
				tri(st, q00, q11, q10, nm, Vector2(u0, p0.y) if uv else Vector2.ZERO, Vector2(u1, p1.y) if uv else Vector2.ZERO, Vector2(u0, p1.y) if uv else Vector2.ZERO)
			elif p1.x <= 1e-7:
				tri(st, q00, q01, q10, nm, Vector2(u0, p0.y) if uv else Vector2.ZERO, Vector2(u1, p0.y) if uv else Vector2.ZERO, Vector2(u0, p1.y) if uv else Vector2.ZERO)
			else:
				quad(st, q00, q01, q11, q10, nm, Vector2(u0, p0.y) if uv else Vector2.ZERO, Vector2(u1, p0.y) if uv else Vector2.ZERO, Vector2(u1, p1.y) if uv else Vector2.ZERO, Vector2(u0, p1.y) if uv else Vector2.ZERO)


## A cylinder from y0 to y1 about +Y.
static func cyl_y(st: SurfaceTool, y0: float, y1: float, r: float, sides: int = 16, uv: bool = false) -> void:
	lathe(st, PackedVector2Array([Vector2(0, y0), Vector2(r, y0), Vector2(r, y1), Vector2(0, y1)]), sides, uv)


## A cylinder between two points in the current frame.
static func cyl(st: SurfaceTool, a: Vector3, b: Vector3, r: float, sides: int = 12) -> void:
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	var saved := _xf
	_xf = saved * Transform3D(basis_y(axis / L), a)
	cyl_y(st, 0.0, L, r, sides)
	_xf = saved


static func sphere(st: SurfaceTool, c: Vector3, r: float, sides: int = 10, rings: int = 6) -> void:
	var prof := PackedVector2Array()
	for i in rings + 1:
		var t := PI * float(i) / float(rings)
		prof.append(Vector2(sin(t) * r, -cos(t) * r))
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, c)
	lathe(st, prof, sides)
	_xf = saved


## A rectangular bar between two points (w across, t thick, up-ish = +Y).
static func bar(st: SurfaceTool, a: Vector3, b: Vector3, w: float, t: float) -> void:
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	var saved := _xf
	_xf = saved * Transform3D(basis_y(axis / L), a)
	prism(st, rect_outline(w, t), 0.0, L)
	_xf = saved


## A tube swept along a polyline with parallel-transport frames.
static func tube(st: SurfaceTool, pts: PackedVector3Array, r: float, sides: int = 8) -> void:
	var n := pts.size()
	if n < 2:
		return
	var frames: Array = []
	var t0 := (pts[1] - pts[0]).normalized()
	var ref := Vector3.UP if absf(t0.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	var u := (ref - t0 * ref.dot(t0)).normalized()
	for i in n:
		var t: Vector3
		if i == 0:
			t = (pts[1] - pts[0]).normalized()
		elif i == n - 1:
			t = (pts[n - 1] - pts[n - 2]).normalized()
		else:
			t = ((pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()).normalized()
			if t.length() < 1e-6:
				t = (pts[i + 1] - pts[i]).normalized()
		u = (u - t * u.dot(t)).normalized()
		if u.length() < 1e-6:
			u = (ref - t * ref.dot(t)).normalized()
		frames.append([u, t.cross(u).normalized()])
	for i in n - 1:
		var ua: Vector3 = frames[i][0]
		var va: Vector3 = frames[i][1]
		var ub: Vector3 = frames[i + 1][0]
		var vb: Vector3 = frames[i + 1][1]
		for k in sides:
			var a0 := TAU * float(k) / float(sides)
			var a1 := TAU * float(k + 1) / float(sides)
			var ra0 := ua * cos(a0) + va * sin(a0)
			var ra1 := ua * cos(a1) + va * sin(a1)
			var rb0 := ub * cos(a0) + vb * sin(a0)
			var rb1 := ub * cos(a1) + vb * sin(a1)
			quad(st, pts[i] + ra0 * r, pts[i] + ra1 * r, pts[i + 1] + rb1 * r, pts[i + 1] + rb0 * r, (ra0 + ra1 + rb0 + rb1).normalized())
	# Caps.
	var f0: Array = frames[0]
	var fn: Array = frames[n - 1]
	var ta := (pts[1] - pts[0]).normalized()
	var tb := (pts[n - 1] - pts[n - 2]).normalized()
	for k in sides:
		var a0 := TAU * float(k) / float(sides)
		var a1 := TAU * float(k + 1) / float(sides)
		tri(st, pts[0], pts[0] + (f0[0] * cos(a1) + f0[1] * sin(a1)) * r, pts[0] + (f0[0] * cos(a0) + f0[1] * sin(a0)) * r, -ta)
		tri(st, pts[n - 1], pts[n - 1] + (fn[0] * cos(a0) + fn[1] * sin(a0)) * r, pts[n - 1] + (fn[0] * cos(a1) + fn[1] * sin(a1)) * r, tb)


## A flat ribbon along a closed loop: `w` wide along `n`, `t` thick in the
## loop plane; UV.x = arc length (m), UV.y = the face (0 inside, 1 back,
## 2 edges) — the belt shader's frame. `inside` says which side of the loop
## the pulleys are on (+1: the loop's left normal points at them).
static func ribbon(st: SurfaceTool, pts: PackedVector3Array, n: Vector3, w: float, t: float, inside: float = 1.0) -> void:
	var m := pts.size()
	if m < 2:
		return
	var nn := n.normalized()
	var arc := 0.0
	var arcs := PackedFloat32Array()
	for i in m:
		arcs.append(arc)
		if i < m - 1:
			arc += pts[i].distance_to(pts[i + 1])
	for i in m - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var d := (b - a).normalized()
		if d.length() < 1e-6:
			continue
		var left := nn.cross(d).normalized() * inside  # toward the pulleys
		var hw := nn * (w * 0.5)
		var ht := left * (t * 0.5)
		var ua := arcs[i]
		var ub := arcs[i + 1]
		# Inside face (toward the pulleys).
		quad(st, a + ht - hw, b + ht - hw, b + ht + hw, a + ht + hw, left, Vector2(ua, 0.1), Vector2(ub, 0.1), Vector2(ub, 0.9), Vector2(ua, 0.9))
		# Back face.
		quad(st, a - ht - hw, a - ht + hw, b - ht + hw, b - ht - hw, -left, Vector2(ua, 1.1), Vector2(ua, 1.9), Vector2(ub, 1.9), Vector2(ub, 1.1))
		# Edges.
		quad(st, a + hw + ht, b + hw + ht, b + hw - ht, a + hw - ht, nn, Vector2(ua, 2.1), Vector2(ub, 2.1), Vector2(ub, 2.9), Vector2(ua, 2.9))
		quad(st, a - hw - ht, b - hw - ht, b - hw + ht, a - hw + ht, -nn, Vector2(ua, 2.1), Vector2(ub, 2.1), Vector2(ub, 2.9), Vector2(ua, 2.9))


## A V-slot extrusion between a and b: the profile's rectangle with a 6 mm
## groove every 20 mm cell on every face (and the open channel of a C-Beam).
static func extrusion(st: SurfaceTool, a: Vector3, b: Vector3, profile_id: String, up: Vector3 = Vector3.UP) -> void:
	var p := GantryLabParts.profile(profile_id)
	var w := float(p["w_mm"]) * 0.001
	var h := float(p["h_mm"]) * 0.001
	var axis := b - a
	var L := axis.length()
	if L < 1e-6:
		return
	axis /= L
	var u := up - axis * up.dot(axis)
	if u.length() < 1e-6:
		u = Vector3.FORWARD - axis * Vector3.FORWARD.dot(axis)
	if u.length() < 1e-6:
		u = Vector3.RIGHT
	u = u.normalized()
	var v := axis.cross(u).normalized()
	var outline := vslot_outline(w, h, profile_id == "c_beam_4080")
	var n := outline.size()
	for i in n:
		var p0: Vector2 = outline[i]
		var p1: Vector2 = outline[(i + 1) % n]
		var e := p1 - p0
		var nrm2 := Vector2(e.y, -e.x).normalized()
		var nrm := (v * nrm2.x + u * nrm2.y).normalized()
		var q0 := a + v * p0.x + u * p0.y
		var q1 := a + v * p1.x + u * p1.y
		quad(st, q0, q0 + axis * L, q1 + axis * L, q1, nrm)
	var tris := Geometry2D.triangulate_polygon(outline)
	for t in range(0, tris.size() - 2, 3):
		var c0: Vector2 = outline[tris[t]]
		var c1: Vector2 = outline[tris[t + 1]]
		var c2: Vector2 = outline[tris[t + 2]]
		tri(st, a + v * c0.x + u * c0.y, a + v * c1.x + u * c1.y, a + v * c2.x + u * c2.y, -axis)
		tri(st, b + v * c0.x + u * c0.y, b + v * c2.x + u * c2.y, b + v * c1.x + u * c1.y, axis)


static func vslot_outline(w: float, h: float, c_channel: bool = false) -> PackedVector2Array:
	var slot_w := 0.0062
	var slot_d := 0.0055
	var out := PackedVector2Array()
	var hw := w * 0.5
	var hh := h * 0.5
	var cells_w := maxi(1, int(round(w / 0.02)))
	var cells_h := maxi(1, int(round(h / 0.02)))
	# Walk counter-clockwise: bottom (y = -hh) left→right, right up, top
	# right→left, left down; a groove per 20 mm cell on each face.
	out.append(Vector2(-hw, -hh))
	for i in cells_w:
		var cx := -hw + 0.02 * (i + 0.5)
		out.append(Vector2(cx - slot_w * 0.5, -hh))
		out.append(Vector2(cx - slot_w * 0.5, -hh + slot_d))
		out.append(Vector2(cx + slot_w * 0.5, -hh + slot_d))
		out.append(Vector2(cx + slot_w * 0.5, -hh))
	out.append(Vector2(hw, -hh))
	for i in cells_h:
		var cy := -hh + 0.02 * (i + 0.5)
		out.append(Vector2(hw, cy - slot_w * 0.5))
		out.append(Vector2(hw - slot_d, cy - slot_w * 0.5))
		out.append(Vector2(hw - slot_d, cy + slot_w * 0.5))
		out.append(Vector2(hw, cy + slot_w * 0.5))
	out.append(Vector2(hw, hh))
	if c_channel:
		# The C-Beam's open channel: a 20 mm wide, 20 mm deep slot in the top face.
		out.append(Vector2(0.01, hh))
		out.append(Vector2(0.01, hh - 0.02))
		out.append(Vector2(-0.01, hh - 0.02))
		out.append(Vector2(-0.01, hh))
	else:
		for i in cells_w:
			var cx := hw - 0.02 * (i + 0.5)
			out.append(Vector2(cx + slot_w * 0.5, hh))
			out.append(Vector2(cx + slot_w * 0.5, hh - slot_d))
			out.append(Vector2(cx - slot_w * 0.5, hh - slot_d))
			out.append(Vector2(cx - slot_w * 0.5, hh))
	out.append(Vector2(-hw, hh))
	for i in cells_h:
		var cy := hh - 0.02 * (i + 0.5)
		out.append(Vector2(-hw, cy + slot_w * 0.5))
		out.append(Vector2(-hw + slot_d, cy + slot_w * 0.5))
		out.append(Vector2(-hw + slot_d, cy - slot_w * 0.5))
		out.append(Vector2(-hw, cy - slot_w * 0.5))
	return out


static func _hex_bolt_head(st: SurfaceTool, c: Vector3, r: float, h: float) -> void:
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, c)
	prism(st, ngon_outline(r, 6), 0.0, h)
	_xf = saved


## A socket-cap bolt head standing on the local y = y0 plane at (x, z).
static func _cap_head(st: SurfaceTool, c: Vector3, r: float = 0.0043, h: float = 0.0045) -> void:
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, c)
	lathe(st, PackedVector2Array([Vector2(0, 0), Vector2(r, 0), Vector2(r, h * 0.8), Vector2(r * 0.8, h), Vector2(r * 0.42, h), Vector2(r * 0.42, h - 0.0015), Vector2(0, h - 0.0015)]), 10)
	_xf = saved


# ---------------------------------------------------------------------------
# Motion parts
# ---------------------------------------------------------------------------

static func _motor(sts: Dictionary, p: Dictionary) -> void:
	var frame := float(p.get("frame", 0.042))
	var len := float(p.get("len", 0.04))
	var black := _st(sts, "motor")
	var chrome := _st(sts, "chrome")
	var alu := _st(sts, "alu")
	# The body: a chamfered square prism hanging below the mounting face, with
	# the end caps a shade lighter (aluminium) between black laminations.
	var k := frame * 0.12
	var cap := minf(0.009, len * 0.25)
	prism(alu, rect_outline(frame, frame, k), -cap, 0.0)
	prism(black, rect_outline(frame * 0.985, frame * 0.985, k), -len + cap, -cap)
	prism(alu, rect_outline(frame, frame, k), -len, -len + cap)
	# Pilot boss and the D-shaft.
	cyl_y(alu, 0.0, 0.002, frame * 0.26, 16)
	cyl_y(chrome, 0.0, float(p.get("shaft", 0.024)), 0.0025 if frame < 0.05 else 0.004, 10)
	# Four mounting bolts and the wiring connector on the back.
	var bx := frame * 0.37
	if bool(p.get("bolts", true)):
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				_cap_head(chrome, Vector3(sx * bx, 0.0, sz * bx), 0.0028, 0.003)
	box(black, Vector3(frame * 0.5 + 0.004, -len + 0.012, 0.0), Vector3(0.008, 0.012, 0.016))


static func gt2_pitch_radius(teeth: int) -> float:
	return float(teeth) * GT2_PITCH_M / TAU


static func _pulley(sts: Dictionary, p: Dictionary) -> void:
	var teeth := int(p.get("teeth", 20))
	var w := float(p.get("belt_w", 0.006)) + 0.002
	var r := gt2_pitch_radius(teeth) - 0.00025
	var alu := _st(sts, "alu")
	var steel := _st(sts, "steel")
	# Hub with its grub screw, bottom flange, the toothed ring, top flange.
	var y0 := float(p.get("y0", 0.004))
	cyl_y(alu, y0 - 0.007, y0, 0.0062, 14)
	box(steel, Vector3(0.0055, y0 - 0.0035, 0.0), Vector3(0.003, 0.002, 0.002))
	var fr := r + 0.0018
	cyl_y(alu, y0, y0 + 0.001, fr, 20)
	var outline := PackedVector2Array()
	for i in teeth:
		var a0 := TAU * float(i) / float(teeth)
		var a1 := TAU * (float(i) + 0.5) / float(teeth)
		var r_root := r - 0.00075
		outline.append(Vector2(cos(a0) * r_root, sin(a0) * r_root))
		outline.append(Vector2(cos(a0 + 0.12 / teeth * TAU) * r, sin(a0 + 0.12 / teeth * TAU) * r))
		outline.append(Vector2(cos(a1) * r, sin(a1) * r))
		outline.append(Vector2(cos(a1 + 0.12 / teeth * TAU) * r_root, sin(a1 + 0.12 / teeth * TAU) * r_root))
	prism(alu, outline, y0 + 0.001, y0 + 0.001 + w, false)
	cyl_y(alu, y0 + 0.001 + w, y0 + 0.002 + w, fr, 20)
	# Bore cap so the top reads closed.
	cyl_y(steel, y0 + 0.002 + w - 0.0005, y0 + 0.0025 + w, 0.0025, 8)


static func _idler(sts: Dictionary, p: Dictionary) -> void:
	var r := float(p.get("r", 0.006))
	var w := float(p.get("belt_w", 0.006)) + 0.002
	var alu := _st(sts, "alu")
	var chrome := _st(sts, "chrome")
	var y0 := float(p.get("y0", 0.0))
	# A bolt through the idler: head below, nut above, flanged wheel between.
	if not bool(p.get("no_bolt", false)):
		cyl_y(chrome, y0 - float(p.get("bolt_down", 0.006)), y0 + w + 0.002 + 0.004, 0.0025, 8)
		_hex_bolt_head(chrome, Vector3(0, y0 - float(p.get("bolt_down", 0.006)) - 0.003, 0), 0.0042, 0.003)
		_hex_bolt_head(chrome, Vector3(0, y0 + w + 0.002, 0), 0.0042, 0.0025)
	cyl_y(alu, y0, y0 + 0.001, r + 0.0018, 18)
	cyl_y(alu, y0 + 0.001, y0 + 0.001 + w, r, 18)
	cyl_y(alu, y0 + 0.001 + w, y0 + 0.002 + w, r + 0.0018, 18)


static func _coupler(sts: Dictionary, p: Dictionary) -> void:
	var len := float(p.get("len", 0.025))
	var r := float(p.get("d", 0.019)) * 0.5
	var st := _st(sts, "coupler")
	lathe(st, PackedVector2Array([Vector2(0, 0), Vector2(r, 0), Vector2(r, len), Vector2(0, len)]), 16, true)
	var steel := _st(sts, "steel")
	box(steel, Vector3(r + 0.0005, len * 0.18, 0.0), Vector3(0.002, 0.0025, 0.0025))
	box(steel, Vector3(-r - 0.0005, len * 0.82, 0.0), Vector3(0.002, 0.0025, 0.0025))


static func _screw(sts: Dictionary, p: Dictionary) -> void:
	var len := float(p.get("len", 0.3))
	var r := float(p.get("d_mm", 8.0)) * 0.0005
	var key := "thread|%.4f|%d" % [float(p.get("lead_mm", 8.0)) * 0.001, int(p.get("starts", 4))]
	var st := _st(sts, key)
	lathe(st, PackedVector2Array([Vector2(0, 0), Vector2(r, 0), Vector2(r, len), Vector2(0, len)]), 14, true)


static func _nut_tr8(sts: Dictionary, p: Dictionary) -> void:
	var brass := _st(sts, "brass")
	var body_r := float(p.get("body_r", 0.0051))
	cyl_y(brass, 0.0, 0.0035, 0.011, 16)
	cyl_y(brass, -float(p.get("body", 0.0115)), 0.0, body_r, 12)
	var chrome := _st(sts, "chrome")
	if bool(p.get("no_bolts", false)):
		return
	for i in 4:
		var a := TAU * float(i) / 4.0 + PI * 0.25
		_cap_head(chrome, Vector3(cos(a) * 0.008, 0.0035, sin(a) * 0.008), 0.0025, 0.0028)


static func _bearing_block(sts: Dictionary, p: Dictionary) -> void:
	var alu := _st(sts, "alu")
	var chrome := _st(sts, "chrome")
	# KFL08 flange: a diamond plate with the bearing housing on it.
	prism(alu, PackedVector2Array([Vector2(-0.027, 0), Vector2(0, -0.011), Vector2(0.027, 0), Vector2(0, 0.011)]), 0.0, 0.004)
	cyl_y(alu, 0.004, 0.012, 0.011, 14)
	cyl_y(chrome, 0.012, 0.013, 0.0065, 10)
	for sx in [-1.0, 1.0]:
		_cap_head(chrome, Vector3(sx * 0.019, 0.004, 0.0), 0.0025, 0.0028)


static func _endstop(sts: Dictionary, p: Dictionary) -> void:
	var pcb := _st(sts, "pcb")
	var black := _st(sts, "black")
	var chrome := _st(sts, "chrome")
	var red := _st(sts, "led")
	box(pcb, Vector3(0.0, 0.0008, 0.0), Vector3(0.02, 0.0016, 0.015))
	box(black, Vector3(-0.002, 0.0016 + 0.003, 0.0), Vector3(0.0128, 0.006, 0.0058))
	# The lever: hinged at the switch's far end, rising toward +X.
	var saved := _xf
	_xf = saved * Transform3D(Basis(Vector3.FORWARD, deg_to_rad(14.0)), Vector3(-0.0084, 0.0076, 0.0))
	box(chrome, Vector3(0.0085, 0.0, 0.0), Vector3(0.017, 0.0005, 0.0038))
	_xf = saved
	box(red, Vector3(0.007, 0.0016 + 0.0008, -0.0055), Vector3(0.002, 0.0016, 0.0012))
	box(black, Vector3(0.0075, 0.0016 + 0.0025, 0.0045), Vector3(0.006, 0.005, 0.004))
	for sx in [-1.0, 1.0]:
		_cap_head(chrome, Vector3(sx * 0.0078, 0.0016, sx * 0.0045), 0.0018, 0.002)


static func _wheel(sts: Dictionary, p: Dictionary) -> void:
	var r := float(p.get("r", WHEEL_R))
	var w := float(p.get("w", WHEEL_W))
	var delrin := _st(sts, "delrin")
	var chrome := _st(sts, "chrome")
	var hw := w * 0.5
	var g := r - 0.0026  # groove bottom radius
	# The V: edges at the full radius, the groove in the middle, bore each side.
	lathe(delrin, PackedVector2Array([Vector2(0.006, -hw), Vector2(r, -hw), Vector2(r, -hw + 0.0024), Vector2(g, 0.0),
		Vector2(r, hw - 0.0024), Vector2(r, hw), Vector2(0.006, hw)]), 18)
	lathe(chrome, PackedVector2Array([Vector2(0.0, -hw + 0.0002), Vector2(0.0062, -hw + 0.0002), Vector2(0.0062, hw - 0.0002), Vector2(0.0, hw - 0.0002)]), 10)


## The bolt, the precision shim and the eccentric spacer a wheel turns on:
## along +Y through the wheel's centre, the head on the far (−Y) side and
## the spacer between the wheel and the plate on +Y.
static func _wheel_axle(sts: Dictionary, p: Dictionary) -> void:
	var w := float(p.get("w", WHEEL_W))
	var plate_gap := float(p.get("gap", 0.006))
	var chrome := _st(sts, "chrome")
	var alu := _st(sts, "alu")
	cyl_y(chrome, -w * 0.5 - 0.004, w * 0.5 + plate_gap + float(p.get("plate", 0.006)) + 0.003, 0.0025, 8)
	_cap_head(chrome, Vector3(0, -w * 0.5 - 0.0045, 0), 0.0042, 0.0045)
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, Vector3(0, w * 0.5, 0))
	prism(alu if bool(p.get("eccentric", false)) else chrome, ngon_outline(0.0045, 6), 0.0, plate_gap)
	_xf = saved
	_hex_bolt_head(chrome, Vector3(0, w * 0.5 + plate_gap + float(p.get("plate", 0.006)), 0), 0.004, 0.003)


static func _plate(sts: Dictionary, p: Dictionary) -> void:
	var s: Vector3 = p["s"]
	var st := _st(sts, str(p.get("mat", "plate")))
	prism(st, rect_outline(s.x, s.z, float(p.get("chamfer", 0.004))), -s.y * 0.5, s.y * 0.5)


## A flat part cut from an outline (part-local x, z), `t` thick from y = 0
## up: the holes, the motor pilot (`pilot` = x, z, r) and the slots (centre,
## size in x, z) drawn as dark through-cuts, `bores` as dark cylinders
## through it ([a, b, r]). The outline may be wound either way.
static func _outline_plate(sts: Dictionary, p: Dictionary) -> void:
	var t := float(p.get("t", 0.004))
	var outline: PackedVector2Array = p["outline"]
	var area := 0.0
	for i in outline.size():
		var a: Vector2 = outline[i]
		var b: Vector2 = outline[(i + 1) % outline.size()]
		area += a.x * b.y - b.x * a.y
	if area < 0.0:
		outline = outline.duplicate()
		outline.reverse()
	prism(_st(sts, str(p.get("mat", "plate"))), outline, 0.0, t)
	var dark := _st(sts, "black")
	var hr := float(p.get("hole_r", 0.0026))
	var saved := _xf
	for hv in p.get("holes", PackedVector2Array()):
		var h: Vector2 = hv
		_xf = saved * Transform3D(Basis.IDENTITY, Vector3(h.x, 0, h.y))
		cyl_y(dark, -0.0002, t + 0.0002, hr, 12)
	if p.has("pilot"):
		var pl: Vector3 = p["pilot"]
		_xf = saved * Transform3D(Basis.IDENTITY, Vector3(pl.x, 0, pl.y))
		cyl_y(dark, -0.0002, t + 0.0002, pl.z, 24)
	_xf = saved
	for sv in p.get("slots", []):
		var c: Vector2 = sv[0]
		var sz: Vector2 = sv[1]
		box(dark, Vector3(c.x, t * 0.5, c.y), Vector3(sz.x, t + 0.0004, sz.y))
	for bv in p.get("bores", []):
		cyl(dark, bv[0], bv[1], float(bv[2]), 12)


static func _rail(sts: Dictionary, p: Dictionary) -> void:
	var len := float(p.get("len", 0.3))
	var w := float(p.get("w", 0.012))
	var h := float(p.get("h", 0.008))
	var pitch := float(p.get("hole_pitch", 0.025))
	var chrome := _st(sts, "chrome")
	var dark := _st(sts, "steel")
	# The rail runs along +Y, standing on its base at z = 0, +Z up.
	var hw := w * 0.5
	var g := h * 0.45
	var outline := PackedVector2Array([Vector2(-hw, 0), Vector2(hw, 0), Vector2(hw, g - 0.0012), Vector2(hw - 0.0015, g), Vector2(hw, g + 0.0012),
		Vector2(hw, h), Vector2(-hw, h), Vector2(-hw, g + 0.0012), Vector2(-hw + 0.0015, g), Vector2(-hw, g - 0.0012)])
	# prism extrudes along Y with the outline in (x, z): exactly this frame.
	prism(chrome, outline, 0.0, len)
	var n := int(floor(len / pitch))
	for i in n:
		var y := pitch * (float(i) + 0.5)
		if y > len - pitch * 0.3:
			break
		var saved := _xf
		_xf = saved * Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(0, y, h))
		cyl_y(dark, -0.0004, 0.0003, w * 0.22, 8)
		_xf = saved


static func _rail_block(sts: Dictionary, p: Dictionary) -> void:
	var s: Vector3 = p.get("s", Vector3(0.027, 0.0455, 0.013))  # across, along (Y), high (Z)
	var steel := _st(sts, "steel")
	var chrome := _st(sts, "chrome")
	var black := _st(sts, "black")
	# Sits straddling the rail (which is below z = 0 in the block's frame).
	var saved := _xf
	_xf = saved * Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3.ZERO)
	# Now local +Y is the block's up (old +Z); the outline lies in (x, old y).
	prism(steel, rect_outline(s.x, s.y, 0.002), 0.0, s.z)
	# End seals.
	for sy in [-1.0, 1.0]:
		box(black, Vector3(0.0, s.z * 0.5, sy * (s.y * 0.5 + 0.001)), Vector3(s.x * 0.96, s.z * 0.96, 0.002))
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			_cap_head(chrome, Vector3(sx * s.x * 0.37, s.z, sy * s.y * 0.3), 0.0022, 0.0025)
	_xf = saved


static func _rod(sts: Dictionary, p: Dictionary) -> void:
	cyl_y(_st(sts, "chrome"), 0.0, float(p.get("len", 0.3)), float(p.get("d", 0.008)) * 0.5, 12)


static func _lm8uu(sts: Dictionary, p: Dictionary) -> void:
	var len := float(p.get("len", 0.024))
	var r := float(p.get("d", 0.015)) * 0.5
	lathe(_st(sts, "chrome"), PackedVector2Array([Vector2(0.0045, 0), Vector2(r, 0), Vector2(r, 0.0035), Vector2(r - 0.0008, 0.0035), Vector2(r - 0.0008, 0.0047),
		Vector2(r, 0.0047), Vector2(r, len - 0.0047), Vector2(r - 0.0008, len - 0.0047), Vector2(r - 0.0008, len - 0.0035), Vector2(r, len - 0.0035), Vector2(r, len), Vector2(0.0045, len)]), 14)


## An SK shaft support: origin on the shaft axis at mid-thickness, the shaft
## along +Y, the base `h` behind it (-Z) with its two wings, the clamp slot
## and screw over the shaft.
static func _sk_support(sts: Dictionary, p: Dictionary) -> void:
	var alu := _st(sts, "alu")
	var chrome := _st(sts, "chrome")
	var dark := _st(sts, "black")
	var h := float(p.get("h", 0.02))
	var w := float(p.get("w", 0.042))
	var t := float(p.get("t", 0.014))
	var r := float(p.get("d", 0.008)) * 0.5
	var bx := float(p.get("bolts", 0.032)) * 0.5
	box(alu, Vector3(0, 0, -h + 0.003), Vector3(w, t, 0.006))
	box(alu, Vector3(0, 0, (-h + 0.006 + 0.0) * 0.5), Vector3(0.02, t, h - 0.006))
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, Vector3(0, -t * 0.5, 0))
	cyl_y(alu, 0.0, t, r + 0.006, 16)
	_xf = saved
	box(dark, Vector3(0, 0, r + 0.004), Vector3(0.0012, t + 0.0004, 0.008))
	for sx in [-1.0, 1.0]:
		_xf = saved * Transform3D(GantryLabDetail.basis_y(Vector3.BACK), Vector3(sx * bx, 0, -h + 0.006))
		cyl_y(chrome, 0.0, 0.003, 0.0043, 10)
		_xf = saved
	_xf = saved * Transform3D(GantryLabDetail.basis_y(Vector3.RIGHT), Vector3(0.006, 0, r + 0.004))
	cyl_y(chrome, 0.0, 0.0035, 0.0035, 8)
	_xf = saved


## A flange linear bearing: the flange's top face at the origin, the body
## hanging below; four M4 heads on the pcd.
static func _flange_bearing(sts: Dictionary, p: Dictionary) -> void:
	var chrome := _st(sts, "chrome")
	var dark := _st(sts, "black")
	var D := float(p.get("D", 0.015))
	var L := float(p.get("L", 0.024))
	var Df := float(p.get("Df", 0.032))
	var ft := float(p.get("ft", 0.005))
	var ri := float(p.get("d", 0.008)) * 0.5 + 0.0005
	lathe(chrome, PackedVector2Array([Vector2(ri, -L), Vector2(D * 0.5, -L), Vector2(D * 0.5, -ft), Vector2(Df * 0.5, -ft), Vector2(Df * 0.5, 0.0), Vector2(ri, 0.0)]), 18)
	lathe(dark, PackedVector2Array([Vector2(ri - 0.0004, -L - 0.0004), Vector2(ri + 0.0015, -L - 0.0004), Vector2(ri + 0.0015, 0.0004), Vector2(ri - 0.0004, 0.0004)]), 12)
	var k := float(p.get("pcd", 0.024)) * 0.5 * 0.70710678
	var saved := _xf
	for q in [Vector2(-k, -k), Vector2(k, -k), Vector2(k, k), Vector2(-k, k)]:
		_xf = saved * Transform3D(Basis.IDENTITY, Vector3(q.x, -ft - 0.0028, q.y))
		cyl_y(chrome, 0.0, 0.0028, 0.0035, 8)
		_xf = saved


# ---------------------------------------------------------------------------
# Toolheads
# ---------------------------------------------------------------------------

static func _hotend(sts: Dictionary, p: Dictionary) -> void:
	var brass := _st(sts, "brass")
	var alu := _st(sts, "alu")
	var chrome := _st(sts, "chrome")
	var black := _st(sts, "black")
	var red := _st(sts, "wire_red")
	var big := bool(p.get("volcano", false))
	# Nozzle: a cone to the tip, then the hex.
	lathe(brass, PackedVector2Array([Vector2(0, 0), Vector2(0.0008, 0), Vector2(0.0034, 0.0025), Vector2(0.0034, 0.003), Vector2(0, 0.003)]), 12)
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, Vector3(0, 0.003, 0))
	prism(brass, ngon_outline(0.004, 6), 0.0, 0.0045)
	_xf = saved
	# Heater block (Volcano: twice as tall), the cartridge heater and thermistor.
	var bh := 0.0115 if not big else 0.021
	var by := 0.0075
	box(alu, Vector3(0.0, by + bh * 0.5, 0.0), Vector3(0.023, bh, 0.016))
	cyl(chrome, Vector3(0.0, by + bh * 0.5, 0.0), Vector3(0.016, by + bh * 0.5, 0.0), 0.003, 8)
	cyl(red, Vector3(0.016, by + bh * 0.5 + 0.001, 0.0), Vector3(0.022, by + bh * 0.5 + 0.004, 0.004), 0.0008, 5)
	cyl(red, Vector3(0.016, by + bh * 0.5 - 0.001, 0.0), Vector3(0.022, by + bh * 0.5 + 0.002, -0.004), 0.0008, 5)
	# Heat break and the finned sink.
	var hb := by + bh
	cyl_y(chrome, hb, hb + 0.004, 0.0025, 8)
	var sy := hb + 0.004
	cyl_y(alu, sy, sy + 0.0265, 0.0055, 12)
	for i in 9:
		var fy := sy + 0.0015 + float(i) * 0.0028
		cyl_y(alu, fy, fy + 0.0012, 0.0112, 16)
	# Groove-mount collar and the Bowden coupling (or a direct-drive throat).
	var gy := sy + 0.0265
	cyl_y(alu, gy, gy + 0.006, 0.008, 12)
	cyl_y(brass, gy + 0.006, gy + 0.0105, 0.0045, 8)
	cyl_y(black, gy + 0.0105, gy + 0.0135, 0.003, 8)
	# Heatsink fan (30 mm) on +X with its duct shroud; part fan duct on −Z.
	_fan_at(sts, Vector3(0.0215, sy + 0.013, 0.0), Basis(Vector3.FORWARD, -PI * 0.5), 0.03, 0.01)
	box(black, Vector3(0.0, sy + 0.013, 0.0165), Vector3(0.028, 0.026, 0.003))
	box(black, Vector3(0.0, by + bh + 0.009, -0.0135), Vector3(0.03, 0.014, 0.008))
	# A duct aimed at the nozzle.
	_xf = saved * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(-38.0)), Vector3(0.0, by + 0.004, -0.009))
	box(black, Vector3(0.0, 0.0, 0.0), Vector3(0.012, 0.004, 0.009))
	_xf = saved


static func _fan_at(sts: Dictionary, c: Vector3, b: Basis, size: float, depth: float) -> void:
	var saved := _xf
	_xf = saved * Transform3D(b, c)
	_fan(sts, {"size": size, "depth": depth})
	_xf = saved


## An axial fan: the frame square in the local XZ plane, blowing along +Y.
static func _fan(sts: Dictionary, p: Dictionary) -> void:
	var size := float(p.get("size", 0.04))
	var depth := float(p.get("depth", 0.01))
	var black := _st(sts, "black")
	var dark := _st(sts, "steel")
	var hs := size * 0.5
	var hd := depth * 0.5
	# Frame with the round opening suggested by a dark disc on both faces.
	prism(black, rect_outline(size, size, size * 0.12), -hd, hd)
	cyl_y(dark, hd, hd + 0.0004, hs - 0.002, 18)
	cyl_y(dark, -hd - 0.0004, -hd, hs - 0.002, 18)
	cyl_y(black, hd + 0.0004, hd + 0.0012, hs * 0.38, 12)
	# Seven blades, tilted.
	for i in 7:
		var a := TAU * float(i) / 7.0
		var saved := _xf
		_xf = saved * Transform3D(Basis(Vector3.UP, a) * Basis(Vector3.RIGHT, deg_to_rad(30.0)), Vector3(0, hd + 0.0006, 0))
		box(black, Vector3(hs * 0.62, 0.0, 0.0), Vector3(hs * 0.5, 0.0006, hs * 0.36))
		_xf = saved


static func _extruder(sts: Dictionary, p: Dictionary) -> void:
	var alu := _st(sts, "alu")
	var black := _st(sts, "black")
	var chrome := _st(sts, "chrome")
	var brass := _st(sts, "brass")
	var pcb := _st(sts, "steel")
	# Pancake motor behind the mount plate (shaft +Z through it).
	var saved := _xf
	_xf = saved * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3(0.0, 0.0, 0.0))
	_motor(sts, {"frame": 0.042, "len": 0.022, "shaft": 0.0})
	_xf = saved
	# The extruder body on the shaft side, the drive gear, idler arm and bearing.
	box(alu, Vector3(0.0, 0.0, 0.011), Vector3(0.042, 0.042, 0.022))
	cyl(pcb, Vector3(0.0, 0.0, 0.022), Vector3(0.0, 0.0, 0.03), 0.006, 10)
	box(black, Vector3(0.016, 0.004, 0.027), Vector3(0.012, 0.034, 0.009))
	cyl(chrome, Vector3(0.013, 0.0, 0.0245), Vector3(0.013, 0.0, 0.03), 0.0055, 10)
	cyl(chrome, Vector3(0.016, 0.017, 0.027), Vector3(0.016, 0.03, 0.027), 0.0015, 6)
	# Filament couplings: in on top, out below.
	cyl(brass, EXTRUDER_INLET - Vector3(0, 0.005, 0), EXTRUDER_INLET, 0.0045, 8)
	cyl(brass, EXTRUDER_OUTLET + Vector3(0, 0.005, 0), EXTRUDER_OUTLET, 0.0045, 8)


static func _spindle(sts: Dictionary, p: Dictionary) -> void:
	var kind := str(p.get("tool", "spindle_500w"))
	var chrome := _st(sts, "chrome")
	var alu := _st(sts, "alu")
	var black := _st(sts, "black")
	var r := 0.026
	var h := 0.16
	var body := alu
	match kind:
		"router_1250w":
			r = 0.0325
			h = 0.2
			body = _st(sts, "tool_teal")
		"spindle_2200w":
			r = 0.04
			h = 0.21
	# Bit, collet nut, the body, the top cap / vents / cooling fittings.
	cyl_y(chrome, 0.0, 0.025, 0.0016, 8)
	var saved := _xf
	_xf = saved * Transform3D(Basis.IDENTITY, Vector3(0, 0.02, 0))
	prism(chrome, ngon_outline(0.0085, 6), 0.0, 0.012)
	_xf = saved
	lathe(body, PackedVector2Array([Vector2(0, 0.032), Vector2(r * 0.55, 0.032), Vector2(r, 0.046), Vector2(r, 0.032 + h), Vector2(0, 0.032 + h)]), 20)
	if kind == "router_1250w":
		cyl_y(black, 0.032 + h, 0.032 + h + 0.03, r * 0.92, 20)
		box(black, Vector3(r + 0.004, 0.09, 0.0), Vector3(0.016, 0.05, 0.03))
	elif kind == "spindle_2200w":
		for i in 2:
			cyl(chrome, Vector3(r * 0.5, 0.032 + h, (i * 2 - 1) * 0.012), Vector3(r * 0.5, 0.032 + h + 0.018, (i * 2 - 1) * 0.012), 0.003, 8)
		box(black, Vector3(0, 0.032 + h + 0.004, 0), Vector3(0.04, 0.008, 0.04))
	else:
		box(black, Vector3(0, 0.032 + h + 0.006, 0), Vector3(0.03, 0.012, 0.02))
	# The clamp ring that holds it to the Z plate (behind: −Z).
	cyl_y(alu, 0.06, 0.08, r + 0.006, 20)
	box(alu, Vector3(0.0, 0.07, -r - 0.01), Vector3(0.07, 0.02, 0.012))


static func _laser(sts: Dictionary, p: Dictionary) -> void:
	var black := _st(sts, "black")
	var alu := _st(sts, "alu")
	var glass := _st(sts, "glass")
	# Lens barrel at the tip, air nozzle, the finned module above.
	lathe(black, PackedVector2Array([Vector2(0, 0.006), Vector2(0.003, 0.006), Vector2(0.006, 0.012), Vector2(0.006, 0.022), Vector2(0, 0.022)]), 10)
	cyl_y(glass, 0.0055, 0.0065, 0.0025, 8)
	box(black, Vector3(0.0, 0.05, 0.0), Vector3(0.036, 0.056, 0.036))
	for i in 5:
		box(alu, Vector3(0.0, 0.03 + float(i) * 0.009, 0.0), Vector3(0.04, 0.0015, 0.04))
	_fan_at(sts, Vector3(0.0, 0.082, 0.0), Basis.IDENTITY, 0.03, 0.008)
	box(alu, Vector3(0.0, 0.05, -0.021), Vector3(0.03, 0.05, 0.006))


static func _pen(sts: Dictionary, p: Dictionary) -> void:
	var black := _st(sts, "black")
	var alu := _st(sts, "alu")
	lathe(black, PackedVector2Array([Vector2(0, 0), Vector2(0.0008, 0), Vector2(0.005, 0.012), Vector2(0.005, 0.13), Vector2(0, 0.13)]), 10)
	box(alu, Vector3(0.0, 0.07, -0.012), Vector3(0.024, 0.03, 0.014))
	cyl(alu, Vector3(0.012, 0.07, -0.012), Vector3(0.018, 0.07, -0.012), 0.002, 6)


static func _clay_extruder(sts: Dictionary, p: Dictionary) -> void:
	var alu := _st(sts, "alu")
	var tube := _st(sts, "tube")
	var clay := _st(sts, "clay")
	var black := _st(sts, "black")
	# Nozzle, the cartridge (clear with clay inside), the drive stepper on top.
	lathe(alu, PackedVector2Array([Vector2(0, 0), Vector2(0.004, 0), Vector2(0.028, 0.035), Vector2(0.028, 0.045), Vector2(0, 0.045)]), 16)
	cyl_y(clay, 0.045, 0.3, 0.027, 16)
	cyl_y(tube, 0.045, 0.3, 0.03, 16)
	cyl_y(alu, 0.3, 0.315, 0.032, 16)
	var saved := _xf
	_xf = saved * Transform3D(Basis(Vector3.RIGHT, PI), Vector3(0, 0.36, 0))
	_motor(sts, {"frame": 0.042, "len": 0.04})
	_xf = saved
	cyl_y(black, 0.315, 0.36, 0.006, 8)
	box(alu, Vector3(0.0, 0.2, -0.038), Vector3(0.05, 0.1, 0.008))


static func _pellet_extruder(sts: Dictionary, p: Dictionary) -> void:
	var alu := _st(sts, "alu")
	var black := _st(sts, "black")
	var brass := _st(sts, "brass")
	var tube := _st(sts, "tube")
	lathe(brass, PackedVector2Array([Vector2(0, 0), Vector2(0.0025, 0), Vector2(0.008, 0.006), Vector2(0.008, 0.012), Vector2(0, 0.012)]), 10)
	cyl_y(alu, 0.012, 0.11, 0.016, 14)
	for i in 6:
		cyl_y(alu, 0.03 + float(i) * 0.012, 0.032 + float(i) * 0.012, 0.024, 14)
	box(black, Vector3(0.0, 0.125, 0.0), Vector3(0.06, 0.03, 0.06))
	# Hopper (a cone) and the feed stepper beside it.
	lathe(tube, PackedVector2Array([Vector2(0.012, 0.14), Vector2(0.05, 0.2), Vector2(0.05, 0.24), Vector2(0.048, 0.24), Vector2(0.048, 0.2), Vector2(0.011, 0.142)]), 14)
	var saved := _xf
	_xf = saved * Transform3D(Basis(Vector3.RIGHT, PI), Vector3(0.0, 0.16, -0.045))
	_motor(sts, {"frame": 0.042, "len": 0.04})
	_xf = saved
	box(alu, Vector3(0.0, 0.09, -0.04), Vector3(0.05, 0.08, 0.008))


static func _tool_block(sts: Dictionary, p: Dictionary) -> void:
	box(_st(sts, "tool"), Vector3.ZERO, p.get("s", Vector3(0.04, 0.05, 0.04)))


# ---------------------------------------------------------------------------
# Electronics, frame furniture, bed
# ---------------------------------------------------------------------------

static func _psu(sts: Dictionary, p: Dictionary) -> void:
	var s: Vector3 = p.get("s", Vector3(0.215, 0.05, 0.115))
	var galv := _st(sts, "galv")
	var black := _st(sts, "black")
	var dark := _st(sts, "steel")
	box(galv, Vector3.ZERO, s)
	# Terminal block on the −X end, grille slits on top.
	box(black, Vector3(-s.x * 0.5 + 0.012, 0.0, 0.0), Vector3(0.024, s.y * 0.7, s.z * 0.8))
	for i in 7:
		box(dark, Vector3(s.x * 0.15, s.y * 0.5 + 0.0003, -s.z * 0.35 + float(i) * s.z * 0.7 / 6.0), Vector3(s.x * 0.5, 0.0006, 0.003))
	for i in 7:
		box(dark, Vector3(s.x * 0.5 + 0.0003, 0.0, -s.z * 0.35 + float(i) * s.z * 0.7 / 6.0), Vector3(0.0006, s.y * 0.6, 0.003))


static func _lcd(sts: Dictionary, p: Dictionary) -> void:
	var pcb := _st(sts, "pcb")
	var screen := _st(sts, "screen")
	var black := _st(sts, "black")
	var alu := _st(sts, "alu")
	var w := float(p.get("w", 0.1))
	var h := float(p.get("h", 0.062))
	# Board, the screen proud of it on +Z, a knob at the right, a bracket behind.
	box(pcb, Vector3(0.0, 0.0, 0.0), Vector3(w, h, 0.004))
	box(screen, Vector3(-0.008, 0.0, 0.0035), Vector3(w * 0.78, h * 0.72, 0.003))
	cyl(black, Vector3(w * 0.5 - 0.012, -h * 0.2, 0.002), Vector3(w * 0.5 - 0.012, -h * 0.2, 0.016), 0.008, 12)
	box(alu, Vector3(0.0, -h * 0.5 + 0.004, -0.012), Vector3(w * 0.5, 0.008, 0.02))


static func _board(sts: Dictionary, p: Dictionary) -> void:
	var s: Vector3 = p.get("s", Vector3(0.11, 0.0016, 0.09))
	var pcb := _st(sts, "pcb")
	var black := _st(sts, "black")
	var blue := _st(sts, "blue")
	var white := _st(sts, "white")
	box(pcb, Vector3.ZERO, Vector3(s.x, 0.0016, s.z))
	var y := 0.0008
	# The MCU, a row of driver heatsinks, screw terminals and connectors.
	box(black, Vector3(-s.x * 0.2, y + 0.0015, 0.0), Vector3(0.014, 0.003, 0.014))
	var n := int(p.get("drivers", 4))
	for i in n:
		box(blue, Vector3(s.x * 0.05 + float(i) * 0.014, y + 0.005, s.z * 0.2), Vector3(0.01, 0.01, 0.01))
	box(_st(sts, "green"), Vector3(-s.x * 0.38, y + 0.005, -s.z * 0.1), Vector3(0.012, 0.01, s.z * 0.5))
	for i in 5:
		box(white, Vector3(-s.x * 0.2 + float(i) * 0.013, y + 0.003, -s.z * 0.4), Vector3(0.009, 0.006, 0.006))
	for i in 3:
		box(black, Vector3(s.x * 0.3, y + 0.004, -s.z * 0.3 + float(i) * 0.02), Vector3(0.012, 0.008, 0.012))


static func _foot(sts: Dictionary, p: Dictionary) -> void:
	var r := float(p.get("r", 0.013))
	var h := float(p.get("h", 0.011))
	lathe(_st(sts, "rubber"), PackedVector2Array([Vector2(0, -h), Vector2(r * 0.85, -h), Vector2(r, -h * 0.6), Vector2(r, 0.0), Vector2(0, 0.0)]), 14)


## A cast 90° corner bracket: legs along +X and +Y from the inside corner at
## the origin, `size` long, with a gusset web.
static func _corner_bracket(sts: Dictionary, p: Dictionary) -> void:
	var size := float(p.get("size", 0.02))
	var t := 0.0035
	var st := _st(sts, str(p.get("mat", "alu")))
	var chrome := _st(sts, "chrome")
	var hz := size * 0.5
	box(st, Vector3(size * 0.5, t * 0.5, 0.0), Vector3(size, t, size))
	box(st, Vector3(t * 0.5, size * 0.5, 0.0), Vector3(t, size, size))
	for sz_i in 2:
		var sz := -1.0 if sz_i == 0 else 1.0
		var z := sz * (hz - 0.001)
		tri(st, Vector3(t, t, z), Vector3(size * 0.85, t, z), Vector3(t, size * 0.85, z), Vector3(0, 0, sz))
		tri(st, Vector3(t, t, z - sz * 0.002), Vector3(t, size * 0.85, z - sz * 0.002), Vector3(size * 0.85, t, z - sz * 0.002), Vector3(0, 0, -sz))
		quad(st, Vector3(size * 0.85, t, z), Vector3(size * 0.85, t, z - sz * 0.002), Vector3(t, size * 0.85, z - sz * 0.002), Vector3(t, size * 0.85, z), Vector3(1, 1, 0).normalized())
	if not bool(p.get("bolts", true)):
		return
	_cap_head(chrome, Vector3(size * 0.65, t, 0.0), 0.0032, 0.003)
	var saved := _xf
	_xf = saved * Transform3D(Basis(Vector3.FORWARD, -PI * 0.5), Vector3(t, size * 0.65, 0.0))
	_cap_head(chrome, Vector3.ZERO, 0.0032, 0.003)
	_xf = saved


## A bent-steel L bracket (a motor mount): leg A flat along +X (`a` long,
## `w` wide in Z), leg B up along +Y (`b` long), `t` thick, inside corner at
## the origin; `hole` cuts nothing, but the motor's pilot boss sits in it.
static func _bracket_l(sts: Dictionary, p: Dictionary) -> void:
	var a := float(p.get("a", 0.046))
	var b := float(p.get("b", 0.052))
	var w := float(p.get("w", 0.046))
	var t := float(p.get("t", 0.003))
	var st := _st(sts, str(p.get("mat", "black")))
	var chrome := _st(sts, "chrome")
	box(st, Vector3(a * 0.5, -t * 0.5, 0.0), Vector3(a, t, w))
	box(st, Vector3(-t * 0.5, b * 0.5, 0.0), Vector3(t, b, w))
	if bool(p.get("bolts", true)):
		for sz in [-1.0, 1.0]:
			_cap_head(chrome, Vector3(a * 0.5, 0.0, sz * w * 0.33), 0.0032, 0.003)


static func _spring_knob(sts: Dictionary, p: Dictionary) -> void:
	var h := float(p.get("h", 0.02))
	var spring := _st(sts, "spring")
	var black := _st(sts, "black")
	var chrome := _st(sts, "chrome")
	# Spring between the carriage (y = 0) and the bed (y = h), the knob under
	# the carriage, the bolt through everything.
	lathe(spring, PackedVector2Array([Vector2(0, 0.001), Vector2(0.0058, 0.001), Vector2(0.0058, h - 0.001), Vector2(0, h - 0.001)]), 12, true)
	cyl_y(chrome, -0.016, h + 0.004, 0.0015, 6)
	lathe(black, PackedVector2Array([Vector2(0, -0.014), Vector2(0.0095, -0.014), Vector2(0.0095, -0.008), Vector2(0.007, -0.007), Vector2(0, -0.007)]), 16)


static func _bed(sts: Dictionary, p: Dictionary) -> void:
	var size: Vector2 = p.get("size", Vector2(0.24, 0.24))
	var kind := str(p.get("bed_kind", "heated_pcb"))
	var sx := size.x
	var sz := size.y
	match kind:
		"heated_pcb":
			box(_st(sts, "glass"), Vector3(0, -0.002, 0), Vector3(sx, 0.004, sz))
			box(_st(sts, "alu"), Vector3(0, -0.0055, 0), Vector3(sx, 0.003, sz))
			box(_st(sts, "heater"), Vector3(0, -0.0078, 0), Vector3(sx - 0.02, 0.0016, sz - 0.02))
			var black := _st(sts, "black")
			for sxx in [-1.0, 1.0]:
				box(black, Vector3(sxx * (sx * 0.5 - 0.006), -0.0035, 0.0), Vector3(0.014, 0.009, 0.02))
		"alu_plate":
			box(_st(sts, "alu"), Vector3(0, -0.003, 0), Vector3(sx, 0.006, sz))
		"spoilboard":
			box(_st(sts, "mdf"), Vector3(0, -0.009, 0), Vector3(sx, 0.018, sz))
			var dark := _st(sts, "steel")
			var n := maxi(2, int(round(sx / 0.1)))
			for i in n:
				var x := -sx * 0.5 + sx * (float(i) + 0.5) / float(n)
				box(dark, Vector3(x, 0.0002, 0.0), Vector3(0.012, 0.0006, sz))
		"honeycomb":
			box(_st(sts, "steel"), Vector3(0, -0.01, 0), Vector3(sx, 0.02, sz))
			box(_st(sts, "honey"), Vector3(0, 0.0002, 0), Vector3(sx - 0.03, 0.0006, sz - 0.03))
		_:
			box(_st(sts, "concrete"), Vector3(0, -0.01, 0), Vector3(sx + 0.1, 0.02, sz + 0.1))


static func _bed_round(sts: Dictionary, p: Dictionary) -> void:
	var r := float(p.get("r", 0.1))
	var kind := str(p.get("bed_kind", "alu_plate"))
	if kind == "heated_pcb":
		cyl_y(_st(sts, "glass"), -0.004, 0.0, r, 36)
		cyl_y(_st(sts, "alu"), -0.007, -0.004, r, 36)
		cyl_y(_st(sts, "heater"), -0.0086, -0.007, r - 0.01, 36)
	elif kind == "none":
		cyl_y(_st(sts, "concrete"), -0.02, 0.0, r + 0.05, 36)
	else:
		cyl_y(_st(sts, "alu"), -0.006, 0.0, r, 36)


static func _spool(sts: Dictionary, p: Dictionary) -> void:
	var r := float(p.get("r", 0.1))
	var w := float(p.get("w", 0.065))
	var fill := clampf(float(p.get("fill", 0.75)), 0.0, 1.0)
	var black := _st(sts, "black")
	var fil := _st(sts, "filament")
	var chrome := _st(sts, "chrome")
	# Two flanges, the hub, the wound filament between them; a rod through.
	for y in [0.0, w - 0.003]:
		lathe(black, PackedVector2Array([Vector2(0.03, y), Vector2(r, y), Vector2(r, y + 0.003), Vector2(0.03, y + 0.003)]), 24)
	cyl_y(black, 0.003, w - 0.003, 0.03, 16)
	var rf := 0.032 + (r - 0.04) * fill
	lathe(fil, PackedVector2Array([Vector2(0.03, 0.003), Vector2(rf, 0.003), Vector2(rf, w - 0.003), Vector2(0.03, w - 0.003)]), 24)
	cyl_y(chrome, -0.02, w + 0.02, 0.004, 8)


static func _effector(sts: Dictionary, p: Dictionary) -> void:
	var r := float(p.get("r", 0.032))
	var alu := _st(sts, "alu")
	var chrome := _st(sts, "chrome")
	prism(alu, ngon_outline(r + 0.012, 6, PI / 6.0), 0.0, 0.006)
	for i in 6:
		var a := TAU * float(i) / 6.0
		_cap_head(chrome, Vector3(cos(a) * (r + 0.004), 0.006, sin(a) * (r + 0.004)), 0.0025, 0.0025)


static func _rod_end(sts: Dictionary, p: Dictionary) -> void:
	sphere(_st(sts, "chrome"), Vector3.ZERO, 0.004, 8, 5)
	cyl_y(_st(sts, "black"), -0.012, -0.003, 0.0035, 8)


static func _belt_clamp(sts: Dictionary, p: Dictionary) -> void:
	var black := _st(sts, "black")
	var chrome := _st(sts, "chrome")
	box(black, Vector3.ZERO, p.get("s", Vector3(0.02, 0.008, 0.012)))
	_cap_head(chrome, Vector3(0.0, (p.get("s", Vector3(0.02, 0.008, 0.012)) as Vector3).y * 0.5, 0.0), 0.0025, 0.0025)


# ---------------------------------------------------------------------------
# Fasteners (GantryLabMates): a bolt's origin is the face under its head,
# +Y toward the head, the shank down -Y for `len`; a nut / washer / T-nut
# sits on its origin plane with +Y away from the joint; a spacer runs 0..len
# along +Y.
# ---------------------------------------------------------------------------

static func _fastener_bolt(sts: Dictionary, p: Dictionary) -> void:
	var d := float(p.get("d", 0.005))
	var len := float(p.get("len", 0.01))
	var chrome := _st(sts, "chrome")
	cyl_y(chrome, -len, 0.0, d * 0.42, 6)
	if str(p.get("head", "shcs")) == "bhcs":
		lathe(chrome, PackedVector2Array([Vector2(0, 0), Vector2(d * 0.95, 0), Vector2(d * 0.85, d * 0.25), Vector2(d * 0.55, d * 0.5), Vector2(0, d * 0.55)]), 10)
	else:
		_cap_head(chrome, Vector3.ZERO, d * 0.8, d)


static func _fastener_nut(sts: Dictionary, p: Dictionary) -> void:
	var d := float(p.get("d", 0.005))
	var chrome := _st(sts, "chrome")
	prism(chrome, ngon_outline(d * 0.92, 6), 0.0, d * 0.8)


static func _fastener_tnut(sts: Dictionary, p: Dictionary) -> void:
	var steel := _st(sts, "steel")
	# A drop-in T-nut: a bar across the slot's inner cavity.
	box(steel, Vector3(0, -0.001, 0), Vector3(0.0105, 0.004, 0.006))


static func _fastener_washer(sts: Dictionary, p: Dictionary) -> void:
	var chrome := _st(sts, "chrome")
	lathe(chrome, PackedVector2Array([Vector2(0.0027, 0), Vector2(0.005, 0), Vector2(0.005, 0.001), Vector2(0.0027, 0.001)]), 12)


static func _fastener_spacer(sts: Dictionary, p: Dictionary) -> void:
	var len := float(p.get("len", 0.006))
	var ecc := bool(p.get("ecc", false))
	if ecc:
		prism(_st(sts, "alu"), ngon_outline(0.0052, 6), 0.0, len)
	else:
		lathe(_st(sts, "alu"), PackedVector2Array([Vector2(0.0027, 0), Vector2(0.005, 0), Vector2(0.005, len), Vector2(0.0027, len)]), 12)

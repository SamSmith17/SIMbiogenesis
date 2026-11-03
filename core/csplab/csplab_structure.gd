class_name CspLabStructure
extends RefCounted

## What holds a concentrator up and turns it: the members (for the 3D
## structure view), their mass, the wind on the aperture, the drive that has
## to turn and hold it, and the checks a builder would run — the pedestal or
## pylon in bending, the torque tube in twist, a tower's legs.
##
## Members are tubes {a, b, d (outside Ø m), t (wall m), frame} or boxes
## {a, b, w, h, frame, mass}. Frames:
##   "base"  the ground, fixed (prop origin on the ground)
##   "stage" the first moving stage (azimuth / hour angle / the one axis),
##           origin at the tracking pivot
##   "optic" the optic frame (the optic's own coordinates, see CspLabSpec)
## A member may carry "mat": "concrete" (footings, counted apart as
## concrete_kg / concrete_m3) or "counterweight" (moves with the optic,
## counted apart as counterweight_kg); the rest is steel or drives.
##
## Wind (ESTIMATES after Peterka, Tan, Bienkiewicz & Cermak 1989, "Wind
## loads on heliostats and parabolic dish collectors", SERI/STR-253-3431):
## face-on drag Cd ≈ 1.2, peak hinge moment coefficient Cm ≈ 0.25 about the
## elevation axis (moment = q·Cm·A·chord); stowed face-up the drag falls to
## ≈ 0.3 and the hinge moment to ≈ 0.05. q = ½ρv², ρ = 1.225 kg/m³.

const RHO_AIR := 1.225
const G := 9.81
const CD_FACE := 1.2
const CM_FACE := 0.25
const CD_STOW := 0.3
const CM_STOW := 0.05
const SAFETY := 1.5
const FRICTION_NM := 40.0
const CONCRETE_KG_M3 := 2400.0


static func tube_props(d: float, t: float) -> Dictionary:
	var di := maxf(d - 2.0 * t, 0.0)
	var a := PI * (d * d - di * di) / 4.0
	var i := PI * (pow(d, 4.0) - pow(di, 4.0)) / 64.0
	return {"A": a, "I": i, "Z": 2.0 * i / maxf(d, 1e-9), "J": 2.0 * i}


static func q_wind(v: float) -> float:
	return 0.5 * RHO_AIR * v * v


static func _tube(a: Vector3, b: Vector3, d: float, t: float, frame: String, label: String = "") -> Dictionary:
	return {"a": a, "b": b, "d": d, "t": t, "frame": frame, "label": label}


static func _box(a: Vector3, b: Vector3, w: float, h: float, frame: String, mass: float, label: String = "") -> Dictionary:
	return {"a": a, "b": b, "w": w, "h": h, "frame": frame, "mass": mass, "box": true, "label": label}


## The structure for a solved design `d` (needs d.geo, d.spec, d.optic_mass).
static func solve(d: Dictionary) -> Dictionary:
	var spec: Dictionary = d["spec"]
	var g: Dictionary = d["geo"]
	var st: Dictionary = spec["structure"]
	var t := str(spec["type"])
	var mat := CspLabParts.struct_material(str(st["material"]))
	var dm := float(st["member_mm"]) * 0.001
	var wall := minf(float(st["wall_mm"]) * 0.001, dm * 0.5)
	var ped := float(st["pedestal_h_m"])
	var v_op := float(st["wind_op_ms"])
	var v_s := float(st["wind_survival_ms"])
	var out := {"members": [], "checks": [], "pivot_world": Vector3(0, ped, 0), "pivot_local": g.get("pivot", Vector3.ZERO)}
	var members: Array = out["members"]
	var mount := str(st["mount"])
	if not CspLabSpec.mounts_for(t).has(mount):
		mount = str(CspLabSpec.mounts_for(t)[0])
	out["mount"] = mount
	match mount:
		"pedestal_azel", "polar_mount":
			_pedestal(d, out, members, dm, wall, ped, mount)
		"torque_tube":
			_torque_tube(d, out, members, dm, wall, ped)
		"row_frame":
			_row_frame(d, out, members, dm, wall)
		"lattice_tower", "monopole":
			_tower(d, out, members, dm, wall, mount)
	# Mass of every member.
	var mass := 0.0
	var conc := 0.0
	for mv in members:
		var m: Dictionary = mv
		var mk := str(m.get("mat", ""))
		if mk == "concrete":
			conc += float(m.get("mass", 0.0))
		elif mk == "counterweight":
			pass
		elif bool(m.get("box", false)):
			mass += float(m.get("mass", 0.0))
		else:
			var tp := tube_props(float(m["d"]), float(m["t"]))
			mass += (m["a"] as Vector3).distance_to(m["b"] as Vector3) * float(tp["A"]) * float(mat["density"])
	out["mass_kg"] = mass
	out["concrete_kg"] = conc
	out["concrete_m3"] = conc / CONCRETE_KG_M3
	if not out.has("counterweight_kg"):
		out["counterweight_kg"] = 0.0
	_loads(d, out, mat, dm, wall, ped, v_op, v_s, mount)
	return out


# ---------------------------------------------------------------------------
# Members
# ---------------------------------------------------------------------------

## The optic's reach from the pivot (what swings round the axes).
static func swing_radius(g: Dictionary, pivot: Vector3) -> float:
	var t := str(g["type"])
	var pts: Array = []
	var a := float(g.get("a", 0.5))
	match t:
		"parabolic_dish":
			pts = [Vector3(a, float(g["depth"]), 0), Vector3(0, float(g["rec_y"]), 0), Vector3.ZERO]
		"lens", "fresnel_lens", "water_lens":
			var top := float(g.get("y_top", float(g.get("y_flat", 0.0)) + float(g.get("tc", 0.0))))
			pts = [Vector3(a * (1.42 if bool(g.get("square", false)) else 1.0), top, 0), Vector3(0, float(g["rec_y"]) - 0.05, 0)]
		"ball_lens":
			pts = [Vector3(a, float(g["yc"]) + a, 0), Vector3(0, float(g["rec_y"]) - 0.05, 0)]
		_:
			pts = [Vector3(a, 0, 0)]
	var r := 0.0
	for pv in pts:
		r = maxf(r, (pv as Vector3).distance_to(pivot))
	return r


## A cast concrete pier, `depth` into the ground and 0.1 m proud of it.
static func _concrete(c: Vector3, w: float, depth: float, frame: String, label: String) -> Dictionary:
	var m := _box(c - Vector3(0, depth, 0), c + Vector3(0, 0.1, 0), w, w, frame, w * w * (depth + 0.1) * CONCRETE_KG_M3, label)
	m["mat"] = "concrete"
	return m


## The receiver's mass: a housing plus ~20 kg/m² of absorber (an estimate,
## the same figure the bill of materials uses).
static func receiver_kg(g: Dictionary) -> float:
	return 3.0 + float(g["A_rec"]) * 20.0


## Where the moving optic's weight sits on its axis (optic frame): the optic
## at its own centroid, the receiver at its height. {kg, y}.
static func optic_cg(d: Dictionary) -> Dictionary:
	var g: Dictionary = d["geo"]
	var m_opt := float(d.get("optic_mass_kg", 0.0))
	var y_opt := 0.0
	match str(g["type"]):
		"parabolic_dish":
			y_opt = float(g["depth"]) * 0.5
		"parabolic_trough":
			y_opt = float(g["depth"]) * 0.45
		"lens":
			y_opt = float(g["y_flat"]) + float(g["tc"]) * 0.4
		"ball_lens":
			y_opt = float(g["yc"])
		"water_lens":
			y_opt = float(g["y_bot"]) + float(g["sag"]) * 0.7
		"fresnel_lens":
			y_opt = float(g["y_top"])
	var m_rec := receiver_kg(g)
	var m := m_opt + m_rec
	return {"kg": m, "y": (m_opt * y_opt + m_rec * float(g.get("rec_y", 0.0))) / maxf(m, 1e-6)}


## A point behind a parabola y = r²/4f at radius r, `off` behind the mirror
## along its normal (2D: x = r, y).
static func _par_back(r: float, f: float, off: float) -> Vector2:
	var n := Vector2(-r, 2.0 * f).normalized()
	return Vector2(r, r * r / (4.0 * f)) - n * off


## The first drive on top of the post: an azimuth slew drive, or a polar
## mount's wedge and inclined hour-angle housing.
static func _first_drive(d: Dictionary, members: Array, dm: float, mount: String, post_top: Vector3, drive_h: float) -> void:
	if mount == "polar_mount":
		var lat := float((d["spec"]["site"] as Dictionary).get("lat_deg", 35.0))
		var ax := CspLabSite.polar_axis(lat)
		members.append(_box(post_top, post_top + Vector3(0, drive_h * 0.6, 0), dm * 2.0, dm * 2.0, "base", 6.0, "Polar wedge"))
		var w0 := post_top + Vector3(0, drive_h * 0.6, 0)
		members.append(_box(w0, w0 + ax * drive_h * 1.2, dm * 1.6, dm * 1.6, "base", 8.0, "Hour-angle drive"))
	else:
		members.append(_box(post_top, post_top + Vector3(0, drive_h, 0), dm * 1.8, dm * 1.8, "base", 8.0, "Azimuth slew drive"))


static func _pedestal(d: Dictionary, out: Dictionary, members: Array, dm: float, wall: float,
		ped: float, mount: String) -> void:
	var g: Dictionary = d["geo"]
	var drive_h := clampf(dm * 1.2, 0.08, 0.6)
	members.append(_concrete(Vector3.ZERO, clampf(dm * 2.5, 0.35, 1.5), clampf(ped * 0.6, 0.6, 5.0), "base", "Foundation pier"))
	members.append(_box(Vector3(0, 0.1, 0), Vector3(0, 0.13, 0), dm * 3.0, dm * 3.0, "base", dm * dm * 9.0 * 0.03 * 7850.0, "Base plate"))
	if str(g["type"]) == "parabolic_dish":
		_dish_frame(d, out, members, dm, wall, ped, mount, drive_h)
	else:
		_lens_frame(d, out, members, dm, wall, ped, mount, drive_h)


## A lens on a fork. The tilt axis goes through the lens + receiver's centre
## of gravity, so it balances and the drive only fights the wind.
static func _lens_frame(d: Dictionary, out: Dictionary, members: Array, dm: float, wall: float,
		ped: float, mount: String, drive_h: float) -> void:
	var g: Dictionary = d["geo"]
	var t := str(g["type"])
	var a := float(g.get("a", 0.5))
	var square := bool(g.get("square", false))
	var half_w := a * (1.42 if square else 1.0)
	var fd := maxf(dm * 0.6, 0.03)
	var sd := maxf(dm * 0.3, 0.02)
	var st2 := maxf(wall * 0.6, 0.0012)
	var cg := optic_cg(d)
	var pv := Vector3(0, float(cg["y"]), 0)
	out["pivot_local"] = pv
	var swing := swing_radius(g, pv)
	out["swing_r"] = swing
	var yw := half_w + 0.08 + dm * 0.5
	var drop := clampf(swing * 0.55, 0.25, maxf(ped - 0.35 - drive_h, 0.25))
	var post_top := Vector3(0, maxf(ped - drop - drive_h, 0.2), 0)
	members.append(_tube(Vector3(0, 0.13, 0), post_top, dm, wall, "base", "Pedestal post"))
	_first_drive(d, members, dm, mount, post_top, drive_h)
	members.append(_tube(Vector3(-yw, -drop, 0), Vector3(yw, -drop, 0), fd, wall, "stage", "Fork crossbar"))
	members.append(_tube(Vector3(-yw, -drop, 0), Vector3(-yw, 0, 0), fd, wall, "stage", "Fork arm"))
	members.append(_tube(Vector3(yw, -drop, 0), Vector3(yw, 0, 0), fd, wall, "stage", "Fork arm"))
	for sx in [-1.0, 1.0]:
		members.append(_box(Vector3(float(sx) * yw, -0.05, 0), Vector3(float(sx) * yw, 0.05, 0), fd * 1.8, fd * 1.8, "stage", 1.5, "Trunnion bearing"))
	members.append(_box(Vector3(yw + fd, -0.08, 0), Vector3(yw + fd, 0.08, 0), 0.12, 0.14, "stage", 6.0,
		"Elevation drive" if mount == "pedestal_azel" else "Declination drive"))
	# The lens frame, legs to the receiver tied by a ring half-way down, a
	# receiver plate, and trunnions out to the fork at the balance point.
	var yl := float(g.get("y_flat", g.get("y_bot", g.get("y_groove", 0.0))))
	if t == "ball_lens":
		yl = float(g["yc"]) - a * 0.3
	var yr := float(g["rec_y"])
	var rec_r := float(g["rec_r"])
	var nseg := 4 if square else 16
	var rr := half_w * (1.414 if square else 1.0) + 0.01
	var fd2 := fd * (1.4 if t == "water_lens" else 0.8)
	var ring: Array = []
	for k in nseg:
		var ang := TAU * (k + (0.5 if square else 0.0)) / float(nseg)
		ring.append(Vector3(cos(ang) * rr, yl, sin(ang) * rr))
	for k in ring.size():
		members.append(_tube(ring[k] as Vector3, ring[(k + 1) % ring.size()] as Vector3, fd2, wall, "optic", "Lens frame"))
	if t == "water_lens":
		for k in 8:
			var ang2 := TAU * k / 8.0
			members.append(_tube(Vector3(cos(ang2) * rr, yl - 0.02, sin(ang2) * rr), Vector3(0, yl - 0.02, 0), sd * 0.6, st2, "optic", "Membrane spoke"))
	var legs: Array = []
	for k in 4:
		var dir := Vector3(cos(TAU * (k + 0.5) / 4.0), 0, sin(TAU * (k + 0.5) / 4.0))
		var top := dir * rr + Vector3(0, yl, 0)
		var bot := dir * (rec_r + 0.04) + Vector3(0, yr - 0.03, 0)
		members.append(_tube(top, bot, sd, st2, "optic", "Receiver leg"))
		legs.append([top, bot])
	for k in 4:
		var l0: Array = legs[k]
		var l1: Array = legs[(k + 1) % 4]
		members.append(_tube(((l0[0] as Vector3) + (l0[1] as Vector3)) * 0.5, ((l1[0] as Vector3) + (l1[1] as Vector3)) * 0.5,
			sd * 0.7, st2, "optic", "Leg tie ring"))
	var pw2 := rec_r * 2.2 + 0.06
	members.append(_box(Vector3(0, yr - 0.07, 0), Vector3(0, yr - 0.03, 0), pw2, pw2, "optic", 2.0, "Receiver plate"))
	# Where the legs pass the pivot's height: the trunnion bars bolt on there.
	var kk := clampf((yl - pv.y) / maxf(yl - (yr - 0.03), 1e-3), 0.0, 1.0)
	var xl := lerpf(rr, rec_r + 0.04, kk) * 0.7071
	for sx2 in [-1.0, 1.0]:
		var s := float(sx2)
		members.append(_tube(Vector3(s * xl, pv.y, -xl), Vector3(s * xl, pv.y, xl), sd * 0.8, st2, "optic", "Trunnion bar"))
		members.append(_tube(Vector3(s * xl, pv.y, 0), Vector3(s * yw, pv.y, 0), fd * 0.8, wall, "optic", "Trunnion"))
	out["yoke_half"] = yw
	out["drop"] = drop


## A dish, built the way large dishes are: curved ribs and two rings behind
## the mirror, a hub; the elevation axis BEHIND the vertex on a headframe
## over the azimuth drive; a quadripod out to the receiver; and
## counterweights on arms behind the axis that bring the centre of gravity
## back onto it (the receiver far out at the focus puts it in front), so
## the drive only fights the wind.
static func _dish_frame(d: Dictionary, out: Dictionary, members: Array, dm: float, wall: float,
		ped: float, mount: String, drive_h: float) -> void:
	var g: Dictionary = d["geo"]
	var a := float(g["a"])
	var f := float(g["f"])
	var yr := float(g["rec_y"])
	var sd := maxf(dm * 0.32, 0.025)
	var st2 := maxf(wall * 0.6, 0.0015)
	var rib_d := clampf(a * 0.04, 0.03, 0.3)
	var off := 0.015 + sd * 0.5
	var hub := clampf(a * 0.18, 0.1, 1.4)
	var y_piv := -(rib_d + hub * 0.55)
	var pv := Vector3(0, y_piv, 0)
	out["pivot_local"] = pv
	var nrib := clampi(int(round(a * 6.0)), 8, 24)
	for k in nrib:
		var dir := Vector3(cos(TAU * k / float(nrib)), 0, sin(TAU * k / float(nrib)))
		var prev := Vector3.ZERO
		for s in 7:
			var bp := _par_back(lerpf(hub * 0.7, a, float(s) / 6.0), f, off)
			var p := dir * bp.x + Vector3(0, bp.y, 0)
			if s > 0:
				members.append(_tube(prev, p, sd, st2, "optic", "Mirror rib"))
			else:
				members.append(_tube(dir * hub * 0.5 + Vector3(0, y_piv * 0.4, 0), p, sd, st2, "optic", "Rib root"))
			prev = p
	for rf in [1.0, 0.55]:
		var bp2 := _par_back(a * float(rf), f, off)
		for k2 in 32:
			var a0 := TAU * k2 / 32.0
			var a1 := TAU * (k2 + 1) / 32.0
			members.append(_tube(Vector3(cos(a0) * bp2.x, bp2.y, sin(a0) * bp2.x), Vector3(cos(a1) * bp2.x, bp2.y, sin(a1) * bp2.x),
				sd * 0.8, st2, "optic", "Rim ring" if float(rf) == 1.0 else "Mid ring"))
	members.append(_box(Vector3(0, y_piv - hub * 0.3, 0), Vector3(0, -off, 0), hub * 1.6, hub * 1.6, "optic",
		hub * hub * 2.6 * 0.012 * 4.0 * 7850.0, "Hub"))
	var hr := float(g["house_r"])
	var bp3 := _par_back(a * 0.97, f, off)
	for k3 in 4:
		var dir3 := Vector3(cos(TAU * (k3 + 0.5) / 4.0), 0, sin(TAU * (k3 + 0.5) / 4.0))
		members.append(_tube(dir3 * bp3.x + Vector3(0, bp3.y, 0), dir3 * hr * 0.9 + Vector3(0, yr - hr * 0.2, 0),
			sd * 0.9, st2, "optic", "Quadripod leg"))
	# The post, the azimuth drive, the headframe with its bearings.
	var hw := hub * 0.8 + 0.12
	var post_h := maxf(ped - hub * 1.3 - drive_h, 0.4)
	var post_top := Vector3(0, post_h, 0)
	members.append(_tube(Vector3(0, 0.13, 0), post_top, dm, wall, "base", "Pedestal post"))
	_first_drive(d, members, dm, mount, post_top, drive_h)
	var y_drv := post_h + drive_h - ped
	members.append(_box(Vector3(-hw, y_drv + dm * 0.3, 0), Vector3(hw, y_drv + dm * 0.3, 0), dm * 0.8, dm * 0.8, "stage", 0.0, "Headframe beam"))
	for sx in [-1.0, 1.0]:
		var x := float(sx) * hw
		members.append(_tube(Vector3(x, y_drv, 0), Vector3(x, y_piv, 0), dm * 0.7, wall, "stage", "Headframe upright"))
		members.append(_box(Vector3(x, y_piv - 0.06, 0), Vector3(x, y_piv + 0.06, 0), dm * 1.3, dm * 1.3, "stage", 3.0, "Elevation bearing"))
	# A screw jack from the headframe to the back of the dish.
	members.append(_box(Vector3(0, y_drv + dm * 0.3, -hub * 0.5), Vector3(0, y_piv, -hub * 1.1), 0.12, 0.12, "stage", 12.0,
		"Elevation jack" if mount == "pedestal_azel" else "Declination jack"))
	members.append(_tube(pv + Vector3(-hw, 0, 0), pv + Vector3(hw, 0, 0), dm * 0.6, wall, "optic", "Elevation axle"))
	# Counterweights: the moment of the dish + receiver about the axis,
	# balanced by two weights `arm` behind it; the arm short enough that a
	# dish pointing straight up keeps them off the ground.
	var cg := optic_cg(d)
	var moment := float(cg["kg"]) * (float(cg["y"]) - y_piv)
	var arm := clampf(minf(a * 0.7 + 0.3, ped - 0.5), 0.25, 8.0)
	var cw_each := maxf(moment / arm, 0.0) * 0.5
	var side := clampf(pow(cw_each / 7200.0, 1.0 / 3.0), 0.06, 1.4)
	if arm + side * 0.5 > ped - 0.15:
		arm = maxf(ped - 0.15 - side * 0.5, 0.2)
		cw_each = maxf(moment / arm, 0.0) * 0.5
		side = clampf(pow(cw_each / 7200.0, 1.0 / 3.0), 0.06, 1.4)
	var cw_x := hw + 0.12 + dm * 0.4
	for sx2 in [-1.0, 1.0]:
		var base := pv + Vector3(float(sx2) * cw_x, 0, 0)
		members.append(_tube(base, base - Vector3(0, arm, 0), sd * 1.2, st2, "optic", "Counterweight arm"))
		var cw := _box(base - Vector3(0, arm + side * 0.5, 0), base - Vector3(0, arm - side * 0.5, 0), side, side, "optic", cw_each, "Counterweight")
		cw["mat"] = "counterweight"
		members.append(cw)
	members.append(_tube(pv + Vector3(-cw_x, 0, 0), pv + Vector3(cw_x, 0, 0), sd * 1.1, st2, "optic", "Counterweight axle"))
	out["counterweight_kg"] = cw_each * 2.0
	out["cw_arm_m"] = arm
	out["yoke_half"] = hw
	out["swing_r"] = Vector2(a, a * a / (4.0 * f)).distance_to(Vector2(0, y_piv))


static func _torque_tube(d: Dictionary, out: Dictionary, members: Array, dm: float, wall: float, ped: float) -> void:
	var g: Dictionary = d["geo"]
	var spec: Dictionary = d["spec"]
	var lat := float((spec["site"] as Dictionary).get("lat_deg", 35.0))
	var L := float(g["length"])
	var a := float(g["a"])
	var yr := float(g["rec_y"])
	var cpc := bool(g.get("cpc", false))
	var spacing := float((spec["structure"] as Dictionary)["pylon_spacing_m"])
	var n := maxi(int(ceil(L / maxf(spacing, 0.5))), 1) + 1
	var mode := str((spec["tracking"] as Dictionary)["mode"])
	# The tube's axis in the world, as CspLabSite.pose turns it (a fixed
	# trough is tilted to the latitude about an east–west axis).
	var ax := Vector3(0, 0, 1)
	if mode == "ew_horizontal" or mode == "fixed":
		ax = Vector3(1, 0, 0)
	elif mode == "polar":
		ax = CspLabSite.polar_axis(lat)
	var sd := maxf(dm * 0.35, 0.02)
	var st2 := maxf(wall * 0.6, 0.0012)
	# The back of the mirror: its profile offset behind it along the normals.
	var off := 0.012 + sd * 0.5
	var back: Array = []
	if cpc:
		var p: Dictionary = g["cpc_prof"]
		var rp: PackedVector2Array = p["right"]
		var rn: PackedVector2Array = p["normals_r"]
		var half: Array = []
		var step := maxi(rp.size() / 10, 1)
		var i := 0
		while i < rp.size() - 1:
			half.append(rp[i] - rn[i] * off)
			i += step
		half.append(rp[rp.size() - 1] - rn[rn.size() - 1] * off)
		for j in range(half.size() - 1, 0, -1):
			var q: Vector2 = half[j]
			back.append(Vector2(-q.x, q.y))
		back.append_array(half)
	else:
		var f := float(g["f"])
		for k in 13:
			var x := -a + 2.0 * a * k / 12.0
			var bp := _par_back(absf(x), f, off)
			back.append(Vector2(bp.x * signf(x), bp.y))
	var y_low := INF
	for q3 in back:
		y_low = minf(y_low, (q3 as Vector2).y)
	# The torque tube runs behind the vertex; the ribs' arms reach out from it.
	var pv := Vector3(0, y_low - dm * 0.5 - sd * 0.5, 0)
	out["pivot_local"] = pv
	var reach := absf(yr - pv.y) + float(g["rec_r"]) + 0.05
	for q4 in back:
		reach = maxf(reach, (q4 as Vector2).distance_to(Vector2(pv.x, pv.y)))
	var pw: Vector3 = out["pivot_world"]
	pw.y = maxf(ped, reach + 0.25)
	if ax.y > 0.0:
		pw.y = maxf(pw.y, ax.y * L * 0.5 + reach + 0.3)
	out["pivot_world"] = pw
	out["pylons"] = n
	out["swing_r"] = reach
	var drive_i := int(round(float(n - 1) * 0.5))
	for i2 in n:
		var z := -L * 0.5 + L * float(i2) / float(n - 1)
		var top := pw + ax * z
		members.append(_concrete(Vector3(top.x, 0, top.z), clampf(dm * 3.0, 0.3, 1.5), clampf(top.y * 0.45, 0.6, 2.5), "base", "Pylon footing"))
		members.append(_tube(Vector3(top.x, 0.1, top.z), top - Vector3(0, dm * 0.75, 0), dm * 1.1, wall, "base", "Pylon"))
		members.append(_box(top - Vector3(0, dm * 0.8, 0), top + Vector3(0, dm * 0.55, 0), dm * 1.5, dm * 1.5, "base", 4.0,
			"Saddle clamp" if mode == "fixed" else ("Drive" if i2 == drive_i else "Bearing")))
	# Rib stations: at every pylon and half-way between them.
	var nst := (n - 1) * 2
	for k2 in nst + 1:
		var z2 := -L * 0.5 + L * float(k2) / float(maxi(nst, 1))
		for k3 in range(1, back.size()):
			var q5: Vector2 = back[k3 - 1]
			var q6: Vector2 = back[k3]
			members.append(_tube(Vector3(q5.x, q5.y, z2), Vector3(q6.x, q6.y, z2), sd, st2, "optic", "Rib"))
		for fr in [0.35, 0.75, 1.0]:
			for sgn in [-1.0, 1.0]:
				var idx := clampi(int(round((back.size() - 1) * (0.5 + 0.5 * float(sgn) * float(fr)))), 0, back.size() - 1)
				var q7: Vector2 = back[idx]
				members.append(_tube(pv + Vector3(0, 0, z2), Vector3(q7.x, q7.y, z2), sd * 0.9, st2, "optic", "Rib arm"))
		if not cpc and k2 % 2 == 0:
			members.append(_tube(Vector3(0, (back[back.size() / 2] as Vector2).y, z2), Vector3(0, yr - float(g["rec_r"]) * 1.9, z2),
				sd * 0.7, st2, "optic", "Receiver support"))
	members.append(_tube(pv + Vector3(0, 0, -L * 0.5), pv + Vector3(0, 0, L * 0.5), dm, wall, "optic", "Torque tube"))
	for fr2 in [0.2, 0.6, 0.95]:
		for sgn2 in [-1.0, 1.0]:
			var idx2 := clampi(int(round((back.size() - 1) * (0.5 + 0.5 * float(sgn2) * float(fr2)))), 0, back.size() - 1)
			var q8: Vector2 = back[idx2]
			members.append(_tube(Vector3(q8.x, q8.y - sd * 0.8, -L * 0.5), Vector3(q8.x, q8.y - sd * 0.8, L * 0.5), sd * 0.7, st2, "optic", "Purlin"))
	if cpc and str(g.get("profile", "")) == "cpc_tube":
		# The pipe rides on hangers from a tie across the top of each end rib,
		# clear of the cusp underneath.
		var yt := float(g["y_top"])
		var xt := (back[back.size() - 1] as Vector2).x
		for zz in [-L * 0.5, L * 0.5]:
			members.append(_tube(Vector3(-xt, yt, float(zz)), Vector3(xt, yt, float(zz)), sd * 0.7, st2, "optic", "End tie"))
			members.append(_tube(Vector3(0, yr, float(zz)), Vector3(0, yt, float(zz)), sd * 0.6, st2, "optic", "Pipe hanger"))


static func _row_frame(d: Dictionary, out: Dictionary, members: Array, dm: float, wall: float) -> void:
	var g: Dictionary = d["geo"]
	var spec: Dictionary = d["spec"]
	var fb := CspLabSite.field_basis(spec)
	var L := float(g["length"])
	var H := float(g["H"])
	var xs: PackedFloat64Array = g["xs"]
	var spacing := float((spec["structure"] as Dictionary)["pylon_spacing_m"])
	var n := maxi(int(ceil(L / maxf(spacing, 0.5))), 1) + 1
	var row_h := 0.7
	out["row_h"] = row_h
	out["pivot_world"] = Vector3(0, row_h, 0)
	var sd := maxf(dm * 0.45, 0.025)
	var st2 := maxf(wall * 0.6, 0.0012)
	for x in xs:
		members.append(_tube(fb * Vector3(x, row_h, -L * 0.5), fb * Vector3(x, row_h, L * 0.5), sd * 0.8, st2, "base", "Row shaft"))
		for i in n:
			var z := -L * 0.5 + L * float(i) / float(n - 1)
			members.append(_concrete(fb * Vector3(x, 0, z), maxf(sd * 4.0, 0.25), 0.5, "base", "Row post footing"))
			members.append(_tube(fb * Vector3(x, 0.1, z), fb * Vector3(x, row_h - 0.04, z), sd, st2, "base", "Row post"))
			members.append(_box(fb * Vector3(x, row_h - 0.05, z), fb * Vector3(x, row_h + 0.04, z), sd * 2.0, sd * 2.0, "base", 0.8, "Row bearing"))
		members.append(_tube(fb * Vector3(x, row_h, -L * 0.5 - 0.02), fb * Vector3(x, row_h - 0.18, -L * 0.5 - 0.08),
			sd * 0.5, st2, "base", "Row crank"))
	# Every row turns together off one drive, through a link bar along the
	# cranks at one end (how small linear Fresnel fields are built).
	members.append(_tube(fb * Vector3(xs[0], row_h - 0.18, -L * 0.5 - 0.08), fb * Vector3(xs[xs.size() - 1], row_h - 0.18, -L * 0.5 - 0.08),
		sd * 0.6, st2, "base", "Row link bar"))
	members.append(_box(fb * Vector3(xs[0] - 0.3, row_h - 0.3, -L * 0.5 - 0.08), fb * Vector3(xs[0] - 0.3, row_h - 0.05, -L * 0.5 - 0.08),
		0.16, 0.16, "base", 6.0, "Row drive"))
	# The receiver on A-frames.
	var xm := float(g["total"]) * 0.5 + 0.25
	var head := row_h + H + 0.15
	for i in n:
		var z2 := -L * 0.5 + L * float(i) / float(n - 1)
		for side in [-1.0, 1.0]:
			var s := float(side)
			members.append(_concrete(fb * Vector3(s * xm, 0, z2), clampf(dm * 3.5, 0.3, 1.2), 0.8, "base", "Mast footing"))
			members.append(_tube(fb * Vector3(s * xm, 0.1, z2), fb * Vector3(s * xm * 0.15, head, z2), dm, wall, "base", "Receiver mast"))
		members.append(_tube(fb * Vector3(-xm * 0.62, head * 0.45, z2), fb * Vector3(xm * 0.62, head * 0.45, z2), dm * 0.5, wall, "base", "Mast tie"))
		members.append(_tube(fb * Vector3(-xm * 0.15, head, z2), fb * Vector3(xm * 0.15, head, z2), dm * 0.7, wall, "base", "Mast head"))
	for i2 in range(1, n):
		var za := -L * 0.5 + L * float(i2 - 1) / float(n - 1)
		var zb := -L * 0.5 + L * float(i2) / float(n - 1)
		members.append(_tube(fb * Vector3(0, head - 0.05, za), fb * Vector3(0, head * 0.7, (za + zb) * 0.5), dm * 0.4, wall, "base", "Longitudinal brace"))
		members.append(_tube(fb * Vector3(0, head * 0.7, (za + zb) * 0.5), fb * Vector3(0, head - 0.05, zb), dm * 0.4, wall, "base", "Longitudinal brace"))
	members.append(_tube(fb * Vector3(0, head, -L * 0.5), fb * Vector3(0, head, L * 0.5), dm * 0.7, wall, "base", "Receiver beam"))


static func _tower(d: Dictionary, out: Dictionary, members: Array, dm: float, wall: float, mount: String) -> void:
	var g: Dictionary = d["geo"]
	var H := float(g["H"])
	var top := H - float(g["panel_h"]) * 0.5
	out["pivot_world"] = Vector3.ZERO
	var tw := maxf(H / 40.0, 0.3)
	var corners := [Vector2(1, 1), Vector2(-1, 1), Vector2(-1, -1), Vector2(1, -1)]
	if mount == "monopole":
		members.append(_concrete(Vector3.ZERO, clampf(dm * 3.0, 1.0, 5.0), clampf(H * 0.15, 1.0, 8.0), "base", "Tower foundation"))
		members.append(_tube(Vector3(0, 0.1, 0), Vector3(0, top - 0.12, 0), dm, wall, "base", "Monopole"))
		tw = dm * 0.7
	else:
		var b := maxf(H / 12.0, 0.6)
		var levels := maxi(int(H / maxf(b * 1.6, 1.5)), 2)
		for c in corners:
			var cv: Vector2 = c
			members.append(_concrete(Vector3(cv.x * b, 0, cv.y * b), clampf(dm * 4.0, 0.5, 2.0), clampf(H * 0.06, 0.8, 3.0), "base", "Leg footing"))
			members.append(_tube(Vector3(cv.x * b, 0.1, cv.y * b), Vector3(cv.x * tw, top - 0.12, cv.y * tw), dm, wall, "base", "Tower leg"))
		var bd := maxf(dm * 0.45, 0.03)
		for lv in levels:
			var y0 := (top - 0.12) * float(lv) / float(levels)
			var y1 := (top - 0.12) * float(lv + 1) / float(levels)
			var w0 := lerpf(b, tw, float(lv) / float(levels))
			var w1 := lerpf(b, tw, float(lv + 1) / float(levels))
			for k in 4:
				var c0: Vector2 = corners[k]
				var c1: Vector2 = corners[(k + 1) % 4]
				members.append(_tube(Vector3(c0.x * w0, y0, c0.y * w0), Vector3(c1.x * w1, y1, c1.y * w1), bd, wall * 0.7, "base", "Brace"))
				members.append(_tube(Vector3(c1.x * w0, y0, c1.y * w0), Vector3(c0.x * w1, y1, c0.y * w1), bd, wall * 0.7, "base", "Brace"))
				members.append(_tube(Vector3(c0.x * w1, y1, c0.y * w1), Vector3(c1.x * w1, y1, c1.y * w1), bd, wall * 0.7, "base", "Girt"))
	# A work platform under the receiver, with a guard rail (kept within the
	# tower's own footprint so it shades no light on its way up).
	var hp := maxf(tw * 1.4, 0.6)
	members.append(_box(Vector3(0, top - 0.12, 0), Vector3(0, top - 0.04, 0), hp * 2.0, hp * 2.0, "base", hp * hp * 4.0 * 45.0, "Receiver platform"))
	for k2 in 4:
		var c2: Vector2 = corners[k2]
		var c3: Vector2 = corners[(k2 + 1) % 4]
		members.append(_tube(Vector3(c2.x * hp, top + 1.0, c2.y * hp), Vector3(c3.x * hp, top + 1.0, c3.y * hp), 0.042, 0.003, "base", "Guard rail"))
		members.append(_tube(Vector3(c2.x * hp, top - 0.04, c2.y * hp), Vector3(c2.x * hp, top + 1.0, c2.y * hp), 0.042, 0.003, "base", "Rail post"))
	# Heliostats: each on a pier, a pedestal and its two-axis drive.
	var cs: PackedVector3Array = g["centres"]
	var hd := clampf(float(g["hw"]) * 0.05, 0.06, 0.35)
	for c4 in cs:
		members.append(_concrete(Vector3(c4.x, 0, c4.z), hd * 2.5, clampf(float(g["hh"]) * 0.5, 0.6, 3.0), "base", "Heliostat pier"))
		members.append(_tube(Vector3(c4.x, 0.1, c4.z), c4 - Vector3(0, hd * 1.2, 0), hd, maxf(hd * 0.05, 0.003), "base", "Heliostat pedestal"))
		members.append(_box(c4 - Vector3(0, hd * 1.2, 0), c4 - Vector3(0, hd * 0.35, 0), hd * 1.6, hd * 1.6, "base", 9.0, "Heliostat drive"))


# ---------------------------------------------------------------------------
# Loads and checks
# ---------------------------------------------------------------------------

static func _loads(d: Dictionary, out: Dictionary, mat: Dictionary, dm: float, wall: float,
		ped: float, v_op: float, v_s: float, mount: String) -> void:
	var g: Dictionary = d["geo"]
	var spec: Dictionary = d["spec"]
	var checks: Array = out["checks"]
	var q_op := q_wind(v_op)
	var q_s := q_wind(v_s)
	var tp := tube_props(dm, wall)
	var fy := float(mat["fy"])
	var e_mod := float(mat["E"])
	var slope := float((spec["trace"] as Dictionary)["slope_err_mrad"])
	var drive_pick := str((spec["structure"] as Dictionary)["drive"])
	var optic_kg := float(d.get("optic_mass_kg", 0.0))
	var moving_kg := optic_kg + float(out["mass_kg"]) * 0.35 + float(out.get("counterweight_kg", 0.0))
	var t := str(spec["type"])
	var loads := {}
	match mount:
		"pedestal_azel", "polar_mount":
			var area := float(g["A_ap"])
			var chord := float(g.get("a", 0.5)) * 2.0
			var f_op := q_op * CD_FACE * area
			var f_st := q_s * CD_STOW * area
			var m_el := q_op * CM_FACE * area * chord
			var m_st := q_s * CM_STOW * area * chord
			var m_base := maxf(f_op, f_st) * ped
			var weight := moving_kg * G
			var sigma := m_base / float(tp["Z"]) + weight / float(tp["A"])
			var util := sigma / (fy / SAFETY)
			var defl := f_op * ped * ped / (2.0 * e_mod * float(tp["I"])) * 1000.0
			loads = {"wind_force_n": f_op, "stow_force_n": f_st, "hinge_nm": m_el, "stow_hinge_nm": m_st,
				"base_moment_nm": m_base, "stress_mpa": sigma / 1e6, "utilisation": util, "deflection_mrad": defl,
				"moving_kg": moving_kg}
			var turn := m_el * 1.25 + FRICTION_NM
			var hold := maxf(m_el, m_st) * SAFETY
			out["drive"] = _drive(drive_pick, turn, hold)
			loads["drive_turn_nm"] = turn
			loads["drive_hold_nm"] = hold
			_stress_check(checks, util, "Pedestal post", sigma, fy)
			if defl > slope * 0.5:
				checks.append({"level": "warn", "text": "The post bends %.1f mrad in the tracking wind — more than half the surface error. Use a stiffer post." % defl,
					"why": "A pointing error moves the whole focal spot; a mirror doubles it."})
			var swing := float(out.get("swing_r", 0.0))
			if swing > ped + 0.05:
				var min_el := rad_to_deg(asin(clampf(ped / maxf(swing, 1e-6), 0.0, 1.0)))
				checks.append({"level": "warn", "text": "The optic reaches %.2f m from the axis but the axis is %.2f m up: it can't point below ~%.0f° without hitting the ground." % [swing, ped, 90.0 - min_el],
					"why": "Raise the axis height above the swing radius, or accept a later start in the morning."})
		"torque_tube":
			var w := float(g["a"]) * 2.0
			var L := float(g["length"])
			var spacing := L / float(maxi(int(out.get("pylons", 2)) - 1, 1))
			var trib := w * spacing
			var f_p := maxf(q_op * CD_FACE, q_s * CD_STOW) * trib
			var pw: Vector3 = out["pivot_world"]
			var h := pw.y
			var m_p := f_p * h
			var weight2 := (optic_kg / float(maxi(int(out.get("pylons", 2)), 1)) + 30.0) * G
			var sig_p := m_p / float(tp["Z"]) + weight2 / float(tp["A"])
			var util_p := sig_p / (fy / SAFETY)
			# Twist of the tube from the central drive to an end:
			# m_t per metre = q·Cm·w·w, φ = m_t (L/2)² / (2 G J).
			var m_t := q_op * CM_FACE * w * w
			var gj := float(mat["G"]) * float(tp["J"])
			var twist := m_t * (L * 0.5) * (L * 0.5) / (2.0 * gj) * 1000.0
			var t_max := m_t * L * 0.5
			var tau := t_max * dm * 0.5 / float(tp["J"])
			var util_t := tau / (fy / (SAFETY * sqrt(3.0)))
			loads = {"wind_force_n": f_p, "base_moment_nm": m_p, "stress_mpa": sig_p / 1e6, "utilisation": maxf(util_p, util_t),
				"twist_mrad": twist, "torque_nm": t_max * 2.0, "tube_shear_mpa": tau / 1e6, "moving_kg": moving_kg}
			var turn2 := t_max * 2.0 * 1.25 + FRICTION_NM
			var hold2 := maxf(t_max * 2.0, q_s * CM_STOW * w * w * L) * SAFETY
			out["drive"] = _drive(drive_pick, turn2, hold2)
			loads["drive_turn_nm"] = turn2
			loads["drive_hold_nm"] = hold2
			_stress_check(checks, util_p, "Pylon", sig_p, fy)
			_stress_check(checks, util_t, "Torque tube (shear)", tau, fy / sqrt(3.0))
			if twist > slope:
				checks.append({"level": "warn", "text": "The torque tube twists %.1f mrad at its ends in the tracking wind (surface error is %.1f): the end modules aim off. Use a bigger tube or a drive at each end." % [twist, slope],
					"why": "Twist rotates the far mirror modules about the axis, which a mirror doubles into a focal-line error."})
		"row_frame":
			var w2 := float(g["w"])
			var L2 := float(g["length"])
			var m_row := q_op * CM_FACE * w2 * w2 * L2
			var turn3 := m_row * 1.25 + FRICTION_NM * 0.25
			var hold3 := maxf(m_row, q_s * CM_STOW * w2 * w2 * L2) * SAFETY
			out["drive"] = _drive(drive_pick, turn3, hold3)
			var spacing2 := float((spec["structure"] as Dictionary)["pylon_spacing_m"])
			var f_rec := q_s * CD_FACE * (float(g["size"]) + 0.3) * spacing2 * 0.5
			var H := float(g["H"]) + float(out.get("row_h", 0.7))
			# Two masts lean in to each mast head (an A-frame): each carries half.
			var m_m := f_rec * H * 0.5
			var sig_m := m_m / float(tp["Z"])
			var util_m := sig_m / (fy / SAFETY)
			loads = {"wind_force_n": f_rec, "base_moment_nm": m_m, "stress_mpa": sig_m / 1e6, "utilisation": util_m,
				"row_torque_nm": m_row, "drive_turn_nm": turn3, "drive_hold_nm": hold3}
			_stress_check(checks, util_m, "Receiver mast", sig_m, fy)
		"lattice_tower", "monopole":
			var H2 := float(g["H"])
			var a_rec := float(g["panel_w"]) * float(g["panel_h"])
			var f_r := q_s * CD_FACE * a_rec
			var w_t := dm * 0.7 if mount == "monopole" else maxf(H2 / 12.0, 0.6) * 0.6
			var f_t := q_s * 0.9 * w_t * H2
			var m_b := f_r * H2 + f_t * H2 * 0.5
			var wr := 600.0 * G
			var sig := 0.0
			if mount == "monopole":
				sig = m_b / float(tp["Z"]) + wr / float(tp["A"])
			else:
				var b := maxf(H2 / 12.0, 0.6)
				var n_leg := m_b / (2.0 * b) + wr * 0.25
				sig = n_leg / float(tp["A"])
			var util2 := sig / (fy / SAFETY)
			# One heliostat.
			var ha := float(g["hw"]) * float(g["hh"])
			var hchord := maxf(float(g["hw"]), float(g["hh"]))
			var m_h := q_op * CM_FACE * ha * hchord
			var turn4 := m_h * 1.25 + FRICTION_NM
			var hold4 := maxf(m_h, q_s * CM_STOW * ha * hchord) * SAFETY
			out["drive"] = _drive(drive_pick, turn4, hold4)
			loads = {"wind_force_n": f_r + f_t, "base_moment_nm": m_b, "stress_mpa": sig / 1e6, "utilisation": util2,
				"heliostat_hinge_nm": m_h, "drive_turn_nm": turn4, "drive_hold_nm": hold4}
			_stress_check(checks, util2, "Tower leg" if mount != "monopole" else "Monopole", sig, fy)
	out["loads"] = loads
	var drv: Dictionary = out.get("drive", {}) as Dictionary
	if not drv.is_empty():
		if float(drv["turn_nm"]) < float(loads.get("drive_turn_nm", 0.0)) or float(drv["hold_nm"]) < float(loads.get("drive_hold_nm", 0.0)):
			checks.append({"level": "error", "text": "The %s can't turn or hold this in the wind (needs %.0f N·m turning, %.0f N·m holding)." % [str(drv["label"]), float(loads.get("drive_turn_nm", 0.0)), float(loads.get("drive_hold_nm", 0.0))],
				"why": "Choose a bigger drive, or Auto picks the smallest that holds."})
		if not bool(drv.get("powered", true)) and t != "tower" and str((spec["tracking"] as Dictionary)["mode"]) != "fixed":
			checks.append({"level": "info", "text": "A hand-crank drive means someone re-aims it every 10–20 min (a point focus) or hour (a trough).",
				"why": "The sun moves 0.25° a minute; a point focus spills after a few minutes."})


static func _drive(pick: String, turn: float, hold: float) -> Dictionary:
	if pick != "auto":
		for dv in CspLabParts.DRIVES:
			if str((dv as Dictionary)["id"]) == pick:
				return dv as Dictionary
	return CspLabParts.pick_drive(turn, hold)


static func _stress_check(checks: Array, util: float, what: String, sigma: float, fy: float) -> void:
	if util > 1.0:
		checks.append({"level": "error", "text": "%s overstressed: %.0f MPa against %.0f allowed (×%.1f safety). Use a bigger section or a stronger material." % [what, sigma / 1e6, fy / SAFETY / 1e6, SAFETY],
			"why": "Survival wind (stowed) or tracking wind (face-on), whichever is worse."})
	elif util > 0.8:
		checks.append({"level": "warn", "text": "%s at %.0f %% of its allowed stress." % [what, util * 100.0],
			"why": "Little margin for gusts, corrosion or a stuck stow."})

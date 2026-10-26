class_name GantryLabKinematics
extends RefCounted

## The maths of a CNC gantry, pure and cited.
##
##   steps_per_mm      belt: steps·µsteps / (teeth·pitch); screw: steps·µsteps / lead
##   motor_positions   tool (x, y, z) mm → what each motor has moved, per kinematics
##                     (CoreXY: A = x + y, B = x − y — Moyer 2012, corexy.com;
##                      H-bot the same equations on one belt; CoreXZ swaps y for z;
##                      delta: carriage_i = z + sqrt(L² − |T_i − (x, y)|²), the
##                      three-tower inverse kinematics every delta firmware runs)
##   delta_forward     carriages → effector by sphere trilateration (Marlin's
##                     forward_kinematics_DELTA; Wikipedia "Trilateration")
##   motor_velocity    |d(motor)/dt| per 1 mm/s of tool speed along a direction
##   drive_force_n     usable force from a motor through its drive
##   belt_stretch_mm   F·L / k
##   screw_critical_rpm  Nc = 4.76e6 · d_root · C / L²  (Thomson lead screw guide,
##                     d, L in mm; C = 1.0 supported-supported)
##   beam_sag_m        δ = F L³ / (48 E I), simply supported, centre load
##                     (Gere & Timoshenko, Mechanics of Materials)
##   natural_hz        f = (1/2π)·√(k/m): the toolhead on its belts, the ringing
##                     frequency input shaping is tuned to.

## Stepper torque falls with speed; the usable share of holding torque for an
## acceleration budget is commonly taken as half (Gecko Drive "Step motor
## basics"; the mid-speed torque curve of a 24 V NEMA 17).
const USABLE_TORQUE := 0.5
## Delta arm angle above horizontal never below this (rod-end binding, and
## the arms' effective stiffness collapses toward horizontal).
const DELTA_MIN_ARM_DEG := 20.0

const DELTA_TOWER_DEG := [210.0, 330.0, 90.0]


static func steps_per_mm(axis: Dictionary) -> float:
	var motor := GantryLabParts.motor(str(axis["motor"]))
	var drive := GantryLabParts.drive(str(axis["drive"]))
	var steps := float(motor["steps"]) * float(axis["microsteps"])
	match str(drive["kind"]):
		"belt":
			return steps / (float(axis["pulley_teeth"]) * float(drive["pitch_mm"]))
		"screw", "rack":
			return steps / float(drive["lead_mm"])
	return steps / 40.0


## mm the tool moves per motor revolution.
static func mm_per_rev(axis: Dictionary) -> float:
	var drive := GantryLabParts.drive(str(axis["drive"]))
	if str(drive["kind"]) == "belt":
		return float(axis["pulley_teeth"]) * float(drive["pitch_mm"])
	return float(drive["lead_mm"])


## The smallest commandable move (one microstep).
static func resolution_mm(axis: Dictionary) -> float:
	var spm := steps_per_mm(axis)
	return 1.0 / spm if spm > 0.0 else 0.0


## Tool-speed cap from the board's step rate.
static func max_speed_mm_s(axis: Dictionary, max_step_hz: float) -> float:
	var spm := steps_per_mm(axis)
	return max_step_hz / spm if spm > 0.0 else 0.0


## Usable force at the carriage from one motor through its drive (N).
static func drive_force_n(axis: Dictionary) -> float:
	var motor := GantryLabParts.motor(str(axis["motor"]))
	var drive := GantryLabParts.drive(str(axis["drive"]))
	var t := float(motor["torque_nm"]) * USABLE_TORQUE
	var eff := float(drive["eff"])
	if str(drive["kind"]) == "belt":
		var r_m := float(axis["pulley_teeth"]) * float(drive["pitch_mm"]) / TAU * 0.001
		return t * eff / maxf(r_m, 1e-6)
	# Screw / rack: F = 2π T η / lead (lead in m).
	return TAU * t * eff / maxf(float(drive["lead_mm"]) * 0.001, 1e-6)


## Acceleration (mm/s²) a motor can give a moving mass (kg), after friction
## and gravity along the axis (`lift_g` = 1 for a Z lifting its load).
static func accel_capable_mm_s2(axis: Dictionary, moving_kg: float, lift_g: float = 0.0, friction_n: float = 2.0) -> float:
	var f := drive_force_n(axis) * float(axis["motors"]) - friction_n - moving_kg * 9.81 * lift_g
	if moving_kg <= 1e-6:
		return 0.0
	return maxf(f, 0.0) / moving_kg * 1000.0


## Belt stretch (mm) under a force over a belt span (m). k_n_per_m_at_1m is
## the spring rate of one metre of belt; a longer belt is proportionally softer.
static func belt_stretch_mm(drive: Dictionary, force_n: float, span_m: float) -> float:
	var k1 := float(drive.get("k_n_per_m_at_1m", 11000.0))
	if k1 <= 0.0 or span_m <= 0.0:
		return 0.0
	var k := k1 / span_m
	return force_n / k * 1000.0


## Critical (whipping) speed of a lead / ball screw, rpm.
static func screw_critical_rpm(drive: Dictionary, length_mm: float, end_factor: float = 1.0) -> float:
	if str(drive.get("kind", "")) != "screw" or length_mm <= 0.0:
		return INF
	var d := float(drive.get("root_mm", float(drive.get("d_mm", 8.0)) * 0.8))
	return 4.76e6 * d * end_factor / (length_mm * length_mm)


## Max tool speed (mm/s) a screw allows at 80 % of its critical speed.
static func screw_max_speed_mm_s(drive: Dictionary, length_mm: float) -> float:
	var nc := screw_critical_rpm(drive, length_mm)
	if not is_finite(nc):
		return INF
	return nc * 0.8 / 60.0 * float(drive.get("lead_mm", 8.0))


## Mid-span sag (m) of a simply supported beam under a centre load.
static func beam_sag_m(force_n: float, span_m: float, i_m4: float) -> float:
	if i_m4 <= 0.0 or span_m <= 0.0:
		return 0.0
	return force_n * pow(span_m, 3.0) / (48.0 * GantryLabParts.ALU_E_PA * i_m4)


## Cantilever tip sag (m) — a Z column holding a tool out on an arm.
static func cantilever_sag_m(force_n: float, length_m: float, i_m4: float) -> float:
	if i_m4 <= 0.0 or length_m <= 0.0:
		return 0.0
	return force_n * pow(length_m, 3.0) / (3.0 * GantryLabParts.ALU_E_PA * i_m4)


## The toolhead's ringing frequency on its belt (Hz): two spans in parallel.
static func natural_hz(drive: Dictionary, moving_kg: float, span_m: float) -> float:
	var k1 := float(drive.get("k_n_per_m_at_1m", 11000.0))
	if moving_kg <= 0.0 or span_m <= 0.0 or k1 <= 0.0:
		return 0.0
	var k := 2.0 * k1 / span_m
	return sqrt(k / moving_kg) / TAU


# ---------------------------------------------------------------------------
# Inverse kinematics: tool mm → motor mm
# ---------------------------------------------------------------------------

## Motor displacements (mm) for a tool position. Returns an Array of
## {label, mm}: three entries for every kinematics.
static func motor_positions(spec: Dictionary, tool_mm: Vector3) -> Array:
	var kin := str(spec["kinematics"])
	match kin:
		"corexy", "hbot":
			return [{"label": "A", "mm": tool_mm.x + tool_mm.y}, {"label": "B", "mm": tool_mm.x - tool_mm.y},
				{"label": "Z", "mm": tool_mm.z}]
		"corexz":
			return [{"label": "A", "mm": tool_mm.x + tool_mm.z}, {"label": "B", "mm": tool_mm.x - tool_mm.z},
				{"label": "Y", "mm": tool_mm.y}]
		"delta":
			var c := delta_carriages(spec, tool_mm)
			return [{"label": "Tower A", "mm": c[0]}, {"label": "Tower B", "mm": c[1]}, {"label": "Tower C", "mm": c[2]}]
	return [{"label": "X", "mm": tool_mm.x}, {"label": "Y", "mm": tool_mm.y}, {"label": "Z", "mm": tool_mm.z}]


## Per-motor speed per 1 mm/s of tool speed along unit direction d.
static func motor_velocity(spec: Dictionary, d: Vector3, at_mm: Vector3 = Vector3.ZERO) -> PackedFloat32Array:
	var kin := str(spec["kinematics"])
	match kin:
		"corexy", "hbot":
			return PackedFloat32Array([absf(d.x + d.y), absf(d.x - d.y), absf(d.z)])
		"corexz":
			return PackedFloat32Array([absf(d.x + d.z), absf(d.x - d.z), absf(d.y)])
		"delta":
			# Numerical derivative of the carriage heights along d.
			var h := 0.5
			var a := delta_carriages(spec, at_mm - d * h)
			var b := delta_carriages(spec, at_mm + d * h)
			var out := PackedFloat32Array()
			for i in 3:
				var va := float(a[i])
				var vb := float(b[i])
				out.append(absf(vb - va) / (2.0 * h) if is_finite(va) and is_finite(vb) else 1.0)
			return out
	return PackedFloat32Array([absf(d.x), absf(d.y), absf(d.z)])


## Delta geometry: the delta radius and the three tower positions (mm, in the
## bed plane: X right, Y away).
static func delta_radius_mm(spec: Dictionary) -> float:
	var dl: Dictionary = spec["delta"]
	return float(dl["tower_r_mm"]) - float(dl["effector_r_mm"]) - float(dl["carriage_r_mm"])


static func delta_towers(spec: Dictionary) -> Array:
	var r := delta_radius_mm(spec)
	var out: Array = []
	for ang in DELTA_TOWER_DEG:
		var a := deg_to_rad(float(ang))
		out.append(Vector2(cos(a) * r, sin(a) * r))
	return out


## Carriage heights (mm above the effector's z) for a tool position; NaN for
## an unreachable point.
static func delta_carriages(spec: Dictionary, tool_mm: Vector3) -> PackedFloat32Array:
	var l := float(spec["delta"]["arm_mm"])
	var out := PackedFloat32Array()
	for t in delta_towers(spec):
		var tv: Vector2 = t
		var dx := tool_mm.x - tv.x
		var dy := tool_mm.y - tv.y
		var s := l * l - dx * dx - dy * dy
		out.append(tool_mm.z + sqrt(s) if s >= 0.0 else NAN)
	return out


## Effector position from three carriage heights (trilateration). Returns
## Vector3(NAN…) when the spheres do not meet.
static func delta_forward(spec: Dictionary, carriages: PackedFloat32Array) -> Vector3:
	var l := float(spec["delta"]["arm_mm"])
	var tw := delta_towers(spec)
	var p1 := Vector3((tw[0] as Vector2).x, (tw[0] as Vector2).y, carriages[0])
	var p2 := Vector3((tw[1] as Vector2).x, (tw[1] as Vector2).y, carriages[1])
	var p3 := Vector3((tw[2] as Vector2).x, (tw[2] as Vector2).y, carriages[2])
	var ex := (p2 - p1).normalized()
	var i := ex.dot(p3 - p1)
	var ey := (p3 - p1 - ex * i).normalized()
	var ez := ex.cross(ey)
	var d := (p2 - p1).length()
	var j := ey.dot(p3 - p1)
	var x := d * 0.5
	var y := (i * i + j * j) / (2.0 * j) - i * x / j
	var zz := l * l - x * x - y * y
	if zz < 0.0 or d <= 1e-6 or absf(j) <= 1e-6:
		return Vector3(NAN, NAN, NAN)
	var z := -sqrt(zz)  # the effector hangs BELOW the carriages
	return p1 + ex * x + ey * y + ez * z


## The circle a delta can reach with every arm at least DELTA_MIN_ARM_DEG
## above horizontal, and how much of the tower height the arms eat.
static func delta_reach(spec: Dictionary) -> Dictionary:
	var l := float(spec["delta"]["arm_mm"])
	var r := delta_radius_mm(spec)
	var horiz := l * cos(deg_to_rad(DELTA_MIN_ARM_DEG))
	var reach := horiz - r
	# At the centre every arm is at the same angle: cos a = R / L.
	var centre_cos := clampf(r / l, 0.0, 1.0)
	var centre_deg := rad_to_deg(acos(centre_cos))
	# Carriage height above the effector at the centre and at the edge.
	var h_centre := sqrt(maxf(l * l - r * r, 0.0))
	var h_edge := l * sin(deg_to_rad(DELTA_MIN_ARM_DEG))
	return {"reach_mm": reach, "centre_arm_deg": centre_deg, "h_centre_mm": h_centre,
		"h_edge_mm": h_edge, "arm_lost_mm": h_centre - h_edge, "delta_radius_mm": r}


# ---------------------------------------------------------------------------
# Belt lengths (for the BOM) and racking
# ---------------------------------------------------------------------------

## Total belt per shared-belt kinematics (m), from the frame's travel. A
## CoreXY loop is roughly 2 × (X travel + Y travel + overhang) per belt, two
## belts; an H-bot is one belt of that length; a Cartesian axis 2 × travel.
static func belt_length_m(kinematics: String, x_mm: float, y_mm: float, z_mm: float, overhang_mm: float = 120.0) -> Dictionary:
	match kinematics:
		"corexy":
			return {"count": 2, "each_m": 2.0 * (x_mm + y_mm + overhang_mm) / 1000.0}
		"hbot":
			return {"count": 1, "each_m": 2.0 * (2.0 * x_mm + y_mm + overhang_mm) / 1000.0}
		"corexz":
			return {"count": 2, "each_m": 2.0 * (x_mm + z_mm + overhang_mm) / 1000.0}
		"delta":
			return {"count": 3, "each_m": 2.0 * (z_mm + overhang_mm) / 1000.0}
	return {"count": 0, "each_m": 0.0}


## The H-bot's racking moment (N·m) on an X move: the single belt pulls the
## gantry at one end, so the force F acts at the Y rails' half-spacing.
static func hbot_racking_nm(force_n: float, rail_spacing_m: float) -> float:
	return force_n * rail_spacing_m * 0.5

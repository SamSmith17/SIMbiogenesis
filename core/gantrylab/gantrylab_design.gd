class_name GantryLabDesign
extends RefCounted

## The ONE solved gantry design the modal, the builder, the runtime, the BOM
## and the config exports read, cached by the spec's key:
##
##   {spec, layout, bom, motors: [{label, key, steps_per_mm, mm_per_rev,
##     resolution_um, max_mm_s, accel_capable, force_n}], limits {max_feed_mm_s,
##     accel_mm_s2, junction_mm_s, axis_caps, motor_caps, steps_per_mm},
##     stats {…}, checks [{level, text}], delta (reach), graph_preset}
##
## Checks are the engineering a build guide would make you do: step rate vs
## the board, acceleration vs motor torque and moving mass, belt stretch,
## gantry sag, lead-screw whip and back-driving, delta reach, H-bot racking,
## driver count, supply voltage, resolution vs the tool.

static var _cache := {}
const CACHE_MAX := 12

## Cutting force the gantry must hold still against (N): a trim router in
## plywood pushes ~50 N (Bob Warfield, CNCCookbook feeds & speeds), a 2.2 kW
## spindle in aluminium ~120 N; a laser or pen nothing.
const CUT_FORCE_N := {"spindle_500w": 25.0, "router_1250w": 60.0, "spindle_2200w": 120.0}
## Sag tolerance (mm) the process can stand.
const SAG_TOL_MM := {"additive": 0.08, "subtractive": 0.1, "mark": 0.15}
## A Z lead screw never runs at the XY feed: 10 mm/s on a fine Tr8×2, 30 on the rest.
const Z_FEED_SCREW_FINE := 10.0
const Z_FEED_MM_S := 30.0


static func solve(spec: Dictionary) -> Dictionary:
	var s := GantryLabSpec.resolve(spec)
	var key := GantryLabSpec.key_of(s)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(s)
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[key] = d
	return d


static func clear_cache() -> void:
	_cache.clear()


static func _solve(s: Dictionary) -> Dictionary:
	var d := {"spec": s}
	var lay := GantryLabFrame.layout(s)
	d["layout"] = lay
	d["bom"] = GantryLabBom.compute(s, lay)
	var kin := str(s["kinematics"])
	var e: Dictionary = s["electronics"]
	var board := GantryLabParts.board(str(e["board"]))
	var max_hz := float(board["max_step_hz"])
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var moving: Dictionary = lay["moving_kg"]
	# --- Per-motor numbers ---------------------------------------------------
	var motors: Array = []
	var spm_arr := PackedFloat32Array()
	var caps_arr := PackedFloat32Array()
	for m in GantryLabSpec.motor_axes(kin):
		var k := str(m["key"])
		var a: Dictionary = s["axis"][k]
		var spm := GantryLabKinematics.steps_per_mm(a)
		var mx := GantryLabKinematics.max_speed_mm_s(a, max_hz)
		var dr := GantryLabParts.drive(str(a["drive"]))
		var screw_len := _screw_len_mm(kin, k, s, lay)
		var screw_cap := GantryLabKinematics.screw_max_speed_mm_s(dr, screw_len)
		var cap := minf(mx, screw_cap)
		var lift := 0.0
		if (k == "z" and kin != "corexz" and kin != "delta") or (kin == "corexz" and k != "y"):
			lift = 1.0 if k == "z" else 0.5
		var mass := float(moving.get(k if kin != "delta" else "z", 1.0))
		if kin == "corexy" or kin == "hbot":
			mass = float(moving["x"]) if k != "z" else float(moving["z"])
		var acc := GantryLabKinematics.accel_capable_mm_s2(a, mass, lift)
		motors.append({"label": str(m["label"]), "key": k, "steps_per_mm": spm, "mm_per_rev": GantryLabKinematics.mm_per_rev(a),
			"resolution_um": GantryLabKinematics.resolution_mm(a) * 1000.0, "max_mm_s": cap, "step_cap_mm_s": mx,
			"screw_cap_mm_s": screw_cap, "accel_capable": acc, "force_n": GantryLabKinematics.drive_force_n(a) * float(a["motors"]),
			"moving_kg": mass, "drive": str(dr["label"]), "motor": str(GantryLabParts.motor(str(a["motor"]))["label"])})
		spm_arr.append(spm)
		caps_arr.append(cap)
	d["motors"] = motors
	# Tool-axis caps for the planner: the slowest motor along each axis.
	var axis_caps := {}
	for k in ["x", "y", "z"]:
		var a: Dictionary = s["axis"][k]
		var spm := GantryLabKinematics.steps_per_mm(a)
		var cap := GantryLabKinematics.max_speed_mm_s(a, max_hz)
		var dr := GantryLabParts.drive(str(a["drive"]))
		cap = minf(cap, GantryLabKinematics.screw_max_speed_mm_s(dr, _screw_len_mm(kin, k, s, lay)))
		axis_caps[k] = cap
	d["limits"] = {"max_feed_mm_s": float(e["max_feed_mm_s"]), "accel_mm_s2": float(e["accel_mm_s2"]),
		"junction_mm_s": float(e["junction_mm_s"]), "axis_caps": axis_caps, "motor_caps": caps_arr, "steps_per_mm": spm_arr, "spec": s}
	# --- Stats ---------------------------------------------------------------
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"])
	var vy := float(v["y_mm"])
	var vz := float(v["z_mm"])
	var dims: Vector3 = lay["dims"]
	var vol_l := vx * vy * vz * 1e-6 * (0.785 if kin == "delta" else 1.0)
	var x_drive := GantryLabParts.drive(str(s["axis"]["x"]["drive"]))
	var span_x := float(lay["spans"].get("x_beam_m", 0.3))
	var f_hz := GantryLabKinematics.natural_hz(x_drive, float(moving["x"]), maxf(span_x, 0.1)) if str(x_drive["kind"]) == "belt" else 0.0
	var reach := GantryLabKinematics.delta_reach(s) if kin == "delta" else {}
	var stats := {
		"dims_m": dims, "volume_l": vol_l, "mass_kg": float(d["bom"]["kg"]), "frame_kg": float(d["bom"]["frame_kg"]),
		"usd": float(d["bom"]["usd"]), "watts": float(d["bom"]["watts"]), "moving_kg": moving,
		"extrusion_m": float(d["bom"]["extrusion_m"]), "ringing_hz": f_hz, "delta": reach,
		"accel_mm_s2": float(e["accel_mm_s2"]), "max_feed_mm_s": float(e["max_feed_mm_s"]),
	}
	d["stats"] = stats
	d["checks"] = _checks(s, d)
	d["graph_preset"] = graph_preset(s, d)
	return d


static func _screw_len_mm(kin: String, k: String, s: Dictionary, lay: Dictionary) -> float:
	var spans: Dictionary = lay["spans"]
	var v: Dictionary = s["volume"]
	match k:
		"x":
			return float(spans.get("x_beam_m", 0.3)) * 1000.0
		"y":
			return float(spans.get("y_rail_m", 0.3)) * 1000.0
		"z":
			if kin == "router":
				return float(spans.get("z_plate_m", 0.2)) * 1000.0
			return float(spans.get("z_col_m", float(v["z_mm"]) * 0.001 + 0.15)) * 1000.0
	return 300.0


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

static func _checks(s: Dictionary, d: Dictionary) -> Array:
	var out: Array = []
	var kin := str(s["kinematics"])
	var e: Dictionary = s["electronics"]
	var board := GantryLabParts.board(str(e["board"]))
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var lay: Dictionary = d["layout"]
	var moving: Dictionary = lay["moving_kg"]
	var v: Dictionary = s["volume"]
	var vx := float(v["x_mm"])
	var vy := float(v["y_mm"])
	var vz := float(v["z_mm"])
	var max_feed := float(e["max_feed_mm_s"])
	var accel := float(e["accel_mm_s2"])
	var process := str(tool["process"])
	# Step rate at the max feed, worst direction (a shared belt's motor sees
	# √2 × the feed on a diagonal).
	var worst_hz := 0.0
	var worst := ""
	for m in d["motors"]:
		var md: Dictionary = m
		var fac := sqrt(2.0) if (kin == "corexy" or kin == "hbot" or kin == "corexz") and str(md["key"]) != "y" and str(md["key"]) != "z" else 1.0
		if kin == "corexz" and str(md["key"]) == "z":
			fac = sqrt(2.0)
		if kin == "delta":
			fac = 1.3
		var hz := max_feed * fac * float(md["steps_per_mm"])
		if str(md["key"]) == "z" and kin != "delta" and kin != "corexz":
			hz = minf(max_feed, z_feed_mm_s(s)) * float(md["steps_per_mm"])
		if hz > worst_hz:
			worst_hz = hz
			worst = str(md["label"])
	var max_hz := float(board["max_step_hz"])
	if worst_hz > max_hz:
		out.append({"level": "error", "text": "%s needs %s steps/s at %.0f mm/s; the %s manages %s. Lower the microsteps, use a bigger pulley or a 32-bit board." % [worst, _khz(worst_hz), max_feed, str(board["label"]), _khz(max_hz)]})
	elif worst_hz > max_hz * 0.6:
		out.append({"level": "warn", "text": "%s runs at %s steps/s at full feed, %.0f %% of what the %s can do." % [worst, _khz(worst_hz), 100.0 * worst_hz / max_hz, str(board["label"])]})
	else:
		out.append({"level": "ok", "text": "Step rate: %s at most on %s, the %s can do %s." % [_khz(worst_hz), worst, str(board["label"]), _khz(max_hz)]})
	# Acceleration vs torque, per moving mass.
	for m in d["motors"]:
		var md: Dictionary = m
		var k := str(md["key"])
		if k == "z" and kin != "delta" and kin != "corexz":
			continue
		var acc := float(md["accel_capable"])
		if acc < accel:
			out.append({"level": "warn" if acc > accel * 0.5 else "error", "text": "%s can give %.1f kg about %.0f mm/s², below the %.0f mm/s² asked for: a lighter head, a bigger motor, or a smaller pulley." % [str(md["label"]), float(md["moving_kg"]), acc, accel]})
	# Z lifting its load.
	for m in d["motors"]:
		var md: Dictionary = m
		if str(md["key"]) == "z" and kin != "delta" and kin != "corexz":
			var zmass := float(moving["z"])
			var force := float(md["force_n"])
			if force < zmass * 9.81 * 1.5:
				out.append({"level": "error" if force < zmass * 9.81 else "warn", "text": "Z lifts %.1f kg (%.0f N) with %.0f N of usable force: it will skip steps. A finer lead, a bigger motor or more Z motors." % [zmass, zmass * 9.81, force]})
			else:
				out.append({"level": "ok", "text": "Z lifts %.1f kg with %.0f N in hand (%.0f N needed)." % [zmass, force, zmass * 9.81]})
			var z_dr := GantryLabParts.drive(str(s["axis"]["z"]["drive"]))
			if str(s["axis"]["z"]["drive"]) == "leadscrew_t8_8" and zmass > 4.0:
				out.append({"level": "warn", "text": "A 4-start Tr8×8 screw back-drives: the %.1f kg %s sinks when the motors are off. Tr8×2, a worm, or a brake." % [zmass, "bed" if kin != "bedslinger" else "X beam"]})
			if str(z_dr["kind"]) == "belt" and kin != "corexz":
				out.append({"level": "warn", "text": "A belt-driven Z holds the %.1f kg %s on the motors alone; they drop it when powered down." % [zmass, "bed"]})
	# Belt stretch under the acceleration force on the moving mass.
	var x_dr := GantryLabParts.drive(str(s["axis"]["x"]["drive"]))
	if str(x_dr["kind"]) == "belt":
		var f_n := float(moving["x"]) * accel * 0.001
		if kin == "corexy" or kin == "hbot":
			f_n = float(moving["y"]) * accel * 0.001
		var span_m := (vx + vy + 240.0) * 0.001 if (kin == "corexy" or kin == "hbot") else (vx + 120.0) * 0.001
		var stretch := GantryLabKinematics.belt_stretch_mm(x_dr, f_n, span_m)
		var tol := sag_tol_mm(s)
		if stretch > tol:
			out.append({"level": "warn", "text": "The %s stretches %.2f mm under %.0f N of acceleration over %.1f m of belt: ringing and corner bulge. A wider belt, less acceleration, or input shaping." % [str(x_dr["label"]), stretch, f_n, span_m]})
		else:
			out.append({"level": "ok", "text": "Belt stretch %.3f mm under %.0f N on %.1f m of %s." % [stretch, f_n, span_m, str(x_dr["label"])]})
		var hz := float(d["stats"]["ringing_hz"])
		if hz > 0.0:
			out.append({"level": "ok", "text": "The toolhead rings at about %.0f Hz on its belts — the frequency input shaping is tuned to." % hz})
	# Gantry sag: the X beam simply supported, carriage weight + cutting force at mid-span.
	var cut_n := float(CUT_FORCE_N.get(str(s["tool"]["id"]), 0.0))
	var span_x := float(lay["spans"].get("x_beam_m", 0.0))
	if span_x > 0.0:
		var gf := str(s["frame"]["gantry_profile"])
		var strong := kin == "router"  # the router beam stands on its height
		var i_m4 := GantryLabParts.profile_i_m4(gf, strong)
		var f_n := float(moving["x"]) * 9.81 + cut_n
		var sag := GantryLabKinematics.beam_sag_m(f_n, span_x, i_m4) * 1000.0
		var tol := sag_tol_mm(s)
		if sag > tol:
			out.append({"level": "warn" if sag < tol * 4.0 else "error", "text": "The %.2f m %s X beam sags %.2f mm under %.0f N at mid-span (tolerance %.2f mm): a deeper profile (2060, C-Beam) or a shorter span." % [span_x, str(GantryLabParts.profile(gf)["label"]), sag, f_n, tol]})
		else:
			out.append({"level": "ok", "text": "X beam sag %.3f mm under %.0f N over %.2f m of %s." % [sag, f_n, span_x, str(GantryLabParts.profile(gf)["label"])]})
	if kin == "router":
		var pf := str(s["frame"]["profile"])
		var span_y := float(lay["spans"].get("y_rail_m", 0.0))
		var f_n := float(moving["y"]) * 9.81 * 0.5 + cut_n * 0.5
		var sag := GantryLabKinematics.beam_sag_m(f_n, span_y, GantryLabParts.profile_i_m4(pf, true)) * 1000.0
		if sag > 0.05:
			out.append({"level": "warn", "text": "Each %.2f m %s Y rail sags %.2f mm under half the gantry: add a mid-span leg or use C-Beam." % [span_y, str(GantryLabParts.profile(pf)["label"]), sag]})
		var z_col := float(lay["spans"].get("z_col_m", 0.3))
		var gf := str(s["frame"]["gantry_profile"])
		var tip := GantryLabKinematics.cantilever_sag_m(cut_n, z_col, GantryLabParts.profile_i_m4(gf, false)) * 1000.0
		if tip > 0.05:
			out.append({"level": "warn", "text": "The gantry uprights flex %.2f mm at the cutter under %.0f N of cutting force: brace them, or shorten the Z (%.0f mm of clearance is generous)." % [tip, cut_n, vz]})
		if str(s["axis"]["x"]["guide"]) == "v_wheel" and cut_n >= 100.0:
			out.append({"level": "warn", "text": "A %s on V-wheels chatters: linear rails (HGR15) for aluminium." % str(tool["label"])})
	# Lead-screw whip.
	for m in d["motors"]:
		var md: Dictionary = m
		var sc := float(md["screw_cap_mm_s"])
		if is_finite(sc):
			var want := max_feed if str(md["key"]) != "z" or kin == "router" else minf(max_feed, z_feed_mm_s(s))
			if kin == "router" and str(md["key"]) == "z":
				want = minf(max_feed, z_feed_mm_s(s))
			if sc < want:
				out.append({"level": "warn", "text": "%s's %s whips past %.0f mm/s (critical speed); you asked for %.0f. A bigger screw, a shorter axis or a belt." % [str(md["label"]), str(md["drive"]), sc, want]})
	# Resolution vs the tool.
	var res_worst := 0.0
	for m in d["motors"]:
		res_worst = maxf(res_worst, float((m as Dictionary)["resolution_um"]))
	var nozzle_um := float(tool["nozzle_mm"]) * 1000.0
	if res_worst > nozzle_um * 0.25:
		out.append({"level": "warn", "text": "Coarsest motor step %.0f µm against a %.0f µm line: more microsteps or a finer drive." % [res_worst, nozzle_um]})
	else:
		out.append({"level": "ok", "text": "Finest commandable move %.1f µm; the line is %.0f µm wide." % [res_worst, nozzle_um]})
	# Delta geometry.
	if kin == "delta":
		var r: Dictionary = d["stats"]["delta"]
		var need := vx * 0.5
		if float(r["reach_mm"]) < need:
			out.append({"level": "error", "text": "The arms reach %.0f mm from the centre with every arm ≥ %.0f° above horizontal; the bed asks for %.0f. Longer arms or a smaller delta radius." % [float(r["reach_mm"]), GantryLabKinematics.DELTA_MIN_ARM_DEG, need]})
		else:
			out.append({"level": "ok", "text": "Arms reach %.0f mm (bed radius %.0f), %.0f° at the centre; the arms cost %.0f mm of tower height." % [float(r["reach_mm"]), need, float(r["centre_arm_deg"]), float(r["arm_lost_mm"])]})
		var ratio := float(s["delta"]["arm_mm"]) / maxf(float(r["delta_radius_mm"]), 1.0)
		if ratio < 1.4 or ratio > 2.4:
			out.append({"level": "warn", "text": "Arm length is %.2f × the delta radius; 1.5–2.0 keeps the effector stiff across the bed." % ratio})
	# H-bot racking.
	if kin == "hbot":
		var f_n := float(moving["y"]) * accel * 0.001
		var nm := GantryLabKinematics.hbot_racking_nm(f_n, vx * 0.001 + 0.2)
		if nm > 1.5:
			out.append({"level": "warn", "text": "An X move twists the H-bot gantry with %.1f N·m: either stiff Y rails (MGN12 on both sides) or CoreXY, whose two belts cancel it." % nm})
		else:
			out.append({"level": "ok", "text": "H-bot racking %.2f N·m: fine at this size and acceleration." % nm})
	# Driver count.
	var need_drivers := int(d["bom"]["motors"])
	if need_drivers > int(board["drivers"]):
		out.append({"level": "error", "text": "%d motors on a board with %d driver slots (%s)." % [need_drivers, int(board["drivers"]), str(board["label"])]})
	# Voltage.
	if int(e["volts"]) == 12 and max_feed > 120.0:
		out.append({"level": "warn", "text": "12 V runs out of torque above ~120 mm/s (the motor's inductance limits the current rise); 24 V for %.0f mm/s." % max_feed})
	# Bed slinger inertia.
	if kin == "bedslinger" and vy > 300.0:
		out.append({"level": "warn", "text": "A %.0f mm bed-slinger throws %.1f kg of bed on every Y move; past 300 mm the inertia wins — consider CoreXY." % [vy, float(moving["y"])]})
	# Frame profile vs size.
	var pf := str(s["frame"]["profile"])
	if pf == "2020" and maxf(vx, vy) > 350.0:
		out.append({"level": "warn", "text": "2020 over %.0f mm twists; 2040 on the long edges, or 4040." % maxf(vx, vy)})
	# Tool feed.
	if max_feed > float(tool["max_feed_mm_s"]):
		out.append({"level": "ok", "text": "The %s itself tops out near %.0f mm/s; the machine's %.0f mm/s is for travel moves." % [str(tool["label"]), float(tool["max_feed_mm_s"]), max_feed]})
	# Power.
	out.append({"level": "ok", "text": "Draws %.0f W flat out: motors %.0f W, %s %.0f W, bed %.0f W." % [float(d["bom"]["watts"]), float(d["bom"]["motor_watts"]), str(tool["label"]), float(tool["watts"]), float(d["bom"]["bed_watts"])]})
	# The assembly: mates that do not hold, parts that collide through the
	# travel, belts that cross or run through parts.
	if lay.has("assembly"):
		var asm_issues: Array = []
		asm_issues.append_array(lay.get("issues", []))
		asm_issues.append_array(GantryLabClash.check(s, lay))
		var faults := 0
		for iv in asm_issues:
			if not bool((iv as Dictionary).get("note", false)):
				faults += 1
		if faults == 0:
			out.append({"level": "ok", "text": "Every part fastens where it sits; nothing collides from home to the far corners of travel; every belt runs clear and flat."})
		out.append_array(asm_issues)
	return out


## The sag / stretch a process can stand: a tenth of the line it lays down,
## never under the process floor (a 0.4 mm nozzle wants 0.08 mm; an 8 mm
## clay bead forgives 0.8).
static func sag_tol_mm(s: Dictionary) -> float:
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	return maxf(float(SAG_TOL_MM.get(str(tool["process"]), 0.1)), float(tool["nozzle_mm"]) * 0.1)


static func z_feed_mm_s(s: Dictionary) -> float:
	var dr := str(s["axis"]["z"]["drive"])
	if dr == "leadscrew_t8_2":
		return Z_FEED_SCREW_FINE
	# Threaded rod in a brass nut: ~150 rpm before it chatters and heats.
	var drive := GantryLabParts.drive(dr)
	if str(drive.get("kind", "")) == "screw" and float(drive.get("lead_mm", 8.0)) < 2.0:
		return float(drive["lead_mm"]) * 2.5
	if dr.begins_with("leadscrew") or dr.begins_with("ballscrew"):
		return Z_FEED_MM_S
	return 100.0


static func _khz(hz: float) -> String:
	if hz >= 1000.0:
		return "%.0f k" % (hz / 1000.0)
	return "%.0f" % hz


## The graph node this machine becomes: a cartesian_machine processor (the
## Trash Printer / CNC Router preset shape), its inputs by the tool's
## feedstock, work volume and watts from the design.
static func graph_preset(s: Dictionary, d: Dictionary) -> Dictionary:
	var tool := GantryLabParts.tool(str(s["tool"]["id"]))
	var additive := str(tool["process"]) == "additive"
	var v: Dictionary = s["volume"]
	var inputs: Array = []
	var mat := str(tool["material"])
	if not mat.is_empty():
		inputs.append({"kind": mat, "rate": 0.0, "unit": str(tool["material_unit"])})
	var specs := {
		"name": str(s["name"]), "role": "cartesian_machine", "kind": "gantry_machine",
		"machine_role": "fdm_printer" if additive else "cnc_router", "machine_kind": "gantry",
		"print_persist": str(s["tool"]["id"]) == "clay_extruder", "bed_lowering": false,
		"cost": float(d["bom"]["usd"]), "energy_source": "ac", "efficiency": 1.0, "energy_wh_per_unit": 0.0,
		"watts": float(d["bom"]["watts"]), "speed_factor": 1.0,
		"filament_diameter_mm": float(tool["filament_mm"]), "line_width_mm": float(tool["nozzle_mm"]),
		"layer_height_mm": float(tool["layer_mm"]), "print_speed_mm_s": float(tool["feed_mm_s"]),
		"nozzle_diameter_mm": float(tool["nozzle_mm"]), "print_mode": "solid",
		"flake_density_g_cm3": float(tool["density_g_cm3"]),
		"work_x_mm": float(v["x_mm"]), "work_y_mm": float(v["y_mm"]), "work_z_mm": float(v["z_mm"]),
		"wet_color": [0.85, 0.55, 0.20] if mat != "mud" else [0.36, 0.26, 0.17],
		"dry_color": [0.35, 0.55, 0.65] if mat != "mud" else [0.68, 0.56, 0.42],
		"job_active": false, "job_completed": false, "job_name": "", "job_id": "",
		"job_start_abs_hours": 0.0, "job_duration_hr": 0.0, "job_material_kind": mat,
		"job_material_qty": 0.0, "job_energy_kwh": 0.0, "job_progress": 0.0,
		"job_part_id": "", "job_part_label": "", "job_part_count": 1,
		"print_mesh_path": "", "print_offset_x": 0.0, "print_offset_z": 0.0, "print_scale": 1.0,
		"daily_note": "%s. Designed in the gantry lab; load G-code here or send a job from the lab's Simulate tab." % GantryLabSpec.describe(s),
		"inputs": inputs,
		"outputs": [{"kind": "finished_part", "rate": 0.0, "unit": "units/h"}],
		"model_id": "gantry_machine",
		"gantry_spec": GantryLabSpec.to_json_safe(s),
	}
	return {"type": "processor", "label": str(s["name"]), "icon": "🖨" if additive else "🔩",
		"width": 150.0, "height": 130.0, "specs": specs}


## The shipping spec: the extrusion bundle plus the boxed parts.
static func packed_spec(d: Dictionary) -> Dictionary:
	var bom: Dictionary = d["bom"]
	var longest := 0.0
	var n := 0
	for c in bom["cut_list"]:
		longest = maxf(longest, float(c["len_mm"]) * 0.001)
		n += int(c["qty"])
	var side := 0.02 * sqrt(float(maxi(n, 1))) + 0.06
	return {"w_m": maxf(longest, 0.6), "d_m": maxf(side, 0.3), "h_m": maxf(side * 0.8, 0.25),
		"mass_kg": float(bom["kg"]), "form": "bundle", "source": "computed", "count": 1}

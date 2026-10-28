class_name PrintJob
extends RefCounted

## ONE print job for every machine in the game. A job is a move list (what
## a firmware runs: {p0, p1, feed_mm_s, e_mm, rapid, line} in work mm) plus
## the machine's motion limits; the planner (`GantryLabMotion.plan`) turns
## it into a time line, and the in-world runtime, the print setup's studio
## and the gantry designer's Simulate tab all play that same plan. The three
## ways a job is made:
##   from_parse     a sliced STL (StlSlicer) or a G-code file (GantryLabGcode)
##   from_toolpath  an old point list (Toolpath / StlLoader / MudWallSlicer):
##                  consecutive points pair into moves at the print speed,
##                  travels at the travel speed
## Both return the job dict `SystemGraphView.start_machine_job` schedules and
## `MachineJobStore.save` writes (v2, binary). `PrintJobPlayer` loads one by
## id, plans it and answers "where is the nozzle at this progress".
##
## `moves` in a job is always a `PrintMoves` (packed); a parse may hand in
## either form.
##
## Material: every extruding move carries e_mm in millimetres of the
## feedstock bore d (specs filament_diameter_mm), e = w·h·L / (π d²/4), so
## `CartesianMachineSource.derive_job` bills exactly w·h·L of road.

## Motion limits by machine when the specs carry none. Sources: a Marlin
## default (1000 mm/s², jerk 8) for a desktop FDM; the real mud printer's
## GRBL settings (7200 mm/min, a 2.4 t gantry at ~150 mm/s²); the Trash
## Printer's NEMA 23 belt axes with a 4.5 kg extruder (400 mm/s²).
const LIMIT_DEFAULTS := {
	"trash": {"max_feed_mm_s": 60.0, "accel_mm_s2": 400.0, "junction_mm_s": 6.0},
	"mud": {"max_feed_mm_s": 120.0, "accel_mm_s2": 150.0, "junction_mm_s": 4.0},
	"gantry": {"max_feed_mm_s": 150.0, "accel_mm_s2": 1000.0, "junction_mm_s": 8.0},
	"cnc_router": {"max_feed_mm_s": 80.0, "accel_mm_s2": 600.0, "junction_mm_s": 5.0},
	"fdm": {"max_feed_mm_s": 150.0, "accel_mm_s2": 1000.0, "junction_mm_s": 8.0},
}


static func machine_kind(specs: Dictionary) -> String:
	var kind := str(specs.get("machine_kind", ""))
	if kind.is_empty():
		var mid := str(specs.get("model_id", ""))
		if mid == "trash_printer":
			kind = "trash"
		elif mid == "mud_printer":
			kind = "mud"
		elif str(specs.get("machine_role", "")) == "cnc_router" or mid == "cnc_router":
			kind = "cnc_router"
		else:
			kind = "fdm"
	return kind


## The planner's limits for a machine: the specs' own numbers (a designed
## gantry carries its design's), else the kind's defaults.
static func limits_for_specs(specs: Dictionary) -> Dictionary:
	var kind := machine_kind(specs)
	var base: Dictionary = LIMIT_DEFAULTS.get(kind, LIMIT_DEFAULTS["fdm"])
	var gspec: Variant = specs.get("gantry_spec", {})
	if gspec is Dictionary and not (gspec as Dictionary).is_empty():
		var d := GantryLabDesign.solve(gspec as Dictionary)
		var lim: Dictionary = (d["limits"] as Dictionary).duplicate()
		lim.erase("spec")
		return lim
	return {
		"max_feed_mm_s": maxf(float(specs.get("max_feed_mm_s", base["max_feed_mm_s"])), 0.5),
		"accel_mm_s2": maxf(float(specs.get("accel_mm_s2", base["accel_mm_s2"])), 1.0),
		"junction_mm_s": maxf(float(specs.get("junction_mm_s", base["junction_mm_s"])), 0.01),
		"axis_caps": {},
	}


## The feedstock bore the E words are in (mm).
static func filament_mm(specs: Dictionary) -> float:
	return maxf(float(specs.get("filament_diameter_mm", specs.get("nozzle_diameter_mm", 1.75))), 0.05)


## A job from a move-list parse (StlSlicer.slice_* or GantryLabGcode.parse).
## opts: name, line_width_mm, layer_height_mm (defaults from the parse, then
## the specs), limits (else from the specs).
static func from_parse(parse: Dictionary, specs: Dictionary, opts: Dictionary = {}) -> Dictionary:
	if not bool(parse.get("ok", false)):
		return {"ok": false, "error": str(parse.get("error", "no motion"))}
	var moves := PrintMoves.from_any(parse.get("moves", []))
	if moves.is_empty():
		return {"ok": false, "error": "no moves"}
	var limits: Dictionary = opts.get("limits", limits_for_specs(specs))
	var line_w := float(opts.get("line_width_mm", parse.get("line_width_mm", specs.get("line_width_mm", filament_mm(specs)))))
	var layer_h := float(opts.get("layer_height_mm", parse.get("layer_height_mm", -1.0)))
	if layer_h <= 0.0:
		layer_h = PrintRoads.layer_guess_mm(moves, line_w)
	var d := filament_mm(specs)
	var ext := float(parse.get("extrusion_mm", 0.0))
	# A program with no E words on a printer (the mud printer's GRBL relay
	# dialect, a laser-style S flag): the moves it flagged lay w·h of road.
	if str(parse.get("dialect", "")) == "grbl" and str(specs.get("machine_role", "")) == "fdm_printer" and ext > 0.0 and ext < 1e-2 * moves.size():
		ext = 0.0
		var area := PI * d * d * 0.25
		for i in moves.size():
			if moves.e[i] > 0.0:
				var l := moves.p0[i].distance_to(moves.p1[i])
				moves.e[i] = l * line_w * layer_h / area
				ext += moves.e[i]
	var plan := GantryLabMotion.plan({"ok": true, "moves": moves, "layers": parse.get("layers", 0), "extrusion_mm": ext}, limits)
	var total_s := float(plan.get("total_s", 0.0))
	var speed_factor := maxf(float(specs.get("speed_factor", 1.0)), 0.05)
	var job := {
		"ok": true,
		"kind": str(parse.get("kind", "gcode")),
		"name": str(opts.get("name", parse.get("name", "Job"))),
		"moves": moves,
		"bounds_min": parse.get("bounds_min", Vector3.ZERO),
		"bounds_max": parse.get("bounds_max", Vector3.ZERO),
		"extrusion_mm": ext,
		"total_feed_mm": float(parse.get("total_feed_mm", 0.0)),
		"total_rapid_mm": float(parse.get("total_rapid_mm", 0.0)),
		"volume_mm3": ext * PI * d * d * 0.25,
		"filament_mm": d,
		"line_width_mm": line_w,
		"layer_height_mm": layer_h,
		"layers": int(parse.get("layers", 0)),
		"layer_starts": parse.get("layer_starts", PackedInt32Array()),
		"layer_z": parse.get("layer_z", PackedFloat32Array()),
		"additive": bool(parse.get("additive", ext > 0.0)),
		"limits": limits,
		"total_s": total_s,
		"est_time_hr": total_s / 3600.0 / speed_factor,
		"point_count": moves.size() + 1,
		"raw_point_count": moves.size() + 1,
		"warnings": parse.get("warnings", []),
		"settings": parse.get("settings", {}),
		"mode": str(parse.get("mode", "")),
		"solid_volume_mm3": float(parse.get("solid_volume_mm3", 0.0)),
		"triangles": int(parse.get("triangles", 0)),
		"plan": plan,
	}
	if layer_h > 0.0 and int(job["layers"]) <= 0:
		job["layers"] = _count_layers(moves)
	return job


## A job from an old point-list parse: points + extruding flags (and the
## parse's line_width_mm / layer_height_mm / print_speed_mm_s). `shift_xy`
## moves the path (a plan centred on 0 onto a bed whose origin is a corner).
static func from_toolpath(parse: Dictionary, specs: Dictionary, opts: Dictionary = {}) -> Dictionary:
	if not bool(parse.get("ok", false)):
		return {"ok": false, "error": str(parse.get("error", "no motion"))}
	var pts: PackedVector3Array = parse.get("points", PackedVector3Array())
	var ext: PackedInt32Array = parse.get("extruding", PackedInt32Array())
	if pts.size() < 2:
		return {"ok": false, "error": "empty toolpath"}
	var speed := maxf(float(opts.get("print_speed_mm_s", parse.get("print_speed_mm_s", specs.get("print_speed_mm_s", 40.0)))), 0.5)
	var travel := maxf(float(opts.get("travel_speed_mm_s", speed * 2.5)), speed)
	var line_w := maxf(float(opts.get("line_width_mm", parse.get("line_width_mm", specs.get("line_width_mm", filament_mm(specs))))), 0.05)
	var layer_h := float(opts.get("layer_height_mm", parse.get("layer_height_mm", -1.0)))
	var shift: Vector2 = opts.get("shift_xy", Vector2.ZERO)
	var additive := bool(opts.get("additive", str(specs.get("machine_role", "")) == "fdm_printer"))
	var d := filament_mm(specs)
	var has_ext := ext.size() == pts.size()
	var moves := PrintMoves.new()
	var extrusion := 0.0
	var feed_mm := 0.0
	var rapid_mm := 0.0
	var bmin := Vector3(INF, INF, INF)
	var bmax := Vector3(-INF, -INF, -INF)
	var sh := Vector3(shift.x, shift.y, 0.0)
	var cutting := not additive
	for i in range(1, pts.size()):
		var a := pts[i - 1] + sh
		var b := pts[i] + sh
		var l := a.distance_to(b)
		if l <= 1e-9:
			continue
		var on := (not has_ext) or ext[i] != 0
		var e := 0.0
		if on and additive and layer_h > 0.0:
			e = l * line_w * layer_h / (PI * d * d * 0.25)
		elif on and additive:
			e = l * 0.01
		elif on and cutting:
			e = 1e-4 * l   # a cut marks the stock (the road preview draws it)
		var rapid := not on
		moves.append(a, b, travel if rapid else speed, e, rapid, i)
		if rapid:
			rapid_mm += l
		else:
			feed_mm += l
			bmin = bmin.min(a.min(b))
			bmax = bmax.max(a.max(b))
		extrusion += e
	if moves.is_empty():
		return {"ok": false, "error": "empty toolpath"}
	if not is_finite(bmin.x):
		bmin = pts[0] + sh
		bmax = pts[0] + sh
	if layer_h <= 0.0:
		layer_h = PrintRoads.layer_guess_mm(moves, line_w)
	var p := {
		"ok": true, "kind": str(parse.get("kind", "toolpath")), "moves": moves, "bounds_min": bmin, "bounds_max": bmax,
		"extrusion_mm": extrusion, "total_feed_mm": feed_mm, "total_rapid_mm": rapid_mm,
		"layers": int(parse.get("layer_count", 0)), "additive": additive, "warnings": [],
		"line_width_mm": line_w, "layer_height_mm": layer_h, "mode": str(parse.get("mode", "")),
		"solid_volume_mm3": float(parse.get("solid_volume_mm3", 0.0)), "triangles": int(parse.get("triangles", 0)),
	}
	var o := opts.duplicate()
	o["line_width_mm"] = line_w
	o["layer_height_mm"] = layer_h
	return from_parse(p, specs, o)


static func _count_layers(moves_in: Variant) -> int:
	var moves := PrintMoves.from_any(moves_in)
	var zs := {}
	for i in moves.size():
		if moves.e[i] > 0.0:
			zs[snappedf(float(moves.p1[i].z), 0.01)] = true
	return zs.size()


## The (first) move index of each layer, from the Z steps of extruding moves.
static func layer_starts(moves_in: Variant) -> PackedInt32Array:
	var moves := PrintMoves.from_any(moves_in)
	var out := PackedInt32Array()
	var last_z := NAN
	for i in moves.size():
		if moves.e[i] <= 0.0:
			continue
		var z := float(moves.p1[i].z)
		if is_nan(last_z) or z > last_z + 1e-6:
			out.append(i)
			last_z = z
	return out


## The planner, on a job (its own limits unless `limits` is given).
static func plan(job: Dictionary, limits: Dictionary = {}) -> Dictionary:
	var lim: Dictionary = limits if not limits.is_empty() else job.get("limits", {})
	return GantryLabMotion.plan(job, lim)


## Old readers (the inspector's summary, MudGrblExport) want points + flags.
static func moves_to_points(moves_in: Variant) -> Dictionary:
	var moves := PrintMoves.from_any(moves_in)
	var pts := PackedVector3Array()
	var ext := PackedInt32Array()
	if moves.is_empty():
		return {"points": pts, "extruding": ext}
	pts.append(moves.p0[0])
	ext.append(0)
	for i in moves.size():
		var p0 := moves.p0[i]
		if pts[pts.size() - 1].distance_squared_to(p0) > 1e-10:
			pts.append(p0)
			ext.append(0)
		pts.append(moves.p1[i])
		ext.append(1 if moves.e[i] > 0.0 else 0)
	return {"points": pts, "extruding": ext}


## Feedstock mass (kg) a job uses on a machine: w·h·L × the density.
static func material_kg(job: Dictionary, specs: Dictionary) -> float:
	var density := maxf(float(specs.get("flake_density_g_cm3", 0.95)), 0.05)
	return float(job.get("volume_mm3", 0.0)) / 1000.0 * density / 1000.0


static func fmt_duration(s: float) -> String:
	return GantryLabMotion.fmt_duration(s)

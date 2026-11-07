extends SceneTree

## The biochar reactor preset against the user's model (NOT a selftest):
## prints each nozzle's position against the collar measured in
## "Biochar Reactor.glb" (2026-11-06; the same model ships as
## res://Imported Models/Biochar/biochar_reactor.glb) with PASS / FAIL
## inside the tolerance, the overall size, the condenser's column spacing,
## and shoots both side by side from the front and from behind.
## WINDOWED; APPDATA at a scratch folder.
##   Godot --path . --windowed --resolution 1600x1000 --script res://tools/diag/tclab_reactor_parity.gd -- --out=<dir> [--glb=<path>]

const TOL_MM := 10.0
## Collar centres measured in the GLB (metres, its frame: the vessel's axis
## at x −0.001, z −0.002, its bottom on y = 0).
const GLB_AXIS := Vector3(-0.001, 0.0, -0.002)
const GLB_COLLARS := {
	"element": Vector3(0.201, 0.190, -0.002),
	"drain": Vector3(-0.203, 0.098, -0.002),
	"back_low": Vector3(-0.003, 0.066, -0.206),
	"vapour": Vector3(-0.003, 0.599, -0.206),
	"bung1": Vector3(-0.001, 0.603, 0.203),
	"bung2": Vector3(0.185, 0.603, 0.085),
	"bung3": Vector3(0.145, 0.127, 0.143),
	"bung4": Vector3(0.145, 0.049, 0.143),
	"bung5": Vector3(-0.143, 0.226, 0.140),
	"bung6": Vector3(-0.001, 0.159, 0.203),
}
## Where the replica departs from the model on purpose.
const KNOWN := {
	"element": "moved to the bottom: the user's real reactor has two bottom-entry elements (2026-11-06)",
	"vapour": "raised 21 mm so the condenser's header clears the floor on standard + short fittings (the model's tee and elbows are more compact than the catalogue's)",
}

var _out := "user://tclab_parity"
var _glb := "res://Imported Models/Biochar/biochar_reactor.glb"
var _frames := 0
var _cam: Camera3D
var _shot := 0
var _fails := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--out="):
			_out = s.substr(6)
		elif s.begins_with("--glb="):
			_glb = s.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var d := TcDesign.solve(TcPresets.builtin("biochar_reactor"))
	_numbers(d)
	var world := Node3D.new()
	root.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.62, 0.66, 0.70)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.82)
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	sun.light_energy = 1.5
	world.add_child(sun)
	var b := TcBuilder.new()
	b.build(d)
	b.position = Vector3(-0.45, 0, 0)
	world.add_child(b)
	var model := _load_glb()
	if model != null:
		model.position = Vector3(0.45, 0, 0) - GLB_AXIS
		world.add_child(model)
	else:
		print("parity: the GLB did not load (%s): numbers only" % _glb)
	_cam = Camera3D.new()
	_cam.fov = 38
	world.add_child(_cam)
	_aim(0)


func _load_glb() -> Node3D:
	if _glb.begins_with("res://") and ResourceLoader.exists(_glb):
		var ps := load(_glb) as PackedScene
		return ps.instantiate() as Node3D if ps != null else null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(_glb, st) != OK:
		return null
	return doc.generate_scene(st) as Node3D


func _aim(i: int) -> void:
	var c := Vector3(0, 0.4, -0.05)
	var yaw: float = deg_to_rad(float([20.0, 200.0][i]))
	_cam.look_at_from_position(c + Vector3(sin(yaw) * 2.1, 0.75, cos(yaw) * 2.1), c, Vector3.UP)


func _process(_dt: float) -> bool:
	_frames += 1
	if _frames == 8 or _frames == 16:
		var name: String = ["front", "back"][_shot]
		root.get_texture().get_image().save_png("%s/parity_%s.png" % [_out, name])
		_shot += 1
		if _shot < 2:
			_aim(_shot)
	if _frames >= 17:
		print("parity: %s" % ("PASS" if _fails == 0 else "FAILED (%d)" % _fails))
		return true
	return false


func _numbers(d: Dictionary) -> void:
	var res: Dictionary = d["res"]
	var vid := ""
	for id in res["order"]:
		if str(res["parts"][id]["built"]["type"]) == "vessel":
			vid = id
	var pd: Dictionary = res["parts"][vid]
	var b: Dictionary = pd["built"]
	var nozzles: Dictionary = b["nozzles"]
	var params: Dictionary = b["params"]
	for q in params["ports"]:
		var id := str(q["id"])
		if not GLB_COLLARS.has(id):
			continue
		var f: Dictionary = nozzles[id]
		var dir: Vector3 = f["dir"]
		var hub := float(TcStandards.ferrule(str(q["size"]))["hub"]) if str(q["kind"]) == "tc" else 0.0
		var stub := float(q["stub_mm"])
		var collar: Vector3 = (f["face"] as Vector3) - dir * minf(hub, stub) * 0.5 if str(q["kind"]) == "tc" else ((f["base"] as Vector3) + (f["face"] as Vector3)) * 0.5
		var ours: Vector3 = (pd["xf"] as Transform3D) * collar
		var theirs: Vector3 = ((GLB_COLLARS[id] as Vector3) - GLB_AXIS) * 1000.0
		var dist := ours.distance_to(theirs)
		var ok := dist <= TOL_MM or KNOWN.has(id)
		if not ok:
			_fails += 1
		print("parity %s: nozzle %s %.0f mm off the model's collar (ours %s, model %s)%s" % [
			"PASS" if ok else "FAIL", id, dist, _v(ours), _v(theirs), (" — " + str(KNOWN[id])) if KNOWN.has(id) else ""])
	var bb: AABB = d["stats"]["bounds_mm"]
	print("parity: ours %.0f × %.0f × %.0f mm; the model 613 × 845 × 618 mm (its lid floats ~110 mm over the rim)" % [bb.size.x, bb.size.y, bb.size.z])
	var rim_ok := absf(TcVessel.jacket_r(params) * 2.0 - 396.0) < 1.0 and absf(float(params["height_mm"]) - 650.0) < 1.0
	_fails += 0 if rim_ok else 1
	print("parity %s: the jacketed shell is Ø%.0f × %.0f mm (model Ø396 × 650)" % ["PASS" if rim_ok else "FAIL",
		TcVessel.jacket_r(params) * 2.0, float(params["height_mm"])])
	var lid_ok := absf(TcVessel.lid_od(params) - 516.0) < 1.0
	_fails += 0 if lid_ok else 1
	print("parity %s: the lid is Ø%.0f mm (model 516)" % ["PASS" if lid_ok else "FAIL", TcVessel.lid_od(params)])
	var xs: Array = []
	for id in res["order"]:
		var pb: Dictionary = res["parts"][id]["built"]
		if str(pb["type"]) == "dephlegmator":
			xs.append(roundi((res["parts"][id]["xf"] as Transform3D).origin.x))
	xs.sort()
	print("parity: condenser columns at x = %s mm (model −124, −4, +118)" % str(xs))
	var closing: Array = res["closing"]
	var err := 0.0
	for ci in closing:
		err = maxf(err, float(res["joints"][ci]["err_mm"]))
	var loop_ok := closing.size() == 1 and err < 0.5
	_fails += 0 if loop_ok else 1
	print("parity %s: the condenser loop closes (%.3f mm)" % ["PASS" if loop_ok else "FAIL", err])
	var errs := (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error")
	_fails += errs.size()
	print("parity %s: no error checks (%d), clashes %d" % ["PASS" if errs.is_empty() else "FAIL", errs.size(), (d["clashes"] as Array).size()])


static func _v(v: Vector3) -> String:
	return "(%.0f, %.0f, %.0f)" % [v.x, v.y, v.z]

extends SceneTree

## The 3D-ring model camera uses the same projection as the card layout
## (GraphSchema3D.project). A point's screen offset through a real Camera3D
## posed by GraphModelStage must match that projection, or the mesh would
## sit off the node's ports.
##   Godot --headless --path . --script system_graph/graph_model_stage_selftest.gd

const EXPECTED_CHECKS := 5

var _checks := 0
var _fails := 0


func _init() -> void:
	_run.call_deferred()


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	print(("  PASS  " if cond else "  FAIL  ") + what)
	if not cond:
		_fails += 1


func _run() -> void:
	var dist := 900.0
	var zoom := 1.25
	var vp_h := 720.0
	var fov := GraphModelStage.fov_y_deg(vp_h, dist, zoom)
	var focal := (vp_h * 0.5) / tan(deg_to_rad(fov) * 0.5)
	_ok(absf(focal - dist * zoom) < 0.05, "focal length is dist × zoom (%.2f vs %.2f)" % [focal, dist * zoom])

	var host := Node3D.new()
	root.add_child(host)
	var cam := Camera3D.new()
	host.add_child(cam)
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = fov
	var views := [
		[0.55, -0.32],
		[0.25, 1.05],
		[-1.1, 0.4],
	]
	var points := [Vector3(120, -40, 30), Vector3(-200, 80, -50), Vector3(0, 0, 0), Vector3(15, 15, 400)]
	var worst := 0.0
	for vw in views:
		var yaw := float(vw[0])
		var pitch := float(vw[1])
		var eye := GraphModelStage.eye_godot(yaw, pitch, dist)
		var up := GraphModelStage.up_godot(yaw, pitch)
		cam.position = eye
		cam.look_at(Vector3.ZERO, up.normalized())
		for p in points:
			var got := _camera_px(cam, p as Vector3, focal)
			var exp := GraphSchema3D.project(p as Vector3, yaw, pitch, dist)
			var err := got.distance_to(Vector2(exp.x, exp.y) * zoom)
			worst = maxf(worst, err)
	_ok(worst < 0.75, "camera pixels match the card projection (worst %.3f px)" % worst)

	var eye0 := GraphModelStage.eye_godot(0.0, 0.0, dist)
	_ok(eye0.distance_to(Vector3(0, 0, dist)) < 0.01, "at the default angle the eye is in front of the origin")
	var up0 := GraphModelStage.up_godot(0.0, 0.0)
	_ok(up0.normalized().distance_to(Vector3.UP) < 0.01, "graph down stays screen down")
	_ok(GraphModelStage.to_godot(Vector3(1, 2, 3)) == Vector3(1, -2, 3), "graph +y flips onto Godot up")

	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL  ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("graph_model_stage_selftest: %d checks, %d failures — %s" % [_checks, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(1 if _fails > 0 else 0)


func _camera_px(cam: Camera3D, p: Vector3, focal: float) -> Vector2:
	var local := cam.global_transform.affine_inverse() * GraphModelStage.to_godot(p)
	var ahead := -local.z
	if ahead < 0.001:
		return Vector2(1.0e9, 1.0e9)
	return Vector2(local.x / ahead * focal, -local.y / ahead * focal)

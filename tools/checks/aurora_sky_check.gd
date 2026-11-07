extends RefCounted

## The aurora in the world's sky (sandbox, Mount Vernon):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/aurora_sky_check.gd -Label aurora_sky
## Parks the clock on the night of the May 2024 storm (2024-05-10 23:30 PDT =
## 05-11 06:30 UTC, Kp 8.3 in the GFZ archive), clear sky, and shoots north low,
## north high and straight up; then a quiet night (2024-05-20, Kp ~2) and the
## Settings switch off. Asserts the Kp comes from the archive, the sky shader
## got the aurora uniforms, it is "overhead" in the storm and not seen on the
## quiet night. Nothing is saved.

var _fails: Array = []
var _dir := "user://screenshots/aurora_sky"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("aurora-sky %s: %s%s" % ["PASS" if cond else "FAIL", what, "" if detail.is_empty() else " (%s)" % detail])
	if not cond:
		_fails.append(what)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var aur := main.get_node_or_null("AuroraSky") as AuroraSky
	_ok(aur != null, "Main made the AuroraSky")
	if aur == null:
		return {"ok": false}
	AuroraSky.set_prefs(true, 1.0)
	main.set("time_scale", 0.0)
	main.set("clear_sky_override", true)
	var ui := main.get_node_or_null("UILayer")
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = false
	var player := main.get_node_or_null("Player") as Node3D
	var pcam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D if player != null else null
	var eye := pcam.global_position if pcam != null else Vector3(0, 2, 0)
	var cam := Camera3D.new()
	cam.far = 4000.0
	cam.fov = 80.0
	main.add_child(cam)
	main.call("push_camera_claim", "aurora_check", {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})

	main.set("year", 2024)
	main.set("month", 5)
	main.set("day", 10)
	main.set("day_time", 23.5)
	var waited := 0.0
	while waited < 60.0 and float(aur.state().get("kp", 0.0)) < 8.0:
		aur.push_now()
		await tree.create_timer(0.5).timeout
		waited += 0.5
	var st := aur.state()
	_ok(str(st.get("source", "")) == "archive" and float(st.get("kp", 0.0)) > 8.0,
		"the storm's Kp comes from the GFZ archive", str(st))
	_ok(str(st.get("seen", "")) == "overhead", "the storm is overhead at Mount Vernon", str(st.get("seen", "")))
	var mat: ShaderMaterial = main.call("_sky_material")
	_ok(mat != null and bool(mat.get_shader_parameter("aurora_on")), "the sky shader has the aurora on")
	for v: Array in [["01_storm_north_low", 0.0, 12.0], ["02_storm_north_high", 0.0, 45.0],
			["03_storm_zenith", 180.0, 85.0], ["04_storm_south", 180.0, 20.0]]:
		_aim(cam, eye, float(v[1]), float(v[2]))
		await tree.create_timer(1.5).timeout
		await RenderingServer.frame_post_draw
		main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, v[0]])
	# A quiet night.
	main.set("day", 20)
	waited = 0.0
	while waited < 60.0 and float(aur.state().get("kp", 9.0)) > 4.0:
		aur.push_now()
		await tree.create_timer(0.5).timeout
		waited += 0.5
	st = aur.state()
	_ok(float(st.get("kp", 9.0)) < 4.0 and str(st.get("seen", "x")) == "", "a quiet night is not seen from here", str(st))
	_aim(cam, eye, 0.0, 12.0)
	await tree.create_timer(1.5).timeout
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/05_quiet_north_low.png" % _dir)
	# Settings off.
	AuroraSky.set_prefs(false, 1.0)
	aur.push_now()
	_ok(not bool(mat.get_shader_parameter("aurora_on")), "Settings off turns it off")
	AuroraSky.set_prefs(true, 1.0)

	main.call("pop_camera_claim", "aurora_check")
	cam.queue_free()
	main.set("clear_sky_override", false)
	if ui is CanvasLayer:
		(ui as CanvasLayer).visible = true
	var ok := _fails.is_empty()
	print("aurora-sky %s (%d failures)" % ["PASS" if ok else "FAIL", _fails.size()])
	return {"ok": ok, "failures": _fails}


## Bearing from north (clockwise) and elevation, degrees; north is -Z.
func _aim(cam: Camera3D, eye: Vector3, bearing: float, elev: float) -> void:
	var b := deg_to_rad(bearing)
	var e := deg_to_rad(elev)
	var d := Vector3(sin(b) * cos(e), sin(e), -cos(b) * cos(e))
	cam.global_position = eye
	var up := Vector3.UP if absf(d.y) < 0.98 else Vector3(0, 0, -1)
	cam.look_at(eye + d * 10.0, up)

extends RefCounted

## End-to-end SDFGI outdoor calibration + survey-drone handover + terrain opt-out
## check on a REAL world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/sdfgi_drone_check.gd -Label sdfgi_drone
##
## Verifies:
##   1. Settings → Lighting exposes `SDFGI strength ×` and `SDFGI on terrain`,
##      syncs to snapshot, and passes `UiAudit` with 0 errors.
##   2. `SDFGI on terrain` off swaps `Ground` and `DetailGround` to
##      `terrain_detail_no_sdfgi.gdshader` without losing bound drape uniforms,
##      and turning it back on restores `terrain_detail.gdshader`.
##   3. `SimSettingsController` persists and reloads `sdfgi_enabled`,
##      `sdfgi_energy_mult` and `sdfgi_terrain_enabled`.
##   4. Camera altitude hysteresis + handover: rich calibrated SDFGI (`0.28`) at
##      low/mid drone heights with matched `Environment` sky ambient outside,
##      clean suspension above `suspend_agl_m` (`sdfgi_enabled == false` while
##      keeping landscape brightness seamless!), and hysteretic re-enable on descent.
##   5. Visual & spatial-uniformity comparison in Drone View at Noon, Dusk and
##      Night over uniform hills + over the Mount Vernon property:
##      measures the **center-vs-surround spotlight contrast** (`|center_luma -
##      outer_ring_luma|` relative to SDFGI-off baseline):
##        - Legacy 4-cascade/energy-1.0 creates a huge center-bright square step!
##        - Mode A (`SDFGI on terrain` on) lights BOTH inside and outside smoothly
##          (keeping rich shadow fill while cutting center-vs-surround step >75 %)!
##        - Mode C (`SDFGI on terrain` off) gives 0 cascade step on terrain even
##          when `SDFGI strength ×` is boosted to 2.2× for structures!

const CLAIM := "sdfgi_drone_check"

var _fails: Array = []
var _out := "user://screenshots/sdfgi_drone"


func _ok(cond: bool, what: String) -> void:
	print("sdfgi-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	for arg in OS.get_cmdline_user_args():
		var s := str(arg)
		if s.begins_with("--shots-dir="):
			_out = "user://screenshots/" + s.substr(12)
	DirAccess.make_dir_recursive_absolute(_out)
	print("sdfgi-check: shots in %s" % ProjectSettings.globalize_path(_out))
	# Let any async world-boot requests (e.g. moon globe texture) settle cleanly before closing views.
	await _settle(tree, 45)

	var sgv: Node = main.find_child("SystemGraphView", true, false)
	if sgv != null and bool(sgv.get("visible")) and sgv.has_method("close_graph_view"):
		sgv.call("close_graph_view")
	if main.has_method("settlement_view_open") and bool(main.call("settlement_view_open")):
		(main.get("settlement_view") as Node).call("close")
	var player := main.find_child("Player", true, false) as Node3D
	if player != null and bool(player.get("is_fpv_drone_mode")) and player.has_method("toggle_remote_drone_view"):
		player.call("toggle_remote_drone_view")

	var ssc: Node = main.get_node_or_null("/root/SimSettingsController")
	_ok(ssc != null, "SimSettingsController is present")
	var we: WorldEnvironment = main.get("environment")
	var env: Environment = we.environment if we != null else null
	_ok(env != null, "WorldEnvironment is present")
	if ssc == null or env == null:
		return {"ok": false, "fails": _fails}

	var saved_enabled := bool(main.call("get_sdfgi_enabled"))
	var saved_mult := float(main.call("get_sdfgi_energy_mult"))
	var saved_terrain := bool(main.call("get_sdfgi_terrain_enabled"))
	var saved_amb := float(main.call("get_ambient_energy_mult"))
	var saved_sky := float(main.call("get_ambient_sky_contribution"))
	var saved_hour := float(main.get("day_time"))
	main.set("time_scale", 0.0)
	ssc.call("apply_sdfgi_enabled", false)
	ssc.call("apply_sdfgi_energy_mult", 1.0)
	ssc.call("apply_sdfgi_terrain_enabled", true)
	await _settle(tree, 8)

	# --- 1. Settings → Lighting UI + UiAudit ---------------------------------
	await _check_settings_ui(main, tree)

	# --- 2. Terrain shader swap + uniform preservation -----------------------
	await _check_terrain_shader_toggle(main, ssc, tree)

	# --- 3. Persistence round-trip -------------------------------------------
	await _check_persistence(main, ssc, tree)

	# --- 4. Survey-altitude handover + visual comparison shots ---------------
	var hidden := _hide_ui(main)
	var cam := Camera3D.new()
	cam.name = "SdfgiDroneCheckCam"
	cam.fov = 72.0
	cam.far = 25000.0
	main.add_child(cam)
	var centre := SiteCentre.xz(main)
	var gy := TerrainSurfaceQuery.ground_height_at(main, centre.x, centre.y)
	if not is_finite(gy):
		gy = player.global_position.y - 1.7 if player != null else 0.0

	await _check_altitude_handover(main, ssc, env, cam, centre, gy, tree)
	await _capture_comparisons(main, ssc, env, cam, centre, tree)

	main.call("pop_camera_claim", CLAIM)
	cam.queue_free()
	for n in hidden:
		if is_instance_valid(n):
			n.visible = true

	main.set("day_time", saved_hour)
	ssc.call("apply_ambient_energy_mult", saved_amb)
	ssc.call("apply_ambient_sky_contribution", saved_sky)
	ssc.call("apply_sdfgi_energy_mult", saved_mult)
	ssc.call("apply_sdfgi_terrain_enabled", saved_terrain)
	ssc.call("apply_sdfgi_enabled", saved_enabled)
	ssc.call("persist_settings")
	await _settle(tree, 6)
	return {"ok": _fails.is_empty(), "fails": _fails}


func _check_settings_ui(main: Node, tree: SceneTree) -> void:
	var tui: Node = main.find_child("TimelineUI", true, false)
	if tui == null or not tui.has_method("open_settings_page"):
		_ok(false, "TimelineUI.open_settings_page available")
		return
	tui.call("open_settings_page", "Lighting")
	await _settle(tree, 8)
	var panel: Control = tui.get("_settings_panel")
	_ok(panel != null and bool(panel.call("is_open")), "Settings → Lighting opened")
	if panel != null:
		_ok(panel.get("_sdfgi_enabled") != null, "SDFGI checkbox exists")
		_ok(panel.get("_sdfgi_strength") != null, "SDFGI strength × slider exists")
		_ok(panel.get("_sdfgi_terrain") != null, "SDFGI on terrain checkbox exists")
	var vp := main.get_viewport()
	var audit_top: Dictionary = UiAudit.run(vp)
	_ok(int(audit_top.get("errors", 0)) == 0,
		"Settings → Lighting (top) passes UiAudit at %dx%d (%d errors)" % [vp.size.x, vp.size.y, int(audit_top.get("errors", 0))])
	if panel != null:
		var sdfgi_chk := panel.get("_sdfgi_enabled") as Control
		if sdfgi_chk != null:
			var p_node: Node = sdfgi_chk.get_parent()
			while p_node != null and not (p_node is ScrollContainer):
				p_node = p_node.get_parent()
			if p_node is ScrollContainer:
				(p_node as ScrollContainer).ensure_control_visible(sdfgi_chk)
				(p_node as ScrollContainer).scroll_vertical += 90
				await _settle(tree, 4)
	var audit: Dictionary = UiAudit.run(vp)
	print("sdfgi-check: ui audit (%dx%d) — %s" % [vp.size.x, vp.size.y, UiAudit.summary_line(audit)])
	_ok(int(audit.get("errors", 0)) == 0,
		"Settings → Lighting (SDFGI section) passes UiAudit at %dx%d (%d errors)" % [vp.size.x, vp.size.y, int(audit.get("errors", 0))])
	_save_shot(vp, "%s/settings_lighting_%dx%d.png" % [_out, vp.size.x, vp.size.y])
	if panel != null and panel.has_method("toggle") and bool(panel.call("is_open")):
		panel.call("toggle")
	await _settle(tree, 4)


func _check_terrain_shader_toggle(main: Node, ssc: Node, tree: SceneTree) -> void:
	var terrain := main.get_node_or_null("Terrain") as Node3D
	_ok(terrain != null, "Terrain node exists")
	if terrain == null:
		return
	var ground := terrain.get_node_or_null("Ground") as MeshInstance3D
	var detail := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	_ok(ground != null and ground.material_override is ShaderMaterial, "Ground uses ShaderMaterial")
	if ground == null or not (ground.material_override is ShaderMaterial):
		return
	var gsm := ground.material_override as ShaderMaterial
	var had_base := bool(gsm.get_shader_parameter("use_base"))
	ssc.call("apply_sdfgi_terrain_enabled", false)
	await _settle(tree, 3)
	_ok(gsm.shader == TerrainBuilder.DETAIL_NO_SDFGI_SHADER,
		"Ground shader swapped to DETAIL_NO_SDFGI_SHADER when SDFGI on terrain is off")
	_ok(bool(gsm.get_shader_parameter("use_base")) == had_base,
		"Ground preserved bound drape parameters across shader swap")
	if detail != null and detail.material_override is ShaderMaterial:
		_ok((detail.material_override as ShaderMaterial).shader == TerrainBuilder.DETAIL_NO_SDFGI_SHADER,
			"DetailGround shader swapped to DETAIL_NO_SDFGI_SHADER")
	_ok(ground.gi_mode == GeometryInstance3D.GI_MODE_STATIC,
		"Ground keeps GI_MODE_STATIC so sunlight still bounces off terrain onto structures")
	ssc.call("apply_sdfgi_terrain_enabled", true)
	await _settle(tree, 3)
	_ok(gsm.shader == TerrainBuilder.DETAIL_SHADER,
		"Ground shader restored to DETAIL_SHADER when SDFGI on terrain is re-enabled")


func _check_persistence(main: Node, ssc: Node, tree: SceneTree) -> void:
	ssc.call("apply_sdfgi_enabled", true)
	ssc.call("apply_sdfgi_energy_mult", 1.45)
	ssc.call("apply_sdfgi_terrain_enabled", false)
	ssc.call("persist_settings")
	ssc.call("apply_sdfgi_enabled", false)
	ssc.call("apply_sdfgi_energy_mult", 0.5)
	ssc.call("apply_sdfgi_terrain_enabled", true)
	await _settle(tree, 2)
	ssc.call("_load_persisted_settings")
	await _settle(tree, 4)
	_ok(bool(main.call("get_sdfgi_enabled")), "sdfgi_enabled reloads true")
	_ok(absf(float(main.call("get_sdfgi_energy_mult")) - 1.45) < 0.01,
		"sdfgi_energy_mult reloads 1.45 (got %.2f)" % float(main.call("get_sdfgi_energy_mult")))
	_ok(not bool(main.call("get_sdfgi_terrain_enabled")), "sdfgi_terrain_enabled reloads false")
	ssc.call("apply_sdfgi_energy_mult", 1.0)
	ssc.call("apply_sdfgi_terrain_enabled", true)
	await _settle(tree, 3)


func _check_altitude_handover(main: Node, ssc: Node, env: Environment,
		cam: Camera3D, centre: Vector2, _gy: float, tree: SceneTree) -> void:
	var qual := int(main.get("graphics_quality"))
	var prof := RenderProfile.sdfgi_profile(qual)
	var suspend_agl := float(prof["suspend_agl_m"])

	main.set("day_time", 12.8)
	ssc.call("apply_sdfgi_enabled", true)
	ssc.call("apply_sdfgi_energy_mult", 1.0)
	ssc.call("apply_sdfgi_terrain_enabled", true)
	main.call("_update")
	main.call("push_camera_claim", CLAIM, {"camera_id": cam.get_instance_id(), "hide_player_mesh": true})

	# 1) Low drone (18 m AGL over exact camera XZ): full calibrated SDFGI + matched outside sky ambient!
	_place_drone_agl(main, cam, centre, 90.0, 18.0, -18.0)
	main.call("_update_sdfgi_state", 0.0, true)
	await _settle(tree, 12)
	var e_low := env.sdfgi_energy
	var amb_low := env.ambient_light_energy
	_ok(env.sdfgi_enabled, "18 m AGL: SDFGI enabled (even when user saved Sky ambient = %.2f)" % float(main.call("get_ambient_sky_contribution")))
	_ok(env.sdfgi_cascades >= 4 and env.sdfgi_max_distance > 400.0,
		"18 m AGL: outdoor cascade span active (%d cascades, %.0f m max_distance)" % [env.sdfgi_cascades, env.sdfgi_max_distance])
	_ok(absf(e_low - SdfgiPolicy.DAY_SDFGI_ENERGY) < 0.03,
		"18 m AGL: calibrated noon sdfgi_energy near %.2f (got %.3f)" % [SdfgiPolicy.DAY_SDFGI_ENERGY, e_low])
	_ok(is_equal_approx(env.ambient_light_sky_contribution, 1.0) and amb_low > 0.30,
		"18 m AGL: outside sky ambient matched to SDFGI (sky_contrib=%.2f, energy=%.3f)" % [env.ambient_light_sky_contribution, amb_low])

	# 2) Survey drone above `suspend_agl_m`: SDFGI suspends (0 GPU cost) while sky ambient stays matched!
	_place_drone_agl(main, cam, centre, 90.0, suspend_agl + 35.0, -30.0)
	main.call("_update_sdfgi_state", 0.0, true)
	await _settle(tree, 10)
	_ok(not env.sdfgi_enabled and is_zero_approx(env.sdfgi_energy),
		"%.0f m AGL: survey altitude suspends SDFGI cleanly (0 GPU cost)" % (suspend_agl + 35.0))
	_ok(is_equal_approx(env.ambient_light_energy, amb_low),
		"%.0f m AGL: landscape sky ambient holds steady across handover (%.3f == %.3f)" % [suspend_agl + 35.0, env.ambient_light_energy, amb_low])

	# 3) Hysteresis check: inside deadband (`suspend_agl - 10 m`) stays suspended; below `suspend_agl - 30 m` re-enables!
	_place_drone_agl(main, cam, centre, 90.0, suspend_agl - 10.0, -24.0)
	main.call("_update_sdfgi_state", 0.0, true)
	await _settle(tree, 4)
	_ok(not env.sdfgi_enabled, "%.0f m AGL: hysteresis prevents chatter inside deadband" % (suspend_agl - 10.0))

	_place_drone_agl(main, cam, centre, 90.0, suspend_agl - 35.0, -22.0)
	main.call("_update_sdfgi_state", 0.0, true)
	await _settle(tree, 8)
	_ok(env.sdfgi_enabled and absf(env.sdfgi_energy - e_low) < 0.01,
		"%.0f m AGL: descending below deadband re-enables SDFGI cleanly" % (suspend_agl - 35.0))

	# 4) Turning SDFGI off restores player's original Sky ambient setting immediately.
	ssc.call("apply_sdfgi_enabled", false)
	await _settle(tree, 3)
	_ok(is_equal_approx(env.ambient_light_sky_contribution, float(main.call("get_ambient_sky_contribution"))),
		"disabling SDFGI restores player's original Sky ambient setting")


func _capture_comparisons(main: Node, ssc: Node, env: Environment,
		cam: Camera3D, centre: Vector2, tree: SceneTree) -> void:
	var vp := main.get_viewport()
	var open_field := centre + Vector2(2200.0, -400.0)
	var open_gy := TerrainSurfaceQuery.ground_height_at(main, open_field.x, open_field.y)
	if not is_finite(open_gy):
		open_gy = 0.0
	var site_gy := TerrainSurfaceQuery.ground_height_at(main, centre.x, centre.y)
	if not is_finite(site_gy):
		site_gy = 0.0

	var scenarios := [
		{"tag": "dusk_hills", "at": open_field, "gy": open_gy, "hour": 17.8, "agl": 45.0, "pitch": -26.0, "back": 0.0},
		{"tag": "noon_hills", "at": open_field, "gy": open_gy, "hour": 13.0, "agl": 45.0, "pitch": -26.0, "back": 0.0},
		{"tag": "site_dusk", "at": centre, "gy": site_gy, "hour": 17.8, "agl": 42.0, "pitch": -24.0, "back": 120.0},
		{"tag": "site_noon", "at": centre, "gy": site_gy, "hour": 13.5, "agl": 42.0, "pitch": -24.0, "back": 120.0},
	]
	for sc in scenarios:
		var tag := str(sc["tag"])
		var at: Vector2 = sc["at"]
		var gy := float(sc["gy"])
		main.set("day_time", float(sc["hour"]))
		main.call("_update")
		_place_drone(cam, at, gy, float(sc["agl"]), float(sc["pitch"]), float(sc["back"]))

		# 1) Reference: SDFGI OFF
		ssc.call("apply_sdfgi_terrain_enabled", true)
		ssc.call("apply_sdfgi_energy_mult", 1.0)
		ssc.call("apply_sdfgi_enabled", false)
		await _settle(tree, 36)
		var img_off := _save_shot(vp, "%s/%s_01_sdfgi_off.png" % [_out, tag])

		# 2) BEFORE (legacy uncalibrated: 4 cascades, 0.2 m cell, 50% Y, energy 1.0, user's low outside sky_contrib)
		main.set_process(false)
		env.sdfgi_enabled = false
		await _settle(tree, 3)
		env.ambient_light_sky_contribution = float(main.call("get_ambient_sky_contribution"))
		env.sdfgi_cascades = 4
		env.sdfgi_min_cell_size = 0.2
		env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_50_PERCENT
		env.sdfgi_bounce_feedback = 0.5
		env.sdfgi_energy = 1.0
		env.sdfgi_enabled = true
		await _settle(tree, 50)
		var img_legacy := _save_shot(vp, "%s/%s_02_before_legacy_square.png" % [_out, tag])
		env.sdfgi_enabled = false
		main.set_process(true)
		await _settle(tree, 4)

		# 3) AFTER Mode A: Calibrated SDFGI (0.28) + Matched Outside Sky + Wide Outdoor Cascades
		ssc.call("apply_sdfgi_terrain_enabled", true)
		ssc.call("apply_sdfgi_energy_mult", 1.0)
		ssc.call("apply_sdfgi_enabled", true)
		main.call("_update_sdfgi_state", 0.0, true)
		await _settle(tree, 50)
		var img_mode_a := _save_shot(vp, "%s/%s_03_after_mode_a_calibrated.png" % [_out, tag])

		# 4) AFTER Mode C: Structure-Only SDFGI ("SDFGI on terrain" unchecked)
		ssc.call("apply_sdfgi_terrain_enabled", false)
		ssc.call("apply_sdfgi_energy_mult", 1.0)
		main.call("_update_sdfgi_state", 0.0, true)
		await _settle(tree, 36)
		var img_mode_c := _save_shot(vp, "%s/%s_04_after_mode_c_terrain_optout.png" % [_out, tag])

		var step_legacy := _spotlight_box_contrast(img_legacy, img_off)
		var step_a := _spotlight_box_contrast(img_mode_a, img_off)
		var step_c := _spotlight_box_contrast(img_mode_c, img_off)
		var mean_off := _mean_ground_luma(img_off)
		var mean_a := _mean_ground_luma(img_mode_a)
		print("sdfgi-check [%s]: spotlight_step legacy=%.4f -> mode_a=%.4f  mode_c=%.4f  (ground_luma off=%.4f -> mode_a=%.4f)" % [
			tag, step_legacy, step_a, step_c, mean_off, mean_a])
		if tag == "dusk_hills":
			_ok(step_legacy > 0.010,
				"%s: legacy SDFGI shows sharp center-box spotlight step (%.4f)" % [tag, step_legacy])
			_ok(step_a < step_legacy * 0.40,
				"%s: Mode A eliminates >60%% of center-box spotlight step (%.4f vs %.4f)" % [tag, step_a, step_legacy])
			_ok(step_c < step_legacy * 0.40,
				"%s: Mode C eliminates >60%% of center-box spotlight step (%.4f vs %.4f)" % [tag, step_c, step_legacy])
		elif tag == "noon_hills":
			_ok(step_a <= step_legacy and step_a < 0.008,
				"%s: Mode A keeps center-vs-surround step tiny at noon (%.4f vs legacy %.4f)" % [tag, step_a, step_legacy])
			_ok(step_c <= step_legacy and step_c < 0.008,
				"%s: Mode C keeps center-vs-surround step tiny at noon (%.4f vs legacy %.4f)" % [tag, step_c, step_legacy])
		_save_quad(img_off, img_legacy, img_mode_a, img_mode_c, "%s/compare_%s.png" % [_out, tag])


func _place_drone_agl(main: Node, cam: Camera3D, centre: Vector2, back_m: float, agl_m: float, pitch_deg: float) -> void:
	var px := centre.x
	var pz := centre.y + back_m
	var local_gy := TerrainSurfaceQuery.ground_height_at(main, px, pz)
	if not is_finite(local_gy):
		local_gy = 0.0
	cam.global_position = Vector3(px, local_gy + agl_m, pz)
	cam.rotation_degrees = Vector3(pitch_deg, 0.0, 0.0)


func _place_drone(cam: Camera3D, centre: Vector2, gy: float, agl_m: float, pitch_deg: float, back_m: float) -> void:
	cam.global_position = Vector3(centre.x, gy + agl_m, centre.y + back_m)
	cam.rotation_degrees = Vector3(pitch_deg, 0.0, 0.0)


func _save_shot(vp: Viewport, path: String) -> Image:
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.save_png(path)
	return img


## Excess center-box brightness minus left/right outer-margin brightness (net of
## natural terrain albedo variations in `ref_off`). Directly measures the square
## spotlight artifact following the camera!
func _spotlight_box_contrast(img: Image, ref_off: Image) -> float:
	var w := mini(img.get_width(), ref_off.get_width())
	var h := mini(img.get_height(), ref_off.get_height())
	var y0 := int(float(h) * 0.46)
	var y1 := int(float(h) * 0.76)
	var center_sum := 0.0
	var center_n := 0
	var outer_sum := 0.0
	var outer_n := 0
	for y in range(y0, y1, 4):
		for x in range(0, w, 4):
			var fx := float(x) / float(maxi(w, 1))
			var ci := img.get_pixel(x, y)
			var cr := ref_off.get_pixel(x, y)
			var dl := (0.299 * ci.r + 0.587 * ci.g + 0.114 * ci.b) - (0.299 * cr.r + 0.587 * cr.g + 0.114 * cr.b)
			if fx >= 0.34 and fx <= 0.66:
				center_sum += dl
				center_n += 1
			elif fx <= 0.16 or fx >= 0.84:
				outer_sum += dl
				outer_n += 1
	var c_mean := center_sum / float(maxi(center_n, 1))
	var o_mean := outer_sum / float(maxi(outer_n, 1))
	return absf(c_mean - o_mean)


func _mean_ground_luma(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var y0 := int(float(h) * 0.48)
	var sum := 0.0
	var n := 0
	for y in range(y0, h, 4):
		for x in range(0, w, 4):
			var c := img.get_pixel(x, y)
			sum += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			n += 1
	return sum / float(maxi(n, 1))


func _save_quad(i0: Image, i1: Image, i2: Image, i3: Image, path: String) -> void:
	var cw := 640
	var ch := int(640.0 * float(i0.get_height()) / float(maxi(i0.get_width(), 1)))
	var sheet := Image.create(cw * 2, ch * 2, false, Image.FORMAT_RGB8)
	var tiles := [i0, i1, i2, i3]
	for idx in 4:
		var t: Image = (tiles[idx] as Image).duplicate()
		t.resize(cw, ch, Image.INTERPOLATE_BILINEAR)
		var ox := (idx % 2) * cw
		var oy := int(idx / 2) * ch
		sheet.blit_rect(t, Rect2i(0, 0, cw, ch), Vector2i(ox, oy))
	sheet.save_png(path)


func _hide_ui(main: Node) -> Array:
	var out: Array = []
	for n in main.get_children():
		if n is CanvasLayer and (n as CanvasLayer).visible:
			(n as CanvasLayer).visible = false
			out.append(n)
	return out

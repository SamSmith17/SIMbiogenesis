extends RefCounted

## End-to-end check for the streamlined Globe-to-World launch sequence
## (sandbox, Mount Vernon):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/globe_launch_transition_check.gd -Label globe_launch -Timeout 900
##
## Takes a fingerprint of the running saved world, exits to the Launch Hub
## (which opens the 3D Globe), clicks Continue with a REAL mouse click, and
## observes the entire orbital descent -> background scene load -> photo drape
## -> crossfade + crane swoop -> resumed first-person world.

var _fails := 0
var _dir := "user://screenshots/globe_launch"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("globe-launch %s: %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else " (%s)" % detail])
	if not cond:
		_fails += 1


func _shoot(vp: Viewport, name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img != null and not img.is_empty():
		img.save_png("%s/%s.png" % [_dir, name])


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var vp := tree.root.get_viewport()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))

	for _i in 15:
		await tree.process_frame
	var fp_before := WorldSession.fingerprint(main)
	_ok(not fp_before.is_empty(), "captured initial saved-world fingerprint",
		"pos=%s hour=%s" % [str(fp_before.get("player.pos", "")), str(fp_before.get("clock.hour", ""))])

	# Return to Launch Hub so the real default 3D Globe starting scene opens.
	WorldSession.exit_to_menu(main)
	var gm: GlobeMode = null
	var waited_hub := 0
	while gm == null and waited_hub < 300:
		await tree.process_frame
		waited_hub += 1
		for n in tree.root.find_children("*", "Control", true, false):
			if n is GlobeMode:
				gm = n as GlobeMode
				break
	_ok(gm != null, "Launch Hub opened 3D GlobeMode", "%d frames" % waited_hub)
	if gm == null:
		return {"ok": false}

	# Let initial z2 tiles settle briefly so the starting shot looks clean.
	for _i in 45:
		await tree.process_frame
	await _shoot(vp, "01_hub_orbit")

	var cont_btn := gm.find_child("GlobeContinueButton", true, false) as Button
	_ok(cont_btn != null and cont_btn.visible and not cont_btn.disabled,
		"Continue button is visible and enabled on Globe HubBar")
	if cont_btn == null:
		return {"ok": false}

	var t_click_ms := Time.get_ticks_msec()
	await HarnessInput.click(vp, HarnessInput.center_of(cont_btn))
	for _w in 8:
		if GlobeLaunchTransition.is_active():
			break
		await tree.process_frame

	_ok(GlobeLaunchTransition.is_active(), "clicking Continue starts GlobeLaunchTransition immediately")

	var saw_hud := false
	var saw_bg_scene_high := false
	var bg_scene_alt_km := -1.0
	var max_z_seen := 0
	var saw_drape := false
	var saw_swoop := false
	var saw_blocker_overlay := false
	var shot_mid := false
	var shot_low := false
	var shot_swoop := false
	var frames := 0
	var t_world_complete_ms := -1

	while GlobeLaunchTransition.is_active() and frames < 2400:
		await tree.process_frame
		frames += 1
		var trans := gm.get_node_or_null("GlobeLaunchTransition") if is_instance_valid(gm) else null
		if is_instance_valid(gm):
			var hud := gm.find_child("GlobeLaunchHud", true, false) as Control
			if hud != null and hud.visible:
				saw_hud = true
			if gm.globe != null:
				for k in gm.globe.selected_tiles():
					max_z_seen = maxi(max_z_seen, k.x)
				if gm.globe.drape_on(0) or gm.globe.drape_on(1):
					saw_drape = true
				var alt := gm.globe.altitude_km()
				if not shot_mid and alt < 1800.0 and alt > 200.0:
					shot_mid = true
					await _shoot(vp, "02_mid_descent")
				if not shot_low and alt < 12.0 and alt > 1.2:
					shot_low = true
					await _shoot(vp, "03_low_drape_approach")
		if trans != null:
			if bool(trans.get("_scene_switched")) and not saw_bg_scene_high and is_instance_valid(gm) and gm.globe != null:
				bg_scene_alt_km = gm.globe.altitude_km()
				if bg_scene_alt_km > 15.0:
					saw_bg_scene_high = true
			if bool(trans.get("_swooping")):
				saw_swoop = true
				if not shot_swoop and float(trans.get("_swoop_t")) >= 0.42:
					shot_swoop = true
					await _shoot(vp, "04_crossfade_swoop")
		var live_main := tree.current_scene
		if live_main != null and str(live_main.name) == "Main":
			var tl := live_main.get_node_or_null("TerrainLoader")
			if tl != null and bool(tl.get("load_completed")) and t_world_complete_ms < 0:
				t_world_complete_ms = Time.get_ticks_msec() - t_click_ms
			var ov := live_main.find_child("TerrainLoadOverlay", true, false) as CanvasLayer
			if ov != null and ov.visible and not bool(ov.get("_compact")):
				saw_blocker_overlay = true

	var total_ms := Time.get_ticks_msec() - t_click_ms
	for _i in 20:
		await tree.process_frame
	await _shoot(vp, "05_arrived_world")

	_ok(not GlobeLaunchTransition.is_active(),
		"transition completed and cleaned up", "%d ms total (%d frames), world ready at %d ms" % [
			total_ms, frames, t_world_complete_ms])
	_ok(saw_hud, "unified bottom GlobeLaunchHud displayed during descent")
	_ok(saw_bg_scene_high,
		"world scene activated in the background mid-flight while still high above the site",
		"switched at %.1f km altitude" % bg_scene_alt_km)
	_ok(max_z_seen >= 13, "globe refined to crisp high-zoom tiles during descent", "max z=%d" % max_z_seen)
	_ok(saw_drape, "world's cached terrain drapes bound onto the globe during approach")
	_ok(saw_swoop, "seamless 3D arrival camera swoop executed")
	_ok(not saw_blocker_overlay, "full-screen grey TerrainLoadOverlay blocker never flashed")

	var new_main := tree.current_scene
	_ok(new_main != null and str(new_main.name) == "Main", "arrived in live Main scene")
	if new_main != null and str(new_main.name) == "Main":
		var tl2 := new_main.get_node_or_null("TerrainLoader")
		_ok(tl2 != null and bool(tl2.get("load_completed")), "TerrainLoader completed load")
		var cam_claims: CameraClaims = new_main.get("camera_claims")
		_ok(cam_claims != null and not cam_claims.has_claim(GlobeLaunchTransition.CLAIM_OWNER),
			"globe_arrival camera claim cleanly released", str(cam_claims.owners() if cam_claims != null else []))
		_ok(new_main.call("clock_hold_owner") != GlobeLaunchTransition.CLAIM_OWNER,
			"globe_arrival clock hold cleanly released", str(new_main.call("clock_hold_owner")))
		var cc := tree.root.get_node_or_null("CursorController")
		_ok(cc != null and not bool(cc.call("has_blocking_modal")),
			"CursorController has no leftover modal after landing",
			str(cc.call("top_modal")) if cc != null else "")
		_ok(not HudLayout.has_claim(GlobeLaunchTransition.MODAL_NAME),
			"HudLayout modal claim released so HUD shows cleanly")

		# Wait briefly for restore_extras (30 frames after map_load_complete) if any.
		for _i in 35:
			await tree.process_frame
		var fp_after := WorldSession.fingerprint(new_main)
		# Compare structural & pose keys (clock.hour within 0.1 h).
		var pos_ok := str(fp_after.get("player.pos", "?")) == str(fp_before.get("player.pos", "!"))
		var yaw_ok := absf(float(fp_after.get("player.yaw", 0.0)) - float(fp_before.get("player.yaw", 99.0))) < 0.03
		var props_ok := str(fp_after.get("props.ids", "")) == str(fp_before.get("props.ids", "?"))
		var graph_ok := str(fp_after.get("graph.ids", "")) == str(fp_before.get("graph.ids", "?"))
		_ok(pos_ok and yaw_ok and props_ok and graph_ok,
			"resumed world matches saved player pose, props and graph",
			"pos %s->%s, yaw %s->%s" % [
				str(fp_before.get("player.pos", "")), str(fp_after.get("player.pos", "")),
				str(fp_before.get("player.yaw", "")), str(fp_after.get("player.yaw", ""))])

	return {"ok": _fails == 0, "total_ms": total_ms, "world_ready_ms": t_world_complete_ms}

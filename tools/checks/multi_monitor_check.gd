extends RefCounted

## End-to-end Multi-Monitor verification on a real world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/multi_monitor_check.gd -Label multimonitor
##
## Verifies:
##   1. Settings -> Multi-Monitor opens (and legacy "Window Wall" alias resolves
##      to it), renders the monitor diagram + Window Wall sub-option, and passes
##      UiAudit with 0 errors.
##   2. Launching simultaneous secondary monitor windows:
##        - Touchscreen monitor -> Systems Graph (undocked, touch mode, full height)
##        - Portrait monitor    -> Biochar Reactor in live Process Mode (vertical
##                                 VSplitContainer: 3D studio top, charts bottom)
##        - Auxiliary monitor   -> 3D Overhead Site Camera (shared World3D)
##      while Main keeps the live 3D Player View unblocked (disable_3d == false,
##      no CursorController modal lock, sky/env updates active).
##   3. Draggable Windowed -> Fullscreen -> Windowed transition records monitor
##      fingerprint + placement and applies DWM-safe borderless fullscreen.
##   4. Closing secondary windows redocks SystemGraphView cleanly back under
##      Main/UILayer and restores root.gui_embed_subwindows.

var _fails: Array = []
var _dir := "user://screenshots/multimonitor"


func _ok(cond: bool, what: String, detail: String = "") -> void:
	var suffix := ("  (%s)" % detail) if not detail.is_empty() else ""
	print("multimonitor %s: %s%s" % ["PASS" if cond else "FAIL", what, suffix])
	if not cond:
		_fails.append(what + suffix)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func _save_window_shot(vp: Viewport, file_stem: String) -> bool:
	await RenderingServer.frame_post_draw
	if vp == null or vp.get_texture() == null:
		return false
	var img := vp.get_texture().get_image()
	if img == null or img.is_empty():
		return false
	img.save_png("%s/%s.png" % [_dir, file_stem])
	return true


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))

	# Use a temp prefs path inside the sandbox so any test writes stay isolated.
	var tmp_cfg := "user://selftest_mm_live.cfg"
	if FileAccess.file_exists(tmp_cfg):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_cfg))
	MultiMonitorPrefs.cfg_path = tmp_cfg
	MultiMonitorPrefs.reset_for_test()

	var embed_before := tree.root.gui_embed_subwindows

	# --- 1. Settings -> Multi-Monitor drawer + UiAudit ------------------------
	main.call("open_settings_page", "Window Wall")  # test backwards-compat alias too
	await _settle(tree, 8)
	var tl := ServiceLocator.timeline_ui()
	var sp: Control = tl.get("_settings_panel") as Control if tl != null else null
	_ok(sp != null and sp.visible and str(sp.call("current_page")) == "Multi-Monitor",
		"Settings -> Multi-Monitor opens (incl. legacy Window Wall alias)",
		str(sp.call("current_page")) if sp != null else "null")
	var audit_settings := UiAudit.run(tree.root.get_viewport())
	_ok(int(audit_settings.get("errors", 0)) == 0,
		"Multi-Monitor settings drawer passes UiAudit",
		UiAudit.summary_line(audit_settings))
	await _save_window_shot(tree.root.get_viewport(), "01_settings_multimonitor")
	if sp != null and sp.has_method("close"):
		sp.call("close")
	await _settle(tree, 6)

	# --- 2. Configure & launch Touchscreen Graph + Portrait Biochar + 3D Cam ---
	MultiMonitorPrefs.set_value("enabled", true)
	var s_touch := MultiMonitorPrefs.add_slot({
		"label": "Touchscreen",
		"starting_view": MultiMonitorCatalog.VIEW_SYSTEM_GRAPH,
		"touchscreen": true,
		"windowed_size": Vector2i(1280, 800),
	})
	var s_port := MultiMonitorPrefs.add_slot({
		"label": "Portrait Reactor",
		"starting_view": MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR,
		"portrait_override": MultiMonitorPrefs.PORTRAIT_PORTRAIT,
		"windowed_size": Vector2i(900, 1520),
	})
	var s_cam := MultiMonitorPrefs.add_slot({
		"label": "Site Overhead",
		"starting_view": MultiMonitorCatalog.VIEW_OVERHEAD_3D,
		"windowed_size": Vector2i(1100, 700),
	})
	MultiMonitorPrefs.save()

	var host: MultiMonitorHost = main.call("ensure_multi_monitor_host")
	await host.open_all_enabled()
	await _settle(tree, 30)

	var w_touch := host.get_slot_window(str(s_touch["id"]))
	var w_port := host.get_slot_window(str(s_port["id"]))
	var w_cam := host.get_slot_window(str(s_cam["id"]))

	_ok(w_touch != null and w_port != null and w_cam != null,
		"all 3 secondary monitor windows spawned")

	# New unplaced windows must start in draggable Windowed mode!
	_ok(w_touch != null and not w_touch.is_monitor_fullscreen and not w_touch.borderless,
		"new secondary windows launch in draggable OS-windowed mode first")

	# Main 3D window stays completely live & unblocked!
	_ok(not tree.root.get_viewport().disable_3d,
		"main 3D viewport keeps rendering 3D while Systems Graph is on Touchscreen")
	_ok(not CursorController.has_blocking_modal(),
		"secondary monitor modals do NOT block CursorController on main 3D window",
		"top_modal=" + CursorController.top_modal())
	_ok(not bool(main.call("_graph_view_visible")),
		"main sky/environment throttle treats undocked graph as non-blocking")

	# Touchscreen Systems Graph checks
	var sgv := ServiceLocator.graph() as Control
	_ok(sgv != null and bool(sgv.call("is_undocked_window")) and sgv.get_window() == w_touch and sgv.visible,
		"Systems Graph is live inside the Touchscreen window")
	_ok(main.find_child("SystemGraphView", true, false) == sgv,
		"main.find_child('SystemGraphView') still resolves while undocked")
	_ok(sgv != null and is_zero_approx(float(sgv.call("_timeline_bottom_inset"))),
		"undocked Systems Graph uses 100% window height (0 timeline inset)")

	# Portrait Biochar Reactor checks (vertical split: 3D top, Process charts bottom)
	if w_port != null:
		w_port.size = Vector2i(960, 1600)
		await _settle(tree, 25)
		var tc_ui := w_port.view_node() as Control
		var shell: DesignerShell = tc_ui.get("_shell") as DesignerShell if tc_ui != null else null
		_ok(tc_ui != null and bool(tc_ui.call("is_process_mode")),
			"Portrait monitor opened Biochar Reactor directly in live Process Mode")
		_ok(shell != null and shell.is_portrait_layout(),
			"DesignerShell switched to dedicated Portrait vertical split",
			"size=%s" % str(w_port.size))
		if shell != null:
			var studio_y := shell.centre.get_global_rect().position.y
			var charts_y := (shell.get("_right_scroll") as Control).get_global_rect().position.y
			_ok(charts_y > studio_y + 150.0,
				"Portrait split places 3D Reactor studio on top and Process charts stacked below",
				"studio_y=%.0f charts_y=%.0f" % [studio_y, charts_y])
		var audit_port := UiAudit.run(w_port)
		_ok(int(audit_port.get("errors", 0)) == 0,
			"Portrait Biochar Reactor passes UiAudit",
			UiAudit.summary_line(audit_port))

	# Overhead 3D shared-World3D camera checks
	if w_cam != null:
		var cam3d := w_cam.get_camera_3d()
		_ok(cam3d != null and w_cam.find_world_3d() == tree.root.find_world_3d(),
			"3D Overhead monitor shares Main's World3D with an active Camera3D")

	# Save frames from all 4 active windows!
	_ok(await _save_window_shot(tree.root.get_viewport(), "02_main_3d_player"),
		"captured Main 3D window frame")
	if w_touch != null:
		_ok(await _save_window_shot(w_touch, "03_touchscreen_graph"),
			"captured Touchscreen Systems Graph window frame")
	if w_port != null:
		_ok(await _save_window_shot(w_port, "04_portrait_biochar_reactor"),
			"captured Portrait Biochar Reactor window frame")
	if w_cam != null:
		_ok(await _save_window_shot(w_cam, "05_overhead_3d_camera"),
			"captured Overhead 3D window frame")

	# --- 3. Draggable Windowed -> Fullscreen -> Windowed persistence ----------
	if w_touch != null:
		w_touch.toggle_monitor_fullscreen()
		await _settle(tree, 8)
		var saved_slot := MultiMonitorPrefs.slot_by_id(w_touch.slot_id)
		_ok(w_touch.is_monitor_fullscreen and w_touch.borderless
			and bool(saved_slot.get("placed", false)) and bool(saved_slot.get("is_fullscreen", false)),
			"toggling Fullscreen applies DWM-safe borderless fullscreen & records monitor placement")
		w_touch.toggle_monitor_fullscreen()
		await _settle(tree, 8)
		var saved_back := MultiMonitorPrefs.slot_by_id(w_touch.slot_id)
		_ok((not w_touch.is_monitor_fullscreen) and (not w_touch.borderless)
			and not bool(saved_back.get("is_fullscreen", true)),
			"toggling back to Windowed restores draggable window & clears fullscreen flag")

	# --- 4. Clean teardown & SystemGraphView redock ---------------------------
	host.close_all()
	await _settle(tree, 10)

	var sgv_after := ServiceLocator.graph() as Control
	var ui_layer := ServiceLocator.ui_layer()
	_ok(host.active_window_count() == 0, "all secondary windows closed and freed")
	_ok(sgv_after != null and sgv_after.get_parent() == ui_layer and not bool(sgv_after.call("is_undocked_window")),
		"SystemGraphView redocked cleanly back under Main/UILayer")
	_ok(tree.root.gui_embed_subwindows == embed_before,
		"root.gui_embed_subwindows restored on teardown")

	# Cleanup temp cfg
	if FileAccess.file_exists(tmp_cfg):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_cfg))
	MultiMonitorPrefs.cfg_path = MultiMonitorPrefs.CFG_PATH
	MultiMonitorPrefs.reset_for_test()

	return {"ok": _fails.is_empty(), "failures": _fails}

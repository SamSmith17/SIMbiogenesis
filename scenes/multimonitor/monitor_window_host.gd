class_name MonitorWindowHost
extends Window

## One secondary OS monitor window managed by `MultiMonitorHost`.
##
## Lifecycle & workflow:
##   1. New / unplaced monitor slots open as standard OS-decorated, draggable,
##      resizable windows (`Window.MODE_WINDOWED`) so the user can drag them to
##      any of their 5 monitors (4 landscape, 1 portrait, 1 touchscreen) and
##      click `⛶ Fullscreen` (or press F11 / Alt+Enter).
##   2. Entering fullscreen detects which OS screen currently holds the window,
##      records that monitor's geometry fingerprint `(x,y,wxh)` + fullscreen
##      flag in `MultiMonitorPrefs`, and applies DWM-safe borderless fullscreen
##      (`h - 1` anti-DirectFlip guard so multi-GPU 5th monitors never show a
##      flat grey Vulkan swapchain).
##   3. Inside each secondary window, `gui_embed_subwindows = true` keeps all
##      `OptionButton` dropdowns, popups, and flyouts embedded inside THAT
##      monitor (essential for Touchscreens and Portrait panels).

signal closed_by_user(slot_id: String)
signal dock_to_main_requested(slot_id: String)
signal state_changed(slot_id: String)

const OVERHEAD_CAM_SCRIPT := preload("res://scenes/multimonitor/overhead_monitor_camera.gd")
const SOLAR_VIEW_SCRIPT   := preload("res://scenes/multimonitor/solar_monitor_view.gd")
const GEOM_POLL_S := 0.25
const SAVE_DEBOUNCE_S := 0.65
const CHROME_IDLE_FADE_S := 4.0

var slot_id := ""
var active_view_id := ""
var is_monitor_fullscreen := false

var _host: Node = null
var _main: Node = null
var _cascade_idx := 0
var _content_root: Control = null
var _view_node: Node = null
var _wall_cam: Camera3D = null
var _reparented_node: Node = null
var _reparent_orig_parent: Node = null
var _reparent_orig_idx := -1
var _reparent_was_visible := false

# Top-right window chrome pill
var _chrome_layer: CanvasLayer = null
var _chrome_pill: PanelContainer = null
var _title_lbl: Label = null
var _view_opt: OptionButton = null
var _view_ids: PackedStringArray = PackedStringArray()
var _dock_btn: Button = null
var _touch_btn: Button = null
var _fs_btn: Button = null
var _close_btn: Button = null
var _chrome_idle_t := 0.0
var _touch_mode := false

# Placement tracking
var _poll_accum := 0.0
var _dirty_save_t := -1.0
var _last_windowed_pos := Vector2i.ZERO
var _last_windowed_size := Vector2i(1280, 800)
var _suppressing_geom_poll := false
var _closing := false


func configure_before_tree(main: Node, host: Node, slot_cfg: Dictionary, cascade_idx: int) -> Dictionary:
	_main = main
	_host = host
	_cascade_idx = cascade_idx
	slot_id = str(slot_cfg.get("id", "mon_1"))
	active_view_id = str(slot_cfg.get("starting_view", MultiMonitorCatalog.DEFAULT_VIEW))
	_touch_mode = bool(slot_cfg.get("touchscreen", false))
	name = "MonitorWindow_%s" % slot_id

	# Keep dropdowns/popups embedded INSIDE this secondary monitor window.
	gui_embed_subwindows = true
	wrap_controls = false
	transparent_bg = false

	var shares_3d := MultiMonitorCatalog.shares_world_3d(active_view_id)
	if shares_3d and main != null and main.get_viewport() != null:
		own_world_3d = false
		world_3d = main.get_viewport().world_3d
		disable_3d = false
		_copy_3d_viewport_settings(main.get_tree().root, float(slot_cfg.get("render_scale_3d", 1.0)))
	else:
		own_world_3d = true
		disable_3d = true

	var screens := MultiMonitorDisplay.os_screens()
	var matched_scr := MultiMonitorDisplay.resolve_screen(
		str(slot_cfg.get("screen_fingerprint", "")),
		int(slot_cfg.get("screen_index", -1)),
		screens
	)
	var want_auto_fs := bool(slot_cfg.get("placed", false)) \
		and bool(slot_cfg.get("is_fullscreen", false)) \
		and MultiMonitorPrefs.auto_fullscreen_saved() \
		and matched_scr >= 0

	var p_ovr := int(slot_cfg.get("portrait_override", 0))
	var scr_dict := MultiMonitorDisplay.screen_by_index(screens,
		matched_scr if matched_scr >= 0 else MultiMonitorDisplay.primary_screen_index(screens))
	var want_portrait := (p_ovr == MultiMonitorPrefs.PORTRAIT_PORTRAIT) \
		or (p_ovr == MultiMonitorPrefs.PORTRAIT_AUTO and bool(scr_dict.get("is_portrait", false)))

	var saved_pos: Vector2i = slot_cfg.get("windowed_pos", MultiMonitorPrefs.UNSET_POS)
	var saved_sz: Vector2i = slot_cfg.get("windowed_size", Vector2i.ZERO)
	var win_rect: Rect2i
	if saved_pos != MultiMonitorPrefs.UNSET_POS and saved_sz.x >= MultiMonitorDisplay.MIN_WIN_SIZE.x:
		win_rect = MultiMonitorDisplay.rescue_window_rect(Rect2i(saved_pos, saved_sz), screens, cascade_idx)
	else:
		win_rect = MultiMonitorDisplay.default_windowed_rect(scr_dict, want_portrait, cascade_idx)
	_last_windowed_pos = win_rect.position
	_last_windowed_size = win_rect.size

	if want_auto_fs:
		is_monitor_fullscreen = true
		var use_os_fs := MultiMonitorPrefs.fullscreen_method() == MultiMonitorPrefs.FS_METHOD_OS_FULLSCREEN
		var fs_rect := MultiMonitorDisplay.dwm_safe_fullscreen_rect(scr_dict, not use_os_fs)
		borderless = true
		unresizable = true
		position = fs_rect.position
		size = fs_rect.size
	else:
		is_monitor_fullscreen = false
		borderless = false
		unresizable = false
		mode = Window.MODE_WINDOWED
		position = win_rect.position
		size = win_rect.size

	_refresh_window_title(slot_cfg)
	return {
		"want_auto_fs": want_auto_fs,
		"matched_scr": matched_scr,
		"scr_dict": scr_dict,
	}


func finish_open_after_tree(slot_cfg: Dictionary, open_plan: Dictionary) -> void:
	UITheme.install_window(
		self,
		int(slot_cfg.get("portrait_override", 0)),
		float(slot_cfg.get("ui_scale", 0.0))
	)
	close_requested.connect(_on_close_requested)

	_content_root = Control.new()
	_content_root.name = "ContentRoot"
	_content_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content_root.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content_root)

	_build_chrome_pill(slot_cfg)

	if bool(open_plan.get("want_auto_fs", false)):
		var scr_dict: Dictionary = open_plan.get("scr_dict", {})
		_apply_fullscreen_state(true, scr_dict, false)

	_mount_view(active_view_id, slot_cfg)
	_update_chrome_state()


func _refresh_window_title(slot_cfg: Dictionary) -> void:
	var lbl := str(slot_cfg.get("label", slot_id))
	var v_short := MultiMonitorCatalog.short_label_of(active_view_id)
	if is_monitor_fullscreen:
		title = I18n.f("SIMbiogenesis — {lbl} · {v_short}", {"lbl": lbl, "v_short": v_short})
	else:
		title = I18n.f("SIMbiogenesis — {lbl} · {v_short}  (Drag to monitor, click ⛶ Fullscreen or press F11)", {"lbl": lbl, "v_short": v_short})


# ---------------------------------------------------------------------------
# Fullscreen <-> Draggable Windowed transitions
# ---------------------------------------------------------------------------

func toggle_monitor_fullscreen() -> void:
	set_monitor_fullscreen(not is_monitor_fullscreen)


func set_monitor_fullscreen(want_fs: bool, persist: bool = true) -> void:
	if _closing:
		return
	_suppressing_geom_poll = true
	var screens := MultiMonitorDisplay.os_screens()
	if want_fs:
		if not is_monitor_fullscreen and mode == Window.MODE_WINDOWED:
			_last_windowed_pos = position
			_last_windowed_size = size
		var target_scr_idx := MultiMonitorDisplay.screen_containing_rect(Rect2i(position, size), screens)
		var scr_dict := MultiMonitorDisplay.screen_by_index(screens, target_scr_idx)
		_apply_fullscreen_state(true, scr_dict, persist)
	else:
		_apply_fullscreen_state(false, {}, persist)
	_update_chrome_state()
	var slot_cfg := MultiMonitorPrefs.slot_by_id(slot_id)
	_refresh_window_title(slot_cfg if not slot_cfg.is_empty() else {"label": slot_id})
	get_tree().create_timer(0.2).timeout.connect(func() -> void:
		_suppressing_geom_poll = false)
	state_changed.emit(slot_id)


func _apply_fullscreen_state(want_fs: bool, scr_dict: Dictionary, persist: bool) -> void:
	var screens := MultiMonitorDisplay.os_screens()
	if want_fs and not scr_dict.is_empty():
		is_monitor_fullscreen = true
		var scr_idx := int(scr_dict.get("index", 0))
		var use_os_fs := MultiMonitorPrefs.fullscreen_method() == MultiMonitorPrefs.FS_METHOD_OS_FULLSCREEN
		if use_os_fs:
			borderless = true
			unresizable = true
			current_screen = scr_idx
			mode = Window.MODE_FULLSCREEN
		else:
			if mode != Window.MODE_WINDOWED:
				mode = Window.MODE_WINDOWED
			var fs_rect := MultiMonitorDisplay.dwm_safe_fullscreen_rect(scr_dict, true)
			borderless = true
			unresizable = true
			always_on_top = false
			position = fs_rect.position
			size = fs_rect.size
		if persist:
			MultiMonitorPrefs.record_placement(
				slot_id,
				scr_idx,
				MultiMonitorDisplay.fingerprint_of(scr_dict),
				_last_windowed_pos,
				_last_windowed_size,
				true
			)
			MultiMonitorPrefs.save()
	else:
		is_monitor_fullscreen = false
		if mode != Window.MODE_WINDOWED:
			mode = Window.MODE_WINDOWED
		borderless = false
		unresizable = false
		always_on_top = false
		var target_rect := MultiMonitorDisplay.rescue_window_rect(
			Rect2i(_last_windowed_pos, _last_windowed_size), screens, _cascade_idx)
		size = target_rect.size
		position = target_rect.position
		_last_windowed_pos = position
		_last_windowed_size = size
		if persist:
			var cur_scr := MultiMonitorDisplay.screen_containing_rect(target_rect, screens)
			var cur_dict := MultiMonitorDisplay.screen_by_index(screens, cur_scr)
			MultiMonitorPrefs.record_placement(
				slot_id,
				cur_scr,
				MultiMonitorDisplay.fingerprint_of(cur_dict) if not cur_dict.is_empty() else "",
				_last_windowed_pos,
				_last_windowed_size,
				false
			)
			MultiMonitorPrefs.save()


## Re-centre as a draggable window on the primary screen ("Gather All").
func gather_to_primary_windowed(cascade_idx: int) -> void:
	var screens := MultiMonitorDisplay.os_screens()
	var prim := MultiMonitorDisplay.screen_by_index(screens, MultiMonitorDisplay.primary_screen_index(screens))
	var slot_cfg := MultiMonitorPrefs.slot_by_id(slot_id)
	var p_ovr := int(slot_cfg.get("portrait_override", 0))
	var rect := MultiMonitorDisplay.default_windowed_rect(prim, p_ovr == MultiMonitorPrefs.PORTRAIT_PORTRAIT, cascade_idx)
	_last_windowed_pos = rect.position
	_last_windowed_size = rect.size
	set_monitor_fullscreen(false, true)


# ---------------------------------------------------------------------------
# View mounting & clean teardown
# ---------------------------------------------------------------------------

func switch_view(new_view_id: String) -> void:
	if not MultiMonitorCatalog.has_view(new_view_id) or new_view_id == active_view_id:
		return
	_unmount_current_view()
	active_view_id = new_view_id
	MultiMonitorPrefs.set_slot_value_by_id(slot_id, "starting_view", new_view_id)
	MultiMonitorPrefs.save()

	var slot_cfg := MultiMonitorPrefs.slot_by_id(slot_id)
	var shares_3d := MultiMonitorCatalog.shares_world_3d(active_view_id)
	if shares_3d and _main != null and _main.get_viewport() != null:
		own_world_3d = false
		world_3d = _main.get_viewport().world_3d
		disable_3d = false
		_copy_3d_viewport_settings(_main.get_tree().root, float(slot_cfg.get("render_scale_3d", 1.0)))
	else:
		disable_3d = true

	_mount_view(active_view_id, slot_cfg)
	_refresh_window_title(slot_cfg)
	_update_chrome_state()
	state_changed.emit(slot_id)


func refresh_from_prefs() -> void:
	var slot_cfg := MultiMonitorPrefs.slot_by_id(slot_id)
	if slot_cfg.is_empty():
		return
	_touch_mode = bool(slot_cfg.get("touchscreen", false))
	set_meta("mm_portrait_override", int(slot_cfg.get("portrait_override", 0)))
	set_meta("mm_ui_scale_override", float(slot_cfg.get("ui_scale", 0.0)))
	UiThemeBuilder._apply_secondary_window_scale(self)
	if _title_lbl != null:
		_title_lbl.text = str(slot_cfg.get("label", slot_id))
	var want_view := str(slot_cfg.get("starting_view", active_view_id))
	if want_view != active_view_id:
		switch_view(want_view)
	else:
		_refresh_window_title(slot_cfg)
		_update_chrome_state()


func view_node() -> Node:
	return _view_node


func _mount_view(view_id: String, slot_cfg: Dictionary) -> void:
	if _main == null or not is_instance_valid(_main):
		_mount_placeholder("Open a world first to activate %s." % MultiMonitorCatalog.label_of(view_id))
		return

	if MultiMonitorCatalog.is_system_graph_variant(view_id):
		_mount_system_graph(view_id)
		return

	match view_id:
		MultiMonitorCatalog.VIEW_TCLAB_BIOCHAR:
			_mount_tclab({"preset": "biochar_reactor", "process_mode": true, "auto_prerun": true, "auto_bind_model": "biochar"})
		MultiMonitorCatalog.VIEW_TCLAB_GENSET:
			_mount_tclab({"preset": "biochar_genset", "process_mode": true, "auto_prerun": true})
		MultiMonitorCatalog.VIEW_TCLAB_DESIGNER:
			_mount_tclab({})
		MultiMonitorCatalog.VIEW_BATTERYLAB:
			_mount_designer_script("res://scenes/ui/batterylab_modal.gd", {})
		MultiMonitorCatalog.VIEW_PVLAB:
			_mount_designer_script("res://scenes/ui/pvlab_modal.gd", {}, true)
		MultiMonitorCatalog.VIEW_CTRLLAB:
			_mount_designer_script("res://scenes/ui/ctrllab_modal.gd", {})
		MultiMonitorCatalog.VIEW_ESPLAB:
			_mount_designer_script("res://scenes/ui/esplab_modal.gd", {})
		MultiMonitorCatalog.VIEW_WINDLAB:
			_mount_designer_script("res://scenes/ui/windlab_modal.gd", {})
		MultiMonitorCatalog.VIEW_PELTONLAB:
			_mount_designer_script("res://scenes/ui/peltonlab_modal.gd", {})
		MultiMonitorCatalog.VIEW_CSPLAB:
			_mount_designer_script("res://scenes/ui/csplab_modal.gd", {})
		MultiMonitorCatalog.VIEW_GANTRYLAB:
			_mount_designer_script("res://scenes/ui/gantrylab_modal.gd", {}, true)
		MultiMonitorCatalog.VIEW_DOMELAB:
			_mount_designer_script("res://scenes/ui/domelab_modal.gd", {}, true)
		MultiMonitorCatalog.VIEW_VEHICLELAB:
			_mount_designer_script("res://scenes/ui/vehiclelab_modal.gd", {}, true)
		MultiMonitorCatalog.VIEW_EARTHSHIPLAB:
			_mount_designer_script("res://scenes/ui/earthshiplab_modal.gd", {}, true)
		MultiMonitorCatalog.VIEW_FLATPACK:
			_mount_designer_script("res://scenes/ui/flatpack_designer_modal.gd", {}, true)
		MultiMonitorCatalog.VIEW_SITE_REPORT:
			_mount_site_report()
		MultiMonitorCatalog.VIEW_COMMUNITY_SCHEDULE:
			_mount_community_schedule()
		MultiMonitorCatalog.VIEW_COMPARE_VIEW:
			_mount_compare_view()
		MultiMonitorCatalog.VIEW_SOLAR_DASHBOARD:
			_mount_solar_dashboard()
		MultiMonitorCatalog.VIEW_OVERHEAD_3D:
			_mount_overhead_3d(slot_cfg)
		MultiMonitorCatalog.VIEW_WINDOW_WALL_SLOT:
			_mount_window_wall_panel(slot_cfg)
		MultiMonitorCatalog.VIEW_PROJECTION_CANVAS:
			_mount_projection_canvas()
		_:
			_mount_placeholder("Unknown view: %s" % view_id)


func _mount_system_graph(view_id: String) -> void:
	var sgv := ServiceLocator.graph() as Control
	if sgv == null:
		sgv = _main.find_child("SystemGraphView", true, false) as Control
	if sgv == null:
		_mount_placeholder("Systems Graph is not available in this scene.")
		return
	if sgv.has_method("is_undocked_window") and bool(sgv.call("is_undocked_window")) \
			and sgv.get_window() != self:
		_mount_steal_singleton_card(
			"Systems Graph is currently shown on another monitor window.",
			"Move Systems Graph Here",
			func() -> void:
				if _host != null and _host.has_method("dock_system_graph_to_main"):
					_host.call("dock_system_graph_to_main")
				_unmount_current_view()
				_mount_system_graph(view_id)
				_update_chrome_state()
		)
		return

	# Cleanly close main-window modal lock if the graph was open on Main first.
	if sgv.visible and not bool(sgv.call("is_undocked_window")):
		sgv.call("close_graph_view")

	_reparented_node = sgv
	_reparent_orig_parent = sgv.get_parent()
	_reparent_orig_idx = sgv.get_index() if _reparent_orig_parent != null else -1
	_reparent_was_visible = false
	if _reparent_orig_parent != null:
		_reparent_orig_parent.remove_child(sgv)
	_content_root.add_child(sgv)
	sgv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ServiceLocator.provide(ServiceLocator.GRAPH, sgv)
	sgv.call("open_graph_view")

	if view_id == MultiMonitorCatalog.VIEW_SYSTEM_GRAPH_SCADA:
		if sgv.has_method("set_operator_mode"):
			sgv.call("set_operator_mode", true)
	else:
		if sgv.has_method("operator_mode") and bool(sgv.call("operator_mode")):
			sgv.call("set_operator_mode", false)
		if view_id == MultiMonitorCatalog.VIEW_SYSTEM_GRAPH_SITE and sgv.has_method("set_spatial_mode"):
			sgv.call("set_spatial_mode", "site_plan")
	_view_node = sgv


func _mount_tclab(opts: Dictionary) -> void:
	var scr := load("res://scenes/ui/tclab_modal.gd") as Script
	if scr == null:
		_mount_placeholder("Could not load Tri-Clamp Process Lab.")
		return
	var open_opts := opts.duplicate(true)
	# Auto-bind to a placed Biochar Reactor prop on the map if one exists!
	if open_opts.has("auto_bind_model"):
		var needle := str(open_opts.get("auto_bind_model", "")).to_lower()
		open_opts.erase("auto_bind_model")
		var bound_id := _find_placed_tc_prop(needle)
		if not bound_id.is_empty():
			open_opts["prop_id"] = bound_id
	var ui := Control.new()
	ui.name = "MonitorTcLabModal"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(scr)
	_content_root.add_child(ui)
	ui.call("open", open_opts)
	_hook_designer_close(ui)
	_view_node = ui


func _find_placed_tc_prop(needle: String) -> String:
	if _main == null or needle.is_empty():
		return ""
	var loader := TerrainSurfaceQuery.find_terrain_loader(_main)
	if loader == null:
		return ""
	var svc: Variant = loader.get("_placed_prop_service")
	if svc == null or not svc.has_method("all_records"):
		return ""
	for r in (svc.call("all_records") as Array):
		if r is Dictionary:
			var rd := r as Dictionary
			var mid := str(rd.get("model_id", "")).to_lower()
			var nm := str((rd.get("tc_spec", {}) as Dictionary).get("name", "") if rd.get("tc_spec") is Dictionary else "").to_lower()
			if mid.contains(needle) or nm.contains(needle):
				return str(rd.get("id", ""))
	return ""


func _mount_designer_script(script_path: String, opts: Dictionary, needs_loader: bool = false) -> void:
	var scr := load(script_path) as Script
	if scr == null:
		_mount_placeholder("Could not load %s." % script_path.get_file())
		return
	var ui := Control.new()
	ui.name = "MonitorDesignerModal"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(scr)
	_content_root.add_child(ui)
	if needs_loader and ui.has_method("bind_loader"):
		ui.call("bind_loader", TerrainSurfaceQuery.find_terrain_loader(_main))
	if ui.has_method("open"):
		var mc := _method_min_args(ui, "open")
		if mc == 0:
			# Check if open accepts optional dict
			if _method_max_args(ui, "open") >= 1:
				ui.call("open", opts)
			else:
				ui.call("open")
		else:
			ui.call("open", opts)
	_hook_designer_close(ui)
	_view_node = ui


func _hook_designer_close(ui: Node) -> void:
	var shell: Variant = ui.get("_shell")
	if shell is DesignerShell:
		(shell as DesignerShell).closed.connect(_on_close_requested)


func _mount_site_report() -> void:
	var scr := load("res://scenes/ui/site_report_panel.gd") as Script
	if scr == null:
		return
	var ui := Control.new()
	ui.name = "MonitorSiteReport"
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.set_script(scr)
	_content_root.add_child(ui)
	var tl := ServiceLocator.timeline_ui()
	ui.set("_timeline", tl)
	ui.set("_main_node", _main)
	ui.call("_build_modal")
	var b := SiteReportBuilder.new()
	b.name = "SiteReportBuilder"
	ui.add_child(b)
	ui.set("_builder", b)
	b.progress.connect(Callable(ui, "_on_build_progress"))
	b.report_ready.connect(Callable(ui, "_on_report_ready"))
	ui.call("open")
	_view_node = ui


func _mount_community_schedule() -> void:
	var scr := load("res://scenes/ui/community_schedule_modal.gd") as Script
	if scr == null:
		return
	var node := Node.new()
	node.name = "MonitorCommunitySchedule"
	node.set_script(scr)
	_content_root.add_child(node)
	node.call("open", "Day")
	var frame: Variant = node.get("_frame")
	if frame is ModalFrame:
		(frame as ModalFrame).closed.connect(_on_close_requested)
	_view_node = node


func _mount_compare_view() -> void:
	var scr := load("res://scenes/ui/experiment/compare_view.gd") as Script
	if scr == null:
		return
	var node := Node.new()
	node.name = "MonitorCompareView"
	node.set_script(scr)
	_content_root.add_child(node)
	node.call("open_on", _main, PackedFloat64Array([NAN, NAN]), {})
	var frame: Variant = node.get("_frame")
	if frame is ModalFrame:
		(frame as ModalFrame).closed.connect(_on_close_requested)
	_view_node = node


func _mount_solar_dashboard() -> void:
	var ui := Control.new()
	ui.name = "MonitorSolarDashboard"
	ui.set_script(SOLAR_VIEW_SCRIPT)
	_content_root.add_child(ui)
	ui.call("setup", _main)
	_view_node = ui


func _mount_overhead_3d(slot_cfg: Dictionary) -> void:
	var cam := OVERHEAD_CAM_SCRIPT.new()
	cam.name = "MonitorOverheadCamera"
	add_child(cam)
	cam.call("setup", _main, float(slot_cfg.get("overhead_height_m", 65.0)))
	_view_node = cam


func _mount_window_wall_panel(slot_cfg: Dictionary) -> void:
	var cam := Camera3D.new()
	cam.name = "MonitorWallSlotCamera"
	var player := _main.get_node_or_null("Player")
	var src: Camera3D = player.get_node_or_null("CameraArm/Camera3D") as Camera3D if player != null else null
	if src != null:
		cam.near = src.near
		cam.far = src.far
		cam.cull_mask = src.cull_mask
		cam.attributes = src.attributes
		cam.environment = src.environment
	cam.projection = Camera3D.PROJECTION_FRUSTUM
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	add_child(cam)
	cam.current = true
	_wall_cam = cam
	_view_node = cam
	_sync_wall_slot_camera(slot_cfg)


func _sync_wall_slot_camera(slot_cfg: Dictionary) -> void:
	if _wall_cam == null or not is_instance_valid(_wall_cam) or _main == null:
		return
	var slots := WindowWallLayout.build_slots(WindowWallPrefs.snapshot())
	if slots.is_empty():
		return
	var w_idx := clampi(int(slot_cfg.get("wall_slot", 0)), 0, slots.size() - 1)
	var f := WindowWallLayout.frustum_for(slots[w_idx], _wall_cam.near)
	if f.is_empty():
		return
	var vp := WindowWallViewpoint.load_for(_main)
	var eye_pos := Vector3.ZERO
	var yaw_rad := 0.0
	if vp != null:
		eye_pos = vp.eye(WindowWallPrefs.seat_eye_height_m())
		yaw_rad = deg_to_rad(vp.yaw_deg)
	else:
		var player := _main.get_node_or_null("Player") as Node3D
		if player != null:
			eye_pos = player.global_position + Vector3(0.0, WindowWallPrefs.seat_eye_height_m(), 0.0)
			yaw_rad = player.rotation.y
	_wall_cam.set_frustum(float(f["size"]), f["offset"], _wall_cam.near, _wall_cam.far)
	_wall_cam.global_transform = Transform3D(
		Basis.from_euler(Vector3(0.0, yaw_rad, 0.0)) * (f["basis"] as Basis),
		eye_pos
	)


func _mount_projection_canvas() -> void:
	var pc := _main.find_child("ProjectionCanvas", true, false) as Control
	if pc == null:
		_mount_placeholder("Projection Canvas is not present in this map scene.")
		return
	_reparented_node = pc
	_reparent_orig_parent = pc.get_parent()
	_reparent_orig_idx = pc.get_index() if _reparent_orig_parent != null else -1
	_reparent_was_visible = pc.visible
	if _reparent_orig_parent != null:
		_reparent_orig_parent.remove_child(pc)
	_content_root.add_child(pc)
	pc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pc.visible = true
	_view_node = pc


func _mount_placeholder(msg: String) -> void:
	var box := PanelContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_BG))
	_content_root.add_child(box)
	var lbl := Label.new()
	lbl.text = msg
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	box.add_child(lbl)
	_view_node = box


func _mount_steal_singleton_card(msg: String, btn_label: String, cb: Callable) -> void:
	var box := PanelContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.add_theme_stylebox_override("panel", UITheme.panel_style(1.0, UITheme.C_BG))
	_content_root.add_child(box)
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	box.add_child(vb)
	var lbl := Label.new()
	lbl.text = msg
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vb.add_child(lbl)
	var b := Button.new()
	b.text = btn_label
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UITheme.style_primary_button(b)
	b.pressed.connect(cb)
	vb.add_child(b)
	_view_node = box


func _unmount_current_view() -> void:
	_wall_cam = null
	if _reparented_node != null and is_instance_valid(_reparented_node):
		var node := _reparented_node
		# Hide and exit operator/lens previews BEFORE removing from the tree so
		# child services (e.g. graph_soi_preview_service) still have a valid
		# SceneTree during NOTIFICATION_VISIBILITY_CHANGED teardown.
		if node.is_inside_tree():
			if node.name == "SystemGraphView":
				if node.has_method("operator_mode") and bool(node.call("operator_mode")):
					node.call("set_operator_mode", false)
				(node as CanvasItem).visible = false
			elif node is CanvasItem:
				(node as CanvasItem).visible = false
		if node.get_parent() != null:
			node.get_parent().remove_child(node)
		if _reparent_orig_parent != null and is_instance_valid(_reparent_orig_parent):
			_reparent_orig_parent.add_child(node)
			if _reparent_orig_idx >= 0 and _reparent_orig_idx < _reparent_orig_parent.get_child_count():
				_reparent_orig_parent.move_child(node, _reparent_orig_idx)
			if node is Control:
				(node as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			if node.name == "SystemGraphView":
				(node as CanvasItem).visible = false
				ServiceLocator.provide(ServiceLocator.GRAPH, node)
				var root_vp := _reparent_orig_parent.get_viewport()
				if root_vp != null:
					root_vp.disable_3d = false
			elif node is CanvasItem:
				(node as CanvasItem).visible = _reparent_was_visible
	_reparented_node = null
	_reparent_orig_parent = null
	_reparent_orig_idx = -1

	if _view_node != null and is_instance_valid(_view_node):
		# Only free views we instantiated ourselves (never a reparented singleton).
		if _view_node.get_parent() == _content_root or _view_node.get_parent() == self:
			if _view_node.has_method("close"):
				_view_node.call("close")
			_view_node.queue_free()
	_view_node = null


# ---------------------------------------------------------------------------
# Top-right floating Window Control Pill
# ---------------------------------------------------------------------------

func _build_chrome_pill(slot_cfg: Dictionary) -> void:
	_chrome_layer = CanvasLayer.new()
	_chrome_layer.name = "MonitorChromeLayer"
	_chrome_layer.layer = UITheme.LAYER_TOAST + 2
	add_child(_chrome_layer)

	var anchor := Control.new()
	anchor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chrome_layer.add_child(anchor)

	_chrome_pill = PanelContainer.new()
	_chrome_pill.name = "MonitorChromePill"
	_chrome_pill.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_chrome_pill.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_chrome_pill.offset_right = -10.0
	_chrome_pill.offset_top = 8.0
	var sb := UITheme.dock_panel_style(0.94, UITheme.C_PANEL_RAISED)
	sb.set_content_margin_all(6)
	_chrome_pill.add_theme_stylebox_override("panel", sb)
	_chrome_pill.mouse_entered.connect(func() -> void:
		_chrome_idle_t = 0.0
		_chrome_pill.modulate.a = 1.0)
	anchor.add_child(_chrome_pill)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_chrome_pill.add_child(row)

	_title_lbl = Label.new()
	_title_lbl.text = str(slot_cfg.get("label", slot_id))
	_title_lbl.add_theme_font_override("font", UITheme.font("semibold"))
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	row.add_child(_title_lbl)

	_view_opt = OptionButton.new()
	_view_opt.name = "MonitorViewPicker"
	_view_opt.fit_to_longest_item = false
	_view_opt.clip_text = true
	_view_opt.custom_minimum_size = Vector2(165, 0)
	_view_opt.tooltip_text = "Switch what view or dashboard is displayed on this monitor."
	_view_ids.clear()
	for e in MultiMonitorCatalog.entries():
		var vid := str(e["id"])
		_view_ids.append(vid)
		_view_opt.add_item(str(e["short"]))
	_view_opt.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and idx < _view_ids.size():
			switch_view(_view_ids[idx]))
	row.add_child(_view_opt)

	_dock_btn = Button.new()
	_dock_btn.name = "MonitorDockMainButton"
	_dock_btn.text = "↙ Dock"
	_dock_btn.tooltip_text = "Close this monitor window and return Systems Graph to the main screen (G)."
	UITheme.style_button(_dock_btn)
	_dock_btn.pressed.connect(func() -> void: dock_to_main_requested.emit(slot_id))
	row.add_child(_dock_btn)

	_touch_btn = Button.new()
	_touch_btn.name = "MonitorTouchButton"
	_touch_btn.text = "✋"
	_touch_btn.toggle_mode = true
	_touch_btn.button_pressed = _touch_mode
	_touch_btn.tooltip_text = "Touchscreen mode: keeps this control bar pinned and enlarges tap targets."
	UITheme.style_button(_touch_btn)
	_touch_btn.toggled.connect(func(on: bool) -> void:
		_touch_mode = on
		MultiMonitorPrefs.set_slot_value_by_id(slot_id, "touchscreen", on)
		MultiMonitorPrefs.save()
		_update_chrome_state())
	row.add_child(_touch_btn)

	_fs_btn = Button.new()
	_fs_btn.name = "MonitorFullscreenButton"
	_fs_btn.tooltip_text = "Toggle Fullscreen on the monitor this window is currently sitting on (F11 / Alt+Enter)."
	UITheme.style_primary_button(_fs_btn)
	_fs_btn.pressed.connect(toggle_monitor_fullscreen)
	row.add_child(_fs_btn)

	_close_btn = Button.new()
	_close_btn.name = "MonitorCloseButton"
	_close_btn.text = "✕"
	_close_btn.tooltip_text = "Close this monitor window."
	UITheme.style_button(_close_btn)
	_close_btn.pressed.connect(_on_close_requested)
	row.add_child(_close_btn)


func _update_chrome_state() -> void:
	if _chrome_pill == null:
		return
	var idx := _view_ids.find(active_view_id)
	if idx >= 0 and _view_opt.selected != idx:
		_view_opt.select(idx)
	_dock_btn.visible = MultiMonitorCatalog.is_system_graph_variant(active_view_id)
	_touch_btn.set_pressed_no_signal(_touch_mode)
	_fs_btn.text = "❐ Windowed" if is_monitor_fullscreen else "⛶ Fullscreen"
	var btn_h := 38.0 if _touch_mode else 28.0
	for b in [_view_opt, _dock_btn, _touch_btn, _fs_btn, _close_btn]:
		b.custom_minimum_size.y = btn_h
	if _touch_mode or not is_monitor_fullscreen:
		_chrome_pill.modulate.a = 0.96


# ---------------------------------------------------------------------------
# Frame tick, shortcuts & cleanup
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _closing:
		return
	if event is InputEventMouseMotion or event is InputEventScreenTouch or event is InputEventMouseButton:
		_chrome_idle_t = 0.0
		if _chrome_pill != null:
			_chrome_pill.modulate.a = 0.96
	if event is InputEventKey:
		var ke := event as InputEventKey
		if ke.pressed and not ke.echo:
			var is_f11 := ke.keycode == KEY_F11 or ke.physical_keycode == KEY_F11
			var is_alt_enter := ke.alt_pressed and (ke.keycode == KEY_ENTER or ke.physical_keycode == KEY_ENTER)
			if is_f11 or is_alt_enter:
				toggle_monitor_fullscreen()
				set_input_as_handled()


func _process(delta: float) -> void:
	if _closing:
		return
	# Keep Window Wall panel camera synced to live eye/viewpoint.
	if active_view_id == MultiMonitorCatalog.VIEW_WINDOW_WALL_SLOT and _wall_cam != null:
		_sync_wall_slot_camera(MultiMonitorPrefs.slot_by_id(slot_id))

	# Auto-dim chrome pill when fullscreen on non-touch monitors.
	if _chrome_pill != null and is_monitor_fullscreen and not _touch_mode:
		_chrome_idle_t += delta
		if _chrome_idle_t > CHROME_IDLE_FADE_S:
			_chrome_pill.modulate.a = lerpf(_chrome_pill.modulate.a, 0.28, clampf(delta * 3.0, 0.0, 1.0))

	# Poll windowed drag/resize so moving a window onto another monitor records it.
	if not _suppressing_geom_poll and not is_monitor_fullscreen and mode == Window.MODE_WINDOWED:
		_poll_accum += delta
		if _poll_accum >= GEOM_POLL_S:
			_poll_accum = 0.0
			if position != _last_windowed_pos or size != _last_windowed_size:
				_last_windowed_pos = position
				_last_windowed_size = size
				var screens := MultiMonitorDisplay.os_screens()
				var scr_idx := MultiMonitorDisplay.screen_containing_rect(Rect2i(position, size), screens)
				var scr_dict := MultiMonitorDisplay.screen_by_index(screens, scr_idx)
				MultiMonitorPrefs.record_placement(
					slot_id,
					scr_idx,
					MultiMonitorDisplay.fingerprint_of(scr_dict) if not scr_dict.is_empty() else "",
					position,
					size,
					false
				)
				_dirty_save_t = SAVE_DEBOUNCE_S

	if _dirty_save_t >= 0.0:
		_dirty_save_t -= delta
		if _dirty_save_t < 0.0:
			MultiMonitorPrefs.save()


func _on_close_requested() -> void:
	if _closing:
		return
	_closing = true
	closed_by_user.emit(slot_id)


func teardown_sync() -> void:
	_closing = true
	set_process(false)
	set_process_input(false)
	_unmount_current_view()


func _exit_tree() -> void:
	_unmount_current_view()


static func _copy_3d_viewport_settings(src: Viewport, scale_3d: float) -> void:
	if src == null:
		return
	# Note: invoked on `self` before add_child via instance properties in caller.
	pass


func _copy_viewport_props_from(src: Viewport, scale_3d: float) -> void:
	if src == null:
		return
	msaa_3d = src.msaa_3d
	screen_space_aa = src.screen_space_aa
	use_taa = false  # Secondary shared-World3D windows skip TAA jitter conflict
	use_debanding = src.use_debanding
	scaling_3d_mode = src.scaling_3d_mode
	scaling_3d_scale = clampf(scale_3d, 0.25, 1.0)
	positional_shadow_atlas_size = src.positional_shadow_atlas_size
	mesh_lod_threshold = src.mesh_lod_threshold
	use_occlusion_culling = src.use_occlusion_culling
	texture_mipmap_bias = src.texture_mipmap_bias


static func _method_min_args(obj: Object, method_name: String) -> int:
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method_name:
			var args: Array = m.get("args", [])
			var defs: Array = m.get("default_args", [])
			return maxi(args.size() - defs.size(), 0)
	return 0


static func _method_max_args(obj: Object, method_name: String) -> int:
	for m in obj.get_method_list():
		if str(m.get("name", "")) == method_name:
			return (m.get("args", []) as Array).size()
	return 0

class_name MultiMonitorHost
extends Node

## Orchestrates secondary monitor windows (`MonitorWindowHost`) under `Main`,
## primary game-window screen/mode application, and non-destructive `Identify
## Screens` overlays across all connected monitors.
##
## Parented under `Main` so `main.find_child("SystemGraphView", true, false)`
## (used by 45+ world scripts) continues to find `SystemGraphView` when it is
## undocked onto a Touchscreen monitor, and so scene teardown cleanly restores
## and frees every secondary window before `Main` exits.

signal windows_changed()

var _main: Node = null
var _windows: Dictionary = {}   # slot_id -> MonitorWindowHost
var _spawning := false
var _saved_root_embed := true
var _embed_overridden := false


func setup(main: Node) -> void:
	_main = main


func open_window_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for k in _windows.keys():
		var w: Variant = _windows[k]
		if is_instance_valid(w):
			out.append(str(k))
	return out


func get_slot_window(slot_id: String) -> MonitorWindowHost:
	var w: Variant = _windows.get(slot_id, null)
	return w as MonitorWindowHost if is_instance_valid(w) else null


func is_slot_open(slot_id: String) -> bool:
	return get_slot_window(slot_id) != null


func active_window_count() -> int:
	return open_window_ids().size()


## Apply the user's Primary Window Mode & Monitor choice to `tree.root`.
static func apply_main_window_prefs(tree: SceneTree) -> void:
	if tree == null or tree.root == null or DisplayServer.get_name() == "headless":
		return
	# Never fight an active automated playtest capture's forced --window-size.
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture=") or a.begins_with("--run-script=") or a.begins_with("--window-size="):
			return
	MultiMonitorPrefs.ensure_loaded()
	if not MultiMonitorPrefs.enabled():
		return
	var root := tree.root
	var screens := MultiMonitorDisplay.os_screens()
	if screens.is_empty():
		return
	var want_scr := MultiMonitorDisplay.resolve_screen(
		MultiMonitorPrefs.main_screen_fingerprint(),
		MultiMonitorPrefs.main_screen(),
		screens
	)
	if want_scr < 0:
		want_scr = MultiMonitorDisplay.primary_screen_index(screens)
	var scr_dict := MultiMonitorDisplay.screen_by_index(screens, want_scr)
	if scr_dict.is_empty():
		return

	var m_mode := MultiMonitorPrefs.main_window_mode()
	match m_mode:
		MultiMonitorPrefs.MAIN_MODE_FULLSCREEN:
			root.borderless = false
			root.current_screen = want_scr
			root.mode = Window.MODE_FULLSCREEN
		MultiMonitorPrefs.MAIN_MODE_BORDERLESS:
			if root.mode != Window.MODE_WINDOWED:
				root.mode = Window.MODE_WINDOWED
			var safe := MultiMonitorDisplay.dwm_safe_fullscreen_rect(scr_dict, true)
			root.borderless = true
			root.position = safe.position
			root.size = safe.size
		MultiMonitorPrefs.MAIN_MODE_WINDOWED:
			if root.mode != Window.MODE_WINDOWED:
				root.mode = Window.MODE_WINDOWED
			root.borderless = false
			var wrect := MultiMonitorDisplay.default_windowed_rect(scr_dict, bool(scr_dict.get("is_portrait", false)), 0)
			root.size = wrect.size
			root.position = wrect.position


## Launch all enabled secondary monitor slots (one window per frame to avoid
## multi-viewport GPU TDR spikes).
func open_all_enabled() -> void:
	if _spawning or _main == null or DisplayServer.get_name() == "headless":
		return
	MultiMonitorPrefs.ensure_loaded()
	if not MultiMonitorPrefs.enabled():
		return
	_spawning = true
	var all_slots := MultiMonitorPrefs.slots()
	var cascade := 0
	for sc in all_slots:
		if not is_inside_tree():
			_spawning = false
			return
		if not bool(sc.get("enabled", true)):
			continue
		var sid := str(sc.get("id", ""))
		if is_slot_open(sid):
			get_slot_window(sid).refresh_from_prefs()
			cascade += 1
			continue
		await get_tree().process_frame
		if not is_inside_tree():
			_spawning = false
			return
		_spawn_slot_now(sc, cascade)
		cascade += 1
	_spawning = false
	windows_changed.emit()


## Open (or focus if already open) one specific monitor slot immediately.
func open_slot(slot_id: String) -> MonitorWindowHost:
	if _main == null or DisplayServer.get_name() == "headless":
		return null
	var existing := get_slot_window(slot_id)
	if existing != null:
		existing.refresh_from_prefs()
		existing.grab_focus()
		return existing
	var idx := MultiMonitorPrefs.find_slot_index(slot_id)
	if idx < 0:
		return null
	var sc := MultiMonitorPrefs.slot(idx)
	var win := _spawn_slot_now(sc, idx)
	windows_changed.emit()
	return win


func _spawn_slot_now(slot_cfg: Dictionary, cascade_idx: int) -> MonitorWindowHost:
	if not _ensure_root_native_subwindows():
		if _main != null and _main.has_method("show_toast"):
			_main.call("show_toast",
				"Close open popup menus first so native monitor windows can open.",
				ToastUI.Level.WARN, 4.0)
		return null
	var w := MonitorWindowHost.new()
	var plan := w.configure_before_tree(_main, self, slot_cfg, cascade_idx)
	if MultiMonitorCatalog.shares_world_3d(w.active_view_id) and get_tree() != null:
		w._copy_viewport_props_from(get_tree().root, float(slot_cfg.get("render_scale_3d", 1.0)))
	add_child(w)
	w.finish_open_after_tree(slot_cfg, plan)
	w.closed_by_user.connect(_on_window_closed_by_user)
	w.dock_to_main_requested.connect(_on_dock_to_main_requested)
	w.state_changed.connect(func(_id: String) -> void: windows_changed.emit())
	_windows[w.slot_id] = w
	return w


func close_slot(slot_id: String) -> void:
	var w := get_slot_window(slot_id)
	_windows.erase(slot_id)
	if w != null:
		w.teardown_sync()
		w.hide()
		if w.get_parent() != null:
			w.get_parent().remove_child(w)
		w.free()
	_maybe_restore_root_embed()
	windows_changed.emit()


func close_all() -> void:
	var ids := open_window_ids()
	for sid in ids:
		var w := get_slot_window(sid)
		if w != null:
			w.teardown_sync()
			w.hide()
			if w.get_parent() != null:
				w.get_parent().remove_child(w)
			w.free()
	_windows.clear()
	_maybe_restore_root_embed()
	windows_changed.emit()


func gather_all_to_windowed() -> void:
	MultiMonitorPrefs.clear_all_fullscreen()
	MultiMonitorPrefs.save()
	var cascade := 0
	for sid in open_window_ids():
		var w := get_slot_window(sid)
		if w != null:
			w.gather_to_primary_windowed(cascade)
			cascade += 1
	windows_changed.emit()


func dock_system_graph_to_main() -> void:
	for sid in open_window_ids():
		var w := get_slot_window(sid)
		if w != null and MultiMonitorCatalog.is_system_graph_variant(w.active_view_id):
			close_slot(sid)
			return


func _on_window_closed_by_user(slot_id: String) -> void:
	close_slot.call_deferred(slot_id)


func _on_dock_to_main_requested(slot_id: String) -> void:
	close_slot.call_deferred(slot_id)
	var reopen := func() -> void:
		var sgv := ServiceLocator.graph()
		if sgv != null and sgv.has_method("open_graph_view"):
			sgv.call("open_graph_view")
		if get_tree() != null and get_tree().root != null:
			get_tree().root.grab_focus()
	reopen.call_deferred()


func _ensure_root_native_subwindows() -> bool:
	var tree := get_tree()
	if tree == null or tree.root == null:
		return false
	var root := tree.root
	if not root.gui_embed_subwindows:
		return true
	_saved_root_embed = root.gui_embed_subwindows
	for child_w in root.find_children("*", "Window", true, false):
		if child_w is Window and child_w != root and (child_w as Window).visible and not _windows.values().has(child_w):
			(child_w as Window).hide()
	root.gui_embed_subwindows = false
	if not root.gui_embed_subwindows:
		_embed_overridden = true
		return true
	return false


func _maybe_restore_root_embed() -> void:
	if not _embed_overridden or not open_window_ids().is_empty():
		return
	var tree := get_tree()
	if tree != null and tree.root != null:
		# Hide any lingering native popup menus on root before flipping back.
		for child_w in tree.root.find_children("*", "Window", true, false):
			if child_w is Window and child_w != tree.root and (child_w as Window).visible:
				(child_w as Window).hide()
		tree.root.gui_embed_subwindows = _saved_root_embed
	_embed_overridden = false


func _exit_tree() -> void:
	close_all()


## Flash big OS screen numbers + resolution + orientation on every connected
## monitor without closing Settings (`TimelineSettingsPanel` is a Control, not
## an embedded Window).
static func identify_screens(tree: SceneTree, seconds: float = 3.0) -> void:
	if tree == null or tree.root == null or DisplayServer.get_name() == "headless":
		return
	var root := tree.root
	var had_embed := root.gui_embed_subwindows
	if had_embed:
		for cw in root.find_children("*", "Window", true, false):
			if cw is Window and cw != root and (cw as Window).visible:
				(cw as Window).hide()
		root.gui_embed_subwindows = false
		if root.gui_embed_subwindows:
			return
	var screens := MultiMonitorDisplay.os_screens()
	var badges: Array[Window] = []
	for sc in screens:
		await tree.process_frame
		var idx := int(sc["index"])
		var w := Window.new()
		w.title = "Screen %d" % (idx + 1)
		w.borderless = true
		w.always_on_top = true
		w.unresizable = true
		w.own_world_3d = true
		w.disable_3d = true
		w.gui_embed_subwindows = true
		var bsz := Vector2i(520, 260)
		w.size = bsz
		w.position = Vector2i(int(sc["x"]), int(sc["y"])) + (Vector2i(int(sc["w"]), int(sc["h"])) - bsz) / 2
		UITheme.install_window(w)
		var p := PanelContainer.new()
		p.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		p.add_theme_stylebox_override("panel", UITheme.modal_panel_style(0.98))
		w.add_child(p)
		var vb := VBoxContainer.new()
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_theme_constant_override("separation", 6)
		p.add_child(vb)
		var big := Label.new()
		big.text = "Screen %d" % (idx + 1)
		big.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		big.add_theme_font_override("font", UITheme.font("semibold"))
		big.add_theme_font_size_override("font_size", 56)
		big.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		vb.add_child(big)
		var sub := Label.new()
		var orient := "Portrait" if bool(sc["is_portrait"]) else "Landscape"
		var prim_tag := "  ·  OS Primary" if bool(sc["is_primary"]) else ""
		sub.text = "%d × %d  (%s)%s" % [int(sc["w"]), int(sc["h"]), orient, prim_tag]
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sub.add_theme_font_size_override("font_size", UITheme.FONT_LG)
		sub.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		vb.add_child(sub)
		root.add_child(w)
		badges.append(w)
	await tree.create_timer(maxf(seconds, 0.5)).timeout
	for bw in badges:
		if is_instance_valid(bw):
			bw.hide()
			if bw.get_parent() != null:
				bw.get_parent().remove_child(bw)
			bw.free()
	# Restore root embed ONLY if no secondary MultiMonitor / WindowWall windows remain.
	var has_other_wins := false
	for cw in root.find_children("*", "Window", true, false):
		if cw is Window and cw != root and (cw as Window).visible:
			has_other_wins = true
			break
	if had_embed and not has_other_wins:
		root.gui_embed_subwindows = true

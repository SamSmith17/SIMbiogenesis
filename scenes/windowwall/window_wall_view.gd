class_name WindowWallView
extends Node3D

## The Window Wall: render the world across a row of physical monitors so they
## read as WINDOWS out of the bus. One eye, one orientation, one off-axis
## frustum per monitor; the existing game window becomes one of the monitors and
## a native `Window` is opened for each of the others, all sharing Main's World3D.
##
## ## Three rules this file exists to hold
##
## 1. **One eye.** Every camera sits at the SAME point with the SAME basis; only
##    the frustum differs (WindowWallLayout). That is what keeps a straight line
##    straight across a bezel. Never give a slot its own yaw "to look better".
## 2. **Leave the world exactly as found.** The root window's mode/screen, the
##    embed flag, the clock (claim + date), every CanvasLayer's visibility, the
##    player's process mode and the live camera are snapshotted at open and put
##    back at close — never blanket-set, since several layers are hidden by
##    design. Every exit path is `close()`: Esc, F11, any window's close
##    button, a scene change, and the harness.
## 3. **The extra windows carry no UI.** They are cameras with a keyboard relay
##    and nothing else; the only chrome is the fading hint on the main window.
##
## Native windows need `root.gui_embed_subwindows = false`, which Godot refuses
## while an embedded child window is visible (measured in the Phase 0 spike),
## so any open dialog is hidden first and a refusal aborts the open loudly.
## Windows are spawned ONE PER FRAME — the AMD-TDR discipline from
## graph_soi_preview_service.gd for shared-world viewports.

const CLAIM := "window_wall"
const HINT_SCRIPT := preload("res://scenes/windowwall/window_wall_hint.gd")
const RELAY_SCRIPT := preload("res://scenes/windowwall/window_wall_input_relay.gd")
## 1 sim-hour per real hour; mirrors TimeDirector.REALTIME_SCALE_REF (an
## autoload constant, kept local so this file never needs the autoload at
## parse time).
const REALTIME_SCALE := 1.0 / 3600.0
## Re-sync the sim clock to the wall clock this often in "live" mode (same
## cadence as SimSettingsController.LIVE_SYNC_INTERVAL).
const LIVE_SYNC_S := 10.0
const YAW_KEY_RATE := deg_to_rad(15.0)
const YAW_DRAG_RATE := 0.003
const HINT_TEXT := "Window view — Esc exit · U toggle UI · Ctrl+S save viewpoint · R reset · I identify screens · WASD/QE nudge, ←→ turn"

signal closed()

var _main: Node = null
var _active := false
var _opening := false
## Set the instant a close is REQUESTED, cleared when the teardown runs. The
## teardown itself is deferred (see request_close), so this is what stops the
## view consuming input and re-entering during that one-frame gap.
var _closing := false
var _slots: Array[Dictionary] = []
var _screens := PackedInt32Array()
var _cams: Array = []          # slot -> Camera3D
var _windows: Dictionary = {}  # slot -> Window
var _eye := Vector3.ZERO
var _yaw := 0.0
var _viewpoint: WindowWallViewpoint = null
var _viewpoint_path := ""
var _restore: Dictionary = {}
var _ui_snapshot: Dictionary = {}  # CanvasLayer -> bool
var _ui_hidden := false
var _hint: CanvasLayer = null
var _identify_layers: Array = []
var _clock_claimed := false
var _live_synced := false
var _date_snapshot: Dictionary = {}
var _live_accum := 0.0
var _drag_yaw := false
var _aspect_warned := false


func _ready() -> void:
	set_process(false)
	set_process_input(false)


func is_open() -> bool:
	return _active


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func open(main: Node) -> void:
	if _active or _opening:
		return
	if DisplayServer.get_name() == "headless":
		return
	_main = main
	if not WindowWallPrefs.enabled():
		_toast("Window wall is off — enable it in Settings → Window Wall", ToastUI.Level.WARN)
		return
	_opening = true

	# 1. The eye: the saved per-site viewpoint, else where the player stands.
	_viewpoint_path = WindowWallViewpoint.path_for(main)
	_viewpoint = WindowWallViewpoint.load_from(_viewpoint_path)
	var fresh := _viewpoint == null
	if fresh:
		_viewpoint = _viewpoint_from_player()
	_eye = _viewpoint.eye(WindowWallPrefs.seat_eye_height_m())
	_yaw = deg_to_rad(_viewpoint.yaw_deg)

	# 2. Layout + screens.
	_slots = WindowWallLayout.build_slots(WindowWallPrefs.snapshot())
	_screens = WindowWallLayout.assign_screens(_slots, os_screens())
	var main_slot := clampi(WindowWallPrefs.main_slot(), 0, _slots.size() - 1)

	# 3. Snapshot everything we are about to change.
	var root := get_tree().root
	_restore = {
		"mode": root.mode,
		"screen": root.current_screen,
		"size": root.size,
		"position": root.position,
		"embed": root.gui_embed_subwindows,
		"scale_3d": root.scaling_3d_scale,
		"player_mode": Node.PROCESS_MODE_INHERIT,
	}
	var player := main.get_node_or_null("Player")
	if player != null:
		_restore["player_mode"] = player.process_mode

	# 4. Take the modal (frees the mouse, blocks every global hotkey) and park
	# the body.
	CursorController.request_modal(CLAIM, Callable(self, "request_close"))
	if player != null:
		player.process_mode = Node.PROCESS_MODE_DISABLED
	_active = true
	visible = true

	# 5. The main window's camera goes through the claim stack so restore is by
	# construction. No shadow/cull keys: this is eye-level, first-person tuning.
	_cams.resize(_slots.size())
	var main_cam := _make_camera(main_slot)
	add_child(main_cam)
	_cams[main_slot] = main_cam
	if main.has_method("push_camera_claim"):
		main.call("push_camera_claim", CLAIM, {
			"camera_id": main_cam.get_instance_id(),
			"hide_player_mesh": true,
		})

	# 6. Move the game window onto its monitor.
	var scale := WindowWallPrefs.render_scale()
	root.current_screen = _screens[main_slot]
	root.mode = Window.MODE_FULLSCREEN
	root.scaling_3d_scale = scale

	# 7. Native windows for the other slots — needs the embed flag off.
	if _slots.size() > 1:
		if not _set_embed(false):
			_toast("Close the open dialog and try again — a visible embedded window blocks native windows", ToastUI.Level.ERROR)
			_opening = false
			close()
			return
		for slot in _slots.size():
			if slot == main_slot:
				continue
			await get_tree().process_frame
			if not _active:
				return  # closed mid-open
			await _spawn_window(slot)
			if not _active:
				return
		_log_window_state()

	# 8. Clock, UI, hint.
	_apply_clock_mode()
	if WindowWallPrefs.hide_ui():
		_apply_hide_ui(true)
	_hint = HINT_SCRIPT.new()
	_hint.name = "WindowWallHint"
	add_child(_hint)
	_hint.call("flash", HINT_TEXT if not fresh else "No window viewpoint saved for this map — Ctrl+S saves the current one. " + HINT_TEXT, 10.0)
	set_process(true)
	set_process_input(true)
	_opening = false


## Ask the view to close, and do the teardown ONE IDLE FRAME LATER.
##
## This is the entry point for every close that can be reached from inside an
## input callback — Esc, F11, a window's close button, the modal stack pop.
## The teardown FREES the extra windows, and an extra window's own relay node
## is what delivers Esc, so freeing synchronously destroys the caller and its
## viewport mid-stack ("Cannot call method 'get_viewport' on a previously freed
## instance"). Input stops being consumed immediately, so the deferred frame is
## invisible. `close()` itself stays synchronous for `_exit_tree` and the
## harness, both of which call it from outside any input dispatch.
func request_close() -> void:
	if not _active or _closing:
		return
	_closing = true
	set_process_input(false)
	close.call_deferred()


## Synchronous and idempotent — safe on every exit path, including a second
## call from the modal pop after our own Esc handler already ran.
func close() -> void:
	if not _active:
		return
	_active = false
	_opening = false
	_closing = false
	set_process(false)
	set_process_input(false)
	_drag_yaw = false
	_live_accum = 0.0
	_end_identify()
	if _hint != null and is_instance_valid(_hint):
		_hint.call("hide_now")
	# Windows first (free(), not queue_free(): the embed flag cannot be flipped
	# back while a child window is still displayed).
	for slot in _windows.keys():
		var w: Window = _windows[slot]
		if is_instance_valid(w):
			w.hide()
			if w.get_parent() != null:
				w.get_parent().remove_child(w)
			w.free()
	_windows.clear()
	var tree := get_tree()
	var root: Window = tree.root if tree != null else null
	if root != null and not _restore.is_empty():
		root.gui_embed_subwindows = bool(_restore.get("embed", true))
		root.current_screen = int(_restore.get("screen", root.current_screen))
		root.mode = int(_restore.get("mode", root.mode)) as Window.Mode
		if root.mode == Window.MODE_WINDOWED:
			root.size = _restore.get("size", root.size)
			root.position = _restore.get("position", root.position)
		root.scaling_3d_scale = float(_restore.get("scale_3d", root.scaling_3d_scale))
	var main_alive := _main != null and is_instance_valid(_main) and _main.is_inside_tree()
	if main_alive and _main.has_method("pop_camera_claim"):
		_main.call("pop_camera_claim", CLAIM)
	# The extra windows took their cameras with them; only the main slot's is
	# ours to free. Validity FIRST — `is` on a freed instance is a runtime error
	# that would abort the rest of this restore.
	for cam in _cams:
		if is_instance_valid(cam) and cam is Camera3D:
			(cam as Camera3D).queue_free()
	_cams.clear()
	if main_alive:
		_restore_clock()
		_apply_hide_ui(false)
		var player := _main.get_node_or_null("Player")
		if player != null:
			player.process_mode = int(_restore.get("player_mode", Node.PROCESS_MODE_INHERIT)) as Node.ProcessMode
	_ui_snapshot.clear()
	_restore.clear()
	CursorController.release_modal(CLAIM)
	visible = false
	closed.emit()


func _exit_tree() -> void:
	# A scene change frees Main with us under it; the ROOT window and the
	# embed flag outlive Main and must still be put back.
	close()


# ---------------------------------------------------------------------------
# Cameras and windows
# ---------------------------------------------------------------------------

func _make_camera(slot: int) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "WallCamera%d" % slot
	var src := _player_camera()
	if src != null:
		cam.near = src.near
		cam.far = src.far
		cam.cull_mask = src.cull_mask
		cam.attributes = src.attributes
		cam.environment = src.environment
	cam.projection = Camera3D.PROJECTION_FRUSTUM
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	_apply_frustum(cam, slot)
	return cam


func _apply_frustum(cam: Camera3D, slot: int) -> void:
	if slot < 0 or slot >= _slots.size():
		return
	var f := WindowWallLayout.frustum_for(_slots[slot], cam.near)
	if f.is_empty():
		return
	cam.set_frustum(float(f["size"]), f["offset"], cam.near, cam.far)
	cam.global_transform = Transform3D(Basis.from_euler(Vector3(0.0, _yaw, 0.0)) * (f["basis"] as Basis), _eye)
	if not _aspect_warned:
		var vp: Viewport = cam.get_viewport()
		if vp != null:
			var sz := vp.get_visible_rect().size
			if sz.y > 0.0 and WindowWallLayout.aspect_mismatch(f, sz.x / sz.y) > 0.01:
				_aspect_warned = true
				push_warning("WindowWall: slot %d panel aspect %.3f vs viewport %.3f — image is stretched; set width/height or portrait" % [slot, float(f["aspect_phys"]), sz.x / sz.y])


## Re-seat every camera on the current eye/yaw (after a nudge).
func _apply_eye() -> void:
	for slot in _cams.size():
		var cam: Camera3D = _cams[slot] if _cams[slot] is Camera3D else null
		if cam != null and is_instance_valid(cam):
			_apply_frustum(cam, slot)


## Open one extra monitor's window.
##
## ⚠ Ordering is measured, not stylistic. `current_screen`/`position`/`size`
## are set BEFORE `add_child` and `mode` in the SAME frame as it: applying
## MODE_FULLSCREEN a frame later is silently ignored (measured — `mode` reads
## back 0 and the window sits two pixels short of the screen), and writing
## `size` to an already-fullscreen window drops it back to windowed the same
## way. The camera is re-asserted a frame afterwards, once the window has
## actually landed on its screen.
func _spawn_window(slot: int) -> Window:
	var screen := _screens[slot]
	var rect_pos := DisplayServer.screen_get_position(screen)
	var rect_size := DisplayServer.screen_get_size(screen)
	# "borderless" keeps the window windowed at exactly the screen rect. It
	# looks the same and is the escape hatch for a display that will not
	# PRESENT a second fullscreen window (it renders, but shows flat grey) —
	# typically a monitor driven by a different graphics adapter than the main
	# game window's.
	var want_fullscreen := WindowWallPrefs.extra_window_mode() == WindowWallPrefs.WIN_FULLSCREEN
	var w := Window.new()
	w.name = "WallWindow%d" % slot
	w.title = "SIMbiogenesis — window %d" % (slot + 1)
	w.own_world_3d = false
	w.world_3d = get_viewport().world_3d
	w.borderless = true
	w.unresizable = true
	w.transparent_bg = false
	w.wrap_controls = false
	w.current_screen = screen
	w.position = rect_pos
	w.size = rect_size
	_copy_viewport_settings(get_tree().root, w)
	add_child(w)
	if want_fullscreen:
		w.mode = Window.MODE_FULLSCREEN
	else:
		w.always_on_top = true
	var cam := _make_camera(slot)
	w.add_child(cam)
	cam.current = true
	_cams[slot] = cam
	var relay: Node = RELAY_SCRIPT.new()
	relay.name = "InputRelay"
	relay.set("view", self)
	relay.set("slot", slot)
	w.add_child(relay)
	w.close_requested.connect(request_close)
	_windows[slot] = w

	await get_tree().process_frame
	if not _active or not is_instance_valid(w):
		return w
	# A window we deliberately left WINDOWED gets its rect re-asserted once it
	# has landed; a fullscreen one is never written to again.
	if not want_fullscreen and w.mode != Window.MODE_FULLSCREEN:
		w.position = rect_pos
		w.size = rect_size
	if is_instance_valid(cam):
		cam.current = true
		_apply_frustum(cam, slot)
	return w


## One line per slot: the state a grey window cannot be told from a working one
## by looking at it. Printed on every open, and read back by --capture=windowwall.
func _log_window_state() -> void:
	var root := get_tree().root
	var world := root.find_world_3d()
	for slot in _slots.size():
		var cam: Camera3D = _cams[slot] if slot < _cams.size() and _cams[slot] is Camera3D else null
		var w: Window = _windows.get(slot)
		if w == null:
			print("WindowWall: slot %d = MAIN window  screen %d  size %s  mode %d  camera %s" % [
				slot, root.current_screen, str(root.size), root.mode,
				"OK" if (cam != null and root.get_camera_3d() == cam) else "MISSING"])
			continue
		if not is_instance_valid(w) or not w.is_inside_tree():
			print("WindowWall: slot %d = window MISSING" % slot)
			continue
		var got_screen := DisplayServer.window_get_current_screen(w.get_window_id())
		print("WindowWall: slot %d = '%s'  screen %d (wanted %d)  size %s (screen %s)  mode %d  camera %s  world %s  eye %s" % [
			slot, w.name, got_screen, _screens[slot], str(w.size),
			str(DisplayServer.screen_get_size(got_screen)), w.mode,
			"OK" if (cam != null and w.get_camera_3d() == cam) else "MISSING",
			"shared" if w.find_world_3d() == world else "SEPARATE",
			str(cam.global_position) if cam != null else "n/a"])


func _copy_viewport_settings(src: Viewport, w: Window) -> void:
	var msaa := int(WindowWallPrefs.get_value("msaa"))
	w.msaa_3d = src.msaa_3d if msaa < 0 else (msaa as Viewport.MSAA)
	w.screen_space_aa = src.screen_space_aa
	w.use_taa = src.use_taa
	w.use_debanding = src.use_debanding
	w.scaling_3d_mode = src.scaling_3d_mode
	w.scaling_3d_scale = WindowWallPrefs.render_scale()
	w.positional_shadow_atlas_size = src.positional_shadow_atlas_size
	w.mesh_lod_threshold = src.mesh_lod_threshold
	w.use_occlusion_culling = src.use_occlusion_culling
	w.texture_mipmap_bias = src.texture_mipmap_bias


## Flip the root's embed flag. Godot refuses while an embedded child window is
## visible, so hide those first; returns whether the flag actually took.
func _set_embed(embed: bool) -> bool:
	var root := get_tree().root
	if root.gui_embed_subwindows == embed:
		return true
	if not embed:
		for w in root.find_children("*", "Window", true, false):
			if w is Window and (w as Window).visible and w != root and not _windows.values().has(w):
				(w as Window).hide()
	root.gui_embed_subwindows = embed
	return root.gui_embed_subwindows == embed


static func os_screens() -> Array:
	var out: Array = []
	for k in DisplayServer.get_screen_count():
		var p := DisplayServer.screen_get_position(k)
		var s := DisplayServer.screen_get_size(k)
		out.append({"index": k, "x": p.x, "y": p.y, "w": s.x, "h": s.y})
	return out


func _player_camera() -> Camera3D:
	if _main == null:
		return null
	var player := _main.get_node_or_null("Player")
	if player == null:
		return null
	var cam: Variant = player.get("camera")
	if cam is Camera3D:
		return cam
	return player.get_node_or_null("CameraArm/Camera3D") as Camera3D


func _viewpoint_from_player() -> WindowWallViewpoint:
	var vp := WindowWallViewpoint.new()
	var player := _main.get_node_or_null("Player") as Node3D if _main != null else null
	if player != null:
		vp.pos = player.global_position
		vp.yaw_deg = rad_to_deg(player.rotation.y)
	return vp


# ---------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------

## "live" and "one_x" CLAIM the scale (ClockClaims composes with every other
## owner and restores the base by construction); "live" additionally syncs the
## date to the wall clock and re-syncs every LIVE_SYNC_S. Deliberately NOT
## SimSettingsController.set_live_mode: that persists a user preference, and
## its disable path hard-writes time_scale = 1.0 (3600×).
func _apply_clock_mode() -> void:
	var mode := WindowWallPrefs.clock_mode()
	if mode == WindowWallPrefs.CLOCK_LEAVE or _main == null:
		return
	if not _main.has_method("push_clock_claim"):
		return
	_clock_claimed = bool(_main.call("push_clock_claim", CLAIM, {"time_scale": REALTIME_SCALE}))
	if not _clock_claimed:
		var owner := ""
		var clock: Variant = _main.get("clock")
		if clock != null and clock.has_method("clock_owner"):
			owner = str(clock.call("clock_owner"))
		_toast("Clock is owned by %s — window view left it alone" % (owner if not owner.is_empty() else "another mode"), ToastUI.Level.WARN)
		return
	if mode == WindowWallPrefs.CLOCK_LIVE:
		if not bool(SimSettingsController.get("live_mode_enabled")):
			_date_snapshot = {
				"year": _main.get("year"), "month": _main.get("month"),
				"day": _main.get("day"), "day_time": _main.get("day_time"),
			}
		SimSettingsController.sync_to_system_time()
		_live_synced = true


func _restore_clock() -> void:
	if _clock_claimed and _main.has_method("pop_clock_claim"):
		_main.call("pop_clock_claim", CLAIM)
	_clock_claimed = false
	if _live_synced and not _date_snapshot.is_empty():
		_main.set("year", _date_snapshot["year"])
		_main.set("month", _date_snapshot["month"])
		_main.set("day", _date_snapshot["day"])
		_main.set("day_time", _date_snapshot["day_time"])
	_live_synced = false
	_date_snapshot = {}


func _tick_live_sync(delta: float) -> void:
	if not _live_synced or _main == null:
		return
	_live_accum += delta
	if _live_accum < LIVE_SYNC_S:
		return
	_live_accum = 0.0
	# A foreign claim on top of ours (video export, a bake) changes the
	# effective scale; stop nudging the date under it.
	if float(_main.get("time_scale")) <= REALTIME_SCALE * 1.1:
		SimSettingsController.sync_to_system_time()


# ---------------------------------------------------------------------------
# UI hide / hint / identify
# ---------------------------------------------------------------------------

## Hide every CanvasLayer child of Main, remembering each one's flag so the
## restore is exact (several layers are hidden by design and must stay so).
func _apply_hide_ui(on: bool) -> void:
	if _main == null or not is_instance_valid(_main):
		return
	if on:
		if _ui_snapshot.is_empty():
			for child in _main.get_children():
				if child is CanvasLayer:
					_ui_snapshot[child] = (child as CanvasLayer).visible
		for layer in _ui_snapshot.keys():
			if is_instance_valid(layer):
				(layer as CanvasLayer).visible = false
		_ui_hidden = true
	else:
		for layer in _ui_snapshot.keys():
			if is_instance_valid(layer):
				(layer as CanvasLayer).visible = bool(_ui_snapshot[layer])
		_ui_hidden = false


func toggle_ui() -> void:
	if not _active:
		return
	_apply_hide_ui(not _ui_hidden)
	if _hint != null:
		_hint.call("flash", "UI %s" % ("hidden" if _ui_hidden else "shown"), 1.5)


func ui_hidden() -> bool:
	return _ui_hidden


## Big slot numbers on every window for `seconds`.
func identify(seconds: float = 3.0) -> void:
	if not _active:
		return
	_end_identify()
	for slot in _slots.size():
		var host: Node = _windows.get(slot, self)
		var layer := _make_identify_layer("%d" % (slot + 1), "Slot %d  →  screen %d" % [slot + 1, _screens[slot]])
		host.add_child(layer)
		_identify_layers.append(layer)
	get_tree().create_timer(maxf(seconds, 0.2)).timeout.connect(_end_identify)


func _end_identify() -> void:
	for l in _identify_layers:
		if is_instance_valid(l):
			(l as Node).queue_free()
	_identify_layers.clear()


static func _make_identify_layer(big: String, small: String) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = UITheme.LAYER_TOAST + 1
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(box)
	var l1 := Label.new()
	l1.text = big
	l1.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l1.add_theme_font_size_override("font_size", 240)
	l1.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	box.add_child(l1)
	var l2 := Label.new()
	l2.text = small
	l2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l2.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	l2.add_theme_color_override("font_color", UITheme.C_TEXT)
	box.add_child(l2)
	return layer


## For the settings tab while the mode is CLOSED: one small always-on-top
## native window per OS screen naming the screen and the slot it will take.
## Same embed dance as open(); restored after the timer.
static func identify_screens(tree: SceneTree, seconds: float = 3.0) -> void:
	if tree == null or DisplayServer.get_name() == "headless":
		return
	var root := tree.root
	var embed_before := root.gui_embed_subwindows
	for w in root.find_children("*", "Window", true, false):
		if w is Window and (w as Window).visible and w != root:
			(w as Window).hide()
	root.gui_embed_subwindows = false
	if root.gui_embed_subwindows:
		push_warning("WindowWall: cannot identify screens while an embedded dialog is open")
		return
	var slots := WindowWallLayout.build_slots(WindowWallPrefs.snapshot())
	var assigned := WindowWallLayout.assign_screens(slots, os_screens())
	var wins: Array[Window] = []
	for k in DisplayServer.get_screen_count():
		await tree.process_frame
		var w := Window.new()
		w.title = "Screen %d" % k
		w.borderless = true
		w.always_on_top = true
		w.unresizable = true
		w.transparent_bg = false
		w.own_world_3d = true
		w.size = Vector2i(560, 300)
		w.current_screen = k
		w.position = DisplayServer.screen_get_position(k) + (DisplayServer.screen_get_size(k) - w.size) / 2
		var slot_txt := "unassigned"
		for i in assigned.size():
			if assigned[i] == k:
				slot_txt = "slot %d" % (i + 1)
				break
		var bg := ColorRect.new()
		bg.color = UITheme.C_BG
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		w.add_child(bg)
		w.add_child(_make_identify_layer("%d" % k, "Screen %d  →  %s" % [k, slot_txt]))
		root.add_child(w)
		wins.append(w)
	await tree.create_timer(maxf(seconds, 0.5)).timeout
	for w in wins:
		if is_instance_valid(w):
			w.hide()
			root.remove_child(w)
			w.free()
	root.gui_embed_subwindows = embed_before


# ---------------------------------------------------------------------------
# Viewpoint
# ---------------------------------------------------------------------------

func save_viewpoint(path_override: String = "") -> bool:
	if _viewpoint == null:
		return false
	_viewpoint.pos = _eye - Vector3(0.0, WindowWallPrefs.seat_eye_height_m(), 0.0)
	_viewpoint.yaw_deg = rad_to_deg(_yaw)
	_viewpoint.saved_at = Time.get_datetime_string_from_system()
	var ok := _viewpoint.save_to(path_override if not path_override.is_empty() else _viewpoint_path)
	if _hint != null:
		_hint.call("flash", "Viewpoint saved" if ok else "Could not save viewpoint", 2.0)
	return ok


func reset_viewpoint() -> void:
	var saved := WindowWallViewpoint.load_from(_viewpoint_path)
	if saved == null:
		saved = _viewpoint
	if saved == null:
		return
	_eye = saved.eye(WindowWallPrefs.seat_eye_height_m())
	_yaw = deg_to_rad(saved.yaw_deg)
	_apply_eye()


## Move the eye by `delta` (world metres, already in the yaw frame if the
## caller wants that) and turn by `yaw_delta` radians.
func nudge(delta: Vector3, yaw_delta: float = 0.0) -> void:
	_eye += delta
	_yaw += yaw_delta
	_apply_eye()


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _active:
		return
	_tick_live_sync(delta)
	# Nudge keys are POLLED so they work from whichever window has focus.
	if _keyboard_captured_by_ui():
		return
	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_physical_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_physical_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D):
		move.x += 1.0
	if Input.is_physical_key_pressed(KEY_E):
		move.y += 1.0
	if Input.is_physical_key_pressed(KEY_Q):
		move.y -= 1.0
	var turn := 0.0
	if Input.is_physical_key_pressed(KEY_LEFT):
		turn += 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT):
		turn -= 1.0
	if move == Vector3.ZERO and turn == 0.0:
		return
	var speed := WindowWallPrefs.nudge_speed_mps() * (4.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)
	var world := Basis.from_euler(Vector3(0.0, _yaw, 0.0)) * Vector3(move.x, 0.0, move.z)
	world.y = move.y
	nudge(world * speed * delta, turn * YAW_KEY_RATE * delta)


## Main-window input. `_input` (not `_unhandled_input`) so a hidden panel's
## own `_unhandled_input` can never wake it on F1/G while we are up.
func _input(event: InputEvent) -> void:
	if not _active:
		return
	if handle_window_event(event, WindowWallPrefs.main_slot()):
		get_viewport().set_input_as_handled()


## Shared by the main window and every relay. Returns true when consumed.
func handle_window_event(event: InputEvent, _slot: int) -> bool:
	if not _active or _closing:
		return false
	if event is InputEventKey:
		var k := event as InputEventKey
		if not k.pressed or k.echo:
			return true
		if _keyboard_captured_by_ui():
			return false
		if k.keycode == KEY_ESCAPE or k.physical_keycode == KEY_ESCAPE \
				or (InputMap.has_action("toggle_window_wall") and k.is_action_pressed("toggle_window_wall")):
			# Deferred: this call can be arriving from an extra window's relay,
			# and the teardown frees that window out from under it.
			request_close()
			return true
		match k.physical_keycode:
			KEY_U:
				toggle_ui()
			KEY_S:
				if k.ctrl_pressed:
					save_viewpoint()
			KEY_R:
				reset_viewpoint()
			KEY_I:
				identify(3.0)
		# Every other key is swallowed: nothing under a window view may react.
		return true
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_drag_yaw = mb.pressed
			return true
		return false
	if event is InputEventMouseMotion and _drag_yaw:
		nudge(Vector3.ZERO, -(event as InputEventMouseMotion).relative.x * YAW_DRAG_RATE)
		return true
	return false


func _keyboard_captured_by_ui() -> bool:
	if _ui_hidden:
		return false
	var focus := get_viewport().gui_get_focus_owner()
	return focus is LineEdit or focus is TextEdit or focus is SpinBox


# ---------------------------------------------------------------------------
# Harness accessors
# ---------------------------------------------------------------------------

func window_count() -> int:
	return _windows.size()


func windows() -> Array:
	return _windows.values()


func cameras() -> Array:
	return _cams.duplicate()


func slots() -> Array[Dictionary]:
	return _slots


func screens() -> PackedInt32Array:
	return _screens


func eye() -> Vector3:
	return _eye


func yaw() -> float:
	return _yaw


## Per slot: the numbers a screenshot cannot show.
func frustum_dump() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for slot in _slots.size():
		var cam: Camera3D = _cams[slot] if slot < _cams.size() and _cams[slot] is Camera3D else null
		var near := cam.near if cam != null else 0.05
		var f := WindowWallLayout.frustum_for(_slots[slot], near)
		var sz := Vector2.ZERO
		if cam != null and cam.get_viewport() != null:
			sz = cam.get_viewport().get_visible_rect().size
		out.append({
			"slot": slot,
			"screen": _screens[slot] if slot < _screens.size() else -1,
			"size": float(f.get("size", 0.0)),
			"offset": f.get("offset", Vector2.ZERO),
			"near": near,
			"d": float(f.get("d", 0.0)),
			"viewport_px": sz,
			"aspect_mismatch": WindowWallLayout.aspect_mismatch(f, sz.x / sz.y) if sz.y > 0.0 else 0.0,
			"hfov_deg": WindowWallLayout.slot_hfov_deg(f),
			"corners": WindowWallLayout.corner_hits(f),
			"origin": cam.global_position if cam != null else Vector3.INF,
			"basis": cam.global_basis if cam != null else Basis.IDENTITY,
		})
	return out


func _toast(text: String, level: ToastUI.Level = ToastUI.Level.INFO) -> void:
	if _main != null and is_instance_valid(_main) and _main.has_method("show_toast"):
		_main.call("show_toast", text, level, 5.0)
	if _hint != null and is_instance_valid(_hint):
		_hint.call("flash", text, 4.0)

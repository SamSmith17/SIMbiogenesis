class_name GlobeLaunchTransition
extends Node

## Orchestrates a streamlined, continuous Globe-to-World launch sequence:
##   1. Starts background scene loading (`ResourceLoader.load_threaded_request`)
##      and parallel worker-thread prewarming of cached DEMs, drapes and OSM
##      layers via `WorldPrewarmer.begin` on frame 0.
##   2. Pre-stages the destination zoom-tile spine and cached world drapes on
##      `GlobeView` while pacing an unhurried, crisp orbital-to-aerial descent
##      aligned to the saved player's position, compass heading, and clock time.
##   3. Reparents `GlobeModeLayer` onto `/root` above the loading layer and
##      activates `Main` mid-flight via `change_scene_to_packed` so `TerrainLoader`
##      builds the 3D world underneath the still-descending Globe with zero
##      frozen frames or jarring loading-screen cuts.
##   4. Tracks a `GlobeArrivalCamera` inside `Main` matching the Globe camera's
##      live tangent-space pose so shaders and auto-exposure warm behind the
##      Globe, then crossfades seamlessly while swooping continuously into the
##      player's eyes (or active world camera).

const MODAL_NAME := "globe_launch_transition"
const CLAIM_OWNER := "globe_arrival"
const HANDOFF_RANGE := 0.00018          # ~1.15 km slant range (~540 m altitude at 62° tilt)
const HANDOFF_TRIGGER_RANGE := 0.00023  # hand off in motion just above target range
const WARM_3D_RANGE := 0.0032           # ~20 km: wake root 3D viewport just before handoff
const HANDOFF_TILT_DEG := 62.0
const MARKER_HIDE_ALT_KM := 45.0
const SCENE_SWITCH_MIN_S := 1.25
const SWOOP_DURATION_S := 1.25
const SWOOP_SKIP_DURATION_S := 0.28
const FADE_DURATION_S := 0.36
const HOVER_TURN_DEG_S := 1.35

static var _active_count := 0


static func is_active() -> bool:
	return _active_count > 0


var _gm: Control = null                 # GlobeMode
var _layer: CanvasLayer = null
var _rec: Dictionary = {}
var _opts: Dictionary = {}
var _snap: Dictionary = {}
var _target: Dictionary = {}
var _scene_file := ""
var _elapsed := 0.0
var _flight_dur := 5.8
var _scene_switched := false
var _main: Node = null
var _loader: Node = null
var _arrival_cam: Camera3D = null
var _warm_world_frames := 0
var _swooping := false
var _swoop_t := 0.0
var _swoop_dur := SWOOP_DURATION_S
var _swoop_from_xf := Transform3D.IDENTITY
var _swoop_from_fov := 40.0
var _skip_requested := false
var _finished := false
var _counted_active := false
var _hid_ui_layer := false

# Globe sun time-blend state.
var _jd_start := NAN
var _jd_end := NAN
var _blend_jd := false

# Unified bottom launch HUD.
var _hud: PanelContainer = null
var _title_lbl: Label = null
var _stage_lbl: Label = null
var _pct_lbl: Label = null
var _skip_lbl: Label = null
var _bar: ProgressBar = null
var _shown_progress := 0.02
var _faded_controls: Array[Control] = []


func begin(gm: Control, rec: Dictionary, opts: Dictionary = {}) -> Error:
	if gm == null or not is_instance_valid(gm) or rec.is_empty():
		return ERR_INVALID_PARAMETER
	var tree := gm.get_tree()
	if tree == null:
		return ERR_UNCONFIGURED
	var target_info := WorldLauncher.world_latlon(rec)
	if target_info.size() != 2:
		return WorldLauncher.play(tree, rec, opts)

	_gm = gm
	_rec = rec.duplicate(true)
	_opts = opts.duplicate(true)
	_layer = gm.get_parent() as CanvasLayer

	WorldLauncher.save_running_world(tree)
	_snap = WorldStore.read_snapshot(str(_rec.get("id", "")))
	_target = WorldPrewarmer.launch_camera_target(_rec, _snap)
	if _target.is_empty():
		return WorldLauncher.play(tree, _rec, _opts)

	_scene_file = WorldPrewarmer.begin(tree, _rec, _snap, _opts)
	if _scene_file.is_empty():
		return ERR_FILE_UNRECOGNIZED

	# Reparent GlobeModeLayer onto /root BEFORE adding `self` as a child of `gm`
	# (`Node.reparent` temporarily exits and re-enters the tree, which would
	# otherwise fire `_exit_tree()` on `self` right after `add_child`).
	if _layer != null and _layer.get_parent() != tree.root:
		_layer.reparent(tree.root)
	if _layer != null:
		_layer.layer = UITheme.LAYER_LOAD_OVERLAY + 4
	if gm.has_method("prepare_for_world_launch"):
		gm.call("prepare_for_world_launch")

	_active_count += 1
	_counted_active = true
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "GlobeLaunchTransition"
	gm.add_child(self)

	var gv := gm.get("globe") as GlobeView
	var map_lat := float(_target["map_lat"])
	var map_lon := float(_target["map_lon"])
	var dest_lat := float(_target["lat"])
	var dest_lon := float(_target["lon"])

	_setup_launch_hud(gm)
	_fade_out_globe_chrome(gm)
	_claim_modals()
	if not tree.scene_changed.is_connected(_on_tree_scene_changed):
		tree.scene_changed.connect(_on_tree_scene_changed)

	# Preload world drapes + destination zoom tile spine on frame 0 so tiles
	# and orthophotos resolve ahead of the descending camera instead of after.
	if gm.has_method("preload_drapes_for_site"):
		gm.call("preload_drapes_for_site", map_lat, map_lon)
	if gv != null:
		gv.labels_on = false
		gv.set_prestage_target(dest_lat, dest_lon)
		var cur_ll := gv.center_latlon()
		var alt0 := gv.altitude_km()
		var hop_km := GlobeMath.great_circle_km(cur_ll[0], cur_ll[1], dest_lat, dest_lon)
		var warm := TerrainCacheSettings.has_warm_cache(map_lat, map_lon) \
			and not bool(_opts.get("force_refetch", false))
		var base_dur := 2.6 + log(maxf(alt0, 1.0)) * 0.28 + hop_km / 10000.0
		_flight_dur = clampf(base_dur if warm else base_dur + 1.5, 2.8, 7.2)

		# Smoothly sweep sunlight to the saved world's clock (at most ±12 h of
		# diurnal rotation — never spinning through hundreds of days).
		if bool(_target.get("has_jd", false)):
			var jd_now := gv.current_jd()
			_jd_end = float(_target["jd_utc"])
			_jd_start = _jd_end - wrapf(_jd_end - jd_now, -0.5, 0.5)
			_blend_jd = true
			gv.sun_continuous = true
			gv.time_provider = Callable(self, "_blended_jd")

		var heading_goal := float(_target["heading_deg"]) if bool(_target.get("has_heading", false)) else NAN
		gv.fly_to(dest_lat, dest_lon, HANDOFF_RANGE, _flight_dur, HANDOFF_TILT_DEG, heading_goal)

	return OK


func _enter_tree() -> void:
	if not _finished and not _counted_active:
		_active_count += 1
		_counted_active = true


func _exit_tree() -> void:
	_release_active_flag()
	var tree := get_tree()
	if tree != null:
		tree.root.disable_3d = false
		if tree.scene_changed.is_connected(_on_tree_scene_changed):
			tree.scene_changed.disconnect(_on_tree_scene_changed)


func _release_active_flag() -> void:
	if _counted_active:
		_counted_active = false
		_active_count = maxi(_active_count - 1, 0)


func _blended_jd() -> float:
	if not _blend_jd:
		return GlobeMath.jd_from_unix(Time.get_unix_time_from_system())
	var u := clampf(_elapsed / maxf(_flight_dur * 0.65, 0.5), 0.0, 1.0)
	var e := u * u * (3.0 - 2.0 * u)
	return lerpf(_jd_start, _jd_end, e)


func _on_tree_scene_changed() -> void:
	if _finished:
		return
	# CursorController._on_scene_changed clears _modal_stack on every scene
	# switch; re-assert immediately so mouse/WASD stay gated until landing.
	_claim_modals()
	_bind_main_if_present()


func _claim_modals() -> void:
	var tree := get_tree()
	if tree == null:
		return
	var cc := tree.root.get_node_or_null("CursorController")
	if cc != null:
		cc.call("request_modal", MODAL_NAME, Callable(self, "_on_skip_requested"))
	HudLayout.claim_modal(MODAL_NAME)


func _on_skip_requested() -> void:
	if _finished:
		return
	_skip_requested = true
	if _swooping and _swoop_dur > SWOOP_SKIP_DURATION_S:
		var rem := maxf(1.0 - _swoop_t / maxf(_swoop_dur, 0.01), 0.05)
		_swoop_dur = SWOOP_SKIP_DURATION_S
		_swoop_t = (1.0 - rem) * _swoop_dur


func _unhandled_key_input(ev: InputEvent) -> void:
	if _finished:
		return
	var k := ev as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	if k.physical_keycode == KEY_ESCAPE or k.physical_keycode == KEY_SPACE:
		if _world_loaded() or _swooping:
			_on_skip_requested()
			var vp := get_viewport()
			if vp != null:
				vp.set_input_as_handled()


func _process(dt: float) -> void:
	if _finished or _gm == null or not is_instance_valid(_gm):
		_finish_and_cleanup()
		return

	var anim_dt := minf(dt, 0.18)
	_elapsed += anim_dt
	var gv := _gm.get("globe") as GlobeView
	# Once the 3D world underneath has finished building, gently nudge any long
	# remaining flight forward so we never linger needlessly after load completes.
	if not _swooping and _world_loaded() and gv != null and gv.is_flying() and not gv._fly.is_empty():
		gv._fly.t = float(gv._fly.t) + anim_dt * 0.35

	# Fade out Globe editing panels smoothly over the first 0.32 s.
	var chrome_a := clampf(1.0 - _elapsed / 0.32, 0.0, 1.0)
	for c in _faded_controls:
		if is_instance_valid(c):
			c.modulate.a = chrome_a
			if chrome_a <= 0.01 and c.visible:
				c.visible = false

	# Keep world photo drapes crisp as soon as altitude enters DRAPE_CLEAR_KM.
	if not _swooping and _gm.has_method("tick_launch_drapes"):
		_gm.call("tick_launch_drapes")

	# Hide floating pin spheres near the ground so no marker ball sits in front
	# of the crossfade.
	if gv != null and gv.altitude_km() < MARKER_HIDE_ALT_KM:
		gv.clear_markers()

	if not _scene_switched:
		_try_activate_world_scene()
	else:
		_bind_main_if_present()

	if _swooping:
		_step_swoop(anim_dt)
		return

	# Keep root 3D disabled while TerrainLoader builds behind the opaque Globe
	# so the GPU renders only GlobeView at full framerate and avoids repeated
	# intermediate SDFGI/shadow bakes; wake root 3D right before handoff.
	var tree := get_tree()
	if _scene_switched and tree != null:
		var want_3d_awake := _world_loaded() and (_skip_requested or gv == null
			or not gv.is_flying() or gv.cam_range <= WARM_3D_RANGE)
		tree.root.disable_3d = not want_3d_awake

	# Sync the hidden 3D arrival camera behind the Globe so shaders, shadows
	# and auto-exposure settle before the crossfade begins.
	_sync_arrival_camera_to_globe(gv)
	_update_progress_hud(gv, anim_dt)

	# Gentle living aerial drift if the Globe reached low altitude while a
	# cold/uncached world is still downloading terrain or OSM data.
	if gv != null and not gv.is_flying() and not _ready_for_swoop(gv):
		gv.cam_range = lerpf(gv.cam_range, GlobeView.MIN_RANGE * 1.02, clampf(dt * 0.45, 0.0, 1.0))
		gv.cam_heading = fposmod(gv.cam_heading + HOVER_TURN_DEG_S * dt, 360.0)
		gv.cam_tilt = lerpf(gv.cam_tilt, HANDOFF_TILT_DEG + 3.0, clampf(dt * 0.6, 0.0, 1.0))
		gv.look_at_point(float(_target["lat"]), float(_target["lon"]), gv.cam_range)

	if _ready_for_swoop(gv):
		_begin_swoop(gv)


func _try_activate_world_scene() -> void:
	if _elapsed < SCENE_SWITCH_MIN_S:
		return
	var polled := WorldPrewarmer.poll_scene(_scene_file)
	if not bool(polled.get("ready", false)):
		return
	var tree := get_tree()
	if tree == null:
		return
	_scene_switched = true
	var launch_opts := _opts.duplicate()
	var packed: PackedScene = polled.get("packed") as PackedScene
	if packed != null:
		launch_opts["packed_scene"] = packed
	launch_opts["from_globe_transition"] = true
	# Keep root 3D asleep during TerrainLoader build; woken near handoff.
	tree.root.disable_3d = true
	var err := WorldSession.launch(_rec, launch_opts)
	if err != OK:
		push_warning("GlobeLaunchTransition: WorldSession.launch failed (%d)" % err)
		_finish_and_cleanup()
		return
	_claim_modals()


func _bind_main_if_present() -> void:
	var tree := get_tree()
	if tree == null:
		return
	if _main == null or not is_instance_valid(_main):
		var cur := tree.current_scene
		if cur != null and str(cur.name) == "Main":
			_main = cur
		else:
			_main = tree.root.find_child("Main", true, false)
		if _main != null:
			_loader = _main.get_node_or_null("TerrainLoader")
			if _main.has_method("push_clock_claim"):
				_main.call("push_clock_claim", CLAIM_OWNER, {"time_scale": 0.0})
			var ui_layer := _main.get_node_or_null("UILayer") as CanvasLayer
			if ui_layer != null:
				ui_layer.visible = false
				_hid_ui_layer = true
			_claim_modals()


func _sync_arrival_camera_to_globe(gv: GlobeView) -> void:
	if _main == null or not is_instance_valid(_main) or gv == null:
		return
	var terrain_ready := _loader == null \
		or (is_instance_valid(_loader) and bool(_loader.get("_built")))
	if not terrain_ready:
		return
	if _arrival_cam == null or not is_instance_valid(_arrival_cam):
		_arrival_cam = Camera3D.new()
		_arrival_cam.name = "GlobeArrivalCamera"
		_arrival_cam.near = 0.2
		var half_ext := float(_loader.get("_half_extent")) if _loader != null and _loader.get("_half_extent") != null else 6000.0
		_arrival_cam.far = maxf(24000.0, half_ext * 3.5)
		var dest_cam := _resolve_destination_camera()
		if dest_cam != null and dest_cam.attributes != null:
			_arrival_cam.attributes = dest_cam.attributes
		_main.add_child(_arrival_cam)
		if _main.has_method("push_camera_claim"):
			_main.call("push_camera_claim", CLAIM_OWNER, {
				"camera_id": _arrival_cam.get_instance_id(),
				"hide_player_mesh": true,
				"shadow_max_distance": 1800.0,
				"prop_cull_scale_m": 2600.0,
			})
		else:
			_arrival_cam.current = true

	var ll := gv.center_latlon()
	var map_lat := float(_target["map_lat"])
	var map_lon := float(_target["map_lon"])
	var xz := GeoMath.lonlat_to_local_m(ll[0], ll[1], map_lat, map_lon)
	var gy := 0.0
	if _loader != null and is_instance_valid(_loader) and _loader.has_method("ground_height_at"):
		gy = float(_loader.call("ground_height_at", xz.x, xz.y))
	var pose := WorldPrewarmer.local_pose_for_globe_camera(
		ll[0], ll[1], gv.cam_range, gv.cam_heading, gv.cam_tilt, map_lat, map_lon, gy)
	_arrival_cam.global_transform = pose["transform"]
	_arrival_cam.fov = float(pose["fov"])
	_ensure_arrival_claim_on_top()
	var tree := get_tree()
	if tree != null and not tree.root.disable_3d:
		_warm_world_frames += 1


func _ensure_arrival_claim_on_top() -> void:
	if _main == null or not is_instance_valid(_main) or _arrival_cam == null or not is_instance_valid(_arrival_cam):
		return
	var claims: Variant = _main.get("camera_claims")
	if claims is CameraClaims and (claims as CameraClaims).effective_camera_id() != _arrival_cam.get_instance_id():
		if _main.has_method("pop_camera_claim") and _main.has_method("push_camera_claim"):
			_main.call("pop_camera_claim", CLAIM_OWNER)
			_main.call("push_camera_claim", CLAIM_OWNER, {
				"camera_id": _arrival_cam.get_instance_id(),
				"hide_player_mesh": true,
				"shadow_max_distance": 1800.0,
				"prop_cull_scale_m": 2600.0,
			})


func _world_loaded() -> bool:
	if not _scene_switched or _main == null or not is_instance_valid(_main):
		return false
	if _loader != null and is_instance_valid(_loader):
		if not bool(_loader.get("load_completed")):
			return false
	return true


func _world_ready_for_handoff() -> bool:
	return _world_loaded() and _warm_world_frames >= 3


func _ready_for_swoop(gv: GlobeView) -> bool:
	if not _world_ready_for_handoff():
		return false
	if _skip_requested:
		return true
	if gv == null:
		return true
	return not gv.is_flying() or gv.cam_range <= HANDOFF_TRIGGER_RANGE


func _begin_swoop(gv: GlobeView) -> void:
	_swooping = true
	_swoop_t = 0.0
	_swoop_dur = SWOOP_SKIP_DURATION_S if _skip_requested else SWOOP_DURATION_S
	if get_tree() != null:
		get_tree().root.disable_3d = false
	if gv != null:
		gv.clear_prestage_target()
		_sync_arrival_camera_to_globe(gv)
	if _arrival_cam != null and is_instance_valid(_arrival_cam):
		_swoop_from_xf = _arrival_cam.global_transform
		_swoop_from_fov = _arrival_cam.fov
	if _gm.has_method("hide_opaque_backdrop_for_crossfade"):
		_gm.call("hide_opaque_backdrop_for_crossfade")
	if _stage_lbl != null:
		_stage_lbl.text = "Entering world…"
	if _pct_lbl != null:
		_pct_lbl.text = "100%"
	if _bar != null:
		_bar.value = 100.0


func _step_swoop(dt: float) -> void:
	_swoop_t += dt
	_ensure_arrival_claim_on_top()
	var fade_u := clampf(_swoop_t / (0.18 if _skip_requested else FADE_DURATION_S), 0.0, 1.0)
	var globe_a := 1.0 - fade_u * fade_u * (3.0 - 2.0 * fade_u)
	if _gm != null and is_instance_valid(_gm):
		_gm.modulate.a = globe_a
		if globe_a <= 0.004 and _gm.visible:
			_gm.visible = false
	if _hud != null and is_instance_valid(_hud):
		_hud.modulate.a = clampf(1.0 - _swoop_t / 0.28, 0.0, 1.0)

	var u := clampf(_swoop_t / maxf(_swoop_dur, 0.05), 0.0, 1.0)
	var dest_cam := _resolve_destination_camera()
	if _arrival_cam != null and is_instance_valid(_arrival_cam) and dest_cam != null:
		# C¹ velocity-continuous landing: non-zero initial descent rate matching
		# the Globe's approach, smoothly decelerating to rest at eye height.
		var e_pos := 1.0 - pow(1.0 - u, 2.5)
		var e_rot := u * u * (3.0 - 2.0 * u)
		var dest_xf := dest_cam.global_transform
		var pos := _swoop_from_xf.origin.lerp(dest_xf.origin, e_pos)
		var q0 := _swoop_from_xf.basis.orthonormalized().get_rotation_quaternion()
		var q1 := dest_xf.basis.orthonormalized().get_rotation_quaternion()
		var basis := Basis(q0.slerp(q1, e_rot))
		_arrival_cam.global_transform = Transform3D(basis, pos)
		_arrival_cam.fov = lerpf(_swoop_from_fov, dest_cam.fov, e_rot)

	if u >= 1.0:
		_finish_and_cleanup()


func _resolve_destination_camera() -> Camera3D:
	if _main == null or not is_instance_valid(_main):
		return null
	var claims: Variant = _main.get("camera_claims")
	if claims is CameraClaims:
		var cid := (claims as CameraClaims).effective_camera_id_excluding(CLAIM_OWNER)
		if cid != 0:
			var c := instance_from_id(cid) as Camera3D
			if c != null and is_instance_valid(c):
				return c
	var base_id := int(_main.get("_base_camera_id")) if _main.get("_base_camera_id") != null else 0
	if base_id != 0:
		var bc := instance_from_id(base_id) as Camera3D
		if bc != null and is_instance_valid(bc):
			return bc
	var player := _main.get_node_or_null("Player")
	if player != null:
		var pcam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
		if pcam != null:
			return pcam
	return null


func _update_progress_hud(gv: GlobeView, dt: float) -> void:
	var flight_u := clampf(_elapsed / maxf(_flight_dur, 0.5), 0.0, 1.0)
	var scene_p := 1.0 if _scene_switched else float(WorldPrewarmer.poll_scene(_scene_file).get("progress", 0.0))
	var world_p := 0.0
	var stage := "Aligning orbit…"
	if not _scene_switched:
		stage = "Preparing world scene…" if _elapsed > 0.7 else "Descending from orbit…"
	elif _loader != null and is_instance_valid(_loader) and _loader.has_method("load_progress_state"):
		var st: Dictionary = _loader.call("load_progress_state")
		world_p = float(st.get("fraction", 0.0))
		var lbl := str(st.get("stage", ""))
		var hint := str(st.get("hint", ""))
		if bool(st.get("load_completed", false)):
			world_p = 1.0
			stage = "Approaching site…"
		elif not lbl.is_empty():
			stage = lbl if hint.is_empty() else "%s — %s" % [lbl, hint]
		else:
			stage = "Building terrain…"
	elif _main != null:
		world_p = 1.0
		stage = "Approaching site…"

	var combined := 0.18 * scene_p + 0.54 * world_p + 0.28 * flight_u
	if _world_ready_for_handoff() and gv != null and gv.is_flying():
		stage = "Descending to %s…" % GlobeMode.world_title(_rec)
	_shown_progress = maxf(_shown_progress, lerpf(_shown_progress, clampf(combined, 0.02, 0.99), clampf(dt * 5.0, 0.0, 1.0)))

	if _stage_lbl != null:
		_stage_lbl.text = stage
	if _pct_lbl != null:
		_pct_lbl.text = "%d%%" % int(round(_shown_progress * 100.0))
	if _bar != null:
		_bar.value = _shown_progress * 100.0
	if _skip_lbl != null:
		_skip_lbl.visible = _world_loaded() and _elapsed > 1.0


func _setup_launch_hud(gm: Control) -> void:
	_hud = PanelContainer.new()
	_hud.name = "GlobeLaunchHud"
	var sb := UITheme.dock_panel_style(0.86)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 12
	sb.content_margin_bottom = 12
	_hud.add_theme_stylebox_override("panel", sb)
	_hud.custom_minimum_size = Vector2(440, 0)
	_hud.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hud.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hud.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_hud.offset_left = -220
	_hud.offset_right = 220
	_hud.offset_bottom = -32
	_hud.offset_top = -32
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gm.add_child(_hud)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(col)

	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top_row)

	_title_lbl = Label.new()
	_title_lbl.text = GlobeMode.world_title(_rec)
	_title_lbl.add_theme_font_override("font", UITheme.font("semibold"))
	_title_lbl.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	_title_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	_title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_lbl.clip_text = true
	_title_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	top_row.add_child(_title_lbl)

	_skip_lbl = Label.new()
	_skip_lbl.text = "Esc to land now"
	_skip_lbl.visible = false
	_skip_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_skip_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	top_row.add_child(_skip_lbl)

	_pct_lbl = Label.new()
	_pct_lbl.text = "2%"
	_pct_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_pct_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	top_row.add_child(_pct_lbl)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 6)
	_bar.max_value = 100.0
	_bar.value = 2.0
	_bar.show_percentage = false
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color = Color(0.12, 0.15, 0.22, 0.9)
	bar_bg.set_corner_radius_all(3)
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color = UITheme.C_PRIMARY
	bar_fill.set_corner_radius_all(3)
	_bar.add_theme_stylebox_override("background", bar_bg)
	_bar.add_theme_stylebox_override("fill", bar_fill)
	col.add_child(_bar)

	_stage_lbl = Label.new()
	_stage_lbl.text = "Descending from orbit…"
	_stage_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_stage_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_stage_lbl.clip_text = true
	_stage_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(_stage_lbl)


func _fade_out_globe_chrome(gm: Control) -> void:
	_faded_controls.clear()
	for child_name in ["TopBar", "WorldsDrawer", "PointCard", "LayerBar", "TimeBar", "SearchPopup"]:
		var ctrl := gm.get_node_or_null(child_name) as Control
		if ctrl != null and ctrl.visible:
			ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_faded_controls.append(ctrl)


func _finish_and_cleanup() -> void:
	if _finished:
		return
	_finished = true
	set_process(false)
	_release_active_flag()

	var tree := get_tree()
	if tree != null:
		tree.root.disable_3d = false
		if tree.scene_changed.is_connected(_on_tree_scene_changed):
			tree.scene_changed.disconnect(_on_tree_scene_changed)

	if _main != null and is_instance_valid(_main):
		if _hid_ui_layer:
			var ui_layer := _main.get_node_or_null("UILayer") as CanvasLayer
			if ui_layer != null:
				ui_layer.visible = true
			_hid_ui_layer = false
		if _main.has_method("pop_camera_claim"):
			_main.call("pop_camera_claim", CLAIM_OWNER)
		if _main.has_method("pop_clock_claim"):
			_main.call("pop_clock_claim", CLAIM_OWNER)
	if _arrival_cam != null and is_instance_valid(_arrival_cam):
		_arrival_cam.queue_free()
		_arrival_cam = null

	if tree != null:
		var cc := tree.root.get_node_or_null("CursorController")
		if cc != null:
			cc.call("release_modal", MODAL_NAME)
			cc.call("release_modal", GlobeMode.MODAL_NAME)
	HudLayout.release(MODAL_NAME)
	HudLayout.release(GlobeMode.MODAL_NAME)

	if _loader != null and is_instance_valid(_loader) and _loader.has_method("on_globe_transition_finished"):
		_loader.call("on_globe_transition_finished")

	if _gm != null and is_instance_valid(_gm) and _gm.has_method("close"):
		_gm.call("close")
	elif _layer != null and is_instance_valid(_layer):
		_layer.queue_free()
	else:
		queue_free()

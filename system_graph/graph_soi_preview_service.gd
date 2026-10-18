extends Node

## Live Sphere-of-Influence snowglobe preview behind the 2D graph.
## Shares the main World3D via a SubViewport (root viewport stays disable_3d
## while the graph is open). Framed so the SoI circumference matches the
## graph's SoI disc (4 px/m × zoom).
## Modes: Site Plan top-down · Freeform orbit (Shift+drag/scroll) · Elevation
## section (optional 3D vertical slice; heading driven by the canvas).

const SOI_PX_PER_M := 4.0
const DEFAULT_ORBIT_YAW := 0.55
const DEFAULT_ORBIT_PITCH := 0.42
## Farther than a silhouette-fill so the globe sits inside the disc by default
## (matches snowglobe feel; Shift+scroll zooms in).
const DEFAULT_ORBIT_MULT := 2.2
const MIN_ORBIT_MULT := 0.35
const MAX_ORBIT_MULT := 4.5
const ZOOM_STEP := 0.06

const ZOOM_SMOOTH := 10.0
const MIN_ORBIT_DIST_M := 8.0
const MIN_VIEWPORT_PX := 64
## Site Plan straight-down camera height. Ortho projection is distance-independent
## (framing = _camera.size), so a modest height frames the whole SoI fine; prop
## distance-culling is lifted while the preview is up (PropRenderTuning.preview_active)
## so twins render regardless of camera distance. (The orbit path pulls the camera
## FARTHER as it tilts — see _apply_topdown_orbit — to avoid near/far clipping.)
const PREVIEW_TOPDOWN_HEIGHT_MAX_M := 60.0
## Higher cap reduces UV stretch pinch on large Site Plan discs / HiDPI.
const MAX_VIEWPORT_PX := 2048
## Elevation CT / Siphon embed — lower than Site Plan; 2048² + shared World3D
## on first G open was a common AMD TDR trigger.
const MAX_SECTION_VIEWPORT_PX := 1280
## Above this disc diameter, cover the canvas and crop the ortho frustum instead
## of growing a Control to tens of thousands of pixels (extreme 2D zoom-in).
# Matches MAX_VIEWPORT_PX so the below-threshold disc never renders at a container
# size larger than the viewport can capture — that mismatch made the disc render at
# ~0.5× (blurry) just under the crop threshold and snap sharp above it (the "zoom
# jump"). Equal caps keep render density ~1× on both sides of the switch.
const MAX_DISC_CONTAINER_PX := 2048.0
## The Site Plan's air outside the SoI clip (overridden by the canvas's bg).
const PLAN_BACKDROP_COLOR := Color(0.055, 0.075, 0.11, 1.0)
## Site Plan / Elevation / Hydro Lab are PERSPECTIVE cameras now (the Globe's
## kind), placed so px/m on their focus plane — the ground under the view
## centre, or the cut face — equals the 2D mapping's scale exactly. At rest
## that plane maps linearly, so every 2D overlay stays registered, while the
## image gains real depth. No ortho floors: the frame height may go to
## MIN_FRAME_H_M and the camera simply comes closer (near plane follows).
const PLAN_FOV_DEG := 35.0
const SECTION_FOV_DEG := 30.0
const MIN_FRAME_H_M := 0.02
const LENS_SHADOW_CLAIM := "graph_lens_shadow"
## Hydro Lab CT ortho floor — shared with the Lab's 2D overlay so the two cannot
## clamp differently. See GraphSiteLayout.LAB_MIN_ORTHO_H_M for the why.
const LAB_MIN_ORTHO_H_M := GraphSiteLayout.LAB_MIN_ORTHO_H_M
## Frames to wait after activate before first UPDATE_ONCE (lets layout settle).
const SOFT_BOOT_FRAMES := 3
const YAW_SENS := 0.005
const PITCH_SENS := 0.004
const PITCH_MIN := 0.05
const PITCH_MAX := 1.45
## Physical-view orbit (Site top-down / Elevation section — free tilt).
## Sensitivity raised 0.006 → 0.008 so a working orbit at deep zoom takes one
## drag, not three.
const PHYS_YAW_SENS := 0.008
const PHYS_PITCH_SENS := 0.008
## Site: 0 = straight down, up to nearly horizon (raised 1.30 → 1.45, matching
## the freeform PITCH_MAX, so a zoomed-in orbit can get low enough to read
## building heights). Section: ± above/below side-on.
const PHYS_PITCH_MAX := 1.45
## Cap idle redraws while SoI lite preview is active (~24 FPS).
const IDLE_REFRESH_HZ := 24.0
## When the disc Control would exceed MAX_DISC_CONTAINER_PX (high 2D zoom).
const IDLE_REFRESH_HZ_CROPPED := 8.0

signal preview_active_changed(active: bool)

var active: bool = false

var _host: Control = null
var _canvas: Control = null
var _container: SubViewportContainer = null
var _viewport: SubViewport = null
var _camera: Camera3D = null
var _yaw: float = DEFAULT_ORBIT_YAW
var _pitch: float = DEFAULT_ORBIT_PITCH
var _orbit_mult: float = DEFAULT_ORBIT_MULT
var _orbit_mult_target: float = DEFAULT_ORBIT_MULT
var _top_down: bool = false
## True when preview covers the canvas and zooms with 2D pan/zoom (Site OR
## Elevation section at extreme zoom — never grow Control to megapixels).
var _top_down_cropped: bool = false
## Elevation: camera looks along a cross-section of the snowglobe.
var _section_mode: bool = false
## Globe lens: the full snowglobe INSIDE the graph — a perspective orbit across
## the whole canvas, glass dome on, rim sun, opaque sky. The graph's Snowglobe
## chip used to start the full-screen SoiSnowglobeCamera, which renders through
## the ROOT viewport — the one the open graph runs with disable_3d — so it drew
## nothing. This lens is rendered by the same SubViewport as Plan/Section.
var _globe: bool = false
## First Globe entry per graph session frames like the full-screen globe
## (sphere snug in frame, sun in view); later entries keep the orbit.
var _globe_framed: bool = false
var _globe_claims_held: bool = false
const GLOBE_MIN_ORBIT_MULT := 0.05
const GLOBE_FIT_FRACTION := 0.86
const GLOBE_PITCH := 0.26
const GLOBE_FOV := 68.0
const GLOBE_RIM_SUN_OWNER := "graph_globe"
const GLOBE_SHADOW_CLAIM := "graph_globe_shadow"

## Lens transitions (SoiStagePose): switching Plan / Section / Globe / bubble
## flies the camera between the two poses instead of cutting — Plan → Section
## swings from overhead through a 3D view to side-on. The view brackets every
## lens change with begin_lens_transition() / end_lens_transition().
const LENS_TWEEN_MS := 560
## Captures while flying: ≤30 Hz, MSAA off, one in flight.
const LENS_TWEEN_FRAME_MS := 33
var _cam_look: Vector3 = Vector3.ZERO
var _lens_pending_from: Dictionary = {}
var _tween_active: bool = false
var _tween_t0_ms: int = 0
var _tween_from: Dictionary = {}
var _tween_to: Dictionary = {}
var _tween_bulge: float = 0.0
var _tween_mask_from: Dictionary = {}
var _tween_mask_to: Dictionary = {}
var _tween_last_frame_ms: int = 0
## Section sweep: entering Elevation the cut plane slices INTO the globe from
## its rim to the slice depth while the camera flies (the solid strata cap
## grows with it); leaving, it slides back out. "in" | "out" | "".
var _tween_sweep: String = ""
var _section_heading: float = 0.0
## CT slice depth along the cross-axis (−R…+R metres from SoI centre).
var _section_offset_m: float = 0.0

## Physical-view orbit state (Site/Elevation). At (0,0) the camera keeps its
## exact default pose (top-down / side-on) so nothing changes until the user
## tilts; once orbited, this service becomes the projection authority for the
## 2D chips + wires so they track the tilt.
var _phys_yaw: float = 0.0
var _phys_pitch: float = 0.0
## Height (m) of the view at its focus plane — what the ortho size used to be.
var _frame_h_m: float = 10.0
var _lens_shadow_held := false
var _clip_owned: bool = false
var _layout_dirty: bool = true
var _camera_dirty: bool = true
var _last_layout_key: String = ""
var _refresh_acc: float = 0.0
var _saved_shadows: int = -1
## When false (default) the preview is captured only on view changes (zoom/pan/
## section) and otherwise holds a still frame — the elevation view does not need
## the sun to move live, and re-rendering the whole shared World3D every idle
## frame was this view's main cost (and the deciduous-shader "pulse"). Flip via
## set_preview_live() if a live-lit preview is ever wanted.
var _preview_live: bool = false
## Clock-driven capture state (see _clock_refresh_due).
const CLOCK_SCRUB_HZ := 10.0
const CLOCK_SCRUB_HZ_HEAVY := 6.0
const CLOCK_PLAY_HZ := 4.0
const CLOCK_PLAY_HZ_HEAVY := 2.0
## Re-capture once the sun has moved this far (a visible shadow/colour shift)…
const CLOCK_SUN_STEP_DEG := 0.35
## …or this many sim-hours passed (night: the sun is under the floor but the
## moon, sky and weather still move)…
const CLOCK_HOURS_STEP := 0.25
## …or at least this often while the clock runs (clouds, hazards).
const CLOCK_IDLE_MS := 5000
var _clock_render_abs_h: float = NAN
var _clock_render_sun: Vector3 = Vector3.ZERO
var _clock_render_ms: int = 0
var _render_in_flight: bool = false
## Captures that actually drew (frame_post_draw acks). Harness-facing.
var frames_rendered: int = 0
## Optional Control that owns the SubViewportContainer (Siphon Lab CT slot).
## When set, layout fills this host instead of the graph SoI disc.
var _embed_host: Control = null
## Siphon Lab framing override: along_m, elev_m, ortho_h_m (metres).
var _lab_along_m: float = NAN
var _lab_elev_m: float = NAN
var _lab_ortho_h_m: float = NAN
## The active lens's camera Environment (see _apply_section_environment) and
## which lens family it was built for. Site Plan: a constant COLOR ambient floor
## so the plan is readable at night while the (boosted) moon still shades it —
## the ambient casts no shadows, the moon does, so moonshadows survive.
## Section / orbit: the world's own ambient by day, handing over to a night
## floor after dark. Only this camera sees it; the first-person world is untouched.
var _lens_env: Environment = null
var _lens_env_key: String = ""
const TOPDOWN_AMBIENT_COLOR := Color(0.58, 0.64, 0.78)
const TOPDOWN_AMBIENT_ENERGY := 0.55
const NIGHT_FLOOR_COLOR := Color(0.55, 0.62, 0.78)
const SECTION_NIGHT_FLOOR_ENERGY := 0.5
## How much of the floor the section keeps by day (1 = full night floor).
const SECTION_DAY_FLOOR := 0.75
const ORBIT_NIGHT_FLOOR_ENERGY := 0.30
const ORBIT_DAY_FLOOR := 0.5
## Moon light-energy multiplier while the top-down plan is live (applied via
## main.moon_light_boost — main's _update_moon rewrites the light every pass,
## so the multiplier must live inside that computation). Restored on exit.
const MOON_BOOST := 3.0
var _moon_boost_applied := false
var _disc_material: ShaderMaterial = null
## Soft-boot: hold first capture until layout has a few idle frames.
var _soft_boot_frames: int = 0
## First-frame handshake: the canvas must not punch its SoI hole (nor hand the
## camera projection authority) until the SubViewport has actually RENDERED
## once — flipping soi_live_preview at activate time showed a black disc for
## the whole soft-boot window, and chips jumped to the camera projection
## frames before any image existed. Pending is cleared by
## _on_first_preview_frame, which runs on RenderingServer.frame_post_draw of
## the first real capture.
var _first_frame_pending: bool = false
var _first_frame_hooked: bool = false


func setup(host: Control, canvas: Control) -> void:
	_host = host
	_canvas = canvas
	_ensure_nodes()
	_set_visible(false)
	var soi := _soi()
	if soi != null and soi.has_signal("soi_changed") \
			and not soi.is_connected("soi_changed", _on_soi_changed):
		soi.connect("soi_changed", _on_soi_changed)
	_connect_canvas_camera_signals()


## Reparent the preview into `host` (Siphon Lab), or restore to the graph host.
## Hide/show the embedded preview container without tearing the embed down. The
## Hydro Lab's turbine close-up takes over the same rect, and leaving this
## rendering underneath it costs a full 3D pass for pixels nobody sees.
func set_embed_visible(on: bool) -> void:
	_embed_shown = on
	if _container == null or not is_instance_valid(_container):
		return
	_container.visible = on
	if _viewport != null and is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE \
				if on else SubViewport.UPDATE_DISABLED


## What set_embed_visible last chose for the Lab embed.
var _embed_shown := true


## Godot's SubViewportContainer switches its child viewport to UPDATE_ALWAYS
## whenever the container becomes visible in the tree (and to DISABLED when it
## stops being), overriding the mode this service picked. That bypassed the
## soft boot whenever the preview was ACTIVATED while the graph was hidden — a
## lens applied to a closed graph (the saved lens at map load, or the Hydro
## Lab's return-to-Elevation run with the graph shut): the container stretches
## the viewport from a 0-size canvas to a 2×2 placeholder, and the reveal then
## rendered that every frame — ~200 "Too many mipmaps" / null scene-buffer /
## zero-dispatch errors the moment the graph opened (found by the feature tour:
## Hydro Lab, then the Solar Bootcamp). Re-assert this service's mode after the
## engine's. `visibility_changed` is emitted on the container's
## NOTIFICATION_VISIBILITY_CHANGED from CanvasItem's (base-class) half of the
## notification, BEFORE SubViewportContainer's half sets the mode — so the
## handler is connected DEFERRED (it then runs after the engine's write and
## before the frame renders).
func _on_container_visibility_changed() -> void:
	if _viewport == null or not is_instance_valid(_viewport) \
			or _container == null or not is_instance_valid(_container):
		return
	if not _container.is_visible_in_tree():
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	if _embed_host != null and is_instance_valid(_embed_host):
		_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE \
				if _embed_shown else SubViewport.UPDATE_DISABLED
		return
	# Dirty-driven as always: _process lays out and schedules the capture.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if not active:
		return
	_layout_dirty = true
	_camera_dirty = true
	if _viewport_too_small():
		# Sized while hidden: let the revealed canvas lay out before a capture.
		_soft_boot_frames = maxi(_soft_boot_frames, SOFT_BOOT_FRAMES)


## A viewport still at a hidden canvas's placeholder size — rendering it makes
## the half/quarter-res effect passes zero-sized.
func _viewport_too_small() -> bool:
	return _viewport.size.x < MIN_VIEWPORT_PX or _viewport.size.y < MIN_VIEWPORT_PX


func set_embed_host(host: Control) -> void:
	_embed_host = host if (host != null and is_instance_valid(host)) else null
	_ensure_nodes()
	if _container == null:
		return
	var parent_target: Control = _embed_host if _embed_host != null else _host
	if parent_target == null:
		return
	if _container.get_parent() != parent_target:
		if _container.get_parent() != null:
			_container.get_parent().remove_child(_container)
		parent_target.add_child(_container)
		if _embed_host == null and _canvas != null and is_instance_valid(_canvas):
			var insert_at := maxi(_canvas.get_index(), 1)
			_host.move_child(_container, insert_at)
		else:
			parent_target.move_child(_container, 0)
	_layout_dirty = true
	_camera_dirty = true
	if active:
		_sync_layout()
		_update_camera()
		_request_viewport_refresh()


## Frame the section camera to a Lab slice window (metres). Pass NAN to clear.
func set_lab_section_frame(along_m: float, elev_m: float, ortho_h_m: float) -> void:
	_lab_along_m = along_m
	_lab_elev_m = elev_m
	_lab_ortho_h_m = ortho_h_m
	_camera_dirty = true
	_layout_dirty = true
	if active and _section_mode:
		_update_camera()
		_request_viewport_refresh()


func clear_lab_section_frame() -> void:
	_lab_along_m = NAN
	_lab_elev_m = NAN
	_lab_ortho_h_m = NAN


func _connect_canvas_camera_signals() -> void:
	if _canvas == null or not is_instance_valid(_canvas):
		return
	if _canvas.has_signal("soi_preview_orbit") \
			and not _canvas.is_connected("soi_preview_orbit", apply_orbit_delta):
		_canvas.connect("soi_preview_orbit", apply_orbit_delta)
	if _canvas.has_signal("soi_preview_zoom") \
			and not _canvas.is_connected("soi_preview_zoom", apply_zoom_step):
		_canvas.connect("soi_preview_zoom", apply_zoom_step)


func _on_soi_changed() -> void:
	_layout_dirty = true
	_camera_dirty = true
	if active:
		_apply_soi_visuals(true)
		_sync_layout()
		_update_camera()
		_request_viewport_refresh()


## How much of the vegetation's night darkening a live lens takes back
## (0 = the first-person look, 1 = full daylight canopy at midnight). Paired
## with the lens ambient floors so trees and ground read on one scale.
const LENS_VEG_NIGHT_LIFT := 0.65


## Main's own vegetation night signal (DaylightModel.vegetation_night).
func _vegetation_world_night() -> float:
	var main: Node = get_tree().current_scene if get_tree() != null else null
	if main != null and main.has_method("get_vegetation_night_factor"):
		return float(main.call("get_vegetation_night_factor"))
	return 0.0


func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	if not on:
		var veg_sync: Node = get_tree().root.get_node_or_null("VegetationEnvironmentSync") if get_tree() != null else null
		if veg_sync != null and veg_sync.has_method("set_night_override"):
			veg_sync.call("set_night_override", NAN)
	# Lift prop distance-culling while the disc is up so the far/tilted preview
	# camera can't cull small graph-twin props; restore normal culling on close.
	# (First-person 3D isn't rendering while the graph is open, so this is free.)
	var _pmain := get_tree().current_scene if get_tree() != null else null
	if _pmain != null:
		PropRenderTuning.preview_active = on
		# The whole-scene prop walk is deferred off the activation frame (which
		# already pays layout + world bind); the first capture is ≥3 soft-boot
		# frames later, so culling state settles well before anything renders.
		call_deferred("_apply_prop_tuning_deferred")
	var soi_v := _soi()
	if soi_v != null and soi_v.has_method("set_preview_vegetation_look"):
		soi_v.call("set_preview_vegetation_look", "graph_preview", on)
	if on:
		_ensure_nodes()
		_connect_canvas_camera_signals()
		_bind_world()
		_apply_soi_visuals(true)
		_apply_preview_shell_visuals()
		_sync_moon_boost()
		_layout_dirty = true
		_camera_dirty = true
		_orbit_mult_target = _orbit_mult
		_sync_layout()
		_update_camera()
		_set_visible(true)
		process_priority = 0
		set_process(true)
		_apply_lite_camera()
		# Soft boot: never UPDATE_WHEN_VISIBLE on open — one deferred capture
		# after layout avoids a same-frame World3D storm (AMD TDR on G).
		if _viewport != null:
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_soft_boot_frames = SOFT_BOOT_FRAMES
		_first_frame_pending = true
		if _section_mode:
			_apply_hydroturbine_section_clip(true)
			_ensure_section_soil_visible()
	else:
		_lens_env = null
		_lens_env_key = ""
		_globe_framed = false
		if _tween_active:
			_tween_active = false
			_tween_sweep = ""
			if _canvas != null and is_instance_valid(_canvas):
				_canvas.modulate.a = 1.0
		_sync_globe_world_effects(false)
		_soft_boot_frames = 0
		_first_frame_pending = false
		set_process(false)
		_set_visible(false)
		_apply_hydroturbine_section_clip(false)
		_apply_soi_visuals(false)
		_sync_moon_boost()
		_restore_lite_camera()
		if _viewport != null:
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_sync_lens_shadow_claim()
	if _canvas != null and is_instance_valid(_canvas):
		# Reveal is deferred to the first RENDERED frame (_on_first_preview_frame)
		# — flipping soi_live_preview now would punch the SoI hole over a
		# SubViewport that stays UPDATE_DISABLED through the soft-boot window,
		# which was the black-flash on every Site/Elevation entry.
		if not on:
			_canvas.set("soi_live_preview", false)
		_canvas.queue_redraw()
	preview_active_changed.emit(on)


func _apply_prop_tuning_deferred() -> void:
	var pmain := get_tree().current_scene if get_tree() != null else null
	if pmain != null and is_instance_valid(pmain):
		PropRenderTuning.apply_to_all(pmain)


func teardown() -> void:
	set_active(false)
	if is_instance_valid(_container):
		_container.queue_free()
	_container = null
	_viewport = null
	_camera = null


func mark_layout_dirty() -> void:
	_layout_dirty = true
	_camera_dirty = true


## Immediate crop/layout (enter Elevation at extreme zoom before next idle tick).
func force_layout_sync() -> void:
	if not active:
		return
	_layout_dirty = true
	_sync_layout()
	_camera_dirty = true
	_update_camera()
	_camera_dirty = false
	_request_viewport_refresh()
	# Section CT: 2D overlays re-project through the updated camera same frame.
	if _section_mode:
		_notify_canvas_redraw()


func apply_orbit_delta(relative: Vector2) -> void:
	if not active:
		return
	if _top_down:
		# Site Plan: horizontal drag rotates the map heading, vertical tilts it
		# up toward the horizon (0 = straight down).
		_phys_yaw = fposmod(_phys_yaw - relative.x * PHYS_YAW_SENS, TAU)
		_phys_pitch = clampf(_phys_pitch - relative.y * PHYS_PITCH_SENS, 0.0, PHYS_PITCH_MAX)
		_camera_dirty = true
		_update_camera()
		_request_viewport_refresh()
		_notify_canvas_redraw()
		return
	if _section_mode:
		# Elevation CT: pitch locked. Slice depth is scrubbed on the canvas.
		_phys_pitch = 0.0
		return
	_yaw = fposmod(_yaw - relative.x * YAW_SENS, TAU)
	_pitch = clampf(_pitch - relative.y * PITCH_SENS, PITCH_MIN, PITCH_MAX)
	_camera_dirty = true
	_update_camera()
	_sync_globe_glass()
	_request_viewport_refresh()
	if _globe:
		_notify_canvas_redraw()


func _notify_canvas_redraw() -> void:
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.queue_redraw()


## True when the user has tilted the physical view off its default pose.
func is_phys_orbited() -> bool:
	return not is_zero_approx(_phys_yaw) or not is_zero_approx(_phys_pitch)


## True when the preview camera can drive Site/Elevation node projection.
## Hydro Lab embed still projects (container fills the Lab preview stack).
func is_projection_authority() -> bool:
	if not active or _camera == null or not is_instance_valid(_camera):
		return false
	# Until the first frame has rendered, chips keep the proven flat-disc math —
	# the camera's default top-down pose matches it, so the handover is seamless.
	if _first_frame_pending:
		return false
	# Mid lens transition the camera is between poses; overlays are faded out.
	if _tween_active:
		return false
	if _viewport == null or _viewport.size.x <= 1 or _viewport.size.y <= 1:
		return false
	if _container == null or not is_instance_valid(_container):
		return false
	if not (_top_down or _section_mode or _globe):
		return false
	if _embed_host != null and is_instance_valid(_embed_host):
		return true
	return _canvas != null and is_instance_valid(_canvas)


func is_section_mode() -> bool:
	return _section_mode and active


func is_globe() -> bool:
	return _globe and active


func is_lens_tweening() -> bool:
	return _tween_active


func _lens_name() -> String:
	if _globe:
		return "globe"
	if _section_mode:
		return "section"
	if _top_down:
		return "plan"
	return "bubble"


## The visible preview circle in canvas pixels (the Globe has none: a circle
## big enough to cover the canvas, so a tween can open / close it).
func _current_mask_canvas() -> Dictionary:
	if _canvas == null or not is_instance_valid(_canvas):
		return {}
	if _globe or _section_mode or _top_down:
		# Every lens fills the canvas now; a covering circle lets a flight
		# open or close the freeform bubble's disc into the full window.
		return {"c": _canvas.size * 0.5, "r": _canvas.size.length() * 0.6}
	var disc := _read_disc()
	return {
		"c": disc.get("origin", _canvas.size * 0.5) as Vector2,
		"r": maxf(float(disc.get("radius_px", 1.0)), 1.0),
	}


## Snapshot where the camera is before the view switches lens.
func begin_lens_transition() -> void:
	_lens_pending_from = {}
	if not active or _first_frame_pending or _camera == null or not is_instance_valid(_camera):
		return
	if _embed_host != null and is_instance_valid(_embed_host):
		return
	if _soft_boot_frames > 0:
		return
	_lens_pending_from = {
		"pose": SoiStagePose.from_camera(_camera, _cam_look),
		"mask": _current_mask_canvas(),
		"lens": _lens_name(),
	}


## After the switch: fly from the snapshot to the new lens's pose.
func end_lens_transition() -> void:
	var from := _lens_pending_from
	_lens_pending_from = {}
	if from.is_empty() or not active or _camera == null:
		return
	if _embed_host != null and is_instance_valid(_embed_host):
		return
	if str(from.get("lens", "")) == _lens_name():
		return
	# Make sure the destination pose + mask are current before reading them.
	_sync_layout()
	_update_camera()
	_tween_from = from["pose"] as Dictionary
	_tween_to = SoiStagePose.from_camera(_camera, _cam_look)
	_tween_mask_from = from["mask"] as Dictionary
	_tween_mask_to = _current_mask_canvas()
	var both_ortho := float(_tween_from["ortho_w"]) >= 0.999 and float(_tween_to["ortho_w"]) >= 0.999
	_tween_bulge = 0.8 if both_ortho else 0.0
	# A flight interrupted mid-sweep: drop its half-cut plane now.
	if _tween_active and not _tween_sweep.is_empty() and not _section_mode:
		_clear_section_cutaway()
	var from_lens := str(from.get("lens", ""))
	_tween_sweep = "in" if _section_mode and from_lens != "section" \
			else ("out" if from_lens == "section" and not _section_mode else "")
	_tween_active = true
	_tween_t0_ms = Time.get_ticks_msec()
	_tween_last_frame_ms = 0
	_process_tween()


func _process_tween() -> void:
	var soi := _soi()
	var r := float(soi.call("radius_m")) if soi != null and soi.has_method("radius_m") else 150.0
	var t := clampf(float(Time.get_ticks_msec() - _tween_t0_ms) / float(LENS_TWEEN_MS), 0.0, 1.0)
	var e := SoiStagePose.ease_t(t)
	SoiStagePose.apply(_camera, SoiStagePose.lerp_pose(_tween_from, _tween_to, e, _tween_bulge), r)
	# Fly in a canvas-sized frame with the mask circle morphing between lenses.
	if _canvas != null and is_instance_valid(_canvas) and _container != null:
		_container.material = _disc_material
		_container.position = _canvas.position
		_container.size = _canvas.size
		if _viewport != null:
			# (Size follows the container — SubViewportContainer.stretch.)
			_viewport.msaa_3d = Viewport.MSAA_DISABLED
		var mc0: Vector2 = _tween_mask_from.get("c", _canvas.size * 0.5) as Vector2
		var mc1: Vector2 = _tween_mask_to.get("c", _canvas.size * 0.5) as Vector2
		var mr0 := float(_tween_mask_from.get("r", 1.0))
		var mr1 := float(_tween_mask_to.get("r", 1.0))
		_set_disc_mask(true, mc0.lerp(mc1, e), exp(lerpf(log(mr0), log(mr1), e)), _container.size)
		# The 2D overlay belongs to a lens's resting pose: fade it out while
		# flying and back in as the camera lands.
		var fade := 1.0 - smoothstep(0.0, 0.3, t) if t < 0.5 else smoothstep(0.7, 1.0, t)
		_canvas.modulate.a = fade
	if not _tween_sweep.is_empty():
		_push_sweep_cutaway(e, r)
	var now := Time.get_ticks_msec()
	if t >= 1.0:
		_finish_tween()
		return
	if now - _tween_last_frame_ms >= LENS_TWEEN_FRAME_MS and not _render_in_flight:
		_tween_last_frame_ms = now
		_request_viewport_refresh()


## The cut plane at sweep progress `e`: from the rim (+R, nothing cut — the
## camera side is +cross) to the slice depth, or back out.
func _push_sweep_cutaway(e: float, r: float) -> void:
	var soi := _soi()
	if soi == null or not soi.has_method("set_section_cutaway") or not _clip_owned:
		return
	if bool(soi.get("snowglobe_active")):
		return
	var c: Vector3 = soi.call("world_center") as Vector3
	var h := _section_heading
	var cross := Vector3(-sin(h), 0.0, cos(h))
	var k := e if _tween_sweep == "in" else 1.0 - e
	var d := lerpf(r, _section_offset_m, k)
	soi.call("set_section_cutaway", true, c + cross * d, cross)


func _finish_tween() -> void:
	_tween_active = false
	# Land the cut where the lens wants it — also when a flight was
	# interrupted by another lens switch part-way through a sweep.
	if _section_mode:
		_push_section_cutaway()
	elif not _tween_sweep.is_empty():
		_clear_section_cutaway()
	_tween_sweep = ""
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.modulate.a = 1.0
		if _canvas.has_method("begin_soi_reveal"):
			_canvas.call("begin_soi_reveal")
		_canvas.queue_redraw()
	# The ordinary path re-lays-out and snaps the camera to the exact pose.
	_layout_dirty = true
	_camera_dirty = true
	_apply_viewport_msaa()


## Globe lens on/off. Mutually exclusive with Site Plan (top-down) and the
## Elevation section; the freeform bubble is "none of the three".
func set_globe(on: bool) -> void:
	if _globe == on:
		return
	_globe = on
	if on:
		if _top_down:
			_top_down = false
		if _section_mode:
			_section_mode = false
			_clear_section_cutaway()
			_apply_hydroturbine_section_clip(false)
		if not _globe_framed:
			_frame_globe()
	_apply_preview_shell_visuals()
	_sync_moon_boost()
	_apply_viewport_msaa()
	_sync_globe_world_effects(on and active)
	_sync_lens_shadow_claim()
	if _viewport != null:
		_viewport.transparent_bg = not _globe
	_apply_section_environment()
	_layout_dirty = true
	_camera_dirty = true
	_update_camera()
	_request_viewport_refresh()
	_notify_canvas_redraw()


## Open composition shared with the full-screen globe (SoiOrbitMath): sphere
## snug in the frame, near side-on, the sun in view.
func _frame_globe() -> void:
	_globe_framed = true
	var frame := Vector2(1280.0, 720.0)
	if _canvas != null and is_instance_valid(_canvas):
		frame = _canvas.size
	_orbit_mult = SoiOrbitMath.fit_orbit_mult(GLOBE_FOV, frame, GLOBE_FIT_FRACTION,
			GLOBE_MIN_ORBIT_MULT, MAX_ORBIT_MULT, DEFAULT_ORBIT_MULT)
	_orbit_mult_target = _orbit_mult
	_pitch = GLOBE_PITCH
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	_yaw = SoiOrbitMath.sun_facing_yaw(main.get("sun") as DirectionalLight3D if main != null else null,
			DEFAULT_ORBIT_YAW)


## Re-fit the Globe (double-click on empty sky).
func refit_globe() -> void:
	if not _globe:
		return
	_frame_globe()
	_camera_dirty = true
	_update_camera()
	_request_viewport_refresh()
	_notify_canvas_redraw()


## World effects the Globe lens owns while it is on: the rim sun (shared with
## the full-screen globe via SoiService) and long shadows — the sun's shadow
## range is tuned for first person, so at globe distance buildings lost their
## shadows. A camera-LESS camera claim: value_or() falls through to whatever
## camera is below it, so this only lengthens the shadows. Idempotent.
func _sync_globe_world_effects(on: bool) -> void:
	if on == _globe_claims_held:
		return
	_globe_claims_held = on
	var soi := _soi()
	if soi != null:
		if on and soi.has_method("acquire_rim_sun"):
			soi.call("acquire_rim_sun", GLOBE_RIM_SUN_OWNER)
		elif not on and soi.has_method("release_rim_sun"):
			soi.call("release_rim_sun", GLOBE_RIM_SUN_OWNER)
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null:
		return
	if on and main.has_method("push_camera_claim"):
		var r := float(soi.call("radius_m")) if soi != null and soi.has_method("radius_m") else 150.0
		main.call("push_camera_claim", GLOBE_SHADOW_CLAIM, {"shadow_max_distance": r * 6.0})
	elif not on and main.has_method("pop_camera_claim"):
		main.call("pop_camera_claim", GLOBE_SHADOW_CLAIM)


## Glass fades out toward the horizon (no Fresnel bullseye over the sky) and in
## as the view rises — the full-screen globe's rule (SoiOrbitMath).
func _sync_globe_glass() -> void:
	if not _globe:
		return
	var soi := _soi()
	if soi != null and soi.has_method("set_snowglobe_glass_opacity"):
		soi.call("set_snowglobe_glass_opacity", SoiOrbitMath.glass_opacity_for_pitch(_pitch))


## Project a world position to canvas-local pixels. Returns Vector2 or null.
func world_to_canvas(world: Vector3) -> Variant:
	var host_local: Variant = world_to_host_local(world)
	if host_local == null:
		return null
	if _canvas == null or not is_instance_valid(_canvas) or _container == null:
		return null
	return (_container.position + (host_local as Vector2)) - _canvas.position


## Project a world position into the SubViewportContainer's local pixels
## (works for Elev canvas host and Siphon Lab embed).
func world_to_host_local(world: Vector3) -> Variant:
	if not is_projection_authority():
		return null
	if _camera == null or not is_instance_valid(_camera):
		return null
	if _camera.is_position_behind(world):
		return null
	var vp_size := Vector2(_viewport.size)
	if vp_size.x < 1.0 or vp_size.y < 1.0:
		return null
	var cont_size := _container.size
	if cont_size.x < 1.0 or cont_size.y < 1.0:
		return null
	var vp := _camera.unproject_position(world)
	return (vp / vp_size) * cont_size


## Host-local point (SubViewportContainer coords) → world ray.
## Use this from Hydro Lab's preview stack (embed host). Elev canvas callers
## can keep using canvas_ray().
func host_ray(host_local_pos: Vector2) -> Variant:
	if not active or _camera == null or not is_instance_valid(_camera) \
			or _container == null or not is_instance_valid(_container):
		return null
	var cont_size := _container.size
	if cont_size.x < 1.0 or cont_size.y < 1.0:
		return null
	var frac := host_local_pos / cont_size
	var vp := frac * Vector2(_viewport.size)
	return {
		"origin": _camera.project_ray_origin(vp),
		"normal": _camera.project_ray_normal(vp),
	}


## Canvas-local point → world ray `{origin, normal}` via the preview camera.
## When the SubViewport is embedded in Hydro Lab, `canvas_pos` is treated as
## host-local (preview-stack coords) so Lab picks match the CT.
func canvas_ray(canvas_pos: Vector2) -> Variant:
	if _embed_host != null and is_instance_valid(_embed_host):
		return host_ray(canvas_pos)
	if not is_projection_authority():
		return null
	if _camera == null or not is_instance_valid(_camera) or _container == null \
			or _canvas == null:
		return null
	var cont_size := _container.size
	if cont_size.x < 1.0 or cont_size.y < 1.0:
		return null
	var host_pos := canvas_pos + _canvas.position
	var frac := (host_pos - _container.position) / cont_size
	var vp := frac * Vector2(_viewport.size)
	return {
		"origin": _camera.project_ray_origin(vp),
		"normal": _camera.project_ray_normal(vp),
	}


## Intersect the ray through a canvas-local point with an arbitrary world plane.
func canvas_to_world_on_plane(canvas_pos: Vector2, plane_point: Vector3,
		plane_normal: Vector3) -> Variant:
	var ray: Variant = canvas_ray(canvas_pos)
	if not (ray is Dictionary):
		return null
	var ro: Vector3 = (ray as Dictionary).get("origin", Vector3.ZERO)
	var rn: Vector3 = (ray as Dictionary).get("normal", Vector3.FORWARD)
	var denom := rn.dot(plane_normal)
	if absf(denom) < 1e-6:
		return null
	var t := (plane_point - ro).dot(plane_normal) / denom
	return ro + rn * t


## Canvas point → SoI-relative ground site metres (Vector2 site_x/site_z) or null.
func canvas_to_site_ground(canvas_pos: Vector2) -> Variant:
	var soi := _soi()
	if soi == null or not soi.has_method("world_center"):
		return null
	var c: Vector3 = soi.call("world_center") as Vector3
	# Perspective: a plane at the centre's height is off by the parallax of
	# the ground's relief — use the plane through the focus first, then walk
	# the ray onto the real ground.
	var plane_y := _cam_look.y if _top_down else c.y
	var hit: Variant = canvas_to_world_on_plane(canvas_pos, Vector3(c.x, plane_y, c.z), Vector3.UP)
	if not (hit is Vector3):
		return null
	var h: Vector3 = hit as Vector3
	var ray: Variant = canvas_ray(canvas_pos)
	if ray is Dictionary and soi.has_method("ground_y_at"):
		var ro: Vector3 = (ray as Dictionary).get("origin", Vector3.ZERO)
		var rn: Vector3 = (ray as Dictionary).get("normal", Vector3.FORWARD)
		var t := (h - ro).length()
		for _i in 6:
			var p := ro + rn * t
			var gy := float(soi.call("ground_y_at", p.x, p.z))
			if not is_finite(gy) or absf(rn.y) < 1e-4:
				break
			t += (p.y - gy) / -rn.y
		var g := ro + rn * t
		if is_finite(g.x):
			h = g
	return Vector2(h.x - c.x, h.z - c.z)


## Canvas point → hit on the vertical elevation section plane.
## Returns `{site_x_m, site_z_m, elevation_m}` or null. Plane is offset along
## the cross-axis by `_section_offset_m` (CT slice depth).
func canvas_to_elevation_hit(canvas_pos: Vector2, heading_rad: float) -> Variant:
	var soi := _soi()
	if soi == null or not soi.has_method("world_center"):
		return null
	var c: Vector3 = soi.call("world_center") as Vector3
	# Section plane normal = cross-section direction in world XZ.
	var cross := Vector2(-sin(heading_rad), cos(heading_rad))
	var plane_n := Vector3(cross.x, 0.0, cross.y)
	var plane_o := c + Vector3(cross.x, 0.0, cross.y) * _section_offset_m
	var hit: Variant = canvas_to_world_on_plane(canvas_pos, plane_o, plane_n)
	if not (hit is Vector3):
		return null
	var h: Vector3 = hit as Vector3
	return {
		"site_x_m": h.x - c.x,
		"site_z_m": h.z - c.z,
		"elevation_m": h.y,
	}


func get_phys_cam_state() -> Dictionary:
	return {"yaw": _phys_yaw, "pitch": _phys_pitch}


func apply_phys_cam_state(state: Dictionary) -> void:
	_phys_yaw = float(state.get("yaw", 0.0))
	_phys_pitch = float(state.get("pitch", 0.0))
	_camera_dirty = true
	if active:
		_update_camera()
		_request_viewport_refresh()
		_notify_canvas_redraw()


func reset_phys_orbit() -> void:
	if is_zero_approx(_phys_yaw) and is_zero_approx(_phys_pitch):
		return
	_phys_yaw = 0.0
	_phys_pitch = 0.0
	_camera_dirty = true
	if active:
		_update_camera()
		_request_viewport_refresh()
		_notify_canvas_redraw()


func apply_zoom_step(zoom_in: bool) -> void:
	# Site Plan and the section zoom with the canvas (GraphElevFrame) — the
	# old separate section ortho zoom was overwritten by the anchors anyway.
	if not active or _top_down or _section_mode:
		return
	var factor2 := 1.0 - ZOOM_STEP if zoom_in else 1.0 + ZOOM_STEP
	var min_mult := GLOBE_MIN_ORBIT_MULT if _globe else MIN_ORBIT_MULT
	_orbit_mult_target = clampf(_orbit_mult_target * factor2, min_mult, MAX_ORBIT_MULT)
	_camera_dirty = true
	_request_viewport_refresh()


## CT slice depth along the cross-axis (−radius…+radius). Moves camera target,
## hit plane, and shader half-plane together.
func set_section_offset(offset_m: float) -> void:
	var soi := _soi()
	var r := 150.0
	if soi != null and soi.has_method("radius_m"):
		r = float(soi.call("radius_m"))
	_section_offset_m = clampf(offset_m, -r, r)
	_camera_dirty = true
	if active and _section_mode:
		_update_camera()
		_push_section_cutaway()
		_request_viewport_refresh()
		_notify_canvas_redraw()


func get_section_offset() -> float:
	return _section_offset_m


## Reset CT section: offset 0, pitch locked, optional heading.
func reset_section(heading_rad: float = NAN) -> void:
	_section_offset_m = 0.0
	_phys_pitch = 0.0
	if not is_nan(heading_rad):
		_section_heading = fposmod(heading_rad, TAU)
	_camera_dirty = true
	if active and _section_mode:
		_update_camera()
		_push_section_cutaway()
		_request_viewport_refresh()
		_notify_canvas_redraw()


## Orthographic north-up top-down for Site Plan (screen up = −Z / north).
func set_top_down(on: bool) -> void:
	_top_down = on
	if on and _section_mode:
		_section_mode = false
		_clear_section_cutaway()
	if on and _globe:
		set_globe(false)
	_apply_preview_shell_visuals()
	_sync_moon_boost()
	_apply_viewport_msaa()
	if _camera != null:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_sync_lens_shadow_claim()
	_layout_dirty = true
	_camera_dirty = true
	_update_camera()
	_request_viewport_refresh()


## Orthographic vertical cross-section of the snowglobe (Elevation 3D option).
func set_section_mode(on: bool) -> void:
	_section_mode = on
	if on:
		_top_down = false
		_phys_pitch = 0.0
		if _globe:
			set_globe(false)
	_apply_preview_shell_visuals()
	_apply_viewport_msaa()
	_apply_section_environment()
	if _camera != null:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_sync_lens_shadow_claim()
	_layout_dirty = true
	_camera_dirty = true
	_update_camera()
	if on and active:
		_push_section_cutaway()
		_apply_hydroturbine_section_clip(true)
		_ensure_section_soil_visible()
	elif not on:
		_clear_section_cutaway()
		_apply_hydroturbine_section_clip(false)
	_request_viewport_refresh()


## Slice placed hydroturbine GLBs with the CT midplane so Lab/Elev show the
## internal prop (SoiSectionMeshClip). Restores materials when leaving section.
func _apply_hydroturbine_section_clip(on: bool) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main == null:
		return
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return
	var root := terrain.get_node_or_null("PlacedProps")
	if root == null:
		return
	for child in root.get_children():
		if not (child is PlacedProp):
			continue
		var prop := child as PlacedProp
		# Every hydro turbine model midplane-slices with the Elevation / Hydro
		# Lab cut, not just the original siphon one.
		if not ModelCatalog.is_hydro_turbine(str(prop.model_id)):
			continue
		if on:
			SoiSectionMeshClip.apply_to_node(prop)
		else:
			SoiSectionMeshClip.clear_from_node(prop)


## Show opaque soil bowl in section — do NOT rebuild the sphere mesh here
## (refresh_footing is expensive and was hanging load when SoI sync re-entered).
func _ensure_section_soil_visible() -> void:
	var soi := _soi()
	if soi == null:
		return
	if soi.has_method("set_graph_preview_shell_visible"):
		soi.call("set_graph_preview_shell_visible", true)
	if soi.has_method("set_graph_preview_glass_enabled"):
		soi.call("set_graph_preview_glass_enabled", false)


func set_section_heading(heading_rad: float) -> void:
	_section_heading = fposmod(heading_rad, TAU)
	if active and _section_mode:
		_camera_dirty = true
		_update_camera()
		_push_section_cutaway()
		_request_viewport_refresh()


## Clock-driven capture policy. The preview holds a still frame between
## captures (re-rendering the shared World3D every frame was this view's main
## cost and an AMD TDR trigger on G open), so time has to ASK for a frame:
##   - scrubbing (clock paused, playhead moved): capture promptly, capped;
##   - playing: capture once the sun has visibly moved (or every few seconds,
##     for clouds/weather), capped lower;
##   - paused and idle: nothing.
## One capture in flight at a time, never during soft boot or while hidden.
## Replaces the Site Plan's private 5 s timer and covers every lens + the
## Hydro Lab CT (whose host graph _process returns early).
func _clock_refresh_due() -> bool:
	if _render_in_flight or _soft_boot_frames > 0:
		return false
	if _container == null or not _container.visible:
		return false
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null or not main.has_method("get_absolute_hours"):
		return false
	var abs_h := float(main.call("get_absolute_hours"))
	if is_nan(_clock_render_abs_h):
		return false
	var dh := absf(abs_h - _clock_render_abs_h)
	if dh < 1e-7:
		return false
	var now_ms := Time.get_ticks_msec()
	var since_ms := now_ms - _clock_render_ms
	var heavy := _section_mode or _top_down_cropped \
			or (_embed_host != null and is_instance_valid(_embed_host)) \
			or (_viewport != null and maxi(_viewport.size.x, _viewport.size.y) > 1500)
	var ts := float(main.get("time_scale")) if main.get("time_scale") != null else 0.0
	if ts <= 0.0:
		# Scrub (or a jump while paused): show it promptly.
		var scrub_hz := CLOCK_SCRUB_HZ_HEAVY if heavy else CLOCK_SCRUB_HZ
		return since_ms >= int(1000.0 / scrub_hz)
	var play_hz := CLOCK_PLAY_HZ_HEAVY if heavy else CLOCK_PLAY_HZ
	if since_ms < int(1000.0 / play_hz):
		return false
	if since_ms >= CLOCK_IDLE_MS:
		return true
	var sun_dir := _sun_dir()
	if sun_dir == Vector3.ZERO or _clock_render_sun == Vector3.ZERO:
		return true
	var ang := rad_to_deg(sun_dir.angle_to(_clock_render_sun))
	return ang >= CLOCK_SUN_STEP_DEG or dh >= CLOCK_HOURS_STEP


func _sun_dir() -> Vector3:
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null:
		return Vector3.ZERO
	var sun := main.get("sun") as DirectionalLight3D
	if sun == null or not is_instance_valid(sun):
		return Vector3.ZERO
	return sun.global_transform.basis.z.normalized()


func _note_clock_capture() -> void:
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main != null and main.has_method("get_absolute_hours"):
		_clock_render_abs_h = float(main.call("get_absolute_hours"))
	_clock_render_sun = _sun_dir()
	_clock_render_ms = Time.get_ticks_msec()


func _on_capture_drawn() -> void:
	_render_in_flight = false
	frames_rendered += 1


func _request_viewport_refresh() -> void:
	if _viewport == null or not active:
		return
	if _soft_boot_frames > 0:
		return
	if _viewport_too_small():
		# Laid out from a hidden (0-size) canvas: re-lay out next frame instead
		# (while still hidden, the reveal handler re-arms it).
		if _container != null and is_instance_valid(_container) and _container.is_visible_in_tree():
			_layout_dirty = true
		return
	# Every capture renders with the world's CURRENT sky/fog/ambient — the
	# lens environment is a shallow copy re-synced here, never a frozen one.
	_sync_lens_env()
	_sync_section_backdrop()
	_note_clock_capture()
	if not _render_in_flight:
		_render_in_flight = true
		RenderingServer.frame_post_draw.connect(_on_capture_drawn, CONNECT_ONE_SHOT)
	# Dirty-driven: one frame now; _process re-arms on orbit/layout/clock.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# First real capture just got scheduled — reveal the disc only once this
	# frame has actually drawn (see _first_frame_pending).
	if _first_frame_pending and not _first_frame_hooked:
		_first_frame_hooked = true
		RenderingServer.frame_post_draw.connect(_on_first_preview_frame, CONNECT_ONE_SHOT)


## Runs on frame_post_draw of the first scheduled capture: the SubViewport's
## image now exists, so terrain visibility (soi_live_preview → the SoI hole)
## and camera projection authority flip in the SAME frame — no black disc, no
## chips jumping to a camera pose that has no picture yet.
func _on_first_preview_frame() -> void:
	_first_frame_hooked = false
	if not active or not _first_frame_pending:
		return
	if _soft_boot_frames > 0:
		# Stale hook from a rapid deactivate/reactivate — the real first capture
		# hasn't been scheduled yet; leave pending set so it re-hooks then.
		return
	_first_frame_pending = false
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.set("soi_live_preview", true)
		if _canvas.has_method("begin_soi_reveal"):
			_canvas.call("begin_soi_reveal")
		_canvas.queue_redraw()


## Public one-shot re-capture. Callers that mutate the shared World3D directly (e.g.
## a Site Plan spatial-edit prop drag or a hover-highlight change) use this so the
## disc reflects the change live instead of holding a stale frame until the next
## layout/camera dirty (which is why a dragged prop used to only "jump" on zoom).
func request_refresh() -> void:
	_request_viewport_refresh()


func _apply_lite_camera() -> void:
	if _camera == null:
		return
	_saved_shadows = int(_camera.attributes != null)
	_camera.fov = 68.0
	# Preview camera: no directional shadows (cheap fill light from environment).
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT


func _restore_lite_camera() -> void:
	_saved_shadows = -1


func _apply_preview_shell_visuals() -> void:
	var soi := _soi()
	if soi == null:
		return
	# Top-down Site Plan: keep the SOIL BOWL so an orbited/tilted view shows a
	# solid tan underside instead of a hollow rim, but not the glass dome
	# (glass from above = black disc) and not the water-cycle-diagram cutaway
	# (veins/aquifer belong to Elevation/Snowglobe) — plain_soil paints it the
	# flat ground tan instead.
	# Elevation section: soil bowl + diagram, kill glass — Fresnel on the dome
	# from the side paints the concentric "bullseye" over the sky.
	# Freeform orbit: full glass snowglobe.
	if soi.has_method("set_graph_preview_shell_visible"):
		soi.call("set_graph_preview_shell_visible", true)
	if soi.has_method("set_graph_preview_glass_enabled"):
		soi.call("set_graph_preview_glass_enabled", not _top_down and not _section_mode)
	if soi.has_method("set_graph_preview_plain_soil"):
		soi.call("set_graph_preview_plain_soil", _top_down)
	_sync_globe_glass()
	_apply_viewport_background()


## Push/restore the moon boost while the top-down plan is live. Idempotent and
## restore-on-every-exit-path (set_active(false), leaving top-down): the boost
## lives on Main because _update_moon owns the light.
func _sync_moon_boost() -> void:
	var want := active and _top_down
	if want == _moon_boost_applied:
		return
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null or main.get("moon_light_boost") == null:
		return
	main.set("moon_light_boost", MOON_BOOST if want else 1.0)
	_moon_boost_applied = want


func _apply_viewport_background() -> void:
	if _viewport == null:
		return
	# transparent_bg skips Environment sky clear — fine for terrain-fill Site
	# Plan, wrong for Elevation where the upper disc is empty air.
	# Section + Globe need an opaque clear so the Environment sky fills empty
	# air; other modes keep transparency so the graph shows at soft edges.
	_viewport.transparent_bg = not _globe
	_bind_world()
	# Mode changed — re-resolve which per-camera environment applies.
	_apply_section_environment()


func _apply_top_down_visuals() -> void:
	_apply_preview_shell_visuals()


func _process(delta: float) -> void:
	if not active:
		return
	var soi := _soi()
	if soi != null and bool(soi.get("snowglobe_active")):
		# Full-screen snowglobe owns the camera / clip — hide preview.
		_set_visible(false)
		return
	_set_visible(true)
	# Re-bind if the root World3D wasn't ready at activate time.
	if _viewport != null and _viewport.world_3d == null:
		_bind_world()
	if _tween_active:
		_process_tween()
		return
	# Smooth freeform zoom toward target.
	if not _top_down and not _section_mode \
			and not is_equal_approx(_orbit_mult, _orbit_mult_target):
		var t := clampf(delta * ZOOM_SMOOTH, 0.0, 1.0)
		_orbit_mult = lerpf(_orbit_mult, _orbit_mult_target, t)
		_camera_dirty = true
	var need_layout := _layout_dirty or _layout_changed()
	if need_layout:
		_sync_layout()
		_camera_dirty = true
	if _camera_dirty or need_layout:
		_update_camera()
		_camera_dirty = false
		# Soft boot: settle layout before the first expensive World3D capture.
		if _soft_boot_frames > 0:
			_soft_boot_frames -= 1
			if _soft_boot_frames == 0:
				_request_viewport_refresh()
		else:
			_request_viewport_refresh()
		# Elev/Siphon CT: keep 2D pond/DEM overlays on the live camera frustum;
		# Globe: keep the pins on their anchors while the zoom eases.
		if _section_mode or _globe:
			_notify_canvas_redraw()
	elif _soft_boot_frames > 0:
		_soft_boot_frames -= 1
		if _soft_boot_frames == 0:
			_request_viewport_refresh()
	elif _preview_live:
		# Tutorial tier: a steady idle re-render regardless of the clock. Cropped
		# high-zoom path refreshes slower — giant world into a small viewport is
		# still expensive.
		_refresh_acc += delta
		var hz := IDLE_REFRESH_HZ_CROPPED if _top_down_cropped or _section_mode \
				else IDLE_REFRESH_HZ
		if _refresh_acc >= 1.0 / hz:
			_refresh_acc = 0.0
			_request_viewport_refresh()
	elif _clock_refresh_due():
		_request_viewport_refresh()


## Toggle live-lit preview (sun/sky updates while idle). Default off: the preview
## is otherwise captured on view changes only. Re-arms an immediate refresh.
func set_preview_live(on: bool) -> void:
	_preview_live = on
	if on and active:
		_request_viewport_refresh()


func _ensure_nodes() -> void:
	if _host == null:
		return
	if _container != null and is_instance_valid(_container):
		return
	_container = SubViewportContainer.new()
	_container.name = "GraphSoiPreview"
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.stretch = true
	_container.clip_contents = false
	_disc_material = ShaderMaterial.new()
	_disc_material.shader = load("res://system_graph/graph_soi_preview_disc.gdshader")
	_container.material = _disc_material
	# DEFERRED: the signal fires from CanvasItem's half of the notification,
	# BEFORE SubViewportContainer's half sets the mode (base class first).
	_container.visibility_changed.connect(_on_container_visibility_changed, CONNECT_DEFERRED)
	# Insert under the graph canvas so nodes/wires draw on top.
	var insert_at := 1
	if _canvas != null and is_instance_valid(_canvas):
		insert_at = maxi(_canvas.get_index(), 1)
	_host.add_child(_container)
	_host.move_child(_container, insert_at)

	_viewport = SubViewport.new()
	_viewport.name = "SoiPreviewViewport"
	_viewport.disable_3d = false
	_viewport.own_world_3d = false
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	# Born DISABLED: activation (soft boot) and set_embed_visible choose the
	# mode once the layout has sized it. Born WHEN_VISIBLE, a graph reopened
	# after a close rendered the fresh 2×2 placeholder for a dozen frames —
	# 200 "Too many mipmaps" / null scene-buffer errors per reopen (Mt Vernon).
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.msaa_3d = Viewport.MSAA_2X
	_container.add_child(_viewport)
	_apply_viewport_msaa()

	_camera = Camera3D.new()
	_camera.name = "SoiPreviewCamera"
	_camera.current = true
	_camera.fov = 70.0
	_camera.near = 0.5
	_camera.far = 8000.0
	# First-person-only furniture (POI name tags) stays out of the lenses.
	_camera.cull_mask = _camera.cull_mask & ~PoiRuntime.LABEL_RENDER_LAYER
	_viewport.add_child(_camera)


func _bind_world() -> void:
	if _viewport == null:
		return
	var tree := get_tree()
	if tree == null:
		return
	var root_vp := tree.root.get_viewport()
	if root_vp != null and root_vp.world_3d != null:
		_viewport.world_3d = root_vp.world_3d
	# Section mode needs an opaque clear so Environment sky fills empty air;
	# other modes keep transparency so the graph canvas shows at soft edges.
	# Section + Globe need an opaque clear so the Environment sky fills empty
	# air; other modes keep transparency so the graph shows at soft edges.
	_viewport.transparent_bg = not _globe
	_apply_section_environment()


## Per-lens camera Environment. Each lens owns ONE environment, built as a
## SHALLOW duplicate of the world's — so the Sky resource (and with it every
## sky-shader parameter main.gd animates) is SHARED and stays live — and then
## re-synced from the world on every capture (_sync_lens_env), so fog, ambient,
## tonemap and glow follow the clock too. The old deep duplicate(true) froze the
## sky colour, fog and ambient at the moment the lens opened, which is why the
## preview only caught up with a time change after G was closed and reopened.
## The shared world's environment is never written (mutating WorldEnvironment
## every frame fought main.gd and TDR'd GPUs).
func _apply_section_environment() -> void:
	if _camera == null:
		return
	var src_env := _world_env()
	if src_env == null:
		return
	var lens := _env_lens()
	if lens != _lens_env_key or _lens_env == null:
		_lens_env = src_env.duplicate(false) as Environment
		_lens_env_key = lens
	_sync_lens_env()
	_camera.environment = _lens_env


func _world_env() -> Environment:
	var tree := get_tree()
	if tree == null:
		return null
	var main := tree.current_scene
	if main == null:
		return null
	var we := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		return we.environment
	if main.get("environment") is WorldEnvironment:
		var we2: WorldEnvironment = main.get("environment") as WorldEnvironment
		if we2 != null:
			return we2.environment
	return null


## "plan" | "section" | "orbit" — the environment family for the active lens.
func _env_lens() -> String:
	if _section_mode:
		return "section"
	if _top_down:
		return "plan"
	return "orbit"


## Copy the time-varying fields main.gd writes into the world environment
## (_update_environment / _update_glow / _apply_tonemap_settings / the hazard
## applier), then lay this lens's overrides on top. Plain property copies —
## cheap enough to run on every capture.
func _sync_lens_env() -> void:
	var src := _world_env()
	var env := _lens_env
	if src == null or env == null:
		return
	env.sky = src.sky
	env.background_mode = src.background_mode
	env.background_energy_multiplier = src.background_energy_multiplier
	env.fog_enabled = src.fog_enabled
	env.fog_light_color = src.fog_light_color
	env.fog_light_energy = src.fog_light_energy
	env.fog_sun_scatter = src.fog_sun_scatter
	env.fog_density = src.fog_density
	env.fog_aerial_perspective = src.fog_aerial_perspective
	env.fog_depth_end = src.fog_depth_end
	env.fog_sky_affect = src.fog_sky_affect
	env.fog_height_density = src.fog_height_density
	env.ambient_light_source = src.ambient_light_source
	env.ambient_light_color = src.ambient_light_color
	env.ambient_light_energy = src.ambient_light_energy
	env.ambient_light_sky_contribution = src.ambient_light_sky_contribution
	env.tonemap_mode = src.tonemap_mode
	env.tonemap_exposure = src.tonemap_exposure
	env.tonemap_white = src.tonemap_white
	env.glow_enabled = src.glow_enabled
	env.glow_intensity = src.glow_intensity
	env.glow_hdr_threshold = src.glow_hdr_threshold
	# Volumetric fog in a preview capture is pure cost (and in a 60 m ortho
	# render, wrong); plain fog stays so weather/hazards still read.
	env.volumetric_fog_enabled = false
	var night := _night_amount()
	# The vegetation shaders darken by their own night signal and scale
	# every fill by (1 - night); the lens's ambient floor never reaches them,
	# so a canopy printed black over a readable globe at night. Hand them a
	# LIFTED night for as long as the lens is the only 3D on screen
	# (cleared in set_active(false)); by day it is the world's own value.
	var veg_sync: Node = get_tree().root.get_node_or_null("VegetationEnvironmentSync")
	if veg_sync != null and veg_sync.has_method("set_night_override"):
		var world_night := _vegetation_world_night()
		veg_sync.call("set_night_override", world_night * (1.0 - LENS_VEG_NIGHT_LIFT * night))
	match _lens_env_key:
		"plan":
			# Site Plan night floor: a shadowless COLOR ambient lifts the whole
			# disc to readable at night while staying dimmer than day, and the
			# boosted moon (see _sync_moon_boost) keeps casting real shadows on
			# top of it — so night reads as night, with moonshadows.
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.ambient_light_color = TOPDOWN_AMBIENT_COLOR
			env.ambient_light_energy = TOPDOWN_AMBIENT_ENERGY
		"section":
			# The CT is a diagram: no fog veil, no bloom, no SSR on the cut.
			env.fog_enabled = false
			env.glow_enabled = false
			env.glow_intensity = 0.0
			env.ssr_enabled = false
			if env.tonemap_mode == Environment.TONE_MAPPER_LINEAR:
				env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
			# The CT is a diagram: keep a fill-light floor BY DAY too. Side-on,
			# the landscape behind the cut is mostly slopes facing away from
			# the sun, and with a low world ambient (players run it as low as
			# 0.05) they rendered pitch black over the section's sky.
			_apply_night_floor(env, src, maxf(night, SECTION_DAY_FLOOR), SECTION_NIGHT_FLOOR_ENERGY)
		_:
			# The bubble / Globe is a diorama: a gentle fill by day too, so
			# shadowed roofs and canopy don't print as black blobs at low
			# world ambient; full floor after dark.
			_apply_night_floor(env, src, maxf(night, ORBIT_DAY_FLOOR), ORBIT_NIGHT_FLOOR_ENERGY)


## Readable-at-night floor that REPLACED the Elevation noon lock (which froze
## the clock and snapped it to midday). Godot mixes ambient_light_color with the
## sky by ambient_light_sky_contribution, so fading the contribution toward 0 as
## the night deepens hands the ambient over to the floor colour continuously —
## daytime is the world's own look, untouched. Only this camera sees it.
func _apply_night_floor(env: Environment, src: Environment, night: float,
		floor_energy: float) -> void:
	if night <= 0.001:
		return
	if env.ambient_light_source == Environment.AMBIENT_SOURCE_DISABLED \
			or env.ambient_light_source == Environment.AMBIENT_SOURCE_BG:
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_color = NIGHT_FLOOR_COLOR
	env.ambient_light_sky_contribution = src.ambient_light_sky_contribution * (1.0 - night)
	env.ambient_light_energy = lerpf(src.ambient_light_energy,
			maxf(src.ambient_light_energy, floor_energy), night)


## Section sky backdrop (graph_soi_preview_disc.gdshader): the section renders
## with a transparent clear and the disc shader paints the empty air with a
## poster sky. Colours follow the DaylightModel curve the world uses — deep
## blue by day, a warm horizon through twilight, navy at night — so playing or
## scrubbing time recolours the CT like everything else.
const SECTION_SKY_DAY_TOP := Color(0.30, 0.52, 0.84)
const SECTION_SKY_DAY_HORIZON := Color(0.76, 0.86, 0.95)
const SECTION_SKY_NIGHT_TOP := Color(0.012, 0.02, 0.05)
const SECTION_SKY_NIGHT_HORIZON := Color(0.05, 0.07, 0.13)
const SECTION_SKY_DUSK_HORIZON := Color(0.96, 0.56, 0.30)


func _sync_section_backdrop() -> void:
	var mat := _disc_material
	if mat == null or _container == null or _container.material != mat:
		return
	if not _section_mode:
		if _top_down and (_embed_host == null or not is_instance_valid(_embed_host)):
			_sync_plan_backdrop()
		else:
			mat.set_shader_parameter("backdrop_on", 0.0)
		return
	var sun_dir := _sun_dir()
	var sin_alt := clampf(sun_dir.y, -1.0, 1.0) if sun_dir != Vector3.ZERO else 0.5
	var day := smoothstep(0.0, 1.0, DaylightModel.sky_light(sin_alt))
	var top := SECTION_SKY_NIGHT_TOP.lerp(SECTION_SKY_DAY_TOP, day)
	var hor := SECTION_SKY_NIGHT_HORIZON.lerp(SECTION_SKY_DAY_HORIZON, day)
	# Warm band while the sun is near the horizon (on either side of it).
	var warm := DaylightModel.twilight_palette(sin_alt) \
			* (1.0 - smoothstep(0.0, 0.22, absf(sin_alt)))
	hor = hor.lerp(SECTION_SKY_DUSK_HORIZON, clampf(warm, 0.0, 1.0) * 0.75)
	mat.set_shader_parameter("backdrop_on", 1.0)
	mat.set_shader_parameter("backdrop_top", top)
	mat.set_shader_parameter("backdrop_horizon", hor)
	# Horizon line = the SoI ground level, through the section camera.
	var hy := 0.6
	var soi := _soi()
	if soi != null and _camera != null and _viewport != null and soi.has_method("world_center"):
		var c: Vector3 = soi.call("world_center") as Vector3
		var look := _camera.global_position - _camera.global_transform.basis.z * 10.0
		var px := _camera.unproject_position(Vector3(look.x, c.y, look.z))
		if _viewport.size.y > 0:
			hy = clampf(px.y / float(_viewport.size.y), 0.0, 1.0)
	mat.set_shader_parameter("backdrop_horizon_y", hy)


## Site Plan backdrop: the viewport is transparent outside the SoI sphere's
## clip, and the container now covers the canvas, so the air round the plan is
## painted the canvas colour by the same backdrop block the section uses (a
## flat colour: every band the same, the horizon at the top).
func _sync_plan_backdrop() -> void:
	var mat := _disc_material
	if mat == null:
		return
	var bg := PLAN_BACKDROP_COLOR
	if _canvas != null and is_instance_valid(_canvas) and _canvas.get("C_CANVAS_BG") is Color:
		var c: Color = _canvas.get("C_CANVAS_BG")
		bg = Color(c.r, c.g, c.b, 1.0)
	mat.set_shader_parameter("backdrop_on", 1.0)
	mat.set_shader_parameter("backdrop_top", bg)
	mat.set_shader_parameter("backdrop_horizon", bg)
	mat.set_shader_parameter("backdrop_ground", bg)
	mat.set_shader_parameter("backdrop_ground_deep", bg)
	mat.set_shader_parameter("backdrop_horizon_y", 0.02)


## 0 by day → 1 in full night, on the same DaylightModel curve the world uses.
func _night_amount() -> float:
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null:
		return 0.0
	var sun := main.get("sun") as DirectionalLight3D
	if sun == null or not is_instance_valid(sun):
		return 0.0
	var sin_alt := clampf(sun.global_transform.basis.z.normalized().y, -1.0, 1.0)
	return clampf(DaylightModel.night_amount(sin_alt), 0.0, 1.0)


func _apply_soi_visuals(on: bool) -> void:
	var soi := _soi()
	if soi == null:
		_clip_owned = false
		return
	if on:
		if bool(soi.get("snowglobe_active")):
			_clip_owned = false
			return
		if soi.has_method("set_graph_preview_active"):
			soi.call("set_graph_preview_active", true)
		else:
			# Fallback if SoiService hasn't been updated yet.
			if soi.has_method("set_clip_enabled"):
				soi.call("set_clip_enabled", true)
		_clip_owned = true
		if _section_mode:
			_push_section_cutaway()
	else:
		_clear_section_cutaway()
		if _clip_owned and soi.has_method("set_graph_preview_active"):
			soi.call("set_graph_preview_active", false)
		elif _clip_owned and soi.has_method("set_clip_enabled") \
				and not bool(soi.get("snowglobe_active")):
			soi.call("set_clip_enabled", false)
		_clip_owned = false


func _set_visible(on: bool) -> void:
	if _container != null and is_instance_valid(_container):
		_container.visible = on


func _layout_changed() -> bool:
	if _embed_host != null and is_instance_valid(_embed_host):
		var ek := "embed|%s|%s|%.3f|%.2f|%.2f|%.2f" % [
			str(_embed_host.size), str(_section_mode), _section_heading,
			_lab_along_m if not is_nan(_lab_along_m) else 0.0,
			_lab_elev_m if not is_nan(_lab_elev_m) else 0.0,
			_lab_ortho_h_m if not is_nan(_lab_ortho_h_m) else 0.0]
		return ek != _last_layout_key
	if _canvas == null or not is_instance_valid(_canvas):
		return false
	return _canvas_layout_key() != _last_layout_key


## The canvas-driven layout signature: _sync_layout stores it, _layout_changed
## compares against it. ONE function so the two can never format it differently
## (a mismatch re-lays-out — and re-renders the shared world — every frame).
func _canvas_layout_key() -> String:
	var disc := _read_disc()
	var elev_along := 0.0
	var elev_elev := 0.0
	var canvas_zoom := 1.0
	if _canvas.has_method("get_elev_anchor_along_m"):
		elev_along = float(_canvas.call("get_elev_anchor_along_m"))
	if _canvas.has_method("get_elev_anchor_elev_m"):
		elev_elev = float(_canvas.call("get_elev_anchor_elev_m"))
	if _canvas.has_method("get_view_zoom"):
		canvas_zoom = float(_canvas.call("get_view_zoom"))
	var key := "%s|%s|%.4f|%.2f|%.2f|%s|%s%s|%.3f|%.2f|%.3f|%.2f|%.2f" % [
		str(_canvas.position),
		str(_canvas.size),
		float(disc.get("radius_px", 0.0)),
		float((disc.get("origin", Vector2.ZERO) as Vector2).x),
		float((disc.get("origin", Vector2.ZERO) as Vector2).y),
		str(_top_down),
		str(_section_mode),
		"G" if _globe else "",
		_section_heading,
		_section_offset_m,
		canvas_zoom,
		elev_along,
		elev_elev,
	]
	return key


func _read_disc() -> Dictionary:
	if _canvas != null and _canvas.has_method("get_soi_disc_layout"):
		return _canvas.call("get_soi_disc_layout") as Dictionary
	# Fallback if canvas helpers aren't available yet.
	var zoom := 1.0
	var pan := Vector2.ZERO
	if _canvas != null:
		if _canvas.has_method("get_view_zoom"):
			zoom = float(_canvas.call("get_view_zoom"))
		if _canvas.has_method("get_view_pan"):
			pan = _canvas.call("get_view_pan") as Vector2
	var r_m := 150.0
	var soi := _soi()
	if soi != null and soi.has_method("radius_m"):
		r_m = float(soi.call("radius_m"))
	var r_px := r_m * SOI_PX_PER_M * zoom
	var origin := (_canvas.size if _canvas != null else Vector2.ZERO) * 0.5 + pan
	return {"origin": origin, "radius_px": r_px, "radius_m": r_m}


func _set_disc_mask(pixel_mode: bool, center_px: Vector2 = Vector2.ZERO,
		radius_px: float = 1.0, container_size: Vector2 = Vector2.ONE) -> void:
	if _container == null:
		return
	var mat := _container.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("use_mask", 1)
	mat.set_shader_parameter("use_pixel_disc", 1 if pixel_mode else 0)
	mat.set_shader_parameter("disc_center_px", center_px)
	mat.set_shader_parameter("disc_radius_px", radius_px)
	mat.set_shader_parameter("container_size_px", container_size)


func _viewport_px_cap() -> float:
	return float(MAX_SECTION_VIEWPORT_PX if _section_mode else MAX_VIEWPORT_PX)


## SubViewport resolution that fits within `cap` while PRESERVING the container's
## aspect ratio. Clamping each axis independently (the old behavior) broke the
## camera-vs-container aspect once the canvas exceeded the cap on one axis, so
## world_to_host_local scaled X wrong and the whole top-down disc — terrain and 2D
## chips together — shifted sideways past the crop-zoom threshold. Scaling both axes
## by one factor keeps px-per-metre equal on both axes.
func _aspect_clamped_viewport_size(container_size: Vector2, cap: float) -> Vector2i:
	var w := maxf(container_size.x, 1.0)
	var h := maxf(container_size.y, 1.0)
	var longest := maxf(w, h)
	var scale := 1.0
	if longest > cap:
		scale = cap / longest
	var rx := int(round(maxf(w * scale, float(MIN_VIEWPORT_PX))))
	var ry := int(round(maxf(h * scale, float(MIN_VIEWPORT_PX))))
	return Vector2i(maxi(rx, 1), maxi(ry, 1))


func _sync_layout() -> void:
	_layout_dirty = false
	if _container == null:
		return
	var vp_cap := _viewport_px_cap()
	# Siphon Lab (or other embed): fill the host Control; no disc mask —
	# rectangular CT matching the Lab panel (Elev disc mask looks like a
	# different snowglobe UI when nested in the Lab card).
	if _embed_host != null and is_instance_valid(_embed_host):
		_top_down_cropped = true
		# The disc material without its mask: the Lab CT is a rectangle, but it
		# still wants the section's time-of-day sky backdrop.
		_container.material = _disc_material
		if _disc_material != null:
			_disc_material.set_shader_parameter("use_mask", 0)
		_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_container.position = Vector2.ZERO
		_container.size = _embed_host.size
		if _viewport != null:
			# Aspect-preserving clamp (same reason as the crop branch below).
			_viewport.size = _aspect_clamped_viewport_size(_container.size, vp_cap)
		_apply_viewport_msaa()
		_apply_section_environment()
		# The SAME format _layout_changed compares against — the two used to
		# differ, so the Lab re-laid-out, re-posed and re-captured every frame.
		_last_layout_key = "embed|%s|%s|%.3f|%.2f|%.2f|%.2f" % [
			str(_embed_host.size), str(_section_mode), _section_heading,
			_lab_along_m if not is_nan(_lab_along_m) else 0.0,
			_lab_elev_m if not is_nan(_lab_elev_m) else 0.0,
			_lab_ortho_h_m if not is_nan(_lab_ortho_h_m) else 0.0]
		return
	if _canvas == null or not is_instance_valid(_canvas):
		return
	if _globe:
		# Globe: the whole canvas, no disc mask — the sphere floats in its own
		# sky, like the full-screen globe.
		_top_down_cropped = false
		_container.material = null
		_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_container.position = _canvas.position
		_container.size = _canvas.size
		if _viewport != null:
			_viewport.size = _aspect_clamped_viewport_size(_container.size,
					float(MAX_SECTION_VIEWPORT_PX))
		_apply_viewport_msaa()
		_last_layout_key = _canvas_layout_key()
		return
	if _section_mode:
		# Elevation section: the WHOLE canvas, no disc mask. The circular lens
		# added nothing conceptually here — the cut is a side-on drawing, and
		# the circle only hid the panel's corners — so the section is a full
		# window like the Hydro Lab embed: the cut sphere with the poster sky
		# painted around it by the disc material (`use_mask` 0 keeps the
		# backdrop, drops the circle). The 3D clip to the SoI sphere is
		# unchanged; what the circle used to cover is sky, not world.
		# `_top_down_cropped` stays true so the camera looks at the point under
		# the canvas centre (the metre anchor) exactly as the crop branch did,
		# and `_want_crop` agrees so a wheel notch never re-lays-out.
		_top_down_cropped = true
		_container.material = _disc_material
		if _disc_material != null:
			_disc_material.set_shader_parameter("use_mask", 0)
		_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_container.position = _canvas.position
		_container.size = _canvas.size
		if _viewport != null:
			_viewport.size = _aspect_clamped_viewport_size(_container.size, vp_cap)
		_apply_viewport_msaa()
		_apply_section_environment()
		_last_layout_key = _canvas_layout_key()
		return
	if _top_down:
		# Site Plan: the WHOLE canvas, no disc mask (2026-10-12). The plan is a
		# map; the circle only hid the panel's corners, and its crop / no-crop
		# hysteresis re-laid-out the viewport (new size, mask mode, camera
		# frame) exactly at the zoom where the disc outgrew the window — the
		# "zoom jumps" the player hit while placing the outlet. The 3D clip to
		# the SoI sphere is unchanged: outside it the viewport is transparent
		# and the disc material paints the canvas colour (`_sync_plan_backdrop`).
		# `_top_down_cropped` stays true so the camera frames the point under
		# the canvas centre at 4 px/m × zoom, as the crop branch always did,
		# and `_want_crop` agrees so a wheel notch never re-lays-out.
		_top_down_cropped = true
		_container.material = _disc_material
		if _disc_material != null:
			_disc_material.set_shader_parameter("use_mask", 0)
		_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_container.position = _canvas.position
		_container.size = _canvas.size
		if _viewport != null:
			_viewport.size = _aspect_clamped_viewport_size(_container.size, vp_cap)
		_apply_viewport_msaa()
		_sync_plan_backdrop()
		_last_layout_key = _canvas_layout_key()
		return
	# Restore free anchors + disc mask when leaving embed.
	if _disc_material != null and _container.material != _disc_material:
		_container.material = _disc_material
	_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var disc := _read_disc()
	var origin: Vector2 = disc.get("origin", Vector2.ZERO)
	var r_px: float = maxf(float(disc.get("radius_px", 0.0)), 1.0)
	var place_d := r_px * 2.0
	# Site Plan AND Elevation section: never grow SubViewportContainer to
	# hundreds of thousands of pixels at high 2D zoom (GPU/compositor stall).
	# _want_crop reads _top_down_cropped for its hysteresis, so decide BEFORE
	# the reset below.
	var want_crop := _want_crop(place_d)
	_top_down_cropped = false
	if want_crop:
		_top_down_cropped = true
		var csz := _canvas.size
		# Hard safety — never allocate a Control larger than the canvas.
		if csz.x > MAX_DISC_CONTAINER_PX * 2.0 or csz.y > MAX_DISC_CONTAINER_PX * 2.0:
			_container.size = Vector2(minf(csz.x, MAX_DISC_CONTAINER_PX),
					minf(csz.y, MAX_DISC_CONTAINER_PX))
		else:
			_container.size = csz
		_container.position = _canvas.position
		_set_disc_mask(true, origin, r_px, _container.size)
		if _viewport != null:
			# Aspect-preserving clamp — see _aspect_clamped_viewport_size. Independent
			# per-axis clamping here caused the top-down disc to shift sideways once
			# the canvas passed the cap on one axis.
			_viewport.size = _aspect_clamped_viewport_size(_container.size, vp_cap)
	elif place_d > MAX_DISC_CONTAINER_PX * 4.0 and not _top_down and not _section_mode:
		# Freeform bubble at absurd zoom — refuse giant Control.
		_container.size = Vector2(MAX_DISC_CONTAINER_PX, MAX_DISC_CONTAINER_PX)
		_container.position = _canvas.position + origin \
				- Vector2(MAX_DISC_CONTAINER_PX, MAX_DISC_CONTAINER_PX) * 0.5
		_set_disc_mask(false)
		if _viewport != null:
			_viewport.size = Vector2i(MAX_VIEWPORT_PX, MAX_VIEWPORT_PX)
	else:
		# Disc-sized square: UV-centered circular mask (legacy / zoomed-out).
		# Clamp place_d so a bug never allocates megapixel Controls.
		var safe_d := minf(place_d, MAX_DISC_CONTAINER_PX)
		_container.position = _canvas.position + origin - Vector2(safe_d, safe_d) * 0.5
		_container.size = Vector2(safe_d, safe_d)
		_set_disc_mask(false)
		if _viewport != null:
			var res := int(round(clampf(safe_d,
					float(MIN_VIEWPORT_PX), vp_cap)))
			_viewport.size = Vector2i(res, res)
	_apply_viewport_msaa()
	_last_layout_key = _canvas_layout_key()


## Crop decision with one-directional hysteresis: crossing UP happens at the
## container cap, crossing back DOWN only below 90% of it. Right at the
## boundary the old exact test flip-flopped every wheel notch — each flip
## re-allocating the viewport, swapping the mask mode, and reframing the
## camera, which is most of what read as "the zoom jumps".
func _want_crop(place_d: float) -> bool:
	if not (_top_down or _section_mode):
		return false
	# The section AND the plan always fill the canvas (see _sync_layout) —
	# reporting anything else would make sync_camera_now force a re-layout
	# per notch.
	if (_section_mode or _top_down) and (_embed_host == null or not is_instance_valid(_embed_host)):
		return true
	if _top_down_cropped:
		return place_d > MAX_DISC_CONTAINER_PX * 0.9
	return place_d > MAX_DISC_CONTAINER_PX


## Same-frame camera-pose sync for one wheel notch — deliberately WITHOUT
## _sync_layout (re-cropping the SubViewport per notch was the deep-zoom
## stutter; the camera framing is pure math). The canvas calls this from
## _zoom_at while the preview camera is projection authority, so chips never
## draw a frame against a stale pose and then snap. If the notch crosses the
## crop threshold, the ONE full re-crop happens now instead, so the mode
## switch lands in the same frame as the 2D zoom.
func sync_camera_now() -> void:
	if not active:
		return
	if _embed_host != null and is_instance_valid(_embed_host):
		return
	var disc := _read_disc()
	var place_d := maxf(float(disc.get("radius_px", 0.0)), 1.0) * 2.0
	if _want_crop(place_d) != _top_down_cropped:
		force_layout_sync()
		return
	_camera_dirty = true
	_update_camera()
	_camera_dirty = false
	_request_viewport_refresh()


## Section / cropped previews skip MSAA — fill-rate savings at high zoom.
func _apply_viewport_msaa() -> void:
	if _viewport == null:
		return
	# Keep MSAA on for the Site Plan (top-down) cropped path so the anti-alias
	# doesn't pop off at the crop-zoom threshold; only the Elevation section crop
	# disables it (that view's fill-rate saving, and its main first-open TDR risk).
	if _section_mode:
		_viewport.msaa_3d = Viewport.MSAA_DISABLED
	else:
		_viewport.msaa_3d = Viewport.MSAA_2X


func _update_camera() -> void:
	if _camera == null:
		return
	var soi := _soi()
	if soi == null or not soi.has_method("world_center"):
		return
	var center: Vector3 = soi.call("world_center")
	var r: float = float(soi.call("radius_m")) if soi.has_method("radius_m") else 150.0
	if _section_mode:
		_update_section_camera(center, r)
		return
	if _top_down:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera.fov = PLAN_FOV_DEG
		# Explicit basis: +X east, cam-up = north (−Z), look down (−Y).
		var basis := Basis(
			Vector3(1.0, 0.0, 0.0),
			Vector3(0.0, 0.0, -1.0),
			Vector3(0.0, 1.0, 0.0)
		)
		var look := center
		if _top_down_cropped and _canvas != null and is_instance_valid(_canvas):
			# Lock ortho frustum to the canvas window at 4 px/m × zoom so 2D
			# scroll-zoom and 3D metres stay physically linked.
			var zoom := 1.0
			if _canvas.has_method("get_view_zoom"):
				zoom = maxf(float(_canvas.call("get_view_zoom")), 0.0001)
			var s := SOI_PX_PER_M * zoom
			var disc := _read_disc()
			var origin: Vector2 = disc.get("origin", Vector2.ZERO)
			var site_at_center := (_canvas.size * 0.5 - origin) / s
			look = center + Vector3(site_at_center.x, 0.0, site_at_center.y)
			_frame_h_m = maxf(_canvas.size.y / s, MIN_FRAME_H_M)
		else:
			# Fit the full SoI diameter into the square disc viewport.
			_frame_h_m = maxf(r * 2.0, 10.0)
		# The focus plane is the GROUND under the view centre (not the SoI
		# centre's height), so the matched scale holds where you are looking and
		# a hilltop is never behind the camera (the old ortho camera sat at most
		# 60 m above the centre and clipped higher ground).
		look.y = _ground_y_or(look.x, look.z, center.y)
		var dist := _matched_distance(_frame_h_m, PLAN_FOV_DEG)
		_cam_look = look
		if is_phys_orbited():
			_apply_topdown_orbit(look, dist)
		else:
			_camera.global_transform = Transform3D(basis, look + Vector3(0.0, dist, 0.0))
		_set_near_far(dist, r)
		return
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	var dist := maxf(r * _orbit_mult, 1.0 if _globe else MIN_ORBIT_DIST_M)
	var offset := Vector3(
		cos(_yaw) * cos(_pitch),
		sin(_pitch),
		sin(_yaw) * cos(_pitch)
	) * dist
	_camera.global_position = center + offset
	_camera.look_at(center, Vector3.UP)
	_cam_look = center
	if _globe:
		_camera.fov = GLOBE_FOV
		# Near tracks zoom so a close-in globe doesn't clip the disc (the
		# full-screen globe's rule); far reaches the horizon behind it.
		_camera.near = clampf(dist * 0.02, 0.05, 0.5)
		_camera.far = maxf(8000.0, dist * 8.0 + r * 4.0)
	else:
		_camera.far = maxf(dist + r * 4.0, 2000.0)


## Orbit the top-down camera around the focus at the matched distance (the
## Globe's orbit, pitched from straight down): the focus keeps its scale, the
## rest of the plan foreshortens like a real oblique view.
func _apply_topdown_orbit(look: Vector3, dist: float) -> void:
	var elev := PI * 0.5 - _phys_pitch  # 90° = straight down (pitch 0)
	var yaw := _phys_yaw
	var dir := Vector3(cos(elev) * sin(yaw), sin(elev), cos(elev) * cos(yaw))
	_camera.global_position = look + dir * dist
	var up := Vector3.UP
	if elev > deg_to_rad(80.0):
		# Near straight-down: UP is degenerate → keep north (−Z) up, yaw-rotated.
		up = Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, yaw)
	_camera.look_at(look, up)


## Vertical slice: screen-right = section along, screen-up = world up.
## Camera sits on the cross-axis looking through the cut plane (CT offset).
## Pitch is locked side-on; zoom is ortho size.
func _update_section_camera(center: Vector3, r: float) -> void:
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = SECTION_FOV_DEG
	_phys_pitch = 0.0
	var h := _section_heading
	var along := Vector3(cos(h), 0.0, sin(h))
	var cross := Vector3(-sin(h), 0.0, cos(h))
	var look := center + cross * _section_offset_m
	# Camera −Z = −cross → view into the section from the +cross side.
	var cam_z := cross.normalized()
	var cam_x := Vector3.UP.cross(cam_z).normalized()
	if cam_x.dot(along) < 0.0:
		cam_x = -cam_x
	var cam_y := cam_z.cross(cam_x).normalized()
	var ortho_h := maxf(r * 2.0, 2.0)
	# Hydro Lab embed owns framing via set_lab_section_frame (prefer over Elev
	# canvas anchors — those belong to the parked freeform canvas).
	var used_anchors := false
	var lab_frame := _embed_host != null and is_instance_valid(_embed_host) \
			and not is_nan(_lab_along_m) and not is_nan(_lab_elev_m) \
			and not is_nan(_lab_ortho_h_m) and _lab_ortho_h_m >= MIN_FRAME_H_M
	if lab_frame:
		look = Vector3(
			center.x + along.x * _lab_along_m + cross.x * _section_offset_m,
			_lab_elev_m,
			center.z + along.z * _lab_along_m + cross.z * _section_offset_m)
		ortho_h = maxf(_lab_ortho_h_m, MIN_FRAME_H_M)
		used_anchors = true
	elif _canvas != null and is_instance_valid(_canvas) \
			and _canvas.has_method("get_elev_frame") \
			and (not _canvas.has_method("has_elev_anchor") \
			or bool(_canvas.call("has_elev_anchor"))):
		# ONE frame (GraphElevFrame) for the 2D overlay, the disc mask and this
		# camera: look at the section point that sits under the CONTAINER's
		# centre. In crop mode the container is the canvas, so that is the
		# anchor; in disc mode the container is centred on the projected SoI
		# centre, so it is the SoI centre on the slice. The old code always
		# looked at the anchor while the disc container sat at the canvas
		# centre — the sphere slid inside its mask on every pan/zoom.
		var frame: Dictionary = _canvas.call("get_elev_frame") as Dictionary
		var cont_ok := _container != null and is_instance_valid(_container) \
				and _container.size.y > 1.0
		var cont_center := (_container.position + _container.size * 0.5 - _canvas.position) \
				if cont_ok else _canvas.size * 0.5
		var m := GraphElevFrame.to_metres(frame, cont_center)
		look = Vector3(
			center.x + along.x * m.x + cross.x * _section_offset_m,
			m.y,
			center.z + along.z * m.x + cross.z * _section_offset_m)
		var cont_h := _container.size.y if cont_ok else _canvas.size.y
		ortho_h = GraphElevFrame.ortho_height_m(frame, cont_h)
		used_anchors = true
	elif not is_nan(_lab_along_m) and not is_nan(_lab_elev_m) \
			and not is_nan(_lab_ortho_h_m) and _lab_ortho_h_m >= MIN_FRAME_H_M:
		look = Vector3(
			center.x + along.x * _lab_along_m + cross.x * _section_offset_m,
			_lab_elev_m,
			center.z + along.z * _lab_along_m + cross.z * _section_offset_m)
		ortho_h = maxf(_lab_ortho_h_m, MIN_FRAME_H_M)
	elif _top_down_cropped and _canvas != null and is_instance_valid(_canvas) \
			and not used_anchors:
		# Legacy Site-Plan-style crop framing (no elev anchors).
		var canvas_zoom2 := 1.0
		if _canvas.has_method("get_view_zoom"):
			canvas_zoom2 = maxf(float(_canvas.call("get_view_zoom")), 0.0001)
		var s2 := SOI_PX_PER_M * canvas_zoom2
		var disc := _read_disc()
		var origin: Vector2 = disc.get("origin", Vector2.ZERO)
		var site_at_center := (_canvas.size * 0.5 - origin) / s2
		var along_m2 := site_at_center.x * cos(h) + site_at_center.y * sin(h)
		look = center + along * along_m2 + cross * _section_offset_m
		var cont_h2 := _container.size.y if (_container != null and is_instance_valid(_container) \
				and _container.size.y > 1.0) else _canvas.size.y
		ortho_h = maxf(cont_h2 / s2, MIN_FRAME_H_M)
	# Perspective, square-on to the cut: at this distance the cut face maps at
	# exactly the 2D scale (GraphElevFrame stays exact on the plane), while
	# the ground behind it recedes with real depth. The camera sits in the
	# discarded half (+cross), so nothing between it and the cut renders.
	_frame_h_m = maxf(ortho_h, MIN_FRAME_H_M)
	var dist := _matched_distance(_frame_h_m, SECTION_FOV_DEG)
	var basis := Basis(cam_x, cam_y, cam_z)
	_camera.global_transform = Transform3D(basis, look + cross * dist)
	_cam_look = look
	_set_near_far(dist, r)
	_push_section_cutaway()


## Camera distance at which a `frame_h_m`-tall window at the focus fills the
## viewport height with a `fov_deg` vertical FOV.
static func _matched_distance(frame_h_m: float, fov_deg: float) -> float:
	return maxf(frame_h_m, MIN_FRAME_H_M) * 0.5 / tan(deg_to_rad(fov_deg) * 0.5)


func _set_near_far(dist: float, r: float) -> void:
	_camera.near = clampf(dist * 0.02, 0.002, 0.5)
	_camera.far = maxf(dist * 6.0 + r * 4.0, 3000.0)


## Ground height at world xz from SoiService (the edit-aware terrain), else
## `fallback` — keeps the plan's focus on the ground actually drawn.
func _ground_y_or(x: float, z: float, fallback: float) -> float:
	var soi := _soi()
	if soi != null and soi.has_method("ground_y_at"):
		var y := float(soi.call("ground_y_at", x, z))
		if is_finite(y):
			return y
	return fallback


## Long shadows for the perspective plan / section: the sun's shadow range is
## tuned for first person, and these cameras now sit hundreds of metres out.
## A camera-LESS claim (falls through to the camera below), like the Globe's.
func _sync_lens_shadow_claim() -> void:
	var want := active and (_top_down or _section_mode) and not _globe
	if want == _lens_shadow_held:
		return
	var tree := get_tree()
	var main := tree.current_scene if tree != null else null
	if main == null:
		return
	_lens_shadow_held = want
	if want and main.has_method("push_camera_claim"):
		var soi := _soi()
		var r := float(soi.call("radius_m")) if soi != null and soi.has_method("radius_m") else 150.0
		main.call("push_camera_claim", LENS_SHADOW_CLAIM, {"shadow_max_distance": r * 6.0})
	elif not want and main.has_method("pop_camera_claim"):
		main.call("pop_camera_claim", LENS_SHADOW_CLAIM)


func _push_section_cutaway() -> void:
	var soi := _soi()
	if soi == null or not soi.has_method("set_section_cutaway"):
		return
	if not _section_mode or not active or not _clip_owned:
		return
	if bool(soi.get("snowglobe_active")):
		return
	var c: Vector3 = soi.call("world_center") as Vector3 if soi.has_method("world_center") \
			else Vector3.ZERO
	var h := _section_heading
	var cross := Vector3(-sin(h), 0.0, cos(h))
	var origin := c + cross * _section_offset_m
	# The cut-face cap's top-edge lip scales with the zoom (~1.5 px) so no sky
	# sliver opens between it and the terrain mesh at Hydro Lab depth.
	if soi.has_method("set_section_cap_lip") and _camera != null:
		soi.call("set_section_cap_lip", clampf(_frame_h_m * 0.004, 0.002, 1.5))
	# Normal toward camera (+cross) → camera-side half discarded.
	soi.call("set_section_cutaway", true, origin, cross)


func _clear_section_cutaway() -> void:
	var soi := _soi()
	if soi != null and soi.has_method("set_section_cutaway"):
		soi.call("set_section_cutaway", false)


func _soi() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("SoiService")


## The Globe lens's orbit, so the full-screen globe opens on the same view
## and hands it back on exit ({} when the Globe lens is not on).
func globe_orbit_state() -> Dictionary:
	if not _globe:
		return {}
	return {"yaw": _yaw, "pitch": _pitch, "mult": _orbit_mult}


func apply_globe_orbit_state(d: Dictionary) -> void:
	if d.is_empty():
		return
	_yaw = float(d.get("yaw", _yaw))
	_pitch = float(d.get("pitch", _pitch))
	_orbit_mult = clampf(float(d.get("mult", _orbit_mult)), GLOBE_MIN_ORBIT_MULT, MAX_ORBIT_MULT)
	_orbit_mult_target = _orbit_mult
	_globe_framed = true
	_camera_dirty = true
	_update_camera()
	_request_viewport_refresh()
	_notify_canvas_redraw()

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
## Elevation CT ortho zoom (Shift+wheel) — larger than freeform orbit step.
const SECTION_ZOOM_STEP := 0.14
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
## Frames to wait after activate before first UPDATE_ONCE (lets layout settle).
const SOFT_BOOT_FRAMES := 3
const YAW_SENS := 0.005
const PITCH_SENS := 0.004
const PITCH_MIN := 0.05
const PITCH_MAX := 1.45
## Physical-view orbit (Site top-down / Elevation section — free tilt).
const PHYS_YAW_SENS := 0.006
const PHYS_PITCH_SENS := 0.006
## Site: 0 = straight down, up to nearly horizon. Section: ± above/below side-on.
const PHYS_PITCH_MAX := 1.30
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
var _section_heading: float = 0.0
## CT slice depth along the cross-axis (−R…+R metres from SoI centre).
var _section_offset_m: float = 0.0
## Ortho zoom into the cut face (1 = fit SoI diameter; higher = closer).
var _section_zoom: float = 1.0
const MIN_SECTION_ZOOM := 1.0
const MAX_SECTION_ZOOM := 16.0
## Physical-view orbit state (Site/Elevation). At (0,0) the camera keeps its
## exact default pose (top-down / side-on) so nothing changes until the user
## tilts; once orbited, this service becomes the projection authority for the
## 2D chips + wires so they track the tilt.
var _phys_yaw: float = 0.0
var _phys_pitch: float = 0.0
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
## Optional Control that owns the SubViewportContainer (Siphon Lab CT slot).
## When set, layout fills this host instead of the graph SoI disc.
var _embed_host: Control = null
## Siphon Lab framing override: along_m, elev_m, ortho_h_m (metres).
var _lab_along_m: float = NAN
var _lab_elev_m: float = NAN
var _lab_ortho_h_m: float = NAN
var _section_env: Environment = null
var _disc_material: ShaderMaterial = null
## Soft-boot: hold first capture until layout has a few idle frames.
var _soft_boot_frames: int = 0


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


func set_active(on: bool) -> void:
	if active == on:
		return
	active = on
	# Lift prop distance-culling while the disc is up so the far/tilted preview
	# camera can't cull small graph-twin props; restore normal culling on close.
	# (First-person 3D isn't rendering while the graph is open, so this is free.)
	var _pmain := get_tree().current_scene if get_tree() != null else null
	if _pmain != null:
		PropRenderTuning.preview_active = on
		PropRenderTuning.apply_to_all(_pmain)
	if on:
		_ensure_nodes()
		_connect_canvas_camera_signals()
		_bind_world()
		_apply_soi_visuals(true)
		_apply_preview_shell_visuals()
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
		if _section_mode:
			_apply_hydroturbine_section_clip(true)
			_ensure_section_soil_visible()
	else:
		_section_env = null
		_soft_boot_frames = 0
		set_process(false)
		_set_visible(false)
		_apply_hydroturbine_section_clip(false)
		_apply_soi_visuals(false)
		_restore_lite_camera()
		if _viewport != null:
			_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _canvas != null and is_instance_valid(_canvas):
		_canvas.set("soi_live_preview", on)
		_canvas.queue_redraw()
	preview_active_changed.emit(on)


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
	_request_viewport_refresh()


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
	if _viewport == null or _viewport.size.x <= 1 or _viewport.size.y <= 1:
		return false
	if _container == null or not is_instance_valid(_container):
		return false
	if not (_top_down or _section_mode):
		return false
	if _embed_host != null and is_instance_valid(_embed_host):
		return true
	return _canvas != null and is_instance_valid(_canvas)


func is_section_mode() -> bool:
	return _section_mode and active


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
	var hit: Variant = canvas_to_world_on_plane(canvas_pos, c, Vector3.UP)
	if not (hit is Vector3):
		return null
	var h: Vector3 = hit as Vector3
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
	if not active or _top_down:
		return
	if _section_mode:
		# Ortho size zoom into the cut face (not freeform orbit mult).
		var factor := 1.0 + SECTION_ZOOM_STEP if zoom_in else 1.0 - SECTION_ZOOM_STEP
		_section_zoom = clampf(_section_zoom * factor, MIN_SECTION_ZOOM, MAX_SECTION_ZOOM)
		_camera_dirty = true
		_update_camera()
		_request_viewport_refresh()
		_notify_canvas_redraw()
		return
	var factor2 := 1.0 - ZOOM_STEP if zoom_in else 1.0 + ZOOM_STEP
	_orbit_mult_target = clampf(_orbit_mult_target * factor2, MIN_ORBIT_MULT, MAX_ORBIT_MULT)
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


func get_section_zoom() -> float:
	return _section_zoom


## Reset CT section: offset 0, zoom fit, pitch locked, optional heading.
func reset_section(heading_rad: float = NAN) -> void:
	_section_offset_m = 0.0
	_section_zoom = 1.0
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
	_apply_preview_shell_visuals()
	_apply_viewport_msaa()
	if _camera != null:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if (on or _section_mode) \
				else Camera3D.PROJECTION_PERSPECTIVE
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
	else:
		_section_env = null
	_apply_preview_shell_visuals()
	_apply_viewport_msaa()
	_apply_section_environment()
	if _camera != null:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if (_section_mode or _top_down) \
				else Camera3D.PROJECTION_PERSPECTIVE
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
		if str(prop.model_id) != "hydroturbine":
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


func _request_viewport_refresh() -> void:
	if _viewport == null or not active:
		return
	if _soft_boot_frames > 0:
		return
	# Dirty-driven: one frame now; _process re-arms on orbit/layout/time scrub.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


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
	# Top-down: hide the whole subsurface mesh (glass from above = black disc).
	# Elevation section: keep soil bowl, kill glass — Fresnel on the dome from
	# the side paints the concentric "bullseye" over the sky.
	# Freeform orbit: full glass snowglobe.
	if soi.has_method("set_graph_preview_shell_visible"):
		soi.call("set_graph_preview_shell_visible", not _top_down)
	if soi.has_method("set_graph_preview_glass_enabled"):
		soi.call("set_graph_preview_glass_enabled", not _top_down and not _section_mode)
	_apply_viewport_background()


func _apply_viewport_background() -> void:
	if _viewport == null:
		return
	# transparent_bg skips Environment sky clear — fine for terrain-fill Site
	# Plan, wrong for Elevation where the upper disc is empty air.
	_viewport.transparent_bg = not _section_mode
	_bind_world()


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
		# Elev/Siphon CT: keep 2D pond/DEM overlays on the live camera frustum.
		if _section_mode:
			_notify_canvas_redraw()
	elif _soft_boot_frames > 0:
		_soft_boot_frames -= 1
		if _soft_boot_frames == 0:
			_request_viewport_refresh()
	elif _preview_live:
		# Idle throttle: soft refresh so sky/time scrub still updates. OFF by
		# default (see _preview_live) — this idle re-render of the whole shared
		# World3D was the elevation view's dominant cost. Cropped high-zoom path
		# refreshes slower — giant world into a small viewport is still expensive.
		_refresh_acc += delta
		var hz := IDLE_REFRESH_HZ_CROPPED if _top_down_cropped or _section_mode \
				else IDLE_REFRESH_HZ
		if _refresh_acc >= 1.0 / hz:
			_refresh_acc = 0.0
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
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_viewport.msaa_3d = Viewport.MSAA_2X
	_container.add_child(_viewport)
	_apply_viewport_msaa()

	_camera = Camera3D.new()
	_camera.name = "SoiPreviewCamera"
	_camera.current = true
	_camera.fov = 70.0
	_camera.near = 0.5
	_camera.far = 8000.0
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
	_viewport.transparent_bg = not _section_mode
	_apply_section_environment()


## Preview-local Environment clone: no fog/glow on the CT camera.
## Shared-world god rays are gated in main.gd while section preview is active
## (do not mutate WorldEnvironment every frame — that fought main + TDRd GPUs).
func _apply_section_environment() -> void:
	if _camera == null:
		return
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main == null:
		return
	var src_env: Environment = null
	var we := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		src_env = we.environment
	elif main.get("environment") is WorldEnvironment:
		var we2: WorldEnvironment = main.get("environment") as WorldEnvironment
		if we2 != null:
			src_env = we2.environment
	if src_env == null:
		return
	if not _section_mode:
		_section_env = null
		_camera.environment = src_env
		return
	if _section_env == null:
		_section_env = src_env.duplicate(true) as Environment
		var env := _section_env
		env.volumetric_fog_enabled = false
		env.volumetric_fog_density = 0.0
		env.fog_enabled = false
		env.glow_enabled = false
		env.glow_intensity = 0.0
		env.ssr_enabled = false
		if env.tonemap_mode == Environment.TONE_MAPPER_LINEAR:
			env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_camera.environment = _section_env


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
	var key := "%s|%s|%.4f|%.2f|%.2f|%s|%s|%.3f|%.2f|%.2f|%.3f|%.2f|%.2f" % [
		str(_canvas.position),
		str(_canvas.size),
		float(disc.get("radius_px", 0.0)),
		float((disc.get("origin", Vector2.ZERO) as Vector2).x),
		float((disc.get("origin", Vector2.ZERO) as Vector2).y),
		str(_top_down),
		str(_section_mode),
		_section_heading,
		_section_offset_m,
		_section_zoom,
		canvas_zoom,
		elev_along,
		elev_elev,
	]
	return key != _last_layout_key


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
		_container.material = null
		_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_container.position = Vector2.ZERO
		_container.size = _embed_host.size
		if _viewport != null:
			# Aspect-preserving clamp (same reason as the crop branch below).
			_viewport.size = _aspect_clamped_viewport_size(_container.size, vp_cap)
		_apply_viewport_msaa()
		_apply_section_environment()
		_last_layout_key = "embed|%s|%s|%s" % [
			str(_embed_host.size), str(_section_mode), str(_lab_ortho_h_m)]
		return
	if _canvas == null or not is_instance_valid(_canvas):
		return
	# Restore free anchors + disc mask when leaving embed.
	if _disc_material != null and _container.material != _disc_material:
		_container.material = _disc_material
	_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var disc := _read_disc()
	var origin: Vector2 = disc.get("origin", Vector2.ZERO)
	var r_px: float = maxf(float(disc.get("radius_px", 0.0)), 1.0)
	var place_d := r_px * 2.0
	_top_down_cropped = false
	# Site Plan AND Elevation section: never grow SubViewportContainer to
	# hundreds of thousands of pixels at high 2D zoom (GPU/compositor stall).
	var want_crop := (_top_down or _section_mode) and place_d > MAX_DISC_CONTAINER_PX
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
	var elev_along := 0.0
	var elev_elev := 0.0
	var canvas_zoom := 1.0
	if _canvas.has_method("get_elev_anchor_along_m"):
		elev_along = float(_canvas.call("get_elev_anchor_along_m"))
	if _canvas.has_method("get_elev_anchor_elev_m"):
		elev_elev = float(_canvas.call("get_elev_anchor_elev_m"))
	if _canvas.has_method("get_view_zoom"):
		canvas_zoom = float(_canvas.call("get_view_zoom"))
	_last_layout_key = "%s|%s|%.4f|%.2f|%.2f|%s|%s|%.3f|%.2f|%.2f|%.3f|%.2f|%.2f" % [
		str(_canvas.position), str(_canvas.size), r_px, origin.x, origin.y,
		str(_top_down), str(_section_mode), _section_heading,
		_section_offset_m, _section_zoom, canvas_zoom, elev_along, elev_elev,
	]


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
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		# Explicit basis: +X east, cam-up = north (−Z), look down (−Y).
		var basis := Basis(
			Vector3(1.0, 0.0, 0.0),
			Vector3(0.0, 0.0, -1.0),
			Vector3(0.0, 1.0, 0.0)
		)
		# Keep the ortho camera CLOSE to the ground. Ortho scale is set by
		# _camera.size (below), independent of distance, so a low camera doesn't
		# change framing — but it keeps small graph-twin props (generic_box/tank,
		# ~1-2 m radius) inside PropRenderTuning's ~200 m distance cull. A far camera
		# (the old r*0.45, and r*2.5 when orbited) culled the twins while large
		# cull-exempt props (rack/buildings) stayed, so only the latter showed.
		var height := clampf(r * 0.45, 20.0, PREVIEW_TOPDOWN_HEIGHT_MAX_M)
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
			_camera.size = maxf(_canvas.size.y / s, 0.5)
		else:
			# Fit the full SoI diameter into the square disc viewport.
			_camera.size = maxf(r * 2.0, 10.0)
		if is_phys_orbited():
			_apply_topdown_orbit(look, r, height)
		else:
			_camera.global_transform = Transform3D(basis, look + Vector3(0.0, height, 0.0))
		_camera.near = 0.5
		# Far/near derived from the ACTUAL camera→look distance so a tilted orbit (a
		# far camera, see _apply_topdown_orbit) doesn't slice the ground into an
		# ellipse. Ortho depth is linear, so a generous far has no precision cost.
		var cam_dist := _camera.global_position.distance_to(look)
		_camera.far = maxf(cam_dist + r * 4.0, 3000.0)
		return
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	var dist := maxf(r * _orbit_mult, MIN_ORBIT_DIST_M)
	var offset := Vector3(
		cos(_yaw) * cos(_pitch),
		sin(_pitch),
		sin(_yaw) * cos(_pitch)
	) * dist
	_camera.global_position = center + offset
	_camera.look_at(center, Vector3.UP)
	_camera.far = maxf(dist + r * 4.0, 2000.0)


## Orbit the top-down ortho camera around the look target. Ortho size is kept
## (set by the caller) so 2D px/m stays locked; only the pose tilts/rotates.
func _apply_topdown_orbit(look: Vector3, r: float, _height: float) -> void:
	var elev := PI * 0.5 - _phys_pitch  # 90° = straight down (pitch 0)
	var yaw := _phys_yaw
	var dir := Vector3(cos(elev) * sin(yaw), sin(elev), cos(elev) * cos(yaw))
	# Pull the camera back as the view tilts toward the horizon so the near/far
	# planes never slice the ground (a close camera at a low angle + wide view
	# clips both the near foreground and far edge → the "ellipse" clip). Ortho
	# projection is distance-independent (framing = _camera.size), and prop culling
	# is lifted while the preview is up (PropRenderTuning.preview_active), so a far
	# camera costs nothing and doesn't hide twins. `1/tan(elev)` is the ground
	# distance the ortho half-window spans at this tilt.
	var dist := clampf(r / maxf(tan(elev), 0.12), r * 2.0, r * 10.0)
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
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
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
	var zoom := clampf(_section_zoom, MIN_SECTION_ZOOM, MAX_SECTION_ZOOM)
	var ortho_h := maxf(r * 2.0 / zoom, 2.0)
	# Hydro Lab embed owns framing via set_lab_section_frame (prefer over Elev
	# canvas anchors — those belong to the parked freeform canvas).
	var used_anchors := false
	var lab_frame := _embed_host != null and is_instance_valid(_embed_host) \
			and not is_nan(_lab_along_m) and not is_nan(_lab_elev_m) \
			and not is_nan(_lab_ortho_h_m) and _lab_ortho_h_m > 0.5
	if lab_frame:
		look = Vector3(
			center.x + along.x * _lab_along_m + cross.x * _section_offset_m,
			_lab_elev_m,
			center.z + along.z * _lab_along_m + cross.z * _section_offset_m)
		ortho_h = maxf(_lab_ortho_h_m, 2.0)
		used_anchors = true
	elif _canvas != null and is_instance_valid(_canvas) \
			and _canvas.has_method("get_elev_anchor_along_m") \
			and (not _canvas.has_method("has_elev_anchor") \
			or bool(_canvas.call("has_elev_anchor"))):
		var canvas_zoom := 1.0
		if _canvas.has_method("get_view_zoom"):
			canvas_zoom = maxf(float(_canvas.call("get_view_zoom")), 0.0001)
		var s := SOI_PX_PER_M * canvas_zoom
		var along_m := float(_canvas.call("get_elev_anchor_along_m"))
		var elev_m := float(_canvas.call("get_elev_anchor_elev_m")) \
				if _canvas.has_method("get_elev_anchor_elev_m") else center.y
		look = Vector3(
			center.x + along.x * along_m + cross.x * _section_offset_m,
			elev_m,
			center.z + along.z * along_m + cross.z * _section_offset_m)
		# Frustum matches the SubViewportContainer (disc or full canvas), not
		# always canvas.h — otherwise non-crop disc stretches vs 2D px/m.
		var cont_h := _container.size.y if (_container != null and is_instance_valid(_container) \
				and _container.size.y > 1.0) else _canvas.size.y
		ortho_h = maxf(cont_h / maxf(s, 0.0001), 2.0)
		used_anchors = true
	elif not is_nan(_lab_along_m) and not is_nan(_lab_elev_m) \
			and not is_nan(_lab_ortho_h_m) and _lab_ortho_h_m > 0.5:
		look = Vector3(
			center.x + along.x * _lab_along_m + cross.x * _section_offset_m,
			_lab_elev_m,
			center.z + along.z * _lab_along_m + cross.z * _section_offset_m)
		ortho_h = maxf(_lab_ortho_h_m, 2.0)
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
		ortho_h = maxf(cont_h2 / s2, 2.0)
	_camera.size = ortho_h
	var dist := maxf(r * 1.15, 20.0)
	var basis := Basis(cam_x, cam_y, cam_z)
	_camera.global_transform = Transform3D(basis, look + cross * dist)
	_camera.near = 0.5
	_camera.far = maxf(dist + r * 3.0, 500.0)
	_push_section_cutaway()


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

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
## Higher cap reduces UV stretch pinch on large Site Plan discs / HiDPI.
const MAX_VIEWPORT_PX := 2048
## Above this disc diameter, cover the canvas and crop the ortho frustum instead
## of growing a Control to tens of thousands of pixels (extreme 2D zoom-in).
const MAX_DISC_CONTAINER_PX := 4096.0
const YAW_SENS := 0.005
const PITCH_SENS := 0.004
const PITCH_MIN := 0.05
const PITCH_MAX := 1.45
## Cap idle redraws while SoI lite preview is active (~24 FPS).
const IDLE_REFRESH_HZ := 24.0

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
## True when top-down preview covers the canvas and zooms with 2D pan/zoom.
var _top_down_cropped: bool = false
## Elevation: camera looks along a cross-section of the snowglobe.
var _section_mode: bool = false
var _section_heading: float = 0.0
var _clip_owned: bool = false
var _layout_dirty: bool = true
var _camera_dirty: bool = true
var _last_layout_key: String = ""
var _refresh_acc: float = 0.0
var _saved_shadows: int = -1


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
		set_process(true)
		_apply_lite_camera()
		_request_viewport_refresh()
	else:
		set_process(false)
		_set_visible(false)
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


func apply_orbit_delta(relative: Vector2) -> void:
	if not active or _top_down or _section_mode:
		return
	_yaw = fposmod(_yaw - relative.x * YAW_SENS, TAU)
	_pitch = clampf(_pitch - relative.y * PITCH_SENS, PITCH_MIN, PITCH_MAX)
	_camera_dirty = true
	_update_camera()
	_request_viewport_refresh()


func apply_zoom_step(zoom_in: bool) -> void:
	if not active or _top_down or _section_mode:
		return
	var factor := 1.0 - ZOOM_STEP if zoom_in else 1.0 + ZOOM_STEP
	_orbit_mult_target = clampf(_orbit_mult_target * factor, MIN_ORBIT_MULT, MAX_ORBIT_MULT)
	_camera_dirty = true
	_request_viewport_refresh()


## Orthographic north-up top-down for Site Plan (screen up = −Z / north).
func set_top_down(on: bool) -> void:
	_top_down = on
	if on:
		_section_mode = false
	_apply_preview_shell_visuals()
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
	_apply_preview_shell_visuals()
	if _camera != null:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL if (_section_mode or _top_down) \
				else Camera3D.PROJECTION_PERSPECTIVE
	_layout_dirty = true
	_camera_dirty = true
	_update_camera()
	_request_viewport_refresh()


func set_section_heading(heading_rad: float) -> void:
	_section_heading = fposmod(heading_rad, TAU)
	if active and _section_mode:
		_camera_dirty = true
		_update_camera()
		_request_viewport_refresh()


func _request_viewport_refresh() -> void:
	if _viewport == null or not active:
		return
	# Dirty-driven: one frame now; _process re-arms on orbit/layout/time scrub.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


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
		_request_viewport_refresh()
	else:
		# Idle throttle: soft refresh so sky/time scrub still updates.
		_refresh_acc += delta
		if _refresh_acc >= 1.0 / IDLE_REFRESH_HZ:
			_refresh_acc = 0.0
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
	var mat := ShaderMaterial.new()
	mat.shader = load("res://system_graph/graph_soi_preview_disc.gdshader")
	_container.material = mat
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
	# Prefer the main scene Environment so lighting/sky/clouds match the world.
	var main := tree.current_scene
	if main != null and _camera != null:
		var we := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
		if we != null and we.environment != null:
			_camera.environment = we.environment


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
	else:
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
	if _canvas == null or not is_instance_valid(_canvas):
		return false
	var disc := _read_disc()
	var key := "%s|%s|%.4f|%.2f|%.2f|%s|%s|%.3f" % [
		str(_canvas.position),
		str(_canvas.size),
		float(disc.get("radius_px", 0.0)),
		float((disc.get("origin", Vector2.ZERO) as Vector2).x),
		float((disc.get("origin", Vector2.ZERO) as Vector2).y),
		str(_top_down),
		str(_section_mode),
		_section_heading,
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


func _sync_layout() -> void:
	_layout_dirty = false
	if _container == null or _canvas == null or not is_instance_valid(_canvas):
		return
	var disc := _read_disc()
	var origin: Vector2 = disc.get("origin", Vector2.ZERO)
	var r_px: float = maxf(float(disc.get("radius_px", 0.0)), 1.0)
	var place_d := r_px * 2.0
	_top_down_cropped = false
	if _top_down and place_d > MAX_DISC_CONTAINER_PX:
		# Extreme zoom: cover the canvas, crop the camera to the visible
		# metres, mask with the 2D disc in pixel space — keeps 4 px/m × zoom.
		_top_down_cropped = true
		_container.position = _canvas.position
		_container.size = _canvas.size
		_set_disc_mask(true, origin, r_px, _canvas.size)
		if _viewport != null:
			var res_x := int(round(clampf(_canvas.size.x,
					float(MIN_VIEWPORT_PX), float(MAX_VIEWPORT_PX))))
			var res_y := int(round(clampf(_canvas.size.y,
					float(MIN_VIEWPORT_PX), float(MAX_VIEWPORT_PX))))
			_viewport.size = Vector2i(maxi(res_x, 1), maxi(res_y, 1))
	else:
		# Disc-sized square: UV-centered circular mask (legacy / zoomed-out).
		_container.position = _canvas.position + origin - Vector2(place_d, place_d) * 0.5
		_container.size = Vector2(place_d, place_d)
		_set_disc_mask(false)
		if _viewport != null:
			var res := int(round(clampf(place_d,
					float(MIN_VIEWPORT_PX), float(MAX_VIEWPORT_PX))))
			_viewport.size = Vector2i(res, res)
	_last_layout_key = "%s|%s|%.4f|%.2f|%.2f|%s|%s|%.3f" % [
		str(_canvas.position), str(_canvas.size), r_px, origin.x, origin.y,
		str(_top_down), str(_section_mode), _section_heading,
	]


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
		var height := clampf(r * 0.45, 20.0, maxf(r * 0.85, 20.0))
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
			var look := center + Vector3(site_at_center.x, 0.0, site_at_center.y)
			_camera.size = maxf(_canvas.size.y / s, 0.5)
			_camera.global_transform = Transform3D(basis, look + Vector3(0.0, height, 0.0))
		else:
			# Fit the full SoI diameter into the square disc viewport.
			_camera.size = maxf(r * 2.0, 10.0)
			_camera.global_transform = Transform3D(basis, center + Vector3(0.0, height, 0.0))
		_camera.near = 0.5
		_camera.far = maxf(height + r * 2.0, 500.0)
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


## Vertical slice: screen-right = section along, screen-up = world up.
## Camera sits on the cross-axis looking through the diameter so sky, terrain,
## and building cross-sections fill the snowglobe disc.
func _update_section_camera(center: Vector3, r: float) -> void:
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var h := _section_heading
	var along := Vector3(cos(h), 0.0, sin(h))
	var cross := Vector3(-sin(h), 0.0, cos(h))
	# Camera −Z = −cross → view into the section from the +cross side.
	var cam_z := cross
	var cam_x := along
	var cam_y := Vector3.UP
	# Orthonormalise in case of float drift.
	cam_z = cam_z.normalized()
	cam_x = cam_y.cross(cam_z).normalized()
	if cam_x.dot(along) < 0.0:
		cam_x = -cam_x
	cam_y = cam_z.cross(cam_x).normalized()
	var basis := Basis(cam_x, cam_y, cam_z)
	var dist := maxf(r * 1.15, 20.0)
	var pos := center + cross * dist
	_camera.global_transform = Transform3D(basis, pos)
	# Vertical extent = SoI diameter → metres match 2D disc at 1× exaggeration.
	_camera.size = maxf(r * 2.0, 10.0)
	_camera.near = 0.5
	_camera.far = maxf(dist + r * 2.5, 500.0)


func _soi() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("SoiService")

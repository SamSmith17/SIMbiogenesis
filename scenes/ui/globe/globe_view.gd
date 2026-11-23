class_name GlobeView
extends Control

## A responsive 3D Earth (Globe mode, Phase 1). Self-contained: its own
## World3D inside a SubViewport, so it works on the launch hub (no Main) and
## in-game without a camera claim (the modal-preview rule in camera_claims.gd).
##
## The ground is Web Mercator tiles laid straight onto the sphere (one curved
## patch per tile, GlobeQuadtree picks them), so a tile's pixels need no
## reprojection; the poles above 85.05° are caps. Lighting is the real Sun at
## the clock's instant (GlobeMath.subsolar_point), with the city lights as
## points made from NASA's Black Marble tiles (GlobeCityLights), an atmosphere
## shell and the star map behind. The Moon stands at its true distance; the
## camera can orbit either body (set_primary_body), the other stays where it
## is in the sky.
##
## Navigation: drag = grab the ground and turn the globe, wheel = zoom toward
## the pointer, right / middle drag = heading and tilt, double click = fly in,
## keys: arrows / WASD pan, Q E turn, R F tilt, + - zoom, N north up.
## A click (no drag) emits point_clicked(lat, lon).
##
## Frame: GlobeMath's (Earth radius 1.0, +Y north pole, lon 0 on +Z).
## `cam_range` is the distance from the camera to the point it orbits.

signal point_clicked(lat: float, lon: float)
signal point_double_clicked(lat: float, lon: float)
signal point_hovered(lat: float, lon: float, on_globe: bool)
signal view_changed
## The other body (Moon while the Earth is centred, Earth while the Moon is).
signal companion_clicked
signal body_changed(body: String)

const SURFACE_SHADER := preload("res://scenes/ui/globe/globe_surface.gdshader")
const ATMO_SHADER := preload("res://scenes/ui/globe/globe_atmosphere.gdshader")
const SKY_SHADER := preload("res://scenes/ui/globe/globe_sky.gdshader")
const CLOUD_SHADER := preload("res://scenes/ui/globe/globe_clouds.gdshader")
const WIND_SHADER := preload("res://scenes/ui/globe/globe_wind.gdshader")
const AURORA_SHADER := preload("res://scenes/ui/globe/globe_aurora.gdshader")
const CURTAIN_SHADER := preload("res://scenes/ui/globe/globe_aurora_curtain.gdshader")
const MOON_SHADER := preload("res://scenes/ui/globe/globe_moon.gdshader")
const PATH_SHADER := preload("res://scenes/ui/globe/globe_path.gdshader")
## The camera's reach when it orbits the Moon (Moon radii).
const MOON_MAX_RANGE := 40.0
## A body smaller than this on screen is still clickable in a disc this wide.
const BODY_PICK_PX := 14.0
## Aurora shells, globe radii: the green line (~110 km) and the red (~230 km).
## Faint, behind the field-line ribbons (AuroraCurtains).
const AURORA_R := [1.0173, 1.036]
## The weather shell's height: ~10 km, a cloud deck.
const CLOUD_SHELL_R := 1.0016
const STARMAP := "res://assets/sky/starmap_equirect_8k.png"
const STARMAP_SIDECAR := "res://assets/sky/starmap_equirect_8k.json"

const SEGMENTS := 16
const FOV_DEG := 40.0
const MIN_RANGE := 1.6e-4        # ~1 km
const MAX_RANGE := 7.0
const MAX_TILT_DEG := 75.0
const CAP_SEGMENTS := 96
const MESH_CACHE := 700
const RESELECT_S := 0.35
const CLICK_PX := 5.0

var max_zoom := 17
var tile_budget := GlobeQuadtree.DEFAULT_MAX_TILES
var night_lights := true
## Pin names on the globe (pins stay; the "You are here" name too).
var labels_on := true
## The ground imagery layer ("esri", or a registered daily layer).
var base_layer := "esri"
## () -> float UTC Julian Day; empty = the computer's clock.
var time_provider: Callable
## While a time strip is playing or being dragged, the Sun is read every frame.
var sun_continuous := false
## "earth" or "moon": which body sits at the origin, under the camera.
var _body := "earth"
## "moon" or "earth" when the pointer is on the companion, else "".
var hovered_body := ""

# Camera state. The orbit point is a direction (unit vector) so the poles and
# the antimeridian need no special cases; lat/lon are derived.
var cam_range := 2.8
var cam_heading := 0.0
var cam_tilt := 0.0
var _target := GlobeMath.to_unit(25.0, -30.0)

var _vp: SubViewport
var _container: SubViewportContainer
var _cam: Camera3D
var _globe: Node3D
var _atmo: MeshInstance3D
var _aurora: Array[MeshInstance3D] = []
var _aurora_mats: Array[ShaderMaterial] = []
var _aurora_on := false
var _atmo_mat: ShaderMaterial
var _sky_mat: ShaderMaterial
var _caps: Array[MeshInstance3D] = []
var _fetcher: GlobeTileFetcher
var _attrib: Label

var _patches := {}         # Vector3i -> MeshInstance3D
var _patch_state := {}     # Vector3i -> {day: String, night: String}
var _mesh_cache := {}      # Vector3i -> ArrayMesh
var _mesh_order: Array[Vector3i] = []
var _selected: Array[Vector3i] = []
var _reselect_t := 0.0
var _cam_dirty := true
var _sun := Vector3(0, 0, 1)
var _sun_t := 0.0

var _markers := {}         # id -> Node3D
var _overlay := {}         # shader parameter name -> value (empty = none)
var _wx_ground := {}       # cloud-shadow parameters for the ground patches
var _shell: MeshInstance3D
var _shell_mat: ShaderMaterial
var _credits_extra: Array = []
var _has_clouds := false
var _drape := {}           # shader params for the world drapes ({} = none)
var _outlines := {}        # id -> MeshInstance3D
var _wind_mi: MeshInstance3D
var _wind_lines := 0
var _has_rain := false
var _caps_tinted := [false, false]
var _aurora_kp := 2.0
var _ovation: Texture2D
var _curtain: MeshInstance3D
var _curtain_mat: ShaderMaterial
var _curtain_kp := -1.0
var _curtain_lon := 99.0
var _moon_mi: MeshInstance3D
var _moon_mat: ShaderMaterial
var _moon_label: Label3D
var _moon_basis := Basis.IDENTITY
var _irradiance := false
var _moon_photo := false
var _saved_target := Vector3.ZERO
var _saved_range := 2.8
var _saved_heading := 0.0
var _saved_tilt := 0.0
var _saved_valid := false
var _polar: GlobePolarFill
var _polar_date := ""
var _polar_live := false
var _moon_http: HTTPRequest
var _moon_small_tried := false
var _lights: GlobeCityLights
var _path_root: Node3D
var _path_sun: MeshInstance3D          # the analemma in the orbit point's sky
var _path_dome: MeshInstance3D         # that sky's horizon ring
var _path_ground: MeshInstance3D       # the subsolar track on the ground
var _path_moon_orbit: MeshInstance3D   # the Moon's path over a lunation
var _path_moon_ground: MeshInstance3D  # the sublunar track
var _path_marker: MeshInstance3D       # the subsolar point on the Earth
var _moon_sub_marker: MeshInstance3D   # the subsolar point on the Moon
var _moon_sub_track: MeshInstance3D    # its track over a lunation
var _sun_now: MeshInstance3D           # today's Sun on the analemma
var _path_planets: Array = []          # [{line, dot, tag}]
var _show_sun_path := false
var _show_moon_path := false
var _show_planet_paths := false
var _path_key := ""
var _path_wait := 0.0
var _marker_lat := 0.0

# Input state.
var _press_pos := Vector2.ZERO
var _press_ms := 0
var _dragging := false
var _drag_button := 0
var _grab_dir := Vector3.ZERO
var _spin_axis := Vector3.ZERO
var _spin_rate := 0.0
var _range_goal := -1.0
var _zoom_toward := Vector3.ZERO
var _zoom_toward_t := 0.0
var _fly := {}
## Optional destination [lat, lon] whose tile zoom spine (coarse -> z17) is
## pre-staged ahead of a descending flight so tiles never cancel mid-zoom.
var _prestage_ll := PackedFloat64Array()


func _ready() -> void:
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	_container = SubViewportContainer.new()
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_container)
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.handle_input_locally = false
	_vp.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	_container.add_child(_vp)
	_build_world()
	_fetcher = GlobeTileFetcher.new()
	_fetcher.name = "TileFetcher"
	add_child(_fetcher)
	_fetcher.tile_ready.connect(func(_l: String, _k: Vector3i) -> void: _cam_dirty = true)
	_polar = GlobePolarFill.new()
	_polar.name = "PolarFill"
	add_child(_polar)
	_polar.cap_ready.connect(_on_polar_cap)
	_apply_polar_fallback()
	_fetch_moon()
	_lights = GlobeCityLights.new()
	_lights.name = "CityLights"
	_globe.add_child(_lights)
	_attrib = Label.new()
	_attrib.text = ""
	_attrib.add_theme_font_size_override("font_size", 11)
	_attrib.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	_attrib.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Bottom edge, right-aligned, wrapping in the width left of `credits_left`
	# (a panel the owner keeps bottom-left).
	_attrib.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_attrib.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_attrib.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_attrib.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_attrib.offset_right = -8
	_attrib.offset_bottom = -6
	_attrib.offset_left = 8
	add_child(_attrib)
	_update_attribution()
	_update_sun()
	_apply_camera()


func _build_world() -> void:
	var root := Node3D.new()
	root.name = "GlobeWorld"
	_vp.add_child(root)
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = SKY_SHADER
	_load_starmap()
	sky.sky_material = _sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)
	_cam = Camera3D.new()
	_cam.fov = FOV_DEG
	_cam.current = true
	root.add_child(_cam)
	_globe = Node3D.new()
	_globe.name = "Globe"
	root.add_child(_globe)
	for north in [true, false]:
		var cap := MeshInstance3D.new()
		cap.mesh = _cap_mesh(north)
		var m := ShaderMaterial.new()
		m.shader = SURFACE_SHADER
		m.set_shader_parameter("solid", true)
		m.set_shader_parameter("solid_color",
			Color(0.52, 0.60, 0.68) if north else Color(0.86, 0.89, 0.93))
		cap.material_override = m
		_globe.add_child(cap)
		_caps.append(cap)
	_shell = MeshInstance3D.new()
	_shell.name = "WeatherShell"
	var shm := SphereMesh.new()
	shm.radius = CLOUD_SHELL_R
	shm.height = CLOUD_SHELL_R * 2.0
	shm.radial_segments = 256
	shm.rings = 128
	_shell.mesh = shm
	_shell_mat = ShaderMaterial.new()
	_shell_mat.shader = CLOUD_SHADER
	_shell.material_override = _shell_mat
	_shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shell.visible = false
	_globe.add_child(_shell)
	_atmo = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.07
	sm.height = 2.14
	sm.radial_segments = 96
	sm.rings = 48
	_atmo.mesh = sm
	_atmo_mat = ShaderMaterial.new()
	_atmo_mat.shader = ATMO_SHADER
	_atmo.material_override = _atmo_mat
	_atmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(_atmo)
	for i in AURORA_R.size():
		var am := MeshInstance3D.new()
		var asm := SphereMesh.new()
		asm.radius = AURORA_R[i]
		asm.height = AURORA_R[i] * 2.0
		asm.radial_segments = 192
		asm.rings = 96
		am.mesh = asm
		var mat := ShaderMaterial.new()
		mat.shader = AURORA_SHADER
		mat.set_shader_parameter("shell", i)
		mat.set_shader_parameter("aurora_pole", AuroraModel.pole_dir())
		am.material_override = mat
		am.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		am.visible = false
		_globe.add_child(am)
		_aurora.append(am)
		_aurora_mats.append(mat)
	_curtain = MeshInstance3D.new()
	_curtain.name = "AuroraCurtains"
	_curtain_mat = ShaderMaterial.new()
	_curtain_mat.shader = CURTAIN_SHADER
	_curtain_mat.set_shader_parameter("aurora_pole", AuroraModel.pole_dir())
	_curtain.material_override = _curtain_mat
	_curtain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_curtain.visible = false
	_globe.add_child(_curtain)
	_moon_mi = MeshInstance3D.new()
	_moon_mi.name = "Moon"
	var moon_mesh := SphereMesh.new()
	moon_mesh.radius = 1.0
	moon_mesh.height = 2.0
	moon_mesh.radial_segments = 128
	moon_mesh.rings = 64
	_moon_mi.mesh = moon_mesh
	_moon_mat = ShaderMaterial.new()
	_moon_mat.shader = MOON_SHADER
	_moon_mi.material_override = _moon_mat
	_moon_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon_mi.scale = Vector3.ONE * MoonGlobe.RADIUS_RATIO
	root.add_child(_moon_mi)
	_moon_label = Label3D.new()
	_moon_label.name = "MoonLabel"
	_moon_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_moon_label.fixed_size = true
	_moon_label.no_depth_test = true
	_moon_label.pixel_size = 0.0011
	_moon_label.font_size = 18
	_moon_label.outline_size = 6
	_moon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_moon_label.modulate = Color(0.9, 0.93, 1.0, 0.9)
	_moon_label.outline_modulate = Color(0, 0, 0, 0.8)
	_moon_label.offset = Vector2(0, -22)
	_moon_label.render_priority = 2
	root.add_child(_moon_label)
	_path_root = Node3D.new()
	_path_root.name = "Paths"
	root.add_child(_path_root)
	_path_sun = _path_line(_path_root, "SunPath", Color(1.0, 0.82, 0.25), 2.4)
	_path_dome = _path_line(_path_root, "SkyDome", Color(1.0, 1.0, 1.0, 0.28), 1.2)
	_path_ground = _path_line(_path_root, "SubsolarTrack", Color(1.0, 0.72, 0.2, 0.95), 2.6)
	_path_moon_orbit = _path_line(_path_root, "MoonOrbit", Color(0.75, 0.84, 1.0, 0.9), 1.8)
	_path_moon_ground = _path_line(_path_root, "SublunarTrack", Color(0.65, 0.78, 1.0, 0.85), 1.6)
	_moon_sub_track = _path_line(_moon_mi, "MoonSubsolarTrack", Color(1.0, 0.72, 0.2, 0.9), 2.0)
	_path_marker = _path_dot(_path_root, "SubsolarMarker", Color(1.0, 0.95, 0.55), 0.012)
	_moon_sub_marker = _path_dot(_moon_mi, "MoonSubsolarMarker", Color(1.0, 0.95, 0.55), 0.045)
	_sun_now = _path_dot(_path_root, "SunNow", Color(1.0, 0.9, 0.4), 0.01)


func _load_starmap() -> void:
	if not ResourceLoader.exists(STARMAP):
		return
	var tex := load(STARMAP) as Texture2D
	if tex == null:
		return
	_sky_mat.set_shader_parameter("stars", tex)
	_sky_mat.set_shader_parameter("has_stars", true)
	var f := FileAccess.open(STARMAP_SIDECAR, FileAccess.READ)
	if f != null:
		var reg: Variant = JSON.parse_string(f.get_as_text())
		if reg is Dictionary:
			_sky_mat.set_shader_parameter("ra0_deg", float(reg.get("ra_deg_at_u0", 0.0)))
			_sky_mat.set_shader_parameter("ra_dir", -1.0 if float(reg.get("ra_direction", -1)) < 0.0 else 1.0)


# --- Public API ---------------------------------------------------------------

## The orbit point [lat, lon].
func center_latlon() -> PackedFloat64Array:
	return GlobeMath.to_latlon(_target)


## Altitude of the camera above the ground, km (the Moon's own radius while
## it is the body the camera orbits).
func altitude_km() -> float:
	return maxf(0.0, (_cam_pos() - _body_centre()).length() / _body_scale() - 1.0) * _body_radius_km()


func primary_body() -> String:
	return _body


func _body_radius_km() -> float:
	return MoonGlobe.RADIUS_KM if _body == "moon" else GlobeMath.EARTH_RADIUS_KM


## Where the body the camera orbits is (globe frame).
func _body_centre() -> Vector3:
	return _moon_mi.position if _body == "moon" and _moon_mi != null else Vector3.ZERO


## Its radius in globe units (Earth radii).
func _body_scale() -> float:
	return MoonGlobe.RADIUS_RATIO if _body == "moon" else 1.0


## Its body frame (lat/lon directions) in the globe frame.
func _body_basis() -> Basis:
	return _moon_basis if _body == "moon" else Basis.IDENTITY


func _max_range() -> float:
	return MOON_MAX_RANGE if _body == "moon" else MAX_RANGE


## Centre the Earth or the Moon under the camera. Both stay where they are
## in space (the Moon at its true distance); the camera moves. The Moon opens
## on an "Earthrise": low over its eastern limb, the Earth above the horizon.
func set_primary_body(body: String) -> void:
	if (body != "earth" and body != "moon") or body == _body:
		return
	_fly.clear()
	_spin_rate = 0.0
	_range_goal = -1.0
	if body == "moon":
		_saved_target = _target
		_saved_range = cam_range
		_saved_heading = cam_heading
		_saved_tilt = cam_tilt
		_saved_valid = true
		_body = body
		_place_moon()
		# The Earth is on the Moon's prime meridian (+Z of the body frame):
		# stand over the limb at longitude 88 E, look west across it.
		_target = GlobeMath.to_unit(0.0, 88.0)
		cam_range = 2.6
		cam_heading = 270.0
		cam_tilt = 74.0
	else:
		_body = body
		_irradiance = false
		if _moon_mat != null:
			_moon_mat.set_shader_parameter("irradiance", false)
		if _saved_valid:
			_target = _saved_target
			cam_range = _saved_range
			cam_heading = _saved_heading
			cam_tilt = _saved_tilt
	_apply_aurora_visible()
	_path_key = ""
	_cam_dirty = true
	_apply_camera()
	_reselect()
	body_changed.emit(_body)


## The other body is always drawn now; kept for the checks.
func companion_visible() -> bool:
	return _moon_mi != null and _moon_mi.visible


## Where the Moon is drawn, km from the Earth's centre.
func moon_distance_km() -> float:
	return _moon_mi.position.length() * GlobeMath.EARTH_RADIUS_KM if _moon_mi != null else 0.0


## The clear-sky irradiance map on the Moon. Ignored while the Earth is centred.
func set_moon_irradiance(on: bool) -> void:
	_irradiance = on and _body == "moon"
	if _moon_mat != null:
		_moon_mat.set_shader_parameter("irradiance", _irradiance)


func snapshot() -> Image:
	if _vp == null or _vp.get_texture() == null:
		return Image.new()
	return _vp.get_texture().get_image()


## Read the clock now (a playing time strip calls this every frame).
func refresh_sun() -> void:
	_update_sun()


## Jump straight to a view.
func look_at_point(lat: float, lon: float, range_r: float = -1.0) -> void:
	_fly.clear()
	_spin_rate = 0.0
	_range_goal = -1.0
	_target = GlobeMath.to_unit(lat, lon)
	if range_r > 0.0:
		cam_range = clampf(range_r, MIN_RANGE, _max_range())
	_cam_dirty = true
	_apply_camera()


## Animated flight: rises in the middle when a low-altitude hop is long (a
## simplified van Wijk & Nuij 2003 path), descends steadily from orbit without
## zooming backward first, and smoothly aligns tilt + optional heading.
func fly_to(lat: float, lon: float, range_r: float = -1.0, duration_s: float = -1.0,
		tilt_end: float = -1.0, heading_end: float = NAN) -> void:
	var to := GlobeMath.to_unit(lat, lon)
	var r1 := clampf(range_r if range_r > 0.0 else cam_range, MIN_RANGE, _max_range())
	var ang := acos(clampf(_target.dot(to), -1.0, 1.0))
	var hop_peak := maxf(r1, ang * (0.65 if cam_range > 0.25 and r1 < 0.01 else 1.3))
	var peak := maxf(maxf(cam_range, r1), ang * 1.3)
	var dur := duration_s if duration_s > 0.0 else clampf(0.8 + ang * 0.9 + absf(log(r1 / cam_range)) * 0.12, 0.8, 3.2)
	_fly = {"from": _target, "to": to, "r0": cam_range, "r1": r1, "peak": peak,
		"hop_peak": hop_peak, "t": 0.0, "dur": dur,
		"tilt0": cam_tilt, "tilt1": tilt_end, "h0": cam_heading, "h1": heading_end,
		"dest_lat": lat, "dest_lon": lon}
	_spin_rate = 0.0
	_range_goal = -1.0


func set_prestage_target(lat: float, lon: float) -> void:
	_prestage_ll = PackedFloat64Array([lat, lon])


func clear_prestage_target() -> void:
	_prestage_ll = PackedFloat64Array()


func is_flying() -> bool:
	return not _fly.is_empty()


## [lat, lon] under a point of this control, or empty when it misses the Earth.
func pick(local_pos: Vector2) -> PackedFloat64Array:
	var d := _pick_dir(local_pos)
	if d == Vector3.ZERO:
		return PackedFloat64Array()
	return GlobeMath.to_latlon(d)


## Where a lat/lon is drawn on this control; Vector2.INF when it is behind
## the Earth or the camera.
func latlon_to_local(lat: float, lon: float) -> Vector2:
	var p := GlobeMath.to_unit(lat, lon)
	var cp := _cam.global_position
	if p.dot(cp) <= 1.0:
		return Vector2.INF
	if _cam.is_position_behind(p):
		return Vector2.INF
	var vp_px := _cam.unproject_position(p)
	return vp_px * (size / Vector2(_vp.size))


## A labelled pin on the ground (id replaces).
func set_marker(id: String, lat: float, lon: float, color: Color = Color(1.0, 0.75, 0.2),
		text: String = "") -> void:
	remove_marker(id)
	var root := Node3D.new()
	root.name = "Marker_%s" % id.validate_node_name()
	root.set_meta("dir", GlobeMath.to_unit(lat, lon))
	var dot := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 16
	sm.rings = 8
	dot.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	dot.material_override = m
	root.add_child(dot)
	if not text.is_empty():
		var l := Label3D.new()
		l.text = text
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.pixel_size = 0.0011
		l.font_size = 22
		l.outline_size = 8
		l.modulate = Color(1, 1, 1)
		l.outline_modulate = Color(0, 0, 0, 0.8)
		l.offset = Vector2(0, 26)
		# Far-side pins are hidden by _place_markers; a depth-tested label was
		# cut off by the globe's own edge near the limb.
		l.no_depth_test = true
		l.render_priority = 2
		root.add_child(l)
	_globe.add_child(root)
	_markers[id] = root
	_place_markers()


func remove_marker(id: String) -> void:
	if _markers.has(id):
		var n: Node = _markers[id]
		_markers.erase(id)
		if is_instance_valid(n):
			n.queue_free()


func clear_markers() -> void:
	for id in _markers.keys():
		remove_marker(id)


## Camera distance (Earth radii) at which a data layer is fully shown; it is
## gone at OVERLAY_FADE_RATIO of that. A 1-degree layer says nothing a photo
## does not from ~300 km down, so it is faded out well above the ground.
const OVERLAY_FADE_FAR := 0.26
const OVERLAY_FADE_RATIO := 0.18

## A data layer draped over the ground: `tex` equirect (R = value / max_value,
## G = coverage), `colors` 6 band colours (sRGB), `steps` the 5 band edges.
## mode 0 = bands with outlines, 1 = a smooth ramp. `fade_far` / `fade_near`:
## camera distances (radii) between which the layer fades out as the camera
## comes down.
func set_overlay(tex: Texture2D, colors: Array, steps: Array, max_value: float,
		mode: int = 0, alpha: float = 0.6, offset: float = 0.0, ramp_lo: float = 1.5,
		ramp_step: float = 1.0, fade_far: float = OVERLAY_FADE_FAR, fade_near: float = -1.0) -> void:
	var lin: Array = []
	for c in colors:
		var cc: Color = c
		var l := cc.srgb_to_linear()
		lin.append(Vector4(l.r, l.g, l.b, 1.0))
	var st := PackedFloat32Array()
	for v in steps:
		st.append(float(v))
	_overlay = {"overlay_tex": tex, "has_overlay": tex != null, "overlay_colors": lin,
		"overlay_steps": st, "overlay_max": max_value, "overlay_mode": mode, "overlay_alpha": alpha,
		"overlay_offset": offset, "overlay_ramp_lo": ramp_lo, "overlay_ramp_step": ramp_step,
		"overlay_fade_far": fade_far,
		"overlay_fade_near": fade_near if fade_near > 0.0 else fade_far * OVERLAY_FADE_RATIO}
	_push_overlay()


func set_overlay_style(mode: int, alpha: float) -> void:
	if _overlay.is_empty():
		return
	_overlay["overlay_mode"] = mode
	_overlay["overlay_alpha"] = alpha
	_push_overlay()


func clear_overlay() -> void:
	_overlay = {"has_overlay": false}
	_push_overlay()
	_overlay.clear()


func has_overlay() -> bool:
	return bool(_overlay.get("has_overlay", false))


## Ground imagery: "esri", or a layer registered here with its definition
## (GlobeTileFetcher.LAYERS form), e.g. a satellite image of one day.
func set_base_layer(id: String, def: Dictionary = {}) -> void:
	if not def.is_empty():
		_fetcher.register_layer(id, def)
	if base_layer == id:
		return
	base_layer = id
	for k in _patch_state:
		_patch_state[k].day = "?"
	_update_attribution()


## Clouds (an infrared equirect image, gray + alpha) on the weather shell,
## with their shadows on the ground; null hides them.
func set_clouds(tex: Texture2D) -> void:
	_has_clouds = tex != null
	_shell_mat.set_shader_parameter("has_clouds", _has_clouds)
	if tex != null:
		_shell_mat.set_shader_parameter("cloud_tex", tex)
	_wx_ground = {"has_cloud_shadow": tex != null}
	if tex != null:
		_wx_ground["cloud_tex"] = tex
	for m: ShaderMaterial in _all_surface_materials():
		for pn in _wx_ground:
			m.set_shader_parameter(pn, _wx_ground[pn])
	_update_shell()


## Rain (an RGBA equirect image, transparent where dry); null hides it.
func set_rain(tex: Texture2D) -> void:
	_has_rain = tex != null
	_shell_mat.set_shader_parameter("has_rain", _has_rain)
	if tex != null:
		_shell_mat.set_shader_parameter("rain_tex", tex)
	_update_shell()


func _update_shell() -> void:
	_shell.visible = _has_clouds or _has_rain


## Wind streamlines from GlobeWindField.line_arrays ({verts, uvs, cols}); an
## empty dict hides them.
func set_wind_lines(arr: Dictionary) -> void:
	if _wind_mi == null:
		_wind_mi = MeshInstance3D.new()
		_wind_mi.name = "WindLines"
		var m := ShaderMaterial.new()
		m.shader = WIND_SHADER
		_wind_mi.material_override = m
		_wind_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_globe.add_child(_wind_mi)
	var verts: PackedVector3Array = arr.get("verts", PackedVector3Array())
	if verts.is_empty():
		_wind_mi.visible = false
		_wind_lines = 0
		return
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_TEX_UV] = arr.uvs
	a[Mesh.ARRAY_COLOR] = arr.cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, a)
	_wind_mi.mesh = mesh
	_wind_mi.visible = true
	_wind_lines = verts.size() >> 1


## A world's photos on the globe: slot 0 the wide drape, 1 the fine one
## (GlobeDrape.shader_params "d0_" / "d1_" + a texture); tex null clears.
func set_drape(slot: int, tex: Texture2D, params: Dictionary = {}) -> void:
	var p := "d%d_" % slot
	_drape[p.trim_suffix("_").replace("d", "has_d")] = tex != null
	if tex != null:
		_drape[p + "tex"] = tex
		for k in params:
			_drape[k] = params[k]
	for m: ShaderMaterial in _all_surface_materials():
		for pn in _drape:
			m.set_shader_parameter(pn, _drape[pn])


func drape_on(slot: int) -> bool:
	return bool(_drape.get("has_d%d" % slot, false))


## A line on the ground through [lat, lon, lat, lon, ...] (doubles), closed
## when `closed`; drawn a little above it. Empty points remove it.
func set_outline(id: String, pts: PackedFloat64Array, color: Color, closed: bool = true) -> void:
	if _outlines.has(id):
		(_outlines[id] as Node).queue_free()
		_outlines.erase(id)
	if pts.size() < 4:
		return
	var verts := PackedVector3Array()
	for i in pts.size() / 2:
		verts.append(GlobeMath.to_unit(pts[i * 2], pts[i * 2 + 1]) * 1.000004)
	if closed:
		verts.append(verts[0])
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINE_STRIP, a)
	var mi := MeshInstance3D.new()
	mi.name = "Outline_%s" % id.validate_node_name()
	mi.mesh = mesh
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.no_depth_test = false
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_globe.add_child(mi)
	_outlines[id] = mi


func has_outline(id: String) -> bool:
	return _outlines.has(id)


func wind_segments() -> int:
	return _wind_lines


func has_clouds() -> bool:
	return _has_clouds


func has_rain() -> bool:
	return _has_rain


## The aurora layer: off, or on with the Kp of the globe's time and, near
## the present, NOAA's OVATION nowcast (an L8 probability texture).
## Shells stay faint; the field-line ribbons carry the height.
func set_aurora(on: bool, kp: float = 2.0, ovation: Texture2D = null) -> void:
	_aurora_on = on
	_aurora_kp = kp
	_ovation = ovation
	for i in _aurora.size():
		var m := _aurora_mats[i]
		m.set_shader_parameter("aurora_on", on)
		m.set_shader_parameter("aurora_kp", kp)
		m.set_shader_parameter("aurora_use_ovation", ovation != null)
		if ovation != null:
			m.set_shader_parameter("aurora_ovation", ovation)
	_push_curtain()
	if on:
		_rebuild_curtain(true)
	_apply_aurora_visible()


func aurora_on() -> bool:
	return _aurora_on


## Min and max radius of the curtain mesh, once it has been built. Zero before.
func aurora_curtain_span() -> Vector2:
	if _curtain == null or _curtain.mesh == null or _curtain.mesh.get_surface_count() == 0:
		return Vector2.ZERO
	return Vector2(1.0 + AuroraCurtains.H0_KM / AuroraCurtains.R_KM,
		1.0 + AuroraCurtains.H1_KM / AuroraCurtains.R_KM)


func poles_textured() -> bool:
	for c in _caps:
		var m := c.material_override as ShaderMaterial
		if m == null or not bool(m.get_shader_parameter("has_cap")):
			return false
	return true


## Sun, moon and planet paths. Off until asked. On the Moon, Sun is the
## subsolar track; the sky paths belong to the Earth.
func set_paths(sun_on: bool, moon_on: bool, planets_on: bool) -> void:
	_show_sun_path = sun_on
	_show_moon_path = moon_on
	_show_planet_paths = planets_on
	_path_key = ""
	_rebuild_paths()


## Latitude of the subsolar marker, degrees. 0 when the sun path is off.
func path_marker_lat() -> float:
	return _marker_lat


## Keeps the attribution clear of a panel this many pixels wide at the
## bottom-left.
func set_credits_left(px: float) -> void:
	if _attrib != null:
		_attrib.offset_left = px


## The attribution's height on screen (an owner keeps its panels above it).
func credits_height() -> float:
	return _attrib.size.y if _attrib != null else 0.0


## Extra credit lines for the attribution (weather layers in use).
func set_extra_credits(lines: Array) -> void:
	_credits_extra = lines
	_update_attribution()


func _update_attribution() -> void:
	if _attrib == null:
		return
	var ids := [base_layer]
	if base_layer != "esri":
		ids.append("esri")
	if night_lights:
		ids.append("night")
	var parts := PackedStringArray([_fetcher.attribution_for(ids)])
	for l in _credits_extra:
		parts.append(str(l))
	if _polar_live:
		parts.append(GlobePolarFill.CREDIT)
	if _moon_photo:
		parts.append(MoonGlobe.CREDIT)
	_attrib.text = " · ".join(parts)


func set_night_lights(on: bool) -> void:
	night_lights = on
	_update_attribution()
	if _lights != null:
		_lights.set_enabled(on)


## The city-light point layer (for checks).
func city_lights() -> GlobeCityLights:
	return _lights


func _push_overlay() -> void:
	for m: ShaderMaterial in _all_surface_materials():
		for pn in _overlay:
			m.set_shader_parameter(pn, _overlay[pn])


func selected_tiles() -> Array[Vector3i]:
	return _selected


func tile_fetcher() -> GlobeTileFetcher:
	return _fetcher


func camera() -> Camera3D:
	return _cam


func sun_direction() -> Vector3:
	return _sun


## One line for the harness / a debug readout.
func debug_line() -> String:
	var ll := center_latlon()
	var zmax := 0
	for k in _selected:
		zmax = maxi(zmax, k.x)
	return "centre %.4f, %.4f  alt %.1f km  tilt %.0f  tiles %d (max z %d)  textures %d  pending %d  dl %d  disk %d  failed %d" % [
		ll[0], ll[1], altitude_km(), cam_tilt, _selected.size(), zmax, _fetcher.texture_count(),
		_fetcher.pending_count(), int(_fetcher.stats.downloaded), int(_fetcher.stats.from_disk),
		int(_fetcher.stats.failed)]


# --- Frame ------------------------------------------------------------------

func _process(dt: float) -> void:
	if not is_visible_in_tree():
		return
	_step_motion(dt)
	if sun_continuous:
		_update_sun()
	else:
		_sun_t -= dt
		if _sun_t <= 0.0:
			_sun_t = 0.5
			_update_sun()
	_path_wait -= dt
	if _path_wait <= 0.0:
		_path_wait = 0.25
		_rebuild_paths()
	if _cam_dirty:
		_apply_camera()
	_reselect_t -= dt
	if _cam_dirty or _reselect_t <= 0.0:
		_reselect_t = RESELECT_S
		_cam_dirty = false
		_reselect()
	_lights.begin_frame()
	_request_and_bind()
	_lights.end_frame()
	_place_markers()
	if not (_caps_tinted[0] and _caps_tinted[1]):
		_tint_caps()


func _step_motion(dt: float) -> void:
	if not _fly.is_empty():
		var step_dt := minf(dt, 0.18) if GlobeLaunchTransition.is_active() else dt
		_fly.t = float(_fly.t) + step_dt
		var u := clampf(float(_fly.t) / float(_fly.dur), 0.0, 1.0)
		var e := u * u * (3.0 - 2.0 * u)
		var r0 := float(_fly.r0)
		var r1 := float(_fly.r1)
		var deep_dive := r0 > 0.08 and r1 < 0.005
		# On a deep orbital-to-site descent, finish centring the lateral target
		# early (first 55% of the flight) so the lower half descends straight
		# down the pre-staged tile column instead of sweeping sideways across
		# uncached z14-z17 tiles, and use `hop_peak` (not `r0`) so starting from
		# orbit descends steadily from frame 1 instead of zooming backward first.
		var e_pan := smoothstep(0.0, 0.55, u) if deep_dive else e
		_target = GlobeMath.slerp_dir(_fly.from, _fly.to, e_pan)
		var lr0 := log(r0)
		var lr1 := log(r1)
		var lp := log(float(_fly.get("hop_peak", _fly.peak)) if deep_dive else float(_fly.peak))
		var e_zoom := lerpf(u, e, 0.38) if deep_dive else e
		var base := lerpf(lr0, lr1, e_zoom)
		var bump := maxf(0.0, lp - lerpf(lr0, lr1, 0.5))
		cam_range = exp(base + bump * sin(PI * e_zoom))
		var h1 := float(_fly.get("h1", NAN))
		if is_finite(h1):
			var h0 := float(_fly.get("h0", cam_heading))
			var dh := wrapf(h1 - h0, -180.0, 180.0)
			cam_heading = fposmod(h0 + dh * smoothstep(0.18, 0.92, u), 360.0)
		if float(_fly.tilt1) >= 0.0:
			# Level out over the hop, then lean smoothly into the landing.
			cam_tilt = lerpf(float(_fly.tilt0) * (1.0 - smoothstep(0.0, 0.35, e)),
				float(_fly.tilt1), smoothstep(0.45, 1.0, e))
		else:
			cam_tilt = float(_fly.tilt0) * (1.0 - sin(PI * e))
		_cam_dirty = true
		if u >= 1.0:
			_fly.clear()
		return
	if _spin_rate > 1e-6 and not _dragging:
		_target = _target.rotated(_spin_axis, _spin_rate * dt).normalized()
		_spin_rate *= exp(-dt * 4.0)
		_cam_dirty = true
	if _range_goal > 0.0:
		var k := 1.0 - exp(-dt * 14.0)
		var nr := exp(lerpf(log(cam_range), log(_range_goal), k))
		if _zoom_toward_t > 0.0 and _zoom_toward != Vector3.ZERO:
			# Move toward the point under the pointer by the zoom's share.
			var share := clampf(1.0 - nr / cam_range, 0.0, 1.0)
			_target = GlobeMath.slerp_dir(_target, _zoom_toward, share)
		cam_range = nr
		_clamp_tilt()
		_cam_dirty = true
		if absf(log(cam_range / _range_goal)) < 0.002:
			cam_range = _range_goal
			_range_goal = -1.0
			_zoom_toward = Vector3.ZERO
	_step_keys(dt)


func _step_keys(dt: float) -> void:
	if not has_focus():
		return
	var mv := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
		mv.x -= 1.0
	if Input.is_physical_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
		mv.x += 1.0
	if Input.is_physical_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
		mv.y -= 1.0
	if Input.is_physical_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
		mv.y += 1.0
	if mv != Vector2.ZERO:
		_pan_pixels(mv * 500.0 * dt)
	var turn := 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		turn -= 1.0
	if Input.is_physical_key_pressed(KEY_E):
		turn += 1.0
	if turn != 0.0:
		cam_heading = fposmod(cam_heading + turn * 60.0 * dt, 360.0)
		_cam_dirty = true
	var tl := 0.0
	if Input.is_physical_key_pressed(KEY_R):
		tl += 1.0
	if Input.is_physical_key_pressed(KEY_F):
		tl -= 1.0
	if tl != 0.0:
		cam_tilt += tl * 40.0 * dt
		_clamp_tilt()
		_cam_dirty = true
	var z := 0.0
	if Input.is_physical_key_pressed(KEY_EQUAL) or Input.is_physical_key_pressed(KEY_KP_ADD):
		z -= 1.0
	if Input.is_physical_key_pressed(KEY_MINUS) or Input.is_physical_key_pressed(KEY_KP_SUBTRACT):
		z += 1.0
	if z != 0.0:
		cam_range = clampf(cam_range * exp(z * 1.6 * dt), MIN_RANGE, _max_range())
		_range_goal = -1.0
		_clamp_tilt()
		_cam_dirty = true


func _max_tilt() -> float:
	# Tilt opens up as the camera comes down: none from orbit, full near the
	# ground. On the Moon (no tile pyramid to protect) it is always free.
	if _body == "moon":
		return MAX_TILT_DEG + 5.0
	var t := clampf((log(cam_range) - log(0.25)) / (log(0.004) - log(0.25)), 0.0, 1.0)
	return MAX_TILT_DEG * t


func _clamp_tilt() -> void:
	cam_tilt = clampf(cam_tilt, 0.0, _max_tilt())


## The camera in the GLOBE frame from the body-frame orbit point: the body's
## centre, radius and basis carry it (the Earth: origin, 1, identity).
func _cam_frame() -> Dictionary:
	var ll := GlobeMath.to_latlon(_target)
	var n := GlobeMath.north_at(ll[0], ll[1])
	var e := GlobeMath.east_at(ll[1])
	var h := deg_to_rad(cam_heading)
	var t := deg_to_rad(cam_tilt)
	var hv := (n * cos(h) + e * sin(h)).normalized()
	var back := _target * cos(t) - hv * sin(t)
	var b := _body_basis()
	var c := _body_centre()
	var sc := _body_scale()
	return {"pos": c + b * (_target + back * cam_range) * sc, "up": b * (hv * cos(t) + _target * sin(t)),
		"look": c + b * _target * sc}


func _cam_pos() -> Vector3:
	return _cam_frame().pos


func _apply_camera() -> void:
	if _cam == null:
		return
	var f := _cam_frame()
	var pos: Vector3 = f.pos
	_cam.global_transform = Transform3D(Basis.looking_at((f.look as Vector3) - pos, f.up), pos)
	var alt := maxf((pos - _body_centre()).length() - _body_scale(), 1e-7)
	_cam.near = clampf(alt * 0.35, 1e-7, 0.05)
	# Far enough for the Moon (or the Earth, from the Moon) and the sky paths.
	var reach := 4.0
	if _moon_mi != null:
		reach = maxf(reach, _moon_mi.position.length() + 1.5 + pos.length())
	reach = maxf(reach, AnalemmaPaths.SKY_R + 2.0 + pos.length())
	_cam.far = cam_range * _body_scale() + reach
	_apply_path_visibility()
	view_changed.emit()


## The globe's instant (UTC Julian Day): time_provider, else the computer's clock.
func current_jd() -> float:
	if time_provider.is_valid():
		return float(time_provider.call())
	return GlobeMath.jd_from_unix(Time.get_unix_time_from_system())


func _update_sun() -> void:
	var jd := current_jd()
	_sun = GlobeMath.sun_dir(jd)
	for m: ShaderMaterial in _all_surface_materials():
		m.set_shader_parameter("sun_dir", _sun)
	_atmo_mat.set_shader_parameter("sun_dir", _sun)
	for am in _aurora_mats:
		am.set_shader_parameter("sun_dir", _sun)
		am.set_shader_parameter("aurora_sun", _sun)
	_shell_mat.set_shader_parameter("sun_dir", _sun)
	_sky_mat.set_shader_parameter("sun_dir", _sun)
	_sky_mat.set_shader_parameter("gmst_deg", StarSkyMath.gmst_deg(jd))
	_push_curtain()
	if _aurora_on:
		_rebuild_curtain(false)
	if _lights != null:
		_lights.set_sun(_sun)
	_place_moon()
	_update_polar_date(jd)
	_update_marker(jd)
	_place_planet_basis(jd)


func _all_surface_materials() -> Array:
	var out := []
	for c in _caps:
		out.append(c.material_override)
	for k in _patches:
		out.append((_patches[k] as MeshInstance3D).material_override)
	return out


# --- Tiles -------------------------------------------------------------------

func _reselect() -> void:
	var vs := Vector2(_vp.size)
	if vs.x < 4.0 or vs.y < 4.0:
		return
	_selected = GlobeQuadtree.select(_cam.global_position, _cam.global_transform.basis, FOV_DEG,
		vs.x / vs.y, vs.y, max_zoom, tile_budget)
	var want := {}
	for k in _selected:
		want[k] = true
		if not _patches.has(k):
			_make_patch(k)
	for k in _patches.keys():
		if not want.has(k):
			var mi: MeshInstance3D = _patches[k]
			_patches.erase(k)
			_patch_state.erase(k)
			mi.queue_free()


func _make_patch(k: Vector3i) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _tile_mesh(k)
	mi.position = GlobeMath.tile_point(k.x, k.y, k.z, 0.5, 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := ShaderMaterial.new()
	m.shader = SURFACE_SHADER
	m.set_shader_parameter("sun_dir", _sun)
	for pn in _overlay:
		m.set_shader_parameter(pn, _overlay[pn])
	for pn in _wx_ground:
		m.set_shader_parameter(pn, _wx_ground[pn])
	for pn in _drape:
		m.set_shader_parameter(pn, _drape[pn])
	mi.material_override = m
	_globe.add_child(mi)
	_patches[k] = mi
	_patch_state[k] = {"day": "", "night": ""}


func _request_and_bind() -> void:
	_fetcher.begin_frame()
	# The coarse world is always wanted, so every patch has some ancestor.
	for x in 4:
		for y in 4:
			_fetcher.want("esri", Vector3i(2, x, y), -10.0)
			if base_layer != "esri":
				_fetcher.want(base_layer, Vector3i(2, x, y), -9.5)
			if night_lights:
				_fetcher.want("night", Vector3i(2, x, y), -9.0)
	_prestage_flight_pyramid()
	var view_dir := _target
	for k in _selected:
		var c: Vector3 = (_patches[k] as MeshInstance3D).position
		var prio := float(k.x) * 0.25 + c.distance_to(view_dir) * 6.0
		var bz := mini(k.x, _fetcher.max_zoom(base_layer))
		_fetcher.want(base_layer, GlobeMath.ancestor(k, bz), prio)
		if bz > 4:
			_fetcher.want(base_layer, GlobeMath.ancestor(k, maxi(bz - 2, 3)), prio - 1.2)
		if bz > 8:
			_fetcher.want(base_layer, GlobeMath.ancestor(k, bz - 5), prio - 2.0)
		var nk := GlobeMath.ancestor(k, mini(k.x, _fetcher.max_zoom("night")))
		if night_lights:
			_fetcher.want("night", nk, prio + 0.5)
		_bind(k)


## Keeps the destination zoom spine (z3 -> z17, coarse-first) in `_wanted`
## throughout a deep flight so `_drop_unwanted` never cancels intermediate or
## landing tiles as `_selected` steps through zoom levels.
func _prestage_flight_pyramid() -> void:
	if _body != "earth":
		return
	var la := NAN
	var lo := NAN
	if _prestage_ll.size() == 2:
		la = _prestage_ll[0]
		lo = _prestage_ll[1]
	elif not _fly.is_empty() and float(_fly.get("r1", 1.0)) < 0.02 and _fly.has("dest_lat"):
		la = float(_fly.dest_lat)
		lo = float(_fly.dest_lon)
	if not is_finite(la) or not is_finite(lo) or absf(la) >= GlobeMath.MERCATOR_MAX_LAT:
		return
	var z_cap := mini(max_zoom, _fetcher.max_zoom(base_layer))
	for z in range(3, z_cap + 1):
		var kt := GlobeMath.tile_at(la, lo, z)
		# Coarse-to-fine priority (-8.5 up to -1.5) so intermediate rungs always
		# arrive before finer ones, ahead of peripheral tiles.
		var base_prio := -8.8 + float(z) * 0.42
		_fetcher.want(base_layer, kt, base_prio)
		if z == 8 or z == 11 or z == 13 or z == 15 or z == 16 or z == 17:
			var n_tiles := 1 << z
			for dy in range(-1, 2):
				var ty := kt.z + dy
				if ty < 0 or ty >= n_tiles:
					continue
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var tx := (kt.y + dx + n_tiles) % n_tiles
					_fetcher.want(base_layer, Vector3i(z, tx, ty), base_prio + 0.35)


func _bind(k: Vector3i) -> void:
	var mi: MeshInstance3D = _patches[k]
	var st: Dictionary = _patch_state[k]
	var m := mi.material_override as ShaderMaterial
	var day := _best(base_layer, k, mini(k.x, _fetcher.max_zoom(base_layer)))
	if day.is_empty() and base_layer != "esri":
		day = _best("esri", k, k.x)
	if str(day.get("ks", "")) != str(st.day):
		st.day = str(day.get("ks", ""))
		m.set_shader_parameter("has_day", day.has("tex"))
		if day.has("tex"):
			m.set_shader_parameter("day_tex", day.tex)
			m.set_shader_parameter("day_rect", day.rect)
	# City lights: the finest night tile in memory over this patch becomes a
	# point cloud (GlobeCityLights); the ground shader draws no night texture.
	if night_lights:
		var nz := mini(k.x, _fetcher.max_zoom("night"))
		for z in range(nz, -1, -1):
			var a := GlobeMath.ancestor(k, z)
			var img := _fetcher.get_image("night", a)
			if img != null:
				_lights.use(a, img)
				break


## The finest loaded texture for a tile at or above zoom `from_z`.
func _best(layer: String, k: Vector3i, from_z: int) -> Dictionary:
	for z in range(from_z, -1, -1):
		var a := GlobeMath.ancestor(k, z)
		var tex := _fetcher.get_texture(layer, a)
		if tex != null:
			return {"tex": tex, "rect": GlobeMath.uv_rect_in(k, a), "ks": GlobeTileFetcher.key_str(layer, a)}
	return {}


## A curved patch for tile k, relative to the tile centre (float32 stays
## precise near the ground), with a skirt round the edge so a neighbour at a
## different zoom never shows a crack. Triangles wound clockwise seen from
## outside (Godot's front face).
func _tile_mesh(k: Vector3i) -> ArrayMesh:
	if _mesh_cache.has(k):
		return _mesh_cache[k]
	var c := GlobeMath.tile_point(k.x, k.y, k.z, 0.5, 0.5)
	var n := SEGMENTS
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in n + 1:
		for i in n + 1:
			var u := float(i) / float(n)
			var v := float(j) / float(n)
			var p := GlobeMath.tile_point(k.x, k.y, k.z, u, v)
			verts.append(p - c)
			uvs.append(Vector2(u, v))
			norms.append(p)
	var seg_ang := GlobeMath.tile_point(k.x, k.y, k.z, 0.5, 0.5).distance_to(
		GlobeMath.tile_point(k.x, k.y, k.z, 0.5 + 1.0 / float(n), 0.5))
	var drop := maxf(seg_ang * seg_ang * 0.35, 3e-6)
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			_tri(verts, norms, idx, a, a + 1, a + n + 1)
			_tri(verts, norms, idx, a + 1, a + n + 2, a + n + 1)
	# Skirts: each edge vertex gets a twin pulled toward the centre.
	var edges := [[], [], [], []]
	for i in n + 1:
		edges[0].append(i)
		edges[1].append(n * (n + 1) + i)
		edges[2].append(i * (n + 1))
		edges[3].append(i * (n + 1) + n)
	for e: Array in edges:
		var base := verts.size()
		for vi: int in e:
			var p := (verts[vi] + c) * (1.0 - drop)
			verts.append(p - c)
			uvs.append(uvs[vi])
			norms.append(norms[vi])
		for s in e.size() - 1:
			var a: int = e[s]
			var b: int = e[s + 1]
			var a2 := base + s
			var b2 := base + s + 1
			# Both windings: a skirt is a thin wall seen from either side.
			idx.append_array(PackedInt32Array([a, b, b2, a, b2, a2, a, b2, b, a, a2, b2]))
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	_mesh_cache[k] = mesh
	_mesh_order.append(k)
	if _mesh_order.size() > MESH_CACHE:
		var old: Vector3i = _mesh_order.pop_front()
		if not _patches.has(old):
			_mesh_cache.erase(old)
	return mesh


static func _tri(verts: PackedVector3Array, norms: PackedVector3Array, idx: PackedInt32Array,
		a: int, b: int, c: int) -> void:
	var cr := (verts[b] - verts[a]).cross(verts[c] - verts[a])
	if cr.dot(norms[a]) > 0.0:
		idx.append_array(PackedInt32Array([a, c, b]))
	else:
		idx.append_array(PackedInt32Array([a, b, c]))


## Each cap takes the mean colour of the pixels along the last Mercator row
## next to it (z2 tiles: Arctic sea, Antarctic ice), so the pole does not
## read as a grey disc stuck on the globe.
func _tint_caps() -> void:
	for i in 2:
		if _caps_tinted[i]:
			continue
		var row := 0 if i == 0 else 3
		var sum := Vector3.ZERO
		var cnt := 0
		var ok := true
		for x in 4:
			var tex := _fetcher.get_texture("esri", Vector3i(2, x, row))
			if tex == null:
				ok = false
				break
			var img := tex.get_image()
			if img == null or img.is_empty():
				ok = false
				break
			if img.is_compressed():
				img.decompress()
			var py := 1 if i == 0 else img.get_height() - 2
			for px in range(0, img.get_width(), 4):
				var c := img.get_pixel(px, py)
				sum += Vector3(c.r, c.g, c.b)
				cnt += 1
		if not ok or cnt == 0:
			continue
		sum /= float(cnt)
		(_caps[i].material_override as ShaderMaterial).set_shader_parameter("solid_color",
			Color(sum.x, sum.y, sum.z))
		_caps_tinted[i] = true


## A cap over a pole, from the pole to the last Mercator row.
## UV is polar stereographic (GlobePolarFill): the pole at the centre.
func _cap_mesh(north: bool) -> ArrayMesh:
	var sgn := 1.0 if north else -1.0
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var rings := 4
	verts.append(Vector3(0, sgn, 0))
	norms.append(Vector3(0, sgn, 0))
	uvs.append(GlobePolarFill.uv_of(90.0 * sgn, 0.0))
	for r in range(1, rings + 1):
		var lat := sgn * lerpf(90.0, GlobeMath.MERCATOR_MAX_LAT - 0.02, float(r) / float(rings))
		for s in CAP_SEGMENTS:
			var lon := float(s) / float(CAP_SEGMENTS) * 360.0 - 180.0
			var p := GlobeMath.to_unit(lat, lon)
			verts.append(p)
			norms.append(p)
			uvs.append(GlobePolarFill.uv_of(lat, lon))
	for s in CAP_SEGMENTS:
		var s1 := (s + 1) % CAP_SEGMENTS
		_tri(verts, norms, idx, 0, 1 + s, 1 + s1)
	for r in rings - 1:
		var o := 1 + r * CAP_SEGMENTS
		var o2 := o + CAP_SEGMENTS
		for s in CAP_SEGMENTS:
			var s1 := (s + 1) % CAP_SEGMENTS
			_tri(verts, norms, idx, o + s, o + s1, o2 + s)
			_tri(verts, norms, idx, o + s1, o2 + s1, o2 + s)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh


## Pins sit on the ground at a constant screen size. Labels are decluttered:
## a label shows only if it is on the near side and no label already placed
## (priority first: markers whose id does not start with "world_", then
## nearest the screen centre) is within LABEL_GAP_PX.
const LABEL_GAP_PX := Vector2(150.0, 28.0)

func _place_markers() -> void:
	if _markers.is_empty():
		return
	if _body != "earth":
		for id in _markers:
			(_markers[id] as Node3D).visible = false
		return
	var cp := _cam.global_position
	var cands: Array = []
	var mid := size * 0.5
	for id in _markers:
		var root: Node3D = _markers[id]
		var d: Vector3 = root.get_meta("dir")
		var dist := maxf((d - cp).length(), 1e-6)
		var s := dist * 0.006
		root.position = d * (1.0 + s * 0.8)
		var dot := root.get_child(0) as Node3D
		dot.scale = Vector3.ONE * s
		var front := d.dot(cp) > 1.0
		root.visible = front
		if root.get_child_count() > 1:
			var l := root.get_child(1) as Label3D
			l.visible = false
			if front and (labels_on or not str(id).begins_with("world_")):
				var sp := latlon_to_local_dir(d)
				if sp != Vector2.INF:
					var pri := 0.0 if not str(id).begins_with("world_") else 1.0
					cands.append([pri + sp.distance_to(mid) / maxf(size.length(), 1.0), sp, l])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	var placed: Array[Vector2] = []
	for c in cands:
		var sp: Vector2 = c[1]
		var ok := true
		for q in placed:
			if absf(q.x - sp.x) < LABEL_GAP_PX.x and absf(q.y - sp.y) < LABEL_GAP_PX.y:
				ok = false
				break
		if ok:
			placed.append(sp)
			(c[2] as Label3D).visible = true


## The world-pin names showing now (for checks).
func visible_world_labels() -> PackedStringArray:
	var out := PackedStringArray()
	for id in _markers:
		if not str(id).begins_with("world_"):
			continue
		var root: Node3D = _markers[id]
		if root.visible and root.get_child_count() > 1 and (root.get_child(1) as Label3D).visible:
			out.append((root.get_child(1) as Label3D).text)
	return out


## Screen point of a unit direction on the ground, or INF.
func latlon_to_local_dir(d: Vector3) -> Vector2:
	if d.dot(_cam.global_position) <= 1.0 or _cam.is_position_behind(d):
		return Vector2.INF
	return _cam.unproject_position(d) * (size / Vector2(_vp.size))


# --- Input -----------------------------------------------------------------

func _to_vp(local_pos: Vector2) -> Vector2:
	if size.x <= 0.0 or size.y <= 0.0:
		return local_pos
	return local_pos * (Vector2(_vp.size) / size)


## The body-frame unit direction under a point of this control (the body the
## camera orbits), or ZERO off the body.
func _pick_dir(local_pos: Vector2) -> Vector3:
	var vpp := _to_vp(local_pos)
	var o := _cam.project_ray_origin(vpp)
	var d := _cam.project_ray_normal(vpp)
	var c := _body_centre()
	var t := GlobeMath.ray_sphere(o - c, d, _body_scale())
	if t < 0.0:
		return Vector3.ZERO
	return (_body_basis().inverse() * (o + d * t - c)).normalized()


func _pan_pixels(px: Vector2) -> void:
	var k := cam_range * 2.0 * tan(deg_to_rad(FOV_DEG) * 0.5) / maxf(1.0, float(_vp.size.y))
	k = minf(k, PI / maxf(1.0, float(_vp.size.y)) * 1.5)
	var cb := _cam.global_transform.basis
	var inv := _body_basis().inverse()
	var b := Basis(inv * cb.x, inv * cb.y, inv * cb.z)
	# Screen right / up projected on the tangent plane.
	var right := (b.x - _target * b.x.dot(_target)).normalized()
	var up := (b.y - _target * b.y.dot(_target))
	if up.length() < 1e-4:
		up = _target.cross(right)
	up = up.normalized()
	var step := right * px.x - up * px.y
	var ang := step.length() * k
	if ang <= 0.0:
		return
	var axis := _target.cross(step.normalized()).normalized()
	_target = _target.rotated(axis, ang).normalized()
	_cam_dirty = true


func _gui_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_zoom_step(mb.position, mb.button_index == MOUSE_BUTTON_WHEEL_UP, mb.factor)
			accept_event()
			return
		if mb.pressed:
			grab_focus()
			_fly.clear()
			_spin_rate = 0.0
			_press_pos = mb.position
			_press_ms = Time.get_ticks_msec()
			_dragging = true
			_drag_button = mb.button_index
			_grab_dir = _pick_dir(mb.position)
			if mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT:
				if _body_hit(mb.position) != "":
					companion_clicked.emit()
				else:
					var dd := _pick_dir(mb.position)
					if dd != Vector3.ZERO:
						var ll := GlobeMath.to_latlon(dd)
						point_double_clicked.emit(ll[0], ll[1])
						fly_to(ll[0], ll[1], cam_range * 0.3)
				_dragging = false
		else:
			if _dragging and mb.button_index == _drag_button:
				_dragging = false
				var moved := mb.position.distance_to(_press_pos)
				if mb.button_index == MOUSE_BUTTON_LEFT and moved < CLICK_PX \
						and Time.get_ticks_msec() - _press_ms < 600:
					_spin_rate = 0.0
					if _body_hit(mb.position) != "":
						companion_clicked.emit()
					else:
						var d := _pick_dir(mb.position)
						if d != Vector3.ZERO:
							var ll2 := GlobeMath.to_latlon(d)
							point_clicked.emit(ll2[0], ll2[1])
		accept_event()
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if _dragging and _drag_button == MOUSE_BUTTON_LEFT:
			_drag_grab(mm)
		elif _dragging and (_drag_button == MOUSE_BUTTON_RIGHT or _drag_button == MOUSE_BUTTON_MIDDLE):
			cam_heading = fposmod(cam_heading - mm.relative.x * 0.25, 360.0)
			cam_tilt += mm.relative.y * 0.25
			_clamp_tilt()
			_cam_dirty = true
		hovered_body = _body_hit(mm.position)
		if hovered_body != "":
			point_hovered.emit(0.0, 0.0, false)
		else:
			var hd := _pick_dir(mm.position)
			if hd != Vector3.ZERO:
				var hl := GlobeMath.to_latlon(hd)
				point_hovered.emit(hl[0], hl[1], true)
			else:
				point_hovered.emit(0.0, 0.0, false)
		accept_event()
	elif ev is InputEventKey and (ev as InputEventKey).pressed:
		var kc := (ev as InputEventKey).physical_keycode
		if kc == KEY_N:
			cam_heading = 0.0
			_cam_dirty = true
			accept_event()


## Keeps the grabbed ground point under the pointer: the orbit point turns
## by the rotation that carries the point now under the pointer back onto the
## grabbed one. Off the globe it falls back to a screen-scaled pan.
func _drag_grab(mm: InputEventMouseMotion) -> void:
	var now := _pick_dir(mm.position)
	if _grab_dir == Vector3.ZERO or now == Vector3.ZERO:
		_pan_pixels(-mm.relative)
		return
	var axis := now.cross(_grab_dir)
	var s := axis.length()
	if s < 1e-12:
		return
	axis /= s
	var ang := atan2(s, now.dot(_grab_dir))
	_target = _target.rotated(axis, ang).normalized()
	var dtm := maxf(get_process_delta_time(), 1e-3)
	_spin_axis = axis
	_spin_rate = lerpf(_spin_rate, ang / dtm, 0.5)
	_cam_dirty = true
	_apply_camera()


func _zoom_step(local_pos: Vector2, zoom_in: bool, factor: float) -> void:
	_fly.clear()
	var f := pow(0.8, maxf(factor, 1.0)) if zoom_in else pow(1.0 / 0.8, maxf(factor, 1.0))
	var base := _range_goal if _range_goal > 0.0 else cam_range
	_range_goal = clampf(base * f, MIN_RANGE, _max_range())
	if zoom_in:
		var d := _pick_dir(local_pos)
		_zoom_toward = d
		_zoom_toward_t = 1.0 if d != Vector3.ZERO else 0.0
	else:
		_zoom_toward = Vector3.ZERO
		_zoom_toward_t = 0.0


# --- Aurora curtains, poles, the Moon, paths ---------------------------------

## A constant-pixel-width line (globe_path.gdshader) under `parent`.
func _path_line(parent: Node, node_name: String, color: Color, width_px: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var m := ShaderMaterial.new()
	m.shader = PATH_SHADER
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("width_px", width_px)
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	parent.add_child(mi)
	return mi


func _path_dot(parent: Node, node_name: String, color: Color, radius: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	sm.radial_segments = 16
	sm.rings = 8
	mi.mesh = sm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	parent.add_child(mi)
	return mi


static func _set_head(mi: MeshInstance3D, head: float) -> void:
	(mi.material_override as ShaderMaterial).set_shader_parameter("head", head)


func _apply_aurora_visible() -> void:
	var on := _aurora_on
	for a in _aurora:
		a.visible = on
	if _curtain != null:
		_curtain.visible = on


func _push_curtain() -> void:
	if _curtain_mat == null:
		return
	_curtain_mat.set_shader_parameter("aurora_on", _aurora_on)
	_curtain_mat.set_shader_parameter("aurora_kp", _aurora_kp)
	_curtain_mat.set_shader_parameter("aurora_sun", _sun)
	_curtain_mat.set_shader_parameter("sun_dir", _sun)
	_curtain_mat.set_shader_parameter("aurora_pole", AuroraModel.pole_dir())
	_curtain_mat.set_shader_parameter("aurora_use_ovation", _ovation != null)
	if _ovation != null:
		_curtain_mat.set_shader_parameter("aurora_ovation", _ovation)


func _rebuild_curtain(force: bool) -> void:
	if _curtain == null or not _aurora_on:
		return
	var pole := AuroraModel.pole_dir()
	var lon := AuroraCurtains.mag_lon(_sun, pole)
	var dlon := absf(wrapf(lon - _curtain_lon, -PI, PI))
	if not force and absf(_aurora_kp - _curtain_kp) < 0.25 and dlon < deg_to_rad(8.0) \
			and _curtain.mesh != null:
		return
	_curtain_kp = _aurora_kp
	_curtain_lon = lon
	_curtain.mesh = AuroraCurtains.build_mesh(_aurora_kp, _sun, pole)


func _apply_polar_fallback() -> void:
	for i in 2:
		var m := _caps[i].material_override as ShaderMaterial
		m.set_shader_parameter("cap_tex", GlobePolarFill.fallback_texture(i == 0))
		m.set_shader_parameter("has_cap", true)


func _on_polar_cap(north: bool, tex: Texture2D, live: bool) -> void:
	var m := _caps[0 if north else 1].material_override as ShaderMaterial
	m.set_shader_parameter("cap_tex", tex)
	m.set_shader_parameter("has_cap", true)
	if live:
		_polar_live = true
		_update_attribution()


func _update_polar_date(jd: float) -> void:
	if _polar == null:
		return
	var u := GlobeWeather.unix_from_jd(jd)
	if u < GlobeWeather.MODIS_EARLIEST:
		return
	var date := GlobeWeather.daily_date(u, Time.get_unix_time_from_system())
	if date == _polar_date:
		return
	_polar_date = date
	_polar.request_date(date)


## The LRO colour mosaic: the 4k cut from the cache or the net, the 1k behind it.
func _fetch_moon() -> void:
	for path in [MoonGlobe.CACHE, MoonGlobe.CACHE_SMALL]:
		if FileAccess.file_exists(path):
			var img := Image.new()
			if img.load(path) == OK:
				img.generate_mipmaps()
				_set_moon_tex(ImageTexture.create_from_image(img))
				if path == MoonGlobe.CACHE:
					return
				break
	if GlobeTileFetcher.offline_for_test:
		return
	_moon_http = HTTPRequest.new()
	_moon_http.timeout = 40.0
	_moon_http.use_threads = true
	_moon_http.name = "MoonFetch"
	add_child(_moon_http)
	_moon_http.request_completed.connect(_on_moon_tex)
	_moon_http.request(MoonGlobe.COLOR_URL)


func _on_moon_tex(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not is_inside_tree() or _moon_http == null or not _moon_http.is_inside_tree():
		return
	var img := Image.new()
	if result != HTTPRequest.RESULT_SUCCESS or code != 200 or img.load_jpg_from_buffer(body) != OK:
		if not _moon_small_tried:
			_moon_small_tried = true
			_moon_http.request(MoonGlobe.COLOR_URL_SMALL)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://globe_cache"))
	img.save_jpg(MoonGlobe.CACHE if not _moon_small_tried else MoonGlobe.CACHE_SMALL, 0.9)
	img.generate_mipmaps()
	_set_moon_tex(ImageTexture.create_from_image(img))


func _set_moon_tex(tex: Texture2D) -> void:
	if _moon_mat == null:
		return
	_moon_mat.set_shader_parameter("albedo_tex", tex)
	_moon_mat.set_shader_parameter("has_tex", true)
	_moon_photo = true
	_update_attribution()


## The Moon where it really is: its true distance and direction, near side
## toward the Earth, lit by the same Sun. The camera follows it when it is
## the body being orbited.
func _place_moon() -> void:
	if _moon_mi == null:
		return
	var jd := current_jd()
	_moon_basis = MoonGlobe.basis(jd)
	_moon_mi.transform = Transform3D(_moon_basis.scaled(Vector3.ONE * MoonGlobe.RADIUS_RATIO),
		MoonGlobe.position(jd))
	_moon_mat.set_shader_parameter("sun_dir", _sun)
	_moon_mat.set_shader_parameter("irradiance", _irradiance and _body == "moon")
	if _moon_label != null:
		_moon_label.position = _moon_mi.position
		_moon_label.visible = _body == "earth"
		var ph := MoonGlobe.phase(jd)
		_moon_label.text = "Moon\n%s km · %s %d %%" % [UiText.thousands(int(roundf(MoonGlobe.distance_km(jd) / 100.0) * 100.0)),
			str(ph.name).to_lower(), int(round(float(ph.lit) * 100.0))]
	if _body == "moon":
		_cam_dirty = true


## "moon" or "earth" when the pointer is on the body the camera is NOT
## orbiting and it is in front of the one it is, else "". A body that is a
## few pixels across is still caught inside BODY_PICK_PX.
func _body_hit(local_pos: Vector2) -> String:
	if _cam == null or _moon_mi == null:
		return ""
	var which := "moon" if _body == "earth" else "earth"
	var centre := _moon_mi.position if which == "moon" else Vector3.ZERO
	var radius := MoonGlobe.RADIUS_RATIO if which == "moon" else 1.0
	var vpp := _to_vp(local_pos)
	var o := _cam.project_ray_origin(vpp)
	var d := _cam.project_ray_normal(vpp)
	var dist := (centre - o).length()
	var per_px := 2.0 * dist * tan(deg_to_rad(FOV_DEG) * 0.5) / maxf(1.0, float(_vp.size.y))
	var r := maxf(radius, BODY_PICK_PX * 0.5 * per_px)
	var t_c := GlobeMath.ray_sphere(o - centre, d, r)
	if t_c < 0.0:
		return ""
	var t_g := GlobeMath.ray_sphere(o - _body_centre(), d, _body_scale())
	if t_g >= 0.0 and t_g < t_c:
		return ""
	return which


## Today's subsolar points (Earth, Moon) and today's Sun on the analemma.
func _update_marker(jd: float) -> void:
	if _path_marker == null:
		return
	var sub := GlobeMath.subsolar_point(jd)
	_marker_lat = sub[0]
	_path_marker.position = GlobeMath.to_unit(sub[0], sub[1]) * 1.012
	_path_marker.visible = _show_sun_path and _body == "earth"
	var ms := MoonGlobe.subsolar_latlon(jd)
	_moon_sub_marker.position = GlobeMath.to_unit(ms[0], ms[1]) * 1.03
	_moon_sub_marker.visible = _show_sun_path and _body == "moon"
	if _body == "moon":
		_marker_lat = ms[0]
	# The Sun's place in the orbit point's sky right now.
	var up := _target
	var r := _dome_radius()
	_sun_now.visible = _show_sun_path and _body == "earth" and _sun.dot(up) > 0.0
	if _sun_now.visible:
		_sun_now.position = up * (1.0 + 0.002) + _sun * r
		(_sun_now.mesh as SphereMesh).radius = r * 0.05
		(_sun_now.mesh as SphereMesh).height = r * 0.1


func _place_planet_basis(jd: float) -> void:
	if _path_planets.is_empty():
		return
	var b := AnalemmaPaths.equatorial_to_globe(StarSkyMath.gmst_deg(jd))
	for pack in _path_planets:
		var mi: MeshInstance3D = pack.line
		if is_instance_valid(mi):
			mi.basis = b


func _apply_path_visibility() -> void:
	var earth := _body == "earth"
	if _path_sun == null:
		return
	_path_sun.visible = _show_sun_path and earth
	_path_dome.visible = _show_sun_path and earth
	_path_ground.visible = _show_sun_path and earth
	_moon_sub_track.visible = _show_sun_path and not earth
	_path_moon_orbit.visible = _show_moon_path and earth
	_path_moon_ground.visible = _show_moon_path
	for pack in _path_planets:
		if is_instance_valid(pack.line):
			(pack.line as MeshInstance3D).visible = _show_planet_paths and earth


## The sky dome drawn over the orbit point: a share of the camera range, in
## steps so a wheel notch does not rebuild it.
func _dome_radius() -> float:
	var r := clampf(cam_range * AnalemmaPaths.DOME_SHARE, 0.003, 0.22)
	return exp(round(log(r) / log(1.3)) * log(1.3))


## Builds whatever paths are on and stale. Three keys: the orbit point's sky
## (lat, lon, hour, dome size), the day (ground tracks, the Moon's orbit)
## and the planets (the day too; they do not depend on the place).
func _rebuild_paths() -> void:
	if _path_root == null:
		return
	if not (_show_sun_path or _show_moon_path or _show_planet_paths):
		if _path_key != "off":
			_path_key = "off"
			_apply_path_visibility()
			_path_marker.visible = false
			_moon_sub_marker.visible = false
			_sun_now.visible = false
		return
	var ll := center_latlon()
	var jd := current_jd()
	var hour := AnalemmaPaths.mean_solar_hour(jd, ll[1])
	var day := floorf(jd + 0.5)
	var key := "%s|%.0f|%.0f|%.1f|%.4f|%d|%d|%d|%d" % [_body, ll[0], ll[1], hour, _dome_radius(),
		int(_show_sun_path), int(_show_moon_path), int(_show_planet_paths), int(day)]
	if key == _path_key:
		_apply_path_visibility()
		return
	var parts := _path_key.split("|")
	var same_day := parts.size() == 9 and parts[8] == str(int(day)) and parts[0] == _body
	var same_sky := same_day and parts[1] == "%.0f" % ll[0] and parts[2] == "%.0f" % ll[1] \
		and parts[3] == "%.1f" % hour and parts[4] == "%.4f" % _dome_radius()
	_path_key = key
	var year := AnalemmaPaths.year_of(jd)
	var doy_frac := float(AnalemmaPaths.doy_of(jd)) / (366.0 if AnalemmaPaths.is_leap(year) else 365.0)
	if _body == "moon":
		if _show_sun_path and not same_day:
			var lifted := PackedVector3Array()
			for p in MoonGlobe.subsolar_track(jd):
				lifted.append(p * 1.004)
			_moon_sub_track.mesh = AnalemmaPaths.line_mesh(lifted, 0.45)
			_set_head(_moon_sub_track, 0.5)
		if _show_moon_path and not same_day:
			_rebuild_sublunar(jd)
		_apply_path_visibility()
		_update_marker(jd)
		return
	var lat := ll[0]
	var lon := ll[1]
	var up := GlobeMath.to_unit(lat, lon)
	if _show_sun_path:
		if not same_sky:
			var r := _dome_radius()
			var sky := PackedVector3Array()
			for d in AnalemmaPaths.sun_sky(lat, lon, year, hour):
				sky.append(up * 1.002 + AnalemmaPaths.horizon_to_globe(lat, lon, d) * r)
			_path_sun.mesh = AnalemmaPaths.line_mesh(sky, r * 0.5)
			_set_head(_path_sun, doy_frac)
			var ring := PackedVector3Array()
			var north := GlobeMath.north_at(lat, lon)
			var east := GlobeMath.east_at(lon)
			for i in 96:
				var a := TAU * float(i) / 96.0
				ring.append(up * 1.002 + (north * cos(a) + east * sin(a)) * r)
			_path_dome.mesh = AnalemmaPaths.line_mesh(ring, r, true)
		if not same_day:
			var ground := PackedVector3Array()
			for p in AnalemmaPaths.subsolar_track(jd):
				ground.append(p * 1.003)
			_path_ground.mesh = AnalemmaPaths.line_mesh(ground, 0.5)
			_set_head(_path_ground, 0.5)
	if _show_moon_path and not same_day:
		var orbit := AnalemmaPaths.moon_orbit(jd)
		_path_moon_orbit.mesh = AnalemmaPaths.line_mesh(orbit, 30.0)
		_set_head(_path_moon_orbit, 0.5)
		_rebuild_sublunar(jd)
	if _show_planet_paths and (not same_day or _path_planets.is_empty()):
		for pack in _path_planets:
			if is_instance_valid(pack.line):
				(pack.line as Node).queue_free()
		_path_planets.clear()
		for pname in AnalemmaPaths.PLANETS:
			var pk := AnalemmaPaths.planet_year(pname, jd)
			var scaled := PackedVector3Array()
			for p in pk.points:
				scaled.append((p as Vector3) * AnalemmaPaths.SKY_R)
			var col: Color = pk.color
			var line := _path_line(_path_root, "PlanetPath_%s" % pname, Color(col.r, col.g, col.b, 0.85), 1.6)
			line.mesh = AnalemmaPaths.line_mesh(scaled, 8.0)
			_set_head(line, 0.5)
			var dot := _path_dot(line, "Now", col, 0.42)
			dot.position = (pk.now as Vector3) * AnalemmaPaths.SKY_R
			dot.visible = true
			var tag := Label3D.new()
			tag.text = str(pk.title)
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.fixed_size = true
			tag.no_depth_test = true
			tag.pixel_size = 0.0011
			tag.font_size = 20
			tag.outline_size = 7
			tag.modulate = col
			tag.outline_modulate = Color(0, 0, 0, 0.8)
			tag.offset = Vector2(0, 18)
			dot.add_child(tag)
			_path_planets.append({"line": line, "dot": dot, "tag": tag})
		_place_planet_basis(jd)
	_apply_path_visibility()
	_update_marker(jd)


func _rebuild_sublunar(jd: float) -> void:
	var mground := PackedVector3Array()
	for p in AnalemmaPaths.sublunar_track(jd):
		mground.append(p * 1.003)
	_path_moon_ground.mesh = AnalemmaPaths.line_mesh(mground, 0.45)
	_set_head(_path_moon_ground, 0.5)

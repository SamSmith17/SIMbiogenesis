class_name ClimelapsePathView
extends Node3D

## The video's camera path drawn in the world while the camera-path editor is
## open: the line the camera flies (sampled from the keyframes exactly as the
## export samples them), short view ticks along it showing where the camera
## points on the way, and at each keyframe a marker, its number and time, and
## a wireframe of what it sees (the frustum at the export's aspect). The
## selected key is amber, the others violet; the camera at the playhead is
## white. Drawn through everything (no depth test) so a key behind a hill can
## still be found.
##
## Sizes follow the viewing camera's distance, so markers and frustums read
## the same from beside a key and from far above the whole path.

const C_PATH := Color(0.62, 0.36, 1.0, 0.95)
const C_TICK := Color(0.25, 0.78, 1.0, 0.8)
const C_SEL := Color(1.0, 0.74, 0.28, 1.0)
const C_NOW := Color(1.0, 1.0, 1.0, 0.9)
const MARK_SCREEN := 0.011     # marker radius per metre of camera distance
const FRUSTUM_SCREEN := 0.09   # frustum depth per metre of camera distance

var selected := -1
var aspect := 16.0 / 9.0
## The camera at the playhead ({xform, fov}) or {} for none.
var now_pose: Dictionary = {}

var _mesh: ImmediateMesh = null
var _mi: MeshInstance3D = null
var _mat_line: StandardMaterial3D = null
var _mat_key: StandardMaterial3D = null
var _mat_sel: StandardMaterial3D = null
var _sphere: SphereMesh = null
var _markers: Array = []
var _labels: Array = []


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	_mesh = ImmediateMesh.new()
	_mi = MeshInstance3D.new()
	_mi.mesh = _mesh
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat_line = _material(Color.WHITE, true)
	_mi.material_override = _mat_line
	add_child(_mi)
	_mat_key = _material(C_PATH, false)
	_mat_sel = _material(C_SEL, false)
	_sphere = SphereMesh.new()
	_sphere.radius = 1.0
	_sphere.height = 2.0
	_sphere.radial_segments = 12
	_sphere.rings = 6


static func _material(c: Color, vertex_colors: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.vertex_color_use_as_albedo = vertex_colors
	m.albedo_color = c
	m.render_priority = 20
	m.disable_fog = true
	return m


## Redraw from the keys, as seen from `cam`. `clock` (CelestialClock or null)
## gives the labels their dates.
func refresh(keys: ClimelapseKeyframes, cam: Camera3D, clock: Object) -> void:
	_mesh.clear_surfaces()
	var n := keys.size() if keys != null else 0
	_sync_nodes(n)
	if n == 0 or cam == null:
		return
	var eye := cam.global_position
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var path := keys.sample_path(clampi(n * 32, 2, 600))
	for j in range(1, path.size()):
		_line((path[j - 1] as Dictionary)["pos"], (path[j] as Dictionary)["pos"], C_PATH)
	# View ticks: every few samples, a short line along where the camera points.
	var step := maxi(path.size() / 40, 1)
	for j in range(0, path.size(), step):
		var p: Vector3 = (path[j] as Dictionary)["pos"]
		var f: Vector3 = (path[j] as Dictionary)["fwd"]
		_line(p, p + f * maxf(eye.distance_to(p) * FRUSTUM_SCREEN * 0.45, 0.2), C_TICK)
	for i in n:
		var k := keys.key(i)
		var xf := ClimelapseKeyframes.key_transform(k)
		var c := C_SEL if i == selected else C_PATH
		var d := maxf(eye.distance_to(xf.origin) * FRUSTUM_SCREEN, 0.3)
		_frustum(xf, float(k.get("fov", 75.0)), d, c)
		# The view ray: well past the frustum, so the aim reads at a glance.
		_line(xf.origin, xf.origin - xf.basis.z * d * 3.0, Color(c.r, c.g, c.b, 0.55))
		var mk: MeshInstance3D = _markers[i]
		mk.global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * maxf(eye.distance_to(xf.origin) * MARK_SCREEN, 0.05)), xf.origin)
		mk.material_override = _mat_sel if i == selected else _mat_key
		var lb: Label3D = _labels[i]
		lb.global_position = xf.origin + Vector3.UP * maxf(eye.distance_to(xf.origin) * MARK_SCREEN * 2.4, 0.15)
		lb.text = "%d · %s" % [i + 1, time_label(clock, float(k.get("t", 0.0)))]
		lb.modulate = c
	if not now_pose.is_empty():
		var nx: Transform3D = now_pose.get("xform", Transform3D.IDENTITY)
		_frustum(nx, float(now_pose.get("fov", 75.0)), maxf(eye.distance_to(nx.origin) * FRUSTUM_SCREEN * 0.8, 0.3), C_NOW)
	_mesh.surface_end()


func _line(a: Vector3, b: Vector3, c: Color) -> void:
	_mesh.surface_set_color(c)
	_mesh.surface_add_vertex(a)
	_mesh.surface_set_color(c)
	_mesh.surface_add_vertex(b)


func _frustum(xf: Transform3D, fov: float, dist: float, c: Color) -> void:
	var cs := ClimelapseKeyframes.frustum_corners(xf, fov, aspect, dist)
	for j in 4:
		_line(xf.origin, cs[j], c)
		_line(cs[j], cs[(j + 1) % 4], c)
	# The top edge doubled inward a little: which way is up in the frame.
	var up_a := cs[0].lerp(cs[3], 0.08)
	var up_b := cs[1].lerp(cs[2], 0.08)
	_line(up_a, up_b, c)


func _sync_nodes(n: int) -> void:
	while _markers.size() < n:
		var mk := MeshInstance3D.new()
		mk.mesh = _sphere
		mk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mk)
		_markers.append(mk)
		var lb := Label3D.new()
		lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lb.no_depth_test = true
		lb.fixed_size = true
		lb.pixel_size = 0.0011
		lb.font_size = 26
		lb.outline_size = 8
		lb.outline_modulate = Color(0, 0, 0, 0.85)
		lb.render_priority = 21
		lb.outline_render_priority = 20
		add_child(lb)
		_labels.append(lb)
	while _markers.size() > n:
		(_markers.pop_back() as Node).queue_free()
		(_labels.pop_back() as Node).queue_free()


## "Oct 3 14:05" for an absolute hour (or "123.4 h" without a clock).
static func time_label(clock: Object, h: float) -> String:
	if clock == null or not clock.has_method("abs_hours_to_date"):
		return "%.1f h" % h
	var d: Dictionary = clock.call("abs_hours_to_date", h)
	var dt := float(d.get("day_time", 0.0))
	var mins := int(round(dt * 60.0)) % (24 * 60)
	const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
	return "%s %d %02d:%02d" % [MONTHS[clampi(int(d.get("month", 1)) - 1, 0, 11)],
		int(d.get("day", 1)), mins / 60, mins % 60]


## Index of the key whose marker is under the screen point, else -1.
static func pick_key(keys: ClimelapseKeyframes, cam: Camera3D, screen: Vector2, radius_px: float = 16.0) -> int:
	if keys == null or cam == null:
		return -1
	var best := -1
	var best_d := radius_px
	for i in keys.size():
		var p := ClimelapseKeyframes.key_transform(keys.key(i)).origin
		if cam.is_position_behind(p):
			continue
		var d := cam.unproject_position(p).distance_to(screen)
		if d <= best_d:
			best_d = d
			best = i
	return best

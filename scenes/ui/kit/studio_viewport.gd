class_name StudioViewport
extends VBoxContainer

## THE 3D studio every designer, Tune look and port editor shows its subject
## in: one SubViewport with its own world, a filmic environment lit by a soft
## overcast sky (the top, the sides and the undersides of a facetted shape
## each take a different tone — a flat ambient made every dome a smooth
## bubble), a key + fill light, an optional ground plane and scale person,
## and the one orbit: drag turns, the wheel zooms, the middle button (or
## Shift + drag) pans. Under the view sits `strip`, a row the owner fills
## (explode / build sliders, a mode chip, the hover readout). Before the kit
## twelve files carried their own copy of this, each with slightly different
## lights, zoom limits and picking maths.
##
##   var studio := StudioViewport.create({"ground": true, "person": true})
##   centre.add_child(studio)
##   studio.holder.add_child(my_model)          # the subject
##   studio.frame_sphere(Vector3(0, h * 0.45, 0), r)
##   studio.clicked.connect(func(pos): _pick(studio.pick_ray(pos)))
##   studio.hovered.connect(func(pos): ...)      # every 4th motion event
##   studio.strip.add_child(slider_row)
##
## The viewport is `viewport`; the container that receives the mouse is
## `container`; `camera` is the orbit camera. A designer that needs its own
## drag (sliding a part along a mate) sets `input_hook`: a Callable taking
## the InputEvent and returning true when it consumed it.

signal clicked(pos: Vector2, button: int)
signal hovered(pos: Vector2)
signal view_changed

const HOVER_EVERY := 4
const DIST_MIN := 0.3
const DIST_MAX := 400.0
const BACKDROP_HAZE := Color(0.60, 0.63, 0.67)

var viewport: SubViewport = null
var container: SubViewportContainer = null
var world: Node3D = null
var holder: Node3D = null
var camera: Camera3D = null
var strip: HBoxContainer = null
var environment: Environment = null
var key_light: DirectionalLight3D = null
var fill_light: DirectionalLight3D = null
var ground: MeshInstance3D = null
var person: MeshInstance3D = null

## Orbit state (radians, metres).
var yaw := 0.8
var pitch := 0.35
var dist := 12.0
var target := Vector3(0, 1.5, 0)
var pitch_min := -0.3
var pitch_max := 1.45
var zoom_step := 0.1
## The orbit's far limit (a camp preview stands 900 m out; a cup 2 m).
var dist_max := DIST_MAX
## Set to intercept input before the orbit (return true = consumed).
var input_hook: Callable = Callable()
## The orbit can be switched off (a 2D plan view) without losing the signals.
var orbit_enabled := true

var _showroom := true
var _home_yaw := 0.8
var _home_pitch := 0.35
var _dragging := false
var _panning := false
var _press_pos := Vector2.ZERO
var _press_button := 0
var _moved := false
var _hover_frame := 0


## Options: ground (bool, a 200 m matte plane), person (bool, a 1.75 m
## capsule for scale — moved with `place_person`), ssao (bool), msaa (int,
## Viewport.MSAA_*), size (Vector2i, the render size before stretch),
## exposure (float).
static func create(opts: Dictionary = {}) -> StudioViewport:
	var s := StudioViewport.new()
	s._build(opts)
	return s


func _build(opts: Dictionary) -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", UITheme.SPACE_XS)
	container = SubViewportContainer.new()
	container.stretch = true
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.mouse_filter = Control.MOUSE_FILTER_STOP
	container.gui_input.connect(_on_gui_input)
	add_child(container)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = int(opts.get("msaa", Viewport.MSAA_4X)) as Viewport.MSAA
	viewport.size = opts.get("size", Vector2i(900, 640))
	container.add_child(viewport)
	_build_world(opts)
	strip = HBoxContainer.new()
	strip.add_theme_constant_override("separation", UITheme.SPACE_SM)
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(strip)


func _build_world(opts: Dictionary) -> void:
	world = Node3D.new()
	world.name = "Studio"
	viewport.add_child(world)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	# ONE backdrop for every studio (opts.backdrop "showroom", the default): a
	# soft grey sky that meets the floor in haze. The old default was a
	# near-black void over a dark floor, which half the studios still showed
	# while the newer ones had dressed their own. "dark" keeps the void.
	_showroom = str(opts.get("backdrop", "showroom")) != "dark"
	e.background_mode = Environment.BG_SKY if _showroom else Environment.BG_COLOR
	e.background_color = Color(0.035, 0.043, 0.063)
	var skymat := ProceduralSkyMaterial.new()
	if _showroom:
		skymat.sky_top_color = Color(0.30, 0.34, 0.41)
		skymat.sky_horizon_color = BACKDROP_HAZE
		skymat.sky_curve = 0.25
		skymat.ground_horizon_color = BACKDROP_HAZE
		skymat.ground_bottom_color = Color(0.42, 0.44, 0.47)
		e.fog_enabled = true
		e.fog_light_color = BACKDROP_HAZE
		e.fog_sky_affect = 0.0
	else:
		skymat.sky_top_color = Color(0.62, 0.68, 0.78)
		skymat.sky_horizon_color = Color(0.42, 0.42, 0.44)
		skymat.ground_horizon_color = Color(0.22, 0.21, 0.20)
		skymat.ground_bottom_color = Color(0.08, 0.08, 0.08)
	skymat.sun_angle_max = 10.0
	skymat.sun_curve = 0.2
	var sky := Sky.new()
	sky.sky_material = skymat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_sky_contribution = 1.0
	e.ambient_light_energy = 0.9
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.ssao_enabled = bool(opts.get("ssao", true))
	e.ssao_radius = 0.5
	e.ssao_intensity = 1.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = float(opts.get("exposure", 1.05))
	env.environment = e
	environment = e
	world.add_child(env)
	key_light = DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-48, 35, 0)
	key_light.light_energy = 1.5
	key_light.light_color = Color(1.0, 0.96, 0.9)
	key_light.shadow_enabled = true
	key_light.light_angular_distance = 1.2
	key_light.directional_shadow_max_distance = 80.0
	key_light.shadow_normal_bias = 1.5
	world.add_child(key_light)
	fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-20, -140, 0)
	fill_light.light_energy = 0.25
	fill_light.light_color = Color(0.8, 0.88, 1.0)
	world.add_child(fill_light)
	if bool(opts.get("ground", true)):
		ground = MeshInstance3D.new()
		ground.name = "Ground"
		var plane := PlaneMesh.new()
		plane.size = Vector2(200, 200)
		ground.mesh = plane
		var gmat := StandardMaterial3D.new()
		gmat.albedo_color = Color(0.36, 0.37, 0.39) if _showroom else Color(0.13, 0.125, 0.12)
		gmat.roughness = 0.95
		ground.material_override = gmat
		world.add_child(ground)
	if bool(opts.get("person", false)):
		person = MeshInstance3D.new()
		person.name = "ScalePerson"
		var cap := CapsuleMesh.new()
		cap.radius = 0.2
		cap.height = 1.75
		person.mesh = cap
		person.position = Vector3(0, 0.875, 0)
		var pm := StandardMaterial3D.new()
		pm.albedo_color = Color(0.45, 0.48, 0.55)
		person.material_override = pm
		world.add_child(person)
	holder = Node3D.new()
	holder.name = "Holder"
	world.add_child(holder)
	camera = Camera3D.new()
	camera.fov = float(opts.get("fov", 45.0))
	camera.far = float(opts.get("far", 500.0))
	world.add_child(camera)
	update_camera()


# ---------------------------------------------------------------------------
# The subject
# ---------------------------------------------------------------------------

## Remove everything in the holder (the previous build of the subject).
func clear() -> void:
	if holder == null:
		return
	for c in holder.get_children():
		holder.remove_child(c)
		c.queue_free()


## Replace the subject with `node`.
func show_node(node: Node3D) -> void:
	clear()
	if node != null:
		holder.add_child(node)


## Stand the scale person beside a subject of radius `r`.
func place_person(r: float, side: float = 0.6) -> void:
	if person != null:
		person.position = Vector3(r + side, 0.875, 0.0)


# ---------------------------------------------------------------------------
# The orbit
# ---------------------------------------------------------------------------

## Frame a sphere: look at `centre` from far enough to see radius `r` with
## some air round it. Keeps the current yaw / pitch.
func frame_sphere(centre: Vector3, r: float, pad: float = 1.6) -> void:
	target = centre
	dist = clampf(maxf(r, 0.5) * pad + 1.0, DIST_MIN, dist_max)
	update_camera()


## Frame a box (its centre at a fraction `up` of its height, as a standing
## structure is best framed a little under its middle).
func frame_aabb(bb: AABB, up: float = 0.45, pad: float = 1.6) -> void:
	var c := bb.position + Vector3(bb.size.x * 0.5, bb.size.y * up, bb.size.z * 0.5)
	var r := maxf(maxf(bb.size.x, bb.size.z) * 0.5 * 2.0, bb.size.y)
	frame_sphere(c, r, pad)


## The bounds of everything drawn under `node` (default: the holder), in the
## studio's own space. Built from LOCAL transforms up the parent chain, so it
## is right before the studio is in the tree (global_transform is not) and
## whatever scale an imported model's inner nodes carry. Hidden nodes and
## nodes with meta "studio_no_frame" (gizmos, ghosts) are left out. An empty
## AABB (size 0) when nothing is drawn.
func subject_aabb(node: Node3D = null) -> AABB:
	var root := node if node != null else holder
	var out := AABB()
	if root == null:
		return out
	var any := false
	var stack: Array = [[root, _xf_to_world(root)]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var n := top[0] as Node
		var xf := top[1] as Transform3D
		if n.has_meta("studio_no_frame") or (n is Node3D and not (n as Node3D).visible):
			continue
		var bb := AABB()
		var has := false
		if n is MeshInstance3D:
			if (n as MeshInstance3D).mesh != null:
				bb = (n as MeshInstance3D).mesh.get_aabb()
				has = true
		elif n is MultiMeshInstance3D:
			if (n as MultiMeshInstance3D).multimesh != null:
				bb = (n as MultiMeshInstance3D).multimesh.get_aabb()
				has = true
		elif n is GeometryInstance3D:
			bb = (n as GeometryInstance3D).get_aabb()
			has = true
		if has and bb.size.length() > 0.0:
			var w := xf * bb
			out = w if not any else out.merge(w)
			any = true
		# A plain Node between two Node3Ds passes the frame straight through.
		for c in n.get_children():
			stack.append([c, xf * (c as Node3D).transform if c is Node3D else xf])
	return out


func _xf_to_world(n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != world:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


## Frame whatever is in the holder (or under `node`): the whole subject in
## view from the current angle, with air round it. False when nothing is
## drawn (the view is left alone). Call after building or rebuilding the
## subject, so a studio never opens on the wrong picture.
func frame_subject(node: Node3D = null, pad: float = 1.25) -> bool:
	var bb := subject_aabb(node)
	if bb.size.length() < 0.001:
		return false
	target = bb.get_center()
	dist = clampf(fit_distance(bb, pad), DIST_MIN, dist_max)
	update_camera()
	return true


## How far back the camera stands to show a box whole at the current pitch
## and any yaw: its height and plan diagonal against the view's two half
## angles, plus half the plan diagonal so the near side stays in front.
func fit_distance(bb: AABB, pad: float = 1.25) -> float:
	var ty := tan(deg_to_rad(camera.fov if camera != null else 45.0) * 0.5)
	var size := Vector2(viewport.size) if viewport != null else Vector2(4, 3)
	var tx := ty * size.x / maxf(size.y, 1.0)
	var half_w := Vector2(bb.size.x, bb.size.z).length() * 0.5
	var half_v := bb.size.y * 0.5 * cos(pitch) + half_w * absf(sin(pitch))
	return maxf(half_v / ty, half_w / tx) * pad + half_w * 0.5


## How much of the subject's box is inside the view, 0..1 (its eight corners
## projected); -1 with no subject. The modal audit reads it: a studio that
## opens with the camera inside the model, or on empty floor, scores low.
func subject_in_view(node: Node3D = null) -> float:
	var bb := subject_aabb(node)
	if camera == null or viewport == null or bb.size.length() < 0.001:
		return -1.0
	var size := Vector2(viewport.size)
	var inv := camera.transform.affine_inverse()
	var ty := tan(deg_to_rad(camera.fov) * 0.5)
	var tx := ty * size.x / maxf(size.y, 1.0)
	var inside := 0
	for i in 8:
		var p := inv * bb.get_endpoint(i)
		if p.z < -camera.near and absf(p.x) <= -p.z * tx and absf(p.y) <= -p.z * ty:
			inside += 1
	return float(inside) / 8.0


## The orbit the view returns to on "frame": set it once after creating.
func set_home(y: float, p: float) -> void:
	_home_yaw = y
	_home_pitch = p
	yaw = y
	pitch = p


func reset_orbit() -> void:
	yaw = _home_yaw
	pitch = _home_pitch
	update_camera()


func set_orbit(y: float, p: float, d: float = -1.0) -> void:
	yaw = y
	pitch = clampf(p, pitch_min, pitch_max)
	if d > 0.0:
		dist = clampf(d, DIST_MIN, dist_max)
	update_camera()


func update_camera() -> void:
	if camera == null:
		return
	var cp := Vector3(dist * cos(pitch) * sin(yaw), dist * sin(pitch), dist * cos(pitch) * cos(yaw))
	camera.look_at_from_position(target + cp, target, Vector3.UP)
	# The haze sits well behind the subject at any zoom (0.007 at 12 m).
	if _showroom and environment != null and environment.fog_enabled:
		environment.fog_density = clampf(0.085 / maxf(dist, 1.0), 0.0003, 0.02)
	view_changed.emit()


## The world-space ray under a container position: {origin, dir}.
func pick_ray(pos: Vector2) -> Dictionary:
	if camera == null:
		return {}
	var p := to_viewport(pos)
	return {"origin": camera.project_ray_origin(p), "dir": camera.project_ray_normal(p)}


## A container position as a viewport pixel (the view is stretched).
func to_viewport(pos: Vector2) -> Vector2:
	var vp_size := Vector2(viewport.size)
	var cs := container.size
	return pos * (vp_size / cs) if cs.x > 0.0 and cs.y > 0.0 else pos


## Where a container position is on the SCREEN (what a harness clicks). A
## full-screen modal draws zoomed (UiFit), so this is not the container's
## corner plus the offset: it goes through the container's own transform.
func screen_pos(pos: Vector2) -> Vector2:
	return container.get_global_transform() * pos


## The ray in a subject node's LOCAL frame: {origin, dir}.
func pick_ray_local(node: Node3D, pos: Vector2) -> Dictionary:
	var r := pick_ray(pos)
	if r.is_empty() or node == null:
		return {}
	var inv := node.global_transform.affine_inverse()
	return {"origin": inv * (r["origin"] as Vector3), "dir": (inv.basis * (r["dir"] as Vector3)).normalized()}


## The rendered frame (a PNG for the harness).
func image() -> Image:
	return viewport.get_texture().get_image() if viewport != null else null


func _on_gui_input(e: InputEvent) -> void:
	if input_hook.is_valid() and bool(input_hook.call(e)):
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if orbit_enabled:
				dist = maxf(DIST_MIN, dist * (1.0 - zoom_step))
				update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if orbit_enabled:
				dist = minf(dist_max, dist * (1.0 + zoom_step))
				update_camera()
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT \
				or mb.button_index == MOUSE_BUTTON_MIDDLE:
			if mb.pressed:
				_dragging = true
				_panning = mb.button_index == MOUSE_BUTTON_MIDDLE or mb.shift_pressed
				_moved = false
				_press_pos = mb.position
				_press_button = mb.button_index
			else:
				_dragging = false
				_panning = false
				if not _moved and mb.button_index == _press_button:
					clicked.emit(mb.position, mb.button_index)
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _dragging:
			if mm.position.distance_to(_press_pos) > 4.0:
				_moved = true
			if _moved and orbit_enabled:
				if _panning:
					var right := camera.global_transform.basis.x
					var up := camera.global_transform.basis.y
					var k := dist * 0.0015
					target -= right * mm.relative.x * k
					target += up * mm.relative.y * k
				else:
					yaw -= mm.relative.x * 0.01
					pitch = clampf(pitch - mm.relative.y * 0.01, pitch_min, pitch_max)
				update_camera()
		else:
			_hover_frame += 1
			if _hover_frame % HOVER_EVERY == 0:
				hovered.emit(mm.position)

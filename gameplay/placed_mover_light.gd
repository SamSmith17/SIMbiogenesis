class_name PlacedMoverLight
extends PlacedLight

## A DMX-style moving fixture placed with the J Light Studio: moving-head beam,
## gobo spot, wash/PAR, laser, gobo projector, strobe, sky tracker.
##
##   self (base, record pitch/yaw/roll — its +Y is the mounting axis)
##     Yoke   pans about +Y
##       Head tilts away from +Y; the light, the beam shaft and the lasers
##            all shine along the head's −Z
## MoverProgram owns the angle maths (and the selftest pins that this
## hierarchy aims where MoverProgram.direction says). The sweep runs on the
## shared PlacedLightClock, so a set of fixtures sweeps in step and "Fan
## phases" spreads them into a fan.
##
## What you SEE of a beam is haze: the SpotLight3D's volumetric-fog energy
## scatters in real fog, and light_beam.gdshader draws the shaft for scenes
## without it (scaled by `beam_haze` and by night — a beam is all but
## invisible at noon). Beams and lasers stop at the first surface (a 10 Hz
## raycast) — a laser does not pass through a tent.

const BEAM_SHADER := preload("res://gameplay/light_beam.gdshader")
const RAY_HZ := 10.0
## Base / yoke / head proportions of a ~15 kg moving head (metres).
const BASE_H := 0.14
const YOKE_H := 0.24
const HEAD_LEN := 0.34
const LENS_R := 0.07

var _yoke: Node3D = null
var _head: Node3D = null
var _fixture_root: Node3D = null
var _lens_mat: StandardMaterial3D = null
var _beam: MeshInstance3D = null
var _beam_mat: ShaderMaterial = null
var _beam_len := 10.0
var _lasers: Array[Node3D] = []          # pivots, each holds one beam mesh
var _laser_mats: Array[ShaderMaterial] = []
var _laser_lens: PackedFloat32Array = PackedFloat32Array()
var _ray_acc := 0.0
var _built_fixture := ""


func _rebuild_light_node() -> void:
	for n in [_light_node, _yoke, _fixture_root]:
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()
	_lasers.clear()
	_laser_mats.clear()
	_laser_lens = PackedFloat32Array()
	_built_fixture = ""
	_fixture_root = Node3D.new()
	_fixture_root.name = "FixtureBase"
	add_child(_fixture_root)
	_yoke = Node3D.new()
	_yoke.name = "Yoke"
	_yoke.position = Vector3(0.0, BASE_H, 0.0)
	add_child(_yoke)
	_head = Node3D.new()
	_head.name = "Head"
	_head.position = Vector3(0.0, YOKE_H, 0.0)
	_yoke.add_child(_head)
	_light_node = SpotLight3D.new()
	_light_node.name = "Light"
	_head.add_child(_light_node)
	_beam = MeshInstance3D.new()
	_beam.name = "Beam"
	var cone := CylinderMesh.new()
	# A unit cone along +Y (top = far end), scaled per frame to (R, L, R).
	cone.height = 1.0
	cone.top_radius = 1.0
	cone.bottom_radius = 0.02
	cone.radial_segments = 24
	cone.rings = 1
	cone.cap_top = false
	cone.cap_bottom = false
	_beam.mesh = cone
	_beam.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam_mat = ShaderMaterial.new()
	_beam_mat.shader = BEAM_SHADER
	_beam.material_override = _beam_mat
	_head.add_child(_beam)


## The visible fixture: dark base, yoke arms, head can with a glowing lens
## (a laser is a box). Rebuilt only when the fixture type changes.
func _build_body(fixture: String) -> void:
	if _built_fixture == fixture:
		return
	_built_fixture = fixture
	for c in _fixture_root.get_children():
		c.queue_free()
	for c in _yoke.get_children():
		if c != _head:
			c.queue_free()
	for c in _head.get_children():
		if c.name.begins_with("Body"):
			c.queue_free()
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.07, 0.07, 0.08)
	metal.metallic = 0.4
	metal.roughness = 0.5
	_box(_fixture_root, "BodyBase", Vector3(0.42, BASE_H, 0.42), Vector3(0, BASE_H * 0.5, 0), metal)
	for sx in [-1.0, 1.0]:
		_box(_yoke, "BodyArm", Vector3(0.04, YOKE_H + 0.06, 0.09),
			Vector3(0.19 * sx, (YOKE_H + 0.06) * 0.5, 0), metal)
	var can := MeshInstance3D.new()
	can.name = "BodyHead"
	if fixture == "laser":
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, 0.14, HEAD_LEN)
		can.mesh = bm
	else:
		var cm := CylinderMesh.new()
		cm.top_radius = 0.12
		cm.bottom_radius = 0.14
		cm.height = HEAD_LEN
		cm.radial_segments = 16
		can.mesh = cm
		can.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	can.material_override = metal
	_head.add_child(can)
	var lens := MeshInstance3D.new()
	lens.name = "BodyLens"
	var lm := CylinderMesh.new()
	lm.top_radius = LENS_R if fixture != "laser" else 0.02
	lm.bottom_radius = lm.top_radius
	lm.height = 0.01
	lm.radial_segments = 16
	lens.mesh = lm
	lens.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	lens.position = Vector3(0.0, 0.0, -HEAD_LEN * 0.5 - 0.006)
	_lens_mat = StandardMaterial3D.new()
	_lens_mat.emission_enabled = true
	_lens_mat.albedo_color = Color(0.1, 0.1, 0.12)
	lens.material_override = _lens_mat
	_head.add_child(lens)


func _box(parent: Node3D, n: String, size: Vector3, pos: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = n
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)


func _apply_fields() -> void:
	super._apply_fields()
	if _light_node == null or _head == null:
		return
	var fixture := str(fields.get("fixture", "beam"))
	_build_body(fixture)
	var show := bool(fields.get("show_body", true))
	if _bulb != null:
		_bulb.visible = false   # the fixture IS the body
	_fixture_root.visible = show
	for c in _yoke.get_children():
		if c != _head:
			(c as Node3D).visible = show
	for c in _head.get_children():
		if c.name.begins_with("Body"):
			(c as Node3D).visible = show
	var s := _light_node as SpotLight3D
	var haze := clampf(float(fields.get("beam_haze", 0.5)), 0.0, 1.0)
	s.shadow_enabled = bool(fields.get("shadow_enabled", false))
	# Real scattering wherever the scene has volumetric fog (valley fog, the
	# fog slider); the drawn shaft covers scenes without it.
	s.light_volumetric_fog_energy = haze * 4.0
	var gobo_on := fixture == "spot" or fixture == "projector"
	s.light_projector = MoverGobo.texture(str(fields.get("gobo", "none"))) if gobo_on else null
	if fixture == "laser":
		# A show laser lights almost nothing; its beams are the effect.
		s.light_energy = 0.0
		s.visible = false
	else:
		s.visible = true
	_beam.visible = fixture != "laser" and haze > 0.0
	_sync_lasers(fixture)


func _sync_lasers(fixture: String) -> void:
	var want := clampi(int(fields.get("laser_beams", 1)), 1, 16) if fixture == "laser" else 0
	while _lasers.size() > want:
		_lasers.pop_back().queue_free()
		_laser_mats.pop_back()
	while _lasers.size() < want:
		var pivot := Node3D.new()
		pivot.name = "Laser_%d" % _lasers.size()
		var mi := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.height = 1.0
		cyl.top_radius = 1.0
		cyl.bottom_radius = 1.0
		cyl.radial_segments = 6
		cyl.rings = 1
		cyl.cap_top = false
		cyl.cap_bottom = false
		mi.mesh = cyl
		mi.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = BEAM_SHADER
		mat.set_shader_parameter("min_width_rad", 0.0012)
		mat.set_shader_parameter("falloff", 0.6)
		mat.set_shader_parameter("shimmer", 0.15)
		mi.material_override = mat
		pivot.add_child(mi)
		_head.add_child(pivot)
		_lasers.append(pivot)
		_laser_mats.append(mat)
	_laser_lens.resize(_lasers.size())
	var fan := float(fields.get("laser_fan_deg", 0.0))
	for j in _lasers.size():
		var f := 0.0 if _lasers.size() < 2 else (float(j) / float(_lasers.size() - 1) - 0.5) * fan
		_lasers[j].rotation = Vector3(0.0, deg_to_rad(f), 0.0)
		if _laser_lens[j] <= 0.0:
			_laser_lens[j] = float(fields.get("range", 100.0))


func _process(delta: float) -> void:
	super._process(delta)
	if _head == null:
		return
	# Sound reactive in a beat mode: the sweep moves with the music.
	var t := effect_time()
	var ang := MoverProgram.angles(fields, t)
	_yoke.rotation = Vector3(0.0, deg_to_rad(ang.x), 0.0)
	_head.rotation = Vector3(deg_to_rad(90.0 - ang.y), 0.0, 0.0)
	# Gobo wheel spin (rpm), a pure function of the clock.
	var spin := float(fields.get("gobo_spin", 0.0))
	if _light_node != null:
		_light_node.rotation = Vector3(0.0, 0.0, fposmod(t * spin / 60.0 * TAU, TAU))
	_ray_acc += delta
	if _ray_acc >= 1.0 / RAY_HZ:
		_ray_acc = 0.0
		_cast_beams()
	_update_beam_visuals(t)


func _cast_beams() -> void:
	var rng := maxf(float(fields.get("range", 60.0)), 1.0)
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	_beam_len = _ray_len(space, _head.global_transform, rng)
	for j in _lasers.size():
		_laser_lens[j] = _ray_len(space, _lasers[j].global_transform, rng)


func _ray_len(space: PhysicsDirectSpaceState3D, xf: Transform3D, rng: float) -> float:
	if space == null:
		return rng
	var from := xf.origin - xf.basis.z.normalized() * (HEAD_LEN * 0.5 + 0.05)
	var to := from - xf.basis.z.normalized() * rng
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	return from.distance_to(hit["position"]) if not hit.is_empty() else rng


func _update_beam_visuals(t: float) -> void:
	var lit := _lit
	var col: Color = _light_node.light_color if _light_node != null else Color.WHITE
	var night := lerpf(0.08, 1.0, PlacedLightPower.night_factor(_main))
	var haze := clampf(float(fields.get("beam_haze", 0.5)), 0.0, 1.0)
	var energy := float(fields.get("energy", 1.0)) * sound_level
	if _lens_mat != null:
		_lens_mat.emission = col
		_lens_mat.emission_energy_multiplier = energy * 1.5 if lit else 0.0
	var half := clampf(float(fields.get("spot_angle", 3.0)), 0.3, 89.0)
	if _beam != null and _beam.visible:
		var length := maxf(_beam_len, 0.1)
		var r := tan(deg_to_rad(half)) * length
		_beam.scale = Vector3(r, length, r)
		_beam.position = Vector3(0.0, 0.0, -HEAD_LEN * 0.5 - length * 0.5)
		_beam_mat.set_shader_parameter("beam_color", col)
		# A wide wash spreads the same light over a far bigger shaft.
		_beam_mat.set_shader_parameter("intensity",
			(energy * 0.09 / sqrt(maxf(half, 0.5))) if lit else 0.0)
		_beam_mat.set_shader_parameter("haze", haze)
		_beam_mat.set_shader_parameter("night", night)
		_beam_mat.set_shader_parameter("radial_scale", r)
	var base := PlacedLightPower.parse_color(str(fields.get("color", "ffffff")))
	for j in _lasers.size():
		var len_j := maxf(_laser_lens[j], 0.1)
		var mi := _lasers[j].get_child(0) as MeshInstance3D
		mi.scale = Vector3(0.0015, len_j, 0.0015)
		mi.position = Vector3(0.0, 0.0, -HEAD_LEN * 0.5 - len_j * 0.5)
		var m := _laser_mats[j]
		m.set_shader_parameter("beam_color", LedEffects.color_at(fields, j, _lasers.size(), t, base))
		m.set_shader_parameter("intensity", energy * 2.5 if lit else 0.0)
		m.set_shader_parameter("haze", maxf(haze, 0.2))
		m.set_shader_parameter("night", night)
		m.set_shader_parameter("radial_scale", 0.0015)


## Where the beam points right now (world) — the harness and the Aim tool.
func beam_direction() -> Vector3:
	return -_head.global_transform.basis.z.normalized() if _head != null else Vector3.DOWN


func beam_length() -> float:
	return _beam_len

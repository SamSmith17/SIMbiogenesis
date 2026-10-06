class_name FireAshPile
extends Node3D

## What a burned structure collapses into: a mound over the footprint of its
## base that burns as a bonfire, dies back to glowing, smoking embers, goes
## black and finally turns to grey-white ash.
##
## It is its OWN node, not part of FireNode, because it outlives it: the fire
## event frees its FireNodes when it times out (2 sim-hours), long before a
## bonfire has burned down, and the ash is meant to stay. FireNode spawns it at
## the moment of collapse, hands it copies of its emitters, and from then on only
## asks it how much flame is left (so the extinguisher and fire damage still
## have a fire to act on while there is one).
##
## Everything it shows is a function of ONE number, `age_hours` of SIM time,
## through `look()` — so it burns down at the same rate whatever the clock speed.

const PILE_SHADER := preload("res://crisis_events/fire/fire_pile.gdshader")
const GROUP := "fire_ash_piles"

## Sim-hours after the collapse. Open flame is gone by FLAME; the ember bed is
## dead black by EMBER; it starts greying at ASH_FROM and is ash by TOTAL.
const FLAME_HOURS : float = 3.0
const EMBER_HOURS : float = 6.5
const ASH_FROM_HOURS : float = 6.0
const TOTAL_HOURS : float = 9.0

const FLAME_AMOUNT : int = 160
const SMOKE_AMOUNT : int = 110
const EMBER_AMOUNT : int = 60
const EMISSION_POINTS : int = 200
## The collapse flare, in real seconds.
const WHOOSH_SECONDS : float = 1.8
const DOUSE_SECONDS : float = 2.0

var age_hours : float = 0.0
var radius : Vector2 = Vector2.ONE      # footprint half-extents on x / z
var height : float = 0.4                # how high the mound stands
var structure_height : float = 3.0      # what fell into it: scales the whoosh

var mound : MeshInstance3D = null
var flames : GPUParticles3D = null
var smoke : GPUParticles3D = null
var embers : GPUParticles3D = null
var light : OmniLight3D = null
var whoosh_emitters : Array[GPUParticles3D] = []

var _mat : ShaderMaterial = null
var _aging : bool = false
var _doused : bool = false
var _douse_t : float = 0.0
var _whoosh : float = 0.0
var _flicker : float = 0.0
var _look_bucket : int = -1
var _finished : bool = false
var _clock : Node = null

static var _mound_mesh : ArrayMesh = null


## The whole burn-down as a pure function of sim-hours since the collapse:
##   flame  1 = bonfire .. 0 = no open flame
##   heat   1 = whole bed glowing .. 0 = black
##   smoke  how much smoke it gives off
##   sparks rising embers
##   ash    0 = black char .. 1 = grey-white ash
static func look(age_h: float) -> Dictionary:
	# Holds as a bonfire for most of its span, then dies back quickly.
	var flame := 1.0 - pow(clampf(age_h / FLAME_HOURS, 0.0, 1.0), 1.6)
	var heat := 1.0 - smoothstep(FLAME_HOURS * 0.6, EMBER_HOURS, age_h)
	var smoke_lvl := (0.3 + 0.7 * flame) * (1.0 - smoothstep(EMBER_HOURS - 1.5, EMBER_HOURS + 0.5, age_h))
	return {
		"flame": flame,
		"heat": heat,
		"smoke": smoke_lvl,
		"sparks": maxf(flame, heat * 0.25),
		"ash": smoothstep(ASH_FROM_HOURS, TOTAL_HOURS, age_h),
	}


## Remove every pile left by a structure (`node` is the structure or any mesh in
## it) — called when burned meshes are restored.
static func clear_for(node: Node) -> void:
	if node == null or not node.is_inside_tree():
		return
	for p in node.get_tree().get_nodes_in_group(GROUP):
		var scope := instance_from_id(int(p.get_meta("fire_scope", 0))) as Node
		if scope == null:
			continue
		if scope == node or scope.is_ancestor_of(node) or node.is_ancestor_of(scope):
			p.queue_free()


## A unit mound (radius 1, about 1 high, rim on y = 0), lumpy, with a ragged
## edge. UV.x is the radius. The node scales it to the footprint.
static func mound_mesh() -> ArrayMesh:
	if _mound_mesh != null:
		return _mound_mesh
	const RINGS := 9
	const SEGS := 28
	var rng := RandomNumberGenerator.new()
	rng.seed = 4711
	var grid: Array[PackedVector3Array] = []
	for r in RINGS + 1:
		var rr := float(r) / float(RINGS)
		var row := PackedVector3Array()
		for s in SEGS:
			var a := TAU * float(s) / float(SEGS)
			var lump := 0.85 if r == 0 else 0.6 + 0.4 * rng.randf()
			var edge := 1.0 + (rng.randf() - 0.5) * 0.16 if r == RINGS else 1.0
			row.append(Vector3(cos(a) * rr * edge, pow(1.0 - rr * rr, 1.3) * lump, sin(a) * rr * edge))
		grid.append(row)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in RINGS:
		var u0 := float(r) / float(RINGS)
		var u1 := float(r + 1) / float(RINGS)
		for s in SEGS:
			var s1 := (s + 1) % SEGS
			var quad: Array = [
				[grid[r][s], u0], [grid[r + 1][s], u1], [grid[r + 1][s1], u1], [grid[r][s1], u0]]
			for tri: Array in [[0, 1, 2], [0, 2, 3]]:
				if r == 0 and tri == [0, 2, 3]:
					continue  # the centre ring is one point: that triangle is empty
				for k: int in tri:
					st.set_uv(Vector2(float(quad[k][1]), 0.0))
					st.add_vertex(quad[k][0])
	st.generate_normals()
	st.index()
	_mound_mesh = st.commit()
	return _mound_mesh


## Call after add_child. `centre` is the middle of the base, on the ground.
func setup(centre: Vector3, footprint_radius: Vector2, mound_height: float,
		fell_from_m: float, scope: Node) -> void:
	add_to_group(GROUP)
	global_position = centre
	radius = footprint_radius
	height = mound_height
	structure_height = fell_from_m
	if scope != null and is_instance_valid(scope):
		set_meta("fire_scope", scope.get_instance_id())
		scope.tree_exiting.connect(queue_free)  # the structure was deleted

	mound = MeshInstance3D.new()
	mound.name = "Mound"
	mound.mesh = mound_mesh()
	_mat = ShaderMaterial.new()
	_mat.shader = PILE_SHADER
	mound.material_override = _mat
	mound.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Never a burn target: FireNode skips anything already marked burned.
	mound.set_meta("fire_burned", true)
	mound.position = Vector3(0.0, -0.04, 0.0)
	add_child(mound)
	set_rise(0.0)

	light = OmniLight3D.new()
	light.name = "PileLight"
	light.shadow_enabled = false
	light.omni_attenuation = 1.1
	light.position = Vector3(0.0, height + 0.6, 0.0)
	add_child(light)
	_apply_look(look(0.0), 0.0)


## 0..1 while the structure is coming down: the mound heaps up under it.
func set_rise(u: float) -> void:
	if mound != null:
		mound.scale = Vector3(radius.x, maxf(height * smoothstep(0.2, 1.0, u), 0.02), radius.y)


## Take COPIES of a fire's emitters (its own are about to stop) and point them
## at the footprint. Null entries are fine — that layer is simply absent.
func adopt_emitters(flame_src: GPUParticles3D, smoke_src: GPUParticles3D,
		ember_src: GPUParticles3D) -> void:
	var points := _footprint_points()
	flames = _adopt(flame_src, "PileFlames", FLAME_AMOUNT, 40.0, points)
	smoke = _adopt(smoke_src, "PileSmoke", SMOKE_AMOUNT, 140.0, points)
	embers = _adopt(ember_src, "PileEmbers", EMBER_AMOUNT, 80.0, points)
	_look_bucket = -1
	_apply_look(look(age_hours), 0.0)


## The structure has landed: from here the pile burns down on the sim clock.
func ignite() -> void:
	_aging = true
	set_rise(1.0)


## The short, violent flare as the structure drops into its own fire: a burst of
## flame, a rolling puff of smoke and a shower of sparks, one shot each.
func whoosh() -> void:
	_whoosh = 1.0
	var power := clampf(sqrt(maxf(structure_height, 0.5) / 4.0), 0.7, 2.2)
	var box := Vector3(radius.x * 0.8, 0.25, radius.y * 0.8)
	var reach := maxf(radius.x, radius.y) + 20.0
	var specs: Array[Dictionary] = [
		{"src": flames, "name": "WhooshFlames", "amount": 110, "life": 1.5, "expl": 0.82,
			"spread": 26.0, "v": Vector2(5.0, 12.0), "g": 7.0, "scale": Vector2(1.0, 2.4),
			"damp": Vector2(1.5, 3.0), "rise": 40.0},
		{"src": smoke, "name": "WhooshSmoke", "amount": 70, "life": 6.0, "expl": 0.8,
			"spread": 38.0, "v": Vector2(4.0, 10.0), "g": 6.0, "scale": Vector2(1.6, 3.4),
			"damp": Vector2(0.6, 1.2), "rise": 120.0},
		{"src": embers, "name": "WhooshSparks", "amount": 220, "life": 3.2, "expl": 0.9,
			"spread": 55.0, "v": Vector2(5.0, 14.0), "g": -3.5, "scale": Vector2(0.5, 1.4),
			"damp": Vector2(0.1, 0.4), "rise": 60.0},
	]
	for spec in specs:
		var src := spec["src"] as GPUParticles3D
		if src == null:
			continue
		var ps := GPUParticles3D.new()
		ps.name = String(spec["name"])
		ps.amount = int(spec["amount"])
		ps.lifetime = float(spec["life"])
		ps.one_shot = true
		ps.explosiveness = float(spec["expl"])
		ps.fixed_fps = src.fixed_fps
		ps.local_coords = false
		ps.draw_pass_1 = src.draw_pass_1
		ps.visibility_aabb = AABB(Vector3(-reach, -4.0, -reach),
			Vector3(reach * 2.0, float(spec["rise"]) * power + 8.0, reach * 2.0))
		var pm := (src.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
		pm.emission_box_extents = box
		pm.direction = Vector3.UP
		pm.spread = float(spec["spread"])
		var v: Vector2 = spec["v"]
		pm.initial_velocity_min = v.x * power
		pm.initial_velocity_max = v.y * power
		pm.gravity = Vector3(0.0, float(spec["g"]), 0.0)
		var sc: Vector2 = spec["scale"]
		pm.scale_min = sc.x * power
		pm.scale_max = sc.y * power
		var damp: Vector2 = spec["damp"]
		pm.damping_min = damp.x
		pm.damping_max = damp.y
		ps.process_material = pm
		add_child(ps)
		ps.emitting = true
		whoosh_emitters.append(ps)


## Put out by the extinguisher: the flames go at once, the glow dies in a couple
## of seconds, and the pile stays whatever colour it had reached.
func douse() -> void:
	if _doused:
		return
	_doused = true
	_douse_t = 0.0


## How much open flame is left (0 once it is embers, or doused).
func flame_level() -> float:
	if _doused or _finished:
		return 0.0
	return float(look(age_hours)["flame"])


func is_finished() -> bool:
	return _finished


func _process(delta: float) -> void:
	advance(delta, delta * maxf(_time_scale(), 0.0))


## One step: `delta` real seconds (flicker, the whoosh, dousing) and `sim_hours`
## of burning down. Public so the selftest can drive it without a clock.
func advance(delta: float, sim_hours: float) -> void:
	if _finished:
		return
	_flicker += delta
	_whoosh = maxf(0.0, _whoosh - delta / WHOOSH_SECONDS)
	var l := look(age_hours)
	if _doused:
		_douse_t += delta
		var k := clampf(1.0 - _douse_t / DOUSE_SECONDS, 0.0, 1.0)
		l["flame"] = 0.0
		l["sparks"] = 0.0
		l["heat"] = float(l["heat"]) * k
		l["smoke"] = float(l["smoke"]) * k
		_apply_look(l, delta)
		if k <= 0.0 and _whoosh <= 0.0:
			_finish()
		return
	if _aging:
		age_hours += sim_hours
		l = look(age_hours)
	_apply_look(l, delta)
	if age_hours >= TOTAL_HOURS and _whoosh <= 0.0:
		_finish()


## Cold: nothing left to animate. The mound stays as it is.
func _finish() -> void:
	_finished = true
	for ps: GPUParticles3D in [flames, smoke, embers]:
		if ps != null and is_instance_valid(ps):
			ps.queue_free()
	for ps in whoosh_emitters:
		if is_instance_valid(ps):
			ps.queue_free()
	whoosh_emitters.clear()
	flames = null
	smoke = null
	embers = null
	if light != null:
		light.queue_free()
		light = null
	if _mat != null:
		_mat.set_shader_parameter("heat", 0.0)
	set_process(false)


func _apply_look(l: Dictionary, _delta: float) -> void:
	var flame := float(l["flame"])
	var heat := float(l["heat"])
	if _mat != null:
		_mat.set_shader_parameter("heat", heat)
		_mat.set_shader_parameter("ash", float(l["ash"]))
	_set_level(flames, flame, 0.15)
	_set_level(smoke, float(l["smoke"]), 0.08)
	_set_level(embers, float(l["sparks"]), 0.05)
	# A bonfire throws flame high; a dying one only licks. Stepped, so the
	# particle materials are not rewritten every frame.
	var bucket := int(flame * 16.0)
	if bucket != _look_bucket:
		_look_bucket = bucket
		var size := clampf(maxf(radius.x, radius.y) / 1.5, 0.8, 2.2)
		var fm := _pm(flames)
		if fm != null:
			fm.initial_velocity_min = lerpf(0.4, 1.8, flame) * size
			fm.initial_velocity_max = lerpf(1.0, 4.6, flame) * size
			fm.gravity = Vector3(0.0, lerpf(1.5, 6.5, flame), 0.0)
			fm.scale_min = lerpf(0.3, 0.5, flame) * size
			fm.scale_max = lerpf(0.6, 1.1, flame) * size
		var sm := _pm(smoke)
		if sm != null:
			sm.initial_velocity_min = lerpf(0.6, 3.2, flame)
			sm.initial_velocity_max = lerpf(1.3, 6.0, flame)
			sm.gravity = Vector3(0.0, lerpf(2.0, 10.0, flame), 0.0)
		var em := _pm(embers)
		if em != null:
			em.initial_velocity_min = lerpf(0.5, 2.8, flame)
			em.initial_velocity_max = lerpf(1.2, 5.5, flame)
			em.gravity = Vector3(0.0, lerpf(1.2, 5.5, flame), 0.0)
	if light != null:
		var flick := sin(_flicker * 6.0) * 0.22 + sin(_flicker * 10.3) * 0.14 + sin(_flicker * 15.1) * 0.08 + 1.0
		# Embers glow steadily; only flame flickers.
		var energy := flame * 9.0 * flick + heat * 1.4 * (0.92 + 0.08 * sin(_flicker * 1.4))
		light.light_energy = energy + _whoosh * _whoosh * 24.0
		light.light_color = Color(1.0, 0.2, 0.04).lerp(Color(1.0, 0.55, 0.18), clampf(flame * 1.5 + _whoosh, 0.0, 1.0))
		light.omni_range = 6.0 + maxf(radius.x, radius.y) * 2.0 + flame * 14.0 + _whoosh * 14.0
		light.visible = light.light_energy > 0.02


func _set_level(ps: GPUParticles3D, level: float, floor_ratio: float) -> void:
	if ps == null or not is_instance_valid(ps):
		return
	var on := level > 0.02
	ps.emitting = on
	if on:
		ps.amount_ratio = clampf(level, floor_ratio, 1.0)


func _pm(ps: GPUParticles3D) -> ParticleProcessMaterial:
	if ps == null or not is_instance_valid(ps):
		return null
	return ps.process_material as ParticleProcessMaterial


func _adopt(src: GPUParticles3D, node_name: String, amount: int, rise_m: float,
		points: PackedVector3Array) -> GPUParticles3D:
	if src == null or not is_instance_valid(src):
		return null
	var ps := GPUParticles3D.new()
	ps.name = node_name
	ps.amount = amount
	ps.lifetime = src.lifetime
	ps.fixed_fps = src.fixed_fps
	ps.local_coords = false
	ps.draw_pass_1 = src.draw_pass_1
	var r := maxf(radius.x, radius.y) + 14.0
	ps.visibility_aabb = AABB(Vector3(-r, -4.0, -r), Vector3(r * 2.0, rise_m + 8.0, r * 2.0))
	var pm := (src.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
	var img := Image.create(points.size(), 1, false, Image.FORMAT_RGBF)
	for i in points.size():
		img.set_pixel(i, 0, Color(points[i].x, points[i].y, points[i].z))
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	pm.emission_point_texture = ImageTexture.create_from_image(img)
	pm.emission_point_count = points.size()
	pm.direction = Vector3.UP
	ps.process_material = pm
	add_child(ps)
	ps.emitting = true
	return ps


## Points over the mound, in this node's own frame: a sunflower spiral, so the
## whole footprint burns rather than a ring or a centre spot.
func _footprint_points() -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in EMISSION_POINTS:
		var rr := sqrt((float(i) + 0.5) / float(EMISSION_POINTS))
		var a := float(i) * 2.39996323
		out.append(Vector3(
			cos(a) * rr * radius.x * 0.9,
			height * pow(1.0 - rr * rr, 1.3) * 0.6,
			sin(a) * rr * radius.y * 0.9))
	return out


## Sim-hours per real second, off the same root node FireNode reads.
func _time_scale() -> float:
	if _clock == null or not is_instance_valid(_clock):
		_clock = null
		var tree := get_tree()
		if tree == null:
			return 1.0
		for child in tree.root.get_children():
			if "time_scale" in child:
				_clock = child
				break
	return float(_clock.time_scale) if _clock != null else 1.0

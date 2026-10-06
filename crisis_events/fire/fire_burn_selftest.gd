extends SceneTree

## Self-test for the fire burn front (FireNode surface mode): ignition lands at
## the BASE of a model whatever its own axes and import scale are, the front
## climbs monotonically from bottom to top, flames are emitted from surface
## points, the char overlay follows the front, and a restore takes it off again.
## Then the END of the fire: at three quarters consumed the structure collapses
## into a FireAshPile over its base (it must not hang in the air, and no flame
## may be left up where it stood), which burns down bonfire -> embers -> ash on
## the sim clock and stays behind as ash after the fire node has gone.
## Offline (headless has no renderer, so the char shader itself is not compiled
## here — the windowed game is what proves that).
##   godot --headless --path . --script crisis_events/fire/fire_burn_selftest.gd
##
## The rig is the worst case that produced "the flame starts at the very top":
## an inch-unit, Z-up import (node scaled 0.0254 and turned -90 deg about X), so
## the mesh's LOCAL Y is horizontal and its local sizes are 39x its real ones.

const EXPECTED_CHECKS := 45

var _failures := 0
var _checks := 0
var _frames := 0
var _rig: Node3D = null
var _mesh: MeshInstance3D = null
var _fire: FireNode = null
var _pile: FireAshPile = null


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _initialize() -> void:
	# FireNode reads the sim clock off the first root child with `time_scale`.
	# Without one it assumes 1 sim-hour per second and burns out in a blink.
	var clock := Node.new()
	clock.name = "Clock"
	clock.set_script(_clock_script())
	root.add_child(clock)

	_rig = Node3D.new()
	_rig.name = "Rig"
	root.add_child(_rig)
	_rig.position = Vector3(40.0, 12.0, -7.0)
	var import_node := Node3D.new()
	import_node.name = "InchZUp"
	import_node.transform = Transform3D(
		Basis(Vector3.RIGHT, -PI * 0.5).scaled(Vector3.ONE * 0.0254), Vector3.ZERO)
	_rig.add_child(import_node)
	_mesh = MeshInstance3D.new()
	_mesh.name = "Tower"
	var box := BoxMesh.new()
	box.size = Vector3(80.0, 80.0, 240.0)   # inches; local Z is "up"
	_mesh.mesh = box
	_mesh.position = Vector3(0.0, 0.0, 120.0)  # stand it on the rig origin
	import_node.add_child(_mesh)
	process_frame.connect(_on_frame)


func _clock_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node\nvar time_scale := 0.0\n"
	s.reload()
	return s


func _on_frame() -> void:
	_frames += 1
	if _frames == 1:
		_spawn()
	elif _frames == 4:
		_run_checks()


func _spawn() -> void:
	var world := FireNode._mesh_world_aabb(_mesh)
	_check("rig is ~6.1 m tall in world space", absf(world.size.y - 6.096) < 0.01,
		"h=%.3f" % world.size.y)
	var spawn := FireNode.ignition_point_on_mesh_bottom(_mesh)
	_check("ignition point is in the bottom quarter of the WORLD box",
		spawn.y >= world.position.y and spawn.y <= world.position.y + world.size.y * 0.25,
		"y=%.2f base=%.2f top=%.2f" % [spawn.y, world.position.y, world.end.y])
	var pts := FireNode.sample_surface_points([_mesh], 600)
	var sorted_ok := pts.size() >= 60
	var inside := true
	for i in pts.size():
		if i > 0 and pts[i].y < pts[i - 1].y:
			sorted_ok = false
		inside = inside and world.grow(0.01).has_point(pts[i])
	_check("surface points are sorted by height", sorted_ok, "n=%d" % pts.size())
	_check("surface points lie on the model in world space", inside)
	_check("surface points span the whole height",
		pts[0].y < world.position.y + 0.3 and pts[pts.size() - 1].y > world.end.y - 0.3)

	_fire = FireNode.new()
	_fire.name = "Fire_Test"
	_fire.target_mesh = _mesh
	_fire.burn_scope = _rig
	_fire.intensity = 16.0
	root.add_child(_fire)
	_fire.global_position = spawn


## The burn-down curve: flames first, then a long ember bed, black, then ash.
func _test_pile_look() -> void:
	var at0 := FireAshPile.look(0.0)
	_check("a fresh pile is a full bonfire", is_equal_approx(at0["flame"], 1.0)
		and is_equal_approx(at0["heat"], 1.0) and is_zero_approx(at0["ash"]))
	var embers := FireAshPile.look(FireAshPile.FLAME_HOURS)
	_check("when the flames are gone it is still a hot, smoking ember bed",
		is_zero_approx(embers["flame"]) and embers["heat"] > 0.5 and embers["smoke"] > 0.1,
		"heat=%.2f smoke=%.2f" % [embers["heat"], embers["smoke"]])
	var black := FireAshPile.look(FireAshPile.EMBER_HOURS)
	_check("it goes black before it goes grey", is_zero_approx(black["heat"]) and black["ash"] < 0.1,
		"ash=%.2f" % black["ash"])
	var done := FireAshPile.look(FireAshPile.TOTAL_HOURS)
	_check("it ends as cold ash", is_equal_approx(done["ash"], 1.0) and is_zero_approx(done["heat"])
		and is_zero_approx(done["smoke"]) and is_zero_approx(done["sparks"]))
	var mono := true
	var prev := at0
	var t := 0.0
	while t <= FireAshPile.TOTAL_HOURS:
		var l := FireAshPile.look(t)
		if l["flame"] > prev["flame"] + 1e-6 or l["heat"] > prev["heat"] + 1e-6 or l["ash"] < prev["ash"] - 1e-6:
			mono = false
		prev = l
		t += 0.05
	_check("it only ever burns DOWN (flame, heat fall; ash rises)", mono)
	_check("the bonfire lasts hours", FireAshPile.FLAME_HOURS >= 2.0
		and FireAshPile.look(1.0)["flame"] > 0.4)


func _test_collapse_and_pile(world: AABB) -> void:
	# Past three quarters consumed: it fails.
	_fire.fire_time_hours = FireNode.DESTROY_TIME_HOURS * 0.96
	_fire._advance_burn_front(0.1, 0.0, false)
	_pile = _fire.ash_pile
	_check("at three quarters consumed the structure starts to collapse",
		_fire.burn_phase == FireNode.BurnPhase.COLLAPSING and _pile != null)
	if _pile == null:
		return
	_check("it collapses from 75 % gone, not from further",
		is_equal_approx(float(_fire._ash_mat.get_shader_parameter("dissolve")), FireNode.COLLAPSE_AT_DISSOLVE))
	_check("the remains FALL (still drawn), they do not just vanish",
		_mesh.visible and _mesh.material_override == _fire._ash_mat)
	var c := _pile.global_position
	_check("the pile sits on the ground at the middle of the base",
		absf(c.y - world.position.y) < 0.05 and absf(c.x - world.get_center().x) < 0.1
		and absf(c.z - world.get_center().z) < 0.1, "at %s" % c)
	_check("the pile covers the base footprint (2 m square -> ~1.1 m radius)",
		_pile.radius.x > 0.9 and _pile.radius.x < 1.4 and _pile.radius.y > 0.9 and _pile.radius.y < 1.4,
		"r=%s" % _pile.radius)
	_check("the fire came down to the base with it",
		_fire.global_position.y < world.position.y + world.size.y * 0.25, "y=%.2f" % _fire.global_position.y)
	_check("no flame is left burning up where the structure stood",
		not _fire.flame_particles.emitting and not _fire.smoke_particles.emitting
		and not _fire.ember_particles.emitting)
	var pm := _pile.flames.process_material as ParticleProcessMaterial
	var in_foot := pm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	for p in _pile._footprint_points():
		if absf(p.x) > _pile.radius.x or absf(p.z) > _pile.radius.y or p.y < 0.0 or p.y > _pile.height:
			in_foot = false
	_check("the pile's flames come from all over its footprint, at pile height", in_foot)

	# Part-way down.
	_fire._advance_collapse(_fire._collapse_seconds * 0.6)
	var fall := float(_fire._ash_mat.get_shader_parameter("collapse"))
	_check("the fall takes time", fall > 0.3 and fall < 1.0 and _mesh.visible, "collapse=%.2f" % fall)
	var one_shots := _pile.whoosh_emitters.size() == 3
	for ps in _pile.whoosh_emitters:
		one_shots = one_shots and ps.one_shot and ps.explosiveness > 0.7
	_check("landing throws up a one-shot whoosh of flame, smoke and sparks", one_shots,
		"n=%d" % _pile.whoosh_emitters.size())

	# Down.
	_fire._advance_collapse(10.0)
	_check("once down, the structure is gone and the fire is a pile",
		_fire.burn_phase == FireNode.BurnPhase.PILE and not _mesh.visible
		and bool(_mesh.get_meta("fire_burned", false))
		and float(_fire._ash_mat.get_shader_parameter("dissolve")) >= FireNode.COLLAPSE_END_DISSOLVE - 0.001)
	_check("the mound is heaped to full height",
		is_equal_approx(_pile.mound.scale.y, _pile.height) and _pile.height > 0.15)

	# Burning down, on SIM time. (The rig clock reads 0, so nothing moves unless
	# this drives it.)
	_pile.set_process(false)
	_pile.advance(0.1, 1.0)
	_fire._process_aftermath(0.1, false)
	_check("an hour on it is a bonfire, and still a fire to fight",
		_pile.flames.emitting and _pile.flames.amount_ratio > 0.4
		and float(_pile._mat.get_shader_parameter("heat")) > 0.99
		and not _fire.is_queued_for_deletion() and _fire.intensity > FireNode.EXTINGUISH_THRESHOLD)
	_pile.advance(0.1, 3.0)
	_check("four hours on: no flames, glowing and smoking embers",
		not _pile.flames.emitting and _pile.smoke.emitting
		and float(_pile._mat.get_shader_parameter("heat")) > 0.3
		and is_zero_approx(float(_pile._mat.get_shader_parameter("ash"))))
	_fire._process_aftermath(0.1, false)
	_check("with the flames out the fire node goes, and says so once",
		_fire.is_queued_for_deletion() and _fire._extinguish_signalled)
	_pile.advance(5.0, FireAshPile.TOTAL_HOURS)  # 5 s real: the whoosh has died too
	_check("in the end it is cold grey ash, and the ash stays",
		_pile.is_finished() and _pile.flames == null and _pile.light == null
		and is_zero_approx(float(_pile._mat.get_shader_parameter("heat")))
		and is_equal_approx(float(_pile._mat.get_shader_parameter("ash")), 1.0)
		and not _pile.is_queued_for_deletion() and _pile.mound.visible)


func _run_checks() -> void:
	var world := FireNode._mesh_world_aabb(_mesh)
	_fire.set_process(false)  # drive the front by hand from here: deterministic
	_check("the fire switched to surface mode", _fire._surface_mode)
	_check("it starts at the base", _fire.global_position.y < world.position.y + world.size.y * 0.25,
		"y=%.2f" % _fire.global_position.y)
	_check("the mesh carries the char overlay",
		_mesh.material_overlay is ShaderMaterial and _mesh.has_meta("fire_char_overlay"))
	_check("the mesh keeps its own material (overlay, not override)", _mesh.material_override == null)
	var pm := _fire.flame_particles.process_material as ParticleProcessMaterial
	_check("flames emit from surface points",
		pm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_POINTS
		and pm.emission_point_count >= 6 and pm.emission_point_texture != null)
	_check("emitters sit at the node with unit scale",
		_fire.flame_particles.position == Vector3.ZERO and _fire.flame_particles.scale == Vector3.ONE)

	# Climb. 2 s steps; the front must rise and never fall back.
	var last_y := _fire.global_position.y
	var last_p := _fire.burn_progress
	var monotonic := true
	var mid_ratio := 0.0
	var early_reach := float(_fire._char_mat.get_shader_parameter("reach_m"))
	var steps := 0
	while _fire.burn_progress < 1.0 and steps < 200:
		_fire._advance_burn_front(2.0, 0.0, false)
		steps += 1
		if _fire.global_position.y < last_y - 0.6 or _fire.burn_progress < last_p:
			monotonic = false
		last_y = maxf(last_y, _fire.global_position.y)
		last_p = _fire.burn_progress
		if _fire.burn_progress > 0.45 and mid_ratio == 0.0:
			mid_ratio = _fire.flame_particles.amount_ratio
	_check("the front reaches the top", _fire.burn_progress >= 1.0, "steps=%d" % steps)
	_check("it takes real time to get there (not one frame)", steps >= 6, "steps=%d" % steps)
	_check("the fire climbs and never drops back", monotonic)
	_check("it ends in the upper half", _fire.global_position.y > world.position.y + world.size.y * 0.5,
		"y=%.2f" % _fire.global_position.y)
	_check("the char front is at the top", float(_fire._char_mat.get_shader_parameter("front_y"))
		>= world.end.y - 0.05)
	_check("the fire spread round the base before it topped out",
		float(_fire._char_mat.get_shader_parameter("reach_m")) > early_reach)
	_check("more surface alight means more flame", mid_ratio > 0.14, "ratio=%.2f" % mid_ratio)

	# A sprayed fire holds its ground.
	_fire.burn_progress = 0.3
	_fire._advance_burn_front(5.0, 0.0, true)
	_check("the front does not advance while sprayed", is_equal_approx(_fire.burn_progress, 0.3))

	# Late in its life the whole structure goes black, then burns away.
	_fire.burn_progress = 1.0
	_fire.fire_time_hours = FireNode.DESTROY_TIME_HOURS * 0.92
	_fire._advance_burn_front(0.1, 0.0, false)
	_check("the structure is black, then eaten away, before it is destroyed",
		float(_fire._char_mat.get_shader_parameter("char_all")) > 0.99
		and _mesh.material_override == _fire._ash_mat and _mesh.material_overlay == null
		and float(_fire._ash_mat.get_shader_parameter("dissolve")) > 0.5)
	_check("it is still standing while less than three quarters is gone",
		_fire.burn_phase == FireNode.BurnPhase.BURNING and _fire.ash_pile == null)

	_test_pile_look()
	_test_collapse_and_pile(world)

	FireNode._restore_burned_mesh(_mesh)
	_check("a restore removes the char and the ash", _mesh.material_overlay == null
		and _mesh.material_override == null and not _mesh.has_meta("fire_char_overlay"))
	_check("a restore brings the structure back and clears its ash pile",
		_mesh.visible and _pile != null and _pile.is_queued_for_deletion())

	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)"
			% [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("FIRE BURN SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("FIRE BURN SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)

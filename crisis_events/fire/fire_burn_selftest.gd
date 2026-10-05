extends SceneTree

## Self-test for the fire burn front (FireNode surface mode): ignition lands at
## the BASE of a model whatever its own axes and import scale are, the front
## climbs monotonically from bottom to top, flames are emitted from surface
## points, the char overlay follows the front, and a restore takes it off again.
## Offline (headless has no renderer, so the char shader itself is not compiled
## here — the windowed game is what proves that).
##   godot --headless --path . --script crisis_events/fire/fire_burn_selftest.gd
##
## The rig is the worst case that produced "the flame starts at the very top":
## an inch-unit, Z-up import (node scaled 0.0254 and turned -90 deg about X), so
## the mesh's LOCAL Y is horizontal and its local sizes are 39x its real ones.

const EXPECTED_CHECKS := 21

var _failures := 0
var _checks := 0
var _frames := 0
var _rig: Node3D = null
var _mesh: MeshInstance3D = null
var _fire: FireNode = null


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
	_fire.fire_time_hours = FireNode.DESTROY_TIME_HOURS * 0.95
	_fire._advance_burn_front(0.1, 0.0, false)
	_check("the structure is black, then eaten away, before it is destroyed",
		float(_fire._char_mat.get_shader_parameter("char_all")) > 0.99
		and _mesh.material_override == _fire._ash_mat and _mesh.material_overlay == null
		and float(_fire._ash_mat.get_shader_parameter("dissolve")) > 0.5)

	FireNode._restore_burned_mesh(_mesh)
	_check("a restore removes the char and the ash", _mesh.material_overlay == null
		and _mesh.material_override == null and not _mesh.has_meta("fire_char_overlay"))

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

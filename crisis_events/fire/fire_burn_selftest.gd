extends SceneTree

## Self-test for the fire burn front (FireNode surface mode): ignition lands at
## the BASE of a model whatever its own axes and import scale are, the front
## climbs monotonically from bottom to top, flames are emitted from surface
## points, the char overlay follows the front, and a restore takes it off again.
## Then the END of the fire: at three quarters consumed the structure collapses
## into a FireAshPile over its base (it must not hang in the air, and no flame
## may be left up where it stood), a one-shot whoosh fires on landing, and the
## pile burns down bonfire -> embers -> black -> ash.
##
## Since the time rewrite the whole thing is a PURE FUNCTION of the sim clock
## (FireTimeline): this file pins the record maths (burn hours net of
## extinguisher holds, the phase ladder, the fuel estimate, put-out freezing)
## and then drives ONE FireNode through its life by MOVING THE CLOCK — forward
## to ash, BACK to a standing structure, forward again — asserting the scene
## reconciles both ways. Offline (headless has no renderer, so the shaders are
## only proven by the windowed game).
##   godot --headless --path . --script crisis_events/fire/fire_burn_selftest.gd
##
## The rig is the worst case that produced "the flame starts at the very top":
## an inch-unit, Z-up import (node scaled 0.0254 and turned -90 deg about X), so
## the mesh's LOCAL Y is horizontal and its local sizes are 39x its real ones.

const EXPECTED_CHECKS := 69

var _failures := 0
var _checks := 0
var _frames := 0
var _rig: Node3D = null
var _mesh: MeshInstance3D = null
var _fire: FireNode = null
var _pile: FireAshPile = null
var _clock: Node = null


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _initialize() -> void:
	# FireNode reads the sim clock off the first root child with
	# `get_absolute_hours` (Main in the game). This one is driven by hand.
	_clock = Node.new()
	_clock.name = "Clock"
	_clock.set_script(_clock_script())
	root.add_child(_clock)

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
	s.source_code = "extends Node\nvar time_scale := 0.0\nvar abs_h := 1000.0\nfunc get_absolute_hours() -> float:\n\treturn abs_h\n"
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
	# 80x80x240 in = 2.03x2.03x6.10 m box: 2*(2.03^2) + 4*(2.03*6.10) = 57.8 m2
	_check("the sample measures the WORLD surface area through the inch import",
		absf(FireNode._last_sampled_area_m2 - 57.8) < 1.5, "area=%.1f" % FireNode._last_sampled_area_m2)

	_fire = FireNode.new()
	_fire.name = "Fire_Test"
	_fire.target_mesh = _mesh
	_fire.burn_scope = _rig
	_fire.intensity = 16.0
	_fire.ignite_at(1000.0)
	root.add_child(_fire)
	_fire.global_position = spawn


## One rendered frame at clock hour `h`.
func _at(h: float, delta: float = 0.1) -> Dictionary:
	_clock.abs_h = h
	_fire._process(delta)
	return FireTimeline.state_at(_fire.burn_rec, h)


func _run_checks() -> void:
	_test_timeline_maths()
	_test_estimate()
	var world := FireNode._mesh_world_aabb(_mesh)
	_fire.set_process(false)  # drive the clock by hand from here: deterministic
	_at(1000.0)
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
	var rec := _fire.burn_rec
	_check("lighting it filled in durations from the geometry (and kept them as 'auto')",
		rec.has("auto") and float(rec["climb_h"]) > 0.0 and float(rec["bonfire_h"]) > 0.0
		and is_equal_approx(float(rec["climb_h"]), float(rec["auto"]["climb_h"])),
		"rec=%s" % str(rec))
	var climb := FireTimeline.climb_h(rec)
	_check("a 6 m tower takes on the order of 20 minutes to collapse", climb > 0.2 and climb < 0.6,
		"climb_h=%.2f" % climb)

	# Climb: the front must rise with the clock and never fall back.
	var last_y := _fire.global_position.y
	var last_p := _fire.burn_progress
	var monotonic := true
	var mid_ratio := 0.0
	var early_reach := float(_fire._char_mat.get_shader_parameter("reach_m"))
	var steps := 0
	var h := 1000.0
	while _fire.burn_progress < 1.0 and steps < 200:
		h += climb * FireTimeline.FRONT_TOP_AT / 40.0
		_at(h)
		steps += 1
		if _fire.global_position.y < last_y - 0.6 or _fire.burn_progress < last_p:
			monotonic = false
		last_y = maxf(last_y, _fire.global_position.y)
		last_p = _fire.burn_progress
		if _fire.burn_progress > 0.45 and mid_ratio == 0.0:
			mid_ratio = _fire.flame_particles.amount_ratio
	_check("the front reaches the top", _fire.burn_progress >= 1.0, "steps=%d" % steps)
	_check("it takes sim time to get there (not one frame)", steps >= 30, "steps=%d" % steps)
	_check("the fire climbs and never drops back", monotonic)
	_check("it ends in the upper half", _fire.global_position.y > world.position.y + world.size.y * 0.5,
		"y=%.2f" % _fire.global_position.y)
	_check("the char front is at the top", float(_fire._char_mat.get_shader_parameter("front_y"))
		>= world.end.y - 0.05)
	_check("the fire spread round the base before it topped out",
		float(_fire._char_mat.get_shader_parameter("reach_m")) > early_reach)
	_check("more surface alight means more flame", mid_ratio > 0.14, "ratio=%.2f" % mid_ratio)

	_test_hold_and_scrub(world)
	_test_collapse_and_pile(world)
	_test_put_out(world)
	_test_restore(world)

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


## The record maths, with no scene at all.
func _test_timeline_maths() -> void:
	var rec := FireTimeline.make(100.0, {"climb_h": 0.5, "bonfire_h": 6.0, "ember_h": 2.0})
	_check("before ignition there is nothing", int(FireTimeline.state_at(rec, 99.0)["phase"]) == FireTimeline.Phase.NONE)
	var mid := FireTimeline.state_at(rec, 100.2)
	_check("mid-climb the front is part way up and nothing is eaten yet",
		int(mid["phase"]) == FireTimeline.Phase.BURNING and mid["progress"] > 0.5 and mid["progress"] < 1.0
		and is_zero_approx(mid["dissolve"]), "p=%.2f d=%.2f" % [mid["progress"], mid["dissolve"]])
	var late := FireTimeline.state_at(rec, 100.49)
	_check("just before the collapse it is black and three quarters gone",
		late["char_all"] > 0.99 and late["dissolve"] > 0.55 and late["dissolve"] <= FireTimeline.DISSOLVE_AT_COLLAPSE)
	_check("the collapse is a short window after the climb",
		int(FireTimeline.state_at(rec, 100.5 + FireTimeline.COLLAPSE_H * 0.5)["phase"]) == FireTimeline.Phase.COLLAPSING)
	var pile := FireTimeline.state_at(rec, 102.0)
	_check("then it is a pile aged from the landing",
		int(pile["phase"]) == FireTimeline.Phase.PILE and absf(float(pile["age_h"]) - (1.5 - FireTimeline.COLLAPSE_H)) < 1e-4
		and (pile["look"] as Dictionary)["flame"] > 0.5)
	_check("open flame lasts the bonfire hours, then embers, then ash",
		FireTimeline.has_flame(rec, 105.9) and not FireTimeline.has_flame(rec, 106.6)
		and not FireTimeline.is_finished(rec, 108.0) and FireTimeline.is_finished(rec, 108.6))
	_check("the total life is the sum of its parts",
		is_equal_approx(FireTimeline.total_h(rec), 8.5 + FireTimeline.COLLAPSE_H))
	# Holds: the extinguisher stops the clock.
	FireTimeline.begin_hold(rec, 100.1)
	_check("an open hold runs to now", is_equal_approx(FireTimeline.burn_hours(rec, 100.3), 0.1)
		and FireTimeline.is_held(rec, 100.3))
	FireTimeline.begin_hold(rec, 100.2)
	_check("begin_hold is idempotent while a hold is open", (rec["holds"] as Array).size() == 1)
	FireTimeline.end_hold(rec, 100.3)
	_check("after the hold the clock runs again from where it stopped",
		is_equal_approx(FireTimeline.burn_hours(rec, 100.5), 0.3) and not FireTimeline.is_held(rec, 100.5))
	_check("a held fire collapses LATER by exactly the hold",
		int(FireTimeline.state_at(rec, 100.55)["phase"]) == FireTimeline.Phase.BURNING
		and int(FireTimeline.state_at(rec, 100.71)["phase"]) == FireTimeline.Phase.PILE)
	# Put out: everything freezes at that moment.
	FireTimeline.put_out(rec, 100.4)
	var frozen := FireTimeline.state_at(rec, 103.0)
	_check("put out: the state is frozen at the moment it went out",
		bool(frozen["out"]) and int(frozen["phase"]) == FireTimeline.Phase.OUT
		and is_equal_approx(float(frozen["burn_h"]), 0.2) and not FireTimeline.has_flame(rec, 103.0)
		and FireTimeline.is_finished(rec, 103.0))
	_check("...but scrubbing to before it went out shows it burning again",
		int(FireTimeline.state_at(rec, 100.35)["phase"]) == FireTimeline.Phase.BURNING
		and not bool(FireTimeline.state_at(rec, 100.35)["out"]))
	_check("and to before the ignition shows nothing", int(FireTimeline.state_at(rec, 50.0)["phase"]) == FireTimeline.Phase.NONE)
	# Edits.
	FireTimeline.set_duration(rec, "bonfire_h", 0.0)
	_check("a duration cannot be edited below its floor", float(rec["bonfire_h"]) == FireTimeline.MIN_BONFIRE_H)
	FireTimeline.reset_to_auto(rec)
	_check("reset puts the estimate back", is_equal_approx(float(rec["bonfire_h"]), 6.0))


func _test_estimate() -> void:
	var small := FireTimeline.estimate(2.0, 0.8, 10.0)
	var big := FireTimeline.estimate(12.0, 4.0, 400.0)
	_check("a bigger structure takes longer in every phase",
		big["climb_h"] > small["climb_h"] and big["bonfire_h"] > small["bonfire_h"] and big["ember_h"] > small["ember_h"])
	var tonne := FireTimeline.estimate(6.0, 1.5, 60.0, 1000.0)
	_check("a tonne of fuel is about six hours of bonfire", absf(float(tonne["bonfire_h"]) - 6.0) < 0.3,
		"bonfire_h=%.2f" % tonne["bonfire_h"])
	_check("a known mass beats the surface guess", float(tonne["mass_kg"]) == 1000.0
		and float(FireTimeline.estimate(6.0, 1.5, 60.0)["mass_kg"]) != 1000.0)
	_check("embers are a share of the bonfire", absf(float(tonne["ember_h"]) / float(tonne["bonfire_h"]) - FireTimeline.EMBER_SHARE) < 0.02)


## The extinguisher holds the climb; the clock can run backwards.
func _test_hold_and_scrub(world: AABB) -> void:
	var rec := _fire.burn_rec
	var climb := FireTimeline.climb_h(rec)
	var h0 := 1000.0 + climb * 0.3
	_at(h0)
	var p0 := _fire.burn_progress
	var dummy := Node3D.new()
	dummy.set_script(_spray_script())
	root.add_child(dummy)
	_fire.spray_bodies.append(dummy)
	_at(h0)  # the hold starts the frame the spray lands
	_at(h0 + climb * 0.1)
	_at(h0 + climb * 0.2)
	_check("while sprayed the front does not advance", is_equal_approx(_fire.burn_progress, p0)
		and FireTimeline.is_held(rec, h0 + climb * 0.2), "p0=%.3f p=%.3f" % [p0, _fire.burn_progress])
	_check("the hold is written into the record", (rec["holds"] as Array).size() == 1)
	_fire.spray_bodies.clear()
	_fire.intensity = 80.0  # the spray above pulled it down; it was not put out
	_at(h0 + climb * 0.3)  # the hold closes here...
	_at(h0 + climb * 0.4)  # ...and the clock runs again from the next frame
	_check("spraying stopped: the hold closed and the front moves again",
		float((rec["holds"] as Array)[0][1]) > 0.0 and _fire.burn_progress > p0)
	_check("the hold put the collapse later by its length",
		int(FireTimeline.state_at(rec, 1000.0 + climb + climb * 0.1)["phase"]) == FireTimeline.Phase.BURNING)
	# Scrub back to before the ignition.
	_at(999.0)
	_check("scrubbed before ignition: the mesh stands clean, no overlay, no flames",
		_mesh.visible and _mesh.material_overlay == null and _mesh.material_override == null
		and not _fire.flame_particles.emitting and _fire.burn_progress == 0.0)
	_at(h0)
	_check("scrubbed forward again: the front is back where it was",
		absf(_fire.burn_progress - p0) < 1e-3 and _mesh.material_overlay is ShaderMaterial
		and _fire.flame_particles.emitting)
	dummy.queue_free()


func _spray_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = "extends Node3D\nfunc is_extinguisher_spray() -> bool:\n\treturn true\n"
	s.reload()
	return s


func _test_collapse_and_pile(world: AABB) -> void:
	var rec := _fire.burn_rec
	var climb := FireTimeline.climb_h(rec)
	var t_collapse := 1000.0 + climb + float((rec["holds"] as Array)[0][1]) - float((rec["holds"] as Array)[0][0])
	# Nearly there: black, eaten, still standing.
	_at(t_collapse - climb * 0.05)
	_check("late in the climb the structure is black and being eaten away, still standing",
		float(_fire._char_mat.get_shader_parameter("char_all")) > 0.99
		and _mesh.material_override == _fire._ash_mat and _mesh.material_overlay == null
		and float(_fire._ash_mat.get_shader_parameter("dissolve")) > 0.4 and _mesh.visible
		and _fire.ash_pile == null)
	# Part way down.
	_at(t_collapse + FireTimeline.COLLAPSE_H * 0.3)
	_pile = _fire.ash_pile
	_check("at three quarters consumed the structure collapses and a pile appears",
		_fire._last_phase == FireTimeline.Phase.COLLAPSING and _pile != null)
	if _pile == null:
		return
	var fall := float(_fire._ash_mat.get_shader_parameter("collapse"))
	_check("the remains FALL (still drawn), they do not just vanish",
		_mesh.visible and fall > 0.2 and fall < 0.5, "collapse=%.2f" % fall)
	var c := _pile.global_position
	_check("the pile sits on the ground at the middle of the base",
		absf(c.y - world.position.y) < 0.05 and absf(c.x - world.get_center().x) < 0.1
		and absf(c.z - world.get_center().z) < 0.1, "at %s" % c)
	_check("the pile covers the base footprint (2 m square -> ~1.1 m radius)",
		_pile.radius.x > 0.9 and _pile.radius.x < 1.4 and _pile.radius.y > 0.9 and _pile.radius.y < 1.4,
		"r=%s" % _pile.radius)
	_check("no flame is left burning up where the structure stood",
		not _fire.flame_particles.emitting and not _fire.smoke_particles.emitting)
	var ppm := _pile.flames.process_material as ParticleProcessMaterial
	var in_foot := ppm.emission_shape == ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	for p in _pile._footprint_points():
		if absf(p.x) > _pile.radius.x or absf(p.z) > _pile.radius.y or p.y < 0.0 or p.y > _pile.height:
			in_foot = false
	_check("the pile's flames come from all over its footprint, at pile height", in_foot)
	_at(t_collapse + FireTimeline.COLLAPSE_H * 0.7)
	var one_shots := _pile.whoosh_emitters.size() == 3
	for ps in _pile.whoosh_emitters:
		one_shots = one_shots and ps.one_shot and ps.explosiveness > 0.7
	_check("landing throws up a one-shot whoosh of flame, smoke and sparks", one_shots,
		"n=%d" % _pile.whoosh_emitters.size())
	# Down, and burning as a bonfire.
	var t_pile := t_collapse + FireTimeline.COLLAPSE_H
	_at(t_pile + 0.02)
	_check("once down, the structure is gone and the fire is a pile",
		_fire._last_phase == FireTimeline.Phase.PILE and not _mesh.visible
		and bool(_mesh.get_meta("fire_burned", false))
		and is_equal_approx(_pile.mound.scale.y, _pile.height) and _pile.height > 0.15)
	_check("the fire came down to the base with it",
		_fire.global_position.y < world.position.y + world.size.y * 0.25, "y=%.2f" % _fire.global_position.y)
	_check("a bonfire is still a fire to fight", _pile.flames.emitting and _pile.flames.amount_ratio > 0.4
		and float(_pile._mat.get_shader_parameter("heat")) > 0.99 and not _fire._extinguish_signalled
		and _fire.intensity > FireNode.EXTINGUISH_THRESHOLD)
	var bonfire := FireTimeline.bonfire_h(rec)
	var ember := FireTimeline.ember_h(rec)
	_at(t_pile + bonfire + ember * 0.3)
	_check("after the bonfire hours: no flames, glowing and smoking embers",
		not _pile.flames.emitting and _pile.smoke.emitting
		and float(_pile._mat.get_shader_parameter("heat")) > 0.2
		and float(_pile._mat.get_shader_parameter("ash")) < 0.05)
	_check("with the flames out the event is told, once", _fire._extinguish_signalled)
	_at(t_pile + bonfire + ember + 0.1, 3.0)
	_check("in the end it is cold grey ash — and the fire node is still there to draw it",
		is_zero_approx(float(_pile._mat.get_shader_parameter("heat")))
		and is_equal_approx(float(_pile._mat.get_shader_parameter("ash")), 1.0)
		and is_instance_valid(_fire) and not _fire.is_queued_for_deletion())
	# BACK: the whole thing reverses.
	_at(t_pile + bonfire * 0.5)
	_check("scrub back into the bonfire: flames again",
		_pile.flames.emitting and float(_pile._mat.get_shader_parameter("ash")) < 0.01)
	_at(1000.0 + climb * 0.2)
	_check("scrub back into the climb: the structure stands, charred to the front, no pile",
		_mesh.visible and not bool(_mesh.get_meta("fire_burned", false)) and _mesh.material_overlay is ShaderMaterial
		and (_fire.ash_pile == null or not is_instance_valid(_fire.ash_pile) or _fire.ash_pile.is_queued_for_deletion())
		and _fire.burn_progress > 0.0 and _fire.burn_progress < 1.0 and _fire.flame_particles.emitting)
	_check("...and the event is no longer told it is out", not _fire._extinguish_signalled)
	_at(t_pile + 0.5)
	_check("forward again: the pile is back and the whoosh fires again",
		_fire.ash_pile != null and is_instance_valid(_fire.ash_pile) and not _mesh.visible
		and _fire.ash_pile.whoosh_emitters.size() == 3)
	_pile = _fire.ash_pile


func _test_put_out(world: AABB) -> void:
	var rec := _fire.burn_rec
	var t := float(rec["ignited_h"]) + FireTimeline.climb_h(rec) * 0.4
	# Spray it out mid-climb.
	_at(t)
	var dummy := Node3D.new()
	dummy.set_script(_spray_script())
	root.add_child(dummy)
	_fire.spray_bodies.append(dummy)
	_fire.intensity = 6.0
	_at(t + 0.001)
	_fire.spray_bodies.clear()
	dummy.queue_free()
	_check("sprayed to the threshold: the fire is OUT, written into the record",
		float(rec["out_h"]) >= 0.0 and _fire._extinguish_signalled and not _fire.flame_particles.emitting)
	_at(t + 2.0)
	_check("hours later it is still out, the char frozen where the front reached",
		_mesh.visible and _mesh.material_overlay is ShaderMaterial
		and is_zero_approx(float(_fire._char_mat.get_shader_parameter("ember")))
		and absf(float(FireTimeline.state_at(rec, t + 2.0)["progress"]) - float(FireTimeline.state_at(rec, t)["progress"])) < 0.05
		and (_fire.ash_pile == null or not is_instance_valid(_fire.ash_pile) or _fire.ash_pile.is_queued_for_deletion()))
	_at(t - 0.01)
	_check("scrub to before it was put out: it burns", _fire.flame_particles.emitting
		and float(_fire._char_mat.get_shader_parameter("ember")) > 0.5)


func _test_restore(world: AABB) -> void:
	_at(float(_fire.burn_rec["ignited_h"]) + 0.1)
	FireNode._restore_burned_mesh(_mesh)
	_check("a restore removes the char and the ash", _mesh.material_overlay == null
		and _mesh.material_override == null and not _mesh.has_meta("fire_char_overlay") and _mesh.visible)

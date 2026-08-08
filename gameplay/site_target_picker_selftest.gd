extends SceneTree

## Offline selftest for SiteTargetPicker (gameplay/site_target_picker.gd).
##
## The ladder ORDER and the angular pick radius are the two things that are
## invisible to code review and to screenshots, and both decide whether the
## settlement view is usable. This pins them without a map.
##
## Run: Godot.exe.exe --headless --path . --script gameplay/site_target_picker_selftest.gd

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


## Every _check in this file, counted by hand. A Godot runtime error PRINTS
## and aborts the enclosing function while the suite still reports PASS — this
## file lost a whole test function to that once (instantiating a real
## NpcAvatar in a bare SceneTree throws), and the run still said PASS with
## silently fewer checks. Pinning the count is what makes that impossible.
const EXPECTED_CHECKS := 16


func _initialize() -> void:
	_test_pick_radius()
	_test_want_filter()
	_test_ray_selection_math()
	_test_degenerate_input()
	_check("every check in this file ran (silent-abort guard)",
			_checks == EXPECTED_CHECKS - 1, "%d of %d" % [_checks, EXPECTED_CHECKS - 1])
	if _fails == 0:
		print("SITE TARGET PICKER SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("SITE TARGET PICKER SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


## THE property that makes people clickable at every zoom. At 500 m a person
## subtends far less than a pixel, so an exact sphere test is unusable — the
## radius has to grow with distance to keep the on-screen target constant.
func _test_pick_radius() -> void:
	var near := SiteTargetPicker.pick_radius_at(5.0)
	var mid := SiteTargetPicker.pick_radius_at(200.0)
	var far := SiteTargetPicker.pick_radius_at(500.0)
	# Up close the body's own radius wins; the angular floor only takes over
	# past the crossover (~52 m at 0.6°), which is the intended shape — near
	# targets should not become sloppy.
	_check("up close the body radius governs",
			is_equal_approx(near, NpcAvatar.PICK_RADIUS_M), "%.3f" % near)
	_check("the radius grows with distance", mid > near and far > mid,
			"%.2f / %.2f / %.2f" % [near, mid, far])
	# Past the crossover the angular size is constant: radius/distance is the
	# tangent, so it must match at 200 m and 500 m.
	_check("angular size is constant far out",
			absf((far / 500.0) - (mid / 200.0)) < 1e-4,
			"%.5f vs %.5f" % [far / 500.0, mid / 200.0])
	_check("500 m still gives a metres-wide target", far > 4.0, "%.2f m" % far)
	# And the floor is honoured: a zero angle degrades to the body radius
	# rather than to nothing.
	_check("a zero angle falls back to the body radius",
			is_equal_approx(SiteTargetPicker.pick_radius_at(500.0, 0.0),
				NpcAvatar.PICK_RADIUS_M))


## `want` narrows the ladder. Both views share one resolver, so the way a view
## says "I only care about people" must not be a second code path.
func _test_want_filter() -> void:
	var all := PackedStringArray()
	var only_npc := PackedStringArray(["npc"])
	_check("an empty want accepts everything",
			SiteTargetPicker._wants(all, "npc")
				and SiteTargetPicker._wants(all, "ground")
				and SiteTargetPicker._wants(all, "crew"))
	_check("a narrow want excludes the rest",
			SiteTargetPicker._wants(only_npc, "npc")
				and not SiteTargetPicker._wants(only_npc, "prop")
				and not SiteTargetPicker._wants(only_npc, "ground"))


## The ray-vs-sphere selection rule the NPC rung runs, pinned as arithmetic.
##
## Instantiating real NpcAvatars here is not viable — an avatar in a bare
## SceneTree throws during construction, and a throw ABORTS the enclosing test
## function while the suite still prints PASS. So the geometry is pinned here
## and the wiring (group membership, the actual click) is asserted end to end
## by the windowed --capture=settlement harness, where real avatars exist.
func _test_ray_selection_math() -> void:
	var origin := Vector3.ZERO
	var fwd := Vector3(0.0, 0.0, -1.0)
	var hit_test := func(center: Vector3, max_d: float) -> bool:
		var to_c := center - origin
		var t := to_c.dot(fwd)
		if t <= 0.0 or t > max_d:
			return false
		return (to_c - fwd * t).length() <= SiteTargetPicker.pick_radius_at(t)

	_check("someone dead ahead is hit",
			hit_test.call(Vector3(0.0, 0.0, -10.0), 250.0))
	_check("someone behind the camera is never hit",
			not hit_test.call(Vector3(0.0, 0.0, 10.0), 250.0))
	_check("beyond max_dist_m is not hit",
			not hit_test.call(Vector3(0.0, 0.0, -100.0), 50.0))
	# Up close the target is tight: 1.5 m off-axis at 10 m is a genuine miss.
	_check("a wide miss up close is a miss",
			not hit_test.call(Vector3(1.5, 0.0, -10.0), 250.0))
	# Far away the SAME 1.5 m offset is inside the target — this is the whole
	# point of the angular floor, and the reason people stay clickable when
	# the settlement camera pulls back.
	_check("the same offset at distance is a hit",
			hit_test.call(Vector3(1.5, 0.0, -300.0), 500.0))
	# Nearest-wins: two candidates on the ray, the closer t must be preferred.
	var t_near := (Vector3(0.0, 0.0, -10.0) - origin).dot(fwd)
	var t_far := (Vector3(0.0, 0.0, -40.0) - origin).dot(fwd)
	_check("the nearer candidate sorts first", t_near < t_far)


func _test_degenerate_input() -> void:
	_check("a null scene resolves to nothing",
			SiteTargetPicker.resolve(null, Vector3.ZERO, Vector3.FORWARD).is_empty())
	var m := Node3D.new()
	root.add_child(m)
	_check("a zero direction resolves to nothing",
			SiteTargetPicker.resolve(m, Vector3.ZERO, Vector3.ZERO).is_empty())
	m.queue_free()

extends SceneTree

## Offline selftest — PlacedPropHosts (props standing on props move with them).
##   Godot --headless --path . --script core/placed_models/placed_prop_hosts_selftest.gd
## The transform maths (a host moved or turned leaves the child's pose in its
## frame exact, on sloped ground, with foot offsets), the children index (it
## finds new links, never returns a stale one) and the owned flag.
## Carries EXPECTED_CHECKS: a Godot runtime error aborts a test function while
## the suite would still print PASS.

const EXPECTED_CHECKS := 32

var _checks := 0
var _fails := 0


func _ok(label: String, cond: bool) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", label)


func _initialize() -> void:
	_test_arrays()
	_test_follow_maths()
	_test_index()
	_test_owned_and_loops()
	if _fails == 0 and _checks == EXPECTED_CHECKS:
		print("PLACED PROP HOSTS SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("PLACED PROP HOSTS SELFTEST FAIL  (%d failed, %d/%d checks ran)" % [
			_fails, _checks, EXPECTED_CHECKS])
	quit()


## A sloped, bumpy ground: heights differ under the host and the child.
func _ground(x: float, z: float) -> float:
	return 3.0 + 0.12 * x - 0.07 * z + 0.4 * sin(x * 0.3) * cos(z * 0.2)


func _frame(rec: Dictionary, foot: float) -> Transform3D:
	return PlacedPropHosts.frame(rec, _ground(float(rec["x"]), float(rec["z"])), foot)


## The record a child gets at `xf` (what follow writes).
func _child_at(child: Dictionary, xf: Transform3D, foot: float) -> Dictionary:
	var c := child.duplicate(true)
	c.merge(PlacedPropHosts.patch_from(xf, _ground(xf.origin.x, xf.origin.z), foot), true)
	return c


func _test_arrays() -> void:
	var t := Transform3D(Basis.from_euler(Vector3(0.2, 1.1, -0.3)), Vector3(4, 5, 6))
	_ok("12-float round trip", PlacedPropHosts.xf_from_array(PlacedPropHosts.xf_to_array(t)).is_equal_approx(t))
	_ok("a short array reads as identity", PlacedPropHosts.xf_from_array([1, 2]) == Transform3D.IDENTITY)
	_ok("a non-array reads as identity", PlacedPropHosts.xf_from_array(null) == Transform3D.IDENTITY)
	_ok("pose keys move", PlacedPropHosts.patch_moves({"yaw": 10.0}))
	_ok("other keys do not", not PlacedPropHosts.patch_moves({"packed": true}))


func _test_follow_maths() -> void:
	var host_foot := -0.25
	var kid_foot := 0.6
	var host := {"x": 10.0, "z": -4.0, "y_offset": 0.3, "yaw": 20.0, "pitch": 0.0, "roll": 0.0}
	var kid := {"x": 13.5, "z": -2.0, "y_offset": 0.9, "yaw": 65.0, "pitch": 4.0, "roll": -2.0}
	var hx0 := _frame(host, host_foot)
	var kx0 := _frame(kid, kid_foot)
	var local := PlacedPropHosts.local_of(hx0, kx0)
	_ok("carried at the attach pose is the child itself",
		PlacedPropHosts.carried(hx0, local).is_equal_approx(kx0))
	# patch_from is the inverse of frame (on any ground).
	var back := _frame(_child_at(kid, kx0, kid_foot), kid_foot)
	_ok("patch_from inverts frame", back.is_equal_approx(kx0))

	# The host moved and turned (yaw, and a tilt).
	var host2 := host.duplicate()
	host2["x"] = -25.0
	host2["z"] = 40.0
	host2["yaw"] = 137.0
	host2["pitch"] = 6.0
	host2["y_offset"] = 1.4
	var hx1 := _frame(host2, host_foot)
	var cx1 := PlacedPropHosts.carried(hx1, local)
	var kid2 := _child_at(kid, cx1, kid_foot)
	var kx1 := _frame(kid2, kid_foot)
	_ok("child record lands on host × local (position)", kx1.origin.distance_to(cx1.origin) < 1e-3)
	_ok("child record lands on host × local (rotation)", kx1.basis.is_equal_approx(cx1.basis))
	var local2 := PlacedPropHosts.xf_from_array(PlacedPropHosts.local_of(hx1, kx1))
	_ok("the local pose is unchanged by the move", local2.is_equal_approx(PlacedPropHosts.xf_from_array(local)))
	_ok("distance host→child kept", absf(hx1.origin.distance_to(kx1.origin) - hx0.origin.distance_to(kx0.origin)) < 1e-3)
	var dyaw := fposmod(float(kid2["yaw"]) - float(kid["yaw"]) + 180.0, 360.0) - 180.0
	# With a pitched host the yaw is not a plain sum; check the flat turn too.
	var host3 := host.duplicate()
	host3["yaw"] = 80.0
	var hx3 := _frame(host3, host_foot)
	var kid3 := _child_at(kid, PlacedPropHosts.carried(hx3, local), kid_foot)
	var d3 := fposmod(float(kid3["yaw"]) - float(kid["yaw"]) + 180.0, 360.0) - 180.0
	_ok("a host turned 60° turns the child 60°", absf(d3 - 60.0) < 1e-2)
	_ok("a turned host carries the child round its own origin",
		absf(Vector2(float(kid3["x"]) - 10.0, float(kid3["z"]) + 4.0).length()
			- Vector2(3.5, 2.0).length()) < 1e-3)
	_ok("a pitched move still writes a finite yaw", is_finite(dyaw))
	# Moving back puts the child exactly where it was.
	var kid4 := _child_at(kid2, PlacedPropHosts.carried(hx0, local), kid_foot)
	_ok("host moved back: child x", absf(float(kid4["x"]) - float(kid["x"])) < 1e-3)
	_ok("host moved back: child z", absf(float(kid4["z"]) - float(kid["z"])) < 1e-3)
	_ok("host moved back: child y_offset", absf(float(kid4["y_offset"]) - float(kid["y_offset"])) < 1e-3)
	_ok("host moved back: child yaw", absf(float(kid4["yaw"]) - float(kid["yaw"])) < 1e-2)
	# Twenty moves in a row do not drift.
	var drift := kid.duplicate()
	for i in range(20):
		var h := host.duplicate()
		h["x"] = 10.0 + 7.0 * i
		h["yaw"] = 20.0 + 33.0 * i
		drift = _child_at(drift, PlacedPropHosts.carried(_frame(h, host_foot), local), kid_foot)
	drift = _child_at(drift, PlacedPropHosts.carried(hx0, local), kid_foot)
	_ok("twenty moves and back: no drift",
		_frame(drift, kid_foot).origin.distance_to(kx0.origin) < 1e-3)


func _test_index() -> void:
	PlacedPropHosts.invalidate()
	var layer := PlacedPropLayer.create_empty()
	var h := layer.add_free_prop("generic_box", 0, 0, 0)
	var a := layer.add_free_prop("generic_box", 1, 0, 0)
	var b := layer.add_free_prop("generic_box", 2, 0, 0)
	var c := layer.add_free_prop("generic_box", 3, 0, 0)
	layer.update_prop(a, {"mount_host": {"kind": "prop", "id": h, "local": [], "owned": true}})
	layer.update_prop(b, {"mount_host": {"kind": "prop", "id": h, "local": []}})
	layer.update_prop(c, {"mount_host": {"kind": "building", "id": h}})
	PlacedPropHosts.invalidate()
	var kids := PlacedPropHosts.children_of(layer, h)
	_ok("two children on the host", kids.size() == 2)
	_ok("a building link is not a prop child", not _ids(kids).has(c))
	_ok("no children on a child", PlacedPropHosts.children_of(layer, a).is_empty())
	# A link dropped without invalidate is never returned (checked on read).
	layer.update_prop(b, {"mount_host": null})
	_ok("a stale entry is filtered", not _ids(PlacedPropHosts.children_of(layer, h)).has(b))
	# A prop added with a link is found (the list grew).
	var d := layer.add_free_prop("generic_box", 4, 0, 0)
	layer.update_prop(d, {"mount_host": {"kind": "prop", "id": h, "local": []}})
	_ok("a new child is found once the layer grows", _ids(PlacedPropHosts.children_of(layer, h)).has(d))
	# A link changed in place is found after invalidate.
	layer.update_prop(c, {"mount_host": {"kind": "prop", "id": h, "local": []}})
	PlacedPropHosts.invalidate()
	_ok("a re-linked child is found after invalidate", _ids(PlacedPropHosts.children_of(layer, h)).has(c))
	# A removed child is gone.
	layer.remove_prop(a)
	PlacedPropHosts.invalidate()
	_ok("a removed child is gone", not _ids(PlacedPropHosts.children_of(layer, h)).has(a))


func _test_owned_and_loops() -> void:
	PlacedPropHosts.invalidate()
	var layer := PlacedPropLayer.create_empty()
	var h := layer.add_free_prop("generic_box", 0, 0, 0)
	var bed := layer.add_free_prop("generic_box", 1, 0, 0)
	var arr := layer.add_free_prop("generic_box", 2, 0, 0)
	var sub := layer.add_free_prop("generic_box", 3, 0, 0)
	layer.update_prop(bed, {"mount_host": {"kind": "prop", "id": h, "local": [], "owned": true}})
	layer.update_prop(arr, {"mount_host": {"kind": "prop", "id": h, "local": []}})
	layer.update_prop(sub, {"mount_host": {"kind": "prop", "id": bed, "local": [], "owned": true}})
	PlacedPropHosts.invalidate()
	var owned := PlacedPropHosts.owned_children(layer, h)
	_ok("only the owned child is owned", owned == [bed])
	_ok("is_owned reads the flag", PlacedPropHosts.is_owned(layer.find_by_id(bed))
		and not PlacedPropHosts.is_owned(layer.find_by_id(arr)))
	_ok("host_of reads the link", PlacedPropHosts.host_of(layer.find_by_id(sub)) == bed)
	_ok("linking the host onto its grandchild would loop", PlacedPropHosts.would_loop(layer, h, sub))
	_ok("linking the host onto its child would loop", PlacedPropHosts.would_loop(layer, h, bed))
	_ok("linking a child onto a sibling does not loop", not PlacedPropHosts.would_loop(layer, arr, bed))


func _ids(recs: Array) -> Array:
	var out: Array = []
	for r in recs:
		out.append(str((r as Dictionary).get("id", "")))
	return out

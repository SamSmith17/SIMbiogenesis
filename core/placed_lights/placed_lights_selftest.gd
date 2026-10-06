extends SceneTree

## Offline selftest for the J Light Studio (core/placed_lights/):
##   layer v2 -> v3 migration (radians -> degrees, type -> kind, identical looks
##   share ONE auto style), the built-in-map path staying the v2 path, linked
##   styles (style edits restyle every user, overrides survive and prune,
##   revert, make_unique, push_overrides, remove_style keeps the look), groups,
##   duplicate/translate incl. string waypoints, string geometry (sag below the
##   chord, bulb spacing + half-spacing inset), LedEffects (a rainbow moves one
##   bulb per 1/speed s, theatre chase lights n/gap, twinkle is deterministic),
##   the led_bulb.gdshader mirror constants, gizmo maths round trips, the
##   service's undo/redo + node refresh, and the graph-load contract (no load
##   until "Add to graph", idempotent, never a power_consumers member).
##
## Carries EXPECTED_CHECKS: a Godot runtime error aborts the enclosing test
## function while the suite still prints PASS. Runs on the first PROCESS frame
## (nodes added in _initialize never get _ready()). --import first.
##
##   Godot --headless --path . --script core/placed_lights/placed_lights_selftest.gd

const EXPECTED_CHECKS := 129

var _checks := 0
var _fails := 0
var _ran := false


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if ok:
		print("PASS  ", label)
	else:
		_fails += 1
		print("FAIL  ", label, ("  (" + detail + ")") if not detail.is_empty() else "")


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_test_migration()
	_test_paths()
	_test_styles()
	_test_groups_and_copies()
	_test_string_geometry()
	_test_led_effects()
	_test_shader_mirror()
	_test_gizmo_math()
	_test_service()
	_test_modifiers_and_bulbs()
	_test_festival_fixtures()
	_test_drag_rules()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("FAIL  check count %d != EXPECTED_CHECKS %d (a test function aborted?)" % [
			_checks, EXPECTED_CHECKS])
	print("PLACED LIGHTS SELFTEST %s  (%d checks, %d failed)" % [
		"PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)
	return true


func _near(a: float, b: float, eps: float = 1e-3) -> bool:
	return absf(a - b) <= eps


# ---------------------------------------------------------------------------

func _test_migration() -> void:
	var v2 := {"version": 2, "lights": [
		{"id": "a", "type": "omni", "x": 1.0, "y": 2.0, "z": 3.0, "pitch": 0.0, "yaw": PI / 2.0,
			"roll": 0.0, "color": "ff0000", "energy": 2.0, "range": 8.0, "spot_angle": 45.0,
			"shadow_enabled": true, "lod_m": 50.0},
		{"id": "b", "type": "omni", "x": 4.0, "y": 2.0, "z": 3.0, "pitch": 0.0, "yaw": 0.0,
			"roll": 0.0, "color": "ff0000", "energy": 2.0, "range": 8.0, "spot_angle": 45.0,
			"shadow_enabled": true, "lod_m": 50.0},
		{"id": "c", "type": "spot", "x": 0.0, "y": 5.0, "z": 0.0, "pitch": -PI / 2.0, "yaw": 0.0,
			"roll": 0.0, "color": "00ff00", "energy": 4.0, "range": 20.0, "spot_angle": 30.0},
	]}
	var layer := PlacedLightLayer.create_empty()
	layer.deserialize(v2)
	_check("v2 file reports a migration", layer.migrated_from == 2)
	_check("v2 lights all migrated", layer.lights.size() == 3)
	var a := layer.find_light("a")
	_check("type -> kind", str(a.get("kind")) == "omni" and not a.has("type"))
	_check("radians -> degrees", _near(float(a["yaw"]), 90.0) \
		and _near(float(layer.find_light("c")["pitch"]), -90.0))
	_check("identical looks share one auto style", str(a["style_id"]) == str(layer.find_light("b")["style_id"]))
	_check("a different look gets its own style", layer.styles.size() == 2)
	var res := layer.resolved(a)
	_check("migrated look resolves through the style",
		str(res["color"]) == "ff0000" and _near(float(res["energy"]), 2.0) \
		and _near(float(res["range"]), 8.0) and _near(float(res["fade_m"]), 50.0))
	_check("spot keeps its cone", _near(float(layer.resolved(layer.find_light("c"))["spot_angle"]), 30.0))
	var rt := PlacedLightLayer.create_empty()
	rt.deserialize(layer.serialize())
	_check("v3 round trip is not a migration", rt.migrated_from == 0 and rt.lights.size() == 3 \
		and rt.styles.size() == 2)


func _test_paths() -> void:
	_check("built-in maps keep their v2 path (so they read their old file)",
		PlacedLightLayer.path_for_key("scene_soak_festival_2026") \
		== PlacedLightLayer.legacy_path_for_scene("res://scenes/maps/soak_festival_2026.tscn"))
	_check("a site key is per lat/lon", PlacedLightLayer.path_for_key("47p1_n122p2").ends_with("placed_lights_47p1_n122p2.json"))


func _test_styles() -> void:
	var layer := PlacedLightLayer.create_empty()
	var sid := layer.add_style("Warm floods", "spot", {"color": "ffaa66", "energy": 3.0})
	var a := layer.add_light("spot", Vector3.ZERO, Vector3.ZERO, sid)
	var b := layer.add_light("spot", Vector3.ONE, Vector3.ZERO, sid)
	layer.set_field(a, "energy", 6.0, true)
	_check("a STYLE edit restyles every user", _near(float(layer.resolved(layer.find_light(b))["energy"]), 6.0))
	layer.set_field(a, "color", "0000ff", false)
	_check("a LIGHT edit is an override on that light only",
		str(layer.resolved(layer.find_light(a))["color"]) == "0000ff" \
		and str(layer.resolved(layer.find_light(b))["color"]) == "ffaa66")
	layer.set_field(b, "range", 30.0, true)
	_check("overrides survive a later style edit",
		str(layer.resolved(layer.find_light(a))["color"]) == "0000ff" \
		and _near(float(layer.resolved(layer.find_light(a))["range"]), 30.0))
	layer.set_field(a, "spot_angle", 35.0, false)   # == the default the style resolves to
	_check("an override equal to the style is pruned",
		not (layer.find_light(a)["overrides"] as Dictionary).has("spot_angle"))
	_check("non-style keys are refused", not PlacedLightStyles.is_style_key("spot", "x") \
		and not PlacedLightStyles.is_style_key("omni", "spot_angle"))
	layer.revert_override(a, "color")
	_check("revert drops the override", str(layer.resolved(layer.find_light(a))["color"]) == "ffaa66")
	layer.set_field(a, "color", "00ff00", false)
	var new_sid := layer.make_unique(a)
	_check("make_unique detaches with the same look",
		str(layer.find_light(a)["style_id"]) == new_sid \
		and str(layer.resolved(layer.find_light(a))["color"]) == "00ff00" \
		and (layer.find_light(a)["overrides"] as Dictionary).is_empty())
	layer.set_field(b, "color", "123456", false)
	layer.push_overrides_to_style(b)
	_check("push_overrides_to_style moves the override into the style",
		str(layer.styles[sid]["fields"]["color"]) == "123456" \
		and (layer.find_light(b)["overrides"] as Dictionary).is_empty())
	var before := layer.resolved(layer.find_light(b))
	layer.remove_style(sid)
	var after := layer.resolved(layer.find_light(b))
	_check("removing a style keeps its lights' look",
		str(before["color"]) == str(after["color"]) and _near(float(before["energy"]), float(after["energy"])) \
		and layer.styles.has(str(layer.find_light(b)["style_id"])))
	_check("kelvin: 1800 K is warm, 10000 K is cool",
		PlacedLightStyles.kelvin_to_color(1800.0).b < 0.4 \
		and PlacedLightStyles.kelvin_to_color(10000.0).b > 0.95)
	_check("6600 K is near white", PlacedLightStyles.kelvin_to_color(6600.0).r > 0.97 \
		and PlacedLightStyles.kelvin_to_color(6600.0).b > 0.9)
	var pf := PlacedLightStyles.preset_fields("fairy")
	_check("a string preset carries its conduit kind's spacing", _near(float(pf["bulb_spacing_m"]), 0.15) \
		and PlacedLightStyles.conduit_kind_for("fairy") == "led_fairy")


func _test_groups_and_copies() -> void:
	var layer := PlacedLightLayer.create_empty()
	var sid := layer.ensure_default_style("omni")
	_check("ensure_default_style is idempotent", layer.ensure_default_style("omni") == sid)
	var a := layer.add_light("omni", Vector3(0, 1, 0), Vector3.ZERO, sid)
	var b := layer.add_light("omni", Vector3(2, 1, 0), Vector3.ZERO, sid)
	var gid := layer.add_group("Stage", [a, b])
	_check("group membership", layer.group_members(gid).size() == 2)
	var c := layer.duplicate_light(a, Vector3(5, 0, 0))
	_check("a duplicate keeps style and groups", str(layer.find_light(c)["style_id"]) == sid \
		and gid in (layer.find_light(c)["group_ids"] as Array))
	_check("a duplicate is offset", _near(float(layer.find_light(c)["x"]), 5.0))
	layer.find_light(a)["graph_item_id"] = "item_7"
	var d := layer.duplicate_light(a, Vector3.ZERO)
	_check("a duplicate is never already a graph load", str(layer.find_light(d)["graph_item_id"]).is_empty())
	layer.groups[gid]["hidden"] = true
	_check("hidden-by-group", layer.is_hidden_by_group(layer.find_light(b)))
	layer.remove_group(gid)
	_check("removing a group keeps its lights", layer.lights.size() == 4 \
		and not gid in (layer.find_light(b)["group_ids"] as Array))
	var s := layer.add_string([Vector3(0, 3, 0), Vector3(10, 3, 0), Vector3(10, 3, 10)],
		layer.ensure_default_style("string"))
	var s2 := layer.duplicate_light(s, Vector3(0, 0, 4))
	var w := PlacedLightLayer.waypoints_of(layer.find_light(s2))
	_check("a string duplicate moves every pin", w.size() == 3 and _near(w[2].z, 14.0))
	layer.translate_light(s, Vector3(1, 0, 0))
	_check("translate moves a string's pins and anchor",
		_near(PlacedLightLayer.waypoints_of(layer.find_light(s))[1].x, 11.0) \
		and _near(float(layer.find_light(s)["x"]), 1.0))
	_check("a one-pin string is refused", layer.add_string([Vector3.ZERO], sid).is_empty())


func _test_string_geometry() -> void:
	var pts := [Vector3(0, 5, 0), Vector3(10, 5, 0), Vector3(20, 6, 0)]
	var fields := PlacedLightStyles.defaults("string")
	var geo := LightStringGeometry.build(pts, fields)
	var samples: PackedVector3Array = geo["samples"]
	var mid := samples[LightStringGeometry.SEGMENTS_PER_SPAN / 2]
	_check("the string sags below its chord mid-span", mid.y < 5.0 - 0.3, "mid y %.2f" % mid.y)
	_check("the string passes through its pins", samples[0].is_equal_approx(pts[0]) \
		and samples[samples.size() - 1].is_equal_approx(pts[2]))
	var length := float(geo["length_m"])
	var spacing := float(fields["bulb_spacing_m"])
	var bulbs: PackedVector3Array = geo["bulbs"]
	_check("bulb count ≈ length / spacing", absi(bulbs.size() - int(round(length / spacing))) <= 1,
		"%d bulbs over %.2f m" % [bulbs.size(), length])
	_check("the first bulb is half a spacing in", _near(bulbs[0].distance_to(samples[0]), spacing * 0.5, 0.05))
	var taut := fields.duplicate()
	taut["sag"] = 0.0
	var tgeo := LightStringGeometry.build(pts, taut)
	_check("sag 0 hangs straight", _near((tgeo["samples"] as PackedVector3Array)[6].y, 5.0))
	_check("ground clamp lifts a sag that would tunnel", (LightStringGeometry.build(
		[Vector3(0, 0.2, 0), Vector3(30, 0.2, 0)], fields,
		func(_p: Vector3) -> float: return 0.0)["samples"] as PackedVector3Array)[6].y >= 0.0)
	var idx := LightStringGeometry.light_indices(100, 4)
	_check("real lights spread evenly", idx.size() == 4 and idx[0] == 12 and idx[3] == 87)
	_check("real lights never exceed the bulbs", LightStringGeometry.light_indices(3, 16).size() == 3)
	var ns := LightStringGeometry.nearest_span(pts, samples, Vector3(15, 10, 0), Vector3.DOWN)
	_check("a ray onto the second span picks span 1", int(ns["span"]) == 1)


func _test_led_effects() -> void:
	var base := Color(1.0, 0.8, 0.5)
	var fx := {"effect": "rainbow_chase", "fx_speed": 4.0, "fx_span": 20.0, "fx_saturation": 1.0}
	var c0 := LedEffects.color_at(fx, 5, 50, 1.0, base)
	var c1 := LedEffects.color_at(fx, 6, 50, 1.25, base)
	_check("a rainbow chase moves one bulb per 1/speed s", c0.is_equal_approx(c1))
	_check("a rainbow repeats every span/speed s",
		c0.is_equal_approx(LedEffects.color_at(fx, 5, 50, 1.0 + 20.0 / 4.0, base)))
	var rev := fx.duplicate()
	rev["fx_direction"] = -1.0
	_check("reverse runs the other way", LedEffects.color_at(rev, 6, 50, 1.0, base) \
		.is_equal_approx(LedEffects.color_at(rev, 5, 50, 1.25, base)))
	var chase := {"effect": "chase", "fx_speed": 3.0, "fx_gap": 3.0}
	var lit := 0
	for i in 30:
		if LedEffects.color_at(chase, i, 30, 0.7, base).is_equal_approx(base):
			lit += 1
	_check("a theatre chase lights every gap-th bulb", lit == 10, "%d lit" % lit)
	var tw := {"effect": "twinkle", "fx_speed": 6.0}
	_check("twinkle is deterministic per bulb", LedEffects.color_at(tw, 7, 40, 2.3, base) \
		.is_equal_approx(LedEffects.color_at(tw, 7, 40, 2.3, base)))
	_check("twinkle bulbs differ from each other", not LedEffects.color_at(tw, 7, 40, 2.3, base) \
		.is_equal_approx(LedEffects.color_at(tw, 8, 40, 2.3, base)))
	var lo := INF
	var hi := -INF
	for k in 64:
		var b := LedEffects.color_at({"effect": "breathe", "fx_speed": 6.0}, 0, 1, float(k) * 0.05, base).r
		lo = minf(lo, b)
		hi = maxf(hi, b)
	_check("breathe swells between its floor and full", lo < 0.3 and hi > 0.9)
	var wipe := {"effect": "color_wipe", "fx_speed": 10.0}
	_check("a colour wipe paints bulbs behind its head",
		LedEffects.color_at(wipe, 2, 20, 0.5, base).is_equal_approx(LedEffects.color_at(wipe, 0, 20, 0.5, base)) \
		and not LedEffects.color_at(wipe, 8, 20, 0.5, base).is_equal_approx(LedEffects.color_at(wipe, 0, 20, 0.5, base)))
	_check("solid is the light's own colour", LedEffects.color_at({}, 3, 9, 4.0, base).is_equal_approx(base))
	var hmin := INF
	var hmax := -INF
	for k in 200:
		var h := LedEffects.hash11(float(k) * 0.37)
		hmin = minf(hmin, h)
		hmax = maxf(hmax, h)
	_check("hash11 stays in [0, 1)", hmin >= 0.0 and hmax < 1.0)


## The LEDs (GPU) and the real lights (CPU) must run the same function. The
## shader half lives in ONE include that both the bulb and the tube shaders
## pull in.
func _test_shader_mirror() -> void:
	var f := FileAccess.open("res://gameplay/led_effects.gdshaderinc", FileAccess.READ)
	_check("led_effects.gdshaderinc readable", f != null)
	if f == null:
		return
	var src := f.get_as_text()
	for pair in [["TWINKLE_FLOOR", LedEffects.TWINKLE_FLOOR], ["BREATHE_FLOOR", LedEffects.BREATHE_FLOOR],
			["CHASE_DIM", LedEffects.CHASE_DIM], ["WIPE_HUE_STEP", LedEffects.WIPE_HUE_STEP],
			["BREATHE_BULBS", LedEffects.BREATHE_BULBS], ["FLICKER_FLOOR", LedEffects.FLICKER_FLOOR],
			["STROBE_DUTY", LedEffects.STROBE_DUTY]]:
		var re := RegEx.create_from_string("const float %s = ([0-9.]+);" % pair[0])
		var m := re.search(src)
		_check("shader %s == LedEffects" % pair[0], m != null and _near(float(m.get_string(1)), float(pair[1]), 1e-6))
	_check("shader hash11 constants match", src.contains("p * 0.1031") and src.contains("p + 33.33"))
	var modes_ok := true
	for k in range(1, LedEffects.EFFECTS.size()):
		modes_ok = modes_ok and src.contains("fx_mode == %d" % k)
	_check("the include handles every LedEffects mode", modes_ok and LedEffects.EFFECTS[6] == "flicker" \
		and LedEffects.EFFECTS[7] == "strobe")
	for path in ["res://gameplay/led_bulb.gdshader", "res://gameplay/led_rope.gdshader"]:
		var g := FileAccess.open(path, FileAccess.READ)
		_check("%s includes the shared effect block" % path.get_file(), g != null \
			and g.get_as_text().contains('#include "res://gameplay/led_effects.gdshaderinc"'))


func _test_gizmo_math() -> void:
	var o := Vector3(1, 2, 3)
	var ax := Vector3(1, 0, 0)
	var s := LightGizmoMath.axis_param(Vector3(4.5, 10, 3), Vector3.DOWN, o, ax)
	_check("axis_param finds the grab point along the axis", _near(s, 3.5))
	_check("a ray parallel to the axis is not draggable", is_nan(LightGizmoMath.axis_param(
		Vector3.ZERO, Vector3.RIGHT, o, ax)))
	var hit: Variant = LightGizmoMath.ray_plane(Vector3(0, 5, 0), Vector3.DOWN, Vector3.ZERO, Vector3.UP)
	_check("ray_plane hits", hit is Vector3 and (hit as Vector3).is_equal_approx(Vector3.ZERO))
	var ang := LightGizmoMath.ring_angle(Vector3(0, 0, -1), Vector3.ZERO, Vector3.UP, Vector3(1, 0, 0))
	_check("ring_angle is signed about the normal", _near(absf(ang), PI / 2.0))
	var rot := LightGizmoMath.aim_rotation(Vector3.ZERO, Vector3(3, -4, -5))
	_check("aim_rotation points -Z at the target",
		LightGizmoMath.direction_of(rot).is_equal_approx(Vector3(3, -4, -5).normalized()))
	var r2 := LightGizmoMath.rotate_by(Vector3.ZERO, Vector3.UP, PI / 2.0, true)
	_check("rotate_by yaw 90° turns -Z to -X", LightGizmoMath.direction_of(r2).is_equal_approx(Vector3(-1, 0, 0)))
	var tilted := Vector3(-30.0, 45.0, 0.0)
	_check("rotation_of(basis_of(r)) round-trips", LightGizmoMath.basis_of(
		LightGizmoMath.rotation_of(LightGizmoMath.basis_of(tilted))).is_equal_approx(LightGizmoMath.basis_of(tilted)))
	_check("the pick radius has an angular floor", LightGizmoMath.pick_radius(0.3, 1000.0) > 10.0 \
		and _near(LightGizmoMath.pick_radius(0.3, 1.0), 0.3))
	var seg := LightGizmoMath.ray_segment(Vector3(0.5, 3, 0), Vector3.DOWN, Vector3.ZERO, Vector3(1, 0, 0))
	_check("ray_segment distance", _near(float(seg["dist"]), 0.0) and _near(float(seg["s"]), 0.5))


func _test_service() -> void:
	var main := Node3D.new()
	main.name = "SelftestLightsMain"
	root.add_child(main)
	var graph := Node.new()
	graph.name = "SystemGraphView"
	graph.set_script(_fake_graph_script())
	main.add_child(graph)
	var path := PlacedLightLayer.path_for_key(PlacedLightService.map_key(main))
	var had := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	var layer := PlacedLightService.get_layer(main)
	layer.lights.clear()
	layer.styles.clear()
	layer.groups.clear()
	PlacedLightService.rebuild_all(main)

	PlacedLightService.checkpoint(main)
	var id := PlacedLightService.add_point_light(main, "spot", Vector3(0, 3, 0), Vector3(-90, 0, 0))
	PlacedLightService.commit(main)
	var node := PlacedLightRuntime.find_node(main, id) as PlacedLight
	_check("a placed spot builds its node", node != null and node.kind == "spot")
	_check("the node sits at the record's WORLD position", node != null \
		and node.global_position.is_equal_approx(Vector3(0, 3, 0)))
	_check("the node faces the record's rotation (degrees)", node != null \
		and (node.global_basis * Vector3.FORWARD).is_equal_approx(Vector3.DOWN))
	PlacedLightService.checkpoint(main)
	PlacedLightService.set_field(main, [id], "energy", 7.0, true)
	PlacedLightService.commit(main)
	_check("a style edit reaches the node", node != null and _near(float(node.fields["energy"]), 7.0))
	PlacedLightService.undo(main)
	var n2 := PlacedLightRuntime.find_node(main, id) as PlacedLight
	_check("undo restores the previous value", n2 != null and _near(float(n2.fields["energy"]), 1.0))
	PlacedLightService.redo(main)
	_check("redo re-applies it", _near(float(layer.resolved(layer.find_light(id))["energy"]), 7.0))

	PlacedLightService.checkpoint(main)
	var sid := PlacedLightService.add_string(main, [Vector3(0, 3, 0), Vector3(8, 3, 0)])
	PlacedLightService.commit(main)
	var sn := PlacedLightRuntime.find_node(main, sid) as PlacedStringLight
	# This bare test "Main" has no clock; the string preset defaults to
	# dusk-to-dawn, so switch it to always-on for the power assertions.
	PlacedLightService.set_field(main, [sid], "schedule", "always", false)
	_check("a string builds bulbs and pins", sn != null and sn.bulb_count > 4 and sn.pin(1) != null)
	_check("a J string is NOT a power consumer", sn != null and not sn.is_in_group("power_consumers"))
	_check("a J string draws nothing until added to the graph", sn != null and sn.get_current_power() == 0.0)
	PlacedLightService.set_waypoint(main, sid, 1, Vector3(12, 3, 0))
	_check("moving a pin rebuilds the string", sn != null and sn.length_m > 11.0)
	var mid_hit := PlacedLightService.pick(main, Vector3(12, 10, 0), Vector3.DOWN)
	_check("a ray at a pin picks the pin", str(mid_hit["type"]) == "pin" and int(mid_hit["index"]) == 1)

	_check("Add to graph creates one load", PlacedLightService.add_to_graph(main, sid) \
		and graph.get("loads").size() == 1)
	PlacedLightService.add_to_graph(main, sid)
	_check("Add to graph is idempotent", graph.get("loads").size() == 1)
	_check("the load is billed from the measured length", float(layer.find_light(sid)["graph_watts"]) > 30.0)
	_check("a bound, lit string reports its watts", sn != null and sn.get_current_power() > 30.0)
	PlacedLightService.checkpoint(main)
	PlacedLightService.delete_ids(main, [sid])
	PlacedLightService.commit(main)
	_check("deleting the light removes its load", graph.get("loads").size() == 0)
	_check("deleting the light removes its node", PlacedLightRuntime.find_node(main, sid) == null)

	# Leave the player's file exactly as found.
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(backup)
		f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	main.queue_free()


func _fake_graph_script() -> GDScript:
	var s := GDScript.new()
	s.source_code = """extends Node
var loads := {}
func add_placed_light_load(light_id, _kind, _label, _watts, _pos):
	if not loads.has(light_id):
		loads[light_id] = "item_%d" % loads.size()
	return loads[light_id]
func remove_placed_light_load(light_id):
	loads.erase(light_id)
"""
	s.reload()
	return s

## The Ctrl/Alt gate that shows IK spheres and crosshair highlights reads the
## latest INPUT EVENT, so a modifier whose release was lost (Alt+Tab) heals on
## the next mouse motion instead of leaving every highlight on.
func _test_modifiers_and_bulbs() -> void:
	ModifierKeys.reset()
	var down := InputEventKey.new()
	down.keycode = KEY_ALT
	down.pressed = true
	down.alt_pressed = true
	ModifierKeys.observe(down)
	_check("Alt down selects", ModifierKeys.selecting())
	var mm := InputEventMouseMotion.new()   # the release never arrived; the mouse moves
	ModifierKeys.observe(mm)
	_check("a mouse motion without the flag heals a stuck Alt", not ModifierKeys.selecting())
	var ctrl_mm := InputEventMouseMotion.new()
	ctrl_mm.ctrl_pressed = true
	ModifierKeys.observe(ctrl_mm)
	_check("Ctrl held while moving still selects", ModifierKeys.ctrl() and ModifierKeys.selecting())
	ModifierKeys.reset()
	_check("focus loss resets the modifiers", not ModifierKeys.selecting())
	_check("show bulb: off for omni/spot, on for strings",
		not bool(PlacedLightStyles.defaults("omni")["show_body"]) 		and not bool(PlacedLightStyles.defaults("spot")["show_body"]) 		and bool(PlacedLightStyles.defaults("string")["show_body"]))

	var main := Node3D.new()
	main.name = "SelftestLightsMain2"
	root.add_child(main)
	var path := PlacedLightLayer.path_for_key(PlacedLightService.map_key(main))
	var had := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	var layer := PlacedLightService.get_layer(main)
	layer.lights.clear()
	layer.styles.clear()
	PlacedLightService.rebuild_all(main)
	PlacedLightService.set_studio_open(false)
	var id := PlacedLightService.add_point_light(main, "omni", Vector3(0, 2, 0), Vector3.ZERO)
	var node := PlacedLightRuntime.find_node(main, id) as PlacedLight
	node._process(0.0)
	var giz := node.get_node_or_null("LightGizmo") as Node3D
	var bulb := node.get_node_or_null("Bulb") as Node3D
	_check("J closed, no modifier: the IK sphere is hidden", giz != null and not giz.visible)
	_check("by default an omni shows no bulb — only its light", bulb != null and not bulb.visible)
	PlacedLightService.set_field(main, [id], "show_body", true, false)
	_check("Show bulb draws the lamp", bulb != null and bulb.visible)
	var sid := PlacedLightService.add_string(main, [Vector3(0, 3, 0), Vector3(6, 3, 0)])
	var sn := PlacedLightRuntime.find_node(main, sid) as PlacedStringLight
	var bulbs := sn.get_node_or_null("Bulbs") as Node3D
	_check("a string shows its bulbs by default", bulbs != null and bulbs.visible)
	PlacedLightService.set_field(main, [sid], "show_body", false, false)
	_check("Show bulb off hides a string's bulbs", bulbs != null and not bulbs.visible)
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(backup)
		f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	main.queue_free()


## Festival fixtures: presets are real style data, the new effects behave, the
## mover geometry is the scene hierarchy, tubes carry arc length, gobos.
func _test_festival_fixtures() -> void:
	# Every preset only sets keys its kind has (a typo would be silently ignored).
	var bad: Array = []
	for kind in PlacedLightStyles.PRESET_ORDER.keys():
		for pid in PlacedLightStyles.PRESET_ORDER[kind]:
			var f := PlacedLightStyles.preset_fields(str(pid), str(kind))
			for k in f.keys():
				if not PlacedLightStyles.is_style_key(str(kind), str(k)):
					bad.append("%s/%s.%s" % [kind, pid, k])
	_check("every preset field is a style key of its kind", bad.is_empty(), str(bad))
	var mov_ok := true
	for pid in PlacedLightStyles.PRESET_ORDER["mover"]:
		var r := PlacedLightStyles.resolve("mover", PlacedLightStyles.preset_fields(str(pid), "mover"), {})
		mov_ok = mov_ok and str(r["fixture"]) in PlacedLightStyles.FIXTURES \
			and str(r["program"]) in MoverProgram.PROGRAMS
	_check("every mover preset names a real fixture and program", mov_ok)
	_check("movers default to a visible fixture; omni to just the light",
		bool(PlacedLightStyles.defaults("mover")["show_body"]) and not bool(PlacedLightStyles.defaults("omni")["show_body"]))

	# Strobe and flicker.
	var lit := 0
	for k in 1000:
		if LedEffects.color_at({"effect": "strobe", "fx_speed": 8.0}, 0, 1, float(k) * 0.00125 * 1.0,
				Color.WHITE).r > 0.5:
			lit += 1
	_check("strobe duty ≈ STROBE_DUTY", absi(lit - int(LedEffects.STROBE_DUTY * 1000.0)) <= 15, "%d / 1000 lit" % lit)
	var flo := INF
	var fhi := -INF
	for k in 300:
		var v := LedEffects.color_at({"effect": "flicker", "fx_speed": 6.0}, 3, 9, float(k) * 0.037, Color.WHITE).r
		flo = minf(flo, v)
		fhi = maxf(fhi, v)
	_check("flicker wavers above its floor", flo >= LedEffects.FLICKER_FLOOR - 1e-4 and fhi - flo > 0.2,
		"%.2f..%.2f" % [flo, fhi])

	# Mover geometry.
	_check("tilt 0 beams along the mount axis", MoverProgram.direction(0, 0).is_equal_approx(Vector3.UP))
	_check("tilt 90 at pan 0 beams to -Z", MoverProgram.direction(0, 90).is_equal_approx(Vector3(0, 0, -1)))
	var rt := true
	for pt in [Vector2(30, 40), Vector2(-120, 75), Vector2(170, 130), Vector2(0, 10)]:
		var back := MoverProgram.angles_for(MoverProgram.direction(pt.x, pt.y))
		rt = rt and MoverProgram.direction(back.x, back.y).is_equal_approx(MoverProgram.direction(pt.x, pt.y))
	_check("angles_for inverts direction", rt)
	var sweep := {"program": "pan_sweep", "prog_speed": 6.0, "pan_center": 10.0, "pan_range": 50.0,
		"tilt_center": 30.0}
	_check("a pan sweep repeats every 60/speed s",
		MoverProgram.angles(sweep, 1.3).is_equal_approx(MoverProgram.angles(sweep, 11.3)))
	var opp := sweep.duplicate()
	opp["phase_deg"] = 180.0
	_check("phase 180 mirrors the sweep",
		_near(MoverProgram.angles(sweep, 2.5).x - 10.0, -(MoverProgram.angles(opp, 2.5).x - 10.0)))
	_check("a static program holds its centre", MoverProgram.angles({"program": "static",
		"pan_center": 15.0, "tilt_center": 33.0}, 99.0).is_equal_approx(Vector2(15, 33)))
	var hung := LightGizmoMath.basis_of(MoverProgram.mount_rotation(Vector3.DOWN))
	_check("a fixture hung from a truss beams DOWN at tilt 0",
		(hung * MoverProgram.direction(0, 0)).is_equal_approx(Vector3.DOWN))
	var wall := MoverProgram.mount_rotation(Vector3(1, 0, 0))
	var wb := LightGizmoMath.basis_of(wall)
	_check("a wall fixture's mount axis is the wall normal", (wb * Vector3.UP).is_equal_approx(Vector3(1, 0, 0)))
	var aim := MoverProgram.aim_angles(Vector3.ZERO, Vector3.ZERO, Vector3(3, 4, -5))
	_check("aim_angles points the beam at the target",
		MoverProgram.direction(aim.x, aim.y).is_equal_approx(Vector3(3, 4, -5).normalized()))

	# Gobos.
	_check("gobo: the lens aperture is round", MoverGobo.alpha("dots", 0.95, 0.95) == 0.0)
	_check("gobo: the dots pattern has a centre dot", MoverGobo.alpha("dots", 0.0, 0.0) > 0.9 \
		and MoverGobo.alpha("dots", 0.3, 0.0) < 0.1)
	_check("gobo textures are made once and cached",
		MoverGobo.texture("star") != null and MoverGobo.texture("star") == MoverGobo.texture("star") \
		and MoverGobo.texture("none") == null)

	# Continuous tubes.
	var samples := PackedVector3Array([Vector3.ZERO, Vector3(3, 0, 0), Vector3(3, 0, 4)])
	var tube := LightStringGeometry.build_tube(samples, 0.007, 6)
	var uvs: PackedVector2Array = tube.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]
	var umax := 0.0
	for uv in uvs:
		umax = maxf(umax, uv.x)
	_check("a tube's UV.x is its arc length", _near(umax, 7.0, 1e-3))

	# Nodes: a mover aims where MoverProgram says; a tube preset draws a tube.
	var main := Node3D.new()
	main.name = "SelftestLightsMain3"
	root.add_child(main)
	var path := PlacedLightLayer.path_for_key(PlacedLightService.map_key(main))
	var had := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	var layer := PlacedLightService.get_layer(main)
	layer.lights.clear()
	layer.styles.clear()
	layer.groups.clear()
	PlacedLightService.rebuild_all(main)
	var mount := MoverProgram.mount_rotation(Vector3(0, 0, 1))
	var mid := PlacedLightService.add_point_light(main, "mover", Vector3(0, 1, 0), mount)
	PlacedLightService.set_field(main, [mid], "program", "static", false)
	PlacedLightService.set_field(main, [mid], "pan_center", 40.0, false)
	PlacedLightService.set_field(main, [mid], "tilt_center", 65.0, false)
	var mnode := PlacedLightRuntime.find_node(main, mid) as PlacedMoverLight
	if mnode != null:
		mnode._process(0.016)
	var want := LightGizmoMath.basis_of(mount) * MoverProgram.direction(40.0, 65.0)
	_check("the mover's head aims where MoverProgram.direction says",
		mnode != null and mnode.beam_direction().is_equal_approx(want.normalized()),
		"%s vs %s" % [str(mnode.beam_direction() if mnode != null else Vector3.ZERO), str(want)])
	PlacedLightService.set_field(main, [mid], "fixture", "laser", false)
	PlacedLightService.set_field(main, [mid], "laser_beams", 5.0, false)
	_check("a laser fixture grows its beams", mnode != null and mnode.find_children("Laser_*", "", true, false).size() == 5)
	var sid := PlacedLightService.add_string(main, [Vector3(0, 2, 0), Vector3(6, 2, 0)])
	PlacedLightService.style_for_preset(main, "string", "neon_flex")
	var fields := PlacedLightStyles.preset_fields("neon_flex", "string")
	for k in fields.keys():
		PlacedLightService.set_field(main, [sid], k, fields[k], false)
	var snode := PlacedLightRuntime.find_node(main, sid) as PlacedStringLight
	var rope := snode.get_node_or_null("Rope") as MeshInstance3D if snode != null else null
	var bulbs := snode.get_node_or_null("Bulbs") as Node3D if snode != null else null
	_check("a neon-flex preset draws a glowing tube, not bulbs",
		snode != null and snode.is_continuous() and rope != null and rope.visible \
		and (bulbs == null or not bulbs.visible))
	_check("its pixels follow LEDs/m (60/m on 6 m)", snode != null and absi(snode.bulb_count - 360) <= 2,
		str(snode.bulb_count if snode != null else -1))
	var w := PlacedLightService.estimate_watts(main, layer.find_light(sid), layer.resolved(layer.find_light(sid)))
	_check("a tube bills its preset's W/m", _near(w, 9.6 * 6.0, 0.6), "%.1f W" % w)
	var preset_sid := PlacedLightService.style_for_preset(main, "mover", "skytracker")
	_check("a preset becomes ONE reusable style on the map",
		preset_sid == PlacedLightService.style_for_preset(main, "mover", "skytracker") \
		and str(layer.styles[preset_sid]["name"]) == "Sky tracker (searchlight)")
	if had:
		var fw := FileAccess.open(path, FileAccess.WRITE)
		fw.store_buffer(backup)
		fw.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	main.queue_free()


## Ctrl+drag moves a WHOLE string; Shift+drag duplicates; copies are grouped
## with their source and share its style; Esc takes the copy back.
func _test_drag_rules() -> void:
	var main := Node3D.new()
	main.name = "SelftestLightsMain4"
	root.add_child(main)
	var path := PlacedLightLayer.path_for_key(PlacedLightService.map_key(main))
	var had := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	var layer := PlacedLightService.get_layer(main)
	layer.lights.clear()
	layer.styles.clear()
	layer.groups.clear()
	PlacedLightService.rebuild_all(main)
	var sid := PlacedLightService.add_string(main, [Vector3(0, 2, 0), Vector3(4, 3, 0), Vector3(8, 2, 1)])
	var before := PlacedLightLayer.waypoints_of(layer.find_light(sid))
	var got := PlacedLightService.begin_drag(main, sid, false)
	PlacedLightService.drag_to(main, Vector3(1, 0, 2))
	PlacedLightService.drag_to(main, Vector3(2, 0.5, 3))
	PlacedLightService.end_drag(main)
	var after := PlacedLightLayer.waypoints_of(layer.find_light(sid))
	var same := got == sid and after.size() == before.size()
	for i in after.size():
		same = same and (after[i] - before[i]).is_equal_approx(Vector3(2, 0.5, 3))
	_check("a whole-string drag moves every pin by the same offset", same)
	var copy := PlacedLightService.begin_drag(main, sid, true)
	PlacedLightService.drag_to(main, Vector3(0, 0, 5))
	PlacedLightService.end_drag(main)
	var src_rec := layer.find_light(sid)
	var cp_rec := layer.find_light(copy)
	_check("a duplicate-drag makes a copy and leaves the source", not copy.is_empty() and copy != sid \
		and PlacedLightLayer.waypoints_of(src_rec)[0].is_equal_approx(after[0]) \
		and PlacedLightLayer.waypoints_of(cp_rec)[0].is_equal_approx(after[0] + Vector3(0, 0, 5)))
	var shared_group := false
	for g in src_rec["group_ids"]:
		if g in cp_rec["group_ids"]:
			shared_group = true
	_check("copies join the source's group and share its style",
		shared_group and str(src_rec["style_id"]) == str(cp_rec["style_id"]))
	var n_before := layer.lights.size()
	var c2 := PlacedLightService.begin_drag(main, sid, true)
	PlacedLightService.drag_to(main, Vector3(9, 0, 0))
	PlacedLightService.cancel_drag(main)
	_check("cancelling a duplicate-drag removes the copy", not c2.is_empty() and layer.lights.size() == n_before \
		and layer.find_light(c2).is_empty() and PlacedLightRuntime.find_node(main, c2) == null)
	PlacedLightClock.set_time(5.0)
	_check("the shared effect clock is one clock", _near(PlacedLightClock.now(main, false), 5.0))
	if had:
		var fw := FileAccess.open(path, FileAccess.WRITE)
		fw.store_buffer(backup)
		fw.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	main.queue_free()

extends SceneTree

## Headless tests for OSM water ring assembly + river buffering.
## Run: godot --headless --path . --script core/terrain/osm_water_selftest.gd

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_ring_assembly()
	_test_river_buffer()
	_test_waterway_dedupe()
	_test_flat_water_level()
	_test_reflection_probes()
	if _failures == 0:
		print("OSM WATER SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("OSM WATER SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_ring_assembly() -> void:
	var nodes := {
		1: Vector2(-116.0, 33.0),
		2: Vector2(-115.9, 33.0),
		3: Vector2(-115.9, 33.1),
		4: Vector2(-116.0, 33.1),
	}
	var ways := {
		10: {"nodes": [1, 2]},
		11: {"nodes": [2, 3]},
		12: {"nodes": [3, 4]},
		13: {"nodes": [4, 1]},
	}
	var ring := OsmWaterParser._assemble_ring([10, 11, 12, 13], ways, nodes, 33.05, -115.95)
	_check("ring closes", ring.size() >= 4)
	_check("ring area > 0", OsmWaterParser._polygon_area(ring) > 1000.0,
		"area=%.0f" % OsmWaterParser._polygon_area(ring))


func _test_river_buffer() -> void:
	var line := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(200, 0)])
	var ribbon := OsmWaterParser._buffer_polyline(line, 10.0)
	_check("river ribbon verts", ribbon.size() >= 6, "got %d" % ribbon.size())
	_check("river ribbon area", OsmWaterParser._polygon_area(ribbon) > 3500.0,
		"area=%.0f" % OsmWaterParser._polygon_area(ribbon))


func _test_waterway_dedupe() -> void:
	var lake := PackedVector2Array([
		Vector2(-30, -20), Vector2(230, -20), Vector2(230, 20), Vector2(-30, 20)])
	var existing: Array = [{"points": lake, "kind": "riverbank", "tags": {}}]
	var centerline := PackedVector2Array([Vector2(0, 0), Vector2(100, 0), Vector2(200, 0)])
	_check("centerline inside lake is covered",
		OsmWaterParser._centerline_covered_by_water(centerline, existing))
	var outside := PackedVector2Array([Vector2(0, 80), Vector2(100, 80), Vector2(200, 80)])
	_check("offset centerline not covered",
		not OsmWaterParser._centerline_covered_by_water(outside, existing))


func _test_flat_water_level() -> void:
	# Low percentile sits near the basin floor, ignoring high banks.
	var banks := PackedFloat32Array([10.0, 11.0, 12.0, 40.0, 10.5])
	var level: float = WaterBuilder._water_level(banks)
	_check("water level near basin floor", level <= 11.0, "level=%.2f" % level)
	_check("water level not below lowest bank", level >= 10.0, "level=%.2f" % level)
	# A single abnormally low DEM dip should not drag the level down to it.
	var dip := PackedFloat32Array([10.0, 10.0, 10.0, 10.0, -50.0])
	var level2: float = WaterBuilder._water_level(dip)
	_check("water level robust to single dip", level2 >= 9.0, "level=%.2f" % level2)

	# Two bodies must triangulate against their own vertices (no cross-body indices).
	var elev := PackedFloat32Array()
	elev.resize(4)
	elev.fill(5.0)
	var a := PackedVector2Array([Vector2(-50, -50), Vector2(-10, -50), Vector2(-10, -10), Vector2(-50, -10)])
	var b := PackedVector2Array([Vector2(10, 10), Vector2(50, 10), Vector2(50, 50), Vector2(10, 50)])
	var node := WaterBuilder.build_water_node(
		[{"points": a}, {"points": b}], elev, 2, 400.0, 5.0)
	_check("two water bodies build a node", node != null)
	if node != null:
		var mi := node.get_child(0)
		var mesh: ArrayMesh = mi.mesh
		_check("water mesh has one surface", mesh.get_surface_count() == 1)
		var arrays := mesh.surface_get_arrays(0)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		_check("two quads = 8 verts", verts.size() == 8, "got %d" % verts.size())
		var flat := true
		var y0 := verts[0].y
		for v in verts:
			if absf(v.y - y0) > 0.001:
				flat = false
		_check("water surface is flat", flat)
		node.free()


func _test_reflection_probes() -> void:
	var elev := PackedFloat32Array()
	elev.resize(4)
	elev.fill(5.0)
	var lake := PackedVector2Array([
		Vector2(-40, -30), Vector2(40, -30), Vector2(40, 30), Vector2(-40, 30)])
	var river := PackedVector2Array([
		Vector2(-100, -5), Vector2(100, -5), Vector2(100, 5), Vector2(-100, 5)])
	var node := WaterBuilder.build_water_node(
		[
			{"points": lake, "kind": "lake"},
			{"points": river, "kind": "river"},
		], elev, 2, 400.0, 5.0)
	_check("water with lake builds", node != null)
	if node == null:
		return
	var probes := node.get_node_or_null("WaterProbes")
	_check("lake gets a reflection probe container", probes != null)
	if probes != null:
		_check("one probe for lake not river", probes.get_child_count() == 1)
		var probe := probes.get_child(0)
		_check("probe is ReflectionProbe", probe is ReflectionProbe)
		if probe is ReflectionProbe:
			var rp := probe as ReflectionProbe
			_check("probe uses box projection", rp.box_projection)
			_check("probe captures once", rp.update_mode == ReflectionProbe.UPDATE_ONCE)
	WaterBuilder.refresh_reflection_probes(node)
	node.free()
	_check("river ribbon skipped", not WaterBuilder._wants_reflection_probe(
		river, "river"))
	_check("small puddle skipped", not WaterBuilder._wants_reflection_probe(
		PackedVector2Array([Vector2(0, 0), Vector2(5, 0), Vector2(5, 5)]), "lake"))

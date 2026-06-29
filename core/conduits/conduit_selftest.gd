extends SceneTree

## Offline self-test for ConduitKinds, GraphModel v4 migration, and ConduitMeshBuilder.
## Run: godot --headless --path . --script core/conduits/conduit_selftest.gd

var _failures: int = 0
var _checks: int = 0


func _initialize() -> void:
	_test_conduit_kinds()
	_test_graph_migration()
	_test_mesh_builder()
	_test_determinism()
	if _failures == 0:
		print("CONDUIT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CONDUIT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_conduit_kinds() -> void:
	_check("has extension_cord", ConduitKinds.has_type("extension_cord"))
	_check("has garden_hose", ConduitKinds.has_type("garden_hose"))
	var ac_conn := {"polarity": "ac", "resource_type": "", "conduit_type": ""}
	_check("ac -> extension_cord", ConduitKinds.derive_type_for_connection(ac_conn) == "extension_cord")
	var water_conn := {"polarity": "resource", "resource_type": "water", "conduit_type": ""}
	_check("water -> garden_hose", ConduitKinds.derive_type_for_connection(water_conn) == "garden_hose")
	var override := {"polarity": "ac", "conduit_type": "ducting"}
	_check("override ducting", ConduitKinds.derive_type_for_connection(override) == "ducting")
	var pts := PackedVector3Array([Vector3.ZERO, Vector3(3, 0, 0), Vector3(3, 4, 0)])
	_check("polyline length", absf(ConduitKinds.polyline_length_m(pts) - 7.0) < 0.001,
		"got %.3f" % ConduitKinds.polyline_length_m(pts))
	var wp := ConduitKinds.waypoint_dict(Vector3(1, 2, 3), "/Main/Terrain")
	_check("waypoint dict", absf(float(wp["y"]) - 2.0) < 0.001)


func _test_graph_migration() -> void:
	var model := GraphModel.new()
	var conn := {
		"id": "conn_test",
		"polarity": "ac",
		"source_item_id": "a",
		"target_item_id": "b",
	}
	model.connections.append(conn)
	model.call("_migrate_connection", conn)
	_check("route_3d migrated", conn.has("route_3d") and (conn["route_3d"] as Array).is_empty())
	_check("conduit_type migrated", conn.has("conduit_type"))
	_check("route_length_m migrated", conn.has("route_length_m"))
	var ser := model.serialize()
	_check("serialize v4", int(ser.get("version", 0)) == 4)
	model.add_item({"id": "a", "type": "panel", "specs": {"scene_device_path": "/Main/Sun"}})
	model.add_item({"id": "b", "type": "panel", "specs": {"scene_device_path": "/Main/Moon"}})
	model.add_connection({
		"id": "c1",
		"source_item_id": "a",
		"target_item_id": "b",
		"polarity": "ac",
	})
	var c := model.get_connection("c1")
	_check("routable both linked", model.connection_is_3d_routable(c))
	model.update_item("b", {"specs": {}})
	c = model.get_connection("c1")
	_check("not routable missing path", not model.connection_is_3d_routable(c))


func _test_mesh_builder() -> void:
	var control: Array = [Vector3(0, 5, 0), Vector3(10, 5, 0)]
	var built: Dictionary = ConduitMeshBuilder.build(control, "extension_cord", 8)
	var mesh: ArrayMesh = built.get("mesh", null)
	_check("mesh created", mesh != null and mesh.get_surface_count() > 0)
	var arc: float = float(built.get("arc_length_m", 0.0))
	_check("arc length > 10m (sag)", arc > 10.0, "arc=%.3f" % arc)
	var rigid: Dictionary = ConduitMeshBuilder.build(control, "pvc_pipe", 4)
	var rigid_arc: float = float(rigid.get("arc_length_m", 0.0))
	_check("rigid ~10m", absf(rigid_arc - 10.0) < 0.05, "arc=%.3f" % rigid_arc)
	var samples: PackedVector3Array = ConduitMeshBuilder.sample_path(
		control, ConduitKinds.type_meta("extension_cord"), 6)
	_check("samples count", samples.size() >= 7, "n=%d" % samples.size())


func _test_determinism() -> void:
	var control: Array = [Vector3(1, 2, 3), Vector3(4, 2, 8), Vector3(4, 6, 8)]
	var a: Dictionary = ConduitMeshBuilder.build(control, "garden_hose", 10)
	var b: Dictionary = ConduitMeshBuilder.build(control, "garden_hose", 10)
	_check("deterministic arc", absf(float(a["arc_length_m"]) - float(b["arc_length_m"])) < 1e-6)

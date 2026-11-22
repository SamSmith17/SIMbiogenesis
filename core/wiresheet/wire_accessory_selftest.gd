extends SceneTree

## Accessory props (offline). Each kind is a small mesh wound the way the
## battery parts are, its studs are where a conduit leaves, and a placed
## record is found by the graph item it embodies.
##
##   Godot --headless --path . --script core/wiresheet/wire_accessory_selftest.gd

const EXPECTED_CHECKS := 11

var _n := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_n += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _initialize() -> void:
	print("wire accessory selftest")
	_test_mesh()
	_test_place()
	_ok(_n == EXPECTED_CHECKS, "ran %d checks (expected %d)" % [_n, EXPECTED_CHECKS])
	print("wire accessory selftest: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _n, _fails])
	quit(0 if _fails == 0 else 1)


func _test_mesh() -> void:
	var empty: Array = []
	var wound: Array = []
	var nonfinite: Array = []
	for kind in ["fuse", "breaker", "switch", "busbar", "distributor", "shunt"]:
		var g := BattParts.Geo.new()
		WireAccessory.build(g, kind)
		if g.tri_count() < 4:
			empty.append(kind)
			continue
		for fin in g.surf:
			var sf: BattParts.Surf = g.surf[fin]
			for t in range(0, sf.v.size(), 3):
				var a := sf.v[t]
				var b := sf.v[t + 1]
				var c := sf.v[t + 2]
				if not (a.is_finite() and b.is_finite() and c.is_finite()):
					nonfinite.append(kind)
					break
				var nsum := sf.n[t] + sf.n[t + 1] + sf.n[t + 2]
				if (b - a).cross(c - a).dot(nsum) > 1e-12:
					wound.append(kind)
					break
	_ok(empty.is_empty(), "every accessory draws a mesh %s" % str(empty))
	_ok(nonfinite.is_empty(), "no accessory has a non-finite vertex %s" % str(nonfinite))
	_ok(wound.is_empty(), "every triangle is clockwise from its normal's side %s" % str(wound))
	var xf := Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(2, 0.5, -1))
	var tip := xf * Vector3(-0.055, 0.016, 0)
	_ok(WireAccessory.terminal_m("fuse", "input", xf).distance_to(tip) < 1e-5,
		"a fuse's input stud follows the prop")
	var node := WireAccessory.build_node({"accessory_kind": "breaker"})
	var mesh_ok := node.get_child_count() == 1 and node.get_child(0) is MeshInstance3D \
		and (node.get_child(0) as MeshInstance3D).mesh != null
	node.free()
	_ok(mesh_ok, "the prop is a mesh under one root")


func _test_place() -> void:
	var fuse := {"type": "breaker", "specs": {"fuse": true, "name": "Fuse 50 A"}}
	_ok(WireAccessory.kind_of_item(fuse) == "fuse", "a fuse-flagged breaker is a fuse")
	_ok(ModelCatalog.default_twin_model_id(fuse) == WireAccessory.MODEL_ID,
		"a fuse with no model of its own is the accessory prop")
	var dims := ModelCatalog.twin_box_spec_for_item(fuse)
	_ok(float(dims.get("h_m", 1.0)) < 0.05 and str(dims.get("accessory_kind", "")) == "fuse",
		"the fuse stays a fuse, not a metre-tall box (h %.3f)" % float(dims.get("h_m", -1)))
	var kept := {"type": "breaker", "specs": {"fuse": true, "model_id": ModelCatalog.GENERIC_BOX_ID}}
	_ok(ModelCatalog.default_twin_model_id(kept) == ModelCatalog.GENERIC_BOX_ID,
		"an explicit model id is left as it is")
	var ports := ConnectionPortDefs.default_ports_for_model(WireAccessory.MODEL_ID, dims)
	var input := _port(ports, "input")
	var dist := ConnectionPortDefs.default_ports_for_model(
		WireAccessory.MODEL_ID, WireAccessory.box_spec("distributor"))
	_ok(not input.is_empty() and absf(float(input.get("x", 0.0)) + 0.055) < 1e-4
		and not _port(dist, "input1").is_empty() and not _port(dist, "output").is_empty(),
		"ports sit on the studs a conduit leaves from")
	var rec := WireAccessory.prop_for([
		{"id": "p1", "graph_item_id": "brk"},
		{"id": "p2", "graph_item_id": "other"},
	], "brk")
	_ok(str(rec.get("id", "")) == "p1" and WireAccessory.prop_for([rec], "missing").is_empty(),
		"the prop for a graph item is the record that names it")


func _port(ports: Array, id: String) -> Dictionary:
	for p in ports:
		if str((p as Dictionary).get("id", "")) == id:
			return p
	return {}

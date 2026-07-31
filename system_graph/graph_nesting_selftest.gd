extends SceneTree

## Offline, deterministic self-test for the nested super-node architecture:
## portal resolution across levels, flattened-connection reconstruction, walk
## recursion, cascade delete, v5->v6 boundary_links migration, exposed-port
## maintenance, and nesting-aware PV Voc faulting. Run --import first so the
## GraphNesting / GraphModel class_names register.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _checks := 0


func _initialize() -> void:
	var fails := 0
	fails += _test_resolve_multilevel()
	fails += _test_flat_connections_tunnel()
	fails += _test_walk_items_recursion()
	fails += _test_walk_prunes_opaque()
	fails += _test_cascade_delete()
	fails += _test_migration_boundary_links()
	fails += _test_reconcile_on_child_delete()
	fails += _test_pv_fault_across_boundary()
	fails += _test_flat_mass_path()
	fails += _test_port_face_layout()
	if fails == 0:
		print("GRAPH NESTING SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("GRAPH NESTING SELFTEST FAIL  (%d of %d checks failed)" % [fails, _checks])
	quit()


## Promoted-port faces: default flow is inputs-top / outputs-bottom; pinning a
## port to a side edge moves its handle there, same-face ports spread evenly,
## and unknown faces are refused. Pure layout math over one synthetic compound.
func _test_port_face_layout() -> int:
	var fails := 0
	var comp := {
		"id": "box", "type": "compound", "specs": {"exposed_ports": [
			{"handle_id": "in_ac_1", "direction": "in"},
			{"handle_id": "in_ac_2", "direction": "in"},
			{"handle_id": "out_dc_1", "direction": "out"},
			{"handle_id": "out_dc_2", "direction": "out", "face": "right"},
		]},
		"handles": [
			{"id": "in_ac_1", "direction": "in", "rx": 0.5, "ry": 0.0},
			{"id": "in_ac_2", "direction": "in", "rx": 0.5, "ry": 0.0},
			{"id": "out_dc_1", "direction": "out", "rx": 0.5, "ry": 1.0},
			{"id": "out_dc_2", "direction": "out", "rx": 0.5, "ry": 1.0},
			{"id": "legacy_static", "rx": 0.13, "ry": 0.37},
		],
	}
	var out := GraphNesting.layout_exposed_handles(comp)
	var by_id: Dictionary = {}
	for h_v in out:
		by_id[str((h_v as Dictionary).get("id", ""))] = h_v
	# Two inputs share the top edge, spread evenly.
	var a: Dictionary = by_id["in_ac_1"]
	var b: Dictionary = by_id["in_ac_2"]
	fails += _check(absf(float(a.get("ry", -1.0))) < 0.001
		and absf(float(b.get("ry", -1.0))) < 0.001, "inputs stay on the top edge")
	fails += _check(absf(float(a.get("rx", 0.0)) - 1.0 / 3.0) < 0.01
		and absf(float(b.get("rx", 0.0)) - 2.0 / 3.0) < 0.01,
		"same-face ports spread evenly along the edge")
	# out_dc_2 was pinned to the RIGHT face; out_dc_1 stays bottom (alone → centered).
	var p: Dictionary = by_id["out_dc_2"]
	fails += _check(absf(float(p.get("rx", 0.0)) - 1.0) < 0.001
		and absf(float(p.get("ry", 0.0)) - 0.5) < 0.01, "pinned port sits on the right edge")
	var q: Dictionary = by_id["out_dc_1"]
	fails += _check(absf(float(q.get("ry", 0.0)) - 1.0) < 0.001
		and absf(float(q.get("rx", 0.0)) - 0.5) < 0.01,
		"remaining bottom port re-centers alone")
	# Handles with no exposed_ports entry are untouched.
	var lg: Dictionary = by_id["legacy_static"]
	fails += _check(absf(float(lg.get("rx", 0.0)) - 0.13) < 0.001
		and absf(float(lg.get("ry", 0.0)) - 0.37) < 0.001,
		"legacy/static handles are left where they are")
	# Face default derives from direction; garbage faces fall back the same way.
	fails += _check(GraphNesting.face_for_port({"direction": "out"}) == "bottom"
		and GraphNesting.face_for_port({"direction": "in"}) == "top"
		and GraphNesting.face_for_port({"direction": "out", "face": "diagonal"}) == "bottom",
		"face defaults follow direction and reject unknown faces")
	return fails


func _check(cond: bool, label: String) -> int:
	_checks += 1
	if not cond:
		push_error("FAIL: " + label)
		print("  FAIL: " + label)
		return 1
	return 0


# ---------------------------------------------------------------------------
# Builders — construct a compound + exposed ports the way the view does.
# ---------------------------------------------------------------------------

func _add(model: GraphModel, id: String, type_id: String, scope := "root", specs := {}) -> void:
	model.add_item({
		"id": id, "type": type_id, "x": 0.0, "y": 0.0,
		"width": 120.0, "height": 100.0, "scope_id": scope, "specs": specs,
	})


## Group `child_ids` (already in `parent_scope`) into a generic super-node
## `comp_id` with child scope `scope_<comp_id>`. `exposures` = array of
## {handle_id, child_item_id, child_handle_id, direction, polarity, kind}.
func _make_compound(model: GraphModel, comp_id: String, parent_scope: String,
		child_ids: Array, exposures: Array) -> String:
	var child_scope := "scope_%s" % comp_id
	var handles: Array = []
	for ep_v in exposures:
		var ep := ep_v as Dictionary
		handles.append({
			"id": str(ep.get("handle_id", "")),
			"polarity": str(ep.get("polarity", "ac")),
			"direction": str(ep.get("direction", "in")),
			"rx": 0.0, "ry": 0.5,
		})
	model.add_item({
		"id": comp_id, "type": "compound", "x": 0.0, "y": 0.0,
		"width": 180.0, "height": 120.0, "scope_id": parent_scope,
		"child_scope_id": child_scope,
		"handles": handles,
		"specs": {"compound_kind": "", "exposed_ports": exposures.duplicate(true),
			"child_count": child_ids.size()},
	})
	model.ensure_scope(child_scope, parent_scope, comp_id, comp_id)
	for cid in child_ids:
		model.update_item(str(cid), {"scope_id": child_scope, "parent_compound_id": comp_id})
	return child_scope


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

func _test_resolve_multilevel() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	# leaf inside inner inside outer.
	_add(model, "leaf", "processor")
	_add(model, "outer", "compound")
	_add(model, "inner", "compound")
	# inner exposes handle "iq" -> leaf.input
	_make_compound(model, "inner", "scope_outer", ["leaf"], [
		{"handle_id": "iq", "child_item_id": "leaf", "child_handle_id": "input",
			"direction": "in", "polarity": "resource", "kind": "water"}])
	# outer exposes handle "op" -> inner.iq
	_make_compound(model, "outer", "root", ["inner"], [
		{"handle_id": "op", "child_item_id": "inner", "child_handle_id": "iq",
			"direction": "in", "polarity": "resource", "kind": "water"}])
	var res := GraphNesting.resolve_port(model, "outer", "op")
	f += _check(str(res["item_id"]) == "leaf" and str(res["handle_id"]) == "input",
		"resolve 2 levels -> leaf.input (got %s.%s)" % [res["item_id"], res["handle_id"]])
	# A plain node resolves to itself.
	var res2 := GraphNesting.resolve_port(model, "leaf", "input")
	f += _check(str(res2["item_id"]) == "leaf", "leaf resolves to self")
	return f


func _test_flat_connections_tunnel() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_add(model, "tank", "resource", "root", {"resource_kind": "water"})
	_add(model, "proc", "processor")
	_make_compound(model, "grp", "root", ["proc"], [
		{"handle_id": "in0", "child_item_id": "proc", "child_handle_id": "res_in_0",
			"direction": "in", "polarity": "resource", "kind": "water"}])
	# Real boundary wire: tank.output -> grp.in0
	model.add_connection({"id": "c1", "scope_id": "root", "polarity": "resource",
		"resource_type": "water",
		"source_item_id": "tank", "source_handle_id": "output",
		"target_item_id": "grp", "target_handle_id": "in0"})
	var flat := GraphNesting.flat_connections(model)
	var found := false
	for e_v in flat:
		var e := e_v as Dictionary
		if str(e.get("id", "")) == "c1":
			found = str(e.get("source_item_id", "")) == "tank" \
				and str(e.get("target_item_id", "")) == "proc" \
				and str(e.get("target_handle_id", "")) == "res_in_0"
	f += _check(found, "boundary wire flattens tank.output -> proc.res_in_0")
	# Origin id preserved (so flow writeback hits the real wire).
	var ids: Array = []
	for e_v in flat:
		ids.append(str((e_v as Dictionary).get("id", "")))
	f += _check(ids.has("c1"), "flat edge keeps origin conn id")
	return f


func _test_walk_items_recursion() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_add(model, "p1", "panel", "root", {"wmp": 400.0})
	_add(model, "grp", "compound")
	_add(model, "p2", "panel", "root", {"wmp": 400.0})  # will move into grp
	_make_compound(model, "grp", "root", ["p2"], [])
	# nested compound inside grp holding p3
	_add(model, "p3", "panel", "scope_grp", {"wmp": 400.0})
	_add(model, "sub", "compound", "scope_grp")
	_make_compound(model, "sub", "scope_grp", ["p3"], [])
	var walked := GraphNesting.walk_items(model, "root")
	var panels := 0
	for it_v in walked:
		if str((it_v as Dictionary).get("type", "")) == "panel":
			panels += 1
	f += _check(panels == 3, "walk_items finds all 3 nested panels (got %d)" % panels)
	return f


func _test_walk_prunes_opaque() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	# array compound (opaque) containing a hidden panel that must NOT be counted.
	_add(model, "arr", "compound", "root", {"compound_kind": "array",
		"array_equiv_wmp": 2400.0, "array_panel_units": 6})
	model.update_item("arr", {"child_scope_id": "scope_arr"})
	model.ensure_scope("scope_arr", "root", "arr", "arr")
	_add(model, "ghost_panel", "panel", "scope_arr", {"wmp": 999.0})
	var walked := GraphNesting.walk_items(model, "root")
	var saw_arr := false
	var saw_ghost := false
	for it_v in walked:
		var it := it_v as Dictionary
		if str(it.get("id", "")) == "arr":
			saw_arr = true
		if str(it.get("id", "")) == "ghost_panel":
			saw_ghost = true
	f += _check(saw_arr, "walk includes the opaque array compound")
	f += _check(not saw_ghost, "walk does NOT recurse into opaque array children")
	return f


func _test_cascade_delete() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_add(model, "a", "processor")
	_add(model, "b", "processor")
	_make_compound(model, "grp", "root", ["a", "b"], [])
	model.add_connection({"id": "cin", "scope_id": "scope_grp", "polarity": "resource",
		"source_item_id": "a", "source_handle_id": "output",
		"target_item_id": "b", "target_handle_id": "res_in_0"})
	model.remove_item("grp")
	f += _check(model.get_item("a").is_empty(), "cascade delete removed child a")
	f += _check(model.get_item("b").is_empty(), "cascade delete removed child b")
	f += _check(model.get_item("grp").is_empty(), "compound shell removed")
	f += _check(model.get_connection("cin").is_empty(), "interior connection removed")
	f += _check(model.get_scope("scope_grp").is_empty(), "child scope entry removed")
	return f


func _test_migration_boundary_links() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_add(model, "child", "processor")
	# Legacy compound with boundary_links, no exposed_ports.
	model.add_item({
		"id": "leg", "type": "compound", "x": 0, "y": 0, "width": 180, "height": 120,
		"scope_id": "root", "child_scope_id": "scope_leg",
		"specs": {"compound_kind": "", "boundary_links": [{
			"compound_handle_id": "out_ac_1", "polarity": "ac",
			"child_item_id": "child", "child_handle_id": "acOutput",
			"external_item_id": "x", "external_handle_id": "in",
			"source_was_child": true}]},
	})
	var saved := model.serialize()
	f += _check(int(saved.get("version", 0)) == 7, "serialize version is 7")
	var m2: GraphModel = GraphModelScript.new()
	m2.deserialize(saved)
	var leg := m2.get_item("leg")
	var eps: Array = (leg.get("specs", {}) as Dictionary).get("exposed_ports", []) as Array
	f += _check(eps.size() == 1, "boundary_links migrated to one exposed_port")
	if eps.size() == 1:
		var ep := eps[0] as Dictionary
		f += _check(str(ep.get("handle_id", "")) == "out_ac_1"
			and str(ep.get("child_item_id", "")) == "child"
			and str(ep.get("direction", "")) == "out",
			"migrated exposed_port fields correct")
	return f


func _test_reconcile_on_child_delete() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_add(model, "keep", "processor")
	_add(model, "drop", "processor")
	_make_compound(model, "grp", "root", ["keep", "drop"], [
		{"handle_id": "hk", "child_item_id": "keep", "child_handle_id": "output",
			"direction": "out", "polarity": "ac", "kind": ""},
		{"handle_id": "hd", "child_item_id": "drop", "child_handle_id": "output",
			"direction": "out", "polarity": "ac", "kind": ""}])
	model.remove_item("drop")
	var changed := GraphNesting.reconcile_exposed_ports(model, "grp")
	f += _check(changed, "reconcile reports a change after child delete")
	var eps: Array = (model.get_item("grp").get("specs", {}) as Dictionary).get("exposed_ports", []) as Array
	f += _check(eps.size() == 1 and str((eps[0] as Dictionary).get("handle_id", "")) == "hk",
		"dangling exposed_port pruned, live one kept")
	return f


func _test_pv_fault_across_boundary() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	# 4 panels @48V series inside a group -> controller (max 150V) outside.
	for i in 4:
		_add(model, "p%d" % i, "panel", "root",
			{"voc": 48.0, "vmp": 38.0, "wmp": 400.0, "imp": 10.0, "isc": 10.5})
	_add(model, "ctrl", "controller", "root", {"max_voc": 150.0})
	# Series-chain the panels (internal wires) and expose the string ends.
	for i in 3:
		model.add_connection({"scope_id": "scope_grp", "polarity": "positive",
			"source_item_id": "p%d" % i, "source_handle_id": "positive",
			"target_item_id": "p%d" % (i + 1), "target_handle_id": "negative"})
	_make_compound(model, "grp", "root", ["p0", "p1", "p2", "p3"], [
		{"handle_id": "pv+", "child_item_id": "p3", "child_handle_id": "positive",
			"direction": "out", "polarity": "positive", "kind": ""},
		{"handle_id": "pv-", "child_item_id": "p0", "child_handle_id": "negative",
			"direction": "out", "polarity": "negative", "kind": ""}])
	# Wire the group's promoted PV bus to the controller (parent scope).
	model.add_connection({"scope_id": "root", "polarity": "positive",
		"source_item_id": "grp", "source_handle_id": "pv+",
		"target_item_id": "ctrl", "target_handle_id": "pvPositive"})
	model.add_connection({"scope_id": "root", "polarity": "negative",
		"source_item_id": "grp", "source_handle_id": "pv-",
		"target_item_id": "ctrl", "target_handle_id": "pvNegative"})
	var faults := PvElectrical.find_overvoltage_faults_flat(model, 25.0)
	# 4 x 48 = 192 V > 150 V -> fault expected.
	f += _check(faults.size() == 1, "over-voltage fault detected across boundary (got %d)" % faults.size())
	if faults.size() == 1:
		f += _check(str((faults[0] as Dictionary).get("controller_id", "")) == "ctrl",
			"fault names the controller")
	return f


func _test_flat_mass_path() -> int:
	# Two-level tunnel: tank -> outer.op -> inner.iq -> proc.res_in_0
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_add(model, "tank", "resource", "root", {"resource_kind": "water"})
	_add(model, "proc", "processor")
	_make_compound(model, "inner", "scope_outer", ["proc"], [
		{"handle_id": "iq", "child_item_id": "proc", "child_handle_id": "res_in_0",
			"direction": "in", "polarity": "resource", "kind": "water"}])
	_make_compound(model, "outer", "root", ["inner"], [
		{"handle_id": "op", "child_item_id": "inner", "child_handle_id": "iq",
			"direction": "in", "polarity": "resource", "kind": "water"}])
	model.add_connection({"id": "cc", "scope_id": "root", "polarity": "resource",
		"resource_type": "water",
		"source_item_id": "tank", "source_handle_id": "output",
		"target_item_id": "outer", "target_handle_id": "op"})
	var flat := GraphNesting.flat_connections(model)
	var ok := false
	for e_v in flat:
		var e := e_v as Dictionary
		if str(e.get("id", "")) == "cc":
			ok = str(e.get("source_item_id", "")) == "tank" \
				and str(e.get("target_item_id", "")) == "proc"
	f += _check(ok, "two-level tunnel flattens tank -> proc")
	return f

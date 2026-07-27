extends SceneTree

## Offline, deterministic self-test for SketchUp-style graph COMPONENTS:
## definition realize (single + multi-level), capture round-trip, edit-one-
## instance-updates-all with per-instance battery SOC preserved, external-wire
## survival across a re-stamp, Make Unique detach, and v6->v7 definitions
## round-trip. Run --import first so GraphComponentDefs / GraphModel register.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")

var _checks := 0


func _initialize() -> void:
	var fails := 0
	fails += _test_realize_single_level()
	fails += _test_capture_roundtrip()
	fails += _test_multilevel_realize_starshade()
	fails += _test_starshade_no_overvoltage()
	fails += _test_edit_propagates_soc_preserved()
	fails += _test_external_wire_survives_restamp()
	fails += _test_make_unique_detaches()
	fails += _test_v6_to_v7_definitions()
	if fails == 0:
		print("GRAPH COMPONENTS SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("GRAPH COMPONENTS SELFTEST FAIL  (%d of %d checks failed)" % [fails, _checks])
	quit()


func _check(cond: bool, label: String) -> int:
	_checks += 1
	if not cond:
		push_error("FAIL: " + label)
		print("  FAIL: " + label)
		return 1
	return 0


func _register(model: GraphModel, def_id: String) -> void:
	var tree := ComponentPresets.builtin_component_tree(def_id)
	for did in tree.keys():
		model.put_definition(tree[did] as Dictionary)


func _kids(model: GraphModel, compound_id: String) -> Array:
	var it := model.get_item(compound_id)
	return model.get_items_in_scope(str(it.get("child_scope_id", "")))


func _count_type(model: GraphModel, type_id: String) -> int:
	var n := 0
	for it_v in GraphNesting.walk_items(model, "root"):
		if str((it_v as Dictionary).get("type", "")) == type_id:
			n += 1
	return n


# ---------------------------------------------------------------------------

func _test_realize_single_level() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "hybrid_inverter")
	var cid := GraphComponentDefs.realize(model, "hybrid_inverter", "root", Vector2(0, 0))
	f += _check(not cid.is_empty(), "realize returns a compound id")
	var inst := model.get_item(cid)
	f += _check(GraphComponentDefs.is_instance(inst), "compound is a bound instance")
	f += _check(str((inst.get("specs", {}) as Dictionary).get("definition_id", "")) == "hybrid_inverter",
		"instance carries definition_id")
	f += _check(_kids(model, cid).size() == 2, "hybrid inverter realized 2 children")
	var handles: Array = inst.get("handles", []) as Array
	f += _check(handles.size() == 5, "5 exposed handles present (got %d)" % handles.size())
	# def_local_id assigned to every child.
	var tagged := true
	for k_v in _kids(model, cid):
		if str((k_v as Dictionary).get("specs", {}).get("def_local_id", "")).is_empty():
			tagged = false
	f += _check(tagged, "each realized child tagged with def_local_id")
	return f


func _test_capture_roundtrip() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "solar_generator")
	var cid := GraphComponentDefs.realize(model, "solar_generator", "root", Vector2(0, 0))
	var rev0 := int(model.get_definition("solar_generator").get("rev", 0))
	var def_id := GraphComponentDefs.capture(model, cid)
	f += _check(def_id == "solar_generator", "capture returns the definition id")
	var rev1 := int(model.get_definition("solar_generator").get("rev", 0))
	f += _check(rev1 == rev0 + 1, "capture bumps rev (%d -> %d)" % [rev0, rev1])
	var sub: Dictionary = model.get_definition("solar_generator").get("subgraph", {}) as Dictionary
	f += _check((sub.get("items", []) as Array).size() == 3, "captured subgraph has 3 items")
	# Captured leaf specs are stripped of instance-only keys (soc).
	var soc_stripped := true
	for it_v in (sub.get("items", []) as Array):
		if (it_v as Dictionary).get("specs", {}).has("soc"):
			soc_stripped = false
	f += _check(soc_stripped, "capture strips instance-only 'soc' from definition")
	return f


func _test_multilevel_realize_starshade() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "starshade")
	var cid := GraphComponentDefs.realize(model, "starshade", "root", Vector2(0, 0))
	f += _check(not cid.is_empty(), "starshade realized")
	f += _check(_count_type(model, "panel") == 18, "18 PV panels across the tree (got %d)"
		% _count_type(model, "panel"))
	f += _check(_count_type(model, "battery") == 2, "2 batteries (got %d)" % _count_type(model, "battery"))
	# array + hybrid inverter (cc+inv=2 controllers) + bank -> 2 controllers total.
	f += _check(_count_type(model, "controller") == 2, "2 controller circuits (got %d)"
		% _count_type(model, "controller"))
	# Aggregate PV watts via nesting walk.
	var wmp := 0.0
	for it_v in GraphNesting.walk_items(model, "root"):
		var it := it_v as Dictionary
		if str(it.get("type", "")) == "panel":
			wmp += float((it.get("specs", {}) as Dictionary).get("wmp", 0.0))
	f += _check(abs(wmp - 18.0 * 220.0) < 0.5, "aggregate PV = 3960 W (got %.0f)" % wmp)
	# The top instance exposes sunlight_in + ac_out.
	var hids: Array = []
	for h_v in (model.get_item(cid).get("handles", []) as Array):
		hids.append(str((h_v as Dictionary).get("id", "")))
	f += _check(hids.has("sunlight_in") and hids.has("ac_out"),
		"top StarShade exposes sunlight_in + ac_out")
	# Nested instances exist (array/hybrid/bank are themselves definitions).
	var nested_instances := 0
	for it_v in GraphNesting.walk_items(model, "root"):
		if GraphComponentDefs.is_instance(it_v as Dictionary):
			nested_instances += 1
	f += _check(nested_instances >= 3, "array/inverter/bank are nested instances (got %d)" % nested_instances)
	return f


## The StarShade array is 3S×6P — six 3-panel strings in parallel — so the
## charge controller sees ~112.5 Voc, NOT 18×37.5 = 675 Voc. Regression guard for
## the "controller destroyed" over-voltage bug (parallel links must not series-sum).
func _test_starshade_no_overvoltage() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "starshade")
	GraphComponentDefs.realize(model, "starshade", "root", Vector2(0, 0))
	var faults := PvElectrical.find_overvoltage_faults_flat(model, 25.0)
	f += _check(faults.is_empty(), "no over-voltage fault on StarShade (got %d)" % faults.size())
	# Find the charge-controller and confirm its max branch Voc is one 3S string.
	var cc := ""
	for it_v in GraphNesting.walk_items(model, "root"):
		var it := it_v as Dictionary
		if str(it.get("type", "")) == "controller" \
				and str((it.get("specs", {}) as Dictionary).get("name", "")).contains("Charge"):
			cc = str(it.get("id", ""))
	f += _check(not cc.is_empty(), "found StarShade charge controller")
	if not cc.is_empty():
		var flat := GraphNesting.flat_connections(model)
		var vmax := 0.0
		for bv in PvElectrical.branch_vocs_for_controller_flat(model, cc, flat, 25.0):
			vmax = maxf(vmax, float(bv))
		f += _check(abs(vmax - 112.5) < 1.0, "max string Voc ~112.5 (3S) (got %.1f)" % vmax)
	return f


func _test_edit_propagates_soc_preserved() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "solar_generator")
	var a := GraphComponentDefs.realize(model, "solar_generator", "root", Vector2(0, 0))
	var b := GraphComponentDefs.realize(model, "solar_generator", "root", Vector2(400, 0))
	# Give instance B's battery a distinct SOC + a live output value.
	var b_bat := ""
	for k_v in _kids(model, b):
		if str((k_v as Dictionary).get("type", "")) == "battery":
			b_bat = str((k_v as Dictionary).get("id", ""))
	f += _check(not b_bat.is_empty(), "found instance B battery")
	var bs: Dictionary = (model.get_item(b_bat).get("specs", {}) as Dictionary).duplicate(true)
	bs["soc"] = 0.42
	model.update_item(b_bat, {"specs": bs})
	# Structural edit inside A: add a new appliance load child.
	var a_scope := str(model.get_item(a).get("child_scope_id", ""))
	var new_id := model.generate_item_id()
	model.add_item({"id": new_id, "type": "appliance", "x": 0, "y": 160,
		"width": 120, "height": 90, "scope_id": a_scope, "parent_compound_id": a,
		"specs": {"name": "Aux Load", "avg_watts": 40.0}})
	# Propagate: capture A -> restamp B.
	GraphComponentDefs.capture(model, a)
	GraphComponentDefs.restamp(model, b)
	# B gained the appliance...
	var b_has_appliance := false
	for k_v in _kids(model, b):
		if str((k_v as Dictionary).get("type", "")) == "appliance":
			b_has_appliance = true
	f += _check(b_has_appliance, "structural add propagated to sibling instance B")
	# ...and B's battery kept its per-instance SOC.
	var soc_kept := false
	for k_v in _kids(model, b):
		if str((k_v as Dictionary).get("type", "")) == "battery":
			soc_kept = abs(float((k_v as Dictionary).get("specs", {}).get("soc", -1.0)) - 0.42) < 0.001
	f += _check(soc_kept, "sibling B battery SOC (0.42) preserved across propagation")
	return f


func _test_external_wire_survives_restamp() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "hybrid_inverter")
	var cid := GraphComponentDefs.realize(model, "hybrid_inverter", "root", Vector2(0, 0))
	# External load wired to the instance's ac_out handle.
	model.add_item({"id": "ext_load", "type": "acload", "x": 300, "y": 0,
		"width": 120, "height": 90, "scope_id": "root", "specs": {"name": "House"}})
	model.add_connection({"id": "ext_w", "scope_id": "root", "polarity": "ac",
		"source_item_id": cid, "source_handle_id": "ac_out",
		"target_item_id": "ext_load", "target_handle_id": "input"})
	# Interior edit + propagate cycle (single instance: capture then restamp self).
	var a_scope := str(model.get_item(cid).get("child_scope_id", ""))
	var new_id := model.generate_item_id()
	model.add_item({"id": new_id, "type": "appliance", "x": 0, "y": 160,
		"width": 120, "height": 90, "scope_id": a_scope, "parent_compound_id": cid,
		"specs": {"name": "Fan", "avg_watts": 20.0}})
	GraphComponentDefs.capture(model, cid)
	GraphComponentDefs.restamp(model, cid)
	f += _check(not model.get_connection("ext_w").is_empty(),
		"external ac_out wire survives re-stamp")
	# ac_out handle still present on the instance.
	var has_ac := false
	for h_v in (model.get_item(cid).get("handles", []) as Array):
		if str((h_v as Dictionary).get("id", "")) == "ac_out":
			has_ac = true
	f += _check(has_ac, "ac_out handle still present after re-stamp")
	return f


func _test_make_unique_detaches() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "hybrid_inverter")
	var cid := GraphComponentDefs.realize(model, "hybrid_inverter", "root", Vector2(0, 0))
	var kids_before := _kids(model, cid).size()
	GraphComponentDefs.make_unique(model, cid)
	var inst := model.get_item(cid)
	f += _check(not GraphComponentDefs.is_instance(inst), "make_unique clears definition binding")
	f += _check(_kids(model, cid).size() == kids_before, "children kept after make_unique")
	var tags_cleared := true
	for k_v in _kids(model, cid):
		if (k_v as Dictionary).get("specs", {}).has("def_local_id"):
			tags_cleared = false
	f += _check(tags_cleared, "def_local_id tags cleared on children")
	# The now-unused definition was pruned.
	f += _check(model.get_definition("hybrid_inverter").is_empty(),
		"unused definition pruned after last instance detached")
	return f


func _test_v6_to_v7_definitions() -> int:
	var f := 0
	var model: GraphModel = GraphModelScript.new()
	_register(model, "hybrid_inverter")
	GraphComponentDefs.realize(model, "hybrid_inverter", "root", Vector2(0, 0))
	var saved := model.serialize()
	f += _check(int(saved.get("version", 0)) == 7, "serialize version is 7")
	f += _check(saved.has("definitions"), "serialize includes definitions registry")
	var m2: GraphModel = GraphModelScript.new()
	m2.deserialize(saved)
	f += _check(not m2.get_definition("hybrid_inverter").is_empty(),
		"definition survives serialize round-trip")
	# Legacy save (no definitions key) loads clean with an empty registry.
	var legacy := {"version": 6, "items": [], "connections": [], "scopes": {}}
	var m3: GraphModel = GraphModelScript.new()
	m3.deserialize(legacy)
	f += _check(m3.definitions.is_empty(), "legacy v6 save loads with empty definitions")
	return f

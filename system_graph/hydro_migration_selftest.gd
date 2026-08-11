extends SceneTree

## Offline, deterministic self-test for the Phase B hydro node unification:
## legacy `type=="hydro"` estimator items migrate on GraphModel.deserialize into
## `type=="processor"` / role "siphon_hydro" (one inspector section, one Hydro
## Lab, one physics path), carrying their estimator specs so the flow engine's
## spec-driven branch reproduces the old numbers. Saved DC wires on the legacy
## "positive"/"negative" handles are remapped to the processor's DC port pair
## (res_out_1_pos / res_out_1_neg — outputs[1] is dc_electricity).
## Run --import first so GraphModel / DcPowerWiring class_names register.

var _checks := 0


func _initialize() -> void:
	var fails := 0
	fails += _test_legacy_hydro_migrates()
	fails += _test_dc_wire_remap_and_battery_trace()
	fails += _test_migration_idempotent()
	fails += _test_existing_siphon_untouched()
	if fails == 0:
		print("HYDRO MIGRATION SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("HYDRO MIGRATION SELFTEST FAIL  (%d of %d checks failed)" % [fails, _checks])
	quit()


func _check(cond: bool, label: String) -> int:
	_checks += 1
	if cond:
		return 0
	print("  FAIL: %s" % label)
	return 1


## A canned legacy save: one type-"hydro" Pelton wired +/− to a battery.
func _legacy_save() -> Dictionary:
	return {
		"items": [
			{
				"id": "hyd1", "type": "hydro", "label": "Pelton 500W",
				"width": 124.0, "height": 112.0, "scope_id": "root",
				"elevation_m": 41.5,
				"specs": {
					"name": "Pelton 500W", "kind": "pelton",
					"gross_head_m": 25.0, "design_flow_lps": 3.0,
					"penstock_length_m": 60.0, "penstock_diameter_mm": 63.0,
					"pipe_roughness_mm": 0.0015,
					"turbine_efficiency": 0.0, "generator_efficiency": 0.85,
					"current_output_kw": 0.42, "cost": 1200.0,
					"monthly_flow_multipliers": [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
					"custom_note": "keep me",
				},
			},
			{
				"id": "bat1", "type": "battery", "scope_id": "root",
				"specs": {"voltage": 48.0, "ah": 100.0},
			},
		],
		"connections": [
			{
				"id": "c1", "scope_id": "root",
				"source_item_id": "hyd1", "source_handle_id": "positive",
				"target_item_id": "bat1", "target_handle_id": "positive",
				"polarity": "positive",
			},
			{
				"id": "c2", "scope_id": "root",
				"source_item_id": "hyd1", "source_handle_id": "negative",
				"target_item_id": "bat1", "target_handle_id": "negative",
				"polarity": "negative",
			},
		],
	}


func _test_legacy_hydro_migrates() -> int:
	var fails := 0
	var m := GraphModel.new()
	m.deserialize(_legacy_save())
	var it := m.get_item("hyd1")
	fails += _check(not it.is_empty(), "migrated item exists")
	fails += _check(str(it.get("type", "")) == "processor", "type hydro -> processor")
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	fails += _check(str(sp.get("role", "")) == "siphon_hydro", "role siphon_hydro")
	fails += _check(str(sp.get("turbine_kind", "")) == "pelton",
			"legacy kind -> turbine_kind pelton")
	fails += _check(is_equal_approx(float(sp.get("gross_head_m", 0.0)), 25.0),
			"gross_head_m carried")
	fails += _check(is_equal_approx(float(sp.get("design_flow_lps", 0.0)), 3.0),
			"design_flow_lps carried")
	fails += _check(is_equal_approx(float(sp.get("penstock_diameter_mm", 0.0)), 63.0),
			"penstock diameter carried")
	fails += _check(is_equal_approx(float(sp.get("generator_efficiency", 0.0)), 0.85),
			"generator efficiency carried")
	fails += _check(is_equal_approx(float(sp.get("cost", 0.0)), 1200.0), "cost carried")
	fails += _check(str(sp.get("custom_note", "")) == "keep me",
			"unfamiliar spec keys preserved")
	fails += _check((sp.get("monthly_flow_multipliers", []) as Array).size() == 12,
			"monthly multipliers preserved")
	fails += _check(is_equal_approx(float(it.get("elevation_m", 0.0)), 41.5),
			"elevation_m preserved")
	# Processor port shape: water in (direct intake), water + DC out.
	var inputs: Array = sp.get("inputs", []) as Array
	var outputs: Array = sp.get("outputs", []) as Array
	fails += _check(inputs.size() == 1 \
			and str((inputs[0] as Dictionary).get("kind", "")) == "water",
			"water input port")
	fails += _check(outputs.size() == 2 \
			and str((outputs[0] as Dictionary).get("kind", "")) == "water" \
			and str((outputs[1] as Dictionary).get("kind", "")) == "dc_electricity",
			"water + dc output ports (dc at index 1)")
	fails += _check(str(sp.get("model_id", "")) == "hydroturbine", "model_id set")
	# Card grew to the processor size.
	fails += _check(float(it.get("width", 0.0)) >= 150.0 \
			and float(it.get("height", 0.0)) >= 130.0, "card resized to processor")
	return fails


func _test_dc_wire_remap_and_battery_trace() -> int:
	var fails := 0
	var m := GraphModel.new()
	m.deserialize(_legacy_save())
	var pos_handle := ""
	var neg_handle := ""
	for conn: Dictionary in m.connections:
		if str(conn.get("id", "")) == "c1":
			pos_handle = str(conn.get("source_handle_id", ""))
		elif str(conn.get("id", "")) == "c2":
			neg_handle = str(conn.get("source_handle_id", ""))
	fails += _check(pos_handle == "res_out_1_pos", "positive wire remapped (got %s)" % pos_handle)
	fails += _check(neg_handle == "res_out_1_neg", "negative wire remapped (got %s)" % neg_handle)
	# The remapped wiring still counts as battery-connected DC generation.
	fails += _check(DcPowerWiring.find_battery_for_dc_port(m, "hyd1", "res_out_1_pos") == "bat1",
			"remapped DC port traces to the battery")
	fails += _check(DcPowerWiring.sum_graph_dc_generation_kw(m) > 0.41,
			"migrated turbine's kW counted toward the battery")
	# A wire on an UNRELATED item's positive handle is untouched.
	var m2 := GraphModel.new()
	var save := _legacy_save()
	(save["connections"] as Array).append({
		"id": "c3", "scope_id": "root",
		"source_item_id": "bat1", "source_handle_id": "positive",
		"target_item_id": "nowhere", "target_handle_id": "positive",
	})
	m2.deserialize(save)
	for conn: Dictionary in m2.connections:
		if str(conn.get("id", "")) == "c3":
			fails += _check(str(conn.get("source_handle_id", "")) == "positive",
					"non-hydro wires keep their handles")
	return fails


func _test_migration_idempotent() -> int:
	var fails := 0
	var m := GraphModel.new()
	m.deserialize(_legacy_save())
	var once := m.get_item("hyd1").duplicate(true)
	var once_conns := m.connections.duplicate(true)
	# Round-trip: serialize the migrated state and load it again.
	var m2 := GraphModel.new()
	m2.deserialize(m.serialize())
	var twice := m2.get_item("hyd1")
	fails += _check(str(twice.get("type", "")) == "processor", "still processor after round-trip")
	var sp1: Dictionary = once.get("specs", {}) as Dictionary
	var sp2: Dictionary = twice.get("specs", {}) as Dictionary
	fails += _check(str(sp2.get("turbine_kind", "")) == str(sp1.get("turbine_kind", "")),
			"turbine_kind stable")
	fails += _check(is_equal_approx(float(sp2.get("gross_head_m", 0.0)),
			float(sp1.get("gross_head_m", 0.0))), "gross_head_m stable")
	for i in m2.connections.size():
		var a: Dictionary = once_conns[i] as Dictionary
		var b: Dictionary = m2.connections[i] as Dictionary
		fails += _check(str(a.get("source_handle_id", "")) == str(b.get("source_handle_id", "")),
				"conn %d source handle stable" % i)
	return fails


func _test_existing_siphon_untouched() -> int:
	var fails := 0
	var m := GraphModel.new()
	m.deserialize({
		"items": [{
			"id": "sip1", "type": "processor", "scope_id": "root",
			"specs": {
				"role": "siphon_hydro", "turbine_kind": "siphon",
				"intake_diameter_mm": 203.0, "barrel_length_m": 20.0,
				"hydraulic_efficiency": 0.6,
				"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h", "direct_intake": true}],
				"outputs": [
					{"kind": "water", "rate": 0.0, "unit": "L/h"},
					{"kind": "dc_electricity", "rate": 0.0, "unit": "kW"},
				],
			},
		}],
		"connections": [],
	})
	var it := m.get_item("sip1")
	var sp: Dictionary = it.get("specs", {}) as Dictionary
	fails += _check(str(it.get("type", "")) == "processor"
			and str(sp.get("role", "")) == "siphon_hydro"
			and str(sp.get("turbine_kind", "")) == "siphon"
			and is_equal_approx(float(sp.get("barrel_length_m", 0.0)), 20.0),
			"existing siphon processor passes through unchanged")
	return fails

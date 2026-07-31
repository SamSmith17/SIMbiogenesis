extends SceneTree

## Offline self-test for PV electrical math, graph layout, and wiring helpers.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const GraphCanvasScript := preload("res://system_graph/graph_canvas.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_voc_series()
	fails += _test_voc_parallel_branches()
	fails += _test_overvoltage_fault()
	fails += _test_layout_resolver()
	fails += _test_layout_bounds_filter()
	fails += _test_controller_reset()
	fails += _test_array_topology()
	fails += _test_array_wire_and_voc()
	fails += _test_controller_ranking()
	fails += _test_voc_across_supernode()
	fails += _test_short_circuit_direct()
	fails += _test_short_circuit_series_loop()
	fails += _test_parallel_bank_no_short()
	fails += _test_bus_voltage_topology()
	fails += _test_battery_overvoltage()
	fails += _test_controller_clip_values()
	fails += _test_battery_chemistry()
	fails += _test_reverse_polarity()
	fails += _test_open_circuit_needs_return_leg()
	fails += _test_destroy_fx_envelope()
	fails += _test_fault_card_placement()
	if fails == 0:
		print("GRAPH ELECTRICAL SELFTEST PASS  (21 checks)")
	else:
		print("GRAPH ELECTRICAL SELFTEST FAIL  (%d failed)" % fails)
	quit()


# ---------------------------------------------------------------------------
# DC-side (GraphDcElectrical): banks, shorts, overcharge, current clipping
# ---------------------------------------------------------------------------

## Tutorial level 1: one wire straight from + to − of a single battery.
func _test_short_circuit_direct() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "b1", 12.0, 1.2)
	_dc_wire(model, "b1", "positive", "b1", "negative")
	var analysis := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	var shorts: Array = analysis.get("shorts", []) as Array
	if shorts.size() != 1:
		push_error("expected 1 short for direct +→− wire, got %d" % shorts.size())
		return 1
	var s: Dictionary = shorts[0]
	if str(s.get("battery_id", "")) != "b1":
		push_error("short should name b1, got %s" % str(s))
		return 1
	if (s.get("conn_ids", []) as Array).is_empty():
		push_error("short should carry the offending wire id")
		return 1
	if absf(float(s.get("loop_emf_v", 0.0)) - 12.0) > 0.5:
		push_error("loop EMF expected ~12 got %s" % str(s.get("loop_emf_v")))
		return 1
	return 0


## A clean series pair is fine; closing the loop (B+ back to A−) is a dead
## short with the full 24 V around the loop (KVL).
func _test_short_circuit_series_loop() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0, 1.2)
	_add_battery(model, "b", 12.0, 1.2)
	_dc_wire(model, "a", "positive", "b", "negative")  # series link — legitimate
	var clean := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	if not (clean.get("shorts", []) as Array).is_empty():
		push_error("open series chain must not read as a short")
		return 1
	var banks: Array = clean.get("banks", []) as Array
	if banks.size() != 1 or absf(float((banks[0] as Dictionary).get("bus_voltage", 0.0)) - 24.0) > 0.5:
		push_error("series pair should be one 24 V bank, got %s" % str(banks))
		return 1
	_dc_wire(model, "b", "positive", "a", "negative")  # closes the loop
	var looped := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	var shorts: Array = looped.get("shorts", []) as Array
	if shorts.size() != 1:
		push_error("closed series loop should short, got %d" % shorts.size())
		return 1
	if absf(float((shorts[0] as Dictionary).get("loop_emf_v", 0.0)) - 24.0) > 1.0:
		push_error("series-loop EMF expected ~24 got %s" % str(shorts[0]))
		return 1
	return 0


## Tutorial level 5 trap: paralleling equal batteries is legitimate — same bus
## voltage, doubled capacity, NOT a short (zero net EMF around the loop).
func _test_parallel_bank_no_short() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0, 1.2)
	_add_battery(model, "b", 12.0, 1.2)
	_dc_wire(model, "a", "positive", "b", "positive")
	_dc_wire(model, "a", "negative", "b", "negative")
	var analysis := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	if not (analysis.get("shorts", []) as Array).is_empty():
		push_error("equal parallel bank must not read as a short")
		return 1
	var banks: Array = analysis.get("banks", []) as Array
	if banks.size() != 1:
		push_error("expected one bank, got %d" % banks.size())
		return 1
	var bank: Dictionary = banks[0]
	if absf(float(bank.get("bus_voltage", 0.0)) - 12.0) > 0.5:
		push_error("parallel bank bus expected 12 got %s" % str(bank.get("bus_voltage")))
		return 1
	if absf(float(bank.get("capacity_kwh", 0.0)) - 2.4) > 0.01:
		push_error("parallel bank capacity expected 2.4 got %s" % str(bank.get("capacity_kwh")))
		return 1
	return 0


## 4S = 48 V; 2S2P = 24 V with series/parallel counts; a 12 V chain paralleled
## onto a 24 V chain flags mismatch (circulating current) without a fault.
func _test_bus_voltage_topology() -> int:
	var model: GraphModel = GraphModelScript.new()
	for i in 4:
		_add_battery(model, "s%d" % i, 12.0, 1.2)
	for i in 3:
		_dc_wire(model, "s%d" % i, "positive", "s%d" % (i + 1), "negative")
	var a := GraphDcElectrical.analyze(model, GraphNesting.flat_connections(model))
	var bank: Dictionary = (a.get("banks", []) as Array)[0]
	if absf(float(bank.get("bus_voltage", 0.0)) - 48.0) > 0.5 \
			or int(bank.get("series_count", 0)) != 4:
		push_error("4S bank expected 48 V ×4S, got %s" % str(bank))
		return 1
	# 2S2P: two series pairs, paralleled at both ends.
	var m2: GraphModel = GraphModelScript.new()
	for id in ["a1", "a2", "b1", "b2"]:
		_add_battery(m2, id, 12.0, 1.2)
	_dc_wire(m2, "a1", "positive", "a2", "negative")
	_dc_wire(m2, "b1", "positive", "b2", "negative")
	_dc_wire(m2, "a2", "positive", "b2", "positive")
	_dc_wire(m2, "a1", "negative", "b1", "negative")
	var a2an := GraphDcElectrical.analyze(m2, GraphNesting.flat_connections(m2))
	if not (a2an.get("shorts", []) as Array).is_empty():
		push_error("2S2P must not short")
		return 1
	var bank2: Dictionary = (a2an.get("banks", []) as Array)[0]
	if absf(float(bank2.get("bus_voltage", 0.0)) - 24.0) > 0.5 \
			or int(bank2.get("series_count", 0)) != 2 \
			or int(bank2.get("parallel_count", 0)) != 2:
		push_error("2S2P bank expected 24 V 2S2P, got %s" % str(bank2))
		return 1
	# Mismatched parallel: 24 V chain ∥ single 12 V battery → warn, not short.
	var m3: GraphModel = GraphModelScript.new()
	for id in ["c1", "c2", "d1"]:
		_add_battery(m3, id, 12.0, 1.2)
	_dc_wire(m3, "c1", "positive", "c2", "negative")
	_dc_wire(m3, "c2", "positive", "d1", "positive")
	_dc_wire(m3, "c1", "negative", "d1", "negative")
	var a3 := GraphDcElectrical.analyze(m3, GraphNesting.flat_connections(m3))
	if not (a3.get("shorts", []) as Array).is_empty():
		push_error("mismatched parallel chains should warn, not short")
		return 1
	if not bool(((a3.get("banks", []) as Array)[0] as Dictionary).get("mismatch", false)):
		push_error("mismatched parallel chains should set the mismatch flag")
		return 1
	return 0


## Tutorial level 2: 40 Voc panel wired straight to a 12 V battery overcharges
## it; the same panel behind a controller does not.
func _test_battery_overvoltage() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 12.0, 1.2)
	_add_panel(model, "p1", 40.0)
	_dc_wire(model, "p1", "positive", "bat", "positive")
	_dc_wire(model, "p1", "negative", "bat", "negative")
	var flat := GraphNesting.flat_connections(model)
	var analysis := GraphDcElectrical.analyze(model, flat)
	var faults := GraphDcElectrical.find_battery_overvoltage(model, flat, analysis, 25.0)
	if faults.size() != 1:
		push_error("expected 1 battery-overvoltage fault, got %d" % faults.size())
		return 1
	var f: Dictionary = faults[0]
	# 12.0 V nominal is 6 lead-acid cells, so the absorb ceiling is 6 × 2.40 V.
	# (Chemistry-aware since batteries carry a chemistry: the old blanket 1.217
	# ratio would have allowed a 12.8 V LFP pack up to ~15.6 V.)
	if absf(float(f.get("safe_v", 0.0)) - 14.4) > 0.1:
		push_error("safe_v expected 14.4 (6S lead-acid) got %s" % str(f.get("safe_v")))
		return 1
	# Behind a controller: no fault.
	var m2: GraphModel = GraphModelScript.new()
	_add_battery(m2, "bat", 12.0, 1.2)
	_add_panel(m2, "p1", 40.0)
	_add_controller(m2, "ctrl", 150.0)
	_dc_wire(m2, "p1", "positive", "ctrl", "pvPositive")
	_dc_wire(m2, "p1", "negative", "ctrl", "pvNegative")
	_dc_wire(m2, "ctrl", "batteryPositive", "bat", "positive")
	_dc_wire(m2, "ctrl", "batteryNegative", "bat", "negative")
	var flat2 := GraphNesting.flat_connections(m2)
	var an2 := GraphDcElectrical.analyze(m2, flat2)
	if not GraphDcElectrical.find_battery_overvoltage(m2, flat2, an2, 25.0).is_empty():
		push_error("panel behind a controller must not overcharge the battery")
		return 1
	return 0


## Tutorial levels 3–6: the curriculum wattages emerge from bus_V × I_max.
## 300 W @ 12 V×10 A → 120 W; 1200 W @ 12 V×30 A → 360 W; 24 V → 720 W;
## 48 V×30 A (1440 W cap) → array-limited 1200 W, not clipped.
func _test_controller_clip_values() -> int:
	var cases := [
		{"array_w": 300.0, "bus": 12.0, "amps": 10.0, "want": 120.0, "clipped": true},
		{"array_w": 1200.0, "bus": 12.0, "amps": 30.0, "want": 360.0, "clipped": true},
		{"array_w": 1200.0, "bus": 24.0, "amps": 30.0, "want": 720.0, "clipped": true},
		{"array_w": 1200.0, "bus": 48.0, "amps": 30.0, "want": 1200.0, "clipped": false},
	]
	for c_v in cases:
		var c: Dictionary = c_v
		var ctrl := {"type": "controller", "specs": {"max_charge_amps": float(c["amps"])}}
		var bank := {"bus_voltage": float(c["bus"])}
		var th := GraphDcElectrical.controller_throttle(ctrl, bank, float(c["array_w"]))
		if absf(float(th.get("delivered_w", 0.0)) - float(c["want"])) > 0.5:
			push_error("throttle %s expected %.0f W got %s" % [str(c), float(c["want"]), str(th)])
			return 1
		if bool(th.get("clipped", true)) != bool(c["clipped"]):
			push_error("throttle clipped flag wrong for %s: %s" % [str(c), str(th)])
			return 1
	# End-to-end: bank_for_controller resolves the wired bank (2S → 24 V).
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "a", 12.0, 1.2)
	_add_battery(model, "b", 12.0, 1.2)
	_dc_wire(model, "a", "positive", "b", "negative")
	_add_controller(model, "ctrl", 150.0)
	_dc_wire(model, "ctrl", "batteryPositive", "b", "positive")
	_dc_wire(model, "ctrl", "batteryNegative", "a", "negative")
	var flat := GraphNesting.flat_connections(model)
	var analysis := GraphDcElectrical.analyze(model, flat)
	var bank2 := GraphDcElectrical.bank_for_controller(model, "ctrl", flat, analysis)
	if bank2.is_empty() or absf(float(bank2.get("bus_voltage", 0.0)) - 24.0) > 0.5:
		push_error("bank_for_controller expected 24 V bank, got %s" % str(bank2))
		return 1
	# No current limit modeled (amps ≤ 0) → array passes untouched.
	var free := GraphDcElectrical.controller_throttle(
		{"type": "controller", "specs": {}}, bank2, 5000.0)
	if absf(float(free.get("delivered_w", 0.0)) - 5000.0) > 0.5:
		push_error("no-amp-limit controller must not clip, got %s" % str(free))
		return 1
	return 0


## Destroy-FX envelope. The visuals need a viewport, but the timing/easing/audio
## are pure functions and are pinned here: stages open and close where they
## should, the shake decays to EXACTLY zero (a residual offset would leave the
## canvas permanently nudged), and the synthesized boom is real audio.
func _test_destroy_fx_envelope() -> int:
	# Stage envelope: clamped at both ends, monotonic across the window.
	if GraphCanvasScript.fx_stage(0.0, 0.1, 0.5) != 0.0 \
			or GraphCanvasScript.fx_stage(0.05, 0.1, 0.5) != 0.0:
		push_error("fx_stage should read 0 before the stage opens")
		return 1
	if GraphCanvasScript.fx_stage(0.5, 0.1, 0.5) != 1.0 \
			or GraphCanvasScript.fx_stage(9.0, 0.1, 0.5) != 1.0:
		push_error("fx_stage should read 1 once the stage has closed")
		return 1
	var prev := -1.0
	for i in 12:
		var v: float = GraphCanvasScript.fx_stage(0.1 + float(i) * 0.03, 0.1, 0.5)
		if v < prev:
			push_error("fx_stage must not go backwards inside the window")
			return 1
		prev = v

	# Shake: strongest at t=0, decaying, and exactly zero once the window closes.
	var early: Vector2 = GraphCanvasScript.fx_shake_offset(0.02)
	var late: Vector2 = GraphCanvasScript.fx_shake_offset(0.30)
	if early.length() <= 0.0:
		push_error("shake should be non-zero at the start of the blast")
		return 1
	if late.length() >= early.length():
		push_error("shake should decay: %f then %f" % [early.length(), late.length()])
		return 1
	if GraphCanvasScript.fx_shake_offset(GraphCanvasScript.FX_SHAKE_S) != Vector2.ZERO \
			or GraphCanvasScript.fx_shake_offset(5.0) != Vector2.ZERO:
		push_error("shake must settle to exactly zero or the canvas stays nudged")
		return 1

	# The second arc-flash's own shake pulse: silent in the gap after the
	# primary shake ends, non-zero during its own window, and settled again
	# once IT closes — two independent decays, not one long tail.
	var gap_t := (GraphCanvasScript.FX_SHAKE_S + GraphCanvasScript.FX_CRACK_AT) * 0.5
	if gap_t < GraphCanvasScript.FX_CRACK_AT \
			and GraphCanvasScript.fx_shake_offset(gap_t) != Vector2.ZERO:
		push_error("shake should be silent in the gap before the crack pulse")
		return 1
	if GraphCanvasScript.fx_shake_offset(GraphCanvasScript.FX_CRACK_AT + 0.02).length() <= 0.0:
		push_error("crack pulse should shake the canvas when it fires")
		return 1
	# Past the window, not exactly on its edge — FX_CRACK_AT + FX_CRACK_SHAKE_S
	# is a sum of two floats and can land a hair inside or outside the open
	# interval depending on rounding, which isn't the thing being tested.
	if GraphCanvasScript.fx_shake_offset(
			GraphCanvasScript.FX_CRACK_AT + GraphCanvasScript.FX_CRACK_SHAKE_S + 0.05) != Vector2.ZERO:
		push_error("crack pulse shake must also settle to exactly zero")
		return 1

	# Fire ramp: white-hot at the start, cooled to smoke by the end.
	var hot: Color = GraphCanvasScript.fx_fire_color(0.0)
	var cold: Color = GraphCanvasScript.fx_fire_color(1.0)
	if hot.r + hot.g + hot.b <= cold.r + cold.g + cold.b:
		push_error("fire ramp should cool, not heat up")
		return 1

	# Synthesized boom: right length/format, real signal, and it decays.
	var stream: AudioStreamWAV = GraphCanvasScript.build_boom_stream()
	var want_bytes := int(GraphCanvasScript.BOOM_SAMPLE_RATE
		* GraphCanvasScript.BOOM_SECONDS) * 2
	if stream.data.size() != want_bytes:
		push_error("boom expected %d bytes got %d" % [want_bytes, stream.data.size()])
		return 1
	if stream.format != AudioStreamWAV.FORMAT_16_BITS or stream.stereo:
		push_error("boom should be 16-bit mono")
		return 1
	var head_peak := 0
	var tail_peak := 0
	var total := stream.data.size() / 2
	for i in total:
		var v: int = absi(stream.data.decode_s16(i * 2))
		if i < total / 8:
			head_peak = maxi(head_peak, v)
		elif i > total * 7 / 8:
			tail_peak = maxi(tail_peak, v)
	if head_peak < 8000:
		push_error("boom is near-silent at the attack (peak %d)" % head_peak)
		return 1
	if tail_peak >= head_peak:
		push_error("boom should decay: head %d tail %d" % [head_peak, tail_peak])
		return 1
	return 0


## The fault card must stay fully on screen in its corner dock and clear of the
## timeline stack. Headless has no viewport, so UiScreenLayout falls back to its
## documented 1280×720 — the oversized case proves the clamp actually engages.
func _test_fault_card_placement() -> int:
	var screen := Vector2(1280.0, 720.0)
	var max_h := screen.y - UiScreenLayout.timeline_stack_height()
	for desired in [Vector2(520.0, 340.0), Vector2(4000.0, 4000.0)]:
		var panel := Control.new()
		UiScreenLayout.clamped_corner_card(panel, desired)
		var w: float = panel.custom_minimum_size.x
		var h: float = panel.custom_minimum_size.y
		if w <= 0.0 or h <= 0.0:
			push_error("corner card got a degenerate size for desired %s" % str(desired))
			panel.free()
			return 1
		if w > screen.x or h > max_h:
			push_error("corner card %.0fx%.0f overflows the usable area (%.0fx%.0f)"
				% [w, h, screen.x, max_h])
			panel.free()
			return 1
		# Anchored bottom-right: offsets inset back from that corner, and the
		# bottom edge must sit above the timeline stack.
		if panel.offset_right > 0.0 or panel.offset_left >= panel.offset_right:
			push_error("corner card should inset from the right edge")
			panel.free()
			return 1
		if panel.offset_bottom > -UiScreenLayout.timeline_stack_height() + 0.01:
			push_error("corner card should clear the timeline stack, got %f"
				% panel.offset_bottom)
			panel.free()
			return 1
		panel.free()
	return 0


## One wire is not a circuit. Until the return leg lands there is no current
## path, so: no bank for the controller, no PV sources, and no overcharge fault.
## Each leg is then completed in turn to prove the flip is the second wire.
func _test_open_circuit_needs_return_leg() -> int:
	# --- battery leg: controller + → battery + only ---------------------------
	var model: GraphModel = GraphModelScript.new()
	_add_battery(model, "bat", 12.0, 1.2)
	_add_controller(model, "ctrl", 150.0)
	_dc_wire(model, "ctrl", "batteryPositive", "bat", "positive")
	var flat := GraphNesting.flat_connections(model)
	var an := GraphDcElectrical.analyze(model, flat)
	if not GraphDcElectrical.bank_for_controller(model, "ctrl", flat, an).is_empty():
		push_error("one battery wire is an open circuit — bank_for_controller must be empty")
		return 1
	_dc_wire(model, "ctrl", "batteryNegative", "bat", "negative")
	flat = GraphNesting.flat_connections(model)
	an = GraphDcElectrical.analyze(model, flat)
	var bank := GraphDcElectrical.bank_for_controller(model, "ctrl", flat, an)
	if bank.is_empty() or absf(float(bank.get("bus_voltage", 0.0)) - 12.0) > 0.5:
		push_error("both battery legs wired should resolve a 12 V bank, got %s" % str(bank))
		return 1

	# --- PV leg: panel + → controller pv+ only --------------------------------
	var m2: GraphModel = GraphModelScript.new()
	_add_panel(m2, "p1", 48.0)
	_add_controller(m2, "ctrl", 150.0)
	_dc_wire(m2, "p1", "positive", "ctrl", "pvPositive")
	var flat2 := GraphNesting.flat_connections(m2)
	if not PvElectrical.pv_sources_for_controller_flat(m2, "ctrl", flat2).is_empty():
		push_error("one PV wire is an open circuit — no PV sources should be reported")
		return 1
	_dc_wire(m2, "p1", "negative", "ctrl", "pvNegative")
	flat2 = GraphNesting.flat_connections(m2)
	if PvElectrical.pv_sources_for_controller_flat(m2, "ctrl", flat2).size() != 1:
		push_error("both PV legs wired should report the panel as a source")
		return 1

	# --- overcharge: a half-wired panel cannot overcharge a bank --------------
	var m3: GraphModel = GraphModelScript.new()
	_add_battery(m3, "bat", 12.0, 1.2)
	_add_panel(m3, "p1", 40.0)
	_dc_wire(m3, "p1", "positive", "bat", "positive")
	var flat3 := GraphNesting.flat_connections(m3)
	var an3 := GraphDcElectrical.analyze(m3, flat3)
	if not GraphDcElectrical.find_battery_overvoltage(m3, flat3, an3, 25.0).is_empty():
		push_error("a panel wired on one leg cannot overcharge the bank")
		return 1
	_dc_wire(m3, "p1", "negative", "bat", "negative")
	flat3 = GraphNesting.flat_connections(m3)
	an3 = GraphDcElectrical.analyze(m3, flat3)
	if GraphDcElectrical.find_battery_overvoltage(m3, flat3, an3, 25.0).size() != 1:
		push_error("closing the return leg should overcharge the 12 V bank")
		return 1
	return 0


## Nesting-aware Voc: a PV string whose panels live inside a super-node wired to
## a controller in the parent scope must still fault (find_overvoltage_faults_flat
## flattens the portals and scans every scope).
func _test_voc_across_supernode() -> int:
	var model: GraphModel = GraphModelScript.new()
	for i in 4:
		_add_panel(model, "sp%d" % i, 48.0)
	_add_controller(model, "ctrl", 150.0)
	# Series-chain panels inside the child scope.
	for i in 3:
		model.add_connection({"scope_id": "scope_grp", "polarity": "positive",
			"source_item_id": "sp%d" % i, "source_handle_id": "positive",
			"target_item_id": "sp%d" % (i + 1), "target_handle_id": "negative"})
	# Group them; expose the string ends.
	model.add_item({"id": "grp", "type": "compound", "x": 0, "y": 0,
		"width": 180, "height": 120, "scope_id": "root", "child_scope_id": "scope_grp",
		"handles": [
			{"id": "pv+", "polarity": "positive", "direction": "out", "rx": 1.0, "ry": 0.4},
			{"id": "pv-", "polarity": "negative", "direction": "out", "rx": 1.0, "ry": 0.6}],
		"specs": {"compound_kind": "", "exposed_ports": [
			{"handle_id": "pv+", "child_item_id": "sp3", "child_handle_id": "positive",
				"direction": "out", "polarity": "positive"},
			{"handle_id": "pv-", "child_item_id": "sp0", "child_handle_id": "negative",
				"direction": "out", "polarity": "negative"}]}})
	model.ensure_scope("scope_grp", "root", "grp", "grp")
	for i in 4:
		model.update_item("sp%d" % i, {"scope_id": "scope_grp", "parent_compound_id": "grp"})
	model.add_connection({"scope_id": "root", "polarity": "positive",
		"source_item_id": "grp", "source_handle_id": "pv+",
		"target_item_id": "ctrl", "target_handle_id": "pvPositive"})
	model.add_connection({"scope_id": "root", "polarity": "negative",
		"source_item_id": "grp", "source_handle_id": "pv-",
		"target_item_id": "ctrl", "target_handle_id": "pvNegative"})
	var faults := PvElectrical.find_overvoltage_faults_flat(model, 25.0)
	if faults.size() != 1:
		push_error("expected 1 over-voltage fault across super-node, got %d" % faults.size())
		return 1
	return 0


func _test_voc_series() -> int:
	var model: GraphModel = GraphModelScript.new()
	var p1 := _add_panel(model, "p1", 48.0)
	var p2 := _add_panel(model, "p2", 48.0)
	var p3 := _add_panel(model, "p3", 48.0)
	var ctrl := _add_controller(model, "ctrl", 100.0)
	GraphPvWiring.wire_series(model, ["p1", "p2", "p3"], "ctrl")
	var voc := PvElectrical.max_string_voc_for_controller(model, "ctrl", "root", 25.0)
	if absf(voc - 144.0) > 0.5:
		push_error("series voc expected ~144 got %f" % voc)
		return 1
	return 0


func _test_voc_parallel_branches() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_panel(model, "a1", 40.0)
	_add_panel(model, "a2", 40.0)
	_add_panel(model, "b1", 50.0)
	var ctrl := _add_controller(model, "ctrl", 200.0)
	GraphPvWiring.add_pv_connection(model, "positive", "a1", "positive", "a2", "negative")
	GraphPvWiring.add_pv_connection(model, "positive", "a1", "negative", "ctrl", "pvNegative")
	GraphPvWiring.add_pv_connection(model, "positive", "a2", "positive", "ctrl", "pvPositive")
	GraphPvWiring.add_pv_connection(model, "positive", "b1", "positive", "ctrl", "pvPositive")
	GraphPvWiring.add_pv_connection(model, "negative", "b1", "negative", "ctrl", "pvNegative")
	var vocs: Array = PvElectrical.branch_vocs_for_controller(model, "ctrl", "root", 25.0)
	var max_v := 0.0
	for v in vocs:
		max_v = maxf(max_v, float(v))
	if absf(max_v - 80.0) > 0.5:
		push_error("parallel branch max voc expected ~80 got %f branches=%s" % [max_v, str(vocs)])
		return 1
	return 0


func _test_overvoltage_fault() -> int:
	var model: GraphModel = GraphModelScript.new()
	var panels: Array[String] = []
	for i in 4:
		panels.append("p%d" % i)
		_add_panel(model, "p%d" % i, 48.0)
	var ctrl := _add_controller(model, "ctrl", 150.0)
	GraphPvWiring.wire_series(model, panels, "ctrl")
	var faults := PvElectrical.find_overvoltage_faults(model, "root", 25.0)
	if faults.is_empty():
		push_error("expected overvoltage fault for 4x48V series on 150V controller")
		return 1
	return 0


func _test_layout_resolver() -> int:
	var items: Array = [
		{"id": "a", "x": 0.0, "y": 0.0, "width": 100.0, "height": 80.0},
		{"id": "b", "x": 10.0, "y": 10.0, "width": 100.0, "height": 80.0},
	]
	var patches: Dictionary = GraphLayout.resolve_overlaps(items, 16.0, 64)
	var ra := GraphLayout.item_rect({"id": "a", "x": (patches["a"] as Vector2).x,
		"y": (patches["a"] as Vector2).y, "width": 100.0, "height": 80.0})
	var rb := GraphLayout.item_rect({"id": "b", "x": (patches["b"] as Vector2).x,
		"y": (patches["b"] as Vector2).y, "width": 100.0, "height": 80.0})
	if GraphLayout.rects_overlap(ra, rb):
		push_error("layout resolver left overlapping rects")
		return 1
	return 0


func _test_layout_bounds_filter() -> int:
	var items: Array = [
		{"id": "virtual_solar_array", "x": -1650.0, "y": -1050.0, "width": 168.0, "height": 96.0,
			"layout_exclude": true},
		{"id": "virtual_controller", "x": 140.0, "y": -120.0, "width": 140.0, "height": 120.0},
		{"id": "virtual_battery", "x": 340.0, "y": -100.0, "width": 100.0, "height": 136.0},
	]
	var bounds := GraphLayout.content_bounds(items)
	if bounds.position.x < -500.0:
		push_error("layout bounds filter still includes off-canvas virtual_solar_array")
		return 1
	if GraphLayout.include_in_layout(items[0] as Dictionary):
		push_error("virtual_solar_array should be excluded from layout")
		return 1
	return 0


func _test_controller_reset() -> int:
	var model: GraphModel = GraphModelScript.new()
	var ctrl := _add_controller(model, "ctrl", 150.0)
	var sp: Dictionary = (model.get_item("ctrl").get("specs", {}) as Dictionary).duplicate(true)
	sp["destroyed"] = true
	sp["destroyed_reason"] = "test"
	model.update_item("ctrl", {"specs": sp})
	sp = model.get_item("ctrl").get("specs", {}) as Dictionary
	sp["destroyed"] = false
	sp.erase("destroyed_reason")
	model.update_item("ctrl", {"specs": sp})
	if bool((model.get_item("ctrl").get("specs", {}) as Dictionary).get("destroyed", true)):
		push_error("controller reset did not clear destroyed flag")
		return 1
	return 0


func _test_array_topology() -> int:
	# 12 panels @ 48 V on a 150 V controller → max series = 3 → 3S×4P.
	var topo := SolarArrayIntelligence.best_series_parallel(12, 48.0, 150.0)
	if int(topo.get("series", 0)) != 3:
		push_error("expected series 3 got %s" % str(topo))
		return 1
	if int(topo.get("parallel", 0)) != 4:
		push_error("expected parallel 4 got %s" % str(topo))
		return 1
	if absf(float(topo.get("equiv_voc", 0.0)) - 144.0) > 0.5:
		push_error("expected equiv_voc 144 got %s" % str(topo))
		return 1
	# Panel Voc alone exceeds controller → fitted 0.
	var bad := SolarArrayIntelligence.best_series_parallel(6, 200.0, 150.0)
	if int(bad.get("fitted", 1)) != 0:
		push_error("expected fitted 0 when panel Voc > max_voc")
		return 1
	return 0


func _test_array_wire_and_voc() -> int:
	var model: GraphModel = GraphModelScript.new()
	var array_id := "arr1"
	var topo := SolarArrayIntelligence.best_series_parallel(6, 48.0, 150.0)
	var equiv := SolarArrayIntelligence.build_array_equiv_specs(
			6, 400.0, 48.0, 41.0, 9.76, 11.0, topo)
	model.add_item({
		"id": array_id, "type": "compound", "x": 0.0, "y": 0.0,
		"width": 200.0, "height": 140.0, "scope_id": "root",
		"specs": {
			"compound_kind": "array",
			"array_equiv_voc": float(equiv.get("array_equiv_voc", 0.0)),
			"array_panel_units": 6,
			"osm_import": true, "osm_tag": "osm_solar_0_0",
		},
	})
	_add_controller(model, "ctrl", 150.0)
	SolarArrayIntelligence.wire_array_to_controller(model, array_id, "ctrl", "root")
	var voc := PvElectrical.max_string_voc_for_controller(model, "ctrl", "root", 25.0)
	var want := float(equiv.get("array_equiv_voc", 0.0))
	if absf(voc - want) > 0.5:
		push_error("array compound Voc expected ~%f got %f" % [want, voc])
		return 1
	if not PvElectrical.is_pv_source_item(model.get_item(array_id)):
		push_error("array compound should be a PV source")
		return 1
	return 0


func _test_controller_ranking() -> int:
	var model: GraphModel = GraphModelScript.new()
	_add_controller(model, "near", 150.0)
	model.update_item("near", {"x": 50.0, "y": 0.0})
	_add_controller(model, "far_big", 500.0)
	model.update_item("far_big", {"x": 2000.0, "y": 0.0})
	# 20 panels × 48 V needs ~3S (144 V) — both fit; nearer 150 V should rank high.
	var ranked := SolarArrayIntelligence.rank_controllers(
			model, Vector2(0.0, 0.0), 20, 48.0, 400.0, "root")
	if ranked.is_empty():
		push_error("expected ranked controllers")
		return 1
	var top: Dictionary = ranked[0]
	# Top should be an on-canvas fit (near) or a fitting preset — not a over-Voc.
	if not bool(top.get("fits", false)):
		push_error("top-ranked controller should fit Voc")
		return 1
	var rec := SolarArrayIntelligence.recommend_controller_preset(20, 48.0, 400.0)
	if rec.is_empty() or not (rec.get("specs", {}) is Dictionary):
		push_error("recommend_controller_preset returned empty")
		return 1
	var max_voc := float((rec.get("specs", {}) as Dictionary).get("max_voc", 0.0))
	if max_voc < 144.0:
		push_error("recommended preset max_voc too low: %f" % max_voc)
		return 1
	return 0


## Reverse polarity is judged ONLY on controller↔device links. Series strings
## (+ to − between two panels, or two batteries) are legitimate wiring and must
## never be flagged — a blanket "+ must meet +" rule would break them, and
## graph_seed_selftest asserts they stay connectable.
func _test_reverse_polarity() -> int:
	# Correctly wired reference system: nothing flagged.
	var ok: GraphModel = GraphModelScript.new()
	_add_battery(ok, "bat", 12.0, 1.2)
	_add_panel(ok, "p1", 40.0)
	_add_controller(ok, "ctrl", 150.0)
	_dc_wire(ok, "p1", "positive", "ctrl", "pvPositive")
	_dc_wire(ok, "p1", "negative", "ctrl", "pvNegative")
	_dc_wire(ok, "ctrl", "batteryPositive", "bat", "positive")
	_dc_wire(ok, "ctrl", "batteryNegative", "bat", "negative")
	var flat_ok := GraphNesting.flat_connections(ok)
	if not GraphDcElectrical.find_reverse_polarity(ok, flat_ok).is_empty():
		push_error("correctly wired system must not report reverse polarity")
		return 1
	if GraphDcElectrical.controller_pv_reversed(ok, "ctrl", flat_ok):
		push_error("correctly wired PV must not read as reversed")
		return 1

	# Crossed PV pair: flagged as a non-destructive "pv" reversal.
	var pv: GraphModel = GraphModelScript.new()
	_add_battery(pv, "bat", 12.0, 1.2)
	_add_panel(pv, "p1", 40.0)
	_add_controller(pv, "ctrl", 150.0)
	_dc_wire(pv, "p1", "positive", "ctrl", "pvNegative")
	_dc_wire(pv, "p1", "negative", "ctrl", "pvPositive")
	_dc_wire(pv, "ctrl", "batteryPositive", "bat", "positive")
	_dc_wire(pv, "ctrl", "batteryNegative", "bat", "negative")
	var flat_pv := GraphNesting.flat_connections(pv)
	var rev_pv := GraphDcElectrical.find_reverse_polarity(pv, flat_pv)
	if rev_pv.size() != 2:
		push_error("crossed PV pair should flag both wires, got %d" % rev_pv.size())
		return 1
	for r in rev_pv:
		if str((r as Dictionary).get("kind", "")) != "pv":
			push_error("PV reversal should be kind 'pv', got %s" % str(r))
			return 1
	if not GraphDcElectrical.controller_pv_reversed(pv, "ctrl", flat_pv):
		push_error("controller_pv_reversed should see the crossed pair")
		return 1
	# ...and the tutorial's watt goal must therefore be unsatisfiable.
	var deliv := TutorialGoals.deliverable(pv, flat_pv,
		GraphDcElectrical.analyze(pv, flat_pv))
	if float(deliv.get("deliverable_w", -1.0)) != 0.0:
		push_error("a reversed array must deliver 0 W, got %s" % str(deliv))
		return 1

	# Crossed battery lead: flagged as the destructive "battery" kind. This is
	# the case the union-find was blind to (controller-side wires never entered
	# it, and either leg resolved to the same bank root).
	var bt: GraphModel = GraphModelScript.new()
	_add_battery(bt, "bat", 12.0, 1.2)
	_add_panel(bt, "p1", 40.0)
	_add_controller(bt, "ctrl", 150.0)
	_dc_wire(bt, "p1", "positive", "ctrl", "pvPositive")
	_dc_wire(bt, "p1", "negative", "ctrl", "pvNegative")
	_dc_wire(bt, "ctrl", "batteryPositive", "bat", "negative")
	_dc_wire(bt, "ctrl", "batteryNegative", "bat", "positive")
	var rev_bt := GraphDcElectrical.find_reverse_polarity(bt, GraphNesting.flat_connections(bt))
	if rev_bt.size() != 2:
		push_error("crossed battery leads should flag both wires, got %d" % rev_bt.size())
		return 1
	for r2 in rev_bt:
		if str((r2 as Dictionary).get("kind", "")) != "battery":
			push_error("battery reversal should be kind 'battery', got %s" % str(r2))
			return 1
		if str((r2 as Dictionary).get("other_id", "")) != "bat":
			push_error("battery reversal should name the battery")
			return 1

	# Series chaining stays legal: panel + → panel −, battery + → battery −.
	var ser: GraphModel = GraphModelScript.new()
	_add_panel(ser, "a", 40.0)
	_add_panel(ser, "b", 40.0)
	_add_battery(ser, "b1", 12.0, 1.2)
	_add_battery(ser, "b2", 12.0, 1.2)
	_dc_wire(ser, "a", "positive", "b", "negative")
	_dc_wire(ser, "b1", "positive", "b2", "negative")
	if not GraphDcElectrical.find_reverse_polarity(
			ser, GraphNesting.flat_connections(ser)).is_empty():
		push_error("series strings must never be flagged as reversed")
		return 1
	return 0


## Chemistry identification and what it implies. The voltage discriminator is
## the load-bearing rule: it classifies packs whose names carry no chemistry
## token, plus every legacy save and user-authored preset written before the
## field existed.
func _test_battery_chemistry() -> int:
	var cases := [
		# explicit spec wins
		[{"chemistry": "LFP", "voltage": 12.0, "name": "12V 100Ah AGM"}, BatteryChemistry.LFP],
		# name when there is no explicit field
		[{"voltage": 0.0, "name": "12V 100Ah LiFePO4"}, BatteryChemistry.LFP],
		[{"voltage": 0.0, "name": "12V 100Ah AGM"}, BatteryChemistry.LEAD],
		# voltage discriminator — whole cells only divide one way
		[{"voltage": 12.8, "name": "Server Rack"}, BatteryChemistry.LFP],
		[{"voltage": 51.2, "name": "Server Rack 48V 100Ah"}, BatteryChemistry.LFP],
		[{"voltage": 12.0, "name": "Unlabelled"}, BatteryChemistry.LEAD],
		[{"voltage": 24.0, "name": "Unlabelled"}, BatteryChemistry.LEAD],
	]
	for c_v in cases:
		var c: Array = c_v
		var got := BatteryChemistry.infer(c[0] as Dictionary)
		if got != str(c[1]):
			push_error("chemistry for %s expected '%s' got '%s'" % [str(c[0]), str(c[1]), got])
			return 1
	# Ceilings follow whole cells, not a blanket ratio.
	if absf(BatteryChemistry.charge_ceiling_v(12.8, BatteryChemistry.LFP) - 14.6) > 0.05:
		push_error("4S LFP should charge to 14.6 V")
		return 1
	if absf(BatteryChemistry.charge_ceiling_v(12.0, BatteryChemistry.LEAD) - 14.4) > 0.05:
		push_error("6S lead-acid should charge to 14.4 V")
		return 1
	if absf(BatteryChemistry.charge_ceiling_v(51.2, BatteryChemistry.LFP) - 58.4) > 0.05:
		push_error("16S LFP should charge to 58.4 V")
		return 1
	# Lead-acid can only be cycled about half as deep as LFP.
	if BatteryChemistry.usable_fraction(BatteryChemistry.LEAD) \
			>= BatteryChemistry.usable_fraction(BatteryChemistry.LFP):
		push_error("lead-acid usable depth must be shallower than LFP")
		return 1
	# Resting voltage rises with SOC for both, but LFP stays far flatter across
	# the mid range — which is exactly why voltage is a poor LFP fuel gauge.
	for chem in [BatteryChemistry.LFP, BatteryChemistry.LEAD]:
		var lo := BatteryChemistry.voltage_at_soc(12.8, str(chem), 0.05)
		var hi := BatteryChemistry.voltage_at_soc(12.8, str(chem), 0.95)
		if hi <= lo:
			push_error("'%s' resting voltage must rise with SOC" % str(chem))
			return 1
	var lfp_mid := absf(BatteryChemistry.voltage_at_soc(12.8, BatteryChemistry.LFP, 0.7)
			- BatteryChemistry.voltage_at_soc(12.8, BatteryChemistry.LFP, 0.3))
	var pb_mid := absf(BatteryChemistry.voltage_at_soc(12.0, BatteryChemistry.LEAD, 0.7)
			- BatteryChemistry.voltage_at_soc(12.0, BatteryChemistry.LEAD, 0.3))
	if lfp_mid >= pb_mid:
		push_error("LFP mid-range voltage should be flatter than lead-acid (%.3f vs %.3f)" % [
			lfp_mid, pb_mid])
		return 1
	# Every shipped battery preset must resolve to a known chemistry.
	for p in ComponentPresets.presets_for_category("batteries"):
		var sp: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
		if BatteryChemistry.infer(sp).is_empty():
			push_error("preset '%s' has no resolvable chemistry" % str((p as Dictionary).get("label", "")))
			return 1
	return 0


func _add_panel(model: GraphModel, id: String, voc: float) -> String:
	model.add_item({
		"id": id, "type": "panel", "x": 0.0, "y": 0.0, "width": 120.0, "height": 100.0,
		"scope_id": "root",
		"specs": {"voc": voc, "vmp": voc * 0.8, "wmp": 400.0, "imp": 10.0, "isc": 10.5},
	})
	return id


func _add_controller(model: GraphModel, id: String, max_voc: float) -> String:
	model.add_item({
		"id": id, "type": "controller", "x": 400.0, "y": 0.0, "width": 140.0, "height": 120.0,
		"scope_id": "root",
		"specs": {"max_voc": max_voc, "max_charge_amps": 30.0, "max_pv_watts": 2000.0},
	})
	return id


func _add_battery(model: GraphModel, id: String, voltage: float, kwh: float) -> String:
	model.add_item({
		"id": id, "type": "battery", "x": 0.0, "y": 300.0, "width": 110.0, "height": 80.0,
		"scope_id": "root",
		"specs": {"voltage": voltage, "ah": kwh * 1000.0 / maxf(voltage, 1.0), "kwh": kwh,
			"soc": 0.8},
	})
	return id


## Raw DC wire between two handles (polarity follows the source handle like the
## canvas does; GraphDcElectrical only requires it to be a DC polarity).
func _dc_wire(model: GraphModel, src: String, src_handle: String,
		tgt: String, tgt_handle: String) -> void:
	var pol := "negative" if src_handle.to_lower().contains("neg") else "positive"
	model.add_connection({"scope_id": "root", "polarity": pol,
		"source_item_id": src, "source_handle_id": src_handle,
		"target_item_id": tgt, "target_handle_id": tgt_handle})

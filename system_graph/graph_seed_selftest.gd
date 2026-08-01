extends SceneTree

## Offline checks for blank-graph migration, StarShade seeding idempotency, and aggregate math.

const GraphModelScript := preload("res://system_graph/data/graph_model.gd")
const SolarBridgeScript := preload("res://system_graph/solar_bridge.gd")
const PuzzleStarterScript := preload("res://system_graph/puzzle_starter_graph_seeder.gd")


func _initialize() -> void:
	var fails := 0
	fails += _test_legacy_strip()
	fails += _test_bridge_no_autoseed()
	fails += _test_starshade_idempotent()
	fails += _test_starshade_full_wiring()
	fails += _test_starshade_reseed_resizes()
	fails += _test_dc_series_polarity()
	fails += _test_aggregate_sync()
	fails += _test_puzzle_starter_idempotent()
	fails += _test_unique_item_ids()
	fails += _test_deserialize_dedup()
	if fails == 0:
		print("GRAPH SEED SELFTEST PASS  (10 checks)")
	else:
		print("GRAPH SEED SELFTEST FAIL  (%d failed)" % fails)
	quit()


func _populate_legacy_virtual_graph(model: GraphModel) -> void:
	for i in range(GraphVirtualIds.ARRAY_PANEL_COUNT):
		var iid := GraphVirtualIds.panel_node_id(i)
		var pos := GraphVirtualIds.panel_node_position(i)
		model.add_item({
			"id": iid,
			"type": "panel",
			"x": pos.x,
			"y": pos.y,
			"width": 66.0,
			"height": 112.0,
			"is_virtual": true,
			"specs": {"name": "PV-%02d" % (i + 1), "wmp": 220.0, "voc": 37.5, "cost": 0.0},
		})
	model.add_item({
		"id": GraphVirtualIds.V_CTRL_ID,
		"type": "controller",
		"x": 140.0,
		"y": -120.0,
		"width": 140.0,
		"height": 120.0,
		"is_virtual": true,
		"specs": {"name": "Hybrid Inverter", "max_voc": 150.0, "max_pv_watts": 3960.0},
	})
	model.add_item({
		"id": GraphVirtualIds.V_BATTERY_ID,
		"type": "battery",
		"x": 340.0,
		"y": -100.0,
		"width": 100.0,
		"height": 136.0,
		"is_virtual": true,
		"specs": {"name": "Battery Bank", "kwh": 16.0, "voltage": 48.0},
	})


func _test_legacy_strip() -> int:
	var model: GraphModel = GraphModelScript.new()
	_populate_legacy_virtual_graph(model)
	if not GraphVirtualIds.is_legacy_auto_virtual_only(model):
		push_error("legacy strip setup: should detect auto-virtual-only graph")
		return 1
	if not GraphVirtualIds.strip_legacy_virtual_solar(model):
		push_error("legacy strip: strip returned false")
		return 1
	if not model.items.is_empty():
		push_error("legacy strip: items remain after strip")
		return 1
	var bridge := SolarBridgeScript.new()
	bridge.setup(model, null)
	bridge.suppressed_ids = GraphVirtualIds.suppression_dictionary()
	bridge.tick(1.0)
	if not model.items.is_empty():
		push_error("legacy strip: bridge recreated virtual stack after strip+suppress")
		return 1
	return 0


func _test_bridge_no_autoseed() -> int:
	var model: GraphModel = GraphModelScript.new()
	var bridge := SolarBridgeScript.new()
	bridge.setup(model, null)
	bridge.suppressed_ids = GraphVirtualIds.suppression_dictionary()
	bridge.tick(1.0)
	if not model.items.is_empty():
		push_error("bridge no-autoseed: created items on blank graph")
		return 1
	return 0


func _test_starshade_idempotent() -> int:
	var model: GraphModel = GraphModelScript.new()
	if not StarShadeGraphSeeder.seed_graph(model, 18, 220.0, "test_tag"):
		push_error("starshade seed: first seed failed")
		return 1
	var first_count: int = model.items.size()
	if not StarShadeGraphSeeder.has_graph_content(model):
		push_error("starshade seed: missing starshade content after seed")
		return 1
	if StarShadeGraphSeeder.seed_graph(model, 18, 220.0, "test_tag"):
		push_error("starshade seed: second seed should be skipped")
		return 1
	if model.items.size() != first_count:
		push_error("starshade seed: item count changed on re-seed")
		return 1
	return 0


## Full 18-panel StarShade seed must wire every panel into a 3S×6P topology
## (regression: missing `+ s * series` left only 9 panels connected).
##
## The seeder now realizes the StarShade COMPONENT tree instead of seeding flat
## nodes, so the topology lives one level down: panels sit in the PV-array
## instance's child scope (walk the nesting tree, not the root scope), the six
## 3-panel strings parallel onto string 0's terminals rather than each running
## its own pair into a controller, and the array's exposed PV bus is what feeds
## the hybrid inverter's charge controller.
func _test_starshade_full_wiring() -> int:
	var model: GraphModel = GraphModelScript.new()
	if not StarShadeGraphSeeder.seed_graph(model, 18, 220.0, "wire_tag"):
		push_error("starshade wiring: seed failed")
		return 1
	var panel_ids: Dictionary = {}
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if str(item.get("type", "")) == "panel":
			panel_ids[str(item.get("id", ""))] = true
	if panel_ids.size() != 18:
		push_error("starshade wiring: expected 18 panels got %d" % panel_ids.size())
		return 1
	var wired: Dictionary = {}
	var series_links := 0
	var parallel_pos := 0
	var parallel_neg := 0
	for conn: Dictionary in model.connections:
		var a := str(conn.get("source_item_id", ""))
		var b := str(conn.get("target_item_id", ""))
		if not (panel_ids.has(a) and panel_ids.has(b)):
			continue
		wired[a] = true
		wired[b] = true
		var ah := str(conn.get("source_handle_id", ""))
		var bh := str(conn.get("target_handle_id", ""))
		# Series string links: panel+ → panel−
		if ah == "positive" and bh == "negative":
			series_links += 1
		# Parallel bus: another string's end tied onto string 0's matching end.
		elif ah == "positive" and bh == "positive":
			parallel_pos += 1
		elif ah == "negative" and bh == "negative":
			parallel_neg += 1
	if wired.size() != 18:
		push_error("starshade wiring: only %d/18 panels have PV connections" % wired.size())
		return 1
	# 6 strings × 2 series links each = 12
	if series_links != 12:
		push_error("starshade wiring: expected 12 series links got %d" % series_links)
		return 1
	# Strings 1..5 parallel onto string 0 — 5 links per polarity. (A 6th pair
	# would mean string 0 shorted onto itself; fewer means a dangling string.)
	if parallel_pos != 5 or parallel_neg != 5:
		push_error("starshade wiring: expected 5+ / 5− parallel bus links got %d+ / %d−" % [
			parallel_pos, parallel_neg])
		return 1
	if not _starshade_array_feeds_inverter(model):
		push_error("starshade wiring: array PV bus does not reach the hybrid inverter")
		return 1
	return 0


## True when the realized PV-array instance's exposed pv_pos/pv_neg ports are
## both wired to the realized hybrid-inverter instance.
func _starshade_array_feeds_inverter(model: GraphModel) -> bool:
	var array_id := ""
	var hinv_id := ""
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		var did := str((item.get("specs", {}) as Dictionary).get("definition_id", ""))
		if did == "starshade_solar_array":
			array_id = str(item.get("id", ""))
		elif did == "starshade_hybrid_inverter":
			hinv_id = str(item.get("id", ""))
	if array_id.is_empty() or hinv_id.is_empty():
		return false
	var pos := false
	var neg := false
	for conn: Dictionary in model.connections:
		if str(conn.get("source_item_id", "")) != array_id:
			continue
		if str(conn.get("target_item_id", "")) != hinv_id:
			continue
		match str(conn.get("source_handle_id", "")):
			"pv_pos": pos = true
			"pv_neg": neg = true
	return pos and neg


## panel_count / panel_watts are player-facing — the StarShade edit modal's
## spinboxes and an imported LinkageLab bundle's solar.panelCount/panelWatts both
## reach reseed_graph. Regression: realizing a FIXED 18 × 220 W component template
## ignored both, so Re-seed silently did nothing (and reseed_graph only clears the
## instance, so the stale array definition had to be re-registered too).
func _test_starshade_reseed_resizes() -> int:
	var model: GraphModel = GraphModelScript.new()
	if not StarShadeGraphSeeder.seed_graph(model, 24, 400.0, "resize_tag"):
		push_error("starshade resize: first seed failed")
		return 1
	if _check_seeded_panels(model, 24, 400.0, "first seed") != 0:
		return 1
	if not StarShadeGraphSeeder.reseed_graph(model, 9, 100.0, "resize_tag"):
		push_error("starshade resize: reseed failed")
		return 1
	if _check_seeded_panels(model, 9, 100.0, "reseed") != 0:
		return 1
	# A count that is not a multiple of the 3-panel string still yields exactly
	# that many panel nodes (the trailing partial string is laid out, not dropped).
	if not StarShadeGraphSeeder.reseed_graph(model, 20, 220.0, "resize_tag"):
		push_error("starshade resize: partial-string reseed failed")
		return 1
	if _check_seeded_panels(model, 20, 220.0, "partial string") != 0:
		return 1
	return 0


## Every seeded panel (across the component's nested scopes) must be present in
## the requested quantity and at the requested watts. A leftover instance from a
## previous seed shows up here as an inflated count.
func _check_seeded_panels(model: GraphModel, want_count: int, want_watts: float,
		label: String) -> int:
	var got := StarShadeGraphSeeder.count_panels(model)
	if got != want_count:
		push_error("starshade resize (%s): expected %d panels got %d" % [
			label, want_count, got])
		return 1
	for item: Dictionary in GraphNesting.walk_items(model, "root"):
		if str(item.get("type", "")) != "panel":
			continue
		var wmp := float((item.get("specs", {}) as Dictionary).get("wmp", 0.0))
		if absf(wmp - want_watts) > 0.01:
			push_error("starshade resize (%s): expected %.0f W panels got %.0f W" % [
				label, want_watts, wmp])
			return 1
	return 0


## Manual series wiring must allow positive ↔ negative (port type check).
func _test_dc_series_polarity() -> int:
	var canvas_script: GDScript = load("res://system_graph/graph_canvas.gd") as GDScript
	if canvas_script == null:
		push_error("dc polarity: could not load graph_canvas.gd")
		return 1
	var canvas: Object = canvas_script.new()
	if canvas == null or not canvas.has_method("_polarity_compatible"):
		push_error("dc polarity: canvas missing _polarity_compatible")
		return 1
	if not bool(canvas.call("_polarity_compatible", "positive", "negative")):
		push_error("dc polarity: positive→negative should be allowed for series")
		return 1
	if not bool(canvas.call("_polarity_compatible", "negative", "positive")):
		push_error("dc polarity: negative→positive should be allowed for series")
		return 1
	if not bool(canvas.call("_polarity_compatible", "positive", "positive")):
		push_error("dc polarity: same-polarity positive should still be allowed")
		return 1
	canvas.free()
	return 0


func _test_aggregate_sync() -> int:
	var model: GraphModel = GraphModelScript.new()
	StarShadeGraphSeeder.seed_graph(model, 6, 200.0, "agg_test")
	if StarShadeGraphSeeder.count_panels(model) != 6:
		push_error("aggregate sync: expected 6 panels got %d" % StarShadeGraphSeeder.count_panels(model))
		return 1
	if absf(StarShadeGraphSeeder.total_battery_kwh(model) - 5.12) > 0.01:
		push_error("aggregate sync: expected 5.12 kWh bank got %.2f" % StarShadeGraphSeeder.total_battery_kwh(model))
		return 1
	return 0


## add_item must never create a second row for an id that already exists — a
## duplicate row renders as an overlapping twin that "splits" on drag (only the
## last-indexed copy moves). Merge into the existing row instead.
func _test_unique_item_ids() -> int:
	var model: GraphModel = GraphModelScript.new()
	model.add_item({"id": "n1", "type": "controller", "x": 10.0, "y": 20.0})
	model.add_item({"id": "n1", "type": "controller", "x": 99.0, "y": 88.0})
	if model.items.size() != 1:
		push_error("unique ids: duplicate add created %d rows (expected 1)" % model.items.size())
		return 1
	# The merge should update fields on the single surviving row.
	var it := model.get_item("n1")
	if absf(float(it.get("x", 0.0)) - 99.0) > 0.001 or absf(float(it.get("y", 0.0)) - 88.0) > 0.001:
		push_error("unique ids: merged row did not take updated position")
		return 1
	# get_items_in_scope (drives rendering + hit-test) must list it exactly once.
	var count := 0
	for row: Dictionary in model.get_items_in_scope("root"):
		if str(row.get("id", "")) == "n1":
			count += 1
	if count != 1:
		push_error("unique ids: scope query returned id 'n1' %d times" % count)
		return 1
	return 0


## deserialize must drop duplicate-id rows a corrupt/legacy save may carry, so
## loading such a save self-heals rather than propagating the drag-split ghost.
func _test_deserialize_dedup() -> int:
	var model: GraphModel = GraphModelScript.new()
	model.deserialize({
		"items": [
			{"id": "dup", "type": "battery", "x": 0.0, "y": 0.0, "scope_id": "root"},
			{"id": "dup", "type": "battery", "x": 500.0, "y": 500.0, "scope_id": "root"},
			{"id": "unique", "type": "panel", "x": 1.0, "y": 1.0, "scope_id": "root"},
		],
		"connections": [],
	})
	if model.items.size() != 2:
		push_error("deserialize dedup: expected 2 rows got %d" % model.items.size())
		return 1
	var dup_rows := 0
	for row: Dictionary in model.items:
		if str(row.get("id", "")) == "dup":
			dup_rows += 1
	if dup_rows != 1:
		push_error("deserialize dedup: id 'dup' survived %d times" % dup_rows)
		return 1
	# First occurrence wins (position 0,0), not the later 500,500 row.
	var kept := model.get_item("dup")
	if absf(float(kept.get("x", -1.0))) > 0.001:
		push_error("deserialize dedup: kept the wrong duplicate row")
		return 1
	return 0


func _test_puzzle_starter_idempotent() -> int:
	var model: GraphModel = GraphModelScript.new()
	if not PuzzleStarterScript.seed_graph(model, 1):
		push_error("puzzle starter: first seed failed")
		return 1
	var first_count: int = model.items.size()
	if not PuzzleStarterScript.has_starter_content(model):
		push_error("puzzle starter: missing starter content after seed")
		return 1
	if not PuzzleStarterScript.has_habitat(model):
		push_error("puzzle starter: missing habitat after seed")
		return 1
	if PuzzleStarterScript.seed_graph(model, 1):
		push_error("puzzle starter: second seed should be skipped")
		return 1
	if model.items.size() != first_count:
		push_error("puzzle starter: item count changed on re-seed")
		return 1
	var power_model: GraphModel = GraphModelScript.new()
	if not PuzzleStarterScript.seed_graph(power_model, 1, true):
		push_error("puzzle starter power-only: seed failed")
		return 1
	var kinds: Array = []
	for it: Dictionary in power_model.items:
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		kinds.append(str(sp.get("resource_kind", sp.get("role", ""))))
	if kinds.has("water") or kinds.has("food"):
		push_error("puzzle starter power-only: must not seed water/food")
		return 1
	return 0

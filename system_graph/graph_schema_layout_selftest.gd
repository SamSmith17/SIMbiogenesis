extends SceneTree

## GraphSchemaLayout (offline): every arrangement places every card, none
## overlap, and each does what it says — the ring puts stores inside and
## machines outside with the people in the middle; clusters keep each
## system's cards together and the systems apart; swimlanes give each system
## its own lane with columns in flow order; the grid is a grid. Plus the
## force layout's anchors (Live layout holding an arrangement): a node pulled
## off its slot comes back, and its wired neighbour moves while it is held.
##
##   Godot --headless --path . --script system_graph/graph_schema_layout_selftest.gd

const EXPECTED_CHECKS := 26

var _checks := 0
var _fails := 0


func _initialize() -> void:
	var g := _settlement()
	var items: Array = g["items"]
	var conns: Array = g["conns"]
	var side := Callable(self, "_port_side")
	for schema in GraphSchemaLayout.SCHEMAS:
		var res := GraphSchemaLayout.arrange(schema, items, conns, side, {"spacing": 40.0})
		var pos: Dictionary = res["positions"]
		_check("%s: every card placed" % schema, pos.size() == items.size(), "%d of %d" % [pos.size(), items.size()])
		var ov := _overlaps(items, pos)
		_check("%s: no two cards overlap" % schema, ov == 0, "%d overlapping pairs" % ov)
	_test_ring(items, conns, side)
	_test_clusters(items, conns, side)
	_test_swimlanes(items, conns, side)
	_test_domains(items, conns)
	_test_anchors()
	var ok := _fails == 0 and _checks == EXPECTED_CHECKS
	if _checks != EXPECTED_CHECKS:
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("SCHEMA LAYOUT SELFTEST %s  (%d checks, %d failed)" % ["PASS" if ok else "FAIL", _checks, _fails])
	quit(0 if ok else 1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: %s  %s" % [label, detail])


## Inputs on the top edge, outputs on the bottom (the graph's own rule).
func _port_side(_item: Dictionary, handle_id: String) -> float:
	if handle_id.begins_with("res_in") or handle_id == "input" or handle_id == "power_in":
		return 0.0
	if handle_id.begins_with("res_out") or handle_id == "output" or handle_id == "acOutput":
		return 1.0
	return NAN


func _item(iid: String, type: String, specs: Dictionary, w := 140.0, h := 110.0) -> Dictionary:
	return {"id": iid, "type": type, "x": 0.0, "y": 0.0, "width": w, "height": h, "specs": specs}


func _wire(a: String, b: String, kind: String, ah := "res_out_0", bh := "res_in_0") -> Dictionary:
	return {"source_item_id": a, "source_handle_id": ah, "target_item_id": b, "target_handle_id": bh,
		"polarity": "resource", "resource_type": kind}


## A small settlement: a power train, a water train, food, people, fuel.
func _settlement() -> Dictionary:
	var items: Array = [
		_item("ctl", "controller", {}), _item("bat", "battery", {}),
		_item("cistern", "resource", {"resource_kind": "water"}, 90.0, 100.0),
		_item("filter", "processor", {}), _item("potable", "resource", {"resource_kind": "water"}, 90.0, 100.0),
		_item("hab", "processor", {"role": "habitat"}, 150.0, 150.0),
		_item("grey", "resource", {"resource_kind": "greywater"}, 90.0, 100.0),
		_item("gfilter", "processor", {}),
		_item("pantry", "resource", {"resource_kind": "food"}, 90.0, 100.0),
		_item("bed", "processor", {}), _item("nutr", "resource", {"resource_kind": "nutrients"}, 90.0, 100.0),
		_item("compost", "processor", {}),
		_item("gas", "resource", {"resource_kind": "woodgas"}, 90.0, 100.0), _item("genset", "processor", {}),
	]
	# Spread them out a little so nothing starts stacked.
	for i in items.size():
		(items[i] as Dictionary)["x"] = float(i % 4) * 160.0
		(items[i] as Dictionary)["y"] = float(i / 4) * 140.0
	var conns: Array = [
		{"source_item_id": "ctl", "source_handle_id": "batteryPositive", "target_item_id": "bat",
			"target_handle_id": "positive", "polarity": "positive"},
		_wire("cistern", "filter", "water", "output"), _wire("filter", "potable", "water", "res_out_0", "input"),
		_wire("potable", "hab", "water", "output"), _wire("hab", "grey", "greywater", "res_out_0", "input"),
		_wire("grey", "gfilter", "greywater", "output"),
		_wire("pantry", "hab", "food", "output", "res_in_1"),
		_wire("cistern", "bed", "water", "output"), _wire("nutr", "bed", "nutrients", "output", "res_in_1"),
		_wire("bed", "pantry", "food", "res_out_0", "input"),
		_wire("compost", "nutr", "nutrients", "res_out_0", "input"),
		_wire("gas", "genset", "woodgas", "output"),
	]
	return {"items": items, "conns": conns}


func _sizes(items: Array) -> Dictionary:
	var out := {}
	for it in items:
		var d: Dictionary = it
		out[str(d["id"])] = Vector2(float(d["width"]), float(d["height"]))
	return out


func _overlaps(items: Array, pos: Dictionary) -> int:
	var sz := _sizes(items)
	var ids: Array = pos.keys()
	var n := 0
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a := Rect2(pos[ids[i]] as Vector2, sz[ids[i]] as Vector2)
			var b := Rect2(pos[ids[j]] as Vector2, sz[ids[j]] as Vector2)
			if a.grow(-1.0).intersects(b.grow(-1.0)):
				n += 1
	return n


func _centre(pos: Dictionary, sz: Dictionary, iid: String) -> Vector2:
	return (pos[iid] as Vector2) + (sz[iid] as Vector2) * 0.5


func _test_ring(items: Array, conns: Array, side: Callable) -> void:
	var res := GraphSchemaLayout.ring(items, conns, side, {"spacing": 40.0})
	var pos: Dictionary = res["positions"]
	var sz := _sizes(items)
	var ring: Dictionary = res["ring"]
	var c: Vector2 = ring["centre"]
	var r_out := float(ring["r_outer"])
	var r_in := float(ring["r_inner"])
	var stores_inside := true
	var machines_out := true
	for it in items:
		var d: Dictionary = it
		var iid := str(d["id"])
		var dist := _centre(pos, sz, iid).distance_to(c)
		if iid == "hab":
			continue
		if GraphSchemaLayout.is_store(d):
			stores_inside = stores_inside and absf(dist - r_in) < 2.0
		else:
			machines_out = machines_out and absf(dist - r_out) < 2.0
	_check("ring: every store on the inner ring", stores_inside)
	_check("ring: every machine on the outer ring", machines_out)
	_check("ring: inner ring inside the outer", r_in < r_out, "%.0f vs %.0f" % [r_in, r_out])
	_check("ring: the people in the middle", _centre(pos, sz, "hab").distance_to(c) < r_in * 0.5)
	# A store sits toward the machines wired to it: the nutrient store is
	# nearer the bed and the compost than the genset is.
	var n := _centre(pos, sz, "nutr")
	_check("ring: a store sits by its machines",
		n.distance_to(_centre(pos, sz, "compost")) < n.distance_to(_centre(pos, sz, "genset")))


func _test_clusters(items: Array, conns: Array, side: Callable) -> void:
	var res := GraphSchemaLayout.clusters(items, conns, side, {"spacing": 40.0})
	var pos: Dictionary = res["positions"]
	var sz := _sizes(items)
	var boxes := {}
	for reg in (res["regions"] as Array):
		var rd: Dictionary = reg
		var box := Rect2()
		var first := true
		for iid in (rd["ids"] as Array):
			var r := Rect2(pos[iid] as Vector2, sz[iid] as Vector2)
			box = r if first else box.merge(r)
			first = false
		boxes[str(rd["domain"])] = box
	_check("clusters: power, water, food, fuel and people each have an area",
		boxes.has("power") and boxes.has("water") and boxes.has("food") and boxes.has("fuel") and boxes.has("people"),
		str(boxes.keys()))
	var apart := true
	var keys: Array = boxes.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			if (boxes[keys[i]] as Rect2).intersects(boxes[keys[j]] as Rect2):
				apart = false
	_check("clusters: the systems' areas do not overlap", apart)


func _test_swimlanes(items: Array, conns: Array, side: Callable) -> void:
	var res := GraphSchemaLayout.swimlanes(items, conns, side, {"spacing": 40.0})
	var pos: Dictionary = res["positions"]
	var sz := _sizes(items)
	# Water lane: cistern -> filter -> potable left to right.
	_check("swimlanes: flow reads left to right",
		(pos["cistern"] as Vector2).x < (pos["filter"] as Vector2).x
		and (pos["filter"] as Vector2).x < (pos["potable"] as Vector2).x)
	# A lane is a horizontal band: the water lane and the power lane do not
	# share a height.
	var w_top := minf((pos["cistern"] as Vector2).y, (pos["filter"] as Vector2).y)
	var p_bot := maxf((pos["ctl"] as Vector2).y + (sz["ctl"] as Vector2).y, (pos["bat"] as Vector2).y + (sz["bat"] as Vector2).y)
	_check("swimlanes: power above water, in its own lane", p_bot <= w_top)
	var layers := GraphSchemaLayout.flow_layers(items, conns, side)
	_check("flow layers: a filter is after its tank", int(layers["filter"]) > int(layers["cistern"]))


func _test_domains(items: Array, conns: Array) -> void:
	var by := {}
	for it in items:
		by[str((it as Dictionary)["id"])] = it
	_check("domain: a tank by what it holds", GraphSchemaLayout.domain_of(by["cistern"], conns) == "water")
	_check("domain: a habitat is people", GraphSchemaLayout.domain_of(by["hab"], conns) == "people")
	_check("domain: a machine by its resource wires", GraphSchemaLayout.domain_of(by["genset"], conns) == "fuel")
	_check("domain: a controller is power", GraphSchemaLayout.domain_of(by["ctl"], conns) == "power")


func _test_anchors() -> void:
	var items: Array = [_item("a", "processor", {}), _item("b", "processor", {})]
	(items[1] as Dictionary)["x"] = 400.0
	var conns: Array = [_wire("a", "b", "water")]
	var f := GraphForceLayout.new()
	f.setup(items, conns, Callable(self, "_port_side"))
	f.set_anchors({"a": Vector2(0, 0), "b": Vector2(400, 0)})
	_check("anchors: on", f.is_anchored())
	# Hold b far off and step: a follows on its wire, a little.
	f.set_pinned("b", true)
	f.set_center("b", Vector2(1400, 55))
	f.reheat(0.3)
	for i in 6:
		f.step()
	var a_moved := f.center_of("a").x - 70.0
	_check("anchors: a held node's neighbour follows", a_moved > 2.0, "moved %.1f px" % a_moved)
	# Let go: b keeps its new slot, a goes back to its own.
	f.set_pinned("b", false)
	f.set_anchor_center("b", f.center_of("b"))
	f.reheat(0.3)
	f.run_to_rest(400)
	_check("anchors: the neighbour springs back", absf(f.center_of("a").x - 70.0) < 4.0,
		"a at %.1f" % f.center_of("a").x)
	_check("anchors: the dropped node keeps its new place", absf(f.center_of("b").x - 1400.0) < 4.0,
		"b at %.1f" % f.center_of("b").x)

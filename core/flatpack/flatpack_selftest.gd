extends SceneTree

## Flat-pack furniture designer (core/flatpack/). Offline:
##   godot --headless --path . --script core/flatpack/flatpack_selftest.gd
## Run `--import` first after adding a class_name here.
##
## The anchor is the real sample (testdata/playatech_daybed_ref.json, measured
## from Playa Tech.glb by tools/flatpack_glb_reference.py): the sofa template
## at the sample's sizes, zero clearance and no relief must give its twelve
## parts, its slots where the sample has them, and three 4×8 sheets.

const EXPECTED_CHECKS := 96
const REF := "res://core/flatpack/testdata/playatech_daybed_ref.json"

var _checks := 0
var _fails := 0


func _ok(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		print("  FAIL: ", what)


func _near(a: float, b: float, eps: float = 0.01) -> bool:
	return absf(a - b) <= eps


func _initialize() -> void:
	_test_profile()
	_test_relief()
	_test_holes()
	_test_joints()
	_test_sample_parity()
	_test_router_sofa()
	_test_all_types()
	_test_wedges_and_overrides()
	_test_nesting()
	_test_cam()
	_test_spec()
	_test_builder()
	_test_packing()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	print("FLATPACK SELFTEST %s  (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)


# ---------------------------------------------------------------------------

func _test_profile() -> void:
	var rr := FlatpackProfile.ring_from_base(FlatpackTemplates.rect(10, 5),
		PackedFloat64Array([1, 1, 1, 1]), [], {"relief": "none"})
	_ok(_near(FlatpackProfile.area(rr["ring"]), 50.0 - (4.0 - PI), 0.02),
		"a rounded rectangle has the area of its fillets (%.3f)" % FlatpackProfile.area(rr["ring"]))
	_ok(_near(FlatpackProfile.perimeter(rr["ring"]), 30.0 - 8.0 + TAU, 0.001), "its perimeter counts true arc lengths")
	var c := FlatpackProfile.arc_center(Vector2(1, 0), Vector2(-1, 0), 1.0)
	_ok(c.length() < 1e-6, "a bulge of 1 is a half circle centred on the chord")
	var circ := FlatpackProfile.circle_ring(Vector2(3, 3), 2.0)
	_ok(_near(FlatpackProfile.area(circ), PI * 4.0, 0.06), "a circle ring is two half arcs (tessellated)")
	_ok(FlatpackProfile.is_ccw(FlatpackProfile.tessellate(circ)), "and runs counter-clockwise")
	var notch := FlatpackProfile.make_notch(0, 6.0, 0.5, 3.0)
	var nr := FlatpackProfile.ring_from_base(FlatpackTemplates.rect(12, 6), PackedFloat64Array(),
		[notch], {"relief": "none"})
	_ok(_near(FlatpackProfile.area(nr["ring"]), 72.0 - 1.5, 0.001), "a slot removes width × depth")
	_ok(FlatpackProfile.inside_corner_count(nr["ring"]) == 2, "a plain slot has two inside corners")
	# A fillet next to a slot shrinks to fit.
	var big := FlatpackProfile.ring_from_base(FlatpackTemplates.rect(12, 6),
		PackedFloat64Array([4, 0, 0, 0]), [FlatpackProfile.make_notch(0, 2.0, 0.5, 2.0)], {"relief": "none"})
	_ok(FlatpackProfile.is_simple(FlatpackProfile.tessellate(big["ring"])),
		"a corner radius beside a slot shrinks rather than crossing it")
	var mir := FlatpackProfile.mirror_ring_x(nr["ring"])
	_ok(_near(FlatpackProfile.area(mir), FlatpackProfile.area(nr["ring"]), 1e-4)
		and FlatpackProfile.is_ccw(FlatpackProfile.tessellate(mir)), "mirroring keeps area and winding")
	# An oblique slot opens wider along the edge than it is across.
	var ob := FlatpackProfile.ring_from_base(FlatpackTemplates.rect(12, 6), PackedFloat64Array(),
		[FlatpackProfile.make_notch(0, 6.0, 0.5, 3.0, Vector2(0.5, 0.866))], {"relief": "none"})
	_ok(_near(FlatpackProfile.area(ob["ring"]), 72.0 - 1.5, 0.01) and FlatpackProfile.is_simple(
		FlatpackProfile.tessellate(ob["ring"])), "an angled slot keeps its width across its axis")


func _test_relief() -> void:
	var base := FlatpackTemplates.rect(12, 6)
	var notch := FlatpackProfile.make_notch(0, 6.0, 0.5, 3.0)
	var none := FlatpackProfile.ring_from_base(base, PackedFloat64Array(), [notch], {"relief": "none"})
	var dog := FlatpackProfile.ring_from_base(base, PackedFloat64Array(), [notch],
		{"relief": "dogbone", "bit_r": 0.13})
	var tb := FlatpackProfile.ring_from_base(base, PackedFloat64Array(), [notch],
		{"relief": "tbone", "bit_r": 0.13})
	var arcs := 0
	var halfs := 0
	for b in (dog["ring"]["bulge"] as PackedFloat64Array):
		if absf(b) > 1e-6:
			arcs += 1
			if _near(absf(b), 1.0, 1e-3):
				halfs += 1
	_ok(arcs == 2 and halfs == 2, "dogbones are two half-circle arcs (%d arcs)" % arcs)
	_ok(FlatpackProfile.area(dog["ring"]) < FlatpackProfile.area(none["ring"]) - 0.01,
		"dogbones remove a little more than the plain slot")
	_ok(FlatpackProfile.is_simple(FlatpackProfile.tessellate(dog["ring"], 0.02)), "the dogboned outline is simple")
	# T-bones overcut sideways: no point of the outline is deeper than the slot.
	var deepest := INF
	for q in FlatpackProfile.tessellate(tb["ring"], 0.02):
		deepest = minf(deepest, 6.0 - q.y) if q.y > 0.0 else deepest
	var max_y := 0.0
	for q in FlatpackProfile.tessellate(tb["ring"], 0.02):
		if q.y < 5.0:
			max_y = maxf(max_y, q.y)
	_ok(max_y <= 3.0 + 1e-4, "T-bones never cut below the slot's bottom (%.4f)" % max_y)
	var narrow := FlatpackProfile.ring_from_base(base, PackedFloat64Array(),
		[FlatpackProfile.make_notch(0, 6.0, 0.3, 3.0)], {"relief": "dogbone", "bit_r": 0.13})
	_ok(not (narrow["warnings"] as Array).is_empty(), "a slot too narrow for dogbones says so and uses T-bones")


func _test_holes() -> void:
	var h := FlatpackProfile.hole_ring(Vector2(5, 5), Vector2(1, 0), 3.0, 0.5, {"relief": "none"})
	var poly := FlatpackProfile.tessellate(h)
	_ok(not FlatpackProfile.is_ccw(poly), "holes wind clockwise")
	_ok(_near(FlatpackProfile.area(h), 1.5, 1e-4), "a mortise is length × width")
	var hd := FlatpackProfile.hole_ring(Vector2(5, 5), Vector2(1, 0), 3.0, 0.5, {"relief": "dogbone", "bit_r": 0.13})
	var arcs := 0
	for b in (hd["bulge"] as PackedFloat64Array):
		if absf(b) > 1e-6:
			arcs += 1
	_ok(arcs == 4, "a mortise gets a dogbone in each corner")


func _two_slabs() -> Array:
	var a := {"id": "a", "name": "A", "base": FlatpackTemplates.rect(20, 10),
		"corner_r": PackedFloat64Array(), "frame": FlatpackTemplates.frame_of(Vector3(0, 0, 5), Vector3.RIGHT, Vector3.UP),
		"thickness": 0.5}
	var b := {"id": "b", "name": "B", "base": FlatpackTemplates.rect(10, 10),
		"corner_r": PackedFloat64Array(), "frame": FlatpackTemplates.frame_of(Vector3(8, 0, 0),
			Vector3(0, 0, 1), Vector3.UP), "thickness": 0.5}
	return [a, b]


func _test_joints() -> void:
	var parts := _two_slabs()
	var j := {"id": "x", "a": "a", "b": "b", "kind": "cross_lap", "open": Vector3.UP, "ratio": 0.5}
	var res := FlatpackJoints.resolve(parts, [j], [], {"thickness": 0.5, "clearance": 0.01})
	var na: Array = parts[0]["notches"]
	var nb: Array = parts[1]["notches"]
	_ok(na.size() == 1 and nb.size() == 1, "a cross-lap slots both parts")
	_ok(_near(float(na[0]["depth"]), 5.0) and _near(float(nb[0]["depth"]), 5.0), "each takes half of the 10\" overlap")
	_ok(_near(float(na[0]["width"]), 0.52), "slot width = the other sheet + clearance each side")
	_ok(int(na[0]["edge"]) == 2 and int(nb[0]["edge"]) == 0, "A opens toward `open` (up), B from below")
	var design := {"parts": parts, "poses": []}
	for p in parts:
		p["ring"] = FlatpackProfile.ring_from_base(p["base"], p["corner_r"], p["notches"], {"relief": "none"})["ring"]
		p["hole_rings"] = []
	_ok(FlatpackJoints.interference(design, "").is_empty(), "the slotted pair goes together")
	for p in parts:
		p["ring"] = FlatpackProfile.rect_ring(float((p["base"] as PackedVector2Array)[1].x),
			float((p["base"] as PackedVector2Array)[2].y))
	_ok(FlatpackJoints.interference(design, "").size() == 1, "without slots the pair clashes")
	# Parallel sheets cannot be slotted.
	var p2 := _two_slabs()
	p2[1]["frame"] = FlatpackTemplates.frame_of(Vector3(0, 0, 9), Vector3.RIGHT, Vector3.UP)
	var r2 := FlatpackJoints.resolve(p2, [j], [], {"thickness": 0.5})
	_ok(not (r2["warnings"] as Array).is_empty(), "parallel parts are refused with a reason")
	_ok(FlatpackJoints.plane_line(p2[0]["frame"], p2[1]["frame"]).is_empty(), "and have no common line")


func _sample_spec() -> Dictionary:
	var s := FlatpackSpec.default_spec("sofa")
	var p: Dictionary = s["params"]
	p["frame_h"] = 12.0
	p["deck_depth"] = 36.0
	p["arm_h"] = 24.0
	p["brace_len"] = 24.0
	p["brace_w"] = 12.0
	s["material"]["nominal"] = "custom"
	s["material"]["thickness"] = 0.5
	s["machine"]["clearance"] = 0.0
	s["machine"]["relief"] = "none"
	s["machine"]["spacing"] = 0.0
	s["machine"]["margin"] = 0.0
	s["style"]["foot_arch"] = false
	s["name"] = "PlayaTech daybed"
	return s


func _centres(notches: Array, edge: int) -> Array:
	var out: Array = []
	for n in notches:
		if int(n["edge"]) == edge:
			out.append(float(n["at"]))
	out.sort()
	return out


func _test_sample_parity() -> void:
	var ref: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REF))
	_ok(not ref.is_empty() and int(ref.get("part_count", 0)) == 12, "the sample fixture loads (12 parts)")
	var d := FlatpackDesign.solve(_sample_spec())
	var groups := {}
	for p in d["parts"]:
		groups[str(p["group"])] = int(groups.get(str(p["group"]), 0)) + 1
	_ok((d["parts"] as Array).size() == 12, "the sample sofa has 12 parts")
	var expect := {"Long rail": [3, 96.0, 12.0], "Cross rail": [3, 48.0, 12.0], "Arm": [2, 48.0, 24.0],
		"Deck": [1, 96.0, 36.0], "Back": [1, 96.0, 24.0], "Back brace": [2, 24.0, 12.0]}
	var ref_sizes := {"LONG RAIL": "Long rail", "SUPPORT RAIL": "Cross rail", "Side Board": "Arm",
		"Cusion Bed Support": "Deck", "Back Panel": "Back", "Back Support": "Back brace"}
	var sizes_ok := true
	for rp in ref["parts"]:
		var g := str(ref_sizes.get(str(rp["group"]), ""))
		var e: Array = expect.get(g, [0, 0.0, 0.0])
		var dims := [maxf(float(rp["w"]), float(rp["h"])), minf(float(rp["w"]), float(rp["h"]))]
		if not (_near(dims[0], float(e[1]), 0.01) and _near(dims[1], float(e[2]), 0.01)):
			sizes_ok = false
	_ok(sizes_ok, "every sample part maps onto a template group of the same size")
	var counts_ok := true
	for g in expect:
		if int(groups.get(g, 0)) != int((expect[g] as Array)[0]):
			counts_ok = false
	_ok(counts_ok, "and the quantities match (%s)" % str(groups))
	var rail := FlatpackDesign.part(d, "long_rail_0")
	var rc := _centres(rail["notches"], 2)
	var want := [6.25, 24.25, 48.0, 71.75, 89.75]
	var ok_r := rc.size() == 5
	for i in mini(rc.size(), 5):
		# The template measures along the rail's top edge from the far end.
		ok_r = ok_r and _near(96.0 - float(rc[4 - i]), float(want[i]), 0.01)
	_ok(ok_r, "long-rail slots sit at 6¼, 24¼, 48, 71¾, 89¾ (%s)" % str(rc))
	var ref_rail: Array = []
	for n in ref["parts"][3]["notches"]:
		ref_rail.append((float(n["from"]) + float(n["to"])) * 0.5)
	var ok_ref := ref_rail.size() == 5
	for i in mini(ref_rail.size(), 5):
		ok_ref = ok_ref and _near(float(ref_rail[i]), float(want[i]), 0.3)
	_ok(ok_ref, "…which is where the sample's are, within 0.3\" (%s)" % str(ref_rail))
	var depth_ok := true
	for n in rail["notches"]:
		depth_ok = depth_ok and _near(float(n["depth"]), 6.0) and _near(float(n["width"]), 0.5)
	_ok(depth_ok, "each rail slot is 1/2\" wide and 6\" deep, half the rail")
	var cr := FlatpackDesign.part(d, "cross_rail_0")
	var cc := _centres(cr["notches"], 0)
	_ok(cc.size() == 3 and _near(float(cc[0]), 4.25) and _near(float(cc[1]), 24.0) and _near(float(cc[2]), 43.75),
		"cross-rail slots at 4¼, 24, 43¾ (sample 4¼, 24.04, 43¾): %s" % str(cc))
	var arm := FlatpackDesign.part(d, "arm_0")
	var deck_slot := 0.0
	var daybed_slot := 0.0
	for n in arm["notches"]:
		if int(n["edge"]) == 1:
			deck_slot = float(n["depth"])
		if int(n["edge"]) == 3:
			daybed_slot = float(n["depth"])
	_ok(_near(deck_slot, 12.0) and _near(daybed_slot, 9.0),
		"the arm's deck slot is 12\" and its daybed slot 9\" deep, as the sample's (%.2f, %.2f)" % [deck_slot, daybed_slot])
	_ok(_centres(arm["notches"], 2).size() == 2, "the arm carries one angled back slot per sitting pose")
	_ok(_centres(cr["notches"], 2).size() == 2, "each cross rail carries one brace slot per sitting pose")
	_ok(int(d["bom"]["sheets"]) == 3, "the sample nests onto exactly three 4×8 sheets (%d)" % int(d["bom"]["sheets"]))
	_ok(float(d["bom"]["utilization"]) > 0.97, "using %d%% of them" % int(float(d["bom"]["utilization"]) * 100))
	_ok((d["poses"] as Array).size() == 3, "upright, reclined and daybed poses")
	var clash_free := true
	for pose in d["poses"]:
		if not FlatpackJoints.interference(d, str(pose["id"])).is_empty():
			clash_free = false
	_ok(clash_free, "every pose goes together with the same parts")
	_ok((d["warnings"] as Array).is_empty(), "no warnings (%s)" % str(d["warnings"]))


func _test_router_sofa() -> void:
	var d := FlatpackDesign.solve(FlatpackSpec.default_spec("sofa"))
	_ok(int(d["bom"]["sheets"]) == 3, "the router-ready sofa still fits three sheets with 3/8\" spacing")
	var rail := FlatpackDesign.part(d, "long_rail_0")
	_ok(_near(float(rail["notches"][0]["width"]), 0.46875 + 0.02, 1e-4),
		"slots are the actual thickness (15/32\") plus clearance")
	var arcs := 0
	for b in (rail["ring"]["bulge"] as PackedFloat64Array):
		if absf(b) > 1e-6:
			arcs += 1
	_ok(arcs >= 10, "every rail slot is dogboned (%d arcs)" % arcs)
	_ok((d["warnings"] as Array).is_empty(), "no warnings at default sizes (%s)" % str(d["warnings"]))
	var lie := 0
	var sit := 0
	for st in d["seats"]:
		if str(st["kind"]) == "lie":
			lie += 1
		else:
			sit += 1
	_ok(sit >= 2 and lie >= 1, "it seats people (sofa) and beds them (daybed)")


func _test_all_types() -> void:
	for type in FlatpackSpec.TYPES:
		var d := FlatpackDesign.solve(FlatpackSpec.default_spec(type))
		var simple := true
		var ccw := true
		for p in d["parts"]:
			var tess := FlatpackProfile.tessellate(p["ring"])
			simple = simple and FlatpackProfile.is_simple(tess)
			ccw = ccw and FlatpackProfile.is_ccw(tess)
		var poses: Array = [""]
		if not (d["poses"] as Array).is_empty():
			poses = (d["poses"] as Array).map(func(x): return str(x["id"]))
		var clashes := 0
		for pose in poses:
			clashes += FlatpackJoints.interference(d, pose).size()
		_ok((d["warnings"] as Array).is_empty() and simple and ccw and clashes == 0
			and (d["nest"]["unplaced"] as Array).is_empty(),
			"%s: solves clean (warnings %s, clashes %d)" % [type, str(d["warnings"]), clashes])


func _test_wedges_and_overrides() -> void:
	var d := FlatpackDesign.solve(FlatpackSpec.default_spec("bench"))
	var wedges := 0
	for p in d["parts"]:
		if str(p["role"]) == "wedge":
			wedges += 1
	_ok(wedges == 2, "a bench stretcher is wedged outside both legs")
	var st := FlatpackDesign.part(d, "stretcher")
	_ok((st["holes"] as Array).size() == 2, "the stretcher carries the two wedge holes")
	var leg := FlatpackDesign.part(d, "leg_0")
	var mort := 0
	for h in leg["holes"]:
		if str(h["kind"]) == "mortise":
			mort += 1
	_ok(mort == 1, "each leg has the stretcher's mortise")
	_ok((FlatpackDesign.part(d, "top")["holes"] as Array).size() == 4, "the seat has a mortise per leg tab")
	var s := FlatpackSpec.default_spec("bench")
	s["joinery"]["wedges"] = false
	var d2 := FlatpackDesign.solve(s)
	var w2 := 0
	for p in d2["parts"]:
		if str(p["role"]) == "wedge":
			w2 += 1
	_ok(w2 == 0, "wedges off: no wedge parts")
	var s3 := FlatpackSpec.default_spec("bench")
	s3["joinery"]["overrides"] = {"stretcher_leg0": {"kind": "cross_lap", "wedge": false},
		"stretcher_leg1": {"kind": "cross_lap", "wedge": false}}
	var d3 := FlatpackDesign.solve(s3)
	_ok((FlatpackDesign.part(d3, "stretcher")["notches"] as Array).size() == 2,
		"a per-joint override turns the stretcher's tenons into cross-laps")
	var s4 := FlatpackSpec.default_spec("bench")
	s4["part_overrides"] = {"top": {"name": "Seat board"}}
	_ok(str(FlatpackDesign.part(FlatpackDesign.solve(s4), "top")["name"]) == "Seat board", "parts can be renamed")
	var dc := FlatpackDesign.solve(FlatpackSpec.default_spec("chair"))
	var side := FlatpackDesign.part(dc, "side_0")
	_ok((side["holes"] as Array).size() == 6, "a chair side has mortises for seat, back and stretcher tabs")
	var sp := FlatpackSpec.default_spec("chair")
	sp["profile_offsets"] = {"front_foot": Vector2(2.0, 0.0)}
	var dp := FlatpackDesign.solve(sp)
	_ok(FlatpackDesign.part(dp, "side_0")["bbox"].size.x > (side["bbox"] as Rect2).size.x + 1.5,
		"dragging a profile point reshapes the sides")


func _test_nesting() -> void:
	_ok(_near(FlatpackNesting.fit_to_sheet(4, 48.0, 0.25, 0.0), 11.75, 1e-6), "four rails across 48\" at 1/4\" spacing: 11 3/4\"")
	var items: Array = []
	for i in 4:
		items.append({"id": "r%d" % i, "w": 12.0, "h": 96.0, "rot_ok": true})
	var n := FlatpackNesting.nest(items, 48.0, 96.0, 0.0, 0.0)
	_ok((n["sheets"] as Array).size() == 1, "four 12×96 rails fill one 4×8 exactly")
	var big := FlatpackNesting.nest([{"id": "x", "w": 50.0, "h": 97.0, "rot_ok": true}], 48.0, 96.0, 0.0, 0.0)
	_ok((big["unplaced"] as Array).size() == 1, "a part larger than the sheet is reported, not placed")
	var grain := FlatpackNesting.nest([{"id": "g", "w": 90.0, "h": 10.0, "rot_ok": false}], 48.0, 96.0, 0.0, 0.0)
	_ok((grain["unplaced"] as Array).size() == 1, "a grain-locked part never turns")
	var s := FlatpackSpec.default_spec("table")
	FlatpackDesign.clear_cache()
	var a := FlatpackDesign.solve(s)
	FlatpackDesign.clear_cache()
	var b := FlatpackDesign.solve(s)
	_ok(var_to_str(a["nest"]) == var_to_str(b["nest"]), "nesting is deterministic")
	# Every placement inside its sheet and no two overlapping.
	var d := FlatpackDesign.solve(FlatpackSpec.default_spec("sofa"))
	var inside := true
	var overlap := false
	for sh in d["nest"]["sheets"]:
		var rects: Array = []
		for pl in sh["placements"]:
			var w := float(pl["h"]) if bool(pl["rot"]) else float(pl["w"])
			var h := float(pl["w"]) if bool(pl["rot"]) else float(pl["h"])
			var r := Rect2(float(pl["x"]), float(pl["y"]), w, h)
			inside = inside and r.position.x >= -1e-4 and r.position.y >= -1e-4 and r.end.x <= 48.0001 and r.end.y <= 96.0001
			for o in rects:
				if (o as Rect2).grow(-0.01).intersects(r.grow(-0.01)):
					overlap = true
			rects.append(r)
	_ok(inside and not overlap, "every part lies inside its sheet, none overlapping")


func _test_cam() -> void:
	var d := FlatpackDesign.solve(FlatpackSpec.default_spec("sofa"))
	var all_ok := true
	var total_outlines := 0
	for sh in d["nest"]["sheets"]:
		var c := FlatpackCam.sheet_content(d, int(sh["index"]))
		var parsed := FlatpackCam.dxf_parse(FlatpackCam.dxf_document(c, "in", true))
		var outs := int((parsed["polylines"] as Dictionary).get("OUTSIDE_CUT", 0))
		total_outlines += outs
		all_ok = all_ok and outs == (sh["placements"] as Array).size()
		all_ok = all_ok and (parsed["min"] as Vector2).x >= -1e-3 and (parsed["max"] as Vector2).y <= 96.001
	_ok(all_ok and total_outlines == 12, "each sheet's DXF has one outline per part, inside the sheet")
	var c0 := FlatpackCam.sheet_content(d, 0)
	var pin := FlatpackCam.dxf_parse(FlatpackCam.dxf_document(c0, "in", true))
	var pmm := FlatpackCam.dxf_parse(FlatpackCam.dxf_document(c0, "mm", true))
	_ok(int(pin["units"]) == 1 and int(pmm["units"]) == 4, "the header names the units")
	_ok(_near((pmm["max"] as Vector2).y, (pin["max"] as Vector2).y * 25.4, 0.01), "mm files are 25.4× the inch files")
	_ok(int(pin["bulged"]) > 0, "arcs stay arcs (bulged vertices)")
	var svg := FlatpackCam.svg_document(c0, "in", true)
	_ok(svg.contains("width=\"48in\"") and svg.contains("height=\"96in\""), "the SVG is sized in real inches")
	_ok(svg.contains(" A") and not svg.contains("<rect"), "SVG arcs are A commands and nothing is filled")
	var bench := FlatpackDesign.solve(FlatpackSpec.default_spec("bench"))
	var bc := FlatpackCam.sheet_content(bench, 0)
	_ok((bc["inside"] as Array).size() > 0 and int((FlatpackCam.dxf_parse(FlatpackCam.dxf_document(bc))["polylines"]
		as Dictionary).get("INSIDE_CUT", 0)) == (bc["inside"] as Array).size(), "mortises go on the inside-cut layer")
	var coupon := FlatpackCam.coupon_content(d)
	_ok((coupon["labels"] as Array).size() == FlatpackCam.COUPON_STEPS.size(), "the fit coupon labels each slot width")
	var txt := FlatpackCam.cut_list_text(d)
	_ok(txt.contains("Long rail") and txt.contains("96\"") and not txt.contains("(s)"), "the cut list reads plainly")
	var dir := OS.get_user_data_dir().path_join("flatpack_selftest_tmp")
	var w := FlatpackCam.write_all(d, dir)
	_ok(bool(w["ok"]) and (w["files"] as Array).size() == 9, "writing gives 3 DXF + 3 SVG + coupon pair + cut list")
	for f in w["files"]:
		DirAccess.remove_absolute(f)
	DirAccess.remove_absolute(dir)


func _test_spec() -> void:
	var s := FlatpackSpec.resolve({"type": "sofa", "params": {"length": 500.0, "rails": 99}})
	_ok(_near(float(s["params"]["length"]), 120.0) and int(s["params"]["rails"]) == 5, "numbers are clamped")
	_ok(str(FlatpackSpec.resolve({"type": "spaceship"})["type"]) == "sofa", "an unknown type falls back to the sofa")
	var m := FlatpackSpec.resolve({"material": {"nominal": "3/4"}})
	_ok(_near(float(m["material"]["thickness"]), 0.71875), "3/4\" plywood is 23/32\" actual")
	var j := FlatpackSpec.to_json_safe({"type": "chair", "profile_offsets": {"front_foot": Vector2(1, 2)}})
	var back := FlatpackSpec.resolve(JSON.parse_string(JSON.stringify(j)))
	_ok((back["profile_offsets"]["front_foot"] as Vector2).is_equal_approx(Vector2(1, 2)), "the spec round-trips through JSON")
	_ok(FlatpackSpec.fmt_in(11.75) == "11 3/4\"" and FlatpackSpec.fmt_in(0.46875) == "15/32\"" and FlatpackSpec.fmt_in(6.0) == "6\"",
		"inches print as a builder reads them")
	var keys_ok := true
	for type in FlatpackSpec.TYPES:
		for row in FlatpackSpec.param_rows(type):
			keys_ok = keys_ok and FlatpackSpec.default_spec(type)["params"].has(str(row["key"]))
	_ok(keys_ok, "every parameter row has a default")


func _test_builder() -> void:
	var node := FlatpackBuilder.build_node(FlatpackSpec.default_spec("bench"), "B", {"record": true})
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	_ok(mi != null and mi.mesh != null and mi.mesh.get_surface_count() == 2, "one mesh: plywood faces + ply edges")
	var aabb := mi.get_aabb()
	_ok(_near(aabb.position.y, 0.0, 1e-3) and _near(aabb.size.y, 17.5 * 0.0254, 0.002),
		"stands on the floor at the seat height (%.3f m)" % aabb.size.y)
	_ok(_near(aabb.get_center().x, 0.0, 0.01) and _near(aabb.get_center().z, 0.0, 0.01), "centred on its footprint")
	var hit := FlatpackBuilder.pick_part(node, Vector3(0.1, 2.0, 0.02), Vector3.DOWN)
	_ok(hit == "top", "a ray from above picks the seat (%s)" % hit)
	_ok((node.get_meta("seat_spots") as Array).size() == 2, "a 4 ft bench seats two")
	node.free()
	var sofa := FlatpackBuilder.build_node(FlatpackSpec.default_spec("sofa"), "S", {"pose": "daybed"})
	var kinds := (sofa.get_meta("seat_spots") as Array).map(func(x): return str(x["kind"]))
	_ok(kinds.has("lie") and not kinds.has("sit"), "the daybed pose offers beds, not seats")
	sofa.free()
	var holes := FlatpackBuilder.bridge_holes(FlatpackTemplates.rect(10, 10),
		[PackedVector2Array([Vector2(4, 4), Vector2(4, 6), Vector2(6, 6), Vector2(6, 4)])])
	_ok(not Geometry2D.triangulate_polygon(holes).is_empty(), "a part with a mortise triangulates through its keyhole")


func _test_packing() -> void:
	var d := FlatpackDesign.solve(FlatpackSpec.default_spec("sofa"))
	var ps := FlatpackDesign.packed_spec(d)
	_ok(_near(float(ps["mass_kg"]), float(d["bom"]["mass_kg"]), 1e-6) and float(ps["mass_kg"]) > 40.0,
		"the flat stack weighs what the parts do (%.1f kg)" % float(ps["mass_kg"]))
	_ok(_near(float(ps["h_m"]), 12 * 0.46875 * 0.0254, 1e-4), "twelve sheets of 15/32\" stack %.3f m high" % float(ps["h_m"]))
	_ok(_near(float(ps["w_m"]), 96.0 * 0.0254, 1e-3), "as long as the longest part")
	_ok(PackedSpec.DYNAMIC_MODELS.has(FlatpackBuilder.MODEL_ID), "flat-pack furniture is a computed packed model")

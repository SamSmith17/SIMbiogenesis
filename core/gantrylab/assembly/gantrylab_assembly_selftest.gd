extends SceneTree

## Gantry part mates, fasteners, symmetry and the zero-clash gate (offline).
##   Godot --headless --path . --script core/gantrylab/assembly/gantrylab_assembly_selftest.gd
## Run --import first after adding a class_name.

const EXPECTED_CHECKS := 34

var _n := 0
var _fail := 0


func _check(name: String, ok: bool) -> void:
	_n += 1
	if not ok:
		_fail += 1
		print("  FAIL: %s" % name)


func _initialize() -> void:
	print("GantryLab assembly selftest")
	_test_stock_and_slots()
	_test_nema_and_shaft()
	_test_resize_keeps_distance()
	_test_mirror()
	_test_presets_clean()
	_test_bom_counts()
	_test_reference_parts()
	print("GantryLab assembly selftest: %d checks, %d passed, %d failed" % [_n, _n - _fail, _fail])
	if _n != EXPECTED_CHECKS:
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_n, EXPECTED_CHECKS])
		_fail += 1
	print("RESULT: %s" % ("PASS" if _fail == 0 else "FAIL"))
	quit(0 if _fail == 0 else 1)


func _test_stock_and_slots() -> void:
	_check("stock length rounds up (5.1 mm -> 6)", absf(GantryLabMates.stock_len(0.0051) - 0.006) < 1e-9)
	_check("stock length never bottoms out a NEMA thread (3 mm bracket -> M3x6)", absf(GantryLabMates.stock_len(0.006, 0.0075) - 0.006) < 1e-9)
	var tf := GantryLabCatalog.feature("vslot_2040", {"len": 0.3}, "+z")
	var cf := GantryLabCatalog.feature("nema17_mount", {}, "base")
	_check("a 2040's wide face has two slot lines", (tf["lines"] as PackedFloat32Array).size() == 2)
	var sn := GantryLabMates.snap(tf, cf, {"s": 0.1, "lat": 0.004, "turn": 0, "anchor": "start"}, 0.001)
	_check("an L mount's bolt pair snaps onto a slot line", not sn.is_empty() and absf(absf(float(sn["lat"])) - 0.01) < 1e-6)
	_check("and fits", bool(GantryLabMates.fits(tf, cf, sn)["ok"]))
	var bad := sn.duplicate()
	bad["lat"] = 0.0
	_check("between the slots it does not", not bool(GantryLabMates.fits(tf, cf, bad)["ok"]))
	var r := GantryLabMates.slide_range(tf, cf, sn)
	_check("the slide keeps the bracket on the beam", r.x > 0.0 and r.y < 0.3 and r.y > r.x)
	var fz := GantryLabMates.fasteners(Transform3D.IDENTITY, tf, cf, sn)
	var tn := 0
	var bolts := 0
	for f in fz:
		if str(f["kind"]) == "tnut":
			tn += 1
		if str(f["kind"]) == "bolt" and absf(float(f["len"]) - 0.008) < 1e-9:
			bolts += 1
	_check("two T-nuts and two M5x8 bolts (3 mm leg + 5 mm thread)", tn == 2 and bolts == 2)


func _test_nema_and_shaft() -> void:
	var tf := GantryLabCatalog.feature("nema17_mount", {}, "motor")
	var cf := GantryLabCatalog.feature("nema17", {"shaft": 0.024}, "face")
	var sn := GantryLabMates.snap(tf, cf, {"turn": 0}, 0.0)
	_check("a NEMA 17 matches the mount's 31 mm square", not sn.is_empty() and bool(GantryLabMates.fits(tf, cf, sn)["ok"]))
	var w := GantryLabMates.place(Transform3D.IDENTITY, tf, cf, sn)
	_check("its shaft points out through the leg (-X)", w.basis.y.normalized().dot(Vector3.LEFT) > 0.999)
	_check("its body hangs inside the L (+X side)", (w * Vector3(0, -0.02, 0)).x > 0.0)
	var n3 := 0
	for f in GantryLabMates.fasteners(Transform3D.IDENTITY, tf, cf, sn):
		if str(f["label"]) == "M3×6 cap screw":
			n3 += 1
	_check("four M3x6", n3 == 4)
	var c23 := GantryLabCatalog.feature("nema23", {"shaft": 0.021}, "face")
	_check("a NEMA 23 does not", GantryLabMates.mate_type(c23, tf).is_empty())
	var sh := GantryLabCatalog.feature("nema17", {"shaft": 0.024}, "shaft")
	var bore := GantryLabCatalog.feature("gt2_pulley", {"bore": 0.005}, "bore")
	var big := GantryLabCatalog.feature("gt2_pulley", {"bore": 0.008}, "bore")
	_check("a 5 mm bore goes on a 5 mm shaft, an 8 mm one does not", GantryLabMates.mate_type(bore, sh) == "shaft" and GantryLabMates.mate_type(big, sh).is_empty())


func _test_resize_keeps_distance() -> void:
	var s := GantryLabSpec.default_spec("bedslinger")
	GantryLabAssembly.set_part(s, "ymount", {"mate": {"anchor": "end", "s": 0.05}})
	var a := GantryLabAssembly.resolve(GantryLabAssembly.build(GantryLabSpec.resolve(s)))
	var s2 := s.duplicate(true)
	s2["volume"]["x_mm"] = 320.0
	var b := GantryLabAssembly.resolve(GantryLabAssembly.build(GantryLabSpec.resolve(s2)))
	var ea: Transform3D = a["parts"]["cross.B"]["world"]
	var eb: Transform3D = b["parts"]["cross.B"]["world"]
	var la := float(a["parts"]["cross.B"]["part"]["params"]["len"])
	var lb := float(b["parts"]["cross.B"]["part"]["params"]["len"])
	var da := (ea * Vector3(la, 0, 0)).distance_to(a["parts"]["ymount"]["world"].origin)
	var db := (eb * Vector3(lb, 0, 0)).distance_to(b["parts"]["ymount"]["world"].origin)
	_check("a part anchored to a beam's end stays that far from it when the machine grows", absf(da - db) < 1e-5 and lb > la)


func _test_mirror() -> void:
	var s := GantryLabSpec.resolve(GantryLabSpec.default_spec("bedslinger"))
	var before := GantryLabAssembly.resolve(GantryLabAssembly.build(s))
	var wa: Vector3 = before["parts"]["zplate.L"]["world"].origin
	var wb: Vector3 = before["parts"]["zplate.R"]["world"].origin
	_check("the generated pair is mirrored", absf(wa.x + wb.x) < 1e-6 and absf(wa.y - wb.y) < 1e-6)
	var m: Dictionary = before["parts"]["upright.L"]["part"]["mate"]
	var tw := GantryLabAssembly.edit_part(s, "upright.L", {"mate": {"s": float(m["s"]) + 0.01}})
	var after := GantryLabAssembly.resolve(GantryLabAssembly.build(s))
	var ua: Vector3 = after["parts"]["upright.L"]["world"].origin
	var ub: Vector3 = after["parts"]["upright.R"]["world"].origin
	_check("editing one side moves its twin (%s) in mirror" % tw, tw == "upright.R" and absf(ua.x + ub.x) < 1e-6 and absf(ua.z - ub.z) < 1e-6 and ua.distance_to(before["parts"]["upright.L"]["world"].origin) > 0.009)
	GantryLabAssembly.unlink(s, "upright.L")
	var m2: Dictionary = after["parts"]["upright.L"]["part"]["mate"]
	GantryLabAssembly.edit_part(s, "upright.L", {"mate": {"s": float(m2["s"]) - 0.02}})
	var un := GantryLabAssembly.resolve(GantryLabAssembly.build(s))
	_check("once unlinked the twin stays put", (un["parts"]["upright.R"]["world"] as Transform3D).origin.distance_to(ub) < 1e-6)
	var s3 := GantryLabSpec.resolve(GantryLabSpec.default_spec("bedslinger"))
	var r3 := GantryLabAssembly.resolve(GantryLabAssembly.build(s3))
	var cid := GantryLabAssembly.add_part(s3, {"ref": "corner_bracket", "params": {}, "mate": (r3["parts"]["corner.FL1"]["part"]["mate"] as Dictionary).duplicate()})
	var tid := GantryLabAssembly.add_twin(s3, cid)
	var r4 := GantryLabAssembly.resolve(GantryLabAssembly.build(s3))
	var pa: Vector3 = r4["parts"][cid]["world"].origin
	var pb: Vector3 = r4["parts"][tid]["world"].origin if r4["parts"].has(tid) else Vector3.INF
	_check("Add mirrored places the twin on the other side", absf(pa.x + pb.x) < 1e-5 and absf(pa.y - pb.y) < 1e-5 and absf(pa.z - pb.z) < 1e-5)


func _test_presets_clean() -> void:
	var n := 0
	var bad := 0
	var specs: Array = []
	for k in GantryLabAssembly.KINEMATICS:
		specs.append(GantryLabSpec.default_spec(k))
	for p in GantryLabPresets.builtins():
		if GantryLabAssembly.uses_assembly(str(GantryLabSpec.resolve(p["spec"])["kinematics"])):
			specs.append(p["spec"])
	for sp in specs:
		var s := GantryLabSpec.resolve(sp)
		var lay := GantryLabFrame.layout(s)
		var issues: Array = (lay.get("issues", []) as Array) + GantryLabClash.check(s, lay)
		n += 1
		if not issues.is_empty():
			bad += 1
			for i in issues:
				print("    %s: %s" % [str(s["name"]), str(i["text"])])
	_check("every V-slot preset: no collision from home to the far corners, no belt crossing or through a part (%d)" % n, bad == 0 and n >= 8)
	# The checker does see a collision: a motor mount on the front beam's top
	# under the travelling bed.
	var s2 := GantryLabSpec.resolve(GantryLabSpec.default_spec("bedslinger"))
	var r := GantryLabAssembly.resolve(GantryLabAssembly.build(s2))
	var tf := GantryLabAssembly.feature_of(r["parts"]["cross.F"]["part"], "+y")
	var cf := GantryLabCatalog.feature("nema17_mount", {}, "base")
	var m := GantryLabMates.snap(tf, cf, {"s": float(r["parts"]["cross.F"]["part"]["params"]["len"]) * 0.5, "lat": 0.0, "turn": 1, "anchor": "start"}, 0.0)
	m["to"] = "cross.F"
	m["tf"] = "+y"
	m["f"] = "base"
	GantryLabAssembly.add_part(s2, {"ref": "nema17_mount", "params": {}, "mate": m})
	GantryLabAssembly.clear_cache()
	var lay2 := GantryLabFrame.layout(GantryLabSpec.resolve(s2))
	var hits := GantryLabClash.check(GantryLabSpec.resolve(s2), lay2)
	var found := false
	for h in hits:
		if (h["parts"] as Array).has("u1"):
			found = true
	_check("a bracket left under the bed's path is caught", found)
	# And a belt out of its plane.
	var s3 := GantryLabSpec.resolve(GantryLabSpec.default_spec("bedslinger"))
	GantryLabAssembly.set_part(s3, "ypulley", {"mate": {"s": 0.005}})
	var lay3 := GantryLabAssembly.to_layout(s3, GantryLabAssembly.resolve(GantryLabAssembly.build(s3)))
	var twisted := false
	for i in lay3["issues"]:
		if str(i["text"]).find("plane") >= 0:
			twisted = true
	_check("the idler follows the pulley onto the new plane (no twist)", not twisted)


func _test_bom_counts() -> void:
	var d := GantryLabDesign.solve(GantryLabSpec.default_spec("corexy"))
	var res: Dictionary = d["layout"]["assembly"]
	var drawn := 0
	for f in res["fasteners"]:
		if str(f["label"]) == "M5 drop-in T-nut":
			drawn += 1
	var listed := 0
	for r in d["bom"]["rows"]:
		if str(r["item"]) == "M5 drop-in T-nut":
			listed = int(r["qty"])
	_check("the BOM counts the T-nuts the machine draws (%d)" % drawn, drawn > 20 and listed == drawn)
	var wheels := 0
	for r in d["bom"]["rows"]:
		if str(r["item"]).begins_with("Solid V-wheel"):
			wheels = int(r["qty"])
	_check("and its V-wheels (%d)" % wheels, wheels >= 16 and wheels % 4 == 0)
	var belts := 0
	for r in d["bom"]["rows"]:
		if str(r["item"]).begins_with("GT2 belt"):
			belts += 1
	_check("one belt row per drawn loop (A and B)", belts == 2)


## The parts from the player's reference model ("additional 3d printer
## parts"): each lands where it really fastens, with its own fasteners.
func _test_reference_parts() -> void:
	var beam := {"len": 0.3}
	var a_face := GantryLabCatalog.feature("vslot_2020", beam, "+y")
	# A T: beam B butts beam A's side, both lying flat; the T plate's bar on
	# A, its stem over B — the stem's two bolts are found on B by itself.
	var bx := Transform3D(Basis(Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(-1, 0, 0)), Vector3(0.15, 0, 0.01))
	var best := 0
	for turn in 4:
		var bar := GantryLabCatalog.feature("joining_plate_t", {}, "a")
		var sn := GantryLabMates.snap(a_face, bar, {"s": 0.15, "lat": 0.0, "turn": turn, "anchor": "start"}, 0.001)
		if sn.is_empty():
			continue
		var doc := {"parts": [
			{"id": "A", "ref": "vslot_2020", "params": beam},
			{"id": "B", "ref": "vslot_2020", "params": beam, "xf": bx},
			{"id": "plate", "ref": "joining_plate_t", "params": {}, "mate": sn.merged({"to": "A", "tf": "+y", "f": "a"}, true)}]}
		var res := GantryLabAssembly.resolve(doc)
		best = maxi(best, _count(res, "plate", "tnut"))
	_check("a T joining plate on a T joint: 3 T-nuts on the bar's beam + 2 found on the stem's (%d)" % best, best == 5)
	# A cube connector on a beam end: one M5 from inside into the tap.
	var end1 := GantryLabCatalog.feature("vslot_2020", beam, "e1")
	var ca := GantryLabCatalog.feature("cube_corner", {}, "a")
	var cs := GantryLabMates.snap(end1, ca, {"turn": 0}, 0.001)
	_check("a cube corner mates a 2020's tapped end", not cs.is_empty() and bool(GantryLabMates.fits(end1, ca, cs)["ok"]))
	var cdoc := {"parts": [{"id": "A", "ref": "vslot_2020", "params": beam},
		{"id": "cube", "ref": "cube_corner", "params": {}, "mate": cs.merged({"to": "A", "tf": "e1", "f": "a"}, true)}]}
	var cres := GantryLabAssembly.resolve(cdoc)
	var bolt := _first(cres, "cube", "bolt")
	_check("with an M5x20 into the tap", not bolt.is_empty() and absf(float(bolt["len"]) - 0.02) < 1e-9)
	# A second beam on the cube's other face: its bolt is found by itself.
	var cw: Transform3D = cres["parts"]["cube"]["world"]
	var cc := GantryLabCatalog.feature("cube_corner", {}, "c")
	var fw: Transform3D = cw * (cc["xf"] as Transform3D)
	var out_dir := fw.basis.y.normalized()
	var up := fw.basis.x.normalized()
	var dx := Transform3D(Basis(out_dir, up, out_dir.cross(up)), fw.origin)
	cdoc["parts"].append({"id": "D", "ref": "vslot_2020", "params": beam, "xf": dx})
	_check("a second beam on the cube's next face gets its bolt too", _count(GantryLabAssembly.resolve(cdoc), "cube", "bolt") == 2)
	# The 3-way connector's spigot: a set screw, no bolt.
	var sp := GantryLabCatalog.feature("corner_3way", {}, "a")
	var ss := GantryLabMates.snap(end1, sp, {"turn": 0}, 0.001)
	var sf := GantryLabMates.fasteners(Transform3D.IDENTITY, end1, sp, ss)
	_check("a 3-way connector's spigot is held by a set screw", sf.size() == 1 and str(sf[0]["kind"]) == "grub_hidden")
	# The hidden corner bracket's leg in a slot: set screws, no T-nut.
	var hl := GantryLabCatalog.feature("inside_corner", {}, "a")
	var hs := GantryLabMates.snap(a_face, hl, {"s": 0.1, "turn": 0}, 0.001)
	var hf := GantryLabMates.fasteners(Transform3D.IDENTITY, a_face, hl, hs)
	_check("a hidden corner bracket sits in the slot on a set screw", not hs.is_empty() and hf.size() == 1 and str(hf[0]["kind"]) == "grub_hidden")
	# The flat NEMA 17 plate: two bolts along a 2020's slot, a NEMA 17 on it.
	var fm := GantryLabCatalog.feature("nema17_flat", {}, "mount")
	var fs := GantryLabMates.snap(a_face, fm, {"s": 0.1, "turn": 0}, 0.001)
	var mt := GantryLabCatalog.feature("nema17_flat", {}, "motor")
	var mf := GantryLabCatalog.feature("nema17", {}, "face")
	var ms := GantryLabMates.snap(mt, mf, {"turn": 0}, 0.001)
	var wide := GantryLabCatalog.feature("nema17_flat", {}, "wide")
	var f2040 := GantryLabCatalog.feature("vslot_2040", beam, "+z")
	_check("a flat NEMA 17 plate bolts along a 2020 slot, across a 2040's two, and takes a NEMA 17",
		not fs.is_empty() and not GantryLabMates.snap(f2040, wide, {"s": 0.1, "turn": 0}, 0.001).is_empty() and not ms.is_empty())
	# The mini V plate: four mini wheels 30 mm apart on a 2020, none on a 2040.
	var run := GantryLabCatalog.feature("mini_v_plate", {}, "run")
	var rs := GantryLabMates.snap(a_face, run, {"s": 0.1, "turn": 0}, 0.001)
	var wz := GantryLabMates.wheels(Transform3D.IDENTITY, a_face, run, rs, {"wheel_r": GantryLabCatalog.MINI_WHEEL_R, "wheel_w": GantryLabCatalog.MINI_WHEEL_W, "wheelbase": 0.03})
	var cs2: Array = []
	for w in wz:
		if str(w["kind"]) == "wheel":
			cs2.append((w["xf"] as Transform3D).origin)
	var across := (cs2[0] as Vector3).distance_to(cs2[2]) if cs2.size() == 4 else 0.0
	_check("a mini V plate rides a 2020 on four mini wheels ~30 mm apart (%.1f mm)" % (across * 1000.0),
		cs2.size() == 4 and absf(across - 0.030) < 0.0015 and GantryLabMates.snap(f2040, run, {"s": 0.1, "turn": 0}, 0.001).is_empty())
	# The Acme nut block on a gantry plate's grid; the 5 x 6 coupler's 6 mm end.
	var top := GantryLabCatalog.feature("gantry_plate", {}, "top")
	var nb := GantryLabCatalog.feature("nut_block_8", {}, "base")
	_check("the 8 mm Acme nut block bolts to a gantry plate's grid, and the 5 x 6 coupler takes a 6 mm shaft",
		not GantryLabMates.snap(top, nb, {"s": 0.0, "lat": 0.0, "turn": 0}, 0.001).is_empty()
		and str(GantryLabCatalog.feature("coupler_5_6", {}, "top")["cls"]) == "d635")


func _count(res: Dictionary, owner: String, kind: String) -> int:
	var n := 0
	for f in res["fasteners"]:
		if str(f.get("owner", "")) == owner and str(f["kind"]) == kind:
			n += 1
	return n


func _first(res: Dictionary, owner: String, kind: String) -> Dictionary:
	for f in res["fasteners"]:
		if str(f.get("owner", "")) == owner and str(f["kind"]) == kind:
			return f
	return {}

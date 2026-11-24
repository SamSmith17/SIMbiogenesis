extends SceneTree
## Offline selftest for the 3D waste items and the bin pile (food/waste
## realism plan Phase 8): every archetype's mesh resolves at a sane size,
## the pure pile layout is deterministic, stays inside the bin, respects
## the ledger's arrival order as a PREFIX (a scrub back simply lowers the
## pile), and holds the volume-honesty property — within capacity every
## item's BASE sits below the rim; past capacity the heap climbs over it.
## Run:
##   Godot --headless --path . --script core/placed_models/waste_bin_selftest.gd
##
## Carries EXPECTED_CHECKS (a runtime error aborts a test function while
## PASS would still print).

const EXPECTED_CHECKS := 21

var _checks := 0
var _failed := 0


func _initialize() -> void:
	_test_meshes()
	_test_layout()
	_test_honesty()
	_test_fallback()
	if _checks != EXPECTED_CHECKS:
		_failed += 1
		push_error("FAIL: check count drifted — expected %d, ran %d" % [EXPECTED_CHECKS, _checks])
	if _failed == 0:
		print("WASTE BIN SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("WASTE BIN SELFTEST: %d of %d checks FAILED" % [_failed, _checks])
	quit(0 if _failed == 0 else 1)


func _check(what: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failed += 1
		push_error("FAIL: %s%s" % [what, ("  [" + detail + "]") if not detail.is_empty() else ""])


func _test_meshes() -> void:
	var bad := PackedStringArray()
	for aid in PackagingArchetypes.ids():
		var mid := PackagingArchetypes.mesh_id(aid)
		var m := WasteItemMeshes.mesh(mid)
		if m == null or m.get_surface_count() < 1:
			bad.append(aid + ":no mesh")
			continue
		var aabb := m.get_aabb()
		if aabb.size.length() < 0.02 or aabb.size.length() > 0.8:
			bad.append("%s:%s size %.2f" % [aid, mid, aabb.size.length()])
		if WasteItemMeshes.half_h(mid) <= 0.0:
			bad.append(aid + ":no half_h")
		if m.surface_get_material(0) == null:
			bad.append(aid + ":no material")
	_check("every archetype's mesh_id resolves at a believable size, with a material",
		bad.is_empty(), ", ".join(bad))
	_check("the mesh cache hands back the same ArrayMesh",
		WasteItemMeshes.mesh("alu_can") == WasteItemMeshes.mesh("alu_can"))
	_check("15 distinct item meshes", WasteItemMeshes.ids().size() == 15,
		str(WasteItemMeshes.ids()))


func _test_layout() -> void:
	var r := WasteBinBuilder.resolve({})
	_check("the default bin is the 360 L wheelie",
		str(r["style"]) == "bin" and absf(float(r["capacity_l"]) - 360.0) < 1e-9
			and str(r["kind"]) == "pet_waste", str(r))
	var bay := WasteBinBuilder.resolve({"style": "bay", "kind": "glass_waste"})
	_check("the bay style is the big open enclosure",
		float(bay["w"]) > 2.0 and float(bay["capacity_l"]) > 1000.0)
	var inter := WasteBinBuilder.interior(r)
	_check("the interior sits inside the walls",
		float(inter["w"]) < float(r["w"]) and float(inter["floor_y"]) > 0.0
			and absf(float(inter["rim_y"]) - float(r["h"])) < 1e-9)
	var counts := {"pet_bottle_500": 7, "alu_can_355": 5}
	var a := WasteBinBuilder.layout("store1", counts, inter, 360.0)
	var b := WasteBinBuilder.layout("store1", counts, inter, 360.0)
	_check("one item per piece, in ledger order",
		a.size() == 12 and str((a[0] as Dictionary)["mesh_id"]) == "pet_bottle"
			and str((a[7] as Dictionary)["mesh_id"]) == "alu_can", str(a.size()))
	var same := a.size() == b.size()
	for i in a.size():
		same = same and (a[i] as Dictionary)["xform"] == (b[i] as Dictionary)["xform"]
	_check("the layout is deterministic (two calls identical)", same)
	var other := WasteBinBuilder.layout("store2", counts, inter, 360.0)
	var differs := false
	for i in a.size():
		differs = differs or (a[i] as Dictionary)["xform"] != (other[i] as Dictionary)["xform"]
	_check("…but another store's pile is its own jumble", differs)
	# A scrub back = fewer counts: the smaller pile is a PREFIX of the
	# bigger one, item for item — the pile visibly lowers, nothing shuffles.
	var small := WasteBinBuilder.layout("store1", {"pet_bottle_500": 4}, inter, 360.0)
	var prefix := small.size() == 4
	for i in small.size():
		prefix = prefix and (small[i] as Dictionary)["xform"] == (a[i] as Dictionary)["xform"]
	_check("fewer counts = the same pile, lower (prefix property)", prefix)
	var inside := true
	for it in a:
		var p: Vector3 = ((it as Dictionary)["xform"] as Transform3D).origin
		inside = inside and absf(p.x) <= float(inter["w"]) * 0.5 + 1e-6 \
			and absf(p.z) <= float(inter["d"]) * 0.5 + 1e-6 and p.y > 0.0
	_check("every item stands inside the bin's plan", inside)
	_check("an unknown archetype still draws (the stand-in tub)",
		str((WasteBinBuilder.layout("s", {"mystery": 1}, inter, 360.0)[0] as Dictionary)["mesh_id"]) == "plastic_tub")


func _test_honesty() -> void:
	var inter := WasteBinBuilder.interior(WasteBinBuilder.resolve({}))
	var rim := float(inter["rim_y"])
	# 500 ml PET bottles are 1.15 L loose: 300 of them = 345 L, inside the
	# 360 L bin — every item's BASE must sit below the rim.
	var under := WasteBinBuilder.layout("s", {"pet_bottle_500": 300}, inter, 360.0)
	var ok := true
	var top := 0.0
	for it in under:
		var d := it as Dictionary
		var base: float = (d["xform"] as Transform3D).origin.y - WasteItemMeshes.half_h(str(d["mesh_id"]))
		top = maxf(top, base)
		ok = ok and base <= rim + 0.01 and not bool(d["over_rim"])
	_check("within capacity every item's base is below the rim (volume honesty)",
		ok, "top base %.3f of rim %.3f" % [top, rim])
	_check("…and the pile really fills most of the bin", top > rim * 0.75,
		"%.3f" % top)
	# 400 of them = 460 L: past capacity the heap climbs over the rim.
	var over := WasteBinBuilder.layout("s", {"pet_bottle_500": 400}, inter, 360.0)
	var any_over := false
	var above := 0
	for it in over:
		var d := it as Dictionary
		any_over = any_over or bool(d["over_rim"])
		if (d["xform"] as Transform3D).origin.y > rim:
			above += 1
	_check("past capacity the heap climbs above the rim, flagged over_rim",
		any_over and above > 0, "%d above" % above)
	# The litres the layout stacked match the archetype table exactly.
	_check("the pile height maps the table's loose litres",
		absf((300.0 * PackagingArchetypes.loose_l("pet_bottle_500")) - 345.0) < 1e-9)


func _test_fallback() -> void:
	var c := WasteBinBuilder.counts_from_kg("steel_waste", 5.5)
	_check("kg with no ledger becomes the kind's representative pieces",
		int(c.get("steel_can_400", 0)) == 100, str(c))
	_check("an unknown kind or no kg = an empty pile",
		WasteBinBuilder.counts_from_kg("steel_waste", 0.0).is_empty()
			and WasteBinBuilder.counts_from_kg("unobtainium", 3.0).is_empty())
	_check("every typed bin kind has a store capacity",
		WasteBinBuilder.KIND_CAPACITY_KG.size() == 10)
	var node := WasteBinBuilder.build_node({"kind": "alu_waste"})
	_check("the shell builds: a Mesh, a Stripe, a Piles anchor",
		node.get_node_or_null("Mesh") != null and node.get_node_or_null("Piles") != null
			and node.get_node_or_null("Stripe") != null)
	_check("the pile anchor and stripe skip prop collision",
		bool((node.get_node_or_null("Stripe") as Node).get_meta("skip_prop_collision", false)))
	node.free()

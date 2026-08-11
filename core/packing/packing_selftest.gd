extends SceneTree

## Offline deterministic selftest for the packing data model — PACKING_PLAN.md
## Phase 0: PackedSpec (core/packing/packed_spec.gd) resolution/normalization/
## estimation + mass heuristics, the shipped-model packing-decision coverage
## guard, and LinkageStructureBuilder.packed_spec_for's honest-fold envelope.
##
## Run --import first (PackedSpec is a new class_name):
##   Godot.exe.exe --headless --path . --import
##   Godot.exe.exe --headless --path . --script core/packing/packing_selftest.gd

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_normalize()
	_test_format()
	_test_model_coverage_guard()
	_test_curated_sanity()
	_test_preset_coverage()
	_test_mass_heuristics()
	_test_estimator()
	_test_linkage_packed_envelope()
	_test_container_catalog()
	_test_container_door_fit()
	_test_container_builder()
	_test_solver_known_answers()
	_test_solver_constraints()
	_test_manifest()
	_test_pack_tree()
	_test_pack_defs()
	_test_packed_form_builder()
	_test_packed_contents_label()
	_test_haul_model()
	_test_unpack_scenario()
	_test_stow_plan()
	_test_crew_plan()
	_test_manifest_export()
	if _fails == 0:
		print("PACKING SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("PACKING SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


## PackManifestExport (Phase 7): load order is nose-first / floor-first (the
## physical order — never asks a crew to stack onto a box not yet placed),
## totals are mass-exact, unplaced items are reported with a door verdict,
## and the CSV round-trips the same numbers.
func _test_manifest_export() -> void:
	var entry := ContainerCatalog.find("uhaul_15")
	_check("manifest: uhaul_15 entry resolves", not entry.is_empty())
	if entry.is_empty():
		return
	var units: Array = [
		{"label": "Heavy crate", "w_m": 1.0, "d_m": 1.0, "h_m": 1.0,
			"mass_kg": 100.0, "stackable": true, "this_side_up": false},
		{"label": "Top box", "w_m": 0.5, "d_m": 0.5, "h_m": 0.5,
			"mass_kg": 20.0, "stackable": true, "this_side_up": true},
		{"label": "Door-side crate", "w_m": 1.0, "d_m": 1.0, "h_m": 1.0,
			"mass_kg": 60.0, "stackable": false, "this_side_up": false},
		{"label": "Left behind, with comma", "w_m": 9.0, "d_m": 9.0, "h_m": 9.0,
			"mass_kg": -1.0, "stackable": true, "this_side_up": false},
	]
	# Hand-authored placements: one on the floor at the nose, one stacked on
	# it, one on the floor by the door. Index 3 stays unplaced (oversized).
	var placed: Array = [
		{"unit_idx": 2, "pos": Vector3(0.0, 0.0, 2.5), "size": Vector3(1.0, 1.0, 1.0)},
		{"unit_idx": 1, "pos": Vector3(0.2, 1.0, 0.2), "size": Vector3(0.5, 0.5, 0.5)},
		{"unit_idx": 0, "pos": Vector3(0.0, 0.0, 0.0), "size": Vector3(1.0, 1.0, 1.0)},
	]
	var m := PackManifestExport.build(entry, units, placed)
	var loaded: Array = m.get("loaded", []) as Array
	_check("manifest: 3 loaded rows", loaded.size() == 3)
	var order: Array = []
	for r: Variant in loaded:
		order.append(str((r as Dictionary).get("label", "")))
	_check("manifest: nose floor box loads first, stacked second, door last",
		order == ["Heavy crate", "Top box", "Door-side crate"], str(order))
	_check("manifest: load_seq is 1..n",
		int((loaded[0] as Dictionary).get("load_seq", 0)) == 1
		and int((loaded[2] as Dictionary).get("load_seq", 0)) == 3)
	var t: Dictionary = m.get("totals", {}) as Dictionary
	_check("manifest: mass sums placed only (180 kg)",
		absf(float(t.get("mass_kg", 0.0)) - 180.0) < 0.01,
		"mass=%.2f" % float(t.get("mass_kg", 0.0)))
	_check("manifest: payload ok at 180 kg", bool(t.get("payload_ok", false)))
	var unplaced: Array = m.get("unplaced", []) as Array
	_check("manifest: 1 unplaced row", unplaced.size() == 1)
	if unplaced.size() == 1:
		_check("manifest: oversized item flagged at the door",
			not bool((unplaced[0] as Dictionary).get("fits_door", true)))
	# CoM sits between the two floor crates, biased toward the nose pair.
	var com := float(t.get("com_len_frac", 0.0))
	_check("manifest: CoM fraction sane (0..0.5)", com > 0.0 and com < 0.5,
		"com=%.3f" % com)
	# JSON-cleanliness: build() must emit no Vector3s (they stringify badly).
	var json := JSON.stringify(m)
	_check("manifest: JSON round-trips", JSON.parse_string(json) is Dictionary)
	_check("manifest: no Vector3 leaked into JSON", not json.contains("("),
		json.substr(0, 200))
	var csv := PackManifestExport.to_csv(m)
	_check("manifest CSV: has load order header", csv.contains("LOAD ORDER"))
	_check("manifest CSV: comma label quoted",
		csv.contains("\"Left behind, with comma\""))
	_check("manifest CSV: this-side-up note present", csv.contains("THIS SIDE UP"))
	_check("manifest CSV: do-not-stack note present", csv.contains("do not stack on"))
	_check("manifest CSV: totals present", csv.contains("Load mass,180 kg"))


func _test_normalize() -> void:
	_check("empty in empty out", PackedSpec.normalize({}).is_empty())
	_check("degenerate dims rejected",
		PackedSpec.normalize({"w_m": 1.0, "d_m": 0.0, "h_m": 1.0}).is_empty())
	var s := PackedSpec.normalize({"w_m": 0.3, "d_m": 2.0, "h_m": 1.0})
	_check("dims canonicalized w>=d>=h",
		float(s["w_m"]) == 2.0 and float(s["d_m"]) == 1.0 and float(s["h_m"]) == 0.3,
		str(s))
	var up := PackedSpec.normalize({"w_m": 0.3, "d_m": 2.0, "h_m": 1.0, "this_side_up": true})
	_check("this_side_up keeps authored orientation",
		float(up["w_m"]) == 0.3 and float(up["h_m"]) == 1.0, str(up))
	_check("defaults filled", s.has("stackable") and s.has("contains") and int(s["count"]) == 1)
	_check("bad form falls back to crate",
		str(PackedSpec.normalize({"w_m": 1, "d_m": 1, "h_m": 1, "form": "zeppelin"})["form"]) == "crate")
	_check("zero mass becomes unknown sentinel",
		float(PackedSpec.normalize({"w_m": 1, "d_m": 1, "h_m": 1, "mass_kg": 0.0})["mass_kg"]) == PackedSpec.MASS_UNKNOWN)
	_check("volume", absf(PackedSpec.volume_m3(s) - 0.6) < 1e-6)


func _test_format() -> void:
	var s := PackedSpec.normalize({"w_m": 2.4384, "d_m": 1.2192, "h_m": 0.4572, "mass_kg": 100.0})
	var d := PackedSpec.format_dims(s)
	_check("format_dims feet", d.begins_with("8' ×"), d)
	_check("format_dims inches under 3ft", d.contains("18\""), d)
	_check("format_dims metric parens", d.contains("(2.44 × 1.22 × 0.46 m)"), d)
	_check("format_mass lb", PackedSpec.format_mass(s).contains("220 lb"),
		PackedSpec.format_mass(s))
	_check("format_mass unknown", PackedSpec.format_mass({}) == "—")
	_check("format_dims empty", PackedSpec.format_dims({}) == "—")
	var short := PackedSpec.format_dims_short(s)
	_check("format_dims_short compact", short == "8' × 4' × 18\"", short)
	_check("format_dims_short empty", PackedSpec.format_dims_short({}) == "—")


## Every shipped structures/tools model must have a declared packing story
## (curated / dynamic / explicitly non-packable). A new model that skips the
## decision fails here — that is the point.
func _test_model_coverage_guard() -> void:
	var swept := 0
	for m in ModelCatalog.all_models():
		var cat := str(m.get("category", ""))
		if cat != "structures" and cat != "tools":
			continue
		var mid := str(m.get("id", ""))
		if mid.begins_with("user_"):
			continue  # user imports resolve via AABB estimation at runtime
		swept += 1
		_check("packing decision declared for '%s'" % mid,
			PackedSpec.model_packing_known(mid) or m.has("packed"))
	_check("coverage guard swept a real set", swept >= 20, "swept %d" % swept)
	# Non-packable and curated resolve as documented.
	_check("non-packable returns empty", PackedSpec.for_model("pine_1").is_empty())
	var pod := PackedSpec.for_model("shiftpod")
	_check("curated resolves", not pod.is_empty() and str(pod["source"]) == "curated")
	_check("unknown id without AABB is empty", PackedSpec.for_model("no_such_model").is_empty())


func _test_curated_sanity() -> void:
	for mid in PackedSpec.CURATED_MODELS:
		var s := PackedSpec.for_model(mid)
		_check("curated '%s' normalizes" % mid, not s.is_empty())
		if s.is_empty():
			continue
		var vol := PackedSpec.volume_m3(s)
		_check("curated '%s' plausible volume" % mid, vol > 0.001 and vol < 20.0,
			"%f m3" % vol)
		_check("curated '%s' has mass" % mid, PackedSpec.has_mass(s))
		_check("curated '%s' plausible density" % mid,
			float(s["mass_kg"]) / vol > 5.0 and float(s["mass_kg"]) / vol < 3000.0,
			"%f kg/m3" % (float(s["mass_kg"]) / vol))


## Every physical preset type derives a packed spec with dims + mass; abstract
## types stay empty.
func _test_preset_coverage() -> void:
	var physical: Array = [ComponentPresets.PANELS, ComponentPresets.BATTERIES,
		ComponentPresets.CONTROLLERS, ComponentPresets.APPLIANCES,
		ComponentPresets.PROCESSORS, ComponentPresets.RESOURCES,
		ComponentPresets.WIND_TURBINES, ComponentPresets.HYDRO_TURBINES]
	for group in physical:
		for preset in group:
			var t := str(preset.get("type", ""))
			var specs: Dictionary = preset.get("specs", {})
			var s := PackedSpec.for_preset_specs(t, specs)
			_check("preset '%s' packs" % str(preset.get("label", "?")),
				not s.is_empty() and PackedSpec.has_mass(s),
				"type=%s -> %s" % [t, str(s)])
	for abstract_type in ["pbi", "catchment", "compound", "plant"]:
		_check("abstract '%s' does not pack" % abstract_type,
			PackedSpec.for_preset_specs(abstract_type, {}).is_empty())


func _test_mass_heuristics() -> void:
	# 12V 100Ah LiFePO4 ≈ 1.28 kWh / 90 Wh/kg ≈ 14 kg (real: 11–13 kg).
	var lfp := PackedSpec.for_preset_specs("battery",
		{"chemistry": "LFP", "kwh": 1.28})
	_check("LFP 100Ah mass band", float(lfp["mass_kg"]) > 10.0 and float(lfp["mass_kg"]) < 18.0,
		str(lfp["mass_kg"]))
	_check("battery is this_side_up", bool(lfp["this_side_up"]))
	# Same capacity AGM must be much heavier (real 12V 100Ah AGM ≈ 29 kg).
	var agm := PackedSpec.for_preset_specs("battery",
		{"chemistry": "SLA", "kwh": 1.20})
	_check("AGM heavier than LFP", float(agm["mass_kg"]) > float(lfp["mass_kg"]) * 1.6,
		"%s vs %s" % [agm["mass_kg"], lfp["mass_kg"]])
	# 410 W rigid panel ≈ 21.5 kg, ~2 m long.
	var p410 := PackedSpec.for_preset_specs("panel", {"wmp": 410.0, "name": "REC Alpha"})
	_check("410W panel mass band", float(p410["mass_kg"]) > 17.0 and float(p410["mass_kg"]) < 26.0,
		str(p410["mass_kg"]))
	_check("410W panel long edge band", float(p410["w_m"]) > 1.5 and float(p410["w_m"]) < 2.1,
		str(p410["w_m"]))
	# Flexible panel is several times lighter per watt.
	var flex := PackedSpec.for_preset_specs("panel", {"wmp": 100.0, "name": "Alrska Flexible 100W"})
	var rigid100 := PackedSpec.for_preset_specs("panel", {"wmp": 100.0, "name": "Rigid 100"})
	_check("flex lighter than rigid", float(flex["mass_kg"]) < float(rigid100["mass_kg"]) * 0.6,
		"%s vs %s" % [flex["mass_kg"], rigid100["mass_kg"]])
	# Monotonicity: more capacity/watts never packs smaller or lighter.
	var b1 := PackedSpec.for_preset_specs("battery", {"chemistry": "LFP", "kwh": 1.28})
	var b4 := PackedSpec.for_preset_specs("battery", {"chemistry": "LFP", "kwh": 5.12})
	_check("bigger battery heavier", float(b4["mass_kg"]) > float(b1["mass_kg"]))
	_check("bigger battery bulkier", PackedSpec.volume_m3(b4) > PackedSpec.volume_m3(b1))
	# 250 gal tank ≈ 65 kg empty (rotomolded HDPE).
	var tank := PackedSpec.for_preset_specs("resource",
		{"capacity_qty": 946.0, "capacity_unit": "L"})
	_check("250gal tank mass band", float(tank["mass_kg"]) > 45.0 and float(tank["mass_kg"]) < 90.0,
		str(tank["mass_kg"]))
	_check("tank ships upright", bool(tank["this_side_up"]) and str(tank["form"]) == "tank")
	# Victron 150/35 ≈ 1.25 kg; a 3.5 kW hybrid is an order heavier.
	var mppt := PackedSpec.for_preset_specs("controller",
		{"name": "Victron SmartSolar 150/35", "max_voc": 150.0, "max_charge_amps": 35.0, "max_pv_watts": 2000.0})
	_check("MPPT mass band", float(mppt["mass_kg"]) > 0.8 and float(mppt["mass_kg"]) < 3.5,
		str(mppt["mass_kg"]))
	var hybrid := PackedSpec.for_preset_specs("controller",
		{"name": "EcoWorthy SL3500 Hybrid", "max_pv_watts": 3500.0, "max_charge_amps": 80.0, "overload_watts": 3500.0})
	_check("hybrid much heavier than MPPT", float(hybrid["mass_kg"]) > float(mppt["mass_kg"]) * 5.0,
		"%s vs %s" % [hybrid["mass_kg"], mppt["mass_kg"]])
	# Processor with a real 3D twin defers to the model's curated entry.
	var shredder := PackedSpec.for_preset_specs("processor",
		{"name": "PP Shredder", "watts": 600.0, "model_id": "pp_shredder"})
	_check("processor uses model curated entry",
		absf(float(shredder["mass_kg"]) - 95.0) < 0.01, str(shredder["mass_kg"]))


func _test_estimator() -> void:
	var rigid := PackedSpec.estimate_from_deployed(Vector3(0.7, 1.7, 0.7), "rigid")
	_check("rigid ships at deployed size",
		absf(float(rigid["w_m"]) - 1.7) < 1e-6 and absf(float(rigid["h_m"]) - 0.7) < 1e-6)
	var frame := PackedSpec.estimate_from_deployed(Vector3(3.0, 3.0, 3.0), "frame")
	_check("frame knocks down to a bundle", str(frame["form"]) == "bundle"
		and PackedSpec.volume_m3(frame) < 27.0 * 0.05, str(frame))
	var generic := PackedSpec.estimate_from_deployed(Vector3(2.0, 1.0, 1.0))
	_check("generic estimate shrinks but survives",
		PackedSpec.volume_m3(generic) < 2.0 and PackedSpec.volume_m3(generic) > 0.05)
	_check("estimates are marked", str(generic["source"]) == "estimated")


## The honest-fold contract (PACKING_PLAN.md Phase 0.5): the envelope is
## solved at the EFFECTIVE min fold angle — the user override moves it, the
## live fold angle does not, and two calls agree exactly.
func _test_linkage_packed_envelope() -> void:
	var p := LinkageParams.new()
	var s1: Dictionary = LinkageStructureBuilder.packed_spec_for(p)
	_check("linkage packed spec resolves", not s1.is_empty(), str(s1))
	if s1.is_empty():
		return
	_check("linkage packed computed source", str(s1["source"]) == "computed")
	_check("linkage packed form folded", str(s1["form"]) == "folded")
	_check("linkage packed dims positive", PackedSpec.volume_m3(s1) > 0.01)
	_check("linkage packed has mass", PackedSpec.has_mass(s1))
	# Default 8-module 8' design: wood + steel lands in the hundreds of kg,
	# not single digits or tonnes.
	_check("linkage packed mass band",
		float(s1["mass_kg"]) > 30.0 and float(s1["mass_kg"]) < 2000.0,
		str(s1["mass_kg"]))
	# Deterministic: same params, same answer.
	var s1b: Dictionary = LinkageStructureBuilder.packed_spec_for(p)
	_check("linkage packed deterministic", s1.hash() == s1b.hash())
	# The LIVE fold angle must not leak into the shipping dims.
	var p_folded := p.duplicate_params()
	p_folded.fold_angle = deg_to_rad(30.0)
	var p_open := p.duplicate_params()
	p_open.fold_angle = deg_to_rad(135.0)
	_check("live fold angle does not change packed dims",
		LinkageStructureBuilder.packed_spec_for(p_folded).hash()
			== LinkageStructureBuilder.packed_spec_for(p_open).hash())
	# A LOOSER user minimum (can't fold as tight) grows the radial envelope —
	# the "brackets used to intersect" fix expressed as a property.
	var p_loose := p.duplicate_params()
	p_loose.min_fold_angle_deg = 45.0
	var s_loose: Dictionary = LinkageStructureBuilder.packed_spec_for(p_loose)
	_check("looser min fold grows packed envelope",
		PackedSpec.volume_m3(s_loose) > PackedSpec.volume_m3(s1),
		"%f vs %f" % [PackedSpec.volume_m3(s_loose), PackedSpec.volume_m3(s1)])
	# Folded ships smaller than deployed: packed volume well under the
	# deployed ring's bounding volume (diameter² × height).
	var closed := LinkageKinematics.optimal_closed_angle(p)
	var frame: Dictionary = LinkageSolver.solve(p, closed)
	var dia_m: float = float(frame["max_rad"]) * 2.0 * 0.0254
	var h_m: float = float(frame["max_height"]) * 0.0254
	var deployed_vol := dia_m * dia_m * h_m
	_check("packed well under deployed bounding volume",
		PackedSpec.volume_m3(s1) < deployed_vol * 0.5,
		"%f vs %f" % [PackedSpec.volume_m3(s1), deployed_vol])


## Container catalog integrity (PACKING_PLAN.md Phase 1) — real published
## dims, so the checks pin known answers, not just shapes.
func _test_container_catalog() -> void:
	var seen: Dictionary = {}
	for entry in ContainerCatalog.all_containers():
		var cid := str(entry.get("id", ""))
		_check("container id unique '%s'" % cid, not seen.has(cid))
		seen[cid] = true
		_check("container kind valid '%s'" % cid,
			ContainerCatalog.KINDS.has(str(entry.get("kind", ""))))
		var inter: Dictionary = entry.get("interior", {})
		var il := float(inter.get("l_m", 0.0))
		var iw := float(inter.get("w_m", 0.0))
		var ih := float(inter.get("h_m", 0.0))
		_check("interior dims positive '%s'" % cid, il > 0.0 and iw > 0.0 and ih > 0.0)
		_check("payload positive '%s'" % cid, float(entry.get("payload_kg", 0.0)) > 0.0)
		var door = entry.get("door")
		if door != null:
			var dd := door as Dictionary
			_check("door fits its end wall '%s'" % cid,
				float(dd.get("w_m", 0.0)) <= iw + 0.01
					and float(dd.get("h_m", 0.0)) <= ih + 0.01,
				"door %s in %sx%s" % [str(dd), iw, ih])
		if entry.has("exterior"):
			var ext: Dictionary = entry.get("exterior", {})
			_check("exterior wraps interior '%s'" % cid,
				float(ext.get("l_m", 0.0)) >= il - 0.001
					and float(ext.get("w_m", 0.0)) >= iw - 0.001
					or str(entry.get("kind", "")) == "sub")
	# Known answers: 20' ISO interior ≈ 33.2 m³; 26' truck ≈ 1,682 cu ft claim.
	var c20 := ContainerCatalog.find("container_20")
	_check("20ft interior volume", absf(ContainerCatalog.interior_volume_m3(c20) - 33.2) < 0.4,
		str(ContainerCatalog.interior_volume_m3(c20)))
	var u26 := ContainerCatalog.find("uhaul_26")
	var u26_cuft := ContainerCatalog.interior_volume_m3(u26) / 0.0283168
	_check("26ft truck near published cu ft", u26_cuft > 1550.0 and u26_cuft < 1800.0,
		"%f cu ft" % u26_cuft)
	# The fleet quirk the notes call out: 15' payload exceeds the 20'.
	_check("15ft payload > 20ft payload",
		float(ContainerCatalog.find("uhaul_15")["payload_kg"])
			> float(ContainerCatalog.find("uhaul_20")["payload_kg"]))
	# The container's own packed spec = exterior + tare, upright.
	var ps := ContainerCatalog.packed_spec_for("container_20")
	_check("container packed spec resolves", not ps.is_empty())
	_check("container packed = exterior", absf(float(ps.get("w_m", 0.0)) - 6.058) < 0.001
		and absf(float(ps.get("h_m", 0.0)) - 2.591) < 0.001, str(ps))
	_check("container packed tare", absf(float(ps.get("mass_kg", 0.0)) - 2300.0) < 0.01)
	_check("vehicles are not cargo", ContainerCatalog.packed_spec_for("uhaul_15").is_empty())
	_check("kind filter", ContainerCatalog.containers_of_kind("sub").size() >= 4)


func _test_container_door_fit() -> void:
	var truck := ContainerCatalog.find("uhaul_15")  # door 2.21 x 1.96
	var slab := PackedSpec.normalize({"w_m": 3.0, "d_m": 1.9, "h_m": 0.4})
	_check("long slab passes lengthwise", ContainerCatalog.fits_through_door(truck, slab))
	var cube := PackedSpec.normalize({"w_m": 2.5, "d_m": 2.5, "h_m": 2.5})
	_check("oversize cube refused", not ContainerCatalog.fits_through_door(truck, cube))
	# Fits the VOLUME but not the DOOR — the check this API exists for.
	var tub := PackedSpec.normalize({"w_m": 2.2, "d_m": 2.2, "h_m": 2.0})
	var trailer := ContainerCatalog.find("trailer_6x12")
	_check("hot tub volume-fits but door-fails",
		PackedSpec.volume_m3(tub) < ContainerCatalog.interior_volume_m3(trailer)
			and not ContainerCatalog.fits_through_door(trailer, tub))
	var open_top := ContainerCatalog.find("pickup_bed")
	_check("open top always passes", ContainerCatalog.fits_through_door(open_top, cube))


func _test_container_builder() -> void:
	var node := CargoContainerBuilder.build_node({"container_id": "container_20"})
	_check("builder returns node", node != null)
	if node == null:
		return
	var mi := node.get_node_or_null("Mesh") as MeshInstance3D
	_check("builder has Mesh child", mi != null and mi.mesh != null)
	if mi != null and mi.mesh != null:
		_check("two surfaces (shell + doors)", mi.mesh.get_surface_count() == 2,
			str(mi.mesh.get_surface_count()))
		var aabb := mi.mesh.get_aabb()
		_check("AABB matches 20ft exterior",
			absf(aabb.size.z - 6.058) < 0.2 and absf(aabb.size.x - 2.438) < 0.2
				and absf(aabb.size.y - 2.591) < 0.2, str(aabb.size))
		_check("floor at local y=0", absf(aabb.position.y) < 0.05, str(aabb.position))
	_check("spec meta stamped",
		(node.get_meta("container_spec", {}) as Dictionary).get("container_id", "") == "container_20")
	var hc := CargoContainerBuilder.build_node({"container_id": "container_40hc"})
	var hc_mi := hc.get_node_or_null("Mesh") as MeshInstance3D
	if hc_mi != null and hc_mi.mesh != null:
		_check("40hc builds longer + taller",
			hc_mi.mesh.get_aabb().size.z > 12.0 and hc_mi.mesh.get_aabb().size.y > 2.8,
			str(hc_mi.mesh.get_aabb().size))
	var bogus := CargoContainerBuilder.build_node({"container_id": "no_such"})
	var bogus_mi := bogus.get_node_or_null("Mesh") as MeshInstance3D
	_check("unknown id falls back to 20ft",
		bogus_mi != null and absf(bogus_mi.mesh.get_aabb().size.z - 6.058) < 0.2)
	node.free()
	hc.free()
	bogus.free()


func _box_container(w: float, h: float, l: float, payload := 0.0) -> Dictionary:
	return {"id": "test_box", "kind": "container",
		"interior": {"w_m": w, "h_m": h, "l_m": l}, "door": null,
		"payload_kg": payload}


func _cube(edge: float, mass := 10.0, extra := {}) -> Dictionary:
	var d := {"w_m": edge, "d_m": edge, "h_m": edge, "mass_kg": mass,
		"stackable": true, "this_side_up": false, "label": "cube"}
	for k in extra:
		d[k] = extra[k]
	return d


## PackSolver known answers (PACKING_PLAN.md Phase 2).
func _test_solver_known_answers() -> void:
	var box := _box_container(2.0, 2.0, 2.0)
	var eight: Array = []
	for _i in 8:
		eight.append(_cube(1.0))
	var r := PackSolver.solve(box, eight)
	_check("8 unit cubes fill a 2-cube", bool(r["fit"])
		and (r["placements"] as Array).size() == 8, str(r["overflow"]))
	_check("perfect utilization", absf(float(r["utilization"]) - 1.0) < 1e-6,
		str(r["utilization"]))
	_check("total mass summed", absf(float(r["total_mass_kg"]) - 80.0) < 1e-6)
	_check("symmetric CoM centered", absf(float(r["com_len_frac"]) - 0.5) < 0.01,
		str(r["com_len_frac"]))
	# Deterministic: byte-identical placements across runs.
	var r2 := PackSolver.solve(box, eight)
	_check("solver deterministic", str(r["placements"]) == str(r2["placements"]))
	# 9th cube overflows with reason space.
	var nine := eight.duplicate()
	nine.append(_cube(1.0))
	var r9 := PackSolver.solve(box, nine)
	_check("9th cube overflows", not bool(r9["fit"])
		and (r9["overflow"] as Array).size() == 1
		and str(((r9["overflow"] as Array)[0] as Dictionary)["reason"]) == "space")
	_check("empty manifest fits", bool(PackSolver.solve(box, [])["fit"]))
	# A single box parked at the origin pulls the CoM toward the front.
	var one := PackSolver.solve(_box_container(2.0, 2.0, 4.0), [_cube(1.0)])
	_check("front-loaded CoM below half", float(one["com_len_frac"]) < 0.3,
		str(one["com_len_frac"]))


func _test_solver_constraints() -> void:
	# Door gate: fits the volume, not the aperture.
	var doored := _box_container(2.0, 2.0, 2.0)
	doored["door"] = {"w_m": 0.5, "h_m": 0.5}
	var rd := PackSolver.solve(doored, [_cube(1.0)])
	_check("door blocks oversize item",
		not bool(rd["fit"])
			and str(((rd["overflow"] as Array)[0] as Dictionary)["reason"]) == "door")
	# this_side_up refuses to lie a tall item down.
	var low := _box_container(2.0, 1.0, 2.0)
	var tall := {"w_m": 0.5, "d_m": 0.5, "h_m": 1.5, "mass_kg": 5.0,
		"stackable": true, "this_side_up": true, "label": "tank"}
	_check("this_side_up cannot lie down", not bool(PackSolver.solve(low, [tall])["fit"]))
	var tall_free := tall.duplicate()
	tall_free["this_side_up"] = false
	_check("free orientation lies down", bool(PackSolver.solve(low, [tall_free])["fit"]))
	# Non-stackable tops support nothing.
	var tower := _box_container(1.0, 3.0, 1.0)
	var frag := _cube(1.0, 10.0, {"stackable": false})
	var r_frag := PackSolver.solve(tower, [frag, frag.duplicate()])
	_check("no stacking on non-stackable", not bool(r_frag["fit"]))
	var r_stack := PackSolver.solve(tower, [_cube(1.0), _cube(1.0)])
	_check("stackables stack", bool(r_stack["fit"]))
	# Support needs >=50% footprint — a wide slab must not "rest" on a thin
	# pedestal top (tested against the support rule directly: largest-first
	# ordering makes the two-item solve arrange itself legally instead).
	var pedestal_box := [{"pos": Vector3.ZERO, "size": Vector3(0.4, 1.0, 0.4),
		"stackable": true, "mass": 5.0}]
	_check("no floating on a sliver",
		not PackSolver._supported(Vector3(0, 1.0, 0), Vector3(1.0, 0.5, 1.0), pedestal_box))
	var full_base := [{"pos": Vector3.ZERO, "size": Vector3(1.0, 1.0, 1.0),
		"stackable": true, "mass": 5.0}]
	_check("full base supports",
		PackSolver._supported(Vector3(0, 1.0, 0), Vector3(1.0, 0.5, 1.0), full_base))
	_check("non-stackable base supports nothing",
		not PackSolver._supported(Vector3(0, 1.0, 0), Vector3(0.4, 0.5, 0.4),
			[{"pos": Vector3.ZERO, "size": Vector3(1.0, 1.0, 1.0),
				"stackable": false, "mass": 5.0}]))
	# Payload reported, not blocking.
	var heavy := PackSolver.solve(_box_container(2.0, 2.0, 2.0, 50.0),
		[_cube(1.0, 40.0), _cube(1.0, 40.0)])
	_check("overweight still packs", bool(heavy["fit"]))
	_check("payload flag trips", not bool(heavy["payload_ok"]))


func _test_manifest() -> void:
	var graph_items: Array = [
		{"type": "panel", "is_virtual": true,
			"specs": {"name": "Mirror", "wmp": 400.0}},          # skipped: virtual
		{"type": "compound", "specs": {"name": "Group"}},         # skipped: compound
		{"type": "panel", "specs": {"name": "REC 410", "wmp": 410.0}},
		{"type": "panel", "specs": {"name": "REC 410", "wmp": 410.0}},
		{"type": "resource", "specs": {"name": "Water Tank 250",
			"capacity_qty": 946.0, "capacity_unit": "L"}},
		{"type": "resource", "specs": {"name": "Culvert Outlet",
			"capacity_qty": 1e12, "capacity_unit": "L"}},         # skipped: site infra
		{"type": "pbi", "specs": {"name": "Sunlight"}},           # skipped: abstract
	]
	var g := CampManifest.from_graph_items(graph_items)
	_check("graph sweep counts physical only", g.size() == 3, str(g.size()))
	var merged := CampManifest.merge(g)
	_check("identical panels merge qty 2", merged.size() == 2
		and int((merged[0] as Dictionary)["qty"]) == 2, str(merged))
	var props: Array = [
		{"model_id": "shiftpod"},
		{"model_id": "pine_1"},                                   # skipped: non-packable
		{"model_id": "cargo_container",
			"container_spec": {"container_id": "container_40"}},
	]
	var p := CampManifest.from_prop_records(props)
	_check("prop sweep resolves curated + container", p.size() == 2, str(p.size()))
	var forty := (p[1] as Dictionary)["spec"] as Dictionary
	_check("container prop uses its variant dims",
		absf(float(forty.get("w_m", 0.0)) - 12.192) < 0.01, str(forty))
	var units := CampManifest.expand_for_solver(merged)
	_check("expand honours qty", units.size() == 3, str(units.size()))
	var mass := CampManifest.total_mass_kg(merged)
	_check("mass totals known", float(mass["mass_kg"]) > 40.0
		and int(mass["unknown_count"]) == 0, str(mass))
	# Fleet report: a few totes fit the smallest vehicle.
	var totes: Array = []
	for _i in 4:
		totes.append({"label": "tote", "qty": 1, "spec": PackedSpec.normalize(
			{"w_m": 0.68, "d_m": 0.51, "h_m": 0.38, "mass_kg": 20.0})})
	var fleet := CampManifest.fleet_report(totes)
	_check("fleet report covers the shortlist",
		fleet.size() == CampManifest.FLEET_IDS.size())
	var van := (fleet[0] as Dictionary)["result"] as Dictionary
	_check("totes fit the cargo van", bool(van["fit"])
		and float(van["utilization"]) > 0.05, str(van["utilization"]))


func _leaf(label: String, w: float, d: float, h: float, mass := 5.0, qty := 1) -> Dictionary:
	return {"label": label, "qty": qty, "spec": {"w_m": w, "d_m": d, "h_m": h,
		"mass_kg": mass, "stackable": true, "this_side_up": false}}


## Nesting — PACKING_PLAN.md Phase 3: innermost-first, outer envelopes,
## escapes, depth guard.
func _test_pack_tree() -> void:
	# Leaf qty × spec.count expansion.
	var multi := _leaf("brick", 0.2, 0.1, 0.1, 1.0, 2)
	(multi["spec"] as Dictionary)["count"] = 3
	var flat := PackTree.flatten([multi])
	_check("qty x count expands", (flat["items"] as Array).size() == 6)
	# Tote with contents: parent sees ONE outer unit at exterior dims,
	# mass = tare + contents.
	var tote := {"label": "camp tote", "container_id": "tote_27gal", "qty": 1,
		"contents": [_leaf("mug", 0.1, 0.1, 0.1, 1.0, 3)]}
	var f2 := PackTree.flatten([tote])
	_check("tote flattens to one outer unit", (f2["items"] as Array).size() == 1)
	var outer := (f2["items"] as Array)[0] as Dictionary
	_check("outer unit at exterior dims", absf(float(outer["w_m"]) - 0.68) < 0.01,
		str(outer))
	_check("outer mass = tare + contents",
		absf(float(outer["mass_kg"]) - (2.5 + 3.0)) < 0.01, str(outer["mass_kg"]))
	_check("one scope solved", (f2["scopes"] as Array).size() == 1
		and bool(((f2["scopes"] as Array)[0] as Dictionary)["result"]["fit"]))
	# Escape: an item longer than the tote interior rides loose in the parent.
	var stuffed := {"label": "camp tote", "container_id": "tote_27gal", "qty": 1,
		"contents": [_leaf("mug", 0.1, 0.1, 0.1, 1.0, 1),
			_leaf("tent pole", 0.9, 0.05, 0.05, 2.0, 1)]}
	var f3 := PackTree.flatten([stuffed])
	_check("oversize content escapes to parent",
		(f3["items"] as Array).size() == 2 and (f3["escaped"] as Array).size() == 1,
		"%d items, %d escaped" % [(f3["items"] as Array).size(), (f3["escaped"] as Array).size()])
	var esc := (f3["items"] as Array)[1] as Dictionary
	_check("escape keeps its dims and is labeled loose",
		absf(float(esc["w_m"]) - 0.9) < 0.01 and str(esc["label"]).contains("loose"),
		str(esc))
	# Three levels: crate{ tote{ mug } } — masses cascade outward.
	var deep := {"label": "kit crate", "container_id": "crate_8x4", "qty": 1,
		"contents": [tote.duplicate(true)]}
	var f4 := PackTree.flatten([deep])
	_check("deep nest: one top unit, two scopes",
		(f4["items"] as Array).size() == 1 and (f4["scopes"] as Array).size() == 2)
	var crate_out := (f4["items"] as Array)[0] as Dictionary
	_check("crate mass cascades (45 + 2.5 + 3)",
		absf(float(crate_out["mass_kg"]) - 50.5) < 0.01, str(crate_out["mass_kg"]))
	# qty > 1 containers: identical instances, one scope entry, N outer units.
	var two_totes := tote.duplicate(true)
	two_totes["qty"] = 2
	var f5 := PackTree.flatten([two_totes])
	_check("qty containers replicate outer units",
		(f5["items"] as Array).size() == 2 and (f5["scopes"] as Array).size() == 1
			and int(((f5["scopes"] as Array)[0] as Dictionary)["qty"]) == 2)
	# Depth guard terminates pathological nesting.
	var chain: Dictionary = _leaf("pebble", 0.05, 0.05, 0.05)
	for _i in 12:
		chain = {"label": "box", "container_id": "tote_27gal", "qty": 1,
			"contents": [chain]}
	var f6 := PackTree.flatten([chain])
	_check("depth guard trips", bool(f6["depth_exceeded"]))
	# End-to-end nested solve into a truck, deterministic.
	var r1 := PackTree.solve(ContainerCatalog.find("uhaul_10"), [deep, two_totes])
	_check("nested solve fits the truck", bool(r1["fit"]), str(r1.get("overflow")))
	var r2 := PackTree.solve(ContainerCatalog.find("uhaul_10"), [deep, two_totes])
	_check("nested solve deterministic", str(r1["placements"]) == str(r2["placements"]))


## Pack definitions — builtin kits realize, solve self-consistently, and the
## def store round-trips without touching real user data.
func _test_pack_defs() -> void:
	var star := PackDefs.realize("starshade_kit")
	_check("starshade kit realizes 2 units", star.size() == 2, str(star.size()))
	var r := PackTree.solve(ContainerCatalog.find("container_20"), star)
	_check("starshade kit fits a 20ft container", bool(r["fit"]), str(r.get("overflow")))
	_check("starshade kit is self-consistent (no escapes)",
		(r["escaped"] as Array).is_empty(), str(r["escaped"]))
	_check("starshade crate scope fits",
		bool(((r["scopes"] as Array)[0] as Dictionary)["result"]["fit"]))
	var starter := PackDefs.realize("solar_starter_kit")
	var rv := PackTree.solve(ContainerCatalog.find("cargo_van"), starter)
	_check("starter kit fits the cargo van + no escapes",
		bool(rv["fit"]) and (rv["escaped"] as Array).is_empty(),
		str(rv.get("escaped")))
	# Realize is a deep copy: mutating it never edits the def.
	var mutant := PackDefs.realize("starshade_kit")
	((mutant[0] as Dictionary)["contents"] as Array).clear()
	var fresh := PackDefs.realize("starshade_kit")
	_check("realize deep-copies",
		not ((fresh[0] as Dictionary)["contents"] as Array).is_empty())
	_check("unknown def realizes empty", PackDefs.realize("no_such_kit").is_empty())
	# User-def store: snapshot whatever exists, exercise, restore exactly.
	var pre_existing := FileAccess.file_exists(PackDefs.USER_PATH)
	var pre_text := ""
	if pre_existing:
		pre_text = FileAccess.get_file_as_string(PackDefs.USER_PATH)
	var test_defs: Array = [
		{"id": "t_ref_kit", "label": "Ref kit", "units": [
			{"def_ref": "solar_starter_kit"},
			_leaf("spare fuse box", 0.15, 0.1, 0.08, 0.5)]},
		{"id": "t_cycle", "label": "Cycle", "units": [{"def_ref": "t_cycle"}]},
	]
	_check("save_user writes", PackDefs.save_user(test_defs))
	_check("load_user round-trips", PackDefs.load_user().size() == 2)
	var reffed := PackDefs.realize("t_ref_kit")
	_check("def_ref splices another def", reffed.size() == 2, str(reffed.size()))
	_check("spliced unit is the tote",
		str((reffed[0] as Dictionary).get("container_id", "")) == "tote_27gal")
	_check("def cycle terminates empty", PackDefs.realize("t_cycle").is_empty())
	if pre_existing:
		var f := FileAccess.open(PackDefs.USER_PATH, FileAccess.WRITE)
		f.store_string(pre_text)
	else:
		DirAccess.remove_absolute(PackDefs.USER_PATH)
	_check("user store restored",
		FileAccess.file_exists(PackDefs.USER_PATH) == pre_existing)


func _form_aabb(node: Node3D) -> AABB:
	var mesh_root := node.get_node_or_null("Mesh") as Node3D
	var out := AABB()
	var first := true
	for child in mesh_root.get_children():
		if not (child is MeshInstance3D):
			continue
		var mi := child as MeshInstance3D
		var ab := mi.mesh.get_aabb()
		ab.position += mi.position
		out = ab if first else out.merge(ab)
		first = false
	return out


## Phase 5: the PACKED world form. The crate node is what PlacedPropRuntime
## builds for a `packed: true` record — dims must match the spec and the
## floor must sit at local y=0 (the prop grounding contract).
## "What is inside this crate" — the crosshair focus + edit drawer share this
## one helper, so its ladder is pinned here: a folded linkage design describes
## itself from its params; everything else gets the catalog label + shipping
## dims (delivery context needs a live scene and is exercised windowed).
func _test_packed_contents_label() -> void:
	var p := LinkageParams.new()
	var lk := PlacedPropRuntime.packed_contents_label(
		{"linkage_spec": p.to_config(), "packed": true})
	_check("linkage crate names its modules",
		lk.begins_with("Folded structure") and str(p.modules) in lk, lk)
	var gen := PlacedPropRuntime.packed_contents_label(
		{"model_id": "cargo_container", "packed": true,
			"container_spec": {"container_id": "container_20"}})
	_check("generic crate leads with the catalog label",
		gen.begins_with("Shipping Container"), gen)
	_check("generic crate carries the shipping dims", "·" in gen, gen)
	var unknown := PlacedPropRuntime.packed_contents_label(
		{"model_id": "no_such_model_xyz", "packed": true})
	_check("unknown model still yields a readable label",
		not unknown.is_empty(), unknown)


func _test_packed_form_builder() -> void:
	var crate := PackedFormBuilder.build_node(PackedSpec.normalize(
		{"w_m": 2.0, "d_m": 1.0, "h_m": 0.5, "form": "crate"}))
	var ab := _form_aabb(crate)
	_check("crate AABB matches spec",
		absf(ab.size.x - 2.0) < 0.06 and absf(ab.size.z - 1.0) < 0.06
			and absf(ab.size.y - 0.5) < 0.06, str(ab.size))
	_check("crate floor at y=0", absf(ab.position.y) < 0.02, str(ab.position))
	var tank := PackedFormBuilder.build_node(PackedSpec.normalize(
		{"w_m": 0.6, "d_m": 0.6, "h_m": 0.9, "form": "tank", "this_side_up": true}))
	var tab := _form_aabb(tank)
	_check("tank is a cylinder (round footprint, authored height)",
		absf(tab.size.x - tab.size.z) < 0.01 and absf(tab.size.y - 0.9) < 0.02,
		str(tab.size))
	for form in ["bundle", "panel_stack", "pallet", "folded", "loose"]:
		var n := PackedFormBuilder.build_node(PackedSpec.normalize(
			{"w_m": 1.2, "d_m": 0.8, "h_m": 0.6, "form": form}))
		var fab := _form_aabb(n)
		_check("form '%s' builds at spec size" % form,
			fab.size.x > 1.1 and fab.size.y > 0.55 and fab.size.z > 0.75,
			str(fab.size))
		n.free()
	# The runtime's record resolver: container records use their variant,
	# curated models resolve, non-packable records resolve empty (and thus
	# deploy normally even when flagged packed).
	var r1 := PlacedPropRuntime.packed_spec_for_record(
		{"model_id": "cargo_container",
			"container_spec": {"container_id": "container_40"}})
	_check("record resolver honours container variant",
		absf(float(r1.get("w_m", 0.0)) - 12.192) < 0.01, str(r1))
	_check("record resolver curated model",
		not PlacedPropRuntime.packed_spec_for_record({"model_id": "shiftpod"}).is_empty())
	_check("record resolver non-packable empty",
		PlacedPropRuntime.packed_spec_for_record({"model_id": "pine_1"}).is_empty())
	crate.free()
	tank.free()


## NpcHaulModel — the first emergent group-behavior primitive. The checks
## pin the EMERGENT properties, not just the arithmetic: the strategy flips
## with crew density, and a saturated brigade's throughput stops caring
## about route length. Nobody scripted either rule.
func _test_haul_model() -> void:
	# TEAM-LIFT crew sizing (NIOSH 23 kg solo ceiling; ~0.85 team efficiency;
	# ≥1.8 m needs a hand on each end whatever it weighs; cap 4).
	_check("light load is a solo carry", NpcHaulModel.carriers_for(20.0) == 1)
	_check("unknown mass reads as light", NpcHaulModel.carriers_for(-1.0) == 1)
	_check("35 kg is a two-person lift", NpcHaulModel.carriers_for(35.0) == 2)
	_check("55 kg takes three", NpcHaulModel.carriers_for(55.0) == 3,
		str(NpcHaulModel.carriers_for(55.0)))
	_check("300 kg caps at four hands", NpcHaulModel.carriers_for(300.0) == 4)
	_check("a long light beam still takes two",
		NpcHaulModel.carriers_for(8.0, 2.4) == 2)
	_check("carriers monotone in mass",
		NpcHaulModel.carriers_for(70.0) >= NpcHaulModel.carriers_for(45.0))
	_check("solo can't brigade", NpcHaulModel.brigade_throughput(1, 20.0) == 0.0
		and NpcHaulModel.brigade_throughput(2, 20.0) == 0.0)
	_check("solo plan is round trips",
		str(NpcHaulModel.best_plan(1, 20.0, 10)["strategy"]) == "round_trip")
	# Sparse crew on a long route: independent round trips win.
	var long_sparse := NpcHaulModel.best_plan(3, 60.0, 20)
	_check("sparse long route → round trips",
		str(long_sparse["strategy"]) == "round_trip", str(long_sparse))
	# Dense crew on a short route: the bucket brigade wins.
	var short_dense := NpcHaulModel.best_plan(8, 10.0, 20)
	_check("dense short route → brigade",
		str(short_dense["strategy"]) == "brigade", str(short_dense))
	# EMERGENT: once spacing ≤ arm reach, throughput = 1/t_handoff and the
	# route length drops out entirely.
	var sat_short := NpcHaulModel.brigade_throughput(15, 20.0)
	var sat_long := NpcHaulModel.brigade_throughput(41, 60.0)
	_check("saturated brigade is length-independent",
		absf(sat_short - sat_long) < 1e-9
			and absf(sat_short - 1.0 / NpcHaulModel.T_HANDOFF_S) < 1e-9,
		"%f vs %f" % [sat_short, sat_long])
	# More hands never slow the job.
	var prev := 0.0
	for n in range(1, 13):
		var ups := float(NpcHaulModel.best_plan(n, 20.0, 10)["throughput_ups"])
		_check("workers monotonic n=%d" % n, ups >= prev - 1e-9,
			"%f < %f" % [ups, prev])
		prev = ups
	# Brigade ETA pays the pipeline fill latency.
	var bp := NpcHaulModel.best_plan(8, 10.0, 20)
	_check("brigade eta includes fill latency",
		float(bp["eta_s"]) > 20.0 / float(bp["throughput_ups"]), str(bp))
	_check("zero units instant", float(NpcHaulModel.best_plan(4, 20.0, 0)["eta_s"]) == 0.0)
	var chore := NpcHaulModel.chore_spec("Unload delivery", 4, 20.0, 7)
	_check("chore spec shaped for the board",
		float(chore["chore_hours"]) > 0.0 and chore.has("haul_plan")
			and str(chore["exposure"]) == "outdoor", str(chore))


## Phase 6 delivery scenarios — spawn is real prop records, progress is just
## counting them, so the whole Phase 5 loop IS the gameplay.
## Round 3: the in-container stow plan and its LIFO unload order.
func _test_stow_plan() -> void:
	var plan := UnpackScenario.stow_plan("starter_camp")
	_check("stow plan solves", bool(plan.get("ok", false)))
	var items: Array = plan.get("items", [])
	var placements: Array = plan.get("placements", [])
	var order: Array = plan.get("order", [])
	_check("one item per delivered unit", items.size() == 7, str(items.size()))

	# Deterministic: two solves of the same scenario must agree exactly, or the
	# same delivery would stow differently between runs (and between the plan
	# the selftest pins and the one spawn() places).
	_check("stow plan is deterministic",
		JSON.stringify(plan) == JSON.stringify(UnpackScenario.stow_plan("starter_camp")))

	# EVERY item must be this_side_up. A spawned crate is a BoxMesh with yaw
	# applied and nothing else, so of the solver's six axis permutations only
	# two are renderable — this flag is what restricts it to those two.
	var upright := true
	for it in items:
		if not bool((it as Dictionary).get("this_side_up", false)):
			upright = false
	_check("every stow item is this_side_up (only yaw is renderable)", upright)

	# A total order over the placements, no gaps and no repeats.
	var seen: Dictionary = {}
	for oi in order:
		seen[int(oi)] = true
	_check("order is a permutation of the placements",
		order.size() == placements.size() and seen.size() == order.size())

	# THE invariant: never take a box out from under a box still resting on it.
	var box_of: Dictionary = {}
	for pl in placements:
		box_of[int((pl as Dictionary)["item_index"])] = pl
	var lifo_ok := true
	for i in order.size():
		var lower: Dictionary = box_of.get(int(order[i]), {})
		if lower.is_empty():
			continue
		var lp: Vector3 = lower["pos"]
		var ls: Vector3 = lower["size"]
		for j in range(i + 1, order.size()):
			var upper: Dictionary = box_of.get(int(order[j]), {})
			if upper.is_empty():
				continue
			var up: Vector3 = upper["pos"]
			var us: Vector3 = upper["size"]
			# Still-present box sitting directly on the one being removed?
			if absf(up.y - (lp.y + ls.y)) > 0.001:
				continue
			var ox := minf(lp.x + ls.x, up.x + us.x) - maxf(lp.x, up.x)
			var oz := minf(lp.z + ls.z, up.z + us.z) - maxf(lp.z, up.z)
			if ox > 0.001 and oz > 0.001:
				lifo_ok = false
	_check("LIFO order never unloads a box with load still on top", lifo_ok)

	# Every placement is inside the interior, in the solver's own frame.
	var interior: Dictionary = plan.get("interior", {})
	var bounded := true
	for pl2 in placements:
		var p: Vector3 = (pl2 as Dictionary)["pos"]
		var s: Vector3 = (pl2 as Dictionary)["size"]
		if p.x < -0.001 or p.y < -0.001 or p.z < -0.001 \
				or p.x + s.x > float(interior.get("w_m", 0.0)) + 0.001 \
				or p.y + s.y > float(interior.get("h_m", 0.0)) + 0.001 \
				or p.z + s.z > float(interior.get("l_m", 0.0)) + 0.001:
			bounded = false
	_check("every placement is inside the interior", bounded)

	# The linkage kit resolves its crate from the DESIGN, not the catalog.
	var kit := UnpackScenario.stow_plan("starshade_kit")
	_check("linkage kit stows its solved envelope", bool(kit.get("ok", false))
		and (kit["items"] as Array).size() == 1)
	_check("unknown scenario yields no plan",
		not bool(UnpackScenario.stow_plan("no_such").get("ok", true)))


func _test_unpack_scenario() -> void:
	_check("scenario catalog lists both", UnpackScenario.scenario_ids().size() >= 2)
	var layer := PlacedPropLayer.new()
	var res := UnpackScenario.spawn(layer, "starter_camp", 100.0, 200.0, 30.0)
	_check("spawn returns container + crates", not res.is_empty()
		and not str(res.get("container_prop_id", "")).is_empty(), str(res))
	var crate_ids: Array = res.get("crate_ids", [])
	_check("starter camp spawns 7 crates", crate_ids.size() == 7, str(crate_ids.size()))
	var cont := layer.find_by_id(str(res["container_prop_id"]))
	_check("container carries its variant",
		str((cont.get("container_spec", {}) as Dictionary).get("container_id", "")) == "container_20")
	var all_packed := true
	for pid in crate_ids:
		var rec := layer.find_by_id(str(pid))
		all_packed = all_packed and bool(rec.get("packed", false))
	_check("every crate spawns packed", all_packed)
	# v3: crates ride INSIDE the container (the old check asserted the
	# opposite — that they stood clear of it). Project each crate back into
	# container-local axes and require it inside the interior footprint, at a
	# legal stack height.
	var sc_plan := UnpackScenario.stow_plan("starter_camp")
	var interior: Dictionary = sc_plan.get("interior", {})
	var yaw_r := deg_to_rad(30.0)
	var fwd := Vector2(sin(yaw_r), cos(yaw_r))
	var side := Vector2(fwd.y, -fwd.x)
	# Slot -> the height the solver put that item at, so the world placement can
	# be checked against the plan rather than against a guess. (Whether THIS
	# scenario happens to stack is a property of its contents, not of the code:
	# the seven starter-camp crates fit the floor. The contract worth pinning
	# is that y_offset tracks the solved height exactly, stacked or not.)
	var solved_y: Dictionary = {}
	for pl in sc_plan.get("placements", []):
		solved_y[int((pl as Dictionary)["item_index"])] = float(((pl as Dictionary)["pos"] as Vector3).y)
	var all_inside := true
	var heights_ok := true
	var heights_match := true
	for pid in crate_ids:
		var rec := layer.find_by_id(str(pid))
		if str(rec.get("stowed_in", "")).is_empty():
			continue   # overflow rows legitimately sit outside
		var d := Vector2(float(rec["x"]) - 100.0, float(rec["z"]) - 200.0)
		var along := d.dot(fwd)
		var across := d.dot(side)
		if absf(along) > float(interior.get("l_m", 0.0)) * 0.5 + 0.01 \
				or absf(across) > float(interior.get("w_m", 0.0)) * 0.5 + 0.01:
			all_inside = false
		var yo := float(rec.get("y_offset", 0.0))
		if yo < -0.001 or yo > float(interior.get("h_m", 0.0)):
			heights_ok = false
		var slot := int(rec.get("delivery_slot", -1))
		if solved_y.has(slot) and absf(yo - float(solved_y[slot])) > 0.001:
			heights_match = false
	_check("stowed crates sit inside the container footprint", all_inside)
	_check("stack heights are legal", heights_ok)
	# y_offset is EXACT, not approximate: a crate's origin is its own floor and
	# the container's floor is local Y=0, so no deck fudge is involved.
	_check("y_offset equals the solved stack height", heights_match)
	var collision_off := true
	for pid2 in crate_ids:
		var r2 := layer.find_by_id(str(pid2))
		if not str(r2.get("stowed_in", "")).is_empty() \
				and bool(r2.get("collision_enabled", true)):
			collision_off = false
	_check("stowed crates have collision off", collision_off)
	# A null patch value ERASES. Callers use null for "no longer applies"
	# (stowed_in on a hauled crate, build_state on a finished build), and a
	# stored null reads back as the string "<null>" — which is not empty, so
	# every `str(rec.get(k, "")).is_empty()` guard would think the flag is
	# still set. That exact cascade blocked an erect-phase deploy once.
	var probe_id := str(crate_ids[0])
	layer.update_prop(probe_id, {"stowed_in": null})
	_check("a null patch erases the key",
		not layer.find_by_id(probe_id).has("stowed_in"))
	_check("erased key reads as absent",
		str(layer.find_by_id(probe_id).get("stowed_in", "")).is_empty())
	# A future unit-list change that no longer fits must fail HERE, loudly,
	# rather than silently regressing every delivery to the door stack.
	_check("starter camp fits its 20' interior",
		(sc_plan.get("overflow", []) as Array).is_empty(),
		str(sc_plan.get("overflow", [])))
	# v2 (Site Projects): crates land at the DOOR and carry the staging slot
	# they are destined for — the unload haul is real distance, not theater.
	var idents_ok := true
	var min_haul := INF
	var slots_seen: Dictionary = {}
	for pid in crate_ids:
		var rec := layer.find_by_id(str(pid))
		var st: Dictionary = rec.get("staging", {})
		if str(rec.get("delivery_id", "")) != str(res["container_prop_id"]) \
				or not st.has("x") or not st.has("z"):
			idents_ok = false
			continue
		slots_seen[int(rec.get("delivery_slot", -1))] = true
		min_haul = minf(min_haul, Vector2(float(st["x"]) - float(rec.get("x", 0.0)),
			float(st["z"]) - float(rec.get("z", 0.0))).length())
	_check("every crate carries delivery identity + staging slot", idents_ok)
	_check("delivery slots are distinct", slots_seen.size() == crate_ids.size())
	_check("staging is a real haul away", min_haul > 4.0, str(min_haul))
	var dl: Dictionary = UnpackScenario.delivery_record(layer, str(res["container_prop_id"]))
	_check("container persists the delivery blob",
		str(dl.get("scenario_id", "")) == "starter_camp"
			and (dl.get("crate_ids", []) as Array).size() == 7)
	# Kit → scenario mapping is explicit; unmapped kits refuse rather than
	# silently coercing to the starter camp (the old Solar-Starter-Kit trap).
	_check("kit maps through pack_kit_id",
		UnpackScenario.scenario_for_kit("starshade_kit") == "starshade_kit")
	_check("unmapped kit maps to nothing",
		UnpackScenario.scenario_for_kit("solar_starter_kit").is_empty()
			and UnpackScenario.scenario_for_kit("").is_empty())
	# Progress tracks the Phase 5 records directly.
	var p0 := UnpackScenario.progress(layer, crate_ids)
	_check("starts fully packed", int(p0["packed"]) == 7 and not bool(p0["done"]))
	layer.update_prop(str(crate_ids[0]), {"packed": false})
	var p1 := UnpackScenario.progress(layer, crate_ids)
	_check("unpack counts", int(p1["unpacked"]) == 1 and int(p1["packed"]) == 6)
	for pid in crate_ids:
		layer.update_prop(str(pid), {"packed": false})
	_check("all unpacked = done", bool(UnpackScenario.progress(layer, crate_ids)["done"]))
	layer.remove_prop(str(crate_ids[1]))
	_check("deleted crate counts missing, still done",
		int(UnpackScenario.progress(layer, crate_ids)["missing"]) == 1
			and bool(UnpackScenario.progress(layer, crate_ids)["done"]))
	# The linkage scenario ships a real default design in its crate.
	var res2 := UnpackScenario.spawn(layer, "starshade_kit", 0.0, 0.0)
	var link_rec := layer.find_by_id(str((res2["crate_ids"] as Array)[0]))
	_check("linkage crate carries a v30 design",
		(link_rec.get("linkage_spec", {}) as Dictionary).has("structure"))
	_check("crew estimate spans the kit",
		int(UnpackScenario.crew_estimate("starter_camp", 20.0, 4)["units"]) == 7)
	_check("unknown scenario spawns empty",
		UnpackScenario.spawn(layer, "no_such", 0.0, 0.0).is_empty())


## NpcCrewPlan — the pit-crew scheduler. Checks pin the classic emergent
## scheduling facts: the two lower bounds hold, more hands never hurt,
## makespan flatlines at the critical path once parallelism is exhausted,
## and a task's minimum-crew gate (the barn raise) blocks small crews.
func _test_crew_plan() -> void:
	# Diamond DAG known answer: A → (B ∥ C) → D, 60 person-s each, max 1.
	var diamond: Array = [
		{"id": "a", "label": "A", "work_s": 60.0, "max_workers": 1, "deps": []},
		{"id": "b", "label": "B", "work_s": 60.0, "max_workers": 1, "deps": ["a"]},
		{"id": "c", "label": "C", "work_s": 60.0, "max_workers": 1, "deps": ["a"]},
		{"id": "d", "label": "D", "work_s": 60.0, "max_workers": 1, "deps": ["b", "c"]},
	]
	var d1 := NpcCrewPlan.schedule(diamond, 1)
	var d2 := NpcCrewPlan.schedule(diamond, 2)
	_check("diamond solo = 240 s", absf(float(d1["makespan_s"]) - 240.0) < 0.01,
		str(d1["makespan_s"]))
	_check("diamond pair = 180 s (B ∥ C)", absf(float(d2["makespan_s"]) - 180.0) < 0.01,
		str(d2["makespan_s"]))
	_check("diamond critical path 180", absf(float(d2["critical_path_s"]) - 180.0) < 0.01)
	_check("solo fully busy", absf(float(d1["utilization"]) - 1.0) < 1e-6)
	# The real linkage fab graph from a REAL solve's part counts.
	var p := LinkageParams.new()
	var frame: Dictionary = LinkageSolver.solve(p, p.fold_angle)
	var counts := {
		"beam_count": (frame["beams"] as Array).size(),
		"bracket_count": (frame["brackets"] as Array).size(),
		"bolt_count": (frame["bolts"] as Array).size(),
		"module_count": p.modules, "panel_count": 0,
	}
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	_check("fab graph has the seven phases", tasks.size() == 7, str(tasks.size()))
	# Small crews can't raise the structure — blocked at the barn threshold.
	var r5 := NpcCrewPlan.schedule(tasks, 5)
	_check("5 ppl blocked at the raise", not bool(r5["feasible"])
		and str(r5["blocked_id"]) == "erect", str(r5["blocked_id"]))
	# Feasible crews: both lower bounds hold, more hands never hurt.
	var prev := INF
	var cp := 0.0
	for n in range(6, 25, 2):
		var r := NpcCrewPlan.schedule(tasks, n)
		_check("feasible at n=%d" % n, bool(r["feasible"]))
		cp = float(r["critical_path_s"])
		var ms := float(r["makespan_s"])
		_check("bounds hold n=%d" % n,
			ms >= cp - 0.01 and ms >= float(r["floor_s"]) - 0.01,
			"%f vs cp %f floor %f" % [ms, cp, float(r["floor_s"])])
		_check("monotone n=%d" % n, ms <= prev + 0.01, "%f > %f" % [ms, prev])
		prev = ms
	# Saturation: past the graph's parallelism the makespan flatlines.
	var sat_a := float(NpcCrewPlan.schedule(tasks, 48)["makespan_s"])
	var sat_b := float(NpcCrewPlan.schedule(tasks, 96)["makespan_s"])
	_check("saturated makespan flatlines", absf(sat_a - sat_b) < 0.01,
		"%f vs %f" % [sat_a, sat_b])
	_check("saturated ≥ critical path", sat_a >= cp - 0.01)
	# The recommendation: smallest crew within 10% of saturated.
	var reco := NpcCrewPlan.recommend_crew(tasks, 24)
	_check("recommended crew is real", int(reco["n"]) >= 6 and int(reco["n"]) <= 24,
		str(reco))
	_check("recommended hits the slack target",
		float(reco["makespan_s"]) <= float(reco["saturated_s"]) * 1.1 + 0.01)
	# Determinism + docs output.
	var ra := NpcCrewPlan.schedule(tasks, 8)
	var rb := NpcCrewPlan.schedule(tasks, 8)
	_check("schedule deterministic", str(ra["timeline"]) == str(rb["timeline"]))
	var gantt := NpcCrewPlan.timeline_text(ra)
	_check("gantt renders bars", gantt.contains("█") and gantt.contains("total"),
		gantt.left(60))
	_check("infeasible gantt says so",
		NpcCrewPlan.timeline_text(r5).contains("infeasible"))
	# Chore bridge: start-time order, first chore is the first fab phase.
	var chores := NpcCrewPlan.chore_specs(tasks, ra)
	_check("chores in schedule order", chores.size() == 7
		and str((chores[0] as Dictionary)["label"]).begins_with("Cut"),
		str((chores[0] as Dictionary).get("label", "")))
	_check("chores carry dependency groundwork",
		(chores[2] as Dictionary).has("depends_on")
			and float((chores[1] as Dictionary)["chore_hours"]) > 0.0)
	# Min-first dealing: a high-rank hog can't starve a min-2 task.
	var pair: Array = [
		{"id": "hog", "label": "Hog", "work_s": 600.0, "max_workers": 10, "deps": []},
		{"id": "duo", "label": "Duo", "work_s": 60.0, "min_workers": 2,
			"max_workers": 2, "deps": []},
	]
	var rp := NpcCrewPlan.schedule(pair, 3)
	_check("min-first anti-starvation", bool(rp["feasible"]), str(rp))
	for row in rp["timeline"]:
		if str((row as Dictionary)["id"]) == "duo":
			_check("duo starts immediately", float((row as Dictionary)["start_s"]) < 0.01,
				str(row))
	_check("empty graph instant",
		float(NpcCrewPlan.schedule([], 4)["makespan_s"]) == 0.0)

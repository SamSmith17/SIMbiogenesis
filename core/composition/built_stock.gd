class_name BuiltStock
extends RefCounted

## What is stored in the things built on a site (resource composition plan
## Phase 9). Pure over prop records:
##
##   of_record(rec)       {known, skip, kg, materials {material: kg}, est,
##                        source}: what one placed structure is made of
##   site(records)        the built stock: kg, water held, elements, energy,
##                        by_material, how many structures, how many unknown
##   embodied(materials)  {kg, water_kg, elements, energy_mj}
##   salvage_kinds(mats)  {kinds {resource kind: kg}, kept {material: kg}}:
##                        what taking it down would put into stores
##   salvage_into(model, scope, kinds, at)  credit it to the graph's stores,
##                        a new "<Kind> (salvaged)" store where none has room
##   describe(mats)       "70 kg lumber, 12 kg steel"
##
## Where the material comes from, strongest first:
##   - a designer's own spec: the Linkage frame's wood and steel (its
##     shipping spec carries the split), every other designer's packing
##     parts each given a material from that designer's own stock (a dome's
##     strut stock and cover sheet, a rack's uprights / lumber / sheets, a
##     solar array's rails and modules …);
##   - MODEL_MATERIALS: the shipped models, by share of their packed mass
##     (estimates, from the models' look and published kit weights);
##   - otherwise unknown: the mass is counted, the elements are not.
## Vehicles and living things are not built stock (SKIP_MODELS, catalog
## "vehicle" entries); things built from the site's own earth are left out.

## Material id -> {kind: CompositionData row, salvage: resource kind ("" =
## kept whole: reuse it), label}.
const MATERIALS := {
	"lumber": {"kind": "lumber", "salvage": "lumber", "label": "lumber"},
	"plywood": {"kind": "mat_plywood", "salvage": "lumber", "label": "plywood"},
	"steel": {"kind": "mat_steel", "salvage": "scrap_metal", "label": "steel"},
	"aluminium": {"kind": "mat_aluminium", "salvage": "scrap_metal", "label": "aluminium"},
	"hdpe": {"kind": "mat_hdpe", "salvage": "plastic_waste", "label": "HDPE"},
	"pp": {"kind": "mat_pp", "salvage": "plastic_waste", "label": "polypropylene"},
	"pvc": {"kind": "mat_pvc", "salvage": "plastic_waste", "label": "PVC"},
	"pc": {"kind": "mat_pc", "salvage": "plastic_waste", "label": "polycarbonate"},
	"pmma": {"kind": "mat_pmma", "salvage": "plastic_waste", "label": "acrylic"},
	"fabric": {"kind": "mat_fabric", "salvage": "plastic_waste", "label": "fabric"},
	"glass": {"kind": "mat_glass", "salvage": "rubble", "label": "glass"},
	"concrete": {"kind": "mat_concrete", "salvage": "rubble", "label": "concrete"},
	"pv_module": {"kind": "mat_pv_module", "salvage": "", "label": "solar modules"},
}

## Shipped models by share of packed mass. All estimates.
const MODEL_MATERIALS := {
	"shiftpod": {"fabric": 0.55, "aluminium": 0.40, "steel": 0.05},
	"carport": {"steel": 0.70, "hdpe": 0.30},
	"ez_up": {"steel": 0.75, "fabric": 0.25},
	"starshade": {"aluminium": 0.55, "pv_module": 0.35, "steel": 0.10},
	"starshade_center_camp": {"aluminium": 0.80, "steel": 0.10, "fabric": 0.10},
	"starshade_man_effigy": {"lumber": 0.80, "steel": 0.20},
	"grow_bed": {"lumber": 0.85, "steel": 0.15},
	"bed": {"lumber": 0.50, "fabric": 0.50},
	"vawt": {"steel": 0.70, "aluminium": 0.30},
	"csp_trough": {"steel": 0.75, "glass": 0.25},
	"small_hawt": {"steel": 0.60, "aluminium": 0.20, "pp": 0.20},
	"hydroturbine": {"steel": 1.0},
	"powerspout_plt": {"steel": 0.60, "aluminium": 0.20, "pp": 0.20},
	"ali_pelton": {"aluminium": 0.50, "steel": 0.50},
	"site_gate": {"lumber": 0.90, "steel": 0.10},
	"firepit": {"steel": 1.0},
	"waste_bin": {"hdpe": 1.0},
	"stream_intake": {"hdpe": 0.80, "steel": 0.20},
	"heliostat": {"steel": 0.70, "glass": 0.30},
	"home_biogas_2": {"hdpe": 0.90, "steel": 0.10},
	"biochar_reactor": {"steel": 1.0},
	"cnc_router": {"steel": 0.60, "aluminium": 0.40},
	"trash_printer": {"steel": 0.70, "aluminium": 0.30},
	"mud_printer": {"steel": 0.80, "aluminium": 0.20},
	"pp_shredder": {"steel": 1.0},
	"pp_beam_extruder": {"steel": 1.0},
	"pp_sheet_press": {"steel": 1.0},
	"geodesic_dome": {"steel": 0.60, "pc": 0.40},
	"pallet_rack": {"steel": 0.80, "plywood": 0.20},
	"pv_array": {"aluminium": 0.25, "pv_module": 0.75},
	"pvlab_array": {"aluminium": 0.25, "pv_module": 0.75},
	"linkage_structure": {"lumber": 0.88, "steel": 0.12},
	"flatpack_furniture": {"plywood": 1.0},
	"parametric_building": {"lumber": 0.70, "plywood": 0.20, "steel": 0.10},
	"esplab_board": {"steel": 0.70, "pp": 0.30},
	"farmbot": {"aluminium": 0.60, "lumber": 0.30, "steel": 0.10},
	"cargo_container": {"steel": 1.0},
	"intermodal_unit": {"lumber": 1.0},
	"domelab_structure": {"steel": 0.60, "pc": 0.40},
	"toroidlab_structure": {"steel": 0.60, "pp": 0.20, "pv_module": 0.20},
	"peltonlab_turbine": {"steel": 1.0},
	"windlab_turbine": {"steel": 0.60, "pp": 0.40},
	"gantry_machine": {"aluminium": 0.60, "steel": 0.40},
	"csplab_concentrator": {"steel": 0.70, "glass": 0.30},
	"tclab_assembly": {"steel": 1.0},
}

## Not built stock: living things, placeholders, things of the site's earth.
const SKIP_MODELS := ["pine_1", "generic_box", "generic_tank", "mud_building",
	"earthship_phoenix", "earthship_detail", "earthshiplab_structure"]

const CACHE_MAX := 256
static var _cache: Dictionary = {}


## What one placed record is made of.
static func of_record(rec: Dictionary) -> Dictionary:
	var mid := str(rec.get("model_id", ""))
	if SKIP_MODELS.has(mid) or rec.has("vehicle_spec") or ModelCatalog.find(mid).has("vehicle"):
		return {"known": false, "skip": true, "kg": 0.0, "materials": {}, "est": false, "source": ""}
	var key := _key(rec)
	if _cache.has(key):
		return (_cache[key] as Dictionary).duplicate(true)
	var out := _resolve(rec, mid)
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[key] = out
	return out.duplicate(true)


static func _key(rec: Dictionary) -> String:
	var parts: Array = [str(rec.get("model_id", ""))]
	for k in ["linkage_spec", "flatpack_spec", "domelab_spec", "pvlab_spec", "toroid_spec", "pelton_spec",
			"windlab_spec", "gantry_spec", "tc_spec", "rack_spec", "container_spec", "intermodal_spec",
			"grow_bed_spec"]:
		if rec.has(k):
			parts.append(k)
			parts.append(rec[k])
	return str(hash(JSON.stringify(parts)))


static func _resolve(rec: Dictionary, mid: String) -> Dictionary:
	if rec.get("linkage_spec") is Dictionary:
		var p := LinkageParams.new()
		p.from_config(rec.get("linkage_spec") as Dictionary)
		var s := LinkageStructureBuilder.packed_spec_for(p)
		if s.get("materials") is Dictionary:
			return _done(_scaled(s["materials"], float(s.get("count", 1))), "Linkage frame", false)
	var ps := _part_source(rec, mid)
	if not ps.is_empty():
		return _from_parts(ps["parts"], ps["cls"], str(ps["source"]))
	if rec.get("container_spec") is Dictionary:
		var c := ContainerCatalog.packed_spec_for(str((rec["container_spec"] as Dictionary).get("container_id", "")))
		if PackedSpec.has_mass(c):
			return _done({"steel": float(c["mass_kg"])}, "container tare", false)
	if rec.get("intermodal_spec") is Dictionary:
		var e := IntermodalUnitBuilder.entry_for_spec(rec["intermodal_spec"])
		var iu := IntermodalUnits.packed_spec_for(e)
		if PackedSpec.has_mass(iu):
			return _done(_shares(float(iu["mass_kg"]), _intermodal_shares(e)), "unit tare", true)
	var spec := PlacedPropRuntime.packed_spec_for_record(rec)
	var kg := float(spec.get("mass_kg", -1.0)) * float(spec.get("count", 1)) if PackedSpec.has_mass(spec) else 0.0
	if MODEL_MATERIALS.has(mid) and kg > 0.0:
		return _done(_shares(kg, MODEL_MATERIALS[mid]), "model table", true)
	return {"known": false, "skip": false, "kg": kg, "materials": {}, "est": true, "source": "unknown"}


## The designer's own part list for one record and how each part maps to a
## material: {parts, cls (Callable(part) -> material), source}, or {} for a
## record with no part list (the Linkage frame carries a material split
## instead; shipped models go by MODEL_MATERIALS).
static func _part_source(rec: Dictionary, mid: String) -> Dictionary:
	if rec.get("flatpack_spec") is Dictionary:
		return _src(FlatpackDesign.parts_for_packing(FlatpackDesign.solve(rec["flatpack_spec"])),
			func(_pt: Dictionary) -> String: return "plywood", "flat-pack parts")
	if rec.get("domelab_spec") is Dictionary:
		var dd := DomeLabDesign.solve(rec["domelab_spec"])
		var ds: Dictionary = dd.get("spec", rec["domelab_spec"])
		return _src(DomeLabDesign.parts_for_packing(dd), func(pt: Dictionary) -> String:
			return _dome_part(pt, ds), "dome parts")
	if rec.get("pvlab_spec") is Dictionary:
		return _src(PvLabDesign.parts_for_packing(PvLabDesign.solve(rec["pvlab_spec"])),
			_pv_part, "solar array parts")
	if rec.get("toroid_spec") is Dictionary:
		return _src(ToroidLabDesign.parts_for_packing(ToroidLabDesign.solve(rec["toroid_spec"])),
			_toroid_part, "toroid parts")
	if rec.get("pelton_spec") is Dictionary:
		return _src(PeltonLabDesign.parts_for_packing(PeltonLabDesign.solve(rec["pelton_spec"])),
			func(_pt: Dictionary) -> String: return "steel", "turbine parts")
	if rec.get("windlab_spec") is Dictionary:
		return _src(WindLabDesign.parts_for_packing(WindLabDesign.solve(rec["windlab_spec"])),
			func(pt: Dictionary) -> String: return "pp" if str(pt.get("kind", "")) == "sheet" else "steel",
			"turbine parts")
	if rec.get("gantry_spec") is Dictionary:
		return _src(GantryLabDesign.parts_for_packing(GantryLabDesign.solve(rec["gantry_spec"])),
			_gantry_part, "machine parts")
	if rec.get("tc_spec") is Dictionary or TcBuilder.handles(mid):
		var tsp: Dictionary = rec.get("tc_spec", {}) if rec.get("tc_spec") is Dictionary else TcBuilder.spec_for_model(mid)
		if not tsp.is_empty():
			return _src(TcDesign.parts_for_packing(TcDesign.solve(tsp)),
				func(_pt: Dictionary) -> String: return "steel", "tri-clamp parts")
	if rec.get("rack_spec") is Dictionary:
		return _src(PalletRackBuilder.parts_for_packing(rec["rack_spec"]), _rack_part, "rack parts")
	return {}


static func _src(parts: Array, cls: Callable, source: String) -> Dictionary:
	return {"parts": parts, "cls": cls, "source": source}


## One record's parts with their materials, for the parts circle pack:
## [{label, qty, kg (each), material}]. [] when the record has no part list.
static func parts_of_record(rec: Dictionary) -> Array:
	var ps := _part_source(rec, str(rec.get("model_id", "")))
	if ps.is_empty():
		return []
	var cls: Callable = ps["cls"]
	var out: Array = []
	for pt in (ps["parts"] as Array):
		var d: Dictionary = pt
		var kg := float(d.get("mass_kg", 0.0))
		if kg <= 0.0:
			continue
		out.append({"label": str(d.get("label", d.get("kind", "part"))), "qty": maxi(1, int(d.get("qty", 1))),
			"kg": kg, "material": str(cls.call(d))})
	return out


static func _done(mats: Dictionary, source: String, est: bool) -> Dictionary:
	var kg := 0.0
	for v in mats.values():
		kg += float(v)
	return {"known": kg > 0.0, "skip": false, "kg": kg, "materials": mats, "est": est, "source": source}


static func _scaled(mats: Dictionary, f: float) -> Dictionary:
	var out: Dictionary = {}
	for m in mats.keys():
		out[m] = float(mats[m]) * f
	return out


static func _shares(kg: float, shares: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for m in shares.keys():
		out[m] = kg * float(shares[m])
	return out


static func _from_parts(parts: Array, cls: Callable, source: String) -> Dictionary:
	var mats: Dictionary = {}
	for pt in parts:
		var d: Dictionary = pt
		var kg := float(d.get("mass_kg", 0.0)) * float(d.get("qty", 1))
		if kg <= 0.0:
			continue
		var m := str(cls.call(d))
		mats[m] = float(mats.get(m, 0.0)) + kg
	return _done(mats, source, true)


## A dome: struts and slats of the strut stock, covers of the face sheet,
## panes of the glazing, hubs and fasteners steel.
static func _dome_part(pt: Dictionary, s: Dictionary) -> String:
	var label := str(pt.get("label", ""))
	var face: Dictionary = s.get("face", {}) if s.get("face") is Dictionary else {}
	if label.begins_with("Glazing"):
		return material_of_stock(str(face.get("glazing", "polycarb_6")), "glazing")
	if label.begins_with("Hub") or str(pt.get("kind", "")) == "loose":
		return "steel"
	if str(pt.get("kind", "")) == "sheet":
		return material_of_stock(str(face.get("material", "none")), DomeLabMaterials.sheet_look(str(face.get("material", "none"))))
	var sid := str((s.get("strut", {}) as Dictionary).get("material", "emt_34")) if s.get("strut") is Dictionary else "emt_34"
	return material_of_stock(sid, DomeLabMaterials.strut_look(sid))


## A designer's stock id (and how it is drawn) -> a material.
static func material_of_stock(id: String, look: String = "") -> String:
	var i := id.to_lower()
	if i.begins_with("pvc"):
		return "pvc"
	if i.begins_with("hdpe") or i == "tarp_pe":
		return "hdpe"
	if i.begins_with("pp") or i.begins_with("corflute"):
		return "pp"
	if i.begins_with("polycarb"):
		return "pc"
	if i.begins_with("pmma"):
		return "pmma"
	if i.begins_with("alu"):
		return "aluminium"
	if i.begins_with("ply"):
		return "plywood"
	if i.begins_with("wood") or i.begins_with("bamboo"):
		return "lumber"
	match look:
		"alu":
			return "aluminium"
		"wood":
			return "lumber"
		"ply":
			return "plywood"
		"plastic":
			return "pp"
		"glazing":
			return "pc"
		"fabric":
			return "fabric"
	return "steel"


static func _pv_part(pt: Dictionary) -> String:
	var l := str(pt.get("label", "")).to_lower()
	if l.contains("module") or l.contains("solar"):
		return "pv_module"
	if l.begins_with("al ") or l.contains("alumin") or l.contains("al rail"):
		return "aluminium"
	if l.contains("lumber") or l.contains("2x") or l.contains("timber"):
		return "lumber"
	return "steel"


static func _toroid_part(pt: Dictionary) -> String:
	var l := str(pt.get("label", "")).to_lower()
	if l.contains("flexible") or l.contains("solar") or l.contains(" w "):
		return "pv_module"
	if str(pt.get("kind", "")) == "sheet":
		return "pp"
	return "steel"


static func _gantry_part(pt: Dictionary) -> String:
	var l := str(pt.get("label", "")).to_lower()
	if l.contains("v-slot") or l.contains("plate") or l.contains("bracket") or l.contains("carriage"):
		return "aluminium"
	return "steel"


static func _rack_part(pt: Dictionary) -> String:
	var l := str(pt.get("label", "")).to_lower()
	if l.contains("lumber") or l.contains("2x"):
		return "lumber"
	if l.contains("module") or l.contains("solar"):
		return "pv_module"
	if l.contains("glaz") or l.contains("polycarb"):
		return "pc"
	if str(pt.get("kind", "")) == "sheet":
		return "plywood"
	return "steel"


static func _intermodal_shares(e: Dictionary) -> Dictionary:
	var t := str(e.get("template", e.get("id", ""))).to_lower()
	if t.contains("ibc"):
		return {"hdpe": 0.30, "steel": 0.70}
	if t.contains("drum"):
		return {"steel": 1.0}
	if t.contains("plastic"):
		return {"hdpe": 1.0}
	return {"lumber": 1.0}


## What a set of materials holds.
static func embodied(materials: Dictionary) -> Dictionary:
	var out := {"kg": 0.0, "water_kg": 0.0, "elements": {}, "energy_mj": 0.0}
	for m in materials.keys():
		var kind := str((MATERIALS.get(m, {}) as Dictionary).get("kind", ""))
		if kind.is_empty():
			continue
		var emb := CompositionCatalog.embodied_kg(kind, float(materials[m]))
		out["kg"] = float(out["kg"]) + float(emb.get("kg", 0.0))
		out["water_kg"] = float(out["water_kg"]) + float(emb.get("water_kg", 0.0))
		out["energy_mj"] = float(out["energy_mj"]) + float(emb.get("energy_mj", 0.0))
		for e in (emb.get("elements", {}) as Dictionary).keys():
			out["elements"][e] = float((out["elements"] as Dictionary).get(e, 0.0)) + float(emb["elements"][e])
	return out


## The site's built stock over prop records.
static func site(records: Array) -> Dictionary:
	var by: Dictionary = {}
	var n := 0
	var unknown := 0
	var unknown_kg := 0.0
	var rows: Array = []
	for r in records:
		if not r is Dictionary:
			continue
		var o := of_record(r)
		if bool(o.get("skip", false)):
			continue
		n += 1
		if not bool(o.get("known", false)):
			unknown += 1
			unknown_kg += float(o.get("kg", 0.0))
			continue
		rows.append({"id": str((r as Dictionary).get("id", "")), "model_id": str((r as Dictionary).get("model_id", "")),
			"kg": float(o["kg"]), "materials": o["materials"]})
		for m in (o["materials"] as Dictionary).keys():
			by[m] = float(by.get(m, 0.0)) + float(o["materials"][m])
	var emb := embodied(by)
	emb["by_material"] = by
	emb["structures"] = n
	emb["unknown"] = unknown
	emb["unknown_kg"] = unknown_kg
	emb["rows"] = rows
	return emb


## What taking it down puts into stores; pv modules are kept whole.
static func salvage_kinds(materials: Dictionary) -> Dictionary:
	var kinds: Dictionary = {}
	var kept: Dictionary = {}
	for m in materials.keys():
		var kg := float(materials[m])
		if kg <= 0.0:
			continue
		var sk := str((MATERIALS.get(m, {}) as Dictionary).get("salvage", ""))
		if sk.is_empty():
			kept[m] = float(kept.get(m, 0.0)) + kg
		else:
			kinds[sk] = float(kinds.get(sk, 0.0)) + kg
	return {"kinds": kinds, "kept": kept}


## Credit salvaged kinds to the scope's stores: the first tank of the kind
## with room, else a new "<Kind> (salvaged)" store sized to hold it with room
## to spare, placed from `at` along a row. → [{id, kind, kg, created}].
## Tank levels are fractions of capacity_qty (kinds here are all kg);
## `level_of(id)` gives a tank's current level (its timeline's) when the
## specs may be stale.
static func salvage_into(model: GraphModel, scope: String, kinds: Dictionary, at: Vector2,
		level_of: Callable = Callable()) -> Array:
	var out: Array = []
	var i := 0
	var ks: Array = kinds.keys()
	ks.sort()
	for k in ks:
		var kg := float(kinds[k])
		if kg <= 0.0:
			continue
		var tank := ""
		for it in model.get_items_in_scope(scope):
			var d: Dictionary = it
			if str(d.get("type", "")) != "resource":
				continue
			var sp: Dictionary = d.get("specs", {})
			if ResourceKinds.normalize_kind(str(sp.get("resource_kind", ""))) != str(k) or bool(sp.get("unlimited_capacity", false)):
				continue
			var cap := float(sp.get("capacity_qty", 0.0))
			var lv := float(level_of.call(str(d["id"]))) if level_of.is_valid() else float(sp.get("level", 0.0))
			if cap > 0.0 and cap * (1.0 - lv) >= kg:
				tank = str(d["id"])
				break
		var created := tank.is_empty()
		if created:
			tank = model.generate_item_id()
			var cap2 := maxf(ceilf(kg * 1.5 / 50.0) * 50.0, 100.0)
			model.add_item({"id": tank, "type": "resource", "scope_id": scope,
				"x": at.x + 170.0 * i, "y": at.y, "width": 120.0, "height": 120.0,
				"specs": {"name": "%s (salvaged)" % ResourceKinds.display_name(str(k)).get_slice(" (", 0),
					"resource_kind": str(k), "capacity_qty": cap2, "capacity_unit": "kg", "level": 0.0,
					"salvage_store": true}})
			i += 1
		var cur: Dictionary = model.get_item(tank)
		var sp2: Dictionary = (cur.get("specs", {}) as Dictionary).duplicate(true)
		var cap3 := float(sp2.get("capacity_qty", 1.0))
		var lv0 := float(level_of.call(tank)) if level_of.is_valid() and not created else float(sp2.get("level", 0.0))
		sp2["level"] = clampf(lv0 + kg / maxf(cap3, 1e-6), 0.0, 1.0)
		model.update_item(tank, {"specs": sp2})
		out.append({"id": tank, "kind": str(k), "kg": kg, "created": created, "level": float(sp2["level"])})
	return out


## The dashboard's "Built" rows (ElementLedger.rows' format).
static func rows(st: Dictionary) -> Array:
	var r: Array = []
	if int(st.get("structures", 0)) <= 0:
		return r
	r.append({"t": "sub", "text": "Built (in structures)"})
	var n := int(st["structures"])
	var unk := int(st.get("unknown", 0))
	r.append({"t": "kv", "k": "Structures", "v": UiText.count(n, "structure")
		+ ((" · %d not known" % unk) if unk > 0 else "")})
	r.append({"t": "kv", "k": "Material in them", "v": ElementLedger.fmt_kg(float(st.get("kg", 0.0)))})
	var el: Dictionary = st.get("elements", {})
	if float(el.get("C", 0.0)) > 0.01:
		r.append({"t": "kv", "k": "Carbon held", "v": ElementLedger.fmt_kg(float(el["C"]))})
	if float(st.get("water_kg", 0.0)) > 0.01:
		r.append({"t": "kv", "k": "Water in the wood", "v": ElementLedger.fmt_kg(float(st["water_kg"]))})
	if float(st.get("energy_mj", 0.0)) > 0.01:
		r.append({"t": "kv", "k": "Energy in it", "v": ElementLedger.fmt_energy_mj(float(st["energy_mj"]))})
	var by: Dictionary = st.get("by_material", {})
	if not by.is_empty():
		r.append({"t": "note", "k": "", "v": "mostly " + describe(by, 3), "tone": "muted"})
	return r


## "70 kg lumber, 12 kg steel" (largest first).
static func describe(materials: Dictionary, max_n: int = 3) -> String:
	var rows: Array = []
	for m in materials.keys():
		if float(materials[m]) > 0.0:
			rows.append([str(m), float(materials[m])])
	rows.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	var parts := PackedStringArray()
	for j in mini(rows.size(), max_n):
		parts.append("%s %s" % [UiText.num(float(rows[j][1]), "kg"),
			str((MATERIALS.get(rows[j][0], {}) as Dictionary).get("label", rows[j][0]))])
	if rows.size() > max_n:
		var rest := 0.0
		for j2 in range(max_n, rows.size()):
			rest += float(rows[j2][1])
		parts.append("%s other" % UiText.num(rest, "kg"))
	return ", ".join(parts)

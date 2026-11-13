class_name CirclePackSources
extends RefCounted

## Trees for the circle pack (CirclePack / CirclePackView) from the game's
## nested things. Each returns a tree node {id, name, value | children,
## color, unit, detail, data}; values are positive, in `unit`.
##
##   graph(model, scope, size_by)   the systems graph: groups (camps,
##       vehicles, arrays, components) round what is inside them, a solar
##       array's panels in their strings. size_by: "count" (one each; an
##       array's panels count one each), "power" (rated watts), "mass"
##       (shipping kg). Leaves take their system's colour (power amber,
##       water cyan, food green, fuel orange, people violet).
##   composition(kind, qty_kg)      what a kind is made of: its components,
##       each split into elements (CompositionCatalog)
##   stores(model, scope)           what the stores hold: by system, each
##       store by what it holds, down to its components
##   built(records, by)             what the site is built from: by
##       structure, then material ("structure"), or by material, then
##       structure ("material") (BuiltStock)
##   parts(rec)                     one structure: its materials, each its
##       parts (the designer's own part list; others by material only)

const SIZE_COUNT := "count"
const SIZE_POWER := "power"
const SIZE_MASS := "mass"
const SIZES := [[SIZE_COUNT, "One each"], [SIZE_POWER, "Rated power"], [SIZE_MASS, "Mass"]]

const ELEMENT_NAMES := {"C": "Carbon", "H": "Hydrogen", "O": "Oxygen", "N": "Nitrogen",
	"P": "Phosphorus", "K": "Potassium", "S": "Sulphur", "Na": "Sodium", "Cl": "Chlorine",
	"Ca": "Calcium", "Mg": "Magnesium", "Si": "Silicon", "Al": "Aluminium", "Fe": "Iron",
	"X": "Other elements"}
const ELEMENT_EXTRA := {"S": Color(0.86, 0.84, 0.34), "Na": Color(0.70, 0.62, 0.95),
	"Cl": Color(0.45, 0.88, 0.55), "Ca": Color(0.92, 0.90, 0.82), "Mg": Color(0.62, 0.86, 0.78),
	"Si": Color(0.70, 0.60, 0.48), "Al": Color(0.72, 0.76, 0.82), "Fe": Color(0.82, 0.44, 0.30),
	"X": Color(0.50, 0.52, 0.58)}
const _RATING_KEYS := ["wmp", "rated_w", "max_power_w", "max_pv_watts", "max_watts", "watts", "power_w"]


static func element_color(el: String) -> Color:
	if ElementLens.is_lens(el):
		return ElementLens.color(el)
	return ELEMENT_EXTRA.get(el, Color(0.6, 0.62, 0.68))


static func domain_color(domain: String) -> Color:
	match domain:
		GraphDomainFilter.WATER:
			return GraphTheme.channel("water")
		GraphDomainFilter.FOOD:
			return GraphTheme.channel("food")
		GraphDomainFilter.FUEL:
			return GraphTheme.channel("fuel")
		GraphSchemaLayout.PEOPLE:
			return GraphTheme.channel("people")
		GraphDomainFilter.MATERIALS:
			return Color(0.72, 0.66, 0.58)
		GraphDomainFilter.OTHER:
			return Color(0.60, 0.64, 0.72)
	return GraphTheme.channel("power")


static func fmt(v: float, unit: String) -> String:
	match unit:
		"kg":
			return ElementLedger.fmt_kg(v)
		"W":
			return UiText.num(v, "W")
		"node":
			return "" if is_equal_approx(v, 1.0) else UiText.count(v, "node")
		"", "item":
			return UiText.count(v, "part")
	return UiText.num(v, unit)


# ---------------------------------------------------------------------------
# The systems graph
# ---------------------------------------------------------------------------

static func graph(model: GraphModel, scope: String = "root", size_by: String = SIZE_COUNT) -> Dictionary:
	if model == null:
		return {}
	var by_scope := GraphNesting.scope_index(model)
	var conns := GraphNesting.flat_connections_cached(model)
	var unit := "W" if size_by == SIZE_POWER else ("kg" if size_by == SIZE_MASS else "node")
	var root_name := "Site"
	if scope != "root":
		for it in model.items:
			if str((it as Dictionary).get("child_scope_id", "")) == scope:
				root_name = _item_name(it)
				break
	var kids := _graph_scope(model, by_scope, conns, scope, size_by, unit, 0)
	return {"id": "scope:" + scope, "name": root_name, "children": kids, "unit": unit}


static func _graph_scope(model: GraphModel, by_scope: Dictionary, conns: Array, scope: String,
		size_by: String, unit: String, guard: int) -> Array:
	var out: Array = []
	if guard > 12:
		return out
	for it in (by_scope.get(scope, []) as Array):
		var d: Dictionary = it
		if bool(d.get("is_ghost", false)) or str(d.get("type", "")) == "virtual":
			continue
		var cs := str(d.get("child_scope_id", ""))
		var id := str(d.get("id", ""))
		if not cs.is_empty() and (by_scope.get(cs, []) as Array).size() > 0:
			var inner: Array = []
			if GraphSolarArrays.is_solar_array(d) and GraphSolarArrays.is_materialized(d):
				inner = _array_strings(d, by_scope.get(cs, []) as Array, size_by, unit)
			else:
				inner = _graph_scope(model, by_scope, conns, cs, size_by, unit, guard + 1)
			if not inner.is_empty():
				var g := {"id": id, "name": _item_name(d), "children": inner, "unit": unit,
					"detail": _item_detail(d), "data": {"item_id": id}}
				out.append(g)
				continue
		var v := _item_value(d, size_by)
		var leaf := {"id": id, "name": _item_name(d), "value": v, "unit": unit,
			"color": domain_color(GraphSchemaLayout.domain_of(d, conns)),
			"detail": _item_detail(d), "data": {"item_id": id}}
		out.append(leaf)
	return out


## An array's panels grouped in their strings.
static func _array_strings(arr: Dictionary, panels: Array, size_by: String, unit: String) -> Array:
	var by: Dictionary = {}
	var order: Array = []
	for it in panels:
		var d: Dictionary = it
		if str(d.get("type", "")) != "panel":
			continue
		var sp: Dictionary = d.get("specs", {}) as Dictionary
		var si := int(sp.get("array_string", sp.get("pvlab_string", 0)))
		if not by.has(si):
			by[si] = []
			order.append(si)
		var v := _item_value(d, size_by)
		(by[si] as Array).append({"id": str(d.get("id", "")), "name": _item_name(d), "value": v, "unit": unit,
			"color": GraphSolarArrays.string_color(si), "detail": _item_detail(d),
			"data": {"item_id": str(d.get("id", ""))}})
	order.sort()
	var out: Array = []
	for si in order:
		var c := GraphSolarArrays.string_color(int(si))
		out.append({"id": "%s:string%d" % [str(arr.get("id", "")), int(si)], "name": "String %d" % (int(si) + 1),
			"children": by[si], "unit": unit, "color": c,
			"detail": "%s in series" % UiText.count((by[si] as Array).size(), "panel")})
	return out


static func _item_name(d: Dictionary) -> String:
	var sp: Dictionary = d.get("specs", {}) as Dictionary
	var n := str(sp.get("name", ""))
	if n.is_empty():
		n = UiText.from_id(str(d.get("type", "node")))
	return n


static func _item_detail(d: Dictionary) -> String:
	var sp: Dictionary = d.get("specs", {}) as Dictionary
	var t := str(d.get("type", ""))
	var bits: Array = []
	var w := _rated_w(d)
	if w > 0.0:
		bits.append(UiText.num(w, "W") + (" peak" if t == "panel" else ""))
	if t in ["battery", "smartbattery"] and float(sp.get("capacity_kwh", 0.0)) > 0.0:
		bits.append(UiText.num(float(sp["capacity_kwh"]) * 1000.0, "Wh"))
	if t == "resource":
		var k := str(sp.get("resource_kind", ""))
		if not k.is_empty():
			bits.append(ResourceKinds.display_name(k))
	return " · ".join(bits)


static func _rated_w(d: Dictionary) -> float:
	var sp: Dictionary = d.get("specs", {}) as Dictionary
	for k in _RATING_KEYS:
		var v := float(sp.get(k, 0.0))
		if v > 0.0:
			if k == "wmp" and int(sp.get("panel_count", 1)) > 1 and not bool(sp.get("string_proxy", false)):
				return v * float(sp.get("panel_count", 1))
			return v
	if float(sp.get("rated_kw", 0.0)) > 0.0:
		return float(sp["rated_kw"]) * 1000.0
	return 0.0


static func _item_value(d: Dictionary, size_by: String) -> float:
	var sp: Dictionary = d.get("specs", {}) as Dictionary
	match size_by:
		SIZE_POWER:
			return _rated_w(d)
		SIZE_MASS:
			var ps := PackedSpec.for_preset_specs(str(d.get("type", "")), sp)
			if PackedSpec.has_mass(ps):
				return float(ps["mass_kg"]) * float(ps.get("count", 1))
			return 0.0
	if str(d.get("type", "")) == "panel":
		return maxf(1.0, float(sp.get("panel_count", 1)))
	return 1.0


# ---------------------------------------------------------------------------
# What a kind is made of
# ---------------------------------------------------------------------------

static func composition(kind: String, qty_kg: float = 1.0) -> Dictionary:
	var k := CompositionCatalog.canonical(kind)
	var comps: Dictionary = CompositionCatalog.components_of(k)
	var kids: Array = []
	var slot := 0
	var keys: Array = comps.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return float(comps[a]) > float(comps[b]))
	for cid in keys:
		var f := float(comps[cid])
		if f <= 0.0:
			continue
		var els := CompositionCatalog.component_elements(str(cid))
		var col := CirclePack.palette(slot)
		var is_water := CompositionCatalog.component_name(str(cid)).to_lower() == "water"
		if is_water:
			# Water is water: its oxygen and hydrogen say nothing here.
			els = {}
			col = GraphTheme.channel("water")
		slot += 1
		var ek: Array = []
		var tot := 0.0
		for e in els.keys():
			tot += float(els[e])
		for e in els.keys():
			var m := float(els[e]) / maxf(tot, 1e-12) * f * qty_kg
			if m <= 0.0:
				continue
			ek.append({"id": "%s/%s" % [str(cid), str(e)], "name": str(ELEMENT_NAMES.get(e, e)), "value": m,
				"unit": "kg", "color": element_color(str(e)), "detail": "%s in %s" % [str(e), CompositionCatalog.component_name(str(cid))]})
		var cname := CompositionCatalog.component_name(str(cid)).capitalize()
		if ek.is_empty():
			kids.append({"id": str(cid), "name": cname, "value": f * qty_kg, "unit": "kg", "color": col,
				"detail": UiText.pct(f, 1) + " of it"})
		else:
			kids.append({"id": str(cid), "name": cname, "children": ek, "unit": "kg", "color": col,
				"detail": UiText.pct(f, 1) + " of it"})
	return {"id": "kind:" + k, "name": ResourceKinds.display_name(k), "children": kids, "unit": "kg"}


# ---------------------------------------------------------------------------
# What the stores hold
# ---------------------------------------------------------------------------

static func stores(model: GraphModel, scope: String = "root", level_of: Callable = Callable()) -> Dictionary:
	var groups: Dictionary = {}
	if model == null:
		return {}
	for it in GraphNesting.walk_items(model, scope):
		var d: Dictionary = it
		if str(d.get("type", "")) != "resource":
			continue
		var sp: Dictionary = d.get("specs", {}) as Dictionary
		if bool(sp.get("unlimited_capacity", false)):
			continue
		var kind := str(sp.get("resource_kind", ""))
		if kind.is_empty():
			continue
		var cap := float(sp.get("capacity_qty", 0.0))
		var lv := float(level_of.call(str(d["id"]))) if level_of.is_valid() else float(sp.get("level", 0.0))
		var kpu := CompositionCatalog.kg_per_unit(kind)
		if is_nan(kpu) or kpu <= 0.0:
			kpu = 1.0
		var kg := cap * clampf(lv, 0.0, 1.0) * kpu
		if kg <= 0.0:
			continue
		var dom := GraphDomainFilter.kind_domain(kind)
		if not groups.has(dom):
			groups[dom] = []
		var comp := composition(kind, kg)
		var kids: Array = comp.get("children", []) as Array
		var node := {"id": str(d["id"]), "name": _item_name(d), "unit": "kg",
			"detail": "%s · %s full" % [ResourceKinds.display_name(kind), UiText.pct(lv)],
			"data": {"item_id": str(d["id"])}}
		if kids.is_empty() or not CompositionCatalog.is_known(kind):
			node["value"] = kg
			node["color"] = domain_color(dom)
		else:
			node["children"] = kids
		(groups[dom] as Array).append(node)
	var out: Array = []
	for dom in groups.keys():
		out.append({"id": "dom:" + str(dom), "name": str(GraphDomainFilter.LABELS.get(dom, str(dom).capitalize())),
			"children": groups[dom], "unit": "kg", "color": domain_color(str(dom))})
	return {"id": "stores:" + scope, "name": "What the stores hold", "children": out, "unit": "kg"}


# ---------------------------------------------------------------------------
# What the site is built from
# ---------------------------------------------------------------------------

static func built(records: Array, by: String = "structure") -> Dictionary:
	var st := BuiltStock.site(records)
	var rows: Array = st.get("rows", []) as Array
	var by_id := {}
	for r0 in records:
		if r0 is Dictionary:
			by_id[str((r0 as Dictionary).get("id", ""))] = r0
	var seen := {}
	for r1 in rows:
		var rd1: Dictionary = r1
		var nm := _record_name(by_id.get(str(rd1["id"]), rd1) as Dictionary)
		seen[nm] = int(seen.get(nm, 0)) + 1
		rd1["_name"] = nm if int(seen[nm]) == 1 else "%s #%d" % [nm, int(seen[nm])]
	var mat_slot := {}
	for r in rows:
		for m in ((r as Dictionary)["materials"] as Dictionary).keys():
			if not mat_slot.has(m):
				mat_slot[m] = mat_slot.size()
	var kids: Array = []
	if by == "material":
		var by_m: Dictionary = {}
		for r in rows:
			var rd: Dictionary = r
			for m in (rd["materials"] as Dictionary).keys():
				if not by_m.has(m):
					by_m[m] = []
				(by_m[m] as Array).append({"id": "%s/%s" % [str(m), str(rd["id"])], "name": str(rd["_name"]),
					"value": float(rd["materials"][m]), "unit": "kg", "data": {"prop_id": str(rd["id"])}})
		for m in by_m.keys():
			kids.append({"id": "mat:" + str(m), "name": _material_name(str(m)), "children": by_m[m],
				"unit": "kg", "color": CirclePack.palette(int(mat_slot[m]))})
	else:
		for r in rows:
			var rd2: Dictionary = r
			var mk: Array = []
			for m in (rd2["materials"] as Dictionary).keys():
				mk.append({"id": "%s/%s" % [str(rd2["id"]), str(m)], "name": _material_name(str(m)),
					"value": float(rd2["materials"][m]), "unit": "kg", "color": CirclePack.palette(int(mat_slot[m])),
					"data": {"prop_id": str(rd2["id"])}})
			kids.append({"id": "rec:" + str(rd2["id"]), "name": str(rd2["_name"]), "children": mk, "unit": "kg",
				"data": {"prop_id": str(rd2["id"])}, "color": Color(0.55, 0.62, 0.78)})
	var unk := int(st.get("unknown", 0))
	return {"id": "built:" + by, "name": "What the site is built from", "children": kids, "unit": "kg",
		"detail": ("%s not known" % UiText.count(unk, "structure")) if unk > 0 else ""}


static func _record_name(rd: Dictionary) -> String:
	for k in ["name", "label"]:
		if str(rd.get(k, "")).strip_edges() != "":
			return str(rd[k]).strip_edges()
	# A designed structure carries its design's name in its spec.
	for k in rd.keys():
		if str(k).ends_with("_spec") and rd[k] is Dictionary:
			var dn := str((rd[k] as Dictionary).get("name", "")).strip_edges()
			if not dn.is_empty():
				return dn
	var mid := str(rd.get("model_id", ""))
	var lbl := str(ModelCatalog.find(mid).get("label", ""))
	return lbl if not lbl.is_empty() else UiText.from_id(mid)


static func _material_name(m: String) -> String:
	var row: Dictionary = BuiltStock.MATERIALS.get(m, {}) as Dictionary
	var n := str(row.get("label", ""))
	if n.is_empty():
		return UiText.from_id(m)
	return n.substr(0, 1).to_upper() + n.substr(1)


## One structure: its materials, each its parts.
static func parts(rec: Dictionary) -> Dictionary:
	var nm := _record_name(rec)
	var pl := BuiltStock.parts_of_record(rec)
	var kids: Array = []
	var by_m: Dictionary = {}
	var order: Array = []
	for p in pl:
		var pd: Dictionary = p
		var m := str(pd.get("material", "other"))
		if not by_m.has(m):
			by_m[m] = []
			order.append(m)
		var q := int(pd.get("qty", 1))
		var lbl := str(pd.get("label", "part"))
		(by_m[m] as Array).append({"id": "%s/%d" % [m, (by_m[m] as Array).size()],
			"name": lbl if q <= 1 else "%s × %d" % [lbl, q], "value": float(pd.get("kg", 0.0)) * float(q),
			"unit": "kg", "detail": ("%s each" % ElementLedger.fmt_kg(float(pd.get("kg", 0.0)))) if q > 1 else ""})
	for i in order.size():
		var m2 := str(order[i])
		kids.append({"id": "mat:" + m2, "name": _material_name(m2), "children": by_m[m2], "unit": "kg",
			"color": CirclePack.palette(i)})
	if kids.is_empty():
		var o := BuiltStock.of_record(rec)
		var j := 0
		for m3 in (o.get("materials", {}) as Dictionary).keys():
			kids.append({"id": "mat:" + str(m3), "name": _material_name(str(m3)),
				"value": float(o["materials"][m3]), "unit": "kg", "color": CirclePack.palette(j)})
			j += 1
	return {"id": "rec:" + str(rec.get("id", "")), "name": nm, "children": kids, "unit": "kg"}

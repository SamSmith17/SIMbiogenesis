class_name LinkagePartKeys
extends RefCounted
## Stable part identity for build steps — port of LinkageLab's
## `js/linkage/part-keys.js` (LINKAGE_PARITY.md, phase A1).
##
## The solver rebuilds every beam, bolt, washer and bracket on each solve, so a
## part's index is useless as an identifier. Each part carries a few semantic
## fields (module, stack type, ring, role, layer, ...) and this file turns them
## into deterministic string keys IDENTICAL to the web app's, so a build step
## authored in LinkageLab ("fasten module 3's top inner joint") names the same
## part in the game. Pinned per preset against
## `core/linkage/testdata/parity/*.json` (`deployed.parts.keys`).
##
## Selectors stay in the web app's camelCase (`{kind, stackType, moduleIndex}`)
## because they are CONFIG data, saved inside `buildSteps`; `FIELD` maps each
## selector field onto the game's snake_case part dictionaries.
##
## Pure and static: no scene, no THREE, runs under `--script`.

const PART_KINDS := ["beam", "bolt", "washer", "bracket", "placement", "hwpart", "panel", "wall"]

const STACK_TYPE_LABELS := {
	"horizontal-bottom": "Bottom H-beam",
	"horizontal-top": "Top H-beam",
	"vertical": "V-beam",
	"vertical-cap": "Cap V-beam",
	"fixed-beam": "Fixed beam",
	"fixed-beam-cap": "Cap fixed beam",
	"support-beam": "Radial support beam",
	"support-beam-reciprocal": "Reciprocal beam",
	"floor-beam": "Floor radial beam",
	"floor-beam-reciprocal": "Floor beam",
}

const BOLT_TYPE_LABELS := {
	"vstack": "V-stack bolt",
	"hstack": "H-center bolt",
	"hpivot": "H-pivot bolt",
	"rcp-ring": "Reciprocal ring bolt",
	"rcp-cross": "Reciprocal cross bolt",
}

## Order joints are worked in: pivots with brackets first, then centre links.
const JOINT_ROLE_RANK := {"outer": 0, "inner": 1, "center": 2}

const ASSEMBLY_ROLES := {
	"outerVBeam": "outer",
	"innerVBeam": "inner",
	"vCenter": "center",
	"hCenter": "center",
}

## Selector field (web camelCase) -> part dictionary key (game snake_case).
const FIELD := {
	"stackType": "stack_type", "moduleIndex": "module_index", "stackId": "stack_id",
	"patternId": "pattern_id", "layerIndex": "layer_index", "arrayIndex": "array_index",
	"boltType": "bolt_type", "boltSubType": "bolt_sub_type", "ring": "ring", "role": "role",
	"cap": "cap", "gapIndex": "gap_index", "washerType": "washer_type",
	"pivotRole": "pivot_role", "assemblyId": "assembly_id", "rcpStackId": "rcp_stack_id",
	"rcpStackA": "rcp_stack_a", "rcpStackB": "rcp_stack_b", "partId": "part_id",
	"copyIndex": "copy_index", "renderAxisKey": "render_axis_key", "index": "index",
	"spanIndex": "span_index", "band": "band", "coverType": "cover_type",
}

## Fields a selector may constrain, by kind (part-keys.js SELECTOR_FIELDS).
const SELECTOR_FIELDS := {
	"beam": ["stackType", "moduleIndex", "stackId", "patternId", "layerIndex", "arrayIndex"],
	"bolt": ["boltType", "boltSubType", "moduleIndex", "ring", "role", "cap", "arrayIndex", "rcpStackId", "rcpStackA", "rcpStackB"],
	"washer": ["washerType", "boltSubType", "moduleIndex", "ring", "role", "gapIndex", "cap", "arrayIndex"],
	"bracket": ["moduleIndex", "ring", "pivotRole", "cap", "arrayIndex"],
	"placement": ["assemblyId", "moduleIndex", "ring", "cap", "arrayIndex"],
	"hwpart": ["assemblyId", "moduleIndex", "ring", "cap", "arrayIndex", "partId", "copyIndex", "renderAxisKey"],
	"panel": ["index"],
	"wall": ["spanIndex", "band", "coverType", "moduleIndex", "arrayIndex"],
}


static func joint_role_rank(role: String) -> int:
	return int(JOINT_ROLE_RANK.get(role, 3))


# ---------------------------------------------------------------------------
# Field access (JS `num(v, fallback)` + the ring / role / pivot fallbacks)
# ---------------------------------------------------------------------------

static func _num(obj: Dictionary, key: String, fallback: int) -> int:
	var v = obj.get(key)
	if v is int:
		return v
	if v is float and not is_nan(v):
		return int(v)
	return fallback


static func _str(obj: Dictionary, key: String) -> String:
	var v = obj.get(key)
	return "" if v == null else str(v)


static func _ring(obj: Dictionary) -> String:
	var r := _str(obj, "ring")
	if not r.is_empty():
		return r
	return "bottom" if bool(obj.get("is_bottom", false)) else "top"


static func _role(obj: Dictionary) -> String:
	var r := _str(obj, "role")
	return r if not r.is_empty() else _str(obj, "bolt_sub_type")


static func _or_dash(v: String) -> String:
	return v if not v.is_empty() else "-"


static func _cap(obj: Dictionary) -> String:
	return ":cap" if bool(obj.get("cap", false)) else ""


## Kind of a part dictionary (part-keys.js partKind). `collect_parts` tags
## kinds explicitly; this is for loose dictionaries.
static func part_kind(obj) -> String:
	if not (obj is Dictionary):
		return ""
	var d: Dictionary = obj
	if d.has("_part_kind"):
		return str(d["_part_kind"])
	if d.has("stack_type"):
		return "beam"
	if d.has("washer_type"):
		return "washer"
	if d.has("bolt_type"):
		return "bolt"
	if d.has("assembly_id") and d.has("part_id"):
		return "hwpart"
	if d.has("assembly_id"):
		return "placement"
	if d.has("hole_distance") and d.has("pos"):
		return "bracket"
	if str(d.get("type", "")) == "covering":
		return "wall"
	if str(d.get("type", "")) == "panel":
		return "panel"
	return ""


# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

## Deterministic key for one part (part-keys.js partKey). "" for non-parts.
static func part_key(obj: Dictionary, kind: String = "") -> String:
	if kind.is_empty():
		kind = part_kind(obj)
	var a := "a%d" % _num(obj, "array_index", 0)
	var m := "m%d" % _num(obj, "module_index", -1)
	match kind:
		"beam":
			return "beam:%s:%s:%s:s%d:%s:L%d" % [
				_str(obj, "stack_type") if not _str(obj, "stack_type").is_empty() else "unknown",
				a, m, _num(obj, "stack_id", -1), _or_dash(_str(obj, "pattern_id")),
				_num(obj, "layer_index", 0)]
		"bolt":
			var bt := _str(obj, "bolt_type")
			if bt == "rcp-ring":
				return "bolt:rcp-ring:r%d:%s" % [_num(obj, "rcp_stack_id", -1), a]
			if bt == "rcp-cross":
				return "bolt:rcp-cross:r%d-%d:%s:%s" % [_num(obj, "rcp_stack_a", -1),
					_num(obj, "rcp_stack_b", -1), _or_dash(_str(obj, "bolt_sub_type")), a]
			return "bolt:%s:%s:%s:%s:%s%s" % [bt, a, m, _or_dash(_str(obj, "ring")),
				_or_dash(_role(obj)), _cap(obj)]
		"washer":
			return "washer:%s:%s:%s:%s:%s%s:g%d" % [_str(obj, "washer_type"), a, m,
				_or_dash(_str(obj, "ring")), _or_dash(_role(obj)), _cap(obj), _num(obj, "gap_index", 0)]
		"bracket":
			var pr := _str(obj, "pivot_role")
			return "bracket:%s:%s:%s:%s%s" % [a, m, _ring(obj), pr if not pr.is_empty() else "outer", _cap(obj)]
		"placement":
			return "hwpl:%s:%s:%s:%s%s" % [_str(obj, "assembly_id"), a, m, _ring(obj), _cap(obj)]
		"hwpart":
			var pl: String
			if obj.get("placement") is Dictionary:
				pl = part_key(obj["placement"], "placement")
			else:
				pl = "hwpl:%s:%s:%s:%s" % [_str(obj, "assembly_id"), a, m, _or_dash(_str(obj, "ring"))]
			return "hwpart:%s:%s:%s:c%d" % [pl, _str(obj, "part_id"),
				_or_dash(_str(obj, "render_axis_key")), _num(obj, "copy_index", 0)]
		"panel":
			return "panel:%d" % _num(obj, "index", _num(obj, "panel_index", 0))
		"wall":
			var ai := _num(obj, "array_index", 0)
			var band := _str(obj, "band")
			return "wall:s%d:%s%s" % [_num(obj, "span_index", 0),
				band if not band.is_empty() else "lower", (":a%d" % ai) if ai != 0 else ""]
	return ""


## Canonical key of the JOINT a fastener belongs to (part-keys.js jointKey): a
## simple bolt and the hardware placement that replaces it share it, so a
## fasten step keeps its target when the representation switches.
static func joint_key(obj: Dictionary, kind: String = "") -> String:
	if kind.is_empty():
		kind = part_kind(obj)
	var a := "a%d" % _num(obj, "array_index", 0)
	var m := "m%d" % _num(obj, "module_index", -1)
	match kind:
		"bolt":
			var bt := _str(obj, "bolt_type")
			if bt == "rcp-ring" or bt == "rcp-cross":
				return part_key(obj, kind)
			return "joint:%s:%s:%s:%s%s" % [a, m, _or_dash(_str(obj, "ring")), _or_dash(_role(obj)), _cap(obj)]
		"washer":
			return "joint:%s:%s:%s:%s%s" % [a, m, _or_dash(_str(obj, "ring")), _or_dash(_role(obj)), _cap(obj)]
		"bracket":
			var pr := _str(obj, "pivot_role")
			return "joint:%s:%s:%s:%s%s" % [a, m, _ring(obj), pr if not pr.is_empty() else "outer", _cap(obj)]
		"placement":
			var role := str(ASSEMBLY_ROLES.get(_str(obj, "assembly_id"), ""))
			if role.is_empty():
				role = _or_dash(_str(obj, "pivot_role"))
			return "joint:%s:%s:%s:%s%s" % [a, m, _ring(obj), role, _cap(obj)]
		"hwpart":
			if obj.get("placement") is Dictionary:
				return joint_key(obj["placement"], "placement")
	return ""


# ---------------------------------------------------------------------------
# Labels
# ---------------------------------------------------------------------------

## Human-readable label (part-keys.js describePart).
static func describe_part(obj: Dictionary, kind: String = "") -> String:
	if kind.is_empty():
		kind = part_kind(obj)
	var mi := _num(obj, "module_index", -1)
	var ai := _num(obj, "array_index", 0)
	var mod := (", module %d" % (mi + 1)) if mi >= 0 else ""
	var arr := (", array %d" % (ai + 1)) if ai > 0 else ""
	var cap := " (cap)" if bool(obj.get("cap", false)) else ""
	match kind:
		"beam":
			var st := _str(obj, "stack_type")
			var base := str(STACK_TYPE_LABELS.get(st, st if not st.is_empty() else "Beam"))
			var layer := (", layer %d" % (_num(obj, "layer_index", 0) + 1)) if obj.has("layer_index") else ""
			var pid := _str(obj, "pattern_id")
			var pat := (" (%s)" % pid) if not pid.is_empty() else ""
			if st == "support-beam" or st == "support-beam-reciprocal":
				return "%s %d%s" % [base, _num(obj, "stack_id", 0) + 1, arr]
			return base + mod + layer + pat + arr
		"bolt":
			var bt := _str(obj, "bolt_type")
			var base := str(BOLT_TYPE_LABELS.get(bt, "Bolt"))
			if bt == "rcp-ring":
				return "%s (beam %d)%s" % [base, _num(obj, "rcp_stack_id", 0) + 1, arr]
			if bt == "rcp-cross":
				return "%s (beams %d/%d)%s" % [base, _num(obj, "rcp_stack_a", 0) + 1, _num(obj, "rcp_stack_b", 0) + 1, arr]
			var where := _join_nonempty([_str(obj, "ring"), _role(obj)])
			return base + ((" (%s)" % where) if not where.is_empty() else "") + cap + mod + arr
		"washer":
			var where := _join_nonempty([_str(obj, "ring"), _role(obj)])
			var w := ""
			if not where.is_empty():
				w = " (%s, gap %d)" % [where, _num(obj, "gap_index", 0) + 1]
			return "Washer" + w + cap + mod + arr
		"bracket":
			var pr := _str(obj, "pivot_role")
			return "Bracket (%s %s)%s%s%s" % [_ring(obj), pr if not pr.is_empty() else "outer", cap, mod, arr]
		"placement":
			return "%s assembly (%s)%s%s%s" % [_str(obj, "assembly_id"), _ring(obj), cap, mod, arr]
		"hwpart":
			var lbl := _str(obj, "part_label")
			var pl = obj.get("placement")
			return "%s in %s" % [lbl if not lbl.is_empty() else _str(obj, "part_id"),
				describe_part(pl if pl is Dictionary else {}, "placement")]
		"panel":
			return "Solar panel %d" % (_num(obj, "index", 0) + 1)
		"wall":
			var band := _str(obj, "band")
			var span := _num(obj, "span_index", 0) + 1
			if band == "floor":
				return "Floor deck"
			if band == "roof":
				return "Shade tarp %d" % span
			var what := "Table" if band == "table" else "%s %s" % [
				"Upper" if band == "upper" else "Lower",
				"fabric" if _str(obj, "cover_type") == "fabric" else "plywood wall"]
			return "%s, span %d" % [what, span]
	return "Part" if not kind.is_empty() else "Unknown part"


static func _join_nonempty(parts: Array) -> String:
	var out: PackedStringArray = []
	for s in parts:
		if not str(s).is_empty():
			out.append(str(s))
	return " ".join(out)


# ---------------------------------------------------------------------------
# Selectors (web camelCase, saved in buildSteps)
# ---------------------------------------------------------------------------

## Exact selector matching only this part (part-keys.js selectorForPart).
static func selector_for_part(obj: Dictionary, kind: String = "") -> Dictionary:
	if kind.is_empty():
		kind = part_kind(obj)
	var sel := {"kind": kind}
	var cap_sel = true if bool(obj.get("cap", false)) else null
	match kind:
		"beam":
			_put(sel, "stackType", obj.get("stack_type"))
			sel["moduleIndex"] = _num(obj, "module_index", -1)
			sel["stackId"] = _num(obj, "stack_id", -1)
			_put(sel, "patternId", _str(obj, "pattern_id") if not _str(obj, "pattern_id").is_empty() else null)
			sel["layerIndex"] = _num(obj, "layer_index", 0)
			sel["arrayIndex"] = _num(obj, "array_index", 0)
		"bolt":
			var bt := _str(obj, "bolt_type")
			_put(sel, "boltType", obj.get("bolt_type"))
			if bt == "rcp-ring":
				_put(sel, "rcpStackId", obj.get("rcp_stack_id"))
				sel["arrayIndex"] = _num(obj, "array_index", 0)
				return sel
			if bt == "rcp-cross":
				_put(sel, "rcpStackA", obj.get("rcp_stack_a"))
				_put(sel, "rcpStackB", obj.get("rcp_stack_b"))
				_put(sel, "boltSubType", obj.get("bolt_sub_type"))
				sel["arrayIndex"] = _num(obj, "array_index", 0)
				return sel
			sel["moduleIndex"] = _num(obj, "module_index", -1)
			_put(sel, "ring", obj.get("ring"))
			_put(sel, "role", _role(obj) if not _role(obj).is_empty() else null)
			_put(sel, "cap", cap_sel)
			sel["arrayIndex"] = _num(obj, "array_index", 0)
		"washer":
			_put(sel, "washerType", obj.get("washer_type"))
			sel["moduleIndex"] = _num(obj, "module_index", -1)
			_put(sel, "ring", obj.get("ring"))
			_put(sel, "role", _role(obj) if not _role(obj).is_empty() else null)
			sel["gapIndex"] = _num(obj, "gap_index", 0)
			_put(sel, "cap", cap_sel)
			sel["arrayIndex"] = _num(obj, "array_index", 0)
		"bracket":
			sel["moduleIndex"] = _num(obj, "module_index", -1)
			sel["ring"] = _ring(obj)
			var pr := _str(obj, "pivot_role")
			sel["pivotRole"] = pr if not pr.is_empty() else "outer"
			_put(sel, "cap", cap_sel)
			sel["arrayIndex"] = _num(obj, "array_index", 0)
		"placement":
			_put(sel, "assemblyId", obj.get("assembly_id"))
			sel["moduleIndex"] = _num(obj, "module_index", -1)
			sel["ring"] = _ring(obj)
			_put(sel, "cap", cap_sel)
			sel["arrayIndex"] = _num(obj, "array_index", 0)
		"hwpart":
			var pl = obj.get("placement")
			sel = selector_for_part(pl if pl is Dictionary else {}, "placement")
			sel["kind"] = "hwpart"
			_put(sel, "partId", obj.get("part_id"))
			sel["copyIndex"] = _num(obj, "copy_index", 0)
			_put(sel, "renderAxisKey", obj.get("render_axis_key"))
		"panel":
			sel["index"] = _num(obj, "index", 0)
		"wall":
			sel["spanIndex"] = _num(obj, "span_index", 0)
			_put(sel, "band", obj.get("band"))
			if _num(obj, "array_index", 0) != 0:
				sel["arrayIndex"] = _num(obj, "array_index", 0)
		_:
			return {}
	return sel


static func _put(sel: Dictionary, field: String, value) -> void:
	if value != null:
		sel[field] = value


## "Every part of this kind in the same module / ring" (groupSelectorForPart).
static func group_selector_for_part(obj: Dictionary, kind: String = "") -> Dictionary:
	if kind.is_empty():
		kind = part_kind(obj)
	var exact := selector_for_part(obj, kind)
	if exact.is_empty():
		return {}
	var sel := {"kind": exact["kind"]}
	match kind:
		"beam":
			sel["stackType"] = exact.get("stackType")
			sel["moduleIndex"] = exact.get("moduleIndex")
			if int(exact.get("arrayIndex", 0)) != 0:
				sel["arrayIndex"] = exact["arrayIndex"]
		"bolt", "washer":
			for f in ["boltType", "washerType", "moduleIndex", "ring"]:
				if exact.has(f):
					sel[f] = exact[f]
		"bracket", "placement":
			sel["moduleIndex"] = exact.get("moduleIndex")
			if exact.has("assemblyId"):
				sel["assemblyId"] = exact["assemblyId"]
		"wall":
			sel["band"] = exact.get("band")
		_:
			return exact
	return sel


## A selector field's value on a part (part-keys.js fieldValue).
static func field_value(obj: Dictionary, kind: String, field: String):
	match field:
		"moduleIndex":
			return _num(obj, "module_index", -1)
		"arrayIndex":
			return _num(obj, "array_index", 0)
		"layerIndex":
			return _num(obj, "layer_index", 0)
		"gapIndex":
			return _num(obj, "gap_index", 0)
		"copyIndex":
			return _num(obj, "copy_index", 0)
		"index":
			return _num(obj, "index", _num(obj, "panel_index", 0))
		"cap":
			return bool(obj.get("cap", false))
		"ring":
			if not _str(obj, "ring").is_empty():
				return _str(obj, "ring")
			if obj.has("is_bottom"):
				return "bottom" if bool(obj["is_bottom"]) else "top"
			return null
		"role":
			var r := _role(obj)
			return r if not r.is_empty() else null
		"pivotRole":
			var pr := _str(obj, "pivot_role")
			return pr if not pr.is_empty() else "outer"
		"patternId":
			var pid := _str(obj, "pattern_id")
			return pid if not pid.is_empty() else null
	var key: String = FIELD.get(field, field)
	if kind == "hwpart" and not obj.has(key) and obj.get("placement") is Dictionary:
		return field_value(obj["placement"], "placement", field)
	return obj.get(key)


## part-keys.js valueMatches: value, array of values, {min,max}, or "*" / null.
static func value_matches(actual, wanted) -> bool:
	if wanted == null or (wanted is String and wanted == "*"):
		return true
	if wanted is Array:
		for w in wanted:
			if value_matches(actual, w):
				return true
		return false
	if wanted is Dictionary:
		if not (actual is int or actual is float):
			return false
		if wanted.has("min") and float(actual) < float(wanted["min"]):
			return false
		if wanted.has("max") and float(actual) > float(wanted["max"]):
			return false
		return true
	if (actual is int or actual is float) and (wanted is int or wanted is float):
		return float(actual) == float(wanted)
	if typeof(actual) != typeof(wanted):
		return false
	return actual == wanted


## Does a part match a selector (part-keys.js matchSelector)? `kind: "joint"`
## matches any fastener-side part whose JOINT fields match; `kind: "*"` any kind.
static func match_selector(obj: Dictionary, selector: Dictionary, kind: String = "") -> bool:
	if kind.is_empty():
		kind = part_kind(obj)
	if kind.is_empty() or selector.is_empty():
		return false
	if selector.get("key") != null:
		return str(selector["key"]) == part_key(obj, kind)
	var skind := str(selector.get("kind", ""))
	if skind == "joint":
		if not (kind in ["bolt", "washer", "bracket", "placement", "hwpart"]):
			return false
		var jk := joint_key(obj, kind)
		if not jk.begins_with("joint:"):
			return false
		var bits := jk.split(":")
		var cap := jk.ends_with(":cap")
		var sel_cap = selector.get("cap")
		return value_matches(int(bits[1].substr(1)), selector.get("arrayIndex")) \
			and value_matches(int(bits[2].substr(1)), selector.get("moduleIndex")) \
			and value_matches(bits[3], selector.get("ring")) \
			and value_matches(bits[4], selector.get("role")) \
			and (sel_cap == null or (sel_cap is String and sel_cap == "*") or bool(sel_cap) == cap) \
			and (selector.get("boltType") == null or kind != "bolt" or value_matches(_str(obj, "bolt_type"), selector["boltType"])) \
			and (selector.get("assemblyId") == null or kind != "placement" or value_matches(_str(obj, "assembly_id"), selector["assemblyId"]))
	if not skind.is_empty() and skind != "*" and skind != kind:
		return false
	for field in SELECTOR_FIELDS.get(kind, []):
		var want = selector.get(field)
		if want == null:
			continue
		if not value_matches(field_value(obj, kind, field), want):
			return false
	return true


# ---------------------------------------------------------------------------
# Collection + resolution
# ---------------------------------------------------------------------------

## Tagged part records `{kind, obj, key}` (part-keys.js collectParts) from a
## part-data dict: {beams, bolts, washers, brackets, placements, panels, walls}.
static func collect_parts(data: Dictionary) -> Array:
	var out: Array = []
	for pair in [["beam", "beams"], ["bolt", "bolts"], ["washer", "washers"],
			["bracket", "brackets"], ["placement", "placements"], ["panel", "panels"],
			["wall", "walls"]]:
		var list = data.get(pair[1])
		if not (list is Array):
			continue
		var idx := 0
		for obj in list:
			if obj is Dictionary:
				var d: Dictionary = obj
				if pair[0] == "panel" and not d.has("index"):
					d["index"] = idx
				var k := part_key(d, pair[0])
				if not k.is_empty():
					out.append({"kind": pair[0], "obj": d, "key": k})
			idx += 1
	return out


## Resolve selectors to parts (part-keys.js resolveTargets).
static func resolve_targets(data: Dictionary, selectors, parts: Array = []) -> Dictionary:
	var all := parts if not parts.is_empty() else collect_parts(data)
	var sels: Array = selectors if selectors is Array else ([selectors] if selectors is Dictionary else [])
	var result := {"items": [], "keys": {}, "beams": [], "bolts": [], "washers": [],
		"brackets": [], "placements": [], "panels": [], "walls": []}
	if sels.is_empty():
		return result
	for rec in all:
		var key: String = rec["key"]
		if result["keys"].has(key):
			continue
		for sel in sels:
			if sel is Dictionary and match_selector(rec["obj"], sel, rec["kind"]):
				result["items"].append(rec)
				result["keys"][key] = true
				var bucket := "placements" if rec["kind"] == "placement" else str(rec["kind"]) + "s"
				if result.has(bucket):
					result[bucket].append(rec["obj"])
				break
	return result


## Representative points of a part, in the solver frame (inches).
static func part_points(obj: Dictionary, kind: String = "") -> Array:
	if kind.is_empty():
		kind = part_kind(obj)
	var out: Array = []
	match kind:
		"beam", "panel":
			if obj.get("corners") is Array and not (obj["corners"] as Array).is_empty():
				return (obj["corners"] as Array).duplicate()
			for k in ["p1", "p2", "center"]:
				if obj.get(k) is Vector3:
					out.append(obj[k])
		"bolt":
			for k in ["start", "end", "center"]:
				if obj.get(k) is Vector3:
					out.append(obj[k])
		"washer":
			if obj.get("center") is Vector3:
				out.append(obj["center"])
		"bracket":
			for k in ["pos", "bottom_pos"]:
				if obj.get(k) is Vector3:
					out.append(obj[k])
		"placement":
			for k in ["pos", "v_bolt_pivot"]:
				if obj.get(k) is Vector3:
					out.append(obj[k])
		"wall":
			for k in ["slab_corners", "corners"]:
				if obj.get(k) is Array and not (obj[k] as Array).is_empty():
					return (obj[k] as Array).duplicate()
			if obj.get("center") is Vector3:
				out.append(obj["center"])
	return out


## Axis-aligned bounds of part records: {min, max, center: Vector3, radius}.
static func parts_bounds(items: Array) -> Dictionary:
	var have := false
	var lo := Vector3.ZERO
	var hi := Vector3.ZERO
	for rec in items:
		for pt in part_points(rec["obj"], rec["kind"]):
			var v: Vector3 = pt
			if not have:
				lo = v
				hi = v
				have = true
			else:
				lo = lo.min(v)
				hi = hi.max(v)
	if not have:
		return {}
	return {"min": lo, "max": hi, "center": (lo + hi) * 0.5,
		"radius": maxf(0.5, (hi - lo).length() / 2.0)}


## Short label for a selector, for step lists (part-keys.js selectorLabel).
static func selector_label(sel: Dictionary) -> String:
	if sel.is_empty():
		return ""
	if sel.get("key") != null:
		return str(sel["key"])
	var parts: PackedStringArray = []
	var kind := str(sel.get("kind", "*"))
	var any := func(f: String) -> bool:
		var v = sel.get(f)
		return v != null and not (v is String and v == "*")
	match kind:
		"beam":
			var st = sel.get("stackType")
			parts.append(str(STACK_TYPE_LABELS.get(str(st), str(st) if st != null else "Beams")))
		"bolt":
			parts.append(str(BOLT_TYPE_LABELS.get(str(sel.get("boltType", "")), "Bolts")))
		"joint":
			parts.append("Joint")
		"placement":
			parts.append("%s assembly" % (str(sel["assemblyId"]) if sel.get("assemblyId") != null else "Hardware"))
		"hwpart":
			parts.append("%s (%s)" % [str(sel.get("partId", "part")) if sel.get("partId") != null else "part",
				str(sel.get("assemblyId")) if sel.get("assemblyId") != null else "assembly"])
		"panel":
			parts.append(("Solar panel %d" % (int(sel["index"]) + 1)) if any.call("index") else "Solar panels")
		"wall":
			var band := str(sel.get("band", ""))
			if band == "floor":
				return "Floor deck"
			if band == "roof":
				parts.append("Shade tarps")
				if any.call("spanIndex"):
					parts.append("#%d" % (int(sel["spanIndex"]) + 1))
				return " · ".join(parts)
			var cover := str(sel.get("coverType", ""))
			var label: String
			if band == "table":
				label = "Tables"
			else:
				label = ("Upper" if band == "upper" else ("Lower" if band == "lower" else "All")) \
					+ (" fabric" if cover == "fabric" else (" walls" if cover == "plywood" else " coverings"))
			parts.append(label)
			parts.append(("span %d" % (int(sel["spanIndex"]) + 1)) if any.call("spanIndex") else "all spans")
		_:
			parts.append("All parts" if kind == "*" else kind.capitalize() + "s")
	for f in ["ring", "role", "pivotRole"]:
		if any.call(f):
			parts.append(str(sel[f]))
	if any.call("moduleIndex"):
		var mi = sel["moduleIndex"]
		if mi is Array:
			var ns: PackedStringArray = []
			for v in mi:
				ns.append(str(int(v) + 1))
			parts.append("modules " + ",".join(ns))
		elif mi is Dictionary:
			parts.append("modules %d-%d" % [int(mi.get("min", 0)) + 1, int(mi.get("max", 0)) + 1])
		else:
			parts.append("module %d" % (int(mi) + 1))
	elif not (kind in ["panel", "wall", "*"]):
		parts.append("all modules")
	if any.call("layerIndex"):
		parts.append("layer %d" % (int(sel["layerIndex"]) + 1))
	if any.call("patternId"):
		parts.append("pattern %s" % str(sel["patternId"]))
	if bool(sel.get("cap", false)):
		parts.append("cap")
	return " · ".join(parts)


# ---------------------------------------------------------------------------
# The web app's part list, built from the game's solve
# ---------------------------------------------------------------------------

## True when a detailed hardware assembly is drawn in place of its simple
## bracket / bolts (hardware-detail.js hwAssemblyEnabled with hwDetailMode off).
## Unlike `LinkageHardware.use_full_detail` this honours the assembly's own
## `detailed` flag, as the web does.
static func hw_assembly_enabled(p: LinkageParams, assembly_id: String) -> bool:
	if not p.show_hardware_full_detail:
		return false
	var asm := LinkageHardware.assembly(p.hardware_assemblies, assembly_id)
	if asm.is_empty() or not bool(asm.get("detailed", true)):
		return false
	return LinkageHardware.assembly_has_parts(p.hardware_assemblies, assembly_id)


## The parts the web app would collect for this design at `fold`
## ({beams, bolts, washers, brackets, placements, panels, walls}).
##
## The solver always emits every simple bracket and bolt (LinkageHwPlacement
## seats the detailed assemblies on those brackets), so the web's
## representation switch lives here: an enabled outer / inner / centre assembly
## REPLACES the matching brackets, bolts and washers with placements, gated
## line for line as solver.js:2008-2315 does — including its asymmetries (the
## h-pivot INNER bolt and the bottom-inner V washers are never replaced).
##
## Not yet produced (later parity phases): floor beams and coverings / floor
## deck / shade ("wall").
static func part_data(p: LinkageParams, fold: float, include_panels: bool = true) -> Dictionary:
	var q := p.duplicate_params()
	q.show_brackets = true
	q.show_bolts = true
	var frame := LinkageSolver.solve(q, fold)
	var full := hw_assembly_enabled(p, "outerVBeam")
	var inner := hw_assembly_enabled(p, "innerVBeam")
	var v_center := hw_assembly_enabled(p, "vCenter")
	var h_center := hw_assembly_enabled(p, "hCenter")

	var beams: Array = (frame["beams"] as Array).duplicate()
	beams.append_array(LinkageGeometry.support_beams(frame, p, fold))
	# The web appends the reciprocal support bolts whatever "show bolts" says
	# (buildLinkageGeometry, linkage-geometry.js:3763).
	var support_bolts := LinkageGeometry.reciprocal_support_bolts(beams, p, fold)

	var brackets: Array = []
	var placements: Array = []
	for br in frame["brackets"]:
		var d: Dictionary = br
		var outer := str(d.get("pivot_role", "outer")) != "inner"
		var replaced := full if outer else inner
		if replaced:
			placements.append(_placement_from(d, "outerVBeam" if outer else "innerVBeam"))
		elif p.show_brackets:
			brackets.append(d)

	var bolts: Array = []
	var washers: Array = []
	if p.show_bolts:
		for b in frame["bolts"]:
			if _bolt_kept(b, full, inner, v_center, h_center):
				bolts.append(b)
		for w in frame.get("washers", []):
			if _washer_kept(w, full, inner):
				washers.append(w)
	bolts.append_array(support_bolts)
	# The raised floor (A4): its beams join the beams after the supports, as
	# the web appends them; the deck, the coverings and the shade tarps are
	# "wall" parts (LinkageEnclosure).
	beams.append_array(LinkageFloor.floor_beams(frame["beams"], p, fold))
	var walls: Array = LinkageEnclosure.compute(beams, p)["walls"]
	# Centre assemblies are placed whenever enabled — the web pushes them even
	# with bolts hidden (solver.js:2026 vCenter, :2238 hCenter).
	for b in frame["bolts"]:
		var d: Dictionary = b
		if str(d.get("role", "")) != "center" or bool(d.get("cap", false)):
			continue
		if str(d["bolt_type"]) == "vstack" and v_center:
			placements.append(_placement_from(d, "vCenter"))
		elif str(d["bolt_type"]) == "hstack" and h_center:
			placements.append(_placement_from(d, "hCenter"))
	# The web emits placements in module order: outer, inner, vCenter, caps,
	# hCenter. Sort so collection order is stable regardless of emission order.
	placements.sort_custom(_placement_less)

	var panels: Array = []
	if include_panels:
		panels = LinkageGeometry.solar_panels(frame, p)
	# The radial array (A3) copies everything, applied last as the web does.
	var pl := LinkageRadialArray.deployed_plan(p)
	if not pl.is_empty():
		var res := LinkageRadialArray.apply(pl, {"beams": beams, "bolts": bolts, "washers": washers,
			"brackets": brackets, "placements": placements, "panels": panels, "walls": walls})
		var g: Dictionary = res["geo"]
		beams = g["beams"]
		bolts = g["bolts"]
		washers = g["washers"]
		brackets = g["brackets"]
		placements = g["placements"]
		panels = g["panels"]
		walls = g["walls"]
		frame = frame.duplicate()
		frame["radial"] = res["plan"]
		frame["max_rad"] = float((res["plan"] as Dictionary).get("max_rad", frame.get("max_rad", 0.0)))
	return {"beams": beams, "bolts": bolts, "washers": washers, "brackets": brackets,
		"placements": placements, "panels": panels, "walls": walls, "frame": frame}


static func _bolt_kept(b: Dictionary, full: bool, inner: bool, v_center: bool, h_center: bool) -> bool:
	var role := str(b.get("role", ""))
	var cap := bool(b.get("cap", false))
	match str(b.get("bolt_type", "")):
		"hpivot":
			return role != "outer" or not full
		"vstack":
			if role == "outer":
				return not full
			if role == "inner":
				return not inner
			return cap or not v_center
		"hstack":
			return not h_center
	return true


static func _washer_kept(w: Dictionary, full: bool, inner: bool) -> bool:
	var role := str(w.get("role", ""))
	match str(w.get("washer_type", "")):
		"hpivot":
			return role != "outer" or not full
		"vstack":
			if role == "outer":
				return not full
			if role == "inner":
				return str(w.get("ring", "")) == "bottom" or not inner
	return true


static func _placement_from(src: Dictionary, assembly_id: String) -> Dictionary:
	var ring := str(src.get("ring", ""))
	if ring.is_empty():
		ring = "bottom" if bool(src.get("is_bottom", false)) else "top"
	return {
		"assembly_id": assembly_id,
		"module_index": int(src.get("module_index", -1)),
		"ring": ring,
		"cap": bool(src.get("cap", false)),
		"array_index": int(src.get("array_index", 0)),
		"pivot_role": str(ASSEMBLY_ROLES.get(assembly_id, "outer")),
		"pos": src.get("pos", src.get("center", Vector3.ZERO)),
		"v_bolt_pivot": src.get("v_bolt_pivot", src.get("center", Vector3.ZERO)),
		# The joint's bolt axis: a bracket's, or the centre bolt's own.
		"bolt_dir": src.get("bolt_dir", src.get("dir", Vector3.UP)),
	}


const _ASM_ORDER := {"outerVBeam": 0, "innerVBeam": 1, "vCenter": 2, "hCenter": 4}
const _RING_ORDER := {"bottom": 0, "top": 1, "center": 2}


static func _placement_less(a: Dictionary, b: Dictionary) -> bool:
	var ka := [int(a["array_index"]), int(a["module_index"]),
		3 if bool(a["cap"]) and str(a["assembly_id"]) != "hCenter" else int(_ASM_ORDER.get(a["assembly_id"], 5)),
		int(_ASM_ORDER.get(a["assembly_id"], 5)), int(_RING_ORDER.get(a["ring"], 3))]
	var kb := [int(b["array_index"]), int(b["module_index"]),
		3 if bool(b["cap"]) and str(b["assembly_id"]) != "hCenter" else int(_ASM_ORDER.get(b["assembly_id"], 5)),
		int(_ASM_ORDER.get(b["assembly_id"], 5)), int(_RING_ORDER.get(b["ring"], 3))]
	for i in ka.size():
		if ka[i] != kb[i]:
			return ka[i] < kb[i]
	return false

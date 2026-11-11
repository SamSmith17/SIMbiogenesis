extends RefCounted

## The library as data an AI can choose from: every shipped preset a design
## may name, with what it takes in, what it gives out and the fields a design
## may `set`. Written once by the kernel (mode "catalog") and served in slices
## by the MCP server, so a model never has to read the game's source.
##
## rows: [label, category, type, role, headline]; `detail[label]` = {specs
## (numbers, booleans and short strings only), in: ["kind rate unit"], out,
## note}. Player-made presets are not listed: a design must build the same on
## anyone's machine.

const SKIP_CATEGORIES := ["my_components", "supernodes", "pbis"]
const NOTE_MAX := 240


static func build() -> Dictionary:
	var rows: Array = []
	var detail := {}
	for cat: Dictionary in ComponentPresets.CATEGORIES:
		var cid := str(cat.get("id", ""))
		if cid in SKIP_CATEGORIES:
			continue
		for p_v in (cat.get("presets", []) as Array):
			if not (p_v is Dictionary):
				continue
			var p: Dictionary = p_v
			var label := str(p.get("label", ""))
			if label.is_empty() or detail.has(label):
				continue
			var sp: Dictionary = p.get("specs", {})
			var ins := _ports(sp.get("inputs", []))
			var outs := _ports(sp.get("outputs", []))
			rows.append([label, cid, str(p.get("type", "")), str(sp.get("role", "")), _headline(p, sp, ins, outs)])
			detail[label] = {"specs": _scalars(sp), "in": ins, "out": outs,
				"note": str(sp.get("daily_note", sp.get("description", ""))).substr(0, NOTE_MAX)}
	return {"v": 1, "cols": ["label", "category", "type", "role", "headline"], "rows": rows, "detail": detail}


static func _ports(list: Variant) -> Array:
	var out: Array = []
	if not (list is Array):
		return out
	for e in (list as Array):
		if e is Dictionary:
			var d: Dictionary = e
			out.append("%s %s %s" % [str(d.get("kind", "?")), str(d.get("rate", d.get("qty", ""))), str(d.get("unit", ""))])
	return out


static func _scalars(sp: Dictionary) -> Dictionary:
	var out := {}
	for k in sp.keys():
		var v: Variant = sp[k]
		if k in ["inputs", "outputs", "daily_note", "description", "icon"]:
			continue
		if v is bool or v is int or v is float:
			out[str(k)] = v
		elif v is String and (v as String).length() <= 60:
			out[str(k)] = v
	return out


static func _headline(p: Dictionary, sp: Dictionary, ins: Array, outs: Array) -> String:
	match str(p.get("type", "")):
		"battery":
			return "%s kWh %s V" % [str(sp.get("kwh", "?")), str(sp.get("voltage", "?"))]
		"panel":
			return "%s W" % str(sp.get("wmp", sp.get("watts", "?")))
		"resource":
			return "%s %s %s" % [str(sp.get("capacity_qty", "?")), str(sp.get("capacity_unit", "")),
				str(sp.get("resource_kind", ""))]
		"controller":
			return "%s W PV, %s W AC" % [str(sp.get("max_pv_watts", "?")), str(sp.get("overload_watts", "?"))]
	var s := ""
	if not ins.is_empty():
		s += "in " + ", ".join(ins.slice(0, 3))
	if not outs.is_empty():
		s += ("; " if not s.is_empty() else "") + "out " + ", ".join(outs.slice(0, 3))
	var w := float(sp.get("watts", sp.get("avg_watts", 0.0)))
	if w > 0.0:
		s += "; %s W" % str(w)
	return s

class_name SiteCost
extends RefCounted

## What a placed thing COST, one rule for every record (the packed-spec
## pattern): a designer's own bill of materials where the design carries one
## (Linkage Lab, Solar designer, CNC gantry), else nothing — and said so. The
## graph half is GraphModel.total_cost() (each node's specs.cost + the wires).
## Both reach SiteBalance's Cost rows and the Site Report. Pure; BOM solves
## are cached per record + spec so a 5 Hz dashboard never re-solves.

static var _cache: Dictionary = {}


## {usd, source: "design" | "unpriced"}
static func for_record(rec: Dictionary) -> Dictionary:
	var key := _key(rec)
	if not key.is_empty() and _cache.has(key):
		return (_cache[key] as Dictionary).duplicate()
	var out := _compute(rec)
	if not key.is_empty():
		_cache[key] = out.duplicate()
	return out


static func _key(rec: Dictionary) -> String:
	for k in ["linkage_spec", "pvlab_spec", "gantry_spec"]:
		if rec.get(k) is Dictionary:
			return "%s|%s|%d" % [str(rec.get("id", "")), k, var_to_str(rec[k]).hash()]
	return ""


static func _compute(rec: Dictionary) -> Dictionary:
	if rec.get("linkage_spec") is Dictionary:
		var p := LinkageParams.new()
		p.from_config(rec.get("linkage_spec") as Dictionary)
		var bom := LinkageBom.compute(p)
		return {"usd": maxf(float(bom.get("total_cost", 0.0)), 0.0), "source": "design"}
	if rec.get("pvlab_spec") is Dictionary:
		var d := PvLabDesign.solve(rec.get("pvlab_spec") as Dictionary)
		return {"usd": maxf(float((d.get("bom", {}) as Dictionary).get("cost_usd", 0.0)), 0.0), "source": "design"}
	if rec.get("gantry_spec") is Dictionary:
		var g := GantryLabDesign.solve(rec.get("gantry_spec") as Dictionary)
		return {"usd": maxf(float((g.get("bom", {}) as Dictionary).get("usd", 0.0)), 0.0), "source": "design"}
	return {"usd": 0.0, "source": "unpriced"}


## Every placed record summed: {usd, priced, unpriced, rows: [{id, name, usd, source}]}.
static func placed_total(records: Array) -> Dictionary:
	var usd := 0.0
	var priced := 0
	var unpriced := 0
	var rows: Array = []
	for r_v in records:
		if not (r_v is Dictionary):
			continue
		var r: Dictionary = r_v
		var c := for_record(r)
		if str(c["source"]) == "unpriced":
			unpriced += 1
		else:
			priced += 1
			usd += float(c["usd"])
		rows.append({"id": str(r.get("id", "")), "name": str(r.get("label", r.get("model_id", ""))),
			"usd": float(c["usd"]), "source": str(c["source"])})
	return {"usd": usd, "priced": priced, "unpriced": unpriced, "rows": rows}


static func format_usd(usd: float) -> String:
	return "$%s" % UiText.thousands(int(round(usd)))

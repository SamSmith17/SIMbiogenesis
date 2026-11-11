class_name GapBrief
extends RefCounted

## A gap node's design brief (resource composition plan Phase 8): what the
## missing machine must do, from what its GapMeter measured. Pure.
##
##   make(specs, meter, ctx) → {title, lines: [{key, text}], data: {…}}
##   ctx: {curtailed_kwh_day: float (NAN = unknown), site: String}
##   markdown(brief) / export(brief, dir) → the .md and .json files.
##
## Example lines:
##   Process 12 L/day of urine (busiest hour 3 L at 07:00).
##   Deliver 10.4 L/day of reclaimed water.
##   Send 95 % of the water and 88 % of the nitrogen out in what it delivers.
##   Release 0.4 kg/day of what is left (salts and the rest): it must leave
##     somewhere.
##   Energy: no target set. The site curtails 3.1 kWh/day of solar.
##   Distillation would take about 9.2 kWh/day; the least it could take is
##     7.2.

const DIR := "user://design_challenges"
const MONTHS := ["January", "February", "March", "April", "May", "June", "July",
	"August", "September", "October", "November", "December"]
const ELEMENT_WORDS := {"C": "carbon", "N": "nitrogen", "P": "phosphorus", "K": "potassium"}


static func make(specs: Dictionary, meter: GapMeter, ctx: Dictionary = {}) -> Dictionary:
	var ins: Array = specs.get("inputs", [])
	var outs: Array = specs.get("outputs", [])
	var title := str(specs.get("name", "Gap"))
	var lines: Array = []
	var data := {"title": title, "inputs": [], "outputs": [], "split": {}, "hours": 0.0}
	var h := meter.hours() if meter != null else 0.0
	data["hours"] = h
	if meter == null or h < 0.5:
		lines.append({"key": "wait", "text": "Not run yet: run the clock and it measures what the machine must do."})
		for i in ins:
			lines.append({"key": "in", "text": "Takes %s." % GraphSuggestions.kind_word(str((i as Dictionary)["kind"]))})
		for o in outs:
			lines.append({"key": "out", "text": "Delivers %s." % GraphSuggestions.kind_word(str((o as Dictionary)["kind"]))})
		return {"title": title, "lines": lines, "data": data}
	var seen := {}
	for i2 in ins:
		var k := str((i2 as Dictionary)["kind"])
		if seen.has("in:" + k):
			continue
		seen["in:" + k] = true
		var pd := meter.per_day("in:" + k)
		var pk := meter.peak("in:" + k)
		var u := _unit(k)
		var txt := "Process %s/day of %s" % [UiText.num(pd, u), GraphSuggestions.kind_word(k)]
		if int(pk["hour_of_day"]) >= 0:
			txt += " (busiest hour %s at %02d:00)" % [UiText.num(float(pk["rate"]), u), int(pk["hour_of_day"])]
		lines.append({"key": "in:" + k, "text": txt + "."})
		(data["inputs"] as Array).append({"kind": k, "per_day": pd, "unit": u, "peak_per_h": float(pk["rate"]),
			"peak_hour": int(pk["hour_of_day"]), "by_month": meter.by_month("in:" + k)})
	for o2 in outs:
		var k2 := str((o2 as Dictionary)["kind"])
		if seen.has("out:" + k2):
			continue
		seen["out:" + k2] = true
		var pd2 := meter.per_day("out:" + k2)
		var verb := "Release" if bool((o2 as Dictionary).get("residue", false)) else "Deliver"
		lines.append({"key": "out:" + k2, "text": "%s %s/day of %s." % [verb, UiText.num(pd2, _unit(k2)), GraphSuggestions.kind_word(k2)]})
		(data["outputs"] as Array).append({"kind": k2, "per_day": pd2, "unit": _unit(k2),
			"residue": bool((o2 as Dictionary).get("residue", false))})
	# The split: how much of each part it must send out in its products.
	var parts := PackedStringArray()
	var w_in := meter.total("water_in")
	if w_in > 1e-6:
		var ws := meter.total("water_out") / w_in
		data["split"]["water"] = ws
		parts.append("%s of the water" % UiText.pct(ws))
	for e in DesignGap.TRACK:
		var ei := meter.total("el_in:" + e)
		if ei > 1e-6:
			var es := meter.total("el_out:" + e) / ei
			data["split"][e] = es
			parts.append("%s of the %s" % [UiText.pct(es), ELEMENT_WORDS[e]])
	if not parts.is_empty():
		lines.append({"key": "split", "text": "Send %s out in what it delivers." % _and(parts)})
	var res := meter.per_day("res_kg")
	data["residue_kg_day"] = res
	if res > 1e-4:
		lines.append({"key": "residue", "text": "Release %s/day of what is left (salts and the rest): it must leave somewhere."
			% UiText.num(res, "kg")})
	var sh := meter.per_day("short_kg")
	data["short_kg_day"] = sh
	# Only a shortfall worth designing for: at least a gram a day and half a
	# percent of the water it takes (trace elements round to less).
	if sh >= maxf(1e-3, 0.005 * meter.per_day("water_in")):
		lines.append({"key": "short", "text": "Needs an extra input: what it is asked to deliver holds %s/day more than comes in."
			% UiText.num(sh, "kg")})
	# Energy.
	var target := float(specs.get("gap_kwh_per_kg", -1.0))
	var kg_day := meter.per_day("water_in")
	var kg_in_day := 0.0
	for d in data["inputs"]:
		kg_in_day += float(d["per_day"]) * CompositionCatalog.kg_per_unit(str(d["kind"]))
	data["kg_in_day"] = kg_in_day
	var curtail := float(ctx.get("curtailed_kwh_day", NAN))
	if target >= 0.0:
		var kwh := meter.per_day("wh") / 1000.0
		data["energy_kwh_day"] = kwh
		lines.append({"key": "energy", "text": "Energy: %s/day at the %s per kg target." % [UiText.num(kwh * 1000.0, "Wh"),
			UiText.num(target * 1000.0, "Wh")]})
	elif not is_nan(curtail):
		lines.append({"key": "energy", "text": "Energy: no target set. The site curtails %s/day of solar, a budget it could fit in."
			% UiText.num(curtail * 1000.0, "Wh")})
	else:
		lines.append({"key": "energy", "text": "Energy: no target set (reported, not drawn)."})
	data["curtailed_kwh_day"] = curtail
	var cid := str(specs.get("gap_class", ""))
	if UnitOps.CLASSES.has(cid):
		var row: Dictionary = UnitOps.CLASSES[cid]
		var basis := kg_day if str(row.get("per", "feed")) == "water" else kg_in_day
		var typical := float(row.get("kwh_per_kg", 0.0)) * basis
		var floor_v := float(row.get("kwh_min", NAN))
		var t := "%s would take about %s/day" % [str(row["label"]), UiText.num(typical * 1000.0, "Wh")]
		if not is_nan(floor_v):
			t += "; the least it could take is %s" % UiText.num(floor_v * basis * 1000.0, "Wh")
		lines.append({"key": "class", "text": t + "."})
		data["class"] = {"id": cid, "typical_kwh_day": typical,
			"min_kwh_day": floor_v * basis if not is_nan(floor_v) else null}
	# Seasons and duty.
	if not ins.is_empty():
		var bm: Array = meter.by_month("in:" + str((ins[0] as Dictionary)["kind"]))
		var hi := -1
		var lo := -1
		for m in 12:
			if is_nan(float(bm[m])):
				continue
			if hi < 0 or float(bm[m]) > float(bm[hi]):
				hi = m
			if lo < 0 or float(bm[m]) < float(bm[lo]):
				lo = m
		# A season only when the months really differ (a week across two
		# months is not one).
		if hi >= 0 and lo >= 0 and hi != lo and float(bm[hi]) > 1.1 * float(bm[lo]):
			var u2 := _unit(str((ins[0] as Dictionary)["kind"]))
			lines.append({"key": "season", "text": "Busiest in %s (%s/day), quietest in %s (%s/day)." % [MONTHS[hi],
				UiText.num(float(bm[hi]), u2), MONTHS[lo], UiText.num(float(bm[lo]), u2)]})
	data["duty"] = meter.duty()
	lines.append({"key": "duty", "text": "Runs %s of the hours measured (%s)." % [UiText.pct(meter.duty()),
		UiText.duration(h)]})
	return {"title": title, "lines": lines, "data": data}


static func markdown(brief: Dictionary, site: String = "") -> String:
	var s := "# %s\n\n" % str(brief.get("title", "Gap"))
	if not site.is_empty():
		s += "Site: %s\n\n" % site
	for l in brief.get("lines", []):
		s += "- %s\n" % str((l as Dictionary)["text"])
	return s


## Write <slug>.md and <slug>.json into `dir`. → the .md path ("" = failed).
static func export(brief: Dictionary, dir: String = DIR, site: String = "") -> String:
	DirAccess.make_dir_recursive_absolute(dir)
	var slug := str(brief.get("title", "gap")).to_snake_case().validate_filename()
	if slug.is_empty():
		slug = "gap"
	var md := dir.path_join(slug + ".md")
	var f := FileAccess.open(md, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(markdown(brief, site))
	f.close()
	var j := FileAccess.open(dir.path_join(slug + ".json"), FileAccess.WRITE)
	if j != null:
		j.store_string(JSON.stringify({"title": brief.get("title", ""), "site": site, "lines": brief.get("lines", []),
			"data": _json_safe(brief.get("data", {}))}, "\t"))
	return md


static func _json_safe(v: Variant) -> Variant:
	if v is float and (is_nan(v) or is_inf(v)):
		return null
	if v is Dictionary:
		var d := {}
		for k in (v as Dictionary).keys():
			d[k] = _json_safe((v as Dictionary)[k])
		return d
	if v is Array:
		var a: Array = []
		for x in v:
			a.append(_json_safe(x))
		return a
	return v


static func _and(parts: PackedStringArray) -> String:
	if parts.size() <= 1:
		return "".join(parts)
	return ", ".join(parts.slice(0, parts.size() - 1)) + " and " + parts[parts.size() - 1]


static func _unit(kind: String) -> String:
	return str(ResourceKinds.kind_meta(kind).get("unit", "kg"))

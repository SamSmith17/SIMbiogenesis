class_name GreenhouseDesign
extends RefCounted

## A greenhouse spec solved into everything the designer, the builder, the
## climate model and the graph read: the frame and its faces, the beds and
## barrels, stats, the bill of materials and the checks. Cached by key.

const CACHE_MAX := 24

static var _cache: Dictionary = {}


static func solve(spec: Dictionary) -> Dictionary:
	var s := GreenhouseSpec.resolve(spec)
	var key := GreenhouseSpec.key_of(s)
	if _cache.has(key):
		var hit: Dictionary = _cache[key]
		if str(hit["spec"]["name"]) == str(s["name"]):
			return hit
		var copy := hit.duplicate()
		copy["spec"] = s
		return copy
	var d := _solve(s)
	d["key"] = key
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[key] = d
	return d


static func clear_cache() -> void:
	_cache.clear()


static func _solve(s: Dictionary) -> Dictionary:
	var fr := GreenhouseFrame.solve(s)
	var lay := GreenhouseBeds.layout(s, fr)
	var stats := _stats(s, fr, lay)
	var bom := _bom(s, fr, lay)
	var checks: Array = (lay["checks"] as Array).duplicate()
	return {"spec": s, "frame": fr, "beds": lay["beds"], "barrels": lay["barrels"], "stats": stats,
		"bom": bom, "checks": checks}


static func _stats(s: Dictionary, fr: Dictionary, lay: Dictionary) -> Dictionary:
	var glazed := 0.0
	var opaque := 0.0
	var earth := 0.0
	var by_facing := {"south": 0.0, "north": 0.0, "east": 0.0, "west": 0.0, "up": 0.0}
	var ua := 0.0
	for f in fr["faces"]:
		var fd: Dictionary = f
		var a := float(fd["area"])
		match str(fd["kind"]):
			"earth":
				earth += a
			_:
				if bool(fd["glazed"]):
					glazed += a
					ua += a * float(GreenhouseMaterials.glazing(str(fd["material"]))["u"])
				else:
					opaque += a
					ua += a * float(GreenhouseMaterials.wall(str(fd["material"]))["u"])
		if bool(fd["glazed"]):
			by_facing[facing_of(fd["normal"])] = float(by_facing[facing_of(fd["normal"])]) + a
	var vent_a := 0.0
	for v in fr["vents"]:
		vent_a += float((v as Dictionary)["area_m2"])
	var light_w := 0.0
	for bd in lay["beds"]:
		if (bd as Dictionary).has("light"):
			light_w += float(bd["light"]["w"])
	var fan := GreenhouseMaterials.fan(str(s["fans"]["kind"]))
	var floor_a := float(fr["floor_area_m2"])
	return {"floor_area_m2": floor_a, "volume_m3": float(fr["volume_m3"]),
		"glazed_m2": glazed, "opaque_m2": opaque, "earth_m2": earth, "glazed_by_facing": by_facing,
		"surface_to_floor": (glazed + opaque) / maxf(floor_a, 0.01),
		"ua_w_k": ua, "vent_m2": vent_a, "vent_share": vent_a / maxf(floor_a, 0.01),
		"fan_m3s": float(s["fans"]["count"]) * float(fan["m3s"]),
		"fan_w": float(s["fans"]["count"]) * float(fan["w"]),
		"bed_area_m2": float(lay["bed_area_m2"]), "beds": (lay["beds"] as Array).size(),
		"bed_share": float(lay["bed_area_m2"]) / maxf(floor_a, 0.01),
		"barrels": int(lay["barrels"]["count"]), "water_mass_l": float(lay["barrels"]["litres"]),
		"light_w": light_w, "roof_plan_m2": float(fr["roof_plan_m2"]),
		"height_m": float(fr["ridge_h_m"]), "frame_m": float(fr["frame_m"]),
		"heater_w": float(GreenhouseMaterials.heater(str(s["heater"]))["w"])}


## Which way a face looks in the local frame (+Z = south, the equator side,
## at the default yaw).
static func facing_of(n: Vector3) -> String:
	if n.y > 0.7:
		return "up"
	if absf(n.z) >= absf(n.x):
		return "south" if n.z > 0.0 else "north"
	return "east" if n.x > 0.0 else "west"


## Rows {item, qty, unit, usd, kg}; totals in the "total" row.
static func _bom(s: Dictionary, fr: Dictionary, lay: Dictionary) -> Array:
	var rows: Array = []
	var frm := GreenhouseMaterials.frame(str(s["frame"]))
	var fm := float(fr["frame_m"])
	rows.append({"item": str(frm["label"]), "qty": fm, "unit": "m", "usd": fm * float(frm["usd_m"]),
		"kg": fm * float(frm["kg_m"])})
	var areas := {}
	for f in fr["faces"]:
		var fd: Dictionary = f
		if str(fd["kind"]) == "door":
			continue
		var mid := str(fd["material"])
		areas[mid] = float(areas.get(mid, 0.0)) + float(fd["area"])
	for mid in areas:
		var a := float(areas[mid])
		if GreenhouseMaterials.GLAZING.has(mid):
			var g := GreenhouseMaterials.glazing(mid)
			rows.append({"item": str(g["label"]), "qty": a, "unit": "m²", "usd": a * float(g["usd_m2"]),
				"kg": a * float(g["kg_m2"])})
		else:
			var w := GreenhouseMaterials.wall(mid)
			rows.append({"item": str(w["label"]), "qty": a, "unit": "m²", "usd": a * float(w["usd_m2"]),
				"kg": a * float(w["kg_m2"])})
	for v in fr["vents"]:
		var vd: Dictionary = v
		var usd := 0.0
		match str(vd["kind"]):
			"ridge":
				usd = float(s["length_m"]) * GreenhouseMaterials.RIDGE_VENT_USD_M
			"sides":
				usd = float(s["length_m"]) * GreenhouseMaterials.ROLLUP_USD_M * (1.0 if str(s["form"]) == "lean_to" else 2.0)
			_:
				usd = float(vd["area_m2"]) * GreenhouseMaterials.LOUVRE_USD_M2
		rows.append({"item": "Vent: " + str(vd["kind"]), "qty": float(vd["area_m2"]), "unit": "m² open",
			"usd": usd, "kg": 0.0})
	var nf := int(s["fans"]["count"])
	if nf > 0:
		var fan := GreenhouseMaterials.fan(str(s["fans"]["kind"]))
		rows.append({"item": str(fan["label"]), "qty": float(nf), "unit": "", "usd": float(nf) * float(fan["usd"]),
			"kg": float(nf) * 25.0})
	var ht := GreenhouseMaterials.heater(str(s["heater"]))
	if float(ht["w"]) > 0.0:
		rows.append({"item": str(ht["label"]), "qty": 1.0, "unit": "", "usd": float(ht["usd"]), "kg": 12.0})
	rows.append({"item": "Doors", "qty": float((fr["doors"] as Array).size()), "unit": "",
		"usd": float((fr["doors"] as Array).size()) * GreenhouseMaterials.DOOR_USD, "kg": 30.0})
	var nb := int(lay["barrels"]["count"])
	if nb > 0:
		rows.append({"item": "Water barrels (%d L)" % int(s["mass"]["litres_each"]), "qty": float(nb), "unit": "",
			"usd": float(nb) * GreenhouseMaterials.BARREL_USD, "kg": float(nb) * 9.0})
	if bool(s["rain"]["gutters"]):
		var gm := float(s["length_m"]) * (1.0 if str(s["form"]) == "lean_to" else 2.0)
		if str(s["form"]) == "dome":
			gm = TAU * float(fr["floor"]["r"])
		rows.append({"item": "Gutters + downpipes", "qty": gm, "unit": "m", "usd": gm * GreenhouseMaterials.GUTTER_USD_M,
			"kg": gm * 1.2})
	var cl := float(s["rain"]["cistern_l"])
	if cl > 0.0:
		rows.append({"item": "Cistern", "qty": cl, "unit": "L", "usd": cl * GreenhouseMaterials.CISTERN_USD_L,
			"kg": cl * 0.05})
	var lw := 0.0
	for bd in lay["beds"]:
		if (bd as Dictionary).has("light"):
			lw += float(bd["light"]["w"])
	if lw > 0.0:
		rows.append({"item": "LED grow lights", "qty": lw, "unit": "W", "usd": lw * GreenhouseMaterials.LED_USD_PER_W,
			"kg": lw * 0.012})
	var tu := 0.0
	var tk := 0.0
	for r in rows:
		tu += float((r as Dictionary)["usd"])
		tk += float(r["kg"])
	rows.append({"item": "Total", "qty": 0.0, "unit": "", "usd": tu, "kg": tk, "total": true})
	return rows


static func cost_usd(d: Dictionary) -> float:
	for r in d["bom"]:
		if bool((r as Dictionary).get("total", false)):
			return float(r["usd"])
	return 0.0


static func mass_kg(d: Dictionary) -> float:
	for r in d["bom"]:
		if bool((r as Dictionary).get("total", false)):
			return float(r["kg"])
	return 0.0


## The shipping form: the frame bundled, the glazing rolled or stacked.
static func packed_spec(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var kg := mass_kg(d)
	var long_m := minf(maxf(float(s["width_m"]), 3.0), 6.1)
	var vol := maxf(kg / 450.0, 0.2)
	var side := sqrt(vol / long_m)
	return PackedSpec.normalize({"w_m": long_m, "d_m": maxf(side, 0.4), "h_m": maxf(side, 0.3),
		"mass_kg": kg, "form": "bundle", "stackable": false, "source": "computed"})

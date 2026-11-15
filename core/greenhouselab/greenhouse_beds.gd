class_name GreenhouseBeds
extends RefCounted

## Where things stand on a greenhouse's floor: the growing beds (raised
## beds, in-ground rows or keyhole rings; any of them with a FarmBot gantry
## and / or a grow-light rack over it), the row of water barrels along the
## back, and the paths between. Pure; local frame of GreenhouseSpec.
##
## Bed: {id, kind: "rect"|"keyhole", x, z, length_m (along X), width_m (Z),
##   keyhole: {...} (GrowBed keys, keyhole only), crops: mix, gantry, lights,
##   area_m2, wall_h_m, headroom_m (inside height left over the bed's low
##   side above its soil), light: {w, ppfd, area_m2} (when lit)}

const EDGE_M := 0.08
const BARREL_D := 0.58
const BARREL_PITCH := 0.62
const BARREL_ROW_W := 0.66
const GANTRY_MAX_LEN := 12.0
const GANTRY_MIN_W := 0.6
## A crop's leaves need this much clear air above them before the glazing.
const HEADROOM_SPARE_M := 0.2


static func layout(spec: Dictionary, fr: Dictionary) -> Dictionary:
	var s := GreenhouseSpec.resolve(spec)
	var b: Dictionary = s["beds"]
	var barrels := _barrels(s, fr)
	var beds: Array = []
	if str(b["layout"]) == "custom" and not (b["items"] as Array).is_empty():
		for it in b["items"]:
			beds.append((it as Dictionary).duplicate(true))
	elif str(fr["form"]) == "dome" or str(b["style"]) == "keyhole":
		beds = _auto_keyholes(s, fr, barrels)
	else:
		beds = _auto_rows(s, fr, barrels)
	for bd in beds:
		_finish_bed(s, fr, bd as Dictionary)
	return {"beds": beds, "barrels": barrels, "checks": checks(s, fr, beds, barrels),
		"bed_area_m2": total_area(beds)}


static func total_area(beds: Array) -> float:
	var a := 0.0
	for bd in beds:
		a += float((bd as Dictionary).get("area_m2", 0.0))
	return a


# --- rows ---------------------------------------------------------------------

static func _auto_rows(s: Dictionary, fr: Dictionary, barrels: Dictionary) -> Array:
	var b: Dictionary = s["beds"]
	var L := float(s["length_m"])
	var W := float(s["width_m"])
	var x0 := -L * 0.5 + float(b["end_clear_m"])
	var x1 := L * 0.5 - float(b["end_clear_m"])
	var z0 := -W * 0.5 + EDGE_M + float(barrels.get("strip_w", 0.0))
	var z1 := W * 0.5 - EDGE_M
	var bw := float(b["bed_w_m"])
	var pw := float(b["path_w_m"])
	if str(b["style"]) == "ground":
		bw = maxf(bw, 0.9)
	var avail := z1 - z0
	var n := maxi(int(floor((avail + pw) / (bw + pw))), 0)
	if n == 0 or x1 - x0 < 0.6:
		return []
	# Spread what is left over the paths so beds sit on the walls.
	var spare := avail - (float(n) * bw + float(n - 1) * pw)
	var path := pw + (spare / float(n - 1) if n > 1 else 0.0)
	var start := z0 if n > 1 else (z0 + z1 - bw) * 0.5
	var out: Array = []
	# Gantry beds longer than a FarmBot track are cut into pieces.
	var pieces := 1
	if bool(b["gantry"]):
		pieces = maxi(int(ceil((x1 - x0) / GANTRY_MAX_LEN)), 1)
	var gap := 0.6
	var piece_len := ((x1 - x0) - gap * float(pieces - 1)) / float(pieces)
	for i in n:
		var zc := start + bw * 0.5 + float(i) * (bw + path)
		for k in pieces:
			var xa := x0 + float(k) * (piece_len + gap)
			out.append({"id": "b%d" % (out.size() + 1), "kind": "rect", "x": xa + piece_len * 0.5,
				"z": zc, "length_m": piece_len, "width_m": bw, "crops": b["crops"],
				"gantry": bool(b["gantry"]), "lights": bool(b["lights"])})
	return out


# --- keyholes -----------------------------------------------------------------

static func _auto_keyholes(s: Dictionary, fr: Dictionary, barrels: Dictionary) -> Array:
	var b: Dictionary = s["beds"]
	var out: Array = []
	var bw := float(b["bed_w_m"])
	var pw := float(b["path_w_m"])
	if str(fr["form"]) == "dome":
		var r := float(fr["floor"]["r"]) - 0.35 - float(barrels.get("strip_w", 0.0))
		out.append(_keyhole_bed("b1", 0.0, 0.0, r, bw, pw, b))
		return out
	var W := float(s["width_m"]) - 2.0 * EDGE_M - float(barrels.get("strip_w", 0.0))
	var L := float(s["length_m"]) - 2.0 * float(b["end_clear_m"])
	var r2 := W * 0.5
	var n := maxi(int(floor((L + pw) / (2.0 * r2 + pw))), 1)
	var zc := float(barrels.get("strip_w", 0.0)) * 0.5
	for i in n:
		var xc := -L * 0.5 + r2 + float(i) * (2.0 * r2 + pw) + (L - (float(n) * 2.0 * r2 + float(n - 1) * pw)) * 0.5
		out.append(_keyhole_bed("b%d" % (i + 1), xc, zc, r2, bw, pw, b))
	return out


static func _keyhole_bed(id: String, x: float, z: float, outer_r: float, bw: float, pw: float,
		b: Dictionary) -> Dictionary:
	var k: Dictionary = GrowBed.KEYHOLE_DEFAULTS.duplicate()
	k["outer_r"] = maxf(outer_r, 1.5)
	k["ring_w"] = bw
	k["path_w"] = pw
	k["wall_h"] = float(b["wall_h_m"])
	k["rings"] = maxi(int(floor((float(k["outer_r"]) - float(k["centre_r"]) + pw) / (bw + pw))), 1)
	return {"id": id, "kind": "keyhole", "x": x, "z": z, "length_m": 2.0 * float(k["outer_r"]),
		"width_m": 2.0 * float(k["outer_r"]), "keyhole": k, "crops": b["crops"],
		"gantry": bool(b["gantry"]), "lights": bool(b["lights"])}


static func keyhole_area(k: Dictionary) -> float:
	var a := 0.0
	for r in GrowBed._keyhole_rings(k):
		var rr: Dictionary = r
		a += 0.5 * (float(rr["a1"]) - float(rr["a0"])) * (pow(float(rr["r1"]), 2.0) - pow(float(rr["r0"]), 2.0))
	return a


# --- barrels ------------------------------------------------------------------

## The water barrels: a row (or rows) along the back (-Z) wall of a tunnel,
## an arc on the back of a dome. {count, litres, positions: [Vector2 x, z],
## strip_w: how much floor they take from the beds}.
static func _barrels(s: Dictionary, fr: Dictionary) -> Dictionary:
	var m: Dictionary = s["mass"]
	var n := int(m["barrels"])
	if n <= 0:
		return {"count": 0, "litres": 0.0, "positions": [], "strip_w": 0.0}
	var pos: Array = []
	var rows := 1
	if str(fr["form"]) == "dome":
		var r := float(fr["floor"]["r"]) - 0.4
		var ring := 0
		while pos.size() < n and r > 1.0:
			# The back half of the circle, centred on -Z.
			var span := PI * 0.8
			var per := maxi(int(floor(span * r / BARREL_PITCH)), 1)
			for i in per:
				if pos.size() >= n:
					break
				var a := -PI * 0.5 - span * 0.5 + span * (float(i) + 0.5) / float(per)
				pos.append(Vector2(cos(a) * r, sin(a) * r))
			r -= BARREL_ROW_W
			ring += 1
		rows = maxi(ring, 1)
	else:
		var L := float(s["length_m"]) - 2.0 * float(s["beds"]["end_clear_m"])
		var per_row := maxi(int(floor(L / BARREL_PITCH)), 1)
		rows = int(ceil(float(n) / float(per_row)))
		var zb := -float(s["width_m"]) * 0.5 + EDGE_M + BARREL_ROW_W * 0.5
		for i in n:
			var row := i / per_row
			var k := i % per_row
			pos.append(Vector2(-L * 0.5 + BARREL_PITCH * (float(k) + 0.5), zb + float(row) * BARREL_ROW_W))
	return {"count": pos.size(), "litres": float(pos.size()) * float(m["litres_each"]), "positions": pos,
		"strip_w": float(rows) * BARREL_ROW_W}


# --- per bed ------------------------------------------------------------------

static func _finish_bed(s: Dictionary, fr: Dictionary, bd: Dictionary) -> void:
	bd["wall_h_m"] = float(s["beds"]["wall_h_m"]) if str(s["beds"]["style"]) != "ground" else 0.05
	if str(bd["kind"]) == "keyhole":
		bd["area_m2"] = keyhole_area(bd["keyhole"])
	else:
		bd["area_m2"] = float(bd["length_m"]) * float(bd["width_m"])
	bd["headroom_m"] = headroom(fr, bd) - float(bd["wall_h_m"])
	# A "garden" bed under a low roof keeps the crops that fit there: the
	# tall ones (staked tomatoes, pole beans) go to the beds in the middle.
	if bd["crops"] is String and str(bd["crops"]) == "garden":
		var fit: Array = []
		for c in GardenCrops.GARDEN_BEDS:
			if float(GardenCrops.info(str(c))["height"]) + HEADROOM_SPARE_M <= float(bd["headroom_m"]):
				fit.append({"crop": str(c), "share": 1.0})
		if fit.size() < (GardenCrops.GARDEN_BEDS as Array).size() and not fit.is_empty():
			bd["crops"] = GreenhouseSpec.clean_mix(fit)
	if bool(bd.get("lights", false)):
		var lt: Dictionary = s["lights"]
		var area := float(bd["area_m2"])
		bd["light"] = {"area_m2": area, "ppfd": float(lt["ppfd"]),
			"w": float(lt["ppfd"]) * area / GreenhouseMaterials.LED_EFFICACY_UMOL_J,
			"hang_m": float(lt["hang_m"])}


## The least inside height over a bed (sampled along its edges).
static func headroom(fr: Dictionary, bd: Dictionary) -> float:
	var x := float(bd["x"])
	var z := float(bd["z"])
	var lo := INF
	if str(bd["kind"]) == "keyhole":
		var r := float((bd["keyhole"] as Dictionary)["outer_r"])
		for i in 12:
			var a := TAU * float(i) / 12.0
			lo = minf(lo, GreenhouseFrame.height_at_xz(fr, x + cos(a) * r, z + sin(a) * r))
		return lo
	# The plants stand a little in from the bed's walls.
	var hl := float(bd["length_m"]) * 0.5 - 0.2
	var hw := float(bd["width_m"]) * 0.3
	for sx: float in [-1.0, 0.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			lo = minf(lo, GreenhouseFrame.height_at_xz(fr, x + sx * hl, z + sz * hw))
	return lo


static func tallest_crop(mix: Variant) -> float:
	var h := 0.0
	for c in GreenhouseSpec.mix_crops(mix):
		h = maxf(h, float(GardenCrops.info(str(c))["height"]))
	return h


# --- checks -------------------------------------------------------------------

## {level: "error"|"warn"|"info", text, why}
static func checks(s: Dictionary, fr: Dictionary, beds: Array, barrels: Dictionary) -> Array:
	var out: Array = []
	if beds.is_empty():
		out.append({"level": "warn", "text": "No room for a bed on this floor.",
			"why": "The beds need the end clearance plus at least one bed width inside the walls."})
	for bd in beds:
		var need := tallest_crop(bd["crops"]) + HEADROOM_SPARE_M
		if bool(bd.get("lights", false)):
			need = maxf(need, float(s["lights"]["hang_m"]) + 0.1)
		if float(bd["headroom_m"]) < need:
			out.append({"level": "warn", "ids": [str(bd["id"])],
				"text": "Bed %s: %.1f m over the soil at its low side, its crops want %.1f m." % [
					str(bd["id"]), float(bd["headroom_m"]), need],
				"why": "Tall crops and light racks need clear air under the glazing; move tall crops to the middle or raise the eaves."})
		if bool(bd.get("gantry", false)):
			if str(bd["kind"]) == "rect" and float(bd["length_m"]) > GANTRY_MAX_LEN + 0.01:
				out.append({"level": "warn", "ids": [str(bd["id"])],
					"text": "Bed %s is longer than a FarmBot track (12 m)." % str(bd["id"]),
					"why": "FarmBot sells tracks up to the Genesis XL; longer beds need two gantries."})
			if float(bd["width_m"]) < GANTRY_MIN_W:
				out.append({"level": "warn", "ids": [str(bd["id"])],
					"text": "Bed %s is too narrow for a gantry." % str(bd["id"]),
					"why": "The gantry's cross slide needs at least 0.6 m between its tracks."})
	var floor_a := float(fr["floor_area_m2"])
	var vent_a := 0.0
	for v in fr["vents"]:
		vent_a += float((v as Dictionary)["area_m2"])
	var fans := int(s["fans"]["count"])
	var fan_m3s := float(fans) * float(GreenhouseMaterials.fan(str(s["fans"]["kind"]))["m3s"])
	if vent_a < 0.15 * floor_a and fan_m3s < GreenhouseMaterials.FAN_M3S_PER_M2 * floor_a * 0.5:
		out.append({"level": "warn",
			"text": "Vents are %d %% of the floor and the fans are small: it will overheat on sunny days." % int(round(100.0 * vent_a / maxf(floor_a, 0.01))),
			"why": "Natural ventilation wants vents of 15-25 % of the floor area; fans about 0.04 m³/s per m² (NGMA)."})
	var fr_span := float(GreenhouseMaterials.frame(str(s["frame"]))["max_span_m"])
	if str(fr["form"]) != "dome" and float(s["width_m"]) > fr_span:
		out.append({"level": "warn", "text": "%s spans %.1f m at most; this house is %.1f m wide." % [
			str(GreenhouseMaterials.frame(str(s["frame"]))["label"]), fr_span, float(s["width_m"])],
			"why": "Wider houses need a heavier hoop or a truss to carry snow and wind."})
	if str(fr["form"]) == "lean_to" and float(s["ground"]["sink_m"]) == 0.0 and int(barrels["count"]) == 0 \
			and float(GreenhouseMaterials.wall(str(s["back_wall"]))["cap_kj_m2k"]) < 100.0:
		out.append({"level": "info", "text": "A lean-to stores heat best in a masonry back wall or water barrels.",
			"why": "A passive solar greenhouse warms its back wall by day and lives off it at night."})
	var gl := GreenhouseMaterials.glazing(str(s["glazing"]["roof"]))
	if float(gl["tau_lw"]) > 0.5:
		out.append({"level": "info", "text": "Single poly passes long-wave heat: clear nights can get colder inside than out.",
			"why": "Polyethylene film is transparent to thermal infrared unless IR-treated (Giacomelli & Roberts 1993)."})
	return out

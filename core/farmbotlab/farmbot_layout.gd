class_name FarmBotLayout
extends RefCounted

## Where every plant on a FarmBot bed goes, and when it is sown.
##
## The bed (its local frame: X along the length, Z across, centred on the
## prop) is cut into SECTIONS, each one crop sown on one day:
##   rows        each crop takes a share of the bed's length; its band is cut
##               into sections `section_m` long, the full width
##   blocks      each crop takes a lane along the whole length, as wide as its
##               share; lanes cut into sections along the length
##   interleave  the crops alternate in strips `section_m` long, each crop's
##               strips in proportion to its share (companion rows)
## Plants in a section sit at the crop's spacing (GardenCrops) times
## `spacing_scale`, packed square or hexagonal, half a spacing in from its
## edges. Sections are sown in succession over a crop's first cycle (the same
## rule GrowBed uses), so the robot seeds a little every day and the bed is
## never all bare or all ripe.

## -> {plants: [{crop, x, z, sow_d, section}], sections: [{crop, rect: Rect2
##    (x, z, length, width) in bed metres, sow_d, n}], counts: {crop: n},
##    total: int, tall: [crop ids taller than the gantry clearance]}
static func solve(spec: Dictionary) -> Dictionary:
	var s := FarmBotSpec.resolve(spec)
	var out := _solve_inner(s)
	# Every plant's machine X, Y, once (the day plans read them thousands of
	# times).
	for p in (out["plants"] as Array):
		var m := FarmBotGeom.to_machine(s, float(p["x"]), float(p["z"]))
		p["mx"] = m.x
		p["my"] = m.y
	return out


static func _solve_inner(s: Dictionary) -> Dictionary:
	var b: Dictionary = s["bed"]
	var L := float(b["length_m"])
	var W := float(b["width_m"])
	var c: Dictionary = s["crops"]
	var mix: Array = c["mix"]
	var tot := 0.0
	for e in mix:
		tot += float((e as Dictionary)["share"])
	if tot <= 0.0:
		tot = 1.0
	var sec_m := float(c["section_m"])
	if FarmBotGeom.is_radial(s):
		return _solve_radial(s, mix, tot)
	var rects: Array = []           # [crop, Rect2]
	var x0 := -L * 0.5
	var z0 := -W * 0.5
	match str(c["layout"]):
		"blocks":
			var z := z0
			for e2 in mix:
				var w := W * float((e2 as Dictionary)["share"]) / tot
				if w < 0.05:
					continue
				var n := maxi(int(roundf(L / sec_m)), 1)
				for k in n:
					rects.append([str(e2["crop"]), Rect2(x0 + L * float(k) / float(n), z, L / float(n), w)])
				z += w
		"interleave":
			var n2 := maxi(int(roundf(L / sec_m)), 1)
			# Deal strips to crops in proportion (largest remainder each step).
			var owed: Array = []
			for e3 in mix:
				owed.append(0.0)
			for k2 in n2:
				for i in mix.size():
					owed[i] = float(owed[i]) + float((mix[i] as Dictionary)["share"]) / tot
				var best := 0
				for i2 in mix.size():
					if float(owed[i2]) > float(owed[best]):
						best = i2
				owed[best] = float(owed[best]) - 1.0
				rects.append([str((mix[best] as Dictionary)["crop"]), Rect2(x0 + L * float(k2) / float(n2), z0, L / float(n2), W)])
		_:
			var x := x0
			for e4 in mix:
				var band := L * float((e4 as Dictionary)["share"]) / tot
				if band < 0.05:
					continue
				var n3 := maxi(int(roundf(band / sec_m)), 1)
				for k3 in n3:
					rects.append([str(e4["crop"]), Rect2(x + band * float(k3) / float(n3), z0, band / float(n3), W)])
				x += band
	var plants: Array = []
	var sections: Array = []
	var counts := {}
	var per_crop_k := {}
	var hex := str(c["packing"]) == "hex"
	var scale := float(c["spacing_scale"])
	var bay := toolbay_rect(s)
	for si in rects.size():
		var crop := str(rects[si][0])
		var rc: Rect2 = rects[si][1]
		var sp := GardenCrops.spacing(crop) * scale
		var k4 := int(per_crop_k.get(crop, 0))
		per_crop_k[crop] = k4 + 1
		var sow := first_sow(crop, k4)
		var pts: Array = []
		for p0 in pack(rc, sp, hex):
			# Nothing grows under the tool bay (a plant's crown clears it).
			if not bay.grow(sp * 0.4).has_point(p0):
				pts.append(p0)
		for p in pts:
			var q: Vector2 = p
			plants.append({"crop": crop, "x": q.x, "z": q.y, "sow_d": sow, "section": si})
		sections.append({"crop": crop, "shape": "rect", "rect": rc, "c": rc.get_center(), "sow_d": sow, "n": pts.size()})
		counts[crop] = int(counts.get(crop, 0)) + pts.size()
	return {"plants": plants, "sections": sections, "counts": counts, "total": plants.size(), "tall": _tall(s, mix)}


static func _tall(s: Dictionary, mix: Array) -> Array:
	var tall: Array = []
	var clear := float((s["gantry"] as Dictionary)["clearance_m"])
	for e5 in mix:
		var cid := str((e5 as Dictionary)["crop"])
		if float(GardenCrops.info(cid)["height"]) > clear and not tall.has(cid):
			tall.append(cid)
	return tall


## The radial robot's keyhole bed: every ring bed cut into sectors about
## `section_m` of arc long at its middle, a crop to each sector by the layout:
##   rows (here: rings)  each crop the next share of the bed's AREA, ring by
##                       ring from the outside in (bands round the keyhole)
##   blocks (wedges)     each crop a wedge of every ring, its share of the angle
##   interleave          sectors dealt to the crops in turn (companion beds)
## Plants sit on arcs half a spacing in from each sector's edges: square =
## arcs one spacing apart with plants a spacing apart along them; hex = arcs
## 0.866 of a spacing apart, every other arc shifted half a spacing (kept
## only where it fits more, as in the straight bed).
static func _solve_radial(s: Dictionary, mix: Array, tot: float) -> Dictionary:
	var c: Dictionary = s["crops"]
	var sec_m := float(c["section_m"])
	var secs: Array = []
	var area := 0.0
	for r in FarmBotGeom.rings(s):
		var rr: Dictionary = r
		var r0 := float(rr["r0"])
		var r1 := float(rr["r1"])
		var a0 := float(rr["a0"])
		var a1 := float(rr["a1"])
		var n := maxi(int(roundf((a1 - a0) * 0.5 * (r0 + r1) / sec_m)), 1)
		for k in n:
			var sa0 := lerpf(a0, a1, float(k) / float(n))
			var sa1 := lerpf(a0, a1, float(k + 1) / float(n))
			var ar := 0.5 * (sa1 - sa0) * (r1 * r1 - r0 * r0)
			secs.append({"r0": r0, "r1": r1, "a0": sa0, "a1": sa1, "ring": int(rr["ring"]),
				"f": (float(k) + 0.5) / float(n), "area": ar})
			area += ar
	# Which crop each sector grows.
	var cum: Array = []
	var acc := 0.0
	for e in mix:
		acc += float((e as Dictionary)["share"]) / tot
		cum.append(acc)
	var pick := func(f: float) -> String:
		for i in cum.size():
			if f <= float(cum[i]) + 1e-9:
				return str((mix[i] as Dictionary)["crop"])
		return str((mix[mix.size() - 1] as Dictionary)["crop"])
	var owed: Array = []
	for e2 in mix:
		owed.append(0.0)
	var run := 0.0
	for sv in secs:
		var sc: Dictionary = sv
		match str(c["layout"]):
			"blocks":
				sc["crop"] = pick.call(float(sc["f"]))
			"interleave":
				for i2 in mix.size():
					owed[i2] = float(owed[i2]) + float((mix[i2] as Dictionary)["share"]) / tot
				var best := 0
				for i3 in mix.size():
					if float(owed[i3]) > float(owed[best]):
						best = i3
				owed[best] = float(owed[best]) - 1.0
				sc["crop"] = str((mix[best] as Dictionary)["crop"])
			_:
				var mid := (run + 0.5 * float(sc["area"])) / maxf(area, 1e-6)
				sc["crop"] = pick.call(mid)
				run += float(sc["area"])
	var plants: Array = []
	var sections: Array = []
	var counts := {}
	var per_crop_k := {}
	var hex := str(c["packing"]) == "hex"
	var scale := float(c["spacing_scale"])
	for si in secs.size():
		var sc2: Dictionary = secs[si]
		var crop := str(sc2["crop"])
		var sp := GardenCrops.spacing(crop) * scale
		var k4 := int(per_crop_k.get(crop, 0))
		per_crop_k[crop] = k4 + 1
		var sow := first_sow(crop, k4)
		var pts := pack_sector(float(sc2["r0"]), float(sc2["r1"]), float(sc2["a0"]), float(sc2["a1"]), sp, hex)
		for p in pts:
			var q: Vector2 = p
			plants.append({"crop": crop, "x": q.x, "z": q.y, "sow_d": sow, "section": si})
		var am := 0.5 * (float(sc2["a0"]) + float(sc2["a1"]))
		var rm := 0.5 * (float(sc2["r0"]) + float(sc2["r1"]))
		sections.append({"crop": crop, "shape": "sector", "r0": sc2["r0"], "r1": sc2["r1"], "a0": sc2["a0"],
			"a1": sc2["a1"], "c": Vector2(sin(am) * rm, cos(am) * rm), "sow_d": sow, "n": pts.size()})
		counts[crop] = int(counts.get(crop, 0)) + pts.size()
	return {"plants": plants, "sections": sections, "counts": counts, "total": plants.size(), "tall": _tall(s, mix)}


## Points in a ring sector (angles from +Z, GrowBed's convention), half a
## spacing in from its edges, on arcs.
static func pack_sector(r0: float, r1: float, a0: float, a1: float, sp: float, hex: bool) -> Array:
	sp = maxf(sp, 0.05)
	var out := _arcs(r0, r1, a0, a1, sp, sp, -1)
	if hex:
		for phase in [1, 0]:
			var pts := _arcs(r0, r1, a0, a1, sp, sp * 0.8660254, phase)
			if pts.size() > out.size():
				out = pts
	if out.is_empty() and r1 - r0 >= sp * 0.6 and (a1 - a0) * 0.5 * (r0 + r1) >= sp * 0.6:
		var am := 0.5 * (a0 + a1)
		var rm := 0.5 * (r0 + r1)
		out.append(Vector2(sin(am) * rm, cos(am) * rm))
	return out


static func _arcs(r0: float, r1: float, a0: float, a1: float, sp: float, dr: float, phase: int) -> Array:
	# Along an arc, neighbours are a CHORD apart (shorter than the arc), so the
	# step is the angle whose chord is a spacing. Offset rows on circles of
	# different radius do not stay in step the way straight rows do, so each
	# plant on an offset row is placed at the first angle clear of the row
	# before it (that is what makes the rows interlock).
	var out: Array = []
	var m := sp * 0.5
	var prev: Array = []
	var row := 0
	var r := r0 + m
	var need := sp * 0.9999
	while r <= r1 - m + 0.0001:
		var da := 2.0 * asin(clampf(sp / (2.0 * r), 0.0, 1.0))
		var lo := a0 + 2.0 * asin(clampf(m / (2.0 * r), 0.0, 1.0))
		var hi := a1 - 2.0 * asin(clampf(m / (2.0 * r), 0.0, 1.0))
		var a := lo
		if phase >= 0 and row % 2 == phase:
			a += da * 0.5
		var cur: Array = []
		var k := 0
		var nudge := da * 0.04
		while a <= hi + 0.00001:
			var p := Vector2(sin(a) * r, cos(a) * r)
			var clear := true
			if phase >= 0:
				while k < prev.size() and (prev[k] as Vector2).distance_to(p) >= need and \
						fposmod(atan2((prev[k] as Vector2).x, (prev[k] as Vector2).y) - a + PI, TAU) - PI < -da:
					k += 1
				for q in range(k, mini(k + 4, prev.size())):
					if (prev[q] as Vector2).distance_to(p) < need:
						clear = false
						break
			if clear:
				cur.append(p)
				a += da
			else:
				a += nudge
		out.append_array(cur)
		prev = cur
		r += dr
		row += 1
	return out


## The strip the tool bay takes (bed metres, Rect2 x, z, length, width): along
## the -Z wall from the -X end, as far as the last slot.
static func toolbay_rect(s: Dictionary) -> Rect2:
	if FarmBotGeom.is_radial(s):
		# The radial robot's tools hang round its post, inside every bed.
		return Rect2(0.0, 0.0, 0.0, 0.0)
	var b: Dictionary = s["bed"]
	var L := float(b["length_m"])
	var W := float(b["width_m"])
	var n := 0
	for t in FarmBotJobs.TOOL_ORDER:
		if bool((s["tools"] as Dictionary).get(t, false)):
			n = FarmBotJobs.TOOL_ORDER.find(t) + 1
	var x1 := (FarmBotJobs.SLOT_X0_MM + FarmBotJobs.SLOT_PITCH_MM * float(maxi(n - 1, 0)) + 100.0) / 1000.0
	return Rect2(-L * 0.5, -W * 0.5, x1, (FarmBotJobs.SLOT_Y_MM + 60.0) / 1000.0)


## Points at spacing `sp` in a rectangle (Rect2 x, z, length, width), half a
## spacing in from its edges: a square grid, or hexagonal (rows 0.866 sp
## apart, every other row shifted half a spacing; 15 % more plants a m²).
static func pack(rc: Rect2, sp: float, hex: bool) -> Array:
	sp = maxf(sp, 0.05)
	var out: Array = []
	out = _rows(rc, sp, sp, false, 0)
	if hex:
		# Offset rows sit 0.866 of a spacing apart, so a strip wide enough
		# takes an extra row; one too narrow for that only loses the plant
		# the offset pushes off each odd row, and a grower keeps it square.
		# Rows along the strip or across it, the offset on odd or even rows:
		# the arrangement with the most plants (never fewer than square).
		for along_x in [true, false]:
			for phase in [1, 0]:
				var pts := _rows(rc, sp, sp * 0.8660254, not along_x, phase)
				if pts.size() > out.size():
					out = pts
	if out.is_empty() and rc.size.x >= sp * 0.6 and rc.size.y >= sp * 0.6:
		out.append(rc.get_center())
	return out


## Rows `dz` apart, plants `sp` apart in a row; `hex` offsets every other row
## (row % 2 == phase) by half a spacing. `swap` lays the rows along Z.
static func _rows(rc: Rect2, sp: float, dz: float, swap: bool, phase: int) -> Array:
	var out: Array = []
	var m := sp * 0.5
	var r := Rect2(rc.position.y, rc.position.x, rc.size.y, rc.size.x) if swap else rc
	var hex := dz < sp - 1e-6
	var row := 0
	var z := r.position.y + m
	while z <= r.end.y - m + 0.0001:
		var shift := sp * 0.5 if hex and row % 2 == phase else 0.0
		var x := r.position.x + m + shift
		while x <= r.end.x - m + 0.0001:
			out.append(Vector2(z, x) if swap else Vector2(x, z))
			x += sp
		z += dz
		row += 1
	return out


## The day a crop's k-th section is first sown (days after the bed was
## planted): spread over its cycle, as GrowBed does.
static func first_sow(crop: String, k: int) -> float:
	var cyc := float(GardenCrops.info(crop)["cycle"])
	var share := fposmod(float(k) * 0.618034, 1.0)
	return 2.0 + share * minf(cyc, 120.0) * 0.9


## Sections whose sowing falls on day `day` (days since planting, whole
## days): the first sowing, then every cycle after it (the bed is cleared
## and resown).
static func sections_sown_on(lay: Dictionary, day: int) -> Array:
	var out: Array = []
	for i in (lay["sections"] as Array).size():
		var sec: Dictionary = lay["sections"][i]
		var sow := float(sec["sow_d"])
		var cyc := float(GardenCrops.info(str(sec["crop"]))["cycle"])
		if float(day) + 1.0 <= sow:
			continue
		var since := float(day) - floorf(sow)
		if int(roundf(since)) % maxi(int(roundf(cyc)), 1) == 0 and float(day) >= floorf(sow):
			out.append(i)
	return out


## A bed point (metres, local) to machine mm.
static func to_machine(spec: Dictionary, x: float, z: float) -> Vector2:
	return FarmBotGeom.to_machine(spec, x, z)

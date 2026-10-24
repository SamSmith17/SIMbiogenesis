class_name FlatpackDesign
extends RefCounted

## One flat-pack design, solved: spec → template → joints → finished outlines
## → sheets, cut list and bill of materials. Pure and cached by the spec, so
## the modal, the 3D builder, the packing spec and the CNC writers all read
## the same numbers.
##
## The solved design is a Dictionary:
##   spec, type, name
##   parts:    [{id, name, group, role, frame, thickness, grain, ring,
##               hole_rings, notches, holes, bbox (Rect2 of the ring), area,
##               perimeter, sheet, placement, label}]
##   poses:    [{id, label, frames, hidden, ...}] (empty = one assembly)
##   pose:     the pose drawn by default
##   seats:    [{pose, kind (sit | lie), pos (inches), face, length?}]
##   nest:     FlatpackNesting.nest(...) result
##   cut_list: [{name, qty, w, h, notches, holes, sheets, ids}]
##   bom:      {sheets, sheet_w, sheet_h, area_ft2, utilization, cut_ft,
##              passes, cut_min, mass_kg, parts}
##   warnings: [String]
##   size:     Vector3 assembled size in inches (default pose)

static var _cache := {}
const CACHE_MAX := 24


static func solve(spec: Dictionary) -> Dictionary:
	var s := FlatpackSpec.resolve(spec)
	var key := str(hash(var_to_str(s)))
	if _cache.has(key):
		return _cache[key]
	var d := _solve(s)
	if _cache.size() >= CACHE_MAX:
		_cache.clear()
	_cache[key] = d
	return d


static func clear_cache() -> void:
	_cache.clear()


static func _solve(s: Dictionary) -> Dictionary:
	var gen := FlatpackTemplates.generate(s)
	var warnings: Array = (gen.get("warnings", []) as Array).duplicate()
	var parts: Array = gen["parts"]
	var joints: Array = gen["joints"]
	var poses: Array = gen.get("poses", [])
	var t := float(s["material"]["thickness"])
	var mc: Dictionary = s["machine"]
	# The player's per-joint choices.
	var ov: Dictionary = s["joinery"]["overrides"]
	for j in joints:
		var o: Dictionary = ov.get(str(j["id"]), {})
		for k in o:
			j[k] = o[k]
	var res := FlatpackJoints.resolve(parts, joints, poses,
		{"thickness": t, "clearance": float(mc["clearance"])})
	warnings.append_array(res["warnings"])
	parts = res["parts"]
	var relief := {"relief": str(mc["relief"]), "bit_r": float(mc["bit_d"]) * 0.5 + 0.005}
	if float(mc["bit_d"]) <= 0.0:
		relief["relief"] = "none"
	var pov: Dictionary = s["part_overrides"]
	for p in parts:
		var o: Dictionary = pov.get(str(p["id"]), {})
		if o.has("name") and not str(o["name"]).is_empty():
			p["name"] = str(o["name"])
		if o.has("grain"):
			p["grain"] = str(o["grain"])
		p["hidden"] = bool(o.get("hidden", false))
		if p.has("circle"):
			var c: Dictionary = p["circle"]
			p["ring"] = FlatpackProfile.circle_ring(c["c"], float(c["r"]))
		else:
			var r := FlatpackProfile.ring_from_base(p["base"], p["corner_r"], p["notches"], relief)
			p["ring"] = r["ring"]
			for w in r["warnings"]:
				warnings.append("%s: %s" % [str(p["name"]), w])
		var hr: Array = []
		for h in p["holes"]:
			hr.append(FlatpackProfile.hole_ring(h["c"], h["axis"], float(h["length"]),
				float(h["width"]), relief))
		p["hole_rings"] = hr
		var tess := FlatpackProfile.tessellate(p["ring"])
		p["bbox"] = FlatpackProfile.bbox(tess)
		var area := absf(FlatpackProfile.signed_area(tess))
		var perim := FlatpackProfile.perimeter(p["ring"])
		for h in hr:
			area -= absf(FlatpackProfile.signed_area(FlatpackProfile.tessellate(h)))
			perim += FlatpackProfile.perimeter(h)
		p["area"] = area
		p["perimeter"] = perim
		if not FlatpackProfile.is_simple(tess):
			warnings.append("%s: its outline crosses itself" % str(p["name"]))
	# Number the parts by cut-list group: A1, A2, B1 …
	var cut := _cut_list(parts)
	var letters := "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	for gi in cut.size():
		var ids: Array = cut[gi]["ids"]
		var letter := letters[gi % letters.length()]
		cut[gi]["label"] = letter
		for k in ids.size():
			for p in parts:
				if str(p["id"]) == str(ids[k]):
					p["label"] = "%s%d" % [letter, k + 1] if ids.size() > 1 else letter
	# Nest.
	var m: Dictionary = s["material"]
	var items: Array = []
	for p in parts:
		var bb: Rect2 = p["bbox"]
		var g := str(p["grain"])
		var lock := bool(m["grain_lock"]) and g != "any"
		items.append({"id": str(p["id"]), "w": bb.size.x, "h": bb.size.y, "rot_ok": not lock,
			"grain": g})
	var nest := FlatpackNesting.nest(items, float(m["sheet_w"]), float(m["sheet_h"]),
		float(mc["spacing"]), float(mc["margin"]))
	for un in nest["unplaced"]:
		for p in parts:
			if str(p["id"]) == str(un):
				warnings.append("%s (%s) does not fit on a %s sheet" % [str(p["name"]),
					FlatpackSpec.fmt_size((p["bbox"] as Rect2).size.x, (p["bbox"] as Rect2).size.y),
					FlatpackSpec.fmt_size(float(m["sheet_w"]), float(m["sheet_h"]))])
	for sh in nest["sheets"]:
		for pl in sh["placements"]:
			for p in parts:
				if str(p["id"]) == str(pl["id"]):
					p["sheet"] = int(sh["index"])
					p["placement"] = pl
	for row in cut:
		var sheets: Array = []
		for id in row["ids"]:
			for p in parts:
				if str(p["id"]) == str(id) and p.has("sheet") and not sheets.has(int(p["sheet"]) + 1):
					sheets.append(int(p["sheet"]) + 1)
		sheets.sort()
		row["sheets"] = sheets
	var bom := _bom(parts, nest, s)
	var d := {"spec": s, "type": str(s["type"]), "name": str(s["name"]), "parts": parts,
		"joints": joints, "poses": poses, "pose": _default_pose(s, poses),
		"seats": gen.get("seats", []), "nest": nest, "cut_list": cut, "bom": bom,
		"warnings": _unique(warnings)}
	d["size"] = assembled_size(d, str(d["pose"]))
	return d


static func _default_pose(s: Dictionary, poses: Array) -> String:
	var want := str(s.get("pose", ""))
	for p in poses:
		if str(p["id"]) == want:
			return want
	return str(poses[0]["id"]) if not poses.is_empty() else ""


static func _unique(a: Array) -> Array:
	var out: Array = []
	for x in a:
		if not out.has(x):
			out.append(x)
	return out


## Parts that are cut the same: one cut-list row with a quantity.
static func _cut_list(parts: Array) -> Array:
	var rows: Array = []
	for p in parts:
		var bb: Rect2 = p["bbox"]
		var sig := "%s|%.2f|%.2f|%d|%d|%.1f" % [str(p["group"]), bb.size.x, bb.size.y,
			(p["notches"] as Array).size(), (p["holes"] as Array).size(), float(p["area"])]
		var found := false
		for r in rows:
			if str(r["sig"]) == sig:
				r["qty"] = int(r["qty"]) + 1
				(r["ids"] as Array).append(str(p["id"]))
				found = true
				break
		if not found:
			rows.append({"sig": sig, "name": str(p["name"]), "group": str(p["group"]), "qty": 1,
				"w": bb.size.x, "h": bb.size.y, "notches": (p["notches"] as Array).size(),
				"holes": (p["holes"] as Array).size(), "ids": [str(p["id"])],
				"area": float(p["area"])})
	return rows


static func _bom(parts: Array, nest: Dictionary, s: Dictionary) -> Dictionary:
	var m: Dictionary = s["material"]
	var mc: Dictionary = s["machine"]
	var t := float(m["thickness"])
	var area := 0.0
	var cut := 0.0
	var outlines := 0
	for p in parts:
		area += float(p["area"])
		cut += float(p["perimeter"])
		outlines += 1 + (p["hole_rings"] as Array).size()
	var n_sheets := (nest["sheets"] as Array).size()
	var sheet_area := float(m["sheet_w"]) * float(m["sheet_h"])
	var passes := int(ceil(t / float(mc["pass_depth"]) - 1e-6))
	# Router time: every outline cut in `passes` passes at the feed rate, plus
	# a plunge-and-retract per outline per pass (~3 s each).
	var minutes := cut * passes / float(mc["feed_ipm"]) + outlines * passes * 0.05
	var area_ft2 := area / 144.0
	var nominal := t
	var nom := str(m["nominal"])
	if FlatpackSpec.THICKNESS.has(nom) and nom.contains("/"):
		var bits := nom.split("/")
		nominal = float(bits[0]) / float(bits[1])
	var mass := area_ft2 * nominal * FlatpackSpec.LB_PER_FT2_PER_IN * FlatpackSpec.LB_TO_KG
	return {"sheets": n_sheets, "sheet_w": float(m["sheet_w"]), "sheet_h": float(m["sheet_h"]),
		"area_ft2": area_ft2, "utilization": area / maxf(n_sheets * sheet_area, 1.0),
		"cut_ft": cut / 12.0, "passes": passes, "cut_min": minutes, "mass_kg": mass,
		"parts": parts.size(), "thickness": t}


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

static func part(design: Dictionary, id: String) -> Dictionary:
	for p in design.get("parts", []):
		if str(p["id"]) == id:
			return p
	return {}


static func pose_of(design: Dictionary, pose_id: String) -> Dictionary:
	for p in design.get("poses", []):
		if str(p["id"]) == pose_id:
			return p
	return {"id": pose_id}


## The parts drawn in a pose, each with its frame in that pose.
static func parts_in_pose(design: Dictionary, pose_id: String) -> Array:
	var pose := pose_of(design, pose_id)
	var out: Array = []
	for p in design.get("parts", []):
		if not FlatpackJoints.visible_in_pose(p, pose):
			continue
		out.append({"part": p, "frame": FlatpackJoints.frame_in_pose(p, pose)})
	return out


## Bounding box (inches) of the assembled piece in a pose.
static func assembled_aabb(design: Dictionary, pose_id: String) -> AABB:
	var box := AABB()
	var first := true
	for e in parts_in_pose(design, pose_id):
		var p: Dictionary = e["part"]
		var fr: Transform3D = e["frame"]
		var tt := float(p.get("thickness", 0.5))
		for q in FlatpackProfile.tessellate(p["ring"], 2.0):
			for zz in [-tt * 0.5, tt * 0.5]:
				var w := fr * Vector3(q.x, q.y, zz)
				if first:
					box = AABB(w, Vector3.ZERO)
					first = false
				else:
					box = box.expand(w)
	return box


static func assembled_size(design: Dictionary, pose_id: String) -> Vector3:
	return assembled_aabb(design, pose_id).size


static func seats_in_pose(design: Dictionary, pose_id: String) -> Array:
	var out: Array = []
	for st in design.get("seats", []):
		var sp := str(st.get("pose", ""))
		if sp.is_empty() or sp == pose_id:
			out.append(st)
	return out


## The flat stack the parts pack into: the largest part's bounding box, one
## sheet thickness per part, plus the mass. Metres + kg (PackedSpec units).
static func packed_spec(design: Dictionary) -> Dictionary:
	var big := Vector2.ZERO
	var n := 0
	for p in design.get("parts", []):
		var bb: Rect2 = p["bbox"]
		var a := Vector2(maxf(bb.size.x, bb.size.y), minf(bb.size.x, bb.size.y))
		big = Vector2(maxf(big.x, a.x), maxf(big.y, a.y))
		n += 1
	var t := float((design.get("bom", {}) as Dictionary).get("thickness", 0.5))
	var IN := 0.0254
	return {"w_m": big.x * IN, "d_m": big.y * IN, "h_m": maxf(n * t, t) * IN,
		"mass_kg": float((design.get("bom", {}) as Dictionary).get("mass_kg", 0.0)),
		"form": "panel_stack", "source": "computed", "count": 1}

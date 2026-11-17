class_name MimicTcSource
extends RefCounted
## A tri-clamp design's process as a 2D picture (plans/SCADA_PROCESS_PLAN.md,
## Phase 2): the P&ID view of the Process Lab.
##
## `build(d, net)` (d = TcDesign.solve, net = TcProcNet.build) → the DOC:
##   {pipes:    [{id, cv, role, pts (picture mm), w (mm), depth, shell (cv of
##                its cooling water, -1), label}],
##    elements: [{id, kind, pos, size, depth, cv, link, bnd, part, label,
##                ...kind's own keys}],
##    bounds, proj}
##
## Element kinds: vessel, holder, dryer, engine, flare (equipment, drawn at
## the part's own projected size); valve, check, relief (on a link); heater,
## probe_t, probe_p, probe_well (on a volume); end (an open end: feed,
## product, drain, coolant in / out, outlet, atmosphere, plug).
##
## `state(sim, doc)` → what the picture shows now, by the same ids:
##   {cv: {cv index: {t_c, wall_c, p_kpa, level (0..1), liquid_l, flow,
##                    t_cool_c}},
##    link: {link index: {open, flow}}, end: {bnd index: {open, flow}},
##    heater: {part: {on, w, t_c, fused}}, unit: {cv: {fill | kw, on}},
##    bed: {…} | {}}
##
## Positions come from the real assembly through MimicLayout.Proj, so
## the picture is the reactor seen from the side: what is higher is higher.
## Pure (no nodes); the selftest builds it under --script.

## Outer diameter drawn per inner diameter (wall + a little, so thin lines
## still read as pipe).
const PIPE_WALL := 1.16
const MIN_PIPE_W_MM := 14.0
const VALVE_SIZE := 1.7        # × the pipe width
const PROBE_SIZE_MM := 46.0
const END_SIZE_MM := 40.0
const EQUIPMENT := ["vessel", "holder", "dryer", "engine", "flare"]
## Roles drawn as a line along their centre line.
const LINE_ROLES := ["pipe", "junction", "condenser", "column", "plate", "sight", "filter"]


static func build(d: Dictionary, net: Dictionary) -> Dictionary:
	var cvs: Array = net.get("cvs", [])
	var parts: Dictionary = (d.get("res", {}) as Dictionary).get("parts", {})
	var cloud := PackedVector3Array()
	for cv in cvs:
		cloud.append(cv["centroid_mm"])
		for pl in cv["path"]:
			for v in pl:
				cloud.append(v)
	for b in net.get("boundaries", []):
		cloud.append(b["pos_mm"])
	var proj := MimicLayout.projection_for(cloud)
	# Which coolant volume wraps which condenser; which jacket which vessel.
	var shell_of := {}
	var jacket_of := {}
	for th in net.get("thermal", []):
		if str(th["kind"]) == "condenser":
			shell_of[int(th["a"])] = int(th["b"])
			shell_of[int(th["b"])] = int(th["a"])
		else:
			jacket_of[int(th["a"])] = int(th["b"])
			jacket_of[int(th["b"])] = int(th["a"])
	var pipes: Array = []
	var elements: Array = []
	for i in cvs.size():
		var cv: Dictionary = cvs[i]
		var role := str(cv["role"])
		if role == "coolant" or role == "jacket":
			continue   # drawn as its partner's shell
		var kind := role
		if role == "holder" or role == "dryer" or role == "engine" or role == "flare" or role == "vessel":
			var pid := str(cv.get("vessel_part", "")) if role == "vessel" else str((cv.get("unit", {}) as Dictionary).get("part", ""))
			if pid.is_empty() and not (cv["parts"] as Array).is_empty():
				pid = str(cv["parts"][0])
			var rect := _part_rect(parts.get(pid, {}), proj)
			var e := {"id": "cv%d" % i, "kind": kind, "cv": i, "link": -1, "bnd": -1, "part": pid,
				"pos": rect.get_center(), "size": rect.size, "depth": proj.depth_of(cv["centroid_mm"]),
				"label": str(cv["label"])}
			if role == "vessel":
				e["jacket_cv"] = int(jacket_of.get(i, -1))
				e["shell_h"] = float(cv.get("height_m", 0.0)) * 1000.0
				e["shell_w"] = float(cv.get("r_in_m", 0.0)) * 2000.0
				e["has_lid"] = bool(cv.get("has_lid", false))
				# The shell stands on the vessel's own origin (its bottom seam).
				var pd: Dictionary = parts.get(pid, {})
				if pd.has("xf"):
					e["base"] = proj.to_2d((pd["xf"] as Transform3D).origin)
			elif cv.has("unit"):
				e["unit"] = (cv["unit"] as Dictionary).duplicate(true)
			elements.append(e)
			continue
		var w := maxf(float(cv["r_in_m"]) * 2000.0 * PIPE_WALL, MIN_PIPE_W_MM)
		var n := 0
		for pl in cv["path"]:
			if (pl as PackedVector3Array).size() < 2:
				continue
			var pts := PackedVector2Array()
			var dsum := 0.0
			for v in pl:
				pts.append(proj.to_2d(v))
				dsum += proj.depth_of(v)
			# `corners`: the same run as straight legs and corners, which is what
			# the picture re-routes (with right-angle jogs) when the thing at an
			# end is dragged.
			pipes.append({"id": "cv%d_%d" % [i, n], "cv": i, "role": role, "pts": MimicLayout.densify(pts, 40.0),
				"corners": MimicLayout.simplify_corners(pts, maxf(w * 0.3, 6.0)), "corner_r": w * 0.9,
				"stub": maxf(w * 1.6, 40.0),
				"w": w * (1.5 if role == "column" or role == "filter" else 1.0),
				"depth": dsum / float(pts.size()), "shell": int(shell_of.get(i, -1)), "label": str(cv["label"])})
			n += 1
		# What is screwed into this volume.
		for h in cv["heaters"]:
			elements.append(_attach_el("heater", i, h, proj, float(h.get("reach_mm", 300.0)), cv["centroid_mm"]))
		for p in cv["probes"]:
			elements.append(_attach_el(str(p["role"]), i, p, proj, 0.0, cv["centroid_mm"]))
	# A vessel's own heaters and probes.
	for i in cvs.size():
		var cv2: Dictionary = cvs[i]
		if str(cv2["role"]) != "vessel":
			continue
		var mid: Vector3 = cv2["centroid_mm"]
		var vpd: Dictionary = parts.get(str(cv2.get("vessel_part", "")), {})
		if vpd.has("xf"):
			# The middle of the shell (a vessel's centre line paths are its nozzles').
			mid = (vpd["xf"] as Transform3D) * Vector3(0, float(cv2.get("height_m", 0.0)) * 500.0, 0)
		for h in cv2["heaters"]:
			elements.append(_attach_el("heater", i, h, proj, float(h.get("reach_mm", 300.0)), mid))
		for p in cv2["probes"]:
			elements.append(_attach_el(str(p["role"]), i, p, proj, 0.0, mid))
	var links: Array = net.get("links", [])
	for li in links.size():
		var l: Dictionary = links[li]
		var lk := str(l["kind"])
		if lk == "joint" or str(l["part"]).is_empty():
			continue
		var s := maxf(float(l["r_in_m"]) * 2000.0 * PIPE_WALL, MIN_PIPE_W_MM) * VALVE_SIZE
		var ve := {"id": "l%d" % li, "kind": lk, "cv": int(l["a"]), "link": li, "bnd": int(l.get("boundary", -1)),
			"part": str(l["part"]), "pos": proj.to_2d(l["at_mm"]), "size": Vector2(s, s),
			"depth": proj.depth_of(l["at_mm"]), "label": "" if lk == "pump" else _part_label(parts, str(l["part"]))}
		# A valve lies along its own bore (the part's z axis).
		var lpd: Dictionary = parts.get(str(l["part"]), {})
		if lpd.has("xf"):
			var z3: Vector3 = (lpd["xf"] as Transform3D).basis.z
			var a2 := proj.to_2d(l["at_mm"])
			var b2d := proj.to_2d((l["at_mm"] as Vector3) + z3 * 100.0)
			if a2.distance_to(b2d) > 5.0:
				ve["dir"] = (b2d - a2).normalized()
		elements.append(ve)
	var bnds: Array = net.get("boundaries", [])
	for bi in bnds.size():
		var b: Dictionary = bnds[bi]
		var dir3: Vector3 = b["dir"]
		var p0 := proj.to_2d(b["pos_mm"])
		var p1 := proj.to_2d((b["pos_mm"] as Vector3) + dir3 * 100.0)
		var dir2 := (p1 - p0).normalized() if p1.distance_to(p0) > 1.0 else Vector2.UP
		elements.append({"id": "b%d" % bi, "kind": "end", "cv": int(b["cv"]), "link": int(b.get("link", -1)), "bnd": bi,
			"part": str(b["ref"]).get_slice(":", 0), "pos": p0 + dir2 * END_SIZE_MM * 0.6,
			"size": Vector2(END_SIZE_MM, END_SIZE_MM), "depth": proj.depth_of(b["pos_mm"]),
			"label": str(b["text"]), "role": str(b["role"]), "carries": str(b["kind"]), "dir": dir2, "ref": str(b["ref"])})
	# Far things first.
	pipes.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool: return float(a["depth"]) > float(b2["depth"]))
	elements.sort_custom(func(a: Dictionary, b2: Dictionary) -> bool: return float(a["depth"]) > float(b2["depth"]))
	var doc := {"pipes": pipes, "elements": elements, "proj": proj}
	doc["bounds"] = MimicLayout.bounds_of(doc)
	return doc


static func _attach_el(kind: String, cv: int, info: Dictionary, proj: MimicLayout.Proj, reach_mm: float, toward: Vector3) -> Dictionary:
	var at: Vector3 = info["at_mm"]
	var dir3: Vector3 = info.get("dir", Vector3.UP)
	# "Into the volume" is whichever way along its axis gets nearer the
	# volume's middle (a port's axis sign differs by part).
	if (at + dir3 * 50.0).distance_to(toward) > (at - dir3 * 50.0).distance_to(toward):
		dir3 = -dir3
	var p0 := proj.to_2d(at)
	var p1 := proj.to_2d(at + dir3 * maxf(reach_mm, 60.0))
	var e := {"id": "a_%s" % str(info["part"]), "kind": kind, "cv": cv, "link": -1, "bnd": -1,
		"part": str(info["part"]), "pos": p0, "size": Vector2(PROBE_SIZE_MM, PROBE_SIZE_MM),
		"depth": proj.depth_of(at) - 1.0, "label": "", "into": p1 - p0}
	if kind == "heater":
		e["size"] = Vector2(maxf(absf(p1.x - p0.x), 30.0), maxf(absf(p1.y - p0.y), 30.0))
		e["pos"] = (p0 + p1) * 0.5
		e["from"] = p0
		e["to"] = p1
	return e


static func _part_label(parts: Dictionary, pid: String) -> String:
	var pd: Dictionary = parts.get(pid, {})
	return str((pd.get("built", {}) as Dictionary).get("label", pid))


## A part's bounding box as seen in the picture.
static func _part_rect(pd: Dictionary, proj: MimicLayout.Proj) -> Rect2:
	if pd.is_empty() or not (pd.get("built", {}) as Dictionary).has("bounds"):
		return Rect2(-50, -50, 100, 100)
	var bb: AABB = pd["built"]["bounds"]
	var xf: Transform3D = pd["xf"]
	# Front face only (the middle of the depth), or the oblique depth would
	# fatten every box: corners at the box's mid-depth plane.
	var have := false
	var r := Rect2()
	var mid_d := proj.depth_of(xf * bb.get_center())
	for k in 8:
		var c := xf * bb.get_endpoint(k)
		var flat := c - proj.depth * (proj.depth_of(c) - mid_d)
		var p := proj.to_2d(flat)
		if not have:
			r = Rect2(p, Vector2.ZERO)
			have = true
		else:
			r = r.expand(p)
	return r


# ── live state ──────────────────────────────────────────────────────────────

static func state(sim: TcProcSim, doc: Dictionary) -> Dictionary:
	var out := {"cv": {}, "link": {}, "end": {}, "heater": {}, "bed": {}, "el": {}}
	if sim == null:
		return out
	var net: Dictionary = sim.net
	var cvs: Array = net["cvs"]
	for i in sim.n_cv:
		var st := sim.cv_state(i)
		var vol_l := float(cvs[i]["volume_m3"]) * 1000.0
		out["cv"][i] = {"t_c": float(st["t_gas_c"]), "wall_c": float(st["t_wall_c"]), "p_kpa": float(st["p_kpa_g"]),
			"liquid_l": float(st["liquid_l"]), "level": clampf(float(st["liquid_l"]) / maxf(vol_l, 1e-6), 0.0, 1.0),
			"flow": float(st["flow_mol_s"]), "t_cool_c": float(st["t_cool_c"])}
	var links: Array = net["links"]
	for li in links.size():
		var f := float(sim.flow_link[li]) if li < sim.flow_link.size() else 0.0
		out["link"][li] = {"open": bool(sim.link_open[li]) if li < sim.link_open.size() else true, "flow": f,
			"frac": float(sim.link_frac[li]) if li < sim.link_frac.size() else 1.0}
		if str(links[li]["kind"]) == "pump":
			var pp := str(links[li]["part"])
			var lpm := float(sim.pump_lpm.get(pp, 0.0))
			var pon := bool(sim.pump_on.get(pp, false))
			out["el"]["l%d" % li] = {"running": lpm > 0.01, "open": pon, "warn": pon and lpm <= 0.01,
				"value": ("%.1f L/min" % lpm) if pon else "off"}
	# A line that is moving liquid runs full.
	for ln in sim.lines:
		if absf(float(ln["lpm"])) > 0.01:
			for c in ln["cvs"]:
				if out["cv"].has(int(c)):
					out["cv"][int(c)]["level"] = 1.0
	for bi in (net["boundaries"] as Array).size():
		var b: Dictionary = net["boundaries"][bi]
		var li2 := int(b.get("link", -1))
		var open := true
		if sim.drain_open.has(bi):
			open = bool(sim.drain_open[bi])
		elif str(b["role"]) == "plug" or str(b["role"]) == "feed":
			open = false
		out["end"][bi] = {"open": open, "flow": float(sim.flow_link[li2]) if li2 >= 0 and li2 < sim.flow_link.size() else 0.0,
			"drain": sim.drain_open.has(bi)}
	for k in sim.heater_parts.size():
		var pid := str(sim.heater_parts[k])
		var on := bool(sim.heater_on.get(pid, true)) and float(sim.heater_w.get(pid, 0.0)) > 0.0
		out["heater"][pid] = {"on": on, "w": float(sim.heater_w.get(pid, 0.0)),
			"t_c": float(sim.element_t[k]) - 273.15 if k < sim.element_t.size() else NAN,
			"fused": bool(sim.heater_fused.get(pid, false))}
	out["unit"] = {}
	for u in sim.units:
		var ucv := int(u["cv"])
		match str(u["kind"]):
			"holder":
				out["unit"][ucv] = {"fill": clampf(sim.holder_fill(u), 0.0, 1.0)}
			"engine":
				out["unit"][ucv] = {"kw": float(sim.engine_kw.get(str(u["part"]), 0.0)),
					"on": bool(sim.engine_on.get(str(u["part"]), false))}
			"dryer":
				out["unit"][ucv] = {"fill": clampf(sim.ads_mol[ucv] / maxf(float(u.get("cap_mol", 1.0)), 1e-12), 0.0, 1.0)}
			"flare":
				out["unit"][ucv] = {"kw": float(sim.flare_kw)}
	if sim.bed != null and not sim.bed.is_empty():
		var bt := sim.bed.totals()
		var solid := float(bt["wood_kg"]) + float(bt["char_kg"]) + float(bt["plastic_kg"])
		out["bed"] = {"height_mm": sim.bed.height_m * 1000.0 * sim.bed.volume_frac(),
			"t_max_c": float(bt["t_max_k"]) - 273.15, "t_mean_c": float(bt["t_mean_k"]) - 273.15,
			"dry": float(bt["dry_frac"]), "char": float(bt["char_kg"]) / maxf(solid, 1e-6),
			"moisture_kg": float(bt["moisture_kg"]), "plastic": float(bt["plastic_kg"]) > float(bt["wood_kg"]) + float(bt["char_kg"])}
	return out


## Which way a pipe's line runs with the flow: +1 = first point to last,
## -1 = the other way, 0 = still. Read from the links at the volume's ends
## (a link whose flow comes INTO the volume marks where the flow starts).
static func flow_sign(sim: TcProcSim, doc: Dictionary, pipe: Dictionary) -> int:
	var cv := int(pipe["cv"])
	if cv < 0 or cv >= sim.n_cv or absf(float(sim.cv_flow[cv])) < 1e-7:
		return 0
	var proj: MimicLayout.Proj = doc["proj"]
	var pts: PackedVector2Array = pipe["pts"]
	var a := pts[0]
	var b := pts[pts.size() - 1]
	var best := 0.0
	var links: Array = sim.net["links"]
	for li in links.size():
		var l: Dictionary = links[li]
		var f := float(sim.flow_link[li])
		var into := 0.0
		if int(l["a"]) == cv:
			into = -f
		elif int(l["b"]) == cv:
			into = f
		else:
			continue
		if absf(into) < 1e-9:
			continue
		var p := proj.to_2d(l["at_mm"])
		# Inflow nearer the first point, or outflow nearer the last: forward.
		var toward_a := p.distance_to(a) < p.distance_to(b)
		best += absf(into) * (1.0 if (into > 0.0) == toward_a else -1.0)
	return 1 if best > 0.0 else (-1 if best < 0.0 else 0)

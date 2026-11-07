class_name TcProcNet
extends RefCounted

## The fluid network of a solved TC design (TC Process Lab, Phase 0).
##
## `build(d)` (d = TcDesign.solve output) → {
##   cvs:    [{id, role, parts, circuits, volume_m3, length_m, r_in_m,
##             wall_area_m2, wall_mass_kg, y_low_mm, y_high_mm, centroid_mm,
##             path (world polylines, mm), ports (refs), attach, heaters,
##             probes, internals, label}],
##   links:  [{id, a, b (cv index, −1 = a boundary), kind joint | valve |
##             check | relief, r_in_m, at_mm, part, open, boundary}],
##   thermal: [{a, b, kind}]  (condenser ↔ coolant, vessel ↔ jacket),
##   boundaries: [{id, ref, cv, link, pos_mm, dir, text, kind, role}],
##   refs: {"pid:port" → cv index}, key}
##
## Control volumes come from TcFlowPaths circuits; consecutive 2-port pipe
## parts merge into one CV so a run of spools and elbows is one volume, and
## valves / check / relief valves are LINKS between the CVs on their ends.
## Positions stay in the assembly's own mm frame (TcAssembly); physical
## quantities are SI with the unit in the key.
##
## Boundaries are open ports. Their role says what the sim does there:
## feed (solids in), product (gas out), drain (liquid out), coolant_in /
## coolant_out (a jacket's water circuit), outlet (labelled, no kind),
## plug (a spare threaded bung on a vessel: closed) and atmosphere (an
## unlabelled open clamp end: open to the air).

const CACHE_MAX := 12
const GAS_KINDS := ["woodgas", "syngas", "biogas", "steam", "propane"]
const LIQUID_KINDS := ["water", "hot_water", "wood_vinegar", "tar", "greywater"]

static var _cache: Dictionary = {}
static var _order: Array = []


static func build(d: Dictionary) -> Dictionary:
	var spec: Dictionary = d.get("spec", {})
	var key := TcSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	var net := build_transient(d)
	net["key"] = key
	_cache[key] = net
	_order.append(key)
	while _order.size() > CACHE_MAX:
		_cache.erase(_order.pop_front())
	return net


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()


# --- union-find ------------------------------------------------------------

static func _find(par: Dictionary, x: String) -> String:
	var r := x
	while str(par[r]) != r:
		r = str(par[r])
	var y := x
	while str(par[y]) != r:
		var nx := str(par[y])
		par[y] = r
		y = nx
	return r


static func _union(par: Dictionary, a: String, b: String) -> void:
	var ra := _find(par, a)
	var rb := _find(par, b)
	if ra != rb:
		if ra < rb:
			par[rb] = ra
		else:
			par[ra] = rb


static func build_transient(d: Dictionary) -> Dictionary:
	var res: Dictionary = d.get("res", {})
	var spec: Dictionary = d.get("spec", {})
	var labels: Dictionary = spec.get("labels", {})
	var parts: Dictionary = res.get("parts", {})
	# 1. Circuit instances, in world mm.
	var inst := {}          # "pid/cid" → circuit (with world data)
	var port_inst := {}     # "pid:port" → "pid/cid"
	var order: Array = []
	for pid in res.get("order", []):
		var pd: Dictionary = parts.get(pid, {})
		if pd.is_empty():
			continue
		var built: Dictionary = pd["built"]
		var xf: Transform3D = pd["xf"]
		var first_vol := true
		for c in TcFlowPaths.circuits(built):
			var iid := "%s/%s" % [pid, str(c["id"])]
			var w: Dictionary = c.duplicate()
			w["part"] = str(pid)
			w["type"] = str(built.get("type", ""))
			var wp: Array = []
			for pl in c["path"]:
				var o := PackedVector3Array()
				for v in pl:
					o.append(xf * v)
				wp.append(o)
			if wp.is_empty() and c.has("span_mm"):
				# A jacket has no ports or centre line: its axis span stands
				# in for it (heights, centroid).
				var sp: Vector2 = c["span_mm"]
				wp.append(PackedVector3Array([xf * Vector3(0, sp.x, 0), xf * Vector3(0, sp.y, 0)]))
			w["path"] = wp
			var pw := {}
			for p in built.get("ports", []):
				if str(p["id"]) in c["ports"]:
					pw[str(p["id"])] = {"pos": xf * (p["pos"] as Vector3), "dir": (xf.basis * (p["z"] as Vector3)).normalized(),
						"kind": str(p["kind"])}
			w["port_world"] = pw
			# A part's metal goes with its first fluid volume.
			w["mass_kg"] = float(built.get("mass_kg", 0.0)) if (first_vol and TcFlowPaths.is_volume(str(c["role"]))) else 0.0
			if TcFlowPaths.is_volume(str(c["role"])):
				first_vol = false
			inst[iid] = w
			order.append(iid)
			for port in c["ports"]:
				port_inst["%s:%s" % [pid, str(port)]] = iid
	# 2. Merge consecutive pipes.
	var par := {}
	for iid in order:
		par[iid] = iid
	var joints: Array = res.get("joints", [])
	for jd in joints:
		if not bool(jd.get("ok", false)):
			continue
		var ia := str(port_inst.get(str(jd["a"]), ""))
		var ib := str(port_inst.get(str(jd["b"]), ""))
		if ia == "" or ib == "":
			continue
		var ca: Dictionary = inst[ia]
		var cb: Dictionary = inst[ib]
		if str(ca["role"]) == "pipe" and str(cb["role"]) == "pipe" and (ca["ports"] as Array).size() == 2 and (cb["ports"] as Array).size() == 2:
			_union(par, ia, ib)
	# 3. Control volumes.
	var cvs: Array = []
	var root_cv := {}       # union root → cv index
	var inst_cv := {}       # iid → cv index
	for iid in order:
		var c: Dictionary = inst[iid]
		if not TcFlowPaths.is_volume(str(c["role"])):
			continue
		var r := _find(par, iid)
		var ci: int
		if root_cv.has(r):
			ci = int(root_cv[r])
		else:
			ci = cvs.size()
			root_cv[r] = ci
			cvs.append({"id": "cv%d" % ci, "role": str(c["role"]), "parts": [], "circuits": [], "volume_m3": 0.0,
				"length_m": 0.0, "r_in_m": INF, "wall_area_m2": 0.0, "wall_mass_kg": 0.0,
				"y_low_mm": INF, "y_high_mm": -INF, "centroid_mm": Vector3.ZERO, "path": [], "ports": [],
				"attach": [], "heaters": [], "probes": [], "internals": [], "label": ""})
		inst_cv[iid] = ci
		var cv: Dictionary = cvs[ci]
		if not (str(c["part"]) in cv["parts"]):
			(cv["parts"] as Array).append(str(c["part"]))
		(cv["circuits"] as Array).append(iid)
		cv["volume_m3"] = float(cv["volume_m3"]) + float(c["volume_l"]) * 0.001
		cv["length_m"] = float(cv["length_m"]) + float(c["length_mm"]) * 0.001
		cv["r_in_m"] = minf(float(cv["r_in_m"]), float(c["r_in_mm"]) * 0.001)
		cv["wall_mass_kg"] = float(cv["wall_mass_kg"]) + float(c["mass_kg"])
		cv["wall_area_m2"] = float(cv["wall_area_m2"]) + _wall_area_m2(c)
		for port in c["ports"]:
			(cv["ports"] as Array).append("%s:%s" % [str(c["part"]), str(port)])
		for pl in c["path"]:
			(cv["path"] as Array).append(pl)
			for v in pl:
				cv["y_low_mm"] = minf(float(cv["y_low_mm"]), v.y)
				cv["y_high_mm"] = maxf(float(cv["y_high_mm"]), v.y)
		for pw in (c["port_world"] as Dictionary).values():
			var v2: Vector3 = pw["pos"]
			cv["y_low_mm"] = minf(float(cv["y_low_mm"]), v2.y)
			cv["y_high_mm"] = maxf(float(cv["y_high_mm"]), v2.y)
		if str(c["role"]) == "vessel":
			cv["internals"] = (c.get("internals", []) as Array).duplicate(true)
			cv["vessel_part"] = str(c["part"])
			cv["r_in_m"] = float(c["r_in_mm"]) * 0.001
			cv["height_m"] = float(c.get("height_mm", 0.0)) * 0.001
			cv["insulation_mm"] = float(c.get("insulation_mm", 0.0))
			cv["has_lid"] = bool(c.get("has_lid", false))
		if c.has("packing"):
			cv["packing"] = str(c["packing"])
		if c.has("filter"):
			cv["filter"] = str(c["filter"])
		if c.has("unit"):
			cv["unit"] = (c["unit"] as Dictionary).duplicate(true)
			cv["unit"]["part"] = str(c["part"])
	for cv in cvs:
		var n := 0
		var s := Vector3.ZERO
		for pl in cv["path"]:
			for v in pl:
				s += v
				n += 1
		cv["centroid_mm"] = s / float(maxi(n, 1))
		if not is_finite(float(cv["r_in_m"])):
			cv["r_in_m"] = 0.01
		cv["label"] = _cv_label(cv, parts)
	# 4. Links, attachments.
	var links: Array = []
	var link_inst_ends := {}   # link iid → {port id → cv index | -2 open | -3 closed}
	for jd in joints:
		if not bool(jd.get("ok", false)):
			continue
		var ra := str(jd["a"])
		var rb := str(jd["b"])
		var ia := str(port_inst.get(ra, ""))
		var ib := str(port_inst.get(rb, ""))
		if ia == "" or ib == "":
			continue
		var ca: Dictionary = inst[ia]
		var cb: Dictionary = inst[ib]
		var va := inst_cv.has(ia)
		var vb := inst_cv.has(ib)
		var at: Vector3 = (jd.get("frame", Transform3D.IDENTITY) as Transform3D).origin
		if va and vb:
			var a := int(inst_cv[ia])
			var b := int(inst_cv[ib])
			if a != b:
				links.append({"id": "l%d" % links.size(), "a": a, "b": b, "kind": "joint",
					"r_in_m": minf(float(ca["r_in_mm"]), float(cb["r_in_mm"])) * 0.001, "at_mm": at,
					"part": "", "open": true, "boundary": -1, "joint": int(jd.get("index", -1))})
			continue
		# One side a link circuit (valve) or an attachment.
		for pair in [[ia, ra, ib, rb], [ib, rb, ia, ra]]:
			var me := str(pair[0])
			var other := str(pair[2])
			var mc: Dictionary = inst[me]
			var mrole := str(mc["role"])
			if TcFlowPaths.is_link(mrole):
				var ends: Dictionary = link_inst_ends.get(me, {})
				var my_port := str(TcAssembly.split_ref(str(pair[1]))[1])
				ends[my_port] = int(inst_cv[other]) if inst_cv.has(other) else -3
				link_inst_ends[me] = ends
			elif TcFlowPaths.is_attach(mrole) and inst_cv.has(other):
				var cv2: Dictionary = cvs[int(inst_cv[other])]
				var info := {"part": str(mc["part"]), "role": mrole, "type": str(mc["type"]), "on": str(pair[3])}
				var pw: Dictionary = (mc["port_world"] as Dictionary).get("a", {})
				info["at_mm"] = pw.get("pos", at)
				info["dir"] = -(pw.get("dir", Vector3.UP) as Vector3)   # into the CV
				if mrole == "heater":
					info["reach_mm"] = float(mc.get("reach_mm", 300.0))
					(cv2["heaters"] as Array).append(info)
				elif mrole.begins_with("probe"):
					info["probe_mm"] = float(mc.get("probe_mm", 0.0))
					(cv2["probes"] as Array).append(info)
				(cv2["attach"] as Array).append(info)
	# 5. Boundaries (open ports).
	var boundaries: Array = []
	var open_by_ref := {}
	for op in res.get("open", []):
		var ref := str(op["ref"])
		var iid := str(port_inst.get(ref, ""))
		if iid == "":
			continue   # a stem or an air port: not fluid
		var xf: Transform3D = op["xf"]
		var lab: Dictionary = labels.get(ref, {})
		var c: Dictionary = inst[iid]
		var b := {"id": "b%d" % boundaries.size(), "ref": ref, "cv": int(inst_cv.get(iid, -1)), "link": -1,
			"pos_mm": xf.origin, "dir": xf.basis.z.normalized(), "text": str(lab.get("text", "")),
			"kind": ResourceKinds.normalize_kind(str(lab.get("kind", ""))) if lab.has("kind") else ""}
		b["role"] = _boundary_role(b, str(c["role"]))
		# An unused threaded bung on a vessel is plugged (vessels ship with
		# plugs in their spare bungs); an open clamp end vents to the air.
		var pk := str(((c["port_world"] as Dictionary).get(TcAssembly.split_ref(ref)[1], {}) as Dictionary).get("kind", ""))
		if str(c["role"]) == "vessel" and pk == "npt_f" and str(b["text"]) == "":
			b["role"] = "plug"
		open_by_ref[ref] = boundaries.size()
		boundaries.append(b)
		if TcFlowPaths.is_link(str(c["role"])):
			var ends2: Dictionary = link_inst_ends.get(iid, {})
			ends2[TcAssembly.split_ref(ref)[1]] = -2
			link_inst_ends[iid] = ends2
	# Valve / check / relief links.
	for iid in order:
		var c: Dictionary = inst[iid]
		if not TcFlowPaths.is_link(str(c["role"])):
			continue
		var ends: Dictionary = link_inst_ends.get(iid, {})
		var pairs: Array = [["a", "b", true]]
		if bool(c.get("l_port", false)):
			pairs = [["a", "b", bool(c.get("open", true))], ["a", "c", not bool(c.get("open", true))]]
		for pr in pairs:
			var ea := int(ends.get(str(pr[0]), -3))
			var eb := int(ends.get(str(pr[1]), -3))
			if ea == -3 or eb == -3:
				continue   # one side blind: nothing flows
			var bnd := -1
			if ea == -2 or eb == -2:
				if ea == -2 and eb == -2:
					continue
				var open_port := str(pr[0]) if ea == -2 else str(pr[1])
				bnd = int(open_by_ref.get("%s:%s" % [str(c["part"]), open_port], -1))
			var link := {"id": "l%d" % links.size(), "a": ea if ea >= 0 else eb, "b": eb if (ea >= 0 and eb >= 0) else -1,
				"kind": str(c["role"]), "r_in_m": float(c["r_in_mm"]) * 0.001,
				"at_mm": _mid(c), "part": str(c["part"]), "open": bool(pr[2]) if str(c["role"]) == "valve" else true,
				"boundary": bnd, "joint": -1}
			if str(c["role"]) == "valve" and not bool(c.get("l_port", false)):
				link["open"] = bool(c.get("open", true))
			if str(c["role"]) in ["check", "relief"]:
				# Flow is allowed a → b only; record which end is which.
				link["from"] = ea if ea >= 0 else -1
				link["set_bar"] = float(c.get("set_bar", 1.0))
			if bnd >= 0:
				(boundaries[bnd] as Dictionary)["link"] = links.size()
				(boundaries[bnd] as Dictionary)["cv"] = int(link["a"])
			links.append(link)
	# Boundaries on a CV get a boundary link so every way out is a link.
	for bi in boundaries.size():
		var b: Dictionary = boundaries[bi]
		if int(b["link"]) >= 0 or int(b["cv"]) < 0 or str(b["role"]) == "plug":
			continue
		var cv3: Dictionary = cvs[int(b["cv"])]
		b["link"] = links.size()
		links.append({"id": "l%d" % links.size(), "a": int(b["cv"]), "b": -1, "kind": "joint",
			"r_in_m": float(cv3["r_in_m"]) if str(cv3["role"]) != "vessel" else _port_r_m(b["ref"], parts),
			"at_mm": b["pos_mm"], "part": "", "open": true, "boundary": bi, "joint": -1})
	# 6. Thermal links.
	var thermal: Array = []
	for iid in order:
		var c: Dictionary = inst[iid]
		var partner := ""
		if c.has("cooled_by"):
			partner = "%s/%s" % [str(c["part"]), str(c["cooled_by"])]
		elif c.has("around"):
			partner = "%s/%s" % [str(c["part"]), str(c["around"])]
		if partner == "" or not inst_cv.has(iid) or not inst_cv.has(partner):
			continue
		thermal.append({"a": int(inst_cv[partner]), "b": int(inst_cv[iid]),
			"kind": "condenser" if c.has("cooled_by") else "jacket", "part": str(c["part"]),
			"area_m2": _wall_area_m2(inst[partner]) if c.has("cooled_by") else _wall_area_m2(c)})
	var refs := {}
	for iid in inst_cv.keys():
		var c: Dictionary = inst[iid]
		for port in c["ports"]:
			refs["%s:%s" % [str(c["part"]), str(port)]] = int(inst_cv[iid])
	return {"cvs": cvs, "links": links, "thermal": thermal, "boundaries": boundaries, "refs": refs, "key": ""}


static func _mid(c: Dictionary) -> Vector3:
	var s := Vector3.ZERO
	var n := 0
	for pw in (c["port_world"] as Dictionary).values():
		s += pw["pos"] as Vector3
		n += 1
	return s / float(maxi(n, 1))


static func _port_r_m(ref: String, parts: Dictionary) -> float:
	var sp := TcAssembly.split_ref(ref)
	var pd: Dictionary = parts.get(sp[0], {})
	for p in (pd.get("built", {}) as Dictionary).get("ports", []):
		if str(p["id"]) == sp[1]:
			var size := str(p["size"])
			if TcStandards.has_size(size):
				return float(TcStandards.tube(size)["r_in"]) * 0.001
			return 0.006   # ½" NPT: about 12 mm bore
	return 0.01


## Inside wall area of a circuit (m²): tube walls 2πrL, a vessel's shell
## and bottom, a dephlegmator jacket's annulus walls.
static func _wall_area_m2(c: Dictionary) -> float:
	var r := float(c.get("r_in_mm", 10.0)) * 0.001
	match str(c.get("role", "")):
		"vessel":
			var H := float(c.get("height_mm", 0.0)) * 0.001
			return 2.0 * PI * r * H + PI * r * r * (2.0 if bool(c.get("has_lid", false)) else 1.0)
		"jacket":
			var sp: Vector2 = c.get("span_mm", Vector2.ZERO)
			return 2.0 * PI * float(c.get("r_mm", 0.0)) * 0.001 * maxf(sp.y - sp.x, 0.0) * 0.001
		"coolant":
			return 2.0 * PI * r * float(c.get("jacket_len_mm", 0.0)) * 0.001
	return 2.0 * PI * r * float(c.get("length_mm", 0.0)) * 0.001


const FEED_KINDS := ["biomass", "plastic_waste", "plastic_flake"]


static func _boundary_role(b: Dictionary, circuit_role: String) -> String:
	var kind := str(b["kind"])
	var text := str(b["text"]).to_lower()
	if circuit_role == "coolant":
		if kind == "hot_water" or text.contains(" out"):
			return "coolant_out"
		return "coolant_in"
	if kind == "":
		return "outlet" if text != "" else "atmosphere"
	if kind in FEED_KINDS:
		return "feed"   # where a solid charge goes in: closed while it runs
	if kind in GAS_KINDS:
		return "product"
	if kind in LIQUID_KINDS:
		return "drain"
	return "outlet"


static func _cv_label(cv: Dictionary, parts: Dictionary) -> String:
	var names: Array = []
	for pid in cv["parts"]:
		var pd: Dictionary = parts.get(pid, {})
		names.append(str((pd.get("built", {}) as Dictionary).get("label", pid)))
	match str(cv["role"]):
		"vessel": return str(names[0]) if not names.is_empty() else "Vessel"
		"jacket": return "Jacket"
		"coolant": return "Cooling water · %s" % (str(names[0]) if not names.is_empty() else "")
		"condenser": return "Condenser · %s" % (str(names[0]) if not names.is_empty() else "")
	if names.size() == 1:
		return str(names[0])
	return "%s + %s" % [str(names[0]), UiText.count(names.size() - 1, "part")]


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

static func cv_of_ref(net: Dictionary, ref: String) -> int:
	return int((net.get("refs", {}) as Dictionary).get(ref, -1))


## The CV holding a part's circuit (main / product / coolant / jacket).
static func cv_of_part(net: Dictionary, pid: String, circuit: String = "") -> int:
	var cvs: Array = net.get("cvs", [])
	for i in cvs.size():
		for iid in cvs[i]["circuits"]:
			var sp := str(iid).split("/")
			if sp[0] == pid and (circuit == "" or sp[1] == circuit):
				return i
	return -1


static func boundary_of_ref(net: Dictionary, ref: String) -> Dictionary:
	for b in net.get("boundaries", []):
		if str(b["ref"]) == ref:
			return b
	return {}


## CV adjacency over the links that let fluid through (open valves;
## check / relief in either direction), skipping boundary links.
## `skip` = CV indices treated as walls.
static func neighbours(net: Dictionary, skip: Array = []) -> Array:
	var cvs: Array = net.get("cvs", [])
	var adj: Array = []
	for _i in cvs.size():
		adj.append([])
	for l in net.get("links", []):
		var a := int(l["a"])
		var b := int(l["b"])
		if a < 0 or b < 0 or not bool(l["open"]):
			continue
		if a in skip or b in skip:
			continue
		(adj[a] as Array).append(b)
		(adj[b] as Array).append(a)
	return adj


## Is `to` reachable from `from` without passing through any CV in `skip`?
static func reachable(net: Dictionary, from: int, to: int, skip: Array = []) -> bool:
	if from < 0 or to < 0:
		return false
	var adj := neighbours(net, skip)
	var seen := {from: true}
	var q: Array = [from]
	while not q.is_empty():
		var c := int(q.pop_front())
		if c == to:
			return true
		for n in adj[c]:
			if not seen.has(n):
				seen[n] = true
				q.append(n)
	return false


## The CVs reachable from `from` (the connected fluid region).
static func region(net: Dictionary, from: int) -> Array:
	var adj := neighbours(net)
	var seen := {from: true}
	var q: Array = [from]
	var out: Array = []
	while not q.is_empty():
		var c := int(q.pop_front())
		out.append(c)
		for n in adj[c]:
			if not seen.has(n):
				seen[n] = true
				q.append(n)
	return out

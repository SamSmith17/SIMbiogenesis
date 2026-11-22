class_name CtrlDesign
extends RefCounted

## A controller spec solved: the body box, each face's frame, every port's
## placement and pins (with roles), the checks, and what the graph and the
## other labs read (graph specs, handles). Cached by CtrlSpec.key_of.
##
##   var d := CtrlDesign.solve(spec)
##   d.faces[f] = {c, x, y, n, size: Vector2, xf: Transform3D}   (mm)
##   d.ports[i] = {id, connector, face, xf, entry, roles, pins, label, group, corners}
##   d.roles[role] = [{port, pin, pos, dir}]
##   d.checks = [{level: "error" | "warn" | "info", text, why, ids}]

const CACHE_MAX := 32
static var _cache: Dictionary = {}
static var _order: Array = []


static func clear_cache() -> void:
	_cache.clear()
	_order.clear()


static func solve(spec: Dictionary) -> Dictionary:
	var key := CtrlSpec.key_of(spec)
	if _cache.has(key):
		return _cache[key]
	var d := _solve(CtrlSpec.resolve(spec))
	_cache[key] = d
	_order.append(key)
	while _order.size() > CACHE_MAX:
		_cache.erase(_order.pop_front())
	return d


static func _solve(s: Dictionary) -> Dictionary:
	var b: Dictionary = s["body"]
	var w := float(b["w"])
	var h := float(b["h"])
	var dd := float(b["d"])
	var z0 := body_z0(s)
	var y0 := body_y0(s)
	var zf := z0 + dd
	var faces := {}
	_face(faces, "front", Vector3(0, y0 + h * 0.5, zf), Vector3.RIGHT, Vector3.UP, Vector2(w, h))
	_face(faces, "back", Vector3(0, y0 + h * 0.5, z0), Vector3.LEFT, Vector3.UP, Vector2(w, h))
	_face(faces, "left", Vector3(-w * 0.5, y0 + h * 0.5, z0 + dd * 0.5), Vector3.BACK, Vector3.UP, Vector2(dd, h))
	_face(faces, "right", Vector3(w * 0.5, y0 + h * 0.5, z0 + dd * 0.5), Vector3.FORWARD, Vector3.UP, Vector2(dd, h))
	_face(faces, "top", Vector3(0, y0 + h, z0 + dd * 0.5), Vector3.RIGHT, Vector3.FORWARD, Vector2(w, dd))
	_face(faces, "bottom", Vector3(0, y0, z0 + dd * 0.5), Vector3.RIGHT, Vector3.BACK, Vector2(w, dd))
	var bay: Dictionary = s["bay"]
	var bay_on := bool(bay["on"])
	if bay_on:
		var wall := float(bay["wall"])
		var by1 := clampf(float(bay["y1"]), wall + 20.0, h - 10.0)
		var depth := clampf(float(bay["depth"]), 10.0, dd - 5.0)
		_face(faces, "bay", Vector3(0, y0 + (wall + by1) * 0.5, zf - depth), Vector3.RIGHT, Vector3.UP,
			Vector2(w - 2.0 * wall, by1 - wall))
		faces["bay"]["depth"] = depth
		faces["bay"]["y1"] = by1
	var d := {"spec": s, "w": w, "h": h, "d": dd, "z0": z0, "y0": y0, "zf": zf, "faces": faces,
		"ports": [], "roles": {}, "checks": []}
	var checks: Array = d["checks"]
	for p in (s["ports"] as Array):
		var face := str(p["face"])
		if not faces.has(face):
			checks.append(_chk("error", "%s sits on the wiring bay, but this unit has no bay." % _port_name(p),
				"Turn the wiring bay on, or move the port to a face.", [p["id"]]))
			continue
		var f: Dictionary = faces[face]
		var local := Transform3D(Basis(Vector3.BACK, deg_to_rad(float(p["rot"]))),
			Vector3(float(p["u"]), float(p["v"]), float(p["dz"])))
		var xf: Transform3D = (f["xf"] as Transform3D) * local
		var e := ConnectorCatalog.resolve(str(p["connector"]), p["opts"])
		var roles := CtrlRoles.pin_roles(p, e)
		var pins: Array = []
		var pe: Array = e["pins"]
		for i in pe.size():
			var pin: Dictionary = pe[i]
			var rec := {"id": pin["id"], "label": pin["label"], "role": roles[i],
				"pos": xf * (pin["pos"] as Vector3), "dir": (xf.basis * (pin["dir"] as Vector3)).normalized()}
			pins.append(rec)
			if str(roles[i]) != "":
				if not d["roles"].has(roles[i]):
					d["roles"][roles[i]] = []
				d["roles"][roles[i]].append({"port": p["id"], "pin": pin["id"], "pos": rec["pos"], "dir": rec["dir"]})
		var bw: Vector3 = e["body"]
		var corners: Array = []
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var q := Vector2(c.x * bw.x * 0.5, c.y * bw.y * 0.5).rotated(deg_to_rad(float(p["rot"])))
			corners.append(q + Vector2(float(p["u"]), float(p["v"])))
		d["ports"].append({"id": p["id"], "connector": p["connector"], "face": face, "xf": xf, "entry": e,
			"roles": roles, "pins": pins, "label": str(p["label"]), "group": str(p["group"]), "corners": corners})
	_checks(d)
	d["graph_specs"] = graph_specs(d)
	d["handles"] = handles(d)
	d["stats"] = _stats(d)
	return d


## What stands between the wall and the body.
static func body_z0(s: Dictionary) -> float:
	var hs: Dictionary = s["heatsink"]
	var z := float(s["body"]["standoff"])
	if str(hs["where"]) == "back":
		z = maxf(z, float(hs["fin_d"]) + float(hs["base_t"]))
	match str(s["mount"]["style"]):
		"flange":
			z = maxf(z, 3.0)
		"bracket":
			z = maxf(z, 4.0)
	return z


## What the body stands on (feet).
static func body_y0(s: Dictionary) -> float:
	if str(s["mount"]["style"]) == "feet":
		return 8.0
	return 0.0


static func _face(faces: Dictionary, id: String, c: Vector3, x: Vector3, y: Vector3, size: Vector2) -> void:
	var n := x.cross(y).normalized()
	faces[id] = {"c": c, "x": x, "y": y, "n": n, "size": size, "xf": Transform3D(Basis(x, y, n), c)}


static func _chk(level: String, text: String, why: String, ids: Array = []) -> Dictionary:
	return {"level": level, "text": text, "why": why, "ids": ids}


static func _port_name(p: Dictionary) -> String:
	var lb := str(p.get("label", ""))
	return "%s (%s)" % [lb, ConnectorCatalog.label(str(p["connector"]))] if lb != "" else ConnectorCatalog.label(str(p["connector"]))


## The part of a face a port may use, in the face's own coordinates.
static func _usable(d: Dictionary, face: String) -> Dictionary:
	var s: Dictionary = d["spec"]
	var r := float(s["body"]["corner_r"])
	var e := float(s["body"]["edge_r"])
	var f: Dictionary = d["faces"][face]
	var size: Vector2 = f["size"]
	match face:
		"front", "back":
			return {"round": true, "w": size.x - 2.0 * e, "h": size.y - 2.0 * e, "r": maxf(r - e, 0.0)}
		"left", "right":
			return {"round": false, "hx": size.x * 0.5 - e, "hy": size.y * 0.5 - r}
		"top", "bottom":
			return {"round": false, "hx": size.x * 0.5 - r, "hy": size.y * 0.5 - e}
	return {"round": false, "hx": size.x * 0.5, "hy": size.y * 0.5}


static func point_on_face(d: Dictionary, face: String, q: Vector2, slack: float = 0.5) -> bool:
	var u := _usable(d, face)
	if bool(u["round"]):
		var hw := float(u["w"]) * 0.5
		var hh := float(u["h"]) * 0.5
		var r := float(u["r"])
		var ax := absf(q.x)
		var ay := absf(q.y)
		if ax > hw + slack or ay > hh + slack:
			return false
		if ax > hw - r and ay > hh - r:
			return Vector2(ax - (hw - r), ay - (hh - r)).length() <= r + slack
		return true
	return absf(q.x) <= float(u["hx"]) + slack and absf(q.y) <= float(u["hy"]) + slack


static func _checks(d: Dictionary) -> void:
	var s: Dictionary = d["spec"]
	var e: Dictionary = s["elec"]
	var checks: Array = d["checks"]
	var kind := str(e["kind"])
	# Every port on its face.
	for p in (d["ports"] as Array):
		var ok := true
		for c in (p["corners"] as Array):
			if not point_on_face(d, str(p["face"]), c):
				ok = false
		if not ok:
			checks.append(_chk("warn", "%s runs off the %s face." % [_port_name(p), p["face"]],
				"Part of the connector hangs over an edge or a rounded corner; move it in.", [p["id"]]))
	# Overlaps on one face.
	var ports: Array = d["ports"]
	for i in ports.size():
		for j in range(i + 1, ports.size()):
			var a: Dictionary = ports[i]
			var bq: Dictionary = ports[j]
			if a["face"] != bq["face"]:
				continue
			# Breakers sit on their DIN rail.
			var sa := str(a["entry"]["shape"])
			var sb := str(bq["entry"]["shape"])
			if (sa == "din_rail" and str(bq["entry"]["mount"]) == "din") or (sb == "din_rail" and str(a["entry"]["mount"]) == "din"):
				continue
			if _rect_of(a["corners"]).grow(-0.5).intersects(_rect_of(bq["corners"]).grow(-0.5)):
				checks.append(_chk("warn", "%s and %s overlap." % [_port_name(a), _port_name(bq)],
					"Two connectors share the same spot on the %s face." % a["face"], [a["id"], bq["id"]]))
	# Required roles.
	var missing: Array = []
	for r in CtrlRoles.required(e):
		# A split-phase unit's L1 / L2 stand in for L.
		if not d["roles"].has(r) and not (str(r).ends_with("_L") and d["roles"].has(str(r) + "1")):
			missing.append(CtrlRoles.words(r))
	if not missing.is_empty():
		checks.append(_chk("error", "No terminal for: %s." % ", ".join(missing),
			"A %s needs somewhere to land each of these wires." % str(CtrlSpec.KIND_WORDS.get(kind, kind)).to_lower()))
	# Connector ratings against the currents they carry.
	var sys_v := maxf(float(e["system_v"]), 1.0)
	var bat_a := maxf(float(e["max_charge_a"]), float(e["ac_out_w"]) / (sys_v * 0.85))
	var pv_a := float(e["max_input_a"])
	for p in ports:
		var amps := float((p["entry"]["rating"] as Dictionary).get("amps", 0.0))
		if amps <= 0.0:
			continue
		var groups := {}
		for r in (p["roles"] as Array):
			if str(r) != "":
				groups[CtrlRoles.group_of(str(r))] = true
		var need := 0.0
		for g in groups:
			if str(g) == "bat":
				need = maxf(need, bat_a)
			elif str(g).begins_with("pv"):
				need = maxf(need, pv_a)
		if need > amps + 0.01:
			checks.append(_chk("error", "%s is rated %.0f A but carries up to %.0f A." % [_port_name(p), amps, need],
				"Battery terminals carry the charge current or the inverter's draw (AC watts over the battery voltage at 85 %%); PV terminals the MPPT input current.",
				[p["id"]]))
	# AC outlets against the inverter's output.
	var ac_w := float(e["ac_out_w"])
	if ac_w > 0.0:
		var outlet_w := 0.0
		var hardwired := false
		for p in ports:
			if not str(p["group"]).begins_with("ac_out"):
				continue
			var ent: Dictionary = p["entry"]
			if str(ent["shape"]) in ["terminal_block", "din_breaker"]:
				hardwired = true
			else:
				outlet_w += float((ent["rating"] as Dictionary).get("amps", 0.0)) * float(e["ac_v"])
		if not hardwired and outlet_w > 0.0 and outlet_w < ac_w - 1.0:
			checks.append(_chk("info", "The outlets take %.0f W of the %.0f W output." % [outlet_w, ac_w],
				"Plug-in outlets are limited by their own rating; a unit that delivers more has hard-wire terminals."))
	# The MPPT window inside the input limit.
	var voc := float(e["max_voc"])
	if float(e["mppt_max_v"]) > voc + 0.01 and voc > 0.0:
		checks.append(_chk("error", "The MPPT window tops out at %.0f V, over the %.0f V input limit." % [e["mppt_max_v"], voc],
			"The tracking range must sit inside the absolute maximum PV voltage."))
	if float(e["max_pv_w_per_mppt"]) > 0.0 and float(e["max_pv_w"]) > float(e["max_pv_w_per_mppt"]) * maxi(int(e["mppt_count"]), 1) + 1.0:
		checks.append(_chk("error", "The PV limit is more than its trackers can take.",
			"Total PV watts cannot exceed the per-MPPT limit times the number of MPPTs."))


static func _rect_of(corners: Array) -> Rect2:
	var r := Rect2(corners[0], Vector2.ZERO)
	for c in corners:
		r = r.expand(c)
	return r


## The numbers the graph's controller reads (the keys PvElectrical,
## GraphDcElectrical and the card already use).
static func graph_specs(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var e: Dictionary = s["elec"]
	var g := {"name": str(s["name"]), "max_voc": float(e["max_voc"]), "max_charge_amps": float(e["max_charge_a"]),
		"max_pv_watts": float(e["max_pv_w"]), "cost": float(e["cost"]), "system_voltage": int(e["system_v"])}
	if int(e["mppt_count"]) > 1 or float(e["mppt_min_v"]) > 0.0:
		g["mppt_count"] = int(e["mppt_count"])
	for pair in [["mppt_min_v", "mppt_min_v"], ["mppt_max_v", "mppt_max_v"], ["startup_v", "startup_v"],
			["max_input_a", "max_input_amps"], ["max_isc_a", "max_isc_amps"], ["max_pv_w_per_mppt", "max_pv_watts_per_mppt"],
			["idle_w", "idle_w"]]:
		if float(e[pair[0]]) > 0.0:
			g[pair[1]] = float(e[pair[0]])
	if float(e["ac_out_w"]) > 0.0:
		g["overload_watts"] = float(e["ac_out_w"])
		g["overload_duration_s"] = 10.0
		g["overload_lockout_s"] = 30.0
		# A missing surge rating is the continuous rating: the spike has no
		# extra headroom. A designed surge_w is what a short inrush is allowed.
		var surge := float(e.get("surge_w", 0.0))
		g["surge_w"] = surge if surge > 0.0 else float(e["ac_out_w"])
	var eff: Dictionary = e["eff"]
	if eff.has("mppt"):
		g["mppt_efficiency"] = float(eff["mppt"])
	if eff.has("charge"):
		g["charge_efficiency"] = float(eff["charge"])
	if eff.has("inverter"):
		g["inverter_efficiency"] = float(eff["inverter"])
	if float(e["ac_in_a"]) > 0.0:
		g["ac_in_amps"] = float(e["ac_in_a"])
	if not (e["comms"] as Array).is_empty():
		g["comms"] = (e["comms"] as Array).duplicate()
	if str(s.get("id", "")) != "":
		g["controller_preset"] = str(s["id"])
	return g


## The graph handles the unit's roles land on, in a stable order.
static func handles(d: Dictionary) -> Array:
	var seen := {}
	var out: Array = []
	var keys: Array = (d["roles"] as Dictionary).keys()
	keys.sort()
	for r in keys:
		var hnd := CtrlRoles.handle_for(str(r))
		if hnd != "" and not seen.has(hnd):
			seen[hnd] = true
			out.append(hnd)
	return out


static func _stats(d: Dictionary) -> Dictionary:
	var s: Dictionary = d["spec"]
	var e: Dictionary = s["elec"]
	var vol_l := float(d["w"]) * float(d["h"]) * float(d["d"]) * 1e-6
	var mass := float(e["mass_kg"]) if float(e["mass_kg"]) > 0.0 else vol_l * 0.55
	return {"mass_kg": mass, "mass_estimate": float(e["mass_kg"]) <= 0.0,
		"size_text": "%d × %d × %d mm" % [int(d["w"]), int(d["h"]), int(d["d"] + d["z0"])],
		"errors": (d["checks"] as Array).filter(func(c): return str(c["level"]) == "error").size()}


## The whole unit's box (mm, local), heatsink and mounts included.
static func bounds(d: Dictionary) -> AABB:
	var s: Dictionary = d["spec"]
	var w := float(d["w"])
	var ab := AABB(Vector3(-w * 0.5, 0.0, 0.0), Vector3(w, float(d["h"]) + float(d["y0"]), float(d["zf"])))
	var hs: Dictionary = s["heatsink"]
	var ex := float(hs["extra_w"]) if str(hs["where"]) == "back" else 0.0
	if str(hs["where"]) in ["full", "sides"]:
		ex = maxf(ex, float(hs["fin_d"]))
	ab.position.x -= ex
	ab.size.x += 2.0 * ex
	if str(hs["where"]) in ["full", "top"]:
		ab.size.y += float(hs["fin_d"])
	return ab


## Where a ray (unit-local mm) first meets the unit's box: {face, u, v, pos,
## t} or {}. With the bay's cover off (`bay_open`), a hit on the front over
## the bay lands on the bay's back plate.
static func face_hit(d: Dictionary, o: Vector3, dir: Vector3, bay_open: bool = false) -> Dictionary:
	var best := {}
	var best_t := INF
	for id in ["front", "back", "left", "right", "top", "bottom"]:
		var f: Dictionary = d["faces"][id]
		var hit := _plane_hit(f, o, dir)
		if hit.is_empty() or float(hit["t"]) >= best_t:
			continue
		var size: Vector2 = f["size"]
		if absf(float(hit["u"])) > size.x * 0.5 + 0.5 or absf(float(hit["v"])) > size.y * 0.5 + 0.5:
			continue
		best_t = float(hit["t"])
		hit["face"] = id
		best = hit
	if bay_open and (d["faces"] as Dictionary).has("bay") and str(best.get("face", "")) == "front":
		var fb: Dictionary = d["faces"]["bay"]
		var hb := _plane_hit(fb, o, dir)
		var sb: Vector2 = fb["size"]
		if not hb.is_empty() and absf(float(hb["u"])) <= sb.x * 0.5 and absf(float(hb["v"])) <= sb.y * 0.5:
			hb["face"] = "bay"
			best = hb
	return best


static func _plane_hit(f: Dictionary, o: Vector3, dir: Vector3) -> Dictionary:
	var n: Vector3 = f["n"]
	var den := dir.dot(n)
	if den > -1e-6:
		return {}
	var c: Vector3 = f["c"]
	var t := (c - o).dot(n) / den
	if t < 0.0:
		return {}
	var p := o + dir * t
	return {"t": t, "pos": p, "u": (p - c).dot(f["x"] as Vector3), "v": (p - c).dot(f["y"] as Vector3)}


# ---------------------------------------------------------------------------
# On the graph and in the world (Phase 4)
# ---------------------------------------------------------------------------

## The graph controller's own handles. The plain controller's set is always
## kept (pvPositive … acOutputBottom: every wire drawn to an undesigned
## controller lands again); the design adds what its terminals carry — a
## second MPPT's pvPositive2 / pvNegative2, acInput, genInput, the DC load
## and DC-in pairs, data. Inputs across the top, outputs across the bottom,
## as every node in the graph.
const LEGACY_HANDLES := [
	{"id": "pvPositive", "polarity": "positive", "rx": 0.25, "ry": 0.0},
	{"id": "pvNegative", "polarity": "negative", "rx": 0.75, "ry": 0.0},
	{"id": "batteryPositive", "polarity": "positive", "rx": 0.25, "ry": 1.0},
	{"id": "batteryNegative", "polarity": "negative", "rx": 0.75, "ry": 1.0},
	{"id": "acOutput", "polarity": "ac", "rx": 0.5, "ry": 1.0},
	{"id": "acOutputLeft", "polarity": "ac", "rx": 0.0, "ry": 0.5},
	{"id": "acOutputTop", "polarity": "ac", "rx": 0.5, "ry": 0.0},
	{"id": "acOutputBottom", "polarity": "ac", "rx": 0.5, "ry": 1.0},
]
const TOP_ORDER := ["pvPositive", "pvNegative", "pvPositive2", "pvNegative2", "pvPositive3", "pvNegative3",
	"pvPositive4", "pvNegative4", "dcInPositive", "dcInNegative", "acInput", "genInput"]
const BOTTOM_ORDER := ["batteryPositive", "batteryNegative", "loadPositive", "loadNegative", "acOutput", "data"]


static func handle_polarity(id: String) -> String:
	if id == "data":
		return ScadaNet.POLARITY
	if id.begins_with("ac") or id == "genInput":
		return "ac"
	if id.contains("Positive"):
		return "positive"
	if id.contains("Negative"):
		return "negative"
	return ""


static func graph_handles(d: Dictionary) -> Array:
	var have: Array = d.get("handles", [])
	var top: Array = []
	var bottom: Array = []
	for id in TOP_ORDER:
		if id in ["pvPositive", "pvNegative"] or have.has(id):
			top.append(id)
	for id2 in BOTTOM_ORDER:
		if id2 in ["batteryPositive", "batteryNegative", "acOutput"] or have.has(id2):
			bottom.append(id2)
	var out: Array = []
	for i in top.size():
		out.append({"id": top[i], "polarity": handle_polarity(str(top[i])),
			"rx": float(i + 1) / float(top.size() + 1), "ry": 0.0})
	for j in bottom.size():
		out.append({"id": bottom[j], "polarity": handle_polarity(str(bottom[j])),
			"rx": float(j + 1) / float(bottom.size() + 1), "ry": 1.0})
	# The plain controller's side / top AC handles, where they were.
	for h in LEGACY_HANDLES:
		if str(h["id"]) in ["acOutputLeft", "acOutputTop", "acOutputBottom"]:
			out.append((h as Dictionary).duplicate())
	return out


## The unit's connection ports in the world (model-root metres): one per
## graph handle, ON the terminal it lands on — a single stud or MC4 at its
## pin, a terminal strip or outlet at its middle — facing out of its face.
## A conduit whose handle is batteryPositive ends on the BAT + stud.
static func connection_ports(d: Dictionary) -> Array:
	var out: Array = []
	var done := {}
	for p in (d.get("ports", []) as Array):
		var xf: Transform3D = p["xf"]
		var n: Vector3 = xf.basis.z.normalized()
		var pins: Array = p["pins"]
		for pin in pins:
			var role := str(pin["role"])
			var hnd := CtrlRoles.handle_for(role)
			if hnd == "" or done.has(hnd):
				continue
			done[hnd] = true
			var pos: Vector3 = (pin["pos"] as Vector3) if pins.size() == 1 or hnd.contains("Positive") or hnd.contains("Negative") \
				else xf.origin
			var kind := "dc_electricity"
			var pol := handle_polarity(hnd)
			if pol == "ac":
				kind = "ac_electricity"
			elif pol == ScadaNet.POLARITY:
				kind = "data"
			var conduit := ""
			if hnd == "batteryPositive":
				conduit = "battery_cable_pos"
			elif hnd == "batteryNegative":
				conduit = "battery_cable_neg"
			var lab := str(p["label"]) if str(p["label"]) != "" else CtrlRoles.words(role)
			out.append(ConnectionPortDefs.make_port("ctl_" + hnd, "%s (%s)" % [GraphPortLabels.port_name(hnd), lab],
				pos * CtrlBuilder.MM + n * 0.004, n, hnd, pol, kind, "", ConnectionPortDefs.DEFAULT_APPROACH_M, conduit))
	return out


## How it ships: one box the size of the unit (heatsink and tabs included).
static func packed_spec(d: Dictionary) -> Dictionary:
	var ab := bounds(d)
	var s: Dictionary = d["spec"]
	var kg := float((s["elec"] as Dictionary).get("mass_kg", 0.0))
	if kg <= 0.0:
		kg = maxf(ab.size.x * ab.size.y * ab.size.z * 1e-9 * 900.0, 0.3)
	return {"w_m": ab.size.x * 0.001 + 0.08, "d_m": ab.size.z * 0.001 + 0.08, "h_m": ab.size.y * 0.001 + 0.08,
		"mass_kg": kg + 1.0, "form": "crate", "this_side_up": true, "source": "computed"}

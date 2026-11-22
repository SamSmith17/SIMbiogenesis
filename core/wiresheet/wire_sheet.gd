class_name WireSheet
extends RefCounted

## A front elevation of one solar power chain, in millimetres, y up.
## Devices are boxes with ports; conductors are orthogonal polylines with a
## colour, a gauge and a length. The systems graph stays the circuit: a
## position here is the page, not the card's x/y (pass it in opts.places).
##
## Gauge is the bank's rule (BankDesign): NEC 310.16 at 125 % of the
## continuous current, then the next size up while the drop at that current
## over the run is over 1 %. A run with route_length_m (else
## estimated_length) uses that; otherwise a PV run is 8 m and a battery run
## is 2 m. Colour is CtrlSheet.wire_color, so a positive lead is the same
## red as on a controller face.
##
## A breaker, combiner or fuse between the controller and the battery is a
## device on the page, and the battery positive is called out when the walk
## from it reaches the controller without passing a fuse or a breaker. A
## switch, a busbar or a shunt is in the line and does not clear that note.
## Shorts and overvoltage stay with GraphDcElectrical, which sees them once
## the graph is running. Comms (VE.Direct, VE.Bus, RS485) stay off the page
## until opts.show_data. They draw in the same teal as the controller face,
## and they are not sized as power cable.
## `svg` draws this same layout (the on-screen page uses it too).
##
## The controller is the front face `CtrlSheet` already lays out, and its
## wires leave that face's lead ends. The array is the string (nS × nP and
## its watts). The battery is the case, its studs, and the voltage and
## amp-hours. A fuse or breaker carries its rating, and "Blown" or "Tripped"
## when the graph says it has opened.


const DROP_MAX := 0.01
const CONT_FACTOR := 1.25
const RUN_PV_M := 8.0
const RUN_BAT_M := 2.0
const GAP_X := 100.0
const GAP_Y := 28.0
const STUB_MM := 14.0
## Port offset from a device's centre, so a + and a − on two boxes of
## different heights still leave on the same horizontal.
const PORT_DY := 22.0

const SIZE := {
	"panels": Vector2(150, 210),
	"controller": Vector2(180, 120),
	"battery": Vector2(170, 130),
	"breaker": Vector2(64, 48),
	"fuse": Vector2(64, 48),
	"switch": Vector2(64, 48),
	"busbar": Vector2(120, 28),
	"combiner": Vector2(88, 56),
	"distributor": Vector2(140, 56),
	"shunt": Vector2(72, 40),
	"monitor": Vector2(120, 44),
}

const INSERT_KINDS := ["fuse", "breaker", "switch", "busbar", "distributor", "shunt"]


## {devices, conductors, checks, bounds}. `places` is {item id: Vector2},
## the box's bottom-left, used instead of the automatic column for that id.
## `show_data` adds the comms runs and any monitor they land on.
static func layout(model: GraphModel, item_id: String, opts: Dictionary = {}) -> Dictionary:
	var empty := {"devices": [], "conductors": [], "checks": [], "bounds": Rect2()}
	if model == null or item_id.is_empty():
		return empty
	var chain := _resolve(model, item_id)
	if (chain["units"] as Array).is_empty():
		return empty
	var places: Dictionary = opts.get("places", {})
	var show_data := bool(opts.get("show_data", false))
	var devices := _place(model, chain, places)
	if show_data:
		_add_monitors(model, devices, places)
	var by_id := {}
	for d in devices:
		by_id[str(d["id"])] = d
	var conductors := _conductors(model, chain, by_id, show_data)
	var checks: Array = PowerChain.checks(model, chain["power"])
	var bat := str(chain["battery"])
	if not bat.is_empty() and _has_pole(conductors, bat, "positive"):
		if not bool(chain["fused_positive"]):
			checks.append({
				"level": "warn", "code": "no_fuse", "link": "battery",
				"text": "Battery: no fuse on the positive.",
				"why": "A short across the bank is limited only by the cable until a fuse opens. Put one on the positive, close to the battery.",
			})
	return {"devices": devices, "conductors": conductors, "checks": checks, "bounds": _bounds(devices)}


## The wire for `amps` continuous at `volts` over `length_m` (one way).
## {gauge, mm2, amps, drop_pct, upsized}.
static func size_run(amps: float, volts: float, length_m: float) -> Dictionary:
	var w := BattElectrical.wire_for(maxf(amps, 0.0) * CONT_FACTOR)
	var gauge := str(w["name"])
	var mm2 := float(w["mm2"])
	var upsized := false
	var drop := 0.0
	for _i in 20:
		var r := BattElectrical.resistance("copper", maxf(length_m, 0.0) * 1000.0, mm2)
		drop = amps * r / maxf(volts, 1.0)
		if drop <= DROP_MAX:
			break
		var nxt := _next_wire(mm2)
		if nxt.is_empty():
			break
		gauge = str(nxt[0])
		mm2 = float(nxt[1])
		upsized = true
	return {"gauge": gauge, "mm2": mm2, "amps": amps, "drop_pct": drop * 100.0, "upsized": upsized}


## Split `conn_id` with a protection or a bus. The new item is a graph
## breaker (a fuse is one with fuse set; a switch, a busbar and a shunt are
## too, so the DC tracer hops them) or a combiner for a distributor, which
## also gets a fuse on its way out. Returns the new item's id, or "".
static func insert(model: GraphModel, conn_id: String, kind: String) -> String:
	if model == null or not INSERT_KINDS.has(kind):
		return ""
	var c := model.get_connection(conn_id)
	if c.is_empty():
		return ""
	var pol := str(c.get("polarity", ""))
	if pol == "ac" or pol == "data":
		return ""
	var src := str(c.get("source_item_id", ""))
	var sh := str(c.get("source_handle_id", ""))
	var dst := str(c.get("target_item_id", ""))
	var th := str(c.get("target_handle_id", ""))
	if src.is_empty() or dst.is_empty():
		return ""
	if pol != "positive" and pol != "negative":
		pol = "negative" if _is_negative(sh) or _is_negative(th) else "positive"
	var rate := BattElectrical.breaker_for(maxf(_insert_amps(model, c), 1.0) * CONT_FACTOR)
	var volts := _insert_volts(model, src, dst)
	var at := _midpoint(model, src, dst)
	if kind == "distributor":
		var dist := _add_protection(model, "distributor", rate, volts, at)
		var fuse := _add_protection(model, "fuse", rate, volts, at + Vector2(90, 0))
		model.remove_connection(conn_id)
		_bridge(model, c, src, sh, dist, "input1", true)
		_bridge(model, c, dist, "output", fuse, "input", false)
		_bridge(model, c, fuse, "output", dst, th, false)
		return dist
	var nid := _add_protection(model, kind, rate, volts, at)
	model.remove_connection(conn_id)
	_bridge(model, c, src, sh, nid, "input", true)
	_bridge(model, c, nid, "output", dst, th, false)
	return nid


## The conductor under a page point, within `tol` mm of its polyline, or "".
static func conductor_at(lay: Dictionary, q: Vector2, tol: float = 8.0) -> String:
	var best := ""
	var best_d := tol
	for c in (lay.get("conductors", []) as Array):
		var pts: PackedVector2Array = c["pts"]
		for i in range(1, pts.size()):
			var d := _seg_dist(q, pts[i - 1], pts[i])
			if d < best_d:
				best_d = d
				best = str(c["id"])
	return best


static func _seg_dist(q: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-8:
		return q.distance_to(a)
	var t := clampf((q - a).dot(ab) / l2, 0.0, 1.0)
	return q.distance_to(a + ab * t)


static func _insert_amps(model: GraphModel, c: Dictionary) -> float:
	var ha := str(c.get("source_handle_id", ""))
	var hb := str(c.get("target_handle_id", ""))
	var src := str(c.get("source_item_id", ""))
	var dst := str(c.get("target_item_id", ""))
	var pv := ha.begins_with("pv") or hb.begins_with("pv")
	if not pv:
		for id in [src, dst]:
			if str(model.get_item(id).get("type", "")) == "panel":
				pv = true
	if pv:
		var a := _string_isc(model, _panel_item(model, src, dst))
		return a if a > 0.0 else 10.0
	for id2 in [src, dst]:
		if PowerChain.kind_of(model, id2) == "controller":
			var ch := _charge_amps(model, id2)
			if ch > 0.0:
				return ch
	return 30.0


static func _insert_volts(model: GraphModel, a: String, b: String) -> float:
	for id in [a, b]:
		if PowerChain.kind_of(model, id) == "battery":
			return _bat_volts(model, id)
	return 12.0


static func _midpoint(model: GraphModel, a: String, b: String) -> Vector2:
	var ia := model.get_item(a)
	var ib := model.get_item(b)
	var ax := float(ia.get("x", 0.0))
	var bx := float(ib.get("x", 0.0))
	var x := (ax + bx) * 0.5
	var y := (float(ia.get("y", 0.0)) + float(ib.get("y", 0.0))) * 0.5
	if absf(x - ax) < 1.0:
		x = ax + 120.0
	return Vector2(x, y)


static func _add_protection(model: GraphModel, kind: String, rate: float, volts: float, at: Vector2) -> String:
	var id := model.generate_item_id()
	var fuse := kind == "fuse"
	var name := "Shunt" if kind == "shunt" else ("Switch" if kind == "switch" else ("Busbar" if kind == "busbar" else ("Distributor" if kind == "distributor" else ("%s %s A" % ["Fuse" if fuse else "Breaker", _n(rate)]))))
	var specs := {
		"name": name, "rating_a": rate, "volts": volts, "closed": true, "tripped": false, "fuse": fuse,
		"model_id": WireAccessory.MODEL_ID,
	}
	if kind == "switch":
		specs["switch"] = true
	elif kind == "busbar":
		specs["busbar"] = true
	elif kind == "shunt":
		specs["shunt"] = true
	elif kind == "distributor":
		specs["distributor"] = true
	var ty := "combiner" if kind == "distributor" else "breaker"
	var sz: Vector2 = SIZE.get(kind, SIZE["breaker"])
	model.add_item({
		"id": id, "type": ty, "label": name,
		"x": at.x, "y": at.y, "width": sz.x, "height": sz.y,
		"scope_id": "root", "specs": specs,
	})
	return id


static func _bridge(model: GraphModel, src: Dictionary, a: String, ha: String, b: String, hb: String, keep_length: bool) -> void:
	var n := {
		"scope_id": str(src.get("scope_id", "root")),
		"polarity": str(src.get("polarity", "positive")),
		"source_item_id": a, "source_handle_id": ha,
		"target_item_id": b, "target_handle_id": hb,
	}
	if keep_length:
		if float(src.get("route_length_m", 0.0)) > 0.0:
			n["route_length_m"] = float(src["route_length_m"])
		if float(src.get("estimated_length", 0.0)) > 0.0:
			n["estimated_length"] = float(src["estimated_length"])
	else:
		n["estimated_length"] = 0.15
	model.add_connection(n)


# ---------------------------------------------------------------------------
# Chain: PowerChain, plus a breaker or fuse sitting in the battery leads
# ---------------------------------------------------------------------------

static func _resolve(model: GraphModel, item_id: String) -> Dictionary:
	var power := PowerChain.find(model, item_id)
	var ctrl_id := str((power["controller"] as Dictionary).get("id", ""))
	var bat_id := str((power["battery"] as Dictionary).get("id", ""))
	if ctrl_id.is_empty() and not bat_id.is_empty():
		var found := _walk_kind(model, bat_id, ["positive", "negative"], "controller")
		if bool(found["found"]):
			ctrl_id = str(found["id"])
			power["controller"] = PowerChain.describe(model, ctrl_id)
	if bat_id.is_empty() and not ctrl_id.is_empty():
		var found2 := _walk_kind(model, ctrl_id, ["batteryPositive", "batteryNegative"], "battery")
		if bool(found2["found"]):
			bat_id = str(found2["id"])
			power["battery"] = PowerChain.describe(model, bat_id)
	var pos_j: Array = []
	var neg_j: Array = []
	if not ctrl_id.is_empty() and not bat_id.is_empty():
		pos_j = (_walk(model, ctrl_id, ["batteryPositive"], bat_id)["junctions"] as Array)
		neg_j = (_walk(model, ctrl_id, ["batteryNegative"], bat_id)["junctions"] as Array)
	var units: Array = []
	for a in (power["arrays"] as Array):
		units.append(str(a["id"]))
	if not ctrl_id.is_empty():
		units.append(ctrl_id)
	if not bat_id.is_empty():
		units.append(bat_id)
	for jid in pos_j + neg_j:
		if not units.has(str(jid)):
			units.append(str(jid))
	return {
		"power": power, "units": units, "controller": ctrl_id, "battery": bat_id,
		"pos_junctions": pos_j, "neg_junctions": neg_j,
		"fused_positive": _positive_protected(model, pos_j),
	}


## A fuse or a breaker on the positive. A switch, a busbar or a shunt is in
## the line and the sheet draws it, and it does not clear the missing-fuse note.
static func _positive_protected(model: GraphModel, junctions: Array) -> bool:
	for jid in junctions:
		if _overcurrent(model.get_item(str(jid))):
			return true
	return false


static func _overcurrent(it: Dictionary) -> bool:
	var sp: Dictionary = it.get("specs", {})
	if bool(sp.get("switch", false)) or bool(sp.get("busbar", false)) or bool(sp.get("shunt", false)):
		return false
	var ty := str(it.get("type", ""))
	return ty == "breaker" or ty == "acbreaker"


static func _is_junction(it: Dictionary) -> bool:
	var ty := str(it.get("type", ""))
	return ty == "breaker" or ty == "combiner" or ty == "acbreaker"


## Walk from `start_id` out of `start_handles`, through junctions, until
## `goal_id`. {found, junctions}. A combiner entered on its output leaves
## by input1; a breaker leaves by its other terminal.
static func _walk(model: GraphModel, start_id: String, start_handles: Array, goal_id: String) -> Dictionary:
	var q: Array = []
	for h in start_handles:
		q.append({"id": start_id, "handle": str(h), "junctions": []})
	var seen := {}
	while not q.is_empty():
		var s: Dictionary = q.pop_front()
		var key := "%s|%s" % [str(s["id"]), str(s["handle"])]
		if seen.has(key):
			continue
		seen[key] = true
		for c in model.connections:
			var ends := _ends(c, str(s["id"]), str(s["handle"]))
			if ends.is_empty():
				continue
			var other_id := str(ends["id"])
			var other_h := str(ends["handle"])
			if other_id == goal_id or PowerChain.unit_of(model, other_id) == goal_id:
				return {"found": true, "junctions": s["junctions"], "id": goal_id}
			var it := model.get_item(other_id)
			if not _is_junction(it):
				continue
			var nxt := _leave(it, other_h)
			if nxt.is_empty():
				continue
			var js: Array = (s["junctions"] as Array).duplicate()
			if not js.has(other_id):
				js.append(other_id)
			q.append({"id": other_id, "handle": nxt, "junctions": js})
	return {"found": false, "junctions": [], "id": ""}


static func _walk_kind(model: GraphModel, start_id: String, start_handles: Array, want: String) -> Dictionary:
	var q: Array = []
	for h in start_handles:
		q.append({"id": start_id, "handle": str(h), "junctions": []})
	var seen := {}
	while not q.is_empty():
		var s: Dictionary = q.pop_front()
		var key := "%s|%s" % [str(s["id"]), str(s["handle"])]
		if seen.has(key):
			continue
		seen[key] = true
		for c in model.connections:
			var ends := _ends(c, str(s["id"]), str(s["handle"]))
			if ends.is_empty():
				continue
			var other_id := str(ends["id"])
			var other_h := str(ends["handle"])
			var unit := PowerChain.unit_of(model, other_id)
			if unit != start_id and PowerChain.kind_of(model, unit) == want:
				return {"found": true, "id": unit, "junctions": s["junctions"]}
			var it := model.get_item(other_id)
			if not _is_junction(it):
				continue
			var nxt := _leave(it, other_h)
			if nxt.is_empty():
				continue
			var js: Array = (s["junctions"] as Array).duplicate()
			if not js.has(other_id):
				js.append(other_id)
			q.append({"id": other_id, "handle": nxt, "junctions": js})
	return {"found": false, "id": "", "junctions": []}


## The other end of a connection landed on (item, handle). {} when this
## connection does not touch that terminal, or it is AC / data.
static func _ends(c: Variant, item_id: String, handle: String) -> Dictionary:
	var cd: Dictionary = c
	var pol := str(cd.get("polarity", ""))
	if pol == "ac" or pol == "data":
		return {}
	if str(cd.get("source_item_id", "")) == item_id and str(cd.get("source_handle_id", "")) == handle:
		return {"id": str(cd.get("target_item_id", "")), "handle": str(cd.get("target_handle_id", ""))}
	if str(cd.get("target_item_id", "")) == item_id and str(cd.get("target_handle_id", "")) == handle:
		return {"id": str(cd.get("source_item_id", "")), "handle": str(cd.get("source_handle_id", ""))}
	return {}


## The terminal a junction is left by, given the one it was entered on.
static func _leave(it: Dictionary, entered: String) -> String:
	var ty := str(it.get("type", ""))
	if ty == "combiner":
		if entered == "output":
			return "input1"
		if entered.begins_with("input"):
			return "output"
		return ""
	if entered == "input" or entered.begins_with("input"):
		return "output"
	if entered == "output":
		return "input"
	return ""


# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

static func _place(model: GraphModel, chain: Dictionary, places: Dictionary) -> Array:
	var power: Dictionary = chain["power"]
	var arrays: Array = power["arrays"]
	var n := maxi(arrays.size(), 1)
	var ph: float = SIZE["panels"].y
	var stack := float(n) * ph + float(maxi(n - 1, 0)) * GAP_Y
	var cy := stack * 0.5
	var out: Array = []
	var x := 0.0
	if not arrays.is_empty():
		for i in arrays.size():
			var a: Dictionary = arrays[i]
			var y := stack - float(i + 1) * ph - float(i) * GAP_Y
			out.append(_device(model, str(a["id"]), "panels", Vector2(x, y), places))
		x += SIZE["panels"].x + GAP_X
	var ctrl := str(chain["controller"])
	if not ctrl.is_empty():
		var csz := _box_size(model, ctrl, "controller")
		out.append(_device(model, ctrl, "controller", Vector2(x, cy - csz.y * 0.5), places))
		x += csz.x + GAP_X
	var pos_j: Array = chain["pos_junctions"]
	var neg_j: Array = chain["neg_junctions"]
	var nj := maxi(pos_j.size(), neg_j.size())
	if nj > 0:
		var jw: float = SIZE["breaker"].x
		for i in pos_j.size():
			var id := str(pos_j[i])
			var kind := _junction_kind(model, id)
			var sz: Vector2 = SIZE.get(kind, SIZE["breaker"])
			var origin := Vector2(x + float(i) * (jw + 16.0), cy + PORT_DY - sz.y * 0.5)
			out.append(_device(model, id, kind, origin, places))
		for i in neg_j.size():
			var id2 := str(neg_j[i])
			if pos_j.has(id2):
				continue
			var kind2 := _junction_kind(model, id2)
			var sz2: Vector2 = SIZE.get(kind2, SIZE["breaker"])
			var origin2 := Vector2(x + float(i) * (jw + 16.0), cy - PORT_DY - sz2.y * 0.5)
			out.append(_device(model, id2, kind2, origin2, places))
		x += float(nj) * jw + float(maxi(nj - 1, 0)) * 16.0 + GAP_X
	var bat := str(chain["battery"])
	if not bat.is_empty():
		var bh: float = SIZE["battery"].y
		out.append(_device(model, bat, "battery", Vector2(x, cy - bh * 0.5), places))
	return out


## A comms peer that is not already on the power page, sat below the chain.
## Both ends of a data run get a data port if they did not have one.
static func _add_monitors(model: GraphModel, devices: Array, places: Dictionary) -> void:
	var by := {}
	for d in devices:
		by[str(d["id"])] = d
	var floor := INF
	for d2 in devices:
		floor = minf(floor, ((d2 as Dictionary)["box"] as Rect2).position.y)
	var y := floor - GAP_Y - SIZE["monitor"].y
	var x := 0.0
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("polarity", "")) != "data":
			continue
		var a := str(cd.get("source_item_id", ""))
		var b := str(cd.get("target_item_id", ""))
		if by.has(a) and by.has(b):
			_ensure_data_port(by[a])
			_ensure_data_port(by[b])
			continue
		var known := ""
		var other := ""
		if by.has(a) and not by.has(b):
			known = a
			other = b
		elif by.has(b) and not by.has(a):
			known = b
			other = a
		else:
			continue
		if other.is_empty() or model.get_item(other).is_empty():
			continue
		_ensure_data_port(by[known])
		var role := _data_role(by[known], "data")
		if role.is_empty():
			role = "rs485"
		var dev := _device(model, other, "monitor", Vector2(x, y), places)
		var box: Rect2 = dev["box"]
		dev["ports"] = [{
			"id": "data", "handle": "data", "side": "top", "role": role,
			"pos": Vector2(box.get_center().x, box.end.y), "dir": Vector2.UP,
		}]
		(dev["symbol"] as Dictionary)["caption"] = CtrlSheet.short(role)
		devices.append(dev)
		by[other] = dev
		x += SIZE["monitor"].x + 16.0


static func _ensure_data_port(device: Dictionary) -> void:
	for p in (device["ports"] as Array):
		if str(p["handle"]) == "data":
			return
	var box: Rect2 = device["box"]
	(device["ports"] as Array).append({
		"id": "data", "handle": "data", "side": "bottom", "role": "rs485",
		"pos": Vector2(box.get_center().x, box.position.y), "dir": Vector2.DOWN,
	})


## The face lead this graph handle belongs to (rs485, ve_direct, ve_bus, …).
static func _data_role(device: Dictionary, handle: String) -> String:
	var face: Variant = (device.get("symbol", {}) as Dictionary).get("face", {})
	if face is Dictionary:
		for ld in ((face as Dictionary).get("leads", []) as Array):
			if CtrlRoles.handle_for(str(ld["role"])) == handle:
				return str(ld["role"])
	for p in (device["ports"] as Array):
		if str(p["handle"]) == handle and str(p.get("role", "")) != "":
			var g := CtrlRoles.group_of(str(p["role"]))
			if CtrlRoles.DATA_GROUPS.has(g):
				return str(p["role"])
	return ""


static func _junction_kind(model: GraphModel, id: String) -> String:
	var it := model.get_item(id)
	var sp: Dictionary = it.get("specs", {})
	if bool(sp.get("fuse", false)):
		return "fuse"
	if bool(sp.get("switch", false)):
		return "switch"
	if bool(sp.get("busbar", false)):
		return "busbar"
	if bool(sp.get("shunt", false)):
		return "shunt"
	var ty := str(it.get("type", "breaker"))
	if ty == "combiner" and bool(sp.get("distributor", false)):
		return "distributor"
	return ty if SIZE.has(ty) else "breaker"


static func _box_size(model: GraphModel, id: String, kind: String) -> Vector2:
	if kind == "controller":
		var face := _controller_face(model, id)
		if not face.is_empty():
			return (face["bounds"] as Rect2).size
	return SIZE.get(kind, SIZE["breaker"])


static func _device(model: GraphModel, id: String, kind: String, origin: Vector2, places: Dictionary) -> Dictionary:
	if places.has(id) and places[id] is Vector2:
		origin = places[id]
	var it := model.get_item(id)
	var sp: Dictionary = it.get("specs", {})
	var nm := str(sp.get("name", it.get("label", "")))
	if nm.is_empty():
		nm = str(it.get("label", id))
	var symbol := {"kind": kind, "caption": "", "state": ""}
	var sz: Vector2 = SIZE.get(kind, SIZE["breaker"])
	var ports: Array = []
	if kind == "controller":
		var face := _controller_face(model, id)
		if not face.is_empty():
			var shifted := _shift_face(face, origin)
			var bb: Rect2 = shifted["bounds"]
			sz = bb.size
			symbol = {"kind": "face", "caption": "", "state": "", "face": shifted}
			ports = _face_ports(shifted)
	elif kind == "panels":
		symbol["caption"] = _panel_caption(model, id)
	elif kind == "battery":
		symbol["caption"] = _battery_caption(sp)
	elif kind == "fuse" or kind == "breaker":
		symbol["caption"] = _protection_caption(sp, kind)
		symbol["state"] = _protection_state(sp, kind)
	elif kind == "switch":
		symbol["caption"] = "Switch"
		symbol["state"] = "" if bool(sp.get("closed", true)) else "Open"
	elif kind == "busbar":
		symbol["caption"] = "Bus"
	elif kind == "distributor":
		symbol["caption"] = "Distributor"
	elif kind == "shunt":
		symbol["caption"] = "Shunt"
	var box := Rect2(origin, sz)
	if ports.is_empty():
		ports = _ports(kind, box)
	return {"id": id, "kind": kind, "name": nm, "box": box, "ports": ports, "symbol": symbol}


## The solved front face, in the face's own frame, or {} when this controller
## has no design. A stored spec wins, then the preset it was placed from,
## then the library unit with its label or its name.
static func _controller_face(model: GraphModel, id: String) -> Dictionary:
	var spec := _controller_spec(model, id)
	if spec.is_empty():
		return {}
	var d := CtrlDesign.solve(spec)
	var faces: Dictionary = d.get("faces", {})
	if not faces.has("front"):
		return {}
	var lay := CtrlSheet.layout(d, "front")
	return lay if not lay.is_empty() else {}


static func _controller_spec(model: GraphModel, id: String) -> Dictionary:
	var it := model.get_item(id)
	if it.is_empty():
		return {}
	var sp: Dictionary = it.get("specs", {})
	if sp.get("controller_spec") is Dictionary:
		return (sp["controller_spec"] as Dictionary).duplicate(true)
	var preset := str(sp.get("controller_preset", ""))
	if preset != "":
		var pre := CtrlPresets.builtin(preset)
		if not pre.is_empty():
			return pre
	for nm in [str(it.get("label", "")), str(sp.get("name", ""))]:
		var lib := CtrlPresets.for_library_label(nm)
		if lib.is_empty():
			lib = CtrlPresets.for_name(nm)
		if not lib.is_empty():
			return lib
	return {}


static func _shift_face(face: Dictionary, origin: Vector2) -> Dictionary:
	var bb: Rect2 = face["bounds"]
	return _offset_face(face, origin - bb.position)


static func _offset_face(face: Dictionary, d: Vector2) -> Dictionary:
	var f := face.duplicate(true)
	f["rect"] = _shift_rect(f["rect"], d)
	if bool(f.get("has_bay", false)):
		f["bay"] = _shift_rect(f["bay"], d)
	f["bounds"] = _shift_rect(f["bounds"], d)
	for p in (f["ports"] as Array):
		var corners: Array = []
		for v in (p["corners"] as Array):
			corners.append((v as Vector2) + d)
		p["corners"] = corners
		p["centre"] = (p["centre"] as Vector2) + d
		for pin in (p["pins"] as Array):
			pin["pos"] = (pin["pos"] as Vector2) + d
	for ld in (f["leads"] as Array):
		var pts: Array = []
		for v2 in (ld["pts"] as Array):
			pts.append((v2 as Vector2) + d)
		ld["pts"] = pts
		ld["end"] = (ld["end"] as Vector2) + d
	return f


static func _shift_rect(r: Rect2, d: Vector2) -> Rect2:
	return Rect2(r.position + d, r.size)


## A port at each lead the graph has a handle for. The cable leaves downward,
## the way the face lead already runs.
static func _face_ports(face: Dictionary) -> Array:
	var out: Array = []
	var used := {}
	for ld in (face["leads"] as Array):
		var handle := CtrlRoles.handle_for(str(ld["role"]))
		if handle.is_empty() or used.has(handle):
			continue
		used[handle] = true
		out.append({
			"id": handle, "handle": handle, "side": "bottom", "role": str(ld["role"]),
			"pos": ld["end"], "dir": Vector2.DOWN,
		})
	return out


static func _panel_caption(model: GraphModel, id: String) -> String:
	var n := maxi(_string_members(model, id).size(), 1)
	var sp: Dictionary = model.get_item(id).get("specs", {})
	var w := float(sp.get("wmp", sp.get("watts", 0.0))) * float(n)
	var cap := "%dS × %dP" % [n, 1]
	if w > 0.0:
		cap += " · %d W" % int(round(w))
	return cap


static func _battery_caption(sp: Dictionary) -> String:
	var parts: PackedStringArray = []
	var v := float(sp.get("voltage", 0.0))
	var ah := float(sp.get("ah", 0.0))
	if v > 0.0:
		parts.append("%s V" % _n(v))
	if ah > 0.0:
		parts.append("%s Ah" % _n(ah))
	return " · ".join(parts)


static func _protection_caption(sp: Dictionary, kind: String) -> String:
	var a := float(sp.get("rating_a", 0.0))
	if a > 0.0:
		return "%s A" % _n(a)
	return "Fuse" if kind == "fuse" else "Breaker"


static func _protection_state(sp: Dictionary, kind: String) -> String:
	if not bool(sp.get("tripped", false)):
		return ""
	return "Blown" if bool(sp.get("fuse", false)) or kind == "fuse" else "Tripped"


static func _ports(kind: String, box: Rect2) -> Array:
	var out: Array = []
	match kind:
		"panels":
			out.append(_port("positive", "right", "+", box, "pv1+"))
			out.append(_port("negative", "right", "-", box, "pv1-"))
		"controller":
			out.append(_port("pvPositive", "left", "+", box, "pv1+"))
			out.append(_port("pvNegative", "left", "-", box, "pv1-"))
			out.append(_port("batteryPositive", "right", "+", box, "bat+"))
			out.append(_port("batteryNegative", "right", "-", box, "bat-"))
		"battery":
			out.append(_port("positive", "left", "+", box, "bat+"))
			out.append(_port("negative", "left", "-", box, "bat-"))
		_:
			out.append(_port("input", "left", "0", box, "bat+"))
			out.append(_port("output", "right", "0", box, "bat+"))
			if kind == "combiner" or kind == "distributor":
				out.append(_port("input1", "left", "+", box, "pv1+"))
				out.append(_port("input2", "left", "0", box, "pv1+"))
				out.append(_port("input3", "left", "-", box, "pv1-"))
	return out


static func _port(handle: String, side: String, pole: String, box: Rect2, role: String) -> Dictionary:
	var c := box.get_center()
	var dy := 0.0 if pole == "0" else (PORT_DY if pole == "+" else -PORT_DY)
	var y := c.y + dy
	var x := box.position.x if side == "left" else box.end.x
	var dir := Vector2.LEFT if side == "left" else Vector2.RIGHT
	return {"id": handle, "handle": handle, "side": side, "role": role, "pos": Vector2(x, y), "dir": dir}


# ---------------------------------------------------------------------------
# Conductors
# ---------------------------------------------------------------------------

static func _conductors(model: GraphModel, chain: Dictionary, by_id: Dictionary, show_data: bool = false) -> Array:
	var out: Array = []
	for c in model.connections:
		var cd: Dictionary = c
		var pol := str(cd.get("polarity", ""))
		if pol == "ac" or (pol == "data" and not show_data):
			continue
		var sa := _sheet_id(model, str(cd.get("source_item_id", "")), by_id)
		var sb := _sheet_id(model, str(cd.get("target_item_id", "")), by_id)
		if sa.is_empty() or sb.is_empty() or sa == sb:
			continue
		var ha := str(cd.get("source_handle_id", ""))
		var hb := str(cd.get("target_handle_id", ""))
		var da: Dictionary = by_id[sa]
		var db: Dictionary = by_id[sb]
		var pa := _find_port(da, ha)
		var pb := _find_port(db, hb)
		if pa.is_empty() or pb.is_empty():
			continue
		if pol == "data":
			var drole := _data_role(da, ha)
			if drole.is_empty():
				drole = _data_role(db, hb)
			if drole.is_empty():
				drole = "rs485"
			var dlen := _data_length_m(cd)
			var dpts := _route(pa["pos"], pa["dir"], pb["pos"], pb["dir"])
			out.append({
				"id": str(cd.get("id", "")), "a": sa, "ha": ha, "b": sb, "hb": hb,
				"polarity": "data", "role": drole, "pv": false,
				"color": CtrlSheet.wire_color(drole),
				"gauge": "", "mm2": 0.0, "amps": 0.0, "volts": 0.0,
				"length_m": dlen, "drop_pct": 0.0, "upsized": false,
				"label": CtrlSheet.short(drole), "pts": dpts,
			})
			continue
		if pol != "positive" and pol != "negative":
			pol = "negative" if _is_negative(ha) or _is_negative(hb) else "positive"
		var pv := str(da["kind"]) == "panels" or str(db["kind"]) == "panels" or ha.begins_with("pv") or hb.begins_with("pv")
		var role := _role(pol, pv, ha, hb)
		var amps := 0.0
		var volts := 12.0
		var length := _length_m(cd, pv)
		if pv:
			var panel := _panel_item(model, str(cd.get("source_item_id", "")), str(cd.get("target_item_id", "")))
			amps = _string_isc(model, panel)
			volts = _string_vmp(model, panel)
		else:
			amps = _charge_amps(model, str(chain["controller"]))
			volts = _bat_volts(model, str(chain["battery"]))
		var sized := size_run(amps, volts, length)
		var pts := _route(pa["pos"], pa["dir"], pb["pos"], pb["dir"])
		out.append({
			"id": str(cd.get("id", "")), "a": sa, "ha": ha, "b": sb, "hb": hb,
			"polarity": pol, "role": role, "pv": pv,
			"color": CtrlSheet.wire_color(role),
			"gauge": sized["gauge"], "mm2": sized["mm2"], "amps": amps, "volts": volts,
			"length_m": length, "drop_pct": sized["drop_pct"], "upsized": sized["upsized"],
			"label": str(sized["gauge"]), "pts": pts,
		})
	return out


static func _sheet_id(model: GraphModel, item_id: String, by_id: Dictionary) -> String:
	if by_id.has(item_id):
		return item_id
	var unit := PowerChain.unit_of(model, item_id)
	if by_id.has(unit):
		return unit
	return ""


static func _is_negative(handle: String) -> bool:
	return handle == "negative" or handle.contains("egative") or handle.ends_with("-")


static func _role(pol: String, pv: bool, ha: String, hb: String) -> String:
	if not pv:
		return "bat+" if pol == "positive" else "bat-"
	var h := ha if ha.begins_with("pv") else hb
	var n := ""
	if h.begins_with("pvPositive"):
		n = h.substr(11)
	elif h.begins_with("pvNegative"):
		n = h.substr(11)
	var idx := n if n.is_valid_int() else "1"
	return ("pv%s+" % idx) if pol == "positive" else ("pv%s-" % idx)


static func _find_port(device: Dictionary, handle: String) -> Dictionary:
	for p in (device["ports"] as Array):
		if str(p["handle"]) == handle:
			return p
	if handle.begins_with("input"):
		for p in (device["ports"] as Array):
			if str(p["handle"]) == "input" or str(p["handle"]) == handle:
				return p
	return {}


static func _panel_item(model: GraphModel, a: String, b: String) -> String:
	for id in [a, b]:
		if str(model.get_item(id).get("type", "")) == "panel":
			return id
	return a


static func _string_members(model: GraphModel, panel_id: String) -> Array:
	if panel_id.is_empty():
		return []
	var seen := {panel_id: true}
	var q: Array = [panel_id]
	while not q.is_empty():
		var id := str(q.pop_front())
		for c in model.connections:
			var cd: Dictionary = c
			var other := ""
			if str(cd.get("source_item_id", "")) == id:
				other = str(cd.get("target_item_id", ""))
			elif str(cd.get("target_item_id", "")) == id:
				other = str(cd.get("source_item_id", ""))
			else:
				continue
			if seen.has(other):
				continue
			if str(model.get_item(other).get("type", "")) != "panel":
				continue
			seen[other] = true
			q.append(other)
	return seen.keys()


static func _string_isc(model: GraphModel, panel_id: String) -> float:
	var m := 0.0
	for id in _string_members(model, panel_id):
		var sp: Dictionary = model.get_item(str(id)).get("specs", {})
		m = maxf(m, float(sp.get("isc", sp.get("imp", 0.0))))
	return m


static func _string_vmp(model: GraphModel, panel_id: String) -> float:
	var s := 0.0
	for id in _string_members(model, panel_id):
		var sp: Dictionary = model.get_item(str(id)).get("specs", {})
		var v := float(sp.get("vmp", 0.0))
		if v <= 0.0:
			v = float(sp.get("voc", 0.0))
		s += v
	return s if s > 0.0 else 12.0


static func _charge_amps(model: GraphModel, ctrl_id: String) -> float:
	if ctrl_id.is_empty():
		return 0.0
	var sp: Dictionary = model.get_item(ctrl_id).get("specs", {})
	return float(sp.get("max_charge_amps", 0.0))


static func _bat_volts(model: GraphModel, bat_id: String) -> float:
	if bat_id.is_empty():
		return 12.0
	var sp: Dictionary = model.get_item(bat_id).get("specs", {})
	var v := float(sp.get("voltage", 0.0))
	return v if v > 0.0 else 12.0


const DATA_M := 1.0


static func _data_length_m(conn: Dictionary) -> float:
	var routed := float(conn.get("route_length_m", 0.0))
	if routed > 0.0:
		return routed
	var est := float(conn.get("estimated_length", 0.0))
	if est > 0.0:
		return est
	return DATA_M


static func _length_m(conn: Dictionary, pv: bool) -> float:
	var routed := float(conn.get("route_length_m", 0.0))
	if routed > 0.0:
		return routed
	var est := float(conn.get("estimated_length", 0.0))
	if est > 0.0:
		return est
	return RUN_PV_M if pv else RUN_BAT_M


static func _route(a: Vector2, a_dir: Vector2, b: Vector2, b_dir: Vector2) -> PackedVector2Array:
	var a1 := a + a_dir * STUB_MM
	var b1 := b + b_dir * STUB_MM
	var raw := PackedVector2Array([a, a1])
	if absf(a_dir.x) > 0.5 and absf(b_dir.x) > 0.5:
		var cx := (a1.x + b1.x) * 0.5
		raw.append(Vector2(cx, a1.y))
		raw.append(Vector2(cx, b1.y))
	else:
		raw.append(Vector2(a1.x, b1.y))
	raw.append(b1)
	raw.append(b)
	var out := PackedVector2Array()
	for p in raw:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.05:
			out.append(p)
	return out


static func _has_pole(conductors: Array, device_id: String, handle: String) -> bool:
	for c in conductors:
		var cd: Dictionary = c
		if str(cd["a"]) == device_id and str(cd["ha"]) == handle:
			return true
		if str(cd["b"]) == device_id and str(cd["hb"]) == handle:
			return true
	return false


static func _bounds(devices: Array) -> Rect2:
	var b := Rect2()
	var any := false
	for d in devices:
		var box: Rect2 = d["box"]
		if not any:
			b = box
			any = true
		else:
			b = b.merge(box)
	return b


static func _next_wire(mm2: float) -> Array:
	for w in BattElectrical.WIRES:
		if float(w[1]) > mm2 + 1e-6:
			return w
	return []


# ---------------------------------------------------------------------------
# The page: hit-testing and the SVG (y up → y down)
# ---------------------------------------------------------------------------

const FILL := {
	"panels": Color("#d6e6f5"), "controller": Color("#2a6fad"), "battery": Color("#1d4e89"),
	"fuse": Color("#f4d03f"), "breaker": Color("#e39b2b"), "switch": Color("#d5d8dc"),
	"busbar": Color("#8d9399"), "combiner": Color("#d5d8dc"), "distributor": Color("#b9c0c6"),
	"shunt": Color("#5d6d7e"), "monitor": Color("#d5eef0"),
}
const FILL_INK := {"controller": Color.WHITE, "battery": Color.WHITE}


## The device under a page point (mm, y up), or "".
static func device_at(lay: Dictionary, q: Vector2) -> String:
	var devs: Array = lay.get("devices", [])
	for i in range(devs.size() - 1, -1, -1):
		var d: Dictionary = devs[i]
		if (d["box"] as Rect2).has_point(q):
			return str(d["id"])
	return ""


## Devices, the wire stubs and a margin for the gauge labels.
static func ink_bounds(lay: Dictionary) -> Rect2:
	var b: Rect2 = lay.get("bounds", Rect2())
	var any := b.size.x > 0.0 or b.size.y > 0.0
	for c in (lay.get("conductors", []) as Array):
		var pts: PackedVector2Array = c["pts"]
		for p in pts:
			if not any:
				b = Rect2(p, Vector2.ZERO)
				any = true
			else:
				b = b.expand(p)
	return b.grow(20.0) if any else Rect2()


## The layout as an SVG document (millimetres, y down). The same boxes,
## colours and words the page draws.
static func svg(lay: Dictionary) -> String:
	var b := ink_bounds(lay)
	var checks: Array = lay.get("checks", [])
	var pad := 16.0
	var top := 22.0
	var foot := 8.0 + float(checks.size()) * 8.0
	var w := maxf(b.size.x + pad * 2.0, 120.0)
	var h := top + b.size.y + pad + foot
	var ox := pad - b.position.x
	var oy := top + (b.position.y + b.size.y)
	var o := PackedStringArray()
	o.append('<?xml version="1.0" encoding="UTF-8"?>')
	o.append('<svg xmlns="http://www.w3.org/2000/svg" width="%smm" height="%smm" viewBox="0 0 %s %s" font-family="Inter, Arial, sans-serif">' % [_n(w), _n(h), _n(w), _n(h)])
	o.append('<rect width="%s" height="%s" fill="#ffffff"/>' % [_n(w), _n(h)])
	o.append('<text x="%s" y="14" font-size="6" font-weight="600" fill="#1a1a1a">Wiring diagram</text>' % _n(pad))
	for c in (lay.get("conductors", []) as Array):
		var cd: Dictionary = c
		var pts := PackedStringArray()
		var mid := Vector2.ZERO
		var wire: PackedVector2Array = cd["pts"]
		for p in wire:
			pts.append("%s,%s" % [_n(ox + p.x), _n(oy - p.y)])
			mid += p
		if wire.size() > 0:
			mid /= float(wire.size())
		var col: Color = cd["color"]
		var sw := 2.6 if str(cd.get("gauge", "")).begins_with("6 ") or str(cd.get("gauge", "")).begins_with("4 ") else 1.8
		o.append('<polyline points="%s" fill="none" stroke="#ffffff" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>' % [" ".join(pts), _n(sw + 2.4)])
		o.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>' % [" ".join(pts), _hex(col), _n(sw)])
		var label := "%s · %.1f m" % [str(cd["label"]), float(cd["length_m"])]
		o.append('<text x="%s" y="%s" font-size="3.4" fill="%s" stroke="#ffffff" stroke-width="1.1" paint-order="stroke">%s</text>' % [
			_n(ox + mid.x + 4.0), _n(oy - (mid.y + 5.0)), _hex(col.darkened(0.35)), _esc(label)])
	for d in (lay.get("devices", []) as Array):
		o.append(_device_svg(d, ox, oy))
	var cy := top + b.size.y + pad + 6.0
	for ck in checks:
		var lv := str(ck.get("level", "warn"))
		var cc := Color("#b45309") if lv == "warn" else (Color("#b91c1c") if lv == "error" else Color("#334155"))
		o.append('<text x="%s" y="%s" font-size="3.6" fill="%s">%s</text>' % [_n(pad), _n(cy), _hex(cc), _esc(str(ck["text"]))])
		cy += 8.0
	o.append('</svg>')
	return "\n".join(o)


static func _device_svg(d: Dictionary, ox: float, oy: float) -> String:
	var box: Rect2 = d["box"]
	var kind := str(d["kind"])
	var sym: Dictionary = d.get("symbol", {})
	var o := PackedStringArray()
	o.append('<g id="dev_%s">' % _esc(str(d["id"])))
	if str(sym.get("kind", "")) == "face":
		o.append(CtrlSheet.face_svg(sym["face"], ox, oy))
		o.append('<text x="%s" y="%s" font-size="4.2" font-weight="600" text-anchor="middle" fill="#1a1a1a">%s</text>' % [
			_n(ox + box.get_center().x), _n(oy - box.end.y + 5.0), _esc(str(d["name"]))])
	else:
		o.append(_symbol_svg(kind, box, sym, d, ox, oy))
	o.append('</g>')
	return "\n".join(o)


static func _symbol_svg(kind: String, box: Rect2, sym: Dictionary, d: Dictionary, ox: float, oy: float) -> String:
	var x := ox + box.position.x
	var y := oy - box.end.y
	var w := box.size.x
	var h := box.size.y
	var name := _esc(str(d["name"]))
	var cap := _esc(str(sym.get("caption", "")))
	var state := _esc(str(sym.get("state", "")))
	var o := PackedStringArray()
	if kind == "panels":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#d5d8de" stroke="#8e95a0" stroke-width="0.6"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#163e78"/>' % [_n(x + 4.0), _n(y + 4.0), _n(w - 8.0), _n(h - 16.0)])
		o.append(_module_grid_svg(box, ox, oy))
		o.append('<text x="%s" y="%s" font-size="4.2" font-weight="600" text-anchor="middle" fill="#ffffff">%s</text>' % [_n(x + w * 0.5), _n(y + 12.0), cap])
		o.append('<text x="%s" y="%s" font-size="3.4" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + h - 3.0), name])
	elif kind == "battery":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#0c4c9a" stroke="#08356e" stroke-width="0.7"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#e4570e"/>' % [_n(x), _n(y), _n(w), _n(maxf(h * 0.08, 3.0))])
		o.append('<text x="%s" y="%s" font-size="4.2" font-weight="600" text-anchor="middle" fill="#ffffff">%s</text>' % [_n(x + w * 0.5), _n(y + 14.0), name])
		o.append('<text x="%s" y="%s" font-size="3.6" text-anchor="middle" fill="#ffffff">%s</text>' % [_n(x + w * 0.5), _n(y + 20.0), cap])
		for p in (d["ports"] as Array):
			var pp: Vector2 = p["pos"]
			o.append('<circle cx="%s" cy="%s" r="3.2" fill="#8a7340"/><circle cx="%s" cy="%s" r="2.1" fill="#c6a15a"/>' % [
				_n(ox + pp.x), _n(oy - pp.y), _n(ox + pp.x), _n(oy - pp.y)])
	elif kind == "fuse":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#8d9399"/>' % [_n(x), _n(y), _n(w * 0.16), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#8d9399"/>' % [_n(x + w * 0.84), _n(y), _n(w * 0.16), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#f4d03f" stroke="#b7950b" stroke-width="0.4"/>' % [
			_n(x + w * 0.16), _n(y + h * 0.12), _n(w * 0.68), _n(h * 0.76)])
		o.append('<text x="%s" y="%s" font-size="4" font-weight="600" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + h * 0.55), cap if cap != "" else name])
	elif kind == "busbar":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#b87333" stroke="#7a4e22" stroke-width="0.5"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<text x="%s" y="%s" font-size="3.4" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y - 1.5), name])
	else:
		var fill := "#3a414a" if kind == "distributor" or kind == "shunt" or kind == "breaker" else ("#0c4c9a" if kind == "monitor" else "#e6e8eb")
		var ink := "#ffffff" if fill != "#e6e8eb" else "#1c2430"
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="%s" stroke="#1c2430" stroke-width="0.5"/>' % [_n(x), _n(y), _n(w), _n(h), fill])
		o.append('<text x="%s" y="%s" font-size="4" text-anchor="middle" fill="%s">%s</text>' % [_n(x + w * 0.5), _n(y + h * 0.48), ink, name])
		if cap != "":
			o.append('<text x="%s" y="%s" font-size="3.4" text-anchor="middle" fill="%s">%s</text>' % [_n(x + w * 0.5), _n(y + h * 0.72), ink, cap])
	if state != "":
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#b91c1c">%s</text>' % [_n(x + w * 0.5), _n(y + h - 2.0), state])
	return "\n".join(o)


static func _module_grid_svg(box: Rect2, ox: float, oy: float) -> String:
	var inset := 8.0
	if box.size.x < inset * 3.0 or box.size.y < inset * 3.0:
		return ""
	var r := Rect2(box.position + Vector2(inset, inset), box.size - Vector2(inset * 2.0, inset * 2.0))
	var o := PackedStringArray()
	var cols := 6
	var rows := 10
	for i in range(1, cols):
		var x := r.position.x + r.size.x * float(i) / float(cols)
		o.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#8fb4e0" stroke-width="0.3"/>' % [
			_n(ox + x), _n(oy - r.end.y), _n(ox + x), _n(oy - r.position.y)])
	for j in range(1, rows):
		var y := r.position.y + r.size.y * float(j) / float(rows)
		o.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#8fb4e0" stroke-width="0.3"/>' % [
			_n(ox + r.position.x), _n(oy - y), _n(ox + r.end.x), _n(oy - y)])
	return "\n".join(o)


static func _n(v: float) -> String:
	return ("%.2f" % v).rstrip("0").rstrip(".")


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func _esc(t: String) -> String:
	return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

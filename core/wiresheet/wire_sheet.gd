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
	"breaker": Vector2(58, 44),
	"fuse": Vector2(70, 36),
	"switch": Vector2(60, 44),
	"busbar": Vector2(120, 24),
	"combiner": Vector2(100, 44),
	"distributor": Vector2(150, 44),
	"shunt": Vector2(76, 36),
	"monitor": Vector2(110, 70),
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
	var trough := _lanes_and_routes(devices, conductors, chain)
	var checks: Array = PowerChain.checks(model, chain["power"])
	var bat := str(chain["battery"])
	if not bat.is_empty() and _has_pole(conductors, bat, "positive"):
		if not bool(chain["fused_positive"]):
			checks.append({
				"level": "warn", "code": "no_fuse", "link": "battery",
				"text": "Battery: no fuse on the positive.",
				"why": "A short across the bank is limited only by the cable until a fuse opens. Put one on the positive, close to the battery.",
			})
	return {"devices": devices, "conductors": conductors, "checks": checks, "bounds": _bounds(devices),
		"lanes": trough["lanes"], "trough_top": trough["trough_top"]}


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
# Placement: a shelf and a wiring trough
# ---------------------------------------------------------------------------
#
# Everything that makes or stores power stands on one shelf (its feet at
# y = 0): the modules in a row, the controller's face, the battery. Cables
# hang DOWN from them into a trough of horizontal lanes below the shelf, run
# along a lane, and climb to where they land — the way a wall of gear is
# wired in practice, and the way the maker's diagrams draw it. A fuse, a
# switch, a shunt or a bus stands IN its lane, so the lane runs straight
# through it. The battery's studs are on its lid: a cable comes up beside
# the case and over to its stud. Comms monitors sit under the trough.
#
# Lanes are handed out first-fit from the top: runs whose x-spans do not
# overlap share a lane; PV runs come before battery runs, and inside a side
# the run that would otherwise be crossed goes higher (see _lanes_and_routes).

## The page is y UP (millimetres on paper), so these are the page's own
## up and down — Godot's Vector2.DOWN is (0, 1) and would point into a device.
const DOWN := Vector2(0, -1)
const UP := Vector2(0, 1)
const PIGTAIL_MM := 22.0        ## a module's leads hang this far under its frame
const ARRAY_LANE_DY := 30.0     ## the series jumpers run this far under the pigtails (their chips clear the nameplates)
const TROUGH_GAP := 36.0        ## between the lowest hanging lead and the first lane
const LANE_PITCH := 52.0
const INLINE_GAP := 22.0        ## between two in-line devices on one lane
const RISE_MM := 26.0           ## a battery cable climbs this far off the case
const STUD_IN_MM := 34.0        ## a stud from the battery's end
const PANEL_GAP := 24.0
const MONITOR_GAP := 26.0


static func _place(model: GraphModel, chain: Dictionary, places: Dictionary) -> Array:
	var power: Dictionary = chain["power"]
	var arrays: Array = _ordered_arrays(model, power["arrays"])
	var out: Array = []
	var x := 0.0
	for a in arrays:
		var dev := _device(model, str(a["id"]), "panels", Vector2(x, 0.0), places)
		out.append(dev)
		x += SIZE["panels"].x + PANEL_GAP
	if not arrays.is_empty():
		x += GAP_X - PANEL_GAP
	var ctrl := str(chain["controller"])
	if not ctrl.is_empty():
		var face := _controller_face(model, ctrl)
		var origin := Vector2(x, 0.0)
		if not face.is_empty():
			var bb: Rect2 = face["bounds"]
			var r: Rect2 = face["rect"]
			origin.y = bb.position.y - r.position.y
		var cdev := _device(model, ctrl, "controller", origin, places)
		out.append(cdev)
		x += (cdev["box"] as Rect2).size.x + GAP_X
	# In-line devices stand in the trough between the controller and the
	# battery; their lane (y) is set once the lanes are known.
	var x_row := x
	var far := x
	for lst in [chain["pos_junctions"], chain["neg_junctions"]]:
		var xr := x_row
		var seen := {}
		for d in out:
			seen[str(d["id"])] = true
		for jid in (lst as Array):
			var id := str(jid)
			if seen.has(id):
				continue
			var kind := _junction_kind(model, id)
			var sz: Vector2 = SIZE.get(kind, SIZE["breaker"])
			var dev2 := _device(model, id, kind, Vector2(xr, -sz.y * 0.5), places)
			dev2["inline"] = true
			out.append(dev2)
			xr += sz.x + INLINE_GAP
			far = maxf(far, xr)
	if far > x_row:
		x = far - INLINE_GAP + GAP_X
	var bat := str(chain["battery"])
	if not bat.is_empty():
		out.append(_device(model, bat, "battery", Vector2(x, 0.0), places))
	return out


## The arrays in series order: the one whose positive is free (or wired to
## the controller) first, then each one's negative neighbour.
static func _ordered_arrays(model: GraphModel, arrays: Array) -> Array:
	if arrays.size() < 2:
		return arrays
	var ids: Array = []
	var by := {}
	for a in arrays:
		ids.append(str(a["id"]))
		by[str(a["id"])] = a
	var next := {}
	var has_prev := {}
	for c in model.connections:
		var cd: Dictionary = c
		var sa := PowerChain.unit_of(model, str(cd.get("source_item_id", "")))
		var sb := PowerChain.unit_of(model, str(cd.get("target_item_id", "")))
		if not by.has(sa) or not by.has(sb) or sa == sb:
			continue
		var ha := str(cd.get("source_handle_id", ""))
		var hb := str(cd.get("target_handle_id", ""))
		# A series link runs from one module's negative to the next's positive.
		if _is_negative(ha) and not _is_negative(hb):
			next[sa] = sb
			has_prev[sb] = true
		elif _is_negative(hb) and not _is_negative(ha):
			next[sb] = sa
			has_prev[sa] = true
	var out: Array = []
	var placed := {}
	for id in ids:
		if has_prev.has(id):
			continue
		var cur := str(id)
		while cur != "" and not placed.has(cur):
			placed[cur] = true
			out.append(by[cur])
			cur = str(next.get(cur, ""))
	for id2 in ids:
		if not placed.has(id2):
			out.append(by[id2])
	return out


## A comms peer that is not already on the power page, sat under the
## trough. Both ends of a data run get a data port if they did not have one.
static func _add_monitors(model: GraphModel, devices: Array, places: Dictionary) -> void:
	var by := {}
	for d in devices:
		by[str(d["id"])] = d
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
		var dev := _device(model, other, "monitor", Vector2(x, 0.0), places)
		dev["monitor"] = true
		(dev["symbol"] as Dictionary)["caption"] = CtrlSheet.short(role)
		devices.append(dev)
		by[other] = dev
		x += SIZE["monitor"].x + 16.0


## A data port on a device that had none: a lead hanging under it.
static func _ensure_data_port(device: Dictionary) -> void:
	for p in (device["ports"] as Array):
		if str(p["handle"]) == "data":
			return
	var box: Rect2 = device["box"]
	var kind := str(device["kind"])
	var at := Vector2(box.get_center().x, box.position.y)
	if kind == "battery":
		at = Vector2(box.end.x - STUD_IN_MM * 2.0, box.end.y)
		(device["ports"] as Array).append({"id": "data", "handle": "data", "side": "top", "role": "rs485",
			"pos": at, "dir": UP, "via": [at + Vector2(0, RISE_MM * 0.6), Vector2(box.end.x + RISE_MM * 1.8, at.y + RISE_MM * 0.6)]})
		return
	(device["ports"] as Array).append({"id": "data", "handle": "data", "side": "bottom", "role": "rs485",
		"pos": at, "dir": DOWN, "via": []})


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


static func _device(model: GraphModel, id: String, kind: String, origin: Vector2, places: Dictionary) -> Dictionary:
	if places.has(id) and places[id] is Vector2:
		origin = places[id]
	var it := model.get_item(id)
	var sp: Dictionary = it.get("specs", {})
	var nm := str(sp.get("name", it.get("label", "")))
	if nm.is_empty():
		nm = str(it.get("label", id))
	var symbol := {"kind": kind, "caption": "", "state": "", "module": ""}
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
		symbol["module"] = _module_caption(sp)
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
	return {"id": id, "kind": kind, "name": nm, "box": box, "ports": ports, "symbol": symbol, "placed": places.has(id)}


## Move a device's box and its ports together.
static func _move_device(dev: Dictionary, origin: Vector2) -> void:
	var box: Rect2 = dev["box"]
	var d := origin - box.position
	if d.length() < 0.001:
		return
	dev["box"] = Rect2(origin, box.size)
	for p in (dev["ports"] as Array):
		p["pos"] = (p["pos"] as Vector2) + d
		var via: Array = []
		for v in (p.get("via", []) as Array):
			via.append((v as Vector2) + d)
		p["via"] = via
	var sym: Dictionary = dev["symbol"]
	if str(sym.get("kind", "")) == "face":
		sym["face"] = _offset_face(sym["face"], d)


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
			"pos": ld["end"], "dir": DOWN, "via": [],
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


## One module's own nameplate: "300 W · 40 Voc".
static func _module_caption(sp: Dictionary) -> String:
	var parts: PackedStringArray = []
	var w := float(sp.get("wmp", sp.get("watts", 0.0)))
	var voc := float(sp.get("voc", 0.0))
	if w > 0.0:
		parts.append("%d W" % int(round(w)))
	if voc > 0.0:
		parts.append("%s Voc" % _n(voc))
	return " · ".join(parts)


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


## Where a device's cables leave it, and the way they go. A port is
## {id, handle, side, role, pos, dir, via}: `via` are the points a cable
## passes after `pos` before it heads straight for its lane (a battery
## cable climbs off the lid and over to the side of the case).
static func _ports(kind: String, box: Rect2) -> Array:
	var out: Array = []
	var c := box.get_center()
	match kind:
		"panels":
			var y := box.position.y - PIGTAIL_MM
			out.append(_port("positive", "bottom", Vector2(c.x - 18.0, y), DOWN, "pv1+"))
			out.append(_port("negative", "bottom", Vector2(c.x + 18.0, y), DOWN, "pv1-"))
		"controller":
			out.append(_port("pvPositive", "left", Vector2(box.position.x, c.y + PORT_DY), Vector2.LEFT, "pv1+", true))
			out.append(_port("pvNegative", "left", Vector2(box.position.x, c.y - PORT_DY), Vector2.LEFT, "pv1-", true))
			out.append(_port("batteryPositive", "right", Vector2(box.end.x, c.y + PORT_DY), Vector2.RIGHT, "bat+", true))
			out.append(_port("batteryNegative", "right", Vector2(box.end.x, c.y - PORT_DY), Vector2.RIGHT, "bat-", true))
		"battery":
			# − on the left, + on the right: the negative climbs the left side, the
			# positive the right, so neither crosses the other's lane run.
			var top := box.end.y
			var neg := Vector2(box.position.x + STUD_IN_MM, top)
			var pos := Vector2(box.end.x - STUD_IN_MM, top)
			var over := top + RISE_MM
			out.append({"id": "positive", "handle": "positive", "side": "top", "role": "bat+", "pos": pos, "dir": UP,
				"via": [Vector2(pos.x, over), Vector2(box.end.x + RISE_MM, over)]})
			out.append({"id": "negative", "handle": "negative", "side": "top", "role": "bat-", "pos": neg, "dir": UP,
				"via": [Vector2(neg.x, over), Vector2(box.position.x - RISE_MM, over)]})
		"monitor":
			out.append(_port("data", "top", Vector2(c.x, box.end.y), UP, "rs485"))
		_:
			out.append(_port("input", "left", Vector2(box.position.x, c.y), Vector2.LEFT, "bat+", true))
			out.append(_port("output", "right", Vector2(box.end.x, c.y), Vector2.RIGHT, "bat+", true))
			if kind == "combiner" or kind == "distributor":
				var step := minf(14.0, box.size.y * 0.3)
				out.append(_port("input1", "left", Vector2(box.position.x, c.y + step), Vector2.LEFT, "pv1+", true))
				out.append(_port("input2", "left", Vector2(box.position.x, c.y), Vector2.LEFT, "pv1+", true))
				out.append(_port("input3", "left", Vector2(box.position.x, c.y - step), Vector2.LEFT, "pv1-", true))
			if kind == "shunt":
				out.append(_port("data", "bottom", Vector2(c.x, box.position.y), DOWN, "rs485"))
	return out


static func _port(handle: String, side: String, pos: Vector2, dir: Vector2, role: String, stub: bool = false) -> Dictionary:
	var via: Array = []
	if stub:
		via.append(pos + dir * STUB_MM)
	return {"id": handle, "handle": handle, "side": side, "role": role, "pos": pos, "dir": dir, "via": via}


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
			out.append({
				"id": str(cd.get("id", "")), "a": sa, "ha": ha, "b": sb, "hb": hb,
				"polarity": "data", "role": drole, "pv": false,
				"color": CtrlSheet.wire_color(drole),
				"gauge": "", "mm2": 0.0, "amps": 0.0, "volts": 0.0,
				"length_m": dlen, "drop_pct": 0.0, "upsized": false,
				"label": CtrlSheet.short(drole), "pts": PackedVector2Array(),
				"group": "data|" + str(cd.get("id", "")), "lane": -1,
			})
			continue
		if pol != "positive" and pol != "negative":
			pol = "negative" if _is_negative(ha) or _is_negative(hb) else "positive"
		var pv := str(da["kind"]) == "panels" or str(db["kind"]) == "panels" or ha.begins_with("pv") or hb.begins_with("pv")
		var role := _role(pol, pv, ha, hb)
		var amps := 0.0
		var volts := 12.0
		var length := _length_m(cd, pv)
		var group := ""
		if pv:
			var panel := _panel_item(model, str(cd.get("source_item_id", "")), str(cd.get("target_item_id", "")))
			amps = _string_isc(model, panel)
			volts = _string_vmp(model, panel)
			if str(da["kind"]) == "panels" and str(db["kind"]) == "panels":
				group = "array"
			else:
				group = "pv|%s|%s" % [_string_root(model, panel), pol]
		else:
			amps = _charge_amps(model, str(chain["controller"]))
			volts = _bat_volts(model, str(chain["battery"]))
			group = "bat|" + pol
		var sized := size_run(amps, volts, length)
		out.append({
			"id": str(cd.get("id", "")), "a": sa, "ha": ha, "b": sb, "hb": hb,
			"polarity": pol, "role": role, "pv": pv,
			"color": CtrlSheet.wire_color(role),
			"gauge": sized["gauge"], "mm2": sized["mm2"], "amps": amps, "volts": volts,
			"length_m": length, "drop_pct": sized["drop_pct"], "upsized": sized["upsized"],
			"label": str(sized["gauge"]), "pts": PackedVector2Array(),
			"group": group, "lane": -1,
		})
	return out


## The lowest member id of a string, so both poles of one string share a key.
static func _string_root(model: GraphModel, panel_id: String) -> String:
	var ids := _string_members(model, panel_id)
	ids.sort()
	return str(ids[0]) if not ids.is_empty() else panel_id


## Lanes for every trough run, in-line devices moved onto their lane,
## monitors under the trough, then every conductor's polyline.
## Returns {lanes: [y…], trough_top}.
static func _lanes_and_routes(devices: Array, conductors: Array, chain: Dictionary) -> Dictionary:
	var by_id := {}
	for d in devices:
		by_id[str(d["id"])] = d
	# The trough starts under the lowest hanging lead of a device on the shelf.
	var low := 0.0
	var any := false
	for d in devices:
		if bool(d.get("inline", false)) or bool(d.get("monitor", false)):
			continue
		for p in (d["ports"] as Array):
			if (p["dir"] as Vector2).y < -0.5:
				low = minf(low, (p["pos"] as Vector2).y) if any else (p["pos"] as Vector2).y
				any = true
	var trough_top := (low if any else 0.0) - TROUGH_GAP
	var array_y := -(PIGTAIL_MM + ARRAY_LANE_DY)
	# Group runs: a group is one lane's worth (both ends of a string's pole,
	# every segment of the battery positive through its fuses).
	var groups := {}
	for c in conductors:
		var g := str(c["group"])
		if g == "array":
			continue
		if not groups.has(g):
			groups[g] = {"key": g, "x0": INF, "x1": -INF, "lead_x": 0.0, "n": 0}
		var gr: Dictionary = groups[g]
		for end in [[c["a"], c["ha"]], [c["b"], c["hb"]]]:
			var dev: Dictionary = by_id[str(end[0])]
			var port := _find_port(dev, str(end[1]))
			if port.is_empty():
				continue
			var xs := _port_lane_x(port)
			gr["x0"] = minf(float(gr["x0"]), xs)
			gr["x1"] = maxf(float(gr["x1"]), xs)
			if str(dev["kind"]) == "controller":
				gr["lead_x"] = xs
	# Order: PV groups by their controller lead from the left (the run whose
	# lead is further left must sit higher or the other's climb crosses it),
	# then battery groups from the right, then data; first-fit from the top.
	var order: Array = groups.values()
	order.sort_custom(func(a, b) -> bool:
		var ka := _group_rank(str(a["key"]))
		var kb := _group_rank(str(b["key"]))
		if ka != kb:
			return ka < kb
		if ka == 0:
			return float(a["lead_x"]) < float(b["lead_x"])
		if ka == 1:
			return float(a["lead_x"]) > float(b["lead_x"])
		return str(a["key"]) < str(b["key"]))
	var lanes: Array = []   # each: [[x0, x1], …] occupied spans
	var lane_of := {}
	var first_data := -1
	for gr in order:
		var span := [float(gr["x0"]) - INLINE_GAP, float(gr["x1"]) + INLINE_GAP]
		var k := 0
		if _group_rank(str(gr["key"])) == 2:
			if first_data < 0:
				first_data = lanes.size()
			k = first_data
		while true:
			if k >= lanes.size():
				lanes.append([span])
				break
			var free := true
			for s in (lanes[k] as Array):
				if float(span[0]) < float(s[1]) and float(s[0]) < float(span[1]):
					free = false
					break
			if free:
				(lanes[k] as Array).append(span)
				break
			k += 1
		lane_of[str(gr["key"])] = k
	var ys: Array = []
	for i in lanes.size():
		ys.append(trough_top - (float(i) + 0.5) * LANE_PITCH)
	# In-line devices onto their lane; monitors under the last lane.
	var floor_y := trough_top - float(lanes.size()) * LANE_PITCH
	var pos_j: Array = chain.get("pos_junctions", [])
	for d in devices:
		if bool(d.get("inline", false)) and not bool(d.get("placed", false)):
			var pol := "positive" if pos_j.has(str(d["id"])) else "negative"
			var k2 := int(lane_of.get("bat|" + pol, -1))
			if k2 >= 0:
				var box: Rect2 = d["box"]
				_move_device(d, Vector2(box.position.x, float(ys[k2]) - box.size.y * 0.5))
		elif bool(d.get("monitor", false)) and not bool(d.get("placed", false)):
			var box2: Rect2 = d["box"]
			_move_device(d, Vector2(box2.position.x, floor_y - MONITOR_GAP - box2.size.y))
	for c in conductors:
		var g := str(c["group"])
		var da: Dictionary = by_id[str(c["a"])]
		var db: Dictionary = by_id[str(c["b"])]
		var pa := _find_port(da, str(c["ha"]))
		var pb := _find_port(db, str(c["hb"]))
		var lane_y := array_y
		if g != "array":
			var k3 := int(lane_of.get(g, 0))
			c["lane"] = k3
			lane_y = float(ys[k3]) if k3 < ys.size() else trough_top - LANE_PITCH * 0.5
		c["pts"] = _route(pa, pb, lane_y)
	return {"lanes": ys, "trough_top": trough_top}


static func _group_rank(key: String) -> int:
	if key.begins_with("pv|"):
		return 0
	if key.begins_with("bat|"):
		return 1
	return 2


## Where a port's cable meets its lane (the last via point's x, else its own).
static func _port_lane_x(port: Dictionary) -> float:
	var via: Array = port.get("via", [])
	if not via.is_empty():
		return (via[via.size() - 1] as Vector2).x
	return (port["pos"] as Vector2).x


## One cable: out of port a along its via points, straight to the lane,
## along the lane, straight to port b's last via point, back along b's via
## points into b. Every leg is horizontal or vertical.
static func _route(pa: Dictionary, pb: Dictionary, lane_y: float) -> PackedVector2Array:
	var raw: Array = [pa["pos"]]
	for v in (pa.get("via", []) as Array):
		raw.append(v)
	var la: Vector2 = raw[raw.size() - 1]
	var bvia: Array = (pb.get("via", []) as Array).duplicate()
	bvia.reverse()
	var lb: Vector2 = bvia[0] if not bvia.is_empty() else pb["pos"]
	raw.append(Vector2(la.x, lane_y))
	raw.append(Vector2(lb.x, lane_y))
	for v2 in bvia:
		raw.append(v2)
	raw.append(pb["pos"])
	var out := PackedVector2Array()
	for p in raw:
		var q: Vector2 = p
		if not out.is_empty():
			var last := out[out.size() - 1]
			if last.distance_to(q) < 0.05:
				continue
			# Drop a collinear middle point.
			if out.size() >= 2:
				var prev := out[out.size() - 2]
				if (absf(prev.x - last.x) < 0.01 and absf(last.x - q.x) < 0.01) \
						or (absf(prev.y - last.y) < 0.01 and absf(last.y - q.y) < 0.01):
					out[out.size() - 1] = q
					continue
		out.append(q)
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


## The corners of an orthogonal polyline rounded by up to `r` mm (never more
## than half the shorter leg), each arc as a few points. What the page and
## the SVG both draw; `pts` stays the square polyline the hit test uses.
static func fillet(pts: PackedVector2Array, r: float, steps: int = 6) -> PackedVector2Array:
	if pts.size() < 3 or r <= 0.01:
		return pts
	var out := PackedVector2Array()
	out.append(pts[0])
	for i in range(1, pts.size() - 1):
		var p := pts[i]
		var a := pts[i - 1]
		var b := pts[i + 1]
		var da := (a - p)
		var db := (b - p)
		var la := da.length()
		var lb := db.length()
		if la < 0.01 or lb < 0.01:
			continue
		var rr := minf(r, minf(la, lb) * 0.5)
		var ua := da / la
		var ub := db / lb
		var p0 := p + ua * rr
		var p1 := p + ub * rr
		out.append(p0)
		for k in range(1, steps):
			var t := float(k) / float(steps)
			# A quadratic bezier through the corner is close enough to a quarter arc here.
			var q := p0.lerp(p, t).lerp(p.lerp(p1, t), t)
			out.append(q)
		out.append(p1)
	out.append(pts[pts.size() - 1])
	return out


## The longest horizontal leg of a run: where its gauge chip goes.
static func label_anchor(pts: PackedVector2Array) -> Dictionary:
	var best_len := -1.0
	var best := Vector2.ZERO
	var horizontal := true
	var length := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var l := a.distance_to(b)
		var horiz := absf(a.y - b.y) < 0.01
		var score := l * (1.0 if horiz else 0.6)
		if score > best_len:
			best_len = score
			best = (a + b) * 0.5
			horizontal = horiz
			length = l
	if pts.size() == 1:
		best = pts[0]
	return {"pos": best, "horizontal": horizontal, "length": length}



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


## The layout as an SVG document (millimetres, y down). The same shelf,
## trough, rounded cables and part symbols the page draws.
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
	o.append('<rect width="%s" height="%s" fill="#f5f6f8"/>' % [_n(w), _n(h)])
	o.append('<text x="%s" y="14" font-size="6" font-weight="600" fill="#1a1a1a">Wiring diagram</text>' % _n(pad))
	# Data leads under the power cables; cables under the gear.
	var ordered: Array = []
	for c in (lay.get("conductors", []) as Array):
		if str((c as Dictionary).get("polarity", "")) == "data":
			ordered.append(c)
	for c2 in (lay.get("conductors", []) as Array):
		if str((c2 as Dictionary).get("polarity", "")) != "data":
			ordered.append(c2)
	for c3 in ordered:
		o.append(_wire_svg(c3, ox, oy))
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


static func _wire_svg(c: Variant, ox: float, oy: float) -> String:
	var cd: Dictionary = c
	var wire: PackedVector2Array = cd["pts"]
	if wire.size() < 2:
		return ""
	var data := str(cd.get("polarity", "")) == "data"
	var pts := PackedStringArray()
	for p in fillet(wire, 14.0):
		pts.append("%s,%s" % [_n(ox + p.x), _n(oy - p.y)])
	var col: Color = cd["color"]
	var sw := 1.4 if data else clampf(2.2 + 1.1 * sqrt(maxf(float(cd.get("mm2", 0.0)), 0.5)), 2.2, 9.0)
	var o := PackedStringArray()
	var path := " ".join(pts)
	if data:
		o.append('<polyline points="%s" fill="none" stroke="#ffffff" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>' % [path, _n(sw + 1.6)])
		o.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" stroke-dasharray="%s %s" stroke-linejoin="round"/>' % [
			path, _hex(col), _n(sw), _n(sw * 3.0), _n(sw * 2.0)])
	else:
		o.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>' % [path, _hex(col.darkened(0.55)), _n(sw + 1.8)])
		o.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round"/>' % [path, _hex(col), _n(sw)])
		o.append('<polyline points="%s" fill="none" stroke="#ffffff" stroke-opacity="%s" stroke-width="%s" stroke-linejoin="round" stroke-linecap="round" transform="translate(%s %s)"/>' % [
			path, "0.18" if col.get_luminance() < 0.3 else "0.3", _n(maxf(sw * 0.28, 0.5)), _n(-sw * 0.18), _n(-sw * 0.18)])
		for e in [wire[0], wire[wire.size() - 1]]:
			o.append('<circle cx="%s" cy="%s" r="%s" fill="%s"/><circle cx="%s" cy="%s" r="%s" fill="#cfa85a"/>' % [
				_n(ox + e.x), _n(oy - e.y), _n(sw * 0.75 + 0.6), _hex(col.darkened(0.55)), _n(ox + e.x), _n(oy - e.y), _n(sw * 0.55)])
	var anchor := label_anchor(wire)
	if float(anchor.get("length", 0.0)) >= 48.0:
		var mid: Vector2 = anchor["pos"]
		var label := "%s · %.1f m" % [str(cd["label"]), float(cd["length_m"])]
		if not data and float(cd.get("amps", 0.0)) > 0.0:
			label += " · %s A" % _n(float(cd["amps"]))
		var tw := float(label.length()) * 2.0 + 6.0
		var lx := ox + mid.x - tw * 0.5
		var ly := oy - mid.y - sw * 0.5 - 8.5
		if not bool(anchor["horizontal"]):
			lx = ox + mid.x + sw * 0.5 + 3.0
			ly = oy - mid.y - 3.5
		o.append('<rect x="%s" y="%s" width="%s" height="7" rx="1.2" fill="#ffffff" stroke="#b8bec6" stroke-width="0.3"/>' % [_n(lx), _n(ly), _n(tw)])
		o.append('<rect x="%s" y="%s" width="1.2" height="7" fill="%s"/>' % [_n(lx), _n(ly), _hex(col)])
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" fill="#1c2430">%s</text>' % [_n(lx + 3.0), _n(ly + 5.0), _esc(label)])
	return "\n".join(o)


static func _device_svg(d: Dictionary, ox: float, oy: float) -> String:
	var box: Rect2 = d["box"]
	var kind := str(d["kind"])
	var sym: Dictionary = d.get("symbol", {})
	var o := PackedStringArray()
	o.append('<g id="dev_%s">' % _esc(str(d["id"])))
	if str(sym.get("kind", "")) == "face":
		var face: Dictionary = (sym["face"] as Dictionary).duplicate()
		face["title"] = false
		o.append(CtrlSheet.face_svg(face, ox, oy))
		var r: Rect2 = face["rect"]
		o.append('<text x="%s" y="%s" font-size="4.2" font-weight="600" text-anchor="middle" fill="#1a1a1a">%s</text>' % [
			_n(ox + r.get_center().x), _n(oy - r.end.y - 4.0), _esc(str(d["name"]))])
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
	o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#000" fill-opacity="0.12"/>' % [_n(x + 1.2), _n(y + 1.6), _n(w), _n(h)])
	if kind == "panels":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#c9ced4" stroke="#8e95a0" stroke-width="0.6"/>' % [_n(x), _n(y), _n(w), _n(h)])
		var fw := maxf(w * 0.035, 2.5)
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#0f2d5e"/>' % [_n(x + fw), _n(y + fw), _n(w - 2.0 * fw), _n(h - 2.0 * fw)])
		o.append(_module_grid_svg(Rect2(x + fw, y + fw, w - 2.0 * fw, h - 2.0 * fw)))
		# junction box and the two pigtails to the MC4 ends
		var jb := Rect2(x + w * 0.39, y + h - 1.0, w * 0.22, maxf(h * 0.045, 4.0))
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="1" fill="#2c3138"/>' % [_n(jb.position.x), _n(jb.position.y), _n(jb.size.x), _n(jb.size.y)])
		for p in (d["ports"] as Array):
			var pp: Vector2 = p["pos"]
			var plus := str(p["role"]).ends_with("+")
			var ex := ox + pp.x
			var ey := oy - pp.y
			var fx := jb.get_center().x + (-1.0 if plus else 1.0) * jb.size.x * 0.25
			o.append('<path d="M%s %s C%s %s %s %s %s %s" fill="none" stroke="%s" stroke-width="2.2" stroke-linecap="round"/>' % [
				_n(fx), _n(jb.end.y), _n(fx), _n(jb.end.y + 8.0), _n(ex), _n(ey - 10.0), _n(ex), _n(ey - 5.0), "#c0392b" if plus else "#2c3138"])
			o.append('<rect x="%s" y="%s" width="3.4" height="7" rx="1.3" fill="#23272c"/>' % [_n(ex - 1.7), _n(ey - 7.0)])
		var module := _esc(str(sym.get("module", "")))
		o.append('<text x="%s" y="%s" font-size="3.2" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + h - 1.6), module if module != "" else name])
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y - 2.5), name])
		if cap != "":
			o.append('<text x="%s" y="%s" font-size="3.0" fill="#5b6675">%s</text>' % [_n(x), _n(y - 7.0), cap])
	elif kind == "battery":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="#20314a"/>' % [_n(x), _n(y), _n(w), _n(h)])
		var lid := maxf(h * 0.16, 6.0)
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="#2b4062"/>' % [_n(x), _n(y), _n(w), _n(lid)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#eef1f4"/>' % [_n(x + w * 0.12), _n(y + lid + h * 0.14), _n(w * 0.76), _n(h * 0.52)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#e4570e"/>' % [_n(x + w * 0.12), _n(y + lid + h * 0.14), _n(w * 0.76), _n(maxf(h * 0.08, 3.0))])
		o.append('<text x="%s" y="%s" font-size="4.2" font-weight="600" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + lid + h * 0.42), name])
		o.append('<text x="%s" y="%s" font-size="3.6" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + lid + h * 0.56), cap])
		for p in (d["ports"] as Array):
			if str(p["handle"]) == "data":
				continue
			var pp: Vector2 = p["pos"]
			var plus := str(p["role"]).ends_with("+")
			o.append('<circle cx="%s" cy="%s" r="5.6" fill="%s"/><circle cx="%s" cy="%s" r="4.2" fill="#8a6f34"/><circle cx="%s" cy="%s" r="2.8" fill="#cfa85a"/>' % [
				_n(ox + pp.x), _n(oy - pp.y), "#c0392b" if plus else "#2c3138", _n(ox + pp.x), _n(oy - pp.y), _n(ox + pp.x), _n(oy - pp.y)])
	elif kind == "fuse":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2.5" fill="#23272c"/>' % [_n(x), _n(y + h * 0.1), _n(w), _n(h * 0.8)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="%s"/>' % [_n(x + w * 0.17), _n(y + h * 0.4), _n(w * 0.66), _n(h * 0.2), "#8a6f34" if state != "" else "#cfa85a"])
		for sx in [0.17, 0.83]:
			o.append(_nut_svg(x + w * sx, y + h * 0.5, maxf(h * 0.17, 4.0)))
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#8c99a6" fill-opacity="0.4" stroke="#c0c8d0" stroke-width="0.4"/>' % [_n(x + w * 0.27), _n(y), _n(w * 0.46), _n(h)])
		o.append('<text x="%s" y="%s" font-size="3.6" font-weight="600" text-anchor="middle" fill="#f7f9fb">%s</text>' % [_n(x + w * 0.5), _n(y + h * 0.5 + 1.3), cap if cap != "" else name])
		o.append('<text x="%s" y="%s" font-size="3" text-anchor="middle" fill="%s">%s</text>' % [_n(x + w * 0.5), _n(y + h + 4.5), "#b91c1c" if state != "" else "#5b6675", state.to_upper() if state != "" else "FUSE"])
	elif kind == "breaker":
		var tripped := state != ""
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2.5" fill="#2c3138"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="1.5" fill="%s"/>' % [_n(x + w * 0.3), _n(y + h * (0.42 if tripped else 0.12)), _n(w * 0.4), _n(h * 0.42), "#c0392b" if tripped else "#1f6fd6"])
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#f7f9fb">%s</text>' % [_n(x + w * 0.5), _n(y + h - 3.0), cap if cap != "" else name])
		o.append('<text x="%s" y="%s" font-size="3" text-anchor="middle" fill="%s">%s</text>' % [_n(x + w * 0.5), _n(y + h + 4.5), "#b91c1c" if tripped else "#5b6675", "TRIPPED" if tripped else "BREAKER"])
	elif kind == "switch":
		var open := state != ""
		var cx := x + w * 0.5
		var cyy := y + h * 0.5
		var rad := minf(w, h) * 0.4
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2.5" fill="#1e2328"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<circle cx="%s" cy="%s" r="%s" fill="#0f1215"/><circle cx="%s" cy="%s" r="%s" fill="#c0392b"/>' % [_n(cx), _n(cyy), _n(rad * 1.1), _n(cx), _n(cyy), _n(rad)])
		var dx := 0.0 if open else rad * 0.75
		var dy := rad * 0.75 if open else 0.0
		o.append('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="#7b1d14" stroke-width="%s" stroke-linecap="round"/>' % [_n(cx - dx), _n(cyy - dy), _n(cx + dx), _n(cyy + dy), _n(maxf(rad * 0.32, 2.0))])
		o.append('<text x="%s" y="%s" font-size="3" text-anchor="middle" fill="%s">%s</text>' % [_n(cx), _n(y + h + 4.5), "#b91c1c" if open else "#5b6675", ("OFF" if open else "ON") + " · " + name])
	elif kind == "busbar":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#23272c"/>' % [_n(x - 3.0), _n(y - 3.0), _n(w + 6.0), _n(h + 6.0)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#b87333" stroke="#7a4a1f" stroke-width="0.5"/>' % [_n(x), _n(y), _n(w), _n(h)])
		for i in 5:
			o.append(_nut_svg(x + w * (float(i) + 0.5) / 5.0, y + h * 0.5, maxf(h * 0.3, 3.0)))
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y - 4.5), name])
	elif kind == "distributor":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="3" fill="#1f5fa8"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#e4570e"/>' % [_n(x + w * 0.06), _n(y + h * 0.1), _n(w * 0.88), _n(maxf(h * 0.08, 2.0))])
		for i in 4:
			var fx := x + w * (0.1 + float(i) * 0.21)
			o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="1" fill="#0e1a2b"/>' % [_n(fx), _n(y + h * 0.3), _n(w * 0.13), _n(h * 0.42)])
			o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#cfa85a"/>' % [_n(fx + w * 0.026), _n(y + h * 0.46), _n(w * 0.078), _n(h * 0.1)])
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#f7f9fb">%s</text>' % [_n(x + w * 0.5), _n(y + h - 2.0), name])
	elif kind == "shunt":
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#3a4654"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#8a949e"/>' % [_n(x + w * 0.1), _n(y + h * 0.25), _n(w * 0.8), _n(h * 0.5)])
		for sx in [0.14, 0.86]:
			o.append(_nut_svg(x + w * sx, y + h * 0.5, maxf(h * 0.22, 4.0)))
		o.append('<text x="%s" y="%s" font-size="3.2" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y - 3.5), name])
	elif kind == "monitor":
		var cx2 := x + w * 0.5
		var cy2 := y + h * 0.42
		var rad2 := minf(w, h * 0.84) * 0.5
		o.append('<circle cx="%s" cy="%s" r="%s" fill="#1a1f26"/><circle cx="%s" cy="%s" r="%s" fill="#2b3340"/>' % [_n(cx2), _n(cy2), _n(rad2), _n(cx2), _n(cy2), _n(rad2 * 0.88)])
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="1.5" fill="#102033"/>' % [_n(cx2 - rad2 * 0.55), _n(cy2 - rad2 * 0.36), _n(rad2 * 1.1), _n(rad2 * 0.72)])
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#9fd3ff">100 %%</text>' % [_n(cx2), _n(cy2 + 1.3)])
		o.append('<text x="%s" y="%s" font-size="3.4" font-weight="600" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(cx2), _n(y + h - 2.5), name])
		if cap != "":
			o.append('<text x="%s" y="%s" font-size="3" text-anchor="middle" fill="#5b6675">%s</text>' % [_n(cx2), _n(y + h + 2.5), cap])
	else:
		o.append('<rect x="%s" y="%s" width="%s" height="%s" rx="2" fill="#e6e8eb" stroke="#1c2430" stroke-width="0.5"/>' % [_n(x), _n(y), _n(w), _n(h)])
		o.append('<text x="%s" y="%s" font-size="4" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + h * 0.48), name])
		if cap != "":
			o.append('<text x="%s" y="%s" font-size="3.4" text-anchor="middle" fill="#1c2430">%s</text>' % [_n(x + w * 0.5), _n(y + h * 0.72), cap])
	return "\n".join(o)


static func _nut_svg(cx: float, cy: float, r: float) -> String:
	var pts := PackedStringArray()
	for i in 6:
		var a := PI / 6.0 + TAU * float(i) / 6.0
		pts.append("%s,%s" % [_n(cx + cos(a) * r), _n(cy + sin(a) * r)])
	return '<polygon points="%s" fill="#b9bec4" stroke="#6b7177" stroke-width="0.3"/><circle cx="%s" cy="%s" r="%s" fill="#80868d"/>' % [
		" ".join(pts), _n(cx), _n(cy), _n(r * 0.42)]


## The cells of a module inside `glass` (sheet mm, y down).
static func _module_grid_svg(glass: Rect2) -> String:
	var o := PackedStringArray()
	var cols := 6
	var rows := 10
	var gap := 0.9
	var cw := (glass.size.x - gap * float(cols + 1)) / float(cols)
	var ch := (glass.size.y - gap * float(rows + 1)) / float(rows)
	if cw < 2.0 or ch < 2.0:
		return ""
	for j in rows:
		for i in cols:
			o.append('<rect x="%s" y="%s" width="%s" height="%s" fill="#1c4284"/>' % [
				_n(glass.position.x + gap + float(i) * (cw + gap)), _n(glass.position.y + gap + float(j) * (ch + gap)), _n(cw), _n(ch)])
	return "\n".join(o)


static func _n(v: float) -> String:
	return ("%.2f" % v).rstrip("0").rstrip(".")


static func _hex(c: Color) -> String:
	return "#" + c.to_html(false)


static func _esc(t: String) -> String:
	return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

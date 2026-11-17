class_name TcFlowPaths
extends RefCounted

## Which ports of a TC part share a fluid volume (TC Process Lab, Phase 0).
## A built part (TcParts.build) only lists its ports; this table says how
## the fluid gets from one to another inside the part, which circuits are
## separate (a dephlegmator's product tube and its cooling-water jacket) and
## what the part does to the flow.
##
## `circuits(built)` → [{id, ports: [port ids], role, size, r_in_mm,
## volume_l, length_mm, path: [PackedVector3Array (part-local mm)], ...}].
## Ports no circuit names are not fluid (valve stems, actuator air ports,
## a thermowell's probe thread).
##
## Roles (what TcProcNet does with them):
##   VOLUME roles become control volumes:
##     pipe       2-port pass-through; consecutive pipes merge into one CV
##     junction   tee / cross / lateral: where branches meet
##     vessel     a vessel's interior (every nozzle opens into it)
##     jacket     a vessel's jacket: no ports, thermal only
##     condenser  a dephlegmator's product tube (cooled by its coolant)
##     coolant    a dephlegmator's water jacket (w1 ↔ w2)
##     column     a packed column section
##     plate      one bubble-cap plate
##     sight      a sight glass (a pipe you can read a level in)
##     filter     strainers and cartridge housings
##   LINK roles become links between the CVs on their ends:
##     valve      opens and closes (`open` param; an actuator later)
##     check      a → b only
##     relief     a → b above its set pressure
##   ATTACH roles (one port) close the port they sit on and act on that CV:
##     blind      an end cap
##     probe_t    a dial thermometer's probe
##     probe_p    a pressure gauge
##     probe_well a thermowell
##     heater     an immersion heating element
##     basket     a strainer basket hung in a vessel
##     spray      a CIP spray ball
##     feed       a funnel / hopper (open to the air at its rim)

const VOLUME_ROLES := ["pipe", "junction", "vessel", "jacket", "condenser", "coolant", "column", "plate", "sight", "filter",
	"holder", "dryer", "engine", "flare"]
const LINK_ROLES := ["valve", "check", "relief", "pump"]
const ATTACH_ROLES := ["blind", "probe_t", "probe_p", "probe_well", "probe_l", "probe_ls", "heater", "basket", "spray", "feed", "agitator"]

## Every part type → how its circuits are made. The selftest fails on a
## type in TcParts.TYPES missing here (the PackedSpec coverage rule).
const TYPE_RULES := {
	"spool": "pipe", "elbow90": "bend", "elbow45": "bend", "bend": "bend",
	"tee": "junction", "reducing_tee": "junction", "cross": "junction", "lateral": "junction",
	"ferrule": "pipe", "cap": "blind", "cap_npt": "cap_npt", "reducing_cap": "pipe", "reducer": "pipe", "bowl_reducer": "pipe",
	"tc_npt_m": "pipe", "tc_barb": "pipe",
	"vessel": "vessel",
	"butterfly": "valve", "ball_valve": "valve", "ball_valve_3way": "valve3", "check_valve": "check",
	"diaphragm_valve": "valve", "control_valve": "cvalve", "pump": "pump", "relief_valve": "relief",
	"solenoid_valve": "valve", "level_tx": "probe_l", "level_switch": "probe_ls", "flow_meter": "pipe",
	"plate_exchanger": "plate_hx", "agitator": "agitator",
	"actuator_pneumatic": "none", "actuator_electric": "none",
	"sight_glass": "sight", "thermometer": "probe_t", "gauge": "probe_p", "thermowell": "probe_well",
	"dephlegmator": "dephlegmator", "column": "column", "bubble_plate": "plate",
	"inline_strainer": "filter", "y_strainer": "filter", "cartridge_housing": "filter",
	"strainer_basket": "basket", "funnel": "feed", "spray_ball": "spray", "heating_element": "heater",
	"gas_holder": "holder", "dryer": "dryer", "genset": "engine", "flare": "flare",
}


static func is_volume(role: String) -> bool:
	return role in VOLUME_ROLES


static func is_link(role: String) -> bool:
	return role in LINK_ROLES


static func is_attach(role: String) -> bool:
	return role in ATTACH_ROLES


static func _ports(built: Dictionary) -> Dictionary:
	var out := {}
	for p in built.get("ports", []):
		out[str(p["id"])] = p
	return out


static func _pos(p: Dictionary) -> Vector3:
	return p["pos"]


static func _len(pl: PackedVector3Array) -> float:
	var s := 0.0
	for i in range(1, pl.size()):
		s += pl[i].distance_to(pl[i - 1])
	return s


static func _line(a: Vector3, b: Vector3) -> PackedVector3Array:
	return PackedVector3Array([a, b])


static func _r_in(size: String) -> float:
	return float(TcStandards.tube(size)["r_in"]) if TcStandards.has_size(size) else 10.0


static func _circuit(id: String, ports: Array, role: String, size: String, volume_l: float, path: Array) -> Dictionary:
	var L := 0.0
	for pl in path:
		L += _len(pl)
	return {"id": id, "ports": ports, "role": role, "size": size, "r_in_mm": _r_in(size),
		"volume_l": volume_l, "length_mm": L, "path": path}


## The circuits of one built part (TcParts.build output).
static func circuits(built: Dictionary) -> Array:
	var type := str(built.get("type", ""))
	var size := str(built.get("size", ""))
	var p: Dictionary = built.get("params", {})
	var P := _ports(built)
	var vol := float(built.get("volume_l", 0.0))
	var rule := str(TYPE_RULES.get(type, "none"))
	match rule:
		"none":
			return []
		"holder", "dryer":
			# A process unit with a way in and a way out (TcUnits).
			var c0 := _circuit("main", ["a", "b"], rule, size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			c0["unit"] = (built.get("unit", {}) as Dictionary).duplicate(true)
			return [c0]
		"engine", "flare":
			# A process unit the gas goes into and does not come out of
			# (burned): one port, the line to the unit's middle.
			var cap: Array = built.get("capsules", [])
			var mid: Vector3 = _pos(P["a"]) + Vector3(0, 0, 100.0)
			if not cap.is_empty():
				mid = ((cap[0] as Array)[1] as Vector3)
			var c1 := _circuit("main", ["a"], rule, size, vol, [_line(_pos(P["a"]), mid)])
			c1["unit"] = (built.get("unit", {}) as Dictionary).duplicate(true)
			return [c1]
		"pipe", "sight", "column", "plate", "filter":
			var ids: Array = []
			for k in ["a", "b", "drain"]:
				if P.has(k):
					ids.append(k)
			if ids.size() < 2:
				return [_circuit("main", ids, "blind", size, vol, [])]
			var role := "pipe" if rule == "pipe" else rule
			var path: Array = [_line(_pos(P["a"]), _pos(P["b"]))]
			if P.has("drain"):
				var mid := (_pos(P["a"]) + _pos(P["b"])) * 0.5
				path.append(_line(_pos(P["drain"]), mid))
			var c := _circuit("main", ids, role, size, vol, path)
			if rule == "column":
				c["packing"] = str(p.get("packing", "none"))
			if rule == "filter":
				c["filter"] = type
			return [c]
		"cap_npt":
			if P.has("b"):
				return [_circuit("main", ["a", "b"], "pipe", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])]
			return [_circuit("main", ["a"], "blind", size, vol, [])]
		"bend":
			return [_circuit("main", ["a", "b"], "pipe", size, vol, [_bend_path(built, type, p)])]
		"junction":
			var ids2: Array = []
			var path2: Array = []
			for k in ["a", "b", "c", "d"]:
				if P.has(k):
					ids2.append(k)
					path2.append(_line(_pos(P[k]), Vector3.ZERO))
			return [_circuit("main", ids2, "junction", size, vol, path2)]
		"vessel":
			return _vessel_circuits(built, p, vol)
		"valve":
			var c3 := _circuit("main", ["a", "b"], "valve", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			c3["open"] = bool(p.get("open", true))
			return [c3]
		"valve3":
			# L-port: open = a ↔ b, closed (turned) = a ↔ c (TcSpecialty
			# draws the lever along the run when open). The ball turns the
			# flow, it never shuts all three.
			var mid3 := (_pos(P["a"]) + _pos(P["b"])) * 0.5
			var c4 := _circuit("main", ["a", "b", "c"], "valve", size, vol,
				[_line(_pos(P["a"]), mid3), _line(mid3, _pos(P["b"])), _line(mid3, _pos(P["c"]))])
			c4["open"] = bool(p.get("open", true))
			c4["l_port"] = true
			return [c4]
		"cvalve":
			# A valve whose opening is a number (0..1), set by the process.
			var cc := _circuit("main", ["a", "b"], "valve", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			cc["throttle"] = true
			cc["open_frac"] = clampf(float(p.get("open_pct", 50.0)) / 100.0, 0.0, 1.0)
			cc["open"] = float(cc["open_frac"]) > 0.02
			return [cc]
		"pump":
			# Liquid goes a → b only; what it does to it is the model's.
			var pc := _circuit("main", ["a", "b"], "pump", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			pc["pump"] = {"kind": str(p.get("kind", "centrifugal")), "head_m": float(p.get("head_m", 8.0)),
				"flow_lpm": float(p.get("flow_lpm", 40.0)), "watts": float(p.get("watts", 250.0)), "on": bool(p.get("on", false))}
			return [pc]
		"check":
			return [_circuit("main", ["a", "b"], "check", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])]
		"relief":
			var c5 := _circuit("main", ["a", "b"], "relief", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			c5["set_bar"] = float(p.get("set_bar", 1.0))
			return [c5]
		"dephlegmator":
			var L := float(p.get("length_mm", 300.0))
			var prod := _circuit("product", ["a", "b"], "condenser", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			prod["cooled_by"] = "coolant"
			var w := _circuit("coolant", ["w1", "w2"], "coolant", "0.5", float(built.get("jacket_l", 0.0)),
				[_line(_pos(P["w1"]), Vector3(0, 0, _pos(P["w1"]).z)), _line(Vector3(0, 0, _pos(P["w1"]).z), Vector3(0, 0, _pos(P["w2"]).z)),
				_line(Vector3(0, 0, _pos(P["w2"]).z), _pos(P["w2"]))])
			w["cools"] = "product"
			w["jacket_len_mm"] = L
			w["shell"] = str(p.get("shell", ""))
			return [prod, w]
		"plate_hx":
			# The dephlegmator's two circuits with a plate pack's area: liquid
			# pumped through gives its heat to the wall, the wall to the water.
			var hp := _circuit("product", ["a", "b"], "condenser", size, vol, [_line(_pos(P["a"]), _pos(P["b"]))])
			hp["cooled_by"] = "coolant"
			hp["area_m2"] = float(built.get("area_m2", 0.6))
			var hw2 := _circuit("coolant", ["w1", "w2"], "coolant", "0.5", float(built.get("jacket_l", 0.4)),
				[_line(_pos(P["w1"]), _pos(P["w2"]))])
			hw2["cools"] = "product"
			hw2["area_m2"] = float(built.get("area_m2", 0.6))
			return [hp, hw2]
		"probe_t", "probe_p", "probe_well", "probe_l", "probe_ls", "heater", "basket", "spray", "feed", "blind", "agitator":
			var c6 := _circuit("main", ["a"], rule, size, 0.0, [])
			if rule == "agitator":
				c6["watts"] = float(p.get("watts", 120.0))
				c6["on"] = bool(p.get("on", false))
			if rule == "heater":
				c6["reach_mm"] = float(built.get("reach_mm", p.get("length_mm", 300.0)))
			if rule == "probe_t":
				c6["probe_mm"] = float(p.get("probe_mm", 100.0))
			return [c6]
	return []


static func _bend_path(built: Dictionary, type: String, p: Dictionary) -> PackedVector3Array:
	var ang := 90.0
	if type == "elbow45":
		ang = 45.0
	elif type == "bend":
		ang = float(p.get("angle_deg", 90.0))
	var a := deg_to_rad(ang)
	var R := float(built.get("radius_mm", 50.0))
	var ctf := float(built.get("ctf_mm", R))
	var tang := R * tan(a * 0.5) if ang < 179.0 else R
	var db := Vector3(sin(a), 0.0, cos(a))
	var out := PackedVector3Array([Vector3(0, 0, -ctf)])
	var t1 := Vector3(0, 0, -tang)
	if ctf > tang + 0.01:
		out.append(t1)
	var arc := TcGeom.arc_points(t1 + Vector3(R, 0, 0), t1, Vector3.UP, a, maxi(4, int(ang / 10.0)))
	for i in range(1, arc.size()):
		out.append(arc[i])
	if ctf > tang + 0.01:
		out.append(db * ctf)
	return out


static func _vessel_circuits(built: Dictionary, p: Dictionary, vol: float) -> Array:
	var P := _ports(built)
	var noz: Dictionary = built.get("nozzles", {})
	var ids: Array = []
	var path: Array = []
	var H := float(p.get("height_mm", 500.0))
	path.append(_line(Vector3.ZERO, Vector3(0, H, 0)))
	for pid in P.keys():
		var pr: Dictionary = P[pid]
		if not (str(pr["kind"]) in ["tc", "npt_f", "weld"]):
			continue
		ids.append(str(pid))
		var f: Dictionary = noz.get(str(pid), {})
		var inner: Vector3 = f.get("inner", _pos(pr))
		path.append(PackedVector3Array([_pos(pr), inner, Vector3(0, inner.y, 0)]))
	var R := float(p.get("od_mm", 300.0)) * 0.5 - float(p.get("wall_mm", 2.0))
	var main := _circuit("main", ids, "vessel", "", vol, path)
	main["r_in_mm"] = R
	main["height_mm"] = H
	main["internals"] = (p.get("internals", []) as Array).duplicate(true)
	main["has_lid"] = TcVessel.has_lid(p)
	main["insulation_mm"] = float(p.get("insulation_mm", 0.0))
	var out: Array = [main]
	var js := TcVessel.jacket_span(p)
	if js.x >= 0.0 and str(p.get("jacket", "none")) != "none":
		var jr := TcVessel.jacket_r(p)
		var jv := PI * (jr * jr - pow(float(p.get("od_mm", 300.0)) * 0.5, 2.0)) * (js.y - js.x) * 1e-6
		var j := _circuit("jacket", [], "jacket", "", jv, [])
		j["span_mm"] = js
		j["r_mm"] = jr
		j["around"] = "main"
		out.append(j)
	return out

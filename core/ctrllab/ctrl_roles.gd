class_name CtrlRoles
extends RefCounted

## The wiring vocabulary of a controller: what each terminal is FOR. A port
## (one connector on the unit) has a `group` ("bat", "pv1", "ac_out", …);
## each of its pins gets a full role from the group and the pin's own hint
## in the connector catalog ("+", "-", "L", "N", "G"), or from the port's
## `roles` list when it is a terminal strip whose pins mean different things.
##
## Roles map to graph handles (Controller Lab Phase 4). PV input 1 keeps the
## graph's existing pvPositive / pvNegative so every wired controller keeps
## working.

const GROUPS := {
	"pv1": "PV input 1", "pv2": "PV input 2", "pv3": "PV input 3", "pv4": "PV input 4",
	"bat": "Battery", "load": "Load output (DC)", "dcin": "DC input (alternator / source)",
	"ac_out": "AC output", "ac_in": "AC input (grid)", "gen": "Generator input",
	"comm_bms": "BMS comms", "rs485": "RS485", "can": "CAN", "ve_direct": "VE.Direct", "ve_bus": "VE.Bus",
	"usb": "USB", "wifi": "Wi-Fi / monitoring", "temp": "Battery temperature sensor",
	"dry": "Dry contact", "remote": "Remote on / off", "rsd": "Rapid shutdown", "ground": "Ground",
	"ui": "Front panel", "": "Unassigned",
}

const DATA_GROUPS := ["comm_bms", "rs485", "can", "ve_direct", "ve_bus", "usb", "wifi"]
const IO_GROUPS := ["temp", "dry", "remote", "rsd"]


## A pin's full role from its port's group and the pin's catalog hint.
static func role_of(group: String, hint: String) -> String:
	if group == "":
		return ""
	match hint:
		"+":
			return group + "+"
		"-", "−":
			return group + "-"
		"L", "L1", "L2", "N", "G":
			return "%s_%s" % [group, hint]
	return group


## Every pin's role for a port, in the connector's pin order. `roles` on the
## port wins per pin where set.
static func pin_roles(port: Dictionary, entry: Dictionary) -> Array:
	var out: Array = []
	var own: Array = port.get("roles", [])
	var pins: Array = entry.get("pins", [])
	var group := str(port.get("group", ""))
	for i in pins.size():
		if i < own.size() and str(own[i]) != "":
			out.append(str(own[i]))
		else:
			out.append(role_of(group, str((pins[i] as Dictionary)["role"])))
	return out


## The roles a kind of unit must have somewhere.
static func required(elec: Dictionary) -> Array:
	var kind := str(elec.get("kind", "mppt"))
	var out: Array = []
	var pv := kind in ["mppt", "pwm", "hybrid", "power_station"]
	if pv:
		for n in range(1, maxi(int(elec.get("mppt_count", 1)), 1) + 1):
			out.append("pv%d+" % n)
			out.append("pv%d-" % n)
	if kind in ["mppt", "pwm", "inverter", "hybrid", "charger", "inverter_charger", "dc_dc"]:
		out.append("bat+")
		out.append("bat-")
	if kind == "dc_dc":
		out.append("dcin+")
		out.append("dcin-")
	if kind in ["inverter", "hybrid", "inverter_charger", "power_station"]:
		out.append("ac_out_L")
		out.append("ac_out_N")
	if kind in ["charger", "inverter_charger"] or (kind == "hybrid" and float(elec.get("ac_in_a", 0.0)) > 0.0):
		out.append("ac_in_L")
		out.append("ac_in_N")
	return out


## The group a role belongs to ("pv2+" → "pv2", "ac_out_L" → "ac_out").
static func group_of(role: String) -> String:
	for g in GROUPS:
		if g != "" and (role == g or role.begins_with(g + "_") or role == g + "+" or role == g + "-"):
			return g
	return role


## The graph handle a role lands on ("" = none on the graph).
static func handle_for(role: String) -> String:
	var g := group_of(role)
	if g.begins_with("pv"):
		var n := int(g.substr(2))
		var plus := role.ends_with("+")
		if n <= 1:
			return "pvPositive" if plus else "pvNegative"
		return ("pvPositive%d" if plus else "pvNegative%d") % n
	match g:
		"bat":
			return "batteryPositive" if role.ends_with("+") else "batteryNegative"
		"load":
			return "loadPositive" if role.ends_with("+") else "loadNegative"
		"dcin":
			return "dcInPositive" if role.ends_with("+") else "dcInNegative"
		"ac_out":
			return "acOutput"
		"ac_in":
			return "acInput"
		"gen":
			return "genInput"
	if DATA_GROUPS.has(g):
		return "data"
	return ""


## Words for a role ("pv2+" → "PV input 2 +", "ac_out_N" → "AC output N").
static func words(role: String) -> String:
	if role == "":
		return "Unassigned"
	var g := group_of(role)
	var base := str(GROUPS.get(g, role))
	var rest := role.substr(g.length()).trim_prefix("_")
	return base if rest == "" else "%s %s" % [base, rest.replace("-", "−")]


## A sensible job for a new port of `connector` on a unit that already has
## `ports`: {group, polarity} ("" polarity for multi-pin connectors).
static func suggest(connector: String, ports: Array) -> Dictionary:
	var e := ConnectorCatalog.entry(connector)
	var dom := str(e.get("domain", ""))
	var group := ""
	match dom:
		"pv":
			group = "pv1"
		"dc":
			group = "bat"
		"ac":
			group = "ac_out"
		"ground":
			group = "ground"
		"ui":
			group = "ui"
		"io":
			group = "dry"
		"data":
			match connector:
				"usb_a", "usb_c":
					group = "usb"
				"ve_direct":
					group = "ve_direct"
				"antenna":
					group = "wifi"
				_:
					group = "rs485"
	var single := (e.get("pins", []) as Array).size() == 1 and dom in ["pv", "dc"]
	var pol := ""
	if single:
		pol = "+"
		for p in ports:
			if str(p.get("group", "")) == group and str((p.get("opts", {}) as Dictionary).get("polarity", "")) == "+":
				pol = "-"
		# A PV group with both poles taken: the next MPPT.
		if group == "pv1" and pol == "+":
			var used := {}
			for p in ports:
				used[str(p.get("group", ""))] = true
			for n in range(1, 5):
				var g := "pv%d" % n
				var has_p := false
				var has_n := false
				for p in ports:
					if str(p.get("group", "")) == g:
						var pp := str((p.get("opts", {}) as Dictionary).get("polarity", ""))
						has_p = has_p or pp == "+"
						has_n = has_n or pp == "-"
				if not (has_p and has_n):
					group = g
					pol = "-" if has_p else "+"
					break
	return {"group": group, "polarity": pol}

class_name ScadaNet
extends RefCounted
## The information domain on the graph (plans/SCADA_PROCESS_PLAN.md, Phase
## 3b): data wires, the nodes that carry them, and whether a board can be
## heard by the controller.
##
## A DATA WIRE is a graph connection with `polarity: "data"`. The flow and
## power engines never read that polarity, so a data wire moves nothing. What
## it decides is REACH: a controller board's tags are available only while
## there is a live path from the board to a server.
##
## Nodes (any item with `specs.net_role`; every one is also a load):
##   server   the controller everything reports to (a Home Assistant box)
##   switch   forwards between its ports while it has power
##   ap       a Wi-Fi access point: its `wifi` port serves boards without a
##            cable, its `data` port is its uplink
##   board    a controller board (an ESP design placed in the world)
##
## The rule is only ENFORCED when the graph has a server: a world with no
## network on it behaves as it always did (every board is heard).
##
## Pure and autoload-free.

const POLARITY := "data"

const ROLE_SERVER := "server"
const ROLE_SWITCH := "switch"
const ROLE_AP := "ap"
const ROLE_BOARD := "board"
const ROLES := [ROLE_SERVER, ROLE_SWITCH, ROLE_AP, ROLE_BOARD]

## Link kinds. `max_m` = the longest run that works.
##   ethernet  100 m, TIA-568 channel limit
##   bus_rs485 1200 m at low baud (TIA-485 guidance)
##   bus_can   500 m at 125 kbit/s (CiA 102)
##   signal    a multi-conductor sensor lead; 30 m is an estimate (I2C is far
##             shorter, 1-Wire longer)
##   wireless  45 m, a typical 2.4 GHz outdoor Wi-Fi range (estimate)
const KINDS := {
	"ethernet": {"label": "Ethernet", "max_m": 100.0, "cable": true},
	"signal": {"label": "Signal cable", "max_m": 30.0, "cable": true},
	"bus_rs485": {"label": "RS-485 bus", "max_m": 1200.0, "cable": true},
	"bus_can": {"label": "CAN bus", "max_m": 500.0, "cable": true},
	"wireless": {"label": "Wi-Fi", "max_m": 45.0, "cable": false},
}
const KIND_ORDER := ["ethernet", "wireless", "signal", "bus_rs485", "bus_can"]

## The model id of a placed ESP board (EspBuilder.MODEL_ID): its node is a
## board even when it was made before boards had a role.
const ESP_MODEL_ID := "esplab_board"


static func is_data(conn: Dictionary) -> bool:
	return str(conn.get("polarity", "")) == POLARITY


static func role_of(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var r := str(specs.get("net_role", ""))
	if r in ROLES:
		return r
	if str(specs.get("model_id", "")) == ESP_MODEL_ID:
		return ROLE_BOARD
	return ""


## The data ports a node of `role` has, on its bottom edge (its supply port
## is on top). Added to the type's own ports by GraphPortService.
static func data_handles(role: String, specs: Dictionary = {}) -> Array:
	match role:
		ROLE_SWITCH:
			var n := clampi(int(specs.get("ports", 5)), 2, 8)
			var out: Array = []
			for i in n:
				out.append({"id": "data_%d" % i, "polarity": POLARITY, "rx": float(i + 1) / float(n + 1), "ry": 1.0})
			return out
		ROLE_AP:
			return [{"id": "data", "polarity": POLARITY, "rx": 0.3, "ry": 1.0},
				{"id": "wifi", "polarity": POLARITY, "rx": 0.7, "ry": 1.0, "wireless": true}]
		ROLE_SERVER, ROLE_BOARD:
			return [{"id": "data", "polarity": POLARITY, "rx": 0.75, "ry": 1.0}]
	return []


## What a data wire is: its own `data_kind`, else Wi-Fi when it ends on an
## access point's `wifi` port, else Ethernet.
static func kind_of(conn: Dictionary) -> String:
	var k := str(conn.get("data_kind", ""))
	if KINDS.has(k):
		return k
	if str(conn.get("source_handle_id", "")) == "wifi" or str(conn.get("target_handle_id", "")) == "wifi":
		return "wireless"
	return "ethernet"


## The run's length in metres (-1 = unknown). Only a run the player ROUTED
## in the world counts (`visible_3d`): the conduit system also measures
## wires to nodes that have no place of their own, and those lengths mean
## nothing.
static func length_m(conn: Dictionary) -> float:
	if not bool(conn.get("visible_3d", false)):
		return -1.0
	var l := float(conn.get("route_length_m", -1.0))
	return l if l > 0.0 else -1.0


## "" when the link works, else why not.
static func link_fault(conn: Dictionary) -> String:
	var k := kind_of(conn)
	var l := length_m(conn)
	var max_m := float((KINDS[k] as Dictionary)["max_m"])
	if l > max_m:
		return "%s is %d m long; it works to %d m" % [str((KINDS[k] as Dictionary)["label"]), int(round(l)), int(max_m)]
	return ""


## Whether a node is switched on (its load state; AC loss shows there too).
static func powered(item: Dictionary) -> bool:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	return str(specs.get("current_state", specs.get("requested_state", "on"))).to_lower() == "on"


## Who can be heard. `items` / `conns` = the whole graph, flat.
## → {enforced, servers: [ids], nodes: {id: {ok, why, hops}}} for every node
## with a role. With no server nothing is enforced and every node is ok.
static func reach(items: Array, conns: Array) -> Dictionary:
	var by_id := {}
	var servers: Array = []
	for it in items:
		if not (it is Dictionary):
			continue
		var r := role_of(it)
		if r.is_empty():
			continue
		by_id[str(it["id"])] = it
		if r == ROLE_SERVER:
			servers.append(str(it["id"]))
	var nodes := {}
	if servers.is_empty():
		for id in by_id:
			nodes[id] = {"ok": true, "why": "", "hops": 0}
		return {"enforced": false, "servers": [], "nodes": nodes}
	var adj := {}
	var wired := {}
	var bad_link := {}
	for c in conns:
		if not (c is Dictionary) or not is_data(c):
			continue
		var a := str(c.get("source_item_id", ""))
		var b := str(c.get("target_item_id", ""))
		if not by_id.has(a) or not by_id.has(b):
			continue
		wired[a] = true
		wired[b] = true
		var fault := link_fault(c)
		if not fault.is_empty():
			bad_link[a] = fault
			bad_link[b] = fault
			continue
		for pair in [[a, b], [b, a]]:
			if not adj.has(pair[0]):
				adj[pair[0]] = []
			(adj[pair[0]] as Array).append(pair[1])
	# Breadth-first from every powered server; only powered switches and
	# access points pass anything on.
	var hops := {}
	var queue: Array = []
	for s in servers:
		if powered(by_id[s]):
			hops[s] = 0
			queue.append(s)
	var qi := 0
	while qi < queue.size():
		var id: String = queue[qi]
		qi += 1
		var r := role_of(by_id[id])
		if int(hops[id]) > 0 and not (r in [ROLE_SWITCH, ROLE_AP]):
			continue
		if not powered(by_id[id]):
			continue
		for o in adj.get(id, []):
			if not hops.has(o):
				hops[o] = int(hops[id]) + 1
				queue.append(o)
	for id in by_id:
		var it: Dictionary = by_id[id]
		var ok := hops.has(id) and powered(it)
		var why := ""
		if not powered(it):
			why = "no power"
		elif not hops.has(id):
			if not wired.has(id):
				why = "not on the network"
			elif bad_link.has(id):
				why = str(bad_link[id])
			else:
				why = "no path to the server"
		nodes[id] = {"ok": ok, "why": why, "hops": int(hops.get(id, -1))}
	return {"enforced": true, "servers": servers, "nodes": nodes}


## Design checks: [{level "error" | "warn", text, ids}].
static func checks(items: Array, conns: Array) -> Array:
	var out: Array = []
	var name_of := {}
	var by_id := {}
	for it in items:
		if it is Dictionary and not role_of(it).is_empty():
			by_id[str(it["id"])] = it
			name_of[str(it["id"])] = str((it.get("specs", {}) as Dictionary).get("name", str(it["id"])))
	var on_port := {}
	for c in conns:
		if not (c is Dictionary) or not is_data(c):
			continue
		var fault := link_fault(c)
		if not fault.is_empty():
			out.append({"level": "error", "text": fault + ".", "ids": [str(c.get("id", ""))]})
		for side in ["source", "target"]:
			var key := "%s|%s" % [str(c.get(side + "_item_id", "")), str(c.get(side + "_handle_id", ""))]
			on_port[key] = int(on_port.get(key, 0)) + 1
	for key in on_port:
		var id := str(key).get_slice("|", 0)
		var h := str(key).get_slice("|", 1)
		if h != "wifi" and int(on_port[key]) > 1 and by_id.has(id):
			out.append({"level": "warn", "text": "%s has %d cables in one port." % [str(name_of[id]), int(on_port[key])], "ids": [id]})
	var r := reach(items, conns)
	if bool(r["enforced"]):
		for id in r["nodes"]:
			var n: Dictionary = r["nodes"][id]
			if not bool(n["ok"]) and role_of(by_id[id]) != ROLE_SERVER:
				out.append({"level": "error" if role_of(by_id[id]) == ROLE_BOARD else "warn",
					"text": "%s: %s." % [str(name_of[id]), str(n["why"])], "ids": [id]})
	return out


## Preset specs for a network node (a load with a role).
static func make_specs(role: String, name: String, watts: float, opts: Dictionary = {}) -> Dictionary:
	var s := {"name": name, "net_role": role, "avg_watts": watts, "rated_watts": watts, "max_watts": watts,
		"requested_state": "on", "current_state": "on", "cost": float(opts.get("cost", 0.0))}
	if role == ROLE_SWITCH:
		s["ports"] = int(opts.get("ports", 5))
	return s

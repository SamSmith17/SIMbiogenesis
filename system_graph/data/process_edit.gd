class_name ProcessEdit
extends RefCounted
## Editing a process line (plans/SCADA_PROCESS_PLAN.md, Phase 3): what the
## Process lens's tools do to the graph. Pure over a GraphModel, so the
## selftest drives it without a view.
##
##   place(model, tool, scope, at)        a new unpiped store / valve / pump
##   split(model, conn_id, tool)          put one IN a pipe: A → new → B
##   link(model, from_id, to_id)          a pipe from one thing to another
##   link_power(model, a, b, handles_of)  an AC wire from a supply to a load
##   link_data(model, a, b, handles_of)   a network cable (Wi-Fi on an
##                                        access point's wifi port)
##   split_power(model, conn, handles_of) a breaker IN a power wire
## `handles_of` = Callable(item) -> Array of its resolved ports (the canvas's
## `_resolved_handles`; the selftest passes GraphPortService's).
##
## Each returns {ok, id, why}: `id` = the new item (place, split) or wire
## (link); `why` = a sentence for the player when it refuses.
##
## What a pipe carries is decided by where it starts: a store's kind, a
## valve's or pump's line, a machine's first output the far end takes. A
## valve, pump or lens-placed store that is not piped yet takes the kind of
## the first pipe joined to it.

const TOOLS := ["store", "valve", "check", "pump"]
const TOOL_WORDS := {"store": "store", "valve": "valve", "check": "check valve", "pump": "pump"}
## Items placed in the lens are shown there before they are piped.
const SHOW_KEY := "process_show"


static func _res(ok: bool, id: String, why: String = "") -> Dictionary:
	return {"ok": ok, "id": id, "why": why}


static func _scope_of(item: Dictionary) -> String:
	return str(item.get("scope_id", GraphModel.ROOT_SCOPE_ID))


static func _wired(model: GraphModel, id: String) -> bool:
	for c in model.get_connections_in_scope(_scope_of(model.get_item(id))):
		if str(c.get("source_item_id", "")) == id or str(c.get("target_item_id", "")) == id:
			return true
	return false


## A new item dict for `tool` on a line of `kind`.
static func new_item(tool: String, kind: String, scope: String, at: Vector2) -> Dictionary:
	var k := ResourceKinds.normalize_kind(kind if not kind.is_empty() else "water")
	var nm := ResourceKinds.display_name(k)
	var specs := {}
	var type := "processor"
	var size := Vector2(130, 110)
	match tool:
		"store":
			type = "resource"
			size = Vector2(90, 100)
			specs = {"name": "%s Store" % nm, "resource_kind": k, "capacity_qty": 1000.0,
				"capacity_unit": ResourceKinds.default_unit(k), "level": 0.0, "cost": 0.0}
		"pump":
			specs = FlowCtl.make_specs("%s Pump" % nm, FlowCtl.KIND_PUMP, k, 600.0,
				{"watts": 120.0, "max_lift_m": 12.0})
		"check":
			specs = FlowCtl.make_specs("%s Check Valve" % nm, FlowCtl.KIND_CHECK, k, 1200.0)
		_:
			specs = FlowCtl.make_specs("%s Valve" % nm, FlowCtl.KIND_VALVE, k, 1200.0)
	specs[SHOW_KEY] = true
	return {"type": type, "scope_id": scope, "x": at.x, "y": at.y, "width": size.x, "height": size.y, "specs": specs}


static func place(model: GraphModel, tool: String, scope: String, at: Vector2) -> Dictionary:
	if not (tool in TOOLS):
		return _res(false, "", "There is no such part.")
	var it := new_item(tool, "water", scope, at)
	model.add_item(it)
	return _res(true, str(it["id"]))


## What a pipe leaving `item` carries ("" = it has nothing to give).
static func kind_out(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	match str(item.get("type", "")):
		"resource", "catchment":
			return ResourceKinds.normalize_kind(str(specs.get("resource_kind", "water")))
		"processor":
			if FlowCtl.is_flowctl(specs):
				return ResourceKinds.normalize_kind(str(specs.get("ctl_resource", "water")))
			var outs: Array = specs.get("outputs", []) as Array
			if not outs.is_empty():
				return ResourceKinds.normalize_kind(str((outs[0] as Dictionary).get("kind", "")))
	return ""


## The handle a pipe of `kind` leaves `item` by ("" = none).
static func source_handle(item: Dictionary, kind: String) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	match str(item.get("type", "")):
		"resource", "catchment":
			if ResourceKinds.normalize_kind(str(specs.get("resource_kind", "water"))) != kind:
				return ""
			for h in item.get("handles", []):
				if h is Dictionary and str(h.get("role", "")) == GraphHubPorts.ROLE_OUT:
					return str(h.get("id", "output"))
			return "output"
		"processor":
			var outs: Array = specs.get("outputs", []) as Array
			for i in outs.size():
				if ResourceKinds.normalize_kind(str((outs[i] as Dictionary).get("kind", ""))) == kind:
					return "res_out_%d" % i
	return ""


## The handle a pipe of `kind` enters `item` by ("" = it does not take it).
static func target_handle(item: Dictionary, kind: String) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	match str(item.get("type", "")):
		"resource":
			if ResourceKinds.normalize_kind(str(specs.get("resource_kind", "water"))) != kind:
				return ""
			for h in item.get("handles", []):
				if h is Dictionary and str(h.get("role", "")) == GraphHubPorts.ROLE_IN:
					return str(h.get("id", "input"))
			return "input"
		"processor":
			var ins: Array = specs.get("inputs", []) as Array
			for i in ins.size():
				if ResourceKinds.normalize_kind(str((ins[i] as Dictionary).get("kind", ""))) == kind:
					return "res_in_%d" % i
	return ""


## Whether an unpiped item may still change what it carries.
static func _can_rekind(model: GraphModel, item: Dictionary) -> bool:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	if _wired(model, str(item["id"])):
		return false
	if str(item.get("type", "")) == "processor":
		return FlowCtl.is_flowctl(specs)
	return str(item.get("type", "")) == "resource" and bool(specs.get(SHOW_KEY, false)) \
		and float(specs.get("level", 0.0)) <= 0.0


static func _rekind(model: GraphModel, item: Dictionary, kind: String) -> void:
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	var was := ResourceKinds.display_name(kind_out(item))
	var nm := ResourceKinds.display_name(kind)
	if str(specs.get("name", "")).begins_with(was):
		specs["name"] = nm + str(specs["name"]).substr(was.length())
	if str(item.get("type", "")) == "resource":
		specs["resource_kind"] = kind
		specs["capacity_unit"] = ResourceKinds.default_unit(kind)
	else:
		specs["ctl_resource"] = kind
		FlowCtl.apply_rate(specs, FlowCtl.rate(specs))
	model.update_item(str(item["id"]), {"specs": specs, "handles": []})


static func _wire(model: GraphModel, scope: String, a: Dictionary, ah: String, b: Dictionary, bh: String, kind: String) -> String:
	var c := {"polarity": "resource", "resource_type": kind, "scope_id": scope,
		"source_item_id": str(a["id"]), "source_handle_id": ah,
		"target_item_id": str(b["id"]), "target_handle_id": bh}
	model.add_connection(c)
	return str(c["id"])


static func link(model: GraphModel, from_id: String, to_id: String) -> Dictionary:
	var a := model.get_item(from_id)
	var b := model.get_item(to_id)
	if a.is_empty() or b.is_empty() or from_id == to_id:
		return _res(false, "", "A pipe needs two different things to join.")
	if _scope_of(a) != _scope_of(b):
		return _res(false, "", "Those two are in different groups.")
	var an := str((a.get("specs", {}) as Dictionary).get("name", "that"))
	var bn := str((b.get("specs", {}) as Dictionary).get("name", "that"))
	if str(a.get("type", "")) == "compound" or str(b.get("type", "")) == "compound":
		return _res(false, "", "Go inside the group to pipe what is in it.")
	for c in model.get_connections_in_scope(_scope_of(a)):
		if str(c.get("source_item_id", "")) == from_id and str(c.get("target_item_id", "")) == to_id \
				and str(c.get("polarity", "")) == "resource":
			return _res(false, "", "%s already feeds %s." % [an, bn])
	# What the pipe carries: the source's kind, unless the source is still
	# free to take the target's.
	var kind := kind_out(a)
	var kb := kind_out(b) if str(b.get("type", "")) == "resource" or FlowCtl.is_flowctl(b.get("specs", {})) else ""
	if _can_rekind(model, a) and not _can_rekind(model, b):
		# A machine target: the first of its inputs the source could be.
		if kb.is_empty():
			var ins: Array = (b.get("specs", {}) as Dictionary).get("inputs", []) as Array
			if not ins.is_empty():
				kb = ResourceKinds.normalize_kind(str((ins[0] as Dictionary).get("kind", "")))
		if not kb.is_empty() and kb != kind:
			_rekind(model, a, kb)
			a = model.get_item(from_id)
			kind = kb
	if kind.is_empty():
		return _res(false, "", "%s has nothing to send down a pipe." % an)
	# A machine with several outputs: the first one the target takes.
	if str(a.get("type", "")) == "processor" and not FlowCtl.is_flowctl(a.get("specs", {})):
		for o in (a.get("specs", {}) as Dictionary).get("outputs", []):
			var ko := ResourceKinds.normalize_kind(str((o as Dictionary).get("kind", "")))
			if not target_handle(b, ko).is_empty() or _can_rekind(model, b):
				kind = ko
				break
	if target_handle(b, kind).is_empty() and _can_rekind(model, b):
		_rekind(model, b, kind)
		b = model.get_item(to_id)
	var ah := source_handle(a, kind)
	var bh := target_handle(b, kind)
	if ah.is_empty():
		return _res(false, "", "%s has nothing to send down a pipe." % an)
	if bh.is_empty():
		return _res(false, "", "%s does not take %s." % [bn, ResourceKinds.display_name(kind).to_lower()])
	return _res(true, _wire(model, _scope_of(a), a, ah, b, bh, kind))


## Put a new part in the pipe `conn_id`: A → new → B.
static func split(model: GraphModel, conn_id: String, tool: String) -> Dictionary:
	var c := model.get_connection(conn_id)
	if c.is_empty() or not (tool in TOOLS):
		return _res(false, "", "There is no pipe there.")
	var a := model.get_item(str(c.get("source_item_id", "")))
	var b := model.get_item(str(c.get("target_item_id", "")))
	if a.is_empty() or b.is_empty():
		return _res(false, "", "That pipe has a loose end.")
	var kind := ResourceKinds.normalize_kind(str(c.get("resource_type", "")))
	if kind.is_empty():
		kind = kind_out(a)
	var scope := str(c.get("scope_id", _scope_of(a)))
	var mid := (Vector2(float(a.get("x", 0.0)), float(a.get("y", 0.0))) + Vector2(float(b.get("x", 0.0)), float(b.get("y", 0.0)))) * 0.5
	var it := new_item(tool, kind, scope, mid)
	(it["specs"] as Dictionary).erase(SHOW_KEY)
	model.add_item(it)
	var n := model.get_item(str(it["id"]))
	var ah := str(c.get("source_handle_id", ""))
	var bh := str(c.get("target_handle_id", ""))
	model.remove_connection(conn_id)
	_wire(model, scope, a, ah, n, target_handle(n, kind), kind)
	_wire(model, scope, n, source_handle(n, kind), b, bh, kind)
	return _res(true, str(it["id"]))


# ── power and data lines (Phase 3b) ─────────────────────────────────────────

const AC_POLARITIES := ["ac", "load", "ac_240"]


static func _name_of(item: Dictionary) -> String:
	return str((item.get("specs", {}) as Dictionary).get("name", "that"))


static func _port_used(model: GraphModel, item_id: String, handle_id: String, polarities: Array) -> bool:
	for c in model.get_connections_in_scope(_scope_of(model.get_item(item_id))):
		if not (str(c.get("polarity", "")) in polarities):
			continue
		if (str(c.get("source_item_id", "")) == item_id and str(c.get("source_handle_id", "")) == handle_id) \
				or (str(c.get("target_item_id", "")) == item_id and str(c.get("target_handle_id", "")) == handle_id):
			return true
	return false


## The port a supply's AC leaves by: one that reads as an output first.
static func ac_out_handle(item: Dictionary, handles_of: Callable) -> String:
	var fallback := ""
	for h in handles_of.call(item):
		var pol := str((h as Dictionary).get("polarity", ""))
		var id := str((h as Dictionary).get("id", ""))
		if pol != "ac":
			continue
		if id.contains("out") or id.begins_with("circuit_"):
			return id
		if fallback.is_empty() and not id.contains("in"):
			fallback = id
	return fallback


## The port a load takes its AC by.
static func ac_in_handle(item: Dictionary, handles_of: Callable) -> String:
	var fallback := ""
	for h in handles_of.call(item):
		var pol := str((h as Dictionary).get("polarity", ""))
		var id := str((h as Dictionary).get("id", ""))
		if not (pol in AC_POLARITIES) or id.contains("out"):
			continue
		if id in ["input", "ac_in", "power_in"]:
			return id
		if fallback.is_empty():
			fallback = id
	return fallback


static func link_power(model: GraphModel, from_id: String, to_id: String, handles_of: Callable) -> Dictionary:
	var a := model.get_item(from_id)
	var b := model.get_item(to_id)
	if a.is_empty() or b.is_empty() or from_id == to_id:
		return _res(false, "", "A wire needs two different things to join.")
	if _scope_of(a) != _scope_of(b):
		return _res(false, "", "Those two are in different groups.")
	var ah := ac_out_handle(a, handles_of)
	if ah.is_empty():
		return _res(false, "", "%s has no AC outlet to wire from. Start at an inverter, a panel or a breaker." % _name_of(a))
	var bh := ac_in_handle(b, handles_of)
	if bh.is_empty():
		return _res(false, "", "%s does not take AC power." % _name_of(b))
	for c in model.get_connections_in_scope(_scope_of(a)):
		if str(c.get("source_item_id", "")) == from_id and str(c.get("target_item_id", "")) == to_id \
				and str(c.get("polarity", "")) in AC_POLARITIES:
			return _res(false, "", "%s already powers %s." % [_name_of(a), _name_of(b)])
	var c2 := {"polarity": "ac", "scope_id": _scope_of(a), "source_item_id": from_id, "source_handle_id": ah,
		"target_item_id": to_id, "target_handle_id": bh}
	model.add_connection(c2)
	return _res(true, str(c2["id"]))


## A free data port on `item` for a link to a node of `other_role`.
static func _data_port(model: GraphModel, item: Dictionary, other_role: String, handles_of: Callable) -> String:
	var role := ScadaNet.role_of(item)
	var id := str(item["id"])
	if role == ScadaNet.ROLE_AP and other_role == ScadaNet.ROLE_BOARD:
		return "wifi"
	for h in handles_of.call(item):
		var hid := str((h as Dictionary).get("id", ""))
		if str((h as Dictionary).get("polarity", "")) != ScadaNet.POLARITY or hid == "wifi":
			continue
		if not _port_used(model, id, hid, [ScadaNet.POLARITY]):
			return hid
	return ""


static func link_data(model: GraphModel, from_id: String, to_id: String, handles_of: Callable) -> Dictionary:
	var a := model.get_item(from_id)
	var b := model.get_item(to_id)
	if a.is_empty() or b.is_empty() or from_id == to_id:
		return _res(false, "", "A cable needs two different things to join.")
	if _scope_of(a) != _scope_of(b):
		return _res(false, "", "Those two are in different groups.")
	var ra := ScadaNet.role_of(a)
	var rb := ScadaNet.role_of(b)
	if ra.is_empty():
		return _res(false, "", "%s is not a network device." % _name_of(a))
	if rb.is_empty():
		return _res(false, "", "%s is not a network device." % _name_of(b))
	if ra == ScadaNet.ROLE_BOARD and rb == ScadaNet.ROLE_BOARD:
		return _res(false, "", "A board does not pass data on to another board. Join each to a switch, an access point or the server.")
	for c in model.get_connections_in_scope(_scope_of(a)):
		if not ScadaNet.is_data(c):
			continue
		var s := str(c.get("source_item_id", ""))
		var t := str(c.get("target_item_id", ""))
		if (s == from_id and t == to_id) or (s == to_id and t == from_id):
			return _res(false, "", "%s and %s are already joined." % [_name_of(a), _name_of(b)])
	var ah := _data_port(model, a, rb, handles_of)
	var bh := _data_port(model, b, ra, handles_of)
	if ah.is_empty():
		return _res(false, "", "%s has no free port." % _name_of(a))
	if bh.is_empty():
		return _res(false, "", "%s has no free port." % _name_of(b))
	var c2 := {"polarity": ScadaNet.POLARITY, "scope_id": _scope_of(a), "source_item_id": from_id,
		"source_handle_id": ah, "target_item_id": to_id, "target_handle_id": bh}
	model.add_connection(c2)
	return _res(true, str(c2["id"]))


## Put a breaker in the AC wire `conn_id`: supply → breaker → load.
static func split_power(model: GraphModel, conn_id: String, rating_a: float = 15.0) -> Dictionary:
	var c := model.get_connection(conn_id)
	if c.is_empty() or not (str(c.get("polarity", "")) in AC_POLARITIES):
		return _res(false, "", "A breaker goes in an AC wire. Show the Power lines and click one.")
	var a := model.get_item(str(c.get("source_item_id", "")))
	var b := model.get_item(str(c.get("target_item_id", "")))
	if a.is_empty() or b.is_empty():
		return _res(false, "", "That wire has a loose end.")
	var scope := str(c.get("scope_id", _scope_of(a)))
	var mid := (Vector2(float(a.get("x", 0.0)), float(a.get("y", 0.0))) + Vector2(float(b.get("x", 0.0)), float(b.get("y", 0.0)))) * 0.5
	var it := {"type": BreakerTrip.TYPE, "scope_id": scope, "x": mid.x, "y": mid.y, "width": 80.0, "height": 90.0,
		"specs": BreakerTrip.make_specs("Breaker %d A" % int(rating_a), rating_a)}
	model.add_item(it)
	var first := {"polarity": str(c.get("polarity", "ac")), "scope_id": scope,
		"source_item_id": str(a["id"]), "source_handle_id": str(c.get("source_handle_id", "")),
		"target_item_id": str(it["id"]), "target_handle_id": "input"}
	var second := {"polarity": str(c.get("polarity", "ac")), "scope_id": scope,
		"source_item_id": str(it["id"]), "source_handle_id": "output",
		"target_item_id": str(b["id"]), "target_handle_id": str(c.get("target_handle_id", ""))}
	model.remove_connection(conn_id)
	model.add_connection(first)
	model.add_connection(second)
	return _res(true, str(it["id"]))

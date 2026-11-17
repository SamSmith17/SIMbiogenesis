class_name ScadaOutputs
extends RefCounted

## Real outputs (pure): links from a tag in the game to an entity in Home
## Assistant, so a pump the simulation switches is switched for real. SCADA
## plan, Phase 7. Nothing here talks to anything: ScadaHub sends what `due`
## and `safe_calls` return, and only while the player has ARMED the outputs
## in Live mode.
##
## A link = {id, tag, entity_id, enabled, invert, scale, offset, min, max,
##           deadband, min_interval_s, safe}
##   tag        any tag with a value (a machine's switch "node.<id>", a
##              valve's opening "valve.<id>.open", a control block's output…)
##   entity_id  what takes it. The entity's DOMAIN decides the service:
##                switch / input_boolean / light / fan   turn_on / turn_off
##                number / input_number                  set_value
##                valve                                  set_valve_position
##                                                       (open_valve /
##                                                       close_valve for an
##                                                       on / off tag)
##                cover                                  set_cover_position
##                                                       (open_cover /
##                                                       close_cover)
##   invert     an on / off tag is sent the other way round
##   scale, offset, min, max   a number is sent as value × scale + offset,
##              clamped to [min, max] when max > min
##   deadband   a number is sent again only once it has moved this far (in
##              the entity's units) from what was last sent
##   min_interval_s   never more often than this
##   safe       what the entity is put to when the outputs are disarmed and
##              what the exported watchdog puts it to: "off", "on", "hold"
##              (leave it), or a number (in the entity's units)
##
## `settings` (beside the links) = {heartbeat_entity, heartbeat_s, timeout_s}:
## an input_boolean (toggled) or input_button (pressed) the game touches
## every heartbeat_s while armed; `watchdog_yaml` is the Home Assistant
## automation that puts every output safe when the heartbeat stops.

const BINARY_DOMAINS := ["switch", "input_boolean", "light", "fan"]
const NUMBER_DOMAINS := ["number", "input_number"]
const POSITION_DOMAINS := ["valve", "cover"]
const HEARTBEAT_DOMAINS := ["input_boolean", "input_button"]

const DEFAULT_MIN_INTERVAL_S := 2.0
const DEFAULT_HEARTBEAT_S := 10.0
const DEFAULT_TIMEOUT_S := 45.0
const MAX_LINKS := 64
## At most this many service calls in one pass (the rest go on the next).
const MAX_SENDS := 12


static func domain_of(entity_id: String) -> String:
	var i := entity_id.find(".")
	return entity_id.substr(0, i) if i > 0 else ""


static func supported(entity_id: String) -> bool:
	var d := domain_of(entity_id)
	return entity_id.length() > d.length() + 1 and (d in BINARY_DOMAINS or d in NUMBER_DOMAINS or d in POSITION_DOMAINS)


static func make(id: String, tag: String = "", entity_id: String = "") -> Dictionary:
	return normalized({"id": id, "tag": tag, "entity_id": entity_id})


static func normalized(l: Dictionary) -> Dictionary:
	var safe: Variant = l.get("safe", "off")
	if not (safe is String) or not str(safe) in ["off", "on", "hold"]:
		safe = float(safe) if (safe is float or safe is int) else (str(safe).to_float() if str(safe).is_valid_float() else "off")
	return {
		"id": str(l.get("id", "")), "tag": str(l.get("tag", "")), "entity_id": str(l.get("entity_id", "")).strip_edges(),
		"enabled": bool(l.get("enabled", true)), "invert": bool(l.get("invert", false)),
		"scale": float(l.get("scale", 1.0)), "offset": float(l.get("offset", 0.0)),
		"min": float(l.get("min", 0.0)), "max": float(l.get("max", 0.0)),
		"deadband": maxf(float(l.get("deadband", 0.5)), 0.0),
		"min_interval_s": maxf(float(l.get("min_interval_s", DEFAULT_MIN_INTERVAL_S)), 0.2),
		"safe": safe,
	}


static func normalized_settings(s: Dictionary) -> Dictionary:
	return {"heartbeat_entity": str(s.get("heartbeat_entity", "")).strip_edges(),
		"heartbeat_s": clampf(float(s.get("heartbeat_s", DEFAULT_HEARTBEAT_S)), 2.0, 300.0),
		"timeout_s": clampf(float(s.get("timeout_s", DEFAULT_TIMEOUT_S)), 10.0, 3600.0)}


static func clean(links: Array) -> Array:
	var out: Array = []
	var seen := {}
	for l in links:
		if not (l is Dictionary) or out.size() >= MAX_LINKS:
			continue
		var n := normalized(l)
		if str(n["id"]).is_empty() or seen.has(n["id"]):
			continue
		seen[n["id"]] = true
		out.append(n)
	return out


## What the entity is sent for a tag value: {binary: bool, on: bool} or
## {binary: false, value: float}. `tag_binary` = the tag is on / off.
static func value_for(link: Dictionary, tag_value: float, tag_binary: bool) -> Dictionary:
	var d := domain_of(str(link["entity_id"]))
	if d in BINARY_DOMAINS or (d in POSITION_DOMAINS and tag_binary):
		var on := tag_value > 0.5
		return {"binary": true, "on": on != bool(link["invert"])}
	var v := tag_value
	if tag_binary and bool(link["invert"]):
		v = 1.0 - v
	v = v * float(link["scale"]) + float(link["offset"])
	if float(link["max"]) > float(link["min"]):
		v = clampf(v, float(link["min"]), float(link["max"]))
	if d in POSITION_DOMAINS:
		v = clampf(v, 0.0, 100.0)
	return {"binary": false, "value": v}


## {domain, service, data} for sending `what` (value_for's result) to the
## link's entity; {} for an entity the game cannot drive.
static func call_for(link: Dictionary, what: Dictionary) -> Dictionary:
	var e := str(link["entity_id"])
	var d := domain_of(e)
	if not supported(e):
		return {}
	if bool(what.get("binary", false)):
		var on := bool(what.get("on", false))
		match d:
			"valve":
				return {"domain": d, "service": "open_valve" if on else "close_valve", "data": {}}
			"cover":
				return {"domain": d, "service": "open_cover" if on else "close_cover", "data": {}}
		if d in BINARY_DOMAINS:
			return {"domain": d, "service": "turn_on" if on else "turn_off", "data": {}}
		return {"domain": d, "service": "set_value", "data": {"value": 1.0 if on else 0.0}}
	var v := snappedf(float(what.get("value", 0.0)), 0.01)
	match d:
		"valve":
			return {"domain": d, "service": "set_valve_position", "data": {"position": int(round(v))}}
		"cover":
			return {"domain": d, "service": "set_cover_position", "data": {"position": int(round(v))}}
	if d in NUMBER_DOMAINS:
		return {"domain": d, "service": "set_value", "data": {"value": v}}
	# A number onto an on / off entity: on above a half.
	return {"domain": d, "service": "turn_on" if v > 0.5 else "turn_off", "data": {}}


## What to send for a link's safe state ({} = leave it).
static func safe_what(link: Dictionary) -> Dictionary:
	var s: Variant = link["safe"]
	var d := domain_of(str(link["entity_id"]))
	if s is String and str(s) == "hold":
		return {}
	if s is String:
		var on := str(s) == "on"
		if d in NUMBER_DOMAINS:
			return {"binary": false, "value": float(link["max"]) if on and float(link["max"]) > float(link["min"]) else (float(link["min"]) if float(link["max"]) > float(link["min"]) else (1.0 if on else 0.0))}
		return {"binary": true, "on": on}
	if d in BINARY_DOMAINS:
		return {"binary": true, "on": float(s) > 0.5}
	return {"binary": false, "value": float(s)}


## A key for "what was last sent" (so an unchanged value is not sent again).
static func sent_key(what: Dictionary) -> float:
	if bool(what.get("binary", false)):
		return 1.0 if bool(what.get("on", false)) else 0.0
	return float(what.get("value", 0.0))


## The sends due now. `values` = {tag: float (NAN = no reading)}, `binary` =
## {tag: bool}, `sent` = {link id: {v: last key sent, t: when (s)}}.
## Returns [{id, entity_id, what, call, change}] — biggest change first, at
## most MAX_SENDS. A tag with no reading sends nothing (the entity holds).
static func due(links: Array, values: Dictionary, binary: Dictionary, sent: Dictionary, now_s: float) -> Array:
	var out: Array = []
	for l in links:
		if not bool(l["enabled"]) or not supported(str(l["entity_id"])) or str(l["tag"]).is_empty():
			continue
		var tv := float(values.get(str(l["tag"]), NAN))
		if is_nan(tv):
			continue
		var what := value_for(l, tv, bool(binary.get(str(l["tag"]), false)))
		var key := sent_key(what)
		var last: Dictionary = sent.get(str(l["id"]), {})
		var change := INF
		if not last.is_empty():
			if now_s - float(last.get("t", -INF)) < float(l["min_interval_s"]):
				continue
			change = absf(key - float(last.get("v", NAN)))
			if bool(what.get("binary", false)):
				if change < 0.5:
					continue
			elif change < maxf(float(l["deadband"]), 1e-6):
				continue
		var call := call_for(l, what)
		if call.is_empty():
			continue
		out.append({"id": str(l["id"]), "entity_id": str(l["entity_id"]), "what": what, "call": call, "change": change, "key": key})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["change"]) > float(b["change"]))
	if out.size() > MAX_SENDS:
		out = out.slice(0, MAX_SENDS)
	return out


## Every enabled link's safe state as calls: [{id, entity_id, what, call}].
static func safe_calls(links: Array) -> Array:
	var out: Array = []
	for l in links:
		if not bool(l["enabled"]) or not supported(str(l["entity_id"])):
			continue
		var what := safe_what(l)
		if what.is_empty():
			continue
		var call := call_for(l, what)
		if not call.is_empty():
			out.append({"id": str(l["id"]), "entity_id": str(l["entity_id"]), "what": what, "call": call})
	return out


## The heartbeat's service call ({} = none set / not a heartbeat entity).
static func heartbeat_call(settings: Dictionary) -> Dictionary:
	var e := str(settings.get("heartbeat_entity", ""))
	match domain_of(e):
		"input_boolean":
			return {"domain": "input_boolean", "service": "toggle", "entity_id": e, "data": {}}
		"input_button":
			return {"domain": "input_button", "service": "press", "entity_id": e, "data": {}}
	return {}


## Problems with the set, in words: [{level error | warn, text, id}].
static func checks(links: Array, settings: Dictionary) -> Array:
	var out: Array = []
	var by_entity := {}
	for l in links:
		var e := str(l["entity_id"])
		if str(l["tag"]).is_empty():
			out.append({"level": "error", "text": "An output has no tag to follow.", "id": str(l["id"])})
		if e.is_empty():
			out.append({"level": "error", "text": "%s has no entity to drive." % _name(l), "id": str(l["id"])})
		elif not supported(e):
			out.append({"level": "error", "text": "%s cannot be driven (switches, lights, fans, helpers, numbers, valves and covers can)." % e, "id": str(l["id"])})
		elif bool(l["enabled"]):
			if by_entity.has(e):
				out.append({"level": "error", "text": "%s is driven by two outputs." % e, "id": str(l["id"])})
			by_entity[e] = true
		if l["safe"] is String and str(l["safe"]) == "hold" and bool(l["enabled"]):
			out.append({"level": "warn", "text": "%s has no safe state: it stays as it is when the game lets go." % (e if not e.is_empty() else _name(l)), "id": str(l["id"])})
	var hb := str(settings.get("heartbeat_entity", ""))
	if hb.is_empty():
		out.append({"level": "warn", "text": "No heartbeat: if the game stops, the outputs stay as they were. Add a toggle helper and the watchdog automation.", "id": ""})
	elif not domain_of(hb) in HEARTBEAT_DOMAINS:
		out.append({"level": "error", "text": "The heartbeat must be an input_boolean or an input_button helper.", "id": ""})
	return out


static func has_errors(chk: Array) -> bool:
	for c in chk:
		if str(c.get("level", "")) == "error":
			return true
	return false


static func _name(l: Dictionary) -> String:
	return "The output for %s" % str(l["tag"]) if not str(l["tag"]).is_empty() else "An output"


## The watchdog for Home Assistant: when the heartbeat has not changed for
## `timeout_s`, every output goes to its safe state. Paste it into
## automations.yaml.
static func watchdog_yaml(links: Array, settings: Dictionary, title: String = "SIMbiogenesis") -> String:
	var st := normalized_settings(settings)
	var hb := str(st["heartbeat_entity"])
	var lines: Array = []
	lines.append("# %s outputs: safe states when the game stops talking." % title)
	lines.append("# The game touches %s every %d s while its outputs are armed." % [hb if not hb.is_empty() else "<a toggle helper>", int(st["heartbeat_s"])])
	lines.append("- alias: \"%s watchdog: outputs safe\"" % title)
	lines.append("  mode: single")
	lines.append("  trigger:")
	lines.append("    - platform: state")
	lines.append("      entity_id: %s" % (hb if not hb.is_empty() else "input_boolean.simbio_heartbeat"))
	lines.append("      for:")
	lines.append("        seconds: %d" % int(st["timeout_s"]))
	lines.append("  action:")
	var n := 0
	for c in safe_calls(links):
		var call: Dictionary = c["call"]
		lines.append("    - service: %s.%s" % [str(call["domain"]), str(call["service"])])
		lines.append("      target:")
		lines.append("        entity_id: %s" % str(c["entity_id"]))
		var data: Dictionary = call["data"]
		if not data.is_empty():
			lines.append("      data:")
			for k in data.keys():
				lines.append("        %s: %s" % [str(k), str(data[k])])
		n += 1
	if n == 0:
		lines.append("    # (no output has a safe state yet)")
		lines.append("    - delay: 0")
	return "\n".join(lines) + "\n"


## In words, for a journal line or a row.
static func describe(what: Dictionary) -> String:
	if what.is_empty():
		return "left as it is"
	if bool(what.get("binary", false)):
		return "on" if bool(what.get("on", false)) else "off"
	return str(snappedf(float(what.get("value", 0.0)), 0.1))

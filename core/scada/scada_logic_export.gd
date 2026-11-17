class_name ScadaLogicExport
extends RefCounted
## Control blocks as Home Assistant YAML (and a PID as an ESPHome snippet),
## so logic designed here can run on the real site.
##
##   band, interlock, timer, counter, duty  → `automation:` entries
##   sequence                               → a `script:`
##   pid                                    → an ESPHome `climate: pid` block,
##                                            as a commented snippet (Home
##                                            Assistant has no PID of its own)
##
## Tags become entity ids through `entity_of` (Callable(tag) -> String); the
## default (`default_entity`) keeps ids that already are entity ids (a
## board's, Home Assistant's) and makes plain ones for graph tags, which the
## player then replaces with their own. Nothing is sent anywhere: this is
## text.
##
## Pure and autoload-free.

const DOMAINS := ["sensor", "binary_sensor", "switch", "number", "input_number", "input_boolean", "light", "fan",
	"climate", "valve", "cover"]


static func slug(s: String) -> String:
	var out := ""
	for ch in s.to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	while out.contains("__"):
		out = out.replace("__", "_")
	return out.trim_prefix("_").trim_suffix("_")


static func default_entity(tag: String) -> String:
	var parts := tag.split(".")
	# A graph valve's opening (valve.<id>.open), not a Home Assistant valve.
	if parts[0] == "valve" and parts.size() >= 3 and parts[parts.size() - 1] == "open":
		return "number.%s" % slug(tag)
	if parts.size() >= 2 and parts[0] in DOMAINS:
		return tag
	if parts[0] == "node":
		return "switch.%s" % slug(tag.substr(5))
	if parts[0] == "valve":
		return "number.%s" % slug(tag)
	return "sensor.%s" % slug(tag)


static func _ent(tag: String, entity_of: Callable) -> String:
	var e := str(entity_of.call(tag)) if entity_of.is_valid() else ""
	return e if not e.is_empty() else default_entity(tag)


static func _num(v: float) -> String:
	return str(int(v)) if absf(v - round(v)) < 1e-6 else str(snappedf(v, 0.01))


## The service lines that set `entity` to `value` (a switch: 0 / 1).
static func _set_lines(entity: String, value: float, ind: String) -> Array:
	var dom := entity.split(".")[0]
	if dom in ["number", "input_number"]:
		return ["%s- service: %s.set_value" % [ind, dom], "%s  target:" % ind, "%s    entity_id: %s" % [ind, entity],
			"%s  data:" % ind, "%s    value: %s" % [ind, _num(value)]]
	var svc := "turn_on" if value >= 0.5 else "turn_off"
	if dom == "valve":
		svc = "open_valve" if value >= 0.5 else "close_valve"
	return ["%s- service: %s.%s" % [ind, dom if dom in ["switch", "light", "fan", "input_boolean", "valve"] else "homeassistant", svc],
		"%s  target:" % ind, "%s    entity_id: %s" % [ind, entity]]


## A numeric_state trigger (or condition body) for one comparison.
static func _numeric(entity: String, op: String, value: float, ind: String, as_condition: bool) -> Array:
	var head := "%s- condition: numeric_state" % ind if as_condition else "%s- platform: numeric_state" % ind
	var out: Array = [head, "%s  entity_id: %s" % [ind, entity]]
	if op in [">", ">="]:
		out.append("%s  above: %s" % [ind, _num(value)])
	elif op in ["<", "<="]:
		out.append("%s  below: %s" % [ind, _num(value)])
	else:
		# == / != : a template.
		out = ["%s- %s: template" % [ind, "condition" if as_condition else "platform"],
			"%s  value_template: \"{{ states('%s') | float(0) %s %s }}\"" % [ind, entity, op, _num(value)]]
	return out


static func _auto(id: String, alias: String, trigger: Array, condition: Array, action: Array, mode: String = "single") -> Array:
	var out: Array = ["- id: %s" % id, "  alias: \"%s\"" % alias.replace("\"", "'"), "  mode: %s" % mode, "  trigger:"]
	out.append_array(trigger)
	if not condition.is_empty():
		out.append("  condition:")
		out.append_array(condition)
	out.append("  action:")
	out.append_array(action)
	return out


## → {yaml, notes: [..], automations, scripts}.
static func export(blocks: Array, entity_of: Callable = Callable(), prefix: String = "simbio") -> Dictionary:
	var autos: Array = []
	var scripts: Array = []
	var extra: Array = []
	var counters: Array = []
	var booleans: Array = []
	var notes: Array = []
	var n_auto := 0
	var n_script := 0
	for b in blocks:
		if not (b is Dictionary) or not bool(b.get("enabled", true)):
			continue
		var id := "%s_%s" % [prefix, slug(str(b.get("id", "")))]
		var nm := str(b.get("name", b.get("id", "")))
		match str(b.get("kind", "")):
			"band":
				var pv := _ent(str(b.get("pv", "")), entity_of)
				var out := _ent(str(b.get("out", "")), entity_of)
				var fill := str(b.get("direction", "fill")) != "drain"
				autos.append_array(_auto(id + "_low", nm + " (low)", _numeric(pv, "<", float(b.get("low", 0.0)), "    ", false), [],
					_set_lines(out, 1.0 if fill else 0.0, "    ")))
				autos.append_array(_auto(id + "_high", nm + " (high)", _numeric(pv, ">", float(b.get("high", 0.0)), "    ", false), [],
					_set_lines(out, 0.0 if fill else 1.0, "    ")))
				n_auto += 2
			"interlock":
				var trig: Array = []
				var cond: Array = []
				for c in b.get("when", []):
					if c is Dictionary and not str((c as Dictionary).get("tag", "")).is_empty():
						var e := _ent(str(c["tag"]), entity_of)
						trig.append_array(_numeric(e, str(c.get("op", ">")), float(c.get("value", 0.0)), "    ", false))
						cond.append_array(_numeric(e, str(c.get("op", ">")), float(c.get("value", 0.0)), "    ", true))
				var out2 := _ent(str(b.get("out", "")), entity_of)
				# Also when something else switches the output while tripped.
				trig.append_array(["    - platform: state", "      entity_id: %s" % out2])
				var wrap: Array = ["    - condition: %s" % ("and" if str(b.get("match", "any")) == "all" else "or"), "      conditions:"]
				for ln in cond:
					wrap.append("    " + str(ln))
				autos.append_array(_auto(id, nm, trig, wrap, _set_lines(out2, float(b.get("safe", 0.0)), "    "), "restart"))
				n_auto += 1
				if bool(b.get("latch", false)):
					notes.append("%s: the latch (stay tripped until reset) is not exported; it re-arms by itself." % nm)
			"timer":
				var out3 := _ent(str(b.get("out", "")), entity_of)
				var act: Array = ["    - repeat:", "        while: \"{{ true }}\"", "        sequence:"]
				for ln in _set_lines(out3, 1.0, "        "):
					act.append("  " + str(ln))
				act.append("          - delay: {minutes: %s}" % _num(float(b.get("on_min", 0.0))))
				for ln in _set_lines(out3, 0.0, "        "):
					act.append("  " + str(ln))
				act.append("          - delay: {minutes: %s}" % _num(float(b.get("off_min", 0.0))))
				autos.append_array(_auto(id, nm, ["    - platform: homeassistant", "      event: start"], [], act, "restart"))
				n_auto += 1
				notes.append("%s: the cycle starts when Home Assistant starts, not at the offset set here." % nm)
			"counter":
				var pv2 := _ent(str(b.get("pv", "")), entity_of)
				counters.append_array(["  %s:" % id, "    name: \"%s\"" % nm.replace("\"", "'")])
				autos.append_array(_auto(id, nm, _numeric(pv2, str(b.get("op", ">")), float(b.get("value", 0.5)), "    ", false), [],
					["    - service: counter.increment", "      target:", "        entity_id: counter.%s" % id]))
				n_auto += 1
			"duty":
				var outs: Array = b.get("outs", []) as Array
				if outs.size() >= 2:
					var a := _ent(str(outs[0]), entity_of)
					var bb := _ent(str(outs[1]), entity_of)
					booleans.append_array(["  %s_lead_b:" % id, "    name: \"%s: second one leads\"" % nm.replace("\"", "'")])
					var trig2: Array = []
					var cond2: Array = []
					for c in b.get("when", []):
						if c is Dictionary and not str((c as Dictionary).get("tag", "")).is_empty():
							var e2 := _ent(str(c["tag"]), entity_of)
							trig2.append_array(_numeric(e2, str(c.get("op", ">")), float(c.get("value", 0.0)), "    ", false))
							cond2.append_array(_numeric(e2, str(c.get("op", ">")), float(c.get("value", 0.0)), "        ", true))
					var act2: Array = ["    - choose:", "        - conditions:", "            - condition: state",
						"              entity_id: input_boolean.%s_lead_b" % id, "              state: \"on\"", "          sequence:"]
					for ln in _set_lines(bb, 1.0, "            "):
						act2.append(str(ln))
					act2.append("      default:")
					for ln in _set_lines(a, 1.0, "        "):
						act2.append(str(ln))
					autos.append_array(_auto(id + "_start", nm + " (start)", trig2, [], act2))
					n_auto += 1
					notes.append("%s: only the start is exported. Stopping, the swap after its run hours and the assist need a rule of your own." % nm)
			"sequence":
				scripts.append("  %s:" % id)
				scripts.append("    alias: \"%s\"" % nm.replace("\"", "'"))
				scripts.append("    mode: single")
				scripts.append("    sequence:")
				for s in b.get("steps", []):
					if not (s is Dictionary):
						continue
					scripts.append("      # %s" % str(s.get("name", "step")))
					for a2 in (s as Dictionary).get("set", []):
						if a2 is Dictionary and not str((a2 as Dictionary).get("tag", "")).is_empty():
							scripts.append_array(_set_lines(_ent(str(a2["tag"]), entity_of), float(a2.get("value", 0.0)), "      "))
					if float(s.get("min_s", 0.0)) > 0.0:
						scripts.append("      - delay: {seconds: %s}" % _num(float(s.get("min_s", 0.0))))
					var u: Dictionary = (s as Dictionary).get("until", {}) as Dictionary
					if not str(u.get("tag", "")).is_empty():
						scripts.append("      - wait_template: \"{{ states('%s') | float(0) %s %s }}\"" % [
							_ent(str(u["tag"]), entity_of), str(u.get("op", ">")), _num(float(u.get("value", 0.0)))])
						if float(s.get("timeout_s", 0.0)) > 0.0:
							scripts.append("        timeout: {seconds: %s}" % _num(float(s.get("timeout_s", 0.0))))
							scripts.append("        continue_on_timeout: false")
				n_script += 1
				if bool(b.get("repeat", false)):
					notes.append("%s: repeating is not exported; call the script again from an automation." % nm)
			"pid":
				var pv3 := _ent(str(b.get("pv", "")), entity_of)
				var out4 := _ent(str(b.get("out", "")), entity_of)
				var kp := float(b.get("kp", 1.0)) / 100.0
				var ti_s := float(b.get("ti_min", 0.0)) * 60.0
				extra.append_array([
					"# %s: a PID loop. Home Assistant has none of its own; this is the ESPHome form" % nm,
					"# (put it in the board's YAML; `output` must be a float output on that board).",
					"# Gains are per second and per unit of 0..1 output, converted from the game's.",
					"# climate:",
					"#   - platform: pid",
					"#     name: \"%s\"" % nm.replace("\"", "'"),
					"#     sensor: %s        # was %s" % [slug(pv3.get_slice(".", 1)), pv3],
					"#     default_target_temperature: %s" % _num(float(b.get("sp", 0.0))),
					"#     %s: %s   # was %s" % ["cool_output" if bool(b.get("reverse", false)) else "heat_output", slug(out4.get_slice(".", 1)), out4],
					"#     control_parameters:",
					"#       kp: %s" % str(snappedf(kp, 0.00001)),
					"#       ki: %s" % (str(snappedf(kp / ti_s, 0.0000001)) if ti_s > 0.0 else "0"),
					"#       kd: %s" % str(snappedf(kp * float(b.get("td_min", 0.0)) * 60.0, 0.00001)),
				])
				notes.append("%s: exported as an ESPHome snippet in comments; check the sensor and output ids against the board." % nm)
	var lines: Array = ["# Control logic from SIMbiogenesis.",
		"# Entity ids made from graph tags are placeholders: replace them with your own."]
	for n in notes:
		lines.append("# NOTE %s" % str(n))
	lines.append("")
	if not autos.is_empty():
		lines.append("automation:")
		lines.append_array(autos)
		lines.append("")
	if not scripts.is_empty():
		lines.append("script:")
		lines.append_array(scripts)
		lines.append("")
	if not counters.is_empty():
		lines.append("counter:")
		lines.append_array(counters)
		lines.append("")
	if not booleans.is_empty():
		lines.append("input_boolean:")
		lines.append_array(booleans)
		lines.append("")
	lines.append_array(extra)
	return {"yaml": "\n".join(lines) + "\n", "notes": notes, "automations": n_auto, "scripts": n_script}

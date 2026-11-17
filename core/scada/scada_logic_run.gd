class_name ScadaLogicRun
extends RefCounted
## Control logic (ScadaLogic) run against a graph MODEL with nothing else:
## the A/B and calibration worlds, a simkit year, a step test on a copy.
## Reads come from the model's specs (and `extra` numbers such as
## sensor.battery_level); writes go straight onto the specs.
##
##   var run := ScadaLogicRun.from_data(hub.logic_data())
##   run.step(model, now_h, {"sensor.battery_level": 62.0}, on_switch)
##
## `on_switch` = Callable(item_id, "turn_on" | "turn_off") for node.<id>
## writes (the world's own way of switching a load); invalid = the specs are
## written here.
##
## Pure and autoload-free.

var blocks: Array = []
var state: Dictionary = {}
var status: Dictionary = {}
## Writes that changed something, in all.
var writes_n := 0
## Per block id: how many of its writes changed something.
var switches: Dictionary = {}
## Per band / PID block id: {h, in_h} = hours judged, hours the reading was
## where the block wants it (a band: between its marks; a PID: within
## PID_BAND of its setpoint).
var perf: Dictionary = {}
var _perf_h := NAN
const PID_BAND_PCT := 5.0
const PID_BAND_MIN := 1.0


static func from_data(data: Variant) -> ScadaLogicRun:
	var r := ScadaLogicRun.new()
	if data is Dictionary:
		for b in (data as Dictionary).get("blocks", []):
			if b is Dictionary and str((b as Dictionary).get("kind", "")) in ScadaLogic.KINDS:
				r.blocks.append((b as Dictionary).duplicate(true))
		if (data as Dictionary).get("state") is Dictionary:
			r.state = ((data as Dictionary)["state"] as Dictionary).duplicate(true)
	return r


func is_empty() -> bool:
	return blocks.is_empty()


static func _on(specs: Dictionary) -> bool:
	return str(specs.get("requested_state", specs.get("current_state", "off"))).to_lower() == "on"


## A graph tag's value off the model (NAN = not a graph tag, or gone):
## tank.<id>.level (%), tank.<id>.stock, node.<id> (0 / 1), valve.<id>.open (%).
static func read_model(model: Object, tag: String) -> float:
	if model == null or tag.is_empty():
		return NAN
	var parts := tag.split(".")
	if parts.size() < 2 or not (parts[0] in ["tank", "node", "valve"]):
		return NAN
	var it: Dictionary = model.call("get_item", parts[1])
	if it.is_empty():
		return NAN
	var specs: Dictionary = it.get("specs", {}) as Dictionary
	if parts[0] == "tank" and parts.size() == 3:
		var lv := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
		if parts[2] == "level":
			return lv * 100.0
		if parts[2] == "stock":
			return lv * float(specs.get("capacity_qty", 0.0))
		return NAN
	if parts[0] == "node" and parts.size() == 2:
		return 1.0 if _on(specs) else 0.0
	if parts[0] == "valve" and parts.size() == 3:
		return clampf(float(specs.get("open", 1.0)), 0.0, 1.0) * 100.0
	return NAN


func read(model: Object, tag: String, extra: Dictionary) -> float:
	if tag.begins_with("logic."):
		for r in ScadaLogic.tags(blocks, status):
			if str(r["id"]) == tag:
				return float(r["value"])
		return NAN
	if extra.has(tag):
		return float(extra[tag])
	return read_model(model, tag)


## One look at every block, the writes made on the model. → how many writes
## changed something this step.
func step(model: Object, now_h: float, extra: Dictionary = {}, on_switch: Callable = Callable()) -> int:
	if blocks.is_empty() or model == null:
		return 0
	var r := ScadaLogic.step(blocks, state, func(tag: String) -> float: return read(model, tag, extra), now_h)
	state = r["state"]
	status = r["status"]
	var pdt := (now_h - _perf_h) if not is_nan(_perf_h) and now_h > _perf_h and now_h - _perf_h <= 0.5 else 0.0
	_perf_h = now_h
	if pdt > 0.0:
		for b in blocks:
			var kind := str((b as Dictionary).get("kind", ""))
			if not (kind in ["band", "pid"]) or not bool(b.get("enabled", true)) or str(b.get("pv", "")).is_empty():
				continue
			var v := read(model, str(b["pv"]), extra)
			if is_nan(v):
				continue
			var ok := false
			if kind == "band":
				ok = v >= float(b.get("low", 0.0)) - 1e-6 and v <= float(b.get("high", 0.0)) + 1e-6
			else:
				var sp := float(b.get("sp", 0.0))
				ok = absf(v - sp) <= maxf(absf(sp) * PID_BAND_PCT / 100.0, PID_BAND_MIN)
			var pf: Dictionary = perf.get(str(b["id"]), {"h": 0.0, "in_h": 0.0})
			pf["h"] = float(pf["h"]) + pdt
			if ok:
				pf["in_h"] = float(pf["in_h"]) + pdt
			perf[str(b["id"])] = pf
	var n := 0
	var writes: Dictionary = r["writes"]
	for tag in writes:
		if apply_write(model, str(tag), float(writes[tag]), on_switch):
			n += 1
			var who := _writer_of(str(tag))
			if not who.is_empty():
				switches[who] = int(switches.get(who, 0)) + 1
	writes_n += n
	return n


func _writer_of(tag: String) -> String:
	for b in blocks:
		if tag in (ScadaLogic.tags_used(b)["writes"] as Array):
			return str((b as Dictionary).get("id", ""))
	return ""


## → true when the model changed.
static func apply_write(model: Object, tag: String, value: float, on_switch: Callable = Callable()) -> bool:
	var parts := tag.split(".")
	if parts.size() < 2 or not (parts[0] in ["node", "valve"]):
		return false
	var it: Dictionary = model.call("get_item", parts[1])
	if it.is_empty():
		return false
	var specs: Dictionary = it.get("specs", {}) as Dictionary
	if parts[0] == "node":
		var want := value >= 0.5
		if want == _on(specs):
			return false
		if on_switch.is_valid():
			on_switch.call(parts[1], "turn_on" if want else "turn_off")
		else:
			specs["requested_state"] = "on" if want else "off"
			specs["current_state"] = specs["requested_state"]
		return true
	var o := clampf(value, 0.0, 100.0) / 100.0
	if absf(float(specs.get("open", 1.0)) - o) < 0.002:
		return false
	specs["open"] = o
	return true


## A short account for a report: [{id, name, kind, text, switches}].
func summary() -> Array:
	var out: Array = []
	for b in blocks:
		var id := str((b as Dictionary).get("id", ""))
		var row := {"id": id, "name": str(b.get("name", id)), "kind": str(b.get("kind", "")),
			"text": str((status.get(id, {}) as Dictionary).get("text", "")), "switches": int(switches.get(id, 0))}
		if perf.has(id) and float(perf[id]["h"]) > 0.0:
			row["in_band_pct"] = snappedf(100.0 * float(perf[id]["in_h"]) / float(perf[id]["h"]), 0.1)
		out.append(row)
	return out


## Design-file blocks → graph blocks: every tank. / node. / valve. tag's item
## id goes through `ids` ({design id: [graph ids]} or {design id: graph id}).
static func remap(blocks_in: Array, ids: Dictionary) -> Array:
	var out: Array = []
	for b in blocks_in:
		if b is Dictionary:
			out.append(_remap_value(b, ids))
	return out


static func _remap_value(v: Variant, ids: Dictionary) -> Variant:
	if v is Dictionary:
		var d := {}
		for k in (v as Dictionary):
			d[k] = _remap_value(v[k], ids)
		return d
	if v is Array:
		var a: Array = []
		for x in (v as Array):
			a.append(_remap_value(x, ids))
		return a
	if v is String:
		var parts := (v as String).split(".")
		if parts.size() >= 2 and parts[0] in ["tank", "node", "valve"] and ids.has(parts[1]):
			var to: Variant = ids[parts[1]]
			if to is Array:
				if (to as Array).is_empty():
					return v
				to = (to as Array)[0]
			parts[1] = str(to)
			return ".".join(parts)
	return v

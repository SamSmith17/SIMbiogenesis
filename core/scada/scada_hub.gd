extends Node
## The live half of the tag list (plans/SCADA_PROCESS_PLAN.md, Phase 1): a
## SystemGraphView child that gathers every tag on the site once a second
## (graph, site power, placed ESP boards, followed Home Assistant entities),
## keeps their history on the sim clock and routes commands.
##
## No class_name on purpose: it reaches autoloads (PerfSpan is autoload-safe,
## HomeAssistant is found by path), and selftests load ScadaTags /
## ScadaHistorian directly.
##
## Readers:
##   book()                -> ScadaTags (current values)
##   history()             -> ScadaHistorian
##   command(id, value)    -> bool (writable tags only)
##   extra_context()       -> automation context of the tags the graph's own
##                            context does not already carry (boards)
##   watch(id) / unwatch   -> keep a long history of this tag and save it

const NODE_NAME := "ScadaHub"
const REFRESH_S := 1.0
const SAVE_KIND := "scada_history"
const ESP_GROUP := "esplab_runtimes"

signal tags_refreshed

var _model: RefCounted = null
var _book := ScadaTags.new()
var _hist := ScadaHistorian.new()
var _acc := 0.0
var _extra_ctx: Dictionary = {}
var _save_path := ""
var _watch_dirty := false
var _main: Node = null


func setup(model: RefCounted) -> void:
	_model = model
	add_to_group(WorldSession.PERSIST_GROUP)


func book() -> ScadaTags:
	return _book


func history() -> ScadaHistorian:
	return _hist


func extra_context() -> Dictionary:
	return _extra_ctx


func watch(id: String) -> void:
	if not _hist.watched.has(id):
		_hist.watched[id] = true
		_watch_dirty = true


func unwatch(id: String) -> void:
	if _hist.watched.erase(id):
		_watch_dirty = true


func is_watched(id: String) -> bool:
	return _hist.watched.has(id)


func _process(delta: float) -> void:
	_logic_acc += delta
	if _logic_acc >= LOGIC_S:
		_logic_acc = 0.0
		logic_tick()
		alarm_tick()
	outputs_tick(delta)
	_acc += delta
	if _acc < REFRESH_S:
		return
	# ~10 ms on a big site: not on a frame another heavy job already took.
	if not FramePacer.claim("scada", _refresh_wait):
		_refresh_wait += 1
		return
	_refresh_wait = 0
	_acc = 0.0
	refresh()


var _refresh_wait := 0


## Gather now (the harness and the tag browser call it directly).
func refresh() -> void:
	PerfSpan.begin("scada_hub")
	_ensure_store()
	var tags: Array = ScadaTags.graph_tags(_model)
	tags.append_array(ScadaTags.site_tags(_site_power()))
	var esp := _esp_tags()
	tags.append_array(esp)
	tags.append_array(ScadaTags.ha_tags(_ha_states()))
	if not _logic_blocks.is_empty():
		tags.append_array(ScadaTags.logic_tags(ScadaLogic.tags(_logic_blocks, _logic_status)))
	if not _alarm_rules.is_empty():
		tags.append_array(ScadaTags.alarm_tags(ScadaAlarms.tags(_alarm_rules, _alarm_status)))
	_book.set_all(tags)
	_extra_ctx = ScadaTags.context(esp)
	var h := now_h()
	if not is_nan(h):
		_hist.record(_book.all(), h)
	PerfSpan.end("scada_hub")
	tags_refreshed.emit()


func now_h() -> float:
	var m := _main_node()
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return NAN


## Command a writable tag. A graph node's run switch goes through its load
## proxy (the automations' own path), else straight onto the item as a
## player's edit.
## Why the last `command` was refused ("" = it was not, or not for a reason
## worth telling the player).
var last_refusal := ""


func command(id: String, value: float) -> bool:
	last_refusal = ""
	var t := _book.tag(id)
	if t.is_empty() or not bool(t.get("writable", false)):
		return false
	if str(t.get("source", "")) != ScadaTags.SOURCE_GRAPH or _model == null:
		return false
	var iid := str(t.get("item", ""))
	if id.begins_with("valve.") and id.ends_with(".open"):
		# An opening, 0..100 %: the operator's edit.
		var vit: Dictionary = _model.call("get_item", iid)
		if vit.is_empty():
			return false
		var vs: Dictionary = (vit.get("specs", {}) as Dictionary).duplicate(true)
		vs["open"] = clampf(value, 0.0, 100.0) / 100.0
		_model.call("update_item", iid, {"specs": vs})
		t["value"] = clampf(value, 0.0, 100.0)
		return true
	# A load switched by a board's relay cannot be reached while the server
	# cannot hear that board.
	var why := relay_fault(iid)
	if not why.is_empty():
		last_refusal = why
		return false
	var on := value >= 0.5
	var host := get_parent().get_node_or_null("GraphSimLoadHost") if get_parent() != null else null
	var proxy: Node = host.call("proxy_for", iid) if host != null and host.has_method("proxy_for") else null
	if proxy != null:
		proxy.call("turn_on" if on else "turn_off")
		# The proxy writes as the simulation (it also follows the inverter).
		# A command is the operator's: a pre-rendered future no longer holds.
		if "user_rev" in _model:
			_model.set("user_rev", int(_model.get("user_rev")) + 1)
	else:
		var item: Dictionary = _model.call("get_item", iid)
		if item.is_empty():
			return false
		var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		specs["requested_state"] = "on" if on else "off"
		specs["current_state"] = specs["requested_state"]
		_model.call("update_item", iid, {"specs": specs})
	t["value"] = 1.0 if on else 0.0
	t["text"] = "on" if on else "off"
	return true


# ── sources ─────────────────────────────────────────────────────────────────

func _main_node() -> Node:
	if _main != null and is_instance_valid(_main):
		return _main
	var p := get_parent()
	if p != null and p.has_method("_get_scene_main_node"):
		_main = p.call("_get_scene_main_node")
	return _main


func _site_power() -> Dictionary:
	var p := get_parent()
	var solar: Node = p.get("_solar_ui") if p != null and "_solar_ui" in p else null
	if solar == null or not is_instance_valid(solar):
		return {}
	var d := {}
	if "battery_kwh_stored" in solar and "BATTERY_CAPACITY_KWH" in solar:
		var cap := float(solar.get("BATTERY_CAPACITY_KWH"))
		if cap > 0.0:
			d["battery_pct"] = float(solar.get("battery_kwh_stored")) / cap * 100.0
	if "current_solar_kw" in solar:
		d["solar_w"] = float(solar.get("current_solar_kw")) * 1000.0
	if "current_load_kw" in solar:
		d["load_w"] = float(solar.get("current_load_kw")) * 1000.0
	return d


func _esp_tags() -> Array:
	var out: Array = []
	if not is_inside_tree():
		return out
	for rt in get_tree().get_nodes_in_group(ESP_GROUP):
		if not is_instance_valid(rt) or not rt.has_method("design"):
			continue
		var d: Dictionary = rt.call("design")
		var tags := ScadaTags.esp_tags(str(d.get("friendly", "Board")),
				d.get("entities", []) as Array, rt.get("latest") as Dictionary)
		# A board the server cannot hear reads unavailable (ScadaNet; only
		# once the graph has a server).
		var gid := str(rt.call("graph_item_id")) if rt.has_method("graph_item_id") else ""
		var why := net_fault(gid)
		if not why.is_empty():
			for t: Dictionary in tags:
				t["available"] = false
				t["text"] = why
				t["value"] = NAN
		out.append_array(tags)
	return out


var _net: Dictionary = {}
var _net_key := ""


## Who the server can hear, over the whole graph (cached on its revisions).
func net_reach() -> Dictionary:
	if _model == null:
		return {"enforced": false, "servers": [], "nodes": {}}
	var key := "%d|%d|%d" % [int(_model.get("struct_rev")), int(_model.get("user_rev")), int(Time.get_ticks_msec() / 1000)]
	if key != _net_key:
		_net_key = key
		_net = ScadaNet.reach(GraphNesting.walk_items(_model as GraphModel, "root"), GraphNesting.flat_connections_cached(_model as GraphModel))
	return _net


## "" when the node `gid` is heard (or nothing is enforced), else why not.
func net_fault(gid: String) -> String:
	if gid.is_empty():
		return ""
	var r := net_reach()
	if not bool(r.get("enforced", false)):
		return ""
	var n: Dictionary = (r.get("nodes", {}) as Dictionary).get(gid, {}) as Dictionary
	if n.is_empty() or bool(n.get("ok", true)):
		return ""
	return str(n.get("why", "not heard"))


func _ha_states() -> Dictionary:
	var out := {}
	if not is_inside_tree():
		return out
	var ha := get_tree().root.get_node_or_null("HomeAssistant")
	if ha == null or not ha.has_method("latest"):
		return out
	for eid in ha.get("subscribed_entities"):
		var l: Dictionary = ha.call("latest", str(eid))
		if not l.is_empty():
			out[str(eid)] = str(l.get("value", ""))
	return out


# ── the world's file ────────────────────────────────────────────────────────

func _path() -> String:
	var view := get_parent()
	var key := ""
	if view != null and view.has_method("_resolve_map_graph_key"):
		key = str(view.call("_resolve_map_graph_key"))
	if key.is_empty():
		return ""
	return WorldPaths.keyed_file(SAVE_KIND, key.trim_prefix("map_"), "json")


func _ensure_store() -> void:
	var path := _path()
	if path == _save_path:
		return
	_save_path = path
	_hist.clear()
	_hist.watched.clear()
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		_hist.from_dict(data)
		for id in data.get("watched", []):
			_hist.watched[str(id)] = true


## WorldSession's flush: the watched tags' history and the watch list.
func flush_world_state() -> void:
	if _save_path.is_empty() or (_hist.watched.is_empty() and not _watch_dirty
			and not FileAccess.file_exists(_save_path)):
		return
	var d := _hist.to_dict(_hist.watched.keys(), 2000) if not _hist.watched.is_empty() \
			else {"version": ScadaHistorian.VERSION, "tags": {}}
	d["watched"] = _hist.watched.keys()
	var f := FileAccess.open(_save_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		_watch_dirty = false


# ── instruments: what the placed boards measure on the graph ────────────────

## Every board reading bound to a graph item (EspBindings): [{id (entity id),
## item (the graph item measured), board (the board's graph node), src,
## label, text, available}].
func esp_instruments() -> Array:
	var out: Array = []
	if not is_inside_tree():
		return out
	for rt in get_tree().get_nodes_in_group(ESP_GROUP):
		if not is_instance_valid(rt) or not rt.has_method("design"):
			continue
		var d: Dictionary = rt.call("design")
		var latest: Dictionary = rt.get("latest") as Dictionary
		var gid := str(rt.call("graph_item_id")) if rt.has_method("graph_item_id") else ""
		var why := net_fault(gid)
		for e in d.get("entities", []):
			if not (e is Dictionary):
				continue
			var src := str(e.get("src", ""))
			var item := EspBindings.item_of(src)
			if item.is_empty():
				continue
			var eid := str(e.get("entity_id", ""))
			var l: Dictionary = latest.get(eid, {}) as Dictionary
			var ok := bool(l.get("available", false)) and why.is_empty()
			out.append({"id": eid, "item": item, "board": gid, "src": src, "label": str(e.get("name", eid)),
				"text": str(l.get("text", "")) if ok else (why if not why.is_empty() else "no reading"), "available": ok})
	return out


## "" when `item_id` can be switched; else why not: every relay bound to it
## is on a board the server cannot hear.
func relay_fault(item_id: String) -> String:
	var r := net_reach()
	if not bool(r.get("enforced", false)):
		return ""
	var why := ""
	var relays := 0
	for ins in esp_instruments():
		if str(ins["src"]) != "item.%s.switch" % item_id:
			continue
		relays += 1
		var f := net_fault(str(ins["board"]))
		if f.is_empty():
			return ""
		why = f
	if relays == 0:
		return ""
	return "Its relay's board cannot be reached (%s)." % why


# ── control logic (ScadaLogic), live on the graph ───────────────────────────

const LOGIC_S := 0.1

signal logic_changed

var _logic_blocks: Array = []
var _logic_state: Dictionary = {}
var _logic_status: Dictionary = {}
var _logic_acc := 0.0
var _logic_notes: Dictionary = {}


func logic_blocks() -> Array:
	return _logic_blocks


func logic_status() -> Dictionary:
	return _logic_status


## A write the logic wanted and could not make: {tag: why}.
func logic_notes() -> Dictionary:
	return _logic_notes


func logic_block(id: String) -> Dictionary:
	for b in _logic_blocks:
		if str((b as Dictionary).get("id", "")) == id:
			return b
	return {}


func new_logic_id() -> String:
	var n := 1
	while not logic_block("b%d" % n).is_empty():
		n += 1
	return "b%d" % n


## Replace the blocks (the editor's edits: the player's, so the graph is
## marked for saving and a pre-rendered future no longer holds).
func set_logic_blocks(blocks: Array) -> void:
	_logic_blocks = blocks.duplicate(true)
	var keep := {"_last_h": _logic_state.get("_last_h", NAN)}
	for b in _logic_blocks:
		var id := str((b as Dictionary).get("id", ""))
		if _logic_state.has(id):
			keep[id] = _logic_state[id]
	_logic_state = keep
	if _model != null and "user_rev" in _model:
		_model.set("user_rev", int(_model.get("user_rev")) + 1)
	var p := get_parent()
	if p != null and p.has_method("_mark_dirty_for_autosave"):
		p.call("_mark_dirty_for_autosave")
	logic_tick()
	logic_changed.emit()


func logic_command(id: String, what: String, value: float = 0.0) -> void:
	_logic_state = ScadaLogic.command(_logic_blocks, _logic_state, id, what, value)
	logic_tick()
	logic_changed.emit()


## Saved with the graph.
func logic_data() -> Dictionary:
	if _logic_blocks.is_empty():
		return {}
	return {"blocks": _logic_blocks.duplicate(true), "state": _logic_state.duplicate(true)}


func set_logic_data(data: Variant) -> void:
	_logic_blocks = []
	_logic_state = {}
	_logic_status = {}
	if data is Dictionary:
		for b in (data as Dictionary).get("blocks", []):
			if b is Dictionary and str((b as Dictionary).get("kind", "")) in ScadaLogic.KINDS:
				_logic_blocks.append((b as Dictionary).duplicate(true))
		if (data as Dictionary).get("state") is Dictionary:
			_logic_state = ((data as Dictionary)["state"] as Dictionary).duplicate(true)
	logic_changed.emit()


## A tag's value right now, straight from the graph where it can be (the
## tag list itself is gathered once a second: too slow for a loop).
func read_now(tag: String) -> float:
	if tag.is_empty():
		return NAN
	if tag.begins_with("logic."):
		for r in ScadaLogic.tags(_logic_blocks, _logic_status):
			if str(r["id"]) == tag:
				return float(r["value"])
		return NAN
	if tag.begins_with("alarm."):
		var aid := tag.substr(6)
		if (_alarm_status.get(aid, {}) as Dictionary).is_empty():
			return NAN
		return 1.0 if bool((_alarm_status[aid] as Dictionary).get("active", false)) else 0.0
	if _model != null:
		var parts := tag.split(".")
		if parts.size() >= 2 and parts[0] in ["tank", "node", "valve"]:
			var it: Dictionary = _model.call("get_item", parts[1])
			if not it.is_empty():
				var specs: Dictionary = it.get("specs", {}) as Dictionary
				if parts[0] == "tank" and parts.size() == 3 and parts[2] == "level":
					return clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * 100.0
				if parts[0] == "tank" and parts.size() == 3 and parts[2] == "stock":
					return clampf(float(specs.get("level", 0.0)), 0.0, 1.0) * float(specs.get("capacity_qty", 0.0))
				if parts[0] == "node" and parts.size() == 2:
					return 1.0 if str(specs.get("requested_state", specs.get("current_state", "off"))).to_lower() == "on" else 0.0
				if parts[0] == "valve" and parts.size() == 3:
					return clampf(float(specs.get("open", 1.0)), 0.0, 1.0) * 100.0
	var t := _book.tag(tag)
	if t.is_empty() or not bool(t.get("available", false)):
		return NAN
	return float(t.get("value", NAN))


## One look at every block: step, then make the writes that change anything.
## A logic write is the SIMULATION's (like an automation's), not an edit.
## Inside a pre-rendered stretch nothing is stepped: the state the render
## reached at that hour is shown.
func logic_tick() -> void:
	if _logic_blocks.is_empty() or _model == null:
		return
	var p := get_parent()
	if p != null and bool(p.get("_ambient_flow_suspended")):
		return
	var h := now_h()
	if is_nan(h):
		return
	if p != null and bool(p.get("_replaying")):
		_adopt_rendered(h)
		return
	_logic_run(h, p)


func _logic_run(h: float, p: Node) -> void:
	PerfSpan.begin("scada_logic")
	var r := ScadaLogic.step(_logic_blocks, _logic_state, read_now, h)
	_logic_state = r["state"]
	_logic_status = r["status"]
	var writes: Dictionary = r["writes"]
	var notes := {}
	var bracket := false
	for tag in writes:
		var why := _logic_write(str(tag), float(writes[tag]), p, bracket)
		if why == "#wrote":
			bracket = true
		elif not why.is_empty():
			notes[tag] = why
	if bracket and p != null and p.has_method("_end_sim_writes"):
		p.call("_end_sim_writes")
	_logic_notes = notes
	PerfSpan.end("scada_logic")


# ── the pre-render and the challenge bake ──

var _render_states: Array = []      # [[abs_h, state]], in time order
var _render_snapshot: Dictionary = {}
var _render_last_h := -INF
var _adopted_h := NAN


## A render / bake is about to step the world from `start_h`: keep what the
## logic is now, so it can be put back.
func logic_render_begin(start_h: float) -> void:
	_render_snapshot = {"on": true, "state": _logic_state.duplicate(true), "status": _logic_status.duplicate(true)}
	_render_states = _render_states.filter(func(e: Array) -> bool: return float(e[0]) < start_h - 1e-9)
	_render_last_h = -INF


func logic_render_end() -> void:
	if not bool(_render_snapshot.get("on", false)):
		return
	_logic_state = _render_snapshot["state"]
	_logic_status = _render_snapshot["status"]
	_render_snapshot = {}
	_adopted_h = NAN


## One render / bake step at `h` (SimBakeStepper, before the flow step).
func logic_step_at(h: float) -> void:
	if _logic_blocks.is_empty() or _model == null:
		return
	_logic_run(h, get_parent())
	if h - _render_last_h >= 0.25 - 1e-9:
		_render_states.append([h, _logic_state.duplicate(true), _logic_status.duplicate(true)])
		_render_last_h = h
		if _render_states.size() > 4000:
			_render_states.pop_front()


func _adopt_rendered(h: float) -> void:
	var pick := -1
	for i in range(_render_states.size() - 1, -1, -1):
		if float(_render_states[i][0]) <= h + 1e-9:
			pick = i
			break
	if pick < 0 or float(_render_states[pick][0]) == _adopted_h:
		return
	_adopted_h = float(_render_states[pick][0])
	_logic_state = (_render_states[pick][1] as Dictionary).duplicate(true)
	_logic_status = (_render_states[pick][2] as Dictionary).duplicate(true)


# ── tuning, export, trends ──

## A step test of a PID block on a COPY of the graph (ScadaStepTest).
func tune_block(id: String) -> Dictionary:
	var b := logic_block(id)
	if b.is_empty() or str(b.get("kind", "")) != "pid":
		return {"ok": false, "why": "Not a PID loop."}
	if not (_model is GraphModel):
		return {"ok": false, "why": "No graph."}
	return ScadaStepTest.run(_model as GraphModel, get_parent(), b, now_h())


## The blocks as Home Assistant YAML, written to user://scada_export/logic.yaml.
## → {yaml, notes, automations, scripts, path}.
func export_logic() -> Dictionary:
	var r := ScadaLogicExport.export(_logic_blocks, func(tag: String) -> String:
		var t := _book.tag(tag)
		return tag if not t.is_empty() and str(t.get("source", "")) in [ScadaTags.SOURCE_ESP, ScadaTags.SOURCE_HA] else "")
	DirAccess.make_dir_recursive_absolute("user://scada_export")
	var path := "user://scada_export/logic.yaml"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(str(r["yaml"]))
		f.close()
		r["path"] = ProjectSettings.globalize_path(path)
	return r


## `n` samples of a tag over the last `hours` (NAN = no reading then).
func trend(tag: String, hours: float = 2.0, n: int = 48) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var h := now_h()
	if is_nan(h) or tag.is_empty():
		return out
	for i in n:
		out.append(_hist.value_at(tag, h - hours + hours * float(i + 1) / float(n)))
	return out


## → "" (nothing to change), "#wrote", or why it could not.
func _logic_write(tag: String, value: float, p: Node, in_bracket: bool) -> String:
	var parts := tag.split(".")
	if parts.size() < 2 or not (parts[0] in ["node", "valve"]):
		return "not something logic can drive"
	var iid := parts[1]
	var it: Dictionary = _model.call("get_item", iid)
	if it.is_empty():
		return "gone"
	var specs: Dictionary = it.get("specs", {}) as Dictionary
	var patch := {}
	if parts[0] == "node":
		var want := value >= 0.5
		var is_on := str(specs.get("requested_state", specs.get("current_state", "off"))).to_lower() == "on"
		if want == is_on:
			return ""
		var fault := relay_fault(iid)
		if not fault.is_empty():
			return fault
		var host := p.get_node_or_null("GraphSimLoadHost") if p != null else null
		var proxy: Node = host.call("proxy_for", iid) if host != null and host.has_method("proxy_for") else null
		if proxy != null:
			proxy.call("turn_on" if want else "turn_off")
		# The specs too (the proxy's own write lands a frame later: too late
		# for a render stepping many times inside one frame).
		patch = {"requested_state": "on" if want else "off", "current_state": "on" if want else "off"}
	else:
		var o := clampf(value, 0.0, 100.0) / 100.0
		if absf(float(specs.get("open", 1.0)) - o) < 0.002:
			return ""
		patch = {"open": o}
	if not in_bracket and p != null and p.has_method("_begin_sim_writes"):
		p.call("_begin_sim_writes")
	var ns: Dictionary = specs.duplicate(true)
	ns.merge(patch, true)
	_model.call("update_item", iid, {"specs": ns})
	return "#wrote"


# ── alarms (ScadaAlarms) ────────────────────────────────────────────────────

signal alarms_changed
signal alarm_raised(event: Dictionary)

var _alarm_rules: Array = []
var _alarm_state: Dictionary = {}
var _alarm_status: Dictionary = {}
## Newest last: [{id, what, h, name, priority, text}].
var _alarm_journal: Array = []


func alarm_rules() -> Array:
	return _alarm_rules


func alarm_rule(id: String) -> Dictionary:
	for r in _alarm_rules:
		if str((r as Dictionary).get("id", "")) == id:
			return r
	return {}


func alarm_status() -> Dictionary:
	return _alarm_status


func alarm_journal() -> Array:
	return _alarm_journal


## Worst first: what is in alarm or waiting to be acknowledged.
func alarm_active() -> Array:
	return ScadaAlarms.active_list(_alarm_rules, _alarm_status)


## {active, unack, worst, text, count}.
func alarm_summary() -> Dictionary:
	return ScadaAlarms.summary(_alarm_rules, _alarm_status)


func new_alarm_id() -> String:
	var n := 1
	while not alarm_rule("a%d" % n).is_empty():
		n += 1
	return "a%d" % n


## The player's edit.
func set_alarm_rules(rules: Array) -> void:
	_alarm_rules = rules.duplicate(true)
	var keep := {"_last_h": _alarm_state.get("_last_h", NAN)}
	for r in _alarm_rules:
		var id := str((r as Dictionary).get("id", ""))
		if _alarm_state.has(id):
			keep[id] = _alarm_state[id]
	_alarm_state = keep
	var p := get_parent()
	if p != null and p.has_method("_mark_dirty_for_autosave"):
		p.call("_mark_dirty_for_autosave")
	alarm_tick()
	alarms_changed.emit()


## Rules for what this site has (a high and a low on every store, a trip on
## every interlock, a low battery), added to the ones already there. → how many.
func suggest_alarms() -> int:
	refresh()
	var all := _alarm_rules.duplicate(true)
	var made: Array = []
	var added := ScadaAlarms.suggest(_book.all(), all, func() -> String:
		var n := 1
		while not alarm_rule("a%d" % n).is_empty() or ("a%d" % n) in made:
			n += 1
		made.append("a%d" % n)
		return "a%d" % n)
	if added.is_empty():
		return 0
	all.append_array(added)
	set_alarm_rules(all)
	return added.size()


## "ack" | "shelve" (value = hours) | "unshelve" on one alarm; "ack_all".
func alarm_command(id: String, what: String, value: float = 1.0) -> void:
	var h := now_h()
	if what == "ack_all":
		_alarm_state = ScadaAlarms.ack_all(_alarm_state, _alarm_rules)
	else:
		_alarm_state = ScadaAlarms.command(_alarm_state, id, what, h if not is_nan(h) else 0.0, value)
		_alarm_journal.append({"id": id, "what": what, "h": h, "name": str(alarm_rule(id).get("name", id)),
			"priority": str(alarm_rule(id).get("priority", "medium")), "text": ""})
	alarm_tick()
	alarms_changed.emit()


func alarm_data() -> Dictionary:
	if _alarm_rules.is_empty():
		return {}
	return {"rules": _alarm_rules.duplicate(true), "state": _alarm_state.duplicate(true),
		"journal": _alarm_journal.slice(maxi(_alarm_journal.size() - 100, 0)).duplicate(true)}


func set_alarm_data(data: Variant) -> void:
	_alarm_rules = []
	_alarm_state = {}
	_alarm_status = {}
	_alarm_journal = []
	if data is Dictionary:
		for r in (data as Dictionary).get("rules", []):
			if r is Dictionary and not str((r as Dictionary).get("id", "")).is_empty():
				_alarm_rules.append((r as Dictionary).duplicate(true))
		if (data as Dictionary).get("state") is Dictionary:
			_alarm_state = ((data as Dictionary)["state"] as Dictionary).duplicate(true)
		if (data as Dictionary).get("journal") is Array:
			_alarm_journal = ((data as Dictionary)["journal"] as Array).duplicate(true)
	alarms_changed.emit()


## One look at every rule. Nothing is judged while a render or a bake owns
## the world, or inside a replayed stretch (the alarms are about NOW).
func alarm_tick() -> void:
	if _alarm_rules.is_empty():
		return
	var p := get_parent()
	if p != null and (bool(p.get("_ambient_flow_suspended")) or bool(p.get("_replaying"))):
		return
	var h := now_h()
	if is_nan(h):
		return
	var r := ScadaAlarms.step(_alarm_rules, _alarm_state, read_now, h)
	_alarm_state = r["state"]
	_alarm_status = r["status"]
	var events: Array = r["events"]
	if events.is_empty():
		return
	for e in events:
		_alarm_journal.append(e)
		if str(e["what"]) == "raised":
			alarm_raised.emit(e)
			if p != null and p.has_method("scada_alarm_toast"):
				p.call("scada_alarm_toast", e)
	while _alarm_journal.size() > ScadaAlarms.JOURNAL_MAX:
		_alarm_journal.pop_front()
	alarms_changed.emit()


## {graph item id: {priority, unack}}: the worst alarm on each thing, for a
## picture's outlines.
func alarm_items() -> Dictionary:
	var out := {}
	for a in alarm_active():
		if str(a["state"]) == "rtn":
			continue
		var parts := str(a["tag"]).split(".")
		var iid := ""
		if parts.size() >= 2 and parts[0] in ["tank", "node", "valve"]:
			iid = parts[1]
		elif parts.size() >= 2 and parts[0] == "logic":
			var used := ScadaLogic.tags_used(logic_block(parts[1]))
			for t in (used["writes"] as Array) + (used["reads"] as Array):
				var tp := str(t).split(".")
				if iid.is_empty() and tp.size() >= 2 and tp[0] in ["tank", "node", "valve"]:
					iid = tp[1]
		if iid.is_empty():
			continue
		var cur: Dictionary = out.get(iid, {}) as Dictionary
		var rank := int(ScadaAlarms.PRIORITY_RANK.get(str(a["priority"]), 1))
		if cur.is_empty() or rank < int(ScadaAlarms.PRIORITY_RANK.get(str(cur["priority"]), 1)):
			cur = {"priority": str(a["priority"]), "unack": false, "text": "%s: %s" % [str(a["name"]), str(a["text"])]}
		if str(a["state"]) == "unack":
			cur["unack"] = true
		out[iid] = cur
	return out

# ── real outputs (SCADA plan, Phase 7) ──────────────────────────────────────
#
# Links from tags to Home Assistant entities (ScadaOutputs), saved per world
# (entity ids only). They send NOTHING until the player arms them, and arming
# is refused unless the game is in Live mode and connected. Armed is never
# saved: a world always loads disarmed. Disarming (by hand, on leaving Live
# mode, on a sandbox / render taking the world, on closing the world) first
# puts every output to its safe state.

const OUT_KIND := "scada_outputs"
const OUT_TICK_S := 0.5
const OUT_JOURNAL_MAX := 200

signal outputs_changed

var _out_links: Array = []
var _out_settings: Dictionary = ScadaOutputs.normalized_settings({})
var _out_path := "#"
var _armed := false
var _disarm_reason := ""
var _out_sent: Dictionary = {}
var _out_journal: Array = []
var _out_acc := 0.0
var _hb_last := -INF
var out_sends := 0
## Set by a harness check only: outputs are otherwise never armed under
## --capture / --run-script.
var test_allow_arm := false


func _out_file() -> String:
	var view := get_parent()
	var key := ""
	if view != null and view.has_method("_resolve_map_graph_key"):
		key = str(view.call("_resolve_map_graph_key"))
	if key.is_empty():
		return ""
	return WorldPaths.keyed_file(OUT_KIND, key.trim_prefix("map_"), "json")


func _ensure_outputs() -> void:
	var path := _out_file()
	if path == _out_path:
		return
	# Another world: whatever was armed belongs to the one that closed.
	if _armed:
		disarm("the world changed")
	_out_path = path
	_out_links = []
	_out_settings = ScadaOutputs.normalized_settings({})
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if data is Dictionary:
		_out_links = ScadaOutputs.clean(data.get("links", []) as Array if data.get("links", []) is Array else [])
		_out_settings = ScadaOutputs.normalized_settings(data.get("settings", {}) as Dictionary if data.get("settings", {}) is Dictionary else {})


func _save_outputs() -> void:
	if _out_path.is_empty() or _out_path == "#":
		return
	var f := FileAccess.open(_out_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": 1, "links": _out_links, "settings": _out_settings}))


func output_links() -> Array:
	_ensure_outputs()
	return _out_links.duplicate(true)


func output_settings() -> Dictionary:
	_ensure_outputs()
	return _out_settings.duplicate()


func new_output_id() -> String:
	var n := 1
	var used := {}
	for l in _out_links:
		used[str(l["id"])] = true
	while used.has("o%d" % n):
		n += 1
	return "o%d" % n


## Editing the links disarms first: what is armed is what the player saw.
func set_output_links(links: Array) -> void:
	_ensure_outputs()
	if _armed:
		disarm("the outputs were edited")
	_out_links = ScadaOutputs.clean(links)
	_save_outputs()
	outputs_changed.emit()


func set_output_settings(st: Dictionary) -> void:
	_ensure_outputs()
	if _armed:
		disarm("the outputs were edited")
	_out_settings = ScadaOutputs.normalized_settings(st)
	_save_outputs()
	outputs_changed.emit()


func output_checks() -> Array:
	_ensure_outputs()
	return ScadaOutputs.checks(_out_links, _out_settings)


func outputs_armed() -> bool:
	return _armed


func output_journal() -> Array:
	return _out_journal.duplicate()


## What each link would send now and what it last sent: {id: {value (words),
## sent (words), at_s (seconds ago, -1 = never), reading: bool}}.
func output_rows() -> Dictionary:
	_ensure_outputs()
	var out := {}
	var now := Time.get_ticks_msec() / 1000.0
	for l in _out_links:
		var tv := read_now(str(l["tag"]))
		var row := {"reading": not is_nan(tv), "value": "no reading", "sent": "", "at_s": -1.0}
		if not is_nan(tv):
			row["value"] = ScadaOutputs.describe(ScadaOutputs.value_for(l, tv, _tag_binary(str(l["tag"]))))
		var last: Dictionary = _out_sent.get(str(l["id"]), {})
		if not last.is_empty():
			row["sent"] = str(last.get("text", ""))
			row["at_s"] = now - float(last.get("t", now))
		out[str(l["id"])] = row
	return out


func _tag_binary(tag: String) -> bool:
	if tag.begins_with("node.") or tag.begins_with("alarm.") or tag.ends_with(".tripped"):
		return true
	var t := _book.tag(tag)
	return str(t.get("kind", "")) in ["binary", "switch"]


func _is_live() -> bool:
	var sm := get_node_or_null("/root/SimMode")
	return sm != null and sm.has_method("should_run_realworld_actions") and bool(sm.call("should_run_realworld_actions"))


func _ha() -> Node:
	var ha := get_node_or_null("/root/HomeAssistant")
	return ha if ha != null and ha.has_method("is_authed") else null


func _world_taken() -> String:
	var view := get_parent()
	if view == null:
		return ""
	if bool(view.get("_sandbox_active")):
		return "a tutorial sandbox has the graph"
	if not str(view.get("_fork_edit_id")).is_empty():
		return "a fork is being edited"
	if bool(view.get("_ambient_flow_suspended")):
		return "a render or a challenge has the world"
	if view.has_method("_mp_is_replica") and bool(view.call("_mp_is_replica")):
		return "this is a guest's copy of the world"
	return ""


static func _in_test_run() -> bool:
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--capture") or str(a).begins_with("--run-script"):
			return true
	return false


## Why the outputs cannot be armed now ("" = they can).
func arm_refusal() -> String:
	_ensure_outputs()
	if _in_test_run() and not test_allow_arm:
		return "Outputs are never armed in a test run."
	var any := false
	for l in _out_links:
		any = any or bool(l["enabled"])
	if not any:
		return "Add an output first."
	var chk := ScadaOutputs.checks(_out_links, _out_settings)
	for c in chk:
		if str(c["level"]) == "error":
			return str(c["text"])
	var taken := _world_taken()
	if not taken.is_empty():
		return "Not now: %s." % taken
	if not _is_live():
		return "Turn on Live mode first (the real clock, at 1×)."
	var ha := _ha()
	if ha == null or not bool(ha.call("is_authed")):
		return "Home Assistant isn't connected (Settings → Home Assistant)."
	return ""


## Arm: from now on the links drive their entities. "" on success, else why not.
func arm() -> String:
	var why := arm_refusal()
	if not why.is_empty():
		last_refusal = why
		return why
	_armed = true
	_disarm_reason = ""
	_out_sent = {}
	_hb_last = -INF
	_out_acc = OUT_TICK_S
	_journal_out("Armed: %s." % UiText.count(_enabled_count(), "output"))
	outputs_changed.emit()
	_out_toast("Outputs ARMED: the game now drives %s in Home Assistant." % UiText.count(_enabled_count(), "real device"), true)
	return ""


func _enabled_count() -> int:
	var n := 0
	for l in _out_links:
		if bool(l["enabled"]) and ScadaOutputs.supported(str(l["entity_id"])):
			n += 1
	return n


## Disarm: every output to its safe state (where Home Assistant can still be
## reached), then nothing more is sent.
func disarm(reason: String = "") -> void:
	if not _armed:
		return
	_armed = false
	_disarm_reason = reason
	var ha := _ha()
	var n := 0
	if ha != null and bool(ha.call("is_authed")):
		for c in ScadaOutputs.safe_calls(_out_links):
			var call: Dictionary = c["call"]
			# Forced: leaving Live mode is one of the reasons to be here.
			ha.call("call_service", str(call["domain"]), str(call["service"]), str(c["entity_id"]), call["data"] as Dictionary, true)
			out_sends += 1
			n += 1
	var tail := (" (%s)" % reason) if not reason.is_empty() else ""
	_journal_out("Disarmed%s: %s put safe." % [tail, UiText.count(n, "output")] if n > 0 else "Disarmed%s: Home Assistant could not be reached, so nothing was put safe." % tail)
	_out_sent = {}
	outputs_changed.emit()
	_out_toast("Outputs disarmed%s." % tail, false)


func disarm_reason() -> String:
	return _disarm_reason


func _journal_out(text: String) -> void:
	_out_journal.append({"unix": Time.get_unix_time_from_system(), "text": text})
	if _out_journal.size() > OUT_JOURNAL_MAX:
		_out_journal = _out_journal.slice(_out_journal.size() - OUT_JOURNAL_MAX)


func _out_toast(text: String, armed_now: bool) -> void:
	var view := get_parent()
	if view != null and view.has_method("scada_output_toast"):
		view.call("scada_output_toast", text, armed_now)


## Twice a second (real time): while armed, check it may still be, then send
## what has changed and touch the heartbeat.
func outputs_tick(delta: float) -> void:
	_out_acc += delta
	if _out_acc < OUT_TICK_S:
		return
	_out_acc = 0.0
	_ensure_outputs()
	if not _armed:
		return
	var taken := _world_taken()
	if not taken.is_empty():
		disarm(taken)
		return
	if not _is_live():
		disarm("the game left Live mode")
		return
	var ha := _ha()
	if ha == null or not bool(ha.call("is_authed")):
		disarm("Home Assistant disconnected")
		return
	var now := Time.get_ticks_msec() / 1000.0
	var values := {}
	var binary := {}
	for l in _out_links:
		var tag := str(l["tag"])
		if not values.has(tag):
			values[tag] = read_now(tag)
			binary[tag] = _tag_binary(tag)
	for d in ScadaOutputs.due(_out_links, values, binary, _out_sent, now):
		var call: Dictionary = d["call"]
		ha.call("call_service", str(call["domain"]), str(call["service"]), str(d["entity_id"]), call["data"] as Dictionary)
		var words := ScadaOutputs.describe(d["what"] as Dictionary)
		_out_sent[str(d["id"])] = {"v": float(d["key"]), "t": now, "text": words}
		out_sends += 1
		_journal_out("%s → %s" % [str(d["entity_id"]), words])
	var hb := ScadaOutputs.heartbeat_call(_out_settings)
	if not hb.is_empty() and now - _hb_last >= float(_out_settings["heartbeat_s"]):
		_hb_last = now
		ha.call("call_service", str(hb["domain"]), str(hb["service"]), str(hb["entity_id"]), hb["data"] as Dictionary)
		out_sends += 1


func _exit_tree() -> void:
	disarm("the world closed")


func watchdog_yaml() -> Dictionary:
	_ensure_outputs()
	var text := ScadaOutputs.watchdog_yaml(_out_links, _out_settings)
	var dir := "user://scada_export"
	DirAccess.make_dir_recursive_absolute(dir)
	var path := "%s/watchdog.yaml" % dir
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
	return {"text": text, "path": path}


# ── trends (SCADA plan, Phase 8) ────────────────────────────────────────────
# The pens of the Trends window: tag ids, saved with the graph. A pen's tag is
# WATCHED, so its history is kept long and saved with the world.

signal trends_changed

const MAX_PENS := 8
var _trend_pens: Array = []


func trend_pens() -> Array:
	return _trend_pens.duplicate()


func set_trend_pens(pens: Array) -> void:
	var out: Array = []
	for p in pens:
		var id := str(p)
		if not id.is_empty() and not out.has(id) and out.size() < MAX_PENS:
			out.append(id)
	_trend_pens = out
	for id in out:
		watch(str(id))
	var p2 := get_parent()
	if p2 != null and p2.has_method("_mark_dirty_for_autosave"):
		p2.call("_mark_dirty_for_autosave")
	trends_changed.emit()


func trend_data() -> Dictionary:
	return {"pens": _trend_pens.duplicate()} if not _trend_pens.is_empty() else {}


func set_trend_data(data: Variant) -> void:
	_trend_pens = []
	if data is Dictionary and (data as Dictionary).get("pens") is Array:
		for p in (data as Dictionary)["pens"]:
			if not str(p).is_empty() and not _trend_pens.has(str(p)) and _trend_pens.size() < MAX_PENS:
				_trend_pens.append(str(p))
	trends_changed.emit()


## `n` samples of a tag from `t0` to `t1` (site hours; NAN = no reading
## then). Nothing after now.
func trend_span(tag: String, t0: float, t1: float, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var h := now_h()
	if tag.is_empty() or n < 2 or not (t1 > t0):
		return out
	out.resize(n)
	for i in n:
		var t := t0 + (t1 - t0) * float(i) / float(n - 1)
		out[i] = _hist.value_at(tag, t) if is_nan(h) or t <= h + 1e-6 else NAN
	return out

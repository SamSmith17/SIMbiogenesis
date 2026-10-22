class_name HAEntityLinker
extends Node

## The Home Assistant link runtime for the open world (a SystemGraphView child).
##
## Links live in the world's own file (HaLinkStore, WorldPaths kind
## "ha_links"): any HA entity → any tracked sim value (HaTargets — the site's
## energy picture, the weather station, a graph node's field, a tank). For
## every linked reading the runtime:
##   1. converts it into the target's unit (HaUnits, from the sensor's
##      unit_of_measurement) and applies the link's scale / offset / invert;
##   2. keeps it as the target's latest live value (status for the UI, the
##      graph's 📡 badge through specs.ha_live, the observed track);
##   3. ONLY while TimeDirector is LIVE, the service is connected and the
##      reading is fresh (STALE_S), writes it into the simulation: graph
##      nodes inside the view's sim-write bracket (so the pre-render cache
##      survives), site / weather values through SolarUI.set_live_reading,
##      tanks onto their ResourceTimeline. Outside LIVE the sim runs its own
##      model and the readings are only recorded.
##
## The old places links lived (each node's specs.ha_links, SolarUI's
## solar_ui_ha_entities.cfg) migrate into a world once, the first time it
## opens with no link file.

signal ha_live_updated(item_id: String, role: String, value: float)
signal links_changed()

## A reading older than this no longer drives the sim (the sim takes over).
const STALE_S := 600
## Tanks are re-held at the measured level this often in LIVE (the flow
## engine integrates them every tick).
const HOLD_INTERVAL_S := 1.0

const SOLAR_UI_PATHS := ["Main/UILayer/SolarUI", "UILayer/SolarUI"]

var model: GraphModel = null
var _svc: Node = null
var _solar_ui: Node = null
var _store: HaLinkStore = HaLinkStore.new()
var _store_path: String = ""
var _last: Dictionary = {}       # link id -> {raw, unit, value, ok, warn, t_unix}
var _was_live: bool = false
var _hold_acc: float = 0.0
## Old consumers (history player, CSV player) look links up by entity.
var _routes: Dictionary = {}     # entity_id -> [{item_id, role}]
## Every reading, in the target's unit, on the real clock (the timeline's
## "HA:" tracks and the Live links window's sim-vs-real read it).
var _observed: HaObservedStore = HaObservedStore.new()
var _history_asked: Dictionary = {}   # target id -> true (backfilled this session)
## How far back a newly linked value is filled in from HA's recorder.
const HISTORY_BACKFILL_H := 72.0


func setup(mdl: GraphModel) -> void:
	model = mdl
	_resolve_nodes()
	if model != null and not model.changed.is_connected(_on_model_changed):
		model.changed.connect(_on_model_changed)


func teardown() -> void:
	if _svc != null:
		if _svc.sensor_updated.is_connected(_on_sensor_updated):
			_svc.sensor_updated.disconnect(_on_sensor_updated)
		if _svc.state_changed.is_connected(_on_svc_state):
			_svc.state_changed.disconnect(_on_svc_state)
	_routes.clear()


func _exit_tree() -> void:
	teardown()


# ---------------------------------------------------------------------------
# Store
# ---------------------------------------------------------------------------

## (Re)load this world's links when the world / map changed, migrate the old
## links once, subscribe. Called after the graph loads and after any edit.
func refresh_subscriptions() -> void:
	_resolve_nodes()
	var path := _links_path()
	if path != _store_path:
		_store_path = path
		_store = HaLinkStore.load_from(path)
		_last.clear()
		if not _store.migrated:
			_migrate_legacy()
	_prune()
	_rebuild_routes()
	_tell_solar_ui()
	if _svc != null:
		var ids := _store.entity_ids()
		_svc.call("subscribe_to_entities", ids)
		_svc.call("get_entity_states", ids)
		_publish_summary()
		_backfill_history()
	links_changed.emit()


func store() -> HaLinkStore:
	return _store


func links() -> Array:
	return _store.links.duplicate(true)


func link_for_target(target_id: String) -> Dictionary:
	return _store.for_target(target_id)


func linked_entity_ids() -> Array:
	return _store.entity_ids()


## Link an entity to a target (replacing the target's old link) and save.
func link_entity(entity_id: String, target_id: String, opts: Dictionary = {}) -> Dictionary:
	var l := _store.link(entity_id, target_id, opts)
	_save()
	refresh_subscriptions()
	# A cached reading answers at once.
	if _svc != null:
		var lt: Dictionary = _svc.call("latest", entity_id)
		if not lt.is_empty():
			_on_sensor_updated(entity_id, {"entity_id": entity_id, "state": lt.get("value", ""),
				"attributes": lt.get("attributes", {})})
	return l


func unlink_target(target_id: String) -> void:
	var l := _store.for_target(target_id)
	if l.is_empty():
		return
	_store.unlink_target(target_id)
	_last.erase(str(l["id"]))
	_observed.clear_key(target_id)
	_history_asked.erase(target_id)
	_clear_target_live(target_id)
	_save()
	refresh_subscriptions()


func set_link_fields(link_id: String, patch: Dictionary) -> void:
	if _store.set_fields(link_id, patch):
		_save()
		# Re-convert the last raw reading with the new scale / offset.
		for l in _store.links:
			if str(l["id"]) == link_id:
				var lt: Dictionary = _svc.call("latest", str(l["entity_id"])) if _svc != null else {}
				if not lt.is_empty():
					_take(l, str(lt.get("value", "")), str((lt.get("attributes", {}) as Dictionary).get("unit_of_measurement", "")), true)
		refresh_subscriptions()


## Every target in this world (HaTargets over the graph's items).
func targets() -> Array:
	return HaTargets.all_targets(model.items if model != null else [])


func target(target_id: String) -> Dictionary:
	return HaTargets.find(target_id, model.items if model != null else [])


## What the UI shows for one target: {linked, entity_id, link, value, raw,
## unit, warn, age_s, stale, applies}. `value` is in the target's unit.
func link_status(target_id: String) -> Dictionary:
	var l := _store.for_target(target_id)
	if l.is_empty():
		return {"linked": false}
	var last: Dictionary = _last.get(str(l["id"]), {})
	var age := int(Time.get_unix_time_from_system()) - int(last.get("t_unix", 0)) if not last.is_empty() else -1
	return {"linked": true, "link": l, "entity_id": str(l["entity_id"]),
		"has_value": not last.is_empty() and bool(last.get("ok", false)),
		"value": float(last.get("value", 0.0)), "raw": str(last.get("raw", "")),
		"unit": str(last.get("unit", "")), "warn": str(last.get("warn", "")),
		"age_s": age, "stale": age < 0 or age > STALE_S,
		"applies": _may_apply() and age >= 0 and age <= STALE_S and bool(l.get("enabled", true))}


## The sim's own current value for a target (for "sim vs real"), NAN if unknown.
func sim_value(target_id: String) -> float:
	var p := HaTargets.parse(target_id)
	if p.is_empty():
		return NAN
	var f := str(p["field"])
	if p["scope"] != "item":
		_resolve_nodes()
		if _solar_ui == null:
			return NAN
		match f:
			"battery_soc":
				var cap := float(_solar_ui.get("BATTERY_CAPACITY_KWH")) if _solar_ui.get("BATTERY_CAPACITY_KWH") != null else 0.0
				var kwh := float(_solar_ui.get("battery_kwh_stored")) if _solar_ui.get("battery_kwh_stored") != null else 0.0
				return kwh / cap * 100.0 if cap > 0.0 else NAN
			"solar_kw":
				return float(_solar_ui.get("current_solar_kw")) if _solar_ui.get("current_solar_kw") != null else NAN
			"load_kw":
				return float(_solar_ui.get("current_load_kw")) if _solar_ui.get("current_load_kw") != null else NAN
		if _solar_ui.has_method("get_live_reading_sim"):
			return float(_solar_ui.call("get_live_reading_sim", f))
		return NAN
	var it := model.get_item(str(p["item_id"])) if model != null else {}
	if it.is_empty():
		return NAN
	var s: Dictionary = it.get("specs", {})
	match str(it.get("type", "")):
		"appliance", "acload":
			match f:
				"power": return float(s.get("avg_watts", NAN))
				"switch": return 1.0 if str(s.get("current_state", "")) == "on" else 0.0
				"energy": return float(s.get("energy_kwh", NAN))
		"panel", "controller", "wind", "hydro":
			if f in ["power", "ac_power"]:
				return float(s.get("current_output_kw", NAN)) * 1000.0
		"battery", "smartbattery":
			if f == "soc":
				return float(s.get("soc", NAN)) * 100.0
			if f == "voltage":
				return float(s.get("voltage", NAN))
		"resource":
			if f == "level_pct":
				return float(s.get("level", NAN)) * 100.0
			if f == "stock_l":
				return float(s.get("stock_l", float(s.get("level", 0.0)) * float(s.get("capacity_qty", 0.0))))
		"processor":
			if f == "switch":
				return 1.0 if str(s.get("current_state", "")) == "on" else 0.0
		"shelly4pm":
			var ci := f.substr(1, 1)
			if f.ends_with("_power"): return float(s.get("c%s_power_w" % ci, NAN))
			if f.ends_with("_switch"): return 1.0 if bool(s.get("c%s_on" % ci, false)) else 0.0
			if f.ends_with("_energy"): return float(s.get("c%s_energy_kwh" % ci, NAN))
	return NAN


# ---------------------------------------------------------------------------
# Observed track (recorded readings + HA's own history)
# ---------------------------------------------------------------------------

## `n` bins of a target's recorded readings over [t0, t1) abs hours (NAN where
## nothing was recorded). Real time: the timeline's NOW axis.
func observed_bins(target_id: String, t0: float, t1: float, n: int) -> PackedFloat32Array:
	return _observed.bins(target_id, t0, t1, n, 6.0, HaObservedStore.now_abs_hours())


## Zoom-stable bins of a target's recorded readings (TimelineBinning).
func observed_bins_exact(target_id: String, w: float, i0: int, n: int) -> Dictionary:
	return _observed.bins_exact(target_id, w, i0, n, 6.0, HaObservedStore.now_abs_hours())


func observed_value_at(target_id: String, t_abs: float) -> float:
	return _observed.value_at(target_id, t_abs)


func observed_range(target_id: String) -> Vector2:
	return _observed.range_of(target_id)


func observed_count(target_id: String) -> int:
	return _observed.size(target_id)


## Ask HA's recorder for the last HISTORY_BACKFILL_H of every linked entity
## not filled in yet this session.
func _backfill_history() -> void:
	if _svc == null or not bool(_svc.call("is_authed")):
		return
	var now := Time.get_unix_time_from_system()
	var asked_eids := {}
	for l in _store.links:
		var tid := str(l["target_id"])
		if _history_asked.has(tid) or not bool(l.get("enabled", true)):
			continue
		_history_asked[tid] = true
		var eid := str(l["entity_id"])
		if asked_eids.has(eid):
			continue
		asked_eids[eid] = true
		_svc.call("get_entity_history", eid, HaObservedStore.unix_to_iso(now - HISTORY_BACKFILL_H * 3600.0),
			HaObservedStore.unix_to_iso(now), true)


func _on_history(entity_id: String, rows: Array) -> void:
	var ls := _store.for_entity(entity_id)
	if ls.is_empty() or rows.is_empty():
		return
	var unit := ""
	if _svc != null:
		unit = str((_svc.call("catalog_entry", entity_id) as Dictionary).get("unit", ""))
	var n := 0
	for l in ls:
		var t := target(str(l["target_id"]))
		if t.is_empty():
			continue
		for row in rows:
			if not (row is Dictionary):
				continue
			var tu := HaObservedStore.row_unix(row)
			if is_nan(tu):
				continue
			var raw := str(row.get("s", row.get("state", "")))
			var c := HaUnits.convert(raw, unit, str(t["unit"]))
			if not bool(c["ok"]):
				continue
			var v := HaUnits.adjust(float(c["value"]), float(l.get("scale", 1.0)), float(l.get("offset", 0.0)), bool(l.get("invert", false)))
			if str(t["kind"]) == "binary":
				v = 1.0 if v >= 0.5 else 0.0
			_observed.add(str(l["target_id"]), HaObservedStore.abs_hours_local(tu), v)
			n += 1
	if n > 0:
		print("[HA] Filled %d recorded reading(s) of %s from Home Assistant's history" % [n, entity_id])
		links_changed.emit()


## Returns true if Home Assistant is connected and logged in.
func is_live() -> bool:
	_resolve_nodes()
	return _svc != null and bool(_svc.call("is_authed"))


# ---------------------------------------------------------------------------
# Readings
# ---------------------------------------------------------------------------

func _on_sensor_updated(entity_id: String, state: Dictionary) -> void:
	var ls := _store.for_entity(entity_id)
	if ls.is_empty():
		return
	var attrs: Dictionary = state.get("attributes", {}) if state.get("attributes", {}) is Dictionary else {}
	var unit := str(attrs.get("unit_of_measurement", ""))
	var raw := str(state.get("state", ""))
	for l in ls:
		if bool(l.get("enabled", true)):
			_take(l, raw, unit, true)


## Convert, remember, and (in LIVE) apply one reading for one link.
func _take(l: Dictionary, raw: String, unit: String, apply: bool) -> void:
	var t := target(str(l["target_id"]))
	if t.is_empty():
		return
	var c := HaUnits.convert(raw, unit, str(t["unit"]))
	var v := HaUnits.adjust(float(c["value"]), float(l.get("scale", 1.0)), float(l.get("offset", 0.0)), bool(l.get("invert", false)))
	if str(t["kind"]) == "binary":
		v = 1.0 if v >= 0.5 else 0.0
	_last[str(l["id"])] = {"raw": raw, "unit": unit, "value": v, "ok": bool(c["ok"]),
		"warn": str(c.get("warn", "")), "t_unix": int(Time.get_unix_time_from_system())}
	if not bool(c["ok"]):
		return
	_observed.add(str(l["target_id"]), HaObservedStore.now_abs_hours(), v)
	_write_live_badge(t, v, unit)
	if apply and _may_apply():
		_apply(t, v)


func _may_apply() -> bool:
	var td := get_node_or_null("/root/TimeDirector")
	var live: bool = td == null or bool(td.call("should_apply_live_data"))
	return live and is_live()


## Item targets: the 📡 cache (specs.ha_live[field]) that the canvas badge and
## solar_bridge's live-wins rule read. Written in every mode, as a sim write.
func _write_live_badge(t: Dictionary, v: float, unit: String) -> void:
	if str(t["scope"]) != "item" or model == null:
		return
	var iid := str(t["item_id"])
	var it := model.get_item(iid)
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var live: Dictionary = (specs.get("ha_live", {}) as Dictionary).duplicate(true)
	live[str(t["field"])] = {"value": v, "unit": unit, "t": int(Time.get_unix_time_from_system())}
	specs["ha_live"] = live
	_sim_write(iid, specs)


func _clear_target_live(target_id: String) -> void:
	var p := HaTargets.parse(target_id)
	if p.is_empty():
		return
	if p["scope"] != "item":
		_resolve_nodes()
		if _solar_ui != null and _solar_ui.has_method("clear_live_reading"):
			_solar_ui.call("clear_live_reading", str(p["field"]))
		return
	var it := model.get_item(str(p["item_id"])) if model != null else {}
	if it.is_empty():
		return
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	var live: Dictionary = (specs.get("ha_live", {}) as Dictionary).duplicate(true)
	live.erase(str(p["field"]))
	specs["ha_live"] = live
	_sim_write(str(p["item_id"]), specs)


## Write one converted reading into the simulation (LIVE only).
func _apply(t: Dictionary, v: float) -> void:
	var f := str(t["field"])
	if str(t["scope"]) != "item":
		_resolve_nodes()
		if _solar_ui != null and _solar_ui.has_method("set_live_reading"):
			_solar_ui.call("set_live_reading", f, v)
		return
	var iid := str(t["item_id"])
	var it := model.get_item(iid)
	if it.is_empty():
		return
	var itype := str(it.get("type", ""))
	var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
	match itype:
		"appliance", "acload":
			match f:
				"power": specs["avg_watts"] = v
				"switch": specs["current_state"] = "on" if v >= 0.5 else "off"
				"energy": specs["energy_kwh"] = v
				"voltage": specs["voltage_v"] = v
				"current": specs["current_a"] = v
		"panel", "controller", "wind", "hydro":
			if f in ["power", "ac_power"]:
				specs["current_output_kw"] = v / 1000.0
		"battery", "smartbattery":
			if f == "soc":
				specs["soc"] = clampf(v / 100.0, 0.0, 1.0)
			elif f == "voltage":
				specs["voltage"] = v
		"resource":
			var cap := float(specs.get("capacity_qty", specs.get("capacity_l", 0.0)))
			var frac := -1.0
			if f == "level_pct":
				frac = clampf(v / 100.0, 0.0, 1.0)
			elif f == "stock_l" and cap > 0.0:
				frac = clampf(v / cap, 0.0, 1.0)
			if frac >= 0.0:
				specs["level"] = frac
				if cap > 0.0:
					specs["stock_l"] = frac * cap
				_hold_tank(iid, frac)
		"processor":
			if f == "switch":
				specs["current_state"] = "on" if v >= 0.5 else "off"
				specs.erase("requested_state")
		"shelly4pm":
			var ci := f.substr(1, 1)
			if f.ends_with("_power"): specs["c%s_power_w" % ci] = v
			elif f.ends_with("_switch"): specs["c%s_on" % ci] = v >= 0.5
			elif f.ends_with("_energy"): specs["c%s_energy_kwh" % ci] = v
	_sim_write(iid, specs)
	_push_item_to_solar_ui(itype, f, v)
	ha_live_updated.emit(iid, f, v)


## The measured level becomes the tank's present on its timeline, so the flow
## engine carries on from the real level instead of its own.
func _hold_tank(iid: String, frac: float) -> void:
	var view := get_parent()
	var flow: Variant = view.get("_resource_flow") if view != null else null
	if flow == null or not (flow as Object).has_method("get_timeline"):
		return
	var tl: Variant = flow.call("get_timeline", iid)
	if tl != null and (tl as Object).has_method("set_current_level"):
		var main := get_tree().current_scene if get_tree() != null else null
		var h := float(main.call("get_absolute_hours")) if main != null and main.has_method("get_absolute_hours") else 0.0
		tl.call("set_current_level", h, frac)


## Before site targets existed, a battery / panel / inverter node's link also
## drove SolarUI's battery, solar and load. Kept for those nodes unless the
## world links that site value directly.
func _push_item_to_solar_ui(itype: String, f: String, v: float) -> void:
	_resolve_nodes()
	if _solar_ui == null or not _solar_ui.has_method("set_live_reading"):
		return
	if itype in ["battery", "smartbattery"] and f == "soc":
		if _store.for_target("site.battery_soc").is_empty():
			_solar_ui.call("set_live_reading", "battery_soc", v)
	elif itype == "panel" and f == "power":
		if _store.for_target("site.solar_kw").is_empty():
			_solar_ui.call("set_live_reading", "solar_kw", v / 1000.0)
	elif itype == "controller" and f == "ac_power":
		if _store.for_target("site.load_kw").is_empty():
			_solar_ui.call("set_live_reading", "load_kw", v / 1000.0)


func _sim_write(iid: String, specs: Dictionary) -> void:
	if model == null:
		return
	var view := get_parent()
	var bracket := view != null and view.has_method("_begin_sim_writes")
	if bracket:
		view.call("_begin_sim_writes")
	else:
		model.sim_writing = true
	model.update_item(iid, {"specs": specs})
	if bracket:
		view.call("_end_sim_writes")
	else:
		model.sim_writing = false


# ---------------------------------------------------------------------------
# History replay (HistoryPlayer / CsvHistoryPlayer)
# ---------------------------------------------------------------------------

## Apply a replayed value to every target linked to `entity_id`, bypassing the
## LIVE gate: in PLAYBACK the player is the legitimate writer. `unit` "" =
## already in the target's unit.
func apply_historical_value(entity_id: String, value: float, unit: String, t_unix: int) -> void:
	for l in _store.for_entity(entity_id):
		var t := target(str(l["target_id"]))
		if t.is_empty():
			continue
		var c := HaUnits.convert(str(value), unit, str(t["unit"]))
		if not bool(c["ok"]):
			continue
		var v := HaUnits.adjust(float(c["value"]), float(l.get("scale", 1.0)), float(l.get("offset", 0.0)), bool(l.get("invert", false)))
		_last[str(l["id"])] = {"raw": str(value), "unit": unit, "value": v, "ok": true, "warn": "", "t_unix": t_unix, "history": true}
		_apply(t, v)


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	var live := _may_apply()
	if live and not _was_live:
		_reapply_all()
	elif not live and _was_live:
		_snapshot_for_sim()
	_was_live = live
	if live:
		_hold_acc += delta
		if _hold_acc >= HOLD_INTERVAL_S:
			_hold_acc = 0.0
			_reapply_held()


## Entering LIVE: every fresh reading takes over at once.
func _reapply_all() -> void:
	var now := int(Time.get_unix_time_from_system())
	for l in _store.links:
		var last: Dictionary = _last.get(str(l["id"]), {})
		if last.is_empty() or not bool(last.get("ok", false)) or now - int(last.get("t_unix", 0)) > STALE_S:
			continue
		var t := target(str(l["target_id"]))
		if not t.is_empty() and bool(l.get("enabled", true)):
			_apply(t, float(last["value"]))


## Tanks: the flow engine integrates them every tick, so the measured level is
## re-held once a second while LIVE.
func _reapply_held() -> void:
	var now := int(Time.get_unix_time_from_system())
	for l in _store.links:
		var tid := str(l["target_id"])
		if not tid.ends_with(".level_pct") and not tid.ends_with(".stock_l"):
			continue
		var last: Dictionary = _last.get(str(l["id"]), {})
		if last.is_empty() or not bool(last.get("ok", false)) or now - int(last.get("t_unix", 0)) > STALE_S:
			continue
		var t := target(tid)
		if not t.is_empty() and bool(l.get("enabled", true)):
			_apply(t, float(last["value"]))


## LIVE → SIMULATE: SolarUI snapshots the live readings as its starting point
## and runs on its own model from there.
func _snapshot_for_sim() -> void:
	_resolve_nodes()
	if _solar_ui == null:
		return
	if is_instance_valid(SimSettingsController) and SimSettingsController.has_method("notify_simulation_start"):
		SimSettingsController.notify_simulation_start()


func _on_svc_state(state: int, _info: Dictionary) -> void:
	if state == HomeAssistantService.State.CONNECTED:
		refresh_subscriptions.call_deferred()
	_publish_summary()


func _on_model_changed(reason: String) -> void:
	if reason == "remove_item" or reason == "deserialize" or reason == "clear":
		_prune_deferred.call_deferred()


func _prune_deferred() -> void:
	if _prune() > 0:
		_save()
		_rebuild_routes()
		_publish_summary()
		links_changed.emit()


func _prune() -> int:
	if model == null:
		return 0
	var live := {}
	for it in model.items:
		live[str(it.get("id", ""))] = true
	return _store.prune_items(live)


func _migrate_legacy() -> void:
	if model == null:
		return
	var solar_cfg := HaLinkStore.LEGACY_SOLAR_CFG if FileAccess.file_exists(HaLinkStore.LEGACY_SOLAR_CFG) else ""
	var res := _store.migrate_legacy(model.items, solar_cfg)
	# The old free-text "Entity Subscriptions" list had no targets: nothing to
	# carry over except as a hint the Live links window can show.
	for iid in res.get("cleared", []):
		var it := model.get_item(str(iid))
		if it.is_empty():
			continue
		var specs: Dictionary = (it.get("specs", {}) as Dictionary).duplicate(true)
		specs.erase("ha_links")
		_sim_write(str(iid), specs)
	if int(res.get("added", 0)) > 0:
		print("[HA] Moved %d Home Assistant link(s) into this world's link file" % int(res["added"]))
	_save()


func _save() -> void:
	if not _store_path.is_empty():
		_store.save_to(_store_path)


func _links_path() -> String:
	var view := get_parent()
	var key := ""
	if view != null and view.has_method("_resolve_map_graph_key"):
		key = str(view.call("_resolve_map_graph_key"))
	if key.is_empty():
		return ""
	return WorldPaths.keyed_file(HaLinkStore.KIND, key.trim_prefix("map_"), "json")


func _rebuild_routes() -> void:
	_routes.clear()
	for l in _store.links:
		var p := HaTargets.parse(str(l["target_id"]))
		if p.is_empty() or p["scope"] != "item":
			continue
		var eid := str(l["entity_id"])
		var arr: Array = _routes.get(eid, [])
		arr.append({"item_id": str(p["item_id"]), "role": str(p["field"])})
		_routes[eid] = arr


## SolarUI's own per-field entity handling stands down while this world's
## links drive the site values.
func _tell_solar_ui() -> void:
	_resolve_nodes()
	if _solar_ui != null:
		_solar_ui.set("ha_links_external", true)


func _publish_summary() -> void:
	if _svc == null or not _svc.has_method("set_link_summary"):
		return
	var live := 0
	var stale := 0
	var warn := 0
	var now := int(Time.get_unix_time_from_system())
	for l in _store.links:
		var last: Dictionary = _last.get(str(l["id"]), {})
		if last.is_empty() or now - int(last.get("t_unix", 0)) > STALE_S:
			stale += 1
		elif not bool(last.get("ok", false)) or not str(last.get("warn", "")).is_empty():
			warn += 1
		else:
			live += 1
	_svc.call("set_link_summary", {"total": _store.links.size(), "live": live, "stale": stale, "warn": warn})


var _summary_acc := 0.0

func _physics_process(delta: float) -> void:
	_summary_acc += delta
	if _summary_acc >= 2.0:
		_summary_acc = 0.0
		_publish_summary()


func _resolve_nodes() -> void:
	var tr := get_tree()
	if tr == null:
		return
	if not is_instance_valid(_svc):
		_svc = tr.root.get_node_or_null("HomeAssistant")
		if _svc != null:
			if not _svc.sensor_updated.is_connected(_on_sensor_updated):
				_svc.sensor_updated.connect(_on_sensor_updated)
			if not _svc.state_changed.is_connected(_on_svc_state):
				_svc.state_changed.connect(_on_svc_state)
			if not _svc.raw_history_received.is_connected(_on_history):
				_svc.raw_history_received.connect(_on_history)
	if not is_instance_valid(_solar_ui):
		_solar_ui = ServiceLocator.solar_ui()
		if _solar_ui == null:
			for p in SOLAR_UI_PATHS:
				var n := tr.root.get_node_or_null(p)
				if n != null:
					_solar_ui = n
					break

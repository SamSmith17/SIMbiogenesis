class_name SiteDeployDirector
extends RefCounted

## The impure half of the site deployment schedule: owned by SystemGraphView,
## ticked right after the population bridge. It turns a schedule event into
## Site Projects for the crews (SiteDeployPlanner rows → the bridge's
## create_site_project), keeps handing out work no board had room for, pins
## the crews as ALL HANDS while an event is in flight, pushes a camp's live
## pitch / strike fraction, and undoes a fired event instantly when the clock
## is scrubbed back past it.
##
## The record is SiteDeploySchedule's, saved per world (WorldPaths kind
## "deploy_schedule", path from TerrainLoader.deploy_schedule_path). Each
## fired event's stamp carries everything a reload needs to carry on:
##   fired[id] = {at, crews: [iid], items: [{kind, id}],
##                pending: [item], projects: [{iid, pid, item}], done: bool}
## An item is the planner's record ({kind: prop|camp, id, label, pos, …}).

signal changed()

## Toast ids (ToastUI.show_community dedupes on them).
const TOAST_KEY := "site_deploy"
## Crews are pinned on the tick the event fires; they have a board on the
## next one. Assignment is retried every tick while anything is pending.
const RETRY_EVERY_H := 0.05

var _rec: Dictionary = SiteDeploySchedule.empty()
var _path := ""
var _loaded := false
var _prev_h := NAN
var _main: Node = null
var _bridge = null
var _loader: Node = null
var _dirty := false
var _last_retry_h := -INF
var _status_cache: Dictionary = {}


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Point the director at the running world (the view calls this before any
## UI query, and tick does it every tick).
func bind(main: Node, bridge = null) -> void:
	_main = main
	if bridge != null:
		_bridge = bridge
	if _main != null:
		_loader = TerrainSurfaceQuery.find_terrain_loader(_main)
	_ensure_loaded()


func _ensure_loaded() -> void:
	if _loader == null or not _loader.has_method("deploy_schedule_path"):
		return
	# Resolved on EVERY bind: the loader's site (lat / lon, the active world)
	# is not known on the first bind after a load, and a path latched then
	# pointed at a 0,0 key for the rest of the session.
	var p := str(_loader.call("deploy_schedule_path"))
	if _loaded and p == _path:
		return
	_path = p
	_loaded = true
	_rec = SiteDeploySchedule.empty()
	if _path.is_empty() or not FileAccess.file_exists(_path):
		return
	var txt := FileAccess.get_file_as_string(_path)
	var parsed: Variant = JSON.parse_string(txt)
	_rec = SiteDeploySchedule.normalize(parsed)


func _save() -> void:
	_dirty = false
	if _path.is_empty() or WorldPaths.is_sealed():
		return
	var dir := _path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_rec, "\t"))
		f.close()


func record() -> Dictionary:
	return _rec


## One tick (after the population bridge): fire what the clock crossed,
## undo what it un-crossed, hand out pending work, push camp fractions.
func tick(main: Node, bridge, abs_h: float) -> void:
	bind(main, bridge)
	if _bridge == null or _loader == null or is_nan(abs_h):
		return
	if is_nan(_prev_h):
		# First tick after a load: the world already reflects whatever fired
		# before the save; only in-flight events need picking up.
		_prev_h = abs_h
		_repin_crews()
	if abs_h > _prev_h:
		for ev in SiteDeploySchedule.due(_rec, _prev_h, abs_h):
			_fire(ev as Dictionary, abs_h)
	elif abs_h < _prev_h:
		for ev in SiteDeploySchedule.rewound(_rec, _prev_h, abs_h):
			_undo(ev as Dictionary)
	_prev_h = abs_h
	_service(abs_h)
	if _dirty:
		_save()
		changed.emit()


# ---------------------------------------------------------------------------
# Schedule API (the timeline chip / flags, the festival panel)
# ---------------------------------------------------------------------------

func events() -> Array:
	return SiteDeploySchedule.events_sorted(_rec)


func add_event(action: String, at_h: float) -> String:
	_ensure_loaded()
	var id := SiteDeploySchedule.add_event(_rec, action, at_h)
	if not id.is_empty():
		_dirty = true
		_save()
		changed.emit()
	return id


func remove_event(id: String) -> bool:
	var info := SiteDeploySchedule.fired_info(_rec, id)
	if not info.is_empty():
		_release(info)
	var ok := SiteDeploySchedule.remove_event(_rec, id)
	if ok:
		_dirty = true
		_save()
		changed.emit()
	return ok


func move_event(id: String, at_h: float) -> bool:
	var ok := SiteDeploySchedule.move_event(_rec, id, at_h)
	if ok:
		_dirty = true
		_save()
		changed.emit()
	return ok


func clear() -> void:
	for ev in events():
		var info := SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))
		if not info.is_empty():
			_release(info)
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty():
		_cancel_projects(manual)
		_release(manual)
	_rec = SiteDeploySchedule.empty()
	_dirty = true
	_save()
	changed.emit()


func phase_at(t: float) -> Dictionary:
	return SiteDeploySchedule.phase_at(_rec, t)


func is_fired(id: String) -> bool:
	return SiteDeploySchedule.is_fired(_rec, id)


## Everything the crews would be handed right now for `action` (what the
## chip's menu counts): [{kind, id, label, pos, …}].
func inventory(action: String) -> Array:
	bind(_main)
	return _inventory(action)


## What is going on: {active (bool), action, done, total, pending, crews,
## line} — `line` is the one sentence for the HUD and the chip tooltip.
func status() -> Dictionary:
	var out := {"active": false, "action": "", "done": 0, "total": 0, "pending": 0,
		"crews": 0, "line": ""}
	for ev in events():
		var id := str((ev as Dictionary).get("id", ""))
		var info := SiteDeploySchedule.fired_info(_rec, id)
		if info.is_empty() or bool(info.get("done", false)):
			continue
		out["active"] = true
		out["action"] = str((ev as Dictionary).get("action", ""))
		var total := (info.get("items", []) as Array).size()
		var done := 0
		for p in info.get("projects", []):
			if _project_state(p as Dictionary) == "done":
				done += 1
		out["done"] = done
		out["total"] = total
		out["pending"] = (info.get("pending", []) as Array).size()
		out["crews"] = (info.get("crews", []) as Array).size()
		break
	if not bool(out["active"]):
		var manual: Dictionary = _rec.get("manual", {})
		if not manual.is_empty() and not bool(manual.get("done", false)):
			out["active"] = true
			out["action"] = str(manual.get("action", ""))
			out["total"] = (manual.get("items", []) as Array).size()
			var mdone := 0
			for p in manual.get("projects", []):
				if _project_state(p as Dictionary) == "done":
					mdone += 1
			out["done"] = mdone
			out["pending"] = (manual.get("pending", []) as Array).size()
			out["crews"] = (manual.get("crews", []) as Array).size()
			out["manual"] = true
	if bool(out["active"]):
		var verb := SiteDeploySchedule.action_verb(str(out["action"]))
		var txt := "%s the site · %d of %d done" % [verb, int(out["done"]), int(out["total"])]
		if int(out["pending"]) > 0:
			txt += " · %s waiting for a crew" % UiText.count(int(out["pending"]), "item")
		txt += " · %s on it" % UiText.count(int(out["crews"]), "camp")
		out["line"] = txt
	else:
		var evs := events()
		if evs.is_empty():
			out["line"] = "No deployment scheduled"
		else:
			var now := _now_h()
			var ph := phase_at(now)
			var nxt: Dictionary = ph.get("next", {})
			if not nxt.is_empty():
				out["line"] = "%s at %s" % [SiteDeploySchedule.action_label(str(nxt.get("action", ""))),
					ClimelapseExportOptions.timecode_at(float(nxt.get("at_h", 0.0)))]
			else:
				out["line"] = "Site %s" % str(ph.get("phase", ""))
	return out


## Pack or deploy everything NOW with no crew (the before-state for a
## scheduled build, or "I just want it packed"). Cancels any site project in
## flight and clears its event's stamp.
func apply_instant(action: String) -> int:
	bind(_main)
	if _loader == null:
		return 0
	for ev in events():
		var id := str((ev as Dictionary).get("id", ""))
		var info := SiteDeploySchedule.fired_info(_rec, id)
		if not info.is_empty() and not bool(info.get("done", false)):
			_cancel_projects(info)
			_release(info)
			SiteDeploySchedule.unmark(_rec, id)
			_dirty = true
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty() and not bool(manual.get("done", false)):
		_cancel_projects(manual)
		_release(manual)
		_rec.erase("manual")
		_dirty = true
	var items := _inventory(action)
	for it in items:
		_instant(it as Dictionary, action)
	if _dirty:
		_save()
	changed.emit()
	_toast("%s — %s, no crew" % [SiteDeploySchedule.action_label(action).replace(" the site", " the site now"),
		_count_text(items)], Vector2.INF)
	return items.size()


# ---------------------------------------------------------------------------
# Firing
# ---------------------------------------------------------------------------

func _fire(ev: Dictionary, abs_h: float) -> void:
	var id := str(ev.get("id", ""))
	var action := str(ev.get("action", ""))
	var items := _inventory(action)
	var crews_all: Array = _bridge.call("crew_summary") if _bridge.has_method("crew_summary") else []
	var picked: Array = SiteDeployPlanner.pick_crews(crews_all, items) if not items.is_empty() else []
	for iid in picked:
		_bridge.call("set_all_hands", str(iid), true)
	var compact: Array = []
	for it in items:
		compact.append({"kind": str((it as Dictionary).get("kind", "")), "id": str((it as Dictionary).get("id", ""))})
	SiteDeploySchedule.mark_fired(_rec, id, abs_h, {
		"crews": picked, "items": compact, "pending": items, "projects": [],
		"done": items.is_empty() or picked.is_empty()})
	_dirty = true
	if items.is_empty():
		_toast("%s — nothing to %s" % [SiteDeploySchedule.action_label(action),
			"deploy" if action == SiteDeploySchedule.ACTION_DEPLOY else "pack"], Vector2.INF)
	elif picked.is_empty():
		_toast("%s — nobody on site to do it (no populated camp)" % SiteDeploySchedule.action_label(action), Vector2.INF)
	else:
		var centre := Vector2.ZERO
		for it in items:
			centre += (it as Dictionary).get("pos", Vector2.ZERO)
		centre /= float(items.size())
		_toast("%s — %s, %s on it" % [SiteDeploySchedule.action_label(action), _count_text(items),
			UiText.count(picked.size(), "camp")], centre)


## Hand out pending work, push camp fractions, notice completion — for
## every fired event and the manual (one-structure) stamp alike.
func _service(abs_h: float) -> void:
	var crews_all: Array = []
	var runs: Array = []   # [[action, info]]
	for ev in events():
		var info0 := SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))
		if not info0.is_empty() and not bool(info0.get("done", false)):
			runs.append([str((ev as Dictionary).get("action", "")), info0])
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty() and not bool(manual.get("done", false)):
		runs.append([str(manual.get("action", SiteDeploySchedule.ACTION_DEPLOY)), manual])
	for run in runs:
		var action := str(run[0])
		var info: Dictionary = run[1]
		var pending: Array = info.get("pending", [])
		if not pending.is_empty() and abs_h - _last_retry_h >= RETRY_EVERY_H:
			_last_retry_h = abs_h
			if crews_all.is_empty() and _bridge.has_method("crew_summary"):
				crews_all = _bridge.call("crew_summary")
			var mine: Array = []
			var pinned: Array = info.get("crews", [])
			for c in crews_all:
				if pinned.has(str((c as Dictionary).get("iid", ""))) and bool((c as Dictionary).get("board", false)):
					mine.append(c)
			if not mine.is_empty():
				var res := SiteDeployPlanner.assign(pending, mine, action)
				var left: Array = res.get("unassigned", [])
				var assigned: Dictionary = res.get("assigned", {})
				for iid in assigned:
					var roster := 4
					for c in mine:
						if str((c as Dictionary).get("iid", "")) == str(iid):
							roster = int((c as Dictionary).get("roster", 4))
					for it in assigned[iid]:
						var pid := _create_project(str(iid), it as Dictionary, action, roster)
						if pid.is_empty():
							left.append(it)
						else:
							(info["projects"] as Array).append({"iid": str(iid), "pid": pid, "item": it})
				info["pending"] = left
				_dirty = true
		# Camps pitch / strike with the crew's labour; props follow their
		# own phases.
		var all_done := (info.get("pending", []) as Array).is_empty()
		for p in info.get("projects", []):
			var pd := p as Dictionary
			var item: Dictionary = pd.get("item", {})
			var state := _project_state(pd)
			if state == "active":
				all_done = false
			if str(item.get("kind", "")) == "camp":
				var f := _project_progress(pd)
				if state == "done":
					f = 1.0
				elif state != "active":
					continue
				var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
				_loader.call("set_camp_built", str(item.get("id", "")), f if deploy else 1.0 - f, false)
		if all_done:
			info["done"] = true
			_dirty = true
			_release(info)
			if is_same(info, manual):
				_toast("Crew work done — %s" % _count_text(_items_of(info)), Vector2.INF)
			else:
				_toast("%s — done" % SiteDeploySchedule.action_label(action), Vector2.INF)


func _create_project(iid: String, item: Dictionary, action: String, roster: int) -> String:
	var rows := SiteDeployPlanner.rows_for(item, action, roster)
	if rows.is_empty():
		return ""
	var kind := SiteProject.KIND_SITE_DEPLOY if action == SiteDeploySchedule.ACTION_DEPLOY \
		else SiteProject.KIND_SITE_PACKUP
	var is_prop := str(item.get("kind", "")) == "prop"
	var pid_prop := str(item.get("id", "")) if is_prop else ""
	var pos: Vector2 = item.get("pos", Vector2.ZERO)
	var target := {"kind": "prop", "id": pid_prop} if is_prop else {"kind": "pos", "x": pos.x, "z": pos.y}
	var meta := {"site_deploy": true, "item_kind": str(item.get("kind", "")),
		"camp_id": "" if is_prop else str(item.get("id", ""))}
	var pid := str(_bridge.call("create_site_project", iid, kind,
		SiteDeployPlanner.project_label(item, action), pid_prop, pos, rows,
		SiteDeployPlanner.WORK_WINDOW, target, meta))
	if pid.is_empty() or not is_prop:
		return pid
	var model_id := str(item.get("model_id", ""))
	var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
	if model_id == LinkageStructureBuilder.MODEL_ID:
		if deploy:
			# The ghost preview of the DEPLOYED frame beside the crate (the
			# crew rebuild's own look); the raise's unpack clears it. A
			# breakdown's visuals are the bridge's own progress push.
			PlacedPropService.update_prop_record(_main, pid_prop,
				{"build_state": {"phase": "", "ghost": 0.14, "preview": true}}, true)
		return pid
	# Every other prop gets a labour-mode build site that follows this
	# project: the rack's stages its units off the real rack, the generic
	# one lays the parts out and seats them (AssemblyBuildSite). build_state
	# flips the prop into construction rendering (the ghost under the site).
	var run := {"mode": "labour", "action": action, "iid": iid, "project_id": pid}
	if model_id == PalletRackBuilder.MODEL_ID:
		run["crew_n"] = clampi(roster, PalletRackBuildSite.MIN_CREW, PalletRackBuildSite.MAX_LABOUR_LANES)
	PlacedPropService.update_prop_record(_main, pid_prop, {
		"build_state": {"phase": "", "ghost": 0.14},
		PalletRackBuildSite.RECORD_KEY: run}, true)
	return pid


# ---------------------------------------------------------------------------
# Undo / instant
# ---------------------------------------------------------------------------

## The clock was scrubbed back past a fired event: cancel its crew work and
## put every item back as it was before the event, at once.
func _undo(ev: Dictionary) -> void:
	var id := str(ev.get("id", ""))
	var action := str(ev.get("action", ""))
	var info := SiteDeploySchedule.fired_info(_rec, id)
	if info.is_empty():
		return
	_cancel_projects(info)
	_release(info)
	var inverse := SiteDeploySchedule.ACTION_PACKUP if action == SiteDeploySchedule.ACTION_DEPLOY \
		else SiteDeploySchedule.ACTION_DEPLOY
	for it in info.get("items", []):
		_instant(it as Dictionary, inverse)
	SiteDeploySchedule.unmark(_rec, id)
	_dirty = true
	_toast("Scrubbed back past “%s” — put back as it was" % SiteDeploySchedule.action_label(action), Vector2.INF)


func _cancel_projects(info: Dictionary) -> void:
	for p in info.get("projects", []):
		var pd := p as Dictionary
		if _project_state(pd) == "active" and _bridge != null:
			_bridge.call("cancel_project", str(pd.get("iid", "")), str(pd.get("pid", "")), _main)


func _release(info: Dictionary) -> void:
	if _bridge == null:
		return
	# Keep a camp pinned while another in-flight event still uses it.
	var still := {}
	var others: Array = []
	for ev in events():
		others.append(SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", ""))))
	others.append(_rec.get("manual", {}))
	for other in others:
		if (other as Dictionary).is_empty() or is_same(other, info) or bool((other as Dictionary).get("done", false)):
			continue
		for iid in (other as Dictionary).get("crews", []):
			still[str(iid)] = true
	for iid in info.get("crews", []):
		if not still.has(str(iid)):
			_bridge.call("set_all_hands", str(iid), false)


## Pin the crews of every in-flight event again (a reload lost the bridge's
## memory, not the stamp's).
func _repin_crews() -> void:
	if _bridge == null:
		return
	for ev in events():
		var info := SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))
		if info.is_empty() or bool(info.get("done", false)):
			continue
		for iid in info.get("crews", []):
			_bridge.call("set_all_hands", str(iid), true)


## One item straight to the action's end state, no crew.
func _instant(item: Dictionary, action: String) -> void:
	if _loader == null:
		return
	var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
	var id := str(item.get("id", ""))
	if str(item.get("kind", "")) == "camp":
		_loader.call("set_camp_built", id, 1.0 if deploy else 0.0, true)
		return
	var rec := PlacedPropService.get_prop_record(_main, id)
	if rec.is_empty():
		return
	# Construction state off the record first; the pack toggle (a coroutine
	# on the loader — the linkage fold sweep) rebuilds the prop itself, so
	# only a prop that stays as it is needs the rebuild here.
	var toggle := bool(rec.get("packed", false)) != (not deploy)
	PlacedPropService.update_prop_record(_main, id,
		{"build_state": null, PalletRackBuildSite.RECORD_KEY: null}, not toggle)
	if toggle and _loader.has_method("set_prop_packed"):
		_loader.call_deferred("set_prop_packed", id, not deploy)


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

func _inventory(action: String) -> Array:
	var out: Array = []
	if _loader == null:
		return out
	var want_packed := action == SiteDeploySchedule.ACTION_PACKUP   # pack-up takes STANDING things
	if _loader.has_method("placed_prop_records"):
		for r in _loader.call("placed_prop_records"):
			var rec: Dictionary = r
			var model_id := str(rec.get("model_id", ""))
			if model_id.is_empty() or model_id == "cargo_container" \
					or not str(rec.get("stowed_in", "")).is_empty() \
					or bool(rec.get("hidden_3d", false)):
				continue
			var packed := bool(rec.get("packed", false))
			if packed == want_packed:
				continue
			var bs: Variant = rec.get("build_state")
			if bs is Dictionary and not (bs as Dictionary).is_empty():
				continue   # a crew is already on it
			var pspec := PlacedPropRuntime.packed_spec_for_record(rec)
			if pspec.is_empty():
				continue
			var entry := ModelCatalog.find(model_id)
			var label := str(entry.get("label", ""))
			if label.is_empty():
				label = model_id.capitalize()
			var item := {"kind": "prop", "id": str(rec.get("id", "")), "label": label,
				"pos": Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))),
				"mass_kg": float(pspec.get("mass_kg", -1.0)), "model_id": model_id}
			if want_packed:
				var door := _container_door_near(item["pos"] as Vector2)
				if not door.is_empty():
					item["loadout"] = door
			if model_id == LinkageStructureBuilder.MODEL_ID and rec.get("linkage_spec") is Dictionary:
				var p := LinkageParams.new()
				p.from_config(rec.get("linkage_spec") as Dictionary)
				item["counts"] = LinkageBom.fab_counts(LinkageBom.compute(p), {})
			out.append(item)
	var layer: Variant = _loader.get("camp_areas")
	if layer != null and _loader.has_method("camp_area_structure_count"):
		for a in layer.areas:
			var area: Dictionary = a
			var cid := str(area.get("id", ""))
			# Deploy wants STRUCK camps (built false), pack-up STANDING ones.
			if bool(area.get("built", true)) != want_packed:
				continue
			var n := int(_loader.call("camp_area_structure_count", cid))
			if n <= 0:
				continue
			var poly: PackedVector2Array = area.get("polygon", PackedVector2Array())
			var c := Vector2.ZERO
			for v in poly:
				c += v
			if poly.size() > 0:
				c /= float(poly.size())
			out.append({"kind": "camp", "id": cid, "label": str(area.get("name", cid)),
				"pos": c, "structures": n})
	return out


## The door of the nearest cargo container within LOADOUT_REACH_M of `pos`
## ({} = none): where a packed crate is carried after a pack-up (the same
## door the prop editor's linkage breakdown used).
const LOADOUT_REACH_M := 200.0

func _container_door_near(pos: Vector2) -> Dictionary:
	if _loader == null or not _loader.has_method("placed_prop_records"):
		return {}
	var best_d := LOADOUT_REACH_M
	var out := {}
	for r in _loader.call("placed_prop_records"):
		var cr: Dictionary = r
		if str(cr.get("model_id", "")) != "cargo_container":
			continue
		var cpos := Vector2(float(cr.get("x", 0.0)), float(cr.get("z", 0.0)))
		var dist := pos.distance_to(cpos)
		if dist < best_d:
			best_d = dist
			var yaw := deg_to_rad(float(cr.get("yaw", 0.0)))
			var door := cpos + Vector2(sin(yaw), cos(yaw)) * 5.0
			out = {"x": door.x, "z": door.y}
	return out


# ---------------------------------------------------------------------------
# One structure at a time (the prop editor, the Projects panel)
# ---------------------------------------------------------------------------

## Hand ONE prop or camp to a crew now, outside any event: the same rows,
## the same staging, the nearest crew with board room (a camp with no board
## yet is pinned ALL HANDS and the item waits for its next tick). Returns
## {ok, error, project_id, site}. Items wait under the record's `manual`
## stamp, which the tick services like an event's.
func queue_item(kind: String, id: String, action: String) -> Dictionary:
	bind(_main)
	var out := {"ok": false, "error": "", "project_id": "", "site": Vector2.ZERO}
	if _loader == null or _bridge == null:
		out["error"] = "no world or population running"
		return out
	var item := {}
	for it in _inventory(action):
		if str((it as Dictionary).get("kind", "")) == kind and str((it as Dictionary).get("id", "")) == id:
			item = it
	if item.is_empty():
		out["error"] = "nothing to %s here" % ("deploy" if action == SiteDeploySchedule.ACTION_DEPLOY else "pack")
		return out
	out["site"] = item.get("pos", Vector2.ZERO)
	var crews_all: Array = _bridge.call("crew_summary") if _bridge.has_method("crew_summary") else []
	if crews_all.is_empty():
		out["error"] = "nobody on site — populate a camp first"
		return out
	var manual: Dictionary = _rec.get("manual", {})
	if manual.is_empty():
		manual = {"crews": [], "items": [], "pending": [], "projects": [], "done": false, "action": action}
		_rec["manual"] = manual
	manual["done"] = false
	manual["action"] = action
	var picked: Array = SiteDeployPlanner.pick_crews(crews_all, [item], 60)
	for iid in picked:
		if not (manual["crews"] as Array).has(str(iid)):
			(manual["crews"] as Array).append(str(iid))
		_bridge.call("set_all_hands", str(iid), true)
	(manual["items"] as Array).append({"kind": kind, "id": id})
	# A crew with a board takes it at once; otherwise it waits for the tick.
	var ready: Array = []
	for c in crews_all:
		if picked.has(str((c as Dictionary).get("iid", ""))) and bool((c as Dictionary).get("board", false)):
			ready.append(c)
	var res := SiteDeployPlanner.assign([item], ready, action)
	var assigned: Dictionary = res.get("assigned", {})
	for iid in assigned:
		var roster := 4
		for c in ready:
			if str((c as Dictionary).get("iid", "")) == str(iid):
				roster = int((c as Dictionary).get("roster", 4))
		var pid := _create_project(str(iid), item, action, roster)
		if not pid.is_empty():
			(manual["projects"] as Array).append({"iid": str(iid), "pid": pid, "item": item})
			out["project_id"] = pid
	if str(out["project_id"]).is_empty():
		(manual["pending"] as Array).append(item)
	out["ok"] = true
	_dirty = true
	_save()
	changed.emit()
	return out


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _project_rec(pd: Dictionary) -> Dictionary:
	if _bridge == null:
		return {}
	var store = _bridge.call("project_store_for", str(pd.get("iid", "")))
	return store.find(str(pd.get("pid", ""))) if store != null else {}


func _project_state(pd: Dictionary) -> String:
	var rec := _project_rec(pd)
	return str(rec.get("state", "cancelled")) if not rec.is_empty() else "cancelled"


func _project_progress(pd: Dictionary) -> float:
	var rec := _project_rec(pd)
	if rec.is_empty():
		return 0.0
	var board = _bridge.call("chore_board_for", str(pd.get("iid", "")))
	if board == null:
		return 0.0
	return float(SiteProject.rollup(rec, board).get("progress", 0.0))


func _now_h() -> float:
	if _main != null and _main.has_method("get_absolute_hours"):
		return float(_main.call("get_absolute_hours"))
	return _prev_h if not is_nan(_prev_h) else 0.0


static func _items_of(info: Dictionary) -> Array:
	return info.get("items", []) as Array


static func _count_text(items: Array) -> String:
	var props := 0
	var camps := 0
	for it in items:
		if str((it as Dictionary).get("kind", "")) == "camp":
			camps += 1
		else:
			props += 1
	var parts := PackedStringArray()
	if props > 0:
		parts.append(UiText.count(props, "structure"))
	if camps > 0:
		parts.append(UiText.count(camps, "camp"))
	return ", ".join(parts) if not parts.is_empty() else "nothing"


func _toast(text: String, watch: Vector2) -> void:
	var sgv: Node = ServiceLocator.graph()
	if sgv == null:
		return
	if watch != Vector2.INF and sgv.has_method("notify_crew_queued"):
		sgv.call("notify_crew_queued", watch, "🏕 %s" % text, "")
	elif sgv.has_method("_show_toast"):
		sgv.call("_show_toast", "🏕 %s" % text)

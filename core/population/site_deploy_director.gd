class_name SiteDeployDirector
extends RefCounted

## The impure half of the site deployment schedule: owned by SystemGraphView,
## ticked right after the population bridge. It turns a schedule event into
## Site Projects for the crews (SiteDeployPlanner rows → the bridge's
## create_site_project), keeps handing out work no board had room for, pins
## the crews as ALL HANDS while an event is in flight, pushes a camp's live
## pitch / strike fraction, and undoes a fired event EXACTLY when the clock
## is scrubbed back past it (every item's `before` snapshot). Inside a
## finished event's window the build is REPLAYED from the projects' progress
## traces, so the clock scrubs through a pack-up or a deploy.
##
## The drive events (ARRIVE / LEAVE) are declarative: the moment one is
## added, moved or removed the vehicles' arrival / departure records are
## written from it (TerrainLoader.schedule_vehicle_arrivals / _departures),
## and the population bridge keeps vehicle-less camps away by
## SiteDeploySchedule.people_present. Nothing fires for them.
##
## The record is SiteDeploySchedule's, saved per world (WorldPaths kind
## "deploy_schedule", path from TerrainLoader.deploy_schedule_path). Each
## fired event's stamp carries everything a reload needs to carry on:
##   fired[id] = {at, crews: [iid], items: [{kind, id}],
##                pending: [item], projects: [{iid, pid, item, trace, done_h}],
##                before: {id: snapshot}, after: {id: snapshot},
##                done: bool, done_h, replaying: bool, auto_leave: event id}
## An item is the planner's record ({kind: prop|camp, id, label, pos, …}).

signal changed()

## Toast ids (ToastUI.show_community dedupes on them).
const TOAST_KEY := "site_deploy"
## Crews are pinned on the tick the event fires; they have a board on the
## next one. Assignment is retried every tick while anything is pending.
const RETRY_EVERY_H := 0.05
## The fewest lanes a scheduled structure build plans for (carry in pairs).
const MIN_PIECE_CREW := 4
## The door of the nearest cargo container / vehicle bay within this reach
## of a packed crate is where a pack-up carries it.
const LOADOUT_REACH_M := 200.0
## A pack-up's vehicles set off this long after the last crate is loaded
## (a LEAVE event the player can drag, when none is on the timeline).
const DEPART_AFTER_H := 2.0 / 60.0
## A replay frame is written to the record when the shown progress moved
## this much (the live site node is pushed every tick regardless).
const REPLAY_RECORD_STEP := 0.02

var _rec: Dictionary = SiteDeploySchedule.empty()
var _path := ""
var _loaded := false
var _prev_h := NAN
var _main: Node = null
var _bridge = null
var _loader: Node = null
var _dirty := false
var _last_retry_h := -INF
var _last_gap_ms := -100000
var _healed: Dictionary = {}
var _status_cache: Dictionary = {}


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

## Point the director at the running world (the view calls this before any
## UI query, and tick does it every tick).
func bind(main: Node, bridge = null) -> void:
	if main != null:
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
## undo what it un-crossed, replay a finished event the clock is inside,
## hand out pending work, push camp fractions, keep the vehicles scheduled.
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
	_settle_afters(abs_h)
	_replay(abs_h)
	_service(abs_h)
	_keep_drives_scheduled()
	if _dirty:
		_save()
		changed.emit()


# ---------------------------------------------------------------------------
# Schedule API (the timeline chip / flags, the festival panel)
# ---------------------------------------------------------------------------

func events() -> Array:
	return SiteDeploySchedule.events_sorted(_rec)


func event_of(action: String) -> Dictionary:
	return SiteDeploySchedule.event_of(_rec, action)


func add_event(action: String, at_h: float) -> String:
	bind(_main)
	var id := SiteDeploySchedule.add_event(_rec, action, at_h)
	if not id.is_empty():
		_dirty = true
		if SiteDeploySchedule.is_drive_action(action):
			apply_drive_events(true)
		_save()
		changed.emit()
	return id


func remove_event(id: String) -> bool:
	var ev := SiteDeploySchedule.event(_rec, id)
	var info := SiteDeploySchedule.fired_info(_rec, id)
	if not info.is_empty():
		_cancel_projects(info)
		_release(info)
	var ok := SiteDeploySchedule.remove_event(_rec, id)
	if ok:
		_dirty = true
		if SiteDeploySchedule.is_drive_action(str(ev.get("action", ""))):
			apply_drive_events(true)
		_save()
		changed.emit()
	return ok


func move_event(id: String, at_h: float) -> bool:
	var ev := SiteDeploySchedule.event(_rec, id)
	var ok := SiteDeploySchedule.move_event(_rec, id, at_h)
	if ok:
		_dirty = true
		if SiteDeploySchedule.is_drive_action(str(ev.get("action", ""))):
			apply_drive_events(true)
		_save()
		changed.emit()
	return ok


func clear() -> void:
	for ev in events():
		var info := SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))
		if not info.is_empty():
			_cancel_projects(info)
			_release(info)
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty():
		_cancel_projects(manual)
		_release(manual)
	_rec = SiteDeploySchedule.empty()
	_dirty = true
	apply_drive_events(true)
	_save()
	changed.emit()


func phase_at(t: float) -> Dictionary:
	return SiteDeploySchedule.phase_at(_rec, t)


func is_fired(id: String) -> bool:
	return SiteDeploySchedule.is_fired(_rec, id)


## Whether the site's people are here at `t` by the ARRIVE / LEAVE events
## (the bridge asks for every camp with no scheduled vehicle).
func people_present_at(t: float) -> bool:
	return SiteDeploySchedule.people_present(_rec, t)


func next_present_h(t: float) -> float:
	return SiteDeploySchedule.next_present_h(_rec, t)


## Everything the crews would be handed right now for `action` (what the
## chip's menu counts): [{kind, id, label, pos, …}].
func inventory(action: String) -> Array:
	bind(_main)
	return _inventory(action)


## What is going on: {active (bool), action, done, total, pending, crews,
## line} — `line` is the one sentence for the HUD and the chip tooltip.
func status() -> Dictionary:
	var out := {"active": false, "action": "", "done": 0, "total": 0, "pending": 0,
		"crews": 0, "line": "", "replaying": false}
	for ev in events():
		var id := str((ev as Dictionary).get("id", ""))
		var info := SiteDeploySchedule.fired_info(_rec, id)
		if info.is_empty():
			continue
		if bool(info.get("done", false)):
			if bool(info.get("replaying", false)):
				out["replaying"] = true
				out["action"] = str((ev as Dictionary).get("action", ""))
			continue
		out["active"] = true
		out["action"] = str((ev as Dictionary).get("action", ""))
		var total := (info.get("items", []) as Array).size()
		var done := 0
		for p in info.get("projects", []):
			if _project_state(p as Dictionary) == "done" or bool((p as Dictionary).get("lost", false)):
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
				if _project_state(p as Dictionary) == "done" or bool((p as Dictionary).get("lost", false)):
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
		if int(out["crews"]) == 0:
			txt += " · nobody on site yet"
		else:
			var away := _away_count(_crews_of_active())
			if away > 0:
				txt += " · %s still on the road" % UiText.count(away, "camp")
			txt += " · %s on it" % UiText.count(int(out["crews"]), "camp")
		out["line"] = txt
	elif bool(out["replaying"]):
		out["line"] = "%s the site · replaying the crew's work" % SiteDeploySchedule.action_verb(str(out["action"]))
	else:
		var evs := events()
		if evs.is_empty():
			out["line"] = "No deployment scheduled"
		else:
			var now := _now_h()
			var nxt: Dictionary = {}
			for e in evs:
				if float((e as Dictionary).get("at_h", 0.0)) > now:
					nxt = e
					break
			if not nxt.is_empty():
				out["line"] = "%s at %s" % [SiteDeploySchedule.action_label(str(nxt.get("action", ""))),
					ClimelapseExportOptions.timecode_at(float(nxt.get("at_h", 0.0)))]
			else:
				var ph := phase_at(now)
				out["line"] = "Site %s" % str(ph.get("phase", ""))
	return out


## Pack or deploy everything NOW with no crew (the before-state for a
## scheduled build, or "I just want it packed"). Cancels any site project in
## flight and clears its event's stamp; a finished event loses its replay.
func apply_instant(action: String) -> int:
	bind(_main)
	if _loader == null:
		return 0
	for ev in events():
		var id := str((ev as Dictionary).get("id", ""))
		var info := SiteDeploySchedule.fired_info(_rec, id)
		if info.is_empty():
			continue
		if not bool(info.get("done", false)):
			_cancel_projects(info)
			_release(info)
			SiteDeploySchedule.unmark(_rec, id)
			_dirty = true
		elif info.has("done_h"):
			info["replaying"] = false
			info.erase("done_h")
			info.erase("after")
			info.erase("after_pending")
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
# Drive events: the vehicles' arrival / departure records
# ---------------------------------------------------------------------------

## Write every self-driving vehicle's `arrival` from the ARRIVE event and its
## `departure` from the LEAVE event (none = cleared). `force` re-applies
## even when nothing is missing (the gate moved, an event was edited);
## otherwise only the vehicles that lack a record are scheduled, so the
## records (and the prop file) are not rewritten on every tick. Returns how
## many records were written.
func apply_drive_events(force: bool = false) -> int:
	bind(_main)
	if _loader == null or not _loader.has_method("schedule_vehicle_arrivals"):
		return 0
	var n := 0
	var arr := SiteDeploySchedule.event_of(_rec, SiteDeploySchedule.ACTION_ARRIVE)
	var gap: Dictionary = _loader.call("drive_schedule_gap") if _loader.has_method("drive_schedule_gap") else {}
	if arr.is_empty():
		if force or int(gap.get("arrivals", 0)) > 0:
			n += int(_loader.call("clear_vehicle_arrivals"))
	elif force or int(gap.get("no_arrival", 0)) > 0:
		n += int(_loader.call("schedule_vehicle_arrivals", float(arr.get("at_h", 0.0)),
			VehicleDrive.DEFAULT_SPACING_H))
	var lv := SiteDeploySchedule.event_of(_rec, SiteDeploySchedule.ACTION_LEAVE)
	if lv.is_empty():
		if force or int(gap.get("departures", 0)) > 0:
			n += int(_loader.call("clear_vehicle_departures", ""))
	elif force or int(gap.get("no_departure", 0)) > 0:
		n += int(_loader.call("schedule_vehicle_departures", float(lv.get("at_h", 0.0)),
			VehicleDrive.DEFAULT_SPACING_H, "schedule"))
	return n


## A vehicle placed (or stepped out of) after the events were set gets its
## drive on the next tick; checked twice a second.
func _keep_drives_scheduled() -> void:
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_gap_ms < 500:
		return
	_last_gap_ms = now_ms
	if SiteDeploySchedule.event_of(_rec, SiteDeploySchedule.ACTION_ARRIVE).is_empty() \
			and SiteDeploySchedule.event_of(_rec, SiteDeploySchedule.ACTION_LEAVE).is_empty():
		return
	apply_drive_events(false)


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
	var before := {}
	for it in items:
		var item := it as Dictionary
		compact.append({"kind": str(item.get("kind", "")), "id": str(item.get("id", ""))})
		before[str(item.get("id", ""))] = _snapshot(item)
	# A crew-less fire is NOT done: the items wait, and _service picks the
	# crews up the moment a camp is on site (people arriving later).
	SiteDeploySchedule.mark_fired(_rec, id, abs_h, {
		"crews": picked, "items": compact, "pending": items, "projects": [],
		"before": before, "done": items.is_empty()})
	_dirty = true
	if items.is_empty():
		_toast("%s — nothing to %s" % [SiteDeploySchedule.action_label(action),
			"deploy" if action == SiteDeploySchedule.ACTION_DEPLOY else "pack"], Vector2.INF)
	elif picked.is_empty():
		_toast("%s — nobody on site yet; the crews start when a camp is here" % SiteDeploySchedule.action_label(action), Vector2.INF)
	else:
		var centre := Vector2.ZERO
		for it in items:
			centre += (it as Dictionary).get("pos", Vector2.ZERO)
		centre /= float(items.size())
		var away := _away_count(picked)
		if away >= picked.size():
			var when := _next_arrival_h(picked)
			_toast("%s — %s; the crews are still on the road%s" % [SiteDeploySchedule.action_label(action),
				_count_text(items), (", here at %s" % ClimelapseExportOptions.timecode_at(when)) if when < INF else ""], centre)
		else:
			_toast("%s — %s, %s on it" % [SiteDeploySchedule.action_label(action), _count_text(items),
				UiText.count(picked.size(), "camp")], centre)


## Hand out pending work, push camp fractions, record progress traces,
## notice completion — for every fired event and the manual (one-structure)
## stamp alike.
func _service(abs_h: float) -> void:
	var crews_all: Array = []
	var runs: Array = []   # [[action, info, event id ("" = manual)]]
	for ev in events():
		var info0 := SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))
		if not info0.is_empty() and not bool(info0.get("done", false)):
			runs.append([str((ev as Dictionary).get("action", "")), info0, str((ev as Dictionary).get("id", ""))])
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty() and not bool(manual.get("done", false)):
		runs.append([str(manual.get("action", SiteDeploySchedule.ACTION_DEPLOY)), manual, ""])
	for run in runs:
		var action := str(run[0])
		var info: Dictionary = run[1]
		var ev_id := str(run[2])
		var pending: Array = info.get("pending", [])
		if not pending.is_empty() and abs_h - _last_retry_h >= RETRY_EVERY_H:
			_last_retry_h = abs_h
			if crews_all.is_empty() and _bridge.has_method("crew_summary"):
				crews_all = _bridge.call("crew_summary")
			# An event that fired with nobody on site takes the crews that
			# have arrived since.
			if (info.get("crews", []) as Array).is_empty() and not crews_all.is_empty():
				var picked: Array = SiteDeployPlanner.pick_crews(crews_all, pending)
				if not picked.is_empty():
					for iid in picked:
						_bridge.call("set_all_hands", str(iid), true)
					info["crews"] = picked
					_dirty = true
					_toast("%s — %s on it now" % [SiteDeploySchedule.action_label(action),
						UiText.count(picked.size(), "camp")], Vector2.INF)
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
							(info["projects"] as Array).append({"iid": str(iid), "pid": pid, "item": it,
								"trace": [[abs_h, 0.0]]})
				info["pending"] = left
				_dirty = true
		# Camps pitch / strike with the crew's labour; props follow their
		# own phases. Every project's progress is traced for the replay.
		var all_done := (info.get("pending", []) as Array).is_empty()
		for p in info.get("projects", []):
			var pd := p as Dictionary
			var item: Dictionary = pd.get("item", {})
			var state := _project_state(pd)
			if bool(pd.get("lost", false)):
				continue
			if state == "active":
				all_done = false
				var f := _project_progress(pd)
				if not pd.has("trace"):
					pd["trace"] = []
				if SiteDeploySchedule.trace_push(pd["trace"] as Array, abs_h, f):
					_dirty = true
				if str(item.get("kind", "")) == "camp":
					var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
					_loader.call("set_camp_built", str(item.get("id", "")), f if deploy else 1.0 - f, false)
			elif state == "done":
				if not pd.has("done_h"):
					pd["done_h"] = abs_h
					if not pd.has("trace"):
						pd["trace"] = []
					SiteDeploySchedule.trace_push(pd["trace"] as Array, abs_h, 1.0)
					_dirty = true
				if str(item.get("kind", "")) == "camp":
					_loader.call("set_camp_built", str(item.get("id", "")),
						1.0 if action == SiteDeploySchedule.ACTION_DEPLOY else 0.0, false)
			else:
				# A camp the bridge has not seen yet (the first ticks after
				# a load) is not a lost project: wait for it.
				if crews_all.is_empty() and _bridge.has_method("crew_summary"):
					crews_all = _bridge.call("crew_summary")
				var known := false
				for c in crews_all:
					if str((c as Dictionary).get("iid", "")) == str(pd.get("iid", "")):
						known = true
						break
				if not known:
					all_done = false
					continue
				# The project is gone (its camp cleared, the board wiped, a
				# save from before it): the crew stopped. The item is left as
				# it stands, visible again, and counts as done — never a ghost
				# nobody can pack or unpack.
				pd["lost"] = true
				_dirty = true
				_clear_construction(item)
				_toast("Crew work on %s stopped — left as it stands" % str(item.get("label", "a structure")), Vector2.INF)
		if all_done:
			_complete(info, action, ev_id, abs_h, is_same(info, manual))


## An event's crews are done: snapshot the end state (the replay's far end),
## release the crews, and after a pack-up send the vehicles home.
func _complete(info: Dictionary, action: String, ev_id: String, abs_h: float, manual: bool) -> void:
	info["done"] = true
	info["done_h"] = abs_h
	# The `after` snapshot waits for the last effect to land: the finishing
	# chore's unpack / pack is a DEFERRED coroutine (the fold sweep), so on
	# this tick the record still reads the old packed state (_settle_afters).
	info["after_pending"] = true
	_dirty = true
	_release(info)
	if manual:
		_toast("Crew work done — %s" % _count_text(_items_of(info)), Vector2.INF)
		return
	_toast("%s — done" % SiteDeploySchedule.action_label(action), Vector2.INF)
	# Everything is packed and loaded: the vehicles drive out through the
	# gate — as a LEAVE event on the timeline, which the player can drag or
	# remove, unless one is already there.
	if action == SiteDeploySchedule.ACTION_PACKUP \
			and SiteDeploySchedule.event_of(_rec, SiteDeploySchedule.ACTION_LEAVE).is_empty():
		var lid := SiteDeploySchedule.add_event(_rec, SiteDeploySchedule.ACTION_LEAVE, abs_h + DEPART_AFTER_H)
		if not lid.is_empty():
			info["auto_leave"] = lid
			var n := apply_drive_events(true)
			if n > 0:
				_toast("%s leaving through the gate" % UiText.count(n, "vehicle"), Vector2.INF)


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
	# Every prop — a rack, a dome, a toroid, a Linkage Lab frame, a GLB — gets
	# the shared labour-mode build site, which follows this project and
	# draws the structure piece by piece (a rack's own units, anything else
	# cut into its real pieces; a pack-up plays it backwards). build_state
	# flips the prop into construction rendering: the site hides the model.
	var run := {"mode": "labour", "action": action, "iid": iid, "project_id": pid,
		"crew_n": clampi(roster, PalletRackBuildSite.MIN_CREW if model_id == PalletRackBuilder.MODEL_ID
			else MIN_PIECE_CREW, PalletRackBuildSite.MAX_LABOUR_LANES)}
	var patch := {"build_state": {"phase": "", "ghost": 0.14}, PalletRackBuildSite.RECORD_KEY: run}
	# A Linkage Lab frame comes down from its build pose: the crew folds it
	# there first (the fold sweep), then takes it apart piece by piece — its
	# pieces are cut at that pose, the one a deploy puts it together in.
	if model_id == LinkageStructureBuilder.MODEL_ID and not deploy:
		var prop := PlacedPropRuntime.find_by_prop_id(_main, pid_prop)
		var dep: Node = prop.get_node_or_null("LinkageDeployRuntime") if prop != null else null
		if dep != null and (bool(dep.call("is_deployed")) or bool(dep.call("is_animating"))):
			_stow_then_stamp(dep, pid_prop, patch)
			return pid
	PlacedPropService.update_prop_record(_main, pid_prop, patch, true)
	return pid


## Fold a deployed linkage frame to the crew's build pose, then hand it to
## the build site.
func _stow_then_stamp(dep: Node, pid_prop: String, patch: Dictionary) -> void:
	var b := dep.get_parent().get_node_or_null("ModelRoot") as LinkageStructureBuilder \
		if dep.get_parent() != null else null
	if b != null:
		dep.call("fold_to", LinkageStructureBuilder.crew_pose_angle(b.params))
	elif not bool(dep.call("is_animating")) or float(dep.get("_rate")) > 0.0:
		dep.call("toggle_deploy")
	await dep.deploy_state_changed
	if _main == null or not is_instance_valid(_main) or not _main.is_inside_tree():
		return
	# Not from inside the signal: the stamp rebuilds the prop, which frees
	# the fold runtime still emitting it (a native crash, measured).
	await _main.get_tree().process_frame
	if _main == null or not is_instance_valid(_main):
		return
	if PlacedPropService.get_prop_record(_main, pid_prop).is_empty():
		return
	PlacedPropService.update_prop_record(_main, pid_prop, patch, true)


# ---------------------------------------------------------------------------
# Undo / replay / instant
# ---------------------------------------------------------------------------

## The clock was scrubbed back past a fired event: cancel its crew work and
## put every item back EXACTLY as it was before the event (its `before`
## snapshot: position, packed, stowed in which bay, where it belongs).
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
	var before: Dictionary = info.get("before", {})
	for it in info.get("items", []):
		var item := it as Dictionary
		var cid := str(item.get("id", ""))
		if before.has(cid):
			_restore_snapshot(item, before[cid] as Dictionary)
		else:
			_instant(item, inverse)
	# The LEAVE this pack-up added goes with it; a leave the player set stays.
	var auto_leave := str(info.get("auto_leave", ""))
	if not auto_leave.is_empty() and not SiteDeploySchedule.event(_rec, auto_leave).is_empty():
		SiteDeploySchedule.remove_event(_rec, auto_leave)
		apply_drive_events(true)
	SiteDeploySchedule.unmark(_rec, id)
	_dirty = true
	_toast("Scrubbed back past “%s” — put back as it was" % SiteDeploySchedule.action_label(action), Vector2.INF)


## A finished event's `after` snapshot is taken once every prop has reached
## the action's end state (unpacked and clear for a deploy, packed for a
## pack-up) — or AFTER_SETTLE_H after the finish, whatever state it is in.
const AFTER_SETTLE_H := 0.1

func _settle_afters(abs_h: float) -> void:
	var stamps: Array = []
	for ev in SiteDeploySchedule.crew_events(_rec):
		stamps.append([str((ev as Dictionary).get("action", "")),
			SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))])
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty():
		stamps.append([str(manual.get("action", "")), manual])
	for s in stamps:
		var action := str(s[0])
		var info: Dictionary = s[1]
		if info.is_empty() or not bool(info.get("after_pending", false)):
			continue
		var want_packed := action == SiteDeploySchedule.ACTION_PACKUP
		var settled := true
		for it in info.get("items", []):
			var item := it as Dictionary
			if str(item.get("kind", "")) != "prop":
				continue
			var rec := PlacedPropService.get_prop_record(_main, str(item.get("id", "")))
			if rec.is_empty():
				continue
			if bool(rec.get("packed", false)) != want_packed or rec.get("build_state") is Dictionary:
				settled = false
				break
		if not settled and abs_h - float(info.get("done_h", abs_h)) < AFTER_SETTLE_H:
			continue
		var after := {}
		for it2 in info.get("items", []):
			after[str((it2 as Dictionary).get("id", ""))] = _snapshot(it2 as Dictionary)
		info["after"] = after
		info.erase("after_pending")
		_dirty = true


## Inside a FINISHED event's window the crew's work is shown again from the
## projects' traces: the structure under construction at that hour's
## progress (the build site draws it), the camps at their fraction. Past the
## window's end the `after` snapshot comes back. Scrubbing back before the
## event is `_undo`'s.
func _replay(abs_h: float) -> void:
	for ev in SiteDeploySchedule.crew_events(_rec):
		var ed := ev as Dictionary
		var id := str(ed.get("id", ""))
		var info := SiteDeploySchedule.fired_info(_rec, id)
		if info.is_empty() or not bool(info.get("done", false)) or not info.has("done_h") \
				or bool(info.get("after_pending", false)):
			continue
		var action := str(ed.get("action", ""))
		var at := float(info.get("at", ed.get("at_h", 0.0)))
		var done_h := float(info["done_h"])
		var inside := abs_h >= at and abs_h < done_h
		if inside:
			if not bool(info.get("replaying", false)):
				info["replaying"] = true
				_dirty = true
				_replay_enter(info, action)
			_replay_frame(info, action, abs_h)
		elif bool(info.get("replaying", false)):
			info["replaying"] = false
			_dirty = true
			_replay_exit(info)


## Put every item of a finished event back under construction at the place
## it was built: a deploy's crate at its home (the `after` pose), a pack-up's
## structure where it stood (the `before` pose).
func _replay_enter(info: Dictionary, action: String) -> void:
	var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
	var before: Dictionary = info.get("before", {})
	var after: Dictionary = info.get("after", {})
	for p in info.get("projects", []):
		var pd := p as Dictionary
		var item: Dictionary = pd.get("item", {})
		if str(item.get("kind", "")) != "prop" or bool(pd.get("lost", false)):
			continue
		var cid := str(item.get("id", ""))
		var rec := PlacedPropService.get_prop_record(_main, cid)
		if rec.is_empty():
			continue
		var built: Dictionary = (after.get(cid, {}) if deploy else before.get(cid, {})) as Dictionary
		var patch := {"build_state": {"phase": "", "ghost": 0.14},
			PalletRackBuildSite.RECORD_KEY: {"mode": "labour", "action": action,
				"iid": str(pd.get("iid", "")), "project_id": str(pd.get("pid", "")),
				"crew_n": MIN_PIECE_CREW, "replay_frac": 0.0},
			# The crew builds FROM the crate (packed + build_state), and
			# strikes the standing structure (unpacked + build_state).
			"packed": deploy, "stowed_in": null, "stow_local": null, "collision_enabled": true}
		for k in ["x", "z", "yaw", "y_offset", "ground_y"]:
			if built.has(k):
				patch[k] = built[k]
		PlacedPropService.update_prop_record(_main, cid, patch, true)


func _replay_frame(info: Dictionary, action: String, abs_h: float) -> void:
	var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
	for p in info.get("projects", []):
		var pd := p as Dictionary
		var item: Dictionary = pd.get("item", {})
		if bool(pd.get("lost", false)):
			continue
		var f := SiteDeploySchedule.trace_frac(pd.get("trace", []) as Array, abs_h)
		var cid := str(item.get("id", ""))
		if str(item.get("kind", "")) == "camp":
			_loader.call("set_camp_built", cid, f if deploy else 1.0 - f, false)
			continue
		var site := PalletRackBuildSite.site_for(_main, cid)
		if site != null:
			site.set_replay_frac(f)
		var rec := PlacedPropService.get_prop_record(_main, cid)
		var run: Variant = rec.get(PalletRackBuildSite.RECORD_KEY)
		if run is Dictionary and absf(float((run as Dictionary).get("replay_frac", -1.0)) - f) >= REPLAY_RECORD_STEP:
			var r2 := (run as Dictionary).duplicate()
			r2["replay_frac"] = f
			PlacedPropService.update_prop_record(_main, cid, {PalletRackBuildSite.RECORD_KEY: r2}, false)


func _replay_exit(info: Dictionary) -> void:
	var after: Dictionary = info.get("after", {})
	for it in info.get("items", []):
		var item := it as Dictionary
		var cid := str(item.get("id", ""))
		if after.has(cid):
			_restore_snapshot(item, after[cid] as Dictionary)
		else:
			_clear_construction(item)


func _cancel_projects(info: Dictionary) -> void:
	for p in info.get("projects", []):
		var pd := p as Dictionary
		if _project_state(pd) == "active" and _bridge != null:
			_bridge.call("cancel_project", str(pd.get("iid", "")), str(pd.get("pid", "")), _main)
		# The prop is never left a ghost: construction state goes with the
		# project (an undo re-stamps what it needs).
		_clear_construction(pd.get("item", {}) as Dictionary)


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
	var home: Variant = rec.get("deploy_home")
	if deploy and home is Dictionary:
		var h := home as Dictionary
		PlacedPropService.move_prop_at(_main, id, float(h.get("x", 0.0)), float(h.get("z", 0.0)),
			NAN, float(h.get("y_offset", 0.0)))
		PlacedPropService.update_prop_record(_main, id,
			{"deploy_home": null, "yaw": float(h.get("yaw", 0.0))}, false)
	PlacedPropService.update_prop_record(_main, id,
		{"build_state": null, PalletRackBuildSite.RECORD_KEY: null}, not toggle)
	if toggle and _loader.has_method("set_prop_packed"):
		_loader.call_deferred("set_prop_packed", id, not deploy)


## The transport state of an item as it stands now (SiteDeploySchedule
## .snapshot for a prop, {built} for a camp).
func _snapshot(item: Dictionary) -> Dictionary:
	var id := str(item.get("id", ""))
	if str(item.get("kind", "")) == "camp":
		return {"built": bool(_loader.call("camp_built", id)) if _loader != null and _loader.has_method("camp_built") else true}
	return SiteDeploySchedule.snapshot(PlacedPropService.get_prop_record(_main, id))


## Put an item back to a snapshot: a camp's built flag; a prop's place,
## packed state and stowage. A crate stowed in a host is re-seated at the
## host's CURRENT pose (the host may have moved meanwhile); a host that is
## gone leaves it standing where the snapshot says.
func _restore_snapshot(item: Dictionary, snap: Dictionary) -> void:
	var id := str(item.get("id", ""))
	if str(item.get("kind", "")) == "camp":
		_loader.call("set_camp_built", id, 1.0 if bool(snap.get("built", true)) else 0.0, true)
		return
	var rec := PlacedPropService.get_prop_record(_main, id)
	if rec.is_empty():
		return
	var patch := SiteDeploySchedule.restore_patch(snap)
	patch["build_state"] = null
	patch[PalletRackBuildSite.RECORD_KEY] = null
	var host := str(snap.get("stowed_in", ""))
	if not host.is_empty():
		var hrec := PlacedPropService.get_prop_record(_main, host)
		if not hrec.is_empty() and snap.get("stow_local") is Array:
			patch.merge(VehicleCargo.place_stowed(hrec, {"stow_local": snap["stow_local"]}), true)
			if patch.has("x") and patch.has("z"):
				patch["ground_y"] = TerrainSurfaceQuery.ground_height_at(_main, float(patch["x"]), float(patch["z"]))
		else:
			patch["stowed_in"] = null
			patch["stow_local"] = null
			patch["collision_enabled"] = true
	var want_packed := bool(snap.get("packed", false))
	var flip := bool(rec.get("packed", false)) != want_packed
	patch.erase("packed")
	PlacedPropService.update_prop_record(_main, id, patch, not flip)
	if flip and _loader.has_method("set_prop_packed"):
		# A crate going back INTO a bay is stowed again after the pack (the
		# pack itself refuses nothing; the unpack of a stowed crate is
		# refused, which the snapshot never asks for).
		_loader.call_deferred("set_prop_packed", id, want_packed)


## Take the construction state off a prop (its site stands down): the prop
## is what its record says again — a crate, or the standing structure.
func _clear_construction(item: Dictionary) -> void:
	if str(item.get("kind", "")) != "prop":
		return
	var id := str(item.get("id", ""))
	var rec := PlacedPropService.get_prop_record(_main, id)
	if rec.is_empty():
		return
	if not (rec.get("build_state") is Dictionary) and not (rec.get(PalletRackBuildSite.RECORD_KEY) is Dictionary):
		return
	PlacedPropService.update_prop_record(_main, id,
		{"build_state": null, PalletRackBuildSite.RECORD_KEY: null}, true)


# ---------------------------------------------------------------------------
# Stuck builds
# ---------------------------------------------------------------------------

## Props a LIVE project is working on (the director's stamps and every
## camp's own project store — the Lab's and the prop editor's linkage jobs
## go through the stores alone).
func _live_prop_ids() -> Dictionary:
	var out := {}
	var stamps: Array = []
	for ev in events():
		stamps.append(SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", ""))))
	stamps.append(_rec.get("manual", {}))
	var known := {}
	if _bridge != null and _bridge.has_method("crew_summary"):
		for c in _bridge.call("crew_summary"):
			known[str((c as Dictionary).get("iid", ""))] = true
	for s in stamps:
		var info := s as Dictionary
		if info.is_empty():
			continue
		for p in info.get("projects", []):
			var pd := p as Dictionary
			# A project on a camp the bridge has not seen yet is live until
			# the camp says otherwise.
			if _project_state(pd) == "active" or not known.has(str(pd.get("iid", ""))):
				out[str((pd.get("item", {}) as Dictionary).get("id", ""))] = true
		if not bool(info.get("done", false)):
			for it in info.get("pending", []):
				out[str((it as Dictionary).get("id", ""))] = true
		if bool(info.get("replaying", false)):
			for p2 in info.get("projects", []):
				out[str(((p2 as Dictionary).get("item", {}) as Dictionary).get("id", ""))] = true
	if _bridge != null and _bridge.has_method("crew_summary"):
		for c in _bridge.call("crew_summary"):
			var store = _bridge.call("project_store_for", str((c as Dictionary).get("iid", "")))
			if store == null:
				continue
			for p3 in store.active():
				var pid := str((p3 as Dictionary).get("prop_id", ""))
				if not pid.is_empty():
					out[pid] = true
	return out


## A prop under construction with no live project behind it is STUCK: the
## crew's job vanished (its camp cleared, the schedule cleared, a save from
## before the job) and the ghost nobody can pack or unpack stayed. The
## construction state comes off and the prop is what its record says again.
## Returns true when it healed something.
func _heal_stale(rec: Dictionary, live: Dictionary) -> bool:
	var bs: Variant = rec.get("build_state")
	var run: Variant = rec.get(PalletRackBuildSite.RECORD_KEY)
	var constructing := bs is Dictionary and not (bs as Dictionary).is_empty()
	var scheduled := run is Dictionary and PalletRackBuildSite.is_schedule_run(run as Dictionary)
	if not constructing and not scheduled:
		return false
	if constructing and bool((bs as Dictionary).get("preview", false)):
		return false   # the Lab's own preview ghost
	var id := str(rec.get("id", ""))
	if live.has(id):
		return false
	var patch := {"build_state": null}
	if scheduled or constructing:
		patch[PalletRackBuildSite.RECORD_KEY] = null
	PlacedPropService.update_prop_record(_main, id, patch, true)
	if not _healed.has(id):
		_healed[id] = true
		var entry := ModelCatalog.find(str(rec.get("model_id", "")))
		_toast("Cleared a stuck build on %s — it is %s again" % [str(entry.get("label", rec.get("model_id", "a structure"))),
			"a crate" if bool(rec.get("packed", false)) else "standing"], Vector2.INF)
	return true


## Heal every stuck prop on the site now (the chip's "Fix stuck builds").
## Returns how many.
func fix_stuck() -> int:
	bind(_main)
	if _loader == null or not _loader.has_method("placed_prop_records"):
		return 0
	var live := _live_prop_ids()
	var n := 0
	for r in _loader.call("placed_prop_records"):
		if _heal_stale(r as Dictionary, live):
			n += 1
	return n


## How many props are stuck right now (the menu's count).
func stuck_count() -> int:
	bind(_main)
	if _loader == null or not _loader.has_method("placed_prop_records"):
		return 0
	var live := _live_prop_ids()
	var n := 0
	for r in _loader.call("placed_prop_records"):
		var rec := r as Dictionary
		var bs: Variant = rec.get("build_state")
		var run: Variant = rec.get(PalletRackBuildSite.RECORD_KEY)
		var constructing := bs is Dictionary and not (bs as Dictionary).is_empty() \
			and not bool((bs as Dictionary).get("preview", false))
		var scheduled := run is Dictionary and PalletRackBuildSite.is_schedule_run(run as Dictionary)
		if (constructing or scheduled) and not live.has(str(rec.get("id", ""))):
			n += 1
	return n


## Stop the crew's work on ONE prop (the prop editor's "Cancel crew work"):
## its project is cancelled wherever it lives, the item leaves every stamp,
## the construction state comes off. The prop stays as its record says
## (packed or standing). Returns true when there was anything to stop.
func abandon_prop(pid: String) -> bool:
	bind(_main)
	if pid.is_empty():
		return false
	var found := false
	var stamps: Array = []
	for ev in events():
		stamps.append(SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", ""))))
	stamps.append(_rec.get("manual", {}))
	for s in stamps:
		var info := s as Dictionary
		if info.is_empty():
			continue
		var keep: Array = []
		for p in info.get("projects", []):
			var pd := p as Dictionary
			if str((pd.get("item", {}) as Dictionary).get("id", "")) == pid:
				found = true
				if _project_state(pd) == "active" and _bridge != null:
					_bridge.call("cancel_project", str(pd.get("iid", "")), str(pd.get("pid", "")), _main)
				info["items"] = _without_id(info.get("items", []), pid)
				(info.get("before", {}) as Dictionary).erase(pid)
				(info.get("after", {}) as Dictionary).erase(pid)
				continue
			keep.append(pd)
		if keep.size() != (info.get("projects", []) as Array).size():
			info["projects"] = keep
			_dirty = true
		var pend: Array = info.get("pending", [])
		var pend2 := _without_id(pend, pid)
		if pend2.size() != pend.size():
			found = true
			info["pending"] = pend2
			info["items"] = _without_id(info.get("items", []), pid)
			_dirty = true
	# A job on a camp's own board (the Lab's rebuild / breakdown).
	if _bridge != null and _bridge.has_method("crew_summary"):
		for c in _bridge.call("crew_summary"):
			var iid := str((c as Dictionary).get("iid", ""))
			var store = _bridge.call("project_store_for", iid)
			if store == null:
				continue
			for p3 in store.active():
				if str((p3 as Dictionary).get("prop_id", "")) == pid:
					found = true
					_bridge.call("cancel_project", iid, str((p3 as Dictionary).get("id", "")), _main)
	var rec := PlacedPropService.get_prop_record(_main, pid)
	if not rec.is_empty() and (rec.get("build_state") is Dictionary or rec.get(PalletRackBuildSite.RECORD_KEY) is Dictionary):
		found = true
		_clear_construction({"kind": "prop", "id": pid})
	if _dirty:
		_save()
		changed.emit()
	return found


## Finish ONE prop's crew job at once, no crew (the prop editor's "Finish
## now"): the job is abandoned and the prop goes straight to the action's
## end state (a deploy's crate back at its home and unpacked; a pack-up
## packed where it stands).
func finish_prop_now(pid: String, action: String) -> bool:
	bind(_main)
	if pid.is_empty() or _loader == null:
		return false
	abandon_prop(pid)
	_instant({"kind": "prop", "id": pid}, action)
	return true


static func _without_id(list: Array, pid: String) -> Array:
	var out: Array = []
	for it in list:
		if str((it as Dictionary).get("id", "")) != pid:
			out.append(it)
	return out


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------

func _inventory(action: String) -> Array:
	var out: Array = []
	if _loader == null:
		return out
	var want_packed := action == SiteDeploySchedule.ACTION_PACKUP   # pack-up takes STANDING things
	# The doors and the forklifts once per inventory, not once per item (each
	# door is a vehicle design solve).
	var all_recs: Array = _loader.call("placed_prop_records") if _loader.has_method("placed_prop_records") else []
	var doors: Array = VehicleCargo.host_doors(all_recs, _now_h()) if want_packed else []
	var forks: Array = []
	for fr in all_recs:
		if str((fr as Dictionary).get("model_id", "")) == ForkliftBuilder.MODEL_ID:
			forks.append(fr)
	var live := _live_prop_ids()
	if _loader.has_method("placed_prop_records"):
		for r in all_recs:
			var rec: Dictionary = r
			var model_id := str(rec.get("model_id", ""))
			# Hosts and the machines that move the work are not packed by it:
			# a container, the forklift, a living vehicle (it drives out).
			if model_id.is_empty() or model_id == "cargo_container" \
					or model_id == ForkliftBuilder.MODEL_ID or VehicleBuilder.handles(model_id) \
					or bool(rec.get("hidden_3d", false)):
				continue
			var host := str(rec.get("stowed_in", ""))
			if not host.is_empty():
				# A kit a pack-up stowed comes back out for the next deploy
				# (its home is recorded) once its host stands in its spot; a
				# delivery's crate is the unload's.
				if want_packed or not (rec.get("deploy_home") is Dictionary):
					continue
				var hrec := PlacedPropService.get_prop_record(_main, host)
				var tow := PlacedPropService.get_prop_record(_main, str(hrec.get("hitched_to", "")))
				if not hrec.is_empty() and not VehicleCargo.host_ready(hrec, _now_h(), tow):
					continue
			# A ghost with no job behind it is healed on the spot and taken.
			if _heal_stale(rec, live):
				rec = PlacedPropService.get_prop_record(_main, str(rec.get("id", "")))
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
			var fork_check := false
			if want_packed:
				var door := VehicleCargo.door_near_in(doors, item["pos"] as Vector2, LOADOUT_REACH_M)
				if not door.is_empty():
					item["loadout"] = door
					fork_check = true
			elif rec.get("deploy_home") is Dictionary:
				item["home"] = (rec["deploy_home"] as Dictionary).duplicate()
				fork_check = true
			if fork_check:
				var fid := _nearest_fork(forks, item["pos"] as Vector2)
				if not fid.is_empty():
					item["forklift_id"] = fid
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


## The nearest forklift within 150 m (the loader's nearest_forklift_id rule)
## in a list gathered once.
static func _nearest_fork(forks: Array, at: Vector2, max_m: float = 150.0) -> String:
	var best := ""
	var best_d := max_m
	for f in forks:
		var rec: Dictionary = f
		var d := at.distance_to(Vector2(float(rec.get("x", 0.0)), float(rec.get("z", 0.0))))
		if d < best_d:
			best_d = d
			best = str(rec.get("id", ""))
	return best


func _container_door_near(pos: Vector2) -> Dictionary:
	if _loader == null or not _loader.has_method("placed_prop_records"):
		return {}
	# A shipping container's door, or a living vehicle's cargo-bay door.
	return VehicleCargo.door_near(_loader.call("placed_prop_records"), pos, LOADOUT_REACH_M, _now_h())


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
		manual = {"crews": [], "items": [], "pending": [], "projects": [], "done": false, "action": action,
			"before": {}}
		_rec["manual"] = manual
	manual["done"] = false
	manual["action"] = action
	if not manual.has("before"):
		manual["before"] = {}
	(manual["before"] as Dictionary)[id] = _snapshot(item)
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
			(manual["projects"] as Array).append({"iid": str(iid), "pid": pid, "item": item,
				"trace": [[_now_h(), 0.0]]})
			out["project_id"] = pid
	if str(out["project_id"]).is_empty():
		(manual["pending"] as Array).append(item)
	var away := _away_count(picked)
	if away > 0 and away >= picked.size():
		out["away_until"] = _next_arrival_h(picked)
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


## How many of these crews are away (their people not on site yet).
func _away_count(crews: Array) -> int:
	if _bridge == null or not _bridge.has_method("is_away"):
		return 0
	var n := 0
	for iid in crews:
		if bool(_bridge.call("is_away", str(iid))):
			n += 1
	return n


## The hour the first of these crews is home (INF unknown).
func _next_arrival_h(crews: Array) -> float:
	if _bridge == null or not _bridge.has_method("away_camps"):
		return INF
	var away: Dictionary = _bridge.call("away_camps")
	var best := INF
	for iid in crews:
		if away.has(str(iid)):
			best = minf(best, float(away[str(iid)]))
	return best


func _crews_of_active() -> Array:
	for ev in events():
		var info := SiteDeploySchedule.fired_info(_rec, str((ev as Dictionary).get("id", "")))
		if not info.is_empty() and not bool(info.get("done", false)):
			return info.get("crews", [])
	var manual: Dictionary = _rec.get("manual", {})
	if not manual.is_empty() and not bool(manual.get("done", false)):
		return manual.get("crews", [])
	return []


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

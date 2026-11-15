class_name ScheduleSources
extends RefCounted

## The impure half of ScheduledEvents: gathers the world's scheduled things
## (deploy events, burns, venue sets, drives, meals, the rota) into one list,
## and routes an edit back to the system that owns it. Everything goes through
## ServiceLocator (never an autoload by bare name), so a script that loads this
## still compiles under --script.

const EXPORT_DIR := "user://schedule_export"


static func _graph() -> Node:
	return ServiceLocator.graph()


static func _loader() -> Node:
	return ServiceLocator.terrain_loader()


static func bridge() -> NpcPopulationBridge:
	var g := _graph()
	if g == null or not g.has_method("npc_population_bridge"):
		return null
	return g.call("npc_population_bridge")


static func deploy() -> SiteDeployDirector:
	var g := _graph()
	if g == null or not g.has_method("site_deploy"):
		return null
	return g.call("site_deploy")


static func now_h() -> float:
	var m := ServiceLocator.main()
	if m != null and m.has_method("get_absolute_hours"):
		return float(m.call("get_absolute_hours"))
	return 0.0


static func set_now_h(h: float) -> void:
	var m := ServiceLocator.main()
	if m != null and m.has_method("set_absolute_hours"):
		m.call("set_absolute_hours", h)


static func registry() -> SpaceRegistry:
	var l := _loader()
	if l != null and l.get("npc_spaces") is SpaceRegistry:
		return l.get("npc_spaces")
	var b := bridge()
	return b.registry_for(ServiceLocator.main()) if b != null else null


## The site's zone for the calendar: the clock's meridian offset and whether
## it observes daylight time.
static func timezone() -> Dictionary:
	var m := ServiceLocator.main()
	var clock: CelestialClock = m.get("clock") if m != null and m.get("clock") is CelestialClock else null
	if clock == null:
		return {"std_offset_h": 0.0, "dst": false}
	return {"std_offset_h": clock.zone_meridian_deg() / 15.0, "dst": clock.auto_dst}


# --- people -------------------------------------------------------------------

## The simulated habitats: [{id, name, light}].
static func habitats() -> Array:
	var out: Array = []
	var b := bridge()
	var g := _graph()
	if b == null:
		return out
	var model = g.get("model") if g != null else null
	for iid in b.pop_driven_item_ids():
		var name := str(iid)
		if model != null:
			var it: Dictionary = model.get_item(str(iid))
			for k in [str((it.get("specs", {}) as Dictionary).get("name", "")), str(it.get("name", "")),
					str(it.get("label", ""))]:
				if not k.strip_edges().is_empty():
					name = k
					break
		out.append({"id": str(iid), "name": name,
			"light": b.tier_of(str(iid)) == CrowdFocus.TIER_LIGHT})
	return out


static func routine_of(hab: String) -> NpcRoutine:
	var b := bridge()
	return b.routine_for(hab) if b != null else null


## A habitat's people: [{id, name, habitat, offset_h}].
static func people(hab: String) -> Array:
	var out: Array = []
	var b := bridge()
	if b == null:
		return out
	for a in b.roster_for(hab):
		var ag: NpcAgent = a
		out.append({"id": ag.id, "name": ag.display_name, "habitat": hab,
			"offset_h": ag.routine_offset_h})
	if out.is_empty():
		var c := b.cohort_for(hab)
		if c != null:
			for id in c.ids:
				out.append({"id": str(id), "name": NpcAgent.name_for(str(id)), "habitat": hab,
					"offset_h": NpcRoutine.offset_for(str(id))})
	return out


static func names_of(hab: String) -> Dictionary:
	var out := {}
	for p in people(hab):
		out[str(p["id"])] = str(p["name"])
	return out


# --- gathering ------------------------------------------------------------------

## Everything scheduled in [h0, h1]. `opts`: {meals: bool, rota: bool,
## habitat: id (meals and the rota for that one only; "" = every habitat)}.
static func gather(h0: float, h1: float, opts: Dictionary = {}) -> Array:
	var lists: Array = []
	var sd := deploy()
	if sd != null:
		lists.append(ScheduledEvents.from_deploy(sd.events()))
	var l := _loader()
	if l != null and l.has_method("scheduled_burns"):
		lists.append(ScheduledEvents.from_burns(l.call("scheduled_burns")))
	var reg := registry()
	if reg != null:
		lists.append(ScheduledEvents.from_programs(reg.spaces, h0, h1))
	if l != null and l.has_method("vehicle_arrivals"):
		lists.append(ScheduledEvents.from_vehicles(l.call("vehicle_arrivals"), vehicle_names()))
	var want_meals := bool(opts.get("meals", true))
	var want_rota := bool(opts.get("rota", true))
	var only := str(opts.get("habitat", ""))
	if want_meals or want_rota:
		var b := bridge()
		for h in habitats():
			var hid := str(h["id"])
			if not only.is_empty() and hid != only:
				continue
			if want_meals:
				var r := routine_of(hid)
				if r != null:
					lists.append(ScheduledEvents.from_meals(r.blocks, h0, h1, hid,
						"" if habitats().size() < 2 else str(h["name"])))
			if want_rota and b != null:
				lists.append(ScheduledEvents.in_window(
					ScheduledEvents.from_rota(b.rota_for(hid), names_of(hid), hid), h0, h1))
	return ScheduledEvents.in_window(ScheduledEvents.merge(lists), h0, h1)


static func vehicle_names() -> Dictionary:
	var out := {}
	var l := _loader()
	if l == null or not l.has_method("placed_prop_records"):
		return out
	for r in l.call("placed_prop_records"):
		var rec: Dictionary = r
		if rec.has("arrival") or rec.has("departure"):
			var nm := str(rec.get("name", ""))
			if nm.is_empty():
				nm = str(ModelCatalog.find(str(rec.get("model_id", ""))).get("label", "Vehicle"))
			out[str(rec.get("id", ""))] = nm
	return out


## The rota shifts of one person over [h0, h1].
static func shifts_of(hab: String, agent_id: String, h0: float, h1: float) -> Array:
	var b := bridge()
	if b == null:
		return []
	var all := ScheduledEvents.from_rota(b.rota_for(hab), {}, hab)
	var out: Array = []
	for e in ScheduledEvents.in_window(all, h0, h1):
		if ((e as Dictionary).get("who", []) as Array).has(agent_id):
			out.append(e)
	return out


# --- editing ----------------------------------------------------------------------

## Move an event to start at `at_h`, through the system that owns it. A set
## keeps its length and moves every day's copy (its slot repeats daily).
## Returns false for events that follow something else (drives, meals, shifts).
static func retime(ev: Dictionary, at_h: float) -> bool:
	match str(ev.get("source", "")):
		ScheduledEvents.SOURCE_DEPLOY:
			var sd := deploy()
			return sd != null and sd.move_event(str(ev.get("ref", ev.get("id", ""))), at_h)
		ScheduledEvents.SOURCE_BURN:
			var l := _loader()
			return l != null and l.has_method("schedule_prop_burn") \
				and bool(l.call("schedule_prop_burn", str(ev.get("ref", "")), at_h))
		ScheduledEvents.SOURCE_SET:
			var ref: Dictionary = ev.get("ref", {})
			return move_set(str(ref.get("space_id", "")), int(ref.get("slot", -1)),
				fposmod(at_h, 24.0), ScheduledEvents.duration_h(ev))
	return false


static func move_set(space_id: String, slot: int, start_h: float, len_h: float) -> bool:
	var reg := registry()
	if reg == null:
		return false
	var rec := reg.find_by_id(space_id)
	if rec.is_empty():
		return false
	var prog: Array = FestivalProgram.normalize(rec.get("program", []))
	if slot < 0 or slot >= prog.size():
		return false
	var s: Dictionary = (prog[slot] as Dictionary).duplicate()
	s["start_h"] = snappedf(fposmod(start_h, 24.0), 0.25)
	s["end_h"] = snappedf(fposmod(start_h + len_h, 24.0), 0.25)
	prog[slot] = s
	reg.set_space_fields(space_id, {"program": prog})
	_save_spaces()
	return true


static func remove(ev: Dictionary) -> bool:
	match str(ev.get("source", "")):
		ScheduledEvents.SOURCE_DEPLOY:
			var sd := deploy()
			return sd != null and sd.remove_event(str(ev.get("ref", ev.get("id", ""))))
		ScheduledEvents.SOURCE_BURN:
			var l := _loader()
			if l != null and l.has_method("cancel_prop_burn"):
				l.call("cancel_prop_burn", str(ev.get("ref", "")))
				return true
		ScheduledEvents.SOURCE_SET:
			var ref: Dictionary = ev.get("ref", {})
			var reg := registry()
			if reg == null:
				return false
			var rec := reg.find_by_id(str(ref.get("space_id", "")))
			var prog: Array = FestivalProgram.normalize(rec.get("program", []))
			var k := int(ref.get("slot", -1))
			if k < 0 or k >= prog.size():
				return false
			prog.remove_at(k)
			reg.set_space_fields(str(ref.get("space_id", "")), {"program": prog})
			_save_spaces()
			return true
	return false


static func _save_spaces() -> void:
	var l := _loader()
	if l != null and l.has_method("save_npc_spaces"):
		l.call("save_npc_spaces")


## A new deploy / pack-up / arrive / leave event. Returns its id.
static func add_deploy(action: String, at_h: float) -> String:
	var sd := deploy()
	return sd.add_event(action, at_h) if sd != null else ""


## A new daily set on a venue, from `start_h` for `len_h` hours.
static func add_set(space_id: String, start_h: float, len_h: float, label: String) -> bool:
	var reg := registry()
	if reg == null:
		return false
	var rec := reg.find_by_id(space_id)
	if rec.is_empty():
		return false
	var prog: Array = FestivalProgram.normalize(rec.get("program", []))
	if prog.size() >= FestivalProgram.MAX_SLOTS:
		return false
	prog.append(FestivalProgram.normalize_slot({"day": -1, "start_h": snappedf(start_h, 0.25),
		"end_h": snappedf(fposmod(start_h + len_h, 24.0), 0.25), "draw": 1.0, "label": label}))
	reg.set_space_fields(space_id, {"program": prog})
	_save_spaces()
	return true


static func add_burn(prop_id: String, at_h: float) -> bool:
	var l := _loader()
	return l != null and l.has_method("schedule_prop_burn") \
		and bool(l.call("schedule_prop_burn", prop_id, at_h))


## Venues that can carry a programme: [{id, label, type}].
static func venues() -> Array:
	var out: Array = []
	var reg := registry()
	if reg == null:
		return out
	for s in reg.spaces:
		var sp: Dictionary = s
		var t := str(sp.get("type", ""))
		if SpaceTypes.ENRICHMENT_KIND.has(t) or t == "stage":
			out.append({"id": str(sp.get("id", "")), "label": str(sp.get("label", t.capitalize())),
				"type": t})
	return out


## Placed props a burn can be scheduled on: [{id, label}].
static func burnable_props() -> Array:
	var out: Array = []
	var l := _loader()
	if l == null or not l.has_method("placed_prop_records"):
		return out
	for r in l.call("placed_prop_records"):
		var rec: Dictionary = r
		if not bool(rec.get("burnable", false)) and not rec.has("burn"):
			continue
		out.append({"id": str(rec.get("id", "")),
			"label": str(ModelCatalog.find(str(rec.get("model_id", ""))).get("label", "Structure"))})
	return out


# --- export --------------------------------------------------------------------

## Write the group calendar and one calendar per person for [h0, h1] into
## user://schedule_export/<world>/. Returns {dir, files: [paths], events: n}.
static func export_ics(h0: float, h1: float, world_key: String = "") -> Dictionary:
	if world_key.is_empty():
		world_key = WorldPaths.active_world_id()
	if world_key.is_empty():
		world_key = "site"
	var dir := "%s/%s" % [EXPORT_DIR, IcsWriter.file_name(world_key)]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var tz := timezone()
	var now_unix := int(Time.get_unix_time_from_system())
	var all := gather(h0, h1, {"meals": true, "rota": true})
	var files: Array = []
	var desc_of := func(ev: Dictionary) -> String:
		var who: Array = ev.get("who", [])
		if who.is_empty():
			return ScheduledEvents.word_of(str(ev.get("kind", "")))
		return "%s for %s" % [ScheduledEvents.word_of(str(ev.get("kind", ""))),
			UiText.count(who.size(), "person", "people")]
	var group := IcsWriter.calendar(all, {"name": "Community schedule", "key": world_key,
		"tz": tz, "now_unix": now_unix, "desc_of": desc_of})
	files.append(_write("%s/community.ics" % dir, group))
	for h in habitats():
		var hid := str(h["id"])
		for p in people(hid):
			var pid := str(p["id"])
			var mine := ScheduledEvents.for_person(all, pid)
			var mine2: Array = []
			for e in mine:
				var ev: Dictionary = e
				# Another habitat's meals are not this person's.
				if str(ev.get("source", "")) == ScheduledEvents.SOURCE_MEAL \
						and str((ev.get("ref", {}) as Dictionary).get("habitat", "")) != hid:
					continue
				mine2.append(ev)
			var txt := IcsWriter.calendar(mine2, {"name": "%s's schedule" % str(p["name"]),
				"key": "%s-%s" % [world_key, pid], "tz": tz, "now_unix": now_unix, "desc_of": desc_of})
			files.append(_write("%s/%s_%s.ics" % [dir, IcsWriter.file_name(str(p["name"])),
				IcsWriter.file_name(pid)], txt))
	return {"dir": dir, "files": files, "events": all.size()}


static func _write(path: String, text: String) -> String:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	return path

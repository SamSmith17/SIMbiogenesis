class_name SiteDeployPlanner
extends RefCounted

## Turns "deploy / pack up the whole site" into Site Projects: which crew
## takes which structure, and the chore rows each structure needs. Pure
## static over plain records so the selftest can run it offline; the
## director (SiteDeployDirector) gathers the inventory and hands the rows to
## NpcPopulationBridge.create_site_project.
##
## An ITEM: {kind: "prop"|"camp", id, label, pos: Vector2, mass_kg,
##   model_id (prop), counts (linkage fab counts, prop), structures (camp)}.
## A CREW:  {iid, home: Vector2, roster, free_chores, free_projects}.
##
## Labour is priced in PERSON-HOURS from the packed mass (NpcChoreBoard
## credits every worker's hours into one chore): a 34 kg shiftpod is ~1.2 h
## for one person, a 350 kg pallet rack ~9 h for its crew of four. Pack-up is
## PACKUP_SCALE of a deploy. These are estimates, not measurements — nobody
## has timed a festival build; the knobs are here to be tuned.

const HOURS_BASE := 0.4
const KG_PER_HOUR := 40.0
const HOURS_MIN := 0.4
const HOURS_MAX := 24.0
const UNKNOWN_MASS_HOURS := 1.0
const PACKUP_SCALE := 0.6
## A painted camp: person-hours per household structure (tent, awning, car).
const CAMP_HOURS_PER_STRUCTURE := 0.12
const CAMP_HOURS_MIN := 0.3
## People the director pins as ALL HANDS for one event (the full-tier
## budget it is willing to spend); the nearest camps to the work first.
const ALL_HANDS_MAX_PEOPLE := 320
## The whole day: a deploy set for 20:00 starts at 20:00. Sleep still wins.
const WORK_WINDOW := {"start_h": 0.0, "end_h": 24.0}


static func labour_hours(mass_kg: float) -> float:
	if mass_kg <= 0.0:
		return UNKNOWN_MASS_HOURS
	return clampf(HOURS_BASE + mass_kg / KG_PER_HOUR, HOURS_MIN, HOURS_MAX)


static func camp_hours(structures: int) -> float:
	return maxf(float(structures) * CAMP_HOURS_PER_STRUCTURE, CAMP_HOURS_MIN)


# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

## Chore-spec rows for one item and action (deploy / packup). Task ids reuse
## the Site Projects vocabulary where a renderer keys on them (a linkage's
## erect / bolts / panels and strip_panels / unbolt / fold_pack drive
## SiteProject.build_progress / breakdown_progress; everything else is
## generic).
static func rows_for(item: Dictionary, action: String, roster: int = 4) -> Array:
	var kind := str(item.get("kind", "prop"))
	if kind == "camp":
		return _camp_rows(item, action, roster)
	var model_id := str(item.get("model_id", ""))
	var pid := str(item.get("id", ""))
	if model_id == LinkageStructureBuilder.MODEL_ID:
		var counts: Dictionary = item.get("counts", {})
		if action == SiteDeploySchedule.ACTION_DEPLOY:
			return SiteProject.rebuild_spec_rows(counts, pid)
		return SiteProject.breakdown_spec_rows(counts, pid, item.get("loadout", {}) as Dictionary)
	var h := labour_hours(float(item.get("mass_kg", -1.0)))
	var label := str(item.get("label", "structure"))
	var target := {"kind": "prop", "id": pid}
	var r := maxi(roster, 1)
	if action == SiteDeploySchedule.ACTION_DEPLOY:
		if model_id == PalletRackBuilder.MODEL_ID:
			return [{
				"task_id": "unpack", "label": "Lay out the bundles — %s" % label,
				"chore_hours": maxf(h * 0.2, 0.1), "priority": 1,
				"min_workers": 1, "max_workers": mini(3, r), "exposure": "outdoor",
				"target": target,
			}, {
				"task_id": "frames", "label": "Raise the frames — %s" % label,
				"chore_hours": maxf(h * 0.45, 0.15), "priority": 2,
				"min_workers": mini(4, r), "max_workers": mini(8, maxi(r, 1)),
				"exposure": "outdoor", "depends_on": ["unpack"], "target": target,
			}, {
				"task_id": "decks", "label": "Decks, walls and stairs — %s" % label,
				"chore_hours": maxf(h * 0.25, 0.1), "priority": 3,
				"min_workers": 1, "max_workers": mini(6, r), "exposure": "outdoor",
				"depends_on": ["frames"], "target": target,
			}, {
				"task_id": "finish", "label": "Finish — %s" % label,
				"chore_hours": maxf(h * 0.1, 0.05), "priority": 4,
				"min_workers": 1, "max_workers": mini(2, r), "exposure": "outdoor",
				"depends_on": ["decks"], "target": target,
				"effect": {"op": "unpack_prop", "prop_id": pid},
			}]
		return [{
			"task_id": "lay_out", "label": "Unpack and lay out — %s" % label,
			"chore_hours": maxf(h * 0.25, 0.1), "priority": 1,
			"min_workers": 1, "max_workers": mini(2, r), "exposure": "outdoor",
			"target": target,
			"effect": {"op": "set_build_phase", "prop_id": pid, "phase": "lay_out", "ghost": 0.3},
		}, {
			"task_id": "assemble", "label": "Assemble — %s" % label,
			"chore_hours": maxf(h * 0.6, 0.1), "priority": 2,
			"min_workers": 2 if (h > 3.0 and r >= 2) else 1,
			"max_workers": clampi(r, 2, 6) if r >= 2 else 1, "exposure": "outdoor",
			"depends_on": ["lay_out"], "target": target,
			"stage_effects": [{"at": 0.5, "effect": {"op": "set_build_phase",
				"prop_id": pid, "phase": "assemble_half", "ghost": 0.55}}],
			"effect": {"op": "set_build_phase", "prop_id": pid, "phase": "assemble", "ghost": 0.85},
		}, {
			"task_id": "finish", "label": "Raise and finish — %s" % label,
			"chore_hours": maxf(h * 0.15, 0.05), "priority": 3,
			"min_workers": 1, "max_workers": mini(4, r), "exposure": "outdoor",
			"depends_on": ["assemble"], "target": target,
			"effect": {"op": "unpack_prop", "prop_id": pid},
		}]
	# Pack-up (rack and generic alike): take it down, then pack it, then —
	# with a container in reach (`item.loadout` = its door) — carry the
	# crate to the door.
	var p := h * PACKUP_SCALE
	var rows_p: Array = [{
		"task_id": "strip", "label": "Take down — %s" % label,
		"chore_hours": maxf(p * 0.5, 0.1), "priority": 1,
		"min_workers": 1, "max_workers": mini(4, r), "exposure": "outdoor",
		"target": target,
		"effect": {"op": "set_build_phase", "prop_id": pid, "phase": "strip", "ghost": 0.5},
	}, {
		"task_id": "pack", "label": "Pack — %s" % label,
		"chore_hours": maxf(p * 0.5, 0.1), "priority": 2,
		"min_workers": 1, "max_workers": mini(3, r), "exposure": "outdoor",
		"depends_on": ["strip"], "target": target,
		"effect": {"op": "pack_prop", "prop_id": pid},
	}]
	var lo: Dictionary = item.get("loadout", {})
	if lo.has("x") and lo.has("z"):
		rows_p.append({
			"task_id": "load_out", "label": "Carry to the container — %s" % label,
			"chore_hours": 0.15, "priority": 3,
			"min_workers": 1, "max_workers": 1, "exposure": "outdoor",
			"depends_on": ["pack"], "target": target,
			"carry_to": {"x": float(lo["x"]), "z": float(lo["z"])},
			"effect": {"op": "move_prop", "prop_id": pid, "x": float(lo["x"]), "z": float(lo["z"])},
		})
	return rows_p


static func _camp_rows(item: Dictionary, action: String, roster: int) -> Array:
	var cid := str(item.get("id", ""))
	var name := str(item.get("label", "camp"))
	var pos: Vector2 = item.get("pos", Vector2.ZERO)
	var h := camp_hours(int(item.get("structures", 0)))
	var deploy := action == SiteDeploySchedule.ACTION_DEPLOY
	if not deploy:
		h *= PACKUP_SCALE
	var r := maxi(roster, 1)
	return [{
		"task_id": "pitch" if deploy else "strike",
		"label": ("Pitch camp — %s" if deploy else "Strike camp — %s") % name,
		"chore_hours": h, "priority": 1,
		"min_workers": mini(2, r), "max_workers": mini(8, r), "exposure": "outdoor",
		"target": {"kind": "pos", "x": pos.x, "z": pos.y},
		"effect": {"op": "set_camp_built", "camp_id": cid, "built": deploy},
	}]


# ---------------------------------------------------------------------------
# Crews
# ---------------------------------------------------------------------------

## Which crews to pin as ALL HANDS for a set of items: nearest to the
## items' centroid first, until their rosters reach `max_people` (always at
## least one crew). Returns the iids in that order.
static func pick_crews(crews: Array, items: Array, max_people: int = ALL_HANDS_MAX_PEOPLE) -> Array:
	if crews.is_empty():
		return []
	var centre := Vector2.ZERO
	for it in items:
		centre += (it as Dictionary).get("pos", Vector2.ZERO)
	if not items.is_empty():
		centre /= float(items.size())
	var sorted: Array = crews.duplicate()
	sorted.sort_custom(func(a, b) -> bool:
		var da: float = ((a as Dictionary).get("home", Vector2.ZERO) as Vector2).distance_to(centre)
		var db: float = ((b as Dictionary).get("home", Vector2.ZERO) as Vector2).distance_to(centre)
		if absf(da - db) > 1e-6:
			return da < db
		return str((a as Dictionary).get("iid", "")) < str((b as Dictionary).get("iid", "")))
	var out: Array = []
	var people := 0
	for c in sorted:
		var cd := c as Dictionary
		out.append(str(cd.get("iid", "")))
		people += int(cd.get("roster", 0))
		if people >= max_people:
			break
	return out


## Hand every item to the nearest crew that has room on its board (rows +
## one project slot). Greedy, deterministic (items by id, crews by distance).
## Returns {assigned: {iid: [item, …]}, unassigned: [item, …]}.
static func assign(items: Array, crews: Array, action: String) -> Dictionary:
	var caps: Dictionary = {}   # iid -> {chores, projects}
	for c in crews:
		var cd := c as Dictionary
		caps[str(cd.get("iid", ""))] = {"chores": int(cd.get("free_chores", 0)),
			"projects": int(cd.get("free_projects", 0))}
	var sorted_items: Array = items.duplicate()
	sorted_items.sort_custom(func(a, b) -> bool:
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
	var assigned: Dictionary = {}
	var unassigned: Array = []
	for it in sorted_items:
		var item := it as Dictionary
		var pos: Vector2 = item.get("pos", Vector2.ZERO)
		var order: Array = crews.duplicate()
		order.sort_custom(func(a, b) -> bool:
			var da: float = ((a as Dictionary).get("home", Vector2.ZERO) as Vector2).distance_to(pos)
			var db: float = ((b as Dictionary).get("home", Vector2.ZERO) as Vector2).distance_to(pos)
			if absf(da - db) > 1e-6:
				return da < db
			return str((a as Dictionary).get("iid", "")) < str((b as Dictionary).get("iid", "")))
		var taken := false
		for c in order:
			var iid := str((c as Dictionary).get("iid", ""))
			var need := rows_for(item, action, int((c as Dictionary).get("roster", 4))).size()
			var cap: Dictionary = caps.get(iid, {})
			if cap.is_empty() or int(cap["chores"]) < need or int(cap["projects"]) < 1:
				continue
			cap["chores"] = int(cap["chores"]) - need
			cap["projects"] = int(cap["projects"]) - 1
			if not assigned.has(iid):
				assigned[iid] = []
			(assigned[iid] as Array).append(item)
			taken = true
			break
		if not taken:
			unassigned.append(item)
	return {"assigned": assigned, "unassigned": unassigned}


## The label a project gets: "Deploy: Shiftpod" / "Pack up: Camp Awesome".
static func project_label(item: Dictionary, action: String) -> String:
	var verb := "Deploy" if action == SiteDeploySchedule.ACTION_DEPLOY else "Pack up"
	return "%s: %s" % [verb, str(item.get("label", "structure"))]

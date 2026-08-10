class_name SiteProject
extends RefCounted

## One end-to-end WORK PROJECT on a site (the unified camp-lifecycle
## mechanic): a labelled group of chore-board tasks wired by dependencies,
## whose completions gate world effects — unload a delivery, fabricate and
## raise a linkage structure, break one down and pack it out.
##
## Pure static helpers over plain Dictionary records (the chore-board idiom):
## no scene access, no HTTP, fully selftest-able offline. Execution stays on
## NpcChoreBoard — a project never duplicates scheduling; it binds task_id →
## chore_id and DERIVES status from board state. World effects ride the
## CHORES (dispatched once by NpcPopulationBridge's post-tick sweep); the
## project is grouping, rollup, and the driver for the progressive build
## visualization.
##
## Record:
## { id, label, kind: "delivery_unload"|"linkage_build"|"linkage_breakdown",
##   prop_id,                    # the structure / container involved ("" ok)
##   site: {x, z},
##   tasks: [ {task_id, chore_id, label, status: "pending"|"done"|"skipped"} ],
##   plan: {crew, makespan_s},   # the scheduler's promise, for plan-vs-actual
##   state: "active"|"done"|"cancelled",
##   created_h }

const KIND_DELIVERY := "delivery_unload"
const KIND_LINKAGE_BUILD := "linkage_build"
const KIND_LINKAGE_BREAKDOWN := "linkage_breakdown"

static var _next_ord := 1


static func make(kind: String, label: String, prop_id: String, site: Vector2,
		created_h: float, plan_meta: Dictionary = {}) -> Dictionary:
	var rec := {
		"id": "proj_%d_%d" % [int(created_h * 3600.0), _next_ord],
		"label": label,
		"kind": kind,
		"prop_id": prop_id,
		"site": {"x": site.x, "z": site.y},
		"tasks": [],
		"plan": plan_meta.duplicate(true),
		"state": "active",
		"created_h": created_h,
	}
	_next_ord += 1
	return rec


## Bind the chores add_plan created back onto the plan specs, in order.
## `spec_rows` and `chore_ids` are add_plan's input/output pair — same length
## unless the board refused (caller handles the empty case before this).
static func bind_tasks(project: Dictionary, spec_rows: Array, chore_ids: Array) -> void:
	var tasks: Array = []
	for i in mini(spec_rows.size(), chore_ids.size()):
		var spec := spec_rows[i] as Dictionary
		tasks.append({
			"task_id": str(spec.get("task_id", "t%d" % i)),
			"chore_id": str(chore_ids[i]),
			"label": str(spec.get("label", "")),
			"status": "pending",
		})
	project["tasks"] = tasks


## Derive task statuses from the board. A missing chore record means the
## player deleted it — "skip that step", per the board's own dangling-dep
## rule; the effect never fires (it lived on the deleted chore). Returns
## true when anything changed (drives change-gated persistence + redraws).
static func sync_with_board(project: Dictionary, board) -> bool:
	if str(project.get("state", "")) != "active" or board == null:
		return false
	var changed := false
	var all_settled := true
	for t in project.get("tasks", []):
		var task: Dictionary = t
		var status := str(task.get("status", "pending"))
		if status == "pending":
			var chore: Dictionary = board.find(str(task.get("chore_id", "")))
			if chore.is_empty():
				task["status"] = "skipped"
				changed = true
			elif int(chore.get("done_day", -1)) >= 0:
				task["status"] = "done"
				changed = true
			else:
				all_settled = false
	if all_settled and not (project.get("tasks", []) as Array).is_empty():
		project["state"] = "done"
		changed = true
	return changed


## Rollup for panels/toasts: {done, skipped, total, progress 0..1,
## active_label, active_chore_id}. Progress is labour-weighted over the
## board's live hours, so a long phase doesn't read as one cheap tick.
static func rollup(project: Dictionary, board) -> Dictionary:
	var done := 0
	var skipped := 0
	var total_h := 0.0
	var done_h := 0.0
	var active_label := ""
	var active_chore := ""
	var tasks: Array = project.get("tasks", [])
	for t in tasks:
		var task: Dictionary = t
		var status := str(task.get("status", "pending"))
		var chore: Dictionary = board.find(str(task.get("chore_id", ""))) \
			if board != null else {}
		var hours := maxf(float(chore.get("chore_hours", 0.0)), 0.0)
		total_h += hours
		match status:
			"done":
				done += 1
				done_h += hours
			"skipped":
				skipped += 1
			_:
				done_h += clampf(float(chore.get("progress_h", 0.0)), 0.0, hours)
				if active_label.is_empty() and not chore.is_empty() \
						and not (chore.get("workers", []) as Array).is_empty():
					active_label = str(task.get("label", ""))
					active_chore = str(task.get("chore_id", ""))
	return {
		"done": done, "skipped": skipped, "total": tasks.size(),
		"progress": clampf(done_h / total_h, 0.0, 1.0) if total_h > 0.0 else 0.0,
		"active_label": active_label, "active_chore_id": active_chore,
	}


# --- linkage build visualization ---------------------------------------------

## Live per-element fractions for LinkageStructureBuilder.set_build_progress,
## derived from the board's real progress on this project's tasks. Keys:
## beams/brackets/bolts/supports/panels 0..1 + ghost (alpha for firming) +
## erected (bool — past the raise, the DEPLOYED structure is showing and only
## the panel fraction still animates).
static func build_progress(project: Dictionary, board) -> Dictionary:
	var frac: Dictionary = {}   # task_id -> completed fraction
	var pre_total := 0.0
	var pre_done := 0.0
	var erected := false
	for t in project.get("tasks", []):
		var task: Dictionary = t
		var tid := str(task.get("task_id", ""))
		var status := str(task.get("status", "pending"))
		var chore: Dictionary = board.find(str(task.get("chore_id", ""))) \
			if board != null else {}
		var hours := maxf(float(chore.get("chore_hours", 0.0)), 0.001)
		var f := 1.0 if status != "pending" \
			else clampf(float(chore.get("progress_h", 0.0)) / hours, 0.0, 1.0)
		frac[tid] = f
		if tid == "erect":
			erected = status == "done"
		elif tid != "panels":
			pre_total += hours
			pre_done += f * hours
	# Assemble may be split into many assemble_* tasks; beams reveal by their
	# combined fraction.
	var asm_total := 0.0
	var asm_done := 0.0
	for tid in frac:
		if str(tid) == "assemble" or str(tid).begins_with("assemble_"):
			asm_total += 1.0
			asm_done += float(frac[tid])
	var beams := (asm_done / asm_total) if asm_total > 0.0 else 0.0
	# PREFAB (a rebuild): no "cut" task means the parts already exist, so the
	# whole frame ghosts in from the first tick — the faint outline of what is
	# being raised — instead of growing piece by piece.
	var prefab := not frac.has("cut")
	if prefab:
		beams = 1.0
	elif float(frac.get("cut", 0.0)) < 1.0:
		# Nothing shows until the drilling is real work underway — a lumber
		# pile has no silhouette worth drawing at plan scale.
		beams = 0.0
	return {
		"beams": beams,
		"brackets": 1.0 if prefab else float(frac.get("brackets", 0.0)),
		"bolts": float(frac.get("bolts", 0.0)),
		"supports": 1.0 if (erected or prefab) else 0.0,
		"panels": float(frac.get("panels", 0.0)),
		"ghost": clampf(0.12 + 0.88 * (pre_done / pre_total if pre_total > 0.0 else 0.0),
			0.12, 1.0),
		"erected": erected,
	}


## Stage-effect indices due to fire NOW: progress has crossed the stage's
## threshold and it hasn't fired yet. A completed chore reads as fraction 1.0
## (completion keeps progress_h at chore_hours), so stages whose thresholds
## were skipped between ticks — or that the completion effect would otherwise
## strand — all come due at the end. Pure decision; the bridge sweep executes
## and stamps `fired` per stage.
static func due_stage_effects(chore: Dictionary) -> Array:
	var stages: Variant = chore.get("stage_effects", null)
	if not (stages is Array) or (stages as Array).is_empty():
		return []
	var hours := maxf(float(chore.get("chore_hours", 0.0)), 0.001)
	var frac := clampf(float(chore.get("progress_h", 0.0)) / hours, 0.0, 1.0)
	if int(chore.get("done_day", -1)) >= 0:
		frac = 1.0
	var out: Array = []
	for i in (stages as Array).size():
		var st := (stages as Array)[i] as Dictionary
		if bool(st.get("fired", false)):
			continue
		if frac + 0.0001 >= clampf(float(st.get("at", 1.0)), 0.0, 1.0):
			out.append(i)
	return out


## Delivery-unload plan rows (pure — selftestable without a loader).
## `crates` = [{pid, stage: Vector2, label}] in delivery-slot order; `from` =
## the container. NpcHaulModel picks the strategy from real crew density:
## - round trips → one carry chore per crate (target = the crate, carry_to =
##   its staging slot, move on completion) — a stream of individual carriers;
## - bucket brigade (enough crates AND hands) → ONE crew chore whose workers
##   take station posts along the route while the crates flow through their
##   hands as stage effects, one per (i+0.5)/N of the labour — the relay line
##   IS the visual, and the world moves incrementally with it.
## Both end with a zero-effect "Delivery unloaded" gate depending on all.
##
## `force_strategy` overrides the density-derived choice ("brigade" /
## "round_trip"); "" reproduces the unforced call byte-for-byte, which the
## selftest pins with a frozen literal. It exists so the experiment lab can ask
## "what if they formed a line instead?" — a question the strategy cannot
## otherwise be asked, because it is emergent rather than a setting.
const BRIGADE_MIN_CRATES := 4
const BRIGADE_MIN_CREW := 4

static func unload_spec_rows(crates: Array, from: Vector2, roster: int,
		force_strategy: String = "") -> Dictionary:
	if crates.is_empty():
		return {"rows": [], "strategy": "none", "plan": {}}
	var mean_route := 0.0
	var centre := Vector2.ZERO
	for c in crates:
		var stage: Vector2 = (c as Dictionary).get("stage", Vector2.ZERO)
		mean_route += from.distance_to(stage)
		centre += stage
	mean_route /= float(crates.size())
	centre /= float(crates.size())
	var plan: Dictionary = NpcHaulModel.best_plan(maxi(roster, 1),
		mean_route + 6.0, crates.size())
	var rows: Array = []
	var gate_deps: Array = []
	var brigade := str(plan.get("strategy", "")) == "brigade" \
		and crates.size() >= BRIGADE_MIN_CRATES and roster >= BRIGADE_MIN_CREW
	if force_strategy == "brigade":
		brigade = true
	elif force_strategy == "round_trip":
		brigade = false
	if brigade:
		var stages: Array = []
		for i in crates.size():
			var cd := crates[i] as Dictionary
			var stg: Vector2 = cd.get("stage", Vector2.ZERO)
			stages.append({"at": (float(i) + 0.5) / float(crates.size()),
				"effect": {"op": "move_prop", "prop_id": str(cd.get("pid", "")),
					"x": stg.x, "z": stg.y,
					# Set down on the ground and made touchable again — a crate
					# rides the container stack at height with collision off.
					"y_offset": 0.0, "collision_enabled": true}})
		rows.append({
			"task_id": "brigade",
			"label": "Bucket-brigade the delivery",
			"chore_hours": maxf(float(plan.get("labor_hours", 0.1)), 0.05),
			"priority": 1,
			"min_workers": mini(BRIGADE_MIN_CREW, roster),
			"max_workers": clampi(roster, BRIGADE_MIN_CREW, 10),
			"exposure": "outdoor",
			"target": {"kind": "pos", "x": centre.x, "z": centre.y},
			"haul": {"from_x": from.x, "from_z": from.y,
				"to_x": centre.x, "to_z": centre.y, "strategy": "brigade"},
			"stage_effects": stages,
		})
		gate_deps.append("brigade")
	else:
		var per_crate_h := maxf(float(plan.get("labor_hours", 0.1))
			/ float(crates.size()), 0.02)
		for i in crates.size():
			var cd2 := crates[i] as Dictionary
			var stg2: Vector2 = cd2.get("stage", Vector2.ZERO)
			var tid := "crate_%d" % i
			gate_deps.append(tid)
			rows.append({
				"task_id": tid,
				"label": "Haul crate — %s" % str(cd2.get("label", "crate")),
				"chore_hours": per_crate_h,
				# ASCENDING per crate, not a flat 1: equal priority + equal
				# hours ties in available_for's sort, and Godot's sort_custom
				# is not stable, so the unload order would be arbitrary — which
				# would take the top crate out from under the one above it.
				"priority": 1 + i,
				"min_workers": 1, "max_workers": 1,
				"exposure": "outdoor",
				"target": {"kind": "prop", "id": str(cd2.get("pid", ""))},
				"carry_to": {"x": stg2.x, "z": stg2.y},
				"effect": {"op": "move_prop", "prop_id": str(cd2.get("pid", "")),
					"x": stg2.x, "z": stg2.y,
					"y_offset": 0.0, "collision_enabled": true},
			})
	rows.append({
		"task_id": "unloaded",
		"label": "Delivery unloaded",
		"chore_hours": 0.05,
		# Above every crate row, so the gate is never offered mid-unload.
		"priority": 2 + (crates.size() if not brigade else 0),
		"min_workers": 1, "max_workers": 1,
		"exposure": "outdoor",
		"depends_on": gate_deps,
	})
	return {"rows": rows, "strategy": "brigade" if brigade else "round_trip",
		"plan": plan, "centre": centre}


## Breakdown plan (the reverse lifecycle): strip panels → unbolt → fold &
## pack (the stow sweep IS the fold-down) → optionally haul the packed crate
## to a container door. Pure — spec rows for add_plan/create_site_project;
## labour priced from the same NpcCrewPlan constants the build uses, scaled
## down (taking apart is faster than making).
## `counts` = the builder's fab counts; `loadout` = {} or {x, z} for the
## load-out carry destination.
static func breakdown_spec_rows(counts: Dictionary, prop_id: String,
		loadout: Dictionary = {}) -> Array:
	var panels := maxi(int(counts.get("panel_count", 0)), 0)
	var bolts := maxi(int(counts.get("bolt_count", 0)),
		maxi(int(counts.get("module_count", 1)), 1) * 6)
	var rows: Array = []
	var fold_deps: Array = []
	if panels > 0:
		rows.append({
			"task_id": "strip_panels", "label": "Strip panels",
			"chore_hours": maxf(panels * NpcCrewPlan.T_PANEL_MOUNT_S * 0.6 / 3600.0, 0.05),
			"priority": 1, "min_workers": 2, "max_workers": maxi(mini(panels, 8), 2),
			"exposure": "outdoor",
		})
		fold_deps.append("strip_panels")
	rows.append({
		"task_id": "unbolt", "label": "Unbolt the ring",
		"chore_hours": maxf(bolts * NpcCrewPlan.T_BOLT_SET_S * 0.5 / 3600.0, 0.05),
		"priority": 2, "min_workers": 1,
		"max_workers": maxi(int(counts.get("module_count", 1)), 1),
		"exposure": "outdoor", "depends_on": fold_deps.duplicate(),
	})
	rows.append({
		"task_id": "fold_pack", "label": "Fold & pack",
		"chore_hours": 0.35,
		"priority": 3, "min_workers": 2, "max_workers": 6,
		"exposure": "outdoor", "depends_on": ["unbolt"],
		"effect": {"op": "pack_prop", "prop_id": prop_id},
	})
	if loadout.has("x") and loadout.has("z"):
		rows.append({
			"task_id": "load_out", "label": "Haul crate to the container",
			"chore_hours": 0.15,
			"priority": 4, "min_workers": 1, "max_workers": 1,
			"exposure": "outdoor", "depends_on": ["fold_pack"],
			"target": {"kind": "prop", "id": prop_id},
			"carry_to": {"x": float(loadout["x"]), "z": float(loadout["z"])},
			"effect": {"op": "move_prop", "prop_id": prop_id,
				"x": float(loadout["x"]), "z": float(loadout["z"])},
		})
	return rows


## Rebuild plan: raise a structure that was already fabricated ONCE and then
## broken down — the crate holds finished parts, so there is nothing to cut or
## drill. The mirror of breakdown_spec_rows, at the same discounted labour:
## raise the frame (the unpack effect IS the raise) → re-bolt the ring →
## re-mount the panels (which re-seeds the graph array). This is what makes a
## teardown reversible by the CREW rather than only by the player's Interact —
## "they took it down, they can put it back up".
static func rebuild_spec_rows(counts: Dictionary, prop_id: String) -> Array:
	var panels := maxi(int(counts.get("panel_count", 0)), 0)
	var bolts := maxi(int(counts.get("bolt_count", 0)),
		maxi(int(counts.get("module_count", 1)), 1) * 6)
	# Task ids reuse the build vocabulary ("erect"/"bolts"/"panels") on
	# purpose: build_progress() and the ghost renderer key on those names, and
	# the ABSENCE of a "cut" task is what tells them this is a PREFAB raise
	# (whole frame ghosted from the start) rather than a fabrication.
	var rows: Array = [{
		"task_id": "erect", "label": "Raise the frame",
		"chore_hours": 0.35,
		"priority": 1, "min_workers": NpcCrewPlan.ERECT_MIN_WORKERS,
		"max_workers": NpcCrewPlan.ERECT_MIN_WORKERS + 2,
		"exposure": "outdoor",
		"effect": {"op": "unpack_prop", "prop_id": prop_id},
	}, {
		"task_id": "bolts", "label": "Bolt the ring",
		"chore_hours": maxf(bolts * NpcCrewPlan.T_BOLT_SET_S * 0.5 / 3600.0, 0.05),
		"priority": 2, "min_workers": 1,
		"max_workers": maxi(int(counts.get("module_count", 1)), 1),
		"exposure": "outdoor", "depends_on": ["erect"],
	}]
	if panels > 0:
		rows.append({
			"task_id": "panels", "label": "Mount the panels",
			"chore_hours": maxf(panels * NpcCrewPlan.T_PANEL_MOUNT_S * 0.6 / 3600.0, 0.05),
			"priority": 3, "min_workers": 2, "max_workers": maxi(mini(panels, 8), 2),
			"exposure": "outdoor", "depends_on": ["bolts"],
			"effect": {"op": "seed_graph", "prop_id": prop_id},
		})
	return rows


## Live per-element fractions for the REVERSE lifecycle — the mirror of
## build_progress(). Keys: beams/brackets/bolts/supports/panels 0..1 + ghost
## + folded (bool — the crate has replaced the frame, stop pushing).
##
## ALWAYS emits all five element keys. `_apply_build_progress` defaults a
## MISSING key to 1.0, so a partial dict leaves everything unmentioned fully
## solid — which is exactly the bug this replaces (the old branch pushed only
## `panels`, so a teardown showed the panels leave and then nothing at all
## happen until the frame teleported into a crate).
##
## `beams` deliberately stays 1.0 THROUGHOUT. `fold_pack`'s completion effect
## is `pack_prop`, which awaits the stow sweep — the fold IS the beam visual,
## and dissolving them first would animate a fold on nothing.
static func breakdown_progress(project: Dictionary, board) -> Dictionary:
	var frac: Dictionary = {}
	var seen: Dictionary = {}
	var folded := false
	for t in project.get("tasks", []):
		var task: Dictionary = t
		var tid := str(task.get("task_id", ""))
		var status := str(task.get("status", "pending"))
		var chore: Dictionary = board.find(str(task.get("chore_id", ""))) \
			if board != null else {}
		var hours := maxf(float(chore.get("chore_hours", 0.0)), 0.001)
		frac[tid] = 1.0 if status != "pending" \
			else clampf(float(chore.get("progress_h", 0.0)) / hours, 0.0, 1.0)
		seen[tid] = true
		if tid == "fold_pack" and status == "done":
			folded = true
	# A missing task means that step isn't in this plan (strip_panels is
	# omitted when the design has no panels) — nothing to remove, so the class
	# stays whole rather than vanishing.
	var strip := float(frac.get("strip_panels", 0.0)) if seen.has("strip_panels") else 0.0
	var unbolt := float(frac.get("unbolt", 0.0)) if seen.has("unbolt") else 0.0
	var fold := float(frac.get("fold_pack", 0.0)) if seen.has("fold_pack") else 0.0
	return {
		"panels": 1.0 - strip,
		# Bolts and brackets leave together — a bracket with its bolts out is
		# not attached to anything.
		"bolts": 1.0 - unbolt,
		"brackets": 1.0 - unbolt,
		# Supports stay WITH the frame through the fold, like the beams — they
		# physically fold with it, and revealing them away during fold_pack
		# (the old 1-fold ramp) plus the deep ghost left the structure all but
		# invisible for the whole fold: the "it disappears, then a crate
		# appears" read this function exists to prevent.
		"supports": 1.0,
		"beams": 1.0,
		# Shallow ghost, floored high: the fold sweep that follows fold_pack
		# plays on THIS frame, and it must stay clearly visible right up to
		# the crate swap. (Was 1−0.65·fold floored at 0.35 — mostly gone
		# before the fold even started.)
		"ghost": clampf(1.0 - 0.25 * fold, 0.75, 1.0),
		"folded": folded,
	}


## Coarse fractions from a persisted build_state.phase (the LAST COMPLETED
## task id stamped by the set_build_phase effect) — what PlacedPropRuntime
## renders on a fresh load before the first bridge tick refines it live.
static func phase_fractions(completed_phase: String) -> Dictionary:
	var order := ["cut", "drill", "assemble", "brackets", "bolts", "fold_test"]
	var phase := completed_phase
	if phase.begins_with("assemble"):
		phase = "assemble"
	var idx := order.find(phase)   # -1 = nothing done yet
	return {
		"beams": 1.0 if idx >= 2 else 0.0,
		"brackets": 1.0 if idx >= 3 else 0.0,
		"bolts": 1.0 if idx >= 4 else 0.0,
		"supports": 0.0,
		"panels": 0.0,
		"ghost": clampf(0.12 + 0.15 * float(idx + 1), 0.12, 1.0),
	}

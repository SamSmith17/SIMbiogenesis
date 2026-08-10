class_name SiteProjectEffects
extends RefCounted

## World-effect executor for completed work (Site Projects — the mechanic that
## makes NPC labour CHANGE THE WORLD: chores gate unpacks, moves, deploys).
##
## Structural rule: this is the ONLY population-side file that touches scene
## nodes, and it is called exclusively from NpcPopulationBridge's POST-TICK
## sweep — never from inside the pure engine, whose determinism must not
## depend on scene state. The sweep observes board state (a completed
## repeat:"once" chore is `done_day >= 0`), executes the chore's `effect`
## payload once, and stamps `effect_done: true` beside it — the fire-once
## flag persists inside pop_state for free because the board round-trips
## unknown chore keys.
##
## Effect vocabulary v1 (each op is a Dictionary; unknown ops are a warning,
## not an error — an old save with a newer effect must not crash the tick):
##   {op:"move_prop",   prop_id, x, z}   crate set-down at its staging slot
##   {op:"unpack_prop", prop_id}         deploy — plays the linkage raise sweep
##   {op:"pack_prop",   prop_id}         breakdown — plays the stow sweep
##   {op:"remove_prop", prop_id}         consume an emptied crate
##   {op:"spawn_prop",  model_id, x, z, extra:{}}
##   {op:"set_build_phase", prop_id, phase, ghost}  progressive build state
##   {op:"finalize_assembly", prop_id, graph_preset} crew assembly complete:
##       clear the ghost; when graph_preset names a ComponentPresets entry,
##       bind the finished structure into the 2D graph (a crafted VAWT
##       becomes a live wind generator)
##
## set_prop_packed is a COROUTINE (it awaits the fold sweep); it is always
## call_deferred'd and never awaited here — the sweep runs inside the ambient
## flow tick and must not yield.


static func execute(main: Node, op: Dictionary) -> bool:
	if main == null or op.is_empty():
		return false
	var kind := str(op.get("op", ""))
	var prop_id := str(op.get("prop_id", ""))
	match kind:
		"move_prop":
			# y_offset defaults to 0: a crate set down after a haul lands ON
			# THE GROUND, whatever stack height it rode at inside the
			# container. Passing NAN here would leave it floating.
			var moved := PlacedPropService.move_prop_at(main, prop_id,
				float(op.get("x", 0.0)), float(op.get("z", 0.0)), NAN,
				float(op.get("y_offset", 0.0)))
			if moved and op.has("collision_enabled"):
				PlacedPropService.update_prop_record(main, prop_id,
					{"collision_enabled": bool(op["collision_enabled"])}, true)
			return moved
		"unpack_prop", "pack_prop":
			var loader := _loader(main)
			if loader == null or not loader.has_method("set_prop_packed"):
				return false
			if kind == "unpack_prop":
				# Clear any construction state FIRST, so the rebuild inside
				# set_prop_packed renders the real deployed structure (and the
				# deploy sweep IS the raise). null, not erase — update_prop is
				# a shallow merge; consumers guard with `is Dictionary`.
				PlacedPropService.update_prop_record(main, prop_id,
					{"build_state": null}, false)
			loader.call_deferred("set_prop_packed", prop_id, kind == "pack_prop")
			return true
		"remove_prop":
			var loader2 := _loader(main)
			if loader2 == null or not loader2.has_method("delete_prop_by_id"):
				return false
			loader2.call_deferred("delete_prop_by_id", prop_id)
			return true
		"recipe_step_done":
			# THE LABOUR MERGE's payoff: a person finished the work, so the
			# machine resumes. Deliberately routes through the SAME
			# `confirm_chore` the player's button uses — which also debits the
			# ledger, so the crew is the gate and the ledger stays the meter,
			# with no second accounting path to drift.
			return _finish_recipe_step(main, str(op.get("item_id", "")),
				str(op.get("step_id", "")))
		"seed_graph":
			# Panels mounted: the structure's solar array joins the graph via
			# the same idempotent per-prop path the Lab placement uses.
			PlacedPropService.seed_linkage_graph(main, prop_id)
			return true
		"spawn_prop":
			var r := PlacedPropService.place_model_at_xz(main,
				str(op.get("model_id", "")), float(op.get("x", 0.0)),
				float(op.get("z", 0.0)), op.get("extra", {}) as Dictionary)
			return bool(r.get("ok", false))
		"set_build_phase":
			# Build state is a record key consumed by PlacedPropRuntime (ghost/
			# progress render) — written on PHASE TRANSITIONS only, so the
			# rebuild_prop cost is ~once per project phase, not per tick.
			var patch := {"build_state": {"phase": str(op.get("phase", "")),
				"ghost": float(op.get("ghost", 0.2))}}
			if str(op.get("phase", "")).is_empty():
				patch = {"build_state": null}
			return PlacedPropService.update_prop_record(main, prop_id, patch, true)
		"finalize_assembly":
			# Crew assembly complete: the ghost firms into the real structure
			# (build_state cleared -> normal rebuild, trackers/runtimes
			# attach), and a graph-linked recipe binds it into the 2D graph.
			PlacedPropService.update_prop_record(main, prop_id,
				{"build_state": null}, true)
			var preset := str(op.get("graph_preset", ""))
			if preset.is_empty():
				return true
			var sgv2 := main.get_node_or_null("UILayer/SystemGraphView")
			if sgv2 == null or not sgv2.has_method("bind_assembled_structure"):
				return false  # view not up yet — retry next sweep
			return bool(sgv2.call("bind_assembled_structure", prop_id, preset))
		_:
			# Consumed, not retried: an unknown op (older build reading a newer
			# save) must not warn on every tick forever. Returning false would
			# leave it un-stamped and re-dispatched each sweep.
			push_warning("SiteProjectEffects: unknown op '%s' (skipped)" % kind)
			return true
	return false


## Resume a labour-gated recipe step whose chore the crew has finished.
static func _finish_recipe_step(main: Node, item_id: String, step_id: String) -> bool:
	if item_id.is_empty():
		return true   # nothing to resume; consumed, not retried
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv == null or not sgv.has_method("resume_recipe_step"):
		return false  # view not up yet — retry next sweep
	return bool(sgv.call("resume_recipe_step", item_id, step_id))


static func _loader(main: Node) -> Node:
	if main == null:
		return null
	var n := main.get_node_or_null("TerrainLoader")
	if n != null:
		return n
	return main.find_child("TerrainLoader", true, false)

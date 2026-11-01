class_name CrewBuildRequest
extends RefCounted

## "Build it with a crew" from a designer modal: the design is placed as a
## PACKED kit crate beside the player and handed to the site's crew through
## the deploy schedule (SiteDeployDirector.queue_item — the nearest camp with
## board room takes it ALL HANDS; the build site lays the kit out in a yard
## and puts it up piece by piece). The Linkage Lab's "Queue build for crew"
## does the same by hand; this is the shared form for the dome, toroid,
## solar, gantry and flat-pack designers. Pure apart from the placement.

const CRATE_AHEAD_M := 8.0


## {ok, error, crate_id, project_id, site: Vector2, hours}
static func queue_design(scene: Node, model_id: String, record_extra: Dictionary) -> Dictionary:
	var out := {"ok": false, "error": "", "crate_id": "", "site": Vector2.ZERO, "hours": 0.0}
	if scene == null or model_id.is_empty():
		out["error"] = "no world"
		return out
	var sgv := ServiceLocator.graph()
	var sd: Object = sgv.call("site_deploy") if sgv != null and sgv.has_method("site_deploy") else null
	if sd == null:
		out["error"] = "no population running — load a world with people first"
		return out
	var player := scene.find_child("Player", true, false) as Node3D
	var px := 0.0
	var pz := 0.0
	if player != null:
		var fwd := -player.global_transform.basis.z
		px = player.global_position.x + fwd.x * CRATE_AHEAD_M
		pz = player.global_position.z + fwd.z * CRATE_AHEAD_M
	var extra := record_extra.duplicate(true)
	extra["packed"] = true
	var placed: Dictionary = PlacedPropService.place_model_at_xz(scene, model_id, px, pz, extra)
	if not bool(placed.get("ok", false)):
		out["error"] = "couldn't place the kit crate — %s" % str(placed.get("error", ""))
		return out
	var crate_id := str(placed.get("prop_id", ""))
	var q: Dictionary = sd.call("queue_item", "prop", crate_id, SiteDeploySchedule.ACTION_DEPLOY)
	if not bool(q.get("ok", false)):
		var loader := TerrainSurfaceQuery.find_terrain_loader(scene)
		if loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", crate_id)
		out["error"] = str(q.get("error", "the crew can't take it"))
		return out
	var rec: Dictionary = PlacedPropService.get_prop_record(scene, crate_id)
	var pspec := PlacedPropRuntime.packed_spec_for_record(rec)
	out["hours"] = SiteDeployPlanner.labour_hours(float(pspec.get("mass_kg", -1.0)))
	out["site"] = Vector2(float(rec.get("x", px)), float(rec.get("z", pz)))
	out["crate_id"] = crate_id
	out["project_id"] = str(q.get("project_id", ""))
	out["ok"] = true
	if sgv.has_method("notify_crew_queued"):
		sgv.call("notify_crew_queued", out["site"], "👷 Build queued for the crew",
			"about %s of crew work" % UiText.duration(float(out["hours"])))
	return out

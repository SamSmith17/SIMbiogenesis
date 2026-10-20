extends RefCounted
## Terrain options → Apply & reload, end to end in the sandbox:
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/terrain_extents_apply_check.gd -Timeout 600
## Changes ONLY the map-data (OSM) square by +0.4 km (one Overpass request;
## the DEM and imagery come from cache), applies through the loader's real
## entry point, waits for the relaunched world and asserts the new size took
## everywhere it is stored: the loader, the world record's map block, the
## world snapshot (WorldSession.launch prefers the snapshot's sizes, which is
## how a resize used to be undone on the next play) and the per-site meta;
## that the world, not a bare scene, came back (same world id); and that the
## resumed player stands on the ground.


func run(main: Node, harness: Node) -> Dictionary:
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null:
		return {"ok": false, "why": "no TerrainLoader"}
	var before: Dictionary = loader.call("get_terrain_extents")
	var world_half := float(before["half_extent_m"])
	var detail_half := float(before["detail_half_extent_m"])
	var osm_half := float(before["osm_half_extent_m"])
	var want_osm := osm_half + 200.0
	if want_osm > TerrainExtents.OSM_SIDE_MAX_M * 0.5:
		want_osm = osm_half - 200.0
	var world_id := WorldSession.active_id()
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	print("extents-apply: %s world, %s hi-res, map data %s -> %s" % [
		TerrainExtents.format_side(world_half * 2.0), TerrainExtents.format_side(detail_half * 2.0),
		TerrainExtents.format_side(osm_half * 2.0), TerrainExtents.format_side(want_osm * 2.0)])
	var prev_id := main.get_tree().current_scene.get_instance_id()
	loader.call("apply_terrain_extents", world_half, detail_half, want_osm)
	var main2: Node = await harness.call("_await_world_scene", prev_id)
	var fails: Array[String] = []
	if main2 == null:
		return {"ok": false, "why": "the world never came back"}
	var loader2 := main2.get_node_or_null("TerrainLoader")
	var after: Dictionary = loader2.call("get_terrain_extents") if loader2 != null else {}
	_expect(fails, absf(float(after.get("osm_half_extent_m", 0.0)) - want_osm) < 0.5,
		"loader runs the new map-data size (%s)" % str(after.get("osm_half_extent_m")))
	_expect(fails, absf(float(after.get("half_extent_m", 0.0)) - world_half) < 0.5, "world size unchanged")
	_expect(fails, absf(float(after.get("detail_half_extent_m", 0.0)) - detail_half) < 0.5, "hi-res size unchanged")
	_expect(fails, WorldSession.active_id() == world_id, "the same world was relaunched (%s)" % WorldSession.active_id())
	var rec := WorldSession.active_record()
	var map: Dictionary = rec.get("map", {})
	_expect(fails, absf(float(map.get("osm_half_extent_m", 0.0)) - want_osm) < 0.5, "world record's map block has it")
	var snap := WorldStore.read_snapshot(world_id)
	_expect(fails, absf(float(snap.get("osm_half_extent_m", 0.0)) - want_osm) < 0.5, "world snapshot has it")
	var meta := TerrainCacheSettings.get_meta_extents(lat, lon)
	_expect(fails, absf(float(meta.get("osm_half_extent_m", 0.0)) - want_osm) < 0.5, "per-site meta has it")
	var player := main2.get_node_or_null("Player") as Node3D
	if player != null and loader2 != null and loader2.has_method("_ground_height_at"):
		var gy := float(loader2.call("_ground_height_at", player.global_position.x, player.global_position.z))
		var off := player.global_position.y - gy
		_expect(fails, off > -1.0 and off < 41.0, "resumed player is on the ground (%.2f m above it)" % off)
	for f in fails:
		print("extents-apply: FAIL — %s" % f)
	print("extents-apply: %s" % ("PASS" if fails.is_empty() else "FAIL"))
	return {"ok": fails.is_empty(), "fails": fails}


func _expect(fails: Array[String], ok: bool, what: String) -> void:
	if ok:
		print("extents-apply: ok — %s" % what)
	else:
		fails.append(what)

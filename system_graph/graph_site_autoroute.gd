class_name GraphSiteAutoroute
extends RefCounted

## Auto-generate draped route_3d polylines from site-plan node positions.

const SAMPLE_M := 5.0
const CLEARANCE_M := 0.15


## Refresh auto routes for all unlocked connections with placed endpoints.
## Returns number of connections updated.
static func refresh_all(model: GraphModel, main: Node, soi_center: Vector3) -> int:
	if model == null or main == null:
		return 0
	var n := 0
	for conn: Dictionary in model.connections:
		if bool(conn.get("route_locked", false)):
			continue
		if _autoroute_connection(model, conn, main, soi_center):
			n += 1
	return n


static func refresh_connection(model: GraphModel, conn_id: String, main: Node,
		soi_center: Vector3) -> bool:
	if model == null:
		return false
	var conn := model.get_connection(conn_id)
	if conn.is_empty() or bool(conn.get("route_locked", false)):
		return false
	return _autoroute_connection(model, conn, main, soi_center)


static func _autoroute_connection(model: GraphModel, conn: Dictionary, main: Node,
		soi_center: Vector3) -> bool:
	var src := model.get_item(str(conn.get("source_item_id", "")))
	var tgt := model.get_item(str(conn.get("target_item_id", "")))
	if src.is_empty() or tgt.is_empty():
		return false
	if not GraphSiteLayout.has_site_coords(src) or not GraphSiteLayout.has_site_coords(tgt):
		return false
	var pts_m: Array = []
	pts_m.append(GraphSiteLayout.site_xz(src))
	var site_wps: Array = conn.get("site_waypoints", []) as Array
	for wp_v in site_wps:
		if wp_v is Dictionary:
			pts_m.append(Vector2(float(wp_v.get("x", 0.0)), float(wp_v.get("z", wp_v.get("y", 0.0)))))
		elif wp_v is Vector2:
			pts_m.append(wp_v)
	pts_m.append(GraphSiteLayout.site_xz(tgt))
	var world_pts := _drape_polyline(pts_m, main, soi_center)
	if world_pts.size() < 2:
		return false
	var route: Array = []
	for p: Vector3 in world_pts:
		route.append(ConduitKinds.waypoint_dict(p))
	var length_m := ConduitKinds.polyline_length_m(
		PackedVector3Array(world_pts))
	var ctype := str(conn.get("conduit_type", ""))
	if ctype.is_empty():
		ctype = GraphSiteLayout.default_conduit_type(conn)
	var cid := str(conn.get("id", ""))
	model.update_connection(cid, {
		"route_3d": route,
		"conduit_type": ctype,
		"route_length_m": length_m,
		"estimated_length": length_m,
	})
	return true


static func _drape_polyline(site_pts: Array, main: Node, soi_center: Vector3) -> Array:
	var out: Array = []
	if site_pts.size() < 2:
		return out
	for i in range(site_pts.size() - 1):
		var a: Vector2 = site_pts[i] as Vector2
		var b: Vector2 = site_pts[i + 1] as Vector2
		var seg_len := a.distance_to(b)
		var steps := maxi(1, int(ceil(seg_len / SAMPLE_M)))
		var start_j := 0 if i == 0 else 1
		for j in range(start_j, steps + 1):
			var t := float(j) / float(steps)
			var s := a.lerp(b, t)
			var wxz := GraphSiteLayout.site_to_world_xz(s, soi_center)
			var gy := TerrainSurfaceQuery.ground_height_at(main, wxz.x, wxz.y)
			out.append(Vector3(wxz.x, gy + CLEARANCE_M, wxz.y))
	return out

class_name GraphSiteAutoroute
extends RefCounted

## Site-plan length estimates from node positions + site_waypoints.
## Does NOT write dense draped route_3d — 3D geometry is owned by
## ConduitManager / ConduitPathfinder (flat metro). Writing route_3d here
## used to pollute drag-lock with DEM samples → jagged spaghetti.

const CLEARANCE_M := 0.15


## Refresh length estimates for all unlocked connections with placed endpoints.
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
	var length_m := _site_polyline_length_m(pts_m)
	if length_m < 0.001:
		return false
	var cid := str(conn.get("id", ""))
	# Length only — leave route_3d alone (empty for unlocked metro).
	var patch: Dictionary = {
		"route_length_m": length_m,
		"estimated_length": length_m,
	}
	# Clear stale dense site-autoroute samples left by older builds.
	var existing: Array = conn.get("route_3d", []) as Array
	if existing.size() >= 5 and not bool(conn.get("route_locked", false)):
		patch["route_3d"] = []
	model.update_connection(cid, patch)
	return true


static func _site_polyline_length_m(site_pts: Array) -> float:
	var total := 0.0
	for i in range(site_pts.size() - 1):
		var a: Vector2 = site_pts[i] as Vector2
		var b: Vector2 = site_pts[i + 1] as Vector2
		total += a.distance_to(b)
	return total

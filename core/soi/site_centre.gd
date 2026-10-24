class_name SiteCentre
extends RefCounted

## Where "the site" is: the location marker the player drags (the SoI
## centre), never the world origin and never wherever the player happens to
## stand. Festival seeding, the settlement view's default framing and the
## population bridge's fallback home all ask this ONE function, so moving the
## marker moves all of them.
##
## The world's coordinate frame itself does not move: terrain, imagery and the
## OSM data stay keyed to the map's lat/lon. The marker is the SITE's centre
## inside that frame — the same convention the graph's site_x_m/site_z_m use
## (GraphSiteLayout.world_xz_to_site).
##
## Autoload-free on purpose: SoiService is reached through the tree, so this
## file compiles under --script for the selftests.


## World XZ of the site centre. SoiService when it is in the tree, else the
## saved marker for the loader's site, else the world origin.
static func xz(context: Node = null) -> Vector2:
	var tree := context.get_tree() if context != null and context.is_inside_tree() else null
	if tree == null:
		var ml := Engine.get_main_loop()
		tree = ml as SceneTree
	if tree != null and tree.root != null:
		var soi := tree.root.get_node_or_null("SoiService")
		if soi != null and soi.has_method("world_center"):
			var c: Vector3 = soi.call("world_center")
			return Vector2(c.x, c.z)
		if context != null:
			var loader := TerrainSurfaceQuery.find_terrain_loader(context)
			if loader != null and "_lat" in loader and "_lon" in loader:
				var cfg := SoiConfig.load_for_map(float(loader.get("_lat")), float(loader.get("_lon")))
				return Vector2(cfg.center_x, cfg.center_z)
	return Vector2.ZERO


## The same point as a Vector3 at y = 0 (GraphSiteLayout takes a Vector3).
static func xyz(context: Node = null) -> Vector3:
	var c := xz(context)
	return Vector3(c.x, 0.0, c.y)


## World XZ -> marker-relative site metres.
static func to_site(world_xz: Vector2, context: Node = null) -> Vector2:
	return world_xz - xz(context)

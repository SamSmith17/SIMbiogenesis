class_name SiteTargetPicker
extends RefCounted

## What a ray points at, as a pure function of the ray.
##
## The first-person crosshair resolves targets by walking a priority ladder
## down the centre ray. The settlement view needs the SAME answers down the
## mouse ray — and "the same" has to be provable, not merely intended, or the
## two views will quietly disagree about what you are looking at. So the
## resolution lives here, once, and both callers use it.
##
## What deliberately stays with the caller: prompt text, focus highlights, and
## every side effect (`set_building_focus_idx`, `set_solar_array_focus_idx`,
## crosshair state). Those are PRESENTATION and they differ per view. This file
## answers one question and changes nothing.
##
## Ladder order is significant and is pinned by the selftest:
##   npc → prop → space → crew → ground
## People come first because someone standing in front of a shed is who you
## meant; ground is the floor of the ladder and always answers when nothing
## else does. Callers narrow with `opts.want`.
##
## `opts`:
##   want: PackedStringArray — kinds to consider (empty = all)
##   max_dist_m: float — ray length (default 250)
##   min_pick_deg: float — MINIMUM angular radius for point targets. Without
##     it, a person 500 m away is sub-pixel and mathematically unclickable, so
##     the settlement view's whole selection story fails at exactly the zoom
##     levels it exists for. 0.6° ≈ 10 px at a 68° fov on a 1080p viewport.

const DEFAULT_MAX_DIST_M := 250.0
const DEFAULT_MIN_PICK_DEG := 0.6
## Ground radius within which a click counts as hitting a work site.
const CREW_PICK_R_M := 4.0


## Returns {} or {kind, t, ...}. Kinds: npc / prop / space / crew / ground.
static func resolve(main: Node, origin: Vector3, dir: Vector3,
		opts: Dictionary = {}) -> Dictionary:
	if main == null or dir.length_squared() < 1e-6:
		return {}
	dir = dir.normalized()
	var want: PackedStringArray = opts.get("want", PackedStringArray())
	var max_d := float(opts.get("max_dist_m", DEFAULT_MAX_DIST_M))
	var min_deg := float(opts.get("min_pick_deg", DEFAULT_MIN_PICK_DEG))

	if _wants(want, "npc"):
		var hit := _pick_npc(main, origin, dir, max_d, min_deg)
		if not hit.is_empty():
			return hit
	if _wants(want, "prop"):
		var hit2 := _pick_prop(main, origin, dir, max_d)
		if not hit2.is_empty():
			return hit2
	# Everything below is resolved against the ground point, so compute it once.
	var ground := ground_hit(main, origin, dir, max_d)
	if ground.is_empty():
		return {}
	var gp: Vector3 = ground["point"]
	if _wants(want, "space"):
		var hit3 := _pick_space(main, gp)
		if not hit3.is_empty():
			hit3["t"] = ground["t"]
			hit3["point"] = gp
			return hit3
	if _wants(want, "crew"):
		var hit4 := _pick_crew(main, gp)
		if not hit4.is_empty():
			hit4["t"] = ground["t"]
			hit4["point"] = gp
			return hit4
	if _wants(want, "ground"):
		return ground
	return {}


static func _wants(want: PackedStringArray, kind: String) -> bool:
	return want.is_empty() or want.has(kind)


## People, by software ray-vs-sphere over the `npc_avatars` group.
##
## Avatars deliberately carry NO collider — a moving StaticBody would shove the
## player around — so this cannot use the physics server, and that constraint
## transfers unchanged from the first-person path.
static func _pick_npc(main: Node, origin: Vector3, dir: Vector3,
		max_d: float, min_deg: float) -> Dictionary:
	var tree := main.get_tree()
	if tree == null:
		return {}
	var best: Node = null
	var best_t := INF
	for node in tree.get_nodes_in_group("npc_avatars"):
		var av := node as NpcAvatar
		if av == null or not is_instance_valid(av) or not av.visible:
			continue
		var to_center: Vector3 = av.pick_center() - origin
		var t := to_center.dot(dir)
		if t <= 0.0 or t > max_d or t >= best_t:
			continue
		if (to_center - dir * t).length() > pick_radius_at(t, min_deg):
			continue
		best_t = t
		best = av
	if best == null:
		return {}
	return {"kind": "npc", "t": best_t, "agent_id": (best as NpcAvatar).agent_id,
		"avatar": best}


## The radius a point target must be given to stay clickable at distance `t`.
## A fixed metre radius is right up close and unusable far away; an angular
## floor keeps the on-screen size constant.
static func pick_radius_at(t: float, min_deg: float = DEFAULT_MIN_PICK_DEG) -> float:
	return maxf(NpcAvatar.PICK_RADIUS_M, t * tan(deg_to_rad(maxf(min_deg, 0.0))))


static func _pick_prop(main: Node, origin: Vector3, dir: Vector3,
		max_d: float) -> Dictionary:
	var space := _space_state(main)
	if space == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_d)
	q.collide_with_areas = false
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return {}
	var node := hit.get("collider") as Node
	while node != null and not (node is PlacedProp):
		node = node.get_parent()
	if node == null:
		return {}
	var p: Vector3 = hit["position"]
	return {"kind": "prop", "t": origin.distance_to(p), "point": p,
		"prop": node, "prop_id": str((node as PlacedProp).prop_id)}


## Tagged spaces, by point-in-polygon on the ground point. Area spaces only —
## a prop-anchored space is reached by picking the prop.
static func _pick_space(main: Node, gp: Vector3) -> Dictionary:
	var reg := _registry(main)
	if reg == null:
		return {}
	var here := Vector2(gp.x, gp.z)
	for sp in reg.spaces:
		var sd: Dictionary = sp
		var tgt: Dictionary = sd.get("target", {})
		if str(tgt.get("kind", "")) != "area":
			continue
		var poly: Array = tgt.get("poly", []) as Array
		if poly.size() < 3:
			continue
		if SpaceRegistry.polygon_contains(poly, here):
			return {"kind": "space", "space_id": str(sd.get("id", "")),
				"space_type": str(sd.get("space_type", ""))}
	return {}


static func _pick_crew(main: Node, gp: Vector3) -> Dictionary:
	var bridge: Variant = _bridge(main)
	if bridge == null:
		return {}
	var here := Vector2(gp.x, gp.z)
	var best: Dictionary = {}
	var best_d := CREW_PICK_R_M
	var marks: Array = bridge.call("crew_site_markers", main)
	for m in marks:
		var mark: Dictionary = m
		var d := here.distance_to(mark.get("pos", Vector2.ZERO) as Vector2)
		if d < best_d:
			best_d = d
			best = mark
	if best.is_empty():
		return {}
	return {"kind": "crew", "label": str(best.get("label", "")),
		"workers": int(best.get("workers", 0)),
		"min_workers": int(best.get("min_workers", 1)),
		"progress": float(best.get("progress", 0.0))}


## Where the ray meets the world. Physics first; falls back to the terrain
## height field so a ray aimed past every collider still lands somewhere —
## which matters at settlement zoom, where most of the frame is bare ground.
static func ground_hit(main: Node, origin: Vector3, dir: Vector3,
		max_d: float = DEFAULT_MAX_DIST_M) -> Dictionary:
	var space := _space_state(main)
	if space != null:
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_d)
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var p: Vector3 = hit["position"]
			return {"kind": "ground", "t": origin.distance_to(p), "point": p}
	if absf(dir.y) < 1e-4:
		return {}
	# Iterate: the plane height depends on where the ray lands, and where it
	# lands depends on the height. Three passes converge on any real terrain.
	var y := 0.0
	var p2 := Vector3.ZERO
	for _i in 3:
		var t := (y - origin.y) / dir.y
		if t <= 0.0 or t > max_d:
			return {}
		p2 = origin + dir * t
		y = TerrainSurfaceQuery.ground_height_at(main, p2.x, p2.z)
	return {"kind": "ground", "t": origin.distance_to(p2),
		"point": Vector3(p2.x, y, p2.z)}


static func _space_state(main: Node) -> PhysicsDirectSpaceState3D:
	var n3 := main as Node3D
	if n3 == null or not n3.is_inside_tree():
		return null
	var w := n3.get_world_3d()
	return w.direct_space_state if w != null else null


static func _registry(main: Node) -> SpaceRegistry:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null:
		var reg: Variant = loader.get("npc_spaces")
		if reg is SpaceRegistry:
			return reg
	return null


static func _bridge(main: Node) -> Variant:
	var sgv := main.get_node_or_null("UILayer/SystemGraphView")
	if sgv != null and sgv.has_method("npc_population_bridge"):
		return sgv.call("npc_population_bridge")
	return null

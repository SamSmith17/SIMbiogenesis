class_name TerrainSurfaceQuery
extends RefCounted

## Ground height for placed props — hi-res TerrainLoader footing or physics raycast.

const RAY_TOP_Y := 20000.0
const RAY_LENGTH := 40000.0
const CAMERA_RAY_LEN := 800.0


static func ground_height_at(main: Node, x: float, z: float) -> float:
	if main == null:
		return 0.0
	var loader := find_terrain_loader(main)
	if loader != null and loader.has_method("ground_height_at"):
		return float(loader.call("ground_height_at", x, z))
	var world: World3D = main.get_world_3d() if main.is_inside_tree() else null
	if world == null:
		return 0.0
	var exclude := _placed_prop_rids(main)
	var probe_y := _probe_y_for(main, x, z)
	var gy := _raycast_ground_y_from(world, x, z, probe_y, exclude)
	if gy == 0.0 and probe_y > 500.0:
		gy = _raycast_ground_y(world, x, z, exclude)
	return gy


static func _probe_y_for(main: Node, x: float, z: float) -> float:
	var player := main.get_node_or_null("Player") as Node3D
	if player != null:
		return player.global_position.y + 30.0
	if "player_spawn_position" in main:
		return float(main.player_spawn_position.y) + 30.0
	return RAY_TOP_Y


static func ground_y_callable(main: Node) -> Callable:
	return func(x: float, z: float) -> float:
		return ground_height_at(main, x, z)


static func placement_xz(main: Node, near_player: bool, offset_xz: Vector2 = Vector2.ZERO) -> Vector2:
	if near_player:
		var player := main.get_node_or_null("Player") as Node3D
		if player != null:
			var forward := -player.global_transform.basis.z
			forward.y = 0.0
			if forward.length_squared() > 0.01:
				forward = forward.normalized()
			else:
				forward = Vector3(0.0, 0.0, -1.0)
			var p := player.global_position + forward * 4.0
			return Vector2(p.x + offset_xz.x, p.z + offset_xz.y)
	return offset_xz


static func raycast_ground_at_camera(main: Node, camera: Camera3D,
		screen_pos: Vector2 = Vector2(-1.0, -1.0)) -> Dictionary:
	if main == null or camera == null:
		return {}
	var vp := camera.get_viewport()
	if vp == null:
		return {}
	var pos := screen_pos
	if pos.x < 0.0:
		pos = vp.get_visible_rect().size * 0.5
	var origin := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var world: World3D = main.get_world_3d() if main.is_inside_tree() else null
	if world == null:
		return {}
	var space := world.direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + dir * CAMERA_RAY_LEN)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = _terrain_physics_excludes(main)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return {}
	var p: Vector3 = hit["position"] as Vector3
	# Authoritative walkable footing (hi-res detail DEM when inside the patch).
	p.y = ground_height_at(main, p.x, p.z)
	var out := hit.duplicate()
	out["position"] = p
	return out


static func _placed_prop_rids(main: Node) -> Array[RID]:
	var rids: Array[RID] = []
	if main == null:
		return rids
	var roots: Array[Node] = []
	var terrain := main.get_node_or_null("Terrain")
	if terrain != null:
		roots.append(terrain)
	roots.append(main)
	for root in roots:
		var placed := root.get_node_or_null("PlacedProps")
		if placed == null:
			continue
		for child in placed.get_children():
			if not (child is PlacedProp):
				continue
			var body := (child as PlacedProp).get_node_or_null("PropBody")
			if body is CollisionObject3D:
				rids.append((body as CollisionObject3D).get_rid())
	return rids


static func _raycast_ground_y(world: World3D, x: float, z: float,
		exclude: Array[RID] = []) -> float:
	return _raycast_ground_y_from(world, x, z, RAY_TOP_Y, exclude)


static func _raycast_ground_y_from(world: World3D, x: float, z: float, from_y: float,
		exclude: Array[RID] = []) -> float:
	var space := world.direct_space_state
	if space == null:
		return 0.0
	var from := Vector3(x, from_y, z)
	var to := Vector3(x, from_y - RAY_LENGTH, z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = exclude
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return 0.0
	var p: Vector3 = hit["position"] as Vector3
	return p.y


static func find_terrain_loader(main: Node) -> Node:
	if main == null:
		return null
	var direct := main.get_node_or_null("TerrainLoader")
	if direct != null:
		return direct
	var terrain := main.get_node_or_null("Terrain")
	if terrain != null:
		var under := terrain.get_node_or_null("TerrainLoader")
		if under != null:
			return under
	return main.find_child("TerrainLoader", true, false)


static func _terrain_physics_excludes(main: Node) -> Array[RID]:
	var rids := _placed_prop_rids(main)
	var loader := find_terrain_loader(main)
	if loader == null:
		return rids
	var has_detail := false
	if loader.has_method("has_detail_footing"):
		has_detail = bool(loader.call("has_detail_footing"))
	if not has_detail:
		return rids
	var terrain := main.get_node_or_null("Terrain")
	if terrain == null:
		return rids
	var coarse := terrain.get_node_or_null("TerrainCollision")
	if coarse is CollisionObject3D:
		rids.append((coarse as CollisionObject3D).get_rid())
	return rids

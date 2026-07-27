class_name ConduitSurfaceAim
extends RefCounted

## Hybrid crosshair → world point for hang-edit conduit pins.
## Physics first (terrain + placed props). Mesh pick is a *fallback* only —
## never triangle-walk the merged OSM Buildings mesh every frame (that hung the game).

const RAY_LEN := 800.0
const MESH_RANGE_M := 40.0
const FREE_AIR_DEPTH_M := 4.0
## Skip per-triangle pick above this; use ray∩AABB entry instead.
const HUGE_MESH_TRIS := 12000
## Hard budget for a single MeshTrianglePick call.
const MESH_PICK_MAX_TRIS := 8000
## Reuse last mesh hit for this many msec when the aim ray barely moved.
const MESH_CACHE_MS := 80


static var _mesh_cache_pos: Vector3 = Vector3.ZERO
static var _mesh_cache_n: Vector3 = Vector3.UP
static var _mesh_cache_valid: bool = false
static var _mesh_cache_ms: int = 0
static var _mesh_cache_origin: Vector3 = Vector3.ZERO
static var _mesh_cache_dir: Vector3 = Vector3.FORWARD


## Returns {valid, position, normal, pin_path, source} where source is
## "physics" | "mesh" | "aabb" | "free".
static func pick(main: Node, camera: Camera3D,
		exclude_rids: Array = []) -> Dictionary:
	var out := {
		"valid": false,
		"position": Vector3.ZERO,
		"normal": Vector3.UP,
		"pin_path": "",
		"source": "",
	}
	if main == null or camera == null:
		return out
	var cam_pos := camera.position
	var cam_basis := camera.transform.basis
	if camera.is_inside_tree():
		cam_pos = camera.global_position
		cam_basis = camera.global_transform.basis
	var origin := cam_pos
	var dir := -cam_basis.z
	if camera.is_inside_tree():
		var vp := camera.get_viewport()
		if vp != null:
			var sz := vp.get_visible_rect().size
			if sz.x > 1.0 and sz.y > 1.0:
				var center := sz * 0.5
				origin = camera.project_ray_origin(center)
				dir = camera.project_ray_normal(center)
	if dir.length_squared() < 1e-12:
		dir = -cam_basis.z
	dir = dir.normalized()

	# 1) Physics — terrain + PlacedProp colliders (pallet racks, etc.).
	var phys := _physics_hit(main, origin, dir, exclude_rids)
	if bool(phys.get("valid", false)):
		out["valid"] = true
		out["position"] = phys.get("position", Vector3.ZERO)
		out["normal"] = phys.get("normal", Vector3.UP)
		out["pin_path"] = str(phys.get("pin_path", ""))
		out["source"] = "physics"
		out["distance"] = float(phys.get("distance", 0.0))
		return out

	# 2) Mesh fallback only when physics missed (OSM buildings have no colliders).
	var mesh := _mesh_hit_cached(main, origin, dir, cam_pos)
	if bool(mesh.get("valid", false)):
		out["valid"] = true
		out["position"] = mesh.get("position", Vector3.ZERO)
		out["normal"] = mesh.get("normal", Vector3.UP)
		out["pin_path"] = ""
		out["source"] = str(mesh.get("source", "mesh"))
		out["distance"] = float(mesh.get("distance", 0.0))
		return out

	# 3) Free-air hang pin.
	out["valid"] = true
	out["position"] = origin + dir * FREE_AIR_DEPTH_M
	out["normal"] = -dir
	out["pin_path"] = ""
	out["source"] = "free"
	out["distance"] = FREE_AIR_DEPTH_M
	return out


static func clear_caches() -> void:
	_mesh_cache_valid = false
	_mesh_cache_ms = 0


static func _physics_hit(main: Node, origin: Vector3, dir: Vector3,
		exclude_rids: Array) -> Dictionary:
	var world: World3D = null
	if main is Node3D and (main as Node3D).is_inside_tree():
		world = (main as Node3D).get_world_3d()
	if world == null and main != null and main.is_inside_tree() \
			and main.get_viewport() != null:
		var cam := main.get_viewport().get_camera_3d()
		if cam != null and cam.is_inside_tree():
			world = cam.get_world_3d()
	if world == null:
		return {"valid": false}
	var space := world.direct_space_state
	if space == null:
		return {"valid": false}
	var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LEN)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if not exclude_rids.is_empty():
		var ex: Array[RID] = []
		for r: Variant in exclude_rids:
			if r is RID:
				ex.append(r as RID)
		query.exclude = ex
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return {"valid": false}
	var pin_path := ""
	var col: Object = hit.get("collider")
	if col is Node:
		pin_path = str((col as Node).get_path())
	var pos: Vector3 = hit.get("position", Vector3.ZERO) as Vector3
	return {
		"valid": true,
		"position": pos,
		"normal": hit.get("normal", Vector3.UP) as Vector3,
		"pin_path": pin_path,
		"distance": origin.distance_to(pos),
		"collider": col,
	}


static func _mesh_hit_cached(main: Node, origin: Vector3, dir: Vector3,
		cam_pos: Vector3) -> Dictionary:
	var now := Time.get_ticks_msec()
	if _mesh_cache_valid and (now - _mesh_cache_ms) < MESH_CACHE_MS:
		if origin.distance_squared_to(_mesh_cache_origin) < 0.01 \
				and dir.dot(_mesh_cache_dir) > 0.998:
			return {
				"valid": true,
				"position": _mesh_cache_pos,
				"normal": _mesh_cache_n,
				"distance": origin.distance_to(_mesh_cache_pos),
				"source": "mesh",
			}
	var hit := _mesh_hit(main, origin, dir, cam_pos)
	if bool(hit.get("valid", false)):
		_mesh_cache_valid = true
		_mesh_cache_ms = now
		_mesh_cache_origin = origin
		_mesh_cache_dir = dir
		_mesh_cache_pos = hit.get("position", Vector3.ZERO) as Vector3
		_mesh_cache_n = hit.get("normal", Vector3.UP) as Vector3
	return hit


static func _mesh_hit(main: Node, origin: Vector3, dir: Vector3,
		cam_pos: Vector3) -> Dictionary:
	var best := {"valid": false}
	var best_d := INF
	var terrain := main.get_node_or_null("Terrain")
	if terrain == null:
		terrain = main.find_child("Terrain", true, false)
	if terrain == null:
		return best
	# Styled / individual buildings first (small meshes — safe to triangle-pick).
	var custom := terrain.get_node_or_null("BuildingsCustom")
	if custom != null:
		for child in custom.get_children():
			if not (child is Node3D):
				continue
			var n3 := child as Node3D
			if n3.global_position.distance_to(cam_pos) > MESH_RANGE_M:
				continue
			var ch := _pick_under_root_budgeted(n3, origin, dir)
			if bool(ch.get("valid", false)) and float(ch.get("distance", INF)) < best_d:
				best = ch
				best_d = float(ch["distance"])
	# Merged OSM Buildings: NEVER full triangle walk — AABB entry only.
	var buildings := terrain.get_node_or_null("Buildings")
	if buildings is MeshInstance3D:
		var bh := _pick_mi_cheap(buildings as MeshInstance3D, origin, dir, cam_pos)
		if bool(bh.get("valid", false)) and float(bh.get("distance", INF)) < best_d:
			best = bh
			best_d = float(bh["distance"])
	return best


static func _pick_under_root_budgeted(root: Node3D, origin: Vector3,
		dir: Vector3) -> Dictionary:
	if root == null:
		return {"valid": false}
	if root is MeshInstance3D:
		return _pick_mi_cheap(root as MeshInstance3D, origin, dir, root.global_position)
	var best := {"valid": false}
	var best_d := INF
	var n_checked := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		n_checked += 1
		if n_checked > 8:
			break
		var mi := node as MeshInstance3D
		if mi == null:
			continue
		var h := _pick_mi_cheap(mi, origin, dir, root.global_position)
		if bool(h.get("valid", false)) and float(h.get("distance", INF)) < best_d:
			best = h
			best_d = float(h["distance"])
	return best


static func _pick_mi_cheap(mi: MeshInstance3D, origin: Vector3, dir: Vector3,
		cam_pos: Vector3) -> Dictionary:
	if mi == null or mi.mesh == null or not mi.visible:
		return {"valid": false}
	var aabb: AABB = mi.global_transform * mi.get_aabb()
	if not _ray_hits_aabb(origin, dir, aabb.grow(0.25)):
		return {"valid": false}
	# Far from camera and not a tight local mesh → skip.
	if aabb.get_center().distance_to(cam_pos) > MESH_RANGE_M * 2.0 \
			and origin.distance_to(aabb.get_center()) > MESH_RANGE_M * 2.0:
		return {"valid": false}
	var tris := MeshTrianglePick.estimate_triangle_count(mi.mesh)
	# Huge merged building mosaics: pin at the AABB ray entry (no triangle walk).
	if tris > HUGE_MESH_TRIS:
		var entry := _aabb_entry(origin, dir, aabb)
		if bool(entry.get("valid", false)):
			entry["source"] = "aabb"
		return entry
	var hit := MeshTrianglePick.pick_mesh_instance(mi, origin, dir, MESH_PICK_MAX_TRIS)
	if bool(hit.get("valid", false)):
		hit["source"] = "mesh"
		return hit
	# Budget exhausted / miss — still offer AABB entry so hang pins work.
	var fallback := _aabb_entry(origin, dir, aabb)
	if bool(fallback.get("valid", false)):
		fallback["source"] = "aabb"
	return fallback


static func _aabb_entry(origin: Vector3, dir: Vector3, aabb: AABB) -> Dictionary:
	var t := _ray_aabb_tmin(origin, dir, aabb)
	if t < 0.0 or t > RAY_LEN:
		return {"valid": false}
	var pos := origin + dir * t
	# Normal ≈ toward the outside of the box from the hit (axis of largest slab).
	var c := aabb.get_center()
	var n := (pos - c)
	if n.length_squared() < 1e-8:
		n = -dir
	else:
		n = n.normalized()
	return {
		"valid": true,
		"position": pos,
		"normal": n,
		"distance": t,
	}


static func _ray_aabb_tmin(origin: Vector3, dir: Vector3, aabb: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	for axis: int in range(3):
		var o := origin[axis]
		var d := dir[axis]
		var mn := aabb.position[axis]
		var mx := aabb.position[axis] + aabb.size[axis]
		if absf(d) < 1e-9:
			if o < mn or o > mx:
				return -1.0
			continue
		var t1 := (mn - o) / d
		var t2 := (mx - o) / d
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		tmin = maxf(tmin, t1)
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return -1.0
	if tmax < 0.0:
		return -1.0
	return maxf(tmin, 0.0)


static func _ray_hits_aabb(origin: Vector3, dir: Vector3, aabb: AABB) -> bool:
	return _ray_aabb_tmin(origin, dir, aabb) >= 0.0

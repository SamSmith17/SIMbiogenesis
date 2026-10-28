class_name PvSurfaceAim
extends RefCounted

## Where a designed solar array goes under the crosshair: the ground, the top
## of a placed prop or generated structure (its PropBody collider: pallet-rack
## roof decks, domes, sheds, containers), or an OSM roof (buildings have no
## collider: TerrainLoader.roof_ray marches their roof surfaces). Keeps the
## hit's height and surface normal, which the old terrain-only aim flattened
## away.
##
## mount_transform turns a hit into the array's pose: on a pitched surface
## (over PITCHED_DEG) the array lies in the surface with its modules facing
## down the slope (the way roof arrays are installed), turned by the
## player's yaw about the surface normal; on level ground or a flat roof it
## stands upright, turned by the yaw.

const RAY_LEN := 250.0
const ROOF_MAX_T := 120.0
const PITCHED_DEG := 6.0


## {valid, position, normal, host: {kind: "terrain" | "prop" | "building",
## id}, pitched}.
static func pick(main: Node, camera: Camera3D) -> Dictionary:
	if main == null or camera == null or not main.is_inside_tree():
		return {"valid": false}
	var vp := camera.get_viewport()
	if vp == null:
		return {"valid": false}
	var c := vp.get_visible_rect().size * 0.5
	return pick_ray(main, camera.project_ray_origin(c), camera.project_ray_normal(c))


static func pick_ray(main: Node, origin: Vector3, dir: Vector3) -> Dictionary:
	var out := {"valid": false}
	var best_t := INF
	var world: World3D = (main as Node3D).get_world_3d() if main is Node3D else main.get_viewport().world_3d
	if world != null and world.direct_space_state != null:
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * RAY_LEN)
		q.collide_with_areas = false
		q.exclude = _player_rids(main)
		var hit: Dictionary = world.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			var pos: Vector3 = hit["position"]
			var n: Vector3 = hit.get("normal", Vector3.UP)
			if n.dot(-dir) < 0.0:
				n = -n
			var host := {"kind": "terrain", "id": ""}
			var col: Object = hit.get("collider")
			var prop := _prop_of(col)
			if prop != null:
				host = {"kind": "prop", "id": str(prop.prop_id)}
			else:
				# Terrain: the walkable footing, level-ish.
				pos.y = TerrainSurfaceQuery.ground_height_at(main, pos.x, pos.z)
			best_t = origin.distance_to(pos)
			out = {"valid": true, "position": pos, "normal": n.normalized(), "host": host}
	var loader := main.get_node_or_null("Terrain/TerrainLoader")
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("roof_ray"):
		var r: Dictionary = loader.call("roof_ray", origin, dir, minf(best_t, ROOF_MAX_T))
		if bool(r.get("ok", false)) and float(r["t"]) < best_t:
			out = {"valid": true, "position": r["position"], "normal": r["normal"],
				"host": {"kind": "building", "id": str(r.get("tag", ""))}}
	if bool(out.get("valid", false)):
		out["pitched"] = rad_to_deg(acos(clampf((out["normal"] as Vector3).y, -1.0, 1.0))) > PITCHED_DEG
	return out


static func _prop_of(col: Object) -> PlacedProp:
	var n := col as Node
	var guard := 0
	while n != null and guard < 6:
		if n is PlacedProp:
			return n as PlacedProp
		n = n.get_parent()
		guard += 1
	return null


static func _player_rids(main: Node) -> Array:
	var out: Array = []
	var player := main.get_node_or_null("Player")
	if player is CollisionObject3D:
		out.append((player as CollisionObject3D).get_rid())
	return out


## The array's world pose for a hit and the player's yaw (degrees).
static func mount_transform(aim: Dictionary, yaw_deg: float) -> Transform3D:
	var pos: Vector3 = aim["position"]
	var n: Vector3 = aim.get("normal", Vector3.UP)
	if not bool(aim.get("pitched", false)):
		return Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)), pos)
	return Transform3D(surface_basis(n, yaw_deg), pos)


## A basis lying in a surface of normal n: +Y the normal, +Z down the slope
## (so the modules face the way the surface does), turned by `yaw_deg` about n.
static func surface_basis(n: Vector3, yaw_deg: float = 0.0) -> Basis:
	var y := n.normalized()
	var down := Vector3(y.x, 0.0, y.z)
	if down.length() < 1e-4:
		down = Vector3(0, 0, 1)
	down = down.normalized()
	var z := (down - y * down.dot(y)).normalized()
	var x := y.cross(z).normalized()
	var b := Basis(x, y, z)
	return b * Basis(Vector3.UP, deg_to_rad(yaw_deg))


## A placed record's world transform (as PlacedPropRuntime._apply_transform
## puts it): yaw / pitch / roll in degrees, the foot on the ground plus
## y_offset.
static func record_xf(main: Node, rec: Dictionary) -> Transform3D:
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	var gy := TerrainSurfaceQuery.ground_height_at(main, x, z)
	var mid := str(rec.get("model_id", ""))
	var ws := ModelCatalog.resolved_scale(mid, float(rec.get("scale", 1.0)))
	var y := gy - ModelCatalog.foot_local_y(mid) * ws + float(rec.get("y_offset", 0.0))
	var b := Basis.from_euler(Vector3(deg_to_rad(float(rec.get("pitch", 0.0))), deg_to_rad(float(rec.get("yaw", 0.0))),
		deg_to_rad(float(rec.get("roll", 0.0)))))
	return Transform3D(b, Vector3(x, y, z))


## The record fields that put a model with `model_id` at world pose `xf`.
static func record_patch_for(main: Node, model_id: String, xf: Transform3D) -> Dictionary:
	var b := xf.basis.orthonormalized()
	var e := b.get_euler()
	var gy := TerrainSurfaceQuery.ground_height_at(main, xf.origin.x, xf.origin.z)
	var ws := ModelCatalog.resolved_scale(model_id, 1.0)
	return {"x": xf.origin.x, "z": xf.origin.z, "y_offset": xf.origin.y - gy + ModelCatalog.foot_local_y(model_id) * ws,
		"pitch": rad_to_deg(e.x), "yaw": rad_to_deg(e.y), "roll": rad_to_deg(e.z)}

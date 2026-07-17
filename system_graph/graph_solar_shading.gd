class_name GraphSolarShading
extends RefCounted

## Per-node geometric shade for solar PBI receivers (panels, grow beds).
## Casts a physics ray from the node's site position toward the sun — same
## idea as SolarUI._get_shadow_factor, generalized to N site-placed nodes.
## Result is written to specs.sunlight_factor (0–1); clouds stay in GHI /
## sun_availability so they are not double-counted here.

## Unoccluded daylight.
const CLEAR := 1.0
## Beam blocked — keep a small residual for isotropic sky diffuse so a
## fully-occluded bed/panel is dim, not dead (unlike SolarUI's binary 0/1
## whole-system shadow toggle).
const SHADED_RESIDUAL := 0.20
## Sample height above ground / elevation_m (m). Clears low self-occlusion
## from flat panel meshes while still catching building/tree shade.
const SAMPLE_HEIGHT_M := 1.5
const RAY_LENGTH_M := 2000.0
## Sun below this elevation (dir.y) → skip raycast, report CLEAR (night is
## already gated by GHI/PAR = 0; don't stamp nodes as "shaded").
const HORIZON_Y := 0.02


## Geometric shade factor from a hit dictionary (empty = clear sky).
static func factor_from_hit(hit: Dictionary, sun_dir: Vector3) -> float:
	if sun_dir.y <= HORIZON_Y:
		return CLEAR
	if hit.is_empty():
		return CLEAR
	return SHADED_RESIDUAL


## Raycast toward the sun. `intersect_fn(from, to) -> Dictionary` is
## injectable for offline selftests (live path passes PhysicsDirectSpaceState
## via a lambda).
static func shade_factor_at(origin: Vector3, sun_dir: Vector3,
		intersect_fn: Callable) -> float:
	if sun_dir.y <= HORIZON_Y:
		return CLEAR
	var dir := sun_dir.normalized()
	if dir.length_squared() < 0.0001:
		return CLEAR
	var hit: Dictionary = intersect_fn.call(origin, origin + dir * RAY_LENGTH_M)
	return factor_from_hit(hit if hit is Dictionary else {}, sun_dir)


## Live physics raycast helper — returns hit dict or {}.
static func physics_intersect(space: PhysicsDirectSpaceState3D,
		from: Vector3, to: Vector3, exclude: Array = []) -> Dictionary:
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.collision_mask = 0xFFFF
	if not exclude.is_empty():
		query.exclude = exclude
	return space.intersect_ray(query)


## World-space sample origin for a graph item with site_x_m / site_z_m.
## Prefer elevation_m when present; else TerrainSurfaceQuery ground height.
static func sample_origin(item: Dictionary, main: Node, soi_center: Vector3) -> Vector3:
	var site := GraphSiteLayout.site_xz(item)
	var wxz := GraphSiteLayout.site_to_world_xz(site, soi_center)
	var y: float
	if item.has("elevation_m") and typeof(item.get("elevation_m")) != TYPE_NIL:
		y = float(item.get("elevation_m", 0.0))
	elif main != null:
		y = TerrainSurfaceQuery.ground_height_at(main, wxz.x, wxz.y)
	else:
		y = soi_center.y
	return Vector3(wxz.x, y + SAMPLE_HEIGHT_M, wxz.y)


## True when this item type should receive per-node shade writeback.
static func is_receiver_type(itype: String) -> bool:
	return itype == "panel" or itype == "plant"


## Live shade for one item. Returns CLEAR when physics/site unavailable.
static func shade_factor_for_item(item: Dictionary, main: Node, soi_center: Vector3,
		sun_dir: Vector3, space: PhysicsDirectSpaceState3D) -> float:
	if not GraphSiteLayout.has_site_coords(item):
		return CLEAR
	if space == null or sun_dir.y <= HORIZON_Y:
		return CLEAR
	var origin := sample_origin(item, main, soi_center)
	var exclude: Array = []
	return shade_factor_at(origin, sun_dir, func(from: Vector3, to: Vector3) -> Dictionary:
		return physics_intersect(space, from, to, exclude)
	)

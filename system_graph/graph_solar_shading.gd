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


# ---------------------------------------------------------------------------
# Array-level shade: one model for the panel cards AND the delivered power.
#
# A shaded panel makes less; nothing it loses moves to its neighbours. So the
# shade is applied ONCE, to SolarUI's array output: the array factor is the
# Wmp-weighted mean of the per-panel factors (each panel's own bypass diodes
# drop it out of the string rather than dragging the whole string down — the
# usual first-order model of partial shade). The panel cards then split what
# the array made by EFFECTIVE Wmp (wmp × factor), so they sum to it.
#
# A receiver is {wmp, group, pos, s}: its Wmp, the index of the controller cap
# it feeds (SolarUI _graph_dc_caps; -1 = unrouted), its world sample origin
# and the live factor the shading tick stamped. Unplaced PV is simply not a
# receiver — it counts as unshaded through `total_wmp`.
# ---------------------------------------------------------------------------

## Distinct sample origins ray-cast per instant for the batch render; beyond
## this the remaining receivers keep their live factor (a year bake is ~14k
## samples, so the ray count is what has to stay bounded).
const MAX_BAKE_ORIGINS := 48
## Origins closer than this share one ray (panels in one row).
const ORIGIN_MERGE_M := 0.5


## Array shade from per-receiver factors (parallel to `receivers`).
## Returns {factor, total_wmp, loss, loss_by_group} — `loss` in Wmp.
static func array_shade(receivers: Array, factors: Array, total_wmp: float) -> Dictionary:
	var t := maxf(total_wmp, 0.0)
	var loss := 0.0
	var by: Dictionary = {}
	for i in receivers.size():
		var r: Dictionary = receivers[i] as Dictionary
		var f := clampf(float(factors[i]) if i < factors.size() else 1.0, 0.0, 1.0)
		var l := maxf(float(r.get("wmp", 0.0)), 0.0) * (1.0 - f)
		if l <= 0.0:
			continue
		var g := int(r.get("group", -1))
		by[g] = float(by.get(g, 0.0)) + l
		loss += l
	loss = minf(loss, t)
	return {
		"factor": (t - loss) / t if t > 0.0 else 1.0,
		"total_wmp": t,
		"loss": loss,
		"loss_by_group": by,
	}


## Array shade from the live factors the shading tick stamped (receiver "s").
static func live_shade(receivers: Array, total_wmp: float) -> Dictionary:
	var f: Array = []
	for r in receivers:
		f.append(float((r as Dictionary).get("s", 1.0)))
	return array_shade(receivers, f, total_wmp)


## Per-controller caps re-shared for a shaded array. The caps' fracs are plain
## Wmp shares of the UNSHADED array; the raw output they multiply already
## carries the array factor, so each share becomes (frac·T − loss_g)/(T − loss)
## — a controller whose panels are in shade is offered less, one in the sun
## exactly its panels' output. The fracs still sum to one.
static func shaded_caps(caps: Array, unrouted_frac: float, shade: Dictionary) -> Dictionary:
	var t := float(shade.get("total_wmp", 0.0))
	var loss := float(shade.get("loss", 0.0))
	var eff := t - loss
	if shade.is_empty() or t <= 0.0 or loss <= 1e-9 or eff <= 1e-9:
		return {"caps": caps, "unrouted_frac": unrouted_frac}
	var by: Dictionary = shade.get("loss_by_group", {}) as Dictionary
	var out: Array = []
	for i in caps.size():
		var c: Dictionary = (caps[i] as Dictionary).duplicate()
		c["frac"] = maxf(float(c.get("frac", 0.0)) * t - float(by.get(i, 0.0)), 0.0) / eff
		out.append(c)
	var u := maxf(unrouted_frac * t - float(by.get(-1, 0.0)), 0.0) / eff
	return {"caps": out, "unrouted_frac": clampf(u, 0.0, 1.0)}


## Factors for every receiver at one sun direction (the batch render's path).
## Origins within ORIGIN_MERGE_M share a ray; past MAX_BAKE_ORIGINS distinct
## origins the rest keep their live "s". `intersect_fn(from, to)` as in
## shade_factor_at.
static func factors_at(receivers: Array, sun_dir: Vector3, intersect_fn: Callable) -> Array:
	var out: Array = []
	if sun_dir.y <= HORIZON_Y:
		for _r in receivers:
			out.append(CLEAR)
		return out
	var memo: Dictionary = {}
	for r in receivers:
		var rd: Dictionary = r as Dictionary
		var p: Variant = rd.get("pos", null)
		if not (p is Vector3):
			out.append(float(rd.get("s", 1.0)))
			continue
		var pos: Vector3 = p
		var key := Vector3i((pos / ORIGIN_MERGE_M).round())
		if memo.has(key):
			out.append(float(memo[key]))
			continue
		if memo.size() >= MAX_BAKE_ORIGINS:
			out.append(float(rd.get("s", 1.0)))
			continue
		var f := shade_factor_at(pos, sun_dir, intersect_fn)
		memo[key] = f
		out.append(f)
	return out

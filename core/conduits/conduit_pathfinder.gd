class_name ConduitPathfinder
extends RefCounted

## Clean auto-routing for conceptual (and other metro) conduits.
## - Ground plane at a stable reference height (not per-sample terrain zigzags)
## - Ortho + 45° with rounded elbows
## - Lane offsets so parallel runs fan into readable corridors
## - Optional AABB jogs around obstacle footprints

const LANE_SPACING_M := 0.45
const MAX_LANES := 10
const JOG_CLEARANCE_M := 0.6
const METRO_CLEARANCE_M := 0.08


## Stable lane index from a connection id (fallback when no packed map).
static func lane_index(conn_id: String) -> int:
	if conn_id.is_empty():
		return 0
	return absi(conn_id.hash()) % MAX_LANES


## Sequential corridor lanes grouped by polarity / resource — not raw hash scatter.
## Returns Dictionary conn_id -> lane int (0..MAX_LANES-1).
static func assign_lanes(model: GraphModel) -> Dictionary:
	var out: Dictionary = {}
	if model == null:
		return out
	var groups: Dictionary = {}  ## group_key -> Array[conn_id]
	for conn: Dictionary in model.connections:
		var cid := str(conn.get("id", ""))
		if cid.is_empty():
			continue
		var pol := str(conn.get("polarity", ""))
		var rk := str(conn.get("resource_kind", conn.get("kind", "")))
		var key := "%s|%s" % [pol, rk]
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(cid)
	for key: Variant in groups.keys():
		var ids: Array = groups[key] as Array
		ids.sort()
		for i: int in ids.size():
			out[str(ids[i])] = i % MAX_LANES
	return out


## Auto metro route. `obstacles` = Array of AABB in world space (XZ used).
## `extra_mids` = sparse user pins (already world-space); projected onto run plane.
static func auto_metro(a: Vector3, b: Vector3, ground_y_fn: Callable,
		lane_i: int = 0, obstacles: Array = [],
		clearance_m: float = METRO_CLEARANCE_M,
		extra_mids: Array = []) -> PackedVector3Array:
	if not ground_y_fn.is_valid():
		return ConduitOrthoRouter.route(a, b, extra_mids, true)
	var ya := float(ground_y_fn.call(a)) + clearance_m
	var yb := float(ground_y_fn.call(b)) + clearance_m
	# Shared plane — avoids jagged re-drape of every elbow sample on bumpy DEM.
	var y_run := (ya + yb) * 0.5
	var ga := Vector3(a.x, y_run, a.z)
	var gb := Vector3(b.x, y_run, b.z)
	var mids: Array = _lane_mids(ga, gb, lane_i)
	for em: Variant in extra_mids:
		if em is Vector3:
			var p: Vector3 = em as Vector3
			mids.append(Vector3(p.x, y_run, p.z))
	mids = _jog_around_obstacles(ga, gb, mids, obstacles)
	var packed := ConduitOrthoRouter.route(ga, gb, mids, true)
	var out := PackedVector3Array()
	if a.distance_to(Vector3(a.x, ya, a.z)) > 0.05:
		out.append(a)
		out.append(Vector3(a.x, ya, a.z))
	# Drop onto run plane, then rise.
	if out.is_empty() or out[out.size() - 1].distance_to(ga) > 0.02:
		out.append(ga)
	for i: int in range(1, packed.size() - 1):
		out.append(Vector3(packed[i].x, y_run, packed[i].z))
	out.append(gb)
	if b.distance_to(Vector3(b.x, yb, b.z)) > 0.05:
		out.append(Vector3(b.x, yb, b.z))
		out.append(b)
	elif out[out.size() - 1].distance_to(b) > 0.02:
		out.append(b)
	return _dedupe(out)


static func _lane_mids(ga: Vector3, gb: Vector3, lane_i: int) -> Array:
	var dx := gb.x - ga.x
	var dz := gb.z - ga.z
	var hz := Vector2(dx, dz)
	if hz.length() < 0.5:
		return []
	var dir := hz.normalized()
	var perp := Vector2(-dir.y, dir.x)
	# Center lanes around 0 so lane 0 is on-axis.
	var offset := (float(lane_i) - float(MAX_LANES - 1) * 0.5) * LANE_SPACING_M
	if absf(offset) < 0.01:
		return []
	# Two mid posts at 30% / 70% create a parallel corridor segment.
	var p1 := ga + Vector3(dir.x, 0, dir.y) * (hz.length() * 0.3) \
			+ Vector3(perp.x, 0, perp.y) * offset
	var p2 := ga + Vector3(dir.x, 0, dir.y) * (hz.length() * 0.7) \
			+ Vector3(perp.x, 0, perp.y) * offset
	p1.y = ga.y
	p2.y = ga.y
	return [p1, p2]


static func _jog_around_obstacles(ga: Vector3, gb: Vector3, mids: Array,
		obstacles: Array) -> Array:
	if obstacles.is_empty():
		return mids
	var out: Array = mids.duplicate()
	# If the straight XZ segment pierces an AABB, insert a side jog.
	for obs: Variant in obstacles:
		if not (obs is AABB):
			continue
		var box: AABB = obs as AABB
		var expanded := box.grow(JOG_CLEARANCE_M)
		if not _segment_hits_aabb_xz(ga, gb, expanded):
			continue
		var center := expanded.get_center()
		var dx := gb.x - ga.x
		var dz := gb.z - ga.z
		var dir := Vector2(dx, dz)
		if dir.length_squared() < 1e-6:
			continue
		dir = dir.normalized()
		var perp := Vector2(-dir.y, dir.x)
		# Jog to the nearer side of the box.
		var to_c := Vector2(center.x - ga.x, center.z - ga.z)
		var side := signf(to_c.dot(perp))
		if absf(side) < 0.1:
			side = 1.0
		var jog_dist := maxf(expanded.size.x, expanded.size.z) * 0.5 + JOG_CLEARANCE_M
		var jog := Vector3(center.x, ga.y, center.z) \
				+ Vector3(perp.x, 0, perp.y) * side * jog_dist
		out.append(jog)
	return out


static func _segment_hits_aabb_xz(a: Vector3, b: Vector3, box: AABB) -> bool:
	# Liang–Barsky-ish coarse test: sample midpoints.
	for t: float in [0.25, 0.5, 0.75]:
		var p := a.lerp(b, t)
		if p.x >= box.position.x and p.x <= box.position.x + box.size.x \
				and p.z >= box.position.z and p.z <= box.position.z + box.size.z:
			return true
	return false


static func _dedupe(pts: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.02:
			out.append(p)
	return out


## Collect rough world AABBs for placed props (footprint obstacles).
static func collect_prop_obstacles(main: Node, ignore_prop_ids: Array = []) -> Array:
	var out: Array = []
	if main == null:
		return out
	var ignore: Dictionary = {}
	for id: Variant in ignore_prop_ids:
		ignore[str(id)] = true
	# Soft type check — avoid hard PlacedProp dep for headless selftests.
	for node in main.find_children("*", "Node3D", true, false):
		if node == null:
			continue
		var scr: Script = node.get_script() as Script
		if scr == null:
			continue
		var path := str(scr.resource_path)
		if not path.ends_with("placed_prop.gd"):
			continue
		var pid := ""
		if node.has_meta("prop_id"):
			pid = str(node.get_meta("prop_id"))
		elif "prop_id" in node:
			pid = str(node.get("prop_id"))
		if ignore.has(pid):
			continue
		var model := node.get_node_or_null("ModelRoot") as Node3D
		var root: Node3D = model if model != null else (node as Node3D)
		var aabb := _mesh_aabb_world(root)
		if aabb.size.length_squared() < 0.01:
			continue
		# Skip absurdly large footprints (terrain shells / whole camps).
		if aabb.size.x > 40.0 or aabb.size.z > 40.0:
			continue
		aabb.position.y = -50.0
		aabb.size.y = 100.0
		out.append(aabb)
	return out


static func _mesh_aabb_world(root: Node3D) -> AABB:
	var acc := AABB()
	var any := false
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var local := mi.get_aabb()
		var world := mi.global_transform * local
		if not any:
			acc = world
			any = true
		else:
			acc = acc.merge(world)
	return acc if any else AABB()

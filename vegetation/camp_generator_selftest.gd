extends SceneTree

## Headless self-test for BrcCampGenerator candidate generation (the pure mask +
## scatter stage). Offline / deterministic — no network, no scene tree, no GLB.
## Run with:
##   godot --headless --path . --script vegetation/camp_generator_selftest.gd
## Exits 0 when all assertions pass, 1 otherwise.

const TerrainRoadFlattenRef := preload("res://core/terrain/terrain_road_flatten.gd")

const AREA_HALF := 1500.0
const EXTENT := 3000.0

var _failures := 0
var _checks := 0


func _initialize() -> void:
	var roads := _brc_like_roads()
	var buildings := [_square(Vector2(300.0, 0.0), 30.0)]

	_test_generates(roads, buildings)
	_test_determinism(roads, buildings)
	_test_exclusions(roads, buildings)
	_test_city_street_filter()
	_test_city_area_excludes_access()
	_test_city_area_crescent_tips()
	_test_sparse_rejected()
	_test_caps(roads, buildings)
	_test_build_node(roads, buildings)

	if _failures == 0:
		print("CAMP GENERATOR SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("CAMP GENERATOR SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


# ---------------------------------------------------------------------------

func _gen(roads: Array, buildings: Array, seed: int) -> Dictionary:
	return BrcCampGenerator.generate_candidates(
		roads, buildings, PackedFloat32Array(), 0, EXTENT, 0.0, AREA_HALF, seed)


func _test_generates(roads: Array, buildings: Array) -> void:
	var res := _gen(roads, buildings, 12345)
	var classes: Dictionary = res["classes"]
	var total := 0
	for k in classes.keys():
		total += (classes[k] as Array).size()
	_check("produces structures", total > 200, "got %d" % total)
	_check("produces glow lights", (res["glow"] as Array).size() > 0,
		"got %d" % (res["glow"] as Array).size())
	# Multiple component classes should appear.
	var nonempty := 0
	for k in classes.keys():
		if (classes[k] as Array).size() > 0:
			nonempty += 1
	_check("multiple classes used", nonempty >= 6, "got %d classes" % nonempty)


func _test_determinism(roads: Array, buildings: Array) -> void:
	var a := _gen(roads, buildings, 999)
	var b := _gen(roads, buildings, 999)
	var ca: Dictionary = a["classes"]
	var cb: Dictionary = b["classes"]
	var same := true
	for k in ca.keys():
		var la: Array = ca[k]
		var lb: Array = cb[k]
		if la.size() != lb.size():
			same = false
			break
		if la.size() > 0:
			if not la[0]["pos"].is_equal_approx(lb[0]["pos"]):
				same = false
				break
			if not la[0]["color"].is_equal_approx(lb[0]["color"]):
				same = false
				break
	_check("same seed → identical layout", same)

	var c := _gen(roads, buildings, 1000)
	var total_a := 0
	var total_c := 0
	for k in ca.keys():
		total_a += (ca[k] as Array).size()
	for k in (c["classes"] as Dictionary).keys():
		total_c += ((c["classes"] as Dictionary)[k] as Array).size()
	_check("different seed → different count or layout",
		total_a != total_c or not _first_pos(a).is_equal_approx(_first_pos(c)))


func _test_exclusions(roads: Array, buildings: Array) -> void:
	var res := _gen(roads, buildings, 42)
	var classes: Dictionary = res["classes"]
	var on_road := 0
	var in_building := 0
	var out_of_bounds := 0
	var checked := 0
	for k in classes.keys():
		for c in classes[k]:
			checked += 1
			var p2 := Vector2(c["pos"].x, c["pos"].z)
			if absf(p2.x) > AREA_HALF or absf(p2.y) > AREA_HALF:
				out_of_bounds += 1
			# "On road" = within the travelled corridor (centreline distance check —
			# exact and free of closed-ring polygon-seam artefacts).
			if _on_any_road(p2, roads):
				on_road += 1
			for b in buildings:
				if Geometry2D.is_point_in_polygon(p2, b["points"]):
					in_building += 1
					break
	_check("nothing placed on a road", on_road == 0, "%d of %d on road" % [on_road, checked])
	_check("nothing placed in a building", in_building == 0, "%d in building" % in_building)
	_check("everything within area bounds", out_of_bounds == 0, "%d oob" % out_of_bounds)


func _on_any_road(p: Vector2, roads: Array) -> bool:
	for r in roads:
		var hw := float(r["half_width_m"]) + BrcCampGenerator.ROAD_SHOULDER_M
		var pts: PackedVector2Array = r["points"]
		for i in range(pts.size() - 1):
			if _point_segment_dist(p, pts[i], pts[i + 1]) <= hw:
				return true
	return false


func _point_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-8:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _test_city_street_filter() -> void:
	var keep := {
		"points": _ring(300.0, 16),
		"half_width_m": 4.0,
		"highway_type": "residential",
		"tags": {"highway": "residential", "name": "Esplanade"},
	}
	var gate := {
		"points": PackedVector2Array([Vector2(0, 500), Vector2(0, 2800)]),
		"half_width_m": 5.0,
		"highway_type": "unclassified",
		"tags": {"highway": "unclassified", "name": "Gate Road"},
	}
	var service := {
		"points": PackedVector2Array([Vector2(800, 800), Vector2(1200, 800)]),
		"half_width_m": 3.0,
		"highway_type": "service",
		"tags": {"highway": "service", "name": "Airport Service"},
	}
	_check("keeps residential camp street", BrcCampGenerator.is_camp_block_street(keep))
	_check("drops Gate Road by name", not BrcCampGenerator.is_camp_block_street(gate))
	_check("drops service highway", not BrcCampGenerator.is_camp_block_street(service))
	var filtered := BrcCampGenerator.filter_camp_streets([keep, gate, service])
	_check("filter keeps only city street", filtered.size() == 1)


func _test_city_area_excludes_access() -> void:
	var roads := _brc_like_roads()
	# Access spur far outside the ring city.
	roads.append({
		"points": PackedVector2Array([Vector2(0, 700), Vector2(0, 2500)]),
		"half_width_m": 5.0,
		"highway_type": "unclassified",
		"tags": {"highway": "unclassified", "name": "Gate Road"},
	})
	var hull := BrcCampGenerator.compute_city_area(roads)
	_check("city hull non-empty", hull.size() >= 3)
	# Far gate endpoint must sit outside the clip hull.
	var far := Vector2(0, 2400)
	_check("Gate Road tip outside city hull",
		not Geometry2D.is_point_in_polygon(far, hull),
		"hull still contains far access point")
	# A mid-ring camp block point must remain inside.
	var inner := Vector2(400, 0)
	_check("ring city inside hull",
		Geometry2D.is_point_in_polygon(inner, hull))


func _test_city_area_crescent_tips() -> void:
	# Open-mouthed BRC (C-shape): tips must stay inside; desert past the closed
	# outer ring and the playa mouth must stay outside.
	var roads := _brc_crescent_roads()
	var poly := BrcCampGenerator.compute_city_area(roads)
	_check("crescent clip non-empty", poly.size() >= 4)
	# Slightly inset from the outer ring so chordal edges don't false-fail.
	var tip_a := Vector2(cos(deg_to_rad(-30.0)), sin(deg_to_rad(-30.0))) * 580.0
	var tip_b := Vector2(cos(deg_to_rad(210.0)), sin(deg_to_rad(210.0))) * 580.0
	_check("crescent tip A inside clip", Geometry2D.is_point_in_polygon(tip_a, poly),
		"tip_a=%s" % tip_a)
	_check("crescent tip B inside clip", Geometry2D.is_point_in_polygon(tip_b, poly),
		"tip_b=%s" % tip_b)
	# Closed-side mid-ring (north) stays inside.
	var mid := Vector2(0.0, 450.0)
	_check("crescent mid-ring inside", Geometry2D.is_point_in_polygon(mid, poly))
	# Beyond outer perimeter on the closed side.
	var beyond := Vector2(0.0, 900.0)
	_check("beyond outer ring outside clip",
		not Geometry2D.is_point_in_polygon(beyond, poly),
		"beyond still inside")
	# Open mouth / playa should be outside the annular sector polygon.
	var mouth := Vector2(0.0, -200.0)
	_check("open mouth outside clip",
		not Geometry2D.is_point_in_polygon(mouth, poly),
		"mouth still inside")


## Open-mouthed BRC: rings + radials on a 240° sector centred on +Y (open to −Y).
func _brc_crescent_roads() -> Array:
	var roads: Array = []
	var ang0 := deg_to_rad(-30.0)
	var ang1 := deg_to_rad(210.0)
	var r := 240.0
	while r <= 640.0:
		roads.append({
			"points": _arc(r, ang0, ang1, 48),
			"half_width_m": 4.0,
			"highway_type": "residential",
			"tags": {"highway": "residential"},
		})
		r += 25.0
	var inner := 240.0
	var outer := 640.0
	for i in 20:
		var t := float(i) / 19.0
		var ang := lerpf(ang0, ang1, t)
		var dir := Vector2(cos(ang), sin(ang))
		roads.append({
			"points": PackedVector2Array([dir * inner, dir * outer]),
			"half_width_m": 4.0,
			"highway_type": "residential",
			"tags": {"highway": "residential"},
		})
	return roads


func _test_sparse_rejected() -> void:
	# 3 small rings with 8 pts each = 24 total points < MIN_ROAD_SEGMENTS (150).
	var few: Array = []
	for i in 3:
		few.append({"points": _ring(200.0 + i * 40.0, 8), "half_width_m": 4.0})
	var pts := BrcCampGenerator.count_road_points(few)
	var res := BrcCampGenerator.generate_candidates(
		few, [], PackedFloat32Array(), 0, EXTENT, 0.0, AREA_HALF, 7)
	var total := 0
	for k in (res["classes"] as Dictionary).keys():
		total += ((res["classes"] as Dictionary)[k] as Array).size()
	_check("sparse road network is skipped (pts=%d)" % pts, total == 0, "got %d" % total)


func _test_caps(roads: Array, buildings: Array) -> void:
	var res := _gen(roads, buildings, 3)
	var total := 0
	for k in (res["classes"] as Dictionary).keys():
		total += ((res["classes"] as Dictionary)[k] as Array).size()
	var combined_cap := BrcCampGenerator.MAX_STRUCTURES + BrcCampGenerator.MAX_FILL_STRUCTURES
	_check("structure cap respected", total <= combined_cap,
		"got %d (cap=%d)" % [total, combined_cap])
	_check("glow cap respected",
		(res["glow"] as Array).size() <= BrcCampGenerator.MAX_GLOW)


## Exercises the live assembly path: GLB merge → per-class MultiMesh → glow
## MultiMesh → CampLightPool, including adding it to the tree (pool._ready).
func _test_build_node(roads: Array, buildings: Array) -> void:
	var profiles := {}
	for p in [
		"res://vegetation/camp_profile_shade_structure.tres",
		"res://vegetation/camp_profile_rv.tres",
		"res://vegetation/camp_profile_car.tres",
		"res://vegetation/camp_profile_popup_tent.tres",
		"res://vegetation/camp_profile_camping_tent.tres",
	]:
		var prof := load(p) as CampScatterProfile
		if prof != null:
			profiles[String(prof.class_id)] = prof
	var node := BrcCampGenerator.build_camps_node(
		roads, buildings, PackedFloat32Array(), 0, EXTENT, 0.0, AREA_HALF, 5,
		profiles, null)
	_check("build_camps_node returns a node", node != null)
	if node == null:
		return
	var mm_count := 0
	var has_glow := false
	var has_pool := false
	for child in node.get_children():
		if child is MultiMeshInstance3D:
			if child.name == "CampGlow_MM":
				has_glow = true
			else:
				mm_count += 1
				var mmi := child as MultiMeshInstance3D
				_check("class MultiMesh has a mesh", mmi.multimesh != null and mmi.multimesh.mesh != null,
					String(child.name))
		if child.name == "CampLightPool":
			has_pool = true
	_check("per-class MultiMeshInstances built", mm_count >= 6, "got %d" % mm_count)
	_check("glow MultiMesh built", has_glow)
	_check("light pool attached", has_pool)
	# Add to tree to trigger CampLightPool._ready (creates the OmniLight pool).
	get_root().add_child(node)
	var pool := node.get_node_or_null("CampLightPool")
	_check("pool spawned OmniLights", pool != null and pool.get_child_count() > 0)
	node.free()


# ---------------------------------------------------------------------------
# Synthetic Black-Rock-City-like street grid: concentric rings + radial avenues.
# ---------------------------------------------------------------------------

func _brc_like_roads() -> Array:
	var roads: Array = []
	# Concentric ring streets (Esplanade outward).
	var r := 240.0
	while r <= 640.0:
		roads.append({
			"points": _ring(r, 64),
			"half_width_m": 4.0,
			"highway_type": "residential",
			"tags": {"highway": "residential"},
		})
		r += 25.0
	# Radial avenues from inner to outer radius.
	var inner := 240.0
	var outer := 640.0
	for i in 24:
		var ang := TAU * float(i) / 24.0
		var dir := Vector2(cos(ang), sin(ang))
		roads.append({
			"points": PackedVector2Array([dir * inner, dir * outer]),
			"half_width_m": 4.0,
			"highway_type": "residential",
			"tags": {"highway": "residential"},
		})
	return roads


func _ring(radius: float, segments: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segments + 1:
		var a := TAU * float(i) / float(segments)
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts


func _arc(radius: float, ang0: float, ang1: float, segments: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in segments + 1:
		var t := float(i) / float(segments)
		var a := lerpf(ang0, ang1, t)
		pts.append(Vector2(cos(a), sin(a)) * radius)
	return pts


func _square(center: Vector2, size: float) -> Dictionary:
	var h := size * 0.5
	return {"points": PackedVector2Array([
		center + Vector2(-h, -h), center + Vector2(h, -h),
		center + Vector2(h, h), center + Vector2(-h, h),
	])}


func _first_pos(res: Dictionary) -> Vector3:
	for k in (res["classes"] as Dictionary).keys():
		var lst: Array = (res["classes"] as Dictionary)[k]
		if lst.size() > 0:
			return lst[0]["pos"]
	return Vector3.ZERO

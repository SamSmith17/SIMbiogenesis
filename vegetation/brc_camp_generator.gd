class_name BrcCampGenerator
extends RefCounted

## Procedurally repopulates the empty street blocks of a dense city grid (built
## for Black Rock City) with camp structures + colourful night lights.
##
## Strategy — a "mask-based scatter" that mirrors the project's existing
## MultiMesh patterns (BuildingBuilder / forest_zone_renderer / vegetation_scatter):
##   1. Rasterise a campable mask from the OSM road network + building footprints:
##      a cell is campable when it is NOT on a road corridor, NOT inside a building,
##      and lies within PLOT_DEPTH_M of some street (so the open central playa and
##      the surrounding desert stay empty without hardcoding BRC's radius).
##   2. Scatter reusable camp components into the mask on a jittered grid, each
##      aligned to the nearest street frontage, with a frontage→interior class bias
##      (shade structures / RVs line the street, tents fill the back).
##   3. Render one MultiMesh per component class (per-instance transform + colour)
##      plus one emissive "glow" MultiMesh for the night lights, fronted by a small
##      camera-following OmniLight pool (camp_light_pool.gd) for real illumination.
##
## `generate_candidates()` is pure + deterministic (seeded) so it is headless
## self-testable; `build_camps_node()` turns candidates into the scene subtree.

const TerrainBuilderRef := preload("res://core/terrain/terrain_builder.gd")
const CampLightPoolScene := preload("res://vegetation/camp_light_pool.gd")
const TINT_SHADER := preload("res://vegetation/camp_tint.gdshader")
const GLOW_SHADER := preload("res://vegetation/camp_glow.gdshader")

## Mask raster resolution. 4 m cells over a 3 km square ≈ 750² cells (~0.5 M).
const CELL_M := 4.0
## How far from a street a cell may still be camped. Confines fill to city blocks.
const PLOT_DEPTH_M := 60.0
## Extra buffer beyond a road's half-width so nothing sits in the travelled way.
const ROAD_SHOULDER_M := 1.5
## Distance (m) from a street under which a plot is "frontage" (shade/RV/cars).
const FRONTAGE_DEPTH_M := 14.0
## Jittered-grid placement step — average spacing between camp components.
const SCATTER_STEP_M := 6.0
## Default probability a campable grid node actually receives a component.
const FILL_PROBABILITY := 0.72
## Hard caps so a huge city can't blow the instance budget.
## BRC's full annular camp area has ~14 k eligible slots at 6 m step + 0.72 fill;
## raise the cap high enough that the shuffle (see generate_candidates) distributes
## evenly before hitting it, rather than cutting off the eastern half of the city.
const MAX_STRUCTURES := 15000
const MAX_GLOW := 12000
## Second fill pass: finer grid, cheap procedural-only types only.
const MAX_FILL_STRUCTURES := 22000
const FILL_SCATTER_STEP_M := 3.5
## Classes used exclusively in the lightweight fill pass (no GLB needed, very low poly).
const FILL_CLASSES := ["geodesic_dome", "shift_pod", "hexayurt"]
## A site needs at least this many total road *segment endpoints* across all road
## ways to be considered a dense city worth populating automatically.
## (BRC at 40 mapped ways × ~15 pts/way = ~600 pts — well above 150.)
## Use generate_candidates with an explicit clip_polygon to bypass this gate.
const MIN_ROAD_SEGMENTS := 150

## Highway types that seed camp corridors. Access / airport / service roads are
## excluded so Gate Road, runway spurs, and perimeter service tracks stay empty.
const CAMP_STREET_HIGHWAY_ALLOW := {
	"residential": true,
	"living_street": true,
	"unclassified": true,
	"tertiary": true,
	"tertiary_link": true,
	"pedestrian": true,
}
## Name substrings (lowercase) that mark non-city access even when tagged residential.
const CAMP_STREET_NAME_DENY := [
	"gate", "airport", "runway", "highway", "county", "access",
	"entrance", "exit", "service", "34", "playa road",
]

## Component classes the generator can place, with frontage vs interior weights.
## class_id matches the camp_profile_*.tres so dimensions/art are reused.
const CLASS_WEIGHTS := {
	"shade_structure": {"frontage": 4.0, "interior": 0.6},
	"rv": {"frontage": 2.6, "interior": 0.3},
	"car": {"frontage": 1.6, "interior": 0.4},
	"popup_tent": {"frontage": 1.0, "interior": 2.4},
	"camping_tent": {"frontage": 0.6, "interior": 3.0},
	"tarp": {"frontage": 1.4, "interior": 1.6},
	# Lightweight fill types — also appear in the main scatter.
	"shade_array": {"frontage": 2.5, "interior": 1.2},
	"geodesic_dome": {"frontage": 0.7, "interior": 2.6},
	"shift_pod": {"frontage": 0.5, "interior": 2.0},
	"hexayurt": {"frontage": 0.4, "interior": 3.2},
}

## Weights used exclusively in the fine-grid fill pass (lightweight types only).
const FILL_CLASS_WEIGHTS := {
	"geodesic_dome": {"frontage": 1.0, "interior": 2.5},
	"shift_pod": {"frontage": 0.8, "interior": 2.0},
	"hexayurt": {"frontage": 0.5, "interior": 3.0},
}

## Fallback footprints (X length, Y height, Z width) when no profile is supplied.
const FALLBACK_SIZE := {
	"shade_structure": Vector3(6.1, 3.0, 3.05),
	"rv": Vector3(8.5, 3.0, 2.6),
	"car": Vector3(4.5, 1.5, 1.8),
	"popup_tent": Vector3(3.05, 2.4, 3.05),
	"camping_tent": Vector3(2.2, 1.5, 2.2),
	"tarp": Vector3(5.0, 0.25, 4.0),
	# X=footprint width, Y used for positioning logic, Z=footprint depth.
	"shade_array": Vector3(10.0, 0.12, 10.0),   # flat black shade cloth panel at 2.1 m height
	"geodesic_dome": Vector3(4.0, 2.1, 4.0),    # white/silver hemisphere
	"shift_pod": Vector3(2.4, 2.5, 5.5),        # compact sleeping container pod
	"hexayurt": Vector3(4.2, 2.8, 4.2),         # reflective hexagonal yurt
}


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

## Count total road segment points (sum of pts.size() per road way).
## This is what MIN_ROAD_SEGMENTS is checked against — it avoids falsely
## rejecting BRC when it has many long polylines but few way-count entries.
static func count_road_points(roads: Array) -> int:
	var n := 0
	for r in roads:
		if r is Dictionary:
			n += (r.get("points", PackedVector2Array()) as PackedVector2Array).size()
	return n


## True when an OSM road should seed camp blocks (core city streets only).
## Roads with no highway tag are kept (synthetic / selftest grids).
static func is_camp_block_street(road: Dictionary) -> bool:
	var tags: Dictionary = road.get("tags", {}) as Dictionary
	var hw := str(road.get("highway_type", tags.get("highway", ""))).to_lower().strip_edges()
	if not hw.is_empty() and not CAMP_STREET_HIGHWAY_ALLOW.get(hw, false):
		return false
	var name := str(tags.get("name", "")).to_lower()
	if name.is_empty():
		name = str(road.get("name", "")).to_lower()
	for deny in CAMP_STREET_NAME_DENY:
		if deny in name:
			return false
	# Long, nearly-straight unclassified spurs (Gate Road style) even without a
	# matching name: drop if length ≫ chord and endpoints sit far from origin.
	var pts: PackedVector2Array = road.get("points", PackedVector2Array())
	if pts.size() >= 2 and (hw.is_empty() or hw == "unclassified" or hw == "tertiary"):
		var path_len := 0.0
		for i in range(pts.size() - 1):
			path_len += pts[i].distance_to(pts[i + 1])
		var chord := pts[0].distance_to(pts[pts.size() - 1])
		var mid_r := pts[pts.size() / 2].length()
		if path_len > 900.0 and chord > path_len * 0.85 and mid_r > 1400.0:
			return false
	return true


## Roads that define campable city blocks (drops Gate / airport / service).
static func filter_camp_streets(roads: Array) -> Array:
	var out: Array = []
	for r in roads:
		if r is Dictionary and is_camp_block_street(r as Dictionary):
			out.append(r)
	return out


## Clip polygon for the *city* road network (core streets only).
##
## BRC is a C-shaped annulus. A centroid + radial-percentile convex hull cuts the
## two open tips (they sit far from the mass centroid) and bulges past the outer
## ring on the closed side. Prefer an angle-binned annular-sector outline around
## the local origin (Man / map centre); fall back to an unfiltered convex hull.
##
## Algorithm:
##   1. Prefer camp-block streets (filter_camp_streets); fall back to all roads.
##   2. Try annular-sector polygon (outer arc + return along Esplanade).
##   3. Else convex-hull all city points and expand 4 %.
static func compute_city_area(roads: Array) -> PackedVector2Array:
	if roads.is_empty():
		return PackedVector2Array()
	var city := filter_camp_streets(roads)
	if count_road_points(city) < 40:
		city = roads
	var all_pts := PackedVector2Array()
	for r in city:
		if r is Dictionary:
			for p: Vector2 in (r.get("points", PackedVector2Array()) as PackedVector2Array):
				all_pts.append(p)
	if all_pts.size() < 3:
		return PackedVector2Array()

	var annular := _annular_city_polygon(all_pts)
	if annular.size() >= 4:
		return annular
	return _expanded_convex_hull(all_pts, 1.04)


## Angle-binned annulus / C-sector around the local origin. Empty when the
## street cloud is not organised as rings around (0,0).
static func _annular_city_polygon(pts: PackedVector2Array) -> PackedVector2Array:
	const BINS := 96
	const MIN_BIN_PTS := 2
	const MIN_ACTIVE_BINS := 24  # ≥ 90° of city arc
	const GAP_FILL_BINS := 2    # bridge tiny street gaps
	# Outer pad so the last ring lane + plot depth stay inside the clip.
	const OUTER_PAD := 1.10
	const INNER_PAD := 0.90

	var outer_r := PackedFloat32Array()
	var inner_r := PackedFloat32Array()
	var outer_ang := PackedFloat32Array()
	var inner_ang := PackedFloat32Array()
	var counts := PackedInt32Array()
	outer_r.resize(BINS)
	inner_r.resize(BINS)
	outer_ang.resize(BINS)
	inner_ang.resize(BINS)
	counts.resize(BINS)
	for i in BINS:
		outer_r[i] = -1.0
		inner_r[i] = 1.0e12
		outer_ang[i] = 0.0
		inner_ang[i] = 0.0
		counts[i] = 0

	var near_origin := 0
	for p in pts:
		var r := p.length()
		if r < 30.0:
			near_origin += 1
			continue
		var ang := atan2(p.y, p.x)
		var bin := int(floor((ang + PI) / TAU * float(BINS)))
		bin = clampi(bin, 0, BINS - 1)
		counts[bin] += 1
		if r >= outer_r[bin]:
			outer_r[bin] = r
			outer_ang[bin] = ang
		if r <= inner_r[bin]:
			inner_r[bin] = r
			inner_ang[bin] = ang

	# Streets must surround the map origin (Man); a blob far off-centre is not BRC.
	if near_origin > pts.size() / 3:
		return PackedVector2Array()

	var active := PackedByteArray()
	active.resize(BINS)
	var active_n := 0
	for i in BINS:
		active[i] = 1 if counts[i] >= MIN_BIN_PTS else 0
		if active[i] != 0:
			active_n += 1
	if active_n < MIN_ACTIVE_BINS:
		return PackedVector2Array()

	# Bridge one-bin gaps so a missing radial doesn't split the city arc.
	for _pass in GAP_FILL_BINS:
		var next := active.duplicate()
		for i in BINS:
			if active[i] != 0:
				continue
			var prev_i := (i - 1 + BINS) % BINS
			var next_i := (i + 1) % BINS
			if active[prev_i] != 0 and active[next_i] != 0:
				next[i] = 1
				outer_r[i] = 0.5 * (outer_r[prev_i] + outer_r[next_i])
				inner_r[i] = 0.5 * (inner_r[prev_i] + inner_r[next_i])
				outer_ang[i] = lerp_angle(outer_ang[prev_i], outer_ang[next_i], 0.5)
				inner_ang[i] = lerp_angle(inner_ang[prev_i], inner_ang[next_i], 0.5)
		active = next

	active_n = 0
	for i in BINS:
		if active[i] != 0:
			active_n += 1

	# Longest contiguous active run (handles wrap across ±π).
	var best_len := 0
	var best_start := 0
	if active_n >= BINS:
		best_len = BINS
		best_start = 0
	else:
		# Start scanning after an inactive bin so wrap-around arcs are one run.
		var gap := 0
		while gap < BINS and active[gap] != 0:
			gap += 1
		var scanned := 0
		while scanned < BINS:
			var idx := (gap + 1 + scanned) % BINS
			if active[idx] == 0:
				scanned += 1
				continue
			var length := 0
			while length < BINS and active[(idx + length) % BINS] != 0:
				length += 1
			if length > best_len:
				best_len = length
				best_start = idx
			scanned += maxi(length, 1)

	if best_len < MIN_ACTIVE_BINS:
		return PackedVector2Array()

	# Reject if the "city" is only a thin radial spike (not an annulus sector).
	var r_min := 1.0e12
	var r_max := 0.0
	for k in best_len:
		var b := (best_start + k) % BINS
		r_min = minf(r_min, inner_r[b])
		r_max = maxf(r_max, outer_r[b])
	if r_max < 80.0 or r_max - r_min < 40.0:
		return PackedVector2Array()

	var poly := PackedVector2Array()
	# Outer arc — use the true angle of each bin's farthest street point so tips
	# aren't cut by chordal bin-centre approximation.
	for k in best_len:
		var b := (best_start + k) % BINS
		var ang := outer_ang[b]
		poly.append(Vector2(cos(ang), sin(ang)) * outer_r[b] * OUTER_PAD)
	# Return along the inner (Esplanade) edge so the open mouth stays outside.
	for k in range(best_len - 1, -1, -1):
		var b2 := (best_start + k) % BINS
		var ang2 := inner_ang[b2]
		poly.append(Vector2(cos(ang2), sin(ang2)) * inner_r[b2] * INNER_PAD)
	return poly


static func _expanded_convex_hull(pts: PackedVector2Array, expand: float) -> PackedVector2Array:
	var hull := Geometry2D.convex_hull(pts)
	if hull.size() < 3:
		return hull
	var hull_c := Vector2.ZERO
	for p in hull:
		hull_c += p
	hull_c /= float(hull.size())
	var expanded := PackedVector2Array()
	for p in hull:
		expanded.append(hull_c + (p - hull_c) * expand)
	return expanded


# ---------------------------------------------------------------------------
# Public entry: build the whole "Camps" subtree from OSM vectors.
# ---------------------------------------------------------------------------

## roads / buildings: the OSM payload arrays (each item a Dictionary with a
## "points" PackedVector2Array in local metres; roads also carry "half_width_m").
## footing_grid / mesh_res / extent_m / center_elev: terrain height sampling.
## area_half_m: half-size of the square to populate (e.g. DETAIL_HALF_EXTENT).
## seed: deterministic seed (derive from lat/lon for cross-reload stability).
## profiles_by_id: { class_id(String): CampScatterProfile } for art/size reuse.
## clip_polygon: optional local-metre polygon; if non-empty only candidates inside
##   this polygon are placed (use BRC Auto area from the camp scatter UI).
## fill_probability / mix_bias / scale_min / scale_max: tuning knobs exposed via
##   the camp scatter UI.  mix_bias < 0 = shade/RV heavy; > 0 = tent heavy.
static func build_camps_node(roads: Array, buildings: Array,
		footing_grid: PackedFloat32Array, mesh_res: int, extent_m: float,
		center_elev: float, area_half_m: float, seed: int,
		profiles_by_id: Dictionary, main: Node = null,
		clip_polygon: PackedVector2Array = PackedVector2Array(),
		fill_probability: float = FILL_PROBABILITY,
		mix_bias: float = 0.0,
		scale_min: float = 0.9, scale_max: float = 1.18,
		light_density: float = 1.0,
		exclusion_radius_m: float = 0.0,
		plot_depth_m: float = PLOT_DEPTH_M,
		scatter_step_m: float = SCATTER_STEP_M,
		light_lod_m: float = -1.0,
		max_pool_lights: int = -1) -> Node3D:
	var candidates := generate_candidates(roads, buildings, footing_grid, mesh_res,
		extent_m, center_elev, area_half_m, seed,
		clip_polygon, fill_probability, mix_bias, scale_min, scale_max,
		light_density, exclusion_radius_m, plot_depth_m, scatter_step_m)
	var classes: Dictionary = candidates.get("classes", {})
	var glow: Array = candidates.get("glow", [])
	var stats: Dictionary = candidates.get("stats", {})

	var total := 0
	for cid in classes.keys():
		total += (classes[cid] as Array).size()
	if total == 0 and glow.is_empty():
		print("BrcCampGenerator: no candidates generated — stats=%s" % str(stats))
		return null

	var root := Node3D.new()
	root.name = "Camps"
	root.set_meta("stats", stats)

	var tint_mat := ShaderMaterial.new()
	tint_mat.shader = TINT_SHADER

	for class_id in classes.keys():
		var items: Array = classes[class_id]
		if items.is_empty():
			continue
		var profile: CampScatterProfile = profiles_by_id.get(class_id, null)
		var mesh_info := _class_mesh(String(class_id), profile, tint_mat)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = mesh_info["mesh"]
		mm.instance_count = items.size()
		for i in items.size():
			var c: Dictionary = items[i]
			var basis := Basis(Vector3.UP, float(c["yaw"])).scaled(
				Vector3.ONE * float(c["scale"]))
			mm.set_instance_transform(i, Transform3D(basis, c["pos"]))
			mm.set_instance_color(i, c["color"])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Class_%s_MM" % String(class_id)
		mmi.multimesh = mm
		if mesh_info["material"] != null:
			mmi.material_override = mesh_info["material"]
		root.add_child(mmi)

	# Night-light field: one emissive MultiMesh with per-instance random colours.
	var glow_mat: ShaderMaterial = null
	if not glow.is_empty():
		glow_mat = ShaderMaterial.new()
		glow_mat.shader = GLOW_SHADER
		var gmm := MultiMesh.new()
		gmm.transform_format = MultiMesh.TRANSFORM_3D
		gmm.use_colors = true
		gmm.mesh = _glow_mesh()
		gmm.instance_count = glow.size()
		for i in glow.size():
			var g: Dictionary = glow[i]
			gmm.set_instance_transform(i, Transform3D(Basis.IDENTITY, g["pos"]))
			gmm.set_instance_color(i, g["color"])
		var gmmi := MultiMeshInstance3D.new()
		gmmi.name = "CampGlow_MM"
		gmmi.multimesh = gmm
		gmmi.material_override = glow_mat
		gmmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(gmmi)

	# Real local illumination near the camera, synced to the glow field/day-night.
	var pool := CampLightPoolScene.new()
	pool.name = "CampLightPool"
	if light_lod_m > 0.0:
		pool.cull_radius_m = light_lod_m
	if max_pool_lights > 0:
		pool.max_lights = max_pool_lights
	root.add_child(pool)
	pool.setup(glow, glow_mat, main)

	return root


# ---------------------------------------------------------------------------
# Pure candidate generation (deterministic, headless self-testable).
# ---------------------------------------------------------------------------

static func generate_candidates(roads: Array, buildings: Array,
		footing_grid: PackedFloat32Array, mesh_res: int, extent_m: float,
		center_elev: float, area_half_m: float, seed: int,
		clip_polygon: PackedVector2Array = PackedVector2Array(),
		fill_probability: float = FILL_PROBABILITY,
		mix_bias: float = 0.0,
		scale_min: float = 0.9, scale_max: float = 1.18,
		light_density: float = 1.0,
		exclusion_radius_m: float = 0.0,
		plot_depth_m: float = PLOT_DEPTH_M,
		scatter_step_m: float = SCATTER_STEP_M) -> Dictionary:

	var road_pts := count_road_points(roads)
	var has_clip := clip_polygon.size() >= 3
	var empty := {"classes": {}, "glow": [], "stats": {
		"reason": "no_roads",
		"road_ways": roads.size() if roads != null else 0,
		"road_pts": road_pts,
		"has_clip": has_clip,
	}}
	# Gate on road segment density UNLESS the caller provides an explicit clip area
	# (camp scatter UI explicitly selecting an area bypasses the auto-gate).
	if (roads == null or road_pts < MIN_ROAD_SEGMENTS) and not has_clip:
		print("BrcCampGenerator: skipped — road_pts=%d < MIN=%d, has_clip=%s" % [
			road_pts, MIN_ROAD_SEGMENTS, str(has_clip)])
		return empty
	if area_half_m <= 0.0:
		return empty

	var cols := int(ceil(area_half_m * 2.0 / CELL_M))
	cols = maxi(cols, 2)
	var rows := cols
	var n := cols * rows

	# road = blocked + distance seed; block = building (blocked, not a seed).
	var road := PackedByteArray()
	road.resize(n)
	var block := PackedByteArray()
	block.resize(n)

	for r in roads:
		if not (r is Dictionary):
			continue
		var pts: PackedVector2Array = r.get("points", PackedVector2Array())
		if pts.size() < 2:
			continue
		var hw := float(r.get("half_width_m", 4.0)) + ROAD_SHOULDER_M + CELL_M
		_stamp_polyline(pts, hw, road, cols, rows, area_half_m)

	for b in buildings:
		if not (b is Dictionary):
			continue
		var bpts: PackedVector2Array = b.get("points", PackedVector2Array())
		if bpts.size() < 3:
			continue
		_rasterize_polygon(bpts, block, cols, rows, area_half_m)

	# Block the inner playa (open circle around the Man / Temple).
	# If the caller provides an explicit exclusion_radius_m (e.g. 0.5 miles = 804 m)
	# use that directly.  Otherwise fall back to auto-detection: find the minimum
	# distance from the local origin to any road point that is NOT an outlier highway
	# (applying the same 90th-percentile cutoff used by compute_city_area so stray
	# Nevada highways passing near the centre don't collapse inner_r to near zero).
	var playa_block_r := 0.0
	if exclusion_radius_m > 0.0:
		playa_block_r = exclusion_radius_m
	else:
		# Auto: gather distances from origin; filter to 90th pct to drop outlier roads.
		var all_dists: Array[float] = []
		for r in roads:
			if r is Dictionary:
				for p: Vector2 in (r.get("points", PackedVector2Array()) as PackedVector2Array):
					all_dists.append(p.length())
		if not all_dists.is_empty():
			all_dists.sort()
			var pct90 := all_dists[int(all_dists.size() * 0.90)]
			var inner_r := area_half_m
			for d in all_dists:
				if d <= pct90:
					inner_r = minf(inner_r, d)
			if inner_r < area_half_m * 0.6:
				playa_block_r = inner_r
	if playa_block_r > CELL_M * 2.0:
		_stamp_disc(0.0, 0.0, playa_block_r, block, cols, rows, area_half_m)

	var dist := _chamfer_distance(road, cols, rows)

	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# Build mix-biased weights from mix_bias (-1 = shade heavy, +1 = tent heavy).
	var biased_weights := _biased_weights(mix_bias)

	# -----------------------------------------------------------------------
	# Phase 1: collect ALL eligible candidate positions across the full area.
	# This decouples scanning from placement so the subsequent shuffle gives
	# uniform coverage before the MAX_STRUCTURES cap is applied — without the
	# shuffle the cap would cut off the eastern half of the city because the
	# column-major scan fills west→east and terminates mid-city.
	# -----------------------------------------------------------------------
	var plot_depth := maxf(plot_depth_m, CELL_M)
	var candidates: Array = []
	var step := maxf(scatter_step_m, 1.0)
	var gx := -area_half_m + step * 0.5
	while gx < area_half_m:
		var gz := -area_half_m + step * 0.5
		while gz < area_half_m:
			gz += step
			var px := gx + rng.randf_range(-step * 0.5, step * 0.5)
			var pz := gz + rng.randf_range(-step * 0.5, step * 0.5)

			# Optional clip polygon (BRC Auto or Lasso/Rect from scatter UI).
			if has_clip and not Geometry2D.is_point_in_polygon(Vector2(px, pz), clip_polygon):
				continue

			var col := int((px + area_half_m) / CELL_M)
			var rw := int((pz + area_half_m) / CELL_M)
			if col < 1 or col >= cols - 1 or rw < 1 or rw >= rows - 1:
				continue
			var idx := rw * cols + col
			if road[idx] != 0 or block[idx] != 0:
				continue
			var d := dist[idx]
			if d > plot_depth:
				continue

			# Street-facing orientation: perpendicular to chamfer distance gradient.
			var grad := _dist_gradient(dist, cols, rows, col, rw)
			var to_road := -grad
			var yaw := 0.0
			if to_road.length_squared() > 1e-6:
				var tangent := Vector2(-to_road.y, to_road.x)
				yaw = atan2(tangent.x, tangent.y)
			yaw += rng.randf_range(-0.14, 0.14)

			var ground_y := 0.0
			if not footing_grid.is_empty() and mesh_res > 1:
				ground_y = TerrainBuilderRef.height_at_world_xz(
					footing_grid, mesh_res, extent_m, center_elev, px, pz)

			candidates.append({
				"pos": Vector3(px, ground_y, pz),
				"yaw": yaw,
				"is_frontage": d <= FRONTAGE_DEPTH_M,
			})
		gx += step

	# -----------------------------------------------------------------------
	# Phase 2: Fisher-Yates shuffle so the cap samples evenly across the city.
	# -----------------------------------------------------------------------
	_rng_shuffle(candidates, rng)

	# -----------------------------------------------------------------------
	# Phase 3: apply fill probability + cap, then assign class / colour.
	# -----------------------------------------------------------------------
	var classes := {}
	for k in CLASS_WEIGHTS.keys():
		classes[k] = []
	var glow: Array = []
	var structure_count := 0

	for cand in candidates:
		if structure_count >= MAX_STRUCTURES:
			break
		if rng.randf() > fill_probability:
			continue
		var is_frontage: bool = cand["is_frontage"]
		var class_id := _pick_class_biased(rng, is_frontage, biased_weights)
		var sc := rng.randf_range(scale_min, scale_max)
		var pos: Vector3 = cand["pos"]
		classes[class_id].append({
			"pos": pos,
			"yaw": cand["yaw"],
			"scale": sc,
			"color": _class_color(class_id, rng),
		})
		structure_count += 1

		# A fraction of camps carry a coloured night light atop the structure.
		if glow.size() < MAX_GLOW and rng.randf() < (0.5 * light_density):
			var csize: Vector3 = FALLBACK_SIZE[class_id]
			var h := csize.y * sc
			glow.append({
				"pos": pos + Vector3(0.0, h + rng.randf_range(0.2, 1.4), 0.0),
				"color": Color.from_hsv(rng.randf(), rng.randf_range(0.7, 1.0), 1.0),
			})

	# -----------------------------------------------------------------------
	# Phase 4: Lightweight fill pass — finer 3.5 m grid, cheap geometry only.
	# Uses a separate RNG stream so the main layout is unaffected by adding or
	# removing fill types.  The fill classes have very low polygon counts
	# (≤24 tris each) so 22 k extra instances costs less than 5 k heavy ones.
	# -----------------------------------------------------------------------
	var fill_rng := RandomNumberGenerator.new()
	fill_rng.seed = seed ^ 0x5A5A5A5A

	var fill_cands: Array = []
	var fstep := FILL_SCATTER_STEP_M
	var fgx := -area_half_m + fstep * 0.5
	while fgx < area_half_m:
		var fgz := -area_half_m + fstep * 0.5
		while fgz < area_half_m:
			fgz += fstep
			var fpx := fgx + fill_rng.randf_range(-fstep * 0.5, fstep * 0.5)
			var fpz := fgz + fill_rng.randf_range(-fstep * 0.5, fstep * 0.5)
			if has_clip and not Geometry2D.is_point_in_polygon(Vector2(fpx, fpz), clip_polygon):
				continue
			var fcol := int((fpx + area_half_m) / CELL_M)
			var frw := int((fpz + area_half_m) / CELL_M)
			if fcol < 1 or fcol >= cols - 1 or frw < 1 or frw >= rows - 1:
				continue
			var fidx := frw * cols + fcol
			if road[fidx] != 0 or block[fidx] != 0:
				continue
			if dist[fidx] > plot_depth:
				continue
			var fgy := 0.0
			if not footing_grid.is_empty() and mesh_res > 1:
				fgy = TerrainBuilderRef.height_at_world_xz(
					footing_grid, mesh_res, extent_m, center_elev, fpx, fpz)
			fill_cands.append({
				"pos": Vector3(fpx, fgy, fpz),
				"is_frontage": dist[fidx] <= FRONTAGE_DEPTH_M,
			})
		fgx += fstep

	_rng_shuffle(fill_cands, fill_rng)

	var fill_count := 0
	for fcand in fill_cands:
		if fill_count >= MAX_FILL_STRUCTURES:
			break
		if fill_rng.randf() > 0.48:
			continue
		var fis_front: bool = fcand["is_frontage"]
		var fcid := _pick_class_biased(fill_rng, fis_front, FILL_CLASS_WEIGHTS)
		var fsc := fill_rng.randf_range(0.85, 1.15)
		var fpos: Vector3 = fcand["pos"]
		var fyaw := fill_rng.randf() * TAU
		classes[fcid].append({
			"pos": fpos,
			"yaw": fyaw,
			"scale": fsc,
			"color": _class_color(fcid, fill_rng),
		})
		fill_count += 1
		if glow.size() < MAX_GLOW and fill_rng.randf() < 0.25:
			var fcsize: Vector3 = FALLBACK_SIZE[fcid]
			glow.append({
				"pos": fpos + Vector3(0.0, fcsize.y * fsc + fill_rng.randf_range(0.1, 0.6), 0.0),
				"color": Color.from_hsv(fill_rng.randf(), fill_rng.randf_range(0.6, 1.0), 1.0),
			})

	# Tally per-class counts for reporting.
	var class_counts := {}
	for cid in classes.keys():
		class_counts[cid] = (classes[cid] as Array).size()

	print("BrcCampGenerator: placed %d structures + %d fill, %d glow pts (road_pts=%d, seed=%d)" % [
		structure_count, fill_count, glow.size(), road_pts, seed])

	return {
		"classes": classes,
		"glow": glow,
		"stats": {
			"cells": n, "cols": cols, "structures": structure_count,
			"glow": glow.size(), "road_pts": road_pts,
			"class_counts": class_counts,
		},
	}


# ---------------------------------------------------------------------------
# Mask rasterisation + distance transform
# ---------------------------------------------------------------------------

## Mark every mask cell within `radius` m of a polyline (road centreline).
static func _stamp_polyline(pts: PackedVector2Array, radius: float,
		mask: PackedByteArray, cols: int, rows: int, area_half: float) -> void:
	var stepd := CELL_M * 0.5
	for i in range(pts.size() - 1):
		var a := pts[i]
		var b := pts[i + 1]
		var seg := b - a
		var len := seg.length()
		_stamp_disc(a.x, a.y, radius, mask, cols, rows, area_half)
		if len < 1e-4:
			continue
		var dir := seg / len
		var t := stepd
		while t < len:
			var p := a + dir * t
			_stamp_disc(p.x, p.y, radius, mask, cols, rows, area_half)
			t += stepd
	if pts.size() > 0:
		var last := pts[pts.size() - 1]
		_stamp_disc(last.x, last.y, radius, mask, cols, rows, area_half)


static func _stamp_disc(cx: float, cz: float, radius: float,
		mask: PackedByteArray, cols: int, rows: int, area_half: float) -> void:
	var c0 := clampi(int((cx - radius + area_half) / CELL_M), 0, cols - 1)
	var c1 := clampi(int((cx + radius + area_half) / CELL_M), 0, cols - 1)
	var r0 := clampi(int((cz - radius + area_half) / CELL_M), 0, rows - 1)
	var r1 := clampi(int((cz + radius + area_half) / CELL_M), 0, rows - 1)
	var r2 := radius * radius
	for rw in range(r0, r1 + 1):
		var wz := -area_half + (rw + 0.5) * CELL_M
		for col in range(c0, c1 + 1):
			var wx := -area_half + (col + 0.5) * CELL_M
			var dx := wx - cx
			var dz := wz - cz
			if dx * dx + dz * dz <= r2:
				mask[rw * cols + col] = 1


static func _rasterize_polygon(poly: PackedVector2Array, mask: PackedByteArray,
		cols: int, rows: int, area_half: float) -> void:
	if poly.size() < 3:
		return
	var min_x := INF
	var min_z := INF
	var max_x := -INF
	var max_z := -INF
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	var c0 := clampi(int((min_x + area_half) / CELL_M), 0, cols - 1)
	var c1 := clampi(int((max_x + area_half) / CELL_M), 0, cols - 1)
	var r0 := clampi(int((min_z + area_half) / CELL_M), 0, rows - 1)
	var r1 := clampi(int((max_z + area_half) / CELL_M), 0, rows - 1)
	for rw in range(r0, r1 + 1):
		var cz := -area_half + (rw + 0.5) * CELL_M
		for col in range(c0, c1 + 1):
			var cx := -area_half + (col + 0.5) * CELL_M
			if Geometry2D.is_point_in_polygon(Vector2(cx, cz), poly):
				mask[rw * cols + col] = 1


## Two-pass chamfer distance (metres) from every seed (road) cell.
static func _chamfer_distance(seeds: PackedByteArray, cols: int, rows: int) -> PackedFloat32Array:
	var big := 1.0e9
	var dist := PackedFloat32Array()
	dist.resize(cols * rows)
	for i in dist.size():
		dist[i] = 0.0 if seeds[i] != 0 else big
	var ortho := CELL_M
	var diag := CELL_M * 1.4142135
	# Forward pass.
	for rw in range(rows):
		for col in range(cols):
			var i := rw * cols + col
			var best := dist[i]
			if col > 0:
				best = minf(best, dist[i - 1] + ortho)
			if rw > 0:
				best = minf(best, dist[i - cols] + ortho)
				if col > 0:
					best = minf(best, dist[i - cols - 1] + diag)
				if col < cols - 1:
					best = minf(best, dist[i - cols + 1] + diag)
			dist[i] = best
	# Backward pass.
	for rw in range(rows - 1, -1, -1):
		for col in range(cols - 1, -1, -1):
			var i := rw * cols + col
			var best := dist[i]
			if col < cols - 1:
				best = minf(best, dist[i + 1] + ortho)
			if rw < rows - 1:
				best = minf(best, dist[i + cols] + ortho)
				if col < cols - 1:
					best = minf(best, dist[i + cols + 1] + diag)
				if col > 0:
					best = minf(best, dist[i + cols - 1] + diag)
			dist[i] = best
	return dist


static func _dist_gradient(dist: PackedFloat32Array, cols: int, rows: int,
		col: int, rw: int) -> Vector2:
	var i := rw * cols + col
	var dx := dist[i + 1] - dist[i - 1]
	var dz := dist[i + cols] - dist[i - cols]
	return Vector2(dx, dz)


# ---------------------------------------------------------------------------
# Class / colour / weight selection
# ---------------------------------------------------------------------------

## In-place Fisher-Yates shuffle using the seeded RNG.
static func _rng_shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## Build mix-biased weight tables from mix_bias (-1 shade heavy, +1 tent heavy).
static func _biased_weights(mix_bias: float) -> Dictionary:
	var b := clampf(mix_bias, -1.0, 1.0)
	# Shade/RV classes get a boost at negative bias, tent classes at positive bias.
	var out := {}
	for cid in CLASS_WEIGHTS.keys():
		var fw: float = CLASS_WEIGHTS[cid]["frontage"]
		var iw: float = CLASS_WEIGHTS[cid]["interior"]
		match cid:
			"shade_structure", "rv", "car", "shade_array":
				fw *= 1.0 + maxf(-b, 0.0) * 2.5
				iw *= 1.0 + maxf(-b, 0.0) * 2.5
			"popup_tent", "camping_tent", "tarp", "geodesic_dome", "shift_pod", "hexayurt":
				fw *= 1.0 + maxf(b, 0.0) * 2.5
				iw *= 1.0 + maxf(b, 0.0) * 2.5
		out[cid] = {"frontage": fw, "interior": iw}
	return out


static func _pick_class(rng: RandomNumberGenerator, frontage: bool) -> String:
	return _pick_class_biased(rng, frontage, CLASS_WEIGHTS)


static func _pick_class_biased(rng: RandomNumberGenerator, frontage: bool,
		weights: Dictionary) -> String:
	var key := "frontage" if frontage else "interior"
	var total := 0.0
	for c in weights.keys():
		total += float(weights[c][key])
	var r := rng.randf() * total
	for c in weights.keys():
		r -= float(weights[c][key])
		if r <= 0.0:
			return c
	return "tarp"


static func _class_color(class_id: String, rng: RandomNumberGenerator) -> Color:
	match class_id:
		"rv":
			var g := rng.randf_range(0.78, 0.95)
			return Color(g, g, g * rng.randf_range(0.97, 1.0))
		"car":
			var v := rng.randf_range(0.18, 0.55)
			return Color(v, v, v * rng.randf_range(1.0, 1.2))
		"shade_structure":
			# Mostly tan/white shade cloth, occasionally a bright tarp.
			if rng.randf() < 0.7:
				return Color(rng.randf_range(0.78, 0.95),
					rng.randf_range(0.74, 0.9), rng.randf_range(0.6, 0.78))
			return Color.from_hsv(rng.randf(), rng.randf_range(0.4, 0.7), 0.85)
		"shade_array":
			# Near-black shade cloth — very dark, slight warm cast.
			var v := rng.randf_range(0.03, 0.10)
			return Color(v, v * rng.randf_range(0.9, 1.0), v * rng.randf_range(0.8, 0.95))
		"geodesic_dome":
			# White/silver aluminium geodesic — occasionally bright-painted.
			if rng.randf() < 0.75:
				var g := rng.randf_range(0.80, 0.96)
				return Color(g, g, g)
			return Color.from_hsv(rng.randf(), rng.randf_range(0.4, 0.7), 0.90)
		"shift_pod":
			# Metallic white/silver sleeping pod.
			var g := rng.randf_range(0.75, 0.95)
			return Color(g, g * rng.randf_range(0.97, 1.0), g * rng.randf_range(0.95, 1.0))
		"hexayurt":
			# Mylar/aluminised foil — very bright reflective silver.
			var g := rng.randf_range(0.85, 1.0)
			return Color(g, g * rng.randf_range(0.95, 1.0), g * rng.randf_range(0.90, 0.98))
		_:
			# Tents / tarps: vivid playa colours.
			return Color.from_hsv(rng.randf(), rng.randf_range(0.45, 0.85),
				rng.randf_range(0.7, 0.95))


# ---------------------------------------------------------------------------
# Mesh library (GLB reuse with procedural fallback)
# ---------------------------------------------------------------------------

## Returns {"mesh": Mesh, "material": Material|null}. When the profile points at a
## camp-component GLB we merge it (keeping its own textured materials, material =
## null). Otherwise we build simple tinted geometry that honours the per-instance
## MultiMesh colour via `tint_mat`.
static func _class_mesh(class_id: String, profile: CampScatterProfile,
		tint_mat: ShaderMaterial) -> Dictionary:
	if profile != null and profile.scene != null:
		var merged := _merge_scene_mesh(profile.scene)
		if merged != null:
			return {"mesh": merged, "material": null}
	var size: Vector3 = FALLBACK_SIZE.get(class_id, Vector3(3, 2.5, 3))
	if profile != null and profile.fallback_size.length_squared() > 0.01:
		size = profile.fallback_size
	return {"mesh": _procedural_mesh(class_id, size), "material": tint_mat}


## Bake a GLB prop into a single multi-surface ArrayMesh usable by one MultiMesh,
## preserving each surface's UVs and textured material (so the camp props keep
## their art) and baking each MeshInstance3D's node transform into the vertices.
static func _merge_scene_mesh(packed: PackedScene) -> ArrayMesh:
	var inst := packed.instantiate()
	if inst == null:
		return null
	var out := ArrayMesh.new()
	var stack: Array = [inst]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D) or (node as MeshInstance3D).mesh == null:
			continue
		var mi := node as MeshInstance3D
		var xf := _local_to_root_xform(mi, inst)
		var basis := xf.basis
		var m := mi.mesh
		for s in m.get_surface_count():
			if m.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var arr := m.surface_get_arrays(s)
			if arr.is_empty():
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			if verts == null or verts.is_empty():
				continue
			var nv := PackedVector3Array()
			nv.resize(verts.size())
			for vi in verts.size():
				nv[vi] = xf * verts[vi]
			arr[Mesh.ARRAY_VERTEX] = nv
			var normals = arr[Mesh.ARRAY_NORMAL]
			if normals != null and (normals as PackedVector3Array).size() == verts.size():
				var nn := PackedVector3Array()
				nn.resize(normals.size())
				for ni in normals.size():
					nn[ni] = (basis * normals[ni]).normalized()
				arr[Mesh.ARRAY_NORMAL] = nn
			var surf := out.get_surface_count()
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			var mat := m.surface_get_material(s)
			if mat == null:
				mat = mi.get_surface_override_material(s)
			if mat != null:
				out.surface_set_material(surf, mat)
	inst.free()
	if out.get_surface_count() == 0:
		return null
	return out


static func _local_to_root_xform(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != root.get_parent():
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		if cur == root:
			break
		cur = cur.get_parent()
	return xf


## Simple impressionistic geometry per class — enough to read as a camp at city
## scale, tinted per-instance. Base sits at y = 0 so it rests on the ground.
static func _procedural_mesh(class_id: String, size: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	match class_id:
		"shade_structure":
			# Flat canopy on four thin legs.
			var top := size.y
			_add_box(st, Vector3(0, top - 0.1, 0), Vector3(size.x, 0.18, size.z))
			var lx := size.x * 0.5 - 0.15
			var lz := size.z * 0.5 - 0.15
			for sx: float in [-lx, lx]:
				for sz: float in [-lz, lz]:
					_add_box(st, Vector3(sx, top * 0.5, sz),
						Vector3(0.12, top, 0.12))
		"tarp":
			_add_box(st, Vector3(0, size.y, 0), Vector3(size.x, 0.12, size.z))
			_add_box(st, Vector3(0, size.y * 0.5, 0), Vector3(0.1, size.y, 0.1))
		"camping_tent", "popup_tent":
			_add_pyramid(st, size)
		"shade_array":
			# Flat shade-cloth panel at ~2.1 m above ground — no poles for perf.
			# size.x / size.z = footprint; size.y = panel thickness.
			_add_box(st, Vector3(0, 2.1, 0), Vector3(size.x, size.y, size.z))
		"geodesic_dome":
			# Two-ring hemisphere: 24 triangles.
			_add_dome(st, size.x * 0.5, size.y)
		"shift_pod":
			# Compact rectangular sleeping pod, same box as RV but smaller.
			_add_box(st, Vector3(0, size.y * 0.5, 0), size)
		"hexayurt":
			# Hexagonal prism body (65 % of height) + hexagonal pyramid top.
			_add_hexprism(st, size.x * 0.5, size.y * 0.65, size.y)
		_:
			# RV / car / generic: a simple rounded body box.
			_add_box(st, Vector3(0, size.y * 0.5, 0), size)
	st.generate_normals()
	return st.commit()


## Low-poly hemisphere: 2 latitude rings → 8 segs → 24 triangles total.
static func _add_dome(st: SurfaceTool, radius: float, height: float) -> void:
	const SEGS := 8
	# Ring parameters: [y_fraction_of_height, radius_fraction].
	var rings := [
		[0.0, 1.0],
		[0.55, 0.65],
		[1.0, 0.0],
	]
	for ri in range(rings.size() - 1):
		var y0 := height * float(rings[ri][0])
		var r0 := radius * float(rings[ri][1])
		var y1 := height * float(rings[ri + 1][0])
		var r1 := radius * float(rings[ri + 1][1])
		for seg in SEGS:
			var a0 := TAU * float(seg) / float(SEGS)
			var a1 := TAU * float(seg + 1) / float(SEGS)
			var v00 := Vector3(cos(a0) * r0, y0, sin(a0) * r0)
			var v10 := Vector3(cos(a1) * r0, y0, sin(a1) * r0)
			var v01 := Vector3(cos(a0) * r1, y1, sin(a0) * r1)
			var v11 := Vector3(cos(a1) * r1, y1, sin(a1) * r1)
			if r1 < 0.01:
				_add_tri(st, v00, v10, Vector3(0.0, y1, 0.0))
			else:
				_add_tri(st, v00, v10, v11)
				_add_tri(st, v00, v11, v01)


## Hexagonal prism up to body_h + hexagonal pyramid apex to total_h → ~22 triangles.
static func _add_hexprism(st: SurfaceTool, radius: float,
		body_h: float, total_h: float) -> void:
	const S := 6
	for i in S:
		var a0 := TAU * float(i) / float(S)
		var a1 := TAU * float(i + 1) / float(S)
		var p00 := Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p10 := Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		var p01 := Vector3(cos(a0) * radius, body_h, sin(a0) * radius)
		var p11 := Vector3(cos(a1) * radius, body_h, sin(a1) * radius)
		_add_quad(st, p00, p10, p11, p01)
	# Roof pyramid.
	for i in S:
		var a0 := TAU * float(i) / float(S)
		var a1 := TAU * float(i + 1) / float(S)
		_add_tri(st,
			Vector3(cos(a0) * radius, body_h, sin(a0) * radius),
			Vector3(cos(a1) * radius, body_h, sin(a1) * radius),
			Vector3(0.0, total_h, 0.0))
	# Floor fan.
	var base0 := Vector3(radius, 0.0, 0.0)
	for i in range(1, S - 1):
		var a1 := TAU * float(i) / float(S)
		var a2 := TAU * float(i + 1) / float(S)
		_add_tri(st, base0,
			Vector3(cos(a1) * radius, 0.0, sin(a1) * radius),
			Vector3(cos(a2) * radius, 0.0, sin(a2) * radius))


static func _add_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	var corners := [
		center + Vector3(-h.x, -h.y, -h.z), center + Vector3(h.x, -h.y, -h.z),
		center + Vector3(h.x, -h.y, h.z), center + Vector3(-h.x, -h.y, h.z),
		center + Vector3(-h.x, h.y, -h.z), center + Vector3(h.x, h.y, -h.z),
		center + Vector3(h.x, h.y, h.z), center + Vector3(-h.x, h.y, h.z),
	]
	var faces := [
		[0, 1, 2, 3], [7, 6, 5, 4], [4, 5, 1, 0],
		[6, 7, 3, 2], [5, 6, 2, 1], [7, 4, 0, 3],
	]
	for f in faces:
		_add_quad(st, corners[f[0]], corners[f[1]], corners[f[2]], corners[f[3]])


static func _add_pyramid(st: SurfaceTool, size: Vector3) -> void:
	var hx := size.x * 0.5
	var hz := size.z * 0.5
	var apex := Vector3(0, size.y, 0)
	var a := Vector3(-hx, 0, -hz)
	var b := Vector3(hx, 0, -hz)
	var c := Vector3(hx, 0, hz)
	var d := Vector3(-hx, 0, hz)
	_add_tri(st, a, b, apex)
	_add_tri(st, b, c, apex)
	_add_tri(st, c, d, apex)
	_add_tri(st, d, a, apex)
	_add_quad(st, d, c, b, a)


static func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_tri(st, a, b, c)
	_add_tri(st, a, c, d)


static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_color(Color.WHITE)
	st.add_vertex(a)
	st.set_color(Color.WHITE)
	st.add_vertex(b)
	st.set_color(Color.WHITE)
	st.add_vertex(c)


## Unit card for an emissive light marker. camp_glow.gdshader billboards it
## toward the camera and enforces a minimum on-screen size, so a single quad is
## all that's needed (size/orientation are computed in the vertex stage).
static func _glow_mesh() -> Mesh:
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	return q

class_name CampLayoutGenerator
extends RefCounted

## Fills one painted camp area with households of tents, shade and vehicles.
## Pure and deterministic: (area record, ctx) -> instances. No scene access.
##
## Why it is not the BrcCampGenerator scatter:
##   * It needs NO roads. BRC's mask places a structure only within `plot_depth`
##     of an OSM street, so a polygon over a meadow got nothing.
##   * It places HOUSEHOLDS (CampStyles.TEMPLATES) with real footprints, so a
##     9 m RV and a 2 m tent no longer share one 6 m grid cell.
##   * Vehicles park ALIGNED — the camp heading, or its reverse (one choice per
##     row), +/- `align_jitter_deg`. People park square to their neighbours.
##
## THE LATTICE IS ANCHORED TO THE WORLD, and every cell is seeded from
## hash(seed, cell) rather than from a running RNG. A household's position, mix
## and jitter therefore depend only on (seed, heading, style, density, cell) —
## never on the polygon. Brushing a camp bigger adds households in the new
## cells and leaves every existing one exactly where it stood. A sequential RNG
## would reshuffle the whole camp on every stroke. Selftest-pinned.
##
## PLOTS are the exception. A record with a `group_id` is one plot of a
## subdivided zone: small, rectangular, already ringed by lanes. A world lattice
## straddles its edges and wastes most of it, so a plot fits its lattice to its
## OWN extent (no inner lane, cells stretched to share the leftover space).
##
## ctx (all optional):
##   ground_y_at: Callable(x, z) -> float   (default: flat 0)
##   roads: Array of {points: PackedVector2Array}  (auto heading only)
##   is_excluded: Callable(Vector2) -> bool  (buildings / roads / water)
##   map_styles: {style_id: entry}  (this map's per-style edits)
##   flatten: bool  (studio preview: test against the real ground, draw on y = 0)
##
## The record may carry `variant` (a named layout of its style), a
## `style_override` entry of its own, and `edits`: {key: {yaw_deg, scale,
## removed}} — the player's hand edits to single elements, keyed by the lattice
## cell + item index ("i:row:k") that every emitted item reports as `key`.
## Edits are applied AFTER the placement tests, on purpose: turning an RV is
## the player's decision, and it must not make that RV fail a test and vanish.

## Clearance kept between a footprint and the camp boundary.
const EDGE_MARGIN_M := 0.75
## A road this close to the camp sets its heading.
const ROAD_ALIGN_DIST_M := 40.0
## Per-area cap; an area is at most 90 000 m2, so this is a backstop only.
const MAX_STRUCTURES_PER_AREA := 6000
## Scale ranges. Rigid things barely vary; tents come in every size.
const ALIGNED_SCALE := Vector2(0.96, 1.04)
const LOOSE_SCALE := Vector2(0.88, 1.08)
## Base chance a structure carries a night light (x light_density).
const GLOW_CHANCE := 0.5
## Step for the central-difference slope sample.
const SLOPE_STEP_M := 2.0


## Returns {classes: {cls: [{pos, yaw, scale, color, up}]}, glow: [{pos, color}],
##          footprints: [{cls, center, half, angle, row}], stats: {...}}.
## `yaw` is the Y rotation to apply (Basis(UP, yaw)); `angle` in a footprint is
## the XZ-plane direction of its long axis, radians.
static func generate(area: Dictionary, ctx: Dictionary = {}) -> Dictionary:
	var classes: Dictionary = {}
	var glow: Array = []
	var footprints: Array = []
	var stats := {"structures": 0, "households": 0, "cells": 0, "heading_deg": 0.0,
		"rejected_edge": 0, "rejected_slope": 0, "rejected_excluded": 0,
		"rejected_overlap": 0}
	var out := {"classes": classes, "glow": glow, "footprints": footprints, "stats": stats}

	var poly: PackedVector2Array = area.get("polygon", PackedVector2Array())
	if poly.size() < 3:
		return out
	var holes: Array = area.get("holes", [])
	var style := CampStyles.style_for_area(area, ctx.get("map_styles", {}))
	var edits: Dictionary = area.get("edits", {})
	var flatten := bool(ctx.get("flatten", false))
	var pos_jitter := float(style["pos_jitter"])
	var loose_jitter := float(style["loose_jitter_deg"])
	var scale_var := float(style["scale_var"])
	var max_scale := float(style["max_scale"])
	var seed := int(area.get("seed", 0)) & 0x7fffffff
	var density := clampf(float(area.get("density", 0.8)), 0.2, 1.0)
	var jitter_deg := clampf(float(area.get("align_jitter_deg", 5.0)), 0.0, 45.0)
	var light_density := clampf(float(area.get("light_density", 1.0)), 0.0, 2.0)

	var heading_deg := float(area.get("heading_deg", -1.0))
	if heading_deg < 0.0:
		heading_deg = resolve_heading(poly, ctx.get("roads", []))
	stats["heading_deg"] = heading_deg
	var phi := heading_to_angle(heading_deg)
	var u := Vector2(cos(phi), sin(phi))
	var v := Vector2(-u.y, u.x)

	# Density scales SPACING (never a count): a sparser camp is the same camp
	# with more room between households.
	var pitch := 1.0 / sqrt(density)
	var cell_u := float(style["cell_u"]) * pitch
	var cell_v := float(style["cell_v"]) * pitch
	stats["variant"] = str(area.get("variant", ""))
	var rows_per_block := maxi(int(style["rows_per_block"]), 1)
	var lane_w := float(style["lane_w"])
	var block_v := float(rows_per_block) * cell_v + lane_w
	var fill := float(style["fill"])
	var templates: Dictionary = style["templates"]
	var template_ids: Array = templates.keys()
	template_ids.sort()  # dictionary order must never decide the mix

	# Polygon extent in the heading frame.
	var u_min := INF
	var u_max := -INF
	var v_min := INF
	var v_max := -INF
	for p in poly:
		var pu := p.dot(u)
		var pv := p.dot(v)
		u_min = minf(u_min, pu)
		u_max = maxf(u_max, pu)
		v_min = minf(v_min, pv)
		v_max = maxf(v_max, pv)

	var ground: Callable = ctx.get("ground_y_at", Callable())
	var excluded: Callable = ctx.get("is_excluded", Callable())
	var rng := RandomNumberGenerator.new()
	var placed_hash: Dictionary = {}  # Vector2i (8 m bucket) -> [footprint index]

	# Lattice origin: the world (so growth is stable), or the plot's own corner.
	var u_off := 0.0
	var v_off := 0.0
	if not str(area.get("group_id", "")).is_empty():
		var span_u := maxf(u_max - u_min - 2.0 * EDGE_MARGIN_M, 1.0)
		var span_v := maxf(v_max - v_min - 2.0 * EDGE_MARGIN_M, 1.0)
		cell_u = span_u / float(maxi(int(floor(span_u / cell_u)), 1))
		cell_v = span_v / float(maxi(int(floor(span_v / cell_v)), 1))
		lane_w = 0.0
		block_v = float(rows_per_block) * cell_v
		u_off = u_min + EDGE_MARGIN_M
		v_off = v_min + EDGE_MARGIN_M
		stats["plot_fit"] = true

	var b0 := int(floor((v_min - v_off) / block_v)) - 1
	var b1 := int(floor((v_max - v_off) / block_v)) + 1
	var i0 := int(floor((u_min - u_off) / cell_u)) - 1
	var i1 := int(floor((u_max - u_off) / cell_u)) + 1
	for b in range(b0, b1 + 1):
		for r in rows_per_block:
			var row := b * rows_per_block + r
			var row_v := v_off + float(b) * block_v + (float(r) + 0.5) * cell_v
			if row_v < v_min - cell_v or row_v > v_max + cell_v:
				continue
			# One parking direction per row: a row of RVs all nose the same way.
			var row_flip := (hash(Vector4i(seed, row, 7919, 1)) & 1) == 1
			var dir_phi := phi + (PI if row_flip else 0.0)
			var du := Vector2(cos(dir_phi), sin(dir_phi))
			var dv := Vector2(-du.y, du.x)
			for i in range(i0, i1 + 1):
				stats["cells"] += 1
				rng.seed = hash(Vector4i(seed, i, row, 2))
				# Every draw below happens whether or not the household survives,
				# so one cell's outcome can never shift another's random stream.
				var occupied := rng.randf() < fill
				var tid := _pick_template(rng, templates, template_ids)
				var ext := CampStyles.template_half_extent(tid, jitter_deg, max_scale)
				var slack_u := maxf(cell_u * 0.5 - ext.x, 0.0) * pos_jitter
				var slack_v := maxf(cell_v * 0.5 - ext.y, 0.0) * pos_jitter
				var ju := rng.randf_range(-slack_u, slack_u)
				var jv := rng.randf_range(-slack_v, slack_v)
				if not occupied:
					continue
				var origin := u * (u_off + (float(i) + 0.5) * cell_u + ju) + v * (row_v + jv)
				if origin.dot(u) < u_min - cell_u or origin.dot(u) > u_max + cell_u:
					continue
				var placed_any := false
				var items: Array = CampStyles.template_items(tid)
				for k in items.size():
					var it: Dictionary = items[k]
					var cls := str(it["cls"])
					# Fixed draw order per item, independent of acceptance.
					var present := rng.randf() < float(it.get("p", 1.0))
					var mode := CampStyles.class_mode(cls)
					var rot := deg_to_rad(float(it.get("rot", 0.0)))
					var ang := dir_phi + rot
					var scale := 1.0
					match mode:
						CampStyles.ALIGNED:
							ang += deg_to_rad(rng.randf_range(-jitter_deg, jitter_deg))
							scale = 1.0 + (rng.randf_range(ALIGNED_SCALE.x, ALIGNED_SCALE.y) - 1.0) * scale_var
						CampStyles.LOOSE:
							ang += deg_to_rad(rng.randf_range(-1.0, 1.0) * loose_jitter)
							scale = 1.0 + (rng.randf_range(LOOSE_SCALE.x, LOOSE_SCALE.y) - 1.0) * scale_var
						_:
							ang = rng.randf() * TAU
							scale = 1.0 + (rng.randf_range(LOOSE_SCALE.x, LOOSE_SCALE.y) - 1.0) * scale_var
					var color := BrcCampGenerator._class_color(_color_class(cls), rng)
					var lit := rng.randf() < GLOW_CHANCE * light_density
					var glow_h := rng.randf_range(0.2, 1.2)
					var glow_color := Color.from_hsv(rng.randf(), rng.randf_range(0.55, 1.0), 1.0)
					if not present:
						continue
					if k > 0 and not placed_any:
						break  # the anchor did not fit — there is no household
					var size := CampStyles.class_size(cls) * scale
					var center := origin + du * float(it["a"]) + dv * float(it["c"])
					var key := "%d:%d:%d" % [i, row, k]
					var fp := {"cls": cls, "center": center,
						"half": Vector2(size.x * 0.5, size.z * 0.5), "angle": ang, "row": row,
						"key": key}
					var why := _reject_reason(fp, poly, holes, excluded, ground,
						footprints, placed_hash)
					if not why.is_empty():
						stats[why] += 1
						continue
					if int(stats["structures"]) >= MAX_STRUCTURES_PER_AREA:
						return out
					var gy := 0.0
					var up := Vector3.UP
					if ground.is_valid() and not flatten:
						gy = float(ground.call(center.x, center.y))
						if CampStyles.is_vehicle(cls):
							up = _surface_up(ground, center)
					_bucket_add(placed_hash, fp, footprints.size())
					footprints.append(fp)
					if not placed_any:
						placed_any = true
						stats["households"] += 1
					# The player's hand edit to THIS element, if any.
					var edit: Dictionary = edits.get(key, {})
					if bool(edit.get("removed", false)):
						stats["removed"] = int(stats.get("removed", 0)) + 1
						continue
					var draw_ang := ang + deg_to_rad(float(edit.get("yaw_deg", 0.0)))
					var draw_scale := scale * clampf(float(edit.get("scale", 1.0)), 0.3, 3.0)
					size = CampStyles.class_size(cls) * draw_scale
					if not classes.has(cls):
						classes[cls] = []
					var pos := Vector3(center.x, gy, center.y)
					(classes[cls] as Array).append({"pos": pos, "yaw": -draw_ang,
						"scale": draw_scale, "color": color, "up": up, "key": key,
						"cls": cls, "size": size, "edited": not edit.is_empty()})
					stats["structures"] += 1
					if lit:
						glow.append({"pos": pos + Vector3(0.0, size.y + glow_h, 0.0),
							"color": glow_color})
	return out


# ---------------------------------------------------------------------------
# Heading
# ---------------------------------------------------------------------------

## Compass bearing (0..180, clockwise from north = -Z) the camp's rows run along.
## A road within ROAD_ALIGN_DIST_M wins — people park along the road they drove
## in on. Otherwise the polygon's longest edge: a camp drawn as a long strip is
## laid out along the strip.
static func resolve_heading(poly: PackedVector2Array, roads: Array = []) -> float:
	if poly.size() < 2:
		return 0.0
	var probes: Array = [_centroid(poly)]
	for p in poly:
		probes.append(p)
	var best_d := ROAD_ALIGN_DIST_M
	var best_dir := Vector2.ZERO
	for road in roads:
		if not (road is Dictionary):
			continue
		var pts: PackedVector2Array = (road as Dictionary).get("points", PackedVector2Array())
		for s in range(pts.size() - 1):
			var a := pts[s]
			var b := pts[s + 1]
			if a.distance_squared_to(b) < 1.0:
				continue
			for q: Vector2 in probes:
				var d := q.distance_to(Geometry2D.get_closest_point_to_segment(q, a, b))
				if d < best_d:
					best_d = d
					best_dir = b - a
	if best_dir == Vector2.ZERO:
		var best_len := -1.0
		for i in poly.size():
			var e := poly[(i + 1) % poly.size()] - poly[i]
			if e.length_squared() > best_len:
				best_len = e.length_squared()
				best_dir = e
	return direction_to_heading(best_dir)


## XZ direction -> compass bearing folded into 0..180 (an axis has no "front").
static func direction_to_heading(dir: Vector2) -> float:
	if dir.length_squared() < 1e-9:
		return 0.0
	# Bearing b: dir = (sin b, -cos b).
	return fposmod(rad_to_deg(atan2(dir.x, -dir.y)), 180.0)


## Compass bearing -> XZ-plane angle (radians) of that direction.
static func heading_to_angle(heading_deg: float) -> float:
	var b := deg_to_rad(heading_deg)
	return atan2(-cos(b), sin(b))


## Smallest angle (degrees, 0..90) between a footprint's long axis and the camp
## heading, treating both as undirected axes. The alignment the selftest and
## the capture harness report.
static func axis_deviation_deg(angle_rad: float, heading_deg: float) -> float:
	var d := fposmod(rad_to_deg(angle_rad - heading_to_angle(heading_deg)), 180.0)
	return minf(d, 180.0 - d)


# ---------------------------------------------------------------------------
# Placement tests
# ---------------------------------------------------------------------------

static func footprint_corners(fp: Dictionary, grow: float = 0.0) -> PackedVector2Array:
	var c: Vector2 = fp["center"]
	var h: Vector2 = fp["half"] + Vector2(grow, grow)
	var a := float(fp["angle"])
	var ax := Vector2(cos(a), sin(a))
	var az := Vector2(-ax.y, ax.x)
	return PackedVector2Array([c + ax * h.x + az * h.y, c - ax * h.x + az * h.y,
		c - ax * h.x - az * h.y, c + ax * h.x - az * h.y])


## Separating-axis test for two oriented rectangles.
static func footprints_overlap(a: Dictionary, b: Dictionary) -> bool:
	var ca := footprint_corners(a)
	var cb := footprint_corners(b)
	for pair in [[ca, cb], [cb, ca]]:
		var pts: PackedVector2Array = pair[0]
		for e in 2:
			var axis := (pts[e + 1] - pts[e]).normalized()
			if axis == Vector2.ZERO:
				continue
			var lo_a := INF
			var hi_a := -INF
			var lo_b := INF
			var hi_b := -INF
			for p in ca:
				lo_a = minf(lo_a, p.dot(axis))
				hi_a = maxf(hi_a, p.dot(axis))
			for p in cb:
				lo_b = minf(lo_b, p.dot(axis))
				hi_b = maxf(hi_b, p.dot(axis))
			if hi_a <= lo_b or hi_b <= lo_a:
				return false
	return true


static func _reject_reason(fp: Dictionary, poly: PackedVector2Array, holes: Array,
		excluded: Callable, ground: Callable, footprints: Array,
		placed_hash: Dictionary) -> String:
	var corners := footprint_corners(fp, EDGE_MARGIN_M)
	var center: Vector2 = fp["center"]
	for p in corners:
		if not Geometry2D.is_point_in_polygon(p, poly):
			return "rejected_edge"
	for h in holes:
		if not (h is PackedVector2Array):
			continue
		if Geometry2D.is_point_in_polygon(center, h):
			return "rejected_edge"
		for p in corners:
			if Geometry2D.is_point_in_polygon(p, h):
				return "rejected_edge"
		# A hole smaller than the footprint can sit wholly inside it.
		if Geometry2D.is_point_in_polygon((h as PackedVector2Array)[0], corners):
			return "rejected_edge"
	if excluded.is_valid():
		if bool(excluded.call(center)):
			return "rejected_excluded"
		for p in corners:
			if bool(excluded.call(p)):
				return "rejected_excluded"
	if ground.is_valid():
		var limit := CampStyles.VEHICLE_MAX_SLOPE_DEG if CampStyles.is_vehicle(str(fp["cls"])) \
			else CampStyles.TENT_MAX_SLOPE_DEG
		if slope_deg_at(ground, center) > limit:
			return "rejected_slope"
	for key in _bucket_keys(fp):
		for idx: int in placed_hash.get(key, []):
			if footprints_overlap(fp, footprints[idx]):
				return "rejected_overlap"
	return ""


## Terrain slope (degrees) by central differences on the ground callable.
static func slope_deg_at(ground: Callable, p: Vector2) -> float:
	var g := _gradient(ground, p)
	return rad_to_deg(atan(g.length()))


static func _gradient(ground: Callable, p: Vector2) -> Vector2:
	var s := SLOPE_STEP_M
	var gx := (float(ground.call(p.x + s, p.y)) - float(ground.call(p.x - s, p.y))) / (2.0 * s)
	var gz := (float(ground.call(p.x, p.y + s)) - float(ground.call(p.x, p.y - s))) / (2.0 * s)
	return Vector2(gx, gz)


static func _surface_up(ground: Callable, p: Vector2) -> Vector3:
	var g := _gradient(ground, p)
	return Vector3(-g.x, 1.0, -g.y).normalized()


static func _bucket_keys(fp: Dictionary) -> Array:
	var c: Vector2 = fp["center"]
	var r := (fp["half"] as Vector2).length()
	var keys: Array = []
	for bx in range(int(floor((c.x - r) / 8.0)), int(floor((c.x + r) / 8.0)) + 1):
		for bz in range(int(floor((c.y - r) / 8.0)), int(floor((c.y + r) / 8.0)) + 1):
			keys.append(Vector2i(bx, bz))
	return keys


static func _bucket_add(placed_hash: Dictionary, fp: Dictionary, idx: int) -> void:
	for key in _bucket_keys(fp):
		if not placed_hash.has(key):
			placed_hash[key] = []
		(placed_hash[key] as Array).append(idx)


static func _pick_template(rng: RandomNumberGenerator, weights: Dictionary,
		ids: Array) -> String:
	var total := 0.0
	for id in ids:
		total += float(weights[id])
	var roll := rng.randf() * total
	for id in ids:
		roll -= float(weights[id])
		if roll <= 0.0:
			return str(id)
	return str(ids[ids.size() - 1])


## BrcCampGenerator owns the colour palettes; map the classes it has never
## heard of onto the nearest one it has.
static func _color_class(cls: String) -> String:
	# A player-added model draws its own materials up close; its far proxy is
	# a quiet off-white rather than a random tent colour.
	if CampStyles.is_user_class(cls):
		return "rv"
	match cls:
		"van":
			return "rv"
		"ez_up":
			return "shade_structure"
		"lotus_tent":
			return "geodesic_dome"
		_:
			return cls


static func _centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(maxi(poly.size(), 1))


## Which placed element does a ray hit? Ray vs each element's oriented box —
## the Tune-look studio has no physics to ask. `items` are the dicts `generate`
## emits per class ({key, pos, yaw, size}). Returns the element key, or "".
static func pick_item_on_ray(items: Array, origin: Vector3, dir: Vector3) -> String:
	var best_t := INF
	var best := ""
	for it: Dictionary in items:
		var size: Vector3 = it["size"]
		# Flat things (a tarp, a shade cloth) are authored as a thin plate up in
		# the air: give every element a clickable body from the ground up.
		var h := maxf(size.y, 2.4)
		var inv := Basis(Vector3.UP, float(it["yaw"])).inverse()
		var o := inv * (origin - (it["pos"] as Vector3))
		var d := inv * dir
		var lo := Vector3(-size.x * 0.5 - 0.15, 0.0, -size.z * 0.5 - 0.15)
		var hi := Vector3(size.x * 0.5 + 0.15, h, size.z * 0.5 + 0.15)
		var t0 := 0.0
		var t1 := INF
		var hit := true
		for axis in 3:
			if absf(d[axis]) < 1e-8:
				if o[axis] < lo[axis] or o[axis] > hi[axis]:
					hit = false
					break
				continue
			var a := (lo[axis] - o[axis]) / d[axis]
			var b := (hi[axis] - o[axis]) / d[axis]
			t0 = maxf(t0, minf(a, b))
			t1 = minf(t1, maxf(a, b))
			if t0 > t1:
				hit = false
				break
		if hit and t0 < best_t:
			best_t = t0
			best = str(it["key"])
	return best

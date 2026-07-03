class_name VegetationPaint
extends RefCounted

## Pure helpers: polygon selection, Poisson disk fill, species mix.

enum Preset { PINE, DECIDUOUS, SHRUB, MIX, GRASS_LAWN, GRASS_FIELD }

const GROUND_SINK_M := 0.05
const GRASS_FILL_CAP := 8000


static func circle_polygon(center: Vector2, radius_m: float, segments: int = 32) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r := maxf(radius_m, 0.0)
	if r <= 0.0:
		return out
	var segs := maxi(segments, 8)
	for i in segs:
		var ang := TAU * float(i) / float(segs)
		out.append(center + Vector2(cos(ang), sin(ang)) * r)
	return out


## Clamp every vertex to a max radius from centre (circle tool cap).
static func clamp_polygon_radius(poly: PackedVector2Array, center: Vector2,
		max_radius_m: float) -> PackedVector2Array:
	if poly.is_empty() or max_radius_m <= 0.0:
		return poly
	var out := PackedVector2Array()
	out.resize(poly.size())
	for i in poly.size():
		var offset := poly[i] - center
		var len := offset.length()
		if len > max_radius_m:
			out[i] = center + offset * (max_radius_m / len)
		else:
			out[i] = poly[i]
	return out


## Rough tree-count estimate for UI feedback (matches populate_vegetation cap logic).
static func estimate_fill_count(poly: PackedVector2Array, spacing_m: float,
		max_count: int = 2500) -> int:
	var area := polygon_area(poly)
	if area < 4.0 or spacing_m <= 0.0:
		return 0
	var est := int(area / (spacing_m * spacing_m * 0.866)) + 8
	return mini(est, max_count)


static func rect_to_polygon(rect_min: Vector2, rect_max: Vector2) -> PackedVector2Array:
	var x0 := minf(rect_min.x, rect_max.x)
	var x1 := maxf(rect_min.x, rect_max.x)
	var z0 := minf(rect_min.y, rect_max.y)
	var z1 := maxf(rect_min.y, rect_max.y)
	return PackedVector2Array([
		Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1),
	])


static func polygon_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return absf(area) * 0.5


static func polygon_aabb(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)
	return Rect2(min_x, min_z, max_x - min_x, max_z - min_z)


static func point_in_polygon(pt: Vector2, poly: PackedVector2Array) -> bool:
	if poly.size() < 3:
		return false
	return Geometry2D.is_point_in_polygon(pt, poly)


static func simplify_polyline(points: PackedVector2Array, tolerance_m: float) -> PackedVector2Array:
	if points.size() <= 2:
		return points
	var keep := PackedByteArray()
	keep.resize(points.size())
	for i in keep.size():
		keep[i] = 0
	keep[0] = 1
	keep[points.size() - 1] = 1
	_rdp(points, 0, points.size() - 1, tolerance_m * tolerance_m, keep)
	var out := PackedVector2Array()
	for i in points.size():
		if keep[i] == 1:
			out.append(points[i])
	return out


static func _rdp(points: PackedVector2Array, start: int, end: int,
		tol_sq: float, keep: PackedByteArray) -> void:
	if end <= start + 1:
		return
	var a := points[start]
	var b := points[end]
	var max_d := 0.0
	var idx := start
	for i in range(start + 1, end):
		var d := _dist_point_segment_sq(points[i], a, b)
		if d > max_d:
			max_d = d
			idx = i
	if max_d > tol_sq:
		keep[idx] = 1
		_rdp(points, start, idx, tol_sq, keep)
		_rdp(points, idx, end, tol_sq, keep)


static func _dist_point_segment_sq(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-8:
		return p.distance_squared_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_squared_to(a + ab * t)


## Bridson-style Poisson disk fill inside a polygon.
static func poisson_fill(poly: PackedVector2Array, spacing_m: float, rng: RandomNumberGenerator,
		existing: Array[Vector2], max_count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if poly.size() < 3 or spacing_m <= 0.0 or max_count <= 0:
		return out
	var cell := spacing_m / sqrt(2.0)
	var aabb := polygon_aabb(poly)
	if aabb.size.x < 0.01 or aabb.size.y < 0.01:
		return out
	var grid_w := maxi(1, int(ceil(aabb.size.x / cell)))
	var grid_h := maxi(1, int(ceil(aabb.size.y / cell)))
	var occupied: Dictionary = {}
	var active: Array[Vector2] = []

	var try_add := func(pt: Vector2) -> bool:
		if not point_in_polygon(pt, poly):
			return false
		for e in existing:
			if pt.distance_to(e) < spacing_m:
				return false
		var gx := int(floor((pt.x - aabb.position.x) / cell))
		var gz := int(floor((pt.y - aabb.position.y) / cell))
		for dz in range(-2, 3):
			for dx in range(-2, 3):
				var key := "%d,%d" % [gx + dx, gz + dz]
				if occupied.has(key):
					var other: Vector2 = occupied[key]
					if pt.distance_to(other) < spacing_m:
						return false
		out.append({"x": pt.x, "z": pt.y})
		occupied["%d,%d" % [gx, gz]] = pt
		active.append(pt)
		return true

	# Seed from polygon centroid jittered.
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= float(poly.size())
	for _attempt in 24:
		var jitter := Vector2(rng.randf_range(-spacing_m, spacing_m), rng.randf_range(-spacing_m, spacing_m))
		if try_add.call(center + jitter):
			break

	while not active.is_empty() and out.size() < max_count:
		var ai := rng.randi_range(0, active.size() - 1)
		var base: Vector2 = active[ai]
		var placed := false
		for _k in 12:
			var ang := rng.randf() * TAU
			var dist := spacing_m * rng.randf_range(1.0, 2.0)
			var candidate := base + Vector2(cos(ang), sin(ang)) * dist
			if try_add.call(candidate):
				placed = true
				break
		if not placed:
			active.remove_at(ai)
	return out


## Flat-top hex grid fill for mowed lawn mats — edge-to-edge tiling, fixed yaw.
## `mat_width_m` is the flat-to-flat width of one hex mat (matches grass_lawn_card_w).
static func hex_grid_fill(poly: PackedVector2Array, mat_width_m: float,
		existing: Array[Vector2], max_count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if poly.size() < 3 or mat_width_m <= 0.0 or max_count <= 0:
		return out
	var col_step := mat_width_m
	var row_step := mat_width_m * sqrt(3.0) * 0.5
	var min_sep_sq := mat_width_m * mat_width_m * 0.25
	var aabb := polygon_aabb(poly)
	var row_min := int(floor(aabb.position.y / row_step)) - 1
	var row_max := int(ceil(aabb.end.y / row_step)) + 1
	for row in range(row_min, row_max + 1):
		if out.size() >= max_count:
			break
		var z := float(row) * row_step
		var x_off := col_step * 0.5 if (row & 1) != 0 else 0.0
		var col_min := int(floor((aabb.position.x - x_off) / col_step)) - 1
		var col_max := int(ceil((aabb.end.x - x_off) / col_step)) + 1
		for col in range(col_min, col_max + 1):
			if out.size() >= max_count:
				break
			var x := float(col) * col_step + x_off
			var pt := Vector2(x, z)
			if not point_in_polygon(pt, poly):
				continue
			var blocked := false
			for e in existing:
				if pt.distance_squared_to(e) < min_sep_sq:
					blocked = true
					break
			if blocked:
				continue
			out.append({"x": x, "z": z, "yaw": 0.0, "scale": 1.0})
	return out


## Rough hex-tile count for UI caps (one mat per hex cell).
static func estimate_hex_fill_count(poly: PackedVector2Array, mat_width_m: float,
		max_count: int = GRASS_FILL_CAP) -> int:
	var area := polygon_area(poly)
	if area < 1.0 or mat_width_m <= 0.0:
		return 0
	var cell_area := mat_width_m * mat_width_m * sqrt(3.0) * 0.5
	var est := int(area / cell_area) + 4
	return mini(est, max_count)


static func default_spacing_for_preset(preset: Preset) -> float:
	match preset:
		Preset.GRASS_LAWN:
			return 0.75
		Preset.GRASS_FIELD:
			return 1.1
		Preset.SHRUB:
			return 3.5
		Preset.PINE:
			return 6.0
		Preset.DECIDUOUS:
			return 8.0
		_:
			return 4.0


static func fill_cap_for_preset(preset: Preset) -> int:
	match preset:
		Preset.GRASS_LAWN, Preset.GRASS_FIELD:
			return GRASS_FILL_CAP
		_:
			return 2500


static func pick_species(preset: Preset, mix_pine: float, mix_deciduous: float,
		mix_shrub: float, rng: RandomNumberGenerator,
		mix_grass_lawn: float = 0.0, mix_grass_field: float = 0.0) -> String:
	match preset:
		Preset.PINE:
			return "pine"
		Preset.DECIDUOUS:
			return "deciduous"
		Preset.SHRUB:
			return "shrub"
		Preset.GRASS_LAWN:
			return "grass_lawn"
		Preset.GRASS_FIELD:
			return "grass_field"
		_:
			var total := maxf(
				mix_pine + mix_deciduous + mix_shrub + mix_grass_lawn + mix_grass_field, 0.001)
			var r := rng.randf() * total
			if r < mix_pine:
				return "pine"
			r -= mix_pine
			if r < mix_deciduous:
				return "deciduous"
			r -= mix_deciduous
			if r < mix_shrub:
				return "shrub"
			r -= mix_shrub
			if r < mix_grass_lawn:
				return "grass_lawn"
			return "grass_field"


static func build_transform(x: float, ground_y: float, z: float, yaw: float,
		scale: float, align_to_surface: bool, surface_up: Vector3,
		vertical_offset_m: float = 0.0, foot_local_y: float = 0.0) -> Transform3D:
	var pos := Vector3(
		x,
		ground_y + vertical_offset_m - foot_local_y * scale - GROUND_SINK_M,
		z)
	var basis := Basis.IDENTITY
	if align_to_surface and surface_up.length_squared() > 0.01:
		basis = _basis_from_up(surface_up)
	basis = basis.rotated(basis.y, yaw)
	basis = basis.scaled(Vector3(scale, scale, scale))
	return Transform3D(basis, pos)


static func _basis_from_up(up: Vector3) -> Basis:
	var n := up.normalized()
	var tangent := Vector3.FORWARD.cross(n)
	if tangent.length_squared() < 1e-6:
		tangent = Vector3.RIGHT.cross(n)
	tangent = tangent.normalized()
	var bitangent := n.cross(tangent).normalized()
	return Basis(tangent, n, bitangent)

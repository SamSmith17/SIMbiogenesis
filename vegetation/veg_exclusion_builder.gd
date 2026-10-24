class_name VegExclusionBuilder
extends RefCounted

## Builds buffered exclusion polygons for auto-vegetation scatter from OSM vectors.


static func build_all(buildings: Array, roads: Array, water: Array,
		building_m: float, road_m: float, water_m: float,
		building_enabled: bool = true, road_enabled: bool = true) -> Array:
	var out: Array = []
	if building_enabled:
		for b in buildings:
			if b is Dictionary:
				out.append_array(_buffer_footprint((b as Dictionary).get("points", PackedVector2Array()), building_m))
	if road_enabled:
		for r in roads:
			if r is Dictionary:
				var d: Dictionary = r
				var pts: PackedVector2Array = d.get("points", PackedVector2Array())
				var half_w := float(d.get("half_width_m", 4.0)) + road_m
				var poly := TerrainRoadFlatten.road_corridor_polygon(pts, half_w)
				if poly.size() >= 3:
					out.append(poly)
	for w in water:
		if w is Dictionary:
			out.append_array(_buffer_footprint((w as Dictionary).get("points", PackedVector2Array()), water_m))
	return out


static func _buffer_footprint(footprint: PackedVector2Array, buffer_m: float) -> Array:
	if footprint.size() < 3:
		return []
	if buffer_m <= 0.01:
		return [footprint.duplicate()]
	var expanded: Array = Geometry2D.offset_polygon(footprint, buffer_m)
	var out: Array = []
	for poly in expanded:
		if poly is PackedVector2Array and (poly as PackedVector2Array).size() >= 3:
			out.append(poly)
	if out.is_empty():
		return [footprint.duplicate()]
	return out


static func point_excluded(p: Vector2, exclusions: Array) -> bool:
	for poly in exclusions:
		if poly is PackedVector2Array and (poly as PackedVector2Array).size() >= 3:
			if Geometry2D.is_point_in_polygon(p, poly):
				return true
	return false


## Spatial broadphase for scatter hot loops (uniform grid over the site square).
## `extra` (x, z) -> bool excludes ground no polygon describes — a lake's
## shore band from its gauge record (ShorelineHistory.in_shore).
static func build_index(exclusions: Array, half_extent_m: float,
		extra: Callable = Callable()) -> ExclusionIndex:
	var idx := ExclusionIndex.build(exclusions, half_extent_m)
	idx.extra = extra
	return idx


class ExclusionIndex:
	extends RefCounted

	const CELL_M := 32.0

	var _polys: Array = []
	var _half := 1500.0
	var _cells: Dictionary = {}
	var extra: Callable = Callable()


	static func build(exclusions: Array, half_extent_m: float) -> ExclusionIndex:
		var idx := ExclusionIndex.new()
		idx._polys = exclusions
		idx._half = half_extent_m
		for pi in exclusions.size():
			var poly: Variant = exclusions[pi]
			if not (poly is PackedVector2Array):
				continue
			var pts: PackedVector2Array = poly
			if pts.size() < 3:
				continue
			var min_x := pts[0].x
			var max_x := pts[0].x
			var min_z := pts[0].y
			var max_z := pts[0].y
			for p in pts:
				min_x = minf(min_x, p.x)
				max_x = maxf(max_x, p.x)
				min_z = minf(min_z, p.y)
				max_z = maxf(max_z, p.y)
			var cx0 := int(floor((min_x + half_extent_m) / CELL_M))
			var cx1 := int(floor((max_x + half_extent_m) / CELL_M))
			var cz0 := int(floor((min_z + half_extent_m) / CELL_M))
			var cz1 := int(floor((max_z + half_extent_m) / CELL_M))
			for cz in range(cz0, cz1 + 1):
				for cx in range(cx0, cx1 + 1):
					var key := "%d,%d" % [cx, cz]
					if key not in idx._cells:
						idx._cells[key] = []
					(idx._cells[key] as Array).append(pi)
		return idx


	func is_excluded(p: Vector2) -> bool:
		if extra.is_valid() and bool(extra.call(p.x, p.y)):
			return true
		if _polys.is_empty():
			return false
		var cx := int(floor((p.x + _half) / CELL_M))
		var cz := int(floor((p.y + _half) / CELL_M))
		var seen: Dictionary = {}
		for dz in range(-1, 2):
			for dx in range(-1, 2):
				var key := "%d,%d" % [cx + dx, cz + dz]
				if key not in _cells:
					continue
				for pi in _cells[key]:
					if seen.has(pi):
						continue
					seen[pi] = true
					var poly: Variant = _polys[pi]
					if poly is PackedVector2Array and Geometry2D.is_point_in_polygon(p, poly):
						return true
		return false

class_name BuildingPicker
extends RefCounted

## Point-in-polygon building pick from world XZ.


static func pick_at_xz(buildings: Array, x: float, z: float) -> Dictionary:
	var pt := Vector2(x, z)
	var best_idx := -1
	var best_area := INF
	for i in buildings.size():
		if not (buildings[i] is Dictionary):
			continue
		var d: Dictionary = buildings[i]
		var pts: Variant = d.get("points", PackedVector2Array())
		if not (pts is PackedVector2Array):
			continue
		var poly: PackedVector2Array = pts
		if poly.size() < 3:
			continue
		if not Geometry2D.is_point_in_polygon(pt, poly):
			continue
		var area := _polygon_area(poly)
		if area < best_area:
			best_area = area
			best_idx = int(d.get("idx", i))
	if best_idx < 0:
		return {"valid": false}
	return footprint_info(buildings, best_idx)


static func footprint_info(buildings: Array, building_idx: int) -> Dictionary:
	for i in buildings.size():
		if not (buildings[i] is Dictionary):
			continue
		var d: Dictionary = buildings[i]
		if int(d.get("idx", i)) != building_idx:
			continue
		var pts: PackedVector2Array = d.get("points", PackedVector2Array())
		if pts.size() < 3:
			return {"valid": false}
		var min_v := pts[0]
		var max_v := pts[0]
		var centroid := Vector2.ZERO
		for p in pts:
			min_v.x = minf(min_v.x, p.x)
			min_v.y = minf(min_v.y, p.y)
			max_v.x = maxf(max_v.x, p.x)
			max_v.y = maxf(max_v.y, p.y)
			centroid += p
		centroid /= float(pts.size())
		return {
			"valid": true,
			"building_idx": building_idx,
			"centroid": centroid,
			"width_m": maxf(max_v.x - min_v.x, 1.0),
			"depth_m": maxf(max_v.y - min_v.y, 1.0),
			"height_m": float(d.get("height_m", BuildingBuilder.DEFAULT_HEIGHT_M)),
			"points": pts,
		}
	return {"valid": false}


static func _polygon_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return absf(area) * 0.5

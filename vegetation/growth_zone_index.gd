class_name GrowthZoneIndex
extends RefCounted

## Fast point-in-polygon lookup for vegetation reseeding bounds.
## Built from OSM scatter polygons or manual paint zones so seedlings stay
## inside the original woodland / painted patch.

var _polys: Array = []


static func from_polygons(polys: Array) -> GrowthZoneIndex:
	var idx := GrowthZoneIndex.new()
	for p in polys:
		if p is PackedVector2Array and (p as PackedVector2Array).size() >= 3:
			idx._polys.append(p)
	return idx


func add_polygon(poly: PackedVector2Array) -> void:
	if poly.size() >= 3:
		_polys.append(poly)


func is_empty() -> bool:
	return _polys.is_empty()


func polygon_count() -> int:
	return _polys.size()


func contains(x: float, z: float) -> bool:
	var pt := Vector2(x, z)
	for poly in _polys:
		if poly is PackedVector2Array and VegetationPaint.point_in_polygon(pt, poly):
			return true
	return false

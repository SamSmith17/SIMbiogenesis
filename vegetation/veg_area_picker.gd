class_name VegAreaPicker
extends RefCounted

## Point-in-polygon pick over the OSM vegetation-area polygons that
## VegetationService returns (terrain_loader._auto_veg_data["polygons"], each
## {points: PackedVector2Array, kind: String, tags: Dictionary}). Mirrors
## BuildingPicker: smallest-area match wins so a small lawn inside a big park is
## selected over the park. Buildings are picked separately and take priority in
## interaction_focus, so a building footprint overlapping a park never blocks it.

## Friendly OSM-kind → label for the crosshair prompt.
const KIND_LABELS := {
	"wood": "forest",
	"forest": "forest",
	"scrub": "scrub",
	"wetland": "wetland",
	"orchard": "orchard",
	"vineyard": "vineyard",
	"cemetery": "cemetery",
	"park": "park",
	"grass_lawn": "lawn",
	"grass_field": "field",
}


static func kind_label(kind: String) -> String:
	return str(KIND_LABELS.get(kind, "vegetation"))


static func pick_at_xz(polygons: Array, x: float, z: float) -> Dictionary:
	var pt := Vector2(x, z)
	var best_idx := -1
	var best_area := INF
	for i in polygons.size():
		if not (polygons[i] is Dictionary):
			continue
		var d: Dictionary = polygons[i]
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
			best_idx = i
	if best_idx < 0:
		return {"valid": false}
	return area_info(polygons, best_idx)


static func area_info(polygons: Array, area_idx: int) -> Dictionary:
	if area_idx < 0 or area_idx >= polygons.size() or not (polygons[area_idx] is Dictionary):
		return {"valid": false}
	var d: Dictionary = polygons[area_idx]
	var pts: Variant = d.get("points", PackedVector2Array())
	if not (pts is PackedVector2Array) or (pts as PackedVector2Array).size() < 3:
		return {"valid": false}
	var poly: PackedVector2Array = pts
	var centroid := Vector2.ZERO
	for p in poly:
		centroid += p
	centroid /= float(poly.size())
	var kind := str(d.get("kind", "grass_field"))
	return {
		"valid": true,
		"area_idx": area_idx,
		"kind": kind,
		"kind_label": kind_label(kind),
		"points": poly,
		"centroid": centroid,
		"area_m2": _polygon_area(poly),
		# Metre-rounded centroid tag (same scheme as BuildingBuilder.building_tag) so
		# per-area edits in later phases survive an OSM re-fetch.
		"tag": "veg_%d_%d" % [roundi(centroid.x), roundi(centroid.y)],
	}


static func _polygon_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return absf(area) * 0.5

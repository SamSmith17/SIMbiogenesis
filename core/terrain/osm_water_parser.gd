class_name OsmWaterParser
extends RefCounted

## OSM water extraction: closed ways, multipolygon relations, buffered waterways.

const JOIN_EPS_M := 0.75
const JOIN_EPS_SQ := JOIN_EPS_M * JOIN_EPS_M
const MIN_RING_AREA_M2 := 80.0

const WATERWAY_HALF_WIDTH := {
	"river": 22.0,
	"stream": 5.0,
	"canal": 7.0,
	"ditch": 2.5,
	"drain": 2.0,
}


static func extract_water(nodes: Dictionary, ways_by_id: Dictionary,
		water_way_ids: Array, water_relations: Array,
		waterway_way_ids: Array, center_lat: float, center_lon: float) -> Array:
	var used_way_ids: Dictionary = {}
	var out: Array = []

	for rel in water_relations:
		if not (rel is Dictionary):
			continue
		var polys := _multipolygon_to_polys(rel, ways_by_id, nodes, center_lat, center_lon, used_way_ids)
		for poly in polys:
			if poly.size() >= 3 and _polygon_area(poly) >= MIN_RING_AREA_M2:
				var tags: Dictionary = rel.get("tags", {})
				out.append({"points": poly, "kind": _water_kind(tags), "tags": tags})

	for wid_v in water_way_ids:
		var wid := int(wid_v)
		if used_way_ids.has(wid):
			continue
		var way: Dictionary = ways_by_id.get(wid, {})
		if way.is_empty():
			continue
		var poly := _way_to_local_poly(way, nodes, center_lat, center_lon)
		if poly.size() >= 3 and _polygon_area(poly) >= MIN_RING_AREA_M2:
			var tags: Dictionary = way.get("tags", {})
			out.append({"points": poly, "kind": _water_kind(tags), "tags": tags})

	for wid_v in waterway_way_ids:
		var wid := int(wid_v)
		var way: Dictionary = ways_by_id.get(wid, {})
		if way.is_empty():
			continue
		var tags: Dictionary = way.get("tags", {})
		var line := _way_to_local_poly(way, nodes, center_lat, center_lon, false)
		if line.size() < 2:
			continue
		# Skip centreline ribbons when a riverbank / water-area polygon already
		# covers this reach — otherwise the same river renders as two parallel strips
		# at slightly different heights after terrain draping.
		if _centerline_covered_by_water(line, out):
			continue
		var half_w := _waterway_half_width(tags)
		var ribbon := _buffer_polyline(line, half_w)
		if ribbon.size() >= 3 and _polygon_area(ribbon) >= MIN_RING_AREA_M2:
			out.append({
				"points": ribbon,
				"kind": str(tags.get("waterway", "river")),
				"tags": tags,
				"centerline": line,
				"half_width": half_w,
			})

	return out


## True when most samples along the waterway lie inside an existing water polygon.
static func _centerline_covered_by_water(line: PackedVector2Array, waters: Array) -> bool:
	if line.size() < 2 or waters.is_empty():
		return false
	var inside := 0
	var samples := maxi(line.size(), 5)
	for si in samples:
		var t := float(si) / float(maxi(samples - 1, 1))
		var seg_len := line.size() - 1
		var dist := t * float(seg_len)
		var idx := int(floor(dist))
		idx = clampi(idx, 0, seg_len - 1)
		var frac := dist - float(idx)
		var p := line[idx].lerp(line[idx + 1], frac)
		for item in waters:
			if not (item is Dictionary):
				continue
			var poly: PackedVector2Array = (item as Dictionary).get("points", PackedVector2Array())
			if poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly):
				inside += 1
				break
	return inside >= maxi(1, int(ceil(float(samples) * 0.45)))


static func is_water_way_tags(tags: Dictionary) -> bool:
	if tags.get("natural", "") == "water" or tags.get("natural", "") == "bay":
		return true
	if tags.has("water"):
		return true
	if tags.get("landuse", "") == "reservoir":
		return true
	if tags.get("waterway", "") == "riverbank":
		return true
	return false


static func is_water_relation_tags(tags: Dictionary) -> bool:
	if tags.get("type", "") == "multipolygon":
		return is_water_way_tags(tags)
	if tags.get("natural", "") == "water" or tags.get("natural", "") == "bay":
		return true
	if tags.has("water"):
		return true
	if tags.get("landuse", "") == "reservoir":
		return true
	return false


static func is_waterway_line_tags(tags: Dictionary) -> bool:
	var ww := str(tags.get("waterway", ""))
	return ww in ["river", "stream", "canal", "ditch", "drain"]


## Assemble multipolygon rings. `punch_holes=true` subtracts inners via
## Geometry2D.exclude_polygons (correct for water lakes with islands).
## Vegetation MUST pass punch_holes=false — nested hole punching on large wood
## relations combinatorially explodes into millions of fragments (Mt. Vernon
## logged 4.2M "wood" polys from a single Overpass reply).
static func _multipolygon_to_polys(relation: Dictionary, ways_by_id: Dictionary,
		nodes: Dictionary, center_lat: float, center_lon: float,
		used_way_ids: Dictionary, punch_holes: bool = true) -> Array[PackedVector2Array]:
	var outers: Array = []
	var inners: Array = []
	for member in relation.get("members", []):
		if not (member is Dictionary):
			continue
		var m: Dictionary = member
		if str(m.get("type", "")) != "way":
			continue
		var wid := int(m.get("ref", -1))
		if wid < 0:
			continue
		used_way_ids[wid] = true
		var way: Dictionary = ways_by_id.get(wid, {})
		if way.is_empty():
			continue
		var role := str(m.get("role", "outer"))
		if role == "inner":
			inners.append(wid)
		else:
			outers.append(wid)

	var result: Array[PackedVector2Array] = []
	for outer_group in _group_connected_way_ids(outers, ways_by_id, nodes, center_lat, center_lon):
		var ring := _assemble_ring(outer_group, ways_by_id, nodes, center_lat, center_lon)
		if ring.size() < 3:
			continue
		if not punch_holes or inners.is_empty():
			result.append(ring)
			continue
		var fragments: Array = [ring]
		for inner_group in _group_connected_way_ids(inners, ways_by_id, nodes, center_lat, center_lon):
			var hole := _assemble_ring(inner_group, ways_by_id, nodes, center_lat, center_lon)
			if hole.size() < 3:
				continue
			var next: Array = []
			for frag in fragments:
				if frag is PackedVector2Array:
					for piece in Geometry2D.exclude_polygons(frag as PackedVector2Array, hole):
						next.append(piece)
			if not next.is_empty():
				fragments = next
		for frag in fragments:
			if frag is PackedVector2Array and (frag as PackedVector2Array).size() >= 3:
				result.append(frag as PackedVector2Array)
	return result


static func _group_connected_way_ids(way_ids: Array, ways_by_id: Dictionary,
		nodes: Dictionary, center_lat: float, center_lon: float) -> Array:
	if way_ids.is_empty():
		return []
	var endpoints: Dictionary = {}
	for wid_v in way_ids:
		var wid := int(wid_v)
		var way: Dictionary = ways_by_id.get(wid, {})
		var seg := _way_to_local_poly(way, nodes, center_lat, center_lon, false)
		if seg.size() < 2:
			continue
		endpoints[wid] = {"start": seg[0], "end": seg[seg.size() - 1]}
	var unused: Array = []
	for wid_v in way_ids:
		if endpoints.has(int(wid_v)):
			unused.append(int(wid_v))
	var groups: Array = []
	while not unused.is_empty():
		var stack: Array = [int(unused.pop_front())]
		var group: Array = []
		while not stack.is_empty():
			var wid := int(stack.pop_back())
			if not endpoints.has(wid):
				continue
			group.append(wid)
			for i in range(unused.size() - 1, -1, -1):
				var other := int(unused[i])
				if not endpoints.has(other):
					unused.remove_at(i)
					continue
				if _endpoints_touch(endpoints[wid], endpoints[other]):
					stack.append(other)
					unused.remove_at(i)
		if not group.is_empty():
			groups.append(group)
	return groups


static func _endpoints_touch(a: Dictionary, b: Dictionary) -> bool:
	var a_start: Vector2 = a["start"]
	var a_end: Vector2 = a["end"]
	var b_start: Vector2 = b["start"]
	var b_end: Vector2 = b["end"]
	return (
		a_start.distance_squared_to(b_start) <= JOIN_EPS_SQ
		or a_start.distance_squared_to(b_end) <= JOIN_EPS_SQ
		or a_end.distance_squared_to(b_start) <= JOIN_EPS_SQ
		or a_end.distance_squared_to(b_end) <= JOIN_EPS_SQ
	)


static func _assemble_ring(way_ids: Array, ways_by_id: Dictionary, nodes: Dictionary,
		center_lat: float, center_lon: float) -> PackedVector2Array:
	var remaining: Array = []
	for wid_v in way_ids:
		remaining.append(int(wid_v))
	var ring := PackedVector2Array()
	while not remaining.is_empty():
		if ring.is_empty():
			var first_wid := int(remaining.pop_front())
			var first_way: Dictionary = ways_by_id.get(first_wid, {})
			ring = _way_to_local_poly(first_way, nodes, center_lat, center_lon, false)
			continue
		var joined := false
		for i in remaining.size():
			var wid := int(remaining[i])
			var way: Dictionary = ways_by_id.get(wid, {})
			var seg := _way_to_local_poly(way, nodes, center_lat, center_lon, false)
			if seg.size() < 2:
				remaining.remove_at(i)
				joined = true
				break
			var trial := ring.duplicate()
			if _try_join_segment(trial, seg) or _try_join_segment(trial, _reverse_poly(seg)):
				ring = trial
				remaining.remove_at(i)
				joined = true
				break
		if not joined:
			break
	if ring.size() >= 3 and ring[0].distance_squared_to(ring[ring.size() - 1]) > JOIN_EPS_SQ:
		ring.append(ring[0])
	return ring


static func _try_join_segment(ring: PackedVector2Array, seg: PackedVector2Array) -> bool:
	if ring.is_empty() or seg.size() < 2:
		return false
	var head: Vector2 = ring[0]
	var tail: Vector2 = ring[ring.size() - 1]
	var seg_start: Vector2 = seg[0]
	var seg_end: Vector2 = seg[seg.size() - 1]
	if tail.distance_squared_to(seg_start) <= JOIN_EPS_SQ:
		for i in range(1, seg.size()):
			ring.append(seg[i])
		return true
	if tail.distance_squared_to(seg_end) <= JOIN_EPS_SQ:
		for i in range(seg.size() - 2, -1, -1):
			ring.append(seg[i])
		return true
	if head.distance_squared_to(seg_end) <= JOIN_EPS_SQ:
		var merged := seg.duplicate()
		for i in range(1, ring.size()):
			merged.append(ring[i])
		ring.clear()
		for p in merged:
			ring.append(p)
		return true
	if head.distance_squared_to(seg_start) <= JOIN_EPS_SQ:
		var merged := _reverse_poly(seg)
		for i in range(1, ring.size()):
			merged.append(ring[i])
		ring.clear()
		for p in merged:
			ring.append(p)
		return true
	return false


static func _reverse_poly(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in range(poly.size() - 1, -1, -1):
		out.append(poly[i])
	return out


static func _buffer_polyline(pts: PackedVector2Array, half_w: float) -> PackedVector2Array:
	if pts.size() < 2 or half_w <= 0.0:
		return PackedVector2Array()
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for i in pts.size():
		var tangent := _segment_tangent(pts, i)
		if tangent.length_squared() < 1e-8:
			continue
		var normal := Vector2(-tangent.y, tangent.x).normalized() * half_w
		left.append(pts[i] + normal)
		right.append(pts[i] - normal)
	if left.size() < 2:
		return PackedVector2Array()
	right.reverse()
	var out := left
	for p in right:
		out.append(p)
	if out.size() >= 3 and out[0].distance_squared_to(out[out.size() - 1]) > JOIN_EPS_SQ:
		out.append(out[0])
	return out


static func _segment_tangent(pts: PackedVector2Array, i: int) -> Vector2:
	if pts.size() < 2:
		return Vector2.ZERO
	if i == 0:
		return pts[1] - pts[0]
	if i == pts.size() - 1:
		return pts[i] - pts[i - 1]
	return (pts[i + 1] - pts[i - 1]).normalized()


static func _waterway_half_width(tags: Dictionary) -> float:
	for key in ["width", "waterway:width"]:
		if tags.has(key):
			var w := _parse_width_m(str(tags[key]))
			if w > 0.0:
				return w * 0.5
	var ww := str(tags.get("waterway", "river"))
	return float(WATERWAY_HALF_WIDTH.get(ww, 10.0))


static func _parse_width_m(raw: String) -> float:
	var s := raw.strip_edges().to_lower()
	if s.is_empty():
		return 0.0
	if s.contains("ft"):
		s = s.replace("feet", "").replace("foot", "").replace("ft", "").strip_edges()
		var feet := s.to_float()
		return feet * 0.3048 if not is_nan(feet) and feet > 0.0 else 0.0
	s = s.trim_suffix("m").strip_edges()
	var metres := s.to_float()
	return metres if not is_nan(metres) and metres > 0.0 else 0.0


static func _water_kind(tags: Dictionary) -> String:
	if tags.has("water"):
		return str(tags["water"])
	if tags.has("natural"):
		return str(tags["natural"])
	if tags.has("landuse"):
		return str(tags["landuse"])
	if tags.has("waterway"):
		return str(tags["waterway"])
	return "water"


static func _way_to_local_poly(way: Dictionary, nodes: Dictionary,
		center_lat: float, center_lon: float, require_closed: bool = true) -> PackedVector2Array:
	var node_ids: Variant = way.get("nodes", [])
	if not (node_ids is Array) or (node_ids as Array).size() < 2:
		return PackedVector2Array()
	var poly := PackedVector2Array()
	for nid_v in node_ids:
		var nid := int(nid_v)
		if not nodes.has(nid):
			poly.clear()
			break
		var ll: Vector2 = nodes[nid]
		poly.append(GeoMath.lonlat_to_local_m(ll.y, ll.x, center_lat, center_lon))
	if poly.size() < 2:
		return PackedVector2Array()
	if require_closed and poly.size() >= 3:
		if poly[0].distance_squared_to(poly[poly.size() - 1]) > JOIN_EPS_SQ:
			pass
	return poly


static func _polygon_area(poly: PackedVector2Array) -> float:
	if poly.size() < 3:
		return 0.0
	var area := 0.0
	for i in poly.size():
		var j := (i + 1) % poly.size()
		area += poly[i].x * poly[j].y - poly[j].x * poly[i].y
	return absf(area) * 0.5

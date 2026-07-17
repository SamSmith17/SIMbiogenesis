class_name GraphLayout
extends RefCounted

## Push-apart overlap resolver and fit-to-view helpers for the system graph canvas.

const DEFAULT_PADDING := 24.0
const DEFAULT_ITERATIONS := 48
## Shared with GraphCanvas — wide enough to frame a sprawling graph or a 0.5 m panel.
const ZOOM_MIN := 0.005
const ZOOM_MAX := 512.0

## Off-canvas / hidden summary nodes must not expand fit-to-view or push the main cluster.
const HIDDEN_LAYOUT_IDS: Array[String] = ["virtual_solar_array"]


static func include_in_layout(item: Dictionary) -> bool:
	if item.is_empty():
		return false
	var iid := str(item.get("id", ""))
	if iid.is_empty():
		return false
	if iid in HIDDEN_LAYOUT_IDS:
		return false
	if bool(item.get("layout_exclude", false)):
		return false
	return true


static func filter_layout_items(items: Array) -> Array:
	var out: Array = []
	for it in items:
		if it is Dictionary and include_in_layout(it as Dictionary):
			out.append(it)
	return out


static func has_overlaps(items: Array, padding: float = DEFAULT_PADDING) -> bool:
	var filtered := filter_layout_items(items)
	for i in filtered.size():
		for j in range(i + 1, filtered.size()):
			var ra := item_rect(filtered[i] as Dictionary, padding * 0.5)
			var rb := item_rect(filtered[j] as Dictionary, padding * 0.5)
			if rects_overlap(ra, rb):
				return true
	return false


static func item_rect(item: Dictionary, padding: float = 0.0) -> Rect2:
	var x := float(item.get("x", 0.0))
	var y := float(item.get("y", 0.0))
	var w := float(item.get("width", 120.0))
	var h := float(item.get("height", 90.0))
	return Rect2(x - padding, y - padding, w + padding * 2.0, h + padding * 2.0)


static func rects_overlap(a: Rect2, b: Rect2) -> bool:
	return a.intersects(b)


static func separation_vector(a: Rect2, b: Rect2) -> Vector2:
	var overlap_x := minf(a.end.x, b.end.x) - maxf(a.position.x, b.position.x)
	var overlap_y := minf(a.end.y, b.end.y) - maxf(a.position.y, b.position.y)
	if overlap_x <= 0.0 or overlap_y <= 0.0:
		return Vector2.ZERO
	if overlap_x < overlap_y:
		var dir := 1.0 if a.get_center().x < b.get_center().x else -1.0
		return Vector2(overlap_x * dir, 0.0)
	var dir_y := 1.0 if a.get_center().y < b.get_center().y else -1.0
	return Vector2(0.0, overlap_y * dir_y)


## Resolve overlaps in-place on item dictionaries; returns position patches {id: Vector2}.
static func resolve_overlaps(items: Array, padding: float = DEFAULT_PADDING,
		iterations: int = DEFAULT_ITERATIONS) -> Dictionary:
	items = filter_layout_items(items)
	var patches: Dictionary = {}
	if items.size() < 2:
		return patches
	var positions: Dictionary = {}
	for it in items:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		var iid := str(d.get("id", ""))
		if iid.is_empty():
			continue
		positions[iid] = Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
	var ids: Array = positions.keys()
	for _iter in iterations:
		var moved := false
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				var id_a := str(ids[i])
				var id_b := str(ids[j])
				var ra := Rect2(positions[id_a], _size_for_id(items, id_a))
				var rb := Rect2(positions[id_b], _size_for_id(items, id_b))
				ra = ra.grow(padding * 0.5)
				rb = rb.grow(padding * 0.5)
				var sep := separation_vector(ra, rb)
				if sep == Vector2.ZERO:
					continue
				positions[id_a] -= sep * 0.5
				positions[id_b] += sep * 0.5
				moved = true
		if not moved:
			break
	for iid in positions:
		patches[iid] = positions[iid]
	return patches


static func _size_for_id(items: Array, item_id: String) -> Vector2:
	for it in items:
		if not (it is Dictionary):
			continue
		if str((it as Dictionary).get("id", "")) == item_id:
			return Vector2(
				float((it as Dictionary).get("width", 120.0)),
				float((it as Dictionary).get("height", 90.0)))
	return Vector2(120.0, 90.0)


static func content_bounds(items: Array, padding: float = DEFAULT_PADDING) -> Rect2:
	items = filter_layout_items(items)
	if items.is_empty():
		return Rect2(-200.0, -200.0, 400.0, 400.0)
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for it in items:
		if not (it is Dictionary):
			continue
		var r := item_rect(it as Dictionary, 0.0)
		min_x = minf(min_x, r.position.x)
		min_y = minf(min_y, r.position.y)
		max_x = maxf(max_x, r.end.x)
		max_y = maxf(max_y, r.end.y)
	return Rect2(min_x - padding, min_y - padding,
		max_x - min_x + padding * 2.0, max_y - min_y + padding * 2.0)


## Pan/zoom so `bounds` fits in `canvas_size` with margin fraction.
static func compute_fit_view(bounds: Rect2, canvas_size: Vector2,
		margin_frac: float = 0.12) -> Dictionary:
	if bounds.size.x < 1.0 or bounds.size.y < 1.0:
		return {"pan_x": 0.0, "pan_y": 0.0, "zoom": 1.0}
	var margin := canvas_size * margin_frac
	var avail := canvas_size - margin * 2.0
	var zx := avail.x / bounds.size.x
	var zy := avail.y / bounds.size.y
	var zoom := clampf(minf(zx, zy), ZOOM_MIN, ZOOM_MAX)
	var center := bounds.get_center()
	var pan := -center * zoom
	return {"pan_x": pan.x, "pan_y": pan.y, "zoom": zoom}


## Nudge `pos` so a new item at `size` does not overlap existing items.
static func nudge_spawn_position(pos: Vector2, size: Vector2, items: Array,
		padding: float = DEFAULT_PADDING) -> Vector2:
	items = filter_layout_items(items)
	var candidate := pos
	var test_rect := Rect2(candidate, size)
	for _attempt in 32:
		var hit := false
		for it in items:
			if not (it is Dictionary):
				continue
			var existing := item_rect(it as Dictionary, padding * 0.5)
			if test_rect.intersects(existing):
				hit = true
				candidate += Vector2(padding + size.x * 0.15, padding * 0.6)
				test_rect = Rect2(candidate, size)
				break
		if not hit:
			break
	return candidate

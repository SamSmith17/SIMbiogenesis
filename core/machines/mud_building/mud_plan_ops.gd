class_name MudPlanOps
extends RefCounted

## Validation + cleanup for mud building plan loops and open wall runs.


static func close_loop(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var out := pts.duplicate()
	if out[0].distance_to(out[out.size() - 1]) > 0.01:
		out.append(out[0])
	return out


static func open_ring(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 2:
		return pts
	if pts[0].distance_to(pts[pts.size() - 1]) <= 0.01:
		var out := PackedVector2Array()
		for i in range(pts.size() - 1):
			out.append(pts[i])
		return out
	return pts.duplicate()


static func snap_to_grid(pts: PackedVector2Array, grid_mm: float) -> PackedVector2Array:
	var g := maxf(grid_mm, 1.0)
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(Vector2(roundf(p.x / g) * g, roundf(p.y / g) * g))
	return out


static func clamp_to_bed(pts: PackedVector2Array, work_x: float, work_y: float,
		margin: float = 0.0) -> PackedVector2Array:
	var hx := work_x * 0.5 - margin
	var hy := work_y * 0.5 - margin
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(Vector2(clampf(p.x, -hx, hx), clampf(p.y, -hy, hy)))
	return out


static func perimeter_mm(pts: PackedVector2Array) -> float:
	var ring := close_loop(pts)
	var total := 0.0
	for i in range(1, ring.size()):
		total += ring[i].distance_to(ring[i - 1])
	return total


static func path_length_mm(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	return total


## Arc-length resample an open polyline to ~spacing_mm (keeps endpoints).
static func densify_open(pts: PackedVector2Array, spacing_mm: float) -> PackedVector2Array:
	if pts.size() < 2:
		return pts.duplicate()
	var spacing := maxf(spacing_mm, 2.0)
	var total := path_length_mm(pts)
	if total < spacing * 1.5:
		return pts.duplicate()
	var n := clampi(int(ceil(total / spacing)) + 1, 2, 4096)
	var out := PackedVector2Array()
	out.resize(n)
	var lengths: PackedFloat32Array = PackedFloat32Array()
	lengths.resize(pts.size())
	lengths[0] = 0.0
	for i in range(1, pts.size()):
		lengths[i] = lengths[i - 1] + pts[i].distance_to(pts[i - 1])
	for s in n:
		var target := total * float(s) / float(n - 1)
		var j := 1
		while j < pts.size() - 1 and lengths[j] < target:
			j += 1
		var seg := lengths[j] - lengths[j - 1]
		var f := 0.0 if seg < 1e-6 else (target - lengths[j - 1]) / seg
		out[s] = pts[j - 1].lerp(pts[j], clampf(f, 0.0, 1.0))
	return out


## Densify a closed ring (open or closed input); returns open ring (no dup end).
static func densify_ring(pts: PackedVector2Array, spacing_mm: float) -> PackedVector2Array:
	var open := open_ring(pts)
	if open.size() < 3:
		return open
	var closed := close_loop(open)
	var dense := densify_open(closed, spacing_mm)
	return open_ring(dense)


static func area_mm2(pts: PackedVector2Array) -> float:
	var ring := open_ring(pts)
	if ring.size() < 3:
		return 0.0
	var a := 0.0
	for i in ring.size():
		var j := (i + 1) % ring.size()
		a += ring[i].x * ring[j].y - ring[j].x * ring[i].y
	return absf(a) * 0.5


static func validate_loop(pts: PackedVector2Array, nozzle_mm: float,
		work_x: float, work_y: float) -> Dictionary:
	var cleaned := open_ring(pts)
	if cleaned.size() < 3:
		return {"ok": false, "error": "need at least 3 points", "cleaned": cleaned}
	var dedup := PackedVector2Array()
	dedup.append(cleaned[0])
	for i in range(1, cleaned.size()):
		if cleaned[i].distance_to(dedup[dedup.size() - 1]) >= maxf(nozzle_mm * 0.15, 5.0):
			dedup.append(cleaned[i])
	if dedup.size() >= 3 and dedup[0].distance_to(dedup[dedup.size() - 1]) < maxf(nozzle_mm * 0.15, 5.0):
		dedup.remove_at(dedup.size() - 1)
	if dedup.size() < 3:
		return {"ok": false, "error": "loop collapsed after cleanup", "cleaned": dedup}
	cleaned = clamp_to_bed(dedup, work_x, work_y, nozzle_mm * 0.5)
	var area := area_mm2(cleaned)
	var min_area := nozzle_mm * nozzle_mm * 4.0
	if area < min_area:
		return {"ok": false, "error": "loop too small for nozzle", "cleaned": cleaned}
	var tri := Geometry2D.triangulate_polygon(cleaned)
	if tri.is_empty():
		return {"ok": false, "error": "self-intersecting or non-simple loop", "cleaned": cleaned}
	return {"ok": true, "error": "", "cleaned": cleaned}


## Open wall run: ≥2 points, min length ~2× nozzle, stays on bed.
static func validate_open_path(pts: PackedVector2Array, nozzle_mm: float,
		work_x: float, work_y: float) -> Dictionary:
	var cleaned := pts.duplicate()
	if cleaned.size() < 2:
		return {"ok": false, "error": "open wall needs ≥2 points", "cleaned": cleaned}
	# Drop accidental close.
	if cleaned.size() >= 3 and cleaned[0].distance_to(cleaned[cleaned.size() - 1]) < 0.01:
		cleaned.remove_at(cleaned.size() - 1)
	var dedup := PackedVector2Array()
	dedup.append(cleaned[0])
	for i in range(1, cleaned.size()):
		if cleaned[i].distance_to(dedup[dedup.size() - 1]) >= maxf(nozzle_mm * 0.15, 5.0):
			dedup.append(cleaned[i])
	if dedup.size() < 2:
		return {"ok": false, "error": "open wall collapsed", "cleaned": dedup}
	cleaned = clamp_to_bed(dedup, work_x, work_y, nozzle_mm * 0.5)
	if path_length_mm(cleaned) < nozzle_mm * 2.0:
		return {"ok": false, "error": "open wall too short", "cleaned": cleaned}
	return {"ok": true, "error": "", "cleaned": cleaned}


static func validate_spec(spec: MudBuildingSpec) -> Dictionary:
	if spec == null:
		return {"ok": false, "error": "no spec", "loops": [], "open_paths": []}
	if spec.loops.is_empty() and spec.open_paths.is_empty():
		return {"ok": false, "error": "draw a wall plan (closed room or open run)",
			"loops": [], "open_paths": []}
	if spec.height_mm < spec.layer_height_mm:
		return {"ok": false, "error": "height shorter than one layer",
			"loops": [], "open_paths": []}
	var lw := maxf(spec.line_width_mm, spec.nozzle_mm * 0.5)
	var min_gap := maxf(lw * 0.35, 10.0)
	if spec.camber_mode == MudBuildingSpec.CamberMode.NONE:
		if spec.shell_gap_mm < min_gap * 0.9:
			return {"ok": false, "error": "shell gap too small for nozzle",
				"loops": [], "open_paths": []}
	else:
		var min_th := minf(spec.thickness_base_mm, spec.thickness_top_mm)
		if min_th < lw + min_gap * 0.5:
			return {"ok": false, "error": "wall thinner than nozzle + shell gap",
				"loops": [], "open_paths": []}
	var out_loops: Array = []
	for loop: Variant in spec.loops:
		if not (loop is PackedVector2Array):
			continue
		var v := validate_loop(loop as PackedVector2Array, spec.nozzle_mm,
			spec.work_x_mm, spec.work_y_mm)
		if not bool(v.get("ok", false)):
			return {"ok": false, "error": str(v.get("error", "?")),
				"loops": out_loops, "open_paths": []}
		out_loops.append(v.get("cleaned", PackedVector2Array()))
	var out_open: Array = []
	for path: Variant in spec.open_paths:
		if not (path is PackedVector2Array):
			continue
		var vo := validate_open_path(path as PackedVector2Array, spec.nozzle_mm,
			spec.work_x_mm, spec.work_y_mm)
		if not bool(vo.get("ok", false)):
			return {"ok": false, "error": str(vo.get("error", "?")),
				"loops": out_loops, "open_paths": out_open}
		out_open.append(vo.get("cleaned", PackedVector2Array()))
	if out_loops.is_empty() and out_open.is_empty():
		return {"ok": false, "error": "no valid walls", "loops": [], "open_paths": []}
	return {"ok": true, "error": "", "loops": out_loops, "open_paths": out_open}


## Normalize opening dict; returns {} if invalid.
static func normalize_opening(o: Dictionary, loop_count: int, height_mm: float) -> Dictionary:
	var li := int(o.get("loop_index", 0))
	if li < 0 or li >= loop_count:
		return {}
	var t0 := clampf(float(o.get("t0", 0.0)), 0.0, 0.999)
	var t1 := clampf(float(o.get("t1", 0.0)), 0.0, 0.999)
	if absf(t1 - t0) < 0.02:
		return {}
	if t1 < t0:
		var tmp := t0
		t0 = t1
		t1 = tmp
	var lintel := clampf(float(o.get("lintel_mm", 2100.0)), 200.0, height_mm)
	return {"loop_index": li, "t0": t0, "t1": t1, "lintel_mm": lintel}

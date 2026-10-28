class_name StlLoader
extends RefCounted

## Loads a real STL mesh (binary or ASCII) and reduces it to the numbers a
## simulated machine needs: bounding box (mm), solid volume (mm3, via the signed
## tetrahedron sum), and — since an STL carries no toolpath — a synthesized
## boustrophedon raster scan path INSIDE the bounding box, layer by layer. That
## gives the 3D machine a plausible "real-ish" motion to trace and a
## volume-derived material/time estimate, consistent with the decimated-real-path
## approach used for G-code. Assumes STL units are millimetres (the near-universal
## convention for 3D-print/CNC STLs).

const LAYER_HEIGHT_MM := 8.0
## Cap on synthesized layers for the motion path (not a true slicer). Raised so
## fine FDM (0.3–1.5 mm layers on ~50–150 mm parts) still shows layered Z motion.
const MAX_LAYERS := 80
const RASTER_STEP_MM := 12.0
## Approximate volumetric material throughput used to estimate print time from a
## model volume when no toolpath timing exists (mm3 per minute). Retained for
## reference; print TIME is now derived from toolpath length / feed (see below).
const DEFAULT_VOL_RATE_MM3_MIN := 4000.0
## Nozzle travel/print feed (mm/s) used to turn the synthesized toolpath LENGTH
## into a watchable, size-scaling print time. Volume-based timing made a full-size
## large-format print take thousands of sim-hours (progress looked frozen); a
## feed-based estimate scales linearly with the print and stays observable.
const DEFAULT_PRINT_SPEED_MM_S := 120.0
## Floor so a tiny model still takes a few visible seconds of sim time.
const MIN_PRINT_TIME_HR := 0.0025


static func parse_file(path: String, opts: Dictionary = {}) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "error": "file not found"}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "cannot open"}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return parse_bytes(bytes, opts)


## opts (all optional): "mode" = "solid"|"vase" (spiral vase = single perimeter,
## no infill), "layer_height_mm", "line_width_mm" (wall/nozzle width),
## "scale" = print scale applied to the model so the material/time estimate
## reflects the up-/down-scaled real print, not the raw STL size.
static func parse_bytes(bytes: PackedByteArray, opts: Dictionary = {}) -> Dictionary:
	if bytes.size() < 15:
		return {"ok": false, "error": "empty"}
	var tris: Array = []
	if _looks_ascii(bytes):
		tris = _parse_ascii(bytes.get_string_from_utf8())
	if tris.is_empty():
		tris = _parse_binary(bytes)
	if tris.is_empty():
		return {"ok": false, "error": "no triangles"}

	var bmin := Vector3(INF, INF, INF)
	var bmax := Vector3(-INF, -INF, -INF)
	var vol6 := 0.0
	for t: Array in tris:
		var a: Vector3 = t[0]
		var b: Vector3 = t[1]
		var c: Vector3 = t[2]
		vol6 += a.dot(b.cross(c))
		for v: Vector3 in t:
			bmin = Vector3(minf(bmin.x, v.x), minf(bmin.y, v.y), minf(bmin.z, v.z))
			bmax = Vector3(maxf(bmax.x, v.x), maxf(bmax.y, v.y), maxf(bmax.z, v.z))
	var solid_mm3 := absf(vol6) / 6.0

	var mode := String(opts.get("mode", "solid")).to_lower()
	var layer_h := maxf(float(opts.get("layer_height_mm", LAYER_HEIGHT_MM)), 0.05)
	var line_w := maxf(float(opts.get("line_width_mm", RASTER_STEP_MM)), 0.1)
	var scale := maxf(float(opts.get("scale", 1.0)), 0.001)
	var speed := maxf(float(opts.get("print_speed_mm_s", DEFAULT_PRINT_SPEED_MM_S)), 1.0)

	var path: Dictionary
	# Volume actually deposited (drives MATERIAL cost, not time) — see
	# estimate_volume_mm3 for the solid (scale³) vs. spiral-vase (scale²) model.
	var volume_mm3 := estimate_volume_mm3(bmin, bmax, solid_mm3, opts)
	if mode == "vase":
		path = _synth_vase_path(bmin, bmax, layer_h)
	else:
		path = _synth_scan_path(bmin, bmax, layer_h, line_w)
	var dec := Toolpath.decimate(path.get("points"), path.get("extruding"), Toolpath.MAX_SEGMENTS)
	# Print TIME = toolpath length (scaled to the real print size) / feed. Uses the
	# FULL synth path length (before decimation) so it doesn't depend on the segment
	# budget, and scales linearly with the model so a 6 ft print is minutes, not
	# thousands of hours.
	var path_len_mm := _path_length(path.get("points", PackedVector3Array()))
	var est_time_hr := maxf((path_len_mm * scale / speed) / 3600.0, MIN_PRINT_TIME_HR)
	return {
		"ok": true,
		"kind": "stl",
		"mode": mode,
		"points": dec.get("points", PackedVector3Array()),
		"extruding": dec.get("extruding", PackedInt32Array()),
		"bounds_min": bmin,
		"bounds_max": bmax,
		"triangles": tris.size(),
		"solid_volume_mm3": solid_mm3,
		"volume_mm3": volume_mm3,
		"extrusion_mm": 0.0,
		"layer_height_mm": layer_h,
		"line_width_mm": line_w,
		"print_scale": scale,
		"print_speed_mm_s": speed,
		"path_length_mm": path_len_mm,
		"est_time_hr": est_time_hr,
		"point_count": (dec.get("points", PackedVector3Array()) as PackedVector3Array).size(),
	}


## Summed segment length (mm, model units) of a polyline — the pre-decimation
## toolpath length that feeds the feed-based print-time estimate.
static func _path_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total


## Deposited material volume (mm³) for the given slicer opts. Solid = full body ×
## scale³; spiral vase = single-wall shell = footprint perimeter × wall width ×
## height × scale². Shared by parse_bytes and the modal's live estimate.
static func estimate_volume_mm3(bmin: Vector3, bmax: Vector3, solid_mm3: float,
		opts: Dictionary = {}) -> float:
	var mode := String(opts.get("mode", "solid")).to_lower()
	var scale := maxf(float(opts.get("scale", 1.0)), 0.001)
	var line_w := maxf(float(opts.get("line_width_mm", RASTER_STEP_MM)), 0.1)
	var layer_h := maxf(float(opts.get("layer_height_mm", LAYER_HEIGHT_MM)), 0.05)
	var size := bmax - bmin
	if mode == "vase":
		var perim := 2.0 * (maxf(size.x, 0.0) + maxf(size.y, 0.0))
		return perim * scale * line_w * maxf(size.z, layer_h) * scale
	return maxf(solid_mm3, 0.0) * scale * scale * scale


## Analytic estimate (mm, unscaled) of the synthesized toolpath length for the
## given opts — mirrors _synth_vase_path / _synth_scan_path closely enough for a
## live UI readout without re-parsing the mesh on every slider drag.
static func estimate_path_length_mm(bmin: Vector3, bmax: Vector3, opts: Dictionary = {}) -> float:
	var mode := String(opts.get("mode", "solid")).to_lower()
	var layer_h := maxf(float(opts.get("layer_height_mm", LAYER_HEIGHT_MM)), 0.05)
	var line_w := maxf(float(opts.get("line_width_mm", RASTER_STEP_MM)), 0.1)
	var size := bmax - bmin
	if size.x <= 0.0 or size.y <= 0.0:
		return 0.0
	var height := maxf(size.z, layer_h)
	if mode == "vase":
		var layers := clampf(height / layer_h, 1.0, float(MAX_LAYERS))
		var rx := size.x * 0.5
		var ry := size.y * 0.5
		# Ramanujan ellipse-perimeter approximation.
		var perim := PI * (3.0 * (rx + ry) - sqrt((3.0 * rx + ry) * (rx + 3.0 * ry)))
		return perim * layers
	var layers_i := clampi(int(ceil(height / layer_h)), 1, MAX_LAYERS)
	var rows := clampi(int(ceil(size.y / maxf(line_w, 0.1))), 1, 200)
	# Per layer: (rows+1) width passes + the y-advance connectors (~size.y total).
	return float(layers_i) * (float(rows + 1) * size.x + size.y)


## Feed-based print-time estimate (hours) for the given opts, scaled to the real
## print size. Matches parse_bytes' timing model.
static func estimate_time_hr(bmin: Vector3, bmax: Vector3, opts: Dictionary = {}) -> float:
	var scale := maxf(float(opts.get("scale", 1.0)), 0.001)
	var speed := maxf(float(opts.get("print_speed_mm_s", DEFAULT_PRINT_SPEED_MM_S)), 1.0)
	var len_mm := estimate_path_length_mm(bmin, bmax, opts)
	return maxf((len_mm * scale / speed) / 3600.0, MIN_PRINT_TIME_HR)


## Builds a renderable ArrayMesh from an STL file for the print-object ghost +
## sliced reveal. STL/CAD is Z-up in millimetres; we convert to Godot's Y-up
## metres, center the footprint on the origin, and seat the base at y=0 so the
## reveal shader can clip cleanly bottom→top and placement is predictable.
## Returns null on failure.
static func build_mesh(path: String) -> ArrayMesh:
	if path.is_empty() or not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return build_mesh_from_bytes(bytes)


static func build_mesh_from_bytes(bytes: PackedByteArray) -> ArrayMesh:
	if bytes.size() < 15:
		return null
	var tris: Array = []
	if _looks_ascii(bytes):
		tris = _parse_ascii(bytes.get_string_from_utf8())
	if tris.is_empty():
		tris = _parse_binary(bytes)
	if tris.is_empty():
		return null
	var bmin := Vector3(INF, INF, INF)
	var bmax := Vector3(-INF, -INF, -INF)
	for t: Array in tris:
		for v: Vector3 in t:
			bmin = Vector3(minf(bmin.x, v.x), minf(bmin.y, v.y), minf(bmin.z, v.z))
			bmax = Vector3(maxf(bmax.x, v.x), maxf(bmax.y, v.y), maxf(bmax.z, v.z))
	var cx := (bmin.x + bmax.x) * 0.5
	var cy := (bmin.y + bmax.y) * 0.5
	var base := bmin.z
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for t: Array in tris:
		# STL winding a,b,c; convert Z-up mm -> Y-up metres and keep front faces.
		for v: Vector3 in [t[0], t[1], t[2]]:
			st.add_vertex(Vector3((v.x - cx), (v.z - base), -(v.y - cy)) * 0.001)
	st.generate_normals()
	return st.commit()


## Boustrophedon (zig-zag) raster covering the bbox footprint, stacked over a
## bounded number of layers up the Z extent.
static func _synth_scan_path(bmin: Vector3, bmax: Vector3, layer_h := LAYER_HEIGHT_MM,
		row_step := RASTER_STEP_MM) -> Dictionary:
	var pts := PackedVector3Array()
	var ext := PackedInt32Array()
	var size := bmax - bmin
	if size.x <= 0.0 or size.y <= 0.0:
		return {"points": pts, "extruding": ext}
	var height := maxf(size.z, layer_h)
	var layers := clampi(int(ceil(height / layer_h)), 1, MAX_LAYERS)
	var rows := clampi(int(ceil(size.y / maxf(row_step, 0.1))), 1, 200)
	for l in range(layers):
		var z := bmin.z + (float(l) + 0.5) * height / float(layers)
		for r in range(rows + 1):
			var y := bmin.y + size.y * float(r) / float(rows)
			var left := (r % 2) == 0
			var x0 := bmin.x if left else bmax.x
			var x1 := bmax.x if left else bmin.x
			pts.append(Vector3(x0, y, z))
			ext.append(1)
			pts.append(Vector3(x1, y, z))
			ext.append(1)
	return {"points": pts, "extruding": ext}


## Spiral-vase toolpath: one continuous single-wall perimeter loop that rises
## smoothly up the Z extent (no infill, no separate layers) — the nozzle traces
## a rising elliptical spiral around the footprint. This is a plausible *motion*
## for the animation, not a true cross-section slice (kept intentionally simple).
static func _synth_vase_path(bmin: Vector3, bmax: Vector3, layer_h := LAYER_HEIGHT_MM) -> Dictionary:
	var pts := PackedVector3Array()
	var ext := PackedInt32Array()
	var size := bmax - bmin
	if size.x <= 0.0 or size.y <= 0.0:
		return {"points": pts, "extruding": ext}
	var height := maxf(size.z, layer_h)
	var layers := clampf(height / layer_h, 1.0, float(MAX_LAYERS))
	var cx := (bmin.x + bmax.x) * 0.5
	var cy := (bmin.y + bmax.y) * 0.5
	var rx := size.x * 0.5
	var ry := size.y * 0.5
	var seg := 48
	var total := int(round(layers)) * seg
	for i in range(total + 1):
		var t := float(i) / float(total)
		var ang := t * layers * TAU
		var z := bmin.z + t * height
		pts.append(Vector3(cx + rx * cos(ang), cy + ry * sin(ang), z))
		ext.append(1)
	return {"points": pts, "extruding": ext}


## The raw triangles of an STL ([[a, b, c] ...] in the file's own units,
## mm by convention) for the slicer. Binary or ASCII; [] when unreadable.
static func load_triangles(path: String) -> Array:
	if path.is_empty() or not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var bytes := f.get_buffer(f.get_length())
	f.close()
	return triangles_from_bytes(bytes)


static func triangles_from_bytes(bytes: PackedByteArray) -> Array:
	if bytes.size() < 15:
		return []
	var tris: Array = []
	if _looks_ascii(bytes):
		tris = _parse_ascii(bytes.get_string_from_utf8())
	if tris.is_empty():
		tris = _parse_binary(bytes)
	return tris


static func _looks_ascii(bytes: PackedByteArray) -> bool:
	var head := bytes.slice(0, min(256, bytes.size())).get_string_from_ascii().to_lower()
	if not head.begins_with("solid"):
		return false
	# Some binary STLs also start with "solid"; require a "facet" keyword soon.
	return head.contains("facet") or bytes.get_string_from_utf8().to_lower().contains("facet normal")


static func _parse_ascii(text: String) -> Array:
	var tris: Array = []
	var verts: Array = []
	for raw in text.split("\n", false):
		var line := raw.strip_edges().to_lower()
		if line.begins_with("vertex"):
			var parts := line.split(" ", false)
			if parts.size() >= 4:
				verts.append(Vector3(parts[1].to_float(), parts[2].to_float(), parts[3].to_float()))
				if verts.size() == 3:
					tris.append([verts[0], verts[1], verts[2]])
					verts = []
	return tris


static func _parse_binary(bytes: PackedByteArray) -> Array:
	var tris: Array = []
	if bytes.size() < 84:
		return tris
	var count := bytes.decode_u32(80)
	if count <= 0 or 84 + count * 50 > bytes.size():
		return tris
	var off := 84
	for i in range(count):
		# Skip normal (12 bytes), read 3 vertices (9 floats).
		var base := off + 12
		var a := Vector3(bytes.decode_float(base), bytes.decode_float(base + 4), bytes.decode_float(base + 8))
		var b := Vector3(bytes.decode_float(base + 12), bytes.decode_float(base + 16), bytes.decode_float(base + 20))
		var c := Vector3(bytes.decode_float(base + 24), bytes.decode_float(base + 28), bytes.decode_float(base + 32))
		tris.append([a, b, c])
		off += 50
	return tris

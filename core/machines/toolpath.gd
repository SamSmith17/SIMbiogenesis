class_name Toolpath
extends RefCounted

## Parses real machine G-code (RepRap/Marlin/GRBL flavor) into a decimated 3D
## point path plus job totals (bounds, feed/rapid distance, extrusion, estimated
## time). "Decimated real path" — the true toolpath is followed but resampled to
## a bounded segment count (MAX_SEGMENTS) so huge production files stay light for
## the 3D animation. Distances are in millimetres (machine convention); time is
## in hours (simulated-time convention used across the graph).
##
## Supported: G0/G1 linear moves, G20/G21 units (inch/mm), G90/G91 abs/rel,
## X/Y/Z/E/F words, ';' and '(...)' comments. Arcs (G2/G3) are treated as linear
## for pathing (rare in FDM; acceptable for a game preview).

const MAX_SEGMENTS := 2000
## Default rapid feedrate (mm/min) when a G0 has no explicit F on record.
const DEFAULT_RAPID_MM_MIN := 6000.0
const DEFAULT_FEED_MM_MIN := 1500.0
## Cap raw parsing so a pathological file can't exhaust memory.
const MAX_RAW_POINTS := 600000


static func parse_file(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "error": "file not found"}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "cannot open"}
	var text := f.get_as_text()
	f.close()
	return parse_gcode(text)


static func parse_gcode(text: String) -> Dictionary:
	var raw_pts := PackedVector3Array()
	var raw_ext := PackedInt32Array()  # 1 if the segment ENDING at this point extrudes/cuts
	var pos := Vector3.ZERO
	var e_pos := 0.0
	var units := 1.0          # mm per gcode unit (1.0 for G21, 25.4 for G20)
	var absolute := true
	var e_absolute := true
	var feed := DEFAULT_FEED_MM_MIN
	var total_feed := 0.0
	var total_rapid := 0.0
	var extrusion_mm := 0.0
	var time_min := 0.0
	var bmin := Vector3(INF, INF, INF)
	var bmax := Vector3(-INF, -INF, -INF)
	var have_start := false

	for raw_line in text.split("\n", false):
		var line := _strip_comment(raw_line)
		if line.is_empty():
			continue
		var words := line.to_upper().split(" ", false)
		var g := -1
		var has_move := false
		var nx := pos.x
		var ny := pos.y
		var nz := pos.z
		var e_word := NAN
		for w in words:
			if w.length() < 1:
				continue
			var code := w[0]
			var val_s := w.substr(1)
			match code:
				"G":
					g = int(val_s)
					if g == 20:
						units = 25.4
					elif g == 21:
						units = 1.0
					elif g == 90:
						absolute = true
						e_absolute = true
					elif g == 91:
						absolute = false
						e_absolute = false
				"X":
					has_move = true
					var v := val_s.to_float() * units
					nx = v if absolute else pos.x + v
				"Y":
					has_move = true
					var v := val_s.to_float() * units
					ny = v if absolute else pos.y + v
				"Z":
					has_move = true
					var v := val_s.to_float() * units
					nz = v if absolute else pos.z + v
				"E":
					e_word = val_s.to_float() * units
				"F":
					feed = maxf(val_s.to_float() * units, 1.0)
				"M":
					pass
		if g == 92:
			# Set position (no motion). Reset E datum most commonly.
			if not is_nan(e_word):
				e_pos = e_word
			continue
		if not has_move and is_nan(e_word):
			continue
		var target := Vector3(nx, ny, nz)
		var seg := target - pos
		var seg_len := seg.length()
		var e_new := e_pos
		if not is_nan(e_word):
			e_new = e_word if e_absolute else e_pos + e_word
		var de := e_new - e_pos
		var extruding := de > 0.0001
		if extruding:
			extrusion_mm += de
		var is_rapid := g == 0
		if seg_len > 0.0:
			if is_rapid:
				total_rapid += seg_len
				time_min += seg_len / DEFAULT_RAPID_MM_MIN
			else:
				total_feed += seg_len
				time_min += seg_len / maxf(feed, 1.0)
			if not have_start:
				raw_pts.append(pos)
				raw_ext.append(0)
				have_start = true
				bmin = pos
				bmax = pos
			raw_pts.append(target)
			raw_ext.append(1 if extruding else 0)
			bmin = Vector3(minf(bmin.x, target.x), minf(bmin.y, target.y), minf(bmin.z, target.z))
			bmax = Vector3(maxf(bmax.x, target.x), maxf(bmax.y, target.y), maxf(bmax.z, target.z))
		pos = target
		e_pos = e_new
		if raw_pts.size() >= MAX_RAW_POINTS:
			break

	if raw_pts.size() < 2:
		return {"ok": false, "error": "no motion found"}

	var dec := decimate(raw_pts, raw_ext, MAX_SEGMENTS)
	return {
		"ok": true,
		"kind": "gcode",
		"points": dec.get("points", PackedVector3Array()),
		"extruding": dec.get("extruding", PackedInt32Array()),
		"bounds_min": bmin,
		"bounds_max": bmax,
		"total_feed_mm": total_feed,
		"total_rapid_mm": total_rapid,
		"extrusion_mm": extrusion_mm,
		"est_time_hr": time_min / 60.0,
		"point_count": (dec.get("points", PackedVector3Array()) as PackedVector3Array).size(),
		"raw_point_count": raw_pts.size(),
	}


## Uniform arc-length resample to at most `max_segments+1` points, preserving
## start/end and carrying an extruding flag by nearest source segment. Fast,
## deterministic, and shape-preserving enough for a game preview.
static func decimate(points: PackedVector3Array, extruding: PackedInt32Array,
		max_segments: int) -> Dictionary:
	var n := points.size()
	if n <= max_segments + 1 or n < 2:
		return {"points": points, "extruding": extruding}
	# Cumulative arc length.
	var cum := PackedFloat32Array()
	cum.resize(n)
	cum[0] = 0.0
	for i in range(1, n):
		cum[i] = cum[i - 1] + points[i].distance_to(points[i - 1])
	var total := cum[n - 1]
	var out_pts := PackedVector3Array()
	var out_ext := PackedInt32Array()
	if total <= 0.0:
		out_pts.append(points[0])
		out_pts.append(points[n - 1])
		out_ext.append(0)
		out_ext.append(extruding[n - 1] if extruding.size() == n else 0)
		return {"points": out_pts, "extruding": out_ext}
	var seg_idx := 1
	for s in range(max_segments + 1):
		var target_len := total * float(s) / float(max_segments)
		while seg_idx < n - 1 and cum[seg_idx] < target_len:
			seg_idx += 1
		var a := seg_idx - 1
		var span := cum[seg_idx] - cum[a]
		var t := 0.0 if span <= 0.0 else (target_len - cum[a]) / span
		out_pts.append(points[a].lerp(points[seg_idx], clampf(t, 0.0, 1.0)))
		out_ext.append(extruding[seg_idx] if extruding.size() == n else 0)
	return {"points": out_pts, "extruding": out_ext}


static func _strip_comment(line: String) -> String:
	var s := line
	var semi := s.find(";")
	if semi >= 0:
		s = s.substr(0, semi)
	# Strip (...) inline comments.
	while true:
		var op := s.find("(")
		if op < 0:
			break
		var cl := s.find(")", op)
		if cl < 0:
			s = s.substr(0, op)
			break
		s = s.substr(0, op) + " " + s.substr(cl + 1)
	return s.strip_edges()

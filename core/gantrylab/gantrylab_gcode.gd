class_name GantryLabGcode
extends RefCounted

## A G-code reader for the gantry designer: every linear and arc move with
## its feed, extrusion and line number, so the motion planner can play it
## back at real speeds. Reads the RepRap / Marlin / Klipper dialect (G0 G1
## G2 G3 G20 G21 G28 G90 G91 G92 M82 M83, M104/M109/M140/M190 temperatures,
## M3/M5 spindle, M106 fan) and grbl's (the same motion words, $ lines
## ignored). Arcs are expanded into chords (NIST RS274NGC §3.5.3: I J centre
## offsets or R radius, in the XY plane).
##
## Output (a move list, mm):
##   {ok, moves: [{p0, p1, feed_mm_s, e_mm, rapid, line}], bounds_min, bounds_max,
##    extrusion_mm, total_feed_mm, total_rapid_mm, layers, dialect,
##    temps {hotend_c, bed_c}, spindle_rpm, laser_s, lines, warnings}
##
## to_toolpath() turns it into the Toolpath shape the job store / machine
## runtime read (points + extruding flags, decimated), so a job designed here
## can run on the placed machine without a second parser.

const MAX_MOVES := 120000
const ARC_CHORD_MM := 1.0
const ARC_MAX_SEGS := 180
const DEFAULT_FEED_MM_S := 25.0
const DEFAULT_RAPID_MM_S := 100.0


static func parse(text: String) -> Dictionary:
	var moves: Array = []
	var pos := Vector3.ZERO
	var e_pos := 0.0
	var units := 1.0
	var absolute := true
	var e_absolute := true
	var feed := DEFAULT_FEED_MM_S
	var rapid_feed := DEFAULT_RAPID_MM_S
	var extrusion_mm := 0.0
	var total_feed := 0.0
	var total_rapid := 0.0
	var bmin := Vector3(INF, INF, INF)
	var bmax := Vector3(-INF, -INF, -INF)
	var temps := {"hotend_c": 0.0, "bed_c": 0.0}
	var spindle_rpm := 0.0
	var spindle_max := 0.0
	var laser_s := 0.0
	var laser_s_max := 0.0
	var dialect := "reprap"
	var warnings: Array = []
	var layer_z: Dictionary = {}
	var line_no := 0
	var seen_e := false
	var seen_s_laser := false
	for raw_line in text.split("\n", false):
		line_no += 1
		var line := _strip_comment(raw_line)
		if line.is_empty():
			continue
		if line.begins_with("$"):
			dialect = "grbl"
			continue
		var words := _words(line.to_upper())
		if words.is_empty():
			continue
		var g := -1
		var m := -1
		var has_xyz := false
		var nx := pos.x
		var ny := pos.y
		var nz := pos.z
		var e_word := NAN
		var i_w := NAN
		var j_w := NAN
		var r_w := NAN
		var s_w := NAN
		for w in words:
			var code: String = w[0]
			var val: float = float(w[1])
			match code:
				"G":
					g = int(val)
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
				"M":
					m = int(val)
					if m == 82:
						e_absolute = true
					elif m == 83:
						e_absolute = false
					elif m == 104 or m == 109:
						dialect = "reprap"
					elif m == 140 or m == 190:
						dialect = "reprap"
				"X":
					has_xyz = true
					nx = val * units if absolute else pos.x + val * units
				"Y":
					has_xyz = true
					ny = val * units if absolute else pos.y + val * units
				"Z":
					has_xyz = true
					nz = val * units if absolute else pos.z + val * units
				"E":
					e_word = val * units
					seen_e = true
				"F":
					var f := val * units / 60.0
					if g == 0:
						rapid_feed = maxf(f, 0.1)
					else:
						feed = maxf(f, 0.1)
				"I":
					i_w = val * units
				"J":
					j_w = val * units
				"R":
					r_w = val * units
				"S":
					s_w = val
		# The hottest the program asks for (a cool-down at the end sets 0).
		if m == 104 or m == 109:
			if not is_nan(s_w):
				temps["hotend_c"] = maxf(float(temps["hotend_c"]), s_w)
			continue
		if m == 140 or m == 190:
			if not is_nan(s_w):
				temps["bed_c"] = maxf(float(temps["bed_c"]), s_w)
			continue
		if m == 3 or m == 4:
			if not is_nan(s_w):
				spindle_rpm = s_w
				spindle_max = maxf(spindle_max, s_w)
				if s_w <= 1000.0 and not seen_e:
					laser_s = s_w
					laser_s_max = maxf(laser_s_max, s_w)
					seen_s_laser = true
			continue
		if m == 5:
			spindle_rpm = 0.0
			laser_s = 0.0
			continue
		if g == 92:
			if not is_nan(e_word):
				e_pos = e_word
			if has_xyz:
				pos = Vector3(nx, ny, nz)
			continue
		if g == 28:
			# Home: a rapid to the origin on the named axes (all if none).
			var home := pos
			var any_axis := false
			for w in words:
				var c: String = w[0]
				if c == "X":
					home.x = 0.0
					any_axis = true
				elif c == "Y":
					home.y = 0.0
					any_axis = true
				elif c == "Z":
					home.z = 0.0
					any_axis = true
			if not any_axis:
				home = Vector3.ZERO
			if moves.size() < MAX_MOVES and home != pos:
				moves.append({"p0": pos, "p1": home, "feed_mm_s": rapid_feed, "e_mm": 0.0, "rapid": true, "line": line_no})
				total_rapid += pos.distance_to(home)
			pos = home
			continue
		if g != 0 and g != 1 and g != 2 and g != 3:
			continue
		if not has_xyz and is_nan(e_word):
			continue
		var target := Vector3(nx, ny, nz)
		var e_new := e_pos
		if not is_nan(e_word):
			e_new = e_word if e_absolute else e_pos + e_word
		var de := e_new - e_pos
		# Laser-on at S > 0 counts as "extruding" so the mark shows.
		if (g == 1 or g == 2 or g == 3) and seen_s_laser and laser_s > 0.0 and not seen_e:
			de = maxf(de, 1e-4)
		if de > 0.0:
			extrusion_mm += de
		var is_rapid := g == 0
		var seg_feed := rapid_feed if is_rapid else feed
		var pts: Array = []
		if (g == 2 or g == 3) and (not is_nan(i_w) or not is_nan(j_w) or not is_nan(r_w)):
			pts = _arc_points(pos, target, i_w, j_w, r_w, g == 2)
			if pts.is_empty():
				warnings.append("line %d: arc could not be solved, drawn straight" % line_no)
				pts = [target]
		else:
			pts = [target]
		var seg_total := 0.0
		for p in pts:
			seg_total += pos.distance_to(p) if pts.size() == 1 else 0.0
		# Share the extrusion over the chords by length.
		var chord_total := 0.0
		var prev := pos
		for p in pts:
			chord_total += prev.distance_to(p as Vector3)
			prev = p
		prev = pos
		for p in pts:
			var pv: Vector3 = p
			var l := prev.distance_to(pv)
			if l <= 1e-9 and de <= 0.0:
				prev = pv
				continue
			var e_share := de * (l / chord_total) if chord_total > 1e-9 else de
			if moves.size() < MAX_MOVES:
				moves.append({"p0": prev, "p1": pv, "feed_mm_s": seg_feed, "e_mm": e_share, "rapid": is_rapid, "line": line_no})
			if is_rapid:
				total_rapid += l
			else:
				total_feed += l
			if e_share > 0.0:
				bmin = Vector3(minf(bmin.x, pv.x), minf(bmin.y, pv.y), minf(bmin.z, pv.z))
				bmax = Vector3(maxf(bmax.x, pv.x), maxf(bmax.y, pv.y), maxf(bmax.z, pv.z))
				bmin = Vector3(minf(bmin.x, prev.x), minf(bmin.y, prev.y), minf(bmin.z, prev.z))
				bmax = Vector3(maxf(bmax.x, prev.x), maxf(bmax.y, prev.y), maxf(bmax.z, prev.z))
				layer_z[snappedf(pv.z, 0.01)] = true
			prev = pv
		pos = target
		e_pos = e_new
		if moves.size() >= MAX_MOVES:
			warnings.append("stopped after %d moves" % MAX_MOVES)
			break
	if moves.is_empty():
		return {"ok": false, "error": "no motion found", "warnings": warnings}
	if not is_finite(bmin.x):
		# Nothing extruded (a router / plotter program): bounds from every move.
		bmin = Vector3(INF, INF, INF)
		bmax = Vector3(-INF, -INF, -INF)
		for mv in moves:
			for p in [mv["p0"], mv["p1"]]:
				var pv: Vector3 = p
				bmin = Vector3(minf(bmin.x, pv.x), minf(bmin.y, pv.y), minf(bmin.z, pv.z))
				bmax = Vector3(maxf(bmax.x, pv.x), maxf(bmax.y, pv.y), maxf(bmax.z, pv.z))
	if seen_e:
		dialect = "reprap"
	elif spindle_max > 0.0 or seen_s_laser:
		dialect = "grbl"
	return {
		"ok": true, "moves": moves, "bounds_min": bmin, "bounds_max": bmax,
		"extrusion_mm": extrusion_mm, "total_feed_mm": total_feed, "total_rapid_mm": total_rapid,
		"layers": layer_z.size(), "dialect": dialect, "temps": temps, "spindle_rpm": spindle_rpm,
		"laser_s": laser_s, "laser_s_max": laser_s_max, "lines": line_no, "warnings": warnings, "additive": seen_e or seen_s_laser,
	}


static func _strip_comment(line: String) -> String:
	var s := line
	var semi := s.find(";")
	if semi >= 0:
		s = s.substr(0, semi)
	while true:
		var a := s.find("(")
		if a < 0:
			break
		var b := s.find(")", a)
		if b < 0:
			s = s.substr(0, a)
			break
		s = s.substr(0, a) + " " + s.substr(b + 1)
	return s.strip_edges()


## "G1X10Y-3.5F1200" and "G1 X10 Y-3.5" both → [[G,1],[X,10],…]. An N line
## number word is dropped; a checksum (*nn) too.
static func _words(line: String) -> Array:
	var out: Array = []
	var i := 0
	var n := line.length()
	while i < n:
		var c := line[i]
		if c == " " or c == "\t":
			i += 1
			continue
		if c == "*":
			break
		if c < "A" or c > "Z":
			i += 1
			continue
		var j := i + 1
		while j < n and (line[j] == " "):
			j += 1
		var k := j
		while k < n and ("0123456789.-+".contains(line[k])):
			k += 1
		var val_s := line.substr(j, k - j)
		if c != "N":
			out.append([c, val_s.to_float() if not val_s.is_empty() else 0.0])
		i = maxi(k, i + 1)
	return out


## Chord points along an arc from p0 to p1 (XY plane, Z interpolated).
static func _arc_points(p0: Vector3, p1: Vector3, i_w: float, j_w: float, r_w: float, clockwise: bool) -> Array:
	var c := Vector2.ZERO
	var a := Vector2(p0.x, p0.y)
	var b := Vector2(p1.x, p1.y)
	if not is_nan(i_w) or not is_nan(j_w):
		c = a + Vector2(0.0 if is_nan(i_w) else i_w, 0.0 if is_nan(j_w) else j_w)
	elif not is_nan(r_w):
		# R form: the centre lies on the chord's perpendicular bisector; a
		# negative R picks the long way round.
		var ab := b - a
		var d := ab.length()
		if d <= 1e-9 or absf(r_w) < d * 0.5 - 1e-6:
			return []
		var h := sqrt(maxf(r_w * r_w - d * d * 0.25, 0.0))
		var mid := (a + b) * 0.5
		var perp := Vector2(-ab.y, ab.x).normalized()
		var sgn := -1.0 if clockwise else 1.0
		if r_w < 0.0:
			sgn = -sgn
		c = mid + perp * h * sgn
	else:
		return []
	var r := (a - c).length()
	if r <= 1e-9:
		return []
	var a0 := (a - c).angle()
	var a1 := (b - c).angle()
	var sweep := a1 - a0
	if clockwise:
		while sweep > -1e-9:
			sweep -= TAU
	else:
		while sweep < 1e-9:
			sweep += TAU
	if absf(sweep) < 1e-6 and a.distance_to(b) < 1e-6:
		sweep = -TAU if clockwise else TAU
	var arc_len := absf(sweep) * r
	var segs := clampi(int(ceil(arc_len / ARC_CHORD_MM)), 2, ARC_MAX_SEGS)
	var out: Array = []
	for k in range(1, segs + 1):
		var t := float(k) / float(segs)
		var ang := a0 + sweep * t
		out.append(Vector3(c.x + cos(ang) * r, c.y + sin(ang) * r, lerpf(p0.z, p1.z, t)))
	return out


## The Toolpath dict (what MachineJobStore.save and the machine runtime read)
## from a parse: points + extruding flags, decimated to Toolpath.MAX_SEGMENTS,
## plus the totals the job derivation needs. `extrusion_mm` is carried so a
## printer bills filament; a subtractive program carries 0.
static func to_toolpath(parse: Dictionary, speed_est_hr: float = -1.0) -> Dictionary:
	if not bool(parse.get("ok", false)):
		return {"ok": false, "error": str(parse.get("error", "no motion"))}
	var moves: Array = parse["moves"]
	var pts := PackedVector3Array()
	var ext := PackedInt32Array()
	pts.append((moves[0] as Dictionary)["p0"])
	ext.append(0)
	for mv in moves:
		pts.append((mv as Dictionary)["p1"])
		ext.append(1 if float((mv as Dictionary)["e_mm"]) > 0.0 else 0)
	var dec := Toolpath.decimate(pts, ext, Toolpath.MAX_SEGMENTS)
	var est_hr := speed_est_hr
	if est_hr < 0.0:
		est_hr = (float(parse["total_feed_mm"]) / (DEFAULT_FEED_MM_S * 60.0)
			+ float(parse["total_rapid_mm"]) / (DEFAULT_RAPID_MM_S * 60.0)) / 60.0
	return {
		"ok": true, "kind": "gcode",
		"points": dec.get("points", PackedVector3Array()),
		"extruding": dec.get("extruding", PackedInt32Array()),
		"bounds_min": parse["bounds_min"], "bounds_max": parse["bounds_max"],
		"total_feed_mm": float(parse["total_feed_mm"]), "total_rapid_mm": float(parse["total_rapid_mm"]),
		"extrusion_mm": float(parse["extrusion_mm"]), "est_time_hr": est_hr,
		"point_count": (dec.get("points", PackedVector3Array()) as PackedVector3Array).size(),
		"raw_point_count": pts.size(),
	}

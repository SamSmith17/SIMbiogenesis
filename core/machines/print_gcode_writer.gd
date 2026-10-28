class_name PrintGcodeWriter
extends RefCounted

## Writes a move list (StlSlicer's, GantryLabGcode's, or a toolpath's turned
## into moves by PrintJob) as real G-code, so what the game simulates can be
## sent to a printer. Two dialects:
##   "reprap"     Marlin / Klipper / RepRapFirmware: G1 X Y Z E F with
##                absolute E (M82) in mm of the feedstock bore, G0 travels,
##                temperatures when given, ;LAYER:n comments a slicer's
##                post-processor can read.
##   "grbl_relay" A GRBL board with no extruder axis (the real mud printer):
##                the pump is a relay on M3 / M5 and flow is set by the feed,
##                travels hop by `travel_hop_mm`.
## `GantryLabGcode.parse` reads either back to the same moves (pinned in the
## print selftest: move count, extrusion and bounds round-trip).
##
## opts: dialect, name, hotend_c, bed_c, filament_mm (for the header), home
## (bool, G28), park_z_mm, travel_hop_mm (grbl), relay_on / relay_off, decimals.


## The program as one string (moves: PrintMoves or an Array of move dicts).
static func write(moves: Variant, opts: Dictionary = {}) -> String:
	return _emit(PrintMoves.from_any(moves), opts, null)


## Lines are flushed to `fh` every FLUSH_LINES when it is given (a large
## print is millions of lines), else collected and returned.
const FLUSH_LINES := 20000


static func _emit(moves: PrintMoves, opts: Dictionary, fh: FileAccess) -> String:
	var dialect := str(opts.get("dialect", "reprap"))
	var dec := clampi(int(opts.get("decimals", 3)), 2, 5)
	var fmt := "%%.%df" % dec
	var efmt := "%.5f"
	var lines: PackedStringArray = PackedStringArray()
	var name := str(opts.get("name", "print"))
	lines.append("; %s — written by SIMbiogenesis" % name)
	lines.append("; moves %d, feedstock bore %.2f mm" % [moves.size(), float(opts.get("filament_mm", 1.75))])
	lines.append("G21 ; mm")
	lines.append("G90 ; absolute")
	var relay := dialect == "grbl_relay"
	# "M3 S1000": the pump on, with an S word so the reader (GantryLabGcode)
	# flags the moves under it as laying material, like a laser's power.
	var relay_on := str(opts.get("relay_on", "M3 S1000"))
	var relay_off := str(opts.get("relay_off", "M5"))
	if not relay:
		lines.append("M82 ; absolute E")
		var hot := float(opts.get("hotend_c", 0.0))
		var bed := float(opts.get("bed_c", 0.0))
		if bed > 0.0:
			lines.append("M140 S%d" % int(bed))
		if hot > 0.0:
			lines.append("M104 S%d" % int(hot))
		if bed > 0.0:
			lines.append("M190 S%d" % int(bed))
		if hot > 0.0:
			lines.append("M109 S%d" % int(hot))
	if bool(opts.get("home", true)):
		lines.append("G28 ; home")
	if not relay:
		lines.append("G92 E0")
	var e := 0.0
	var pump := false
	var cur_feed := -1.0
	var layer := -1
	var last_z := NAN
	var hop := maxf(float(opts.get("travel_hop_mm", 0.0)), 0.0)
	var first := true
	for i in moves.size():
		if fh != null and lines.size() >= FLUSH_LINES:
			fh.store_string("\n".join(lines) + "\n")
			lines = PackedStringArray()
		var p0: Vector3 = moves.p0[i]
		var p1: Vector3 = moves.p1[i]
		var e_mm := float(moves.e[i])
		var rapid := moves.rapid[i] != 0 or e_mm <= 0.0
		var feed := float(moves.feed[i]) * 60.0
		if first:
			lines.append("G0 X%s Y%s Z%s F%.0f" % [fmt % p0.x, fmt % p0.y, fmt % p0.z, feed])
			first = false
		if e_mm > 0.0 and (is_nan(last_z) or absf(p1.z - last_z) > 1e-6) and absf(p1.z - p0.z) < 1e-6:
			layer += 1
			lines.append(";LAYER:%d" % layer)
			last_z = p1.z
		var words: PackedStringArray = PackedStringArray()
		if relay:
			if rapid and pump:
				lines.append(relay_off)
				pump = false
			elif not rapid and not pump:
				lines.append(relay_on)
				pump = true
			if rapid and hop > 0.0 and absf(p1.z - p0.z) < 1e-6:
				lines.append("G0 Z%s" % (fmt % (p0.z + hop)))
				lines.append("G0 X%s Y%s F%.0f" % [fmt % p1.x, fmt % p1.y, feed])
				lines.append("G0 Z%s" % (fmt % p1.z))
				cur_feed = feed
				continue
		words.append("G0" if rapid else "G1")
		if absf(p1.x - p0.x) > 1e-9 or first:
			words.append("X" + (fmt % p1.x))
		if absf(p1.y - p0.y) > 1e-9:
			words.append("Y" + (fmt % p1.y))
		if absf(p1.z - p0.z) > 1e-9:
			words.append("Z" + (fmt % p1.z))
		if e_mm > 0.0 and not relay:
			e += e_mm
			words.append("E" + (efmt % e))
		if absf(feed - cur_feed) > 0.5:
			words.append("F%.0f" % feed)
			cur_feed = feed
		if words.size() == 1:
			continue
		lines.append(" ".join(words))
	if relay and pump:
		lines.append(relay_off)
	var park := float(opts.get("park_z_mm", -1.0))
	if park >= 0.0:
		lines.append("G0 Z%s" % (fmt % park))
	if not relay:
		if float(opts.get("hotend_c", 0.0)) > 0.0:
			lines.append("M104 S0")
		if float(opts.get("bed_c", 0.0)) > 0.0:
			lines.append("M140 S0")
		lines.append("M84 ; motors off")
	else:
		lines.append("M2")
	if fh != null:
		fh.store_string("\n".join(lines) + "\n")
		return ""
	return "\n".join(lines) + "\n"


## Write to a file, streamed; returns the path or "" on failure.
static func write_file(moves: Variant, path: String, opts: Dictionary = {}) -> String:
	var dir := path.get_base_dir()
	if dir.begins_with("user://") or dir.begins_with("res://"):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	else:
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	_emit(PrintMoves.from_any(moves), opts, f)
	f.close()
	return path

class_name MudGrblExport
extends RefCounted

## Writes volumetric-E GRBL G-code from a mud building slice (same path the
## sim uses). E is cumulative mm³ of mud (= length × line_width × layer_h × e_scale).

const EXPORTS_DIR := "user://machines/exports"

## Last successful export path (user:// or filesystem) for Print modal status.
static var last_export_path: String = ""


static func from_spec(spec: MudBuildingSpec, dialect: MudGrblDialect = null) -> Dictionary:
	var d := dialect if dialect != null else MudGrblDialect.default_dialect()
	var parse := MudWallSlicer.slice(spec, {"decimate": false})
	if not bool(parse.get("ok", false)):
		return {"ok": false, "error": str(parse.get("error", "slice failed"))}
	return from_parse(parse, d)


static func from_parse(parse: Dictionary, dialect: MudGrblDialect = null) -> Dictionary:
	var d := dialect if dialect != null else MudGrblDialect.default_dialect()
	if not bool(parse.get("ok", false)):
		return {"ok": false, "error": "invalid parse"}
	var pts: PackedVector3Array = parse.get("points", PackedVector3Array())
	var ext: PackedInt32Array = parse.get("extruding", PackedInt32Array())
	if pts.size() < 2:
		return {"ok": false, "error": "empty toolpath"}
	var line_w := maxf(float(parse.get("line_width_mm", 76.2)), 0.1)
	var layer_h := maxf(float(parse.get("layer_height_mm", 50.0)), 0.1)
	var speed_mm_s := maxf(float(parse.get("print_speed_mm_s", 120.0)), 1.0)
	var print_f := d.print_feed_mm_min
	if print_f <= 0.0:
		print_f = speed_mm_s * 60.0
	print_f = minf(print_f, maxf(d.max_feed_mm_min, 60.0))
	var travel_f := minf(maxf(d.travel_feed_mm_min, 60.0), maxf(d.max_feed_mm_min, 60.0))

	var bmin: Vector3 = parse.get("bounds_min", Vector3.ZERO)
	var bmax: Vector3 = parse.get("bounds_max", Vector3.ZERO)
	var safe_z := bmax.z + maxf(d.safe_z_lift_mm, 0.0)
	var hop := maxf(d.travel_hop_mm, 0.0)
	# XY translation so a corner-homing machine sees a positive envelope: shift the
	# post-swap min corner to origin_offset_mm (else keep bed-centre origin).
	var off := _origin_offset(bmin, bmax, d)
	var has_e := d.has_e_axis()

	var lines: PackedStringArray = PackedStringArray()
	_append_block(lines, d.prelude)
	lines.append("G21")
	lines.append("G90")
	if has_e:
		lines.append("G92 E0")
	lines.append("G0 F%.0f" % travel_f)
	lines.append("G0 Z%s" % _fmt(safe_z))

	# Purge/prime line before the print so flow is established off the wall.
	var primed := false
	if d.purge_enabled and d.purge_len_mm > 1.0:
		var fmin := _xform(bmin, d, off)
		var z0 := _xform(bmin, d, off).z
		var pa := Vector2(fmin.x + d.purge_margin_mm, fmin.y + maxf(d.purge_margin_mm * 0.5, 5.0))
		var pb := pa + Vector2(d.purge_len_mm, 0.0)
		lines.append("G0 X%s Y%s Z%s" % [_fmt(pa.x), _fmt(pa.y), _fmt(z0)])
		_pump_on(lines, d)
		if d.prime_dwell_s > 0.0:
			lines.append("G4 P%s" % _fmt_dwell(d.prime_dwell_s))
		primed = true
		lines.append("G1 F%.0f" % print_f)
		lines.append("G1 X%s Y%s Z%s" % [_fmt(pb.x), _fmt(pb.y), _fmt(z0)])
		_pump_off(lines, d)
		lines.append("G0 F%.0f" % travel_f)
		lines.append("G0 Z%s" % _fmt(z0 + hop))

	var e_cum := 0.0
	var pump_on := false
	var cur_layer_z := -1.0e9
	for i in pts.size():
		var p := _xform(pts[i], d, off)
		var extruding := i > 0 and i < ext.size() and ext[i] != 0
		# Track volumetric mud regardless of mode so the estimate stays meaningful.
		if extruding:
			e_cum += pts[i].distance_to(pts[i - 1]) * line_w * layer_h * maxf(d.e_scale, 0.0)
		if extruding:
			if not pump_on:
				var new_layer := p.z > cur_layer_z + 0.5
				if hop > 0.0:
					lines.append("G0 Z%s" % _fmt(p.z))  # plunge to layer height
				if new_layer and cur_layer_z > -1.0e8 and d.layer_dwell_s > 0.0:
					lines.append("G4 P%s" % _fmt_dwell(d.layer_dwell_s))
				_pump_on(lines, d)
				if not primed and d.prime_dwell_s > 0.0:
					lines.append("G4 P%s" % _fmt_dwell(d.prime_dwell_s))
					primed = true
				lines.append("G1 F%.0f" % print_f)
				pump_on = true
			if p.z > cur_layer_z + 0.5:
				cur_layer_z = p.z
			if has_e:
				lines.append("G1 X%s Y%s Z%s E%s" % [
					_fmt(p.x), _fmt(p.y), _fmt(p.z), _fmt(e_cum)])
			else:
				lines.append("G1 X%s Y%s Z%s" % [_fmt(p.x), _fmt(p.y), _fmt(p.z)])
		else:
			if pump_on:
				_pump_off(lines, d)
				pump_on = false
				lines.append("G0 F%.0f" % travel_f)
			lines.append("G0 X%s Y%s Z%s" % [_fmt(p.x), _fmt(p.y), _fmt(p.z + hop)])
	if pump_on:
		_pump_off(lines, d)

	var epi := d.epilogue.replace("{safe_z}", _fmt(safe_z))
	_append_block(lines, epi)

	var text := "\n".join(lines)
	if not text.ends_with("\n"):
		text += "\n"
	return {
		"ok": true,
		"gcode": text,
		"e_total_mm3": e_cum,
		"has_e": has_e,
		"point_count": pts.size(),
		"path_length_mm": float(parse.get("path_length_mm", 0.0)),
		"volume_mm3": float(parse.get("volume_mm3", 0.0)),
		"bounds_min": parse.get("bounds_min", Vector3.ZERO),
		"bounds_max": parse.get("bounds_max", Vector3.ZERO),
		"safe_z_mm": safe_z,
		"parse": parse,
	}


## Pump on/off M-codes per extrusion mode (nothing for a real E axis).
static func _pump_on(lines: PackedStringArray, d: MudGrblDialect) -> void:
	match d.extrusion_mode:
		MudGrblDialect.ExtrusionMode.RELAY:
			lines.append(d.relay_on_code)
		MudGrblDialect.ExtrusionMode.SPINDLE_PWM:
			lines.append("%s S%s" % [d.relay_on_code, _fmt(d.spindle_flow_s)])
		_:
			pass


static func _pump_off(lines: PackedStringArray, d: MudGrblDialect) -> void:
	if d.extrusion_mode == MudGrblDialect.ExtrusionMode.E_AXIS:
		return
	lines.append(d.relay_off_code)


## XY offset that maps the post-swap min corner to the configured work origin.
static func _origin_offset(bmin: Vector3, bmax: Vector3, d: MudGrblDialect) -> Vector2:
	var pa := _swap_xy(Vector2(bmin.x, bmin.y), d)
	var pb := _swap_xy(Vector2(bmax.x, bmax.y), d)
	var lo := Vector2(minf(pa.x, pb.x), minf(pa.y, pb.y))
	if d.corner_origin:
		return d.origin_offset_mm - lo
	return d.origin_offset_mm


static func _swap_xy(v: Vector2, d: MudGrblDialect) -> Vector2:
	return Vector2(v.y, v.x) if d.xy_swap else v


static func _fmt_dwell(sec: float) -> String:
	return "%.2f" % maxf(sec, 0.0)


static func write_user(result: Dictionary, filename: String = "") -> String:
	if not bool(result.get("ok", false)):
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXPORTS_DIR))
	var name := filename
	if name.is_empty():
		name = "mud_building_%d.gcode" % Time.get_unix_time_from_system()
	if not name.ends_with(".gcode") and not name.ends_with(".nc"):
		name += ".gcode"
	var path := EXPORTS_DIR.path_join(name)
	if not write_file(result, path):
		return ""
	last_export_path = path
	return path


static func write_file(result: Dictionary, path: String) -> bool:
	if not bool(result.get("ok", false)) or path.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(str(result.get("gcode", "")))
	f.close()
	last_export_path = path
	return true


## Re-parse exported text and compare metrics to the source slice (parity).
static func parity_check(result: Dictionary, tol_mm: float = 2.0,
		tol_vol_frac: float = 0.05) -> Dictionary:
	if not bool(result.get("ok", false)):
		return {"ok": false, "error": "bad result"}
	var text := str(result.get("gcode", ""))
	var parsed := Toolpath.parse_gcode(text)
	if not bool(parsed.get("ok", false)):
		return {"ok": false, "error": "reparse failed", "detail": parsed}
	var src_bmin: Vector3 = result.get("bounds_min", Vector3.ZERO)
	var src_bmax: Vector3 = result.get("bounds_max", Vector3.ZERO)
	var pbmin: Vector3 = parsed.get("bounds_min", Vector3.ZERO)
	var pbmax: Vector3 = parsed.get("bounds_max", Vector3.ZERO)
	var src_len := float(result.get("path_length_mm", 0.0))
	# Prefers full-path totals from the parser (not the decimated preview polyline).
	var p_len := float(parsed.get("total_feed_mm", 0.0)) + float(parsed.get("total_rapid_mm", 0.0))
	var e_total := float(result.get("e_total_mm3", 0.0))
	var e_parsed := float(parsed.get("extrusion_mm", 0.0))
	var has_e := bool(result.get("has_e", true))
	# XY must match the *shape* (extent), but a corner-origin export is translated
	# so the min corner sits at the work origin — compare span, not absolute pos.
	var src_span := src_bmax - src_bmin
	var p_span := pbmax - pbmin
	var bounds_ok := (
		absf(p_span.x - src_span.x) <= tol_mm
		and absf(p_span.y - src_span.y) <= tol_mm)
	# Relay/spindle modes carry no E word — volumetric parity only applies to E_AXIS.
	var vol_ok := (not has_e) or e_total <= 0.0 \
		or absf(e_parsed - e_total) <= maxf(e_total * tol_vol_frac, 1.0)
	# The export legitimately ADDS length (purge line, per-travel Z-hops), so the
	# check is "nothing lost" — parsed path must be at least the source path.
	var len_ok := src_len < 100.0 or p_len >= src_len * 0.95
	var ok := bounds_ok and vol_ok and bool(parsed.get("ok", false)) and len_ok
	return {
		"ok": ok,
		"bounds_ok": bounds_ok,
		"vol_ok": vol_ok,
		"len_ok": len_ok,
		"src_bounds": [src_bmin, src_bmax],
		"parsed_bounds": [pbmin, pbmax],
		"e_total": e_total,
		"e_parsed": e_parsed,
		"src_path_len": src_len,
		"parsed_path_len": p_len,
		"parsed": parsed,
	}


static func _xform(p: Vector3, d: MudGrblDialect, off: Vector2 = Vector2.INF) -> Vector3:
	var x := p.x
	var y := p.y
	if d.xy_swap:
		var t := x
		x = y
		y = t
	# Vector2.INF sentinel → legacy path (centre origin + raw offset).
	var o := off if off != Vector2.INF else d.origin_offset_mm
	return Vector3(x + o.x, y + o.y, p.z)


static func _fmt(v: float) -> String:
	# Trim trailing zeros for slightly smaller files; keep mm precision.
	return "%.3f" % v


static func _append_block(lines: PackedStringArray, block: String) -> void:
	if block.is_empty():
		return
	for raw in block.replace("\r\n", "\n").split("\n", false):
		var s := raw.strip_edges()
		if not s.is_empty():
			lines.append(s)

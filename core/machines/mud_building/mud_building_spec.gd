class_name MudBuildingSpec
extends RefCounted

## Plan + print parameters for a mud-printed wall building.
## Phase D: gyroid fill, open wall runs, openings/lintels, place-as-structure.
## Units are millimetres unless noted.

## NONE = constant shell gap (no taper). BOTH/OUTER/INNER taper which face moves.
enum CamberMode { BOTH, OUTER, INNER, NONE }
enum FillMode { NONE, SINE, GYROID }

var loops: Array = []  # closed PackedVector2Array plans
var open_paths: Array = []  # open PackedVector2Array wall runs
## Door/window gaps on closed loops: {loop_index, t0, t1, lintel_mm}.
var openings: Array = []
var height_mm: float = 2400.0
var wall_thickness_mm: float = 152.4
var thickness_base_mm: float = 152.4
var thickness_top_mm: float = 76.2
## Clear cavity between the facing edges of the two perimeter beads (fill space).
var shell_gap_mm: float = 100.0
var camber_mode: int = CamberMode.NONE
var fill_mode: int = FillMode.SINE
## Legacy alias — true when fill_mode != NONE.
var fill_enabled: bool = true
var fill_pitch_mm: float = 200.0
var fill_amplitude: float = 1.0
## Rotate each closed-loop layer's start point by this fraction of the perimeter
## so the seam spirals instead of stacking into one weak vertical line (0 = off).
var seam_stagger_frac: float = 0.11
var layer_height_mm: float = 50.0
var nozzle_mm: float = 76.2
var line_width_mm: float = 76.2
var print_speed_mm_s: float = 120.0
var work_x_mm: float = 3048.0
var work_y_mm: float = 3048.0
var work_z_mm: float = 3048.0


static func from_printer_specs(specs: Dictionary) -> MudBuildingSpec:
	var s := MudBuildingSpec.new()
	s.nozzle_mm = maxf(float(specs.get("filament_diameter_mm", 76.2)), 3.0)
	s.line_width_mm = s.nozzle_mm
	s.shell_gap_mm = s.nozzle_mm * 1.25
	# Camber taper targets (centerline sep ≈ gap + line_width).
	s.thickness_base_mm = s.shell_gap_mm + s.line_width_mm
	s.thickness_top_mm = s.shell_gap_mm * 0.55 + s.line_width_mm
	s.wall_thickness_mm = s.thickness_base_mm
	s.camber_mode = CamberMode.NONE
	s.layer_height_mm = maxf(s.nozzle_mm * 0.65, 20.0)
	s.fill_pitch_mm = s.nozzle_mm * 2.5
	s.fill_mode = FillMode.SINE
	s.fill_enabled = true
	s.work_x_mm = maxf(float(specs.get("work_x_mm", 3048.0)), 500.0)
	s.work_y_mm = maxf(float(specs.get("work_y_mm", 3048.0)), 500.0)
	s.work_z_mm = maxf(float(specs.get("work_z_mm", 3048.0)), 500.0)
	s.height_mm = minf(2400.0, s.work_z_mm * 0.85)
	s.print_speed_mm_s = maxf(float(specs.get("print_speed_mm_s", 120.0)), 10.0)
	return s


func sync_thickness_alias() -> void:
	wall_thickness_mm = thickness_base_mm


func sync_fill_alias() -> void:
	fill_enabled = fill_mode != FillMode.NONE


func thickness_at(t: float) -> float:
	var u := clampf(t, 0.0, 1.0)
	var th := lerpf(thickness_base_mm, thickness_top_mm, u)
	return maxf(th, nozzle_mm)


## Clear cavity between perimeter bead facing edges at normalized height t.
func shell_gap_at(t: float) -> float:
	var lw := maxf(line_width_mm, nozzle_mm * 0.5)
	var min_gap := maxf(lw * 0.35, 10.0)
	if camber_mode == CamberMode.NONE:
		return maxf(shell_gap_mm, min_gap)
	# Camber: thickness_* is centerline separation; strip one bead width for cavity.
	var sep := thickness_at(t)
	return maxf(sep - lw, min_gap)


## Centerline distance between outer and inner perimeter paths.
func centerline_sep_at(t: float) -> float:
	var lw := maxf(line_width_mm, nozzle_mm * 0.5)
	return shell_gap_at(t) + lw


func duplicate_spec() -> MudBuildingSpec:
	var s := MudBuildingSpec.new()
	s.loops = _dup_paths(loops)
	s.open_paths = _dup_paths(open_paths)
	s.openings = openings.duplicate(true)
	s.height_mm = height_mm
	s.wall_thickness_mm = wall_thickness_mm
	s.thickness_base_mm = thickness_base_mm
	s.thickness_top_mm = thickness_top_mm
	s.shell_gap_mm = shell_gap_mm
	s.camber_mode = camber_mode
	s.fill_mode = fill_mode
	s.fill_enabled = fill_enabled
	s.fill_pitch_mm = fill_pitch_mm
	s.fill_amplitude = fill_amplitude
	s.seam_stagger_frac = seam_stagger_frac
	s.layer_height_mm = layer_height_mm
	s.nozzle_mm = nozzle_mm
	s.line_width_mm = line_width_mm
	s.print_speed_mm_s = print_speed_mm_s
	s.work_x_mm = work_x_mm
	s.work_y_mm = work_y_mm
	s.work_z_mm = work_z_mm
	return s


func to_dict() -> Dictionary:
	# Keep fill_mode / fill_enabled consistent for round-trips.
	var mode := fill_mode if fill_enabled else FillMode.NONE
	if not fill_enabled:
		mode = FillMode.NONE
	return {
		"loops": _paths_to_arr(loops),
		"open_paths": _paths_to_arr(open_paths),
		"openings": openings.duplicate(true),
		"height_mm": height_mm,
		"wall_thickness_mm": wall_thickness_mm,
		"thickness_base_mm": thickness_base_mm,
		"thickness_top_mm": thickness_top_mm,
		"shell_gap_mm": shell_gap_mm,
		"camber_mode": camber_mode,
		"fill_mode": mode,
		"fill_enabled": mode != FillMode.NONE,
		"fill_pitch_mm": fill_pitch_mm,
		"fill_amplitude": fill_amplitude,
		"seam_stagger_frac": seam_stagger_frac,
		"layer_height_mm": layer_height_mm,
		"nozzle_mm": nozzle_mm,
		"line_width_mm": line_width_mm,
		"print_speed_mm_s": print_speed_mm_s,
		"work_x_mm": work_x_mm,
		"work_y_mm": work_y_mm,
		"work_z_mm": work_z_mm,
	}


static func from_dict(d: Dictionary) -> MudBuildingSpec:
	var s := MudBuildingSpec.new()
	s.height_mm = float(d.get("height_mm", s.height_mm))
	s.thickness_base_mm = float(d.get("thickness_base_mm",
		d.get("wall_thickness_mm", s.thickness_base_mm)))
	s.thickness_top_mm = float(d.get("thickness_top_mm", s.thickness_top_mm))
	s.wall_thickness_mm = s.thickness_base_mm
	s.line_width_mm = float(d.get("line_width_mm", s.line_width_mm))
	s.nozzle_mm = float(d.get("nozzle_mm", s.nozzle_mm))
	s.camber_mode = int(d.get("camber_mode", s.camber_mode))
	if d.has("shell_gap_mm"):
		s.shell_gap_mm = float(d.get("shell_gap_mm", s.shell_gap_mm))
	else:
		# Legacy saves: derive a clear cavity from centerline thickness.
		var lw := maxf(s.line_width_mm, s.nozzle_mm * 0.5)
		s.shell_gap_mm = maxf(s.thickness_base_mm - lw, lw * 0.5)
	# Prefer fill_enabled=false as hard off (legacy Phase B callers).
	if d.has("fill_enabled") and not bool(d.get("fill_enabled", true)):
		s.fill_mode = FillMode.NONE
	elif d.has("fill_mode"):
		s.fill_mode = int(d.get("fill_mode", FillMode.SINE))
	else:
		s.fill_mode = FillMode.SINE if bool(d.get("fill_enabled", true)) else FillMode.NONE
	s.sync_fill_alias()
	s.fill_pitch_mm = float(d.get("fill_pitch_mm", s.fill_pitch_mm))
	s.fill_amplitude = float(d.get("fill_amplitude", s.fill_amplitude))
	s.seam_stagger_frac = float(d.get("seam_stagger_frac", s.seam_stagger_frac))
	s.layer_height_mm = float(d.get("layer_height_mm", s.layer_height_mm))
	s.print_speed_mm_s = float(d.get("print_speed_mm_s", s.print_speed_mm_s))
	s.work_x_mm = float(d.get("work_x_mm", s.work_x_mm))
	s.work_y_mm = float(d.get("work_y_mm", s.work_y_mm))
	s.work_z_mm = float(d.get("work_z_mm", s.work_z_mm))
	s.loops = _arr_to_paths(d.get("loops", []))
	s.open_paths = _arr_to_paths(d.get("open_paths", []))
	s.openings = []
	var raw_o: Variant = d.get("openings", [])
	if raw_o is Array:
		for o: Variant in raw_o as Array:
			if o is Dictionary:
				s.openings.append((o as Dictionary).duplicate(true))
	return s


static func make_rect(cx: float, cy: float, w: float, h: float) -> PackedVector2Array:
	var hw := w * 0.5
	var hh := h * 0.5
	return PackedVector2Array([
		Vector2(cx - hw, cy - hh),
		Vector2(cx + hw, cy - hh),
		Vector2(cx + hw, cy + hh),
		Vector2(cx - hw, cy + hh),
	])


static func make_rounded_rect(cx: float, cy: float, w: float, h: float,
		corner_r: float, arc_segments: int = 6) -> PackedVector2Array:
	var hw := w * 0.5
	var hh := h * 0.5
	var r := clampf(corner_r, 0.0, minf(hw, hh) - 1.0)
	if r < 1.0:
		return make_rect(cx, cy, w, h)
	var pts := PackedVector2Array()
	var corners := [
		[Vector2(cx + hw - r, cy + hh - r), 0.0],
		[Vector2(cx - hw + r, cy + hh - r), PI * 0.5],
		[Vector2(cx - hw + r, cy - hh + r), PI],
		[Vector2(cx + hw - r, cy - hh + r), PI * 1.5],
	]
	for c: Array in corners:
		var center: Vector2 = c[0]
		var a0: float = c[1]
		for i in range(arc_segments + 1):
			var a := a0 + (PI * 0.5) * (float(i) / float(arc_segments))
			pts.append(center + Vector2(cos(a), sin(a)) * r)
	return pts


## Smooth cubic chain through anchors (Catmull-Rom → Bezier). If `closed`,
## wraps the chain; otherwise leaves an open wall run.
static func make_bezier_chain(anchors: PackedVector2Array, closed: bool,
		samples_per_seg: int = 8) -> PackedVector2Array:
	var n := anchors.size()
	if n < 2:
		return anchors.duplicate()
	if n == 2:
		return anchors.duplicate()
	var segs := maxi(samples_per_seg, 2)
	var pts := PackedVector2Array()
	var count := n if closed else (n - 1)
	for i in count:
		var p0: Vector2 = anchors[(i - 1 + n) % n] if closed or i > 0 else anchors[0]
		var p1: Vector2 = anchors[i]
		var p2: Vector2 = anchors[(i + 1) % n]
		var p3: Vector2 = anchors[(i + 2) % n] if closed or i + 2 < n else anchors[n - 1]
		if not closed and i == 0:
			p0 = p1
		if not closed and i == n - 2:
			p3 = p2
		# Catmull-Rom to cubic Bezier conversion.
		var c1 := p1 + (p2 - p0) / 6.0
		var c2 := p2 - (p3 - p1) / 6.0
		for s in segs:
			var t := float(s) / float(segs)
			if s == 0 and pts.size() > 0:
				continue
			pts.append(_cubic(p1, c1, c2, p2, t))
	return pts


static func _cubic(a: Vector2, b: Vector2, c: Vector2, d: Vector2, t: float) -> Vector2:
	var u := 1.0 - t
	return u * u * u * a + 3.0 * u * u * t * b + 3.0 * u * t * t * c + t * t * t * d


static func _dup_paths(arr: Array) -> Array:
	var out: Array = []
	for loop: Variant in arr:
		if loop is PackedVector2Array:
			out.append((loop as PackedVector2Array).duplicate())
	return out


static func _paths_to_arr(arr: Array) -> Array:
	var out: Array = []
	for loop: Variant in arr:
		if loop is PackedVector2Array:
			var pts: Array = []
			for p: Vector2 in loop as PackedVector2Array:
				pts.append([p.x, p.y])
			out.append(pts)
	return out


static func _arr_to_paths(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for loop_v: Variant in raw as Array:
		if not (loop_v is Array):
			continue
		var pv := PackedVector2Array()
		for pt: Variant in loop_v as Array:
			if pt is Array and (pt as Array).size() >= 2:
				pv.append(Vector2(float(pt[0]), float(pt[1])))
			elif pt is Vector2:
				pv.append(pt as Vector2)
		if pv.size() >= 2:
			out.append(pv)
	return out

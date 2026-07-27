class_name LinkageGeometry
extends RefCounted
## Support-beam + solar-panel geometry for solved linkage frames — GDScript
## port of LinkageLab's `js/linkage/linkage-geometry.js` (canopy area, module
## frames, radial support beams, SIMPLIFIED reciprocal beams, and the
## rectangular / radial / spiral / arch-wall-face panel layouts).
##
## All coordinates are INCHES, Y-up, operating on LinkageSolver frame
## dictionaries. Simplification scope (per plan): reciprocal (RCP) beams use
## STATIC placement from the ring topology at the user's swing angle — the
## kinematic crossing-continuation solver is intentionally not ported.
##
## Panel dictionaries: { center: Vector3, axis_x, axis_y, axis_z: Vector3
##   (axis_y = surface normal), width, length, thickness, watts: float }

const CORNER_Y_TOL := 5.0          # canopy top-surface corner tolerance (in)
const VERTEX_DEDUPE_TOL := 2.0     # canopy outer-vertex dedupe distance (in)
const SEPARATION_BASELINE := 4.6   # PanelPlacer built-in alignment offset (in)


# ---------------------------------------------------------------------------
# Canopy area (cylinder mode top ring) — port of calculateCanopyArea
# ---------------------------------------------------------------------------

static func canopy_area(frame: Dictionary) -> Dictionary:
	var top_beams := _beams_of_type(frame, "horizontal-top")
	if top_beams.is_empty():
		return {}

	var top_height := 0.0
	for beam in top_beams:
		var avg_y := ((beam["p1"] as Vector3).y + (beam["p2"] as Vector3).y) / 2.0
		top_height = maxf(top_height, avg_y)

	var all_corners: Array = []
	var max_radius := 0.0
	var sum_x := 0.0
	var sum_z := 0.0
	for beam in top_beams:
		for c in beam["corners"]:
			var cv: Vector3 = c
			if absf(cv.y - top_height) < CORNER_Y_TOL:
				var rad := Vector2(cv.x, cv.z).length()
				all_corners.append({"x": cv.x, "z": cv.z, "rad": rad})
				sum_x += cv.x
				sum_z += cv.z
				max_radius = maxf(max_radius, rad)

	var center_x := 0.0
	var center_z := 0.0
	if not all_corners.is_empty():
		center_x = sum_x / all_corners.size()
		center_z = sum_z / all_corners.size()
	# Closed rings should be centered on origin; snap small numeric drift.
	if absf(center_x) < max_radius * 0.1 and absf(center_z) < max_radius * 0.1:
		center_x = 0.0
		center_z = 0.0

	var outer_vertices: Array = []
	var radius_threshold := max_radius * 0.85
	for corner in all_corners:
		if float(corner["rad"]) > radius_threshold:
			var exists := false
			for v in outer_vertices:
				if absf(float(v["x"]) - float(corner["x"])) < VERTEX_DEDUPE_TOL \
						and absf(float(v["z"]) - float(corner["z"])) < VERTEX_DEDUPE_TOL:
					exists = true
					break
			if not exists:
				outer_vertices.append({"x": corner["x"], "z": corner["z"]})
	outer_vertices.sort_custom(func(a, b) -> bool:
		return atan2(float(a["z"]) - center_z, float(a["x"]) - center_x) \
			< atan2(float(b["z"]) - center_z, float(b["x"]) - center_x))

	var area := 0.0
	for i in range(outer_vertices.size()):
		var j := (i + 1) % outer_vertices.size()
		area += float(outer_vertices[i]["x"]) * float(outer_vertices[j]["z"]) \
			- float(outer_vertices[j]["x"]) * float(outer_vertices[i]["z"])
	area = absf(area) / 2.0

	return {
		"center": Vector3(center_x, top_height, center_z),
		"top_height": top_height,
		"max_radius": max_radius,
		"area": area,
		"vertex_count": outer_vertices.size(),
	}


# ---------------------------------------------------------------------------
# Module frames — port of extractModuleFrames (cylinder-mode support scaffold)
# ---------------------------------------------------------------------------

static func extract_module_frames(frame: Dictionary, p: LinkageParams) -> Array:
	var frames: Array = []
	var beams: Array = frame.get("beams", [])
	var brackets: Array = frame.get("brackets", [])
	var top_beams := _beams_of_type(frame, "horizontal-top")

	var cx := 0.0
	var cz := 0.0
	var n := 0
	for b in top_beams:
		cx += ((b["p1"] as Vector3).x + (b["p2"] as Vector3).x) * 0.5
		cz += ((b["p1"] as Vector3).z + (b["p2"] as Vector3).z) * 0.5
		n += 1
	if n > 0:
		cx /= n
		cz /= n

	for i in range(p.modules):
		var top_beam := _module_top_beam(top_beams, i)
		if top_beam.is_empty():
			continue
		var tp1: Vector3 = top_beam["p1"]
		var tp2: Vector3 = top_beam["p2"]
		var tang := Vector2(tp2.x - tp1.x, tp2.z - tp1.z)
		var tang_len := maxf(tang.length(), 1.0)
		tang /= tang_len

		var mod_brackets: Array = brackets.filter(func(b):
			return int(b["module_index"]) == i and not bool(b["is_bottom"]))
		var vert_beams: Array = beams.filter(func(b):
			var st: String = b["stack_type"]
			return (st == "vertical" or st == "fixed-beam") and int(b["module_index"]) == i)

		var inner_bracket: Dictionary = {}
		var outer_bracket: Dictionary = {}
		var inner_r := INF
		var outer_r := -INF
		for br in mod_brackets:
			var pos: Vector3 = br["pos"]
			var r := Vector2(pos.x - cx, pos.z - cz).length()
			if r < inner_r:
				inner_r = r
				inner_bracket = br
			if r > outer_r:
				outer_r = r
				outer_bracket = br

		var support_y := support_beam_plane_y(top_beam, p)

		# Hinge = OUTER-top pivot: farthest-from-center upper endpoint among
		# the module's vertical cross beams.
		var hinge_point := Vector3.ZERO
		var hinge_beam: Dictionary = {}
		var hinge_r := -INF
		for vb in vert_beams:
			var top: Vector3 = vb["p1"] if (vb["p1"] as Vector3).y >= (vb["p2"] as Vector3).y else vb["p2"]
			var r2 := Vector2(top.x - cx, top.z - cz).length()
			if r2 > hinge_r:
				hinge_r = r2
				hinge_beam = vb
				hinge_point = Vector3(top.x, support_y, top.z)
		if hinge_beam.is_empty():
			var e1 := Vector2(tp1.x - cx, tp1.z - cz).length()
			var e2 := Vector2(tp2.x - cx, tp2.z - cz).length()
			var outer_end := tp1 if e1 >= e2 else tp2
			if not outer_bracket.is_empty():
				var obp: Vector3 = outer_bracket["pos"]
				hinge_point = Vector3(obp.x, support_y, obp.z)
			else:
				hinge_point = Vector3(outer_end.x, support_y, outer_end.z)

		# Inward radial: the hinge leg's own XZ axis (outer-top -> inner-bottom).
		var in_dir := Vector2.ZERO
		if not hinge_beam.is_empty():
			var hb_top: Vector3 = hinge_beam["p1"] if (hinge_beam["p1"] as Vector3).y >= (hinge_beam["p2"] as Vector3).y else hinge_beam["p2"]
			var hb_bot: Vector3 = hinge_beam["p2"] if (hinge_beam["p1"] as Vector3).y >= (hinge_beam["p2"] as Vector3).y else hinge_beam["p1"]
			in_dir = Vector2(hb_bot.x - hb_top.x, hb_bot.z - hb_top.z)
		if in_dir.length() < 1e-3:
			in_dir = Vector2(cx - hinge_point.x, cz - hinge_point.z)
		var in_len := maxf(in_dir.length(), 1.0)
		in_dir /= in_len

		# Top-ring scissor beams (Pattern A/B) and their XZ crossing (H-center):
		# reciprocal anchors slide along these from the crossing inward.
		var mod_top_beams: Array = top_beams.filter(func(b): return int(b["module_index"]) == i)
		var beam_a := _highest_of_pattern(mod_top_beams, "A")
		var beam_b := _highest_of_pattern(mod_top_beams, "B")
		if beam_a.is_empty():
			beam_a = top_beam
		if beam_b.is_empty():
			beam_b = top_beam
		var inner_a := _inner_end(beam_a, cx, cz)
		var inner_b := _inner_end(beam_b, cx, cz)
		var h_center := Vector3.ZERO
		var isect := _seg_seg_intersect_xz(beam_a["p1"], beam_a["p2"], beam_b["p1"], beam_b["p2"])
		var mid_y := ((beam_a["center"] as Vector3).y + (beam_b["center"] as Vector3).y) * 0.5
		if not isect.is_empty() and float(isect["t"]) > -0.2 and float(isect["t"]) < 1.2 \
				and float(isect["s"]) > -0.2 and float(isect["s"]) < 1.2:
			var ap1: Vector3 = beam_a["p1"]
			var ap2: Vector3 = beam_a["p2"]
			var t := float(isect["t"])
			h_center = Vector3(ap1.x + t * (ap2.x - ap1.x), mid_y, ap1.z + t * (ap2.z - ap1.z))
		else:
			h_center = Vector3((inner_a.x + inner_b.x) * 0.5, mid_y, (inner_a.z + inner_b.z) * 0.5)

		frames.append({
			"module_index": i,
			"top_beam": top_beam,
			"support_y": support_y,
			"hinge_point": hinge_point,
			"in_dir": in_dir,
			"structure_cx": cx,
			"structure_cz": cz,
			"h_center": h_center,
			"scissor_a": _scissor_end(inner_a, h_center),
			"scissor_b": _scissor_end(inner_b, h_center),
		})
	return frames


## Port of getSupportBeamPlaneY: radial beam centerline height above the top ring.
static func support_beam_plane_y(top_beam: Dictionary, p: LinkageParams) -> float:
	var cfg: Dictionary = p.support_beams
	var h_stack_thick := p.h_stack_count * p.h_beam_t + maxf(0.0, p.h_stack_count - 1) * p.h_stack_gap
	var beam_y := ((top_beam["p1"] as Vector3).y + (top_beam["p2"] as Vector3).y) * 0.5
	return beam_y + h_stack_thick + float(cfg["thickness"]) / 2.0 + float(cfg["offset_v"])


static func _module_top_beam(top_beams: Array, module_index: int) -> Dictionary:
	var best: Dictionary = {}
	for beam in top_beams:
		if int(beam["module_index"]) != module_index:
			continue
		if best.is_empty() or (beam["center"] as Vector3).y > (best["center"] as Vector3).y:
			best = beam
	return best


static func _highest_of_pattern(mod_top_beams: Array, pattern: String) -> Dictionary:
	var best: Dictionary = {}
	for b in mod_top_beams:
		if str(b["pattern_id"]) != pattern:
			continue
		if best.is_empty() or (b["center"] as Vector3).y > (best["center"] as Vector3).y:
			best = b
	return best


static func _inner_end(beam: Dictionary, cx: float, cz: float) -> Vector3:
	var p1: Vector3 = beam["p1"]
	var p2: Vector3 = beam["p2"]
	var d1 := Vector2(p1.x - cx, p1.z - cz).length()
	var d2 := Vector2(p2.x - cx, p2.z - cz).length()
	return p1 if d1 <= d2 else p2


static func _scissor_end(inner_end: Vector3, h_center: Vector3) -> Dictionary:
	var d := Vector2(inner_end.x - h_center.x, inner_end.z - h_center.z)
	var l := maxf(d.length(), 1.0)
	return {"dir_x": d.x / l, "dir_z": d.y / l, "max_dist": d.length()}


## Parametric XZ intersection of two segments — port of segSegIntersectParamsXZ.
static func _seg_seg_intersect_xz(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3) -> Dictionary:
	var dax := a1.x - a0.x
	var daz := a1.z - a0.z
	var dbx := b1.x - b0.x
	var dbz := b1.z - b0.z
	var cross := dax * dbz - daz * dbx
	if absf(cross) < 1e-12:
		return {}
	var wx := b0.x - a0.x
	var wz := b0.z - a0.z
	return {
		"t": (wx * dbz - wz * dbx) / cross,
		"s": (wx * daz - wz * dax) / cross,
	}


# ---------------------------------------------------------------------------
# Support beams — port of generateSupportBeams (radial + SIMPLIFIED static RCP)
# ---------------------------------------------------------------------------

## Returns support beam dictionaries (same shape as solver beams), applying
## the radial/rcp visibility-angle gates at `fold_rad`. Cylinder mode only.
static func support_beams(frame: Dictionary, p: LinkageParams, fold_rad: float) -> Array:
	var out: Array = []
	var cfg: Dictionary = p.support_beams
	if not bool(cfg["enabled"]) or p.orientation == "vertical":
		return out
	var top_beams := _beams_of_type(frame, "horizontal-top")
	if top_beams.is_empty():
		return out

	var module_frames := extract_module_frames(frame, p)
	var fold_deg := rad_to_deg(fold_rad)

	# Radial (S) beams: hinge at the outer vertical leg, sliding along the
	# module's fixed inward radial axis.
	if bool(cfg.get("show_radial", true)) and fold_deg >= p.radial_visible_angle:
		for mf in module_frames:
			var placement := _solve_radial_placement(mf, cfg)
			out.append(LinkageSolver._make_beam(
				placement["start"], placement["end"],
				float(cfg["width"]), float(cfg["thickness"]),
				{
					"module_index": mf["module_index"],
					"stack_type": "support-beam",
					"stack_id": mf["module_index"],
				}))

	# Reciprocal (RCP) beams: static placement at the user swing angle
	# (kinematic crossing solver deliberately not ported — see class docs).
	if bool(cfg["parallel_enabled"]) and fold_deg >= p.rcp_visible_angle:
		var rcp_len := float(cfg["parallel_length"])
		var fallback_swing := deg_to_rad(float(cfg["parallel_swing_angle"]))
		var end_offset := float(cfg["rcp_end_offset"])
		for mf in module_frames:
			for side in range(2):
				var anc := _build_rcp_anchor(mf, cfg, side, p)
				var p1 := _rcp_point(anc, -end_offset / rcp_len, fallback_swing, rcp_len)
				var p2 := _rcp_point(anc, 1.0, fallback_swing, rcp_len)
				out.append(LinkageSolver._make_beam(
					p1, p2,
					float(cfg["parallel_width"]), float(cfg["parallel_thickness"]),
					{
						"module_index": mf["module_index"],
						"stack_type": "support-beam-reciprocal",
						"stack_id": int(anc["stack_id"]),
						"pattern_id": "A" if side == 0 else "B",
					}))
	return out


## Port of solveRadialSupportBeamPlacement.
static func _solve_radial_placement(mf: Dictionary, cfg: Dictionary) -> Dictionary:
	var length := float(cfg["length"])
	var offset_h := float(cfg["offset_h"])
	var support_y := float(mf["support_y"])
	var hinge: Vector3 = mf["hinge_point"]
	var dir: Vector2 = mf["in_dir"]
	var start := Vector3(hinge.x + dir.x * offset_h, support_y, hinge.z + dir.y * offset_h)
	var end := Vector3(start.x + dir.x * length, support_y, start.z + dir.y * length)
	return {"start": start, "end": end}


## Port of buildRcpAnchorFromFrame + computeRcpAnchorPosition.
static func _build_rcp_anchor(mf: Dictionary, cfg: Dictionary, side: int, p: LinkageParams) -> Dictionary:
	var ab_offset := float(cfg["parallel_v_offset"])
	var vert_sign := 1.0 if side == 0 else -1.0
	var swing_sign := 1.0 if side == 0 else -1.0
	var stack_id := p.modules + int(mf["module_index"]) * 2 + side

	var scissor: Dictionary = mf["scissor_a"] if side == 0 else mf["scissor_b"]
	var h_center: Vector3 = mf["h_center"]
	var dist := clampf(float(cfg["anchor_dist"]), 0.0, float(scissor["max_dist"]))
	var anchor_x := h_center.x + float(scissor["dir_x"]) * dist
	var anchor_z := h_center.z + float(scissor["dir_z"]) * dist

	# Anchor pinned to the ring's top surface (computeRcpAnchorPosition).
	var top_beam: Dictionary = mf["top_beam"]
	var h_stack_thick := p.h_stack_count * p.h_beam_t + maxf(0.0, p.h_stack_count - 1) * p.h_stack_gap
	var rcp_t := float(cfg["parallel_thickness"])
	var rcp_offset_v := float(cfg["parallel_offset_v"])
	var beam_y := ((top_beam["p1"] as Vector3).y + (top_beam["p2"] as Vector3).y) * 0.5
	var top_surface_y := beam_y + h_stack_thick / 2.0
	var anchor_y := top_surface_y + rcp_t / 2.0 + rcp_offset_v + vert_sign * (ab_offset / 2.0)

	# Radially-inward reference: along this side's scissor leg.
	var rad_in := Vector2(float(scissor["dir_x"]), float(scissor["dir_z"]))
	if rad_in.length() < 1e-6:
		rad_in = mf["in_dir"]
	if rad_in.length() < 1e-6:
		rad_in = Vector2(float(mf["structure_cx"]) - anchor_x, float(mf["structure_cz"]) - anchor_z)
	rad_in /= maxf(rad_in.length(), 1e-9)

	return {
		"stack_id": stack_id,
		"pos": Vector3(anchor_x, anchor_y, anchor_z),
		"rad_in": rad_in,
		"swing_sign": swing_sign,
	}


## Port of computeRcpPoint (+computeRcpBeamUnitDir): beams stay horizontal,
## swung about the vertical axis at the anchor.
static func _rcp_point(anc: Dictionary, t: float, swing_rad: float, length: float) -> Vector3:
	var eff := swing_rad * float(anc["swing_sign"])
	var c := cos(eff)
	var s := sin(eff)
	var rad_in: Vector2 = anc["rad_in"]
	var dir := Vector3(rad_in.x * c - rad_in.y * s, 0.0, rad_in.x * s + rad_in.y * c)
	return (anc["pos"] as Vector3) + dir * (t * length)


# ---------------------------------------------------------------------------
# Solar panels — port of calculateSolarPanels + the four layout functions
# ---------------------------------------------------------------------------

## All panels for the frame (visibility gating is the caller's job).
static func solar_panels(frame: Dictionary, p: LinkageParams) -> Array:
	var sp: Dictionary = p.solar_panels
	if not bool(sp["enabled"]):
		return []
	var panels: Array = []
	if p.orientation == "vertical":
		var side_cfg: Dictionary = sp["side_panels"]
		# Scissor-upright arch too compressed for the panel array -> hide.
		if not p.use_fixed_beams:
			var rows := int(side_cfg["grid_rows"])
			var panel_array_height := rows * float(side_cfg["panel_length"]) + (rows - 1) * float(side_cfg["padding_y"])
			if float(frame.get("max_height", 0.0)) < panel_array_height * 0.8:
				return []
		panels = _arch_layout(frame, side_cfg, sp, p)
	else:
		var canopy := canopy_area(frame)
		if canopy.is_empty():
			return []
		var top_cfg: Dictionary = sp["top_panels"]
		if bool(top_cfg["enabled"]):
			match str(sp["layout_mode"]):
				"radial":
					panels.append_array(_radial_layout(canopy, top_cfg, sp))
				"spiral":
					panels.append_array(_spiral_layout(canopy, top_cfg, sp))
				_:
					panels.append_array(_rectangular_layout(canopy, top_cfg, sp))
		var side_cfg2: Dictionary = sp["side_panels"]
		if bool(side_cfg2["enabled"]):
			panels.append_array(_arch_layout(frame, side_cfg2, sp, p))
	return panels


## Total rated watts across a panel list (feeds the HUD + Phase 6 handoff).
static func total_watts(panels: Array) -> float:
	var total := 0.0
	for panel in panels:
		total += float(panel.get("watts", 0.0))
	return total


## Flat horizontal panel (normal = +Y), rotated about Y — Panel3D's
## horizontal branch.
static func _flat_panel(center: Vector3, sec: Dictionary, rotation_rad: float) -> Dictionary:
	var c := cos(rotation_rad)
	var s := sin(rotation_rad)
	return {
		"center": center,
		"axis_x": Vector3(c, 0.0, s),
		"axis_y": Vector3.UP,
		"axis_z": Vector3(-s, 0.0, c),
		"width": float(sec["panel_width"]),
		"length": float(sec["panel_length"]),
		"thickness": float(sec["panel_thickness"]),
		"watts": float(sec["rated_watts"]),
	}


## Port of calculateRectangularLayout.
static func _rectangular_layout(canopy: Dictionary, sec: Dictionary, sp: Dictionary) -> Array:
	var panels: Array = []
	var rotation_rad := deg_to_rad(float(sp["grid_rotation"]))
	var c := cos(rotation_rad)
	var s := sin(rotation_rad)
	var t := float(sec["panel_thickness"])
	var panel_y := float(canopy["top_height"]) + t / 2.0 + 0.5 + float(sec["panel_lift"])
	var rows := int(sec["grid_rows"])
	var cols := int(sec["grid_cols"])
	var center: Vector3 = canopy["center"]
	for row in range(rows):
		for col in range(cols):
			var local_x := (col - (cols - 1) / 2.0) * (float(sec["panel_width"]) + float(sec["padding_x"]))
			var local_z := (row - (rows - 1) / 2.0) * (float(sec["panel_length"]) + float(sec["padding_y"]))
			var x := center.x + local_x * c - local_z * s
			var z := center.z + local_x * s + local_z * c
			panels.append(_flat_panel(Vector3(x, panel_y, z), sec, rotation_rad))
	return panels


## Port of calculateRadialLayout (pinwheel ring).
static func _radial_layout(canopy: Dictionary, sec: Dictionary, sp: Dictionary) -> Array:
	var panels: Array = []
	var count := maxi(1, int(sp["radial_count"]))
	var t := float(sec["panel_thickness"])
	var panel_y := float(canopy["top_height"]) + t / 2.0 + 0.5 + float(sec["panel_lift"])
	var angle_step := TAU / count
	var pinwheel_rad := deg_to_rad(float(sp["pinwheel_angle"]))
	var pattern_rot := deg_to_rad(float(sp["radial_rotation"]))
	var lateral := float(sp["radial_lateral_offset"])
	var radial_offset := float(sp["radial_offset"])
	var default_radius := float(canopy.get("max_radius", 0.0)) * 0.6 if float(canopy.get("max_radius", 0.0)) > 0.0 else 50.0
	var radius := radial_offset if radial_offset > 0.0 else default_radius
	var center: Vector3 = canopy["center"]
	for i in range(count):
		var base_angle := i * angle_step + pattern_rot
		var radial := Vector2(cos(base_angle), sin(base_angle))
		var lateral_dir := Vector2(-radial.y, radial.x)
		var x := center.x + radius * radial.x + lateral * lateral_dir.x
		var z := center.z + radius * radial.y + lateral * lateral_dir.y
		var rotation := base_angle + PI / 2.0 + pinwheel_rad
		panels.append(_flat_panel(Vector3(x, panel_y, z), sec, rotation))
	return panels


## Port of calculateSpiralLayout (primary ring + secondary spiral arms).
static func _spiral_layout(canopy: Dictionary, sec: Dictionary, sp: Dictionary) -> Array:
	var panels: Array = []
	var count := maxi(1, int(sp["radial_count"]))
	var t := float(sec["panel_thickness"])
	var panel_y := float(canopy["top_height"]) + t / 2.0 + 0.5 + float(sec["panel_lift"])
	var angle_step := TAU / count
	var pattern_rot := deg_to_rad(float(sp["radial_rotation"]))
	var pinwheel_rad := deg_to_rad(float(sp["pinwheel_angle"]))
	var default_radius := float(canopy.get("max_radius", 0.0)) * 0.6 if float(canopy.get("max_radius", 0.0)) > 0.0 else 50.0
	var radial_offset := float(sp["radial_offset"])
	var primary_radius := radial_offset if radial_offset > 0.0 else default_radius
	var primary_lateral := float(sp["radial_lateral_offset"])
	var sec_enabled := bool(sp["spiral_secondary_enabled"])
	var sec_radial := float(sp["spiral_secondary_radial_offset"])
	var sec_lateral := float(sp["spiral_secondary_lateral_offset"])
	var sec_pinwheel := deg_to_rad(float(sp["spiral_secondary_pinwheel"]))
	var sec_rotation := deg_to_rad(float(sp["spiral_secondary_rotation"]))
	var arm_count := maxi(2, int(sp["spiral_arm_count"]))
	var radial_step := float(sp["spiral_arm_radial_step"])
	var lateral_step := float(sp["spiral_arm_lateral_step"])
	var pinwheel_step := deg_to_rad(float(sp["spiral_arm_pinwheel_step"]))
	var rotation_step := deg_to_rad(float(sp["spiral_arm_rotation_step"]))
	var center: Vector3 = canopy["center"]
	for i in range(count):
		var base_angle := i * angle_step + pattern_rot
		var radial := Vector2(cos(base_angle), sin(base_angle))
		var lateral_dir := Vector2(-radial.y, radial.x)
		var px := center.x + radial.x * primary_radius + lateral_dir.x * primary_lateral
		var pz := center.z + radial.y * primary_radius + lateral_dir.y * primary_lateral
		panels.append(_flat_panel(Vector3(px, panel_y, pz), sec, base_angle + pinwheel_rad + PI / 2.0))
		if sec_enabled:
			for j in range(1, arm_count):
				var r_off := sec_radial + (j - 1) * radial_step
				var l_off := sec_lateral + (j - 1) * lateral_step
				var pin_j := sec_pinwheel + (j - 1) * pinwheel_step
				var rot_j := sec_rotation + (j - 1) * rotation_step
				var sx := px + radial.x * r_off + lateral_dir.x * l_off
				var sz := pz + radial.y * r_off + lateral_dir.y * l_off
				panels.append(_flat_panel(Vector3(sx, panel_y, sz),
					sec, base_angle + pinwheel_rad + pin_j + PI / 2.0 + rot_j))
	return panels


# ---------------------------------------------------------------------------
# Arch wall faces + face panel placement — port of calculateArchWallFaces +
# PanelPlacer.placeOnFace
# ---------------------------------------------------------------------------

static func arch_wall_faces(frame: Dictionary) -> Array:
	var roof_faces: Array = []
	var beams: Array = frame.get("beams", [])
	if beams.is_empty():
		return roof_faces

	# Central axis of the ring: arch (vertical) mode lays the ring flat with its
	# axis along Z (radial plane = XY); cylinder (horizontal) mode stands it
	# upright with axis along Y (radial plane = XZ). Faces face radially outward
	# in the plane perpendicular to this axis, so the same face solver serves
	# both modes.
	var up_axis := Vector3(0, 0, 1) if str(frame.get("orientation", "")) == "vertical" \
		else Vector3(0, 1, 0)

	var structure_center := Vector3.ZERO
	var beam_count := 0
	for beam in beams:
		if (beam["stack_type"] as String).begins_with("horizontal"):
			structure_center += beam["center"] as Vector3
			beam_count += 1
	if beam_count > 0:
		structure_center /= float(beam_count)

	var top_h_beams := _beams_of_type(frame, "horizontal-top")
	var bot_h_beams := _beams_of_type(frame, "horizontal-bottom")
	if top_h_beams.is_empty() or bot_h_beams.is_empty():
		return roof_faces

	# Group by array index (tunnel duplicates), matched top<->bottom.
	var top_groups := _group_by_array_index(top_h_beams)
	var bot_groups := _group_by_array_index(bot_h_beams)
	var matched: Array = []
	for idx in top_groups:
		if bot_groups.has(idx) and not (top_groups[idx] as Array).is_empty() \
				and not (bot_groups[idx] as Array).is_empty():
			matched.append({"top": top_groups[idx], "bot": bot_groups[idx]})
	if matched.is_empty():
		matched.append({"top": top_h_beams, "bot": bot_h_beams})

	var face_index := 0
	for group in matched:
		var module_top := _group_by_module(group["top"])
		var module_bot := _group_by_module(group["bot"])
		var module_indices: Array = []
		for k in module_top:
			if not module_indices.has(k):
				module_indices.append(k)
		for k in module_bot:
			if not module_indices.has(k):
				module_indices.append(k)
		module_indices.sort()

		for module_idx in module_indices:
			var top_beams: Array = module_top.get(module_idx, [])
			var bot_beams: Array = module_bot.get(module_idx, [])
			if top_beams.is_empty() or bot_beams.is_empty():
				continue

			var beam_pairs := _match_beams(top_beams, bot_beams)

			# True module center from ALL of this module's H beams.
			var true_center := Vector3.ZERO
			var count_c := 0
			for b in top_beams + bot_beams:
				true_center += b["center"] as Vector3
				count_c += 1
			if count_c > 0:
				true_center /= float(count_c)

			# Module-wide slide axis: in the radial plane, perpendicular to the
			# segment joining the two crossing top beams' centers (i.e. along the
			# central axis after projection).
			var module_slide_axis := up_axis
			if top_beams.size() >= 2:
				var c1: Vector3 = top_beams[0]["center"]
				var c2: Vector3 = top_beams[1]["center"]
				var seg := (c2 - c1)
				seg -= up_axis * seg.dot(up_axis)
				if seg.length() > 0.01:
					var perp := up_axis.cross(seg.normalized())
					if perp.length() > 0.01:
						module_slide_axis = perp.normalized()

			for pair_index in range(beam_pairs.size()):
				var pair: Dictionary = beam_pairs[pair_index]
				var face := _build_roof_face(pair["top"], pair["bot"], structure_center,
					true_center, module_slide_axis, pair_index % 2 == 0, up_axis)
				if face.is_empty():
					continue
				face["module_index"] = module_idx
				face["face_index"] = face_index
				face_index += 1
				roof_faces.append(face)
	return roof_faces


static func _group_by_array_index(beams: Array) -> Dictionary:
	var groups: Dictionary = {}
	for beam in beams:
		var idx := int(beam.get("array_index", 0))
		if not groups.has(idx):
			groups[idx] = []
		(groups[idx] as Array).append(beam)
	return groups


static func _group_by_module(beams: Array) -> Dictionary:
	var groups: Dictionary = {}
	for beam in beams:
		var idx := int(beam["module_index"])
		if not groups.has(idx):
			groups[idx] = []
		(groups[idx] as Array).append(beam)
	return groups


## Match top<->bottom beams of the same scissor pattern (parallel axis_x),
## port of the matchBeams closure.
static func _match_beams(top_list: Array, bot_list: Array) -> Array:
	var pairs: Array = []
	var used_bot: Dictionary = {}
	var angle_of := func(b: Dictionary) -> float:
		var c: Vector3 = b["center"]
		return atan2(c.z, c.x)
	var sorted_top := top_list.duplicate()
	sorted_top.sort_custom(func(a, b) -> bool: return angle_of.call(a) < angle_of.call(b))
	var sorted_bot := bot_list.duplicate()
	sorted_bot.sort_custom(func(a, b) -> bool: return angle_of.call(a) < angle_of.call(b))
	for top_beam in sorted_top:
		var best_idx := -1
		var best_score := -INF
		for idx in range(sorted_bot.size()):
			if used_bot.has(idx):
				continue
			var bot_beam: Dictionary = sorted_bot[idx]
			var cross_score := absf((top_beam["axis_x"] as Vector3).dot(bot_beam["axis_x"] as Vector3))
			var dir_score := absf((top_beam["axis_z"] as Vector3).dot(bot_beam["axis_z"] as Vector3))
			var dc := (top_beam["center"] as Vector3) - (bot_beam["center"] as Vector3)
			var dist := Vector2(dc.x, dc.z).length()
			var prox_score := 1.0 / (1.0 + dist * 0.02)
			var score := cross_score * 0.5 + dir_score * 0.3 + prox_score * 0.2
			if score > best_score:
				best_score = score
				best_idx = idx
		if best_idx >= 0 and best_score > 0.3:
			pairs.append({"top": top_beam, "bot": sorted_bot[best_idx]})
			used_bot[best_idx] = true
	return pairs


static func _build_roof_face(top_beam: Dictionary, bot_beam: Dictionary,
		structure_center: Vector3, true_module_center: Vector3,
		module_slide_axis: Vector3, is_a_face: bool, up_axis: Vector3 = Vector3(0, 0, 1)) -> Dictionary:
	var tp1: Vector3 = top_beam["p1"]
	var tp2: Vector3 = top_beam["p2"]
	var bp1: Vector3 = bot_beam["p1"]
	var bp2: Vector3 = bot_beam["p2"]

	var top_dir := (tp2 - tp1).normalized()
	var bot_dir := (bp2 - bp1).normalized()
	var same_direction := top_dir.dot(bot_dir) > 0.0
	var b1 := bp1 if same_direction else bp2
	var b2 := bp2 if same_direction else bp1

	var raw_center := (tp1 + tp2 + b1 + b2) / 4.0
	# Outward = radial direction in the plane perpendicular to the ring's
	# central axis (XY for arch/Z-axis, XZ for cylinder/Y-axis).
	var to_face := raw_center - structure_center
	to_face -= up_axis * to_face.dot(up_axis)
	var outward := up_axis
	if to_face.length() > 0.01:
		outward = to_face.normalized()

	var half_thick := float(top_beam["t"]) / 2.0
	var tl := tp1 + outward * half_thick
	var tr := tp2 + outward * half_thick
	var bl := b1 + outward * half_thick
	var br := b2 + outward * half_thick

	var top_edge := tr - tl
	var bot_edge := br - bl
	var left_edge := bl - tl
	var right_edge := br - tr
	var width := (top_edge.length() + bot_edge.length()) / 2.0
	var height := (left_edge.length() + right_edge.length()) / 2.0
	if width < 2.0 or height < 2.0:
		return {}

	var center := (tl + tr + bl + br) / 4.0
	var width_axis := ((top_edge + bot_edge) * 0.5).normalized()
	var height_axis := ((left_edge + right_edge) * 0.5).normalized()
	var normal := width_axis.cross(height_axis).normalized()
	if normal.dot(outward) < 0.0:
		normal = -normal
		height_axis = -height_axis
	# Re-orthogonalize preserving the slope (height) axis.
	height_axis = (height_axis - normal * height_axis.dot(normal)).normalized()
	width_axis = height_axis.cross(normal).normalized()

	# Slide axis projected onto the face plane; A/B faces slide oppositely.
	var slide_on_plane := module_slide_axis - normal * module_slide_axis.dot(normal)
	var projected_slide := slide_on_plane.normalized() if slide_on_plane.length() > 0.01 else width_axis
	var slide_direction := projected_slide if is_a_face else -projected_slide

	return {
		"is_a_face": is_a_face,
		"center": center,
		"normal": normal,
		"width_axis": width_axis,
		"height_axis": height_axis,
		"slide_direction": slide_direction,
		"width": width,
		"height": height,
	}


## Port of calculateArchLayout + PanelPlacer.placeOnFace.
static func _arch_layout(frame: Dictionary, sec: Dictionary, sp: Dictionary, p: LinkageParams) -> Array:
	var panels: Array = []
	var faces := arch_wall_faces(frame)
	if faces.is_empty():
		return panels

	var num_faces := p.modules * 2
	var enabled_faces: Array = sp.get("arch_wall_faces", [])
	if enabled_faces.size() != num_faces:
		enabled_faces = []

	var rows := int(sec["grid_rows"])
	var cols := int(sec["grid_cols"])
	var panel_w := float(sec["panel_width"])
	var panel_l := float(sec["panel_length"])
	var panel_t := float(sec["panel_thickness"])
	var pad_x := float(sec["padding_x"])
	var pad_y := float(sec["padding_y"])
	var lift := float(sp["arch_panel_offset"]) + panel_t / 2.0
	var slide := float(sp["arch_panel_slide"])
	var separation := float(sp["arch_panel_separation"]) + SEPARATION_BASELINE

	for face in faces:
		var face_idx := int(face["face_index"])
		if not enabled_faces.is_empty() and face_idx < enabled_faces.size() \
				and not bool(enabled_faces[face_idx]):
			continue
		var width_axis: Vector3 = face["width_axis"]
		var height_axis: Vector3 = face["height_axis"]
		var normal: Vector3 = face["normal"]
		var base: Vector3 = (face["center"] as Vector3) \
			+ height_axis * separation \
			+ (face["slide_direction"] as Vector3) * slide \
			+ normal * lift
		for row in range(rows):
			for col in range(cols):
				var local_x := (col - (cols - 1) / 2.0) * (panel_w + pad_x)
				var local_y := (row - (rows - 1) / 2.0) * (panel_l + pad_y)
				panels.append({
					"center": base + width_axis * local_x + height_axis * local_y,
					"axis_x": width_axis,
					"axis_y": normal,
					"axis_z": height_axis,
					"width": panel_w,
					"length": panel_l,
					"thickness": panel_t,
					"watts": float(sec["rated_watts"]),
				})
	return panels


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

static func _beams_of_type(frame: Dictionary, stack_type: String) -> Array:
	return (frame.get("beams", []) as Array).filter(func(b):
		return str(b["stack_type"]) == stack_type)

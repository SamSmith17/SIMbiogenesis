class_name LinkageSolver
extends RefCounted
## Full linkage geometry solver — GDScript port of LinkageLab's
## `js/linkage/solver.js:solveLinkage` (module chaining, H-ring stacks,
## V-scissor stacks, cap uprights, fixed beams, simplified brackets/bolts,
## arch transform, tunnel array duplication).
##
## All coordinates are in INCHES, Y-up, matching the web app exactly so that
## outputs can be pinned against JavaScript reference values. Hardware
## "full detail" assemblies and washers are intentionally NOT ported (scope:
## simplified brackets/bolts as visual geometry only).
##
## Beam dictionaries: { p1, p2, center: Vector3, w, t: float,
##   axis_x, axis_y, axis_z: Vector3, corners: Array[Vector3] (8),
##   stack_type: String, module_index: int, stack_id: int, pattern_id: String }
## Bracket dictionaries: { pos, bottom_pos, v_bolt_pivot: Vector3,
##   is_bottom: bool, beam_dir, right, bolt_dir: Vector3, basis: Basis
##   (x=bolt axis, y=U opening, z=beam axis), width, depth, actual_height,
##   hole_distance, wall_thickness, inner_width: float, module_index: int,
##   pivot_role: String ("outer"|"inner") }
##   `pos` is the H-ring pivot where the simple bracket is drawn; `v_bolt_pivot`
##   is the V-stack corner the DETAILED hardware anchors on. See `_ring_spec`.
## Bolt dictionaries: { start, end, center, dir: Vector3, length, radius,
##   head_radius: float, bolt_type, bolt_sub_type: String, module_index: int }


## Solve the linkage at a fold angle. Returns the geometry frame dictionary:
## { beams, brackets, bolts: Array, max_rad, max_height, top_h, z_height,
##   y_min, y_max: float, module_frames: Array }
static func solve(p_in: LinkageParams, fold_angle: float) -> Dictionary:
	# THE hardware choke point. With "Hardware Full Detail" off this returns
	# `p_in` itself, so everything below is bit-identical to the pre-hardware
	# port and the pinned reference values hold. With it on, the parametric
	# assemblies own the stack gaps and bracket dimensions.
	var p := LinkageHardwareSpacing.effective_params(p_in)
	var h_active_in := p.h_active_in()
	var v_tot_in := p.v_length_ft * LinkageParams.INCHES_PER_FOOT
	var v_active_in := v_tot_in - p.vert_end_offset * 2.0
	var safe_v := maxf(LinkageKinematics.MIN_SAFE_DIMENSION, v_active_in)

	var jr := LinkageKinematics.calculate_joint_positions(fold_angle, h_active_in, p.pivot_pct, p.hoberman_ang, p.pivot_ang)
	var loc: Dictionary = jr["joints"]
	var relative_rotation: float = jr["relative_rotation"]

	# Vertical beam height from radial span (Pythagorean), or the fixed length.
	var z_height := 0.0
	if p.use_fixed_beams:
		z_height = p.v_length_ft * LinkageParams.INCHES_PER_FOOT
	else:
		var radial_span := (loc["tr"] as Vector2).distance_to(loc["br"] as Vector2)
		if safe_v > radial_span:
			z_height = sqrt(safe_v * safe_v - radial_span * radial_span)

	var beams: Array = []
	var brackets: Array = []
	var bolts: Array = []
	var module_frames: Array = []
	var cur_pos := Vector2.ZERO
	var cur_rot := 0.0

	# Visible H-ring endpoints with end offsets applied (extended radially).
	var vis_loc := {
		"bl": _extend_point(loc["bl"], p.offset_bot_in),
		"tr": _extend_point(loc["tr"], p.offset_top_in),
		"br": _extend_point(loc["br"], p.offset_bot_in),
		"tl": _extend_point(loc["tl"], p.offset_top_in),
	}

	# --- Bracket/pivot vertical geometry (constant across modules) ---
	var h_t := p.h_beam_t
	var h_stack_thick := p.h_stack_count * h_t + (p.h_stack_count - 1) * p.h_stack_gap
	var hole_radius := p.bracket_hole_diameter / 2.0
	var min_hole_offset := p.bracket_wall_thickness + hole_radius + 0.1
	var effective_hole_offset := maxf(p.bracket_hole_distance, min_hole_offset)
	var min_bracket_height := effective_hole_offset + hole_radius + 0.1
	var actual_bracket_height := maxf(p.bracket_height, min_bracket_height)
	var y_min := h_stack_thick / 2.0 + effective_hole_offset
	var y_max := y_min + z_height
	var top_h := y_max + h_stack_thick / 2.0 + effective_hole_offset

	var stack_beam_widths := p.v_stack_beam_widths()

	# V-stack bolt lengths (splits for odd stacks > 2), port of solver lines 1789-1792.
	var split_bolts := p.needs_split_v_bolts()
	var v_bolt_length := p.v_bolt_length if p.v_bolt_length > 0.0 else (p.v_stack_total_thickness() + 1.0)
	var v_bolt_inner_length := (p.v_bolt_inner_length if p.v_bolt_inner_length > 0.0 else v_bolt_length) if split_bolts else v_bolt_length
	var v_bolt_outer_length := (p.v_bolt_outer_length if p.v_bolt_outer_length > 0.0 else v_bolt_length) if split_bolts else v_bolt_length

	var max_rad := 0.0

	for i in range(p.modules):
		# --- HORIZONTAL RINGS (bottom stacks up, top stacks down) ---
		_create_beam_stack(beams,
			_map_to_3d(vis_loc["bl"], 0.0, cur_pos, cur_rot), _map_to_3d(vis_loc["tr"], 0.0, cur_pos, cur_rot),
			_map_to_3d(vis_loc["br"], 0.0, cur_pos, cur_rot), _map_to_3d(vis_loc["tl"], 0.0, cur_pos, cur_rot),
			p.h_stack_count, p.h_beam_w, h_t, Vector3.UP, p.h_stack_gap,
			i, "horizontal-bottom", i * 2)
		_create_beam_stack(beams,
			_map_to_3d(vis_loc["bl"], top_h, cur_pos, cur_rot), _map_to_3d(vis_loc["tr"], top_h, cur_pos, cur_rot),
			_map_to_3d(vis_loc["br"], top_h, cur_pos, cur_rot), _map_to_3d(vis_loc["tl"], top_h, cur_pos, cur_rot),
			p.h_stack_count, p.h_beam_w, h_t, Vector3.DOWN, p.h_stack_gap,
			i, "horizontal-top", i * 2 + 1)

		# --- Corner pivot points (shared by uprights, fixed beams, hardware) ---
		var p_bot_inner := _map_to_3d(loc["br"], y_min, cur_pos, cur_rot)
		var p_top_outer := _map_to_3d(loc["tr"], y_max, cur_pos, cur_rot)
		var p_bot_outer := _map_to_3d(loc["tr"], y_min, cur_pos, cur_rot)
		var p_top_inner := _map_to_3d(loc["br"], y_max, cur_pos, cur_rot)

		# --- VERTICAL UPRIGHTS (scissor cross-beam stacks, Pattern A/B) ---
		if z_height > 1.0 and not p.use_fixed_beams:
			_build_v_scissor_stack(beams, p, stack_beam_widths,
				p_bot_inner, p_top_outer, p_bot_outer, p_top_inner,
				i, "vertical", i)
			if i == 0 and p.arch_cap_uprights:
				var cap_bot_inner := _map_to_3d(loc["bl"], y_min, cur_pos, cur_rot)
				var cap_top_outer := _map_to_3d(loc["tl"], y_max, cur_pos, cur_rot)
				var cap_bot_outer := _map_to_3d(loc["tl"], y_min, cur_pos, cur_rot)
				var cap_top_inner := _map_to_3d(loc["bl"], y_max, cur_pos, cur_rot)
				_build_v_scissor_stack(beams, p, stack_beam_widths,
					cap_bot_inner, cap_top_outer, cap_bot_outer, cap_top_inner,
					i, "vertical-cap", -1)

		# --- FIXED STRAIGHT BEAMS (non-folding constant spacing) ---
		if p.use_fixed_beams and z_height > 1.0:
			var inner_dims := p.v_beam_dims_for_pivot(true)
			var outer_dims := p.v_beam_dims_for_pivot(false)
			var bottom_flush_y := h_t / 2.0
			var top_flush_y := top_h - h_t / 2.0
			var inner_start := Vector3(p_bot_inner.x, bottom_flush_y, p_bot_inner.z)
			var inner_end := Vector3(p_top_inner.x, top_flush_y, p_top_inner.z)
			if inner_start.distance_to(inner_end) > 0.1:
				beams.append(_make_beam(inner_start, inner_end, float(inner_dims["w"]), float(inner_dims["t"]),
					{"module_index": i, "stack_type": "fixed-beam", "stack_id": i * 2}))
			var outer_start := Vector3(p_bot_outer.x, bottom_flush_y, p_bot_outer.z)
			var outer_end := Vector3(p_top_outer.x, top_flush_y, p_top_outer.z)
			if outer_start.distance_to(outer_end) > 0.1:
				beams.append(_make_beam(outer_start, outer_end, float(outer_dims["w"]), float(outer_dims["t"]),
					{"module_index": i, "stack_type": "fixed-beam", "stack_id": i * 2 + 1}))
			if i == 0 and p.arch_cap_uprights:
				var cbi := _map_to_3d(loc["bl"], y_min, cur_pos, cur_rot)
				var cti := _map_to_3d(loc["bl"], y_max, cur_pos, cur_rot)
				var cbo := _map_to_3d(loc["tl"], y_min, cur_pos, cur_rot)
				var cto := _map_to_3d(loc["tl"], y_max, cur_pos, cur_rot)
				var ci_start := Vector3(cbi.x, bottom_flush_y, cbi.z)
				var ci_end := Vector3(cti.x, top_flush_y, cti.z)
				if ci_start.distance_to(ci_end) > 0.1:
					beams.append(_make_beam(ci_start, ci_end, float(inner_dims["w"]), float(inner_dims["t"]),
						{"module_index": i, "stack_type": "fixed-beam-cap", "stack_id": -2}))
				var co_start := Vector3(cbo.x, bottom_flush_y, cbo.z)
				var co_end := Vector3(cto.x, top_flush_y, cto.z)
				if co_start.distance_to(co_end) > 0.1:
					beams.append(_make_beam(co_start, co_end, float(outer_dims["w"]), float(outer_dims["t"]),
						{"module_index": i, "stack_type": "fixed-beam-cap", "stack_id": -3}))

		# --- BRACKETS + BOLTS at pivot points (simplified visual hardware) ---
		if (p.show_brackets or p.show_bolts) and z_height > 1.0:
			var h_pivot_bot_inner := _map_to_3d(loc["br"], 0.0, cur_pos, cur_rot)
			var h_pivot_bot_outer := _map_to_3d(loc["tr"], 0.0, cur_pos, cur_rot)
			var h_pivot_top_inner := _map_to_3d(loc["br"], top_h, cur_pos, cur_rot)
			var h_pivot_top_outer := _map_to_3d(loc["tr"], top_h, cur_pos, cur_rot)

			var pattern_a_dir := (p_top_outer - p_bot_inner).normalized()
			var pattern_b_dir := (p_top_inner - p_bot_outer).normalized()
			var avg_pattern_dir := ((pattern_a_dir + pattern_b_dir) * 0.5).normalized()
			var stack_dir_norm := _v_cross(avg_pattern_dir, Vector3.UP).normalized()
			if stack_dir_norm.length() < 0.1:
				stack_dir_norm = _v_cross(pattern_a_dir, Vector3.UP).normalized()
			var pivot_bot_center := (p_bot_inner + p_bot_outer) * 0.5
			var pivot_top_center := (p_top_outer + p_top_inner) * 0.5
			var center_mid := (pivot_bot_center + pivot_top_center) * 0.5
			var v_beam_dir := avg_pattern_dir
			var v_bolt_dir := stack_dir_norm

			if p.show_brackets:
				var ring_pivots := {
					"p_bot_inner": p_bot_inner, "p_bot_outer": p_bot_outer,
					"p_top_inner": p_top_inner, "p_top_outer": p_top_outer,
					"pattern_a_dir": pattern_a_dir, "pattern_b_dir": pattern_b_dir,
					"h_pivot_bot_inner": h_pivot_bot_inner, "h_pivot_bot_outer": h_pivot_bot_outer,
					"h_pivot_top_inner": h_pivot_top_inner, "h_pivot_top_outer": h_pivot_top_outer,
				}
				var outer_bot := _ring_spec(true, p.v_stack_reverse, ring_pivots, false)
				var outer_top := _ring_spec(false, p.v_stack_reverse, ring_pivots, false)
				var inner_bot := _ring_spec(true, not p.v_stack_reverse, ring_pivots, false)
				var inner_top := _ring_spec(false, not p.v_stack_reverse, ring_pivots, false)
				brackets.append(_create_bracket(p, outer_bot["h_pivot"], true, outer_bot["beam_dir"], v_bolt_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, outer_bot["v_bolt_pivot"], "outer"))
				brackets.append(_create_bracket(p, outer_top["h_pivot"], false, outer_top["beam_dir"], v_bolt_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, outer_top["v_bolt_pivot"], "outer"))
				brackets.append(_create_bracket(p, inner_bot["h_pivot"], true, inner_bot["beam_dir"], v_bolt_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, inner_bot["v_bolt_pivot"], "inner"))
				brackets.append(_create_bracket(p, inner_top["h_pivot"], false, inner_top["beam_dir"], v_bolt_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, inner_top["v_bolt_pivot"], "inner"))

			if p.show_bolts:
				var bolt_radius := p.bolt_diameter / 2.0
				# H-pivot bolts (vertical, through H-stack into brackets).
				var h_pivot_len := p.h_pivot_bolt_length if p.h_pivot_bolt_length > 0.0 else p.auto_h_pivot_bolt_length()
				bolts.append(_make_vertical_bolt(h_pivot_bot_inner, 0.0, h_pivot_len, bolt_radius, "hpivot", "bottom"))
				bolts.append(_make_vertical_bolt(h_pivot_bot_outer, 0.0, h_pivot_len, bolt_radius, "hpivot", "bottom"))
				bolts.append(_make_vertical_bolt(h_pivot_top_inner, top_h, h_pivot_len, bolt_radius, "hpivot", "top"))
				bolts.append(_make_vertical_bolt(h_pivot_top_outer, top_h, h_pivot_len, bolt_radius, "hpivot", "top"))
				# Vertical-module bolts (horizontal, through the V stack).
				bolts.append(_make_axis_bolt(p_bot_inner, v_bolt_dir, v_bolt_inner_length, bolt_radius, "vstack", "inner"))
				var bot_outer_pivot := p_bot_outer if p.v_stack_reverse else p_bot_inner
				bolts.append(_make_axis_bolt(bot_outer_pivot, v_bolt_dir, v_bolt_outer_length, bolt_radius, "vstack", "outer"))
				var top_outer_pivot := p_top_inner if p.v_stack_reverse else p_top_outer
				bolts.append(_make_axis_bolt(top_outer_pivot, v_bolt_dir, v_bolt_outer_length, bolt_radius, "vstack", "outer"))
				bolts.append(_make_axis_bolt(p_top_inner, v_bolt_dir, v_bolt_inner_length, bolt_radius, "vstack", "inner"))
				bolts.append(_make_axis_bolt(center_mid, v_bolt_dir, v_bolt_length, bolt_radius, "vstack", "center", i))
				# Cap-upright bolts (first module only).
				if i == 0 and p.arch_cap_uprights:
					var cap_bot_inner := _map_to_3d(loc["bl"], y_min, cur_pos, cur_rot)
					var cap_top_outer := _map_to_3d(loc["tl"], y_max, cur_pos, cur_rot)
					var cap_bot_outer := _map_to_3d(loc["tl"], y_min, cur_pos, cur_rot)
					var cap_top_inner := _map_to_3d(loc["bl"], y_max, cur_pos, cur_rot)
					var cap_center_mid := ((cap_bot_inner + cap_bot_outer) * 0.5 + (cap_top_outer + cap_top_inner) * 0.5) * 0.5
					var cap_a_dir := (cap_top_outer - cap_bot_inner).normalized()
					var cap_b_dir := (cap_top_inner - cap_bot_outer).normalized()
					var cap_bolt_dir := _v_cross(cap_a_dir, cap_b_dir).normalized()
					if cap_bolt_dir.length() < 0.1:
						var cap_avg := ((cap_a_dir + cap_b_dir) * 0.5).normalized()
						cap_bolt_dir = _v_cross(cap_avg, Vector3.UP).normalized()
					bolts.append(_make_axis_bolt(cap_bot_inner, cap_bolt_dir, v_bolt_inner_length, bolt_radius, "vstack", "inner"))
					bolts.append(_make_axis_bolt(cap_bot_outer, cap_bolt_dir, v_bolt_outer_length, bolt_radius, "vstack", "outer"))
					bolts.append(_make_axis_bolt(cap_top_outer, cap_bolt_dir, v_bolt_outer_length, bolt_radius, "vstack", "outer"))
					bolts.append(_make_axis_bolt(cap_top_inner, cap_bolt_dir, v_bolt_inner_length, bolt_radius, "vstack", "inner"))
					bolts.append(_make_axis_bolt(cap_center_mid, cap_bolt_dir, v_bolt_length, bolt_radius, "vstack", "center", i))

			# Cap-upright brackets (first module only).
			if i == 0 and p.arch_cap_uprights and p.show_brackets:
				# The BRACKET block spans the H-ring heights (0..top_h), while the
				# BOLT block above spans the upright heights (y_min..y_max). The
				# web genuinely differs between the two (solver.js:2103 vs
				# :2134) — same names, different chords — and it is the bracket
				# chord that orients the cap hardware. Using the bolt block's
				# heights here tilted every cap joint by about half a degree.
				var cap_pivots := {
					"pattern_a_dir": (_map_to_3d(loc["tl"], top_h, cur_pos, cur_rot) - _map_to_3d(loc["bl"], 0.0, cur_pos, cur_rot)).normalized(),
					"pattern_b_dir": (_map_to_3d(loc["bl"], top_h, cur_pos, cur_rot) - _map_to_3d(loc["tl"], 0.0, cur_pos, cur_rot)).normalized(),
					"h_pivot_bot_outer": _map_to_3d(loc["tl"], 0.0, cur_pos, cur_rot),
					"h_pivot_bot_inner": _map_to_3d(loc["bl"], 0.0, cur_pos, cur_rot),
					"h_pivot_top_outer": _map_to_3d(loc["tl"], top_h, cur_pos, cur_rot),
					"h_pivot_top_inner": _map_to_3d(loc["bl"], top_h, cur_pos, cur_rot),
					# V-stack corners for the detailed hardware anchor. The cap
					# uprights sit on the LEFT pair, so "outer" is tl and "inner"
					# is bl (getCapOuterVBeamRingSpec, solver.js:2150-2153) —
					# mirroring the main ring's tr/br.
					"p_bot_outer": _map_to_3d(loc["tl"], y_min, cur_pos, cur_rot),
					"p_bot_inner": _map_to_3d(loc["bl"], y_min, cur_pos, cur_rot),
					"p_top_outer": _map_to_3d(loc["tl"], y_max, cur_pos, cur_rot),
					"p_top_inner": _map_to_3d(loc["bl"], y_max, cur_pos, cur_rot),
				}
				var cap_outer_bot := _ring_spec(true, p.v_stack_reverse, cap_pivots, true)
				var cap_outer_top := _ring_spec(false, p.v_stack_reverse, cap_pivots, true)
				var cap_inner_bot := _ring_spec(true, not p.v_stack_reverse, cap_pivots, true)
				var cap_inner_top := _ring_spec(false, not p.v_stack_reverse, cap_pivots, true)
				var cap_a := cap_pivots["pattern_a_dir"] as Vector3
				var cap_b := cap_pivots["pattern_b_dir"] as Vector3
				var cap_stack_dir := _v_cross(cap_a, cap_b).normalized()
				if cap_stack_dir.length() < 0.1:
					cap_stack_dir = _v_cross(((cap_a + cap_b) * 0.5).normalized(), Vector3.UP).normalized()
				brackets.append(_create_bracket(p, cap_outer_bot["h_pivot"], true, cap_outer_bot["beam_dir"], cap_stack_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, cap_outer_bot["v_bolt_pivot"], "outer"))
				brackets.append(_create_bracket(p, cap_outer_top["h_pivot"], false, cap_outer_top["beam_dir"], cap_stack_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, cap_outer_top["v_bolt_pivot"], "outer"))
				brackets.append(_create_bracket(p, cap_inner_bot["h_pivot"], true, cap_inner_bot["beam_dir"], cap_stack_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, cap_inner_bot["v_bolt_pivot"], "inner"))
				brackets.append(_create_bracket(p, cap_inner_top["h_pivot"], false, cap_inner_top["beam_dir"], cap_stack_dir, i, h_stack_thick, top_h, y_min, y_max, actual_bracket_height, effective_hole_offset, cap_inner_top["v_bolt_pivot"], "inner"))

		# H-center bolts (vertical, through the H stacks at the X crossing).
		# NOTE: outside the zHeight gate, matching the JS source exactly.
		if p.show_bolts:
			var h_center_2d := _line_intersection_2d(vis_loc["bl"], vis_loc["tr"], vis_loc["br"], vis_loc["tl"])
			var h_center_bot := _map_to_3d(h_center_2d, 0.0, cur_pos, cur_rot)
			var h_center_top := _map_to_3d(h_center_2d, top_h, cur_pos, cur_rot)
			var h_bolt_len := p.h_bolt_length if p.h_bolt_length > 0.0 else (p.h_stack_count * h_t + 1.0)
			var bolt_radius2 := p.bolt_diameter / 2.0
			bolts.append(_make_vertical_bolt(h_center_bot, 0.0, h_bolt_len, bolt_radius2, "hstack", "center", i))
			bolts.append(_make_vertical_bolt(h_center_top, top_h, h_bolt_len, bolt_radius2, "hstack", "center", i))

		# --- Module frame record (for support beams / panels / diagnostics) ---
		module_frames.append({
			"index": i,
			"rot": cur_rot,
			"p_bot_inner": p_bot_inner, "p_bot_outer": p_bot_outer,
			"p_top_inner": p_top_inner, "p_top_outer": p_top_outer,
			"top_outer_vis": _map_to_3d(vis_loc["tr"], top_h, cur_pos, cur_rot),
			"bot_outer_vis": _map_to_3d(vis_loc["tr"], 0.0, cur_pos, cur_rot),
			"top_inner_vis": _map_to_3d(vis_loc["br"], top_h, cur_pos, cur_rot),
		})

		# Track max radius (cylinder mode; arch recomputes below).
		var current_radius := _map_to_3d(vis_loc["tr"], 0.0, cur_pos, cur_rot).length()
		if current_radius > max_rad:
			max_rad = current_radius

		# --- Chain the next module: align next bl to current br ---
		var next_rotation := cur_rot + relative_rotation
		var next_bl := (loc["bl"] as Vector2).rotated(next_rotation)
		var current_br := (loc["br"] as Vector2).rotated(cur_rot)
		cur_pos = cur_pos + current_br - next_bl
		cur_rot = next_rotation

	var max_height := z_height + h_stack_thick + 2.0 * effective_hole_offset + h_stack_thick / 2.0 + p.vert_end_offset

	# --- Arch (vertical) mode: rotate the ring 90° about X and ground the feet ---
	if p.orientation == "vertical":
		var arch := _apply_arch_transform(p, beams, brackets, bolts, module_frames)
		max_height = arch["max_height"]
		max_rad = arch["max_rad"]

	# --- Array duplication (tunnel/tube, arch only) ---
	if p.array_count > 1 and p.orientation == "vertical":
		_duplicate_array(p, beams, brackets, bolts, module_frames)

	# --- Canonical bracket orientation frames (after all transforms) ---
	var is_arch := p.orientation == "vertical"
	for bracket in brackets:
		bracket["basis"] = bracket_basis_for(bracket, is_arch)

	return {
		"beams": beams,
		"brackets": brackets,
		"bolts": bolts,
		"max_rad": max_rad,
		"max_height": max_height,
		"top_h": top_h,
		"z_height": z_height,
		"y_min": y_min,
		"y_max": y_max,
		"module_frames": module_frames,
		"orientation": p.orientation,
	}


# ---------------------------------------------------------------------------
# Geometry primitives
# ---------------------------------------------------------------------------

## JS cross product convention (same as Godot's Vector3.cross).
static func _v_cross(a: Vector3, b: Vector3) -> Vector3:
	return Vector3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)


## Port of Beam3D: rectangular prism from p1 to p2 with width x thickness.
static func _make_beam(start: Vector3, end: Vector3, width: float, thick: float, meta: Dictionary) -> Dictionary:
	var axis_z := (end - start).normalized()
	var up := Vector3(1, 0, 0) if absf(axis_z.y) > 0.99 else Vector3(0, 1, 0)
	var axis_x := _v_cross(axis_z, up).normalized()
	var axis_y := _v_cross(axis_x, axis_z).normalized()
	var hw := width / 2.0
	var ht := thick / 2.0
	var corners: Array = []
	for c in [start, end]:
		for o in [Vector2(-hw, -ht), Vector2(hw, -ht), Vector2(hw, ht), Vector2(-hw, ht)]:
			corners.append(c + axis_x * o.x + axis_y * o.y)
	return {
		"p1": start, "p2": end,
		"center": (start + end) * 0.5,
		"w": width, "t": thick,
		"axis_x": axis_x, "axis_y": axis_y, "axis_z": axis_z,
		"corners": corners,
		"module_index": int(meta.get("module_index", -1)),
		"stack_type": str(meta.get("stack_type", "unknown")),
		"stack_id": int(meta.get("stack_id", -1)),
		"pattern_id": str(meta.get("pattern_id", "")),
	}


## Port of extendPoint: extend a 2D point radially outward from origin.
static func _extend_point(pt: Vector2, dist: float) -> Vector2:
	var length := pt.length()
	if length == 0.0:
		return pt
	return pt * (1.0 + dist / length)


## Port of mapTo3D: 2D joint plane -> world XZ at height h, yawed by cur_rot.
static func _map_to_3d(pt: Vector2, h: float, cur_pos: Vector2, cur_rot: float) -> Vector3:
	var r := pt.rotated(cur_rot)
	return Vector3(cur_pos.x + r.x, h, cur_pos.y + r.y)


## Port of createBeamStack: alternating Pattern A/B beams offset along offset_dir.
static func _create_beam_stack(beams: Array, p1_a: Vector3, p2_a: Vector3, p1_b: Vector3, p2_b: Vector3, count: int, width: float, thick: float, offset_dir: Vector3, gap: float, module_index: int, stack_type: String, stack_id: int) -> void:
	var dir := offset_dir.normalized()
	if dir.length() < 0.001:
		dir = Vector3(1, 0, 0)
	var total_thick := count * thick + (count - 1) * gap
	var start_offset := -total_thick / 2.0 + thick / 2.0
	for i in range(count):
		var offset_value := start_offset + i * (thick + gap)
		var vector_offset := dir * offset_value
		var is_pattern_a := i % 2 == 0
		var start := (p1_a if is_pattern_a else p1_b) + vector_offset
		var end := (p2_a if is_pattern_a else p2_b) + vector_offset
		beams.append(_make_beam(start, end, width, thick, {
			"module_index": module_index, "stack_type": stack_type,
			"stack_id": stack_id, "pattern_id": "A" if is_pattern_a else "B",
		}))


## V-scissor stack builder — port of the vertical-uprights block of solveLinkage
## (centering each pattern on the center pivot line, then stacking).
static func _build_v_scissor_stack(beams: Array, p: LinkageParams, stack_beam_widths: Array, p_bot_inner: Vector3, p_top_outer: Vector3, p_bot_outer: Vector3, p_top_inner: Vector3, module_index: int, stack_type: String, stack_id: int) -> void:
	var pivot_bot_center := (p_bot_inner + p_bot_outer) * 0.5
	var pivot_top_center := (p_top_outer + p_top_inner) * 0.5

	var pattern_a_bot := p_bot_inner
	var pattern_a_top := p_top_outer
	var pattern_a_dir := (pattern_a_top - pattern_a_bot).normalized()
	var pattern_a_mid := (pattern_a_bot + pattern_a_top) * 0.5
	var pattern_b_bot := p_bot_outer
	var pattern_b_top := p_top_inner
	var pattern_b_dir := (pattern_b_top - pattern_b_bot).normalized()
	var pattern_b_mid := (pattern_b_bot + pattern_b_top) * 0.5
	var avg_pattern_dir := ((pattern_a_dir + pattern_b_dir) * 0.5).normalized()
	var up := Vector3.UP

	# Stack direction: perpendicular to BOTH pattern directions (cross product),
	# with the same fallback ladder as the JS.
	var rad_vec := (pivot_bot_center - Vector3.ZERO).normalized()
	var stack_dir := _v_cross(pattern_a_dir, pattern_b_dir).normalized()
	if stack_dir.length() < 0.1:
		stack_dir = _v_cross(rad_vec, avg_pattern_dir).normalized()
	var dot_a := absf(stack_dir.dot(pattern_a_dir))
	var dot_b := absf(stack_dir.dot(pattern_b_dir))
	if dot_a > 0.1 or dot_b > 0.1 or stack_dir.length() < 0.1:
		stack_dir = _v_cross(avg_pattern_dir, up).normalized()
		var dot2_a := absf(stack_dir.dot(pattern_a_dir))
		var dot2_b := absf(stack_dir.dot(pattern_b_dir))
		if dot2_a > 0.1 or dot2_b > 0.1 or stack_dir.length() < 0.1:
			var perp_vec: Vector3
			if absf(avg_pattern_dir.y) > 0.9:
				perp_vec = Vector3(1, 0, 0)
			elif absf(avg_pattern_dir.x) > 0.9:
				perp_vec = Vector3(0, 0, 1)
			else:
				perp_vec = Vector3(-avg_pattern_dir.z, 0, avg_pattern_dir.x)
			stack_dir = (perp_vec - avg_pattern_dir * perp_vec.dot(avg_pattern_dir)).normalized()
	var final_dot_a := absf(stack_dir.dot(pattern_a_dir))
	var final_dot_b := absf(stack_dir.dot(pattern_b_dir))
	if final_dot_a > 0.01:
		stack_dir = (stack_dir - pattern_a_dir * stack_dir.dot(pattern_a_dir)).normalized()
	if final_dot_b > 0.01:
		stack_dir = (stack_dir - pattern_b_dir * stack_dir.dot(pattern_b_dir)).normalized()
	if stack_dir.length() < 0.1:
		stack_dir = _v_cross(pattern_a_dir, up).normalized()
		if stack_dir.length() < 0.1:
			stack_dir = Vector3(-rad_vec.z, rad_vec.y, rad_vec.x).normalized()

	var stack_dir_norm := stack_dir.normalized()
	var center_mid := (pivot_bot_center + pivot_top_center) * 0.5

	# Global centering offset so the average of all beam midpoints (incl. stack
	# offsets) lands on the center pivot line.
	var total_position := Vector3.ZERO
	for vi in range(p.v_stack_count):
		var offset_value := p.v_stack_beam_center_offset(vi, stack_beam_widths)
		var is_a := (vi % 2 != 0) if p.v_stack_reverse else (vi % 2 == 0)
		var pattern_mid := pattern_a_mid if is_a else pattern_b_mid
		total_position += pattern_mid + stack_dir_norm * offset_value
	var avg_actual_mid := total_position / float(p.v_stack_count)
	var offset_to_center := center_mid - avg_actual_mid
	var global_centering_offset := stack_dir_norm * offset_to_center.dot(stack_dir_norm)

	for vi in range(p.v_stack_count):
		var offset_value := p.v_stack_beam_center_offset(vi, stack_beam_widths)
		var stack_offset := stack_dir_norm * offset_value
		var beam_dims := p.v_beam_dims_for_stack_index(vi)
		var is_a := (vi % 2 != 0) if p.v_stack_reverse else (vi % 2 == 0)
		var pattern_bot := pattern_a_bot if is_a else pattern_b_bot
		var pattern_top := pattern_a_top if is_a else pattern_b_top
		var pattern_dir := pattern_a_dir if is_a else pattern_b_dir
		var beam_start := pattern_bot + global_centering_offset + stack_offset
		var beam_end := pattern_top + global_centering_offset + stack_offset
		var ext_start := beam_start + pattern_dir * -p.vert_end_offset
		var ext_end := beam_end + pattern_dir * p.vert_end_offset
		beams.append(_make_beam(ext_start, ext_end, float(beam_dims["w"]), float(beam_dims["t"]), {
			"module_index": module_index, "stack_type": stack_type,
			"stack_id": stack_id, "pattern_id": "A" if is_a else "B",
		}))


## Ring pivot spec for a bracket — port of getOuterVBeamRingSpec /
## getCapOuterVBeamRingSpec (call with stack_reversed flipped for the inner rule).
##
## TWO pivots come out of here and they are NOT interchangeable. `h_pivot` is
## where the simple bracket is drawn — on the horizontal ring. `v_bolt_pivot` is
## the V-stack corner the crossed uprights actually bolt through, and it is what
## the DETAILED hardware assembly is anchored on (solver.js:1987-1995 passes
## `spec.vBoltPivot` into `hwAddAssemblyPlacement`, and
## `hwComputeAssemblyTransform` prefers it over the bracket position). Anchoring
## the detailed stack on `h_pivot` puts it in the right neighbourhood and the
## wrong relation to the beams.
static func _ring_spec(is_bottom: bool, stack_reversed: bool, pivots: Dictionary, _is_cap: bool) -> Dictionary:
	if is_bottom:
		if stack_reversed:
			return {"h_pivot": pivots["h_pivot_bot_outer"],
				"v_bolt_pivot": pivots["p_bot_outer"], "beam_dir": pivots["pattern_b_dir"]}
		return {"h_pivot": pivots["h_pivot_bot_inner"],
			"v_bolt_pivot": pivots["p_bot_inner"], "beam_dir": pivots["pattern_a_dir"]}
	if stack_reversed:
		return {"h_pivot": pivots["h_pivot_top_inner"],
			"v_bolt_pivot": pivots["p_top_inner"], "beam_dir": pivots["pattern_b_dir"]}
	return {"h_pivot": pivots["h_pivot_top_outer"],
		"v_bolt_pivot": pivots["p_top_outer"], "beam_dir": pivots["pattern_a_dir"]}


static func _create_bracket(p: LinkageParams, pivot_pos: Vector3, is_bottom: bool, beam_dir: Vector3, v_bolt_dir: Vector3, module_index: int, h_stack_thick: float, top_h: float, _y_min: float, _y_max: float, actual_bracket_height: float, effective_hole_offset: float, v_bolt_pivot: Vector3 = Vector3.ZERO, pivot_role: String = "outer") -> Dictionary:
	var bracket_bottom_y := h_stack_thick / 2.0 if is_bottom else top_h - h_stack_thick / 2.0
	var right := _v_cross(beam_dir, Vector3.UP).normalized()
	return {
		"pos": pivot_pos,
		# The V-stack corner this joint bolts through, and which of the two
		# crossing radial lines it rides. Consumed only by LinkageHwPlacement —
		# the simple bracket mesh is still drawn at `pos`.
		"v_bolt_pivot": v_bolt_pivot,
		"pivot_role": pivot_role,
		"bottom_y": bracket_bottom_y,
		"bottom_pos": Vector3(pivot_pos.x, bracket_bottom_y, pivot_pos.z),
		"actual_height": actual_bracket_height,
		"hole_distance": effective_hole_offset,
		"width": p.bracket_width,
		"depth": p.bracket_depth,
		"wall_thickness": p.bracket_wall_thickness,
		"inner_width": p.bracket_inner_width,
		"hole_diameter": p.bracket_hole_diameter,
		"beam_dir": beam_dir,
		"right": right,
		"bolt_dir": v_bolt_dir,
		"is_bottom": is_bottom,
		"module_index": module_index,
	}


static func _make_axis_bolt(pos: Vector3, dir: Vector3, length: float, radius: float, bolt_type: String, sub_type: String, module_index: int = -1) -> Dictionary:
	return {
		"start": pos + dir * (-length / 2.0),
		"end": pos + dir * (length / 2.0),
		"center": pos,
		"dir": dir,
		"length": length,
		"radius": radius,
		"head_radius": radius * 1.8,
		"bolt_type": bolt_type,
		"bolt_sub_type": sub_type,
		"module_index": module_index,
	}


static func _make_vertical_bolt(pos: Vector3, center_y: float, length: float, radius: float, bolt_type: String, sub_type: String, module_index: int = -1) -> Dictionary:
	return {
		"start": Vector3(pos.x, center_y - length / 2.0, pos.z),
		"end": Vector3(pos.x, center_y + length / 2.0, pos.z),
		"center": Vector3(pos.x, center_y, pos.z),
		"dir": Vector3.UP,
		"length": length,
		"radius": radius,
		"head_radius": radius * 1.8,
		"bolt_type": bolt_type,
		"bolt_sub_type": sub_type,
		"module_index": module_index,
	}


## Parametric intersection of the two H-ring crossing lines (Pattern A: bl->tr,
## Pattern B: br->tl); falls back to the quad midpoint when parallel.
static func _line_intersection_2d(bl: Vector2, tr: Vector2, br: Vector2, tl: Vector2) -> Vector2:
	var d1 := tr - bl
	var d2 := tl - br
	var denom := d1.x * d2.y - d1.y * d2.x
	if absf(denom) > 0.0001:
		var t := ((br.x - bl.x) * d2.y - (br.y - bl.y) * d2.x) / denom
		return bl + d1 * t
	return (bl + tr + br + tl) * 0.25


# ---------------------------------------------------------------------------
# Bracket orientation basis — port of computeHwBracketBasis
# ---------------------------------------------------------------------------

## Canonical right-handed frame for a pivot bracket. Columns map LOCAL axes to
## WORLD: x = bolt axis, y = U-channel opening, z = beam axis. Cylinder mode
## keeps the bracket upright (yaw only); arch mode tilts in full 3D.
##
## `flip_stack_axis` mirrors the bolt and beam axes (a half-turn about the
## bracket's up) so an ASYMMETRIC hardware stack sits on the correct side of the
## V-stack. The two outer V-beams cross, so consecutive joints ride opposite
## radial lines and half of them need the mirror. Simple brackets are symmetric
## and pass false — which is why `bracket["basis"]`, and every value pinned
## against it, is unaffected by this parameter existing.
static func compute_bracket_basis(beam_dir: Vector3, v_bolt_dir: Vector3, is_bottom: bool, is_arch: bool, flip_stack_axis: bool = false) -> Basis:
	var beam_axis := beam_dir.normalized()
	if beam_axis.length() < 1e-4:
		beam_axis = Vector3(0, 0, 1)

	if not is_arch:
		var h := Vector2(beam_axis.x, beam_axis.z).length()
		var z := Vector3(beam_axis.x / h, 0.0, beam_axis.z / h) if h > 1e-4 else Vector3(0, 0, 1)
		var y := Vector3(0, 1, 0)
		var x := _v_cross(y, z).normalized()
		if x.length() < 1e-4:
			x = Vector3(1, 0, 0)
		var bolt := v_bolt_dir.normalized()
		if bolt.length() > 1e-4 and x.dot(bolt) < 0.0:
			x = -x
			z = -z
		if not is_bottom:
			y = -y
			z = -z
		if flip_stack_axis:
			x = -x
			z = -z
		return Basis(x, y, z)

	var bolt_axis := v_bolt_dir.normalized()
	if bolt_axis.length() < 1e-4:
		bolt_axis = _v_cross(beam_axis, Vector3.UP).normalized()
	bolt_axis = bolt_axis - beam_axis * bolt_axis.dot(beam_axis)
	if bolt_axis.length() < 1e-4:
		bolt_axis = _v_cross(beam_axis, Vector3.UP).normalized()
		if bolt_axis.length() < 1e-4:
			bolt_axis = Vector3(1, 0, 0)
	bolt_axis = bolt_axis.normalized()

	var up := _v_cross(beam_axis, bolt_axis).normalized()
	if up.length() < 1e-4:
		up = Vector3.UP
	var want_up_sign := 1.0 if is_bottom else -1.0
	var have_up_sign := 1.0 if up.y >= 0.0 else -1.0
	if have_up_sign != want_up_sign:
		up = -up
		bolt_axis = -bolt_axis
	if flip_stack_axis:
		bolt_axis = -bolt_axis
		beam_axis = -beam_axis
	return Basis(bolt_axis, up, beam_axis)


## `compute_bracket_basis` for a solved bracket dict, resolving the bolt-axis
## fallback in one place. `flip` defaults false, which is the SIMPLE bracket's
## frame — the one stamped onto `bracket["basis"]` and pinned by the selftest.
## The detailed hardware asks for the flipped variant per joint.
static func bracket_basis_for(bracket: Dictionary, is_arch: bool, flip: bool = false) -> Basis:
	var bolt_dir: Vector3 = bracket.get("bolt_dir", Vector3.ZERO)
	if bolt_dir.length() < 1e-4:
		bolt_dir = bracket.get("right", Vector3.RIGHT)
	return compute_bracket_basis(bracket.get("beam_dir", Vector3.BACK), bolt_dir,
		bool(bracket.get("is_bottom", false)), is_arch, flip)


# ---------------------------------------------------------------------------
# Arch (vertical) mode transform — port of the orientation === 'vertical' block
# ---------------------------------------------------------------------------

static func _apply_arch_transform(p: LinkageParams, beams: Array, brackets: Array, bolts: Array, module_frames: Array) -> Dictionary:
	# Step 1: find the feet — outermost pivots of first and last modules
	# (cap uprights, when present, provide the left foot).
	var left_foot := Vector3.ZERO
	var right_foot := Vector3.ZERO
	var left_found := false
	var right_found := false

	if p.arch_cap_uprights:
		var max_rad_cap := -INF
		for beam in beams:
			var st: String = beam["stack_type"]
			if st != "vertical-cap" and st != "fixed-beam-cap":
				continue
			for pt in [beam["p1"], beam["p2"]]:
				var v: Vector3 = pt
				var rad := Vector2(v.x, v.z).length()
				if rad > max_rad_cap:
					max_rad_cap = rad
					left_foot = v
					left_found = true
			for c in beam["corners"]:
				var cv: Vector3 = c
				var crad := Vector2(cv.x, cv.z).length()
				if crad > max_rad_cap:
					max_rad_cap = crad
					left_foot = cv
					left_found = true

	var h_beams: Array = beams.filter(func(b): return (b["stack_type"] as String).begins_with("horizontal"))
	if h_beams.size() >= 2:
		var min_module := int(INF)
		var max_module := -int(INF)
		for beam in h_beams:
			min_module = mini(min_module, beam["module_index"])
			max_module = maxi(max_module, beam["module_index"])
		if not left_found:
			var max_rad_first := -INF
			for beam in h_beams:
				if beam["module_index"] != min_module:
					continue
				for pt in [beam["p1"], beam["p2"]]:
					var v: Vector3 = pt
					var rad := Vector2(v.x, v.z).length()
					if rad > max_rad_first:
						max_rad_first = rad
						left_foot = v
						left_found = true
		var max_rad_last := -INF
		for beam in h_beams:
			if beam["module_index"] != max_module:
				continue
			for pt in [beam["p1"], beam["p2"]]:
				var v: Vector3 = pt
				var rad := Vector2(v.x, v.z).length()
				if rad > max_rad_last:
					max_rad_last = rad
					right_foot = v
					right_found = true

	if not left_found or not right_found:
		var centroid := Vector3.ZERO
		var count := 0
		for beam in beams:
			for c in beam["corners"]:
				centroid += c
				count += 1
		if count > 0:
			centroid /= float(count)
		if not left_found:
			left_foot = centroid + Vector3(-10, 0, 0)
		if not right_found:
			right_foot = centroid + Vector3(10, 0, 0)

	# Step 2: rotation that aligns the feet with X, plus user rotation and flip.
	var mid := (left_foot + right_foot) * 0.5
	var foot_angle := atan2(right_foot.z - left_foot.z, right_foot.x - left_foot.x)
	var total_rot_y := -foot_angle + deg_to_rad(p.arch_rotation)
	var cos_r := cos(total_rot_y)
	var sin_r := sin(total_rot_y)
	var flip_y := -1.0 if p.arch_flip_vertical else 1.0

	var xf := func(pt: Vector3) -> Vector3:
		var x := pt.x - mid.x
		var y := pt.y - mid.y
		var z := pt.z - mid.z
		var x2 := x * cos_r - z * sin_r
		var z2 := x * sin_r + z * cos_r
		# 90° about X: (x, y, z) -> (x, z, -y), with vertical flip.
		return Vector3(x2, z2 * flip_y, -y)

	var xf_dir := func(v: Vector3) -> Vector3:
		var x2 := v.x * cos_r - v.z * sin_r
		var z2 := v.x * sin_r + v.z * cos_r
		return Vector3(x2, z2 * flip_y, -v.y)

	for beam in beams:
		beam["p1"] = xf.call(beam["p1"])
		beam["p2"] = xf.call(beam["p2"])
		beam["center"] = xf.call(beam["center"])
		beam["axis_x"] = xf_dir.call(beam["axis_x"])
		beam["axis_y"] = xf_dir.call(beam["axis_y"])
		beam["axis_z"] = xf_dir.call(beam["axis_z"])
		var new_corners: Array = []
		for c in beam["corners"]:
			new_corners.append(xf.call(c))
		beam["corners"] = new_corners

	for bracket in brackets:
		var bottom_offset := Vector3(0, bracket["bottom_y"] - (bracket["pos"] as Vector3).y, 0)
		bracket["pos"] = xf.call(bracket["pos"])
		bracket["beam_dir"] = xf_dir.call(bracket["beam_dir"])
		bracket["right"] = xf_dir.call(bracket["right"])
		bracket["bolt_dir"] = xf_dir.call(bracket["bolt_dir"])
		bracket["bottom_pos"] = (bracket["pos"] as Vector3) + (xf_dir.call(bottom_offset) as Vector3)
		bracket["bottom_y"] = (bracket["pos"] as Vector3).y
		# A point, so it rides the same transform as `pos` (solver.js:2518).
		bracket["v_bolt_pivot"] = xf.call(bracket.get("v_bolt_pivot", Vector3.ZERO))

	for bolt in bolts:
		bolt["start"] = xf.call(bolt["start"])
		bolt["end"] = xf.call(bolt["end"])
		bolt["center"] = xf.call(bolt["center"])
		bolt["dir"] = xf_dir.call(bolt["dir"])

	for frame in module_frames:
		for key in ["p_bot_inner", "p_bot_outer", "p_top_inner", "p_top_outer", "top_outer_vis", "bot_outer_vis", "top_inner_vis"]:
			frame[key] = xf.call(frame[key])

	left_foot = xf.call(left_foot)
	right_foot = xf.call(right_foot)

	# Step 4: ground to the feet (feet at Y=0, centered on X).
	var feet_y := minf(left_foot.y, right_foot.y)
	var feet_center_x := (left_foot.x + right_foot.x) / 2.0
	var ground := func(pt: Vector3) -> Vector3:
		return Vector3(pt.x - feet_center_x, pt.y - feet_y, pt.z)

	for beam in beams:
		beam["p1"] = ground.call(beam["p1"])
		beam["p2"] = ground.call(beam["p2"])
		beam["center"] = ground.call(beam["center"])
		var new_corners2: Array = []
		for c in beam["corners"]:
			new_corners2.append(ground.call(c))
		beam["corners"] = new_corners2
	for bracket in brackets:
		bracket["pos"] = ground.call(bracket["pos"])
		bracket["bottom_y"] = float(bracket["bottom_y"]) - feet_y
		bracket["bottom_pos"] = ground.call(bracket["bottom_pos"])
		bracket["v_bolt_pivot"] = ground.call(bracket.get("v_bolt_pivot", Vector3.ZERO))
	for bolt in bolts:
		bolt["start"] = ground.call(bolt["start"])
		bolt["end"] = ground.call(bolt["end"])
		bolt["center"] = ground.call(bolt["center"])
	for frame in module_frames:
		for key in ["p_bot_inner", "p_bot_outer", "p_top_inner", "p_top_outer", "top_outer_vis", "bot_outer_vis", "top_inner_vis"]:
			frame[key] = ground.call(frame[key])

	var max_y := -INF
	var max_abs_x := 0.0
	for beam in beams:
		for c in beam["corners"]:
			var cv: Vector3 = c
			if cv.y > max_y:
				max_y = cv.y
			if absf(cv.x) > max_abs_x:
				max_abs_x = absf(cv.x)

	return {"max_height": maxf(max_y, 0.0), "max_rad": max_abs_x}


# ---------------------------------------------------------------------------
# Array duplication (tunnel/tube mode)
# ---------------------------------------------------------------------------

static func _duplicate_array(p: LinkageParams, beams: Array, brackets: Array, bolts: Array, module_frames: Array) -> void:
	var min_z := INF
	var max_z := -INF
	for beam in beams:
		for c in beam["corners"]:
			var cv: Vector3 = c
			min_z = minf(min_z, cv.z)
			max_z = maxf(max_z, cv.z)
		for pt in [beam["p1"], beam["p2"]]:
			var v: Vector3 = pt
			min_z = minf(min_z, v.z)
			max_z = maxf(max_z, v.z)
	var spacing := max_z - min_z

	var original_beams := beams.duplicate()
	var original_brackets := brackets.duplicate()
	var original_bolts := bolts.duplicate()
	var original_frames := module_frames.duplicate()
	beams.clear()
	brackets.clear()
	bolts.clear()
	module_frames.clear()

	var total_array_depth := (p.array_count - 1) * spacing
	var start_offset_z := -total_array_depth / 2.0

	for i in range(p.array_count):
		var offset := Vector3(0, 0, start_offset_z + i * spacing)
		for beam in original_beams:
			var nb: Dictionary = beam.duplicate()
			nb["p1"] = (beam["p1"] as Vector3) + offset
			nb["p2"] = (beam["p2"] as Vector3) + offset
			nb["center"] = (beam["center"] as Vector3) + offset
			var nc: Array = []
			for c in beam["corners"]:
				nc.append((c as Vector3) + offset)
			nb["corners"] = nc
			nb["array_index"] = i
			beams.append(nb)
		for bracket in original_brackets:
			var nbr: Dictionary = bracket.duplicate()
			nbr["pos"] = (bracket["pos"] as Vector3) + offset
			nbr["bottom_pos"] = (bracket["bottom_pos"] as Vector3) + offset
			nbr["v_bolt_pivot"] = (bracket.get("v_bolt_pivot", Vector3.ZERO) as Vector3) + offset
			nbr["array_index"] = i
			brackets.append(nbr)
		for bolt in original_bolts:
			var nbo: Dictionary = bolt.duplicate()
			nbo["start"] = (bolt["start"] as Vector3) + offset
			nbo["end"] = (bolt["end"] as Vector3) + offset
			nbo["center"] = (bolt["center"] as Vector3) + offset
			nbo["array_index"] = i
			bolts.append(nbo)
		for frame in original_frames:
			var nf: Dictionary = frame.duplicate()
			for key in ["p_bot_inner", "p_bot_outer", "p_top_inner", "p_top_outer", "top_outer_vis", "bot_outer_vis", "top_inner_vis"]:
				nf[key] = (frame[key] as Vector3) + offset
			nf["array_index"] = i
			module_frames.append(nf)

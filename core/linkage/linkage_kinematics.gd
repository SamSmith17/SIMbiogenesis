class_name LinkageKinematics
extends RefCounted
## Scissor-linkage fold kinematics — GDScript port of LinkageLab's
## `js/linkage/joint-kinematics.js` plus the min-fold search from
## `js/linkage/solver.js` (computeMinFoldAngleVBeamOverlap).
##
## All math is closed-form trigonometry in the 2D joint plane (inches).
## The "compound" ring is N modules chained bl<->br with a cumulative
## relative rotation per module; the deployed (closed) angle is where
## N * relativeRotation == 2*PI (found by a 1-degree then 0.1-degree scan,
## exactly like the web app so results match to the same tolerance).

const INCHES_PER_FOOT := 12.0
const MIN_FOLD_ANGLE := 5.0 * PI / 180.0
const MAX_FOLD_ANGLE := 175.0 * PI / 180.0
const MIN_SAFE_DIMENSION := 1.0


## Port of calculateJointPositions(foldAngle, params).
## Returns {"joints": {"bl","br","tl","tr": Vector2}, "relative_rotation",
## "active_length", "passive_length"}.
static func calculate_joint_positions(fold_angle: float, h_active_in: float, pivot_pct: float, hoberman_ang: float, pivot_ang: float) -> Dictionary:
	var safe_h := maxf(MIN_SAFE_DIMENSION, h_active_in)
	var pivot_ratio := pivot_pct / 100.0
	var active_length := safe_h * pivot_ratio
	var passive_length := safe_h * (1.0 - pivot_ratio)
	var half_angle := fold_angle / 2.0
	var hoberman_rad := deg_to_rad(hoberman_ang)
	var pivot_offset_rad := deg_to_rad(pivot_ang)

	var angle1_bottom := PI - half_angle
	var angle1_top := -half_angle + hoberman_rad
	var angle2_bottom := PI + half_angle + pivot_offset_rad
	var angle2_top := half_angle - hoberman_rad + pivot_offset_rad

	# Scalar math stays in GDScript 64-bit floats before packing into Vector2
	# (32-bit) so relative_rotation keeps double precision — the ring-closure
	# scan and module chaining depend on it matching the JS reference.
	var bl_x := active_length * cos(angle1_bottom)
	var bl_y := active_length * sin(angle1_bottom)
	var tr_x := passive_length * cos(angle1_top)
	var tr_y := passive_length * sin(angle1_top)
	var br_x := active_length * cos(angle2_bottom)
	var br_y := active_length * sin(angle2_bottom)
	var tl_x := passive_length * cos(angle2_top)
	var tl_y := passive_length * sin(angle2_top)

	var source_angle := atan2(tl_y - bl_y, tl_x - bl_x)
	var target_angle := atan2(tr_y - br_y, tr_x - br_x)
	var relative_rotation := target_angle - source_angle

	return {
		"joints": {
			"bl": Vector2(bl_x, bl_y), "br": Vector2(br_x, br_y),
			"tl": Vector2(tl_x, tl_y), "tr": Vector2(tr_x, tr_y),
		},
		"relative_rotation": relative_rotation,
		"active_length": active_length,
		"passive_length": passive_length,
	}


static func joint_positions_for(p: LinkageParams, fold_angle: float) -> Dictionary:
	return calculate_joint_positions(fold_angle, p.h_active_in(), p.pivot_pct, p.hoberman_ang, p.pivot_ang)


## Port of getOptimalClosedAngleForAnimation: fold angle where the ring
## closes (N modules complete 360 degrees). Coarse 1-degree scan with the
## same early-out, then a fine 0.1-degree scan in a +/-2 degree window.
## Callers should cache the result (keyed on modules/pivot/hoberman/pivot_ang
## + h geometry) like the web app does.
static func optimal_closed_angle(p: LinkageParams) -> float:
	var target_rotation := TAU
	var total_modules := p.modules
	var h_active := p.h_active_in()

	var step_size := deg_to_rad(1.0)
	var best_angle := MAX_FOLD_ANGLE
	var best_diff := INF

	var angle := MIN_FOLD_ANGLE
	while angle <= MAX_FOLD_ANGLE:
		var rotation := _total_rotation(angle, h_active, p, total_modules)
		var diff := absf(rotation - target_rotation)
		if diff < best_diff:
			best_diff = diff
			best_angle = angle
		if rotation > target_rotation and diff > best_diff:
			break
		angle += step_size

	var fine_step := deg_to_rad(0.1)
	angle = best_angle - deg_to_rad(2.0)
	var fine_end := best_angle + deg_to_rad(2.0)
	while angle <= fine_end:
		if angle >= MIN_FOLD_ANGLE and angle <= MAX_FOLD_ANGLE:
			var rotation2 := _total_rotation(angle, h_active, p, total_modules)
			var diff2 := absf(rotation2 - target_rotation)
			if diff2 < best_diff:
				best_diff = diff2
				best_angle = angle
		angle += fine_step

	return best_angle


static func _total_rotation(fold_angle: float, h_active: float, p: LinkageParams, total_modules: int) -> float:
	var jr := calculate_joint_positions(fold_angle, h_active, p.pivot_pct, p.hoberman_ang, p.pivot_ang)
	return absf(float(jr["relative_rotation"]) * total_modules)


## Port of computeMinFoldAngleVBeamOverlap: binary search for the fold angle
## where adjacent modules' outer V-beam tips are separated by exactly one
## outer V-beam width — the physical "can't fold further" limit.
static func min_fold_angle_v_overlap(p: LinkageParams) -> float:
	var total_modules := p.modules
	if total_modules < 2:
		return MIN_FOLD_ANGLE

	var h_active := p.h_active_in()
	var outer_w: float = maxf(
		p.v_beam_outer_w if p.v_beam_outer_w > 0.0 else p.v_beam_w,
		p.v_beam_outer_t if p.v_beam_outer_t > 0.0 else p.v_beam_t)

	var lo := MIN_FOLD_ANGLE
	var hi := optimal_closed_angle(p)
	var gap_at_hi := _min_adjacent_gap(hi, h_active, p, total_modules)
	if gap_at_hi <= outer_w:
		return hi
	var gap_at_lo := _min_adjacent_gap(lo, h_active, p, total_modules)
	if gap_at_lo >= outer_w:
		return lo

	for _iter in range(40):
		var mid := (lo + hi) / 2.0
		if _min_adjacent_gap(mid, h_active, p, total_modules) < outer_w:
			lo = mid
		else:
			hi = mid
		if hi - lo < deg_to_rad(0.05):
			break
	return (lo + hi) / 2.0


static func _min_adjacent_gap(fold_angle: float, h_active: float, p: LinkageParams, total_modules: int) -> float:
	var jr := calculate_joint_positions(fold_angle, h_active, p.pivot_pct, p.hoberman_ang, p.pivot_ang)
	var joints: Dictionary = jr["joints"]
	var tr: Vector2 = joints["tr"]
	var bl: Vector2 = joints["bl"]
	var br: Vector2 = joints["br"]
	var rel: float = jr["relative_rotation"]

	var pts: Array[Vector2] = []
	var cur_rot := 0.0
	var cur_pos := Vector2.ZERO
	for i in range(total_modules):
		pts.append(cur_pos + tr.rotated(cur_rot))
		var next_rot := cur_rot + rel
		var next_bl := bl.rotated(next_rot)
		var cur_br := br.rotated(cur_rot)
		cur_pos = cur_pos + cur_br - next_bl
		cur_rot = next_rot

	var min_gap := INF
	for i in range(pts.size()):
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		var d := a.distance_to(b)
		if d < min_gap:
			min_gap = d
	return min_gap


## Effective minimum fold angle: user override (degrees) if set, otherwise
## the computed V-beam contact angle. Port of getEffectiveMinFoldAngle.
static func effective_min_fold_angle(p: LinkageParams) -> float:
	if p.min_fold_angle_deg >= 0.0:
		return deg_to_rad(p.min_fold_angle_deg)
	return min_fold_angle_v_overlap(p)


## Radial span between inner (br) and outer (tr) pivots — actuator travel.
## Port of calculatePivotSpan.
static func pivot_span(p: LinkageParams, fold_angle: float) -> float:
	var jr := joint_positions_for(p, fold_angle)
	var joints: Dictionary = jr["joints"]
	return (joints["tr"] as Vector2).distance_to(joints["br"] as Vector2)

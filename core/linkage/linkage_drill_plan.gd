class_name LinkageDrillPlan
extends RefCounted
## Hole patterns for a representative beam of each type — the drill templates
## a builder tapes to a board before cutting.
##
## Positions are inches measured from the beam's `p1` end. Every beam of a
## given type shares one pattern because the ring is rotationally symmetric, so
## the guide prints one template per type rather than one per beam.
##
## Port of `js/linkage/build-guide.js:computeReciprocalDrillData` (:10) and the
## template rows in `showBuildGuide` (:830-960).
##
## [b]The reciprocal patterns are derived analytically, not from bolt geometry.[/b]
## The web app emits `rcp-ring` / `rcp-cross` bolts and then immediately
## projects each bolt centre back onto a representative beam to recover a
## scalar `t x length` — the bolts are a pass-through. This port already holds
## both ends of that projection (`LinkageGeometry.support_beams` gives every
## reciprocal beam with `p1` at the anchor end), so it skips the round trip.
## That also keeps `LinkageSolver`'s bolt array — which is pinned at 88 for the
## stock design and feeds `get_stats`, `packed_spec_for` and the crew plan —
## exactly where it is. If the kinematic RCP continuation solver is ever
## ported, only this file changes.

## Tolerances from the JS: anchor positions within a quarter inch are the same
## hole; crossings are coarser because two beams meet over a finite width.
const ANCHOR_DEDUPE_IN := 0.25
const CROSS_DEDUPE_IN := 1.2
## Reject a projection that clamps to a segment end — that hole belongs to the
## neighbouring beam, not this one.
const END_CLAMP_EPS := 0.001


## Drill patterns for `p`, solved at the deployed angle (holes are drilled once
## and do not move with the fold).
static func compute(p: LinkageParams) -> Dictionary:
	var closed := LinkageKinematics.optimal_closed_angle(p)
	var frame := LinkageSolver.solve(p, closed)
	var out := {
		"has_reciprocal": false,
		"h_beam": _h_beam_pattern(p),
		"v_beam": _v_beam_pattern(p),
	}
	if p.orientation == "vertical":
		return out

	var supports := LinkageGeometry.support_beams(frame, p, closed)
	var rcp: Array = []
	for beam in supports:
		if str((beam as Dictionary).get("stack_type", "")) == "support-beam-reciprocal":
			rcp.append(beam)
	var tops := _beams_of_type(frame, "horizontal-top")
	if rcp.is_empty() or tops.is_empty():
		return out
	out["has_reciprocal"] = true

	# --- R#: where each reciprocal anchor lands on the top ring H-beam -------
	var rep_top: Dictionary = tops[0]
	var top_p1: Vector3 = rep_top["p1"]
	var top_p2: Vector3 = rep_top["p2"]
	var top_len := top_p1.distance_to(top_p2)
	var anchors: Array[float] = []
	var end_offset := float(p.support_beams["rcp_end_offset"])
	for beam in rcp:
		var hit := _closest_point_on_segment(_anchor_point(beam, end_offset), top_p1, top_p2)
		var t := float(hit["t"])
		if t <= END_CLAMP_EPS or t >= 1.0 - END_CLAMP_EPS:
			continue
		anchors.append(t * top_len)
	var anchor_holes := _label_holes(_dedupe(anchors, ANCHOR_DEDUPE_IN), "R", "rcp_anchor")
	if not anchor_holes.is_empty():
		var top_pattern := _h_beam_pattern(p)
		var merged: Array = (top_pattern["holes"] as Array).duplicate()
		merged.append_array(anchor_holes)
		merged.sort_custom(func(a, b): return float(a["pos_in"]) < float(b["pos_in"]))
		top_pattern["holes"] = merged
		top_pattern["label"] = "Top Ring H-Beam"
		out["h_beam_top"] = top_pattern
		(out["h_beam"] as Dictionary)["label"] = "Bottom Ring H-Beam"

	# --- X#: where reciprocal beams cross each other ------------------------
	var rep: Dictionary = rcp[0]
	var rp1: Vector3 = rep["p1"]
	var rp2: Vector3 = rep["p2"]
	var rcp_len := rp1.distance_to(rp2)
	var crossings: Array[float] = []
	for other in rcp:
		if other == rep:
			continue
		var isect := LinkageGeometry.seg_seg_intersect_xz(
			rp1, rp2, (other as Dictionary)["p1"], (other as Dictionary)["p2"])
		if isect.is_empty():
			continue
		var t2 := float(isect["t"])
		var s := float(isect["s"])
		if t2 <= END_CLAMP_EPS or t2 >= 1.0 - END_CLAMP_EPS:
			continue
		if s <= END_CLAMP_EPS or s >= 1.0 - END_CLAMP_EPS:
			continue
		crossings.append(t2 * rcp_len)
	var holes: Array = [{
		"name": "ANCH",
		"pos_in": clampf(end_offset, 0.0, rcp_len),
		"kind": "rcp_anchor",
	}]
	holes.append_array(_label_holes(_dedupe(crossings, CROSS_DEDUPE_IN), "X", "rcp_cross"))
	out["rcp_beam"] = {
		"label": "Reciprocal Beam",
		"length_in": rcp_len,
		"length_ft": rcp_len / LinkageBom.INCHES_PER_FOOT,
		"holes": holes,
	}
	return out


## Horizontal beam: end bracket holes at the offsets plus the centre pivot.
static func _h_beam_pattern(p: LinkageParams) -> Dictionary:
	var total := p.h_length_ft * LinkageBom.INCHES_PER_FOOT
	var pivot := p.offset_bot_in + p.h_active_in() * p.pivot_pct / 100.0
	return {
		"label": "Horizontal Beam",
		"length_in": total,
		"length_ft": p.h_length_ft,
		"hole_diameter_in": p.bolt_diameter,
		"holes": [
			{"name": "BOT", "pos_in": p.offset_bot_in, "kind": "end"},
			{"name": "CTR", "pos_in": pivot, "kind": "pivot"},
			{"name": "TOP", "pos_in": total - p.offset_top_in, "kind": "end"},
		],
	}


## Vertical beam: both end pivots plus the mid-span scissor pivot.
static func _v_beam_pattern(p: LinkageParams) -> Dictionary:
	var total := p.v_length_ft * LinkageBom.INCHES_PER_FOOT
	var bottom := p.vert_end_offset
	var top := total - p.vert_end_offset
	return {
		"label": "Vertical Beam",
		"length_in": total,
		"length_ft": p.v_length_ft,
		"hole_diameter_in": p.bolt_diameter,
		"holes": [
			{"name": "BOT", "pos_in": bottom, "kind": "end"},
			{"name": "CTR", "pos_in": (bottom + top) / 2.0, "kind": "pivot"},
			{"name": "TOP", "pos_in": top, "kind": "end"},
		],
	}


## The reciprocal beam's anchor point: `p1` is the beam's outer end, offset
## back from the anchor by `rcp_end_offset` (LinkageGeometry:315).
static func _anchor_point(beam: Dictionary, end_offset: float) -> Vector3:
	var p1: Vector3 = beam["p1"]
	var p2: Vector3 = beam["p2"]
	var dir := p2 - p1
	if dir.length() < 1e-9:
		return p1
	return p1 + dir.normalized() * end_offset


static func _beams_of_type(frame: Dictionary, stack_type: String) -> Array:
	var out: Array = []
	for beam in frame.get("beams", []):
		if str((beam as Dictionary).get("stack_type", "")) == stack_type:
			out.append(beam)
	return out


static func _closest_point_on_segment(pt: Vector3, a: Vector3, b: Vector3) -> Dictionary:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 1e-12:
		return {"point": a, "t": 0.0}
	var t := clampf((pt - a).dot(ab) / len_sq, 0.0, 1.0)
	return {"point": a + ab * t, "t": t}


## Collapse positions that land within `tol` of each other into one hole.
static func _dedupe(positions: Array[float], tol: float) -> Array[float]:
	var sorted := positions.duplicate()
	sorted.sort()
	var out: Array[float] = []
	for pos in sorted:
		if out.is_empty() or absf(pos - out[out.size() - 1]) > tol:
			out.append(pos)
	return out


static func _label_holes(positions: Array[float], prefix: String, kind: String) -> Array:
	var out: Array = []
	for i in positions.size():
		out.append({
			"name": "%s%d" % [prefix, i + 1],
			"pos_in": positions[i],
			"kind": kind,
		})
	return out

class_name LinkageBeamHoles
extends RefCounted
## Where the bolts pass through each beam — port of LinkageLab's
## `getBeamBoltIntersections` (renderer-3d.js:337) plus the drill-solve the
## build-step generator runs it against (build-steps-ui.js
## buildGenerationInput). LINKAGE_PARITY.md A2; pinned per beam against
## `core/linkage/testdata/parity/*.json` `holes`.
##
## A hole is beam-local, in inches: {pos_l (along the beam, 0 = its centre),
## pos_w, pos_t (across), radius, through: "W" | "T"} — "W" = the bolt runs
## across the beam's width, "T" across its thickness. Beam axes follow the
## solver: axis_z = length, axis_x = width, axis_y = thickness.

## Slack so a bolt that just touches a beam face still drills cleanly.
const TOL := 0.05


## Holes the given bolts make in one beam.
static func intersections(beam: Dictionary, bolts: Array) -> Array:
	var out: Array = []
	if not beam.has("p1") or not beam.has("axis_z") or bolts.is_empty():
		return out
	var axis_l: Vector3 = beam["axis_z"]
	var axis_w: Vector3 = beam["axis_x"]
	var axis_t: Vector3 = beam["axis_y"]
	var beam_len := ((beam["p2"] as Vector3) - (beam["p1"] as Vector3)).length()
	if beam_len < 1e-4:
		return out
	var half_l := beam_len / 2.0
	var half_w := (float(beam.get("w", 1.0)) if float(beam.get("w", 0.0)) != 0.0 else 1.0) / 2.0
	var half_t := (float(beam.get("t", 1.0)) if float(beam.get("t", 0.0)) != 0.0 else 1.0) / 2.0
	var center: Vector3 = beam["center"]
	for bolt in bolts:
		var b: Dictionary = bolt
		if not (b.get("center") is Vector3) or not (b.get("dir") is Vector3):
			continue
		var r := maxf(float(b.get("radius", 0.0)), 0.05)
		var rel: Vector3 = (b["center"] as Vector3) - center
		var proj_l := rel.dot(axis_l)
		var proj_w := rel.dot(axis_w)
		var proj_t := rel.dot(axis_t)
		var dir: Vector3 = b["dir"]
		var dot_l := absf(dir.dot(axis_l))
		var dot_w := absf(dir.dot(axis_w))
		var dot_t := absf(dir.dot(axis_t))
		var through := "L"
		if dot_w >= dot_t and dot_w >= dot_l:
			through = "W"
		elif dot_t >= dot_l:
			through = "T"
		if through == "L":
			continue
		if proj_l < -half_l - TOL or proj_l > half_l + TOL:
			continue
		var half_bolt := float(b.get("length", 0.0)) / 2.0
		if through == "W":
			if proj_t < -half_t - TOL or proj_t > half_t + TOL:
				continue
			if absf(proj_w) - half_bolt > half_w + TOL:
				continue
		else:
			if proj_w < -half_w - TOL or proj_w > half_w + TOL:
				continue
			if absf(proj_t) - half_bolt > half_t + TOL:
				continue
		out.append({"pos_l": proj_l, "pos_w": proj_w, "pos_t": proj_t, "radius": r, "through": through})
	return out


## The bolt set the web generator drills against: a solve at `fold` with
## legacy bolts on and hardware detail OFF (Full Detail swaps pivot bolts for
## placements, which have no hole), plus the reciprocal support bolts.
## Returns {bolts, beams} — the beams of that same solve (incl. support).
static func drill_solve(p: LinkageParams, fold: float) -> Dictionary:
	var q := p.duplicate_params()
	q.show_bolts = true
	q.show_hardware_full_detail = false
	var frame := LinkageSolver.solve(q, fold)
	var beams: Array = (frame["beams"] as Array).duplicate()
	beams.append_array(LinkageGeometry.support_beams(frame, q, fold))
	var bolts: Array = (frame["bolts"] as Array).duplicate()
	bolts.append_array(LinkageGeometry.reciprocal_support_bolts(beams, q, fold))
	# A radial array drills every copy against its own bolts (holes are
	# beam-local, so each copy's pattern is the base one).
	var pl := LinkageRadialArray.deployed_plan(p)
	if not pl.is_empty():
		var g: Dictionary = LinkageRadialArray.apply(pl, {"beams": beams, "bolts": bolts})["geo"]
		beams = g["beams"]
		bolts = g["bolts"]
	return {"bolts": bolts, "beams": beams}

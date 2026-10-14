class_name NpcLimbIk
extends RefCounted
## Analytic two-bone IK for the stick figure's limbs (NpcSimpleFigure): an arm
## (shoulder -> elbow -> wrist) or a leg (hip -> knee -> ankle). Pure — the
## figure feeds it positions in the ROOT JOINT'S PARENT space and writes the
## two rotations back. The fabrication swarm uses it to put a figure's hands
## on a tool's grips while the tool follows its op's path (LinkageBuildOps).
##
## The figure's conventions, which this matches exactly:
##   - every limb segment hangs along the joint's local -Y;
##   - the middle joint is a HINGE about its local X;
##   - an ELBOW bends the forearm toward the upper arm's local +Z (a negative
##     X rotation — `bend_sign` -1), a KNEE bends the shin toward local -Z
##     (positive — `bend_sign` +1).
## The pole says which way the middle joint points (elbows out and back,
## knees forward).

const EPS := 1e-4


## Solve one limb.
##   root     the root joint's position (parent space)
##   target   where the END (wrist / ankle) should be (parent space)
##   pole     a point (parent space) the middle joint should bend toward
##   l1, l2   segment lengths
##   bend_sign  -1 elbow, +1 knee
## Returns {root_basis: Basis (the root joint's rotation), mid_angle: float
## (the middle joint's X rotation), mid_pos, end_pos: Vector3 (parent space,
## where they actually land), reached: bool (false = clamped to reach)}.
static func solve(root: Vector3, target: Vector3, pole: Vector3, l1: float, l2: float, bend_sign: float) -> Dictionary:
	var d := target - root
	var dist := d.length()
	var reached := true
	var lo := absf(l1 - l2) + EPS
	var hi := l1 + l2 - EPS
	if dist > hi:
		reached = dist <= l1 + l2 + 1e-6
		dist = hi
	elif dist < lo:
		reached = false
		dist = lo
	var dir := d.normalized() if d.length() > EPS else Vector3(0, -1, 0)
	# Pole direction, perpendicular to the reach line.
	var p := pole - root
	p -= dir * p.dot(dir)
	if p.length() < EPS:
		# A pole on the reach line says nothing: pick any perpendicular.
		p = dir.cross(Vector3(1, 0, 0))
		if p.length() < EPS:
			p = dir.cross(Vector3(0, 0, 1))
	p = p.normalized()
	# Law of cosines: angle at the root between the reach line and segment 1,
	# and the hinge's interior angle.
	var cos_a := clampf((l1 * l1 + dist * dist - l2 * l2) / (2.0 * l1 * dist), -1.0, 1.0)
	var cos_m := clampf((l1 * l1 + l2 * l2 - dist * dist) / (2.0 * l1 * l2), -1.0, 1.0)
	var a := acos(cos_a)
	var bend := PI - acos(cos_m)        # 0 = straight
	var mid := root + (dir * cos(a) + p * sin(a)) * l1
	var end := root + dir * dist
	var u := (mid - root).normalized()  # segment 1 direction
	var f := (end - mid).normalized()   # segment 2 direction
	# The root's frame: local -Y along segment 1; local Z on the side segment 2
	# bends toward (+Z for an elbow, -Z for a knee); X completes it.
	var side := f - u * f.dot(u)
	if side.length() < EPS:
		side = -p
	side = side.normalized()
	var y := -u
	var z := side * (-bend_sign)
	var x := y.cross(z).normalized()
	z = x.cross(y).normalized()
	return {"root_basis": Basis(x, y, z), "mid_angle": bend_sign * bend,
		"mid_pos": mid, "end_pos": end, "reached": reached}


## Forward kinematics for checking: where the middle joint and the end land
## for a root rotation + hinge angle (parent space).
static func forward(root: Vector3, root_basis: Basis, mid_angle: float, l1: float, l2: float) -> Dictionary:
	var mid := root + root_basis * Vector3(0, -l1, 0)
	var mid_basis := root_basis * Basis(Vector3(1, 0, 0), mid_angle)
	var end := mid + mid_basis * Vector3(0, -l2, 0)
	return {"mid_pos": mid, "end_pos": end, "mid_basis": mid_basis}


## The hand's rotation in the forearm's frame that makes the hand's world
## basis equal `want` (world), given the forearm's world basis.
static func hand_local(forearm_world: Basis, want: Basis) -> Basis:
	return (forearm_world.orthonormalized().inverse() * want.orthonormalized()).orthonormalized()

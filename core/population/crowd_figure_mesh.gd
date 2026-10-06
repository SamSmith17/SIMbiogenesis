class_name CrowdFigureMesh
extends RefCounted

## The ONE mesh every light-tier person is drawn with: a low-poly stick body
## (torso, head, two arms, two legs as six-sided capsules, ~220 vertices)
## whose UV2 tags each vertex with its body PART and its fraction along the
## limb, so `crowd_figure.gdshader` can swing the limbs about their joints in
## the vertex stage — a walk, a sit, a lie, a dance — with no skeleton and no
## per-person CPU work. Origin at the feet, facing +Z, 1.7 m tall.
##
## Parts (UV2.x × 5): 0 torso, 1 head, 2 left arm, 3 right arm, 4 left leg,
## 5 right leg. UV2.y: 0 at the joint, 1 at the tip (limbs only). The shader
## carries the joint pivots as constants (PIVOT_*), so they must match here.

const SHOULDER_Y := 1.42
const SHOULDER_X := 0.22
const HIP_Y := 0.86
const HIP_X := 0.10
const ARM_LEN := 0.62
const LEG_LEN := 0.86
const RADIAL := 6

static var _cached: ArrayMesh = null


static func mesh() -> ArrayMesh:
	if _cached == null:
		_cached = build()
	return _cached


static func build() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Torso: a capsule from the hips to the shoulders.
	_capsule(st, Vector3(0.0, (HIP_Y + SHOULDER_Y) * 0.5, 0.0), 0.17, (SHOULDER_Y - HIP_Y) * 0.5 - 0.05, 0, false)
	# Head.
	_capsule(st, Vector3(0.0, 1.58, 0.0), 0.115, 0.03, 1, false)
	# Arms hang from the shoulders, legs from the hips: the capsule's local
	# "top" is the joint (fraction 0) and the tip is fraction 1.
	_limb(st, Vector3(-SHOULDER_X, SHOULDER_Y, 0.0), 0.055, ARM_LEN, 2)
	_limb(st, Vector3(SHOULDER_X, SHOULDER_Y, 0.0), 0.055, ARM_LEN, 3)
	_limb(st, Vector3(-HIP_X, HIP_Y, 0.0), 0.08, LEG_LEN, 4)
	_limb(st, Vector3(HIP_X, HIP_Y, 0.0), 0.08, LEG_LEN, 5)
	st.index()
	var mesh := st.commit()
	# The shader moves limbs and lays bodies down; the AABB must cover a
	# lying figure (±1.0 m in every direction is generous and cheap).
	mesh.custom_aabb = AABB(Vector3(-1.0, -0.2, -1.0), Vector3(2.0, 2.2, 2.0))
	return mesh


## A limb capsule hanging DOWN from `joint` by `length`; UV2.y runs 0 → 1
## from the joint to the tip.
static func _limb(st: SurfaceTool, joint: Vector3, radius: float, length: float, part: int) -> void:
	var half := (length - 2.0 * radius) * 0.5
	_capsule(st, joint - Vector3(0.0, radius + half, 0.0), radius, half, part, true, joint, length)


## Rings along local Y: tip, cap-mid, cap-base, cap-base, cap-mid, tip.
static func _capsule(st: SurfaceTool, centre: Vector3, radius: float, half: float,
		part: int, limb: bool, joint: Vector3 = Vector3.ZERO, length: float = 1.0) -> void:
	var ring_y: Array = [half + radius, half + radius * 0.6, half, -half, -half - radius * 0.6, -half - radius]
	var ring_r: Array = [0.0, radius * 0.8, radius, radius, radius * 0.8, 0.0]
	var ring_ny: Array = [1.0, 0.6, 0.0, 0.0, -0.6, -1.0]
	var rings: Array = []
	for k in ring_y.size():
		var ring: Array = []
		for i in RADIAL:
			var a := TAU * float(i) / float(RADIAL)
			var dir := Vector3(cos(a), 0.0, sin(a))
			var p: Vector3 = centre + Vector3(0.0, float(ring_y[k]), 0.0) + dir * float(ring_r[k])
			var n: Vector3 = (dir * (1.0 - absf(float(ring_ny[k]))) + Vector3(0.0, float(ring_ny[k]), 0.0)).normalized()
			var frac := 0.0
			if limb:
				frac = clampf((joint.y - p.y) / maxf(length, 0.001), 0.0, 1.0)
			ring.append([p, n, frac])
		rings.append(ring)
	var uv2x := float(part) / 5.0
	for k in rings.size() - 1:
		var r0: Array = rings[k]
		var r1: Array = rings[k + 1]
		for i in RADIAL:
			var j := (i + 1) % RADIAL
			# Two triangles, wound so the outside faces OUT (Godot front faces
			# are clockwise from outside).
			_tri(st, r0[i], r1[i], r0[j], uv2x)
			_tri(st, r0[j], r1[i], r1[j], uv2x)


static func _tri(st: SurfaceTool, a: Array, b: Array, c: Array, uv2x: float) -> void:
	for v in [a, b, c]:
		st.set_normal(v[1])
		st.set_uv2(Vector2(uv2x, float(v[2])))
		st.add_vertex(v[0])

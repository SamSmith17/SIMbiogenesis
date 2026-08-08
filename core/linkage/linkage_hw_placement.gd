class_name LinkageHwPlacement
extends RefCounted
## Where each hardware assembly sits on the SOLVED structure.
##
## The hardware editor shows a joint stamped onto the real frame at every pivot
## that uses it — the web app's part-detail view. This class is the bridge: it
## turns the solver's bracket and centre-bolt arrays into one transform per
## joint.
##
## Port of `hwAddAssemblyPlacement` (hardware-detail.js:1801) +
## `hwComputeAssemblyTransform` (:2079) + the solver's placement pushes
## (solver.js:1987 outer/inner at every bracket, :2013 vCenter at the V-stack
## crossing, :2221-2222 hCenter at BOTH ring crossings). The web solver pushes
## these as it builds; the Godot solver already records everything needed —
## brackets carry `v_bolt_pivot` + `pivot_role`, and the centre bolts mark the
## crossings — so this derives them afterwards instead. Same joints, and
## `LinkageSolver`'s own output is untouched, which matters because it is pinned.
##
## [b]The placement frame is not the bracket frame.[/b] `bracket["basis"]` is the
## SIMPLE bracket's orientation, unflipped, anchored on the H-ring pivot. A
## placement is flipped per joint (`flip_stack_axis`) and anchored on the V-stack
## pivot. Keeping them as two objects is what lets the detailed hardware be
## corrected without moving one pinned solver value.
##
## [b]Feed this a frame solved with `show_brackets` AND `show_bolts` on[/b] —
## the centre placements read the bolt array, which is only emitted when bolts
## are shown. The caller renders the DISPLAY structure from a separate
## flags-off solve (the web hides legacy hardware the same way:
## `hideLegacyHardware`, scene-render.js:63).

const ASSEMBLY_FOR_ROLE := {
	"outer": "outerVBeam",
	"inner": "innerVBeam",
}


## Mirror the bolt and beam axes so an asymmetric stack sits on the correct side
## of the crossed V-beams — port of the `flipStackAxis` rule at solver.js:2781.
##
## The two outer V-beams cross (Pattern A vs B), so consecutive joints ride
## OPPOSITE radial lines and half of them need the mirror. Note the innerVBeam
## branch collapses to a constant in practice: inner placements always carry
## role "inner", so the rule reduces to `not stack_reversed` and bottom and top
## flip together — that asymmetry against the outer rule is the point.
static func flip_stack_axis(assembly_id: String, pivot_role: String,
		is_bottom: bool, stack_reversed: bool) -> bool:
	if pivot_role == "center":
		return false
	if assembly_id == "innerVBeam":
		return (pivot_role == "inner") != stack_reversed
	return is_bottom != stack_reversed


## Every placement on `frame`, as `{assembly_id, role, module_index, is_bottom,
## transform}`. Transforms are in the solver's INCH space, same as the frame.
static func placements(p: LinkageParams, frame: Dictionary) -> Array:
	var out: Array = []
	var ha: Dictionary = p.hardware_assemblies
	var is_arch := str(frame.get("orientation", "")) == "vertical"

	# Outer / inner V-beam joints: one per bracket. The bracket carries its own
	# role — decoding it from the array index would silently re-label every
	# joint the first time the emission order changes.
	var brackets: Array = frame.get("brackets", [])
	for i in brackets.size():
		var br := brackets[i] as Dictionary
		var role := str(br.get("pivot_role", "outer"))
		var asm_id := str(ASSEMBLY_FOR_ROLE.get(role, "outerVBeam"))
		var asm := LinkageHardware.assembly(ha, asm_id)
		if asm.is_empty() or not bool(asm.get("detailed", true)):
			continue
		var is_bottom := bool(br.get("is_bottom", false))
		var flip := flip_stack_axis(asm_id, role, is_bottom, p.v_stack_reverse)
		out.append({
			"assembly_id": asm_id,
			"role": role,
			"module_index": int(br.get("module_index", -1)),
			"is_bottom": is_bottom,
			"flip_stack_axis": flip,
			"transform": transform_for(asm, br,
				LinkageSolver.bracket_basis_for(br, is_arch, flip)),
		})

	# Centre assemblies sit on the crossing bolts. The web pushes hCenter at
	# BOTH ring crossings and vCenter at the V-stack middle; the corresponding
	# bolts in this solver are the "center" sub-type of each family.
	# A centre assembly with no parts gets no seat. In detail mode the web still
	# pushes a placement for it and then renders nothing there
	# (`buildHardwareAssemblyGroup` bails on an empty parts list,
	# scene-render.js:163) — same outcome, one fewer empty seat to carry.
	var h_center := LinkageHardware.assembly(ha, "hCenter") \
		if LinkageHardware.assembly_has_parts(ha, "hCenter") else {}
	var v_center := LinkageHardware.assembly(ha, "vCenter") \
		if LinkageHardware.assembly_has_parts(ha, "vCenter") else {}
	for bolt in frame.get("bolts", []):
		var b := bolt as Dictionary
		if str(b.get("bolt_sub_type", "")) != "center":
			continue
		match str(b.get("bolt_type", "")):
			"hstack":
				if not h_center.is_empty():
					out.append({
						"assembly_id": "hCenter",
						"role": "center",
						"module_index": int(b.get("module_index", -1)),
						"is_bottom": false,
						"flip_stack_axis": false,
						"transform": _h_center_transform(b),
					})
			"vstack":
				if not v_center.is_empty():
					out.append({
						"assembly_id": "vCenter",
						"role": "center",
						"module_index": int(b.get("module_index", -1)),
						"is_bottom": false,
						"flip_stack_axis": false,
						"transform": _v_center_transform(b),
					})
	return out


## Placements for one assembly id only.
static func placements_for(p: LinkageParams, frame: Dictionary,
		assembly_id: String) -> Array:
	var out: Array = []
	for entry in placements(p, frame):
		if str((entry as Dictionary)["assembly_id"]) == assembly_id:
			out.append((entry as Dictionary)["transform"])
	return out


## Seat an assembly so its BRACKET's side hole lands on the joint's V-STACK
## pivot — the corner the crossed uprights actually bolt through.
##
## [b]Not the bracket's own `pos`.[/b] That is the H-ring pivot, where the simple
## bracket mesh is drawn; the web anchors detailed assemblies on `vBoltPivot`
## instead (solver.js:1987 hands `spec.vBoltPivot` to `hwAddAssemblyPlacement`,
## and `hwComputeAssemblyTransform` :2091 prefers it). The two points are a
## bracket-hole-distance apart, which reads as hardware sitting in the right
## neighbourhood and the wrong relation to the beams.
##
## The assembly's local frame is x = bolt axis, y = up (the U opening),
## z = along the beam, which is exactly what `compute_bracket_basis` produces —
## so `basis` is passed in already flipped for this joint rather than re-derived.
##
## The bracket's `posX/posY/posZ` nudge is applied here AND again to the bracket
## mesh inside the assembly (`LinkageHwAssemblyBuilder._bracket_transform`).
## That double application is the web's own behaviour (hardware-detail.js:2085
## `applyLocalNudge` plus :2174) — do not "fix" it to a single site.
static func transform_for(asm: Dictionary, bracket: Dictionary,
		basis: Basis = Basis.IDENTITY) -> Transform3D:
	var pivot: Vector3 = bracket.get("v_bolt_pivot", bracket.get("pos", Vector3.ZERO))
	var part := LinkageHardware.bracket_part(asm)
	var origin := pivot
	if not part.is_empty():
		# The hole is `bracket_hole_y` above the assembly origin, so back the
		# origin off by that much along the rotated up axis.
		origin -= basis * Vector3(0.0, LinkageHwLayout.bracket_hole_y(part), 0.0)
		var pr: Dictionary = part.get("params", {})
		origin += basis * Vector3(float(pr.get("posX", 0.0)),
			float(pr.get("posY", 0.0)), float(pr.get("posZ", 0.0)))
	return Transform3D(basis, origin)


## H-centre linkage: anchored ON the crossing bolt, stack running along the
## bolt, local +X pointing radially outward from the structure axis.
##
## In CYLINDER mode this is `computeHwHCenterBasis` exactly (solver.js:1011:
## `{x: radialDir, y: UP, z: x × y}`) — the bolt is vertical, so `y` is world up
## and `x` is the radial. Yawing that frame 90° (putting the tangent on +X)
## still yields a valid right-handed basis, so it renders without complaint
## while sending every `crossOffset` sideways instead of outward and pointing
## any right/left part the wrong way. That was the original port's bug.
##
## In ARCH mode this deliberately diverges from the web, which hardcodes
## `y = world up` on the claim that "the H-ring center bolt is vertical and
## never tilts" (solver.js:2790). After the arch's 90° X-rotation that bolt is
## HORIZONTAL, so the claim no longer holds: the web ends up projecting an
## out-of-plane radial onto the ground, which collapses to ±X for every joint
## and gives the whole arch one identical hardware yaw. Taking `y` from the
## bolt's own direction — which the arch transform already rotated correctly —
## costs nothing in cylinder mode (the bolt is exactly up there) and is right in
## both. Arch H-centre bases are therefore not pinned against the JS.
static func _h_center_transform(bolt: Dictionary) -> Transform3D:
	var pos: Vector3 = bolt.get("center", Vector3.ZERO)
	var y: Vector3 = bolt.get("dir", Vector3.UP)
	if y.length() < 1e-5:
		y = Vector3.UP
	y = y.normalized()
	# Yaw reference: outward from the structure's own axis. Perpendicularized
	# against the stack axis, so it stays a valid column when the bolt is tilted.
	var x := Vector3(pos.x, 0.0, pos.z)
	x -= y * x.dot(y)
	if x.length() < 0.1:
		# On the axis (module 0 sits at the construction origin) or parallel to
		# the bolt: any perpendicular will do, so pick one deterministically.
		x = Vector3.RIGHT - y * Vector3.RIGHT.dot(y)
		if x.length() < 0.1:
			x = Vector3.BACK - y * Vector3.BACK.dot(y)
	x = x.normalized()
	return Transform3D(Basis(x, y, x.cross(y)), pos)


## V-centre assembly: anchored on the V-stack's centre bolt with the stack
## (local X — its sandwich plane is horizontal) running along the bolt's own
## axis (solver.js:2001-2013).
##
## Verified equivalent to `computeHwVCenterBasis` (solver.js:994): that builds
## `y` by orthogonalizing world up against `x` and takes `z = x × y`; deriving
## `z = x × UP` first and `y = z × x` gives the same three columns.
static func _v_center_transform(bolt: Dictionary) -> Transform3D:
	var pos: Vector3 = bolt.get("center", Vector3.ZERO)
	var x: Vector3 = (bolt.get("dir", Vector3.RIGHT) as Vector3)
	if x.length() < 1e-5:
		x = Vector3.RIGHT
	x = x.normalized()
	var z := x.cross(Vector3.UP)
	if z.length() < 1e-5:
		z = Vector3.BACK
	z = z.normalized()
	var y := z.cross(x).normalized()
	return Transform3D(Basis(x, y, z), pos)

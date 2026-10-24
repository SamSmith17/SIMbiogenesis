class_name LinkageHwParts
extends RefCounted
## Procedural meshes for hardware parts — bolts, bushings, washers, lock
## washers, nuts, beams and the U-bracket.
##
## Port of the `createHW*Mesh` family in `js/linkage/hardware-detail.js`
## (:1113-1560). Everything is built in INCHES spanning `[0, axial_length]`
## along +Y, matching `LinkageHwLayout.part_axial_length`, so the assembly
## builder can place a part by setting the start of its slot and never has to
## know what shape it is. Conversion to metres happens once, in the builder.
##
## [b]Winding.[/b] Godot front faces wind clockwise seen from outside. Every
## ring here is emitted through `_extrude_ring`, and the selftest asserts a
## known vertex's normal points AWAY from the axis — get it backwards and a
## washer renders as an unlit silhouette, which reads as a shader bug rather
## than a geometry one.

const BRACKET_GLB := "res://assets/linkage/unistrut_trolley_bracket.glb"
## Radians of opening in a split lock washer.
const LOCK_SPLIT_RAD := 0.32
const RING_SEGMENTS := 40
const SHAFT_SEGMENTS := 20

const COL_BOLT := Color(0.227, 0.239, 0.259)
const COL_STEEL := Color(0.541, 0.561, 0.588)
const COL_BRONZE := Color(0.663, 0.455, 0.184)
const COL_COPPER := Color(0.722, 0.451, 0.200)
const COL_ZINC := Color(0.624, 0.651, 0.678)
const COL_THREAD := Color(0.173, 0.184, 0.200)
const COL_WOOD := Color(0.545, 0.412, 0.078)

static var _glb_raw := PackedVector3Array()
static var _glb_tried := false
static var _materials: Dictionary = {}


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

## Mesh for a stack part, by type. Never returns null for a known type.
static func mesh_for(part: Dictionary) -> ArrayMesh:
	var pr: Dictionary = part.get("params", {})
	match str(part.get("type", "")):
		"bolt":
			return bolt_mesh(pr)
		"bushing":
			return bushing_mesh(pr)
		"washer":
			return washer_mesh(pr)
		"lockWasher":
			return lock_washer_mesh(pr)
		"nut":
			return nut_mesh(pr)
		"beam":
			return beam_mesh(pr)
		"bracket":
			return bracket_mesh(pr)
	return null


static func material_for(type: String) -> StandardMaterial3D:
	var kind := "steel"
	match type:
		"bolt":
			kind = "bolt"
		"washer":
			kind = "zinc"
		"nut":
			kind = "bronze"
		"beam":
			kind = "wood"
		"bracket":
			kind = "steel"
	return _material(kind)


static func _material(kind: String) -> StandardMaterial3D:
	if _materials.has(kind):
		return _materials[kind]
	var m := StandardMaterial3D.new()
	match kind:
		"bolt":
			m.albedo_color = COL_BOLT
		"bronze":
			m.albedo_color = COL_BRONZE
		"copper":
			m.albedo_color = COL_COPPER
		"zinc":
			m.albedo_color = COL_ZINC
		"thread":
			m.albedo_color = COL_THREAD
		"wood":
			m.albedo_color = COL_WOOD
		_:
			m.albedo_color = COL_STEEL
	if kind == "wood":
		m.metallic = 0.0
		m.roughness = 0.85
		# The member is CONTEXT, not the subject: ghost it (0.38, the web's
		# opacity) so the stack of hardware running through it stays readable.
		# DEPTH PRE-PASS, not plain alpha: without a depth pass every internal
		# face of the drilled mesh stacks up and the beam renders as a milky
		# mess of facets — the exact confusion the old no-depth-write version
		# shipped. Backface culling stays ON; the drilled slab is watertight.
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		m.albedo_color.a = 0.38
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	else:
		m.metallic = 0.75
		m.roughness = 0.4
	_materials[kind] = m
	return m


# ---------------------------------------------------------------------------
# Fasteners
# ---------------------------------------------------------------------------

## Head + shaft + thread band, spanning [0, head_height + length].
static func bolt_mesh(p: Dictionary) -> ArrayMesh:
	var length := maxf(0.1, _or(p, "length", 1.0))
	var r := maxf(0.02, _or(p, "diameter", 0.25) / 2.0)
	var thread_len := clampf(_or(p, "threadLength", 0.0), 0.0, length)
	var head_h := _bolt_head_height(p)
	var st := _begin()
	_add_bolt_head(st, p, 0.0)
	_add_cylinder(st, r, head_h, head_h + length, SHAFT_SEGMENTS)
	if thread_len > 0.0:
		# A slightly proud band standing in for the thread form — cheaper than
		# a helix and reads correctly at the scale this is ever viewed.
		_add_cylinder(st, r * 1.04, head_h + length - thread_len,
			head_h + length, SHAFT_SEGMENTS)
	return _commit(st)


static func _bolt_head_height(p: Dictionary) -> float:
	var h := _or(p, "headHeight", 0.0)
	if h > 0.0:
		return h
	return _or(p, "diameter", 0.25) * 0.6


static func _bolt_head_radius(p: Dictionary) -> float:
	var d := _or(p, "headDia", 0.0)
	if d > 0.0:
		return d / 2.0
	return _or(p, "diameter", 0.25) * 1.6 / 2.0


static func _add_bolt_head(st: SurfaceTool, p: Dictionary, top_y: float) -> void:
	var r := _bolt_head_radius(p)
	var h := _bolt_head_height(p)
	match str(p.get("headType", "hex")):
		"hex":
			_add_ring(st, _hex_points(r), PackedVector2Array(), top_y, top_y + h)
		"button":
			_add_cylinder(st, r, top_y, top_y + h * 0.5, 24)
			_add_dome(st, r, top_y + h * 0.5, h * 0.8, 24, 8)
		_:
			_add_cylinder(st, r, top_y, top_y + h, 24)


## Plain sleeve, plus a flange when one is authored proud of the body.
static func bushing_mesh(p: Dictionary) -> ArrayMesh:
	var length := maxf(0.05, _or(p, "length", 0.5))
	var id := _or(p, "id", 0.3)
	var od := _or(p, "od", 0.6)
	var st := _begin()
	_add_ring(st, _circle_points(od / 2.0, RING_SEGMENTS),
		_circle_points(_inner_r(id, od), RING_SEGMENTS), 0.0, length)
	var flange_od := _or(p, "flangeOd", 0.0)
	var flange_t := _or(p, "flangeThickness", 0.0)
	if flange_od > od and flange_t > 0.0:
		_add_ring(st, _circle_points(flange_od / 2.0, RING_SEGMENTS),
			_circle_points(_inner_r(id, flange_od), RING_SEGMENTS),
			length, length + flange_t)
	return _commit(st)


static func washer_mesh(p: Dictionary) -> ArrayMesh:
	var t := maxf(0.01, _or(p, "thickness", 0.0625))
	var id := _or(p, "id", 0.3)
	var od := _or(p, "od", 1.0)
	var st := _begin()
	_add_ring(st, _circle_points(od / 2.0, RING_SEGMENTS),
		_circle_points(_inner_r(id, od), RING_SEGMENTS), 0.0, t)
	return _commit(st)


## A split ring: the same annulus with a wedge removed, which is what makes a
## lock washer visually distinct from a plain one at a glance.
static func lock_washer_mesh(p: Dictionary) -> ArrayMesh:
	var t := maxf(0.02, _or(p, "thickness", 0.078))
	var id := _or(p, "id", 0.31)
	var od := _or(p, "od", 0.5)
	var outer_r := od / 2.0
	var inner_r := _inner_r(id, od)
	var seg := 36
	var start := LOCK_SPLIT_RAD / 2.0
	var arc := TAU - LOCK_SPLIT_RAD
	var st := _begin()
	_add_ring(st, _arc_points(outer_r, seg, start, arc),
		_arc_points(inner_r, seg, start, arc), 0.0, t, true)
	return _commit(st)


## Hex prism with a threaded bore — or a rivet-nut sleeve, which is a bushing
## with a flange and a copper look.
static func nut_mesh(p: Dictionary) -> ArrayMesh:
	if str(p.get("style", "")) == "rivet":
		return bushing_mesh({
			"id": _or(p, "id", 0.5),
			"od": _or(p, "od", 17.0 * LinkageHardware.MM_TO_IN),
			"length": _or(p, "length", _or(p, "height", 0.5)),
			"flangeOd": _or(p, "flangeOd", 18.0 * LinkageHardware.MM_TO_IN),
			"flangeThickness": _or(p, "flangeThickness", LinkageHardware.MM_TO_IN),
		})
	var h := maxf(0.05, _or(p, "height", 0.4375))
	var waf := _or(p, "widthAcrossFlats", 0.75)
	# Hex outer radius is measured across CORNERS, not flats.
	var r := waf / cos(PI / 6.0) / 2.0
	var inner_r := maxf(0.02, _or(p, "id", 0.4) / 2.0)
	var st := _begin()
	_add_ring(st, _hex_points(r), _circle_points(inner_r, RING_SEGMENTS), 0.0, h)
	return _commit(st)


# ---------------------------------------------------------------------------
# Structural
# ---------------------------------------------------------------------------

## The real timber this joint clamps, drilled and anchored on its bolt hole.
##
## This is what puts the hardware in CONTEXT: the beam is the design's actual
## member (see `LinkageHardware.sync_beams_from_structure`), it carries real
## bolt holes at `holeOffset` from each end, and it is translated so the
## ALIGNMENT hole sits on the stack axis — which is precisely how a beam
## "connects to" the bolt running through the stack. Port of `createHWBeamMesh`
## (hardware-detail.js:1292).
##
## Local frame: length along X, thickness along +Y spanning `[0, thickness]`
## like every other part, width along Z. `rotDeg` spins the member about the
## stack axis and is baked in, so a mirrored copy (which reflects rotDeg about
## 90 degrees) is simply a different mesh.
static func beam_mesh(p: Dictionary) -> ArrayMesh:
	var w := maxf(0.25, _or(p, "width", 1.5))
	var t := maxf(0.25, _or(p, "thickness", 3.5))
	var length := maxf(2.0, _or(p, "length", 96.0))
	var hole_off := maxf(0.25, _or(p, "holeOffset", 1.5))
	var hole_r := maxf(0.04, _or(p, "holeDiameter", 8.0 / 25.4) / 2.0)
	var align_x := beam_align_hole_x(p, length, hole_off)
	var rot := deg_to_rad(_num(p, "rotDeg", 90.0))

	# Holes: one in from each end, plus the mid-span one when the member is
	# centre-aligned and that hole is clear of the end pair.
	var holes: Array[float] = []
	if hole_off >= hole_r and hole_off <= length - hole_r:
		holes.append(hole_off)
	if length - hole_off >= hole_r and length - hole_off <= length - hole_r:
		holes.append(length - hole_off)
	if str(p.get("holeAlign", "near")) == "center" \
			and absf(align_x - hole_off) > hole_r * 2.0 \
			and absf(align_x - (length - hole_off)) > hole_r * 2.0 \
			and align_x >= hole_r and align_x <= length - hole_r:
		holes.append(align_x)
	holes.sort()

	var st := _begin()
	_add_drilled_slab(st, length, w, t, holes, hole_r)
	return _commit(st, Transform3D(Basis(Vector3.UP, rot), Vector3.ZERO)
		* Transform3D(Basis.IDENTITY, Vector3(-align_x, 0.0, 0.0)))


## Which hole the stack axis passes through (`hwGetBeamAlignHoleX` :1345).
static func beam_align_hole_x(p: Dictionary, length: float = -1.0,
		hole_off: float = -1.0) -> float:
	var l := length if length > 0.0 else maxf(2.0, _or(p, "length", 96.0))
	var off := hole_off if hole_off > 0.0 else maxf(0.25, _or(p, "holeOffset", 1.5))
	match str(p.get("holeAlign", "near")):
		"center":
			return l / 2.0
		"far":
			return l - off
	return off


## A rectangular slab with circular bores through it.
##
## The caps are tiled band by band — one band per hole, split at the midpoints
## between neighbours — because the region between a rectangle and a circle is
## star-shaped about that circle's centre only while it holds ONE hole. Each
## band then tiles exactly by casting rays out from its hole to the band's
## border, and bandless bands are a plain quad.
static func _add_drilled_slab(st: SurfaceTool, length: float, width: float,
		thickness: float, holes: Array[float], hole_r: float) -> void:
	var half_w := width / 2.0
	var edges: Array[float] = [0.0]
	for i in range(holes.size() - 1):
		edges.append((holes[i] + holes[i + 1]) / 2.0)
	edges.append(length)

	for i in range(edges.size() - 1):
		var x0 := edges[i]
		var x1 := edges[i + 1]
		if x1 - x0 <= 1e-6:
			continue
		if i < holes.size():
			_add_band_with_hole(st, x0, x1, half_w, thickness, holes[i], hole_r)
		else:
			# Bottom cap winds the opposite way from the top so both face out.
			_quad(st, Vector3(x0, thickness, -half_w), Vector3(x1, thickness, -half_w),
				Vector3(x1, thickness, half_w), Vector3(x0, thickness, half_w))
			_quad(st, Vector3(x0, 0.0, half_w), Vector3(x1, 0.0, half_w),
				Vector3(x1, 0.0, -half_w), Vector3(x0, 0.0, -half_w))

	# Outer walls of the whole member — band boundaries are internal.
	_quad(st, Vector3(0.0, 0.0, half_w), Vector3(length, 0.0, half_w),
		Vector3(length, thickness, half_w), Vector3(0.0, thickness, half_w))
	_quad(st, Vector3(length, 0.0, -half_w), Vector3(0.0, 0.0, -half_w),
		Vector3(0.0, thickness, -half_w), Vector3(length, thickness, -half_w))
	_quad(st, Vector3(0.0, 0.0, -half_w), Vector3(0.0, 0.0, half_w),
		Vector3(0.0, thickness, half_w), Vector3(0.0, thickness, -half_w))
	_quad(st, Vector3(length, 0.0, half_w), Vector3(length, 0.0, -half_w),
		Vector3(length, thickness, -half_w), Vector3(length, thickness, half_w))


static func _add_band_with_hole(st: SurfaceTool, x0: float, x1: float,
		half_w: float, thickness: float, cx: float, hole_r: float) -> void:
	var seg := 20
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var c0 := Vector2(cx + hole_r * cos(a0), hole_r * sin(a0))
		var c1 := Vector2(cx + hole_r * cos(a1), hole_r * sin(a1))
		var r0 := _ray_to_band(cx, a0, x0, x1, half_w)
		var r1 := _ray_to_band(cx, a1, x0, x1, half_w)
		# Top cap (+Y) and bottom cap (-Y), wound so each faces away.
		_quad(st, _xz(c0, thickness), _xz(r0, thickness),
			_xz(r1, thickness), _xz(c1, thickness))
		_quad(st, _xz(c1, 0.0), _xz(r1, 0.0), _xz(r0, 0.0), _xz(c0, 0.0))
		# Bore wall faces INWARD, toward the bolt.
		_quad(st, _xz(c1, 0.0), _xz(c0, 0.0), _xz(c0, thickness), _xz(c1, thickness))


## Where a ray leaving the hole centre meets the band's border.
static func _ray_to_band(cx: float, angle: float, x0: float, x1: float,
		half_w: float) -> Vector2:
	var dx := cos(angle)
	var dz := sin(angle)
	var t := INF
	if absf(dx) > 1e-9:
		t = minf(t, ((x1 if dx > 0.0 else x0) - cx) / dx)
	if absf(dz) > 1e-9:
		t = minf(t, (half_w if dz > 0.0 else -half_w) / dz)
	if not is_finite(t):
		t = 0.0
	return Vector2(cx + dx * t, dz * t)


static func _xz(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)


## The U-bracket: the real GLB when it is present, else the parametric
## stand-in. Both span [0, height] along +Y, centred on X/Z.
static func bracket_mesh(p: Dictionary) -> ArrayMesh:
	if bool(p.get("useGlb", true)):
		var glb := _build_glb_bracket(p)
		if glb != null:
			return glb
	return parametric_bracket_mesh(p)


## Procedural U-channel: a base plus two side walls, open at the top.
static func parametric_bracket_mesh(p: Dictionary) -> ArrayMesh:
	var w := maxf(0.2, _or(p, "width", 2.15))
	var d := maxf(0.2, _or(p, "depth", 1.57))
	var h := maxf(0.2, _or(p, "height", 3.77))
	var wall := clampf(_or(p, "wallThickness", 0.12), 0.01, w / 2.0 - 0.01)
	var st := _begin()
	# Base slab across the bottom.
	_add_box(st, Vector3(-w / 2.0, 0.0, -d / 2.0), Vector3(w / 2.0, wall, d / 2.0))
	# Two side walls rising from it.
	_add_box(st, Vector3(-w / 2.0, wall, -d / 2.0),
		Vector3(-w / 2.0 + wall, h, d / 2.0))
	_add_box(st, Vector3(w / 2.0 - wall, wall, -d / 2.0),
		Vector3(w / 2.0, h, d / 2.0))
	return _commit(st)


## Merged triangle soup of EVERY mesh in the bracket GLB, node transforms
## applied, in the asset's own space.
##
## The asset is THREE meshes — two trolley side plates and the U body — under
## differently scaled nodes. Loading any single mesh (or any single surface)
## renders a fragment small enough to read as a stray nut sitting where the
## bracket should be, which is exactly the bug this merge replaced.
##
## Returns empty when the asset is absent. Optional assets are the norm in
## this project, so `bracket_mesh` falls back to the parametric form and a
## fresh clone still runs — the same contract as `NpcRig.available()`.
static func glb_bracket_vertices() -> PackedVector3Array:
	if _glb_tried:
		return _glb_raw
	_glb_tried = true
	if not ResourceLoader.exists(BRACKET_GLB):
		return _glb_raw
	var scene := load(BRACKET_GLB) as PackedScene
	if scene == null:
		return _glb_raw
	var root := scene.instantiate()
	if root == null:
		return _glb_raw
	# Plain Array accumulator: packed arrays are copy-on-write, so appending
	# through a parameter would write into a copy.
	var acc: Array = []
	_collect_tris(root, Transform3D.IDENTITY, acc)
	root.free()
	var out := PackedVector3Array()
	out.resize(acc.size())
	for i in acc.size():
		out[i] = acc[i]
	_glb_raw = out
	return _glb_raw


static func _collect_tris(n: Node, xf: Transform3D, out: Array) -> void:
	var acc := xf
	if n is Node3D:
		acc = xf * (n as Node3D).transform
	var mi := n as MeshInstance3D
	if mi != null and mi.mesh != null:
		for surf in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(surf)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var raw_idx = arrays[Mesh.ARRAY_INDEX]
			if raw_idx is PackedInt32Array and not (raw_idx as PackedInt32Array).is_empty():
				for i in (raw_idx as PackedInt32Array):
					out.append(acc * verts[i])
			else:
				for v in verts:
					out.append(acc * v)
	for child in n.get_children():
		_collect_tris(child, acc, out)


## Faithful port of `buildGlbBracketMesh` (hardware-detail.js:1423):
## authored euler FIRST, then auto-orient (longest axis to vertical), then fit
## to the authored height and recentre. Output spans [0, height] on Y with its
## centre on the axis, matching every procedural part.
##
## Order subtleties preserved from three.js: the euler is order-XYZ intrinsic
## (Rx·Ry·Rz), the auto-orient DECISION reads the world box after the euler,
## and the corrective quarter-turn composes in the object's LOCAL frame —
## `Object3D.rotateZ` multiplies the quaternion on the right.
## `cutoffHeight` (a visual clip of the bracket top) is not ported; every
## shipped part authors it 0.
static func _build_glb_bracket(p: Dictionary) -> ArrayMesh:
	var raw := glb_bracket_vertices()
	if raw.is_empty():
		return null
	var target_h := maxf(0.2, _or(p, "height", 3.77))
	var rot := Basis(Vector3.RIGHT, deg_to_rad(_num(p, "glbRotX", 0.0))) \
		* Basis(Vector3.UP, deg_to_rad(_num(p, "glbRotY", 0.0))) \
		* Basis(Vector3.BACK, deg_to_rad(_num(p, "glbRotZ", 0.0)))
	var auto_flag = p.get("glbAutoOrient")
	if not (auto_flag is bool and auto_flag == false):
		var size := _box_of(raw, rot).size
		if size.x >= size.y and size.x >= size.z:
			rot = rot * Basis(Vector3.BACK, PI / 2.0)
		elif size.z >= size.y and size.z >= size.x:
			rot = rot * Basis(Vector3.RIGHT, PI / 2.0)
	var box := _box_of(raw, rot)
	if box.size.y <= 1e-9:
		return null
	var s := target_h / box.size.y * _or(p, "glbScaleMul", 1.0)
	var center := box.get_center()
	var st := _begin()
	for v in raw:
		var r := rot * v
		st.add_vertex(Vector3(
			(r.x - center.x) * s,
			(r.y - center.y) * s + target_h / 2.0,
			(r.z - center.z) * s))
	st.generate_normals()
	return st.commit()


static func _box_of(verts: PackedVector3Array, basis: Basis) -> AABB:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for v in verts:
		var r := basis * v
		mn = mn.min(r)
		mx = mx.max(r)
	return AABB(mn, mx - mn)


## Flat, de-indexed vertex list for surface 0.
static func _mesh_vertices(src: ArrayMesh) -> PackedVector3Array:
	if src.get_surface_count() == 0:
		return PackedVector3Array()
	var arrays := src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	# An un-indexed surface returns null here, not an empty array.
	var raw_idx = arrays[Mesh.ARRAY_INDEX]
	if not (raw_idx is PackedInt32Array) or (raw_idx as PackedInt32Array).is_empty():
		return verts
	var idx: PackedInt32Array = raw_idx
	var out := PackedVector3Array()
	for i in idx:
		out.append(verts[i])
	return out


# ---------------------------------------------------------------------------
# Geometry primitives
# ---------------------------------------------------------------------------

## Points around a full circle in the XZ plane.
static func _circle_points(r: float, segments: int) -> PackedVector2Array:
	return _arc_points(r, segments, 0.0, TAU)


## Points along an arc. A full circle omits the duplicate closing point; a
## partial arc keeps both ends so the split faces can be capped.
static func _arc_points(r: float, segments: int, start: float,
		arc: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var full := absf(arc - TAU) < 1e-9
	var count := segments if full else segments + 1
	for i in count:
		var a := start + arc * (float(i) / float(segments))
		out.append(Vector2(r * cos(a), r * sin(a)))
	return out


static func _hex_points(r: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 6:
		var a := (float(i) / 6.0) * TAU + PI / 6.0
		out.append(Vector2(r * cos(a), r * sin(a)))
	return out


static func _inner_r(id: float, od: float) -> float:
	return minf(id / 2.0, od / 2.0 - 0.001)


## Extrude a ring between `y0` and `y1`.
##
## `outer` and `inner` are XZ profiles with matching point counts (`inner` may
## be empty for a solid prism). `open_arc` caps the two ends of a partial arc —
## a split lock washer would otherwise be hollow at the gap.
static func _add_ring(st: SurfaceTool, outer: PackedVector2Array,
		inner: PackedVector2Array, y0: float, y1: float,
		open_arc: bool = false) -> void:
	var n := outer.size()
	if n < 3:
		return
	var solid := inner.size() != n
	var last := n - 1 if open_arc else n
	for i in last:
		var j := (i + 1) % n
		var o0 := outer[i]
		var o1 := outer[j]
		# Outer wall, wound so its face looks outward.
		_quad(st, _v(o0, y0), _v(o1, y0), _v(o1, y1), _v(o0, y1))
		if solid:
			# Caps fan from the profile centre.
			_tri(st, Vector3(0.0, y1, 0.0), _v(o0, y1), _v(o1, y1))
			_tri(st, Vector3(0.0, y0, 0.0), _v(o1, y0), _v(o0, y0))
			continue
		var i0 := inner[i]
		var i1 := inner[j]
		# Inner wall faces the bore, i.e. inward.
		_quad(st, _v(i1, y0), _v(i0, y0), _v(i0, y1), _v(i1, y1))
		# Top and bottom annulus faces.
		_quad(st, _v(i0, y1), _v(o0, y1), _v(o1, y1), _v(i1, y1))
		_quad(st, _v(o0, y0), _v(i0, y0), _v(i1, y0), _v(o1, y0))
	if open_arc and not solid and n >= 2:
		# Cap the two cut faces of the split.
		_quad(st, _v(inner[0], y0), _v(outer[0], y0), _v(outer[0], y1), _v(inner[0], y1))
		var e := n - 1
		_quad(st, _v(outer[e], y0), _v(inner[e], y0), _v(inner[e], y1), _v(outer[e], y1))


static func _add_cylinder(st: SurfaceTool, r: float, y0: float, y1: float,
		segments: int) -> void:
	_add_ring(st, _circle_points(r, segments), PackedVector2Array(), y0, y1)


## Upper half of a squashed sphere, sitting on `y0` and rising by `height`.
static func _add_dome(st: SurfaceTool, r: float, y0: float, height: float,
		segments: int, rings: int) -> void:
	for ring in rings:
		var t0 := float(ring) / float(rings)
		var t1 := float(ring + 1) / float(rings)
		var a0 := t0 * PI / 2.0
		var a1 := t1 * PI / 2.0
		var r0 := r * cos(a0)
		var r1 := r * cos(a1)
		var h0 := y0 + height * sin(a0)
		var h1 := y0 + height * sin(a1)
		for i in segments:
			var b0 := TAU * float(i) / float(segments)
			var b1 := TAU * float(i + 1) / float(segments)
			var p00 := Vector3(r0 * cos(b0), h0, r0 * sin(b0))
			var p01 := Vector3(r0 * cos(b1), h0, r0 * sin(b1))
			var p10 := Vector3(r1 * cos(b0), h1, r1 * sin(b0))
			var p11 := Vector3(r1 * cos(b1), h1, r1 * sin(b1))
			if r1 <= 1e-6:
				_tri(st, p00, p01, p10)
			else:
				_quad(st, p00, p01, p11, p10)


static func _add_box(st: SurfaceTool, mn: Vector3, mx: Vector3) -> void:
	var a := Vector3(mn.x, mn.y, mn.z)
	var b := Vector3(mx.x, mn.y, mn.z)
	var c := Vector3(mx.x, mn.y, mx.z)
	var d := Vector3(mn.x, mn.y, mx.z)
	var e := Vector3(mn.x, mx.y, mn.z)
	var f := Vector3(mx.x, mx.y, mn.z)
	var g := Vector3(mx.x, mx.y, mx.z)
	var h := Vector3(mn.x, mx.y, mx.z)
	_quad(st, e, f, g, h)   # +Y
	_quad(st, d, c, b, a)   # -Y
	_quad(st, a, b, f, e)   # -Z
	_quad(st, c, d, h, g)   # +Z
	_quad(st, d, a, e, h)   # -X
	_quad(st, b, c, g, f)   # +X


static func _v(p: Vector2, y: float) -> Vector3:
	return Vector3(p.x, y, p.y)


static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)


## Every part begins FLAT-SHADED. Fasteners are machined: averaging normals
## across a rim would round the edge off, and it would also blur the wall and
## cap normals together, which is exactly what the winding assertion reads.
static func _begin() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	return st


## Finish a surface. An optional transform is applied to the committed
## geometry, which is how a beam gets anchored on its bolt hole and spun to its
## `rotDeg` without every caller having to bake it into the vertices.
static func _commit(st: SurfaceTool, xf: Transform3D = Transform3D.IDENTITY) -> ArrayMesh:
	st.generate_normals()
	if xf != Transform3D.IDENTITY:
		st.commit_to_arrays()   # force the internal build before transforming
		var mesh := st.commit()
		return _transformed(mesh, xf)
	return st.commit()


## Re-emit a mesh through a transform, normals included.
static func _transformed(src: ArrayMesh, xf: Transform3D) -> ArrayMesh:
	if src.get_surface_count() == 0:
		return src
	var arrays := src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms = arrays[Mesh.ARRAY_NORMAL]
	var raw_idx = arrays[Mesh.ARRAY_INDEX]
	var idx: PackedInt32Array = raw_idx if raw_idx is PackedInt32Array else PackedInt32Array()
	if idx.is_empty():
		idx = PackedInt32Array()
		for i in verts.size():
			idx.append(i)
	var nb := xf.basis.inverse().transposed()
	var out := SurfaceTool.new()
	out.begin(Mesh.PRIMITIVE_TRIANGLES)
	out.set_smooth_group(-1)
	var has_norms := norms is PackedVector3Array \
		and (norms as PackedVector3Array).size() == verts.size()
	for i in idx:
		if has_norms:
			out.set_normal((nb * (norms as PackedVector3Array)[i]).normalized())
		out.add_vertex(xf * verts[i])
	if not has_norms:
		out.generate_normals()
	return out.commit()


## Reads a value where ZERO is a legitimate setting (rotDeg, posY...), unlike
## `_or`, which treats 0 as "unset" to match the JS `x || default` idiom.
static func _num(d: Dictionary, key: String, fallback: float) -> float:
	var v = d.get(key)
	if v is float or v is int:
		return float(v)
	return fallback


static func _or(d: Dictionary, key: String, fallback: float) -> float:
	var v = d.get(key)
	if (v is float or v is int) and float(v) != 0.0:
		return float(v)
	return fallback

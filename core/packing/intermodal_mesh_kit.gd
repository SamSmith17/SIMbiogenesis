class_name IntermodalMeshKit
extends RefCounted
## Primitive emitters shared by the intermodal unit builders (pallets, IBCs,
## gaylords, drums, rack bays). Every triangle goes through `tri`, which puts
## its corners in Godot's front-face order (clockwise seen from outside:
## cross(b - a, c - a) · n < 0) whatever order the caller gave, so no
## emitter here can build a box inside out.

var st := SurfaceTool.new()
var _count := 0
## Every point and normal goes through this before it is emitted (a door
## leaf swung open about its hinge, a part laid in a yard). Identity by
## default, so the older builders are untouched.
var xf := Transform3D.IDENTITY


func _init() -> void:
	st.begin(Mesh.PRIMITIVE_TRIANGLES)


func tri(a: Vector3, b: Vector3, c: Vector3, n: Vector3) -> void:
	if (b - a).cross(c - a).dot(n) > 0.0:
		var t := b
		b = c
		c = t
	if xf != Transform3D.IDENTITY:
		a = xf * a
		b = xf * b
		c = xf * c
		n = (xf.basis * n).normalized()
	st.set_normal(n)
	st.add_vertex(a)
	st.set_normal(n)
	st.add_vertex(b)
	st.set_normal(n)
	st.add_vertex(c)
	_count += 1


func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3) -> void:
	tri(a, b, c, n)
	tri(a, c, d, n)


## Axis-aligned box from its centre and full size.
func box(center: Vector3, size: Vector3) -> void:
	obox(center, Vector3(size.x * 0.5, 0, 0), Vector3(0, size.y * 0.5, 0),
		Vector3(0, 0, size.z * 0.5))


## Oriented box: centre plus three half-axis vectors (any orientation).
func obox(center: Vector3, ax: Vector3, ay: Vector3, az: Vector3) -> void:
	var axes := [ax, ay, az]
	for i in 3:
		var u: Vector3 = axes[i]
		var v: Vector3 = axes[(i + 1) % 3]
		var w: Vector3 = axes[(i + 2) % 3]
		if u.length_squared() < 1e-12:
			continue
		for s in [-1.0, 1.0]:
			var fc: Vector3 = center + u * s
			var n: Vector3 = (u * s).normalized()
			quad(fc - v - w, fc + v - w, fc + v + w, fc - v + w, n)


## Upright (or axis-aligned) cylinder: `center` is its middle, `axis` a unit
## vector, capped at both ends.
func cylinder(center: Vector3, r: float, h: float, axis: Vector3 = Vector3.UP,
		sides: int = 20, caps: bool = true) -> void:
	axis = axis.normalized()
	var ref := Vector3.RIGHT if absf(axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var e1 := axis.cross(ref).normalized()
	var e2 := axis.cross(e1).normalized()
	var top := center + axis * (h * 0.5)
	var bot := center - axis * (h * 0.5)
	for i in sides:
		var a0 := TAU * float(i) / sides
		var a1 := TAU * float(i + 1) / sides
		var d0 := e1 * cos(a0) + e2 * sin(a0)
		var d1 := e1 * cos(a1) + e2 * sin(a1)
		var n := (d0 + d1).normalized()
		quad(bot + d0 * r, bot + d1 * r, top + d1 * r, top + d0 * r, n)
		if caps:
			tri(top, top + d0 * r, top + d1 * r, axis)
			tri(bot, bot + d1 * r, bot + d0 * r, -axis)


## Commits what was emitted as one surface carrying `material` (a
## StructureMaterials look, say). Nothing emitted = no surface.
func commit_with(mesh: ArrayMesh, material: Material) -> void:
	if _count == 0:
		return
	st.commit(mesh)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material)


## Commits what was emitted as one surface with its own material. Nothing
## emitted = no surface.
func commit(mesh: ArrayMesh, color: Color, metallic: float = 0.0,
		rough: float = 0.8, alpha: float = 1.0) -> void:
	if _count == 0:
		return
	st.commit(mesh)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.metallic = metallic
	m.roughness = rough
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.surface_set_material(mesh.get_surface_count() - 1, m)


func triangle_count() -> int:
	return _count

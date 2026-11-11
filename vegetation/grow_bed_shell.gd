class_name GrowBedShell
extends RefCounted

## The built part of a grow bed: walls, soil, the path floor, a compost
## basket. Two surfaces (matte: soil, mulch, timber, compost; metal: the
## galvanised ring walls) plus a separate far "canopy" mesh, the green band a
## bed shows beyond the distance its plants are drawn to. Angles follow
## GrowBed: angle 0 is +Z (the keyhole slot), x = sin(a) r, z = cos(a) r.

const C_SOIL := Color(0.2, 0.13, 0.08)
const C_WALL := Color(0.66, 0.68, 0.7)
const C_TIMBER := Color(0.5, 0.36, 0.22)
const C_COMPOST := Color(0.24, 0.16, 0.09)
const C_STICK := Color(0.45, 0.36, 0.24)

var matte := Part.new()
var metal := Part.new()
var canopy := Part.new()


## The path floor under a keyhole bed (wood chip mulch).
func disc(r: float, col: Color, y: float) -> void:
	var n := 56
	for i in n:
		var a0 := TAU * float(i) / float(n)
		var a1 := TAU * float(i + 1) / float(n)
		matte.tri(Vector3(0, y, 0), _p(a0, r, y), _p(a1, r, y), col, Vector3.UP)


## One section of a ring bed between angles a0..a1 (radians).
func ring_bed(r0: float, r1: float, a0: float, a1: float, h: float, cap0: bool, cap1: bool) -> void:
	var n := maxi(int(ceilf((a1 - a0) * r1 / 0.45)), 1)
	var soil_y := h - 0.05
	for i in n:
		var b0 := lerpf(a0, a1, float(i) / float(n))
		var b1 := lerpf(a0, a1, float(i + 1) / float(n))
		var col := C_SOIL.lightened(0.025 * float(i % 3))
		_quad(matte, _p(b0, r0, soil_y), _p(b1, r0, soil_y), _p(b1, r1, soil_y), _p(b0, r1, soil_y), col, Vector3.UP)
		var mid := Vector3(sin(0.5 * (b0 + b1)), 0, cos(0.5 * (b0 + b1)))
		_quad(metal, _p(b0, r1, 0.0), _p(b1, r1, 0.0), _p(b1, r1, h), _p(b0, r1, h), C_WALL, mid)
		_quad(metal, _p(b0, r0, 0.0), _p(b1, r0, 0.0), _p(b1, r0, h), _p(b0, r0, h), C_WALL.darkened(0.08), -mid)
		# A rolled rim on both walls.
		_quad(metal, _p(b0, r1 - 0.03, h), _p(b1, r1 - 0.03, h), _p(b1, r1 + 0.02, h + 0.015),
			_p(b0, r1 + 0.02, h + 0.015), C_WALL.lightened(0.1), Vector3.UP)
		_quad(metal, _p(b0, r0 - 0.02, h + 0.015), _p(b1, r0 - 0.02, h + 0.015), _p(b1, r0 + 0.03, h),
			_p(b0, r0 + 0.03, h), C_WALL.lightened(0.1), Vector3.UP)
		if i == 0 and cap0:
			_quad(metal, _p(b0, r0, 0.0), _p(b0, r1, 0.0), _p(b0, r1, h), _p(b0, r0, h), C_WALL,
				Vector3(cos(b0), 0, -sin(b0)) * -1.0)
		if i == n - 1 and cap1:
			_quad(metal, _p(b1, r0, 0.0), _p(b1, r1, 0.0), _p(b1, r1, h), _p(b1, r0, h), C_WALL,
				Vector3(cos(b1), 0, -sin(b1)))


func canopy_band(r0: float, r1: float, a0: float, a1: float, y: float, col: Color) -> void:
	var n := maxi(int(ceilf((a1 - a0) * r1 / 1.2)), 1)
	for i in n:
		var b0 := lerpf(a0, a1, float(i) / float(n))
		var b1 := lerpf(a0, a1, float(i + 1) / float(n))
		_quad(canopy, _p(b0, r0 + 0.1, y), _p(b1, r0 + 0.1, y), _p(b1, r1 - 0.1, y), _p(b0, r1 - 0.1, y), col, Vector3.UP)


func canopy_rect(rc: Rect2, y: float, col: Color) -> void:
	var a := Vector3(rc.position.x + 0.05, y, rc.position.y + 0.05)
	var b := Vector3(rc.end.x - 0.05, y, rc.position.y + 0.05)
	var c := Vector3(rc.end.x - 0.05, y, rc.end.y - 0.05)
	var d := Vector3(rc.position.x + 0.05, y, rc.end.y - 0.05)
	_quad(canopy, a, b, c, d, col, Vector3.UP)


## The keyhole's centre: a woven basket of sticks with compost in it, where
## the kitchen scraps go and the water soaks out to the rings.
func compost_basket(r: float, h: float) -> void:
	var n := 14
	for i in n:
		var a := TAU * float(i) / float(n)
		var p := _p(a, r, 0.0)
		_post(matte, p, p + Vector3(0, h, 0), 0.03, C_STICK)
	for band in [0.25, 0.55, 0.8]:
		var y := h * float(band)
		for i in n:
			var a0 := TAU * float(i) / float(n)
			var a1 := TAU * float(i + 1) / float(n)
			_quad(matte, _p(a0, r + 0.01, y), _p(a1, r + 0.01, y), _p(a1, r + 0.01, y + 0.06),
				_p(a0, r + 0.01, y + 0.06), C_STICK.darkened(0.1), Vector3(sin(a0), 0, cos(a0)))
	# The heap, a little below the rim.
	var m := 12
	for i in m:
		var a0 := TAU * float(i) / float(m)
		var a1 := TAU * float(i + 1) / float(m)
		matte.tri(Vector3(0, h * 0.75, 0), _p(a0, r * 0.95, h * 0.55), _p(a1, r * 0.95, h * 0.55), C_COMPOST, Vector3.UP)


## A timber-sided raised bed.
func box_bed(rc: Rect2, h: float) -> void:
	var x0 := rc.position.x
	var x1 := rc.end.x
	var z0 := rc.position.y
	var z1 := rc.end.y
	var y := h - 0.05
	_quad(matte, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), C_SOIL, Vector3.UP)
	var t := 0.05
	for side in 4:
		var a: Vector3
		var b: Vector3
		var nn: Vector3
		match side:
			0:
				a = Vector3(x0 - t, 0, z0 - t); b = Vector3(x1 + t, 0, z0 - t); nn = Vector3(0, 0, -1)
			1:
				a = Vector3(x1 + t, 0, z0 - t); b = Vector3(x1 + t, 0, z1 + t); nn = Vector3.RIGHT
			2:
				a = Vector3(x1 + t, 0, z1 + t); b = Vector3(x0 - t, 0, z1 + t); nn = Vector3.BACK
			_:
				a = Vector3(x0 - t, 0, z1 + t); b = Vector3(x0 - t, 0, z0 - t); nn = Vector3.LEFT
		_quad(matte, a, b, b + Vector3(0, h, 0), a + Vector3(0, h, 0), C_TIMBER, nn)
		# Board joints as a darker line half way up.
		_quad(matte, a + Vector3(0, h * 0.5 - 0.004, 0) + nn * 0.002, b + Vector3(0, h * 0.5 - 0.004, 0) + nn * 0.002,
			b + Vector3(0, h * 0.5 + 0.004, 0) + nn * 0.002, a + Vector3(0, h * 0.5 + 0.004, 0) + nn * 0.002,
			C_TIMBER.darkened(0.35), nn)
	# Top caps.
	_quad(matte, Vector3(x0 - t, h, z0 - t), Vector3(x1 + t, h, z0 - t), Vector3(x1 + t, h, z0),
		Vector3(x0 - t, h, z0), C_TIMBER.lightened(0.08), Vector3.UP)
	_quad(matte, Vector3(x0 - t, h, z1), Vector3(x1 + t, h, z1), Vector3(x1 + t, h, z1 + t),
		Vector3(x0 - t, h, z1 + t), C_TIMBER.lightened(0.08), Vector3.UP)
	_quad(matte, Vector3(x0 - t, h, z0), Vector3(x0, h, z0), Vector3(x0, h, z1), Vector3(x0 - t, h, z1),
		C_TIMBER.lightened(0.08), Vector3.UP)
	_quad(matte, Vector3(x1, h, z0), Vector3(x1 + t, h, z0), Vector3(x1 + t, h, z1), Vector3(x1, h, z1),
		C_TIMBER.lightened(0.08), Vector3.UP)


## A tilled in-ground plot with a low berm round it.
func plot(rc: Rect2, berm: float) -> void:
	var y := 0.03
	var x0 := rc.position.x
	var x1 := rc.end.x
	var z0 := rc.position.y
	var z1 := rc.end.y
	_quad(matte, Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1), C_SOIL, Vector3.UP)
	var w := 0.3
	var corners := [Vector3(x0, 0, z0), Vector3(x1, 0, z0), Vector3(x1, 0, z1), Vector3(x0, 0, z1)]
	for i in 4:
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		var out := (a + b) * 0.5
		out = Vector3(out.x, 0, out.z).normalized()
		var top_a := a + Vector3(0, berm, 0) + out * (w * 0.5)
		var top_b := b + Vector3(0, berm, 0) + out * (w * 0.5)
		_quad(matte, a + Vector3(0, y, 0), b + Vector3(0, y, 0), top_b, top_a, C_SOIL.lightened(0.12), Vector3.UP - out)
		_quad(matte, top_a, top_b, b + out * w, a + out * w, C_SOIL.lightened(0.18), Vector3.UP + out)


func commit() -> ArrayMesh:
	var m := ArrayMesh.new()
	if matte.v.size() > 0:
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, matte.arrays())
		var mm := StandardMaterial3D.new()
		mm.vertex_color_use_as_albedo = true
		mm.vertex_color_is_srgb = true
		mm.roughness = 0.9
		m.surface_set_material(m.get_surface_count() - 1, mm)
	if metal.v.size() > 0:
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, metal.arrays())
		var me := StandardMaterial3D.new()
		me.vertex_color_use_as_albedo = true
		me.vertex_color_is_srgb = true
		me.metallic = 0.55
		me.roughness = 0.42
		me.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.surface_set_material(m.get_surface_count() - 1, me)
	return m


static func _p(a: float, r: float, y: float) -> Vector3:
	return Vector3(sin(a) * r, y, cos(a) * r)


func _quad(part: Part, a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, hint: Vector3) -> void:
	part.tri(a, b, c, col, hint)
	part.tri(a, c, d, col, hint)


func _post(part: Part, a: Vector3, b: Vector3, w: float, col: Color) -> void:
	var s := [Vector3(w, 0, 0), Vector3(0, 0, w), Vector3(-w, 0, 0), Vector3(0, 0, -w)]
	for i in 4:
		var o0: Vector3 = s[i]
		var o1: Vector3 = s[(i + 1) % 4]
		_quad(part, a + o0 * 0.5, a + o1 * 0.5, b + o1 * 0.5, b + o0 * 0.5, col, (o0 + o1).normalized())


class Part:
	var v := PackedVector3Array()
	var n := PackedVector3Array()
	var c := PackedColorArray()

	func tri(a: Vector3, b: Vector3, cc: Vector3, col: Color, hint: Vector3) -> void:
		var nn := (b - a).cross(cc - a)
		if nn.length_squared() < 1e-14:
			return
		nn = nn.normalized()
		if hint == Vector3.ZERO:
			hint = nn
		if nn.dot(hint) > 0.0:
			v.append_array([a, cc, b])
			n.append_array([nn, nn, nn])
		else:
			v.append_array([a, b, cc])
			n.append_array([-nn, -nn, -nn])
		c.append_array([col, col, col])

	func arrays() -> Array:
		var arr := []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = v
		arr[Mesh.ARRAY_NORMAL] = n
		arr[Mesh.ARRAY_COLOR] = c
		return arr

	func commit() -> ArrayMesh:
		var m := ArrayMesh.new()
		if v.size() > 0:
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays())
		return m

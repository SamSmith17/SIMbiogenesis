extends SceneTree

## Offline: filling a MultiMesh instance by instance (set_instance_transform +
## set_instance_custom_data) against writing one PackedFloat32Array and
## setting `buffer` once, for N vegetation-like instances (3D transform with
## yaw and scale, custom data). Checks the two buffers are byte-identical and
## prints the time of each, plus the cost of the per-instance transform build
## alone for scale.
##   Godot --headless --path . --script tools/diag/multimesh_fill_bench.gd

func _xf(i: int) -> Transform3D:
	var yaw := float(i % 360) * 0.0174533
	var s := 0.7 + float(i % 13) * 0.05
	var b := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
	return Transform3D(b, Vector3(float(i % 997) * 1.3, float(i % 31) * 0.2, float(i % 991) * 1.7))


func _cd(i: int) -> Color:
	return Color(float(i % 50), 30.0 + float(i % 7), 120.0, float(i % 100) / 100.0)


static func write_xf(buf: PackedFloat32Array, o: int, t: Transform3D) -> void:
	var b := t.basis
	buf[o] = b.x.x
	buf[o + 1] = b.y.x
	buf[o + 2] = b.z.x
	buf[o + 3] = t.origin.x
	buf[o + 4] = b.x.y
	buf[o + 5] = b.y.y
	buf[o + 6] = b.z.y
	buf[o + 7] = t.origin.y
	buf[o + 8] = b.x.z
	buf[o + 9] = b.y.z
	buf[o + 10] = b.z.z
	buf[o + 11] = t.origin.z


func _initialize() -> void:
	var n := 60000
	var xfs: Array[Transform3D] = []
	var cds: Array[Color] = []
	for i in n:
		xfs.append(_xf(i))
		cds.append(_cd(i))
	var mesh := BoxMesh.new()
	# A: instance by instance.
	var a := MultiMesh.new()
	a.transform_format = MultiMesh.TRANSFORM_3D
	a.use_custom_data = true
	a.mesh = mesh
	a.instance_count = n
	var t0 := Time.get_ticks_usec()
	for i in n:
		a.set_instance_transform(i, xfs[i])
		a.set_instance_custom_data(i, cds[i])
	var ta := float(Time.get_ticks_usec() - t0) / 1000.0
	# B: one buffer.
	var b := MultiMesh.new()
	b.transform_format = MultiMesh.TRANSFORM_3D
	b.use_custom_data = true
	b.mesh = mesh
	b.instance_count = n
	t0 = Time.get_ticks_usec()
	var buf := PackedFloat32Array()
	buf.resize(n * 16)
	for i in n:
		var o := i * 16
		write_xf(buf, o, xfs[i])
		var c := cds[i]
		buf[o + 12] = c.r
		buf[o + 13] = c.g
		buf[o + 14] = c.b
		buf[o + 15] = c.a
	b.buffer = buf
	var tb := float(Time.get_ticks_usec() - t0) / 1000.0
	var same := a.buffer == b.buffer
	# Scale: the transform build alone.
	t0 = Time.get_ticks_usec()
	var acc := 0.0
	for i in n:
		acc += _xf(i).origin.x
	var tx := float(Time.get_ticks_usec() - t0) / 1000.0
	print("mmfill: %d instances: per-instance %.1f ms, one buffer %.1f ms, buffers identical %s; building the transforms alone %.1f ms (%.0f)" % [
		n, ta, tb, str(same), tx, acc * 0.0])
	quit()

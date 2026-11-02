extends SceneTree

## What the driver sees ahead (offline): rays from each drivable preset's
## driver eye, level and pitched down, against every triangle the builder
## draws. Prints the first hit with the double-sided panels (any face) and
## with the inside view (front faces only), so a cab that walls the driver in
## shows as a near hit.
##   Godot --headless --path . --script tools/diag/vehicle_cab_view_diag.gd

func _initialize() -> void:
	for id in ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "ambulance", "rv", "motorhome", "box_truck", "semi_container"]:
		var spec := VehiclePresets.builtin(id)
		var d := VehicleDesign.solve(spec)
		var root := VehicleBuilder.build_node(spec)
		var tris := []
		for mi in root.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			var xf := _xf(root, m)
			for si in m.mesh.get_surface_count():
				var arr := m.mesh.surface_get_arrays(si)
				var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
				var idx = arr[Mesh.ARRAY_INDEX]
				var ii: PackedInt32Array = idx if idx != null else PackedInt32Array()
				var cnt := ii.size() if ii.size() > 0 else v.size()
				for t in range(0, cnt, 3):
					var a := xf * v[ii[t] if ii.size() > 0 else t]
					var b := xf * v[ii[t + 1] if ii.size() > 0 else t + 1]
					var c := xf * v[ii[t + 2] if ii.size() > 0 else t + 2]
					tris.append([a, b, c, m.name])
		var eye: Vector3 = d["driver_seat"]
		for pitch in [0.0, -10.0, -20.0]:
			var dir := Vector3(0, sin(deg_to_rad(pitch)), -cos(deg_to_rad(pitch)))
			var any := _first(tris, eye, dir, false)
			var front := _first(tris, eye, dir, true)
			print("%s pitch %d: any %s | front-only %s" % [id, int(pitch), any, front])
		root.free()
	quit(0)


func _xf(root: Node3D, n: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


func _first(tris: Array, o: Vector3, d: Vector3, front_only: bool) -> String:
	var best := INF
	var what := "nothing"
	for tr in tris:
		var a: Vector3 = tr[0]
		var b: Vector3 = tr[1]
		var c: Vector3 = tr[2]
		var n := (b - a).cross(c - a)
		# Godot's front face is clockwise: cross · outward < 0, so the outward
		# normal is -n. A front face seen from o has (-n) · d < 0.
		if front_only and (-n).dot(d) >= 0.0:
			continue
		var hit = Geometry3D.ray_intersects_triangle(o, d, a, b, c)
		if hit == null:
			continue
		var dist := (hit as Vector3).distance_to(o)
		if dist < best:
			best = dist
			what = "%.2f m (%s)" % [dist, str(tr[3])]
	return what

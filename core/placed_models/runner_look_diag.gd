extends SceneTree

## WINDOWED runner studio (not a selftest): the bare runner of each hydro
## turbine GLB, housing hidden, shot from the JET'S direction at the pitch
## point, radially from outside, along the shaft (plan) and a 3/4 view — plus
## a cyan rod along the jet line and a red bar along the shaft. The way to
## judge how a runner's buckets are ORIENTED relative to the jet: a Pelton
## bucket's splitter ridge is RADIAL and its two cups sit either side of it
## ALONG THE SHAFT, so from the jet's eye the ridge reads as a line pointing
## at the shaft with a cup on each side of it. A bucket that reads rotated a
## quarter turn in that shot is modelled wrong for its shaft, not lit wrong.
##   godot --path . --windowed --resolution 900x900 --script core/placed_models/runner_look_diag.gd
## Writes user://runner_look_<model>_<view>.png and prints the measured frame.

const MODELS := ["ali_pelton", "powerspout_plt"]


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var root3d := Node3D.new()
	root.add_child(root3d)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.12, 0.13, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.72, 0.78)
	e.ambient_light_energy = 0.8
	env.environment = e
	root3d.add_child(env)
	for rot: Vector3 in [Vector3(-52, -35, 0), Vector3(-18, 140, 0), Vector3(-10, 180, 0)]:
		var l := DirectionalLight3D.new()
		l.rotation_degrees = rot
		l.light_energy = 1.1
		root3d.add_child(l)
	var cam := Camera3D.new()
	cam.near = 0.003
	cam.fov = 40.0
	root3d.add_child(cam)
	cam.make_current()

	for mid in MODELS:
		var inst: Node3D = ModelCatalog.instantiate(mid)
		if inst == null:
			print("RunnerLook: %s — no model (GLB missing?)" % mid)
			continue
		var holder := Node3D.new()
		root3d.add_child(holder)
		inst.scale = Vector3.ONE * ModelCatalog.resolved_scale(mid, 1.0)
		holder.add_child(inst)
		var runner := inst.find_child(ModelCatalog.turbine_node_for(mid), true, false) as Node3D
		if runner == null:
			print("RunnerLook: %s — runner node not found" % mid)
			holder.queue_free()
			continue
		for n: Node in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi != runner and not runner.is_ancestor_of(mi):
				mi.visible = false
		var axis := Vector3.BACK
		match ModelCatalog.spin_axis_for(mid):
			"x": axis = Vector3.RIGHT
			"y": axis = Vector3.UP
		var mi0 := _first_mesh(runner)
		var xf := _chain(mi0, holder)
		var aabb := mi0.get_aabb()
		var centre := xf * aabb.get_center()
		var ext := (xf.basis * aabb.size).abs()
		var comps := [ext.x, ext.y, ext.z]
		comps.sort()
		var r := float(comps[2]) * 0.5
		var thick := float(comps[0])
		var pcd := float(HydroSource.kind_meta("micro_pelton" if mid == "ali_pelton" else "powerspout_pelton").get("runner_pcd_m", 2.0 * r * 0.85))
		var r_pitch := minf(pcd * 0.5, r * 0.97)
		# Jet frame: side = a horizontal in-plane direction, the jet runs along
		# -side on the chord at the pitch radius, tangent at the pitch point.
		var side := axis.cross(Vector3.UP)
		if side.length_squared() < 1e-5:
			side = axis.cross(Vector3.BACK)
		side = side.normalized()
		var n_in := axis.cross(-side).normalized()   # in-plane perpendicular to the jet
		var pitch_pt := centre + n_in * r_pitch
		var jet_dir := -side
		print("RunnerLook: %s runner r=%.3f thick=%.3f axis=%s centre=%s r_pitch=%.3f pitch_pt=%s jet_dir=%s" % [
			mid, r, thick, str(axis), str(centre), r_pitch, str(pitch_pt), str(jet_dir)])
		# Reference rods: cyan along the jet through the pitch point, red along the shaft.
		holder.add_child(_rod(pitch_pt - jet_dir * r * 1.2, pitch_pt + jet_dir * r * 0.5, 0.004, Color(0.3, 0.9, 1.0)))
		holder.add_child(_rod(centre - axis * r * 0.9, centre + axis * r * 0.9, 0.004, Color(1.0, 0.25, 0.25)))
		holder.add_child(_rod(pitch_pt, pitch_pt - n_in * r_pitch, 0.002, Color(1.0, 0.85, 0.2)))   # radial, to the shaft
		var views := {
			"jet_eye": [pitch_pt - jet_dir * r * 1.1 + n_in * r * 0.12, pitch_pt, n_in],
			"radial_out": [pitch_pt + n_in * r * 1.4 - jet_dir * r * 0.15, pitch_pt, axis],
			"plan": [centre + axis * r * 3.2, centre, n_in],
			"three_quarter": [centre + (axis * 1.6 + n_in * 1.4 - jet_dir * 1.1) * r, pitch_pt, axis],
		}
		for vname in views.keys():
			var v: Array = views[vname]
			cam.global_position = v[0]
			cam.look_at(v[1], v[2])
			await process_frame
			await process_frame
			await process_frame
			var img := root.get_viewport().get_texture().get_image()
			var path := "user://runner_look_%s_%s.png" % [mid, vname]
			img.save_png(path)
			print("RunnerLook: wrote %s" % path)
		holder.queue_free()
		await process_frame
	quit(0)


func _rod(a: Vector3, b: Vector3, radius: float, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = a.distance_to(b)
	mi.mesh = cyl
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col
	mi.material_override = m
	var up := (b - a).normalized()
	var fwd := up.cross(Vector3.UP)
	if fwd.length_squared() < 1e-5:
		fwd = up.cross(Vector3.BACK)
	fwd = fwd.normalized()
	mi.transform = Transform3D(Basis(up.cross(fwd).normalized(), up, fwd), (a + b) * 0.5)
	return mi


func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.find_children("*", "MeshInstance3D", true, false):
		return c as MeshInstance3D
	return null


func _chain(node: Node3D, stop: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != stop:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf

extends SceneTree

## What tri-clamp assemblies cost (headless, NOT a selftest):
##   Godot --headless --path . --script tools/bench/tclab_bench.gd
## Prints, for the biochar reactor and a generated 200-part manifold: the
## cold solve (cache cleared), the cached solve, a mid-drag solve_transient,
## the world build (near + far + collision meshes) and the triangle counts
## per level of detail. The plan's targets: a 200-part assembly solves in
## under 30 ms and a drag solve fits a 60 fps frame (16 ms).

func _initialize() -> void:
	var cases := [["biochar_reactor", TcPresets.builtin("biochar_reactor")], ["manifold_200", manifold(200)]]
	for c in cases:
		var name: String = c[0]
		var spec: Dictionary = c[1]
		TcDesign.clear_cache()
		TcParts.clear_cache()
		var t0 := Time.get_ticks_usec()
		var d := TcDesign.solve(spec)
		var cold := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		TcDesign.solve(spec)
		var warm := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		for _i in 5:
			TcDesign.solve_transient(spec)
		var drag := (Time.get_ticks_usec() - t0) / 5000.0
		t0 = Time.get_ticks_usec()
		var node := TcBuilder.build_node(spec)
		var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
		t0 = Time.get_ticks_usec()
		var node2 := TcBuilder.build_node(spec)
		var rebuild_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var tris := {}
		for mi in node.find_children("*", "MeshInstance3D", true, false):
			var m := (mi as MeshInstance3D).mesh
			var n := 0
			for s in m.get_surface_count():
				n += (m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			tris[mi.name] = "%d tris, %d surfaces" % [n, m.get_surface_count()]
		print("tclab bench %s: %d parts, %d joints · solve cold %.1f ms, cached %.2f ms, drag %.1f ms · build %.1f ms (again %.1f ms) · %s" % [
			name, (d["res"]["order"] as Array).size(), (d["res"]["joints"] as Array).size(),
			cold, warm, drag, build_ms, rebuild_ms, str(tris)])
		node.free()
		node2.free()
	quit(0)


## A long manifold: a run of tees, each branch capped or carrying a valve,
## with spools between, wrapping round in 90° elbows every 12 tees.
static func manifold(n_parts: int) -> Dictionary:
	var r := TcAssembly.add_part(TcSpec.empty("Manifold"), "spool", "2", {"length_mm": 150.0}, Transform3D.IDENTITY)
	var s: Dictionary = r[0]
	var tail := str(r[1]) + ":b"
	var k := 0
	while (s["parts"] as Array).size() < n_parts:
		k += 1
		if k % 12 == 0:
			r = TcAssembly.add_part(s, "elbow90", "2", {}, Transform3D.IDENTITY, {"target": tail, "own": "a"})
			s = r[0]
			tail = str(r[1]) + ":b"
			continue
		r = TcAssembly.add_part(s, "tee", "2", {}, Transform3D.IDENTITY, {"target": tail, "own": "a"})
		s = r[0]
		var tee := str(r[1])
		var branch := "butterfly" if k % 3 == 0 else "cap"
		r = TcAssembly.add_part(s, branch, "2", {}, Transform3D.IDENTITY, {"target": tee + ":c", "own": "a"})
		s = r[0]
		r = TcAssembly.add_part(s, "spool", "2", {"length_mm": 100.0}, Transform3D.IDENTITY, {"target": tee + ":b", "own": "a"})
		s = r[0]
		tail = str(r[1]) + ":b"
	return s

extends SceneTree
## GLB dump (NOT a selftest): the node tree with local transforms, every
## mesh's AABB, vertex count and material, then the GLOBAL AABB of each
## top-level assembly part in the root's metre frame. What you read BEFORE
## authoring a ModelCatalog entry: which node is the runner, which axis is
## its shaft, where the nozzle fitting sits, what the exporter left in the
## file (SketchUp scale figures, camera markers) that must be stripped.
## Godot.exe --headless --path . --script core/placed_models/glb_dump_diag.gd -- --glb=<path>


func _initialize() -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		if str(a).begins_with("--glb="):
			path = str(a).substr(6)
	if path.is_empty():
		print("usage: --glb=<path>")
		quit(1)
		return
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_file(path, st)
	if err != OK:
		print("load failed: ", err)
		quit(1)
		return
	_root = doc.generate_scene(st)
	get_root().add_child(_root)


var _root: Node = null


## The SceneTree root is not inside the tree during _initialize, so global
## transforms only resolve on the first process frame.
func _process(_delta: float) -> bool:
	if _root == null:
		return true
	_dump(_root, 0)
	for c in _root.get_children():
		for cc in c.get_children():
			for n in cc.get_children():
				var a := _aabb(n)
				print("GLOBAL %s: pos %s size %s centre %s" % [n.name, a.position, a.size, a.get_center()])
				for m in n.find_children("*", "MeshInstance3D", true, false):
					var mi := m as MeshInstance3D
					var ma := mi.global_transform * mi.get_aabb()
					print("   mesh %s: pos %s size %s" % [mi.name, ma.position, ma.size])
	var aabb := _aabb(_root)
	print("WHOLE AABB pos %s size %s" % [aabb.position, aabb.size])
	quit(0)
	return true


func _aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var a := mi.global_transform * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _dump(n: Node, depth: int) -> void:
	var line := "  ".repeat(depth) + n.name + " (" + n.get_class() + ")"
	if n is Node3D:
		var t := (n as Node3D).transform
		line += " pos=%s scale=%s rot=%s" % [t.origin, t.basis.get_scale(), t.basis.get_euler() * 57.2958]
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var a := mi.get_aabb()
		line += " | aabb pos=%s size=%s surfaces=%d" % [a.position, a.size, mi.mesh.get_surface_count() if mi.mesh else 0]
		if mi.mesh:
			for s in mi.mesh.get_surface_count():
				var mat := mi.mesh.surface_get_material(s)
				line += " mat%d=%s" % [s, mat.resource_name if mat else "null"]
				var arr := mi.mesh.surface_get_arrays(s)
				line += "(v%d)" % (arr[Mesh.ARRAY_VERTEX].size() if arr.size() > 0 and arr[Mesh.ARRAY_VERTEX] else 0)
	print(line)
	for c in n.get_children():
		_dump(c, depth + 1)

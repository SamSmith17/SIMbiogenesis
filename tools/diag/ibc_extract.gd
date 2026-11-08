extends SceneTree
## IBC tote extractor (NOT a selftest — the asset pipeline). The only IBC
## model in the project is the "IBC_DXF" assembly inside the user's big
## SketchUp site exports (Mars 2026 - Aerial Located.glb, 58 MB). Loading
## that for one tote prop is out of the question, so this pulls the
## assembly out ONCE, stands it on the ground at its real size (its mesh
## bounds are about 1.2 x 1.0 x 1.16 m — a 1000 L tote), lays its long axis
## along Z with the valve toward +Z and writes a small standalone GLB that
## IbcBuilder instantiates at runtime (procedural fallback when absent).
##
##   Godot.exe --headless --path . --script tools/diag/ibc_extract.gd -- \
##       --glb="res://Imported Models/Mars Aerial/Mars 2026 - Aerial Located.glb" \
##       --out=res://assets/packing/ibc_tote.glb [--node=IBC_DXF] [--dump]
##
## Prints the assembly's node tree, every mesh's material and the measured
## box before and after normalising.

var _root: Node = null
var _out := "res://assets/packing/ibc_tote.glb"
var _node_prefix := "IBC_DXF"
var _dump := false


func _initialize() -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--glb="):
			path = s.substr(6)
		elif s.begins_with("--out="):
			_out = s.substr(6)
		elif s.begins_with("--node="):
			_node_prefix = s.substr(7)
		elif s == "--dump":
			_dump = true
	if path.is_empty():
		print("usage: --glb=<path> [--out=<path>] [--node=<prefix>] [--dump]")
		quit(1)
		return
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var t0 := Time.get_ticks_msec()
	var err := doc.append_from_file(path, st)
	if err != OK:
		print("load failed: ", err)
		quit(1)
		return
	_root = doc.generate_scene(st)
	print("loaded %s in %d ms" % [path, Time.get_ticks_msec() - t0])
	get_root().add_child(_root)


func _process(_delta: float) -> bool:
	if _root == null:
		return true
	var found: Array = []
	_find(_root, found)
	print("assemblies named %s*: %d" % [_node_prefix, found.size()])
	for n in found:
		print("  %s (%d meshes)" % [_root.get_path_to(n), n.find_children("*", "MeshInstance3D", true, false).size()])
	if found.is_empty():
		quit(1)
		return true
	var src := found[0] as Node3D
	if _dump:
		_dump_tree(src, 0)
	# Materials in use.
	var mats := {}
	for m in src.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			var key := mat.resource_name if mat != null else "<none>"
			mats[key] = int(mats.get(key, 0)) + 1
	print("materials: ", mats)
	var before := _aabb(src)
	print("source box (world): pos %s size %s" % [before.position, before.size])
	# Lift the assembly out, keeping its WORLD pose, under a fresh root.
	var world_xf := src.global_transform
	src.get_parent().remove_child(src)
	var fresh := Node3D.new()
	fresh.name = "IbcTote"
	get_root().add_child(fresh)
	fresh.add_child(src)
	src.transform = world_xf
	src.visible = true
	# Normalise: centre on the ground, floor at y = 0, long axis along Z.
	var bb := _aabb(src)
	var centre := bb.get_center()
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	fresh.remove_child(src)
	fresh.add_child(pivot)
	pivot.add_child(src)
	src.position -= Vector3(centre.x, bb.position.y, centre.z)
	# The site export stands the tote at the camp's own heading: find the
	# yaw that squares it up (the smallest footprint), then lay the long
	# axis along Z with the valve toward +Z.
	var best_yaw := 0.0
	var best_area := INF
	for i in 180:
		pivot.rotation.y = deg_to_rad(float(i) * 0.5)
		var a := _aabb(pivot)
		if a.size.x * a.size.z < best_area:
			best_area = a.size.x * a.size.z
			best_yaw = pivot.rotation.y
	pivot.rotation.y = best_yaw
	bb = _aabb(pivot)
	if bb.size.x > bb.size.z:
		pivot.rotation.y = best_yaw + PI * 0.5
		bb = _aabb(pivot)
	# The pallet frame (the widest mesh in the bottom 20 cm) is the true
	# footprint; the valve overhangs it on the +Z side.
	var pallet := AABB()
	var best_fp := 0.0
	var valve_z := 0.0
	var valve_vol := INF
	for m in pivot.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var a := mi.global_transform * mi.get_aabb()
		var fp := a.size.x * a.size.z
		if a.position.y < 0.2 and fp > best_fp:
			best_fp = fp
			pallet = a
		var vol := a.size.x * a.size.y * a.size.z
		if a.position.y > 0.1 and a.size.y < 0.1 and vol < valve_vol and vol > 1e-5:
			valve_vol = vol
			valve_z = a.get_center().z
	if valve_z < 0.0:
		pivot.rotation.y += PI
		bb = _aabb(pivot)
		pallet = pallet  # re-measured below
	# Fit the pallet footprint to the nominal 1000 L tote (1.2 x 1.0 x 1.16).
	pallet = AABB()
	best_fp = 0.0
	for m in pivot.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var a := mi.global_transform * mi.get_aabb()
		if a.position.y < 0.2 and a.size.x * a.size.z > best_fp:
			best_fp = a.size.x * a.size.z
			pallet = a
	print("pallet footprint: pos %s size %s" % [pallet.position, pallet.size])
	var fit := Node3D.new()
	fit.name = "Fit"
	fresh.remove_child(pivot)
	fresh.add_child(fit)
	fit.add_child(pivot)
	fit.scale = Vector3(1.0 / maxf(pallet.size.x, 0.1), 1.16 / maxf(bb.size.y, 0.1),
		1.2 / maxf(pallet.size.z, 0.1))
	pivot.position = Vector3(-pallet.get_center().x, 0.0, -pallet.get_center().z)
	bb = _aabb(fit)
	print("normalised box: pos %s size %s" % [bb.position, bb.size])
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	var err := gltf.append_from_scene(fresh, state)
	if err != OK:
		print("append_from_scene failed: ", err)
		quit(1)
		return true
	var abs_out := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
	err = gltf.write_to_filesystem(state, abs_out)
	print("write %s: %s (%d bytes)" % [abs_out, error_string(err),
		FileAccess.get_file_as_bytes(abs_out).size() if err == OK else 0])
	quit(0 if err == OK else 1)
	return true


func _find(n: Node, out: Array) -> void:
	if n is Node3D and n.name.begins_with(_node_prefix):
		out.append(n)
		return
	for c in n.get_children():
		_find(c, out)


func _dump_tree(n: Node, depth: int) -> void:
	var line := "  ".repeat(depth) + n.name
	if n is Node3D:
		var t := (n as Node3D).transform
		line += "  pos %s scale %s" % [t.origin, t.basis.get_scale()]
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		line += "  aabb %s surfaces %d" % [mi.get_aabb().size, mi.mesh.get_surface_count()]
	print(line)
	for c in n.get_children():
		_dump_tree(c, depth + 1)


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

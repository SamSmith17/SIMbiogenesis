class_name VehicleModelBuilder
extends RefCounted

## Normalised vehicle models for the placement catalog (ModelCatalog entries
## with `vehicle_build: true`). Some vehicle art does not place cleanly as-is:
## Busses.tscn holds TWO buses side by side in one assembly, authored in
## inches far from the origin, with hundreds of hidden parts; the camper van
## GLB is in its own units. This builder:
##   1. instantiates the entry's `path`,
##   2. keeps only the `isolate` subtree when given (one bus out of two),
##   3. FREES every hidden node (ModelCatalog.mesh_metrics measures hidden
##      meshes too, so a hidden part left in would move the footing),
##   4. lays the long axis along local Z (front toward -Z, `flip` turns it
##      round), scales it to the entry's real `length_m`, centres it on the
##      origin and stands it on y = 0.
## The result is in metres, so the entry carries `preserve_scale: true`.

const MODEL_IDS: Array = ["vehicle_tool_bus", "vehicle_camper_van"]


static func handles(model_id: String) -> bool:
	return MODEL_IDS.has(model_id)


static func build_node(model_id: String) -> Node3D:
	var entry := ModelCatalog.find(model_id)
	var path := str(entry.get("source_path", ""))
	var root := Node3D.new()
	root.name = "VehicleModel"
	if path.is_empty() or not ResourceLoader.exists(path):
		return root
	var ps := ResourceLoader.load(path) as PackedScene
	if ps == null:
		return root
	var src := ps.instantiate() as Node3D
	if src == null:
		return root
	var pivot := Node3D.new()
	pivot.name = "Pivot"
	root.add_child(pivot)
	var isolate := str(entry.get("isolate", ""))
	var keep: Node3D = src
	if not isolate.is_empty():
		var n := src.get_node_or_null(isolate) as Node3D
		if n != null:
			var xf := _xform_relative_to(src, n)
			n.get_parent().remove_child(n)
			n.transform = xf
			# The isolated part is the point, even if its scene hid it.
			n.visible = true
			keep = n
	if keep != src:
		src.free()
	pivot.add_child(keep)
	_free_hidden(keep)
	var aabb := _measure(pivot)
	if aabb.size.length_squared() < 1e-6:
		return root
	# Long axis onto Z. The art's own front is unknown in general; `flip`
	# turns it round per entry (checked by eye — see vehicle_look_diag.gd).
	var yaw := 0.0
	if aabb.size.x > aabb.size.z:
		yaw = PI * 0.5
	if bool(entry.get("flip", false)):
		yaw += PI
	var long := maxf(aabb.size.x, aabb.size.z)
	var s := float(entry.get("length_m", long)) / maxf(long, 1e-4)
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
	var c := aabb.get_center()
	var anchor := Vector3(c.x, aabb.position.y, c.z)
	pivot.transform = Transform3D(basis, -(basis * anchor))
	return root


## Every mesh's box in `pivot`'s parent space (pivot transform excluded —
## it is identity while measuring).
static func _measure(pivot: Node3D) -> AABB:
	var aabb := AABB()
	var found := false
	for node in pivot.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = _xform_relative_to(pivot, mi) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	return aabb


static func _free_hidden(n: Node) -> void:
	for child in n.get_children():
		if child is Node3D and not (child as Node3D).visible:
			n.remove_child(child)
			child.free()
		else:
			_free_hidden(child)


## `descendant`'s local space in `ancestor`'s (excludes the ancestor's own
## transform) — pure local-transform math, valid outside the tree.
static func _xform_relative_to(ancestor: Node, descendant: Node3D) -> Transform3D:
	var t := descendant.transform
	var p := descendant.get_parent()
	while p != null and p != ancestor and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t

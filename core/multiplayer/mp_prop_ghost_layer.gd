class_name MpPropGhostLayer
extends RefCounted

## Spawn translucent 3D stand-ins for foreign placed_props (Phase 3 ghost diff).

const GHOST_ROOT_NAME := "EsimPropGhosts"


static func clear(main: Node) -> void:
	if main == null:
		return
	var root := main.get_node_or_null(GHOST_ROOT_NAME)
	if root != null and is_instance_valid(root):
		root.queue_free()


static func spawn_from_package(main: Node, package: Dictionary, tint: Color = Color(0.4, 0.85, 1.0, 0.45)) -> Dictionary:
	clear(main)
	if main == null:
		return {"ok": false, "error": "Main missing", "count": 0}
	var props_blob: Dictionary = package.get("placed_props", {}) as Dictionary
	var props: Array = props_blob.get("props", []) as Array
	if props.is_empty():
		return {"ok": true, "count": 0}
	var root := Node3D.new()
	root.name = GHOST_ROOT_NAME
	main.add_child(root)
	var count := 0
	for raw in props:
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw as Dictionary
		var node := _make_ghost_node(main, rec, tint)
		if node == null:
			continue
		root.add_child(node)
		count += 1
	return {"ok": true, "count": count}


static func _make_ghost_node(main: Node, rec: Dictionary, tint: Color) -> Node3D:
	var model_id := str(rec.get("model_id", ""))
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	var yaw := float(rec.get("yaw", 0.0))
	var pitch := float(rec.get("pitch", 0.0))
	var roll := float(rec.get("roll", 0.0))
	var scl := float(rec.get("scale", 1.0))
	var gy := float(rec.get("ground_y", NAN))
	if is_nan(gy) and main != null:
		gy = TerrainSurfaceQuery.ground_height_at(main, x, z)
	if is_nan(gy):
		gy = 0.0
	var y_off := float(rec.get("y_offset", 0.0))

	var holder := Node3D.new()
	holder.name = "Ghost_%s" % str(rec.get("id", count_placeholder()))
	# Local, not global: the holder is not in the tree yet (setting a global
	# transform there is an engine error), and every ghost root sits under Main
	# at the origin, so the two are the same.
	holder.position = Vector3(x, gy + y_off, z)
	holder.rotation = Vector3(pitch, yaw, roll)
	holder.scale = Vector3(scl, scl, scl)

	var visual: Node3D = null
	if not model_id.is_empty():
		visual = ModelCatalog.instantiate(model_id, rec)
	if visual == null:
		visual = _fallback_mesh(tint)
	else:
		_apply_ghost_materials(visual, tint)
	holder.add_child(visual)

	var label := Label3D.new()
	label.text = "👻 " + (model_id if not model_id.is_empty() else "prop")
	label.font_size = 36
	label.pixel_size = 0.014
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0.0, 2.2, 0.0)
	label.modulate = Color(tint.r, tint.g, tint.b, 0.95)
	holder.add_child(label)
	return holder


static func _fallback_mesh(tint: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.2, 1.2, 1.2)
	mi.mesh = box
	mi.position = Vector3(0.0, 0.6, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.7
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	return mi


static func _apply_ghost_materials(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.65
		mat.metallic = 0.05
		mi.material_override = mat
	for child in node.get_children():
		_apply_ghost_materials(child, tint)


static func count_placeholder() -> String:
	return str(Time.get_ticks_msec() % 100000)

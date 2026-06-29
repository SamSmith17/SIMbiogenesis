class_name PlacedPropRuntime
extends RefCounted

## Builds PlacedProp nodes under Terrain/PlacedProps.


static func ensure_root(terrain: Node3D) -> Node3D:
	var root := terrain.get_node_or_null("PlacedProps") as Node3D
	if root == null:
		root = Node3D.new()
		root.name = "PlacedProps"
		terrain.add_child(root)
	return root


static func rebuild(terrain: Node3D, layer: PlacedPropLayer,
		ground_y_at: Callable) -> void:
	if terrain == null or layer == null:
		return
	var root := ensure_root(terrain)
	_clear_children(root)
	for item in layer.props:
		if not (item is Dictionary):
			continue
		var prop := _build_prop(item as Dictionary, ground_y_at)
		if prop != null:
			root.add_child(prop)


static func reground(terrain: Node3D, layer: PlacedPropLayer,
		ground_y_at: Callable) -> void:
	rebuild(terrain, layer, ground_y_at)


## Spawn a single prop node from one record without disturbing existing props.
## Used by the ghost-placement commit so confirming a placement doesn't free and
## rebuild every other prop in the scene.
static func add_one(terrain: Node3D, rec: Dictionary,
		ground_y_at: Callable) -> PlacedProp:
	if terrain == null or rec.is_empty():
		return null
	var root := ensure_root(terrain)
	var prop := _build_prop(rec, ground_y_at)
	if prop != null:
		root.add_child(prop)
	return prop


static func _build_prop(rec: Dictionary, ground_y_at: Callable) -> PlacedProp:
	var model_id := str(rec.get("model_id", ""))
	if model_id.is_empty():
		return null
	var model := ModelCatalog.instantiate(model_id)
	if model == null:
		return null
	var prop := PlacedProp.new()
	prop.name = "PlacedProp_%s" % str(rec.get("id", "unknown"))
	prop.prop_id = str(rec.get("id", ""))
	prop.model_id = model_id
	prop.is_osm_replacement = str(rec.get("type", "")) == "osm"
	prop.building_idx = int(rec.get("building_idx", -1))
	prop.prompt = "Edit prop (click) / Grab (hold)"
	prop.add_child(model)
	model.name = "ModelRoot"
	_disable_embedded_physics(model)
	_apply_transform(prop, model, rec, ground_y_at)
	prop.setup_collision()
	var prop_id := str(rec.get("id", ""))
	if PlacedPropService.is_placement_active() and prop_id == PlacedPropService.placement_prop_id():
		prop.set_collision_enabled(false)
	return prop


static func apply_record_to_prop(prop: PlacedProp, rec: Dictionary,
		ground_y_at: Callable) -> void:
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	_apply_transform(prop, model, rec, ground_y_at)
	prop.setup_collision()


static func _apply_transform(_prop: PlacedProp, model: Node3D, rec: Dictionary,
		ground_y_at: Callable) -> void:
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	var yaw := deg_to_rad(float(rec.get("yaw", 0.0)))
	var pitch := deg_to_rad(float(rec.get("pitch", 0.0)))
	var roll := deg_to_rad(float(rec.get("roll", 0.0)))
	var user_scale := float(rec.get("scale", 1.0))
	var world_scale := ModelCatalog.resolved_scale(str(rec.get("model_id", "")), user_scale)
	var foot_y := ModelCatalog.foot_local_y(str(rec.get("model_id", "")))
	var gy: float = float(rec.get("ground_y", ground_y_at.call(x, z)))
	model.scale = Vector3.ONE * world_scale
	model.rotation = Vector3(pitch, yaw, roll)
	var grounded_y := gy - foot_y * world_scale
	_prop.position = Vector3(x, grounded_y, z)
	if rec.has("y"):
		_prop.position.y = float(rec["y"])


static func _clear_children(root: Node3D) -> void:
	for child in root.get_children():
		child.queue_free()


static func _disable_embedded_physics(model: Node3D) -> void:
	if model == null:
		return
	for node in model.find_children("*", "CollisionObject3D", true, false):
		if node is CollisionObject3D:
			var co := node as CollisionObject3D
			co.collision_layer = 0
			co.collision_mask = 0

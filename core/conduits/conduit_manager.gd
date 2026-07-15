class_name ConduitManager
extends Node3D

## Renders 3D conduits for graph connections whose endpoints are linked to
## scene nodes. Rebuilds on model changes and when anchor transforms move.

var _model: GraphModel = null
var _main: Node = null
var _instances: Dictionary = {}  ## conn_id -> MeshInstance3D
var _last_anchors: Dictionary = {}  ## conn_id -> PackedVector3Array hash
var _updating_model: bool = false


func setup(model: GraphModel, main_node: Node) -> void:
	_model = model
	_main = main_node
	set_process(true)
	if _model != null and _model.has_signal("changed"):
		if not _model.changed.is_connected(_on_model_changed):
			_model.changed.connect(_on_model_changed)
	sync_all()


func teardown() -> void:
	if _model != null and _model.has_signal("changed"):
		if _model.changed.is_connected(_on_model_changed):
			_model.changed.disconnect(_on_model_changed)
	for cid: String in _instances.keys().duplicate():
		_remove_instance(cid)
	_instances.clear()
	_last_anchors.clear()
	_model = null
	_main = null


func _on_model_changed(_reason: String) -> void:
	if _updating_model:
		return
	sync_all()


func sync_all() -> void:
	if _model == null:
		return
	var active: Dictionary = {}
	for conn: Dictionary in _model.connections:
		var cid: String = str(conn.get("id", ""))
		if cid.is_empty():
			continue
		if not _model.connection_is_3d_routable(conn):
			continue
		active[cid] = true
		_rebuild_if_dirty(conn)
	for cid: String in _instances.keys().duplicate():
		if not active.has(cid):
			_remove_instance(cid)
			_last_anchors.erase(cid)


func _process(_delta: float) -> void:
	if _model == null:
		return
	for conn: Dictionary in _model.connections:
		var cid: String = str(conn.get("id", ""))
		if cid.is_empty() or not _instances.has(cid):
			continue
		if not _model.connection_is_3d_routable(conn):
			continue
		_rebuild_if_dirty(conn)


## Resolve global anchor for a graph item (conduit_anchor child or node origin).
static func anchor_global_for_item(item: Dictionary, tree: SceneTree) -> Vector3:
	if tree == null or item.is_empty():
		return Vector3.INF
	var path: String = _scene_path_from_item(item)
	if path.is_empty():
		return Vector3.INF
	var node: Node = tree.root.get_node_or_null(NodePath(path))
	if node == null or not is_instance_valid(node):
		return Vector3.INF
	return _anchor_from_node(node)


static func _scene_path_from_item(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var p: String = str(specs.get("scene_device_path", ""))
	if not p.is_empty():
		return p
	return str(item.get("device_path", ""))


static func _anchor_from_node(node: Node) -> Vector3:
	if node is Node3D:
		for child in node.get_children():
			if child is Node3D and child.is_in_group("conduit_anchor"):
				return (child as Node3D).global_position
		return (node as Node3D).global_position + Vector3(0.0, 0.5, 0.0)
	return Vector3.INF


func build_control_points(conn: Dictionary) -> Array:
	var src := _model.get_item(str(conn.get("source_item_id", "")))
	var tgt := _model.get_item(str(conn.get("target_item_id", "")))
	var tree := get_tree()
	if tree == null:
		return []
	var a: Vector3 = anchor_global_for_item(src, tree)
	var b: Vector3 = anchor_global_for_item(tgt, tree)
	if not is_finite(a.x) or not is_finite(b.x):
		return []
	var pts: Array = [a]
	for wp: Vector3 in ConduitKinds.waypoints_to_vectors(conn.get("route_3d", []) as Array):
		pts.append(wp)
	pts.append(b)
	return pts


func preview_mesh(control_points: Array, type_id: String) -> Dictionary:
	return ConduitMeshBuilder.build(control_points, type_id)


func _rebuild_if_dirty(conn: Dictionary) -> void:
	var cid: String = str(conn.get("id", ""))
	var control := build_control_points(conn)
	if control.size() < 2:
		_remove_instance(cid)
		return
	var sig := _control_signature(control)
	if _last_anchors.has(cid) and (_last_anchors[cid] as PackedVector3Array) == sig:
		return
	_last_anchors[cid] = sig
	var type_id: String = ConduitKinds.derive_type_for_connection(conn)
	var built: Dictionary = ConduitMeshBuilder.build(control, type_id)
	var inst: MeshInstance3D = _instances.get(cid, null)
	if inst == null or not is_instance_valid(inst):
		inst = MeshInstance3D.new()
		inst.name = "Conduit_%s" % cid
		inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(inst)
		_instances[cid] = inst
	inst.mesh = built.get("mesh", null)
	inst.material_override = built.get("material", null)
	var arc: float = float(built.get("arc_length_m", 0.0))
	_write_length_back(cid, arc)


func _control_signature(control: Array) -> PackedVector3Array:
	var sig := PackedVector3Array()
	for p: Variant in control:
		if p is Vector3:
			sig.append(p)
	return sig


func _write_length_back(conn_id: String, length_m: float) -> void:
	if _model == null:
		return
	var conn := _model.get_connection(conn_id)
	if conn.is_empty():
		return
	var prev: float = float(conn.get("route_length_m", 0.0))
	var prev_est: float = float(conn.get("estimated_length", 0.0))
	if absf(prev - length_m) < 0.001 and absf(prev_est - length_m) < 0.001:
		return
	_updating_model = true
	_model.update_connection(conn_id, {
		"route_length_m": length_m,
		"estimated_length": length_m,
	})
	_updating_model = false


func clear_route(conn_id: String) -> void:
	if _model == null:
		return
	_updating_model = true
	_model.update_connection(conn_id, {"route_3d": [], "route_length_m": 0.0})
	_updating_model = false
	_last_anchors.erase(conn_id)
	var conn := _model.get_connection(conn_id)
	if not conn.is_empty():
		_rebuild_if_dirty(conn)


func commit_route(conn_id: String, waypoints: Array) -> void:
	if _model == null:
		return
	_updating_model = true
	_model.update_connection(conn_id, {
		"route_3d": waypoints.duplicate(true),
		"route_locked": true,
	})
	_updating_model = false
	_last_anchors.erase(conn_id)
	var conn := _model.get_connection(conn_id)
	if not conn.is_empty():
		_rebuild_if_dirty(conn)


func get_instance(conn_id: String) -> MeshInstance3D:
	return _instances.get(conn_id, null)


func _remove_instance(conn_id: String) -> void:
	if not _instances.has(conn_id):
		return
	var inst: MeshInstance3D = _instances[conn_id]
	_instances.erase(conn_id)
	if is_instance_valid(inst):
		inst.queue_free()

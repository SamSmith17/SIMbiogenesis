class_name GraphPlaceholderHost
extends Node3D

const GROUP := "graph_3d_placeholder"
const ANCHOR_GROUP := "conduit_anchor"
const HORIZ_SCALE := 0.08
const DEFAULT_IBC_MESH_NAMES: Array[String] = ["Mesh36", "Mesh73"]

var _model: GraphModel = null
var _main: Node = null
var _battery_origin_3d: Vector3 = Vector3.ZERO
var _battery_graph_pos: Vector2 = Vector2.ZERO
var _battery_anchor_valid: bool = false

func setup(model: GraphModel, main_node: Node) -> void:
	_model = model
	_main = main_node
	if _model != null and _model.has_signal("changed"):
		if not _model.changed.is_connected(_on_model_changed):
			_model.changed.connect(_on_model_changed)
	_refresh_battery_frame()
	sync_all()

func teardown() -> void:
	if _model != null and _model.has_signal("changed"):
		if _model.changed.is_connected(_on_model_changed):
			_model.changed.disconnect(_on_model_changed)
	for child in get_children():
		if is_instance_valid(child):
			child.queue_free()
	_model = null
	_main = null

var _sync_queued: bool = false


func _on_model_changed(reason: String) -> void:
	if reason not in ["update_item", "deserialize", "add_item"]:
		return
	# Sim telemetry never moves a placeholder (position / binding / the
	# placeholder flag are player edits), and one deferred sync per frame is
	# enough however many writes queued it: the flow tick used to queue one
	# O(N) sync per update_item.
	if reason == "update_item" and _model != null and bool(_model.get("sim_writing")):
		return
	if _sync_queued:
		return
	_sync_queued = true
	call_deferred("_run_queued_sync")


func _run_queued_sync() -> void:
	_sync_queued = false
	sync_all()

func sync_all() -> void:
	if _model == null:
		return
	# Looked up by path, not by bare autoload name: this script is preloaded by
	# the graph view, and a bare `PerfMonitor` would break any headless
	# --script run that ever loads it (the autoload-compile trap).
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm != null:
		pm.call("begin", "gv_placeholder")
	_refresh_battery_frame()
	for item: Dictionary in _model.items:
		if bool((item.get("specs", {}) as Dictionary).get("graph_placeholder", false)):
			_ensure_placeholder(item)
	if pm != null:
		pm.call("end", "gv_placeholder")

func auto_link_battery_to_ibc() -> bool:
	if _model == null:
		return false
	var battery_id := _primary_battery_item_id()
	if battery_id.is_empty():
		return false
	var item := _model.get_item(battery_id)
	if item.is_empty():
		return false
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if not str(specs.get("scene_device_path", "")).is_empty():
		return true
	var tanks := find_ibc_tank_meshes(get_tree())
	if tanks.is_empty():
		return false
	var mesh: MeshInstance3D = tanks[0]
	var path := str(mesh.get_path())
	specs["scene_device_path"] = path
	specs["ibc_tank_link"] = true
	_model.update_item(battery_id, {"specs": specs, "device_path": path})
	return true

func spawn_placeholder_for_item(item_id: String) -> String:
	if _model == null or item_id.is_empty():
		return ""
	var item := _model.get_item(item_id)
	if item.is_empty():
		return ""
	auto_link_battery_to_ibc()
	_refresh_battery_frame()
	var node := _ensure_placeholder(item)
	if node == null:
		return ""
	var path := str(node.get_path())
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["graph_placeholder"] = true
	specs["scene_device_path"] = path
	specs.erase("ibc_tank_link")
	_model.update_item(item_id, {"specs": specs, "device_path": path})
	return path

static func find_ibc_tank_meshes(tree: SceneTree) -> Array:
	var out: Array = []
	if tree == null:
		return out
	var seen: Dictionary = {}
	for glow: Node in tree.get_nodes_in_group("power_consumers"):
		if glow.get_script() != null and str(glow.get_script().resource_path).ends_with("ibc_glow.gd"):
			var parent := glow.get_parent()
			if parent != null:
				_collect_ibc_meshes(parent, out, seen)
	if not out.is_empty():
		return out
	var main := tree.root.get_child(0) if tree.root.get_child_count() > 0 else null
	if main != null:
		_collect_ibc_meshes(main, out, seen)
	return out

static func _collect_ibc_meshes(node: Node, out: Array, seen: Dictionary) -> void:
	if node is MeshInstance3D:
		for nm: String in DEFAULT_IBC_MESH_NAMES:
			if node.name == nm:
				var key := str(node.get_path())
				if not seen.has(key):
					seen[key] = true
					out.append(node)
				break
	for child in node.get_children():
		_collect_ibc_meshes(child, out, seen)

func _primary_battery_item_id() -> String:
	if not _model.get_item("virtual_battery").is_empty():
		return "virtual_battery"
	for item: Dictionary in _model.items:
		var ty: String = str(item.get("type", ""))
		if ty in ["battery", "smartbattery"]:
			return str(item.get("id", ""))
	return ""

func _refresh_battery_frame() -> void:
	_battery_anchor_valid = false
	if _model == null:
		return
	var bid := _primary_battery_item_id()
	if bid.is_empty():
		return
	var bat := _model.get_item(bid)
	_battery_graph_pos = Vector2(float(bat.get("x", 0.0)), float(bat.get("y", 0.0)))
	var tree := get_tree()
	if tree == null:
		return
	var anchor := ConduitManager.anchor_global_for_item(bat, tree)
	if is_finite(anchor.x):
		_battery_origin_3d = anchor
		_battery_anchor_valid = true
	elif _main is Node3D:
		_battery_origin_3d = (_main as Node3D).global_position + Vector3(0.0, 1.0, 0.0)
		_battery_anchor_valid = true

func _graph_to_world_offset(item: Dictionary) -> Vector3:
	var gpos := Vector2(float(item.get("x", 0.0)), float(item.get("y", 0.0)))
	var delta := gpos - _battery_graph_pos
	return Vector3(delta.x * HORIZ_SCALE, 0.0, delta.y * HORIZ_SCALE)

func _ensure_placeholder(item: Dictionary) -> Node3D:
	var iid: String = str(item.get("id", ""))
	if iid.is_empty():
		return null
	var existing_path := str((item.get("specs", {}) as Dictionary).get("scene_device_path", ""))
	if not existing_path.is_empty():
		var tree := get_tree()
		if tree != null:
			var node: Node = tree.root.get_node_or_null(NodePath(existing_path))
			if node is Node3D and is_instance_valid(node):
				_reposition(node as Node3D, item)
				return node as Node3D
	var node_name := "Ph_%s" % iid.replace("/", "_")
	var ph: Node3D = get_node_or_null(node_name) as Node3D
	if ph == null:
		ph = _build_cube(node_name)
		add_child(ph)
	_reposition(ph, item)
	return ph

func _build_cube(node_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.add_to_group(GROUP)
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Cube"
	var box := BoxMesh.new()
	box.size = Vector3(0.55, 0.55, 0.55)
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.62, 0.95, 0.72)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.45
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)
	var anchor := Marker3D.new()
	anchor.name = "ConduitAnchor"
	anchor.position = Vector3(0.0, 0.28, 0.0)
	anchor.add_to_group(ANCHOR_GROUP)
	root.add_child(anchor)
	return root

func _reposition(node: Node3D, item: Dictionary) -> void:
	if not _battery_anchor_valid:
		_refresh_battery_frame()
	var offset := _graph_to_world_offset(item)
	node.global_position = _battery_origin_3d + offset

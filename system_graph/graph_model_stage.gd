class_name GraphModelStage
extends Node

## The 3D ring's models. While Layout ▾ → Show models is on, each node that
## has a catalog model is that mesh, standing where the card would, under the
## same camera the flat projection uses (GraphSchema3D.rotate + persp). The
## canvas draws this viewport's texture under the ports, so a wire still
## lands on the node. The viewport is clear: the canvas keeps its own
## background, shells and wires.

var _vp: SubViewport = null
var _cam: Camera3D = null
var _holder: Node3D = null
var _live := false
## id → {model: String, node: Node3D}
var _nodes: Dictionary = {}


## Vertical field of view (degrees) that makes one graph pixel at the focal
## plane `dist` land on `zoom` screen pixels. KEEP_HEIGHT, so the horizontal
## axis uses the same pixels per unit.
static func fov_y_deg(viewport_h: float, dist: float, zoom: float) -> float:
	var focal := maxf(dist * zoom, 0.001)
	return rad_to_deg(2.0 * atan((maxf(viewport_h, 1.0) * 0.5) / focal))


## Graph point → Godot: graph +y is down the screen, Godot +y is up.
static func to_godot(p: Vector3) -> Vector3:
	return Vector3(p.x, -p.y, p.z)


## Eye, in Godot, `dist` toward the viewer along the view axis.
static func eye_godot(yaw: float, pitch: float, dist: float) -> Vector3:
	return to_godot(GraphSchema3D.unrotate(Vector3(0.0, 0.0, dist), yaw, pitch))


## Camera up (Godot), so graph +y still reads down the screen.
static func up_godot(yaw: float, pitch: float) -> Vector3:
	return to_godot(GraphSchema3D.unrotate(Vector3(0.0, -1.0, 0.0), yaw, pitch))


func set_live(on: bool) -> void:
	_live = on
	if _vp != null:
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


func has_model(item_id: String) -> bool:
	return _nodes.has(item_id)


## Pose the camera and the meshes. Returns the viewport texture while live.
func present(view: GraphView3D, items: Array, model_of: Callable,
		canvas_size: Vector2, zoom: float) -> Texture2D:
	if not _live or view == null or not view.active():
		set_live(false)
		return null
	_ensure()
	if canvas_size.x < 2.0 or canvas_size.y < 2.0:
		return null
	var sz := Vector2i(maxi(int(canvas_size.x), 2), maxi(int(canvas_size.y), 2))
	if _vp.size != sz:
		_vp.size = sz
	_pose_camera(view, zoom, float(sz.y))
	_sync_nodes(view, items, model_of)
	return _vp.get_texture()


func _ensure() -> void:
	if _vp != null and is_instance_valid(_vp):
		return
	_vp = SubViewport.new()
	_vp.name = "GraphModelStageVP"
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.disable_3d = false
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.handle_input_locally = false
	add_child(_vp)
	var world := Node3D.new()
	world.name = "Stage"
	_vp.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.72)
	env.ambient_light_energy = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, 38, 0)
	key.light_energy = 1.2
	key.shadow_enabled = false
	world.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, -135, 0)
	fill.light_energy = 0.35
	world.add_child(fill)
	_holder = Node3D.new()
	_holder.name = "Models"
	world.add_child(_holder)
	_cam = Camera3D.new()
	_cam.current = true
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.near = 1.0
	world.add_child(_cam)
	if _live:
		_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _pose_camera(view: GraphView3D, zoom: float, viewport_h: float) -> void:
	var dist := view.camera_dist()
	_cam.fov = fov_y_deg(viewport_h, dist, zoom)
	_cam.far = dist + view.camera_dist() * 8.0
	var eye := eye_godot(view.yaw, view.pitch, dist)
	var up := up_godot(view.yaw, view.pitch)
	if up.length_squared() < 1e-8:
		up = Vector3.UP
	_cam.position = eye
	_cam.look_at(Vector3.ZERO, up.normalized())


func _sync_nodes(view: GraphView3D, items: Array, model_of: Callable) -> void:
	var want := {}
	for it in items:
		var d: Dictionary = it
		var iid := str(d.get("id", ""))
		if iid.is_empty() or not view.has(iid):
			continue
		var pair: Array = model_of.call(d)
		var mid := str(pair[0]) if pair.size() > 0 else ""
		if mid.is_empty():
			continue
		want[iid] = pair
	var gone: Array = []
	for iid in _nodes:
		if not want.has(iid) or str((_nodes[iid] as Dictionary).get("model", "")) != str((want[iid] as Array)[0]):
			gone.append(iid)
	for iid2 in gone:
		var old: Dictionary = _nodes[iid2]
		var n: Node = old.get("node")
		if n != null and is_instance_valid(n):
			n.free()
		_nodes.erase(iid2)
	for iid3 in want:
		var rec: Array = want[iid3]
		var mid3 := str(rec[0])
		var extras: Dictionary = {}
		if rec.size() > 1 and rec[1] is Dictionary:
			extras = rec[1]
		if not _nodes.has(iid3):
			var inst := ModelCatalog.instantiate(mid3, extras)
			if inst == null:
				continue
			inst.name = "M_" + iid3
			_holder.add_child(inst)
			_nodes[iid3] = {"model": mid3, "node": inst}
		var held: Dictionary = _nodes[iid3]
		_place(view, iid3, held["node"] as Node3D, mid3, d_of(items, iid3))


static func d_of(items: Array, iid: String) -> Dictionary:
	for it in items:
		var d: Dictionary = it
		if str(d.get("id", "")) == iid:
			return d
	return {}


func _place(view: GraphView3D, iid: String, inst: Node3D, model_id: String, item: Dictionary) -> void:
	if inst == null:
		return
	var g := view.node_pos(iid)
	var s := ModelCatalog.resolved_scale(model_id, 1.0)
	var metrics := ModelCatalog.mesh_metrics(model_id)
	var unit_h := float(metrics.get("unit_height", 1.0))
	var longest := maxf(unit_h, maxf(float(metrics.get("width", 1.0)), float(metrics.get("depth", 1.0)))) * s
	var card := Vector2(float(item.get("width", 120.0)), float(item.get("height", 90.0)))
	var target := minf(card.x, card.y) * 0.92
	var fit := target / maxf(longest, 0.01)
	var sc := s * fit
	inst.scale = Vector3.ONE * sc
	var mid_y := (float(metrics.get("foot_local_y", 0.0)) + unit_h * 0.5) * sc
	inst.position = Vector3(g.x, -g.y - mid_y, g.z)
	var flat := Vector2(g.x, g.z)
	if flat.length_squared() > 4.0:
		inst.rotation = Vector3(0.0, atan2(flat.x, flat.y), 0.0)
	else:
		inst.rotation = Vector3.ZERO

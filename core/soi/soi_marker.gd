extends Interactable

## Map-pin marker for the Sphere of Influence origin.

const PIN_HEIGHT_M := 2.4
const HEAD_RADIUS_M := 0.35

var _head: MeshInstance3D = null


func _ready() -> void:
	super._ready()
	prompt = "Snowglobe  ·  drag to move SoI origin"
	max_distance = 12.0
	_build_pin()
	_build_collision()
	call_deferred("sync_position")


func sync_position() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc == null:
		return
	global_position = svc.world_center()


func interact(_player: Node) -> void:
	_open()


func _open() -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc == null:
		return
	if svc.has_method("open_from_marker"):
		svc.open_from_marker()
	elif svc.has_method("enter_snowglobe"):
		svc.enter_snowglobe()
	else:
		svc.open_panel()


## World-drag contract (see gameplay/grab_controller.gd). The SoI pin can be
## Ctrl/Alt-dragged like a placed prop; wherever it is dropped becomes the new
## SoI map origin. GrabController drives the drag and calls these.
func world_drag_commit(world_pos: Vector3) -> void:
	var svc := get_node_or_null("/root/SoiService")
	if svc != null and svc.has_method("set_center_xz"):
		svc.set_center_xz(world_pos.x, world_pos.z)
	sync_position()


## A no-drag click on the pin keeps its original action: open the Snowglobe.
func world_drag_click() -> void:
	_open()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null or _head == null:
		return
	var to_cam := cam.global_position - _head.global_position
	to_cam.y = 0.0
	if to_cam.length_squared() > 0.001:
		_head.look_at(_head.global_position + to_cam.normalized(), Vector3.UP)


func _build_pin() -> void:
	var body := MeshInstance3D.new()
	body.name = "PinBody"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.06
	cone.bottom_radius = 0.14
	cone.height = PIN_HEIGHT_M
	cone.radial_segments = 12
	body.mesh = cone
	body.position = Vector3(0.0, PIN_HEIGHT_M * 0.5, 0.0)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.85, 0.22, 0.18)
	body_mat.roughness = 0.65
	body.material_override = body_mat
	add_child(body)

	_head = MeshInstance3D.new()
	_head.name = "PinHead"
	var sphere := SphereMesh.new()
	sphere.radius = HEAD_RADIUS_M
	sphere.height = HEAD_RADIUS_M * 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	_head.mesh = sphere
	_head.position = Vector3(0.0, PIN_HEIGHT_M + HEAD_RADIUS_M * 0.85, 0.0)
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = UITheme.C_PRIMARY
	head_mat.emission_enabled = true
	head_mat.emission = UITheme.C_PRIMARY * 0.35
	head_mat.roughness = 0.35
	_head.material_override = head_mat
	add_child(_head)
	set_process(true)


func _build_collision() -> void:
	var area := Area3D.new()
	area.name = "InteractArea"
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.55
	cyl.height = PIN_HEIGHT_M + HEAD_RADIUS_M * 2.0
	shape.shape = cyl
	shape.position = Vector3(0.0, (PIN_HEIGHT_M + HEAD_RADIUS_M) * 0.5, 0.0)
	area.add_child(shape)
	add_child(area)

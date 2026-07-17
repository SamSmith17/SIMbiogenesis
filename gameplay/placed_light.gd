class_name PlacedLight
extends Interactable

## In-game placed light. IK spheres are visible in light-place mode (J) or when
## focused under Ctrl/Alt select; otherwise only the Light3D illuminates.
## Pick collider is an Area3D so lights never block the player capsule.

var light_id: String = ""
var light_type: String = "omni"
var light_color: Color = Color.WHITE
var light_energy: float = 1.0
var light_range: float = 10.0
var spot_angle: float = 45.0
var shadow_enabled: bool = true
## 0 = always on; else Light3D disables when camera is farther than this (m).
var lod_m: float = 0.0

var _light_node: Light3D = null
var _gizmo: MeshInstance3D = null
var _aim_ring: MeshInstance3D = null
var _gizmo_mat: StandardMaterial3D = null
var _aim_mat: StandardMaterial3D = null
var _body: Area3D = null
var _outline_mat: StandardMaterial3D = null
var _focus_active_local := false


func _ready() -> void:
	super._ready()
	prompt = "Edit Light (click)"
	max_distance = 2000.0

	_gizmo = MeshInstance3D.new()
	_gizmo.name = "LightGizmo"
	var sphere := SphereMesh.new()
	sphere.radius = 0.28
	sphere.height = 0.56
	sphere.radial_segments = 20
	sphere.rings = 12
	_gizmo.mesh = sphere
	_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_gizmo_mat = StandardMaterial3D.new()
	_gizmo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_gizmo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_gizmo_mat.albedo_color = Color(1, 1, 1, 0.72)
	_gizmo_mat.emission_enabled = true
	_gizmo_mat.emission = Color(1, 1, 1)
	_gizmo_mat.emission_energy_multiplier = 1.4
	_gizmo.material_override = _gizmo_mat
	add_child(_gizmo)

	_aim_ring = MeshInstance3D.new()
	_aim_ring.name = "LightAimRing"
	var ring := SphereMesh.new()
	ring.radius = 0.48
	ring.height = 0.96
	ring.radial_segments = 16
	ring.rings = 8
	_aim_ring.mesh = ring
	_aim_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_aim_mat = StandardMaterial3D.new()
	_aim_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_aim_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_aim_mat.albedo_color = Color(1.0, 0.85, 0.2, 0.28)
	_aim_mat.emission_enabled = true
	_aim_mat.emission = Color(1.0, 0.85, 0.2)
	_aim_mat.emission_energy_multiplier = 0.6
	_aim_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_aim_ring.material_override = _aim_mat
	add_child(_aim_ring)

	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.albedo_color = Color(1.0, 0.6, 0.0)
	_outline_mat.grow = true
	_outline_mat.grow_amount = 0.08
	var next_pass := StandardMaterial3D.new()
	next_pass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	next_pass.albedo_color = Color.WHITE
	_outline_mat.next_pass = next_pass

	# Area3D: ray-pickable, never a solid wall in front of the player.
	_body = Area3D.new()
	_body.name = "LightBody"
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.monitoring = false
	_body.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.2, 1.2, 1.2)
	shape.shape = box
	_body.add_child(shape)
	add_child(_body)

	update_light_node()
	_sync_gizmo_visibility()


func update_light_node() -> void:
	if _light_node != null:
		_light_node.queue_free()
		_light_node = null

	if light_type == "omni":
		_light_node = OmniLight3D.new()
		(_light_node as OmniLight3D).omni_range = light_range
	else:
		_light_node = SpotLight3D.new()
		(_light_node as SpotLight3D).spot_angle = spot_angle
		(_light_node as SpotLight3D).spot_range = light_range

	_light_node.light_color = light_color
	_light_node.light_energy = light_energy
	_light_node.shadow_enabled = shadow_enabled
	add_child(_light_node)

	if _gizmo_mat != null:
		_gizmo_mat.albedo_color = Color(light_color.r, light_color.g, light_color.b, 0.78)
		_gizmo_mat.emission = light_color
		_gizmo_mat.emission_energy_multiplier = 1.2 + light_energy * 0.15
	if _aim_mat != null:
		_aim_mat.albedo_color = Color(light_color.r, light_color.g, light_color.b, 0.28)
		_aim_mat.emission = light_color


func _process(_delta: float) -> void:
	_sync_gizmo_visibility()
	_apply_lod()


func _sync_gizmo_visibility() -> void:
	var place_mode := PlacedLightService.is_placement_active()
	var selecting := Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_CTRL)
	var show := place_mode or selecting or _focus_active_local
	if _gizmo != null:
		_gizmo.visible = show
	if _aim_ring != null:
		_aim_ring.visible = show
	if _body != null:
		_body.collision_layer = 1 if show else 0


func _apply_lod() -> void:
	if _light_node == null:
		return
	if lod_m <= 0.0:
		_light_node.visible = true
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if cam == null:
		_light_node.visible = true
		return
	var dist := cam.global_position.distance_to(global_position)
	_light_node.visible = dist <= lod_m


func get_world_pick_aabb() -> AABB:
	var half := Vector3(0.6, 0.6, 0.6)
	return AABB(global_position - half, half * 2.0)


func on_focus_enter(_player: Node) -> void:
	_focus_active_local = true
	if _gizmo != null:
		_gizmo.visible = true
		_gizmo.material_overlay = _outline_mat
	if _aim_ring != null:
		_aim_ring.visible = true
	if _body != null:
		_body.collision_layer = 1


func on_focus_exit(_player: Node) -> void:
	_focus_active_local = false
	if _gizmo != null:
		_gizmo.material_overlay = null
	_sync_gizmo_visibility()


func interact(_player: Node) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var main := tree.current_scene
	if main == null:
		return
	if main.has_method("_ensure_placed_light_modal"):
		main.call("_ensure_placed_light_modal")
	var modal := main.get_node_or_null("UILayer/PlacedLightModal")
	if modal == null:
		modal = main.find_child("PlacedLightModal", true, false)
	if modal != null and modal.has_method("open"):
		modal.call("open", light_id)

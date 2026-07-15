class_name PlacedLight
extends Interactable

## In-game placed light.

var light_id: String = ""
var light_type: String = "omni"
var light_color: Color = Color.WHITE
var light_energy: float = 1.0
var light_range: float = 10.0
var spot_angle: float = 45.0

var _light_node: Light3D = null
var _gizmo: MeshInstance3D = null
var _gizmo_mat: StandardMaterial3D = null
var _body: StaticBody3D = null
var _outline_mat: StandardMaterial3D = null

func _ready() -> void:
	super._ready()
	prompt = "Edit Light (click)"
	max_distance = 2000.0 # Like PlacedProp
	
	# Gizmo mesh
	_gizmo = MeshInstance3D.new()
	var sphere = SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	_gizmo.mesh = sphere
	_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_gizmo_mat = StandardMaterial3D.new()
	_gizmo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_gizmo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_gizmo_mat.albedo_color = Color(1, 1, 1, 0.5)
	_gizmo.material_override = _gizmo_mat
	add_child(_gizmo)
	
	# Selection outline
	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.albedo_color = Color(1.0, 0.6, 0.0)
	_outline_mat.grow = true
	_outline_mat.grow_amount = 0.05
	var next_pass = StandardMaterial3D.new()
	next_pass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	next_pass.albedo_color = Color.WHITE
	_outline_mat.next_pass = next_pass
	
	# Physics body for raycast
	_body = StaticBody3D.new()
	_body.collision_layer = 1
	var shape = CollisionShape3D.new()
	var box = BoxShape3D.new()
	box.size = Vector3(1.2, 1.2, 1.2)
	shape.shape = box
	_body.add_child(shape)
	add_child(_body)
	
	update_light_node()

func update_light_node() -> void:
	if _light_node != null:
		_light_node.queue_free()
		_light_node = null
		
	if light_type == "omni":
		_light_node = OmniLight3D.new()
	else:
		_light_node = SpotLight3D.new()
		(_light_node as SpotLight3D).spot_angle = spot_angle
		
	_light_node.light_color = light_color
	_light_node.light_energy = light_energy
	_light_node.omni_range = light_range if light_type == "omni" else 0.0
	if light_type == "spot":
		(_light_node as SpotLight3D).spot_range = light_range
	_light_node.shadow_enabled = true
	add_child(_light_node)
	
	if _gizmo_mat != null:
		_gizmo_mat.albedo_color = light_color
		_gizmo_mat.albedo_color.a = 0.8

func _process(_delta: float) -> void:
	var alt_held = Input.is_key_pressed(KEY_ALT)
	if _gizmo != null:
		_gizmo.visible = alt_held
	if _body != null:
		_body.collision_layer = 1 if alt_held else 0 # Only raycastable when gizmo is visible

func on_focus_enter(_player: Node) -> void:
	if _gizmo != null:
		_gizmo.material_overlay = _outline_mat

func on_focus_exit(_player: Node) -> void:
	if _gizmo != null:
		_gizmo.material_overlay = null

func interact(_player: Node) -> void:
	var tree = get_tree()
	if tree == null: return
	var main = tree.current_scene
	if main == null or not main.has_node("UI"): return
	var ui = main.get_node("UI")
	if ui.has_node("PlacedLightModal"):
		var modal = ui.get_node("PlacedLightModal")
		if modal.has_method("open"):
			modal.call("open", light_id)

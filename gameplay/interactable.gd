class_name Interactable
extends Node3D

## Base for center-screen crosshair interaction.
## Add to group "interactables" and provide a CollisionShape3D descendant.

@export var prompt: String = "Interact"
@export var action: String = "interact"
@export var max_distance: float = 8.0

var _focus_active: bool = false
var _highlight_mesh: MeshInstance3D = null
var _highlight_mat: StandardMaterial3D = null


func _ready() -> void:
	add_to_group("interactables")
	_highlight_mat = StandardMaterial3D.new()
	_highlight_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_highlight_mat.albedo_color = Color(0.2, 0.95, 0.35, 0.45)
	_highlight_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_highlight_mat.cull_mode = BaseMaterial3D.CULL_DISABLED


func can_interact(_player: Node) -> bool:
	return true


func get_focus_mesh() -> MeshInstance3D:
	for c in get_children():
		if c is MeshInstance3D:
			return c as MeshInstance3D
	return null


func on_focus_enter(_player: Node) -> void:
	_focus_active = true
	_apply_highlight(true)


func on_focus_exit(_player: Node) -> void:
	_focus_active = false
	_apply_highlight(false)


func interact(player: Node) -> void:
	pass


func get_prompt_text() -> String:
	return prompt


func get_action_name() -> String:
	return action


func _apply_highlight(on: bool) -> void:
	var mesh := get_focus_mesh()
	if mesh == null:
		return
	if on:
		if _highlight_mesh == null:
			_highlight_mesh = MeshInstance3D.new()
			_highlight_mesh.name = "InteractHighlight"
			mesh.add_child(_highlight_mesh)
		_highlight_mesh.mesh = mesh.mesh
		_highlight_mesh.material_override = _highlight_mat
		_highlight_mesh.visible = true
	elif _highlight_mesh != null:
		_highlight_mesh.visible = false

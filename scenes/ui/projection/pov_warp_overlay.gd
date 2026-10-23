extends Control

## POV warp (Z): the player's own view, re-rendered from a mirror camera and
## corner-pinned in four quads (ProjectionWarp) for projecting the first-person
## view onto a physical surface (the StarShade projector). Z toggles it (Main);
## F10 calibrates, F8 resets, Enter saves while it is up.

@export var source_camera_path: NodePath
@export var start_active: bool = false
@export var config_path: String = "user://pov_projection_warp.cfg"

@onready var source_preview: SubViewportContainer = $SourcePreview
@onready var source_subviewport: SubViewport = $SourcePreview/SourceSubViewport
@onready var source_camera: Camera3D = $SourcePreview/SourceSubViewport/SourceCamera3D

const HUD_CLAIM := "pov_warp"

var warp: ProjectionWarp = null
var _source_camera_ref: Camera3D = null


func _ready() -> void:
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The mirror camera renders the world a second time: only while warped.
	if source_subviewport != null:
		source_subviewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if source_preview != null:
		source_preview.modulate.a = 0.0
	warp = ProjectionWarp.new()
	warp.name = "ProjectionWarp"
	warp.config_path = config_path
	warp.quad_count = 4
	warp.toggle_key = false   # Z, through Main.toggle_warp_mode
	warp.title = "POV projection mapping"
	warp.key_gate = func() -> bool: return warp != null and warp.active
	add_child(warp)
	warp.setup(source_subviewport.get_texture() if source_subviewport != null else null)
	warp.warp_changed.connect(_on_warp_changed)
	_resolve_source_camera()
	if start_active:
		toggle_warp_mode()
	else:
		visible = false


func _exit_tree() -> void:
	HudLayout.release(HUD_CLAIM)


func _process(_delta: float) -> void:
	if warp == null or not warp.active:
		return
	_sync_source_camera()


func toggle_warp_mode() -> void:
	if warp == null:
		return
	warp.toggle_active()


func _on_warp_changed(on: bool) -> void:
	visible = on
	# A projector output: nothing of the first-person HUD over it.
	if on:
		HudLayout.claim(HUD_CLAIM, {"hide": ["*"]})
	else:
		HudLayout.release(HUD_CLAIM)
	if source_subviewport != null:
		source_subviewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		_resolve_source_camera()


func _resolve_source_camera() -> void:
	_source_camera_ref = null
	if source_camera_path.is_empty():
		return
	var candidate := get_node_or_null(source_camera_path)
	if candidate is Camera3D:
		_source_camera_ref = candidate as Camera3D
		if source_subviewport != null:
			source_subviewport.world_3d = _source_camera_ref.get_world_3d()


func _sync_source_camera() -> void:
	if _source_camera_ref == null or not is_instance_valid(_source_camera_ref) or source_camera == null:
		return
	source_camera.global_transform = _source_camera_ref.global_transform
	source_camera.fov = _source_camera_ref.fov
	source_camera.near = _source_camera_ref.near
	source_camera.far = _source_camera_ref.far
	if source_subviewport != null and source_subviewport.world_3d != _source_camera_ref.get_world_3d():
		source_subviewport.world_3d = _source_camera_ref.get_world_3d()

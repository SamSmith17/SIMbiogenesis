extends Control

@export var source_camera_path: NodePath
@export var start_active: bool = false
@export var config_path: String = "user://pov_projection_warp.cfg"

const QUADRANT_KEYS: Array[String] = ["TL", "TR", "BL", "BR"]
const HANDLE_HALF_SIZE: float = 6.0
const WARP_CONFIG_VERSION: int = 1

@onready var source_preview: SubViewportContainer = $SourcePreview
@onready var source_subviewport: SubViewport = $SourcePreview/SourceSubViewport
@onready var source_camera: Camera3D = $SourcePreview/SourceSubViewport/SourceCamera3D
@onready var calibration_overlay: Control = $CalibrationOverlay
@onready var warp_output_layer: Node2D = $WarpOutputLayer
@onready var instructions_label: Label = $CalibrationOverlay/InstructionsLabel

@onready var warp_quadrant_tl: Polygon2D = $WarpOutputLayer/WarpQuadrantTL
@onready var warp_quadrant_tr: Polygon2D = $WarpOutputLayer/WarpQuadrantTR
@onready var warp_quadrant_bl: Polygon2D = $WarpOutputLayer/WarpQuadrantBL
@onready var warp_quadrant_br: Polygon2D = $WarpOutputLayer/WarpQuadrantBR

@onready var handle_tl_0: ColorRect = $CalibrationOverlay/HandleTL_0
@onready var handle_tl_1: ColorRect = $CalibrationOverlay/HandleTL_1
@onready var handle_tl_2: ColorRect = $CalibrationOverlay/HandleTL_2
@onready var handle_tl_3: ColorRect = $CalibrationOverlay/HandleTL_3
@onready var handle_tr_0: ColorRect = $CalibrationOverlay/HandleTR_0
@onready var handle_tr_1: ColorRect = $CalibrationOverlay/HandleTR_1
@onready var handle_tr_2: ColorRect = $CalibrationOverlay/HandleTR_2
@onready var handle_tr_3: ColorRect = $CalibrationOverlay/HandleTR_3
@onready var handle_bl_0: ColorRect = $CalibrationOverlay/HandleBL_0
@onready var handle_bl_1: ColorRect = $CalibrationOverlay/HandleBL_1
@onready var handle_bl_2: ColorRect = $CalibrationOverlay/HandleBL_2
@onready var handle_bl_3: ColorRect = $CalibrationOverlay/HandleBL_3
@onready var handle_br_0: ColorRect = $CalibrationOverlay/HandleBR_0
@onready var handle_br_1: ColorRect = $CalibrationOverlay/HandleBR_1
@onready var handle_br_2: ColorRect = $CalibrationOverlay/HandleBR_2
@onready var handle_br_3: ColorRect = $CalibrationOverlay/HandleBR_3

var _source_camera_ref: Camera3D = null
var _warp_polygons: Dictionary = {}
var _warp_default_points: Dictionary = {}
var _warp_default_uv: Dictionary = {}
var _warp_points: Dictionary = {}
var _handle_nodes: Dictionary = {}
var _dragging_handle: bool = false
var _drag_quadrant: String = ""
var _drag_corner: int = -1
var _has_saved_config: bool = false

var warp_active: bool = false
var calibration_mode_enabled: bool = false


func _ready() -> void:
	anchors_preset = PRESET_FULL_RECT
	warp_active = start_active
	calibration_mode_enabled = false

	_setup_warp_nodes()
	_connect_handle_signals()
	_resolve_source_camera()
	_load_warp_config()
	_apply_overlay_visibility()

	if get_viewport() != null and not get_viewport().size_changed.is_connected(_on_viewport_size_changed):
		get_viewport().size_changed.connect(_on_viewport_size_changed)


func _process(_delta: float) -> void:
	if not warp_active:
		return
	_sync_source_camera()


func _input(event: InputEvent) -> void:
	if not warp_active:
		return

	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo:
			if key_event.keycode == KEY_F10 or key_event.physical_keycode == KEY_F10:
				calibration_mode_enabled = not calibration_mode_enabled
				_apply_overlay_visibility()
				get_viewport().set_input_as_handled()
				return
			if calibration_mode_enabled and (key_event.keycode == KEY_ENTER or key_event.physical_keycode == KEY_ENTER):
				_save_warp_config()
				calibration_mode_enabled = false
				_apply_overlay_visibility()
				get_viewport().set_input_as_handled()
				return

	if not calibration_mode_enabled:
		return

	if event is InputEventMouseMotion and _dragging_handle:
		var local_mouse: Vector2 = get_local_mouse_position()
		local_mouse.x = clampf(local_mouse.x, 0.0, size.x)
		local_mouse.y = clampf(local_mouse.y, 0.0, size.y)
		_set_warp_corner(_drag_quadrant, _drag_corner, local_mouse)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and not mouse_event.pressed and _dragging_handle:
			_dragging_handle = false
			_drag_quadrant = ""
			_drag_corner = -1
			get_viewport().set_input_as_handled()


func toggle_warp_mode() -> void:
	warp_active = not warp_active
	if warp_active:
		if not _has_saved_config:
			calibration_mode_enabled = true
		_resolve_source_camera()
	else:
		calibration_mode_enabled = false
		_dragging_handle = false
		_drag_quadrant = ""
		_drag_corner = -1
	_apply_overlay_visibility()


func _on_viewport_size_changed() -> void:
	if source_subviewport != null:
		source_subviewport.size = Vector2i(get_viewport().get_visible_rect().size)
	if not _has_saved_config:
		_reset_warp_to_defaults(false)


func _resolve_source_camera() -> void:
	if source_camera_path.is_empty():
		_source_camera_ref = null
		return
	var candidate := get_node_or_null(source_camera_path)
	if candidate is Camera3D:
		_source_camera_ref = candidate as Camera3D
		if source_subviewport != null:
			source_subviewport.world_3d = _source_camera_ref.get_world_3d()
	else:
		_source_camera_ref = null


func _sync_source_camera() -> void:
	if _source_camera_ref == null or source_camera == null:
		return
	source_camera.global_transform = _source_camera_ref.global_transform
	source_camera.fov = _source_camera_ref.fov
	source_camera.near = _source_camera_ref.near
	source_camera.far = _source_camera_ref.far
	if source_subviewport != null and source_subviewport.world_3d != _source_camera_ref.get_world_3d():
		source_subviewport.world_3d = _source_camera_ref.get_world_3d()


func _setup_warp_nodes() -> void:
	_warp_polygons = {
		"TL": warp_quadrant_tl,
		"TR": warp_quadrant_tr,
		"BL": warp_quadrant_bl,
		"BR": warp_quadrant_br
	}
	_handle_nodes = {
		"TL": [handle_tl_0, handle_tl_1, handle_tl_2, handle_tl_3],
		"TR": [handle_tr_0, handle_tr_1, handle_tr_2, handle_tr_3],
		"BL": [handle_bl_0, handle_bl_1, handle_bl_2, handle_bl_3],
		"BR": [handle_br_0, handle_br_1, handle_br_2, handle_br_3]
	}

	var canvas_size: Vector2 = _get_canvas_size()
	if source_subviewport != null:
		source_subviewport.size = Vector2i(canvas_size)

	var half_w := canvas_size.x * 0.5
	var half_h := canvas_size.y * 0.5
	var default_points := {
		"TL": [Vector2(0.0, 0.0), Vector2(half_w, 0.0), Vector2(half_w, half_h), Vector2(0.0, half_h)],
		"TR": [Vector2(half_w, 0.0), Vector2(canvas_size.x, 0.0), Vector2(canvas_size.x, half_h), Vector2(half_w, half_h)],
		"BL": [Vector2(0.0, half_h), Vector2(half_w, half_h), Vector2(half_w, canvas_size.y), Vector2(0.0, canvas_size.y)],
		"BR": [Vector2(half_w, half_h), Vector2(canvas_size.x, half_h), Vector2(canvas_size.x, canvas_size.y), Vector2(half_w, canvas_size.y)]
	}

	var source_texture: Texture2D = source_subviewport.get_texture()
	for key in QUADRANT_KEYS:
		var poly: Polygon2D = _warp_polygons[key]
		poly.texture = source_texture
		poly.polygon = PackedVector2Array(default_points[key])
		poly.uv = PackedVector2Array(default_points[key])
		_warp_default_points[key] = (default_points[key] as Array).duplicate(true)
		_warp_default_uv[key] = (default_points[key] as Array).duplicate(true)
		_warp_points[key] = (default_points[key] as Array).duplicate(true)
		_apply_polygon_points(key)

	_update_handle_positions()


func _connect_handle_signals() -> void:
	for key in QUADRANT_KEYS:
		var handles: Array = _handle_nodes[key]
		for i in range(handles.size()):
			var handle: ColorRect = handles[i]
			if handle == null:
				continue
			handle.mouse_filter = Control.MOUSE_FILTER_STOP
			handle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			if not handle.gui_input.is_connected(_on_warp_handle_gui_input):
				handle.gui_input.connect(_on_warp_handle_gui_input.bind(key, i))


func _on_warp_handle_gui_input(event: InputEvent, quadrant_key: String, corner_index: int) -> void:
	if not calibration_mode_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_dragging_handle = true
			_drag_quadrant = quadrant_key
			_drag_corner = corner_index
			get_viewport().set_input_as_handled()


func _set_warp_corner(quadrant_key: String, corner_index: int, point: Vector2) -> void:
	var points: Array = _warp_points[quadrant_key]
	points[corner_index] = point
	_warp_points[quadrant_key] = points
	_apply_polygon_points(quadrant_key)
	_update_handle_positions()


func _apply_polygon_points(quadrant_key: String) -> void:
	var poly: Polygon2D = _warp_polygons[quadrant_key]
	var points: Array = _warp_points[quadrant_key]
	poly.polygon = PackedVector2Array(points)
	poly.uv = PackedVector2Array(_warp_default_uv[quadrant_key])


func _update_handle_positions() -> void:
	for key in QUADRANT_KEYS:
		var points: Array = _warp_points[key]
		var handles: Array = _handle_nodes[key]
		for i in range(min(points.size(), handles.size())):
			var handle: ColorRect = handles[i]
			var p: Vector2 = points[i]
			handle.position = p - Vector2(HANDLE_HALF_SIZE, HANDLE_HALF_SIZE)


func _reset_warp_to_defaults(save_after_reset: bool = true) -> void:
	for key in QUADRANT_KEYS:
		_warp_points[key] = _warp_default_points[key].duplicate(true)
		_apply_polygon_points(key)
	_update_handle_positions()
	if save_after_reset:
		_save_warp_config()


func _load_warp_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(config_path) != OK:
		_has_saved_config = false
		return
	if int(cfg.get_value("warp", "version", 0)) != WARP_CONFIG_VERSION:
		_has_saved_config = false
		return

	var loaded_any := false
	for key in QUADRANT_KEYS:
		var packed: PackedVector2Array = cfg.get_value("warp", key, PackedVector2Array())
		if packed.size() != 4:
			continue
		_warp_points[key] = Array(packed)
		_apply_polygon_points(key)
		loaded_any = true

	_has_saved_config = loaded_any
	_update_handle_positions()


func _save_warp_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("warp", "version", WARP_CONFIG_VERSION)
	for key in QUADRANT_KEYS:
		cfg.set_value("warp", key, PackedVector2Array(_warp_points[key]))
	cfg.save(config_path)
	_has_saved_config = true


func _apply_overlay_visibility() -> void:
	visible = warp_active
	if source_preview != null:
		source_preview.visible = true
		source_preview.modulate.a = 0.0
	if warp_output_layer != null:
		warp_output_layer.visible = warp_active
	if calibration_overlay != null:
		calibration_overlay.visible = warp_active and calibration_mode_enabled
	if instructions_label != null:
		instructions_label.text = "POV WARP CALIBRATION  |  Drag handles  |  F10 set calibration  |  Enter save"


func _get_canvas_size() -> Vector2:
	var rect := get_viewport().get_visible_rect()
	if rect.size.x > 0.0 and rect.size.y > 0.0:
		return rect.size
	return Vector2(1920.0, 1080.0)

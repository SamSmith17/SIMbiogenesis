class_name PlacedLightWaypoint
extends Interactable

## One pin (IK sphere) of a J-placed string light.
##
## First person: Ctrl/Alt + click selects the string and opens the Light Studio
## on it; Ctrl/Alt + drag re-pins this waypoint onto whatever surface the
## crosshair is on (GrabController's relocatable-marker contract) and opens the
## Studio on release. Inside the Studio the dock does the same with the mouse.
## Visible only while the Studio is open, while Ctrl/Alt is held, or while its
## string is selected — the pick body is on layer 1 only while visible.

const CORE_R := 0.09
const HALO_R := 0.2

static var _core_mat: StandardMaterial3D = null
static var _halo_mat: StandardMaterial3D = null
static var _hot_mat: StandardMaterial3D = null

var string_id: String = ""
var index: int = 0
var _core: MeshInstance3D = null
var _halo: MeshInstance3D = null
var _body: Area3D = null
var _focus_local := false
var _string_selected := false
var _hot := false


func _ready() -> void:
	super._ready()
	prompt = "String light (click) · drag to move pin"
	max_distance = 2000.0
	top_level = true
	_ensure_mats()
	_core = _sphere(CORE_R, _core_mat)
	_halo = _sphere(HALO_R, _halo_mat)
	_body = Area3D.new()
	_body.name = "PinBody"
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.monitoring = false
	_body.monitorable = false
	var shape := CollisionShape3D.new()
	var s := SphereShape3D.new()
	s.radius = 0.35
	shape.shape = s
	_body.add_child(shape)
	add_child(_body)
	_sync()


func _sphere(r: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = r
	m.height = r * 2.0
	m.radial_segments = 12
	m.rings = 6
	mi.mesh = m
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


static func _ensure_mats() -> void:
	if _core_mat != null:
		return
	_core_mat = _mat(Color(1.0, 0.25, 0.2, 0.9))
	_halo_mat = _mat(Color(1.0, 0.35, 0.25, 0.22))
	_hot_mat = _mat(Color(1.0, 0.85, 0.2, 0.95))


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.no_depth_test = true
	m.render_priority = 11
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func setup(owner_id: String, idx: int, pos: Vector3) -> void:
	string_id = owner_id
	index = idx
	global_position = pos


func set_string_selected(on: bool) -> void:
	_string_selected = on
	_sync()


## The waypoint the Studio is hovering / dragging.
func set_hot(on: bool) -> void:
	_hot = on
	if _core != null:
		_core.material_override = _hot_mat if on else _core_mat


func _process(_delta: float) -> void:
	_sync()


func _sync() -> void:
	var show := PlacedLightService.gizmos_visible() or _string_selected or _focus_local
	visible = show
	if _body != null:
		_body.collision_layer = 1 if show else 0
	if _core != null:
		_core.material_override = _hot_mat if (_hot or _focus_local) else _core_mat


func get_world_pick_aabb() -> AABB:
	var h := Vector3.ONE * 0.35
	return AABB(global_position - h, h * 2.0)


func on_focus_enter(_player: Node) -> void:
	_focus_local = true
	_sync()


func on_focus_exit(_player: Node) -> void:
	_focus_local = false
	_sync()


func interact(_player: Node) -> void:
	PlacedLightService.open_studio_on(get_tree().current_scene, [string_id])


func world_drag_aim(camera: Camera3D) -> Variant:
	var aim := ConduitSurfaceAim.pick(get_tree().current_scene, camera,
		[_body.get_rid()] if _body != null else [])
	if not bool(aim.get("valid", false)):
		return null
	return aim["position"]


## First person (J closed): Ctrl/Alt + drag moves the WHOLE string — every
## pin keeps its place relative to the others — and Ctrl/Alt + Shift + drag
## duplicates it and moves the copy. (Inside the Studio a plain drag moves one
## pin; that is the dock's job.) Nothing opens on release: every nudge used to
## drop the player back into the dock. A click without a drag opens it.
## The FIRST aim point of the drag: offsets are measured from it, so a lamp
## hanging 3 m up keeps its height and nothing jumps on the first frame.
var _drag_from: Variant = null
var _drag_id := ""


func world_drag_begin() -> void:
	_drag_from = null
	_drag_id = PlacedLightService.begin_drag(get_tree().current_scene, string_id,
		ModifierKeys.shift())


func world_drag_preview(pos: Vector3) -> void:
	if _drag_id.is_empty():
		return
	if _drag_from == null:
		_drag_from = pos
	PlacedLightService.drag_to(get_tree().current_scene, pos - (_drag_from as Vector3))


func world_drag_commit(pos: Vector3) -> void:
	world_drag_preview(pos)
	PlacedLightService.end_drag(get_tree().current_scene)
	_drag_id = ""


func world_drag_cancel() -> void:
	PlacedLightService.cancel_drag(get_tree().current_scene)
	_drag_id = ""


func world_drag_click() -> void:
	PlacedLightService.open_studio_on(get_tree().current_scene, [string_id])


func sync_position() -> void:
	PlacedLightService.refresh_light(get_tree().current_scene, string_id)

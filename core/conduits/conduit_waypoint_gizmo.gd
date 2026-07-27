class_name ConduitWaypointGizmo
extends Node3D

## Glowing IK spheres for hang/pipe pin-edit control points.
## Hover sphere tracks the crosshair∩wire hit; pin spheres mark route_3d.
##
## IMPORTANT: never add_child inside the sphere factory and then reparent —
## Godot 4 rejects add_child when a parent already exists, which used to leak
## thousands of pin nodes under this gizmo every focus frame.

const HOVER_CORE_R := 0.12
const HOVER_HALO_R := 0.18
const PIN_CORE_R := 0.08
const PIN_HALO_R := 0.12
const VIS_RANGE_M := 80.0
## Low-poly spheres — these are UI cues, not hero meshes.
const CORE_SEGMENTS := 10
const CORE_RINGS := 6
const HALO_SEGMENTS := 8
const HALO_RINGS := 4

var _hover: Node3D = null
var _pins_root: Node3D = null
var _drag: Node3D = null
## Shared materials (one alloc each) — never recreate per pin/frame.
var _mat_hover_core: StandardMaterial3D = null
var _mat_hover_halo: StandardMaterial3D = null
var _mat_drag_core: StandardMaterial3D = null
var _mat_drag_halo: StandardMaterial3D = null
var _mat_pin_core: StandardMaterial3D = null
var _mat_pin_halo: StandardMaterial3D = null
var _pin_pool: Array = []  ## reusable Pin roots under _pins_root


func _ready() -> void:
	name = "ConduitWaypointGizmo"
	_ensure_materials()
	_hover = _make_dual_sphere("Hover", HOVER_CORE_R, HOVER_HALO_R,
		_mat_hover_core, _mat_hover_halo)
	_drag = _make_dual_sphere("Drag", HOVER_CORE_R * 1.15, HOVER_HALO_R * 1.15,
		_mat_drag_core, _mat_drag_halo)
	add_child(_hover)
	add_child(_drag)
	_pins_root = Node3D.new()
	_pins_root.name = "Pins"
	add_child(_pins_root)
	_hover.visible = false
	_drag.visible = false


func clear_all() -> void:
	set_hover(Vector3.ZERO, false)
	set_drag(Vector3.ZERO, false)
	set_pins(PackedVector3Array())


func set_hover(pos: Vector3, on: bool) -> void:
	if _hover == null:
		return
	_hover.visible = on
	if on:
		_place_world(_hover, pos)


func set_drag(pos: Vector3, on: bool) -> void:
	if _drag == null:
		return
	_drag.visible = on
	if on:
		_place_world(_drag, pos)
		if _hover != null:
			_hover.visible = false


func set_pins(positions: PackedVector3Array) -> void:
	if _pins_root == null:
		return
	_ensure_materials()
	var need := positions.size()
	# Grow pool only — never free/recreate every frame (was the FPS death spiral).
	while _pin_pool.size() < need:
		var pin := _make_dual_sphere("Pin%d" % _pin_pool.size(), PIN_CORE_R, PIN_HALO_R,
			_mat_pin_core, _mat_pin_halo)
		_pins_root.add_child(pin)
		_pin_pool.append(pin)
	# Cap runaway pools — keep a small reserve above current need.
	var keep := maxi(need, 0)
	var max_keep := maxi(keep + 4, 8)
	while _pin_pool.size() > max_keep:
		var extra: Node = _pin_pool.pop_back()
		if extra != null and is_instance_valid(extra):
			_pins_root.remove_child(extra)
			extra.free()
	for i: int in range(_pin_pool.size()):
		var n: Node3D = _pin_pool[i] as Node3D
		if n == null or not is_instance_valid(n):
			continue
		if i < need:
			n.visible = true
			_place_world(n, positions[i])
		else:
			n.visible = false


## Local placement avoids one-frame global_position flashes when the parent
## transform isn't settled (camera look / focus flicker).
func _place_world(n: Node3D, world: Vector3) -> void:
	if not is_inside_tree() or not is_finite(world.x):
		n.position = world
		return
	n.position = to_local(world)


func _ensure_materials() -> void:
	if _mat_pin_core != null:
		return
	_mat_hover_core = _mat(Color(0.95, 0.18, 0.14, 0.9), 2.2)
	_mat_hover_halo = _mat(Color(1.0, 0.25, 0.18, 0.22), 1.0)
	_mat_hover_halo.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_drag_core = _mat(Color(1.0, 0.35, 0.12, 0.95), 2.4)
	_mat_drag_halo = _mat(Color(1.0, 0.4, 0.15, 0.26), 1.1)
	_mat_drag_halo.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_pin_core = _mat(Color(0.92, 0.16, 0.12, 0.85), 1.5)
	_mat_pin_halo = _mat(Color(1.0, 0.22, 0.14, 0.2), 0.8)
	_mat_pin_halo.cull_mode = BaseMaterial3D.CULL_DISABLED


## Build an unparented dual-sphere root (caller must add_child once).
func _make_dual_sphere(node_name: String, core_r: float, halo_r: float,
		core_mat: Material, halo_mat: Material) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var core := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = core_r
	sm.height = core_r * 2.0
	sm.radial_segments = CORE_SEGMENTS
	sm.rings = CORE_RINGS
	core.mesh = sm
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.visibility_range_end = VIS_RANGE_M
	core.material_override = core_mat
	root.add_child(core)
	var halo := MeshInstance3D.new()
	var om := SphereMesh.new()
	om.radius = halo_r
	om.height = halo_r * 2.0
	om.radial_segments = HALO_SEGMENTS
	om.rings = HALO_RINGS
	halo.mesh = om
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.visibility_range_end = VIS_RANGE_M
	halo.material_override = halo_mat
	root.add_child(halo)
	return root


func _mat(col: Color, emission_energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = Color(col.r, col.g, col.b)
	mat.emission_energy_multiplier = emission_energy
	return mat

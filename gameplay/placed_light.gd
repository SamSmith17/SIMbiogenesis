class_name PlacedLight
extends Interactable

## An omni or spot light placed with the J Light Studio.
##
## The IK sphere is visible while the Studio is open, while Ctrl/Alt is held,
## or while the light is focused/selected; otherwise only the Light3D shows.
## The pick body is an Area3D on layer 1 ONLY while visible, so a light never
## blocks the player capsule.
##
## Ctrl/Alt + click opens the Studio on this light; Ctrl/Alt + drag moves it
## (GrabController's relocatable-marker contract: world_drag_aim /
## world_drag_commit / world_drag_click), and the Studio opens on release.
##
## Fade by distance uses Godot's own Light3D distance fade — the old LOD hid the
## light outright past a threshold, so it popped on and off as you walked.

var light_id: String = ""
var kind: String = "omni"
var record: Dictionary = {}
var fields: Dictionary = {}

var _light_node: Light3D = null
var _gizmo: MeshInstance3D = null
var _gizmo_mat: StandardMaterial3D = null
## The lamp itself ("Show bulb"): a small glowing, depth-tested sphere that is
## part of the scene — unlike the IK gizmo, which is an editing handle.
var _bulb: MeshInstance3D = null
var _bulb_mat: StandardMaterial3D = null
var _body: Area3D = null
var _outline_mat: StandardMaterial3D = null
var _focus_local := false
var _selected := false
var _lit := true
var _poll := 0.0
var _main: Node = null
var _base_color := Color.WHITE


func _ready() -> void:
	super._ready()
	prompt = "Edit light (click) · drag to move"
	max_distance = 2000.0
	top_level = true

	_gizmo = MeshInstance3D.new()
	_gizmo.name = "LightGizmo"
	var sphere := SphereMesh.new()
	sphere.radius = 0.22
	sphere.height = 0.44
	sphere.radial_segments = 16
	sphere.rings = 8
	_gizmo.mesh = sphere
	_gizmo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_gizmo_mat = StandardMaterial3D.new()
	_gizmo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_gizmo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_gizmo_mat.no_depth_test = true
	_gizmo_mat.render_priority = 10
	_gizmo.material_override = _gizmo_mat
	add_child(_gizmo)

	_bulb = MeshInstance3D.new()
	_bulb.name = "Bulb"
	var bs := SphereMesh.new()
	bs.radius = 0.07
	bs.height = 0.14
	bs.radial_segments = 12
	bs.rings = 6
	_bulb.mesh = bs
	_bulb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bulb_mat = StandardMaterial3D.new()
	_bulb_mat.emission_enabled = true
	_bulb_mat.roughness = 0.2
	_bulb.material_override = _bulb_mat
	add_child(_bulb)

	_outline_mat = StandardMaterial3D.new()
	_outline_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_outline_mat.albedo_color = Color(1.0, 0.6, 0.0)
	_outline_mat.grow = true
	_outline_mat.grow_amount = 0.06
	_outline_mat.no_depth_test = true
	_outline_mat.cull_mode = BaseMaterial3D.CULL_FRONT

	_body = Area3D.new()
	_body.name = "LightBody"
	_body.collision_layer = 0
	_body.collision_mask = 0
	_body.monitoring = false
	_body.monitorable = false
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.9, 0.9, 0.9)
	shape.shape = box
	_body.add_child(shape)
	add_child(_body)
	_rebuild_light_node()
	_apply_fields()
	_sync_gizmo()


## rec = the layer record, res = its resolved style fields.
func configure(rec: Dictionary, res: Dictionary) -> void:
	record = rec
	fields = res
	light_id = str(rec.get("id", ""))
	var new_kind := str(rec.get("kind", "omni"))
	if not new_kind in ["omni", "spot", "mover"]:
		new_kind = "omni"
	global_position = Vector3(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)), float(rec.get("z", 0.0)))
	rotation_degrees = Vector3(float(rec.get("pitch", 0.0)), float(rec.get("yaw", 0.0)), float(rec.get("roll", 0.0)))
	if new_kind != kind or _light_node == null:
		kind = new_kind
		if is_inside_tree():
			_rebuild_light_node()
	if is_inside_tree():
		_apply_fields()
		_update_lit()


func set_selected(on: bool) -> void:
	_selected = on
	_sync_gizmo()


func _rebuild_light_node() -> void:
	if _light_node != null:
		_light_node.queue_free()
		_light_node = null
	if kind == "spot" or kind == "mover":
		_light_node = SpotLight3D.new()
	else:
		_light_node = OmniLight3D.new()
	_light_node.name = "Light"
	add_child(_light_node)


func _apply_fields() -> void:
	if _light_node == null:
		return
	_base_color = PlacedLightPower.parse_color(str(fields.get("color", "ffffff")))
	var rng := maxf(float(fields.get("range", 10.0)), 0.1)
	if _light_node is SpotLight3D:
		var s := _light_node as SpotLight3D
		s.spot_range = rng
		s.spot_angle = clampf(float(fields.get("spot_angle", 35.0)), 1.0, 89.0)
		s.spot_attenuation = float(fields.get("attenuation", 1.0))
		s.spot_angle_attenuation = clampf(float(fields.get("spot_softness", 1.0)), 0.05, 8.0)
	else:
		var o := _light_node as OmniLight3D
		o.omni_range = rng
		o.omni_attenuation = float(fields.get("attenuation", 1.0))
	_light_node.shadow_enabled = bool(fields.get("shadow_enabled", true))
	var fade := float(fields.get("fade_m", 0.0))
	_light_node.distance_fade_enabled = fade > 0.0
	if fade > 0.0:
		_light_node.distance_fade_begin = fade * 0.75
		_light_node.distance_fade_length = fade * 0.25
		_light_node.distance_fade_shadow = fade * 0.5
	_light_node.light_color = _base_color
	_light_node.light_energy = float(fields.get("energy", 1.0)) if _lit else 0.0
	if _gizmo_mat != null:
		_gizmo_mat.albedo_color = Color(_base_color.r, _base_color.g, _base_color.b, 0.8)
	if _bulb != null:
		_bulb.visible = bool(fields.get("show_body", false))
		_bulb_mat.albedo_color = _base_color
		_bulb_mat.emission = _base_color
		_bulb_mat.emission_energy_multiplier = 3.0 * float(fields.get("energy", 1.0)) if _lit else 0.0


func _process(delta: float) -> void:
	_sync_gizmo()
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.5
		_update_lit()
	var fx := str(fields.get("effect", "solid"))
	if fx != "solid" and _lit and _light_node != null:
		_light_node.light_color = LedEffects.color_at(fields, 0, 1, fx_now(), _base_color)
		if _bulb_mat != null and _bulb.visible:
			_bulb_mat.emission = _light_node.light_color


func _update_lit() -> void:
	if _main == null or not is_instance_valid(_main):
		_main = get_tree().current_scene if is_inside_tree() else null
	var lit := PlacedLightPower.is_lit(_main, record, fields)
	if lit != _lit:
		_lit = lit
		_apply_fields()


## The shared effect clock (PlacedLightClock) — every J light reads the same
## one, so copies chase and sweep in step.
func fx_now() -> float:
	return PlacedLightClock.now(_main, bool(fields.get("fx_pause_with_sim", false)))


func _sim_paused() -> bool:
	return _main != null and "time_scale" in _main and absf(float(_main.get("time_scale"))) < 1e-9


func _sync_gizmo() -> void:
	var show := PlacedLightService.gizmos_visible() or _focus_local or _selected
	if _gizmo != null:
		_gizmo.visible = show
		_gizmo.material_overlay = _outline_mat if (_selected or _focus_local) else null
	if _body != null:
		_body.collision_layer = 1 if show else 0


func get_world_pick_aabb() -> AABB:
	var half := Vector3(0.45, 0.45, 0.45)
	return AABB(global_position - half, half * 2.0)


func on_focus_enter(_player: Node) -> void:
	_focus_local = true
	_sync_gizmo()


func on_focus_exit(_player: Node) -> void:
	_focus_local = false
	_sync_gizmo()


func interact(_player: Node) -> void:
	PlacedLightService.open_studio_on(get_tree().current_scene, [light_id])


# -- GrabController relocatable-marker contract ------------------------------

## Where the light should follow the crosshair while Ctrl-dragged: onto any
## surface (props, walls, buildings), not just the terrain.
func world_drag_aim(camera: Camera3D) -> Variant:
	var aim := ConduitSurfaceAim.pick(get_tree().current_scene, camera, _own_rids())
	if not bool(aim.get("valid", false)):
		return null
	# Sit a little off the surface so a wall-mounted light is not inside the wall.
	return (aim["position"] as Vector3) + (aim["normal"] as Vector3) * 0.15


## First person (J closed): Ctrl/Alt + drag moves it onto whatever surface the
## crosshair is on; Ctrl/Alt + Shift + drag duplicates it and moves the copy.
## A click without a drag opens the Studio on it.
## The FIRST aim point of the drag: offsets are measured from it, so a lamp
## hanging 3 m up keeps its height and nothing jumps on the first frame.
var _drag_from: Variant = null
var _drag_id := ""


func world_drag_begin() -> void:
	_drag_from = null
	_drag_id = PlacedLightService.begin_drag(get_tree().current_scene, light_id,
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
	PlacedLightService.open_studio_on(get_tree().current_scene, [light_id])


func sync_position() -> void:
	configure(record, fields)


func _own_rids() -> Array:
	return [_body.get_rid()] if _body != null else []


# -- Graph load interface (GraphAcLoad reads this through the item's
# scene_device_path once the player has pressed "Add to graph") -------------

func get_current_power() -> float:
	if str(record.get("graph_item_id", "")).is_empty() or not _lit:
		return 0.0
	return float(record.get("graph_watts", 0.0))

class_name NpcAvatar
extends Node3D

## 3D silhouette stand-in for one simulated NPC (Phase B of the population
## system): a stylized flat-shaded figure — head + torso + legs — tinted with
## the agent's stable pastel, no collider/gravity (kinematic ground snap by
## the host, the RemotePlayerAvatar pattern). Walking adds a gentle bob and
## leg swing; sleeping lays the figure down. Swapping in a rigged FBX later
## only touches this class — the host API (setup/apply_state) is stable.

const HEIGHT_M := 1.7
const HEAD_R := 0.12
const TORSO_H := 0.62
const LEG_H := 0.78
const BOB_HZ := 1.8

## Crosshair-pick radius around the figure's mid-height (software ray test in
## InteractionFocus — no collider, so NPCs never shove the player).
const PICK_RADIUS_M := 0.55
const PICK_CENTER_Y := 1.0

var agent_id: String = ""
var display_name: String = ""
var status_text: String = ""
var morale_label: String = ""

var _root: Node3D = null            # animated sub-root (bob/lie-down)
var _leg_l: Node3D = null
var _leg_r: Node3D = null
var _mat: StandardMaterial3D = null
var _tag: Label3D = null
var _phase := 0.0
var _moving := false
var _lying := false


func setup(p_agent_id: String, color: Color, p_name: String = "") -> void:
	agent_id = p_agent_id
	display_name = p_name if not p_name.is_empty() else p_agent_id
	name = "Npc_%s" % p_agent_id.validate_node_name()
	_ensure_visuals()
	_mat.albedo_color = Color(color.r * 0.55, color.g * 0.55, color.b * 0.55)
	_phase = fposmod(float(hash(p_agent_id) % 1000) * 0.13, TAU)
	if _tag != null:
		_tag.text = display_name


## World point the crosshair ray is tested against.
func pick_center() -> Vector3:
	return global_position + Vector3(0.0, PICK_CENTER_Y, 0.0)


## Nametag is off by default (50 floating labels is noise) — the crosshair
## turns it on for whoever the player is looking at.
func set_tag_visible(on: bool) -> void:
	if _tag != null:
		_tag.visible = on


## pos = ground point (feet); yaw = facing; moving/activity drive animation.
func apply_state(pos: Vector3, yaw: float, moving: bool, activity: String) -> void:
	global_position = pos
	rotation = Vector3(0.0, yaw, 0.0)
	_moving = moving
	_lying = activity == "sleep"


func _ready() -> void:
	_ensure_visuals()
	add_to_group("npc_avatars")


func _process(delta: float) -> void:
	if _root == null:
		return
	if _lying:
		_root.rotation.x = lerpf(_root.rotation.x, -PI * 0.5, minf(delta * 6.0, 1.0))
		_root.position.y = lerpf(_root.position.y, 0.25, minf(delta * 6.0, 1.0))
		return
	_root.rotation.x = lerpf(_root.rotation.x, 0.0, minf(delta * 6.0, 1.0))
	if _moving:
		_phase += delta * TAU * BOB_HZ
		_root.position.y = absf(sin(_phase)) * 0.05
		var swing := sin(_phase) * 0.45
		if _leg_l != null:
			_leg_l.rotation.x = swing
		if _leg_r != null:
			_leg_r.rotation.x = -swing
	else:
		_root.position.y = lerpf(_root.position.y, 0.0, minf(delta * 8.0, 1.0))
		if _leg_l != null:
			_leg_l.rotation.x = lerpf(_leg_l.rotation.x, 0.0, minf(delta * 8.0, 1.0))
		if _leg_r != null:
			_leg_r.rotation.x = lerpf(_leg_r.rotation.x, 0.0, minf(delta * 8.0, 1.0))


func _ensure_visuals() -> void:
	if _root != null:
		return
	_root = Node3D.new()
	_root.name = "Figure"
	add_child(_root)
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_mat.roughness = 0.9
	_mat.metallic = 0.0
	_mat.albedo_color = Color(0.2, 0.2, 0.24)

	var torso := MeshInstance3D.new()
	torso.name = "Torso"
	var cap := CapsuleMesh.new()
	cap.radius = 0.16
	cap.height = TORSO_H
	torso.mesh = cap
	torso.position = Vector3(0.0, LEG_H + TORSO_H * 0.5 - 0.1, 0.0)
	torso.material_override = _mat
	_root.add_child(torso)

	_tag = Label3D.new()
	_tag.name = "NameTag"
	_tag.text = display_name
	_tag.font_size = 40
	_tag.pixel_size = 0.0075
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.position = Vector3(0.0, HEIGHT_M + 0.28, 0.0)
	_tag.modulate = Color(1, 1, 1, 0.97)
	_tag.outline_modulate = Color(0.02, 0.04, 0.09, 0.9)
	_tag.outline_size = 8
	_tag.no_depth_test = true
	_tag.visible = false  # only for the person the crosshair is on
	add_child(_tag)

	var head := MeshInstance3D.new()
	head.name = "Head"
	var sph := SphereMesh.new()
	sph.radius = HEAD_R
	sph.height = HEAD_R * 2.0
	head.mesh = sph
	head.position = Vector3(0.0, HEIGHT_M - HEAD_R, 0.0)
	head.material_override = _mat
	_root.add_child(head)

	# Legs pivot at the hip (capsule hangs half its height below the pivot)
	# so rotating the hip node swings the whole leg while walking.
	for side in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.name = "LegL" if side < 0.0 else "LegR"
		hip.position = Vector3(0.09 * side, LEG_H, 0.0)
		var shin := MeshInstance3D.new()
		var leg := CapsuleMesh.new()
		leg.radius = 0.07
		leg.height = LEG_H
		shin.mesh = leg
		shin.material_override = _mat
		shin.position = Vector3(0.0, -LEG_H * 0.5, 0.0)
		hip.add_child(shin)
		_root.add_child(hip)
		if side < 0.0:
			_leg_l = hip
		else:
			_leg_r = hip

class_name RemotePlayerAvatar
extends Node3D

## Lightweight co-presence stand-in for a remote peer (no camera / controller).

const BODY_HEIGHT_M := 1.7
const BODY_RADIUS_M := 0.28

var peer_id: int = 0
var display_name: String = "Player"

var _mesh: MeshInstance3D = null
var _label: Label3D = null
var _bubble: Label3D = null
var _mat: StandardMaterial3D = null
var _bubble_timer: SceneTreeTimer = null


func setup(p_peer_id: int, p_name: String) -> void:
	peer_id = p_peer_id
	display_name = p_name if not p_name.is_empty() else ("Player %d" % p_peer_id)
	name = "Remote_%d" % p_peer_id
	_ensure_visuals()
	_apply_color(color_for_peer(peer_id))
	set_display_name(display_name)


func set_display_name(p_name: String) -> void:
	display_name = p_name if not p_name.is_empty() else ("Player %d" % peer_id)
	if _label != null:
		_label.text = display_name


func apply_pose(pos: Vector3, yaw: float) -> void:
	global_position = pos
	rotation = Vector3(0.0, yaw, 0.0)


static func color_for_peer(p_peer_id: int) -> Color:
	# Stable pastel from peer id (avoid pure black/white).
	var h := fposmod(float(p_peer_id) * 0.61803398875, 1.0)
	return Color.from_hsv(h, 0.55, 0.92)


func _ensure_visuals() -> void:
	if _mesh != null:
		return
	_mesh = MeshInstance3D.new()
	_mesh.name = "Body"
	var cap := CapsuleMesh.new()
	cap.radius = BODY_RADIUS_M
	cap.height = BODY_HEIGHT_M
	_mesh.mesh = cap
	_mesh.position = Vector3(0.0, BODY_HEIGHT_M * 0.5, 0.0)
	_mat = StandardMaterial3D.new()
	_mat.roughness = 0.55
	_mat.metallic = 0.05
	_mesh.material_override = _mat
	add_child(_mesh)

	# Simple facing cue (nose).
	var nose := MeshInstance3D.new()
	nose.name = "Nose"
	var box := BoxMesh.new()
	box.size = Vector3(0.12, 0.12, 0.22)
	nose.mesh = box
	nose.position = Vector3(0.0, BODY_HEIGHT_M * 0.75, -BODY_RADIUS_M - 0.05)
	var nose_mat := StandardMaterial3D.new()
	nose_mat.albedo_color = Color(0.15, 0.15, 0.18)
	nose.material_override = nose_mat
	add_child(nose)

	_label = Label3D.new()
	_label.name = "NameTag"
	_label.text = display_name
	_label.font_size = 48
	_label.pixel_size = 0.012
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position = Vector3(0.0, BODY_HEIGHT_M + 0.35, 0.0)
	_label.modulate = Color(1, 1, 1, 0.95)
	_label.outline_modulate = Color(0, 0, 0, 0.85)
	_label.outline_size = 8
	add_child(_label)

	_bubble = Label3D.new()
	_bubble.name = "ChatBubble"
	_bubble.visible = false
	_bubble.font_size = 40
	_bubble.pixel_size = 0.011
	_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble.position = Vector3(0.0, BODY_HEIGHT_M + 0.85, 0.0)
	_bubble.modulate = Color(1, 1, 1, 0.98)
	_bubble.outline_modulate = Color(0.05, 0.08, 0.14, 0.9)
	_bubble.outline_size = 10
	_bubble.width = 280.0
	_bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_bubble)


## Show a short proximity chat bubble above the avatar.
func show_chat_bubble(text: String, duration_s: float = 4.0) -> void:
	_ensure_visuals()
	if _bubble == null:
		return
	var t := text.strip_edges()
	if t.is_empty():
		return
	if t.length() > 80:
		t = t.substr(0, 77) + "…"
	_bubble.text = t
	_bubble.visible = true
	# Cancel prior hide by bumping a generation via timer callback check.
	var token := Time.get_ticks_msec()
	_bubble.set_meta("bubble_token", token)
	var tree := get_tree()
	if tree == null:
		return
	var timer := tree.create_timer(duration_s)
	timer.timeout.connect(func() -> void:
		if not is_instance_valid(self) or _bubble == null:
			return
		if int(_bubble.get_meta("bubble_token", 0)) == token:
			_bubble.visible = false)


func _apply_color(c: Color) -> void:
	if _mat == null:
		return
	_mat.albedo_color = c

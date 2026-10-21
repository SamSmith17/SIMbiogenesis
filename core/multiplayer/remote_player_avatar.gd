class_name RemotePlayerAvatar
extends Node3D

## Another player in the world: the same silhouette figure the NPCs are drawn
## with (NpcSimpleFigure — black body, rim in that player's own outline
## colour), posed from what their body is doing on their machine (walking,
## running, in the air, driving, on the EUC, using a tool).
##
## It used to be a coloured capsule snapped to each 12 Hz presence packet, so
## it jittered and nobody could tell which way it faced. Now:
## - positions are INTERPOLATED: the figure is drawn INTERP_DELAY_S behind the
##   newest packet, between the two packets that bracket that moment, and
##   extrapolated briefly when a packet is late;
## - the name tag is x-ray and constant-size with the distance under it, so a
##   player behind a hill or 400 m away can still be found (MultiplayerHUD
##   adds an edge arrow when they are off screen).

const BODY_HEIGHT_M := 1.7
const INTERP_DELAY_S := 0.12
const MAX_EXTRAPOLATE_S := 0.3
const TELEPORT_M := 25.0
const MAX_SNAPS := 10
const MODES: Array = ["idle", "walk", "run", "air", "drive", "euc", "sit"]

var peer_id: int = 0
var display_name: String = "Player"
var rim: Color = Color(0.55, 0.62, 0.78)

var _figure: NpcSimpleFigure = null
var _label: Label3D = null
var _bubble: Label3D = null
var _ring: MeshInstance3D = null
var _ring_mat: StandardMaterial3D = null
var _snaps: Array = []        # [{t, pos, yaw, body}]
var _yaw := 0.0
var _label_acc := 0.0
var _has_pose := false


func setup(p_peer_id: int, p_name: String) -> void:
	peer_id = p_peer_id
	display_name = p_name if not p_name.is_empty() else ("Player %d" % p_peer_id)
	name = "Remote_%d" % p_peer_id
	rim = color_for_peer(peer_id)
	_ensure_visuals()
	set_display_name(display_name)


func set_display_name(p_name: String) -> void:
	display_name = p_name if not p_name.is_empty() else ("Player %d" % peer_id)
	_label_acc = 1.0


## The player's own outline colour (sent in their presence) — they pick it in
## Settings → Player, and it is how they look on their own screen too.
func set_rim(c: Color) -> void:
	if c.is_equal_approx(rim):
		return
	rim = c
	if _figure != null:
		_figure.set_tint(c)
	if _ring_mat != null:
		_ring_mat.albedo_color = Color(c.r, c.g, c.b, 0.55)
	if _label != null:
		_label.modulate = c.lightened(0.35)


## A presence packet: where the body stood, which way it faced, what it did.
func push_snapshot(pos: Vector3, yaw: float, body: Dictionary = {}) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	if not _snaps.is_empty():
		var last: Dictionary = _snaps[_snaps.size() - 1]
		if (last["pos"] as Vector3).distance_to(pos) > TELEPORT_M:
			_snaps.clear()   # a teleport / respawn: no glide across the map
	_snaps.append({"t": t, "pos": pos, "yaw": yaw, "body": body})
	while _snaps.size() > MAX_SNAPS:
		_snaps.pop_front()
	if not _has_pose:
		_has_pose = true
		global_position = pos
		_yaw = yaw
		rotation = Vector3(0.0, yaw, 0.0)


## Kept for callers that only know a position (older code paths, tests).
func apply_pose(pos: Vector3, yaw: float) -> void:
	push_snapshot(pos, yaw)


static func color_for_peer(p_peer_id: int) -> Color:
	# Stable pastel from peer id (avoid pure black/white).
	var h := fposmod(float(p_peer_id) * 0.61803398875, 1.0)
	return Color.from_hsv(h, 0.55, 0.92)


## The drawn position (what other code — markers, Locate — should point at).
func drawn_position() -> Vector3:
	return global_position


func _process(delta: float) -> void:
	if _snaps.is_empty() or _figure == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	var rt := now - INTERP_DELAY_S
	var a: Dictionary = _snaps[0]
	var b: Dictionary = _snaps[_snaps.size() - 1]
	var pos: Vector3
	var yaw: float
	var body: Dictionary = b["body"]
	if rt <= float(a["t"]):
		pos = a["pos"]
		yaw = float(a["yaw"])
	elif rt >= float(b["t"]):
		# Late packet: carry on along the last motion for a moment.
		pos = b["pos"]
		yaw = float(b["yaw"])
		if _snaps.size() >= 2:
			var p: Dictionary = _snaps[_snaps.size() - 2]
			var span := maxf(float(b["t"]) - float(p["t"]), 0.001)
			var v := ((b["pos"] as Vector3) - (p["pos"] as Vector3)) / span
			pos += v * minf(rt - float(b["t"]), MAX_EXTRAPOLATE_S)
	else:
		for i in range(_snaps.size() - 1):
			var s0: Dictionary = _snaps[i]
			var s1: Dictionary = _snaps[i + 1]
			if rt >= float(s0["t"]) and rt <= float(s1["t"]):
				var f := (rt - float(s0["t"])) / maxf(float(s1["t"]) - float(s0["t"]), 0.001)
				pos = (s0["pos"] as Vector3).lerp(s1["pos"] as Vector3, f)
				yaw = lerp_angle(float(s0["yaw"]), float(s1["yaw"]), f)
				body = s1["body"]
				break
	global_position = pos
	_yaw = lerp_angle(_yaw, yaw, 1.0 - exp(-18.0 * delta))
	rotation = Vector3(0.0, _yaw, 0.0)
	_pose_body(body, delta)
	_label_acc += delta
	if _label_acc >= 0.25:
		_label_acc = 0.0
		_refresh_label()


func _pose_body(body: Dictionary, dt: float) -> void:
	var st := {
		"mode": str(body.get("mode", "idle")),
		"rate": float(body.get("rate", 1.0)),
		"vy": float(body.get("vy", 0.0)),
		"steer": float(body.get("steer", 0.0)),
		"aim": bool(body.get("aim", false)),
	}
	var seat: Variant = body.get("seat", Vector3.ZERO)
	_figure.position = seat if seat is Vector3 else Vector3.ZERO
	_figure.pose_player(st, maxf(dt, 1e-4))


func _refresh_label() -> void:
	if _label == null:
		return
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	var d := cam.global_position.distance_to(global_position) if cam != null else 0.0
	_label.text = display_name if d < 12.0 else "%s\n%s" % [display_name, UiText.num(d, "m", 2)]


## Network body packet <-> dictionary (compact: 8 floats).
static func pack_body(body: Dictionary) -> PackedFloat32Array:
	var seat: Vector3 = body.get("seat", Vector3.ZERO) if body.get("seat") is Vector3 else Vector3.ZERO
	return PackedFloat32Array([
		float(maxi(MODES.find(str(body.get("mode", "idle"))), 0)),
		float(body.get("rate", 1.0)), float(body.get("vy", 0.0)),
		float(body.get("steer", 0.0)), 1.0 if bool(body.get("aim", false)) else 0.0,
		seat.x, seat.y, seat.z,
	])


static func unpack_body(a: PackedFloat32Array) -> Dictionary:
	if a.size() < 8:
		return {}
	var mi := clampi(int(a[0]), 0, MODES.size() - 1)
	return {"mode": MODES[mi], "rate": clampf(a[1], 0.0, 4.0), "vy": clampf(a[2], -60.0, 60.0),
		"steer": clampf(a[3], -1.0, 1.0), "aim": a[4] > 0.5,
		"seat": Vector3(clampf(a[5], -2.0, 2.0), clampf(a[6], -2.0, 3.0), clampf(a[7], -3.0, 3.0))}


func _ensure_visuals() -> void:
	if _figure != null:
		return
	_figure = NpcSimpleFigure.new()
	_figure.name = "Body"
	_figure.setup("mp_peer_%d" % peer_id, rim)
	# Built facing +Z like every stick figure; the player's forward is -Z.
	_figure.rotation.y = PI
	add_child(_figure)

	# A soft ring at the feet in their colour: which figure is a PLAYER, from
	# above as well as from the side.
	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.42
	torus.outer_radius = 0.5
	torus.rings = 24
	torus.ring_segments = 6
	_ring.mesh = torus
	_ring.scale = Vector3(1.0, 0.08, 1.0)
	_ring.position = Vector3(0.0, 0.04, 0.0)
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.albedo_color = Color(rim.r, rim.g, rim.b, 0.55)
	_ring.material_override = _ring_mat
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ring)

	_label = Label3D.new()
	_label.name = "NameTag"
	_label.text = display_name
	_label.font_size = 30
	_label.pixel_size = 0.0011
	_label.fixed_size = true
	_label.no_depth_test = true
	_label.render_priority = 10
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.position = Vector3(0.0, BODY_HEIGHT_M + 0.18, 0.0)
	_label.modulate = rim.lightened(0.35)
	_label.outline_modulate = Color(0, 0, 0, 0.9)
	_label.outline_size = 10
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_label)

	_bubble = Label3D.new()
	_bubble.name = "ChatBubble"
	_bubble.visible = false
	_bubble.font_size = 28
	_bubble.pixel_size = 0.0011
	_bubble.fixed_size = true
	_bubble.no_depth_test = true
	_bubble.render_priority = 11
	_bubble.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_bubble.position = Vector3(0.0, BODY_HEIGHT_M + 0.5, 0.0)
	_bubble.modulate = Color(1, 1, 1, 0.98)
	_bubble.outline_modulate = Color(0.05, 0.08, 0.14, 0.9)
	_bubble.outline_size = 10
	_bubble.width = 360.0
	_bubble.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_bubble)


## Show a short proximity chat bubble above the avatar.
func show_chat_bubble(text: String, duration_s: float = 5.0) -> void:
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

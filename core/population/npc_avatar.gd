class_name NpcAvatar
extends Node3D

## 3D silhouette stand-in for one simulated NPC. Two bodies share one API:
##
## - **Rigged** (`NpcRig`): the Mixamo character under the unshaded silhouette
##   shader, playing a real clip per activity. Used up close.
## - **Primitive**: the original head/torso/legs figure with a procedural bob
##   and leg swing. Used far away, and whenever the FBX assets are absent —
##   the population sim must never depend on art being installed.
##
## The host only ever calls `setup` / `apply_state` / `set_detail`, so which
## body is active is entirely this class's business. No collider and no
## gravity: the host snaps figures to the ground kinematically (the
## RemotePlayerAvatar pattern) so NPCs can never shove the player.

const HEIGHT_M := 1.7
const HEAD_R := 0.12
const TORSO_H := 0.62
const LEG_H := 0.78
const BOB_HZ := 1.8

## Cross-fade between clips. Long enough to hide the pose pop, short enough
## that a quick stop-and-start does not look like wading.
const CLIP_BLEND_S := 0.22
## Ground speed the walk clip is rate-matched to (NpcNav.WALK_SPEED_MPS).
const WALK_SPEED_MPS := 1.3

## Activity string (from NpcAgent) -> clip. Travelling overrides all of these:
## someone walking to the kitchen walks, whatever they intend to do there.
const ACTIVITY_CLIPS := {
	"sleep": NpcRig.CLIP_SLEEP,
	"chore": NpcRig.CLIP_WORK,
	"hunger": NpcRig.CLIP_SIT,        # eating, seated
	"enrichment": NpcRig.CLIP_DANCE,  # fire circle / movement / gathering
}

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

var _rig: Node3D = null             # rigged body (built lazily)
var _rig_ap: AnimationPlayer = null
var _rig_mat: ShaderMaterial = null
var _rigged := false                # is the rigged body the active one?
var _tint := Color(0.6, 0.65, 0.8)
var _activity := ""
var _space_type := ""
var _clip := ""
var _rig_y_target := 0.0
var _backwards := false
var _machine: NpcPoseMachine = null
## Set when the AnimationPlayer reports a one-shot ended. The machine treats
## this as an accelerator only — its own timer is authoritative, because this
## signal is missed whenever the figure is culled or speed_scale changes.
var _anim_finished := false


func setup(p_agent_id: String, color: Color, p_name: String = "") -> void:
	agent_id = p_agent_id
	display_name = p_name if not p_name.is_empty() else p_agent_id
	name = "Npc_%s" % p_agent_id.validate_node_name()
	_tint = color
	_machine = NpcPoseMachine.new()
	_machine.set_catalog(NpcRig.catalog())
	_machine.set_walk_variant(NpcRig.walk_variant_for(p_agent_id))
	_ensure_visuals()
	_mat.albedo_color = Color(color.r * 0.55, color.g * 0.55, color.b * 0.55)
	if _rig_mat != null:
		_rig_mat.set_shader_parameter("rim_color", color)
	_phase = fposmod(float(hash(p_agent_id) % 1000) * 0.13, TAU)
	if _tag != null:
		_tag.text = display_name


## Host-driven LOD: `true` swaps in the rigged body, `false` the primitive.
## A request for the rig when no assets are installed is a silent no-op, which
## is why the primitive figure is never discarded.
func set_detail(rigged: bool) -> void:
	var want := rigged and NpcRig.available()
	if want == _rigged:
		return
	if want and _rig == null:
		_build_rig()
		if _rig == null:
			return
	_rigged = want
	if _rig != null:
		_rig.visible = want
	if _root != null:
		_root.visible = not want
	if want:
		_clip = ""  # force a re-pick so the new body starts on the right clip
		# Snap to the settled look rather than resuming a transition: acquiring
		# a figure mid lie-down would pop a half-lying body into view.
		if _machine != null:
			_machine.snap_to_settled(_activity, _space_type, _moving)
			_apply_clip(_machine.clip(), _machine.backwards(), 0.0, true)
		else:
			_apply_clip(_pick_clip(), false, 0.0, true)


func is_rigged() -> bool:
	return _rigged


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
	apply_pose(pos, yaw, {"in_transit": moving, "activity": activity})


## Full per-frame drive. `inp` is passed through to NpcPoseMachine — see its
## `step()` for the accepted keys.
func apply_pose(pos: Vector3, yaw: float, inp: Dictionary) -> void:
	global_position = pos
	rotation = Vector3(0.0, yaw, 0.0)
	_drive(float(inp.get("dt", 1.0 / 60.0)), inp)


## What the figure is doing, independent of where it is. Split out from
## `apply_state` because the two answer different questions — and because
## posing needs a tree while clip selection does not, which is what lets the
## offline selftest cover the activity→clip routing at all.
func set_motion_state(moving: bool, activity: String) -> void:
	_drive(1.0 / 60.0, {"in_transit": moving, "activity": activity})


func _drive(dt: float, inp: Dictionary) -> void:
	_moving = bool(inp.get("in_transit", false))
	_activity = str(inp.get("activity", ""))
	_space_type = str(inp.get("space_type", ""))
	if _machine == null:
		_lying = _activity == "sleep"
		return
	var step_inp := inp.duplicate()
	step_inp["finished"] = _anim_finished
	_anim_finished = false
	_machine.step(dt, step_inp)
	# The primitive far-LOD figure reads the SAME machine, which is what stops
	# it lying down for the whole walk to bed the way it used to.
	_lying = _machine.is_lying()
	if _rigged and _machine.changed():
		_apply_clip(_machine.clip(), _machine.backwards(), _machine.blend_s(), false)


## The clip actually playing, for diagnostics.
func current_clip() -> String:
	return _clip


## Is this figure playing a gait?
func is_walking() -> bool:
	return _is_gait(NpcPoseMachine._clip_file_for(_clip))


## Is this figure currently lying down or seated? Used by the harness to assert
## that nobody is holding a settled pose while the sim says they are walking.
func is_posed_down() -> bool:
	return _machine != null and (_machine.is_lying() or _machine.is_seated())


## Whether the figure should hold position this frame (mid stand-up).
func wants_anchor(lag_m: float) -> bool:
	return _machine != null and _machine.anchor(lag_m)


func _ready() -> void:
	_ensure_visuals()
	add_to_group("npc_avatars")


## The clip this figure settles on for its current situation, ignoring
## transitions. Retained as the simple question it always answered — travelling
## wins over intent, then the activity table — and still used by the selftest.
func _pick_clip() -> String:
	if _moving:
		return NpcRig.CLIP_WALK
	return str(ACTIVITY_CLIPS.get(_activity, NpcRig.CLIP_IDLE))


## Play a clip, forwards or backwards.
##
## The guard keys on (clip, DIRECTION), not the clip alone. Sitting down is
## `sit_exit` reversed, so a clip-only guard would make sit-down -> stand-up a
## no-op and freeze the figure half-seated — a wedge, not a cosmetic glitch.
func _apply_clip(clip: String, backwards: bool, blend: float, immediate: bool) -> void:
	if _rig_ap == null:
		return
	if clip == _clip and backwards == _backwards:
		return
	var file_clip := NpcPoseMachine._clip_file_for(clip)
	if not _rig_ap.has_animation(file_clip):
		return
	_clip = clip
	_backwards = backwards
	# Rate-match the gait so the feet grip; per variant, because the alternate
	# walks were authored ~1.02 m/s against the primary's 1.64.
	_rig_ap.speed_scale = NpcRig.walk_speed_scale_for(file_clip, WALK_SPEED_MPS) \
		if _is_gait(file_clip) else 1.0
	_rig_y_target = NpcRig.clip_ground_offset_at(file_clip, 1.0 if backwards else 0.0)
	if immediate or blend <= 0.0:
		if backwards:
			_rig_ap.play_backwards(file_clip)
		else:
			_rig_ap.play(file_clip)
		# Snap, never lerp, on a hard cut: an aborted lie-down would otherwise
		# leave the body most of a metre underground while the offset caught up.
		if _rig != null:
			_rig.position.y = _rig_y_target
	elif backwards:
		_rig_ap.play_backwards(file_clip, blend)
	else:
		_rig_ap.play(file_clip, blend)


static func _is_gait(clip: String) -> bool:
	return clip == NpcRig.CLIP_WALK or clip == NpcRig.CLIP_WALK_ALT \
		or clip == NpcRig.CLIP_WALK_ALT2 or clip == NpcRig.CLIP_WALK_SAD


func _process(delta: float) -> void:
	if _rigged:
		_follow_ground_offset(delta)
		return
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


## Track the ground offset for where the CURRENT clip actually is, rather than
## lerping toward one number per clip on a timer.
##
## A lie-down spans standing to lying, so a single offset is wrong at one end or
## the other; the curve is indexed by the clip\'s own descent, so the body meets
## the ground exactly when the animation puts it there. A small follow remains
## only to absorb cuts.
func _follow_ground_offset(delta: float) -> void:
	if _rig == null or _rig_ap == null:
		return
	var length := _rig_ap.current_animation_length
	if length > 0.0:
		var u := clampf(_rig_ap.current_animation_position / length, 0.0, 1.0)
		_rig_y_target = NpcRig.clip_ground_offset_at(_rig_ap.current_animation, u)
	if not is_equal_approx(_rig.position.y, _rig_y_target):
		_rig.position.y = lerpf(_rig.position.y, _rig_y_target,
				minf(delta * 20.0, 1.0))


## Builds the rigged body once, under the silhouette shader. Kept out of
## `_ensure_visuals` so distant/culled agents never pay for a skeleton they
## will not show.
func _build_rig() -> void:
	if _rig != null:
		return
	var fig := NpcRig.build_figure()
	if fig == null:
		return
	fig.name = "Rig"
	# The imported model faces +Z; the avatar's forward is −Z (host yaw uses
	# atan2(-dir.x, -dir.y)). Offset is measured from the walk clip, not
	# hardcoded, so a re-export with other axis conventions still faces right.
	fig.rotation.y = NpcRig.model_yaw_offset()
	add_child(fig)
	_rig = fig
	_rig.visible = false

	_rig_mat = ShaderMaterial.new()
	_rig_mat.shader = load("res://core/population/npc_silhouette.gdshader")
	_rig_mat.set_shader_parameter("rim_color", _tint)
	var mesh_inst := NpcRig.find_mesh(fig)
	if mesh_inst != null:
		# material_override beats every surface material the FBX brought with
		# it, so the character's own textures never load into the frame.
		mesh_inst.material_override = _rig_mat
		# Skinned meshes are culled against their REST AABB by default, so a
		# figure whose clip reaches outside it (lying down, arms overhead)
		# pops out of view at the screen edge.
		mesh_inst.extra_cull_margin = 1.5
	_rig_ap = NpcRig.find_anim_player(fig)
	if _rig_ap != null:
		_rig_ap.playback_default_blend_time = CLIP_BLEND_S
		_rig_ap.animation_finished.connect(func(_n: StringName) -> void:
			_anim_finished = true)


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

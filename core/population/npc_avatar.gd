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

## Overhead status readout (name + morale bar) geometry, in the same local
## billboard frame as the nametag — see _build_status_bar().
const STATUS_BAR_WIDTH := 0.46
const STATUS_BAR_HEIGHT := 0.055
const STATUS_BAR_Y := HEIGHT_M + 0.12   # below the nametag (HEIGHT_M + 0.28)

var agent_id: String = ""
var display_name: String = ""
var status_text: String = ""
var morale_label: String = ""
var morale: float = 0.0

var _root: Node3D = null            # animated sub-root (bob/lie-down)
var _tag: Label3D = null
var _status_root: Node3D = null     # holds the morale bar + the task tag
var _bar_fill: MeshInstance3D = null
var _bar_fill_mat: StandardMaterial3D = null
var _task_lbl: Label3D = null
var _task_text := ""
var _trend_lbl: Label3D = null
var _morale_trend := 0.0
## Overhead readout visibility has TWO drivers with different owners: the host
## grants AMBIENT visibility by distance (the group-monitoring read), and the
## crosshair grants FOCUS (which also shows the name). Either shows the bar.
var _ambient := false
var _focus := false
var _moving := false
var _lying := false

var _simple: NpcSimpleFigure = null # articulated stick figure (the other style)
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
## Playback rate the current clip WANTS, kept separately so unpausing restores
## it. Setting AnimationPlayer.speed_scale to 0 is what freezes a figure, and
## without remembering the intended value it would resume at zero.
var _speed_scale := 1.0
var _frozen := false
## Metres per REAL second the body is covering on screen. At 60x that is ~60x
## the sim's walking speed, and matching the gait to it is what removes the
## skating; the sim's own 1.3 m/s is only correct at 1x.
var _apparent_speed := WALK_SPEED_MPS
## Sim seconds per real second, so loops keep pace with the clock.
var _time_mult := 1.0
## Hauling a crate this frame (Site Projects). The simple figure draws its own
## box as part of the carry pose; the rigged body shows this avatar-frame box
## instead (chest height, forward −Z) — deliberately NOT a bone attachment in
## v1: with no carry clip the walk arms would swing through a hand-held box
## anyway, and under the silhouette shader a stable chest box reads better
## than a bobbing intersecting one.
var _carrying := false
## The REAL prop is riding this carrier's hands (host follow) — suppress the
## generic chest box so the load is not drawn twice.
var _carry_prop_live := false
## Two or more sets of hands on one load: the low team-lift posture.
var _carry_heavy := false
var _rig_carry_box: MeshInstance3D = null


func setup(p_agent_id: String, color: Color, p_name: String = "") -> void:
	agent_id = p_agent_id
	display_name = p_name if not p_name.is_empty() else p_agent_id
	name = "Npc_%s" % p_agent_id.validate_node_name()
	_machine = NpcPoseMachine.new()
	# Merged HERE and not inside NpcRig.catalog(): that function answers "what
	# animation art is installed" and other callers depend on that meaning,
	# while the work families and their transitions are procedural and exist
	# whether or not the (gitignored) Mixamo pack is present. Without the merge
	# every _has() guard skips them on a fresh clone — silently, on exactly the
	# body they were written for.
	_machine.set_catalog(NpcWorkPose.merge_catalog(NpcRig.catalog()))
	_machine.set_walk_variant(NpcRig.walk_variant_for(p_agent_id))
	_ensure_visuals()
	# The articulated figure owns its own material. The old fixed-primitive
	# body had a shared StandardMaterial3D tinted here; when that body was
	# replaced this line kept assigning to a `_mat` nothing builds any more,
	# which crashed every map load with a pop-driven habitat.
	set_tint(color)
	if _tag != null:
		_tag.text = display_name


## Re-tint live without touching body/visual state — for when a display pref
## (colors on/off) changes mid-session, as opposed to `setup()` which also
## (re)builds visuals and is only meant to run once per avatar.
func set_tint(color: Color) -> void:
	_tint = color
	if _simple != null:
		_simple.set_tint(color)
	if _rig_mat != null:
		_rig_mat.set_shader_parameter("rim_color", color)


## Live-refresh the display name (and nametag text). `setup()` only names an
## avatar once at creation; a rename in the Routines panel edits the live
## NpcAgent, and the host calls this every tick from agent_dots() so a rename
## shows up immediately instead of only on the avatar's next despawn/respawn.
func set_display_name(new_name: String) -> void:
	if new_name.is_empty() or new_name == display_name:
		return
	display_name = new_name
	if _tag != null:
		_tag.text = display_name


func _build_nametag() -> void:
	if _tag != null:
		return
	_tag = Label3D.new()
	_tag.name = "NameTag"
	_tag.text = display_name
	_tag.font_size = 40
	# fixed_size: constant on-screen height regardless of distance — the old
	# fixed WORLD size (pixel_size 0.0075) filled the screen up close and
	# shrank to unreadable pixels at range. 0.0007 ≈ a 13 px line at 720p.
	_tag.fixed_size = true
	_tag.pixel_size = 0.0007
	_tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_tag.position = Vector3(0.0, HEIGHT_M + 0.28, 0.0)
	_tag.modulate = Color(1, 1, 1, 0.97)
	_tag.outline_modulate = Color(0.02, 0.04, 0.09, 0.9)
	_tag.outline_size = 8
	# The FOCUS nametag alone keeps no_depth_test: it answers "who am I
	# pointing at", which must survive the person being behind a wall. The
	# ambient readout below is depth-tested — a camp's bars and tags glowing
	# through every building read as x-ray noise, not information.
	_tag.no_depth_test = true
	_tag.visible = false  # only for the person the crosshair is on
	add_child(_tag)


## Live-refresh morale (and the bar, when visible). Called every tick from
## the host like set_display_name — cheap even when not visible, since the
## bar mesh/label only get touched while _status_root is actually shown.
func set_morale(value: float) -> void:
	morale = clampf(value, 0.0, 1.0)
	if _status_root != null and _status_root.visible:
		_update_status_bar()


## Morale bar + task tag, below the nametag, in the same billboard frame.
## The bar's COLOR carries the "Fuck This → Fuck Yes" scale on its own
## (NpcMorale.color(), the same mapping the roster and Site Plan dots use) —
## the old flanking text labels doubled the bar's width and shouted a joke
## sixteen times at once; the words survive in the Routines roster where
## there is room for them. Under it, a small tag says what this person is
## DOING right now, which is the other half of monitoring a camp at a glance.
func _build_status_bar() -> void:
	if _status_root != null:
		return
	_status_root = Node3D.new()
	_status_root.name = "StatusBar"
	_status_root.visible = false  # ambient (near) or focus shows it
	add_child(_status_root)

	# Track (the empty/background part of the bar) — static, never rescaled.
	var track := _make_bar_quad(Color(0.07, 0.08, 0.11, 0.85))
	track.position = Vector3(0.0, STATUS_BAR_Y, 0.0)
	(track.get_surface_override_material(0) as StandardMaterial3D).render_priority = 0
	_status_root.add_child(track)

	# Fill — scaled by morale fraction, left edge pinned to the track's left
	# edge (see _update_status_bar: a scaled-down quad shrinks toward its own
	# centre, so the X position is re-derived every refresh to compensate).
	_bar_fill = _make_bar_quad(Color.WHITE)
	_bar_fill.position = Vector3(-STATUS_BAR_WIDTH * 0.5, STATUS_BAR_Y, 0.001)
	_bar_fill_mat = _bar_fill.get_surface_override_material(0) as StandardMaterial3D
	_bar_fill_mat.render_priority = 1
	_status_root.add_child(_bar_fill)

	_task_lbl = _make_status_label("", 20, Vector3(0.0, STATUS_BAR_Y - 0.085, 0.0))
	_task_lbl.modulate = Color(0.92, 0.94, 0.97, 0.92)
	_status_root.add_child(_task_lbl)

	# Trend tick at the bar's right end: "unhappy" and "getting worse" are
	# different triage cases, and the bar alone cannot tell them apart.
	_trend_lbl = _make_status_label("", 20,
		Vector3(STATUS_BAR_WIDTH * 0.5 + 0.075, STATUS_BAR_Y, 0.0))
	_status_root.add_child(_trend_lbl)

	_update_status_bar()


## Morale movement over roughly the last sim-hour, host-computed. Small
## drifts stay silent — the tick marks a TREND, not noise.
func set_morale_trend(delta: float) -> void:
	if absf(delta - _morale_trend) < 0.005:
		return
	_morale_trend = delta
	if _status_root != null and _status_root.visible:
		_update_status_bar()


## What this person is doing, in one or two words under the bar. Set by the
## host every tick from the dot payload; refreshes only while visible.
func set_task_text(text: String) -> void:
	if text == _task_text:
		return
	_task_text = text
	if _task_lbl != null and _status_root != null and _status_root.visible:
		_task_lbl.text = _task_text


func _make_bar_quad(color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(STATUS_BAR_WIDTH, STATUS_BAR_HEIGHT)
	mi.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mi.set_surface_override_material(0, mat)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	return mi


func _make_status_label(text: String, font_size: int, pos: Vector3) -> Label3D:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = font_size
	# Constant screen size (see _build_nametag) — the task tag was 2 px of
	# noise at range and a billboard-sized word up close.
	lbl.fixed_size = true
	lbl.pixel_size = 0.0011
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.position = pos
	lbl.modulate = Color(1, 1, 1, 0.97)
	lbl.outline_modulate = Color(0.02, 0.04, 0.09, 0.9)
	lbl.outline_size = 7
	return lbl


func _update_status_bar() -> void:
	if _bar_fill == null:
		return
	var frac := clampf(morale, 0.0, 1.0)
	_bar_fill.scale.x = maxf(frac, 0.001)  # 0 scale degenerates the quad's AABB
	# A scaled quad shrinks toward its own centre, not its left edge — shift
	# the fill's position back out so the visible left edge stays pinned to
	# the track's left edge regardless of fraction (the standard scale-based
	# progress-bar trick).
	_bar_fill.position.x = -STATUS_BAR_WIDTH * 0.5 * (1.0 - frac)
	if _bar_fill_mat != null:
		_bar_fill_mat.albedo_color = NpcMorale.color(morale)
	if _task_lbl != null:
		_task_lbl.text = _task_text
	if _trend_lbl != null:
		if _morale_trend >= 0.03:
			_trend_lbl.text = "▲"
			_trend_lbl.modulate = Color(0.5, 0.85, 0.55, 0.95)
		elif _morale_trend <= -0.03:
			_trend_lbl.text = "▼"
			_trend_lbl.modulate = Color(0.9, 0.45, 0.4, 0.95)
		else:
			_trend_lbl.text = ""


## Host-driven LOD: `true` swaps in the rigged body, `false` the primitive.
## A request for the rig when no assets are installed is a silent no-op, which
## is why the primitive figure is never discarded.
func set_detail(rigged: bool) -> void:
	# Two different reasons to draw the stylised body, kept distinct: the
	# player chose it (a style, survives installing the art), or the rig is not
	# installed (a missing-asset condition). Only the second is a fallback.
	var want := rigged and NpcRig.available() and not NpcDisplayPrefs.wants_simple()
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


## Did construction actually leave something to draw? Cheap, but it is the
## assertion that catches a body swap forgetting to build its material.
func has_body() -> bool:
	return _simple != null or _rig != null


func is_rigged() -> bool:
	return _rigged


## World point the crosshair ray is tested against.
func pick_center() -> Vector3:
	return global_position + Vector3(0.0, PICK_CENTER_Y, 0.0)


## Nametag + morale bar are off by default (50 floating labels is noise) —
## the crosshair turns them on for whoever the player is looking at.
func set_tag_visible(on: bool) -> void:
	_focus = on
	_refresh_overhead()


## Host-driven by distance: near people carry their bar + task tag all the
## time (the "monitor the group from first person" read); far people stay
## clean silhouettes. The name stays focus-only — sixteen names is clutter,
## sixteen thin bars is a dashboard.
func set_ambient_status(on: bool) -> void:
	if on == _ambient:
		return
	_ambient = on
	_refresh_overhead()


func _refresh_overhead() -> void:
	if _tag != null:
		_tag.visible = _focus
	if _status_root != null:
		# The display pref gates the READOUT, never the name: "off" is for
		# players who want clean silhouettes, and aiming still names people.
		var mode := NpcDisplayPrefs.overhead_mode()
		var show := (_focus and mode != NpcDisplayPrefs.OVERHEAD_OFF) \
			or (_ambient and mode == NpcDisplayPrefs.OVERHEAD_ALWAYS)
		if show and not _status_root.visible:
			# Morale/task may have drifted while hidden (their setters skip the
			# refresh) — catch up right as it shows.
			_status_root.visible = true
			_update_status_bar()
		else:
			_status_root.visible = show


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
	# Time paused (or scrubbing backwards, where the population engine freezes
	# anyway): hold the pose. A figure jogging on the spot while the clock is
	# stopped reads as the sim still running.
	var frozen := bool(inp.get("paused", false))
	if frozen != _frozen:
		_frozen = frozen
		if _rig_ap != null:
			_rig_ap.speed_scale = 0.0 if frozen else _speed_scale
	if frozen:
		return
	_moving = bool(inp.get("in_transit", false))
	_activity = str(inp.get("activity", ""))
	_space_type = str(inp.get("space_type", ""))
	_apparent_speed = float(inp.get("apparent_speed_mps", WALK_SPEED_MPS))
	_time_mult = clampf(float(inp.get("time_mult", 1.0)), 0.05, NpcRig.MAX_PLAYBACK_RATE)
	_carrying = bool(inp.get("carrying", false))
	_carry_prop_live = bool(inp.get("carry_prop_live", false))
	_carry_heavy = bool(inp.get("carry_heavy", false))
	if _machine == null:
		_lying = _activity == "sleep"
		return
	if inp.has("anim_map"):
		_machine.set_anim_overrides(inp["anim_map"] as Dictionary)
	var step_inp := inp.duplicate()
	step_inp["playback_rate"] = _speed_scale
	step_inp["finished"] = _anim_finished
	_anim_finished = false
	_machine.step(dt, step_inp)
	# The primitive far-LOD figure reads the SAME machine, which is what stops
	# it lying down for the whole walk to bed the way it used to.
	_lying = _machine.is_lying()
	if _rigged and _machine.changed():
		_apply_clip(_machine.clip(), _machine.backwards(), _machine.blend_s(), false)
	else:
		# Rate is refreshed every frame, not only on a clip change: apparent
		# speed varies continuously and the time scale can be changed mid-stride.
		# This runs for the SIMPLE body too — _process hands _speed_scale to
		# _simple.pose, and computing the rate only on the rigged path left
		# every stylised figure at a stale rate forever (no time-lapse, gait
		# skating at speed). _clip is maintained only by _apply_clip, so the
		# simple body reads the machine's clip directly.
		_refresh_speed_scale(NpcPoseMachine._clip_file_for(
			_clip if _rigged else _machine.clip()))
	_update_carry_box()


## Rigged-body carried-crate visual. Re-derived from current state every step
## (never edge-triggered), so a body swap, a teleport hard-cut, or a culled
## frame can never strand a floating box.
##
## DELIBERATELY parented to the avatar, not bone-attached — and it should STAY
## that way even once a real carry clip lands. A BoneAttachment3D costs a
## per-frame global-transform update per avatar, against a roster of up to 64
## with an LOD budget tuned to avoid exactly that class of cost, and it would
## also break this function's "can never strand a box" invariant (the
## attachment has to be torn down whenever the rig node is freed on a body
## swap). Bone-attach only if a future clip's hands actually converge on a
## point the chest box cannot fake.
func _update_carry_box() -> void:
	# Suppressed while the REAL prop follows the hands (carry_prop_live) —
	# the generic box then only serves brigade station workers, who read as
	# carrying with no single crate of their own.
	var want := _rigged and _carrying and not _carry_prop_live
	if _rig_carry_box != null:
		_rig_carry_box.visible = want
	if not want or _rig_carry_box != null:
		return
	_rig_carry_box = MeshInstance3D.new()
	_rig_carry_box.name = "CarryBox"
	var box := BoxMesh.new()
	box.size = Vector3(0.42, 0.32, 0.30)
	_rig_carry_box.mesh = box
	_rig_carry_box.position = Vector3(0.0, 1.02, -0.36)
	if _rig_mat != null:
		_rig_carry_box.material_override = _rig_mat
	add_child(_rig_carry_box)


## Playhead position within the current clip, so a test can prove the figure
## is genuinely frozen rather than merely looking still.
func clip_position() -> float:
	return _rig_ap.current_animation_position if _rig_ap != null else 0.0


## The clip actually playing, for diagnostics.
func current_clip() -> String:
	return _clip


## The LOGICAL clip the pose machine chose, before `_clip_file_for` collapses
## the aliases. `current_clip()` reports the rigged body's file, which maps
## every work family onto `CLIP_WORK` — so it can never tell you which family
## is being drawn. This can, on either body style.
func pose_clip() -> String:
	return _machine.clip() if _machine != null else ""


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
	_speed_scale = NpcRig.walk_speed_scale_for(file_clip, WALK_SPEED_MPS) \
		if _is_gait(file_clip) else 1.0
	_rig_ap.speed_scale = 0.0 if _frozen else _speed_scale
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


## A gait matches the ground it is covering; everything else keeps pace with
## the clock, so a work or dance loop reads as time-lapse rather than as
## somebody calmly pottering while the day races past.
func _refresh_speed_scale(file_clip: String = "") -> void:
	if file_clip.is_empty():
		file_clip = NpcPoseMachine._clip_file_for(_clip)
	if file_clip.is_empty():
		return
	var want := NpcRig.walk_speed_scale_for(file_clip, _apparent_speed) 		if _is_gait(file_clip) else clampf(_time_mult, 0.25, NpcRig.MAX_PLAYBACK_RATE)
	if is_equal_approx(want, _speed_scale) and not _frozen:
		return
	_speed_scale = want
	# The rate is state either way; the AnimationPlayer only exists when rigged.
	if _rig_ap != null:
		_rig_ap.speed_scale = 0.0 if _frozen else _speed_scale


static func _is_gait(clip: String) -> bool:
	return clip == NpcRig.CLIP_WALK or clip == NpcRig.CLIP_WALK_ALT \
		or clip == NpcRig.CLIP_WALK_ALT2 or clip == NpcRig.CLIP_WALK_SAD


func _process(delta: float) -> void:
	if _frozen:
		return
	if _rigged:
		_follow_ground_offset(delta)
		return
	if _simple != null and _machine != null:
		# Same machine, same decisions — only the rendering differs, so the two
		# styles can never disagree about what somebody is doing. The flavor is
		# a rendering HINT only: hurrying to the bathroom plays the arms-in
		# urgent walk, and a shared team lift plays the low arms-down hold.
		var flavor := ""
		if _carrying and _carry_heavy:
			flavor = "heavy"
		elif _moving and _activity == "bladder":
			flavor = "urgent"
		_simple.set_carry_box_suppressed(_carry_prop_live)
		_simple.pose(_machine.clip(), _speed_scale, delta, flavor)
		return



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
	_simple = NpcSimpleFigure.new()
	_simple.setup(agent_id, _tint)
	_root.add_child(_simple)
	_build_nametag()
	_build_status_bar()
	return

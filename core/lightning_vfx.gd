class_name LightningVfx
extends Node3D

## Thunderstorm lightning using a camera-facing billboard (`assets/vfx/lightning.glb`).
## When the player looks toward the horizon, strikes are placed inside the camera FOV.

signal flash_triggered(intensity: float)

const BOLT_SCENE := preload("res://assets/vfx/lightning.glb")

## Raw ArrayMesh bounds inside the GLB (local space, width along X, height along +Z).
## We pull this bare mesh onto our own MeshInstance3D and scale it directly to world
## metres — the GLB's node hierarchy nests it under a 0.0254 (inch→metre) "Assembly-1"
## scale AND leaves a near-zero-thickness AABB that Godot frustum-culls, so the imported
## scene never rendered. Extracting the mesh + a large cull margin fixes both.
const MESH_WIDTH_M := 1176.057
const MESH_HEIGHT_M := 1934.304

## Additive, unshaded, camera-facing bolt. Colour/energy come from uniforms so the
## texture's alpha (which carries the branching shape) masks a bright electric glow.
const BOLT_SHADER_CODE := "shader_type spatial;\n" + \
	"render_mode blend_add, unshaded, cull_disabled, depth_draw_opaque, shadows_disabled, fog_disabled;\n" + \
	"uniform sampler2D tex : source_color, filter_linear;\n" + \
	"uniform vec3 bolt_color : source_color = vec3(0.78, 0.88, 1.0);\n" + \
	"uniform float energy = 8.0;\n" + \
	"uniform float fade = 1.0;\n" + \
	"void fragment() {\n" + \
	"    vec4 t = texture(tex, UV);\n" + \
	"    ALBEDO = bolt_color * energy;\n" + \
	"    ALPHA = t.a * fade;\n" + \
	"}\n"

const BOLT_LIFETIME := 0.085  ## snappier flash-and-gone bolt
const MIN_INTERVAL := 5.0
const MAX_INTERVAL := 20.0
const STRIKE_DIST_MIN := 320.0  ## keep bolts distant so the texture never looks pixelated up close
const STRIKE_DIST_MAX := 620.0
const STRIKE_HEIGHT_MIN := 260.0
const STRIKE_HEIGHT_MAX := 480.0
const HORIZON_LOOK_Y_MAX := 0.42  ## |camera_forward.y| below this ≈ looking toward horizon
const FOV_PLACE_HALF_RAD := 0.42  ## random yaw offset within view (~±24°)
const FOV_MARGIN := 0.88        ## require strike inside ~88% of camera cone

const THUNDER_STREAM := preload("res://assets/audio/thunder_crack.wav")
## Speed of sound in air at ~20°C (343 m/s, standard atmospheric acoustics figure).
## Thunder is queued at the strike and played after light_delay = distance / SPEED_OF_SOUND_MPS,
## the same "count the seconds between flash and boom" cue real storms give.
const SPEED_OF_SOUND_MPS := 343.0

var _strike_root: MeshInstance3D
var _bolt_mat: ShaderMaterial
var _flash_light: OmniLight3D
var _thunder_player: AudioStreamPlayer3D
var _strike_origin := Vector3.ZERO
var _strike_scale_x := 1.0
var _strike_scale_z := 1.0
var _bolt_timer := 0.0
var _next_strike := 8.0
var _storm_intensity := 0.0
var _active := false
var _rng := RandomNumberGenerator.new()

## Pending thunder crack, delayed to arrive after the (instant) light.
var _thunder_pending := false
var _thunder_delay_remaining := 0.0
var _thunder_position := Vector3.ZERO
var _thunder_volume_db := 0.0
var _thunder_pitch := 1.0


func _ready() -> void:
	_rng.randomize()
	_build_strike_visual()

	_flash_light = OmniLight3D.new()
	_flash_light.name = "StrikeFlash"
	_flash_light.light_color = Color(0.82, 0.9, 1.0)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 700.0
	_flash_light.shadow_enabled = false
	add_child(_flash_light)

	_thunder_player = AudioStreamPlayer3D.new()
	_thunder_player.name = "ThunderCrack"
	_thunder_player.stream = THUNDER_STREAM
	# Real thunder stays loud for hundreds/thousands of metres — disable the engine's
	# close-range SFX falloff and drive volume ourselves from distance/intensity instead.
	# Panning/doppler still apply since those are independent of attenuation_model.
	_thunder_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
	_thunder_player.max_distance = 0.0
	add_child(_thunder_player)


func _build_strike_visual() -> void:
	var tmp := BOLT_SCENE.instantiate() as Node3D
	if tmp == null:
		push_warning("LightningVfx: failed to load lightning.glb")
		return
	var src_mi := _find_mesh_instance(tmp)
	if src_mi == null or src_mi.mesh == null:
		push_warning("LightningVfx: no mesh in lightning.glb")
		tmp.free()
		return

	# Rebuild the bare mesh on our own MeshInstance3D (bypass the Assembly-1 scale + LODs,
	# and dodge the frustum-cull of the flat imported quad via a big cull margin).
	_strike_root = MeshInstance3D.new()
	_strike_root.name = "StrikeBillboard"
	_strike_root.mesh = src_mi.mesh
	_strike_root.extra_cull_margin = 16384.0
	_strike_root.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_strike_root.visible = false

	var sh := Shader.new()
	sh.code = BOLT_SHADER_CODE
	_bolt_mat = ShaderMaterial.new()
	_bolt_mat.shader = sh
	var src_std := src_mi.mesh.surface_get_material(0) as StandardMaterial3D
	if src_std != null and src_std.albedo_texture != null:
		_bolt_mat.set_shader_parameter("tex", src_std.albedo_texture)
	_bolt_mat.set_shader_parameter("bolt_color", Vector3(0.78, 0.88, 1.0))
	_strike_root.material_override = _bolt_mat
	add_child(_strike_root)
	tmp.free()
	_apply_emissive_baseline(1.0)


func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var found := _find_mesh_instance(c)
		if found != null:
			return found
	return null


func set_storm_active(active: bool, intensity: float) -> void:
	_active = active
	_storm_intensity = clampf(intensity, 0.0, 1.0)
	if not active:
		_hide_strike()
		_flash_light.light_energy = 0.0


func _process(delta: float) -> void:
	_update_thunder(delta)

	if _bolt_timer > 0.0:
		_bolt_timer -= delta
		var fade := clampf(_bolt_timer / BOLT_LIFETIME, 0.0, 1.0)
		if fade > 0.02:
			_face_camera_billboard()
			_strike_root.visible = true
			_apply_emissive_baseline(fade)
			_flash_light.light_energy = fade * 18.0 * _storm_intensity
		else:
			_hide_strike()
			_flash_light.light_energy = 0.0
		return

	if not _active or _storm_intensity < 0.15 or _strike_root == null:
		return

	_next_strike -= delta
	if _next_strike > 0.0:
		return
	_try_strike()
	var mean := lerpf(MAX_INTERVAL, MIN_INTERVAL, _storm_intensity)
	_next_strike = _rng.randf_range(mean * 0.55, mean * 1.35)


func _try_strike() -> void:
	var player := _get_player()
	var cam := _get_camera()
	if player == null or cam == null or _strike_root == null:
		return
	var ground_fn := _ground_height_callable()
	if not ground_fn.is_valid():
		return

	var ground := _pick_strike_ground(cam, player.global_position, ground_fn)
	if ground == Vector3.INF:
		return

	var strike_h := _rng.randf_range(STRIKE_HEIGHT_MIN, STRIKE_HEIGHT_MAX)
	_place_strike(ground, strike_h)
	_bolt_timer = BOLT_LIFETIME
	_queue_thunder(ground, player.global_position)
	flash_triggered.emit(_storm_intensity)


## Queue the thunder crack to play after the light-speed-negligible / sound-speed delay
## for the strike's distance from the player — the classic flash-then-boom cue.
func _queue_thunder(strike_ground: Vector3, listener_pos: Vector3) -> void:
	if _thunder_player == null:
		return
	var dist := strike_ground.distance_to(listener_pos)
	_thunder_delay_remaining = dist / SPEED_OF_SOUND_MPS
	_thunder_position = strike_ground + Vector3(0.0, 2.0, 0.0)
	# Closer/stronger strikes hit louder and sharper (higher pitch = "crack" vs. distant "rumble").
	var near_t := 1.0 - clampf(
		(dist - STRIKE_DIST_MIN) / maxf(STRIKE_DIST_MAX - STRIKE_DIST_MIN, 1.0), 0.0, 1.0)
	_thunder_volume_db = lerpf(-6.0, 10.0, near_t) + lerpf(-3.0, 3.0, _storm_intensity)
	_thunder_pitch = lerpf(0.75, 1.05, near_t)
	_thunder_pending = true


func _update_thunder(delta: float) -> void:
	if not _thunder_pending:
		return
	_thunder_delay_remaining -= delta
	if _thunder_delay_remaining > 0.0:
		return
	_thunder_pending = false
	if _thunder_player == null:
		return
	_thunder_player.global_position = _thunder_position
	_thunder_player.volume_db = _thunder_volume_db
	_thunder_player.pitch_scale = _thunder_pitch
	_thunder_player.play()


## Pick a ground point visible in the camera when looking toward the horizon;
## otherwise still bias into the forward view cone.
func _pick_strike_ground(cam: Camera3D, player_pos: Vector3, ground_fn: Callable) -> Vector3:
	var fwd := (-cam.global_transform.basis.z).normalized()
	var horiz_look := absf(fwd.y) <= HORIZON_LOOK_Y_MAX
	var fov_half := deg_to_rad(cam.fov) * 0.5 * FOV_MARGIN

	for attempt in 16:
		var dir := _random_dir_in_view(cam, fwd, horiz_look)
		var dist := _rng.randf_range(STRIKE_DIST_MIN, STRIKE_DIST_MAX)
		var xz := player_pos + dir * dist
		var gy: float = float(ground_fn.call(xz.x, xz.z))
		if not is_finite(gy):
			continue
		var ground := Vector3(xz.x, gy, xz.z)
		if horiz_look and not _in_camera_fov(cam, ground, fov_half):
			continue
		if not horiz_look and attempt < 8 and not _in_camera_fov(cam, ground, fov_half):
			continue
		return ground

	# Last resort: straight ahead at mid distance.
	var fallback_dir := Vector3(fwd.x, 0.0, fwd.z)
	if fallback_dir.length_squared() < 0.01:
		fallback_dir = Vector3(0.0, 0.0, -1.0)
	fallback_dir = fallback_dir.normalized()
	var fb_pos := player_pos + fallback_dir * lerpf(STRIKE_DIST_MIN, STRIKE_DIST_MAX, 0.45)
	var fb_y: float = float(ground_fn.call(fb_pos.x, fb_pos.z))
	if is_finite(fb_y):
		return Vector3(fb_pos.x, fb_y, fb_pos.z)
	return Vector3.INF


func _random_dir_in_view(cam: Camera3D, fwd: Vector3, horiz_look: bool) -> Vector3:
	var yaw_basis := fwd
	if horiz_look or absf(fwd.y) > 0.15:
		yaw_basis = Vector3(fwd.x, 0.0, fwd.z)
		if yaw_basis.length_squared() < 0.0001:
			yaw_basis = -cam.global_transform.basis.z
			yaw_basis.y = 0.0
	yaw_basis = yaw_basis.normalized()
	var yaw_off := _rng.randf_range(-FOV_PLACE_HALF_RAD, FOV_PLACE_HALF_RAD)
	var dir := yaw_basis.rotated(Vector3.UP, yaw_off)
	if not horiz_look:
		# Slight pitch jitter so strikes still feel natural when looking up/down.
		var pitch := _rng.randf_range(-0.08, 0.12)
		dir = dir.rotated(cam.global_transform.basis.x, pitch).normalized()
	return dir


func _in_camera_fov(cam: Camera3D, world_pos: Vector3, fov_half: float) -> bool:
	var to := world_pos - cam.global_position
	if to.length_squared() < 1.0:
		return true
	var view_fwd := (-cam.global_transform.basis.z).normalized()
	var ang := acos(clampf(view_fwd.dot(to.normalized()), -1.0, 1.0))
	return ang <= fov_half


func _place_strike(ground: Vector3, strike_height: float) -> void:
	# GLB quad: width along local X (~1176 m), height along local +Z (~1934 m), flat in Y.
	_strike_scale_z = strike_height / MESH_HEIGHT_M
	var aspect := _rng.randf_range(0.75, 1.15)
	_strike_scale_x = (strike_height * 0.5 * aspect) / MESH_WIDTH_M
	_strike_origin = ground
	_face_camera_billboard()
	_strike_root.visible = true
	_flash_light.global_position = ground + Vector3(0.0, strike_height * 0.35, 0.0)


## Build an upright, camera-facing transform for the flat GLB quad:
##   local X (width)  → horizontal axis perpendicular to the view (r)
##   local Y (normal) → horizontal toward the camera (n)  → face points at camera
##   local Z (height) → world up
func _face_camera_billboard() -> void:
	var cam := _get_camera()
	if cam == null or _strike_root == null:
		return
	var n := Vector3(cam.global_position.x - _strike_origin.x, 0.0,
			cam.global_position.z - _strike_origin.z)
	if n.length_squared() < 0.25:
		n = Vector3(0.0, 0.0, 1.0)
	n = n.normalized()
	var up := Vector3.UP
	var r := n.cross(up).normalized()  # r × n = up → right-handed basis
	var basis := Basis()
	basis.x = r * _strike_scale_x
	basis.y = n
	basis.z = up * _strike_scale_z
	_strike_root.global_transform = Transform3D(basis, _strike_origin)


func _apply_emissive_baseline(fade: float) -> void:
	if _bolt_mat == null:
		return
	# Brighten hard at strike, dim out over the bolt lifetime; fade also drops alpha.
	_bolt_mat.set_shader_parameter("energy", 5.0 + fade * 12.0)
	_bolt_mat.set_shader_parameter("fade", clampf(0.25 + fade * 0.75, 0.0, 1.0))


func _hide_strike() -> void:
	if _strike_root != null:
		_strike_root.visible = false


func _ground_height_callable() -> Callable:
	var tree := get_tree()
	if tree == null:
		return Callable()
	var main := Services.get_main()
	if main == null:
		return Callable()
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("_ground_height_at"):
		return Callable(loader, "_ground_height_at")
	return Callable()


func _get_player() -> Node3D:
	var tree := get_tree()
	if tree == null:
		return null
	var p := tree.root.get_node_or_null("Main/Player")
	if p is Node3D:
		return p as Node3D
	return null


func _get_camera() -> Camera3D:
	var player := _get_player()
	if player == null:
		return null
	for path in ["CameraArm/Camera3D", "Camera3D", "Head/Camera3D"]:
		var n := player.get_node_or_null(path)
		if n is Camera3D:
			return n as Camera3D
	var cam := player.find_child("Camera3D", true, false)
	return cam as Camera3D

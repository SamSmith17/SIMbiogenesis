class_name GraphModelPreviewService
extends Node
## Off-screen SubViewport studio that snapshots a ModelCatalog GLB into a
## cached ImageTexture for system-graph node cards.
##
## One-shot renders (not continuous). Cache key = model_id + camera params.
## Disk: user://graph_previews/<key>.png  ·  Memory: LRU dict.

signal preview_ready(cache_key: String, texture: ImageTexture)

const CACHE_DIR := "user://graph_previews/"
const PREVIEW_PX := 256
const PREVIEW_VERSION := 1
const MAX_MEM_ENTRIES := 64
const RENDERS_PER_FRAME := 1

## Defaults — head-on with a slight elevation so tall models (VAWT) read clearly.
const DEFAULT_YAW_DEG := 0.0
const DEFAULT_PITCH_DEG := 12.0
const DEFAULT_DIST_MULT := 1.9

var _mem: Dictionary = {}          # cache_key → ImageTexture
var _mem_order: Array[String] = [] # LRU order (oldest first)
var _queue: Array[Dictionary] = [] # pending {key, model_id, yaw, pitch, dist}
var _queued_keys: Dictionary = {}  # key → true
var _busy := false
## Icon keys whose model could not be drawn (not asked again this session).
var _failed: Dictionary = {}
## Icons drawn this session, and the last one's cost (ms), for checks.
var _tasks: Array = []
var icons_rendered := 0
var last_icon_ms := 0.0
const ICON_PX := 384

var _viewport: SubViewport = null
var _studio: Node3D = null
var _holder: Node3D = null
var _camera: Camera3D = null


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	_ensure_studio()
	set_process(true)


func _exit_tree() -> void:
	for t in _tasks:
		WorkerThreadPool.wait_for_task_completion(int(t))
	_tasks.clear()


func _process(_delta: float) -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	_run_next_job()


func _run_next_job() -> void:
	if _queue.is_empty():
		_busy = false
		return
	var job: Dictionary = _queue.pop_front()
	_queued_keys.erase(str(job.get("key", "")))
	await _render_job(job)
	_busy = false
	# Kick the next job on the following idle frame so we don't stack awaits.
	if not _queue.is_empty():
		call_deferred("_kick_queue")


func _kick_queue() -> void:
	if _busy or _queue.is_empty():
		return
	_busy = true
	_run_next_job()


## Read camera params from item specs (with defaults).
static func camera_from_specs(specs: Dictionary) -> Dictionary:
	return {
		"yaw": float(specs.get("card_preview_yaw_deg", DEFAULT_YAW_DEG)),
		"pitch": float(specs.get("card_preview_pitch_deg", DEFAULT_PITCH_DEG)),
		"dist": float(specs.get("card_preview_dist_mult", DEFAULT_DIST_MULT)),
	}


static func cache_key_for(model_id: String, yaw: float, pitch: float, dist: float) -> String:
	if model_id.is_empty():
		return ""
	# Quantize so tiny float noise doesn't thrash the cache.
	var y := int(round(yaw * 10.0))
	var p := int(round(pitch * 10.0))
	var d := int(round(dist * 100.0))
	var safe_id := model_id.validate_filename()
	if safe_id.is_empty():
		safe_id = str(model_id.hash())
	return "v%d_%s_y%d_p%d_d%d" % [PREVIEW_VERSION, safe_id, y, p, d]


static func cache_key_from_specs(specs: Dictionary) -> String:
	var mid := str(specs.get("model_id", ""))
	if mid.is_empty():
		return ""
	var cam := camera_from_specs(specs)
	return cache_key_for(mid, float(cam.yaw), float(cam.pitch), float(cam.dist))


## Synchronous lookup — returns cached texture or null (and queues a render).
func get_or_request(specs: Dictionary) -> ImageTexture:
	var mid := str(specs.get("model_id", ""))
	if mid.is_empty():
		return null
	var cam := camera_from_specs(specs)
	var key := cache_key_for(mid, float(cam.yaw), float(cam.pitch), float(cam.dist))
	if key.is_empty():
		return null
	if _mem.has(key):
		_touch_lru(key)
		return _mem[key] as ImageTexture
	# Try disk once before queuing.
	var disk := _load_disk(key)
	if disk != null:
		_store_mem(key, disk)
		return disk
	_enqueue(key, mid, float(cam.yaw), float(cam.pitch), float(cam.dist))
	return null


## A Process-lens icon: the model seen straight on (orthographic) from
## `view` (MimicIcons.VIEWS), redrawn in the picture's look
## (MimicIcons.stylize). `extras` = the placed prop's build options (a
## designed vehicle, dome, …). Returns the cached texture or null (and
## queues a render; `preview_ready` says when it lands).
func get_icon(model_id: String, view: String, extras: Dictionary = {}) -> ImageTexture:
	if model_id.is_empty():
		return null
	var key := icon_key(model_id, view, extras)
	if _mem.has(key):
		_touch_lru(key)
		return _mem[key] as ImageTexture
	if _failed.has(key):
		return null
	var disk := _load_disk(key)
	if disk != null:
		_store_mem(key, disk)
		return disk
	if not (_queued_keys.has(key)):
		_queued_keys[key] = true
		var cam := MimicIcons.camera(view)
		# Newest asks first: after a view switch the pictures now wanted are
		# drawn before what is left of the old view.
		_queue.push_front({"key": key, "model_id": model_id, "yaw": float(cam["yaw"]), "pitch": float(cam["pitch"]),
			"dist": DEFAULT_DIST_MULT, "icon": true, "extras": extras.duplicate(true)})
	return null


static func icon_key(model_id: String, view: String, extras: Dictionary = {}) -> String:
	var safe_id := model_id.validate_filename()
	if safe_id.is_empty():
		safe_id = str(model_id.hash())
	var xh := "" if extras.is_empty() else "_x%x" % (JSON.stringify(extras).hash() & 0x7fffffff)
	return "icon%d_%s_%s%s" % [MimicIcons.STYLE_VERSION, safe_id, view.validate_filename(), xh]


## Force a fresh render (inspector "Refresh preview").
func request_refresh(specs: Dictionary) -> void:
	var mid := str(specs.get("model_id", ""))
	if mid.is_empty():
		return
	var cam := camera_from_specs(specs)
	var key := cache_key_for(mid, float(cam.yaw), float(cam.pitch), float(cam.dist))
	invalidate_key(key)
	_enqueue(key, mid, float(cam.yaw), float(cam.pitch), float(cam.dist))


func invalidate_key(key: String) -> void:
	if key.is_empty():
		return
	_mem.erase(key)
	_mem_order.erase(key)
	var path := CACHE_DIR + key + ".png"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func invalidate_specs(specs: Dictionary) -> void:
	invalidate_key(cache_key_from_specs(specs))


# ---------------------------------------------------------------------------
# Studio
# ---------------------------------------------------------------------------

func _ensure_studio() -> void:
	if _viewport != null and is_instance_valid(_viewport):
		return
	_viewport = SubViewport.new()
	_viewport.name = "GraphModelPreviewVP"
	_viewport.size = Vector2i(PREVIEW_PX, PREVIEW_PX)
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.own_world_3d = true
	_viewport.disable_3d = false
	add_child(_viewport)

	_studio = Node3D.new()
	_studio.name = "Studio"
	_viewport.add_child(_studio)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.66, 0.72)
	env.ambient_light_energy = 0.55
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	_studio.add_child(world_env)

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-42, 38, 0)
	key_light.light_energy = 1.2
	key_light.shadow_enabled = false
	_studio.add_child(key_light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18, -135, 0)
	fill.light_energy = 0.35
	_studio.add_child(fill)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-10, 180, 0)
	rim.light_energy = 0.18
	_studio.add_child(rim)

	_holder = Node3D.new()
	_holder.name = "ModelHolder"
	_studio.add_child(_holder)

	_camera = Camera3D.new()
	_camera.fov = 42.0
	_camera.current = true
	_studio.add_child(_camera)


func _enqueue(key: String, model_id: String, yaw: float, pitch: float, dist: float) -> void:
	if key.is_empty() or _queued_keys.has(key) or _mem.has(key):
		return
	_queued_keys[key] = true
	_queue.append({
		"key": key,
		"model_id": model_id,
		"yaw": yaw,
		"pitch": pitch,
		"dist": dist,
	})


func _render_job(job: Dictionary) -> void:
	_ensure_studio()
	var key := str(job.get("key", ""))
	var model_id := str(job.get("model_id", ""))
	if key.is_empty() or model_id.is_empty() or _viewport == null:
		return
	# Clear previous model.
	for child in _holder.get_children():
		child.free()

	if bool(job.get("icon", false)):
		await _render_icon(job)
		return
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_viewport.size = Vector2i(PREVIEW_PX, PREVIEW_PX)
	var inst := ModelCatalog.instantiate(model_id)
	if inst == null:
		push_warning("GraphModelPreview: failed to instantiate '%s'" % model_id)
		return
	var s := ModelCatalog.resolved_scale(model_id, 1.0)
	inst.scale = Vector3.ONE * s
	inst.position.y = -ModelCatalog.foot_local_y(model_id) * s
	_holder.add_child(inst)

	var metrics := ModelCatalog.mesh_metrics(model_id)
	var unit_h := float(metrics.get("unit_height", 1.0)) * s
	var unit_w := float(metrics.get("width", 1.0)) * s
	var unit_d := float(metrics.get("depth", 1.0)) * s
	var size_m := maxf(unit_h, maxf(unit_w, unit_d))
	var target_y := unit_h * 0.45
	_place_camera(
		float(job.get("yaw", DEFAULT_YAW_DEG)),
		float(job.get("pitch", DEFAULT_PITCH_DEG)),
		float(job.get("dist", DEFAULT_DIST_MULT)),
		size_m, target_y)

	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	# One more frame helps some GLB materials settle.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await RenderingServer.frame_post_draw

	var vp_tex := _viewport.get_texture()
	if vp_tex == null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	var img := vp_tex.get_image()
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if img == null or img.is_empty():
		return
	# Free the instance so we don't keep GLBs in the studio.
	for child2 in _holder.get_children():
		child2.free()

	img.convert(Image.FORMAT_RGBA8)
	_save_disk(key, img)
	var tex := ImageTexture.create_from_image(img)
	_store_mem(key, tex)
	preview_ready.emit(key, tex)


func _render_icon(job: Dictionary) -> void:
	var key := str(job.get("key", ""))
	var model_id := str(job.get("model_id", ""))
	var t0 := Time.get_ticks_usec()
	var inst: Node3D = null
	inst = ModelCatalog.instantiate(model_id, job.get("extras", {}) as Dictionary)
	if inst == null:
		_failed[key] = true
		return
	var s := ModelCatalog.resolved_scale(model_id, 1.0)
	inst.scale = Vector3.ONE * s
	_holder.add_child(inst)
	var box := _visual_aabb(inst)
	if box.size.length() < 1e-4:
		for child in _holder.get_children():
			child.free()
		_failed[key] = true
		return
	_viewport.size = Vector2i(ICON_PX, ICON_PX)
	# Straight on: an orthographic camera on the model's middle, framing its
	# outline as seen from the view (the 8 corners on the camera's axes).
	var az := deg_to_rad(float(job.get("yaw", 90.0)))
	var el := deg_to_rad(clampf(float(job.get("pitch", 0.0)), -89.0, 89.0))
	var dir := Vector3(sin(az) * cos(el), sin(el), cos(az) * cos(el))
	var centre := box.get_center()
	var reach := box.size.length() * 2.0 + 1.0
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.position = centre + dir * reach
	var up := Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD
	_camera.look_at(centre, up)
	var right := _camera.global_transform.basis.x
	var cup := _camera.global_transform.basis.y
	var ext := 0.0
	for k in 8:
		var c := box.get_endpoint(k) - centre
		ext = maxf(ext, maxf(absf(c.dot(right)), absf(c.dot(cup))))
	_camera.size = maxf(ext * 2.0 * 1.06, 0.05)
	_camera.near = 0.01
	_camera.far = reach * 2.5
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var vp_tex := _viewport.get_texture()
	var img: Image = vp_tex.get_image() if vp_tex != null else null
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	for child2 in _holder.get_children():
		child2.free()
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_viewport.size = Vector2i(PREVIEW_PX, PREVIEW_PX)
	if img == null or img.is_empty():
		_failed[key] = true
		return
	# The restyling walks every pixel: off the main thread, so a render
	# never holds up a frame.
	var out := [null]
	var src := img
	var task := WorkerThreadPool.add_task(func() -> void: out[0] = MimicIcons.stylize(src))
	_tasks.append(task)
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	_tasks.erase(task)
	var icon: Image = out[0] as Image
	if icon == null or icon.is_empty():
		_failed[key] = true
		return
	_save_disk(key, icon)
	icons_rendered += 1
	last_icon_ms = float(Time.get_ticks_usec() - t0) / 1000.0
	icon.generate_mipmaps()
	var tex := ImageTexture.create_from_image(icon)
	_store_mem(key, tex)
	preview_ready.emit(key, tex)


## Everything drawn under `root`, in the studio's frame.
func _visual_aabb(root: Node) -> AABB:
	var have := false
	var box := AABB()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is VisualInstance3D and (n as Node3D).is_visible_in_tree() and not (n is Light3D):
			var vi := n as VisualInstance3D
			var b := vi.global_transform * vi.get_aabb()
			if b.size.length() > 1e-6:
				box = b if not have else box.merge(b)
				have = true
		for c in n.get_children():
			stack.append(c)
	return box


func _place_camera(yaw_deg: float, pitch_deg: float, dist_mult: float,
		size_m: float, target_y: float) -> void:
	if _camera == null:
		return
	var dist := clampf(size_m * maxf(dist_mult, 0.4), 0.5, 800.0)
	var az := deg_to_rad(yaw_deg)
	var el := deg_to_rad(clampf(pitch_deg, -80.0, 80.0))
	var target := Vector3(0.0, target_y, 0.0)
	_camera.position = target + Vector3(
		sin(az) * cos(el),
		sin(el),
		cos(az) * cos(el)) * dist
	_camera.look_at(target, Vector3.UP)


# ---------------------------------------------------------------------------
# Cache helpers
# ---------------------------------------------------------------------------

func _store_mem(key: String, tex: ImageTexture) -> void:
	if key.is_empty() or tex == null:
		return
	_mem[key] = tex
	_touch_lru(key)
	while _mem_order.size() > MAX_MEM_ENTRIES:
		var old: String = _mem_order.pop_front()
		_mem.erase(old)


func _touch_lru(key: String) -> void:
	_mem_order.erase(key)
	_mem_order.append(key)


func _disk_path(key: String) -> String:
	return CACHE_DIR + key + ".png"


func _load_disk(key: String) -> ImageTexture:
	var path := _disk_path(key)
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	if key.begins_with("icon"):
		img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _save_disk(key: String, img: Image) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	img.save_png(_disk_path(key))

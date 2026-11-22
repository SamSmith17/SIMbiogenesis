class_name ThumbRenderer
extends Node

## Pictures of 3D models for cards and lists, one a frame, cached on disk.
##
## `request(key, build, target)`: `key` names the look (the cache file),
## `build` returns the Node3D to shoot (called only on a cache miss),
## `target` is the TextureRect that gets the picture. A request whose target
## was freed meanwhile is dropped. Nothing renders headless or while the
## owner is hidden. (DesignGallery keeps its own, older copy of this studio.)

const THUMB_PX := Vector2i(320, 200)
const CACHE_DIR := "user://thumb_cache"
const CACHE_VERSION := 1

var id := "thumbs"

var _vp: SubViewport = null
var _holder: Node3D = null
var _cam: Camera3D = null
var _queue: Array = []
var _job: Dictionary = {}

static var _mem: Dictionary = {}


static func make(renderer_id: String) -> ThumbRenderer:
	var t := ThumbRenderer.new()
	t.id = renderer_id
	t.name = "ThumbRenderer"
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	t.set_process(false)
	return t


func request(key: String, build: Callable, target: TextureRect) -> void:
	if target == null or key.is_empty():
		return
	var k := "%s/%s" % [id, key.md5_text()]
	if _mem.has(k):
		target.texture = _mem[k]
		return
	_queue.append({"key": k, "build": build, "target": target})
	set_process(true)


func clear_queue() -> void:
	_queue.clear()


func pending() -> int:
	return _queue.size() + (0 if _job.is_empty() else 1)


func _visible() -> bool:
	var p := get_parent()
	return p is CanvasItem and (p as CanvasItem).is_visible_in_tree()


func _process(_delta: float) -> void:
	if DisplayServer.get_name() == "headless":
		_queue.clear()
		set_process(false)
		return
	if not _visible():
		return
	if not _job.is_empty():
		_job["wait"] = int(_job["wait"]) - 1
		if int(_job["wait"]) > 0:
			return
		var img := _vp.get_texture().get_image()
		var key := str(_job["key"])
		if img != null and not img.is_empty():
			_mem[key] = ImageTexture.create_from_image(img)
			DirAccess.make_dir_recursive_absolute("%s/v%d/%s" % [CACHE_DIR, CACHE_VERSION, id])
			img.save_png(_cache_path(key))
			_give(_job["target"], key)
		for c in _holder.get_children():
			_holder.remove_child(c)
			c.queue_free()
		_job = {}
		return
	while not _queue.is_empty():
		var q: Dictionary = _queue.pop_front()
		var target: Variant = q["target"]
		if not is_instance_valid(target):
			continue
		var key := str(q["key"])
		if _mem.has(key):
			_give(target, key)
			continue
		var path := _cache_path(key)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				_mem[key] = ImageTexture.create_from_image(img)
				_give(target, key)
				continue
		var build: Callable = q["build"]
		if not build.is_valid():
			continue
		var node: Variant = build.call()
		if not (node is Node3D):
			continue
		_ensure_studio()
		_holder.add_child(node as Node3D)
		if not _aim(node as Node3D):
			_holder.remove_child(node as Node3D)
			(node as Node3D).queue_free()
			continue
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		_job = {"key": key, "target": target, "wait": 3}
		return
	set_process(false)


func _give(target: Variant, key: String) -> void:
	if is_instance_valid(target) and target is TextureRect and _mem.has(key):
		(target as TextureRect).texture = _mem[key]


func _cache_path(key: String) -> String:
	return "%s/v%d/%s.png" % [CACHE_DIR, CACHE_VERSION, key]


func _ensure_studio() -> void:
	if _vp != null:
		return
	_vp = SubViewport.new()
	_vp.name = "ThumbStudio"
	_vp.size = THUMB_PX
	_vp.own_world_3d = true
	_vp.transparent_bg = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_vp)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0, 0, 0, 0)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.88, 0.91, 0.97)
	e.ambient_light_energy = 0.95
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = e
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 150, 0)
	sun.light_energy = 1.65
	_vp.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25, -35, 0)
	fill.light_energy = 0.55
	_vp.add_child(fill)
	_holder = Node3D.new()
	_vp.add_child(_holder)
	_cam = Camera3D.new()
	_cam.fov = 24.0
	_vp.add_child(_cam)


## Three-quarter view of the whole model. False when it draws nothing.
func _aim(node: Node3D) -> bool:
	var bb := DesignGallery.model_aabb(node)
	if bb.size.length() <= 0.0001:
		return false
	var r := bb.size.length() * 0.5
	var half_v := deg_to_rad(_cam.fov) * 0.5
	var half_h := atan(tan(half_v) * float(THUMB_PX.x) / float(THUMB_PX.y))
	var dist := r / sin(minf(half_v, half_h)) * 0.9
	var tgt := bb.get_center()
	var yaw := deg_to_rad(35.0)
	var pitch := deg_to_rad(18.0)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
	_cam.look_at_from_position(tgt + dir * dist, tgt, Vector3.UP)
	_cam.near = maxf(dist * 0.01, 0.005)
	_cam.far = dist * 3.0 + 50.0
	return true

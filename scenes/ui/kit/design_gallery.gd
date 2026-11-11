class_name DesignGallery
extends VBoxContainer

## A designer's "Start from" list: one pictured row per design (thumbnail,
## name, one line of what it is), the player's own designs under their own
## caption. Lifted from the vehicle designer so every designer has it.
##
## It answers the small part of ItemList the designers used, so swapping one
## in is a type change:
##
##   _design_list = DesignGallery.make("domelab")
##   _design_list.item_selected.connect(_on_design_activated)
##   ...
##   _design_list.clear()
##   _design_list.add_item("Geodesic 3V")          # "★ name" = the player's
##   _design_list.set_item_tooltip(i, blurb)
##   _design_list.set_item_subtitle(i, "6.0 m · 165 struts")
##   _design_list.get_selected_items()
##
## Pictures: `set_thumbnailer(func(i) -> {key, build})`. `key` names the
## design (its spec key); `build` returns a fresh Node3D of it. Each is drawn
## once in a small viewport of the gallery's own, one a frame at most, and
## kept in memory and under user://thumb_cache/<id>/. No thumbnailer (or a
## headless run) = text rows.

signal item_selected(index: int)
signal item_activated(index: int)

const THUMB_PX := Vector2i(192, 132)
const THUMB_SHOWN := Vector2(64, 44)
const ROW_H := 52.0
const ROW_H_TEXT := 30.0
const CACHE_DIR := "user://thumb_cache"
const CACHE_VERSION := 1
const MINE_PREFIX := "★ "

var id := "designs"
var item_count: int:
	get:
		return _rows.size()

var _rows: Array = []
var _selected := -1
var _thumb_fn := Callable()
var _mine_caption := false

var _vp: SubViewport = null
var _holder: Node3D = null
var _cam: Camera3D = null
var _queue: Array = []
var _job: Dictionary = {}

static var _mem: Dictionary = {}


static func make(gallery_id: String) -> DesignGallery:
	var g := DesignGallery.new()
	g.id = gallery_id
	g.name = "DesignGallery"
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("separation", 3)
	g.set_process(false)
	return g


func set_thumbnailer(fn: Callable) -> void:
	_thumb_fn = fn


# --- the ItemList subset ----------------------------------------------------

func clear() -> void:
	for c in get_children():
		if c == _vp:
			continue
		remove_child(c)
		c.queue_free()
	_rows.clear()
	_queue.clear()
	_selected = -1
	_mine_caption = false


## `with_picture` false = a text row even in a pictured gallery (a list
## entry that has nothing to draw).
func add_item(text: String, with_picture: bool = true) -> int:
	var mine := text.begins_with(MINE_PREFIX)
	var shown := text.substr(MINE_PREFIX.length()) if mine else text
	if mine and not _mine_caption:
		_mine_caption = true
		var cap := Label.new()
		cap.text = "Your designs"
		cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		add_child(cap)
	var i := _rows.size()
	var pictured := _thumb_fn.is_valid() and with_picture
	var b := Button.new()
	b.name = "design_%d" % i
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(0, ROW_H if pictured else ROW_H_TEXT)
	b.clip_contents = true
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(_on_row_pressed.bind(i))
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 4 if pictured else 8
	h.offset_right = -6
	h.add_theme_constant_override("separation", UITheme.SPACE_SM)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	var tr: TextureRect = null
	if pictured:
		tr = TextureRect.new()
		tr.custom_minimum_size = THUMB_SHOWN
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(tr)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(v)
	var nm := Label.new()
	nm.text = shown
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nm.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	if mine:
		nm.add_theme_color_override("font_color", UITheme.C_GOLD)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(nm)
	var sub := Label.new()
	sub.visible = false
	sub.clip_text = true
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sub.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(sub)
	b.tooltip_text = shown
	add_child(b)
	_rows.append({"btn": b, "name": nm, "sub": sub, "thumb": tr, "text": text, "key": ""})
	if pictured:
		_queue.append(i)
		set_process(true)
	return i


## A grey caption between rows ("Containers"); takes no index.
func add_caption(text: String) -> void:
	var cap := Label.new()
	cap.text = text
	cap.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	add_child(cap)


func ensure_current_is_visible() -> void:
	var b := row_button(_selected)
	var p: Node = get_parent()
	while b != null and p != null:
		if p is ScrollContainer:
			(p as ScrollContainer).ensure_control_visible.call_deferred(b)
			return
		p = p.get_parent()


func set_item_tooltip(i: int, tip: String) -> void:
	if i < 0 or i >= _rows.size():
		return
	var r: Dictionary = _rows[i]
	(r["btn"] as Button).tooltip_text = ("%s\n%s" % [(r["name"] as Label).text, tip]) if not tip.is_empty() else (r["name"] as Label).text


## The grey line under the name ("6.0 m · sleeps 2").
func set_item_subtitle(i: int, text: String) -> void:
	if i < 0 or i >= _rows.size():
		return
	var sub := (_rows[i] as Dictionary)["sub"] as Label
	sub.text = text
	sub.visible = not text.is_empty()


func get_item_text(i: int) -> String:
	return str((_rows[i] as Dictionary)["text"]) if i >= 0 and i < _rows.size() else ""


func get_selected_items() -> PackedInt32Array:
	return PackedInt32Array([_selected]) if _selected >= 0 else PackedInt32Array()


## ItemList compatibility: captions take no index, so no row is disabled.
func is_item_disabled(_i: int) -> bool:
	return false


func is_selected(i: int) -> bool:
	return i == _selected


## Mark a row without telling anyone (as ItemList.select does).
func select(i: int, _single: bool = true) -> void:
	_selected = i if i >= 0 and i < _rows.size() else -1
	_mark()


func deselect_all() -> void:
	_selected = -1
	_mark()


func row_button(i: int) -> Button:
	return (_rows[i] as Dictionary)["btn"] as Button if i >= 0 and i < _rows.size() else null


func has_thumbnail(i: int) -> bool:
	if i < 0 or i >= _rows.size():
		return false
	var tr := (_rows[i] as Dictionary)["thumb"] as TextureRect
	return tr != null and tr.texture != null


func thumbnails_pending() -> int:
	return _queue.size() + (0 if _job.is_empty() else 1)


func _on_row_pressed(i: int) -> void:
	_selected = i
	_mark()
	item_selected.emit(i)


func _mark() -> void:
	for i in _rows.size():
		((_rows[i] as Dictionary)["btn"] as Button).set_pressed_no_signal(i == _selected)


# --- thumbnails -------------------------------------------------------------

func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	if DisplayServer.get_name() == "headless" or not _thumb_fn.is_valid():
		_queue.clear()
		set_process(false)
		return
	if not _job.is_empty():
		_job["wait"] = int(_job["wait"]) - 1
		if int(_job["wait"]) > 0:
			return
		var img := _vp.get_texture().get_image()
		var key := str(_job["key"])
		if img != null and not img.is_empty():
			_mem[key] = ImageTexture.create_from_image(img)
			DirAccess.make_dir_recursive_absolute(_cache_dir())
			img.save_png(_cache_path(key))
			_show(int(_job["row"]), key)
		for c in _holder.get_children():
			_holder.remove_child(c)
			c.queue_free()
		_job = {}
		return
	while not _queue.is_empty():
		var i := int(_queue.pop_front())
		if i >= _rows.size():
			continue
		var info: Variant = _thumb_fn.call(i)
		if not (info is Dictionary) or (info as Dictionary).is_empty():
			continue
		var key := "%s/%s" % [id, str((info as Dictionary).get("key", "")).md5_text()]
		(_rows[i] as Dictionary)["key"] = key
		if _mem.has(key):
			_show(i, key)
			continue
		var path := _cache_path(key)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img != null and not img.is_empty():
				_mem[key] = ImageTexture.create_from_image(img)
				_show(i, key)
				continue
		var build: Callable = (info as Dictionary).get("build", Callable())
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
		_job = {"key": key, "row": i, "wait": 3}
		return
	set_process(false)


func _show(i: int, key: String) -> void:
	if i < 0 or i >= _rows.size():
		return
	var r: Dictionary = _rows[i]
	var tr := r["thumb"] as TextureRect
	if tr != null and str(r["key"]) == key and _mem.has(key):
		tr.texture = _mem[key]


func _cache_dir() -> String:
	return "%s/v%d/%s" % [CACHE_DIR, CACHE_VERSION, id]


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
	e.ambient_light_color = Color(0.85, 0.88, 0.95)
	e.ambient_light_energy = 0.75
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = e
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42, 150, 0)
	sun.light_energy = 1.4
	_vp.add_child(sun)
	_holder = Node3D.new()
	_vp.add_child(_holder)
	_cam = Camera3D.new()
	_cam.fov = 24.0
	_vp.add_child(_cam)


## Three-quarter view of the whole model. False when it draws nothing.
func _aim(node: Node3D) -> bool:
	var bb := model_aabb(node)
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


## A model's bounds from LOCAL transforms (it may not be in a tree yet).
static func model_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var any := false
	var stack: Array = [[root, root.transform]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var n := top[0] as Node
		var xf := top[1] as Transform3D
		if n.has_meta("studio_no_frame") or (n is Node3D and not (n as Node3D).visible):
			continue
		var bb := AABB()
		var has := false
		if n is MeshInstance3D:
			if (n as MeshInstance3D).mesh != null:
				bb = (n as MeshInstance3D).mesh.get_aabb()
				has = true
		elif n is MultiMeshInstance3D:
			if (n as MultiMeshInstance3D).multimesh != null:
				bb = (n as MultiMeshInstance3D).multimesh.get_aabb()
				has = true
		if has and bb.size.length() > 0.0:
			var w := xf * bb
			out = w if not any else out.merge(w)
			any = true
		for c in n.get_children():
			stack.append([c, xf * (c as Node3D).transform if c is Node3D else xf])
	return out

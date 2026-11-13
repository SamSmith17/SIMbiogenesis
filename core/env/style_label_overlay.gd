class_name StyleLabelOverlay
extends CanvasLayer
## Keeps world labels readable under a visual style (RenderStyle).
##
## The style's post pass runs after every 3D object is drawn and has no way to
## tell a label's pixels from water's (neither writes depth, and Label3D has no
## stencil hook), so it paints, bands and outlines text like everything else.
## While a style is on, every SCREEN-FACING Label3D in the main world (turbine
## status, NPC tags, POI pins, run lengths, beacons…) is hidden from the 3D
## cameras (layers = 0, put back exactly when the style goes off) and drawn
## here instead as 2D text at the same spot, size, colour and outline, on top
## of the styled image. Labels that are part of the world's art (billboard off:
## a sign's lettering) stay 3D and take the style like any surface.
##
## Depth-tested labels are hidden when a physics ray from the camera says
## something solid is in front (checked a few labels a frame, round robin).
##
## Only the main window shows the 2D copies: the graph's lens previews, extra
## Window Wall windows and video export do not show these labels while a style
## is on.

const META_LAYERS := &"style_label_orig_layers"
const RAYS_PER_FRAME := 24
const MIN_FONT_PX := 6
const MAX_FONT_PX := 160

var _main: Node
var _active := false
var _labels: Array = []          # Label3D we have hidden
var _occluded: Dictionary = {}   # instance id -> bool (depth-tested labels)
var _ray_i := 0
var _canvas: Control
var _items: Array = []           # this frame's draw list


func setup(main: Node) -> void:
	_main = main


func _ready() -> void:
	layer = -5
	name = "StyleLabelOverlay"
	set_meta(&"style_label_overlay", true)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_canvas = _Canvas.new()
	_canvas.overlay = self
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_canvas)
	get_tree().node_added.connect(_on_node_added)


func _exit_tree() -> void:
	set_active(false)


func set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	if on:
		if _main != null:
			for n in _main.find_children("*", "Label3D", true, false):
				_adopt(n as Label3D)
	else:
		for l in _labels:
			_release(l)
		_labels.clear()
		_occluded.clear()
		_items.clear()
		if _canvas != null:
			_canvas.queue_redraw()


func is_active() -> bool:
	return _active


## For probes.
func mirrored_count() -> int:
	return _labels.size()


func drawn_count() -> int:
	return _items.size()


func drawn_texts() -> Array:
	var out: Array = []
	for it in _items:
		out.append(String(it["text"]))
	return out


func _on_node_added(n: Node) -> void:
	if _active and n is Label3D:
		# The creator sets billboard / layers right after add_child.
		_adopt_later.call_deferred(n)


func _adopt_later(n: Node) -> void:
	if _active and is_instance_valid(n) and n.is_inside_tree():
		_adopt(n as Label3D)


func _eligible(l: Label3D) -> bool:
	if l == null or _main == null or not _main.is_ancestor_of(l):
		return false
	if l.has_meta(META_LAYERS):
		return false
	# Studios (modals, thumbnails) live in their own worlds.
	if l.get_viewport() != _main.get_viewport():
		return false
	return l.billboard != BaseMaterial3D.BILLBOARD_DISABLED


func _adopt(l: Label3D) -> void:
	if not _eligible(l):
		return
	l.set_meta(META_LAYERS, l.layers)
	l.layers = 0
	_labels.append(l)


func _release(l) -> void:
	if not is_instance_valid(l):
		return
	var lbl := l as Label3D
	if lbl.has_meta(META_LAYERS):
		lbl.layers = int(lbl.get_meta(META_LAYERS))
		lbl.remove_meta(META_LAYERS)


func _process(_delta: float) -> void:
	_items.clear()
	if not _active:
		return
	# Drop freed labels; take back any whose layers someone else rewrote.
	var keep: Array = []
	for l in _labels:
		if is_instance_valid(l):
			var lbl := l as Label3D
			if lbl.layers != 0:
				lbl.set_meta(META_LAYERS, lbl.layers)
				lbl.layers = 0
			keep.append(lbl)
	_labels = keep
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null or vp.disable_3d or not visible:
		_canvas.queue_redraw()
		return
	_update_occlusion(cam)
	var cam_inv := cam.global_transform.affine_inverse()
	var cam_up := cam.global_transform.basis.y.normalized()
	for l in _labels:
		var lbl := l as Label3D
		if not lbl.is_visible_in_tree() or lbl.text.is_empty():
			continue
		var orig := int(lbl.get_meta(META_LAYERS, 1))
		if (orig & cam.cull_mask) == 0:
			continue
		if bool(_occluded.get(lbl.get_instance_id(), false)):
			continue
		var p := lbl.global_position
		if cam.is_position_behind(p):
			continue
		var depth := -(cam_inv * p).z
		if depth <= cam.near:
			continue
		var c0 := cam.unproject_position(p)
		var c1 := cam.unproject_position(p + cam_up)
		var px_per_m := c0.distance_to(c1)
		if lbl.fixed_size:
			px_per_m *= depth
		var s := lbl.global_transform.basis.get_scale()
		var unit := lbl.pixel_size * ((absf(s.x) + absf(s.y)) * 0.5) * px_per_m
		var fpx := int(round(lbl.font_size * unit))
		if fpx < MIN_FONT_PX:
			continue
		fpx = mini(fpx, MAX_FONT_PX)
		var a := lbl.modulate.a * (1.0 - lbl.transparency)
		if a <= 0.01:
			continue
		var col := lbl.modulate
		col.a = a
		var ocol := lbl.outline_modulate
		ocol.a *= a
		_items.append({
			"text": lbl.text.to_upper() if lbl.uppercase else lbl.text,
			"at": c0 + Vector2(lbl.offset.x, -lbl.offset.y) * unit,
			"font": lbl.font,
			"px": fpx,
			"outline": int(round(lbl.outline_size * unit)),
			"col": col,
			"ocol": ocol,
			"halign": lbl.horizontal_alignment,
			"valign": lbl.vertical_alignment,
			"width": lbl.width * unit if lbl.autowrap_mode != TextServer.AUTOWRAP_OFF else -1.0,
			"spacing": lbl.line_spacing * unit,
			"depth": depth,
		})
	# Far first, so near labels sit on top.
	_items.sort_custom(func(x, y): return float(x["depth"]) > float(y["depth"]))
	_canvas.queue_redraw()


## Depth-tested labels: a ray from the camera to the label; anything solid in
## between hides it. A few labels a frame.
func _update_occlusion(cam: Camera3D) -> void:
	var tested: Array = []
	for l in _labels:
		if not (l as Label3D).no_depth_test:
			tested.append(l)
	if tested.is_empty():
		return
	var space := cam.get_world_3d().direct_space_state if cam.get_world_3d() != null else null
	if space == null:
		return
	var n := mini(RAYS_PER_FRAME, tested.size())
	var from := cam.global_position
	for _k in n:
		_ray_i = (_ray_i + 1) % tested.size()
		var lbl := tested[_ray_i] as Label3D
		var to := lbl.global_position
		var dir := to - from
		var dist := dir.length()
		if dist < 0.5:
			_occluded[lbl.get_instance_id()] = false
			continue
		var q := PhysicsRayQueryParameters3D.create(from, from + dir * ((dist - 0.4) / dist))
		q.collide_with_areas = false
		_occluded[lbl.get_instance_id()] = not space.intersect_ray(q).is_empty()


func _draw_items(ci: Control) -> void:
	var default_font := ThemeDB.fallback_font
	for it in _items:
		var font: Font = it["font"] if it["font"] != null else default_font
		var text := String(it["text"])
		var px := int(it["px"])
		var halign: int = it["halign"]
		var width := float(it["width"])
		var size := font.get_multiline_string_size(text, halign, width, px)
		var at: Vector2 = it["at"]
		var x := at.x
		match halign:
			HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_FILL:
				x -= size.x * 0.5
			HORIZONTAL_ALIGNMENT_RIGHT:
				x -= size.x
		var y := at.y
		match int(it["valign"]):
			VERTICAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_FILL:
				y -= size.y * 0.5
			VERTICAL_ALIGNMENT_BOTTOM:
				y -= size.y
		var pos := Vector2(x, y + font.get_ascent(px))
		var w := size.x if width < 0.0 else width
		var ol := int(it["outline"])
		if ol > 0 and (it["ocol"] as Color).a > 0.01:
			font.draw_multiline_string_outline(ci.get_canvas_item(), pos, text, halign, w, px, -1, ol, it["ocol"])
		font.draw_multiline_string(ci.get_canvas_item(), pos, text, halign, w, px, -1, it["col"])


class _Canvas extends Control:
	var overlay: StyleLabelOverlay

	func _draw() -> void:
		if overlay != null:
			overlay._draw_items(self)

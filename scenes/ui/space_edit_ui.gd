extends Control

## NPC Spaces dock — draw an AREA and tag it as a place people go.
##
## Toggle with Y (wired in terrain_loader._unhandled_input, the same way the
## camp-scatter dock takes C).
##
## Props and buildings are tagged where you already edit them, through the
## shared `NpcSpaceTagRow`. Areas have nowhere to live like that — there is no
## object to open — so they get this dock: pick a type, draw a polygon on the
## ground, and it becomes a `SpaceRegistry` target of kind "area".
##
## Areas are the right tool when the SPACE is the thing rather than the object:
## a fire circle is a patch of ground, a dining area is a stretch of shade, a
## wash station is wherever the buckets are today.

signal mode_changed(active: bool)

const MODAL_NAME := "npc_spaces"
const TIMELINE_CLEARANCE := 162.0
const PANEL_HEIGHT := 210.0
## Click nearer than this to the first point (in metres) to close the ring.
const CLOSE_SNAP_M := 3.0
const MIN_POINTS := 3

const C_PANEL := Color(0.082, 0.114, 0.208, 0.97)
const C_BORDER := Color(0.227, 0.290, 0.420, 1.0)
const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_DIM := Color(0.62, 0.68, 0.78, 1.0)

var _loader: Node = null
var _active := false
var _drawing := false
var _points: PackedVector2Array = PackedVector2Array()

var _type_option: OptionButton
var _capacity: SpinBox
var _draw_btn: Button
var _status: Label
var _list: VBoxContainer
var _overlay: Control


func bind_loader(loader: Node) -> void:
	_loader = loader


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()


func is_panel_open() -> bool:
	return _active


func toggle_mode() -> void:
	if _active:
		_exit_mode()
	else:
		_enter_mode()


func _enter_mode() -> void:
	if _registry() == null:
		return
	_active = true
	visible = true
	_cancel_drawing()
	_refresh_list()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_exit_mode"))
	mode_changed.emit(true)


func _exit_mode() -> void:
	if not _active:
		return
	_active = false
	visible = false
	_cancel_drawing()
	CursorController.release_modal(MODAL_NAME)
	mode_changed.emit(false)


# --- UI ---------------------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Overlay sits behind the panel and draws the in-progress ring in the world.
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)

	var panel := PanelContainer.new()
	var st := StyleBoxFlat.new()
	st.bg_color = C_PANEL
	st.border_color = C_BORDER
	st.set_border_width_all(1)
	st.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", st)
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 12
	panel.offset_right = -12
	panel.offset_top = -(PANEL_HEIGHT + TIMELINE_CLEARANCE)
	panel.offset_bottom = -TIMELINE_CLEARANCE
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 10)
	panel.add_child(margin)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	margin.add_child(v)

	var title := Label.new()
	title.text = "NPC Spaces — draw an area people go to"
	title.add_theme_color_override("font_color", C_TEXT)
	v.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)

	var tl := Label.new()
	tl.text = "Type"
	tl.add_theme_color_override("font_color", C_DIM)
	row.add_child(tl)

	_type_option = OptionButton.new()
	for i in SpaceTypes.TYPES.size():
		_type_option.add_item(SpaceTypes.label(SpaceTypes.TYPES[i]), i)
	_type_option.selected = 0
	row.add_child(_type_option)

	var cl := Label.new()
	cl.text = "Capacity"
	cl.add_theme_color_override("font_color", C_DIM)
	row.add_child(cl)

	_capacity = SpinBox.new()
	_capacity.min_value = 1
	_capacity.max_value = 64
	_capacity.value = 6      # areas hold more than a single fixture
	_capacity.custom_minimum_size.x = 66
	row.add_child(_capacity)

	_draw_btn = Button.new()
	_draw_btn.text = "Draw area"
	_draw_btn.pressed.connect(_on_draw_pressed)
	row.add_child(_draw_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var close_btn := Button.new()
	close_btn.text = "Close"
	close_btn.pressed.connect(_exit_mode)
	row.add_child(close_btn)

	_status = Label.new()
	_status.add_theme_color_override("font_color", C_DIM)
	_status.add_theme_font_size_override("font_size", 11)
	_status.text = "Pick a type, then Draw area. Click the ground to drop corners."
	v.add_child(_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)


func _registry() -> SpaceRegistry:
	if _loader == null or not is_instance_valid(_loader):
		return null
	var reg: Variant = _loader.get("npc_spaces")
	return reg as SpaceRegistry if reg is SpaceRegistry else null


func _selected_type() -> String:
	var i := _type_option.selected if _type_option != null else 0
	return str(SpaceTypes.TYPES[clampi(i, 0, SpaceTypes.TYPES.size() - 1)])


# --- drawing ----------------------------------------------------------------

func _on_draw_pressed() -> void:
	if _drawing:
		_cancel_drawing()
		return
	_drawing = true
	_points = PackedVector2Array()
	_draw_btn.text = "Cancel"
	_set_status("Click the ground to drop corners. Click the first corner (or right-click) to finish, Esc to cancel.")


func _cancel_drawing() -> void:
	_drawing = false
	_points = PackedVector2Array()
	if _draw_btn != null:
		_draw_btn.text = "Draw area"
	if _overlay != null:
		_overlay.queue_redraw()


func _pick_world(screen_pos: Vector2) -> Vector2:
	if _loader == null or not _loader.has_method("terrain_pick_ray"):
		return Vector2.INF
	var hit: Variant = _loader.call("terrain_pick_ray", screen_pos)
	if hit is Vector3:
		return Vector2((hit as Vector3).x, (hit as Vector3).z)
	return Vector2.INF


func _unhandled_input(event: InputEvent) -> void:
	if not _active or not _drawing:
		return
	if event.is_action_pressed("ui_cancel"):
		_cancel_drawing()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_overlay.queue_redraw()
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		_finish_area()
		get_viewport().set_input_as_handled()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	var p := _pick_world(mb.position)
	if p == Vector2.INF:
		return
	# Clicking back on the first corner closes the ring — the same gesture the
	# terrain dock's polygon tool uses, so it is already in the player's hands.
	if _points.size() >= MIN_POINTS and p.distance_to(_points[0]) < CLOSE_SNAP_M:
		_finish_area()
		get_viewport().set_input_as_handled()
		return
	_points.append(p)
	_set_status("%d corners — click the first corner or right-click to finish." % _points.size())
	_overlay.queue_redraw()
	get_viewport().set_input_as_handled()


func _finish_area() -> void:
	if _points.size() < MIN_POINTS:
		_set_status("An area needs at least %d corners." % MIN_POINTS)
		_cancel_drawing()
		return
	var reg := _registry()
	if reg == null:
		_cancel_drawing()
		return
	var poly: Array = []
	for p in _points:
		poly.append([p.x, p.y])
	reg.set_space_type({"kind": "area", "poly": poly}, _selected_type(),
			int(_capacity.value))
	if _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")
	var m2 := SpaceRegistry.polygon_area_m2(poly)
	_set_status("Added %s — %.0f m². People will gather here." % [
		SpaceTypes.label(_selected_type()), m2])
	_cancel_drawing()
	_refresh_list()


# --- list -------------------------------------------------------------------

func _refresh_list() -> void:
	if _list == null:
		return
	for c in _list.get_children():
		c.queue_free()
	var reg := _registry()
	if reg == null:
		return
	var any := false
	for rec_v in reg.spaces:
		var rec: Dictionary = rec_v
		var target: Dictionary = rec.get("target", {})
		if str(target.get("kind", "")) != "area":
			continue
		any = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var lbl := Label.new()
		lbl.text = "%s  %s  ·  %.0f m²  ·  cap %d" % [
			SpaceTypes.icon(str(rec.get("space_type", ""))),
			SpaceTypes.label(str(rec.get("space_type", ""))),
			SpaceRegistry.polygon_area_m2(target.get("poly", []) as Array),
			int(rec.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))]
		lbl.add_theme_color_override("font_color", C_TEXT)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)
		var del := Button.new()
		del.text = "Delete"
		var sid := str(rec.get("id", ""))
		del.pressed.connect(func() -> void: _delete_space(sid))
		row.add_child(del)
		_list.add_child(row)
	if not any:
		var empty := Label.new()
		empty.text = "No areas yet."
		empty.add_theme_color_override("font_color", C_DIM)
		_list.add_child(empty)


func _delete_space(space_id: String) -> void:
	var reg := _registry()
	if reg == null:
		return
	reg.remove_space(space_id)
	if _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")
	_refresh_list()
	_overlay.queue_redraw()


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t


# --- overlay ----------------------------------------------------------------

func _draw_overlay() -> void:
	if not _active:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null or _loader == null:
		return
	# Existing areas, so you can see what is already tagged while adding more.
	var reg := _registry()
	if reg != null:
		for rec_v in reg.spaces:
			var rec: Dictionary = rec_v
			var target: Dictionary = rec.get("target", {})
			if str(target.get("kind", "")) != "area":
				continue
			var col := SpaceTypes.color(str(rec.get("space_type", "")))
			col.a = 0.55
			_draw_world_ring(cam, SpaceRegistry.poly_points(target.get("poly", []) as Array),
					col, true)
	if not _drawing or _points.is_empty():
		return
	var live := _points.duplicate()
	var cursor := _pick_world(get_viewport().get_mouse_position())
	if cursor != Vector2.INF:
		live.append(cursor)
	_draw_world_ring(cam, live, SpaceTypes.color(_selected_type()), live.size() >= MIN_POINTS)
	for p in _points:
		var sp := _to_screen(cam, p)
		if sp != Vector2.INF:
			_overlay.draw_circle(sp, 4.0, Color(1, 1, 1, 0.9))


func _to_screen(cam: Camera3D, p: Vector2) -> Vector2:
	var y := float(_loader.call("ground_height_at", p.x, p.y)) if _loader.has_method("ground_height_at") else 0.0
	var wp := Vector3(p.x, y + 0.35, p.y)
	if cam.is_position_behind(wp):
		return Vector2.INF
	return cam.unproject_position(wp)


## Draws a ring by projecting each corner onto the terrain, so the outline
## follows the ground instead of floating as a flat plane over rolling terrain.
func _draw_world_ring(cam: Camera3D, pts: PackedVector2Array, col: Color, closed: bool) -> void:
	if pts.size() < 2:
		return
	var screen := PackedVector2Array()
	for p in pts:
		var sp := _to_screen(cam, p)
		if sp == Vector2.INF:
			return
		screen.append(sp)
	if closed:
		screen.append(screen[0])
	_overlay.draw_polyline(screen, col, 2.0, true)


func _process(_delta: float) -> void:
	if _active and _drawing:
		_overlay.queue_redraw()

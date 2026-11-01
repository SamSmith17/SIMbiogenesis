class_name Drawer
extends PanelContainer

## THE bottom drawer: a strip above the timeline bar for ONE object the
## player clicked in the world — the pond settings, the vegetation area
## fill. A title and subtitle with THE close button across the top, columns
## of rows across the body (`body`, an HBox the owner fills with VBox
## columns of `FormRow`s), the actions stacked on the right (`actions`:
## PRIMARY / SECONDARY / DESTRUCTIVE as ModalFrame). It owns the contract a
## drawer kept getting half right: it is pinned above the timeline bar's
## LIVE height, sized to what it holds (a fixed height grew DOWN over the
## bar when a row was added), re-laid on every resize, the cursor modal
## while open (Esc closes), and the HUD's bottom-left region pushed up out
## from under it. It is NOT a modal to the UI audit (no `ui_modal` meta): a
## drawer that grows into the bar must still fail.
##
##   var d := Drawer.create("Pond settings", "pond_edit")
##   layer.add_child(d)
##   d.body.add_child(column)          # a VBox of FormRows
##   d.add_action("Add to graph", Drawer.PRIMARY, _on_graph)
##   d.set_title("Pond 3", "640 m² · rim 12.4 m")
##   d.open()

signal closed

enum { PRIMARY, SECONDARY, DESTRUCTIVE }

const MIN_H := 120.0
const HUD_GAP := 8.0

var body: HBoxContainer = null
var actions: VBoxContainer = null
var title_label: Label = null
var subtitle_label: Label = null
var header: HBoxContainer = null
var drawer_name := "drawer"

var _is_open := false
var _close_btn: Button = null


static func create(title: String, name_id: String = "", opts: Dictionary = {}) -> Drawer:
	var d := Drawer.new()
	d.drawer_name = name_id if not name_id.is_empty() else "drawer_" + title.to_snake_case()
	d._build(title, opts)
	return d


func _build(title: String, _opts: Dictionary) -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var style := UITheme.panel_style(0.98)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	add_theme_stylebox_override("panel", style)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_XS)
	add_child(root)
	header = HBoxContainer.new()
	header.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(header)
	title_label = Label.new()
	title_label.text = title
	title_label.add_theme_font_override("font", UITheme.font("semibold"))
	title_label.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	title_label.add_theme_color_override("font_color", UITheme.C_TEXT)
	# No trimming on the title: a trimmed Label's minimum width is 0, and the
	# expanding subtitle beside it took every pixel (the title vanished).
	header.add_child(title_label)
	subtitle_label = Label.new()
	subtitle_label.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	subtitle_label.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	subtitle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	subtitle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	subtitle_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	subtitle_label.mouse_filter = Control.MOUSE_FILTER_PASS
	subtitle_label.mouse_entered.connect(func() -> void: subtitle_label.tooltip_text = subtitle_label.text)
	header.add_child(subtitle_label)
	_close_btn = IconButton.close(close)
	header.add_child(_close_btn)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_LG)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(row)
	body = HBoxContainer.new()
	body.add_theme_constant_override("separation", UITheme.SPACE_LG)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(body)
	actions = VBoxContainer.new()
	actions.add_theme_constant_override("separation", UITheme.SPACE_XS)
	actions.size_flags_horizontal = Control.SIZE_SHRINK_END
	actions.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(actions)
	minimum_size_changed.connect(func() -> void: _layout.call_deferred())
	visibility_changed.connect(_layout)


## A column of rows for `body`.
static func column(min_w: float = 0.0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UITheme.SPACE_XS)
	v.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if min_w > 0.0:
		v.custom_minimum_size.x = min_w
	return v


func set_title(title: String, sub: String = "") -> void:
	title_label.text = title
	subtitle_label.text = sub


## An action button on the right.
func add_action(text: String, kind: int, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(150, 30)
	UITheme.style_button(b)
	match kind:
		PRIMARY:
			b.add_theme_color_override("font_color", UITheme.C_PRIMARY)
		DESTRUCTIVE:
			b.add_theme_color_override("font_color", UITheme.C_ERROR)
	if cb.is_valid():
		b.pressed.connect(cb)
	actions.add_child(b)
	return b


func open() -> void:
	if _is_open:
		return
	_is_open = true
	visible = true
	_layout()
	CursorController.request_modal(drawer_name, close)
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_layout):
		vp.size_changed.connect(_layout)


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	visible = false
	CursorController.release_modal(drawer_name)
	HudLayout.release(drawer_name)
	closed.emit()


func is_open() -> bool:
	return _is_open


func _exit_tree() -> void:
	if _is_open:
		CursorController.release_modal(drawer_name)
		HudLayout.release(drawer_name)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout()


## The one rule: as tall as its rows, pinned to the timeline bar's live top,
## the HUD's bottom pushed up by the same.
func _layout() -> void:
	if not is_inside_tree() or not visible:
		return
	var clearance := UiScreenLayout.timeline_stack_height()
	var tl := ServiceLocator.timeline_ui()
	if tl != null and is_instance_valid(tl) and tl.has_method("get_stack_height"):
		clearance = float(tl.call("get_stack_height"))
	var h := maxf(MIN_H, get_combined_minimum_size().y)
	UiScreenLayout.pin_above_timeline(self, h, clearance)
	HudLayout.claim(drawer_name, {"inset": {"bottom": h + HUD_GAP}})

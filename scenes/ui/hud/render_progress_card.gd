class_name RenderProgressCard
extends PanelContainer

## The sim pre-render's progress, top-centre of the HUD while a render runs:
## what is being rendered, a bar, the percentage, the time left, Cancel.
## Registered with HudLayout (not tuckable — it is the thing the player is
## waiting on), so it never overlaps the other top-centre chips. Owned by the
## timeline bar, which connects it to SystemGraphView.sim_renderer()'s signals.

signal cancel_requested

const CARD_W := 300.0

var _title: Label
var _range: Label
var _bar: ProgressBar
var _pct: Label
var _eta: Label
var _cancel: Button


func _ready() -> void:
	name = "RenderProgressCard"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UITheme.panel_style(0.94, UITheme.C_PANEL_RAISED))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	box.custom_minimum_size = Vector2(CARD_W, 0.0)
	add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UITheme.SPACE_SM)
	box.add_child(head)
	var icon := TextureRect.new()
	icon.texture = UiIcons.icon("film", 16)
	icon.modulate = UITheme.C_PRIMARY
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.custom_minimum_size = Vector2(16, 16)
	head.add_child(icon)
	_title = Label.new()
	_title.text = "Rendering simulation"
	_title.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_title.add_theme_font_override("font", UITheme.font("semibold"))
	_title.add_theme_color_override("font_color", UITheme.C_TEXT)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_cancel = IconButton.make("x", "Cancel the render (what is done so far is kept)",
		func() -> void: cancel_requested.emit())
	head.add_child(_cancel)

	_range = Label.new()
	_range.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_range.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_range.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	box.add_child(_range)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.001
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(CARD_W, 8.0)
	UITheme.style_progress(_bar, UITheme.C_PRIMARY)
	box.add_child(_bar)

	var foot := HBoxContainer.new()
	box.add_child(foot)
	_pct = Label.new()
	_pct.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_pct.add_theme_font_override("font", UITheme.font("regular", true))
	_pct.add_theme_color_override("font_color", UITheme.C_TEXT)
	_pct.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(_pct)
	_eta = Label.new()
	_eta.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_eta.add_theme_font_override("font", UITheme.font("regular", true))
	_eta.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_eta.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	foot.add_child(_eta)

	HudLayout.register(self, "sim_render", "top_center", {"order": 0, "tuckable": false,
		"title": "Rendering", "icon": "film",
		"size": func() -> Vector2: return get_combined_minimum_size()})


## A render began over `range_text` (e.g. "Oct 17 14:00 → Oct 18 14:00 · 24 h").
func show_render(range_text: String) -> void:
	_range.text = range_text
	_bar.value = 0.0
	_pct.text = "0 %"
	_eta.text = "starting…"
	visible = true


func set_progress(frac: float, eta_s: float) -> void:
	_bar.value = clampf(frac, 0.0, 1.0)
	_pct.text = UiText.pct(clampf(frac, 0.0, 1.0))
	if is_nan(eta_s) or eta_s < 0.0:
		_eta.text = ""
	elif eta_s < 1.5:
		_eta.text = "almost done"
	else:
		_eta.text = "about %s left" % UiText.duration(eta_s / 3600.0)


## The render finished or was cancelled: the card goes; the timeline's green
## strip now says what is rendered.
func finish() -> void:
	visible = false

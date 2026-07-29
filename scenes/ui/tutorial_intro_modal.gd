class_name TutorialIntroModal
extends Control

## First-load query for new players: start the Solar Bootcamp tutorial (gated
## library, guided levels) or skip it (everything unlocked immediately).
## Shown once — either answer persists via ProgressStore, and returning
## players re-enter the bootcamp any time from the timeline's 🎓 entry.

signal start_requested
signal skip_requested

const MODAL_NAME := "tutorial_intro"
const PANEL_SIZE := Vector2(520.0, 330.0)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build_ui()


func open() -> void:
	visible = true
	move_to_front()
	CursorController.request_modal(MODAL_NAME, Callable(self, "_on_skip"))


func close() -> void:
	visible = false
	CursorController.release_modal(MODAL_NAME)


func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0.0, 0.0, 0.0, 0.6)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", UITheme.panel_style(0.98))
	add_child(panel)
	UiScreenLayout.clamped_center(panel, PANEL_SIZE)

	var outer := MarginContainer.new()
	outer.add_theme_constant_override("margin_left", UITheme.SPACE_LG)
	outer.add_theme_constant_override("margin_right", UITheme.SPACE_LG)
	outer.add_theme_constant_override("margin_top", UITheme.SPACE_MD)
	outer.add_theme_constant_override("margin_bottom", UITheme.SPACE_MD)
	panel.add_child(outer)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", UITheme.SPACE_MD)
	outer.add_child(root)

	var title := Label.new()
	title.text = "🎓  New here? Learn solar from the battery up"
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(title)

	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_color_override("default_color", UITheme.C_TEXT)
	body.text = ("The [b]Solar Bootcamp[/b] teaches the systems graph by " +
		"building a real off-grid power system one component at a time — " +
		"short circuits, charge controllers, series vs parallel, inverters. " +
		"Completing levels unlocks new components in the Library.\n\n" +
		"[color=#8899aa]Already know your way around a charge controller? " +
		"Skip to unlock the full component library immediately — the bootcamp " +
		"stays available from the timeline's 🎓 button.[/color]")
	root.add_child(body)

	var btn_row := HBoxContainer.new()
	btn_row.alignment = BoxContainer.ALIGNMENT_END
	btn_row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	root.add_child(btn_row)

	var skip_btn := Button.new()
	skip_btn.text = "Skip — unlock everything"
	UITheme.style_button(skip_btn)
	skip_btn.pressed.connect(_on_skip)
	btn_row.add_child(skip_btn)

	var start_btn := Button.new()
	start_btn.text = "Start Solar Bootcamp"
	UITheme.style_button(start_btn)
	start_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	start_btn.pressed.connect(_on_start)
	btn_row.add_child(start_btn)


func _on_start() -> void:
	ProgressStore.mark_prompt_seen()
	close()
	start_requested.emit()


func _on_skip() -> void:
	ProgressStore.unlock_all()
	close()
	skip_requested.emit()

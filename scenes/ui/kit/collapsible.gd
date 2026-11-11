class_name Collapsible
extends FoldableContainer

## THE collapsible section: Godot's FoldableContainer, styled by the shared
## Theme (UiThemeBuilder: a quiet title row with a Lucide chevron, small
## semibold caps, no box round the body), holding one VBox `body` the caller
## fills. Replaces the hand-rolled "▸ Title" / "▾ Title" toggle buttons that
## each kept their own open flag and redrew their own arrow.
##
##   var sec := Collapsible.make("Advanced", false)
##   parent.add_child(sec)
##   sec.body.add_child(row)
##   sec.folding_changed.connect(func(folded): _save_open(not folded))
##
## A folded section can say what is in it (`set_summary("3V · 6.0 m")`, shown
## on the title row only while folded), and remember the player's choice
## (`persist("domelab", "size")` → ui_prefs.cfg [folds]). `make`'s `open` is
## then the default for a player who never touched it.

const PREFS_PATH := "user://ui_prefs.cfg"
const PREFS_SECTION := "folds"

## Harness runs measure the DEFAULT folds: the player's saved ones are neither
## read nor written while this is set.
static var ignore_saved := false
## SettingFinder opens sections to show matches; those are not the player's.
static var saving_paused := false

var body: VBoxContainer

var _summary_lbl: Label = null
var _pref_key := ""


static func make(title_text: String, open: bool = true, tip: String = "") -> Collapsible:
	var c := Collapsible.new()
	c.title = title_text
	c.folded = not open
	c.tooltip_text = tip
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.body = VBoxContainer.new()
	c.body.add_theme_constant_override("separation", UITheme.SPACE_XS)
	c.body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_child(c.body)
	return c


func is_open() -> bool:
	return not folded


func set_open(open: bool) -> void:
	folded = not open


## One line of what the section holds, on the title row while it is folded.
func set_summary(text: String) -> void:
	if _summary_lbl == null:
		if text.is_empty():
			return
		_summary_lbl = Label.new()
		_summary_lbl.name = "Summary"
		_summary_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		_summary_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_summary_lbl.clip_text = true
		_summary_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_summary_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_summary_lbl.custom_minimum_size = Vector2(150, 0)
		_summary_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_title_bar_control(_summary_lbl)
		folding_changed.connect(func(_f: bool) -> void: _sync_summary())
	if _summary_lbl.text != text:
		_summary_lbl.text = text
	_sync_summary()


func summary() -> String:
	return _summary_lbl.text if _summary_lbl != null else ""


func _sync_summary() -> void:
	if _summary_lbl != null:
		_summary_lbl.visible = folded and not _summary_lbl.text.is_empty()


## Remember the player's fold for this section across sessions. Returns self.
func persist(modal_id: String, section_id: String) -> Collapsible:
	_pref_key = "%s/%s" % [modal_id, section_id]
	if not ignore_saved:
		var cf := ConfigFile.new()
		if cf.load(PREFS_PATH) == OK and cf.has_section_key(PREFS_SECTION, _pref_key):
			folded = not bool(cf.get_value(PREFS_SECTION, _pref_key))
	folding_changed.connect(_on_fold_for_prefs)
	_sync_summary()
	return self


func _on_fold_for_prefs(is_folded: bool) -> void:
	if ignore_saved or saving_paused or _pref_key.is_empty():
		return
	var cf := ConfigFile.new()
	cf.load(PREFS_PATH)
	cf.set_value(PREFS_SECTION, _pref_key, not is_folded)
	cf.save(PREFS_PATH)


## Every section under `root` open (or folded): the "Expand all" button.
static func set_all(root: Node, open: bool) -> void:
	if root == null:
		return
	for n in root.find_children("*", "FoldableContainer", true, false):
		(n as FoldableContainer).folded = not open

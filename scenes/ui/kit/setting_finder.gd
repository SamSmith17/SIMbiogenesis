class_name SettingFinder
extends HBoxContainer

## "Find a setting": a search box at the top of a designer's settings column.
## Typing filters the rows of every Collapsible section in that column by
## their words (labels, button texts, tooltips), opens the sections that hold
## a match and hides the rest; clearing puts everything back as it was.
## Beside it, one button opens or folds every section.
##
##   column.add_child(SettingFinder.make(column))      # first child
##
## A "row" is a direct child of a section's body (a FormRow, a hand-built
## HBox, a grid); plain VBoxes are looked into. Only what the finder itself
## hid or opened is restored, so a designer's own show / hide rules stand.

signal filtered(query: String, matches: int)

var edit: LineEdit = null
var fold_btn: Button = null

var _column: Control = null
var _hidden: Array = []
var _opened: Array = []
var _none: Label = null
var _all_open := false


static func make(column: Control, placeholder: String = "Find a setting") -> SettingFinder:
	var f := SettingFinder.new()
	f.name = "SettingFinder"
	f._column = column
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f.add_theme_constant_override("separation", UITheme.SPACE_XS)
	f.edit = LineEdit.new()
	f.edit.name = "find_setting"
	f.edit.placeholder_text = placeholder
	f.edit.clear_button_enabled = true
	f.edit.right_icon = UiIcons.icon("search", 14)
	f.edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	f.edit.text_changed.connect(f.apply)
	f.add_child(f.edit)
	f.fold_btn = IconButton.make("chevrons-up-down", "Open every section", f._toggle_all)
	f.fold_btn.name = "expand_all"
	f.add_child(f.fold_btn)
	return f


## Filter by `query` ("" restores). Returns the number of matching rows.
func apply(query: String) -> int:
	_restore()
	var words := _words(query)
	if words.is_empty() or _column == null:
		filtered.emit("", 0)
		return 0
	var total := 0
	Collapsible.saving_paused = true
	total = _filter_column(_column, words)
	Collapsible.saving_paused = false
	if total == 0:
		if _none == null:
			_none = Label.new()
			_none.add_theme_font_size_override("font_size", UITheme.FONT_SM)
			_none.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			_none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_column.add_child(_none)
			_column.move_child(_none, get_index() + 1)
		_none.text = "No setting matches “%s”." % query.strip_edges()
		_none.visible = true
	filtered.emit(query, total)
	return total


func _filter_column(box: Control, words: PackedStringArray) -> int:
	var total := 0
	for c in box.get_children():
		if c == self or c == _none or not (c is Control) or not (c as Control).visible:
			continue
		if c is FoldableContainer:
			total += _filter_section(c as FoldableContainer, words)
		elif c.get_child_count() == 1 and c.get_child(0) is FoldableContainer:
			# A section in a card: the card goes when the section has no match.
			var n := _filter_section(c.get_child(0) as FoldableContainer, words)
			if n == 0:
				_hide(c as Control)
			total += n
		elif c is VBoxContainer and not (c as Node).find_children("*", "FoldableContainer", false, false).is_empty():
			# A group of sections (one per tab): look inside it.
			total += _filter_column(c as Control, words)
		else:
			# Tiles, checks, lists: not settings. Out of the way while searching.
			_hide(c as Control)
	return total


func clear() -> void:
	if not edit.text.is_empty():
		edit.text = ""
	apply("")


func _filter_section(sec: FoldableContainer, words: PackedStringArray) -> int:
	# A match on the section's own title shows all of it.
	var whole := _matches(sec.title.to_lower(), words)
	var n := 0
	for body in sec.get_children():
		if body is Control:
			n += _filter_rows(body as Control, words, whole)
	if n == 0:
		_hide(sec)
		return 0
	if sec.folded:
		sec.folded = false
		_opened.append(sec)
	return n


func _filter_rows(box: Control, words: PackedStringArray, keep_all: bool) -> int:
	var n := 0
	for r in box.get_children():
		if not (r is Control) or not (r as Control).visible:
			continue
		if r is FoldableContainer:
			n += _filter_section(r as FoldableContainer, words)
		elif (r is VBoxContainer and not (r is FormRow)) or (r is MarginContainer and r.get_child_count() == 1):
			var inner := _filter_rows(r as Control, words, keep_all)
			if inner == 0:
				_hide(r as Control)
			n += inner
		elif keep_all or _matches(_text_of(r as Control), words):
			n += 1
		else:
			_hide(r as Control)
	return n


func _hide(c: Control) -> void:
	c.visible = false
	_hidden.append(c)


func _restore() -> void:
	for c in _hidden:
		if is_instance_valid(c):
			(c as Control).visible = true
	_hidden.clear()
	Collapsible.saving_paused = true
	for s in _opened:
		if is_instance_valid(s):
			(s as FoldableContainer).folded = true
	Collapsible.saving_paused = false
	_opened.clear()
	if _none != null:
		_none.visible = false


func _toggle_all() -> void:
	_all_open = not _all_open
	Collapsible.set_all(_column, _all_open)
	fold_btn.tooltip_text = "Fold every section" if _all_open else "Open every section"


static func _words(query: String) -> PackedStringArray:
	var out := PackedStringArray()
	for w in query.to_lower().split(" ", false):
		out.append(w)
	return out


static func _matches(text: String, words: PackedStringArray) -> bool:
	for w in words:
		if not text.contains(w):
			return false
	return true


## Every word a row shows or explains, lower case.
static func _text_of(row: Control) -> String:
	var parts := PackedStringArray([row.tooltip_text])
	var stack: Array = [row]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Label:
			parts.append((n as Label).text)
		elif n is OptionButton:
			pass
		elif n is BaseButton and "text" in n:
			parts.append(str(n.get("text")))
		elif n is LineEdit:
			parts.append((n as LineEdit).placeholder_text)
		if n is Control and n != row:
			parts.append((n as Control).tooltip_text)
		for c in n.get_children():
			stack.append(c)
	return " ".join(parts).to_lower()

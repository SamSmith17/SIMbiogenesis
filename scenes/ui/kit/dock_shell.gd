class_name DockShell
extends RefCounted

## The header row every right-hand dock shares (prop editor, Light Studio,
## microclimate drawer, the settlement work dock): a title, an optional
## muted subtitle under it, any extra controls the dock wants beside the
## title, and THE close button on the right. Before the kit each dock built
## its own — different title sizes, a close button in three styles, and
## subtitles that ran past the dock edge instead of ellipsizing.
##
##   var head := DockShell.header("Light Studio", "", close, [night_btn])
##   outer.add_child(head["row"])
##   (head["subtitle"] as Label).text = "Halvorsen dock · placed"
##
## Returns {row: HBoxContainer, title: Label, subtitle: Label, close: Button}.

static func header(title: String, subtitle: String = "", on_close: Callable = Callable(),
		extras: Array = []) -> Dictionary:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_SM)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_theme_constant_override("separation", 0)
	row.add_child(titles)
	var t := Label.new()
	t.text = title
	t.add_theme_font_override("font", UITheme.font("semibold"))
	t.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	t.add_theme_color_override("font_color", UITheme.C_TEXT)
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.clip_text = true
	titles.add_child(t)
	var st := Label.new()
	st.text = subtitle
	st.visible = not subtitle.is_empty()
	st.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	st.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	st.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	st.clip_text = true
	titles.add_child(st)
	for e in extras:
		if e is Control:
			(e as Control).size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(e)
	var close: Button = null
	if on_close.is_valid():
		close = IconButton.close(on_close)
		close.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		row.add_child(close)
	return {"row": row, "title": t, "subtitle": st, "close": close}


## Set a header's subtitle, hiding the line when it is empty.
static func set_subtitle(head: Dictionary, text: String) -> void:
	var st: Label = head.get("subtitle")
	if st == null:
		return
	st.text = text
	st.visible = not text.is_empty()
	st.tooltip_text = text

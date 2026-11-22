class_name StatTiles
extends GridContainer

## Headline tiles: the four to six numbers a design is judged by, at the top
## of a designer's right column (lifted from the vehicle designer).
##
##   _tiles = StatTiles.make(3)
##   column.add_child(_tiles)
##   _tiles.set_tiles([
##       {"caption": "Diameter", "value": "6.0 m", "tip": "Across the base"},
##       {"caption": "Struts", "value": "65", "level": "warn"}])
##
## `level` "ok" | "warn" | "error" | "muted" colours the value; `color` sets
## it outright. Tiles are reused while the count holds, so a refresh on every
## edit does not rebuild anything.

var _tiles: Array = []


static func make(cols: int = 3) -> StatTiles:
	var g := StatTiles.new()
	g.name = "StatTiles"
	g.columns = cols
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	g.add_theme_constant_override("v_separation", UITheme.SPACE_XS)
	return g


func set_tiles(tiles: Array) -> void:
	if tiles.size() != _tiles.size():
		for c in get_children():
			remove_child(c)
			c.queue_free()
		_tiles.clear()
		for i in tiles.size():
			_tiles.append(_make_tile())
	for i in tiles.size():
		var t: Dictionary = tiles[i]
		var w: Dictionary = _tiles[i]
		var cap := str(t.get("caption", ""))
		var val := str(t.get("value", ""))
		if (w["cap"] as Label).text != cap:
			(w["cap"] as Label).text = cap
		if (w["val"] as Label).text != val:
			(w["val"] as Label).text = val
			var fsz := UITheme.FONT_LG
			if val.length() >= 18:
				fsz = UITheme.FONT_SM
			elif val.length() >= 12:
				fsz = UITheme.FONT_MD
			(w["val"] as Label).add_theme_font_size_override("font_size", fsz)
		var tip := str(t.get("tip", ""))
		(w["panel"] as Control).tooltip_text = tip if not tip.is_empty() else "%s: %s" % [cap, val]
		(w["val"] as Label).add_theme_color_override("font_color", _color(t))


## The tiles as [caption, value] pairs (for checks).
func values() -> Array:
	var out: Array = []
	for w0 in _tiles:
		var w: Dictionary = w0
		out.append([(w["cap"] as Label).text, (w["val"] as Label).text])
	return out


func _color(t: Dictionary) -> Color:
	if t.has("color"):
		return t["color"]
	match str(t.get("level", "")):
		"ok":
			return UITheme.C_OK
		"warn":
			return UITheme.C_WARN
		"error":
			return UITheme.C_ERROR
		"muted":
			return UITheme.C_TEXT_M
	return UITheme.C_TEXT


func _make_tile() -> Dictionary:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UITheme.card_style())
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	var c := Label.new()
	c.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	c.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	c.clip_text = true
	c.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(c)
	var val := Label.new()
	val.add_theme_font_override("font", UITheme.font("semibold", true))
	val.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	val.clip_text = true
	val.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	val.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(val)
	add_child(p)
	return {"panel": p, "cap": c, "val": val}

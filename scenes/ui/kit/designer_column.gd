class_name DesignerColumn
extends RefCounted

## The designer pattern for a settings column, applied in one call AFTER the
## designer has built its column the way it always did:
##
##   _col = DesignerColumn.setup(box, "domelab", {
##       "open": ["Geometry", "Size"],                      # the essentials
##       "fold": ["Bill of materials", "Fabrication files"]})  # headers → folds
##   ...
##   _col.set_tiles([{"caption": "Diameter", "value": "6.0 m"}, ...])
##   _col.set_summary("Faces", "Polycarbonate, 105 panels")
##
## It gives the column, top to bottom:
##   - "Find a setting" + the open / fold all button (SettingFinder);
##   - headline tiles (StatTiles);
##   - every Collapsible section with the default fold policy (the ones named
##     in `open` open, the rest folded) and the player's own folds remembered
##     per modal (ui_prefs.cfg [folds]);
##   - each SectionHeader named in `fold`, with everything under it up to the
##     next header or section, turned into a folded section of the same name.
## Sections are found by title, so a designer keeps its own variables.

var finder: SettingFinder = null
var tiles: StatTiles = null
var sections: Dictionary = {}
var modal_id := ""


static func setup(box: Control, id: String, opts: Dictionary = {}) -> DesignerColumn:
	var col := DesignerColumn.new()
	col.modal_id = id
	var open_titles: Array = []
	for t in opts.get("open", []):
		open_titles.append(str(t).to_lower())
	# Headers → folded sections (explicit `fold` names, plus all SectionHeaders
	# when `open` is passed on a column that built only SectionHeaders).
	for title in opts.get("fold", []):
		col._fold_header(box, str(title))
	var has_collapsibles := false
	for ch0 in box.get_children():
		if ch0 is Collapsible:
			has_collapsibles = true
			break
	if opts.has("open") and not has_collapsibles:
		var remaining_headers: Array = []
		for ch in box.get_children():
			if ch is SectionHeader:
				var sh := ch as SectionHeader
				var nm := sh.raw_title if not sh.raw_title.is_empty() else (sh._label.text.capitalize() if sh._label != null else "")
				if not nm.is_empty() and nm.to_lower() != "checks":
					remaining_headers.append(nm)
		for htitle in remaining_headers:
			col._fold_header(box, str(htitle))
	for c in box.get_children():
		if c is Collapsible:
			var sec := c as Collapsible
			var key := _clean(sec.title)
			sec.folded = not open_titles.has(key)
			sec.persist(id, _slug(key))
			col.sections[key] = sec
	if bool(opts.get("tiles", true)):
		col.tiles = StatTiles.make(int(opts.get("tile_cols", 3)))
		box.add_child(col.tiles)
		box.move_child(col.tiles, 0)
	if bool(opts.get("finder", true)):
		col.finder = SettingFinder.make(box)
		box.add_child(col.finder)
		box.move_child(col.finder, 0)
	return col


func set_tiles(list: Array) -> void:
	if tiles != null:
		tiles.set_tiles(list)


func section(title: String) -> Collapsible:
	return sections.get(_clean(title), null) as Collapsible


func set_summary(title: String, text: String) -> void:
	var sec := section(title)
	if sec != null:
		sec.set_summary(text)


## "Parts (click to highlight)" and "Parts" are the same section.
static func _clean(title: String) -> String:
	var t := title.to_lower()
	var cut := t.find(" (")
	return (t.substr(0, cut) if cut > 0 else t).strip_edges()


static func _slug(key: String) -> String:
	var out := ""
	for ch in key:
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	return out


func _fold_header(box: Control, title: String) -> void:
	var want := title.to_upper()
	var kids := box.get_children()
	for i in kids.size():
		var h := kids[i] as SectionHeader
		if h == null or h._label == null or h._label.text != want:
			continue
		var sec := Collapsible.make(title, false)
		var moved: Array = []
		for j in range(i + 1, kids.size()):
			var n: Node = kids[j]
			if n is SectionHeader or n is FoldableContainer:
				break
			moved.append(n)
		box.add_child(sec)
		box.move_child(sec, h.get_index())
		for n in moved:
			box.remove_child(n)
			sec.body.add_child(n)
		box.remove_child(h)
		h.queue_free()
		return

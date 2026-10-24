extends VBoxContainer

## "Shoreline over time" block of Terrain options: which photo the sharp
## drape shows (today's / follow the clock / one archived capture), and the
## gauged lake level. All state lives in the loader's ShorelineHistory; this
## only reads and asks. 260 px wide like the rest of the column, so every
## label wraps.

var _loader: Node = null
var _sh: ShorelineHistory = null
var _imagery_opt: OptionButton = null
var _imagery_lbl: Label = null
var _lake_cb: CheckBox = null
var _lake_lbl: Label = null
## Option index → {mode, release}.
var _opt_map: Array = []
var _poll := 0.0
var _sig := ""


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := Label.new()
	title.text = "Shoreline over time"
	title.clip_text = true
	title.tooltip_text = ("Show the sharp drape as it was photographed on an earlier date (Esri World "
		+ "Imagery Wayback) and a lake at the level its gauge read on the clock's date. Scrub the "
		+ "timeline and both follow.")
	add_child(title)
	_imagery_opt = OptionButton.new()
	_imagery_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_imagery_opt.fit_to_longest_item = false
	_imagery_opt.clip_text = true
	_imagery_opt.tooltip_text = "Which capture the sharp square round the site shows"
	_imagery_opt.item_selected.connect(_on_imagery_selected)
	add_child(_imagery_opt)
	_imagery_lbl = _small_label()
	add_child(_imagery_lbl)
	_lake_cb = CheckBox.new()
	_lake_cb.text = "Lake level from its gauge"
	_lake_cb.tooltip_text = ("Draw the lake at the level its USGS gauge read on the clock's date, "
		+ "so the water edge moves as you scrub")
	_lake_cb.toggled.connect(func(on: bool) -> void:
		if _sh != null:
			_sh.set_lake_level(on))
	add_child(_lake_cb)
	_lake_lbl = _small_label()
	add_child(_lake_lbl)
	add_child(HSeparator.new())
	visibility_changed.connect(_on_visibility)


func _small_label() -> Label:
	var l := Label.new()
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.modulate = Color(1, 1, 1, 0.75)
	return l


func bind(loader: Node) -> void:
	_loader = loader
	_sh = null
	_refresh()


func _shoreline() -> ShorelineHistory:
	if _sh == null and _loader != null and _loader.has_method("shoreline_history"):
		_sh = _loader.call("shoreline_history")
		if _sh != null and not _sh.changed.is_connected(_refresh):
			_sh.changed.connect(_refresh)
	return _sh


func _on_visibility() -> void:
	if is_visible_in_tree():
		var sh := _shoreline()
		if sh != null:
			sh.ensure_captures()
		_refresh()


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	_poll += delta
	if _poll >= 0.5:
		_poll = 0.0
		_refresh_labels()


func _refresh() -> void:
	var sh := _shoreline()
	if sh == null or _imagery_opt == null:
		return
	var caps := sh.captures()
	var sig := "%s|%d|%s|%d" % [sh.mode(), int(sh.record().get("release", -1)), str(sh.captures_status()["status"]), caps.size()]
	if sig != _sig:
		_sig = sig
		_imagery_opt.clear()
		_opt_map.clear()
		_imagery_opt.add_item("Today's imagery")
		_opt_map.append({"mode": "current", "release": -1})
		_imagery_opt.add_item("Follow the clock's date")
		_opt_map.append({"mode": "follow", "release": -1})
		for c_v in caps:
			var c: Dictionary = c_v
			_imagery_opt.add_item("As of " + WaybackCatalog.capture_label(c))
			_opt_map.append({"mode": "pinned", "release": int(c["release"])})
		var sel := 0
		for i in _opt_map.size():
			var o: Dictionary = _opt_map[i]
			if str(o["mode"]) == sh.mode() and (sh.mode() != "pinned" or int(o["release"]) == int(sh.record()["release"])):
				sel = i
		_imagery_opt.select(sel)
		_imagery_opt.disabled = caps.is_empty() and str(sh.captures_status()["status"]) == "failed"
	_lake_cb.set_block_signals(true)
	_lake_cb.button_pressed = sh.lake_level_enabled()
	_lake_cb.set_block_signals(false)
	_refresh_labels()


func _refresh_labels() -> void:
	var sh := _shoreline()
	if sh == null:
		return
	var cs := sh.captures_status()
	var shown := sh.shown_capture()
	var line := ""
	if sh.mode() == "current":
		line = "Today's ESRI drape."
	elif not shown.is_empty():
		line = "Showing the %s photo (detail + sharp square; the wide map stays today's)." % str(shown["date"])
	if str(cs["status"]) in ["loading", "failed"] or sh.captures().is_empty():
		line = (line + " " if not line.is_empty() else "") + str(cs["note"])
	elif sh.mode() == "current":
		line += " " + str(cs["note"]) + "."
	_imagery_lbl.text = line.strip_edges()
	var g := sh.gauge_status()
	var t := ""
	if not sh.lake_level_enabled():
		t = "Off — the lake is drawn at its banks." if not str(g["name"]).is_empty() else "Off."
	elif str(g["status"]) != "ready":
		t = str(g["note"]) if not str(g["note"]).is_empty() else "Waiting for the gauge…"
	else:
		var lv := float(g["level_m"])
		var info: Dictionary = g["level_info"]
		t = "%s: %s m (NAVD88) on the clock's date" % [str(g["name"]), String.num(lv, 2)]
		if not is_nan(float(info.get("ft", NAN))) and str(g["param"]) == LakeGauge.PARAM_NGVD29:
			t += " — gauge %s ft NGVD29, %+.2f m VERTCON" % [String.num(float(info["ft"]), 2), float(g["shift_m"])]
		if not bool(info.get("inside", true)) and float(info.get("gap_days", 0.0)) > 1.5:
			t += ". Outside the record (%s to %s): its nearest reading is held" % [str(g["first"]), str(g["last"])]
		var dem := float(g["dem_water_m"])
		if not is_nan(dem) and lv < dem - 0.05:
			t += ". That is below the ground model's own lake surface (%s m), so the water is drawn there: the DEM has no ground under it to show a lower shore" % String.num(dem, 2)
		elif not is_nan(dem):
			t += ". Levels below the ground model's lake surface (%s m) cannot be drawn" % String.num(dem, 2)
		t += "."
	_lake_lbl.text = t


func _on_imagery_selected(idx: int) -> void:
	var sh := _shoreline()
	if sh == null or idx < 0 or idx >= _opt_map.size():
		return
	var o: Dictionary = _opt_map[idx]
	sh.set_mode(str(o["mode"]), int(o["release"]))

class_name GraphDashboardPanel
extends VBoxContainer

## Native graph left-sidebar dashboard — live power, needs/closure, resource stores.
## Replaces the Test-mode SolarUI embed; reads canonical SolarUI + closure metrics.

const _CLOSURE_SCRIPT := preload("res://system_graph/closure_metrics.gd")
const _HIGH_SCORE_SCRIPT := preload("res://core/high_score_store.gd")

const REFRESH_INTERVAL := 0.2

var _graph_view: Node = null
var _mode := "build"
var _refresh_acc := 0.0

var _solar_lbl: Label = null
var _aux_lbl: Label = null
var _load_lbl: Label = null
var _net_lbl: Label = null
var _bat_bar: ProgressBar = null
var _bat_pct_lbl: Label = null
var _bat_kwh_lbl: Label = null
var _status_lbl: Label = null
var _score_lbl: Label = null
var _best_lbl: Label = null
var _need_rows: Dictionary = {}  # kind -> {status, detail}
var _stores_vbox: VBoxContainer = null


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)
	_build_ui()
	set_process(true)


func bind_graph_view(gv: Node) -> void:
	_graph_view = gv
	refresh(true)


func set_mode(mode: String) -> void:
	_mode = mode
	refresh(true)


func refresh(force: bool = false) -> void:
	if not force and _refresh_acc < REFRESH_INTERVAL:
		return
	_refresh_acc = 0.0
	_refresh_power()
	_refresh_closure()
	_refresh_stores()


func _process(delta: float) -> void:
	_refresh_acc += delta
	if _refresh_acc >= REFRESH_INTERVAL:
		refresh(true)


func _build_ui() -> void:
	add_child(_card_section("⚡ LIVE POWER"))
	var power_wrap := _card_body()
	add_child(power_wrap)
	var power_body := _card_inner(power_wrap)

	var power_grid := GridContainer.new()
	power_grid.columns = 4
	power_grid.add_theme_constant_override("h_separation", 6)
	power_grid.add_theme_constant_override("v_separation", 2)
	power_body.add_child(power_grid)

	_solar_lbl = _stat_cell(power_grid, "SOLAR", "— kW", UITheme.C_GOLD)
	_aux_lbl = _stat_cell(power_grid, "AUX", "— kW", UITheme.C_LAVENDER)
	_load_lbl = _stat_cell(power_grid, "LOAD", "— kW", UITheme.C_TEXT)
	_net_lbl = _stat_cell(power_grid, "NET", "— kW", UITheme.C_PRIMARY)

	var bat_row := HBoxContainer.new()
	bat_row.add_theme_constant_override("separation", 8)
	power_body.add_child(bat_row)

	_bat_bar = ProgressBar.new()
	_bat_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bat_bar.custom_minimum_size = Vector2(0, 14)
	_bat_bar.max_value = 100.0
	_bat_bar.show_percentage = false
	_style_progress(_bat_bar)
	bat_row.add_child(_bat_bar)

	_bat_pct_lbl = Label.new()
	_bat_pct_lbl.custom_minimum_size = Vector2(42, 0)
	_bat_pct_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_bat_pct_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	_bat_pct_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
	bat_row.add_child(_bat_pct_lbl)

	var bat_meta := HBoxContainer.new()
	bat_meta.add_theme_constant_override("separation", 8)
	power_body.add_child(bat_meta)

	_bat_kwh_lbl = Label.new()
	_bat_kwh_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bat_kwh_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_bat_kwh_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	bat_meta.add_child(_bat_kwh_lbl)

	_status_lbl = Label.new()
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	bat_meta.add_child(_status_lbl)

	add_child(_card_section("🔁 NEEDS & CLOSURE"))
	var closure_wrap := _card_body()
	add_child(closure_wrap)
	var closure_body := _card_inner(closure_wrap)

	var score_row := HBoxContainer.new()
	score_row.add_theme_constant_override("separation", 10)
	closure_body.add_child(score_row)

	var score_wrap := PanelContainer.new()
	var score_sb := StyleBoxFlat.new()
	score_sb.bg_color = Color(UITheme.C_PRIMARY.r, UITheme.C_PRIMARY.g, UITheme.C_PRIMARY.b, 0.14)
	score_sb.border_color = Color(UITheme.C_PRIMARY.r, UITheme.C_PRIMARY.g, UITheme.C_PRIMARY.b, 0.65)
	score_sb.set_border_width_all(1)
	score_sb.set_corner_radius_all(8)
	score_sb.content_margin_left = 12
	score_sb.content_margin_right = 12
	score_sb.content_margin_top = 6
	score_sb.content_margin_bottom = 6
	score_wrap.add_theme_stylebox_override("panel", score_sb)
	score_row.add_child(score_wrap)

	var score_col := VBoxContainer.new()
	score_col.add_theme_constant_override("separation", 0)
	score_wrap.add_child(score_col)

	var score_cap := Label.new()
	score_cap.text = "PUZZLE SCORE"
	score_cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_cap.add_theme_font_size_override("font_size", 8)
	score_cap.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	score_col.add_child(score_cap)

	_score_lbl = Label.new()
	_score_lbl.text = "—"
	_score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_lbl.add_theme_font_size_override("font_size", 22)
	_score_lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	score_col.add_child(_score_lbl)

	_best_lbl = Label.new()
	_best_lbl.text = "Best: —"
	_best_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_best_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_best_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_best_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	score_row.add_child(_best_lbl)

	for kind_meta: Array in [
			["energy", "⚡ Energy"],
			["water", "💧 Water"],
			["food", "🍎 Food"],
			["waste", "♻ Waste"],
	]:
		var kind: String = str(kind_meta[0])
		var row := _need_row(str(kind_meta[1]))
		closure_body.add_child(row)
		_need_rows[kind] = row

	add_child(_card_section("🛢 RESOURCE STORES"))
	var stores_wrap := _card_body()
	add_child(stores_wrap)
	var stores_body := _card_inner(stores_wrap)
	_stores_vbox = VBoxContainer.new()
	_stores_vbox.add_theme_constant_override("separation", 4)
	stores_body.add_child(_stores_vbox)


func _card_section(title: String) -> PanelContainer:
	var hdr := PanelContainer.new()
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_PANEL.r * 0.85, UITheme.C_PANEL.g * 0.85, UITheme.C_PANEL.b * 0.85, 1.0)
	sb.border_color = Color(UITheme.C_PRIMARY.r, UITheme.C_PRIMARY.g, UITheme.C_PRIMARY.b, 0.22)
	sb.set_border_width(SIDE_BOTTOM, 1)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	hdr.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = title.to_upper()
	lbl.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	lbl.add_theme_font_size_override("font_size", 10)
	hdr.add_child(lbl)
	return hdr


func _card_body() -> MarginContainer:
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 10)
	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	m.add_child(inner)
	m.set_meta("inner", inner)
	return m


func _card_inner(body: MarginContainer) -> VBoxContainer:
	return body.get_meta("inner") as VBoxContainer


func _stat_cell(parent: GridContainer, cap: String, initial: String, col: Color) -> Label:
	var col_v := VBoxContainer.new()
	col_v.add_theme_constant_override("separation", 0)
	parent.add_child(col_v)
	var c := Label.new()
	c.text = cap
	c.add_theme_font_size_override("font_size", 8)
	c.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	col_v.add_child(c)
	var v := Label.new()
	v.text = initial
	v.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	v.add_theme_color_override("font_color", col)
	col_v.add_child(v)
	return v


## Status-tinted channel row: PanelContainer with a 3 px left accent border
## whose color tracks the channel status, plus a trend arrow in the detail.
func _need_row(title: String) -> PanelContainer:
	var wrap := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.C_TEXT_M.r, UITheme.C_TEXT_M.g, UITheme.C_TEXT_M.b, 0.06)
	sb.set_border_width(SIDE_LEFT, 3)
	sb.border_color = Color(UITheme.C_TEXT_M.r, UITheme.C_TEXT_M.g, UITheme.C_TEXT_M.b, 0.55)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	wrap.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	wrap.add_child(row)
	var name_lbl := Label.new()
	name_lbl.text = title
	name_lbl.custom_minimum_size = Vector2(72, 0)
	name_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	name_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(name_lbl)
	var status_lbl := Label.new()
	status_lbl.name = "status"
	status_lbl.custom_minimum_size = Vector2(36, 0)
	status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	row.add_child(status_lbl)
	var detail_lbl := Label.new()
	detail_lbl.name = "detail"
	detail_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	detail_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	detail_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	detail_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	row.add_child(detail_lbl)
	wrap.set_meta("status_lbl", status_lbl)
	wrap.set_meta("detail_lbl", detail_lbl)
	wrap.set_meta("style", sb)
	return wrap


func _style_progress(bar: ProgressBar) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(UITheme.C_BG.r, UITheme.C_BG.g, UITheme.C_BG.b, 0.9)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UITheme.C_GREEN
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)


func _solar_ui() -> Node:
	if _graph_view == null:
		return null
	return _graph_view.get("_solar_ui") as Node


func _refresh_power() -> void:
	var su := _solar_ui()
	if su == null or not is_instance_valid(su):
		_solar_lbl.text = "— kW"
		_aux_lbl.text = "— kW"
		_load_lbl.text = "— kW"
		_net_lbl.text = "— kW"
		_bat_bar.value = 0.0
		_bat_pct_lbl.text = "—"
		_bat_kwh_lbl.text = "Battery —"
		_status_lbl.text = "No sim" if _mode == "build" else "—"
		return

	var solar_kw := float(su.get("current_solar_kw") if su.get("current_solar_kw") != null else 0.0)
	var load_kw := float(su.get("current_load_kw") if su.get("current_load_kw") != null else 0.0)
	# Aux = real scene wind/hydro/etc EnergySource output + graph-simulated DC
	# generation (fuel generators, graph-only wind/hydro wired into a
	# battery — see system_graph/dc_power_wiring.gd).
	var aux_kw := float(su.get("current_aux_generation_kw") if su.get("current_aux_generation_kw") != null else 0.0) \
		+ float(su.get("current_graph_dc_kw") if su.get("current_graph_dc_kw") != null else 0.0)
	var net_kw := solar_kw + aux_kw - load_kw

	_solar_lbl.text = "%.2f kW" % solar_kw
	_aux_lbl.text = "%.2f kW" % aux_kw
	_load_lbl.text = "%.2f kW" % load_kw
	_net_lbl.text = "%+.2f kW" % net_kw
	_net_lbl.add_theme_color_override("font_color",
			UITheme.C_GREEN if net_kw >= 0.0 else UITheme.C_WARN)

	var pct := 0.0
	if su.has_method("get_battery_percent"):
		pct = float(su.call("get_battery_percent"))
	var stored := 0.0
	var cap := 16.0
	if su.has_method("get_battery_kwh_stored"):
		stored = float(su.call("get_battery_kwh_stored"))
	if su.has_method("get_battery_capacity_kwh"):
		cap = maxf(float(su.call("get_battery_capacity_kwh")), 0.01)
	elif su.get("BATTERY_CAPACITY_KWH") != null:
		cap = maxf(float(su.get("BATTERY_CAPACITY_KWH")), 0.01)

	_bat_bar.value = clampf(pct, 0.0, 100.0)
	_bat_pct_lbl.text = "%.0f%%" % pct
	_bat_kwh_lbl.text = "%.2f / %.1f kWh" % [stored, cap]

	var status := "IDLE"
	if su.has_method("is_ac_output_enabled") and not bool(su.call("is_ac_output_enabled")):
		status = "AC OFF"
	elif su.has_method("is_soc_protect_active") and bool(su.call("is_soc_protect_active")):
		status = "SOC PROTECT"
	elif net_kw > 0.05:
		status = "CHARGING"
	elif net_kw < -0.05:
		status = "DISCHARGING"
	elif pct >= 99.0:
		status = "FULL"
	_status_lbl.text = status
	_status_lbl.add_theme_color_override("font_color",
			UITheme.C_WARN if status == "AC OFF" or status == "SOC PROTECT" else UITheme.C_TEXT_M)

	var alpha := 1.0 if _mode == "test" else 0.72
	_solar_lbl.modulate.a = alpha
	_aux_lbl.modulate.a = alpha
	_load_lbl.modulate.a = alpha
	_net_lbl.modulate.a = alpha


func _refresh_closure() -> void:
	var m: Dictionary = {}
	if _graph_view != null and _graph_view.has_method("compute_closure_metrics"):
		m = _graph_view.call("compute_closure_metrics") as Dictionary

	var score := float(m.get("score", 0.0))
	_score_lbl.text = ("%.0f" % score) if score > 0.01 else "—"

	var lat := 0.0
	var lon := 0.0
	if _graph_view != null and _graph_view.has_method("_get_scene_main_node"):
		var main := _graph_view.call("_get_scene_main_node") as Node
		if main != null:
			lat = float(main.get("latitude")) if main.get("latitude") != null else 0.0
			lon = float(main.get("longitude")) if main.get("longitude") != null else 0.0
	var best := _HIGH_SCORE_SCRIPT.best_score(lat, lon, "")
	_best_lbl.text = "Best: %.0f" % best if best > 0.01 else "Best: —"

	var channels: Dictionary = m.get("channels", {}) as Dictionary
	var now_msec := Time.get_ticks_msec()
	for kind: String in _need_rows.keys():
		var row: PanelContainer = _need_rows[kind] as PanelContainer
		var status_lbl: Label = row.get_meta("status_lbl") as Label
		var detail_lbl: Label = row.get_meta("detail_lbl") as Label
		var sb: StyleBoxFlat = row.get_meta("style") as StyleBoxFlat
		var ch: Dictionary = channels.get(kind, {}) as Dictionary
		var st: String = str(ch.get("status", "idle"))
		var st_col: Color = _CLOSURE_SCRIPT.status_color(st)
		if st == "idle":
			status_lbl.text = "○"
			detail_lbl.text = "inactive"
			status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		else:
			var closure := float(ch.get("closure_pct", 0.0))
			status_lbl.text = _CLOSURE_SCRIPT.status_label(st)
			detail_lbl.text = "%s %.0f%% · %.1fd" % [
					_trend_arrow(kind, closure, now_msec),
					closure * 100.0,
					float(ch.get("autonomy_days", 0.0)),
			]
			status_lbl.add_theme_color_override("font_color", st_col)
		if sb != null:
			sb.bg_color = Color(st_col.r, st_col.g, st_col.b, 0.10 if st != "idle" else 0.05)
			sb.border_color = Color(st_col.r, st_col.g, st_col.b, 0.85 if st != "idle" else 0.35)


## Closure trend vs a snapshot taken every TREND_WINDOW_S: ↑ / → / ↓.
const TREND_WINDOW_S := 45.0
const TREND_EPS := 0.02
var _closure_trend: Dictionary = {}  # kind -> {pct, msec, arrow}

func _trend_arrow(kind: String, closure_pct: float, now_msec: int) -> String:
	if not _closure_trend.has(kind):
		_closure_trend[kind] = {"pct": closure_pct, "msec": now_msec, "arrow": "→"}
		return "→"
	var snap: Dictionary = _closure_trend[kind] as Dictionary
	if float(now_msec - int(snap.get("msec", 0))) >= TREND_WINDOW_S * 1000.0:
		var delta := closure_pct - float(snap.get("pct", closure_pct))
		var arrow := "→"
		if delta > TREND_EPS:
			arrow = "↑"
		elif delta < -TREND_EPS:
			arrow = "↓"
		_closure_trend[kind] = {"pct": closure_pct, "msec": now_msec, "arrow": arrow}
		return arrow
	return str(snap.get("arrow", "→"))


func _refresh_stores() -> void:
	for c in _stores_vbox.get_children():
		c.queue_free()

	var model: GraphModel = null
	if _graph_view != null:
		model = _graph_view.get("model") as GraphModel
	if model == null:
		var hint := Label.new()
		hint.text = "No tanks on graph"
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_stores_vbox.add_child(hint)
		return

	var kinds_seen: Dictionary = {}
	for item: Dictionary in model.get_items_in_scope("root"):
		if str(item.get("type", "")) != "resource":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		var kind := str(specs.get("resource_kind", ""))
		if kind.is_empty():
			continue
		var level := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
		var cap_qty := float(specs.get("capacity_qty", 0.0))
		var unit := str(specs.get("capacity_unit", ""))
		var name := str(specs.get("name", kind.capitalize()))
		if kinds_seen.has(kind):
			continue
		kinds_seen[kind] = true

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_stores_vbox.add_child(row)

		var bar := ProgressBar.new()
		bar.custom_minimum_size = Vector2(80, 10)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.max_value = 100.0
		bar.value = level * 100.0
		bar.show_percentage = false
		_style_progress(bar)
		row.add_child(bar)

		var lbl := Label.new()
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.text = "%s  %.0f%%" % [name, level * 100.0]
		if cap_qty > 0.0:
			lbl.text = "%s  %.1f / %.0f %s" % [name, level * cap_qty, cap_qty, unit]
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		row.add_child(lbl)

	if kinds_seen.is_empty():
		var hint := Label.new()
		hint.text = "Add resource tanks from the library"
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_stores_vbox.add_child(hint)

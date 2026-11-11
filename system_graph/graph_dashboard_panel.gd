class_name GraphDashboardPanel
extends VBoxContainer

## Native graph left-sidebar dashboard — live power, needs/closure, resource stores.
## Replaces the Test-mode SolarUI embed; reads canonical SolarUI + closure metrics.

const _CLOSURE_SCRIPT := preload("res://system_graph/closure_metrics.gd")
const _HIGH_SCORE_SCRIPT := preload("res://core/high_score_store.gd")

const REFRESH_INTERVAL := 0.2
## Stores + Settlement card refresh at 1 Hz — both walk model/roster arrays,
## and neither changes fast enough to justify the 5 Hz power cadence.
const REFRESH_SLOW_MS := 1000

var _graph_view: Node = null
var _mode := "build"
var _refresh_acc := 0.0
var _tick_last_ms := 0
const TICK_REFRESH_MS := 100
var _closure_last_ms := 0
const CLOSURE_REFRESH_MS := 500

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
var _week_note: Label = null
var _week_back: Dictionary = {}
var _stores_vbox: VBoxContainer = null
## Content signature of the last-built store rows. Starts at a sentinel, never
## "" — an empty board yields an empty signature, and "" would compare equal on
## the first pass so the empty-state hint would never build.
var _stores_sig := "<unset>"
var _settlement_vbox: VBoxContainer = null
var _settlement_sig := "<unset>"
## SITE BALANCE card (SiteBalance.lines) — rebuilt on content change only.
var _balance_vbox: VBoxContainer = null
## Its render state for _render_rows: the rows' signature, their structure
## (types + keys) and the value nodes built for it, so a tick that only
## changes numbers updates labels in place.
var _balance_state: Dictionary = {"sig": "<unset>", "shape": "<unset>", "values": []}
## MADE OF card (ElementLedger.rows): what the site's stores hold by element,
## water recovery, what does not add up. 1 Hz with the balance.
var _made_of_vbox: VBoxContainer = null
var _made_of_state: Dictionary = {"sig": "<unset>", "shape": "<unset>", "values": []}
## SolarUI.sim_tick_serial last shown — LIVE POWER and the balance follow
## SolarUI's own tick, the same one the graph cards sync on, so "Making" is
## the figure the panel and controller cards show on that frame.
var _solar_serial := -1
## Forward outlook (SiteProjection), recomputed every PROJECTION_EVERY_MS real
## or when the clock moved > PROJECTION_EVERY_SIM_H — 168 solar evaluations.
const PROJECTION_EVERY_MS := 20000
const PROJECTION_EVERY_SIM_H := 0.25
var _proj_lines: Array = []
var _proj_ms := -1000000
var _proj_abs_h := -1.0e12
## The projection's solar at each WHOLE sim hour (kW), interpolated between
## hours: a re-run 0.25 sim-h later needs about one new evaluation instead of
## 192 (the full run was ~13 ms, and at 7200x it ran 8 times a second).
## Keyed on what the evaluator reads (the graph's revisions, SolarUI's array)
## and dropped every SOLAR_CACHE_MS so new weather data reaches it.
var _solar_hours: Dictionary = {}
var _solar_hours_key := ""
var _solar_hours_ms := 0
const SOLAR_CACHE_MS := 60000
var _slow_last_ms := 0
## Rolling strip of the latest notable settlement-log lines (own named cursor,
## so this never races the toast drain or the challenge bake's watcher).
var _alerts: Array = []
const _ALERT_KINDS := {"blocked": true, "relief": true, "departed": true,
	"lost": true, "collapse_warning": true, "collapsed": true,
	"deserted": true}
const _MAX_ALERTS := 3


func _ready() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 0)
	_build_ui()
	_build_system_tabs()
	set_process(true)
	visibility_changed.connect(_on_visibility_changed)


## Shown again (the graph reopened): refresh at once rather than at the next
## interval, since nothing refreshed while it was hidden.
func _on_visibility_changed() -> void:
	if is_visible_in_tree():
		_refresh_acc = REFRESH_INTERVAL
		refresh(true)


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
	_refresh_tabs()
	PerfSpan.begin("gv_dash_power")
	_refresh_power()
	PerfSpan.end("gv_dash_power")
	# The closure metrics walk the whole model (2-12 ms on a festival): 2 Hz.
	var now_ms := Time.get_ticks_msec()
	if force or now_ms - _closure_last_ms >= CLOSURE_REFRESH_MS:
		_closure_last_ms = now_ms
		PerfSpan.begin("gv_dash_closure")
		_refresh_closure()
		PerfSpan.end("gv_dash_closure")
	# Stores + Settlement walk model/roster arrays — 1 Hz is plenty, and the
	# signature diffs inside them make even that mostly free.
	if now_ms - _slow_last_ms >= REFRESH_SLOW_MS:
		_slow_last_ms = now_ms
		PerfSpan.begin("gv_dash_slow")
		_refresh_stores()
		_refresh_settlement()
		_refresh_balance()
		PerfSpan.begin("gv_dash_made_of")
		_refresh_made_of()
		PerfSpan.end("gv_dash_made_of")
		PerfSpan.end("gv_dash_slow")


func _process(delta: float) -> void:
	# Nothing refreshes while the panel is off screen (the graph closed): the
	# 5 Hz power / closure refresh used to run behind the first-person view.
	# `_on_visibility_changed` forces one refresh when it comes back.
	if not is_visible_in_tree():
		return
	_refresh_acc += delta
	if _refresh_acc >= REFRESH_INTERVAL:
		refresh()
	var su := _solar_ui()
	if su == null or not is_instance_valid(su):
		return
	var sv: Variant = su.get("sim_tick_serial")
	# The power numbers follow SolarUI's tick, at most TICK_REFRESH_MS apart
	# (at speed SolarUI ticks every frame). The site balance walks the model
	# and stays on the 1 Hz slow path in refresh().
	var now_ms := Time.get_ticks_msec()
	if sv != null and int(sv) != _solar_serial and now_ms - _tick_last_ms >= TICK_REFRESH_MS:
		_solar_serial = int(sv)
		_tick_last_ms = now_ms
		PerfSpan.begin("gv_dash_tick")
		_refresh_power()
		PerfSpan.end("gv_dash_tick")


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

	add_child(_card_section("⚖ SITE BALANCE"))
	var bal_wrap := _card_body()
	add_child(bal_wrap)
	var bal_body := _card_inner(bal_wrap)
	_balance_vbox = VBoxContainer.new()
	_balance_vbox.add_theme_constant_override("separation", 2)
	bal_body.add_child(_balance_vbox)

	add_child(_card_section("🧪 WATER & NUTRIENTS"))
	var made_wrap := _card_body()
	add_child(made_wrap)
	var made_body := _card_inner(made_wrap)
	_made_of_vbox = VBoxContainer.new()
	_made_of_vbox.add_theme_constant_override("separation", 2)
	made_body.add_child(_made_of_vbox)
	var where_btn := Button.new()
	where_btn.text = "Where it goes…"
	where_btn.tooltip_text = "Follow one element through the site: where it comes from, what changes it, where it ends up."
	where_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(where_btn)
	where_btn.pressed.connect(func() -> void:
		if _graph_view != null and _graph_view.has_method("open_element_sankey"):
			var lens := str(_graph_view.call("element_lens")) if _graph_view.has_method("element_lens") else ""
			_graph_view.call("open_element_sankey", lens if not lens.is_empty() else "N"))
	made_body.add_child(where_btn)

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

	var week_row := HBoxContainer.new()
	week_row.add_theme_constant_override("separation", 8)
	closure_body.add_child(week_row)
	var dry_btn := Button.new()
	dry_btn.text = "Driest week"
	dry_btn.focus_mode = Control.FOCUS_NONE
	dry_btn.tooltip_text = "Jump the clock to the driest week in this site's weather archive. Closure and battery hours are the score."
	dry_btn.pressed.connect(_on_driest_week)
	week_row.add_child(dry_btn)
	var back_btn := Button.new()
	back_btn.text = "Jump back"
	back_btn.focus_mode = Control.FOCUS_NONE
	back_btn.tooltip_text = "Return to the date you left."
	back_btn.pressed.connect(_on_week_jump_back)
	week_row.add_child(back_btn)
	_week_note = Label.new()
	_week_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_week_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_week_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	closure_body.add_child(_week_note)

	add_child(_card_section("🏕 SETTLEMENT"))
	var settle_wrap := _card_body()
	add_child(settle_wrap)
	var settle_body := _card_inner(settle_wrap)
	_settlement_vbox = VBoxContainer.new()
	_settlement_vbox.add_theme_constant_override("separation", 3)
	settle_body.add_child(_settlement_vbox)

	add_child(_card_section("🛢 RESOURCE STORES"))
	var stores_wrap := _card_body()
	add_child(stores_wrap)
	var stores_body := _card_inner(stores_wrap)
	_stores_vbox = VBoxContainer.new()
	_stores_vbox.add_theme_constant_override("separation", 4)
	stores_body.add_child(_stores_vbox)


## A card's title: the kit's SectionHeader, inset to the card body's margins.
func _card_section(title: String) -> MarginContainer:
	var m := MarginContainer.new()
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 6)
	m.add_theme_constant_override("margin_bottom", 0)
	m.add_child(SectionHeader.make(title))
	return m


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


func _sandboxed() -> bool:
	return _graph_view != null and _graph_view.has_method("is_sandbox_active") \
		and bool(_graph_view.call("is_sandbox_active"))


func _scene_main() -> Node:
	if _graph_view != null and _graph_view.has_method("_get_scene_main_node"):
		return _graph_view.call("_get_scene_main_node") as Node
	return null


func _on_driest_week() -> void:
	var main := _scene_main()
	if main == null:
		return
	var wx: Variant = main.get("_weather_service_node")
	if wx == null or not (wx as Object).has_method("driest_week"):
		return
	var week: Dictionary = (wx as Object).call("driest_week")
	if week.is_empty():
		if _graph_view != null and _graph_view.has_method("_show_toast"):
			_graph_view.call("_show_toast", "No weather archive is loaded for this site yet.")
		return
	_week_back = {
		"year": int(main.get("year")), "month": int(main.get("month")),
		"day": int(main.get("day")), "day_time": float(main.get("day_time")),
	}
	main.set("day", 1)
	main.set("month", int(week.get("month", 1)))
	main.set("day", int(week.get("day", 1)))
	main.set("day_time", float(week.get("hour", 8.0)))
	if _week_note != null:
		_week_note.text = "Driest week: %.1f mm of rain. Closure and battery hours are the score. Jump back returns to where you were." % float(week.get("mm", 0.0))


func _on_week_jump_back() -> void:
	if _week_back.is_empty():
		return
	var main := _scene_main()
	if main == null:
		return
	main.set("year", int(_week_back.get("year", main.get("year"))))
	main.set("day", 1)
	main.set("month", int(_week_back.get("month", main.get("month"))))
	main.set("day", int(_week_back.get("day", main.get("day"))))
	main.set("day_time", float(_week_back.get("day_time", main.get("day_time"))))
	_week_back = {}
	if _week_note != null:
		_week_note.text = ""


func _refresh_closure() -> void:
	var m: Dictionary = {}
	if _graph_view != null and _graph_view.has_method("compute_closure_metrics"):
		m = _graph_view.call("compute_closure_metrics") as Dictionary

	var score := float(m.get("score", 0.0))
	_score_lbl.text = UiText.thousands(int(round(score))) if score > 0.01 else "—"

	var lat := 0.0
	var lon := 0.0
	if _graph_view != null and _graph_view.has_method("_get_scene_main_node"):
		var main := _graph_view.call("_get_scene_main_node") as Node
		if main != null:
			lat = float(main.get("latitude")) if main.get("latitude") != null else 0.0
			lon = float(main.get("longitude")) if main.get("longitude") != null else 0.0
	var best := _HIGH_SCORE_SCRIPT.best_score(lat, lon, "")
	_best_lbl.text = ("Best: %s" % UiText.thousands(int(round(best)))) if best > 0.01 else "Best: —"
	if _sandboxed():
		# The site's record has nothing to do with a bootcamp bench circuit.
		_best_lbl.text = "Bootcamp sandbox"

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


## Pure row model for the RESOURCE STORES card — one row per resource kind,
## aggregated over REAL tanks only. Extracted static so it can be pinned
## headless. The ∞ culvert outlet (specs.outlet_sink / unlimited_capacity) and
## processor ghost containers (is_ghost, item- or specs-level) used to leak in
## here: a habitat's auto-spawned in/out ghosts rendered as stores, and the
## first-item-of-kind-wins naming let the water row wear the outlet's
## "Culvert Outlet" name. Rows are named after the LARGEST tank of the kind.
static func store_rows(items: Array) -> Array:
	var by_kind: Dictionary = {}
	var order: Array = []
	for item: Dictionary in items:
		if str(item.get("type", "")) != "resource":
			continue
		if bool(item.get("is_ghost", false)) or bool(item.get("is_virtual", false)):
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if bool(specs.get("is_ghost", false)):
			continue
		if bool(specs.get("outlet_sink", false)) or bool(specs.get("unlimited_capacity", false)):
			continue
		var kind := str(specs.get("resource_kind", ""))
		if kind.is_empty():
			continue
		var level := clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
		var cap_qty := maxf(float(specs.get("capacity_qty", 0.0)), 0.0)
		var name := str(specs.get("name", ""))
		if name.is_empty():
			name = kind.capitalize()
		var row: Dictionary = by_kind.get(kind, {})
		if row.is_empty():
			row = {"kind": kind, "name": name, "name_cap": cap_qty,
					"stock": 0.0, "cap": 0.0, "count": 0,
					"unit": str(specs.get("capacity_unit", "")), "tanks": []}
			by_kind[kind] = row
			order.append(kind)
		elif cap_qty > float(row["name_cap"]):
			row["name"] = name
			row["name_cap"] = cap_qty
			row["unit"] = str(specs.get("capacity_unit", row["unit"]))
		row["stock"] = float(row["stock"]) + level * cap_qty
		row["cap"] = float(row["cap"]) + cap_qty
		row["count"] = int(row["count"]) + 1
		(row["tanks"] as Array).append({"name": name, "stock": level * cap_qty,
				"cap": cap_qty, "unit": str(specs.get("capacity_unit", ""))})
	var out: Array = []
	for kind: String in order:
		out.append(by_kind[kind])
	return out


## The whole site's energy + water balance right now (SiteBalance): each
## generator by name, make vs use, how long the battery lasts, and each pond's
## inflows / outflows / spill.
## The site's cost for SiteBalance: the graph's own total + every placed
## structure's bill of materials (SiteCost caches the solves).
func _cost_extra(model: GraphModel) -> Dictionary:
	var out := {"graph_usd": model.total_cost()}
	var main: Node = null
	if _graph_view != null and _graph_view.has_method("_get_scene_main_node"):
		main = _graph_view.call("_get_scene_main_node") as Node
	var loader: Node = main.find_child("TerrainLoader", true, false) if main != null else null
	if loader != null and loader.has_method("placed_prop_records"):
		var pt := SiteCost.placed_total(loader.call("placed_prop_records"))
		out["placed_usd"] = pt["usd"]
		out["placed_priced"] = pt["priced"]
		out["placed_unpriced"] = pt["unpriced"]
		var rt := SiteCost.running_total(loader.call("placed_prop_records"))
		out["running_usd"] = rt["usd"]
		out["vehicles"] = rt["vehicles"]
	return out


## What the site's stores hold by element and how much used water comes back
## clean (ElementLedger over the whole site, or the system the player is in).
func _refresh_made_of() -> void:
	if _made_of_vbox == null:
		return
	var model: GraphModel = null
	if _graph_view != null:
		model = _graph_view.get("model") as GraphModel
	var rows: Array = []
	if model != null:
		var scope := "root"
		if _graph_view.has_method("active_system_id") and _inside_system():
			var sid := str(_graph_view.call("active_system_id"))
			var sys_item: Dictionary = model.get_item(sid)
			if not sys_item.is_empty() and not str(sys_item.get("child_scope_id", "")).is_empty():
				scope = str(sys_item["child_scope_id"])
		# The view keeps the ledger at most a second old; computing it here
		# too doubled the cost.
		var led: Dictionary = _graph_view.call("element_ledger", scope) if _graph_view.has_method("element_ledger") else ElementLedger.compute(model, scope)
		rows = ElementLedger.rows(led)
		# What the site's structures hold (Phase 9), at the site level only.
		if scope == "root" and _graph_view.has_method("built_stock"):
			rows.append_array(BuiltStock.rows(_graph_view.call("built_stock")))
	_render_rows(_made_of_vbox, rows, _made_of_state,
		"Add tanks and machines to see the water and nutrients they hold")


func _refresh_balance() -> void:
	if _balance_vbox == null:
		return
	var model: GraphModel = null
	if _graph_view != null:
		model = _graph_view.get("model") as GraphModel
	var su := _solar_ui()
	var snap := {}
	if su != null and is_instance_valid(su):
		snap = {
			"solar_kw": float(su.get("current_solar_kw") if su.get("current_solar_kw") != null else 0.0),
			"graph_dc_kw": float(su.get("current_graph_dc_kw") if su.get("current_graph_dc_kw") != null else 0.0),
			"aux_kw": float(su.get("current_aux_generation_kw") if su.get("current_aux_generation_kw") != null else 0.0),
			"load_kw": float(su.get("current_load_kw") if su.get("current_load_kw") != null else 0.0),
			"stored_kwh": float(su.get("battery_kwh_stored") if su.get("battery_kwh_stored") != null else 0.0),
			"cap_kwh": float(su.get("BATTERY_CAPACITY_KWH") if su.get("BATTERY_CAPACITY_KWH") != null else 0.0),
			"floor_pct": float(su.get("battery_soc_shutdown_pct") if su.get("battery_soc_shutdown_pct") != null else 10.0),
		}
	if model != null and not snap.is_empty():
		# What the loads WANT, not what is served (0 while AC is shed).
		snap["demand_kw"] = GraphAcLoad.demand_watts(model) / 1000.0
	var rows: Array = []
	if model != null:
		rows = SiteBalance.rows(SiteBalance.compute(GraphNesting.walk_items(model, "root"), snap, _cost_extra(model)))
		# The forward projection runs the REAL site's loads and weather — in
		# the bootcamp sandbox it described a world the player is not in.
		var proj := [] if _sandboxed() else _projection_lines(su, snap)
		if not proj.is_empty():
			rows.append({"t": "sub", "text": "Ahead (today's loads, real weather)"})
		for pl_v in proj:
			# "Next 1 d: make … · use … · battery low …" → key "Next 1 d", value the rest.
			var pl: Dictionary = pl_v
			var txt := str(pl.get("text", ""))
			var colon := txt.find(":")
			var key := txt.left(colon) if colon > 0 else ""
			key = {"Next 1 d": "Next 24 hours", "Next 7 d": "Next 7 days"}.get(key, key)
			rows.append({"t": "note", "k": key,
				"v": txt.substr(colon + 1).strip_edges() if colon > 0 else txt, "tone": str(pl.get("tone", "muted"))})
	_render_rows(_balance_vbox, rows, _balance_state,
		"Add generators, a battery or a pond to see the site balance")


## Draws a card of SiteBalance-shaped rows ({t: kv | sub | note | alert, k, v,
## tone}) into `vbox`, rebuilding only when the rows change and updating the
## numbers in place when only they do. `st` keeps {sig, shape, values}.
func _render_rows(vbox: VBoxContainer, rows: Array, st: Dictionary, empty_hint: String) -> void:
	if not st.has("values"):
		st["values"] = []
	var parts := PackedStringArray()
	for r_v in rows:
		parts.append(JSON.stringify(r_v))
	var sig := "\n".join(parts)
	if sig == str(st.get("sig", "")):
		return
	st["sig"] = sig
	var shape_parts := PackedStringArray()
	for r_v3 in rows:
		var r3: Dictionary = r_v3
		var t3 := str(r3.get("t", "kv"))
		if t3 == "kv" or t3 == "note":
			shape_parts.append(t3 + "|" + str(r3.get("k", "")))
		else:
			shape_parts.append(t3 + "|" + str(r3.get("level", "")) + "|" + str(r3.get("text", "")))
	var shape := "\n".join(shape_parts)
	if shape == str(st.get("shape", "")) and (st["values"] as Array).size() == rows.size():
		# Same rows, new numbers — update in place (this runs every SolarUI tick).
		for i in rows.size():
			var rr: Dictionary = rows[i]
			var node: Variant = (st["values"] as Array)[i]
			if node == null or not is_instance_valid(node):
				continue
			var tn := str(rr.get("tone", ""))
			var tc := UITheme.C_WARN if tn == "warn" else (UITheme.C_GREEN if tn == "ok" else UITheme.C_TEXT)
			if node is KVRow:
				(node as KVRow).set_value(str(rr.get("v", "")))
				(node as KVRow).set_tone(tc if tn != "muted" else UITheme.C_TEXT)
			elif node is Label:
				(node as Label).text = str(rr.get("v", ""))
				(node as Label).add_theme_color_override("font_color", UITheme.C_WARN if tn == "warn" else UITheme.C_TEXT)
		return
	st["shape"] = shape
	(st["values"] as Array).clear()
	for c in vbox.get_children():
		vbox.remove_child(c)
		c.free()
	if rows.is_empty():
		var hint := Label.new()
		hint.text = empty_hint
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		vbox.add_child(hint)
		return
	# A grid, not a paragraph: key / value rows, critical state as a banner,
	# each pond under its own small heading, the look-ahead as wrapped notes.
	for r_v2 in rows:
		var r: Dictionary = r_v2
		var tone := str(r.get("tone", ""))
		var tone_col := UITheme.C_WARN if tone == "warn" else (UITheme.C_GREEN if tone == "ok" else UITheme.C_TEXT)
		match str(r.get("t", "kv")):
			"alert":
				var ban := AlertBanner.new()
				ban.show_alert(AlertBanner.ERROR if str(r.get("level", "")) == "error" else AlertBanner.WARN,
					str(r.get("text", "")))
				vbox.add_child(ban)
				(st["values"] as Array).append(null)
			"sub":
				var sub := Label.new()
				sub.text = str(r.get("text", ""))
				sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				sub.add_theme_font_override("font", UITheme.font("semibold"))
				sub.add_theme_font_size_override("font_size", UITheme.FONT_SM)
				sub.add_theme_color_override("font_color", UITheme.C_TEXT)
				vbox.add_child(sub)
				(st["values"] as Array).append(null)
			"note":
				var box := VBoxContainer.new()
				box.add_theme_constant_override("separation", 0)
				# A note with no key is a line under the row above it.
				if not str(r.get("k", "")).is_empty():
					var k := Label.new()
					k.text = str(r.get("k", ""))
					k.add_theme_font_size_override("font_size", UITheme.FONT_XS)
					k.add_theme_color_override("font_color", UITheme.C_TEXT_S)
					box.add_child(k)
				var v := Label.new()
				v.text = str(r.get("v", ""))
				v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				v.add_theme_font_size_override("font_size", UITheme.FONT_XS)
				v.add_theme_color_override("font_color", UITheme.C_WARN if tone == "warn" else UITheme.C_TEXT)
				box.add_child(v)
				vbox.add_child(box)
				(st["values"] as Array).append(v)
			_:
				var row := KVRow.make(str(r.get("k", "")), str(r.get("v", "")))
				row.set_tone(tone_col if tone != "muted" else UITheme.C_TEXT)
				vbox.add_child(row)
				(st["values"] as Array).append(row)


## The next 24 h and 7 days at today's loads and hydro, with solar from the
## real sun + weather at each hour (SiteProjection over SolarUI's pure
## evaluator). Cached — it is 168 evaluations.
func _projection_lines(su: Node, snap: Dictionary) -> Array:
	if su == null or not is_instance_valid(su) or not su.has_method("evaluate_solar_at"):
		return []
	var main := su.get("main_node") as Node
	if main == null or not main.has_method("get_absolute_hours"):
		return []
	var now_h := float(main.call("get_absolute_hours"))
	var now_ms := Time.get_ticks_msec()
	if now_ms - _proj_ms < PROJECTION_EVERY_MS and absf(now_h - _proj_abs_h) < PROJECTION_EVERY_SIM_H:
		return _proj_lines
	_proj_ms = now_ms
	_proj_abs_h = now_h
	PerfSpan.begin("gv_dash_proj")
	var out_lines := _projection_compute(su, snap, now_h)
	PerfSpan.end("gv_dash_proj")
	return out_lines


func _projection_compute(su: Node, snap: Dictionary, now_h: float) -> Array:
	var cap := float(snap.get("cap_kwh", 0.0))
	if cap <= 0.0:
		_proj_lines = []
		return _proj_lines
	var aux := float(snap.get("graph_dc_kw", 0.0)) + float(snap.get("aux_kw", 0.0))
	var demand := maxf(float(snap.get("demand_kw", 0.0)), float(snap.get("load_kw", 0.0)))
	_check_solar_cache(su)
	var fn := func(abs_h: float) -> Dictionary:
		return {"solar_kw": _solar_at(su, abs_h), "aux_kw": aux, "load_kw": demand}
	var floor_pct := float(snap.get("floor_pct", 10.0))
	var resume_pct := float(su.get("battery_soc_resume_pct")) if su.get("battery_soc_resume_pct") != null else 20.0
	var out: Array = []
	for span: float in [24.0, 168.0]:
		var p := SiteProjection.project(now_h, span, 1.0, fn, cap,
				float(snap.get("stored_kwh", 0.0)), 0.95, 0.95, floor_pct, resume_pct)
		out.append(SiteProjection.summary_line(p, cap))
	_proj_lines = out
	# Hours behind the clock are never asked for again.
	for hk in _solar_hours.keys():
		if int(hk) < int(floor(now_h)) - 1:
			_solar_hours.erase(hk)
	return _proj_lines


func _check_solar_cache(su: Node) -> void:
	var m: GraphModel = _graph_view.get("model") as GraphModel if _graph_view != null else null
	var key := "%d|%d|%s|%s|%s|%s" % [int(m.struct_rev) if m != null else -1, int(m.user_rev) if m != null else -1,
		str(su.get("PANEL_COUNT")), str(su.get("PANEL_WATTAGE")), str(su.get("panel_tilt_degrees")),
		str(su.get("panel_azimuth_degrees"))]
	var now_ms := Time.get_ticks_msec()
	if key != _solar_hours_key or now_ms - _solar_hours_ms > SOLAR_CACHE_MS:
		_solar_hours.clear()
		_solar_hours_key = key
		_solar_hours_ms = now_ms


## SolarUI's solar at `abs_h`, linear between whole-hour evaluations.
func _solar_at(su: Node, abs_h: float) -> float:
	var h0 := int(floor(abs_h))
	var f := abs_h - float(h0)
	var a := _solar_hour(su, h0)
	if f < 1e-6:
		return a
	return lerpf(a, _solar_hour(su, h0 + 1), f)


func _solar_hour(su: Node, h: int) -> float:
	if _solar_hours.has(h):
		return float(_solar_hours[h])
	var v := float(su.call("evaluate_solar_at", float(h)))
	_solar_hours[h] = v
	return v


func _refresh_stores() -> void:
	var model: GraphModel = null
	if _graph_view != null:
		model = _graph_view.get("model") as GraphModel
	var rows: Array = []
	var islands := 0
	if model != null:
		# The SITE's own stores at any depth (a tank in a group of the
		# player's used to be missed); camps and vehicles keep their own,
		# and say so below instead of flooding this list with 200 tanks.
		rows = store_rows(GraphSystems.walk_site_power(model))
		islands = GraphSystems.list(model).size()

	# Rebuild only when content changes. The old free-then-add pattern used
	# queue_free(), which is deferred — any frame where refresh(true) ran more
	# than once (bind + set_mode + closure telemetry all force it) rendered N
	# copies of every row until end of frame.
	var sig_parts := PackedStringArray()
	if model == null:
		sig_parts.append("<no-model>")
	sig_parts.append("islands=%d" % islands)
	for row: Dictionary in rows:
		sig_parts.append("%s|%s|%d|%.1f|%.0f" % [str(row["kind"]), str(row["name"]),
				int(row["count"]), float(row["stock"]), float(row["cap"])])
		for tank_v in (row.get("tanks", []) as Array):
			var tank: Dictionary = tank_v
			sig_parts.append("  %s|%.1f|%.0f" % [str(tank["name"]),
					float(tank["stock"]), float(tank["cap"])])
	var sig := "\n".join(sig_parts)
	if sig == _stores_sig:
		return
	_stores_sig = sig

	for c in _stores_vbox.get_children():
		_stores_vbox.remove_child(c)
		c.free()

	if model == null or rows.is_empty():
		var hint := Label.new()
		hint.text = "No tanks on graph" if model == null \
				else "Add resource tanks from the library"
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_stores_vbox.add_child(hint)
		_add_island_stores_note(islands)
		return

	for row_data: Dictionary in rows:
		var tanks: Array = row_data.get("tanks", [])
		if tanks.size() <= 1:
			# One tank of this kind: one row, named after the real tank.
			_add_store_row(str(row_data["name"]), float(row_data["stock"]),
					float(row_data["cap"]), str(row_data["unit"]), false)
			continue
		# Several tanks of one kind: a per-kind subtotal line, then one honest
		# row per tank (this is what replaced the old first-item-wins single
		# row — a camp with a cistern AND rain barrels should read as both).
		var subtotal := Label.new()
		subtotal.text = "%s — %s · %s / %s %s" % [
			ResourceKinds.display_name(str(row_data["kind"])), UiText.count(tanks.size(), "tank"),
			_fmt_qty(float(row_data["stock"])), _fmt_qty(float(row_data["cap"])),
			str(row_data["unit"])]
		subtotal.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		subtotal.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_stores_vbox.add_child(subtotal)
		for tank_v in tanks:
			var tank: Dictionary = tank_v
			_add_store_row(str(tank["name"]), float(tank["stock"]),
					float(tank["cap"]), str(tank["unit"]), true)
	_add_island_stores_note(islands)


## Says what the store list covers when camps / vehicles exist: they are
## their own systems with their own tanks.
func _add_island_stores_note(islands: int) -> void:
	if islands <= 0:
		return
	var note := Label.new()
	note.text = "Site stores only. Camps and vehicles (%d) keep their own: open one to see its tanks." % islands
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_stores_vbox.add_child(note)


func _add_store_row(name: String, stock: float, cap_qty: float,
		unit: String, indent: bool) -> void:
	var frac := clampf(stock / cap_qty, 0.0, 1.0) if cap_qty > 0.0 else 0.0
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_stores_vbox.add_child(row)
	if indent:
		var pad := Control.new()
		pad.custom_minimum_size = Vector2(10, 0)
		row.add_child(pad)
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(70 if indent else 80, 10)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.max_value = 100.0
	bar.value = frac * 100.0
	bar.show_percentage = false
	_style_progress(bar)
	row.add_child(bar)
	var lbl := Label.new()
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text = "%s  %.0f%%" % [name, frac * 100.0]
	if cap_qty > 0.0:
		lbl.text = "%s  %s / %s %s" % [name, _fmt_qty(stock), _fmt_qty(cap_qty), unit]
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(lbl)


## Compact quantity: 30000 -> "30k", 1234.5 -> "1234.5" -> keeps tank rows from
## wrapping the narrow sidebar.
static func _fmt_qty(v: float) -> String:
	if absf(v) >= 10000.0:
		return "%.0fk" % (v / 1000.0)
	if absf(v) >= 100.0 or is_equal_approx(v, roundf(v)):
		return "%.0f" % v
	return "%.1f" % v


## Sim activity names -> what a player would call them. Raw fallthrough keeps
## a NEW sim activity visible (capitalised) instead of silently dropped.
const _ACTIVITY_LABELS := {
	"chore": "working", "sleep": "sleeping", "hunger": "eating",
	"thirst": "drinking", "bladder": "restroom", "hygiene": "washing",
	"enrichment": "gathering", "idle": "free", "walking": "walking",
}


## 🏕 SETTLEMENT — the people themselves: headcount, mood, what everyone is
## doing right now, and the latest notable settlement-log lines. This is the
## panel answer to "the sidebar told me nothing about my community".
func _refresh_settlement() -> void:
	if _settlement_vbox == null:
		return
	var summary: Dictionary = {}
	if _graph_view != null and _graph_view.has_method("npc_dot_summary"):
		summary = _graph_view.call("npc_dot_summary") as Dictionary
	# Alerts ride their own named settlement-log cursor ("dashboard") — the
	# cursor pattern exists precisely so this never races the toast drain or
	# the challenge bake's collapse watcher. Bridge is null on an MP guest.
	if _graph_view != null and _graph_view.has_method("npc_population_bridge"):
		var bridge: Variant = _graph_view.call("npc_population_bridge")
		if bridge != null and bridge.has_method("log_since"):
			for e in (bridge.call("log_since", "dashboard") as Array):
				var ev: Dictionary = e
				if _ALERT_KINDS.has(str(ev.get("kind", ""))):
					_alerts.append(str(ev.get("text", "")))
	while _alerts.size() > _MAX_ALERTS:
		_alerts.pop_front()

	var sig_parts := PackedStringArray()
	if summary.is_empty():
		sig_parts.append("<none>")
	else:
		sig_parts.append("n=%d t=%d m=%.2f" % [int(summary.get("count", 0)),
				int(summary.get("traveling", 0)), float(summary.get("morale_avg", 0.0))])
		var acts: Dictionary = summary.get("activities", {})
		var akeys: Array = acts.keys()
		akeys.sort()
		for a in akeys:
			sig_parts.append("a:%s=%d" % [str(a), int(acts[a])])
	for al in _alerts:
		sig_parts.append("!%s" % str(al))
	var vibe: Dictionary = _graph_view.call("festival_vibe") \
		if _graph_view != null and _graph_view.has_method("festival_vibe") else {}
	if not vibe.is_empty():
		sig_parts.append("v=%s" % str(vibe.get("headline", "")))
	var sig := "\n".join(sig_parts)
	if sig == _settlement_sig:
		return
	_settlement_sig = sig

	for c in _settlement_vbox.get_children():
		_settlement_vbox.remove_child(c)
		c.free()

	if summary.is_empty():
		var hint := Label.new()
		hint.text = "No settlement yet — enable Population on a habitat"
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_settlement_vbox.add_child(hint)
		return

	var morale_avg := float(summary.get("morale_avg", 0.0))
	var head := Label.new()
	head.text = "👥 %d people · %s" % [int(summary.get("count", 0)),
			NpcMorale.label(morale_avg)]
	head.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	head.add_theme_color_override("font_color", NpcMorale.color(morale_avg))
	_settlement_vbox.add_child(head)

	# One line of "what everyone is doing", biggest groups first.
	var acts2: Dictionary = summary.get("activities", {})
	var pairs: Array = []
	for a in acts2.keys():
		pairs.append([int(acts2[a]), str(a)])
	var traveling := int(summary.get("traveling", 0))
	if traveling > 0:
		pairs.append([traveling, "walking"])
	pairs.sort_custom(func(x, y): return int(x[0]) > int(y[0]))
	var bits := PackedStringArray()
	for p in pairs.slice(0, 4):
		var label := str(_ACTIVITY_LABELS.get(str(p[1]), str(p[1]).capitalize()))
		bits.append("%d %s" % [int(p[0]), label])
	if not bits.is_empty():
		var act_lbl := Label.new()
		act_lbl.text = " · ".join(bits)
		act_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		act_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		act_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		_settlement_vbox.add_child(act_lbl)

	for al in _alerts:
		var alert_lbl := Label.new()
		alert_lbl.text = "⚠ %s" % str(al)
		alert_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		alert_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		alert_lbl.add_theme_color_override("font_color", UITheme.C_WARN)
		_settlement_vbox.add_child(alert_lbl)
	# Festival: the whole event's vibe + its band histogram, from the camp
	# compounds (festival plan Phase 7). Absent on a single-camp map.
	if not vibe.is_empty() and int(vibe.get("people", 0)) > 0:
		var fhead := Label.new()
		fhead.text = "🎪 " + str(vibe.get("headline", ""))
		fhead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fhead.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		fhead.add_theme_color_override("font_color", vibe.get("color", UITheme.C_TEXT) as Color)
		_settlement_vbox.add_child(fhead)
		var hist: Array = vibe.get("histogram", [])
		var hbits := PackedStringArray()
		for i in hist.size():
			if int(hist[i]) > 0:
				hbits.append("%d %s" % [int(hist[i]), str((NpcMorale.BANDS[i] as Dictionary)["label"])])
		if not hbits.is_empty():
			var hl := Label.new()
			hl.text = " · ".join(hbits)
			hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			hl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			hl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			_settlement_vbox.add_child(hl)


# ---------------------------------------------------------------------------
# The dashboard follows the active system (plans/GRAPH_SYSTEMS_UX_PLAN.md
# Phase 3). At the site's own level with camps or vehicles on the site the
# tabs are Whole festival · Your system · Board; inside a camp or vehicle they
# are <that system> · Board. Everything here READS the view's board rows
# (GraphSystemBoard, rebuilt once a second); the site's own cards are the
# "Your system" tab, unchanged.
# ---------------------------------------------------------------------------

const TAB_FESTIVAL := "festival"
const TAB_SITE := "site"
const TAB_SYSTEM := "system"
const TAB_BOARD := "board"

var _tab_bar: HBoxContainer = null
var _tab_btns: Dictionary = {}
var _tab_root := ""        # the player's pick at the site level ("" = default)
var _tab_inside := ""      # … and inside a system
var _tab_now := ""
var _tabs_sig := "<unset>"
var _site_nodes: Array = []
var _settle_nodes: Array = []
var _system_wrap: Control = null
var _system_vbox: VBoxContainer = null
var _system_sig := "<unset>"
var _festival_wrap: Control = null
var _festival_vbox: VBoxContainer = null
var _festival_sig := "<unset>"
var _board_wrap: Control = null
var _board: GraphFestivalBoard = null


func _build_system_tabs() -> void:
	# The cards _build_ui made, in order: power, balance, closure, settlement,
	# stores (title + body each). Settlement also shows on the festival tab.
	var kids := get_children()
	for i in kids.size():
		if i == 6 or i == 7:
			_settle_nodes.append(kids[i])
		else:
			_site_nodes.append(kids[i])
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 12)
	m.add_theme_constant_override("margin_right", 12)
	m.add_theme_constant_override("margin_top", 8)
	m.add_theme_constant_override("margin_bottom", 2)
	_tab_bar = HBoxContainer.new()
	_tab_bar.name = "SystemTabs"
	_tab_bar.add_theme_constant_override("separation", 4)
	m.add_child(_tab_bar)
	add_child(m)
	move_child(m, 0)
	_tab_bar.set_meta("wrap", m)
	for t: String in [TAB_FESTIVAL, TAB_SITE, TAB_SYSTEM, TAB_BOARD]:
		var b := Button.new()
		b.name = "Tab_" + t
		b.toggle_mode = true
		b.focus_mode = Control.FOCUS_NONE
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 26)
		b.pressed.connect(set_tab.bind(t))
		_tab_bar.add_child(b)
		_tab_btns[t] = b

	_system_wrap = _card_body()
	_system_wrap.name = "SystemCard"
	_system_vbox = _card_inner(_system_wrap)
	add_child(_system_wrap)
	move_child(_system_wrap, 1)
	_festival_wrap = _card_body()
	_festival_wrap.name = "FestivalCard"
	_festival_vbox = _card_inner(_festival_wrap)
	add_child(_festival_wrap)
	move_child(_festival_wrap, 2)
	_board_wrap = _card_body()
	_board_wrap.name = "BoardCard"
	_board = GraphFestivalBoard.new()
	_card_inner(_board_wrap).add_child(_board)
	_board.expand_pressed.connect(func() -> void:
		if _graph_view != null and _graph_view.has_method("toggle_board_fullscreen"):
			_graph_view.call("toggle_board_fullscreen"))
	add_child(_board_wrap)
	move_child(_board_wrap, 3)
	_refresh_tabs()


## Pick a tab ("festival" | "site" | "system" | "board"); remembered per level.
func set_tab(t: String) -> void:
	if _inside_system():
		_tab_inside = t
	else:
		_tab_root = t
	_tabs_sig = "<unset>"
	_refresh_tabs()
	refresh(true)


func current_tab() -> String:
	return _tab_now


func board() -> GraphFestivalBoard:
	return _board


func _rows() -> Array:
	if _graph_view == null or not _graph_view.has_method("system_board_rows"):
		return []
	return _graph_view.call("system_board_rows") as Array


func _inside_system() -> bool:
	return _graph_view != null and _graph_view.has_method("active_system_id") \
		and not str(_graph_view.call("active_system_id")).is_empty()


func _refresh_tabs() -> void:
	if _tab_bar == null:
		return
	var rows := _rows()
	var inside := _inside_system()
	var sys_id := str(_graph_view.call("active_system_id")) if inside else ""
	var row: Dictionary = _graph_view.call("system_board_row", sys_id) if inside else {}
	var opts: Array = []
	var tab := ""
	if inside:
		opts = [TAB_SYSTEM, TAB_BOARD]
		tab = _tab_inside if _tab_inside in opts else TAB_SYSTEM
	elif rows.size() > 1:
		opts = [TAB_FESTIVAL, TAB_SITE, TAB_BOARD]
		# Decision #3 (plan): the whole festival by default when camps exist.
		tab = _tab_root if _tab_root in opts else TAB_FESTIVAL
	else:
		tab = TAB_SITE
	_tab_now = tab
	var name := str(row.get("name", "This system"))
	var sig := "%s|%s|%s" % [str(opts), tab, name]
	if sig != _tabs_sig:
		_tabs_sig = sig
		(_tab_bar.get_meta("wrap") as Control).visible = not opts.is_empty()
		for t: String in _tab_btns.keys():
			var b: Button = _tab_btns[t]
			b.visible = t in opts
			match t:
				TAB_FESTIVAL:
					b.text = "Whole festival"
				TAB_SITE:
					b.text = "Your system"
				TAB_SYSTEM:
					var icon := "🚐 " if str(row.get("kind", "")) == GraphSystems.KIND_VEHICLE else "⛺ "
					b.text = icon + name
					b.tooltip_text = name
				TAB_BOARD:
					b.text = "Board"
			b.set_pressed_no_signal(t == tab)
			UITheme.style_toggle(b, t == tab, UITheme.FONT_XS)
		for n: Control in _site_nodes:
			n.visible = tab == TAB_SITE
		for n: Control in _settle_nodes:
			n.visible = tab == TAB_SITE or tab == TAB_FESTIVAL
		_system_wrap.visible = tab == TAB_SYSTEM
		_festival_wrap.visible = tab == TAB_FESTIVAL
		_board_wrap.visible = tab == TAB_BOARD
		if tab == TAB_BOARD and _board != null and _graph_view != null:
			_board.bind(_graph_view)
	match tab:
		TAB_SYSTEM:
			_refresh_system_card(row)
		TAB_FESTIVAL:
			_refresh_festival_card(rows)


func _small(text: String, col: Color, fs: int = UITheme.FONT_XS, wrap: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", col)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


static func _fmt_h(h: float) -> String:
	if h < 1.0:
		return "%d min" % int(round(h * 60.0))
	if h < 48.0:
		return "%.1f h" % h
	return "%.1f days" % (h / 24.0)


## One system's balance: battery, solar, loads, time to empty / full,
## stores and open loops.
func _refresh_system_card(r: Dictionary) -> void:
	if r.is_empty():
		var sig0 := "<none>"
		if sig0 == _system_sig:
			return
		_system_sig = sig0
		for c in _system_vbox.get_children():
			_system_vbox.remove_child(c)
			c.free()
		_system_vbox.add_child(_small("Reading this system…", UITheme.C_TEXT_M))
		return
	var parts := PackedStringArray([str(r["name"]), str(r["level"]), ",".join(PackedStringArray(r["reasons"])),
		"%.2f|%.2f|%.2f|%.1f|%s|%d|%.2f" % [float(r["soc"]), float(r["pv_kw"]), float(r["load_kw"]),
		minf(float(r["hours_left"]), 9999.0), str(r["ac"]), int(r["people"]), float(r["morale"])]])
	for st: Dictionary in (r["stores"] as Array):
		parts.append("%s|%.0f|%.0f|%.2f" % [st["kind"], float(st["stock"]), float(st["capacity"]),
			minf(float(st["days"]), 9999.0)])
	parts.append(str(r["open"]))
	var sig := "\n".join(parts)
	if sig == _system_sig:
		return
	_system_sig = sig
	for c in _system_vbox.get_children():
		_system_vbox.remove_child(c)
		c.free()
	var lvl := str(r["level"])
	var lcol: Color = GraphFestivalBoard.LEVEL_COLORS.get(lvl, UITheme.C_TEXT_M)
	var head := _small(("🚐 " if str(r["kind"]) == GraphSystems.KIND_VEHICLE else "⛺ ") + str(r["name"]),
		UITheme.C_TEXT, UITheme.FONT_MD)
	head.name = "SystemTitle"
	_system_vbox.add_child(head)
	var reasons: Array = r["reasons"]
	var verdict := "Everything is fine." if reasons.is_empty() else "Needs: " + ", ".join(PackedStringArray(reasons))
	if lvl == "idle":
		verdict = "Nobody here and nothing running."
	var v := _small(verdict, lcol if not reasons.is_empty() else UITheme.C_GREEN, UITheme.FONT_XS, true)
	v.name = "SystemVerdict"
	_system_vbox.add_child(v)
	var cap := float(r["cap_kwh"])
	if cap > 0.0:
		var bar_row := HBoxContainer.new()
		bar_row.add_theme_constant_override("separation", 8)
		_system_vbox.add_child(bar_row)
		var bar := ProgressBar.new()
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.custom_minimum_size = Vector2(0, 14)
		bar.max_value = 100.0
		bar.value = clampf(float(r["soc"]), 0.0, 1.0) * 100.0
		bar.show_percentage = false
		UITheme.style_progress(bar, lcol if float(r["soc"]) < GraphSystemBoard.SOC_WARN else UITheme.C_PRIMARY)
		bar_row.add_child(bar)
		bar_row.add_child(_small("%d %%" % int(round(float(r["soc"]) * 100.0)), UITheme.C_TEXT, UITheme.FONT_SM))
		_system_vbox.add_child(_small("Battery %.1f / %.1f kWh" % [float(r["kwh"]), cap], UITheme.C_TEXT_S))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	_system_vbox.add_child(grid)
	var net := float(r["pv_kw"]) - float(r["load_kw"])
	_stat_cell(grid, "SOLAR", "%.2f kW" % float(r["pv_kw"]), UITheme.C_GOLD)
	_stat_cell(grid, "LOAD", "%.2f kW" % float(r["load_kw"]), UITheme.C_TEXT)
	var net_lbl := _stat_cell(grid, "NET", "%+.2f kW" % net, UITheme.C_PRIMARY)
	net_lbl.add_theme_color_override("font_color", UITheme.C_GREEN if net >= 0.0 else UITheme.C_WARN)
	var when := "—"
	if cap > 0.0 and is_finite(float(r["hours_left"])):
		when = "empty " + _fmt_h(float(r["hours_left"]))
	elif cap > 0.0 and net > 0.01 and float(r["kwh"]) < cap - 0.01:
		when = "full " + _fmt_h((cap - float(r["kwh"])) / net)
	elif cap > 0.0 and float(r["kwh"]) >= cap - 0.01:
		when = "full"
	_stat_cell(grid, "TIME", when, UITheme.C_TEXT_S)
	if not bool(r["ac"]):
		_system_vbox.add_child(_small("Its loads are OFF: the battery is empty. They come back when it recharges.",
			GraphFestivalBoard.LEVEL_COLORS["crit"], UITheme.FONT_XS, true))
	if int(r["people"]) >= 0:
		var ppl := UiText.count(int(r["people"]), "person", "people")
		if float(r["morale"]) >= 0.0:
			ppl += " · morale %d %%" % int(round(float(r["morale"]) * 100.0))
		_system_vbox.add_child(_small(ppl, UITheme.C_TEXT_S))
	var stores: Array = r["stores"]
	if not stores.is_empty():
		_system_vbox.add_child(SectionHeader.make("Stores"))
		for st: Dictionary in stores:
			var frac := clampf(float(st["stock"]) / float(st["capacity"]), 0.0, 1.0) if float(st["capacity"]) > 0.0 else 0.0
			var hb := HBoxContainer.new()
			hb.add_theme_constant_override("separation", 6)
			_system_vbox.add_child(hb)
			var b2 := ProgressBar.new()
			b2.custom_minimum_size = Vector2(56, 10)
			b2.max_value = 100.0
			b2.value = frac * 100.0
			b2.show_percentage = false
			var waste := CampLedger.WASTE_KINDS.has(str(st["kind"]))
			var days := float(st["days_full"] if waste else st["days"])
			var scol := UITheme.C_PRIMARY
			if days < GraphSystemBoard.DAYS_CRIT:
				scol = GraphFestivalBoard.LEVEL_COLORS["crit"]
			elif days < GraphSystemBoard.DAYS_WARN:
				scol = GraphFestivalBoard.LEVEL_COLORS["warn"]
			UITheme.style_progress(b2, scol)
			hb.add_child(b2)
			var st_when := GraphSystemBoard.fmt_days(days)
			if waste:
				st_when = GraphSystemBoard.fmt_full(days)
			var l := _small("%s  %s / %s %s · %s" % [ResourceKinds.display_name(str(st["kind"])),
				_fmt_qty(float(st["stock"])), _fmt_qty(float(st["capacity"])),
				str(st["unit"]).trim_suffix("/h").trim_suffix("/day"), st_when], UITheme.C_TEXT_S)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hb.add_child(l)
	var used := PackedStringArray()
	var kept := PackedStringArray()
	for k: Variant in (r["open"] as Array):
		if CampLedger.WASTE_KINDS.has(str(k)):
			kept.append(ResourceKinds.display_name(str(k)))
		else:
			used.append(ResourceKinds.display_name(str(k)))
	if not used.is_empty():
		_system_vbox.add_child(_small("Brought in, not made here: %s." % ", ".join(used),
			UITheme.C_TEXT_M, UITheme.FONT_XS, true))
	if not kept.is_empty():
		_system_vbox.add_child(_small("Kept here, not taken away: %s." % ", ".join(kept),
			UITheme.C_TEXT_M, UITheme.FONT_XS, true))
	if str(r.get("kind", "")) == GraphSystems.KIND_CAMP and _graph_view != null:
		var ideas: Array = CampLoopClosure.suggest(_graph_view.get("model"), str(r.get("id", "")))
		if not ideas.is_empty():
			var idea: Dictionary = ideas[0]
			var opts: Array = CampLoopClosure.options(idea, 1)
			if not opts.is_empty():
				var opt: Dictionary = opts[0]
				var add_btn := Button.new()
				add_btn.text = "Add %s" % str(opt["text"])
				add_btn.focus_mode = Control.FOCUS_NONE
				add_btn.tooltip_text = str(idea.get("text", ""))
				var cid := str(r.get("id", ""))
				add_btn.pressed.connect(func() -> void:
					if _graph_view == null:
						return
					var made: Array = CampLoopClosure.apply_option(_graph_view.get("model"), cid, opt)
					if made.is_empty():
						return
					add_btn.disabled = true
					if _graph_view.has_method("_push_history"):
						_graph_view.call("_push_history")
					if _graph_view.has_method("_schedule_graph_autosave"):
						_graph_view.call("_schedule_graph_autosave")
					_system_sig = ""
				)
				_system_vbox.add_child(add_btn)
	_system_vbox.add_child(_small("Esc goes back out to the site.", UITheme.C_TEXT_M))


## The whole festival: systems by state, people, power, the worst few.
func _refresh_festival_card(rows: Array) -> void:
	var t := GraphSystemBoard.totals(rows)
	var worst := GraphSystemBoard.sorted(GraphSystemBoard.filtered(rows, "attention"), "attention")
	var site: Dictionary = rows[0] if not rows.is_empty() else {}
	var vibe: Dictionary = {}
	if _graph_view != null and _graph_view.has_method("festival_vibe"):
		vibe = _graph_view.call("festival_vibe") as Dictionary
	var parts := PackedStringArray([str(t), str(vibe.get("headline", "")),
		"%.2f|%.2f" % [float(site.get("soc", -1.0)), float(site.get("pv_kw", 0.0))]])
	for i in mini(worst.size(), 5):
		var w: Dictionary = worst[i]
		parts.append("%s|%s|%s" % [w["id"], w["name"], ",".join(PackedStringArray(w["reasons"]))])
	var sig := "\n".join(parts)
	if sig == _festival_sig:
		return
	_festival_sig = sig
	for c in _festival_vbox.get_children():
		_festival_vbox.remove_child(c)
		c.free()
	var kinds := PackedStringArray()
	if int(t["camps"]) > 0:
		kinds.append(UiText.count(int(t["camps"]), "camp"))
	if int(t["vehicles"]) > 0:
		kinds.append(UiText.count(int(t["vehicles"]), "vehicle"))
	if int(t["people"]) > 0:
		kinds.append(UiText.count(int(t["people"]), "person", "people"))
	var head := _small(" · ".join(kinds), UITheme.C_TEXT, UITheme.FONT_MD)
	head.name = "FestivalTitle"
	_festival_vbox.add_child(head)
	if not str(vibe.get("headline", "")).is_empty():
		_festival_vbox.add_child(_small(str(vibe["headline"]), UITheme.C_TEXT_S, UITheme.FONT_XS, true))
	var crit := int(t["crit"])
	var warn := int(t["warn"])
	var att := "Nothing needs attention." if crit + warn == 0 else \
		"Needs attention: %d critical, %d warning" % [crit, warn]
	_festival_vbox.add_child(_small(att, GraphFestivalBoard.LEVEL_COLORS["crit" if crit > 0 else ("warn" if warn > 0 else "ok")]))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	_festival_vbox.add_child(grid)
	_stat_cell(grid, "SOLAR", "%.1f kW" % float(t["pv_kw"]), UITheme.C_GOLD)
	_stat_cell(grid, "LOAD", "%.1f kW" % float(t["load_kw"]), UITheme.C_TEXT)
	var stored := "—" if float(t["cap_kwh"]) <= 0.0 else "%d %%" % int(round(float(t["kwh"]) / float(t["cap_kwh"]) * 100.0))
	_stat_cell(grid, "STORED", stored, UITheme.C_PRIMARY)
	var np := _stat_cell(grid, "NO POWER", str(int(t["no_power"])), UITheme.C_TEXT)
	if int(t["no_power"]) > 0:
		np.add_theme_color_override("font_color", GraphFestivalBoard.LEVEL_COLORS["crit"])
	if int(t["short_water"]) + int(t["short_food"]) > 0:
		_festival_vbox.add_child(_small("Short of water: %d · short of food: %d (under 3 days)" % [
			int(t["short_water"]), int(t["short_food"])], GraphFestivalBoard.LEVEL_COLORS["warn"]))
	if not worst.is_empty():
		_festival_vbox.add_child(SectionHeader.make("Worst first"))
		for i in mini(worst.size(), 5):
			var w: Dictionary = worst[i]
			var b := Button.new()
			b.name = "Worst_" + str(w["id"])
			b.flat = true
			b.focus_mode = Control.FOCUS_NONE
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.clip_text = true
			b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			b.text = "%s · %s" % [str(w["name"]), ", ".join(PackedStringArray(w["reasons"]))]
			b.tooltip_text = b.text + "\nClick to fly there."
			b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			b.add_theme_color_override("font_color", GraphFestivalBoard.LEVEL_COLORS[str(w["level"])])
			b.pressed.connect(func() -> void: _graph_view.call("board_fly_to", str(w["id"]), false))
			_festival_vbox.add_child(b)
		if worst.size() > 5:
			var more := Button.new()
			more.text = "All %d on the board" % worst.size()
			UITheme.style_button(more)
			more.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			more.pressed.connect(func() -> void:
				set_tab(TAB_BOARD)
				_board.set_filter("attention"))
			_festival_vbox.add_child(more)
	if not site.is_empty() and float(site.get("cap_kwh", 0.0)) > 0.0:
		var own := Button.new()
		own.flat = true
		own.focus_mode = Control.FOCUS_NONE
		own.alignment = HORIZONTAL_ALIGNMENT_LEFT
		own.text = "🏠 Your system: %d %% · %.2f kW solar  ›" % [int(round(float(site["soc"]) * 100.0)), float(site["pv_kw"])]
		own.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		own.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		own.pressed.connect(set_tab.bind(TAB_SITE))
		_festival_vbox.add_child(own)

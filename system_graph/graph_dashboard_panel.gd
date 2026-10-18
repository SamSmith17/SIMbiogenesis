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
## Content signature of the last-built store rows. Starts at a sentinel, never
## "" — an empty board yields an empty signature, and "" would compare equal on
## the first pass so the empty-state hint would never build.
var _stores_sig := "<unset>"
var _settlement_vbox: VBoxContainer = null
var _settlement_sig := "<unset>"
## SITE BALANCE card (SiteBalance.lines) — rebuilt on content change only.
var _balance_vbox: VBoxContainer = null
var _balance_sig := "<unset>"
## Row structure of the balance card (types + keys) and the value nodes built
## for it, so a tick that only changes numbers updates labels in place.
var _balance_shape := "<unset>"
var _balance_values: Array = []
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
	_refresh_power()
	_refresh_closure()
	# Stores + Settlement walk model/roster arrays — 1 Hz is plenty, and the
	# signature diffs inside them make even that mostly free.
	var now_ms := Time.get_ticks_msec()
	if now_ms - _slow_last_ms >= REFRESH_SLOW_MS:
		_slow_last_ms = now_ms
		_refresh_stores()
		_refresh_settlement()
		_refresh_balance()


func _process(delta: float) -> void:
	# Nothing refreshes while the panel is off screen (the graph closed): the
	# 5 Hz power / closure refresh used to run behind the first-person view.
	# `_on_visibility_changed` forces one refresh when it comes back.
	if not is_visible_in_tree():
		return
	_refresh_acc += delta
	if _refresh_acc >= REFRESH_INTERVAL:
		refresh(true)
	var su := _solar_ui()
	if su == null or not is_instance_valid(su):
		return
	var sv: Variant = su.get("sim_tick_serial")
	if sv != null and int(sv) != _solar_serial:
		_solar_serial = int(sv)
		_refresh_power()
		_refresh_balance()


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
		rows = SiteBalance.rows(SiteBalance.compute(GraphNesting.walk_items(model, "root"), snap))
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
	var parts := PackedStringArray()
	for r_v in rows:
		parts.append(JSON.stringify(r_v))
	var sig := "\n".join(parts)
	if sig == _balance_sig:
		return
	_balance_sig = sig
	var shape_parts := PackedStringArray()
	for r_v3 in rows:
		var r3: Dictionary = r_v3
		var t3 := str(r3.get("t", "kv"))
		if t3 == "kv" or t3 == "note":
			shape_parts.append(t3 + "|" + str(r3.get("k", "")))
		else:
			shape_parts.append(t3 + "|" + str(r3.get("level", "")) + "|" + str(r3.get("text", "")))
	var shape := "\n".join(shape_parts)
	if shape == _balance_shape and _balance_values.size() == rows.size():
		# Same rows, new numbers — update in place (this runs every SolarUI tick).
		for i in rows.size():
			var rr: Dictionary = rows[i]
			var node: Variant = _balance_values[i]
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
	_balance_shape = shape
	_balance_values.clear()
	for c in _balance_vbox.get_children():
		_balance_vbox.remove_child(c)
		c.free()
	if rows.is_empty():
		var hint := Label.new()
		hint.text = "Add generators, a battery or a pond to see the site balance"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_balance_vbox.add_child(hint)
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
				_balance_vbox.add_child(ban)
				_balance_values.append(null)
			"sub":
				var sub := Label.new()
				sub.text = str(r.get("text", ""))
				sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				sub.add_theme_font_override("font", UITheme.font("semibold"))
				sub.add_theme_font_size_override("font_size", UITheme.FONT_SM)
				sub.add_theme_color_override("font_color", UITheme.C_TEXT)
				_balance_vbox.add_child(sub)
				_balance_values.append(null)
			"note":
				var box := VBoxContainer.new()
				box.add_theme_constant_override("separation", 0)
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
				_balance_vbox.add_child(box)
				_balance_values.append(v)
			_:
				var row := KVRow.make(str(r.get("k", "")), str(r.get("v", "")))
				row.set_tone(tone_col if tone != "muted" else UITheme.C_TEXT)
				_balance_vbox.add_child(row)
				_balance_values.append(row)


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
	var cap := float(snap.get("cap_kwh", 0.0))
	if cap <= 0.0:
		_proj_lines = []
		return _proj_lines
	var aux := float(snap.get("graph_dc_kw", 0.0)) + float(snap.get("aux_kw", 0.0))
	var demand := maxf(float(snap.get("demand_kw", 0.0)), float(snap.get("load_kw", 0.0)))
	var fn := func(abs_h: float) -> Dictionary:
		return {"solar_kw": float(su.call("evaluate_solar_at", abs_h)), "aux_kw": aux, "load_kw": demand}
	var floor_pct := float(snap.get("floor_pct", 10.0))
	var resume_pct := float(su.get("battery_soc_resume_pct")) if su.get("battery_soc_resume_pct") != null else 20.0
	var out: Array = []
	for span: float in [24.0, 168.0]:
		var p := SiteProjection.project(now_h, span, 1.0, fn, cap,
				float(snap.get("stored_kwh", 0.0)), 0.95, 0.95, floor_pct, resume_pct)
		out.append(SiteProjection.summary_line(p, cap))
	_proj_lines = out
	return _proj_lines


func _refresh_stores() -> void:
	var model: GraphModel = null
	if _graph_view != null:
		model = _graph_view.get("model") as GraphModel
	var rows: Array = []
	if model != null:
		rows = store_rows(model.get_items_in_scope("root"))

	# Rebuild only when content changes. The old free-then-add pattern used
	# queue_free(), which is deferred — any frame where refresh(true) ran more
	# than once (bind + set_mode + closure telemetry all force it) rendered N
	# copies of every row until end of frame.
	var sig_parts := PackedStringArray()
	if model == null:
		sig_parts.append("<no-model>")
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

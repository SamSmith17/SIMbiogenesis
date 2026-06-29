extends "res://system_graph/graph_canvas.gd"

const InteractionController := preload("res://system_graph_v2/interaction_controller.gd")
const NodeRenderer := preload("res://system_graph_v2/node_renderer.gd")
const WireRenderer := preload("res://system_graph_v2/wire_renderer.gd")
const PortResolver := preload("res://system_graph_v2/port_resolver.gd")

var _interaction: GraphInteractionControllerV2
var _node_renderer: GraphNodeRendererV2
var _wire_renderer: GraphWireRendererV2
var _port_resolver: GraphPortResolverV2

var _legend_visible: bool = true
var _hint_alpha: float = 0.0
var _hover_port: Dictionary = {}

const V2_NODE_SHADOW := Color(0.0, 0.0, 0.0, 0.26)
const V2_TITLE_GLOW := Color(0.13, 0.83, 0.93, 0.14)
const V2_PORT_RING := Color(0.95, 0.97, 1.0, 0.75)
const V2_FLOW_ARROW_ALPHA := 0.82


func _ready() -> void:
	super._ready()
	set_process(true)
	_interaction = InteractionController.new()
	_node_renderer = NodeRenderer.new()
	_wire_renderer = WireRenderer.new()
	_port_resolver = PortResolver.new()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		_interaction.update_pointer(st.position)
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_interaction.update_pointer(sd.position)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# V2 wire-pick: Ctrl+LMB selects nearest connection even when crowded by nodes.
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.ctrl_pressed:
			var conn := _connection_at_screen(mb.position)
			if not conn.is_empty():
				_select_connection(conn.get("id", "") as String)
				accept_event()
				return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_interaction.update_pointer(mm.position)
		var hovered := _item_at_screen(mm.position)
		_interaction.hover_item_id = hovered.get("id", "") as String
		_hover_port = _port_at_screen(mm.position, "", "", _port_grab_radius())
	super._gui_input(event)


func _draw() -> void:
	super._draw()
	_draw_v2_badges()
	_draw_v2_legend()
	_draw_v2_education_panel()
	_draw_v2_connection_feedback()
	_draw_v2_hover_port_tooltip()


func _process(delta: float) -> void:
	# Smoothly hint to users this is a testing/education-focused V2 canvas.
	_hint_alpha = lerpf(_hint_alpha, 0.95 if current_mode == "test" else 0.55, clampf(delta * 6.0, 0.0, 1.0))


func _draw_v2_badges() -> void:
	pass  # Limit badges (3500W cap, SOC thresholds) live in inspector only.


func _draw_v2_legend() -> void:
	if not _legend_visible:
		return
	var entries: Array[Dictionary] = [
		{"label": "DC positive  (red)",   "color": PORT_COLORS.get("positive", Color(0.85, 0.33, 0.33, 1.0))},
		{"label": "DC negative  (grey)",  "color": PORT_COLORS.get("negative", Color(0.48, 0.48, 0.48, 1.0))},
		{"label": "AC output  (amber)",   "color": PORT_COLORS.get("ac", Color(0.94, 0.68, 0.30, 1.0))},
		{"label": "PV string  (gold)",    "color": PORT_COLORS.get("pv", Color(0.96, 0.62, 0.04, 1.0))},
		{"label": "Water",                "color": ResourceKinds.wire_color("water")},
		{"label": "Biomass",              "color": ResourceKinds.wire_color("biomass")},
		{"label": "Plastic / shred",      "color": ResourceKinds.wire_color("plastic_shred")},
		{"label": "Flow animation  (cyan)","color": Color(0.13, 0.83, 0.93, 1.0)},
	]
	# Anchor legend to bottom-right of canvas
	var legend_w := 238.0
	var legend_h := 20.0 + entries.size() * 20.0 + 8.0
	var origin   := Vector2(size.x - legend_w - 14.0, size.y - legend_h - 14.0)
	_wire_renderer.draw_legend(self, origin, entries)


func _draw_v2_education_panel() -> void:
	if model == null:
		return
	var bat_msg := ""
	var inv_msg := ""
	var hover_msg := ""
	var dump_msg := ""
	var automation_msg := ""
	var total_load_w := 0.0
	var solar_kw := 0.0
	if model != null:
		var tree := get_tree()
		if tree != null:
			total_load_w = GraphAcLoad.compute_watts(model, tree)
	for item: Dictionary in _visible_items():
		var itype := item.get("type", "") as String
		var iid   := item.get("id",   "") as String
		var specs := item.get("specs", {}) as Dictionary
		if itype == "panel":
			solar_kw = float(specs.get("current_output_kw", solar_kw))
		if itype == "appliance" or itype == "acload" or itype == "processor":
			var autos := specs.get("graph_automations", []) as Array
			if automation_msg.is_empty() and not autos.is_empty():
				automation_msg = "%d automation rule(s) on graph loads" % autos.size()
			if dump_msg.is_empty() and not autos.is_empty():
				for a in autos:
					var ad := a as Dictionary
					var trigs := ad.get("triggers", []) as Array
					for t in trigs:
						var td := t as Dictionary
						if str(td.get("kind", "")) == "numeric" and str(td.get("entity_id", "")) == "sensor.battery_level":
							if (td.has("above") and float(td.get("above", 0.0)) >= 99.0) or \
							   (td.has("below") and float(td.get("below", 100.0)) <= 95.0):
								dump_msg = "⚡ Dump load detected  (ON >99%% / OFF <95%%)"
								break
					if not dump_msg.is_empty():
						break
		if bat_msg.is_empty() and (itype == "battery" or itype == "smartbattery") and (specs.has("soc_shutdown_pct") or specs.has("soc_resume_pct")):
			bat_msg = _port_resolver.format_soc_protection(specs)
		if inv_msg.is_empty() and itype == "controller" and (specs.has("overload_watts") or specs.has("overload_duration_s")):
			inv_msg = _port_resolver.format_overload_protection(specs)
		if hover_msg.is_empty() and iid == _interaction.hover_item_id:
			var name_ := str(specs.get("name", itype))
			if itype == "appliance" or itype == "acload":
				hover_msg = "%s  ·  %.0f W" % [name_, float(specs.get("avg_watts", 0.0))]
			elif itype == "battery" or itype == "smartbattery":
				hover_msg = "%s  ·  %s" % [name_, _port_resolver.format_soc_protection(specs)]
			elif itype == "controller":
				hover_msg = "%s  ·  %s" % [name_, _port_resolver.format_overload_protection(specs)]
		if not bat_msg.is_empty() and not inv_msg.is_empty():
			break

	# Always draw the live power HUD in test mode
	var has_power_data := solar_kw > 0.0 or total_load_w > 0.0
	var has_info := not (bat_msg.is_empty() and inv_msg.is_empty() and hover_msg.is_empty() and dump_msg.is_empty() and automation_msg.is_empty())
	if not has_power_data and not has_info:
		return

	var fnt  := ThemeDB.fallback_font
	var a    := _hint_alpha
	var px   := 14.0
	var py   := 14.0

	# --- Live power ticker (top strip, always shown when data exists) ---
	if has_power_data:
		var solar_w := solar_kw * 1000.0
		var net_w   := solar_w - total_load_w
		var ticker_w := 520.0
		var ticker_h := 44.0
		var trect := Rect2(Vector2(px, py), Vector2(ticker_w, ticker_h))
		_draw_hud_panel(trect, a)

		# Title strip
		var title_r := Rect2(trect.position, Vector2(trect.size.x, 16.0))
		draw_rect(title_r, Color(0.13, 0.83, 0.93, 0.13 * a), true)
		draw_string(fnt, trect.position + Vector2(10.0, 12.0), "LIVE POWER FLOW", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.13, 0.83, 0.93, 0.72 * a))

		# Three value columns
		var cols: Array[Dictionary] = [
			{"label": "SOLAR",    "value": "%.0f W" % solar_w,     "col": Color(0.27, 0.90, 0.42, a)},
			{"label": "LOAD",     "value": "%.0f W" % total_load_w, "col": Color(0.94, 0.68, 0.30, a)},
			{"label": "NET",      "value": "%+.0f W" % net_w,       "col": Color(0.27, 0.90, 0.42, a) if net_w >= 0.0 else Color(0.95, 0.45, 0.35, a)},
		]
		var col_w := ticker_w / float(cols.size())
		for ci in cols.size():
			var col_x := trect.position.x + float(ci) * col_w + 10.0
			var lbl_y := trect.position.y + 29.0
			var val_y := trect.position.y + 42.0
			draw_string(fnt, Vector2(col_x, lbl_y), cols[ci].label as String, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.58, 0.64, 0.72, 0.80 * a))
			draw_string(fnt, Vector2(col_x, val_y), cols[ci].value as String, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, cols[ci].col as Color)

		py += ticker_h + 6.0

	# --- Info rows (battery/inverter/hover/dump/automation) ---
	if has_info:
		var rows: Array[Dictionary] = []
		if not bat_msg.is_empty():
			rows.append({"text": bat_msg,        "col": Color(0.27, 0.92, 0.55, a)})
		if not inv_msg.is_empty():
			rows.append({"text": inv_msg,        "col": Color(0.96, 0.78, 0.38, a)})
		if not hover_msg.is_empty():
			rows.append({"text": hover_msg,      "col": Color(0.75, 0.87, 1.00, a)})
		if not dump_msg.is_empty():
			rows.append({"text": dump_msg,       "col": Color(0.98, 0.87, 0.45, a)})
		if not automation_msg.is_empty():
			rows.append({"text": automation_msg, "col": Color(0.60, 0.87, 1.00, a)})

		var row_h := 20.0
		var info_w := 520.0
		var info_h := 14.0 + float(rows.size()) * row_h + 4.0
		var irect  := Rect2(Vector2(px, py), Vector2(info_w, info_h))
		_draw_hud_panel(irect, a)
		for ri in rows.size():
			var ry := irect.position.y + 14.0 + float(ri) * row_h
			draw_string(fnt, Vector2(irect.position.x + 10.0, ry), rows[ri].text as String, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, rows[ri].col as Color)


func _draw_hud_panel(rect: Rect2, alpha: float) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.08, 0.17, 0.88 * alpha)
	sb.set_corner_radius_all(8)
	sb.set_border_width_all(1)
	sb.border_color = Color(0.22, 0.30, 0.44, 0.75 * alpha)
	draw_style_box(sb, rect)


func _draw_v2_connection_feedback() -> void:
	if not _wire_dragging:
		return
	var fnt := ThemeDB.fallback_font
	var fs := 11
	var txt := ""
	var col := Color(0.75, 0.84, 0.95, 0.95)
	if not _wire_snap.is_empty():
		var item_id := _wire_snap.get("item_id", "") as String
		var handle_id := _wire_snap.get("handle_id", "") as String
		if _wire_snap_valid:
			txt = "Release to connect: %s.%s" % [item_id, handle_id]
			col = Color(0.33, 0.92, 0.55, 0.95)
		else:
			txt = "Invalid connection: polarity mismatch on %s.%s" % [item_id, handle_id]
			col = Color(0.95, 0.45, 0.45, 0.95)
	else:
		txt = "Drag to a compatible port to connect wires"
	var p := _interaction.last_pointer_pos + Vector2(14.0, -10.0)
	draw_string(fnt, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	draw_string(fnt, p + Vector2(0.0, 14.0), "Touch: drag ports/nodes · 2-finger pan · pinch zoom · double-tap toggles loads", HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(0.75, 0.83, 0.95, 0.82))


func _draw_v2_hover_port_tooltip() -> void:
	if _hover_port.is_empty():
		return
	var fnt := ThemeDB.fallback_font
	var fs := 10
	var item_id := _hover_port.get("item_id", "") as String
	var handle_id := _hover_port.get("handle_id", "") as String
	var pol := _hover_port.get("polarity", "") as String
	var rk := str(_hover_port.get("resource_kind", ""))
	if item_id.is_empty() or handle_id.is_empty():
		return
	var txt := "%s.%s [%s" % [item_id, handle_id, pol]
	if not rk.is_empty():
		txt += " · %s" % ResourceKinds.display_name(rk)
	txt += "]"
	var p := _interaction.last_pointer_pos + Vector2(12.0, 16.0)
	var ts := fnt.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var rect := Rect2(p - Vector2(5.0, 11.0), Vector2(ts.x + 10.0, 16.0))
	draw_rect(rect, Color(0.05, 0.08, 0.16, 0.9), true)
	draw_rect(rect, Color(0.26, 0.34, 0.50, 0.85), false, 1.0)
	draw_string(fnt, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.86, 0.91, 0.98, 0.97))


func _render_item(item: Dictionary) -> void:
	var iid := item.get("id", "") as String
	# Hide legacy aggregate panel card in V2; individual virtual panel nodes replace it.
	if iid == "virtual_solar_array":
		return
	if item.get("type", "") == "panel":
		_render_panel_item_v2(item)
		return
	if item.get("type", "") == "compound":
		var csp: Dictionary = item.get("specs", {}) as Dictionary
		if str(csp.get("compound_kind", "")) == "load_group":
			_render_load_group_item_v2(item)
			return
		_render_compound_item_v2(item)
		return
	var itype := str(item.get("type", ""))
	if itype == "battery" or itype == "smartbattery":
		_render_battery_item_v2(item)
		return
	if itype == "resource":
		_render_resource_item_v2(item)
		return
	super._render_item(item)


func _render_resource_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs := (item.get("specs", {}) as Dictionary).duplicate(true)
	ResourceKinds.new().migrate_resource_specs(specs)
	var kind: String = str(specs.get("resource_kind", "water"))
	var accent := ResourceKinds.wire_color(kind)
	if bool(item.get("is_ghost", false)):
		accent = Color(accent.r, accent.g, accent.b, 0.42)
	var border_col := accent if is_sel else Color(accent.r * 0.75, accent.g * 0.75, accent.b * 0.75, accent.a)
	var level := clampf(float(specs.get("level", 0.5)), 0.0, 1.0)

	_draw_rounded_rect(Rect2(rect.position + Vector2(2.0, 3.0), rect.size), V2_NODE_SHADOW, 12)
	_draw_rounded_rect(rect, Color(0.05, 0.08, 0.14, 0.97), 12, Color(border_col.r, border_col.g, border_col.b, 0.75), 1.2)
	var inner := rect.grow(-4.0)
	_draw_rounded_rect(inner, Color(0.04, 0.07, 0.12, 0.98), 10, Color(border_col.r, border_col.g, border_col.b, 0.25), 1)
	var fill_h := maxf(2.0, inner.size.y * level)
	var fill_rect := Rect2(Vector2(inner.position.x, inner.position.y + inner.size.y - fill_h), Vector2(inner.size.x, fill_h))
	_draw_rounded_rect(fill_rect, Color(accent.r, accent.g, accent.b, 0.88 if not bool(item.get("is_ghost", false)) else 0.35), 9)

	var fnt := ThemeDB.fallback_font
	var fsize := maxi(10, int(round(12.0 * sqrt(_zoom))))
	draw_string(fnt, inner.position + Vector2(4.0, fsize + 2.0),
		str(specs.get("name", ResourceKinds.display_name(kind))),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, C_TEXT_S)
	var pct := "%d%%" % int(round(level * 100.0))
	var ts := fnt.get_string_size(pct, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 4)
	draw_string(fnt, inner.position + Vector2((inner.size.x - ts.x) * 0.5, inner.size.y * 0.5),
		pct, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize + 4, Color(1, 1, 1, 0.92))

	_draw_item_handles(item, tl, sz)
	if is_sel:
		_draw_rounded_rect(rect.grow(1.0), Color(accent.r, accent.g, accent.b, 0.18), 13)


func _render_battery_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs := item.get("specs", {}) as Dictionary
	var soc := clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)

	var accent := Color(0.27, 0.90, 0.55, 1.0)
	var border_col := accent if is_sel else Color(accent.r * 0.82, accent.g * 0.82, accent.b * 0.82, 1.0)

	# Shadow + full-body rounded shell.
	_draw_rounded_rect(Rect2(rect.position + Vector2(2.0, 3.0), rect.size), V2_NODE_SHADOW, 14)
	_draw_rounded_rect(rect, Color(0.05, 0.10, 0.09, 0.97), 14, Color(border_col.r * 0.55, border_col.g * 0.55, border_col.b * 0.55, 0.85), 1)

	# Full-node SOC fill rising from bottom.
	var inner := rect.grow(-3.0)
	_draw_rounded_rect(inner, Color(0.04, 0.08, 0.07, 0.98), 12, Color(border_col.r, border_col.g, border_col.b, 0.35), 1)
	var fill_h := maxf(2.0, inner.size.y * soc)
	var fill_col := Color(0.25, 0.92, 0.56, 0.95) if soc > 0.28 else Color(0.95, 0.63, 0.22, 0.95)
	var fill_rect := Rect2(Vector2(inner.position.x, inner.position.y + inner.size.y - fill_h), Vector2(inner.size.x, fill_h))
	_draw_rounded_rect(fill_rect, fill_col, 11)
	if fill_h > 4.0:
		var sheen_h := minf(3.0, maxf(1.0, fill_h * 0.08))
		draw_rect(Rect2(fill_rect.position, Vector2(fill_rect.size.x, sheen_h)), Color(0.88, 1.0, 0.92, 0.32), true)

	# Centered SOC percentage — scales with node size, never overflows the body.
	var fnt := ThemeDB.fallback_font
	var fsize := clampi(int(round(minf(rect.size.y * 0.38, rect.size.x * 0.32))), 12, 26)
	var label := "%d%%" % int(round(soc * 100.0))
	var ts := fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
	var tp := rect.position + Vector2((rect.size.x - ts.x) * 0.5, (rect.size.y + ts.y * 0.4) * 0.5)
	for ox in [-1.0, 1.0, 0.0]:
		for oy in [-1.0, 1.0, 0.0]:
			if ox == 0.0 and oy == 0.0:
				continue
			draw_string(fnt, tp + Vector2(ox, oy), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.02, 0.06, 0.04, 0.85))
	draw_string(fnt, tp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.98, 1.0, 0.95, 1.0))

	# Handles
	_draw_item_handles(item, tl, sz)

	if is_sel:
		_draw_rounded_rect(rect.grow(1.5), Color(0.27, 0.92, 0.56, 0.15), 15)
		_draw_rounded_rect(rect.grow(1.0), Color(0, 0, 0, 0), 14, Color(0.27, 0.92, 0.56, 0.9), 1)


func _render_panel_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs := item.get("specs", {}) as Dictionary

	# Outer module frame
	draw_rect(rect.grow(1.5), Color(0.01, 0.02, 0.05, 0.74), true)
	draw_rect(rect, Color(0.03, 0.06, 0.12, 0.96), true)
	draw_rect(rect, Color(0.20, 0.67, 0.90, 0.72), false, 1.2)
	draw_rect(rect.grow(-3.0), Color(0.06, 0.13, 0.24, 0.96), true)

	# Cell grid (panel face)
	var face := rect.grow(-6.0)
	face.size.y -= 28.0
	draw_rect(face, Color(0.05, 0.18, 0.33, 0.95), true)
	var cols := 4
	var rows := 8
	for c in range(1, cols):
		var x := face.position.x + face.size.x * (float(c) / float(cols))
		draw_line(Vector2(x, face.position.y), Vector2(x, face.position.y + face.size.y), Color(0.56, 0.79, 0.95, 0.28), 1.0)
	for r in range(1, rows):
		var y := face.position.y + face.size.y * (float(r) / float(rows))
		draw_line(Vector2(face.position.x, y), Vector2(face.position.x + face.size.x, y), Color(0.56, 0.79, 0.95, 0.24), 1.0)
	# Glass sheen
	var sheen := Rect2(face.position + Vector2(0.0, 2.0), Vector2(face.size.x, maxf(4.0, face.size.y * 0.14)))
	draw_rect(sheen, Color(0.74, 0.89, 1.0, 0.10), true)

	# Bottom telemetry strip
	var strip := Rect2(Vector2(rect.position.x + 3.0, rect.position.y + rect.size.y - 22.0), Vector2(rect.size.x - 6.0, 18.0))
	draw_rect(strip, Color(0.01, 0.03, 0.07, 0.82), true)
	draw_rect(strip, Color(0.33, 0.72, 0.94, 0.38), false, 1.0)

	var fnt := ThemeDB.fallback_font
	var fs_name := maxi(9, int(round(10.0 * sqrt(_zoom))))
	var fs_stats := maxi(8, int(round(9.0 * sqrt(_zoom))))
	var label := str(specs.get("name", "PV"))
	var watts := float(specs.get("wmp", 0.0))
	draw_string(fnt, rect.position + Vector2(6.0, 13.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_name, Color(0.90, 0.96, 1.0, 0.95))
	var grp := int(specs.get("array_group", 0))
	var str_idx := int(specs.get("array_string", 0))
	var ser := int(specs.get("array_series_pos", 0))
	if grp > 0 and str_idx > 0 and ser > 0:
		draw_string(fnt, rect.position + Vector2(6.0, 24.0), "G%d S%d P%d" % [grp, str_idx, ser], HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats, Color(0.73, 0.90, 1.0, 0.86))
	draw_string(fnt, strip.position + Vector2(4.0, 12.5), "%.0fW" % watts, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats, Color(0.78, 0.92, 1.0, 0.96))

	_draw_item_handles(item, tl, sz)
	if is_sel:
		draw_rect(rect.grow(1.5), Color(0.13, 0.83, 0.93, 0.16), true)
		draw_rect(rect.grow(1.0), Color(0.13, 0.83, 0.93, 0.85), false, 1.4)


func _render_load_group_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs := item.get("specs", {}) as Dictionary
	var accent := Color(0.94, 0.68, 0.30, 1.0)
	var child_count := int(specs.get("child_count", 0))
	var live_w := float(specs.get("avg_watts", 0.0))
	if model != null:
		var tree := get_tree()
		if tree != null:
			live_w = GraphAcLoad.sum_load_group_watts(model, item, tree, null)

	_draw_rounded_rect(Rect2(rect.position + Vector2(2.0, 3.0), rect.size), V2_NODE_SHADOW, 12)
	_draw_rounded_rect(rect, Color(0.10, 0.08, 0.06, 0.97), 12, Color(accent.r, accent.g, accent.b, 0.85 if is_sel else 0.55), 1.4)

	# Stacked-card cue (group of loads).
	for layer: int in range(2):
		var inset := float(layer + 1) * 3.0
		var card := rect.grow(-inset - 2.0)
		draw_rect(Rect2(card.position + Vector2(0.0, -inset), card.size),
			Color(accent.r, accent.g, accent.b, 0.10 - float(layer) * 0.03), true)

	var fnt := ThemeDB.fallback_font
	var fs_name := maxi(10, int(round(11.0 * sqrt(_zoom))))
	var fs_stats := maxi(9, int(round(10.0 * sqrt(_zoom))))
	var title := str(specs.get("name", "Load Group"))
	draw_string(fnt, rect.position + Vector2(8.0, 14.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_name, Color(0.96, 0.92, 0.86, 0.96))
	draw_string(fnt, rect.position + Vector2(8.0, 26.0), "⧉ %d loads grouped" % child_count,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats, Color(0.78, 0.72, 0.62, 0.88))

	var strip := Rect2(Vector2(rect.position.x + 4.0, rect.end.y - 22.0), Vector2(rect.size.x - 8.0, 18.0))
	draw_rect(strip, Color(0.04, 0.03, 0.02, 0.82), true)
	draw_rect(strip, Color(accent.r, accent.g, accent.b, 0.35), false, 1.0)
	draw_string(fnt, strip.position + Vector2(4.0, 12.5), "%.0f W total" % live_w,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats, Color(0.98, 0.86, 0.58, 0.96))

	_draw_item_handles(item, tl, sz)
	if is_sel:
		_draw_rounded_rect(rect.grow(1.0), Color(accent.r, accent.g, accent.b, 0.18), 13)


func _render_compound_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs := item.get("specs", {}) as Dictionary
	var kind := str(specs.get("compound_kind", ""))
	var accent := Color(0.56, 0.48, 0.90, 1.0)
	var title := str(specs.get("name", "Compound"))
	if kind == "array":
		accent = Color(0.15, 0.76, 0.95, 1.0)
		title = "Solar Array"
	elif kind == "battery_bank":
		accent = Color(0.17, 0.84, 0.52, 1.0)
		title = "Battery Bank"

	_draw_node_frame(rect, accent if is_sel else Color(accent.r * 0.85, accent.g * 0.85, accent.b * 0.85, 1.0))
	var title_h := maxf(24.0, sz.y * 0.27)
	_draw_title_band(rect, title_h, title, accent)
	var body := Rect2(tl + Vector2(0.0, title_h), sz - Vector2(0.0, title_h))

	if kind == "array":
		_draw_array_compound_body_v2(body, specs)
	elif kind == "battery_bank":
		_draw_battery_bank_compound_body_v2(body, specs)
	else:
		_draw_compound_body(body, specs)

	_draw_item_handles(item, tl, sz)
	if is_sel:
		draw_rect(rect.grow(1.2), Color(0.13, 0.83, 0.93, 0.16), true)
		draw_rect(rect.grow(0.8), Color(0.13, 0.83, 0.93, 0.85), false, 1.2)


func _draw_array_compound_body_v2(rect: Rect2, specs: Dictionary) -> void:
	var panel_count := maxi(2, int(specs.get("array_panel_units", specs.get("child_count", 6))))
	var s_count := maxi(1, int(specs.get("array_series", 1)))
	var p_count := maxi(1, int(specs.get("array_parallel", 1)))
	var topo := str(specs.get("array_topology", "%dS%dP" % [s_count, p_count]))
	var body := rect.grow(-6.0)
	var stack_h := maxf(34.0, body.size.y - 28.0)
	var stack := Rect2(body.position + Vector2(0.0, 2.0), Vector2(body.size.x, stack_h))
	var deck_count := mini(4, maxi(2, p_count))
	var deck_gap := 3.0
	var deck_size := Vector2(stack.size.x - 12.0, maxf(9.0, (stack.size.y - float(deck_count - 1) * deck_gap) / float(deck_count)))
	for d in range(deck_count - 1, -1, -1):
		var dd := float(deck_count - 1 - d)
		var dx := 6.0 + dd * 2.2
		var dy := dd * 2.4
		var deck := Rect2(stack.position + Vector2(dx, dy), deck_size)
		_draw_rounded_rect(deck, Color(0.05, 0.16, 0.30, 0.95), 5, Color(0.52, 0.80, 0.97, 0.35), 1)
		var cols := mini(5, maxi(2, s_count))
		for c in range(1, cols):
			var x := deck.position.x + deck.size.x * (float(c) / float(cols))
			draw_line(Vector2(x, deck.position.y + 1.0), Vector2(x, deck.position.y + deck.size.y - 1.0), Color(0.72, 0.90, 1.0, 0.24), 1.0)
		var rows := 2
		for r in range(1, rows):
			var y := deck.position.y + deck.size.y * (float(r) / float(rows))
			draw_line(Vector2(deck.position.x + 1.0, y), Vector2(deck.position.x + deck.size.x - 1.0, y), Color(0.72, 0.90, 1.0, 0.18), 1.0)
		var sheen := Rect2(deck.position + Vector2(0.0, 1.0), Vector2(deck.size.x, maxf(2.0, deck.size.y * 0.16)))
		_draw_rounded_rect(sheen, Color(0.72, 0.92, 1.0, 0.12), 3)

	# Small combiner rail and bus stubs to reinforce "condensed array" feel.
	var rail_y := stack.end.y - 3.0
	draw_line(Vector2(stack.position.x + 10.0, rail_y), Vector2(stack.end.x - 28.0, rail_y), Color(0.42, 0.90, 0.98, 0.58), 2.0)
	draw_line(Vector2(stack.end.x - 26.0, rail_y), Vector2(stack.end.x - 14.0, rail_y), Color(0.33, 0.78, 0.92, 0.85), 3.0)
	draw_circle(Vector2(stack.end.x - 12.0, rail_y), 2.2, Color(0.60, 0.95, 1.0, 0.90))

	var fnt := ThemeDB.fallback_font
	var meta_col := Color(0.82, 0.94, 1.0, 0.92)
	var sub_col := Color(0.74, 0.86, 0.98, 0.90)
	draw_string(fnt, rect.position + Vector2(8.0, rect.size.y - 16.0), "Topology: %s  (%d panels)" % [topo, panel_count], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, meta_col)
	draw_string(fnt, rect.position + Vector2(8.0, rect.size.y - 4.0), "Condensed stack view · Enter to expand", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, sub_col)


func _draw_battery_bank_compound_body_v2(rect: Rect2, specs: Dictionary) -> void:
	var count := maxi(2, int(specs.get("child_count", 4)))
	var cols := mini(4, count)
	var rows := maxi(1, int(ceil(float(count) / float(cols))))
	var gap := 6.0
	var bw := (rect.size.x - 16.0 - gap * float(cols - 1)) / float(cols)
	var bh := minf(34.0, (rect.size.y - 20.0 - gap * float(rows - 1)) / float(rows))
	var start := rect.position + Vector2(8.0, 6.0)
	var idx := 0
	for r in range(rows):
		for c in range(cols):
			if idx >= count:
				break
			var p := start + Vector2(float(c) * (bw + gap), float(r) * (bh + gap))
			var brect := Rect2(p, Vector2(bw, bh))
			draw_rect(brect, Color(0.06, 0.22, 0.13, 0.95), true)
			draw_rect(brect, Color(0.41, 0.90, 0.63, 0.45), false, 1.0)
			# Per-cell visualization inside each battery module
			var cell_gap := 2.0
			var cw := (brect.size.x - 8.0 - 3.0 * cell_gap) / 4.0
			for i in range(4):
				var cp := brect.position + Vector2(4.0 + float(i) * (cw + cell_gap), 6.0)
				var crect := Rect2(cp, Vector2(cw, brect.size.y - 12.0))
				draw_rect(crect, Color(0.11, 0.33, 0.21, 0.95), true)
				draw_rect(crect, Color(0.56, 0.95, 0.73, 0.24), false, 1.0)
				var fill := clampf(0.45 + 0.45 * sin(float(idx * 2 + i) * 0.6 + _flow_phase), 0.10, 0.95)
				var fh := (crect.size.y - 2.0) * fill
				draw_rect(Rect2(Vector2(crect.position.x + 1.0, crect.position.y + crect.size.y - 1.0 - fh), Vector2(crect.size.x - 2.0, fh)), Color(0.41, 0.90, 0.63, 0.76), true)
			idx += 1
	var count_total := maxi(2, int(specs.get("child_count", 4)))
	var p_guess := maxi(1, int(round(sqrt(float(count_total)))))
	var s_guess := maxi(1, int(ceil(float(count_total) / float(p_guess))))
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, rect.size.y - 16.0), "Topology: %dS x %dP (estimated)" % [s_guess, p_guess], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.84, 0.98, 0.90, 0.92))
	draw_string(ThemeDB.fallback_font, rect.position + Vector2(8.0, rect.size.y - 4.0), "Per-cell bank preview · Enter to expand", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.78, 0.98, 0.86, 0.9))


func _draw_battery_body(rect: Rect2, specs: Dictionary) -> void:
	var fnt := ThemeDB.fallback_font
	var fsize := _fit_font_size(rect, 3, 10.0, 12.0)
	var soc := clampf(float(specs.get("soc", 0.5)), 0.0, 1.0)
	var x := rect.position.x + 8.0
	var y := rect.position.y + fsize + 4.0
	var kwh := float(specs.get("kwh", 0.0))
	draw_string(fnt, Vector2(x, y), "%.0f%%  %.1fkWh" % [soc * 100.0, kwh], HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.94, 0.99, 0.95, 1.0))
	y += fsize + 4.0

	# Battery silhouette: rounded can + top terminal cap.
	var body := Rect2(Vector2(x, y), Vector2(rect.size.x - 16.0, rect.size.y - (y - rect.position.y) - 6.0))
	_draw_rounded_rect(body, Color(0.07, 0.15, 0.12, 0.97), 9, Color(0.35, 0.90, 0.62, 0.52), 1)
	var cap_w := maxf(14.0, body.size.x * 0.22)
	var cap_h := 4.0
	var cap := Rect2(Vector2(body.position.x + (body.size.x - cap_w) * 0.5, body.position.y - cap_h - 1.0), Vector2(cap_w, cap_h))
	_draw_rounded_rect(cap, Color(0.18, 0.27, 0.22, 0.96), 2, Color(0.52, 0.95, 0.72, 0.35), 1)

	# Full-body reservoir: charge fills entire battery interior from bottom.
	var reservoir := Rect2(body.position + Vector2(3.0, 3.0), body.size - Vector2(6.0, 6.0))
	_draw_rounded_rect(reservoir, Color(0.04, 0.08, 0.07, 0.98), 6, Color(0.26, 0.40, 0.33, 0.8), 1)
	var fill_h := maxf(2.0, (reservoir.size.y - 2.0) * soc)
	var fill_col := Color(0.25, 0.92, 0.56, 0.96) if soc > 0.28 else Color(0.95, 0.63, 0.22, 0.95)
	var reservoir_fill := Rect2(
		Vector2(reservoir.position.x + 1.0, reservoir.position.y + reservoir.size.y - 1.0 - fill_h),
		Vector2(reservoir.size.x - 2.0, fill_h)
	)
	_draw_rounded_rect(reservoir_fill, fill_col, 5)
	draw_rect(Rect2(Vector2(reservoir_fill.position.x, reservoir_fill.position.y), Vector2(reservoir_fill.size.x, minf(2.0, reservoir_fill.size.y))), Color(0.88, 1.0, 0.92, 0.32), true)

	# Overlay text + optional per-cell bars float above the reservoir fill.
	var info_x := reservoir.position.x + 7.0
	var info_y := body.position.y + fsize
	draw_string(fnt, Vector2(info_x, info_y), "%.0fV  %.0fAh" % [float(specs.get("voltage", 12.0)), float(specs.get("ah", 0.0))], HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 1), Color(0.80, 0.95, 0.87, 0.96))
	info_y += maxi(9, fsize - 1) + 3.0
	draw_string(fnt, Vector2(info_x, info_y), "Charge %.0f%%" % (soc * 100.0), HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 1), Color(0.66, 0.93, 0.77, 0.95))
	info_y += maxi(8, fsize - 2) + 5.0

	var cell_view_mode := bool(specs.get("cell_view_mode", false))
	var cell_gap := 2.0
	var cell_cols := 8 if cell_view_mode else 4
	var cell_area_w := maxf(22.0, reservoir.size.x - 14.0)
	var cw := (cell_area_w - float(cell_cols - 1) * cell_gap) / float(cell_cols)
	for i in range(cell_cols):
		var cp := Vector2(info_x + float(i) * (cw + cell_gap), info_y)
		var ch := maxf(9.0, reservoir.end.y - cp.y - 4.0)
		var crect := Rect2(cp, Vector2(cw, ch))
		_draw_rounded_rect(crect, Color(0.08, 0.21, 0.15, 0.52), 2, Color(0.46, 0.92, 0.69, 0.26), 1)
		var phase := _flow_phase + float(i) * 0.55
		var fill := clampf(soc + 0.07 * sin(phase), 0.06, 0.98)
		var fh := (crect.size.y - 2.0) * fill
		var cfill := Rect2(Vector2(crect.position.x + 1.0, crect.position.y + crect.size.y - 1.0 - fh), Vector2(crect.size.x - 2.0, fh))
		_draw_rounded_rect(cfill, Color(0.39, 0.90, 0.62, 0.78), 2)
	if cell_view_mode:
		draw_string(fnt, Vector2(info_x, rect.position.y + rect.size.y - 2.0), "Cell detail mode", HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(8, fsize - 2), Color(0.76, 0.96, 0.85, 0.92))


func _draw_node_frame(rect: Rect2, border_col: Color) -> void:
	# More sculpted rounded containers in V2.
	_draw_rounded_rect(Rect2(rect.position + Vector2(2.0, 3.0), rect.size), V2_NODE_SHADOW, 12)
	_draw_rounded_rect(rect, Color(0.07, 0.10, 0.19, 0.96), 12, Color(border_col.r * 0.55, border_col.g * 0.55, border_col.b * 0.55, 0.75), 1)
	_draw_rounded_rect(rect.grow(-1.5), Color(0, 0, 0, 0), 10, Color(border_col.r, border_col.g, border_col.b, 0.42), 1)


func _draw_title_band(rect: Rect2, band_h: float, title: String, accent: Color) -> void:
	var band := Rect2(rect.position, Vector2(rect.size.x, band_h))
	_draw_rounded_rect(band, Color(accent.r, accent.g, accent.b, 0.22), 11)
	_draw_rounded_rect(Rect2(band.position, Vector2(band.size.x, 2.0)), Color(V2_TITLE_GLOW.r, V2_TITLE_GLOW.g, V2_TITLE_GLOW.b, 0.72), 2)
	var fnt := ThemeDB.fallback_font
	var fsize := _fit_title_font_size(band_h)
	var cy := rect.position.y + band_h * 0.5 + fsize * 0.38
	draw_string(fnt, Vector2(rect.position.x + 10.0, cy), title, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.93, 0.95, 0.99, 1.0))


func _draw_rounded_rect(rect: Rect2, fill: Color, radius: int, border_col: Color = Color(0, 0, 0, 0), border_w: int = 0) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(radius)
	if border_w > 0 and border_col.a > 0.0:
		sb.set_border_width_all(border_w)
		sb.border_color = border_col
	draw_style_box(sb, rect)


func _draw_port_dot(screen_pos: Vector2, polarity: String, resource_kind: String = "") -> void:
	var col := _wire_color_for_port(polarity, resource_kind)
	var touch := _touch_input_active() or DisplayServer.is_touchscreen_available()
	var hover_hit := false
	if not _hover_port.is_empty():
		var hp := _hover_port.get("pos", Vector2(-9999.0, -9999.0)) as Vector2
		hover_hit = hp.distance_to(screen_pos) < maxf(8.0, 9.0 * _zoom)
	var pulse := 1.0 + (0.13 * sin(_flow_phase * 3.4)) if current_mode == "test" else 1.0
	var r := maxf(5.5, 6.8 * _zoom) * pulse
	if touch:
		r = maxf(r, 10.5)
	if hover_hit:
		r *= 1.18
	draw_circle(screen_pos, r + (6.0 if touch else 4.0), Color(col.r, col.g, col.b, 0.18))
	draw_circle(screen_pos, r + 1.8, Color(col.r, col.g, col.b, 0.34))
	draw_circle(screen_pos, r, col)
	draw_circle(screen_pos, r * 0.56, Color(0.06, 0.09, 0.17, 0.95))
	draw_circle(screen_pos, r + 0.4, V2_PORT_RING, false, 1.0)
	if touch:
		draw_circle(screen_pos, r + 8.0, Color(col.r, col.g, col.b, 0.10), false, 2.0)


func _draw_wire_bezier(from: Vector2, from_tang: Vector2,
		to: Vector2, to_tang_in: Vector2,
		col: Color, width: float, flow_active: bool,
		flow_watts: float, reverse_chase: bool, curve_tension: float = 1.0) -> void:
	var ctrl := _wire_bezier_controls(from, from_tang, to, to_tang_in, curve_tension)
	var c1: Vector2 = ctrl["c1"]
	var c2: Vector2 = ctrl["c2"]
	var gscale := _wire_glow_scale_from_watts(flow_watts)
	var body_w := maxf(2.2, width + 0.6 + gscale * 1.3)

	# Base depth stroke
	_draw_bezier_stroke(from, c1, c2, to, 30, Color(0.01, 0.01, 0.03, 0.32), body_w + 2.4)
	# Colored glow
	var glow_alpha := (0.12 + 0.20 * gscale) if flow_active else 0.08
	_draw_bezier_stroke(from, c1, c2, to, 30, Color(col.r, col.g, col.b, glow_alpha), body_w + 3.0 + 3.2 * gscale)
	# Main stroke
	var core := Color(lerpf(col.r, 1.0, 0.20 * gscale), lerpf(col.g, 1.0, 0.18 * gscale), lerpf(col.b, 1.0, 0.12 * gscale), 0.72 + 0.26 * gscale)
	_draw_bezier_stroke(from, c1, c2, to, 34, core, body_w)
	# Hot inner line
	_draw_bezier_stroke(from, c1, c2, to, 34, Color(1.0, 1.0, 1.0, 0.18 + 0.28 * gscale), maxf(1.0, body_w * 0.24))

	if flow_active:
		# Number of arrows scales with power (1–6) so high-wattage wires feel more alive
		var gscale_v2 := _wire_glow_scale_from_watts(flow_watts)
		var arrow_count := 3 + int(gscale_v2 * 3.0)
		var arrow_gap   := maxf(0.12, 0.22 - gscale_v2 * 0.07)
		var arrow_t     := fposmod(_flow_phase * 0.27, 1.0)
		if reverse_chase:
			arrow_t = 1.0 - arrow_t
		for i in arrow_count:
			var t := fposmod(arrow_t + float(i) * arrow_gap, 1.0)
			_draw_v2_flow_arrow(from, c1, c2, to, t, col, body_w, reverse_chase, gscale_v2)


func _draw_v2_flow_arrow(from: Vector2, c1: Vector2, c2: Vector2, to: Vector2, t: float,
		col: Color, body_w: float, reverse: bool, gscale: float = 0.5) -> void:
	var p   := _bezier_pos(from, c1, c2, to, t)
	var dt  := 0.018 if not reverse else -0.018
	var t2  := clampf(t + dt, 0.0, 1.0)
	var p2  := _bezier_pos(from, c1, c2, to, t2)
	var dir := (p2 - p).normalized()
	if dir.length_squared() < 0.0001:
		return
	var side := Vector2(-dir.y, dir.x)
	# Scale arrow size with power level
	var sz  := 1.0 + gscale * 0.7
	var len := maxf(5.0, body_w * 1.85 * sz)
	var wid := maxf(2.5, body_w * 0.75 * sz)
	var a   := p + dir * len
	var b   := p - dir * len * 0.55 + side * wid
	var c   := p - dir * len * 0.55 - side * wid
	# Outer white arrow
	draw_colored_polygon(PackedVector2Array([a, b, c]), Color(1.0, 1.0, 1.0, V2_FLOW_ARROW_ALPHA * (0.7 + gscale * 0.3)))
	# Inner colored arrow (gives each wire its polarity hue)
	draw_colored_polygon(PackedVector2Array([p + dir * (len * 0.70), b, c]), Color(col.r, col.g, col.b, 0.60 + gscale * 0.25))

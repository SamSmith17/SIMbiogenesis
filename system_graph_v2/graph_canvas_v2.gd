extends "res://system_graph/graph_canvas.gd"

const InteractionController := preload("res://system_graph_v2/interaction_controller.gd")
const WireRenderer := preload("res://system_graph_v2/wire_renderer.gd")

var _interaction: GraphInteractionControllerV2
var _wire_renderer: GraphWireRendererV2

var _legend_visible: bool = false
var _hover_port: Dictionary = {}

# V2_NODE_SHADOW / V2_TITLE_GLOW / V2_PORT_RING, _draw_rounded_rect, and the
# _draw_resource_flow_arrows_* helpers now live in the base graph_canvas.gd (single
# source of truth) and are inherited here.


func _ready() -> void:
	super._ready()
	_interaction = InteractionController.new()
	_wire_renderer = WireRenderer.new()


func _gui_input(event: InputEvent) -> void:
	# The Globe lens — and Site Plan / Elevation on the pin layer — draw no
	# ports or wires: none of the V2 pointer affordances apply; the base
	# handles orbit / zoom / pin picks and drags.
	if view_mode == GraphSiteLayout.VIEW_GLOBE or _pins_mode_active():
		super._gui_input(event)
		return
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
		# _port_at_screen is O(items x connections); only redraw the tooltip when the
		# hovered port identity actually changes (mirrors the base _update_site_hover
		# guard). The old _item_at_screen hover write was pure waste -- hover_item_id
		# is never read anywhere.
		var port := _port_at_screen(mm.position, "", "", _port_grab_radius())
		var before := _hover_port_identity()
		_hover_port = port
		if _hover_port_identity() != before:
			queue_redraw()
	super._gui_input(event)


## Stable identity of the currently-hovered port ("" when none) so motion events
## that don't change which port is under the cursor skip the tooltip redraw.
func _hover_port_identity() -> String:
	if _hover_port.is_empty():
		return ""
	return "%s|%s" % [
		str(_hover_port.get("item_id", "")),
		str(_hover_port.get("handle_id", "")),
	]


func _draw() -> void:
	super._draw()
	if view_mode == GraphSiteLayout.VIEW_GLOBE or _pins_mode_active():
		return
	# Reuse the per-draw visible cache (still populated by super._draw) for the
	# V2 overlay passes below, then release it so input hit-testing recomputes.
	_draw_cache_active = true
	_draw_v2_legend()
	_draw_v2_connection_feedback()
	_draw_v2_hover_port_tooltip()
	_draw_cache_active = false


func set_legend_visible(on: bool) -> void:
	_legend_visible = on
	queue_redraw()


func is_legend_visible() -> bool:
	return _legend_visible


func _draw_v2_legend() -> void:
	if not _legend_visible:
		return
	var entries: Array[Dictionary] = [
		{"label": "DC positive  (red)",   "color": PORT_COLORS.get("positive", Color(0.85, 0.33, 0.33, 1.0))},
		{"label": "DC negative  (grey)",  "color": PORT_COLORS.get("negative", Color(0.48, 0.48, 0.48, 1.0))},
		{"label": "AC output  (amber)",   "color": PORT_COLORS.get("ac", Color(0.94, 0.68, 0.30, 1.0))},
		{"label": "PV string  (gold)",    "color": PORT_COLORS.get("pv", Color(0.96, 0.62, 0.04, 1.0))},
	]
	for e: Dictionary in ResourceKinds.legend_entries(false):
		entries.append({"label": e.get("label", ""), "color": e.get("color", Color.WHITE)})
	entries.append({"label": "Flow animation  (scroll)", "color": Color(0.13, 0.83, 0.93, 1.0)})
	# Anchor legend to bottom-right of canvas
	var legend_w := 238.0
	var legend_h := 20.0 + entries.size() * 20.0 + 8.0
	var origin   := Vector2(size.x - legend_w - 14.0, size.y - legend_h - 14.0)
	_wire_renderer.draw_legend(self, origin, entries)


func _draw_v2_connection_feedback() -> void:
	if not _wire_dragging:
		return
	var fnt := ThemeDB.fallback_font
	var fs := 11
	var txt := ""
	var col := Color(0.75, 0.84, 0.95, 0.95)
	if not _wire_hub_drop.is_empty() and _wire_snap_valid:
		txt = "Release on tank to add perimeter port"
		col = Color(0.33, 0.92, 0.55, 0.95)
		# Preview ghost port on the circle.
		var drop_item := model.get_item(str(_wire_hub_drop.get("item_id", ""))) if model != null else {}
		if not drop_item.is_empty():
			var c := size * 0.5
			var tl := _item_screen_tl(drop_item, c)
			var sz := _item_screen_size(drop_item)
			var gp := GraphHubPorts.screen_pos_on_circle(tl, sz, float(_wire_hub_drop.get("angle_rad", 0.0)))
			draw_circle(gp, 8.0, Color(0.33, 0.92, 0.55, 0.35))
			draw_circle(gp, 5.0, Color(0.33, 0.92, 0.55, 0.9))
	elif not _wire_snap.is_empty():
		var item_id := _wire_snap.get("item_id", "") as String
		var handle_id := _wire_snap.get("handle_id", "") as String
		if _wire_snap_valid:
			if _wire_snap_is_kind_override():
				txt = ResourceKinds.mismatch_message(
					_wire_src_resource_kind, str(_wire_snap.get("resource_kind", "")))
				col = Color(0.95, 0.78, 0.35, 0.95)
			else:
				txt = "Release to connect: %s.%s" % [item_id, handle_id]
				col = Color(0.33, 0.92, 0.55, 0.95)
		else:
			if _wire_src_polarity == "resource":
				txt = ResourceKinds.mismatch_message(
					_wire_src_resource_kind, str(_wire_snap.get("resource_kind", "")))
			else:
				txt = "Invalid connection: polarity mismatch on %s.%s" % [item_id, handle_id]
			col = Color(0.95, 0.45, 0.45, 0.95)
	else:
		txt = "Drag to a port — or drop on a tank body to add a hub port"
	var p := _interaction.last_pointer_pos + Vector2(14.0, -10.0)
	var hint := "Alt+drag hub port to rotate · Touch: drag ports/nodes · 2-finger pan"
	# Background plate so the drag-hint text stays readable over busy graph content
	# (the hover-port tooltip already does this; the drag feedback didn't).
	var w1 := fnt.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w2 := fnt.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1).x
	var plate := Rect2(p - Vector2(6.0, 12.0), Vector2(maxf(w1, w2) + 12.0, 32.0))
	draw_rect(plate, Color(0.05, 0.08, 0.16, 0.85), true)
	draw_rect(plate, Color(0.26, 0.34, 0.50, 0.7), false, 1.0)
	draw_string(fnt, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	draw_string(fnt, p + Vector2(0.0, 14.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(0.75, 0.83, 0.95, 0.82))


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
	# Site Plan / Elevation: always use map-scaled plan chips from the base
	# canvas. V2 freeform bodies (especially solar-array compounds) size cells
	# with GraphArrayLayout.PANEL_* × zoom, which ignores physical footprints and
	# leaves a tiny hit rect under a huge visual — blocking drag/resize.
	if _is_physical_view():
		super._render_item(item)
		return
	var iid := item.get("id", "") as String
	# Hide legacy aggregate panel card in V2; individual virtual panel nodes replace it.
	if iid == "virtual_solar_array":
		return
	# Full-bleed icon/model preview (skip frame + title); keep ports + selection.
	var specs_early: Dictionary = item.get("specs", {}) as Dictionary
	if _icon_replaces_frame(specs_early) and str(item.get("type", "")) not in [
			"battery", "smartbattery", "resource", "panel"]:
		_render_icon_node_v2(item)
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
	if itype == "processor":
		_render_processor_item_v2(item)
		return
	super._render_item(item)


func _render_icon_node_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var accent := NODE_BORDER_COLORS.get(str(item.get("type", "")), C_BORDER) as Color
	if is_sel:
		accent = C_SELECTED_BORDER
	_draw_icon_as_node(rect, specs, accent, is_sel)
	_draw_item_handles(item, tl, sz)
	if is_sel:
		var z := _zoom
		draw_rect(rect.grow(maxf(1.0, 1.5 * z)), Color(0.13, 0.83, 0.93, 0.16), true)
		draw_rect(rect.grow(maxf(0.5, 1.0 * z)), Color(0.13, 0.83, 0.93, 0.9), false,
			maxf(1.0, 1.4 * z))


func _render_resource_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	# Read-only: specs are already migrated at load/creation, and every read
	# below default-guards missing keys — so avoid a per-draw deep copy +
	# ResourceKinds allocation + re-migration on every resource node, every frame.
	var specs := item.get("specs", {}) as Dictionary
	var kind: String = str(specs.get("resource_kind", "water"))
	var accent := ResourceKinds.wire_color(kind)
	if bool(item.get("is_ghost", false)):
		accent = Color(accent.r, accent.g, accent.b, 0.42)
	var raw_level := float(specs.get("level", 0.5))
	var in_deficit := bool(specs.get("allow_negative", false)) and raw_level < 0.0
	if in_deficit:
		accent = UITheme.C_WARN
	var border_col := accent if is_sel else Color(accent.r * 0.75, accent.g * 0.75, accent.b * 0.75, accent.a)
	var level := clampf(raw_level, 0.0, 1.0)

	# True circular hub — inscribed circle in the node rect.
	var hub_c := GraphHubPorts.circle_center(tl, sz)
	var hub_r := GraphHubPorts.circle_radius(sz)
	# Soft shadow
	draw_circle(hub_c + Vector2(2.0, 3.0), hub_r, V2_NODE_SHADOW)
	# Outer shell
	draw_circle(hub_c, hub_r, Color(0.05, 0.08, 0.14, 0.97))
	draw_arc(hub_c, hub_r, 0.0, TAU, 48, Color(border_col.r, border_col.g, border_col.b, 0.85), 2.0, true)
	# Inner well
	var inner_r := maxf(4.0, hub_r - 4.0)
	draw_circle(hub_c, inner_r, Color(0.04, 0.07, 0.12, 0.98))
	# Level fill as a chord from the bottom (clip via arc wedges).
	if level > 0.001:
		var fill_col := Color(accent.r, accent.g, accent.b,
				0.88 if not bool(item.get("is_ghost", false)) else 0.35)
		_draw_circle_level_fill(hub_c, inner_r - 1.0, level, fill_col)

	var fnt := ThemeDB.fallback_font
	var name := str(specs.get("name", ResourceKinds.display_name(kind)))
	var unlimited := bool(specs.get("unlimited_capacity", false))
	var cap_qty := float(specs.get("capacity_qty", 100.0))
	var unit := ("⚠" if in_deficit else ("∞" if unlimited else str(specs.get("capacity_unit", ""))))
	var qty := level * cap_qty

	var qty_str: String
	if in_deficit:
		qty_str = "-%.1f" % float(specs.get("deficit_qty", -raw_level * cap_qty))
	elif unlimited:
		qty_str = "∞"
	else:
		qty_str = "%.1f" % qty
	if not unlimited and not in_deficit and qty_str.ends_with(".0"):
		qty_str = qty_str.substr(0, qty_str.length() - 2)
	
	var net_flow := float(specs.get("inflow_rate", 0.0)) - float(specs.get("outflow_rate", 0.0))
	var flow_str := ""
	if absf(net_flow) > 0.001:
		var sign_str := "+" if net_flow > 0 else ""
		var nf_str := "%.2f" % net_flow
		if nf_str.ends_with("0"):
			nf_str = nf_str.substr(0, nf_str.length() - 1)
		if nf_str.ends_with(".0"):
			nf_str = nf_str.substr(0, nf_str.length() - 2)
		flow_str = "%s%s/h" % [sign_str, nf_str]

	var main_fsize := maxi(10, int(round(22.0 * _zoom)))
	var name_fsize := maxi(8, int(round(11.0 * _zoom)))
	var unit_fsize := maxi(8, int(round(10.0 * _zoom)))
	var flow_fsize := maxi(8, int(round(10.0 * _zoom)))
	var spacing := 2.0 * _zoom
	var line_spacing := 4.0 * _zoom
	
	var total_h := name_fsize + line_spacing + main_fsize + spacing + unit_fsize
	if flow_str != "":
		total_h += line_spacing + flow_fsize
		
	var current_y := hub_c.y - total_h * 0.5
	
	# Draw Name
	var ts_name := fnt.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize)
	var pos_name := Vector2(hub_c.x - ts_name.x * 0.5, current_y + fnt.get_ascent(name_fsize))
	var c_name := Color(0.9, 0.9, 0.9, 0.9)
	draw_string(fnt, pos_name, name, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize, c_name)
	draw_string_outline(fnt, pos_name, name, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize, maxi(1, int(round(1.0 * _zoom))), c_name)
	current_y += name_fsize + line_spacing
	
	# Draw Qty
	var ts_qty := fnt.get_string_size(qty_str, HORIZONTAL_ALIGNMENT_LEFT, -1, main_fsize)
	var pos_qty := Vector2(hub_c.x - ts_qty.x * 0.5, current_y + fnt.get_ascent(main_fsize))
	var text_c := Color(1, 1, 1, 1)
	draw_string(fnt, pos_qty, qty_str, HORIZONTAL_ALIGNMENT_LEFT, -1, main_fsize, text_c)
	draw_string_outline(fnt, pos_qty, qty_str, HORIZONTAL_ALIGNMENT_LEFT, -1, main_fsize, maxi(1, int(round(1.5 * _zoom))), text_c)
	current_y += main_fsize + spacing
	
	# Draw Unit
	var ts_unit := fnt.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, unit_fsize)
	var pos_unit := Vector2(hub_c.x - ts_unit.x * 0.5, current_y + fnt.get_ascent(unit_fsize))
	var c_unit := Color(0.85, 0.85, 0.85, 0.9)
	draw_string(fnt, pos_unit, unit, HORIZONTAL_ALIGNMENT_LEFT, -1, unit_fsize, c_unit)
	draw_string_outline(fnt, pos_unit, unit, HORIZONTAL_ALIGNMENT_LEFT, -1, unit_fsize, maxi(1, int(round(1.0 * _zoom))), c_unit)
	current_y += unit_fsize + line_spacing
	
	# Draw Flow
	if flow_str != "":
		var ts_flow := fnt.get_string_size(flow_str, HORIZONTAL_ALIGNMENT_LEFT, -1, flow_fsize)
		var pos_flow := Vector2(hub_c.x - ts_flow.x * 0.5, current_y + fnt.get_ascent(flow_fsize))
		var flow_col := Color(0.6, 1.0, 0.6, 0.95) if net_flow > 0 else Color(1.0, 0.7, 0.7, 0.95)
		draw_string(fnt, pos_flow, flow_str, HORIZONTAL_ALIGNMENT_LEFT, -1, flow_fsize, flow_col)
		draw_string_outline(fnt, pos_flow, flow_str, HORIZONTAL_ALIGNMENT_LEFT, -1, flow_fsize, maxi(1, int(round(1.0 * _zoom))), flow_col)

	_draw_tank_overflow_glyph(specs,
		hub_c + Vector2(hub_r * 0.85, -hub_r * 0.7))

	_draw_item_handles(item, tl, sz)
	if is_sel:
		draw_arc(hub_c, hub_r + 2.0, 0.0, TAU, 48,
				Color(accent.r, accent.g, accent.b, 0.55), 2.0, true)


## Fill the lower fraction of a circle (tank level) with horizontal chord clipping.
func _draw_circle_level_fill(c: Vector2, r: float, level: float, col: Color) -> void:
	level = clampf(level, 0.0, 1.0)
	if level >= 0.999:
		draw_circle(c, r, col)
		return
	if level <= 0.001 or r < 2.0:
		return
	# Waterline y from bottom: y = c.y + r - 2*r*level
	var water_y := c.y + r - 2.0 * r * level
	var dy := water_y - c.y
	if absf(dy) >= r:
		if dy < 0.0:
			draw_circle(c, r, col)
		return
	var half_chord := sqrt(maxf(0.0, r * r - dy * dy))
	# Approximate fill with a fan of triangles below the waterline.
	var steps := 24
	var pts := PackedVector2Array()
	pts.append(Vector2(c.x - half_chord, water_y))
	pts.append(Vector2(c.x + half_chord, water_y))
	# Walk the lower arc from right chord end → bottom → left chord end.
	var a0 := atan2(dy, half_chord)   # right chord angle from center
	var a1 := PI - a0                 # left chord angle
	# Lower arc goes a0 → π/2 → a1 (clockwise in screen Y-down? use CCW via bezier samples)
	for i in range(1, steps):
		var t := float(i) / float(steps)
		var ang := lerpf(a0, a1, t)
		# Prefer the lower path: if a0 is small positive and a1 near π, lerp goes through bottom.
		pts.append(c + Vector2(cos(ang), sin(ang)) * r)
	if pts.size() >= 3:
		draw_colored_polygon(pts, col)


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
	var fsize := GraphNodeLabel.stat_font_size(rect, 26.0, _zoom)
	var label := "%d%%" % int(round(soc * 100.0))
	var ts := fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize)
	var tp := rect.position + Vector2((rect.size.x - ts.x) * 0.5, (rect.size.y + ts.y * 0.4) * 0.5)
	for ox in [-1.0, 1.0, 0.0]:
		for oy in [-1.0, 1.0, 0.0]:
			if ox == 0.0 and oy == 0.0:
				continue
			draw_string(fnt, tp + Vector2(ox, oy), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.02, 0.06, 0.04, 0.85))
	draw_string(fnt, tp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(0.98, 1.0, 0.95, 1.0))

	# Spec column, all centered on the SOC number so the node reads as one
	# stacked gauge:   voltage / big SOC% / chemistry / stored-vs-total kWh.
	# Hidden when zoomed out far enough that the text would be unreadable.
	if _zoom >= 0.55:
		var small := maxi(8, int(round(9.0 * _zoom)))
		var chem := BatteryChemistry.infer(specs)
		var nominal_v := float(specs.get("voltage", 0.0))
		# Optional: show the modelled resting terminal voltage instead of the
		# nameplate. Off by default — nominal is what a spec sheet quotes.
		var shown_v := nominal_v
		var v_suffix := " V"
		if bool(specs.get("show_real_voltage", false)) and nominal_v > 0.0:
			shown_v = BatteryChemistry.voltage_at_soc(nominal_v, chem, soc)
			v_suffix = " V≡"  # marks a simulated, not nameplate, reading
		var ink := Color(0.80, 0.98, 0.88, 0.95)
		# Nominal voltage, centered ABOVE the SOC number.
		if nominal_v > 0.0:
			var v_txt := "%.1f%s" % [shown_v, v_suffix]
			var vw := fnt.get_string_size(v_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, small)
			draw_string(fnt, Vector2(rect.position.x + (rect.size.x - vw.x) * 0.5,
					tp.y - ts.y - 2.0), v_txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, small, ink)
		# Chemistry, centered BELOW the SOC number.
		var chem_tag := BatteryChemistry.label(chem)
		if not chem_tag.is_empty():
			var cw := fnt.get_string_size(chem_tag, HORIZONTAL_ALIGNMENT_LEFT, -1, small)
			draw_string(fnt, Vector2(rect.position.x + (rect.size.x - cw.x) * 0.5,
					tp.y + small + 4.0), chem_tag,
				HORIZONTAL_ALIGNMENT_LEFT, -1, small, Color(0.72, 0.96, 0.82, 0.92))
		# Stored vs total capacity at the foot — the number the SOC bar is
		# actually showing a fraction of.
		var kwh := float(specs.get("kwh", 0.0))
		if kwh > 0.0:
			var cap_txt := "%.1f / %.1f kWh" % [soc * kwh, kwh]
			var kw2 := fnt.get_string_size(cap_txt, HORIZONTAL_ALIGNMENT_LEFT, -1, small)
			draw_string(fnt, Vector2(rect.position.x + (rect.size.x - kw2.x) * 0.5,
					rect.position.y + rect.size.y - 6.0), cap_txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, small, ink)
		elif float(specs.get("ah", 0.0)) > 0.0 and nominal_v > 0.0:
			# No kWh spec (legacy/user preset): derive from Ah × V.
			var kwh_est := float(specs.get("ah", 0.0)) * nominal_v / 1000.0
			var cap_txt2 := "%.1f / %.1f kWh" % [soc * kwh_est, kwh_est]
			var kw3 := fnt.get_string_size(cap_txt2, HORIZONTAL_ALIGNMENT_LEFT, -1, small)
			draw_string(fnt, Vector2(rect.position.x + (rect.size.x - kw3.x) * 0.5,
					rect.position.y + rect.size.y - 6.0), cap_txt2,
				HORIZONTAL_ALIGNMENT_LEFT, -1, small, ink)

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
	var z := _zoom
	var fnt := ThemeDB.fallback_font

	# Outer module frame (all strokes/paddings in graph px × zoom so the whole
	# card scales as one — no fixed-pixel offsets drifting relative to the ports).
	draw_rect(rect.grow(1.5 * z), Color(0.01, 0.02, 0.05, 0.74), true)
	draw_rect(rect, Color(0.03, 0.06, 0.12, 0.96), true)
	draw_rect(rect, Color(0.20, 0.67, 0.90, 0.72), false, maxf(1.0, 1.2 * z))

	# Proportional zones: name band (top) · cell grid (middle) · telemetry (bottom).
	var pad := maxf(2.0, 4.0 * z)
	var name_h := clampf(sz.y * 0.18, 10.0 * z, 30.0 * z)
	var strip_h := clampf(sz.y * 0.20, 12.0 * z, 30.0 * z)

	# Cell grid (panel face)
	var face := Rect2(
		rect.position + Vector2(pad, name_h),
		Vector2(sz.x - pad * 2.0, sz.y - name_h - strip_h))
	if face.size.x > 6.0 and face.size.y > 6.0:
		draw_rect(face, Color(0.05, 0.18, 0.33, 0.95), true)
		var line_w := maxf(0.6, 0.8 * z)
		for c in range(1, 4):
			var x := face.position.x + face.size.x * (float(c) / 4.0)
			draw_line(Vector2(x, face.position.y), Vector2(x, face.end.y),
				Color(0.56, 0.79, 0.95, 0.28), line_w)
		var grid_rows := 8 if face.size.y > 60.0 else 4
		for r in range(1, grid_rows):
			var y := face.position.y + face.size.y * (float(r) / float(grid_rows))
			draw_line(Vector2(face.position.x, y), Vector2(face.end.x, y),
				Color(0.56, 0.79, 0.95, 0.24), line_w)
		draw_rect(Rect2(face.position, Vector2(face.size.x, maxf(2.0, face.size.y * 0.14))),
			Color(0.74, 0.89, 1.0, 0.10), true)

	# Name band (top)
	var name_band := Rect2(rect.position + Vector2(pad, maxf(1.0, 2.0 * z)),
		Vector2(sz.x - pad * 2.0, maxf(6.0, name_h - 2.0 * z)))
	var fs_name := GraphNodeLabel.body_font_size(name_band, 1, 10.0, 12.0, z)
	_draw_fitted_label(name_band.position + Vector2(0.0, fs_name),
		str(specs.get("name", "PV")), name_band.size.x, fs_name, Color(0.90, 0.96, 1.0, 0.95))

	# Telemetry strip (bottom) — wattage left, array coordinate right.
	var strip := Rect2(Vector2(rect.position.x + pad, rect.end.y - strip_h),
		Vector2(sz.x - pad * 2.0, maxf(6.0, strip_h - pad)))
	draw_rect(strip, Color(0.01, 0.03, 0.07, 0.82), true)
	draw_rect(strip, Color(0.33, 0.72, 0.94, 0.38), false, maxf(0.8, 1.0 * z))
	var fs_stats := GraphNodeLabel.body_font_size(strip, 1, 9.0, 11.0, z)
	var baseline := strip.position.y + strip.size.y * 0.5 + fs_stats * 0.36
	draw_string(fnt, Vector2(strip.position.x + maxf(2.0, 4.0 * z), baseline),
		"%.0fW" % float(specs.get("wmp", 0.0)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats, Color(0.78, 0.92, 1.0, 0.96))
	var grp := int(specs.get("array_group", 0))
	var str_idx := int(specs.get("array_string", 0))
	var ser := int(specs.get("array_series_pos", 0))
	if grp > 0 and str_idx > 0 and ser > 0:
		var gtxt := "G%d S%d P%d" % [grp, str_idx, ser]
		var gsz := fnt.get_string_size(gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats)
		if gsz.x < strip.size.x * 0.55:
			draw_string(fnt, Vector2(strip.end.x - gsz.x - 2.0 * z, baseline),
				gtxt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_stats, Color(0.73, 0.90, 1.0, 0.86))

	_draw_item_handles(item, tl, sz)
	if is_sel:
		draw_rect(rect.grow(1.5 * z), Color(0.13, 0.83, 0.93, 0.16), true)
		draw_rect(rect.grow(1.0 * z), Color(0.13, 0.83, 0.93, 0.85), false, maxf(1.0, 1.4 * z))


## Processor card: generated image (GLB preview or icon) · title · critical stats.
## Every offset is graph-space × zoom so the whole card scales as one unit —
## legible up close, still readable as an image + title chip when zoomed out.
func _render_processor_item_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var rect := Rect2(tl, sz)
	var iid := item.get("id", "") as String
	var is_sel := (iid == selected_item_id) or selected_item_ids.has(iid)
	var specs := item.get("specs", {}) as Dictionary
	var z := _zoom
	var fnt := ThemeDB.fallback_font

	var accent := NODE_BORDER_COLORS.get("processor", Color(0.58, 0.64, 0.72, 1.0)) as Color
	if str(specs.get("role", "")) == "habitat":
		accent = Color(0.62, 0.74, 0.44, 1.0)
	if item.get("batch_error", "") == "missing_inputs":
		accent = Color(0.92, 0.28, 0.28, 1.0)
	if bool(item.get("is_ghost", false)):
		accent = Color(accent.r, accent.g, accent.b, 0.5)

	# Active-load glow behind the frame.
	if _load_item_is_active(item):
		draw_rect(rect.grow(maxf(2.5, 3.0 * z)), C_ACTIVE_LOAD_GLOW, true)

	if _icon_replaces_frame(specs):
		_draw_icon_as_node(rect, specs,
			accent if is_sel else Color(accent.r * 0.85, accent.g * 0.85, accent.b * 0.85, 1.0),
			is_sel)
		_draw_item_handles(item, tl, sz)
		if is_sel:
			draw_rect(rect.grow(1.2 * z), Color(0.13, 0.83, 0.93, 0.16), true)
			draw_rect(rect.grow(0.8 * z), Color(0.13, 0.83, 0.93, 0.85), false, maxf(1.0, 1.2 * z))
		return

	_draw_node_frame(rect, accent if is_sel else Color(accent.r * 0.85, accent.g * 0.85, accent.b * 0.85, 1.0))
	var title_h := _title_band_height(sz.y)
	_draw_title_band(rect, title_h, str(specs.get("name", "Processor")), accent)

	var pad := maxf(3.0, 6.0 * z)
	var detail_h := maxf(24.0, 32.0 * z)
	var body_top := rect.position.y + title_h
	var body_h := sz.y - title_h
	
	if body_h < detail_h + pad * 3.0:
		_draw_item_handles(item, tl, sz)
		if is_sel:
			draw_rect(rect.grow(1.2 * z), Color(0.13, 0.83, 0.93, 0.16), true)
		return
		
	var inner_w := sz.x - pad * 2.0
	var img_h := body_h - detail_h - pad * 1.5
	var img_zone := Rect2(rect.position.x + pad, body_top + pad, inner_w, img_h)
	
	# Image zone (fills body width)
	_draw_processor_image_v2(img_zone, specs, accent, z)
	
	# Stats banner (bottom)
	var detail_zone := Rect2(rect.position.x + pad, img_zone.end.y + pad * 0.5, inner_w, detail_h)
	if inner_w > 12.0:
		var half_w := inner_w * 0.5 - pad
		var left_x := detail_zone.position.x
		var right_x := detail_zone.position.x + inner_w * 0.5 + pad
		var fs := GraphNodeLabel.body_font_size(
			Rect2(Vector2.ZERO, Vector2(half_w, detail_h * 0.4)), 1, 10.0, 12.0, z)
		var line_gap := float(fs) + maxf(2.0, 3.0 * z)
		
		# Left side: Power Draw
		var watts := float(specs.get("watts", specs.get("max_watts", 0.0)))
		var fs_big := GraphNodeLabel.stat_font_size(
			Rect2(Vector2.ZERO, Vector2(half_w, detail_h * 0.55)), 16.0, z)
			
		var y := detail_zone.position.y
		if item.get("batch_error", "") == "missing_inputs":
			draw_string(fnt, Vector2(left_x, y + float(fs_big)),
				"Stalled", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_big, Color(0.92, 0.28, 0.28, 1.0))
			draw_string(fnt, Vector2(left_x, y + float(fs_big) + line_gap),
				"Missing Inputs", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.92, 0.28, 0.28, 0.8))
		elif watts > 0.0:
			draw_string(fnt, Vector2(left_x, y + float(fs_big)),
				_fmt_power_w(watts), HORIZONTAL_ALIGNMENT_LEFT, -1, fs_big, C_TEXT)
			
			var es := str(specs.get("energy_source", "ac"))
			if es.is_empty(): es = "ac"
			var es_str := "⚡ AC in" if es == "ac" else ("%s in" % es)
			var es_c := C_AMBER if es == "ac" else C_TEXT_M
			draw_string(fnt, Vector2(left_x, y + float(fs_big) + line_gap),
				es_str, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, es_c)
				
		# Right side: I/O and Rates
		var inputs: Array = specs.get("inputs", []) as Array
		var outputs: Array = specs.get("outputs", []) as Array
		if not inputs.is_empty() or not outputs.is_empty():
			var in_names: PackedStringArray = []
			for inp: Variant in inputs:
				in_names.append(ResourceKinds.display_name(str((inp as Dictionary).get("kind", ""))))
			var out_names: PackedStringArray = []
			for outp: Variant in outputs:
				out_names.append(ResourceKinds.display_name(str((outp as Dictionary).get("kind", ""))))
			
			var in_k := ", ".join(in_names) if in_names.size() > 0 else "—"
			var out_k := ", ".join(out_names) if out_names.size() > 0 else "—"
			_draw_fitted_label(Vector2(right_x, y + float(fs)), "%s → %s" % [in_k, out_k],
				half_w, fs, Color(0.72, 0.84, 0.96, 0.92))

			var rate_str := str(specs.get("output_rate", ""))
			if not rate_str.is_empty():
				_draw_fitted_label(Vector2(right_x, y + float(fs) + line_gap), rate_str, half_w, fs, C_TEXT_M)

	_draw_item_handles(item, tl, sz)
	if is_sel:
		draw_rect(rect.grow(1.2 * z), Color(0.13, 0.83, 0.93, 0.16), true)
		draw_rect(rect.grow(0.8 * z), Color(0.13, 0.83, 0.93, 0.85), false, maxf(1.0, 1.2 * z))


## Left-zone image for a processor card: rendered GLB thumbnail when the preset
## carries a model_id, else a large centered emoji icon on a tinted tile.
func _draw_processor_image_v2(zone: Rect2, specs: Dictionary, accent: Color, z: float) -> void:
	if zone.size.x < 6.0 or zone.size.y < 6.0:
		return
	var radius := int(maxf(2.0, 6.0 * z))
	_draw_rounded_rect(zone, Color(0.04, 0.07, 0.12, 0.96), radius,
		Color(accent.r, accent.g, accent.b, 0.35), 1)
	# Preferred: cached GLB preview render (fills the tile, aspect-preserved).
	if _draw_model_preview_zone(zone.grow(-maxf(1.0, 2.0 * z)), specs, 1.0):
		return
	# Fallback: emoji icon centered.
	var icon := str(specs.get("icon", "⚙"))
	if icon.is_empty():
		icon = "⚙"
	var fnt := ThemeDB.fallback_font
	var fs := int(clampf(minf(zone.size.x, zone.size.y) * 0.6, 6.0, 220.0))
	var isz := fnt.get_string_size(icon, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	draw_string(fnt, zone.position + Vector2(
			(zone.size.x - isz.x) * 0.5,
			(zone.size.y + isz.y * 0.55) * 0.5),
		icon, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)


## Compact power formatter — kW above 1000 W so headline stays short when zoomed out.
func _fmt_power_w(watts: float) -> String:
	if watts >= 1000.0:
		return "%.1f kW" % (watts / 1000.0)
	return "%.0f W" % watts


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
	var title_band := Rect2(rect.position + Vector2(6.0, 4.0), Vector2(rect.size.x - 12.0, minf(28.0, rect.size.y * 0.22)))
	var fs_name := GraphNodeLabel.body_font_size(title_band, 1, 11.0, 13.0, _zoom)
	var fs_stats := GraphNodeLabel.body_font_size(
		Rect2(Vector2.ZERO, Vector2(rect.size.x, rect.size.y * 0.14)), 1, 10.0, 11.0, _zoom)
	var title := str(specs.get("name", "Load Group"))
	_draw_fitted_label(title_band.position + Vector2(2.0, fs_name),
		title, title_band.size.x, fs_name, Color(0.96, 0.92, 0.86, 0.96))
	draw_string(fnt, rect.position + Vector2(8.0, title_band.position.y - rect.position.y + fs_name + 4.0),
		"⧉ %d loads grouped" % child_count,
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
		var n := int(specs.get("array_panel_units", specs.get("child_count", 0)))
		title = "Solar Array · %d panels" % n if n > 0 else "Solar Array"
	elif kind == "battery_bank":
		accent = Color(0.17, 0.84, 0.52, 1.0)
		title = "Battery Bank"

	_draw_node_frame(rect, accent if is_sel else Color(accent.r * 0.85, accent.g * 0.85, accent.b * 0.85, 1.0))
	var title_h := _title_band_height(sz.y)
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
	var grid := GraphArrayLayout.grid_dims(specs)
	var cols := grid.x
	var rows := grid.y
	var panel_count := maxi(1, int(specs.get("array_panel_units", cols * rows)))
	var s_count := cols
	var p_count := rows
	var topo := str(specs.get("array_topology", "%dS x %dP" % [s_count, p_count]))
	var total_w := float(specs.get("array_equiv_wmp", 0.0))

	var gap := GraphArrayLayout.CELL_GAP * _zoom
	var cell_sz := Vector2(GraphArrayLayout.PANEL_W, GraphArrayLayout.PANEL_H) * _zoom
	var pad := GraphArrayLayout.BODY_PAD * _zoom
	var footer_h := GraphArrayLayout.FOOTER_H * _zoom
	var origin := rect.position + Vector2(pad, pad)
	var grid_h := float(rows) * cell_sz.y + float(maxi(0, rows - 1)) * gap

	var idx := 0
	for r in range(rows):
		for c in range(cols):
			if idx >= panel_count:
				break
			var p := origin + Vector2(
				float(c) * (cell_sz.x + gap),
				float(r) * (cell_sz.y + gap))
			_draw_array_panel_cell_v2(Rect2(p, cell_sz))
			idx += 1

	# Shared bottom bus bar across the array width.
	var bus_y := origin.y + grid_h + maxf(2.0, gap)
	draw_line(
		Vector2(origin.x + cell_sz.x * 0.15, bus_y),
		Vector2(origin.x + float(cols) * cell_sz.x + float(maxi(0, cols - 1)) * gap - cell_sz.x * 0.15, bus_y),
		Color(0.42, 0.90, 0.98, 0.55), maxf(1.5, 2.0 * _zoom))
	draw_line(
		Vector2(origin.x + cell_sz.x * 0.28, bus_y + maxf(2.0, 3.0 * _zoom)),
		Vector2(origin.x + float(cols) * cell_sz.x + float(maxi(0, cols - 1)) * gap - cell_sz.x * 0.28, bus_y + maxf(2.0, 3.0 * _zoom)),
		Color(0.30, 0.32, 0.40, 0.65), maxf(1.2, 1.6 * _zoom))

	var fnt := ThemeDB.fallback_font
	var meta_y := rect.end.y - footer_h * 0.35
	var fs_meta := maxi(GraphNodeLabel.BODY_FONT_MIN, int(round(10.0 * _zoom)))
	var fs_hint := maxi(GraphNodeLabel.BODY_FONT_MIN, int(round(9.0 * _zoom)))
	draw_string(fnt, rect.position + Vector2(pad, meta_y),
			"%s  ·  %d panels  ·  %.0f W" % [topo, panel_count, total_w],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs_meta, Color(0.82, 0.94, 1.0, 0.92))
	draw_string(fnt, rect.position + Vector2(pad, rect.end.y - maxf(6.0, pad * 0.5)),
			"Drag to move · single +/- bus",
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs_hint, Color(0.68, 0.82, 0.96, 0.82))


func _draw_array_panel_cell_v2(cell: Rect2) -> void:
	if cell.size.x < 6.0 or cell.size.y < 6.0:
		return
	draw_rect(cell, Color(0.03, 0.06, 0.12, 0.96), true)
	draw_rect(cell, Color(0.20, 0.67, 0.90, 0.62), false, maxf(0.8, 1.0 * _zoom))
	var face := cell.grow(-maxf(2.0, 3.0 * _zoom))
	draw_rect(face, Color(0.05, 0.18, 0.33, 0.95), true)
	for c in range(1, 4):
		var x := face.position.x + face.size.x * (float(c) / 4.0)
		draw_line(Vector2(x, face.position.y), Vector2(x, face.end.y),
				Color(0.56, 0.79, 0.95, 0.28), maxf(0.6, 0.8 * _zoom))
	for r in range(1, 4):
		var y := face.position.y + face.size.y * (float(r) / 4.0)
		draw_line(Vector2(face.position.x, y), Vector2(face.end.x, y),
				Color(0.56, 0.79, 0.95, 0.22), maxf(0.6, 0.8 * _zoom))
	var sheen := Rect2(face.position + Vector2(0.0, 1.0),
			Vector2(face.size.x, maxf(2.0, face.size.y * 0.14)))
	draw_rect(sheen, Color(0.74, 0.89, 1.0, 0.10), true)


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


func _draw_port_dot(screen_pos: Vector2, polarity: String, resource_kind: String = "") -> void:
	# The physical views own their port sizing: the base draws a port as a
	# ~0.3 m fitting on the ground, CAPPED in screen space (SITE_PORT_DOT_* /
	# the Elevation cap). This billboard override used to run for Site Plan and
	# Elevation too, and its uncapped `6.8 × _zoom` radius is why the port discs
	# grew to the size of the node at high zoom — four discs hid the turbine and
	# each other — even after the base's cap had landed. Route both physical
	# views to the base and keep the billboard for the freeform canvas only.
	if _is_physical_view():
		super(screen_pos, polarity, resource_kind)
		return
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
	var dc := is_dc_polarity(polarity)
	draw_circle(screen_pos, r + (6.0 if touch else 4.0), Color(col.r, col.g, col.b, 0.18))
	draw_circle(screen_pos, r + 1.8, Color(col.r, col.g, col.b, 0.34))
	draw_circle(screen_pos, r, dc_port_fill(col, polarity) if dc else col)
	# DC ports: solid disc + polarity glyph. The old 56%-radius background hole
	# left only a thin rim of colour, so at wide zoom the red + and the near-
	# black − were nearly the same dot. Other port kinds keep the donut.
	if not dc:
		draw_circle(screen_pos, r * 0.56, Color(0.06, 0.09, 0.17, 0.95))
	draw_circle(screen_pos, r + 0.4, V2_PORT_RING, false, 1.0)
	if dc:
		_draw_polarity_glyph(screen_pos, r, polarity)
	if touch:
		draw_circle(screen_pos, r + 8.0, Color(col.r, col.g, col.b, 0.10), false, 2.0)

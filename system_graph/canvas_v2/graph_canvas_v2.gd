extends "res://system_graph/graph_canvas.gd"

const InteractionController := preload("res://system_graph/canvas_v2/interaction_controller.gd")
const WireRenderer := preload("res://system_graph/canvas_v2/wire_renderer.gd")

var _interaction: GraphInteractionControllerV2
var _wire_renderer: GraphWireRendererV2

var _legend_visible: bool = false
var _hover_port: Dictionary = {}
## Live context every GraphCard reads this draw (wired ports, the bank's flow).
var _card_ctx: Dictionary = {}
## Freeform cards use the one shared anatomy (GraphCard). Off = the legacy
## per-type renderers (kept for A/B while the new cards bed in).
var unified_cards: bool = true
## Name every port beside its dot once zoomed in (Display pref "port_names").
## Hover always names a port (the tooltip); this is for reading a whole card.
var port_names: bool = true
const PORT_NAME_MIN_ZOOM := 1.0

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
	if _v3_orbit_input(event):
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		_interaction.update_pointer(st.position)
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		_interaction.update_pointer(sd.position)
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		# V2 wire-pick: Ctrl+LMB selects the nearest connection — but not over a
		# node: Ctrl-click there adds the node to the selection (bootcamp L12
		# tells the player to Ctrl-click the controller, whose card the PV wires
		# cross, and the click used to select a wire instead).
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed and mb.ctrl_pressed \
				and _item_at_screen(mb.position).is_empty():
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
		# Path highlight: the node under the pointer (not while dragging).
		if not _item_dragging and not _wire_dragging and mm.button_mask == 0:
			var hov_id := str(_item_at_screen(mm.position).get("id", ""))
			set_path_focus(hov_id)
			_set_hover_item(hov_id)
		var port := _port_at_screen(mm.position, "", "", _port_grab_radius())
		var before := _hover_port_identity()
		_hover_port = port
		if _hover_port_identity() != before:
			queue_redraw()
	super._gui_input(event)


## 3D view: Ctrl (or Cmd) + drag orbits the camera, anywhere on the canvas.
## A Ctrl-press that does not move is a Ctrl-click: handed to the canvas
## as one on release (it toggles the node in the selection).
var _orbit_press: InputEventMouseButton = null
var _orbit_dragging := false
var _orbit_replay := false
var _orbit_last := Vector2.ZERO
var _orbit_msec := 0
const ORBIT_START_PX := 4.0


func _v3_orbit_input(event: InputEvent) -> bool:
	if _orbit_replay or not _v3_on():
		if _orbit_press != null and not _v3_on():
			_orbit_press = null
			_orbit_dragging = false
			_v3.end_orbit()
		return false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed and (mb.ctrl_pressed or mb.meta_pressed) and not mb.double_click:
			_orbit_press = mb.duplicate() as InputEventMouseButton
			_orbit_dragging = false
			_orbit_last = mb.position
			_orbit_msec = Time.get_ticks_msec()
			accept_event()
			return true
		if not mb.pressed and _orbit_press != null:
			var press := _orbit_press
			_orbit_press = null
			if _orbit_dragging:
				_orbit_dragging = false
				_v3.end_orbit(Time.get_ticks_msec() - _orbit_msec > 80)
			else:
				_orbit_replay = true
				_gui_input(press)
				_gui_input(mb)
				_orbit_replay = false
			accept_event()
			return true
	elif event is InputEventMouseMotion and _orbit_press != null:
		var mm := event as InputEventMouseMotion
		# From positions, not `relative`: pushed / warped motions carry a
		# wrong relative.
		if not _orbit_dragging and mm.position.distance_to(_orbit_press.position) >= ORBIT_START_PX:
			_orbit_dragging = true
			_v3.orbiting = true
		if _orbit_dragging:
			var now := Time.get_ticks_msec()
			var dt := clampf(float(now - _orbit_msec) / 1000.0, 0.004, 0.1)
			_orbit_msec = now
			view_3d_orbit(mm.position - _orbit_last, dt)
		_orbit_last = mm.position
		accept_event()
		return true
	return false


func is_orbiting_3d() -> bool:
	return _orbit_dragging


func _notification(what: int) -> void:
	super._notification(what)
	# The pointer left the canvas: drop the port tooltip (it lingered over the
	# graph after the pointer moved onto the timeline or a panel).
	if what == NOTIFICATION_MOUSE_EXIT:
		_set_hover_item("")
	if what == NOTIFICATION_MOUSE_EXIT and not _hover_port.is_empty():
		_hover_port = {}
		queue_redraw()


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
	# The WHOLE draw, base + V2 passes, one call per redraw (gv_draw stops
	# before the V2 overlays): per-draw cost = avg / calls.
	PerfSpan.begin("gv_draw_all")
	_draw_v2_all()
	PerfSpan.end("gv_draw_all")


func _draw_v2_all() -> void:
	_card_ctx = _build_card_ctx()
	_tile_labels.clear()
	super._draw()
	# The Flows lens draws everything it shows itself (GraphFlowLens).
	if view_mode == GraphSiteLayout.VIEW_FLOWS or view_mode == GraphSiteLayout.VIEW_PROCESS:
		return
	_draw_system_overlay_site()
	_draw_tile_labels()
	_draw_site_inset()
	_draw_inside_cue()
	_draw_element_air()
	_draw_suggestion()
	if view_mode == GraphSiteLayout.VIEW_GLOBE or _pins_mode_active():
		return
	# Reuse the per-draw visible cache (still populated by super._draw) for the
	# V2 overlay passes below, then release it so input hit-testing recomputes.
	_draw_cache_active = true
	if not _v3_on():
		_draw_flow_scale_legend()
	_draw_v2_legend()
	_draw_v2_connection_feedback()
	_draw_v2_hover_port_tooltip()
	_draw_pv_snap_guides()
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
	var fnt := UITheme.font("medium")
	var fs := UITheme.FONT_XS + 1
	var txt := ""
	var col := Color(0.75, 0.84, 0.95, 0.95)
	var snap_pos := Vector2.INF
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
		var target := GraphPortLabels.port_label(model.get_item(item_id) if model != null else {},
			handle_id, str(_wire_snap.get("resource_kind", "")))
		snap_pos = _wire_snap.get("pos", Vector2.INF) as Vector2
		if _wire_snap_valid:
			if _wire_snap_is_kind_override():
				txt = ResourceKinds.mismatch_message(
					_wire_src_resource_kind, str(_wire_snap.get("resource_kind", "")))
				col = Color(0.95, 0.78, 0.35, 0.95)
			else:
				txt = "Release to connect to %s" % target
				col = Color(0.33, 0.92, 0.55, 0.95)
		else:
			if _wire_src_polarity == "resource":
				txt = ResourceKinds.mismatch_message(
					_wire_src_resource_kind, str(_wire_snap.get("resource_kind", "")))
			else:
				txt = "Can't connect here — %s is the wrong polarity" % target
			col = Color(0.95, 0.45, 0.45, 0.95)
	else:
		txt = "Drag to a port — or drop on a tank to add a port"
	# Touch gestures are only worth naming to someone using touch.
	var hint := "Alt+drag a tank port to rotate it · Esc cancels"
	if _touch_input_active():
		hint = "Drag ports or nodes · two fingers pan"
	var w1 := fnt.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var w2 := fnt.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1).x
	var plate_sz := Vector2(maxf(w1, w2) + 16.0, float(fs) * 2.0 + 16.0)
	var plate := Rect2(_feedback_plate_origin(_interaction.last_pointer_pos, snap_pos, plate_sz), plate_sz)
	draw_rect(plate, Color(0.05, 0.08, 0.16, 0.9), true)
	draw_rect(plate, Color(0.26, 0.34, 0.50, 0.7), false, 1.0)
	var tp := plate.position + Vector2(8.0, float(fs) + 4.0)
	draw_string(fnt, tp, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	draw_string(fnt, tp + Vector2(0.0, float(fs) + 4.0), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1,
		Color(0.75, 0.83, 0.95, 0.82))


## Top-left of a hint plate near the pointer that never covers `avoid` (the
## port the wire is about to snap to — the plate used to sit right on it) and
## stays on the canvas.
func _feedback_plate_origin(pointer: Vector2, avoid: Vector2, plate_sz: Vector2) -> Vector2:
	var gap := 18.0
	# Default: above-right of the pointer.
	var o := pointer + Vector2(gap, -gap - plate_sz.y)
	if avoid != Vector2.INF:
		var d := pointer - avoid
		# Put the plate on the far side of the pointer from the target.
		o.x = pointer.x + gap if d.x >= 0.0 else pointer.x - gap - plate_sz.x
		o.y = pointer.y + gap if d.y >= 0.0 else pointer.y - gap - plate_sz.y
		if Rect2(o, plate_sz).grow(10.0).has_point(avoid):
			o.y = avoid.y - gap - plate_sz.y if d.y < 0.0 else avoid.y + gap
	o.x = clampf(o.x, 4.0, maxf(4.0, size.x - plate_sz.x - 4.0))
	o.y = clampf(o.y, 4.0, maxf(4.0, size.y - plate_sz.y - 4.0))
	return o


func _draw_v2_hover_port_tooltip() -> void:
	if _hover_port.is_empty():
		return
	var fnt := UITheme.font("medium")
	var fs := UITheme.FONT_XS + 1
	var item_id := _hover_port.get("item_id", "") as String
	var handle_id := _hover_port.get("handle_id", "") as String
	var rk := str(_hover_port.get("resource_kind", ""))
	if item_id.is_empty() or handle_id.is_empty() or model == null:
		return
	var hover_item := model.get_item(item_id)
	if hover_item.is_empty():
		# The node is gone (deleted, or the graph was reloaded — a bootcamp
		# level change): a stale hover used to read "Node · PV −" forever.
		_hover_port = {}
		return
	var txt := GraphPortLabels.port_label(hover_item, handle_id, rk)
	# What the resource is made of, one line under the name (CompositionCatalog).
	var made := CompositionCatalog.summary(rk) if not rk.is_empty() else ""
	var fs2 := UITheme.FONT_XS
	var ts := fnt.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var w := ts.x
	if not made.is_empty():
		w = maxf(w, fnt.get_string_size(made, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x)
	var sz := Vector2(w + 14.0, float(fs) + 10.0 + (float(fs2) + 3.0 if not made.is_empty() else 0.0))
	var port_pos := _hover_port.get("pos", Vector2.INF) as Vector2
	var rect := Rect2(_feedback_plate_origin(_interaction.last_pointer_pos, port_pos, sz), sz)
	draw_rect(rect, Color(0.05, 0.08, 0.16, 0.92), true)
	draw_rect(rect, Color(0.26, 0.34, 0.50, 0.85), false, 1.0)
	draw_string(fnt, rect.position + Vector2(7.0, float(fs) + 3.0), txt,
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.86, 0.91, 0.98, 0.97))
	if not made.is_empty():
		draw_string(fnt, rect.position + Vector2(7.0, float(fs) + float(fs2) + 6.0), made,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs2, Color(0.62, 0.70, 0.82, 0.95))


func _render_item(item: Dictionary) -> void:
	# Site Plan / Elevation: always use map-scaled plan chips from the base
	# canvas. V2 freeform bodies (especially solar-array compounds) size cells
	# with GraphArrayLayout.PANEL_* × zoom, which ignores physical footprints and
	# leaves a tiny hit rect under a huge visual — blocking drag/resize.
	if _is_physical_view():
		super._render_item(item)
		return
	if show_as_models and _node_model_id(item) != "":
		if _v3_on() and _model_stage_has(str(item.get("id", ""))):
			_render_model_anchor(item)
		else:
			_render_model_picture(item)
		_draw_overlay_outline(item)
		_draw_twin_badge(item)
		_draw_open_loop_badge(item)
		return
	var iid := item.get("id", "") as String
	# Hide legacy aggregate panel card in V2; individual virtual panel nodes replace it.
	if iid == "virtual_solar_array":
		return
	var itype0 := str(item.get("type", ""))
	if unified_cards and GraphCardSpecs.handles(itype0):
		var sp0: Dictionary = item.get("specs", {}) as Dictionary
		# Model-thumbnail controllers and loads keep their full-bleed picture;
		# every other type draws the card, its picture (if any) in the card's
		# media zone.
		if itype0 not in ["controller", "appliance", "acload"] or not _icon_replaces_frame(sp0):
			_render_card_v2(item)
			_draw_overlay_outline(item)
			_draw_twin_badge(item)
			_draw_open_loop_badge(item)
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


## One shared card anatomy (GraphCard) — see GraphCardSpecs for what it says.
func _render_card_v2(item: Dictionary) -> void:
	var center := size * 0.5
	var tl := _item_screen_tl(item, center)
	var sz := _item_screen_size(item)
	var iid := str(item.get("id", ""))
	var itype := str(item.get("type", ""))
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	# Per-item live context (the one dict is reused; these keys are per card).
	_card_ctx["live_w"] = -1.0
	_card_ctx["peak_w"] = -1.0
	_card_ctx["agg_soc"] = -1.0
	if itype == "processor" or itype == "appliance" or itype == "acload" \
			or (itype == "compound" and _is_load_group_item(item)):
		var tree := get_tree()
		if tree != null and model != null:
			_card_ctx["live_w"] = GraphAcLoad.sum_load_group_watts(model, item, tree, null, true) \
				if itype == "compound" else GraphAcLoad.item_draw_watts(model, item, tree, _find_sim_load_host())
			var bus := tree.root.get_node_or_null("AcPowerBus") if tree.root != null else null
			if bus != null and "load_by_item" in bus:
				var rec: Variant = (bus.get("load_by_item") as Dictionary).get(iid, {})
				if rec is Dictionary and float((rec as Dictionary).get("peak_w", -1.0)) >= 0.0:
					_card_ctx["peak_w"] = float((rec as Dictionary).get("peak_w", -1.0))
	elif itype == "compound" and _compound_displays_as_battery(specs):
		_card_ctx["agg_soc"] = _aggregate_child_battery_soc(item)
	_card_ctx["sys_level"] = str(system_status.get(iid, ""))
	_card_ctx["sys_reason"] = str(system_reasons.get(iid, ""))
	_card_ctx["ac_out_w"] = controller_ac_out_w(item) if itype == "controller" else -1.0
	_card_ctx.erase("array_live_w")
	_card_ctx.erase("array_peak_w")
	_card_ctx.erase("array_count")
	if GraphSolarArrays.is_materialized(item):
		var ai := _array_info(item)
		_card_ctx["array_peak_w"] = float(ai.get("peak_w", 0.0))
		_card_ctx["array_count"] = int(ai.get("count", 0))
		if float(ai.get("live_w", -1.0)) >= 0.0:
			_card_ctx["array_live_w"] = float(ai.get("live_w", 0.0))
	var spec := GraphCardSpecs.for_item(item, _card_ctx)
	spec["selected"] = (iid == selected_item_id) or selected_item_ids.has(iid)
	if bool(item.get("is_ghost", false)) or (not _path_items.is_empty() and not _path_items.has(iid)):
		spec["dim"] = true
	# Semantic zoom for systems (Phase 2): a camp / vehicle far out is a
	# festival TILE; close in, the card shows its real interior (the peek).
	if itype == "compound":
		if not GraphSystems.island_kind(item).is_empty() and sz.x < TILE_MAX_PX:
			_draw_system_tile(item, Rect2(tl, sz), bool(spec["selected"]))
			return
		if draws_peek(item, Rect2(tl, sz)):
			_draw_card_peek(item, Rect2(tl, sz), spec)
			_draw_item_handles(item, tl, sz)
			return
	if bool(spec.get("hub", false)):
		GraphCard.draw_hub(self, Rect2(tl, sz), _zoom, spec)
		var r := GraphHubPorts.circle_radius(sz)
		_draw_tank_overflow_glyph(specs, GraphHubPorts.circle_center(tl, sz) + Vector2(r * 0.85, -r * 0.7))
		_draw_item_handles(item, tl, sz)
		return
	var res := GraphCard.draw(self, Rect2(tl, sz), _zoom, spec)
	if res.has("action_rect"):
		# The RESET button: _on_lmb_press handles every rect in this dict.
		_controller_reset_rects[iid] = res["action_rect"]
	if res.has("media_rect"):
		_draw_card_media(item, specs, str(spec.get("media", "")), res["media_rect"] as Rect2,
			spec.get("accent", GraphTheme.TEXT_DIM) as Color, str(spec.get("icon", "box")))
	_draw_item_handles(item, tl, sz)
	_draw_port_annotations(item)


# ---------------------------------------------------------------------------
# Systems at festival scale (plans/GRAPH_SYSTEMS_UX_PLAN.md Phase 2).
# Far out a camp or vehicle card is a TILE: a status ring (power / water /
# food / people, GraphSystems.ring), its icon and a decluttered name. Close
# in, any group card draws its real interior inside itself at its true
# layout (the PEEK), with exactly the mapping the scope swap starts from.
# ---------------------------------------------------------------------------
## On-screen card width below which a system card is a tile.
const TILE_MAX_PX := 96.0
## A tile never shrinks below this radius (a festival stays readable).
const TILE_MIN_R := 11.0
## On-screen card width from which a group card shows its live interior.
const PEEK_MIN_PX := 340.0
## A group with more inside than this keeps its plain card (cost).
const PEEK_MAX_ITEMS := 80
const RING_COLORS := GraphTheme.LEVELS
## Ring arc -> channel (GraphSystems.RING_KEYS order): a calm arc wears its
## channel's colour, a troubled one its level's.
const RING_CHANNELS := ["power", "water", "food", "people"]
const RING_RANK := {"crit": 3, "warn": 2, "ok": 1, "idle": 0}
var _tile_labels: Array = []
## "Colour systems by" (Phase 3): {mode, values: {system id: float}, hidden:
## {bin: true}}, pushed by the view once a second. {} or mode "none" = off.
var system_overlay: Dictionary = {}


## {on, color, hidden} for one system under the current overlay.
func _overlay_for(id: String) -> Dictionary:
	var mode := str(system_overlay.get("mode", "none"))
	if mode == "none":
		return {"on": false}
	var vals: Dictionary = system_overlay.get("values", {}) as Dictionary
	if not vals.has(id):
		return {"on": false}
	var v := float(vals[id])
	var b := GraphSystemBoard.overlay_bin(mode, v)
	var hidden: Dictionary = system_overlay.get("hidden", {}) as Dictionary
	return {"on": true, "color": GraphSystemBoard.overlay_color(mode, v),
		"hidden": b >= 0 and hidden.has(b)}


## Festival trunks (Phase 5): at the site level, when one node (a water
## depot, a shared battery) is wired to three or more systems drawn as tiles,
## its wires become ONE trunk to the middle of those tiles and thin branches
## from there, in the channel's colour, with one bead stream scaled by the
## total flow. Per channel, so water and power to the same camps stay apart.
const TRUNK_MIN := 3
var _trunks: Array = []      # [{src, hub, tiles: [Vector2], col, n, flow}]
var trunks_drawn := 0


func _plan_trunks(visible: Array, center: Vector2, solar_w: float, load_w: float) -> Dictionary:
	_trunks.clear()
	var out: Dictionary = {}
	if view_mode != GraphSiteLayout.VIEW_FREEFORM or active_scope_id != GraphModel.ROOT_SCOPE_ID \
			or model == null or visible.size() < TRUNK_MIN:
		return out
	var groups: Dictionary = {}   # "hub|channel" -> {hub, ch, conns: [], tiles: []}
	for conn: Dictionary in visible:
		var sid := str(conn.get("source_item_id", ""))
		var tid := str(conn.get("target_item_id", ""))
		var a := model.get_item(sid)
		var b := model.get_item(tid)
		if a.is_empty() or b.is_empty():
			continue
		var a_tile := _is_tile(a)
		var b_tile := _is_tile(b)
		if a_tile == b_tile:
			continue
		var hub: Dictionary = b if a_tile else a
		var tile: Dictionary = a if a_tile else b
		var ch := "power" if str(conn.get("polarity", "")) != "resource" \
			else GraphTheme.channel_of_kind(str(conn.get("resource_type", "")))
		# Under a flow style, one trunk per RESOURCE (its own unit), never
		# watts and litres added together.
		var fkey := ch
		if _ribbons_on():
			fkey = str(_flow_est_for(conn, solar_w, load_w).get("_flow_key", ch))
		var key := "%s|%s" % [str(hub.get("id", "")), fkey]
		var g: Dictionary = groups.get(key, {})
		if g.is_empty():
			g = {"hub": hub, "ch": ch, "conns": [], "tiles": []}
			groups[key] = g
		(g["conns"] as Array).append(conn)
		(g["tiles"] as Array).append(tile)
	for key: String in groups.keys():
		var g: Dictionary = groups[key]
		if (g["conns"] as Array).size() < TRUNK_MIN:
			continue
		var hub: Dictionary = g["hub"]
		var src := _item_screen_tl(hub, center) + _item_screen_size(hub) * 0.5
		var pts: Array = []
		var mid := Vector2.ZERO
		for t: Dictionary in (g["tiles"] as Array):
			var p := _item_screen_tl(t, center) + _item_screen_size(t) * 0.5
			pts.append(p)
			mid += p
		mid /= float(pts.size())
		var flow := 0.0
		var vals: Array = []
		var fk := ""
		for conn: Dictionary in (g["conns"] as Array):
			out[str(conn.get("id", ""))] = true
			var est := _flow_est_for(conn, solar_w, load_w)
			flow += absf(float(est.get("watts", 0.0)))
			vals.append(float(est.get("_flow_value", 0.0)))
			fk = str(est.get("_flow_key", ""))
		var tcol := GraphTheme.channel(str(g["ch"]))
		if _ribbons_on() and fk != "" and fk != "electricity" and not fk.begins_with("element:"):
			tcol = ResourceKinds.wire_color(fk)
		_trunks.append({"src": src, "hub": src.lerp(mid, 0.72), "tiles": pts,
			"col": tcol, "n": pts.size(), "flow": flow, "vals": vals, "key": fk})
	return out


func _is_tile(item: Dictionary) -> bool:
	return str(item.get("type", "")) == "compound" and not GraphSystems.island_kind(item).is_empty() \
		and _item_screen_size(item).x < TILE_MAX_PX


func _draw_trunks() -> void:
	trunks_drawn = _trunks.size()
	if _ribbons_on():
		_draw_trunks_ribbon()
		return
	for t: Dictionary in _trunks:
		var col: Color = t["col"]
		var src: Vector2 = t["src"]
		var hub: Vector2 = t["hub"]
		var n := int(t["n"])
		var w := clampf(2.0 + log(float(n)) * 1.6, 2.5, 9.0)
		draw_line(src, hub, Color(col, 0.22), w + 4.0, true)
		draw_line(src, hub, Color(col, 0.85), w, true)
		GraphFastDraw.disc(self, hub, w * 0.7, Color(col, 0.9))
		for p: Variant in (t["tiles"] as Array):
			draw_line(hub, p as Vector2, Color(col, 0.38), 1.2, true)
		# One bead stream along the trunk, as many beads as the flow carries
		# (log scale); they move with the flow animation (the clock rule).
		if _flow_live and float(t["flow"]) > 0.0:
			_flowing_drawn = true
			var beads := clampi(2 + int(log(1.0 + float(t["flow"])) * 1.2), 2, 14)
			var length := src.distance_to(hub)
			for i in beads:
				var u := fposmod(_flow_phase / TAU * maxf(1.0, length / 120.0) + float(i) / float(beads), 1.0)
				GraphFastDraw.disc(self, src.lerp(hub, u), maxf(2.0, w * 0.45), Color(1, 1, 1, 0.85))


## Trunks under a flow style: the trunk is as wide as everything it carries
## (Sankey), each branch as wide as its own wire, all moving with the flow.
func _draw_trunks_ribbon() -> void:
	for t: Dictionary in _trunks:
		var col: Color = t["col"]
		var src: Vector2 = t["src"]
		var hub: Vector2 = t["hub"]
		var key := str(t.get("key", ""))
		var vals: Array = t.get("vals", [])
		var total := 0.0
		for v in vals:
			total += float(v)
		var ref := float(_flow_refs.get(key, total))
		# The trunk carries the sum: measure it against the sum's own scale
		# so it is never narrower than the branches it splits into.
		var ref_t := maxf(ref, total)
		var w_t := GraphFlowStyle.width_px(flow_style, total, ref_t, total > 0.0, _zoom)
		var live := _flow_live and total > 0.0
		if live:
			_flowing_drawn = true
		var anim := str(flow_style.get("anim", GraphFlowStyle.ANIM_STREAKS))
		GraphFlowRibbons.draw(get_canvas_item(), PackedVector2Array([src, hub]), {
			"width": w_t, "color": col, "active": live, "anim": anim, "t": _flow_clock,
			"speed": GraphFlowStyle.anim_speed_px(flow_style, total, ref_t),
			"look": _flow_look, "blur": _high_speed_lod})
		var tiles: Array = t["tiles"]
		for i in tiles.size():
			var v := float(vals[i]) if i < vals.size() else 0.0
			var w_b := GraphFlowStyle.width_px(flow_style, v, ref_t, v > 0.0, _zoom)
			GraphFlowRibbons.draw(get_canvas_item(), PackedVector2Array([hub, tiles[i] as Vector2]), {
				"width": w_b, "color": col, "active": _flow_live and v > 0.0, "anim": anim,
				"t": _flow_clock, "speed": GraphFlowStyle.anim_speed_px(flow_style, v, ref_t),
				"look": _flow_look, "glow": 0.0, "far": true})
		GraphFastDraw.disc(self, hub, maxf(3.0, w_t * 0.6), Color(col, 0.95))


## The twin badge (Phase 4): a small chip on a card's top edge saying what
## ties the node to the world — a 3D twin, a place on the map, its camp's or
## vehicle's place, or nothing (graph only). Clicking it Locates the twin.
const TWIN_BADGE_MIN_PX := 120.0
const TWIN_BADGE := {
	"3d": ["box", Color(0.40, 0.82, 0.95), "Has a 3D twin: click to look at it"],
	"map": ["map-pin", Color(0.98, 0.78, 0.40), "Placed on the map (no 3D object): click to look there"],
	"owner": ["map-pin", Color(0.70, 0.74, 0.82), "Inside a camp or vehicle: click to look at it"],
	"none": ["", Color(0.50, 0.54, 0.62), "Graph only: it has no place in the world yet"],
}


func _draw_twin_badge(item: Dictionary) -> void:
	if view_mode != GraphSiteLayout.VIEW_FREEFORM or bool(item.get("is_virtual", false)):
		return
	var sz := _item_screen_size(item)
	if sz.x < TWIN_BADGE_MIN_PX:
		return
	var kind := GraphSystems.twin_kind(model, item)
	var meta: Array = TWIN_BADGE[kind]
	var tl := _item_screen_tl(item, size * 0.5)
	# Just outside the card's right edge at the header: the top and bottom
	# edges carry the ports and their names.
	var r := Rect2(Vector2(tl.x + sz.x + 3.0, tl.y + 8.0), Vector2(20.0, 16.0))
	var col: Color = meta[1]
	GraphFastDraw.rrect(self, r, 6.0, Color(0.04, 0.06, 0.10, 0.94))
	draw_rect(r, Color(col, 0.75), false, 1.0)
	if str(meta[0]).is_empty():
		draw_arc(r.get_center(), 4.0, 0.0, TAU, 14, Color(col, 0.9), 1.2, true)
		draw_line(r.get_center() + Vector2(-3.0, 3.0), r.get_center() + Vector2(3.0, -3.0), Color(col, 0.9), 1.2)
	else:
		var tex := UiIcons.icon(str(meta[0]), 12)
		draw_texture_rect(tex, Rect2(r.get_center() - Vector2(6.0, 6.0), Vector2(12.0, 12.0)), false, col)
	_twin_badge_rects[str(item.get("id", ""))] = r


## Freeform site inset (Phase 4): every system as a dot where it stands on the
## map, the site's own system at home, the ones on screen ringed. A click
## flies there. Only while systems exist and the inset is on.
const INSET_SIZE := Vector2(210.0, 150.0)


func _draw_site_inset() -> void:
	if not site_inset or view_mode != GraphSiteLayout.VIEW_FREEFORM or model == null or system_status.is_empty():
		return
	var pts: Array = [["", Vector2.ZERO]]
	var lo := Vector2.ZERO
	var hi := Vector2.ZERO
	for id: String in system_status.keys():
		var it := model.get_item(id)
		if it.is_empty() or not GraphSiteLayout.has_site_coords(it):
			continue
		var p := GraphSiteLayout.site_xz(it)
		pts.append([id, p])
		lo = lo.min(p)
		hi = hi.max(p)
	if pts.size() < 2:
		return
	var box := Rect2(Vector2(size.x - INSET_SIZE.x - 14.0, size.y - INSET_SIZE.y - 62.0), INSET_SIZE)
	if _legend_visible:
		box.position.y -= 210.0
	_inset_rect = box
	GraphFastDraw.rrect(self, box, 8.0, Color(0.03, 0.05, 0.09, 0.88))
	draw_rect(box, Color(0.30, 0.38, 0.52, 0.8), false, 1.0)
	var fnt := UITheme.font("semibold")
	draw_string(fnt, box.position + Vector2(8.0, 14.0), "Site map", HORIZONTAL_ALIGNMENT_LEFT, -1, 10,
		Color(0.62, 0.68, 0.78))
	var inner := Rect2(box.position + Vector2(12.0, 22.0), box.size - Vector2(24.0, 32.0))
	var span := (hi - lo).max(Vector2(20.0, 20.0))
	var k := minf(inner.size.x / span.x, inner.size.y / span.y)
	var off := inner.get_center() - (lo + hi) * 0.5 * k
	var view := Rect2(Vector2.ZERO, size)
	var here := ""
	if active_scope_id != GraphModel.ROOT_SCOPE_ID:
		here = str(GraphSystems.island_scopes(model).get(active_scope_id, ""))
	for d: Array in pts:
		var id := str(d[0])
		var q := off + (d[1] as Vector2) * k
		_inset_dots.append([id, q])
		if id.is_empty():
			GraphFastDraw.disc(self, q, 4.5, Color(0.40, 0.82, 0.95))
			continue
		var col: Color = SYSTEM_LEVEL_COLORS.get(str(system_status.get(id, "idle")), Color.WHITE)
		GraphFastDraw.disc(self, q, 3.0, col)
		var on_screen := false
		if active_scope_id == GraphModel.ROOT_SCOPE_ID:
			var it := model.get_item(id)
			on_screen = view.intersects(Rect2(_item_screen_tl(it, size * 0.5), _item_screen_size(it)))
		if on_screen:
			GraphFastDraw.ring(self, q, 5.0, Color(1, 1, 1, 0.55), 1.0)
		if id == here or id == selected_item_id:
			GraphFastDraw.ring(self, q, 6.5, Color(1, 1, 1, 0.95), 1.5)


## A system card (not a tile) under an overlay: a thick outline in its colour.
func _draw_overlay_outline(item: Dictionary) -> void:
	if str(item.get("type", "")) != "compound" or GraphSystems.island_kind(item).is_empty():
		return
	var o := _overlay_for(str(item.get("id", "")))
	if not bool(o.get("on", false)):
		return
	var r := Rect2(_item_screen_tl(item, size * 0.5), _item_screen_size(item))
	if r.size.x < TILE_MAX_PX:
		return
	var col: Color = o["color"]
	if bool(o["hidden"]):
		GraphFastDraw.rrect(self, r, 10.0, Color(0.03, 0.04, 0.07, 0.62))
		return
	draw_rect(r.grow(3.0), Color(col, 0.95), false, 4.0)


## Site Plan under an overlay: a tinted disc where each system stands.
func _draw_system_overlay_site() -> void:
	if view_mode != GraphSiteLayout.VIEW_SITE or str(system_overlay.get("mode", "none")) == "none":
		return
	if model == null or active_scope_id != GraphModel.ROOT_SCOPE_ID:
		return
	var origin: Vector2 = get_soi_disc_layout().get("origin", size * 0.5) as Vector2
	var ppm := GraphSiteLayout.px_per_m(_zoom)
	for it in model.get_items_in_scope(GraphModel.ROOT_SCOPE_ID):
		var d: Dictionary = it
		if GraphSystems.island_kind(d).is_empty() or not GraphSiteLayout.has_site_coords(d):
			continue
		var o := _overlay_for(str(d.get("id", "")))
		if not bool(o.get("on", false)) or bool(o["hidden"]):
			continue
		var p: Variant = _site_point_canvas(origin, GraphSiteLayout.site_xz(d))
		if p == null:
			continue
		var rad := clampf(GraphSystems.island_radius_m(d) * ppm, 9.0, 160.0)
		var col: Color = o["color"]
		GraphFastDraw.disc(self, p as Vector2, rad, Color(col, 0.28))
		GraphFastDraw.ring(self, p as Vector2, rad, Color(col, 0.9), 2.0)
## Per draw: system card id -> half the screen distance to its nearest
## system card, so the minimum tile size never makes neighbours overlap.
var _tile_room: Dictionary = {}
var _tile_room_key := ""


func _tile_room_for(item_id: String) -> float:
	var key := "%d|%.5f|%s" % [Engine.get_frames_drawn(), _zoom, str(_pan)]
	if key != _tile_room_key:
		_tile_room_key = key
		_tile_room.clear()
		var pts: Array = []
		for it in model.get_items_in_scope(active_scope_id):
			var d: Dictionary = it
			if GraphSystems.is_power_island(d):
				pts.append([str(d.get("id", "")), Vector2(float(d.get("x", 0.0)) + float(d.get("width", 220.0)) * 0.5,
					float(d.get("y", 0.0)) + float(d.get("height", 150.0)) * 0.5) * _zoom])
		for i in pts.size():
			var best := INF
			for j in pts.size():
				if i != j:
					best = minf(best, (pts[i][1] as Vector2).distance_to(pts[j][1] as Vector2))
			_tile_room[pts[i][0]] = best * 0.5 - 1.0
	return float(_tile_room.get(item_id, INF))


func draws_peek(item: Dictionary, screen_rect: Rect2) -> bool:
	if not unified_cards or view_mode != GraphSiteLayout.VIEW_FREEFORM:
		return false
	if screen_rect.size.x < PEEK_MIN_PX or str(item.get("type", "")) != "compound":
		return false
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	if str(sp.get("compound_kind", "")) != "" or _compound_displays_as_battery(sp):
		return false
	if bool(sp.get("node_banner", false)) and not str(sp.get("model_id", "")).is_empty():
		return false
	var cs := str(item.get("child_scope_id", ""))
	if cs.is_empty() or model == null:
		return false
	var n := model.get_items_in_scope(cs).size()
	return n > 0 and n <= PEEK_MAX_ITEMS


func _draw_system_tile(item: Dictionary, rect: Rect2, selected: bool) -> void:
	var c := rect.get_center()
	var own := minf(rect.size.x, rect.size.y) * 0.5
	var r := maxf(own, minf(TILE_MIN_R, _tile_room_for(str(item.get("id", "")))))
	r = maxf(r, 4.0)
	# Breathing (Phase 5): a system that is charging swells a little, slowly,
	# each on its own beat; still when the clock is (motion rule).
	var live: Array = system_live.get(str(item.get("id", "")), []) as Array
	if live.size() >= 2 and float(live[1]) > 0.02 and _sim_flow_mult > 0.0:
		var seed := float(hash(str(item.get("id", ""))) % 997) / 997.0
		r *= 1.0 + 0.035 * sin(_alert_phase * 0.8 + seed * TAU)
		_alert_seen_this_draw = true
	var kind := GraphSystems.island_kind(item)
	var power: Dictionary = (live_power_hint.get("vehicles", {}) as Dictionary).get(str(item.get("id", "")), {})
	var ring := GraphSystems.ring(model, item, power)
	GraphFastDraw.disc(self, c + Vector2(0.0, 2.0), r, GraphTheme.CARD_SHADOW)
	GraphFastDraw.disc(self, c, r, GraphTheme.CARD_BG)
	var ov := _overlay_for(str(item.get("id", "")))
	if bool(ov.get("on", false)):
		GraphFastDraw.disc(self, c, r * 0.86, Color(ov["color"] as Color, 0.62))
	var w := maxf(2.0, r * 0.2)
	var worst := "idle"
	for i in GraphSystems.RING_KEYS.size():
		var lvl := str(ring.get(GraphSystems.RING_KEYS[i], "idle"))
		if int(RING_RANK[lvl]) > int(RING_RANK[worst]):
			worst = lvl
		# Quarter arcs from the top, clockwise, a small gap between.
		var a0 := -PI * 0.5 + i * PI * 0.5 + 0.12
		var acol: Color = RING_COLORS[lvl]
		if lvl == "ok":
			acol = GraphTheme.channel(RING_CHANNELS[i])
		elif lvl in ["warn", "crit"]:
			var m := GraphTheme.level_motion(lvl, _status_t()) if _sim_flow_mult > 0.0 else 1.0
			acol = Color(acol, m)
			if _sim_flow_mult > 0.0:
				_alert_seen_this_draw = true
		draw_arc(c, r - w * 0.5, a0, a0 + PI * 0.5 - 0.24, 10, acol, w, true)
	# The battery's charge as a thin inner arc in the power channel's colour.
	if live.size() >= 1 and float(live[0]) >= 0.0 and r >= 9.0:
		var rr := r - w - 1.5
		draw_arc(c, rr, PI * 0.5, PI * 0.5 + TAU * clampf(float(live[0]), 0.0, 1.0), 20,
			Color(GraphTheme.channel("power"), 0.75), maxf(1.0, w * 0.45), true)
	var accent := Color(0.94, 0.62, 0.36) if kind == GraphSystems.KIND_CAMP else Color(0.45, 0.75, 0.95)
	GraphCard._draw_icon(self, "tent" if kind == GraphSystems.KIND_CAMP else "truck", c, r * 0.95, accent)
	if selected:
		GraphFastDraw.ring(self, c, r + 3.0, GraphTheme.SELECTED, 2.0)
	if bool(ov.get("on", false)) and bool(ov["hidden"]):
		# Filtered out on the legend: the tile stays (where it is matters)
		# but goes dark, and its name is not drawn.
		GraphFastDraw.disc(self, c, r + 1.0, Color(0.03, 0.04, 0.07, 0.72))
		return
	var sp: Dictionary = item.get("specs", {}) as Dictionary
	_tile_labels.append({"name": str(sp.get("name", item.get("label", ""))), "c": c, "r": r,
		"rank": int(RING_RANK[worst]) + (10 if selected else 0), "color": RING_COLORS[worst]})


## Names under the tiles, most urgent first; a name that would land on
## another name or another tile is left out (hover / the outliner name it).
func _draw_tile_labels() -> void:
	if _tile_labels.is_empty():
		return
	var discs: Array[Rect2] = []
	for t: Dictionary in _tile_labels:
		discs.append(Rect2(t["c"] - Vector2(t["r"], t["r"]), Vector2(t["r"], t["r"]) * 2.0))
	var order := _tile_labels.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["rank"]) != int(b["rank"]):
			return int(a["rank"]) > int(b["rank"])
		return float(a["r"]) > float(b["r"]))
	var fnt := UITheme.font("semibold")
	var fs := 11
	var placed: Array[Rect2] = []
	var view := Rect2(Vector2.ZERO, size)
	for t: Dictionary in order:
		var nm := UiText.fit(fnt, str(t["name"]), fs, 140.0, "festival tile name")
		if nm.is_empty():
			continue
		var tw := fnt.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var c: Vector2 = t["c"]
		var lr := Rect2(Vector2(c.x - tw * 0.5 - 4.0, c.y + float(t["r"]) + 3.0), Vector2(tw + 8.0, fs + 6.0))
		if not view.encloses(lr):
			continue
		var clash := false
		for p: Rect2 in placed:
			if p.intersects(lr):
				clash = true
				break
		if not clash:
			for d: Rect2 in discs:
				if d.intersects(lr) and not d.has_point(c):
					clash = true
					break
		if clash:
			continue
		placed.append(lr)
		GraphFastDraw.rrect(self, lr, lr.size.y * 0.5, Color(0.04, 0.06, 0.10, 0.82))
		var col: Color = t["color"]
		var tc := Color(0.9, 0.93, 0.98) if int(t["rank"]) % 10 <= 1 else col
		draw_string(fnt, Vector2(lr.position.x + 4.0, lr.end.y - 5.0), nm,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tc)


## The group card with its real interior drawn inside it: the header stays
## (name, chip), the body is the child canvas at its true layout, mapped
## exactly as finish_enter_transition will start it.
func _draw_card_peek(item: Dictionary, rect: Rect2, spec: Dictionary) -> void:
	var head := spec.duplicate()
	for k in ["hero", "sub", "footer", "bar", "fill", "media", "alert"]:
		head.erase(k)
	GraphCard.draw(self, rect, _zoom, head)
	var pr := card_peek_rect(rect)
	var cs := str(item.get("child_scope_id", ""))
	var gb := _scope_content_graph_bbox(cs)
	var m := _view_for_bbox_in_rect(gb, pr)
	if not bool(m.get("ok", false)):
		return
	var zc := float(m["zoom"])
	var origin := size * 0.5 + (m["pan"] as Vector2)
	GraphFastDraw.rrect(self, pr.grow(2.0), maxf(3.0, 6.0 * _zoom), Color(0.02, 0.035, 0.06, 0.55))
	var kids: Array = model.get_items_in_scope(cs)
	var rects: Dictionary = {}
	for k_v in kids:
		var k: Dictionary = k_v
		rects[str(k.get("id", ""))] = Rect2(origin + Vector2(float(k.get("x", 0.0)), float(k.get("y", 0.0))) * zc,
			Vector2(float(k.get("width", 120.0)), float(k.get("height", 90.0))) * zc)
	# Wires first: outputs leave the bottom edge, inputs arrive on the top.
	for c_v in model.get_connections_in_scope(cs):
		var cd: Dictionary = c_v
		var a: Variant = rects.get(str(cd.get("source_item_id", "")))
		var b: Variant = rects.get(str(cd.get("target_item_id", "")))
		if not (a is Rect2 and b is Rect2):
			continue
		var p0 := Vector2((a as Rect2).get_center().x, (a as Rect2).end.y)
		var p3 := Vector2((b as Rect2).get_center().x, (b as Rect2).position.y)
		var bend := maxf(30.0 * zc, absf(p3.y - p0.y) * 0.4)
		var rk := str(cd.get("resource_kind", ""))
		var col: Color = ResourceKinds.wire_color(rk) if not rk.is_empty() \
			else PORT_COLORS.get(str(cd.get("polarity", "")), C_PRIMARY) as Color
		col.a = 0.85 if bool(cd.get("flow_active", false)) else 0.45
		var pts := PackedVector2Array()
		for i in 13:
			var t := float(i) / 12.0
			var u := 1.0 - t
			pts.append(p0 * u * u * u + (p0 + Vector2(0, bend)) * 3.0 * u * u * t
				+ (p3 - Vector2(0, bend)) * 3.0 * u * t * t + p3 * t * t * t)
		draw_polyline(pts, col, maxf(1.0, 2.0 * zc), true)
	for k_v in kids:
		var k: Dictionary = k_v
		var kr: Rect2 = rects[str(k.get("id", ""))]
		if not kr.intersects(Rect2(Vector2.ZERO, size)):
			continue
		var kt := str(k.get("type", ""))
		if GraphCardSpecs.handles(kt):
			_card_ctx["live_w"] = -1.0
			_card_ctx["agg_soc"] = -1.0
			var ks := GraphCardSpecs.for_item(k, _card_ctx)
			if bool(ks.get("hub", false)):
				GraphCard.draw_hub(self, kr, zc, ks)
			else:
				GraphCard.draw(self, kr, zc, ks)
		else:
			var acc := NODE_BORDER_COLORS.get(kt, C_BORDER) as Color
			GraphFastDraw.rrect_box(self, kr, maxf(2.0, 8.0 * zc), GraphTheme.CARD_BG,
				Color(acc.r, acc.g, acc.b, 0.8), 1)
			GraphCard._draw_icon(self, GraphTheme.icon(kt), kr.get_center(),
				minf(kr.size.x, kr.size.y) * 0.5, acc)


## "You are inside X" in every lens: a soft frame in the system's colour and
## its name low on the canvas. Only the breadcrumb used to say where you were.
func _draw_inside_cue() -> void:
	if model == null or active_scope_id == "root":
		return
	var sc := model.get_scope(active_scope_id)
	var owner := model.get_item(str(sc.get("owner_compound_id", "")))
	if owner.is_empty():
		return
	var kind := GraphSystems.island_kind(owner)
	var accent := C_PRIMARY
	var icon := "box"
	if kind == GraphSystems.KIND_CAMP:
		accent = Color(0.94, 0.62, 0.36)
		icon = "tent"
	elif kind == GraphSystems.KIND_VEHICLE:
		accent = Color(0.45, 0.75, 0.95)
		icon = "truck"
	draw_rect(Rect2(Vector2(3.0, 3.0), size - Vector2(6.0, 6.0)),
		Color(accent.r, accent.g, accent.b, 0.30), false, 4.0)
	var nm := str((owner.get("specs", {}) as Dictionary).get("name", sc.get("title", "")))
	if nm.is_empty():
		return
	var fnt := UITheme.font("semibold")
	var fs := 22
	var text := "Inside %s" % nm
	var tw := fnt.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var y := size.y - 118.0
	GraphCard._draw_icon(self, icon, Vector2(30.0, y - fs * 0.35), float(fs) + 4.0,
		Color(accent.r, accent.g, accent.b, 0.55))
	draw_string(fnt, Vector2(48.0, y), text, HORIZONTAL_ALIGNMENT_LEFT, minf(tw + 4.0, size.x - 60.0), fs,
		Color(accent.r, accent.g, accent.b, 0.55))


## Port names beside the dots (zoomed in) and a wire count on any port that
## carries more than one wire. A name grows OUTWARD along its edge (left of a
## port on the left half, right of one on the right half) and is cut at the
## next port that way, so neighbouring names never collide; it sits just
## outside the card, where the port band is.
func _draw_port_annotations(item: Dictionary) -> void:
	var iid := str(item.get("id", ""))
	var names := port_names and _zoom >= PORT_NAME_MIN_ZOOM
	if not names and not (_card_ctx.get("multi", {}) as Dictionary).has(iid):
		return
	var counts: Dictionary = _card_ctx.get("wired", {})
	var infos := _get_interactive_handle_infos(item, size * 0.5)
	if infos.is_empty():
		return
	var fnt := UITheme.font("medium")
	var fs := clampi(int(round(9.0 * _zoom)), 8, 13)
	var dot_r := 6.8 * _zoom
	var plate := Color(0.03, 0.05, 0.09, 0.82)
	for h: Dictionary in infos:
		if bool(h.get("hub", false)):
			continue
		var pos: Vector2 = h["pos"]
		var tan: Vector2 = h.get("tangent", Vector2.UP)
		if absf(tan.y) < 0.5:
			continue  # side ports (rare on cards): no room beside them
		var hid := str(h.get("handle_id", ""))
		# Which way along the edge is outward, and how far to the next port.
		var right := pos.x >= _item_screen_tl(item, size * 0.5).x + _item_screen_size(item).x * 0.5
		var room := 220.0 * _zoom
		for o: Dictionary in infos:
			var op: Vector2 = o["pos"]
			if o == h or absf(op.y - pos.y) > 2.0:
				continue
			var dx := op.x - pos.x
			if (right and dx > 0.0) or (not right and dx < 0.0):
				room = minf(room, absf(dx) - dot_r * 2.0 - 4.0)
		var n := int(counts.get(iid + "|" + hid, 0))
		var mid_y := pos.y + tan.y * (dot_r * 0.4 + float(fs) * 0.55)
		if n > 1:
			var br := maxf(6.0, 6.5 * _zoom)
			var bc := Vector2(pos.x + (-1.0 if right else 1.0) * (dot_r + br * 0.6), mid_y)
			GraphFastDraw.disc(self, bc, br, Color(0.10, 0.14, 0.24, 0.96))
			GraphFastDraw.ring(self, bc, br, Color(0.55, 0.66, 0.85, 0.9), 1.0)
			var bfs := clampi(int(br * 1.2), 8, 13)
			var nf := UITheme.font("semibold", true)
			var t := str(n)
			var tw := nf.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
			draw_string(nf, Vector2(bc.x - tw * 0.5, bc.y + bfs * 0.36), t,
				HORIZONTAL_ALIGNMENT_LEFT, -1, bfs, Color(0.92, 0.95, 1.0))
		if not names or room < 18.0:
			continue
		var p_raw := GraphPortLabels.port_name(hid, str(h.get("resource_kind", "")))
		var p_fs := fs
		while p_fs > 8 and fnt.get_string_size(p_raw, HORIZONTAL_ALIGNMENT_LEFT, -1, p_fs).x > room - 6.0:
			p_fs -= 1
		var label := UiText.fit(fnt, p_raw, p_fs, room - 6.0, "graph port name" if _zoom >= 0.78 else "")
		var lw := fnt.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, p_fs).x
		var x0 := pos.x + dot_r + 2.0 if right else pos.x - dot_r - 2.0 - lw - 6.0
		var r := Rect2(Vector2(x0, mid_y - float(p_fs) * 0.62), Vector2(lw + 6.0, float(p_fs) * 1.24))
		GraphFastDraw.rrect(self, r, r.size.y * 0.5, plate)
		draw_string(fnt, Vector2(r.position.x + 3.0, mid_y + float(p_fs) * 0.36), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, p_fs, Color(0.80, 0.86, 0.95, 0.95))


## The picture in a card's media zone: the GLB thumbnail, a group's miniature,
## a super-node's banner or the array's panel grid. A picture that is not ready
## (thumbnail still rendering, a group too small for its miniature) leaves the
## type icon on a quiet tile, so the card never flickers between layouts.
func _draw_card_media(item: Dictionary, specs: Dictionary, kind: String, zone: Rect2,
		accent: Color, icon: String) -> void:
	var drawn := false
	match kind:
		"preview":
			_draw_rounded_rect(zone, Color(0.04, 0.07, 0.12, 0.96), int(maxf(2.0, 6.0 * _zoom)),
				Color(accent.r, accent.g, accent.b, 0.30), 1)
			drawn = _draw_model_preview_zone(zone.grow(-maxf(1.0, 2.0 * _zoom)), specs, 1.0)
		"miniature":
			drawn = _draw_compound_miniature(zone, specs, item)
		"banner":
			drawn = _draw_compound_banner(zone, specs)
		"array":
			drawn = draw_array_cells(zone, specs, item, accent).size.x > 0.0
	if not drawn:
		var px := minf(zone.size.x, zone.size.y) * 0.5
		if px >= 10.0:
			GraphCard._draw_icon(self, icon, zone.get_center(), px, Color(accent.r, accent.g, accent.b, 0.35))


func _build_card_ctx() -> Dictionary:
	# "<item>|<handle>" → how many wires land there (a key exists = wired).
	var wired := {}
	var multi := {}
	var batteries := 0
	if model != null:
		for c in model.connections:
			var cd: Dictionary = c
			for side: String in ["source", "target"]:
				var iid := str(cd.get(side + "_item_id", ""))
				var key := "%s|%s" % [iid, cd.get(side + "_handle_id", "")]
				var n := int(wired.get(key, 0)) + 1
				wired[key] = n
				if n > 1:
					multi[iid] = true
		for it in model.get_items_in_scope(active_scope_id):
			if str((it as Dictionary).get("type", "")) in ["battery", "smartbattery"]:
				batteries += 1
	var bw := hint_battery_w(0.0)
	return {"wired": wired, "multi": multi, "battery_w": bw, "battery_count": batteries}


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
		# Three significant figures with an SI prefix, the prefix moving onto
		# the unit line: 1473946.5 L reads "1.47" over "ML" (it printed all
		# seven digits and a decimal, wider than the circle).
		var nice := UiText.num(qty, unit)
		var cut := nice.rfind(" ")
		if cut > 0:
			qty_str = nice.left(cut)
			unit = nice.substr(cut + 1)
		else:
			qty_str = nice

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
	
	# Every line fits the circle. The name WRAPS onto two balanced lines and
	# may shrink a little before anything is cut: "Stream Intake: Stream 2"
	# and "Pond Outlet Pipes" were ellipsized on one line at every zoom.
	var line_w := inner_r * 1.7
	var name_fit := _hub_name_lines(fnt, name, name_fsize, line_w)
	var name_lines: PackedStringArray = name_fit["lines"]
	name_fsize = int(name_fit["size"])
	# A name that cannot fit whole (a small circle at a far zoom) is drawn as
	# a CAPTION beside the circle instead — ports sit on the top and bottom
	# edges, the sides are free — and the circle keeps just the quantity.
	var fits_inside := bool(name_fit["fits"])
	if fits_inside:
		# Width alone is not enough: the stack's top lines sit where the
		# circle is narrower than line_w. Lay the stack out and test each
		# name line against the chord at its own height.
		var stack_h := float(name_fsize * name_lines.size()) \
				+ spacing * float(name_lines.size() - 1) + line_spacing \
				+ main_fsize + spacing + unit_fsize \
				+ ((line_spacing + flow_fsize) if flow_str != "" else 0.0)
		var y := hub_c.y - stack_h * 0.5
		for nl in name_lines:
			var dy := maxf(absf(y - hub_c.y), absf(y + name_fsize - hub_c.y))
			var chord := 2.0 * sqrt(maxf(inner_r * inner_r - dy * dy, 0.0)) * 0.94
			if fnt.get_string_size(nl, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize).x > chord:
				fits_inside = false
				break
			y += name_fsize + spacing
	if not fits_inside:
		var cap_fs := maxi(9, int(round(11.0 * _zoom)))
		var cap_pos := Vector2(hub_c.x + hub_r + 5.0 * _zoom,
				hub_c.y + fnt.get_ascent(cap_fs) * 0.5 - 1.0)
		var cap_col := Color(0.86, 0.88, 0.92, 0.92)
		draw_string_outline(fnt, cap_pos, name, HORIZONTAL_ALIGNMENT_LEFT, -1, cap_fs, 3, Color(0.03, 0.05, 0.09, 0.9))
		draw_string(fnt, cap_pos, name, HORIZONTAL_ALIGNMENT_LEFT, -1, cap_fs, cap_col)
		name_lines = PackedStringArray()
	var name_h := float(name_fsize * name_lines.size()) + spacing * float(maxi(name_lines.size() - 1, 0))
	var total_h := (name_h + line_spacing if not name_lines.is_empty() else 0.0) \
			+ main_fsize + spacing + unit_fsize
	if flow_str != "":
		total_h += line_spacing + flow_fsize

	var current_y := hub_c.y - total_h * 0.5
	qty_str = UiText.fit(fnt, qty_str, main_fsize, line_w, "resource_hub")
	flow_str = UiText.fit(fnt, flow_str, flow_fsize, line_w, "resource_hub")

	# Draw Name — each line fitted to the circle's chord at its own height
	# (the top of the stack is where the circle is narrowest).
	var c_name := Color(0.9, 0.9, 0.9, 0.9)
	for nl in name_lines:
		var dy := maxf(absf(current_y - hub_c.y), absf(current_y + name_fsize - hub_c.y))
		var chord := 2.0 * sqrt(maxf(inner_r * inner_r - dy * dy, 0.0)) * 0.94
		var line := UiText.fit(fnt, nl, name_fsize, minf(line_w, chord), "resource_hub")
		var ts_name := fnt.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize)
		var pos_name := Vector2(hub_c.x - ts_name.x * 0.5, current_y + fnt.get_ascent(name_fsize))
		draw_string(fnt, pos_name, line, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize, c_name)
		draw_string_outline(fnt, pos_name, line, HORIZONTAL_ALIGNMENT_LEFT, -1, name_fsize, maxi(1, int(round(1.0 * _zoom))), c_name)
		current_y += name_fsize + spacing
	if not name_lines.is_empty():
		current_y += line_spacing - spacing
	
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


## A resource hub's name as 1–2 lines that fit `width`: one line if it fits,
## else the word break that balances two lines best, shrinking the font by up
## to 20 % before giving up (the caller ellipsizes what still does not fit).
## Returns {lines: PackedStringArray, size: int, fits: bool}.
func _hub_name_lines(fnt: Font, name: String, size: int, width: float) -> Dictionary:
	var min_size := maxi(7, int(floor(float(size) * 0.8)))
	var words := name.split(" ", false)
	var fs := size
	while fs >= min_size:
		if fnt.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= width:
			return {"lines": PackedStringArray([name]), "size": fs, "fits": true}
		var best := PackedStringArray()
		var best_w := INF
		for i in range(1, words.size()):
			var a := " ".join(words.slice(0, i))
			var b := " ".join(words.slice(i))
			var w := maxf(fnt.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x,
					fnt.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
			if w < best_w:
				best_w = w
				best = PackedStringArray([a, b])
		if not best.is_empty() and best_w <= width:
			return {"lines": best, "size": fs, "fits": true}
		fs -= 1
	# Nothing fits whole: two lines at the smallest size (or one long word),
	# left for the caller to ellipsize.
	if words.size() > 1:
		var half := words.size() / 2
		return {"lines": PackedStringArray([" ".join(words.slice(0, half)),
				" ".join(words.slice(half))]), "size": min_size, "fits": false}
	return {"lines": PackedStringArray([name]), "size": min_size, "fits": false}


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
	draw_string_outline(fnt, tp, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, 2, Color(0.02, 0.06, 0.04, 0.85))
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
	if kind == "array" or kind == "pv_design":
		accent = Color(0.15, 0.76, 0.95, 1.0)
		var n := int(specs.get("array_panel_units", specs.get("panel_count", specs.get("child_count", 0))))
		title = "Solar Array · %d panels" % n if n > 0 else "Solar Array"
	elif kind == "battery_bank":
		accent = Color(0.17, 0.84, 0.52, 1.0)
		title = "Battery Bank"

	_draw_node_frame(rect, accent if is_sel else Color(accent.r * 0.85, accent.g * 0.85, accent.b * 0.85, 1.0))
	var title_h := _title_band_height(sz.y)
	_draw_title_band(rect, title_h, title, accent)
	var body := Rect2(tl + Vector2(0.0, title_h), sz - Vector2(0.0, title_h))

	if kind == "array" or kind == "pv_design":
		_draw_array_compound_body_v2(body, specs, item, accent)
	elif kind == "battery_bank":
		_draw_battery_bank_compound_body_v2(body, specs)
	else:
		_draw_compound_body(body, specs)

	_draw_item_handles(item, tl, sz)
	if is_sel:
		draw_rect(rect.grow(1.2), Color(0.13, 0.83, 0.93, 0.16), true)
		draw_rect(rect.grow(0.8), Color(0.13, 0.83, 0.93, 0.85), false, 1.2)


## The pre-card array body: the panels as they sit on the rack, then a meta
## line. Both array kinds draw through draw_array_cells.
func _draw_array_compound_body_v2(rect: Rect2, specs: Dictionary, item: Dictionary, accent: Color) -> void:
	var pad := GraphArrayLayout.BODY_PAD * _zoom
	var footer_h := GraphArrayLayout.FOOTER_H * _zoom
	draw_array_cells(Rect2(rect.position + Vector2(pad, pad),
		Vector2(rect.size.x - pad * 2.0, maxf(1.0, rect.size.y - pad * 2.0 - footer_h))), specs, item, accent)
	var info := _array_info(item)
	var topo := str(specs.get("array_topology", ""))
	if topo.is_empty():
		topo = "%dS x %dP" % [int(specs.get("design_series", 1)), int(specs.get("design_parallel", 1))]
	var fnt := ThemeDB.fallback_font
	var fs_meta := maxi(GraphNodeLabel.BODY_FONT_MIN, int(round(10.0 * _zoom)))
	draw_string(fnt, rect.position + Vector2(pad, rect.end.y - footer_h * 0.35),
			"%s  ·  %s  ·  %.0f W" % [topo, UiText.count(int(info.get("count", 0)), "panel"),
				float(info.get("peak_w", 0.0))],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs_meta, Color(0.82, 0.94, 1.0, 0.92))


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
	var touch := _touch_input_active() or touchscreen_available()
	var hover_hit := false
	if not _hover_port.is_empty():
		var hp := _hover_port.get("pos", Vector2(-9999.0, -9999.0)) as Vector2
		hover_hit = hp.distance_to(screen_pos) < maxf(8.0, 9.0 * _zoom)
	var pulse := 1.0 + (0.13 * sin(_flow_phase * 3.4)) if _flow_live else 1.0
	var r := maxf(5.5, 6.8 * _zoom) * pulse
	if touch:
		r = maxf(r, 10.5)
	if hover_hit:
		r *= 1.18
	var dc := is_dc_polarity(polarity)
	# Texture discs (GraphFastDraw): five draw_circle calls were ~45 µs a port.
	GraphFastDraw.disc(self, screen_pos, r + (6.0 if touch else 4.0), Color(col.r, col.g, col.b, 0.18))
	GraphFastDraw.disc(self, screen_pos, r + 1.8, Color(col.r, col.g, col.b, 0.34))
	GraphFastDraw.disc(self, screen_pos, r, dc_port_fill(col, polarity) if dc else col)
	# DC ports: solid disc + polarity glyph. The old 56%-radius background hole
	# left only a thin rim of colour, so at wide zoom the red + and the near-
	# black − were nearly the same dot. Other port kinds keep the donut.
	if not dc:
		GraphFastDraw.disc(self, screen_pos, r * 0.56, Color(0.06, 0.09, 0.17, 0.95))
	GraphFastDraw.ring(self, screen_pos, r + 0.4, V2_PORT_RING, 1.0)
	if dc:
		_draw_polarity_glyph(screen_pos, r, polarity)
	if touch:
		GraphFastDraw.ring(self, screen_pos, r + 8.0, Color(col.r, col.g, col.b, 0.10), 2.0)

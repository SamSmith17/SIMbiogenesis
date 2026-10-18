class_name HudLayout
extends Node

## The ONE place that decides where the always-on HUD goes. Before this, every
## panel hard-coded its own pixel offsets in its own _ready(), so the edit
## toolbar sat on the Power Scoreboard, the settlement HUD wrote text over it,
## Terrain options showed through the docks and the settlement log covered the
## timeline. Now panels REGISTER into a region and tools CLAIM screen space;
## HudLayoutCore (pure, selftested) solves the placement and this node
## applies it.
##
##   HudLayout.register(panel, "weather", "top_left", {order = 0, priority = 5,
##       compact = func(): return "56°F clear", icon = "sun"})
##   HudLayout.claim("edit_toolbar", {inset = {left = 104, top = 72},
##       tuck = ["top_left", "top_right"]})
##   HudLayout.release("edit_toolbar")
##
## A tucked panel becomes a pill (icon + one-line summary). Clicking the pill
## "peeks" the panel back until the pointer has been off it for a moment.
## Claims nest like the camera / clock claims: release() is per owner and
## idempotent. Visibility stays the PANEL's decision: the manager records
## what the panel itself wants (its own `visible` writes) and only overrides
## it while the panel is tucked or hidden by a claim.
##
## Lives under Main (registered as ServiceLocator key "hud_layout"); the
## static helpers no-op when there is no Main (selftests, the launch hub).

const KEY := &"hud_layout"
const PILL_H := 30.0
const PILL_MAX_W := 260.0
const PEEK_LINGER_S := 1.5
const PILL_REFRESH_S := 0.5

signal layout_changed

var _panels: Dictionary = {}     # id -> {node, region, opts, intent, pill}
var _claims: Dictionary = {}     # owner -> spec
var _peek: Dictionary = {}       # id -> seconds the pointer has been off it
var _setting := false
var _dirty := false
var _layer: CanvasLayer = null
var _pill_acc := 0.0
var _last: Dictionary = {}


# ---------------------------------------------------------------------------
# Static API (safe without a HUD: returns quietly)
# ---------------------------------------------------------------------------

## Registrations / claims made before the manager exists (scene panels are
## ready before Main is) wait here and are applied by its _ready.
static var _pending_panels: Array = []
static var _pending_claims: Dictionary = {}


static func get_hud() -> HudLayout:
	return ServiceLocator.service(KEY) as HudLayout


static func register(panel: Control, id: String, region: String, opts: Dictionary = {}) -> void:
	var h := get_hud()
	if h != null:
		h._register(panel, id, region, opts)
	else:
		_pending_panels.append([panel, id, region, opts])


static func unregister(id: String) -> void:
	var h := get_hud()
	if h != null:
		h._unregister(id)


static func claim(owner: String, spec: Dictionary) -> void:
	var h := get_hud()
	if h != null:
		h._claims[owner] = spec
		h.queue_layout()
	else:
		_pending_claims[owner] = spec


static func release(owner: String) -> void:
	_pending_claims.erase(owner)
	var h := get_hud()
	if h != null and h._claims.has(owner):
		h._claims.erase(owner)
		h._peek.clear()
		h.queue_layout()


static func has_claim(owner: String) -> bool:
	var h := get_hud()
	return h._claims.has(owner) if h != null else _pending_claims.has(owner)


## The usable rectangle right now (screen minus margins, timeline and claims)
## — tools size themselves to it (the edit toolbar's strip, dock heights).
static func usable_rect() -> Rect2:
	var h := get_hud()
	if h == null:
		var tree := Engine.get_main_loop() as SceneTree
		var vp := tree.root.get_visible_rect().size if tree != null else Vector2(1920, 1080)
		return Rect2(HudLayoutCore.MARGIN, HudLayoutCore.MARGIN,
			vp.x - 2.0 * HudLayoutCore.MARGIN, vp.y - 2.0 * HudLayoutCore.MARGIN - 162.0)
	return HudLayoutCore.usable_rect(h._viewport_size(), h._timeline_h(), [])


## The timeline bar's live height (162 when no HUD — selftests, the hub).
static func timeline_height() -> float:
	var h := get_hud()
	return h._timeline_h() if h != null else 162.0


## A right-edge dock: claim its width (the right column tucks), and keep its
## bottom above the live timeline. Call on open; `release(owner)` on close.
static func claim_right_dock(owner: String, dock: Control, dock_w: float) -> void:
	claim(owner, {"inset": {"right": dock_w + 14.0 - HudLayoutCore.MARGIN}, "tuck": ["top_right"]})
	if dock != null:
		dock.offset_bottom = -(timeline_height() + 10.0)


## A full-screen modal over the first-person HUD: the HUD hides under it
## (toasts stay — they are how the game reports — and the alarm feed tucks).
## Release with `release(owner)`.
static func claim_modal(owner: String) -> void:
	claim(owner, {"hide": ["top_left", "top_right", "top_center", "center_prompt"],
		"tuck": ["bottom_left"]})


## Y of the timeline bar's top edge in canvas units (docks stop above it).
static func timeline_top() -> float:
	var h := get_hud()
	var tree := Engine.get_main_loop() as SceneTree
	var vp := tree.root.get_visible_rect().size if tree != null else Vector2(1920, 1080)
	return vp.y - (h._timeline_h() if h != null else 162.0)


# ---------------------------------------------------------------------------
# Node
# ---------------------------------------------------------------------------

func _ready() -> void:
	# Layout and pills must keep working while the tree is paused or Main's
	# processing is switched off by a mode.
	process_mode = Node.PROCESS_MODE_ALWAYS
	ServiceLocator.provide(KEY, self)
	_layer = CanvasLayer.new()
	_layer.name = "HudPills"
	_layer.layer = UITheme.LAYER_HUD
	add_child(_layer)
	get_viewport().size_changed.connect(queue_layout)
	var tl := ServiceLocator.timeline_ui()
	if tl != null and tl.has_signal("stack_height_changed"):
		tl.connect("stack_height_changed", func(_h: Variant = null) -> void: queue_layout())
	for p in _pending_panels:
		if is_instance_valid(p[0]):
			_register(p[0], p[1], p[2], p[3])
	_pending_panels.clear()
	for o in _pending_claims:
		_claims[o] = _pending_claims[o]
	_pending_claims.clear()
	queue_layout()


func queue_layout() -> void:
	if not _dirty:
		_dirty = true
		call_deferred("_layout")


func _register(panel: Control, id: String, region: String, opts: Dictionary) -> void:
	if panel == null:
		return
	_unregister(id)
	var on_vis := _on_panel_visibility.bind(id)
	var on_exit := _unregister.bind(id)
	var rec := {"node": panel, "region": region, "opts": opts, "intent": panel.visible, "pill": null,
		"on_vis": on_vis, "on_exit": on_exit}
	_panels[id] = rec
	panel.visibility_changed.connect(on_vis)
	panel.resized.connect(queue_layout)
	panel.minimum_size_changed.connect(queue_layout)
	panel.tree_exiting.connect(on_exit, CONNECT_ONE_SHOT)
	# A layer shown / hidden by its owner changes what fits (the poll in
	# _process stays as a backstop for a panel reparented under another layer).
	var p := panel.get_parent()
	while p != null:
		if p is CanvasLayer and not (p as CanvasLayer).visibility_changed.is_connected(queue_layout):
			(p as CanvasLayer).visibility_changed.connect(queue_layout)
		p = p.get_parent()
	queue_layout()


func _unregister(id: String) -> void:
	if not _panels.has(id):
		return
	var rec: Dictionary = _panels[id]
	var n: Control = rec["node"]
	if is_instance_valid(n):
		if n.visibility_changed.is_connected(rec["on_vis"]):
			n.visibility_changed.disconnect(rec["on_vis"])
		if n.tree_exiting.is_connected(rec["on_exit"]):
			n.tree_exiting.disconnect(rec["on_exit"])
		if n.resized.is_connected(queue_layout):
			n.resized.disconnect(queue_layout)
		if n.minimum_size_changed.is_connected(queue_layout):
			n.minimum_size_changed.disconnect(queue_layout)
	var pill: Control = rec["pill"]
	if pill != null and is_instance_valid(pill):
		pill.queue_free()
	_panels.erase(id)
	_peek.erase(id)
	queue_layout()


## The panel changed its own visibility: that is its new intent — unless the
## manager is the one writing, or the panel is currently suppressed (tucked /
## hidden by a claim), in which case it is put back.
func _on_panel_visibility(id: String) -> void:
	if _setting or not _panels.has(id):
		return
	var rec: Dictionary = _panels[id]
	var n: Control = rec["node"]
	rec["intent"] = n.visible
	var st := str((_last.get(id, {}) as Dictionary).get("state", "full"))
	if st != "full" and n.visible:
		# DEFERRED: CanvasItem emits visibility_changed BEFORE it propagates
		# the change to its children, so hiding the panel again from inside
		# this handler leaves every child's cached "visible in tree" flag set —
		# the scoreboard's whole body went on drawing under the graph while the
		# panel itself read hidden.
		call_deferred("_revert_suppressed", id)
	queue_layout()


func _revert_suppressed(id: String) -> void:
	if not _panels.has(id):
		return
	var n: Control = _panels[id]["node"]
	var st := str((_last.get(id, {}) as Dictionary).get("state", "full"))
	if is_instance_valid(n) and st != "full" and n.visible:
		_setting = true
		n.visible = false
		_setting = false


func _viewport_size() -> Vector2:
	return get_viewport().get_visible_rect().size


func _timeline_h() -> float:
	var tl := ServiceLocator.timeline_ui()
	if tl != null and tl.is_visible_in_tree() and tl.has_method("get_stack_height"):
		return float(tl.call("get_stack_height"))
	return 0.0 if tl == null or not tl.is_visible_in_tree() else 162.0


func _panel_size(n: Control, opts: Dictionary) -> Vector2:
	if opts.has("size") and opts["size"] is Callable:
		return (opts["size"] as Callable).call()
	var s := n.size
	var m := n.get_combined_minimum_size()
	return Vector2(maxf(s.x, m.x), maxf(s.y, m.y))


func _layout() -> void:
	_dirty = false
	# A deferred layout can land after the scene left the tree (a modal
	# releasing its claim during a scene change): no viewport, nothing to lay out.
	if not is_inside_tree():
		return
	var panels: Array = []
	var layer_hidden := {}
	for id in _panels:
		var rec: Dictionary = _panels[id]
		var n: Control = rec["node"]
		if not is_instance_valid(n):
			continue
		var opts: Dictionary = rec["opts"]
		var tuckable := bool(opts.get("tuckable", true)) and not _peek.has(id)
		# `ignore_layer`: placed even while its CanvasLayer is hidden (the
		# interaction prompt toggles its layer, not itself).
		var shown := n.is_inside_tree() and (bool(opts.get("ignore_layer", false)) or _parent_shown(n))
		rec["parent_shown"] = shown
		if not shown:
			layer_hidden[id] = true
		panels.append({
			"id": id, "region": rec["region"], "order": int(opts.get("order", 0)),
			"priority": float(opts.get("priority", 0)), "tuckable": tuckable,
			"visible": bool(rec["intent"]) and shown,
			"size": _panel_size(n, opts), "pill": _pill_size(id, rec),
		})
	var res := HudLayoutCore.solve(_viewport_size(), _timeline_h(), panels, _claims.values())
	_last = res
	_setting = true
	for id in res:
		var rec: Dictionary = _panels[id]
		var n: Control = rec["node"]
		var st := str(res[id]["state"])
		var r: Rect2 = res[id]["rect"]
		# A panel whose own layer is hidden frees its slot but is never
		# written: it shows again, in place, when its layer does.
		if not layer_hidden.has(id) and bool(rec["intent"]):
			var want_visible := st == "full"
			if n.visible != want_visible:
				n.visible = want_visible
		elif layer_hidden.has(id) and bool(rec["intent"]) and n.visible and _claimed_away(
				str(rec["region"]), bool((rec["opts"] as Dictionary).get("tuckable", true))):
			# Its layer is hidden (a full-screen mode, a clean screenshot) but a
			# claim would hide or tuck it anyway: hide it now, or it is back on
			# screen the moment the layer is, under whatever made the claim.
			n.visible = false
		if st == "full":
			_place(n, r, rec["opts"])
		_sync_pill(id, rec, st == "pill", r)
	_setting = false
	layout_changed.emit()


## Would a live claim hide or tuck a panel in this region?
func _claimed_away(region: String, tuckable: bool) -> bool:
	var cl := _claims.values()
	if HudLayoutCore.region_flag(cl, "hide", region):
		return true
	return tuckable and HudLayoutCore.region_flag(cl, "tuck", region)


## Panels on a hidden CanvasLayer (a mode hid the whole UI layer) count as hidden.

func _parent_shown(n: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p is CanvasLayer and not (p as CanvasLayer).visible:
			return false
		p = p.get_parent()
	return true


func _place(n: Control, r: Rect2, opts: Dictionary) -> void:
	if opts.has("place") and opts["place"] is Callable:
		(opts["place"] as Callable).call(r)
		return
	n.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	# Canvas coordinates: a panel nested in an anchor Control (the chips) lands
	# where the solver put it whatever its parent's offset.
	n.global_position = r.position
	# Always write the size, growing AND shrinking: a container never shrinks
	# on its own, so a panel whose autowrapped text measured tall before its
	# width was known (one word per line) kept that height for good — the
	# festival panel ran down behind the timeline.
	if not n.size.is_equal_approx(r.size):
		n.size = r.size


func _pill_size(id: String, rec: Dictionary) -> Vector2:
	var txt := _pill_text(rec)
	var f := UITheme.font("medium")
	var w := 40.0
	if f != null:
		w = f.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UITheme.FONT_SM).x + 44.0
	return Vector2(clampf(w, 60.0, PILL_MAX_W), PILL_H)


func _pill_text(rec: Dictionary) -> String:
	var opts: Dictionary = rec["opts"]
	if opts.has("compact") and opts["compact"] is Callable:
		return str((opts["compact"] as Callable).call())
	return str(opts.get("title", rec["node"].name))


func _sync_pill(id: String, rec: Dictionary, show: bool, r: Rect2) -> void:
	var pill: Button = rec["pill"]
	if not show:
		if pill != null and is_instance_valid(pill):
			pill.visible = false
		return
	if pill == null or not is_instance_valid(pill):
		pill = Button.new()
		pill.name = "Pill_%s" % id
		pill.focus_mode = Control.FOCUS_NONE
		pill.alignment = HORIZONTAL_ALIGNMENT_LEFT
		pill.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		pill.clip_text = true
		pill.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		pill.add_theme_font_override("font", UITheme.font("medium"))
		var sb := UITheme.chip_style(UITheme.C_TEXT_S)
		sb.bg_color = Color(UITheme.C_PANEL, 0.92)
		sb.border_color = Color(UITheme.C_BORDER, 0.9)
		sb.set_content_margin_all(6)
		sb.content_margin_left = 10
		sb.content_margin_right = 12
		pill.add_theme_stylebox_override("normal", sb)
		var hv := sb.duplicate() as StyleBoxFlat
		hv.border_color = UITheme.C_PRIMARY
		pill.add_theme_stylebox_override("hover", hv)
		pill.add_theme_stylebox_override("pressed", hv)
		pill.tooltip_text = "Show %s" % str((rec["opts"] as Dictionary).get("title", id))
		var icon := str((rec["opts"] as Dictionary).get("icon", ""))
		if not icon.is_empty():
			pill.icon = UiIcons.icon(icon, 14)
		pill.pressed.connect(func() -> void: _peek_panel(id))
		_layer.add_child(pill)
		rec["pill"] = pill
	pill.text = _pill_text(rec)
	pill.position = r.position
	pill.size = r.size
	pill.visible = true


func _peek_panel(id: String) -> void:
	_peek[id] = 0.0
	queue_layout()


func _process(delta: float) -> void:
	PerfSpan.begin("hud_layout")
	_perf_tick(delta)
	PerfSpan.end("hud_layout")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	# Pills refresh their summary twice a second; peeks end once the pointer
	# has been off the panel for a moment.
	_pill_acc += delta
	if _pill_acc >= PILL_REFRESH_S:
		_pill_acc = 0.0
		# A layer shown / hidden by its owner changes what fits.
		for id in _panels:
			var rec: Dictionary = _panels[id]
			var n: Control = rec["node"]
			if is_instance_valid(n) and n.is_inside_tree() and _parent_shown(n) != bool(rec.get("parent_shown", true)):
				queue_layout()
				break
		for id in _panels:
			var rec: Dictionary = _panels[id]
			var pill: Button = rec["pill"]
			if pill != null and is_instance_valid(pill) and pill.visible:
				pill.text = _pill_text(rec)
	if _peek.is_empty():
		return
	var mouse := get_viewport().get_mouse_position()
	for id in _peek.keys():
		var rec: Dictionary = _panels.get(id, {})
		var n: Control = rec.get("node")
		if n == null or not is_instance_valid(n):
			_peek.erase(id)
			continue
		if n.get_global_rect().has_point(mouse):
			_peek[id] = 0.0
		else:
			_peek[id] = float(_peek[id]) + delta
			if float(_peek[id]) > PEEK_LINGER_S:
				_peek.erase(id)
				queue_layout()


## Live state for the harness: {id: {state, rect}}.
func snapshot() -> Dictionary:
	return _last.duplicate(true)


## Per panel: the manager's state beside the node's own flags (harness).
func debug_state() -> Dictionary:
	var out := {}
	for id in _panels:
		var rec: Dictionary = _panels[id]
		var n: Control = rec["node"]
		out[id] = {"state": str((_last.get(id, {}) as Dictionary).get("state", "?")),
			"intent": bool(rec["intent"]), "visible": is_instance_valid(n) and n.visible,
			"in_tree_visible": is_instance_valid(n) and n.is_visible_in_tree(),
			"parent_shown": bool(rec.get("parent_shown", true))}
	return out


func claims() -> Dictionary:
	return _claims.duplicate(true)

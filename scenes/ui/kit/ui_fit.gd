class_name UiFit
extends RefCounted

## Make a panel fit the screen it is on.
##
## Two problems recur across the hand-built modals and docks, and this file
## solves each once:
##   - SIZING. A modal centred on the whole screen at a fixed 1160 × 740 lands
##     on the timeline at 1080p and runs off the screen at 720p (UI scale 125 %
##     leaves a 1536 × 864 canvas). `keep_fitted(panel, want)` centres the panel
##     on the screen, never bigger than it, and re-fits on every resize. The
##     panel's content must scroll — this cannot shrink a container below its
##     children's minimum.
##     A modal COVERS the timeline bar (2026-10-29: most modals have nothing to
##     do with time, and stopping above the bar made them needlessly small);
##     pass `keep_timeline` for one that wants the bar in view. A panel that
##     would draw UNDER the bar (an earlier sibling on the bar's own canvas
##     layer) still keeps clear of it, or its bottom would be hidden.
##   - WIDTH. One label or option button whose minimum width is wider than its
##     column stretches the whole column past its parent (the graph inspector
##     was 20 px past its sidebar, the Site Report's header 240 px past the
##     modal). `tame_widths(root)` makes every text control under `root`
##     shrinkable: a label in a row ellipsizes with its full text on hover,
##     option buttons stop sizing to their longest item, long buttons clip.

const MARGIN := 24.0

## FULL SCREEN (2026-11-08, the user's call: a modal blocks every other UI
## anyway, so it may as well have the whole screen). A modal with a size
## (`want` > 0 on both axes) fills the screen edge to edge, and its contents
## are ZOOMED (Control.scale) by how much room the screen has over `want`, up
## to `ZOOM_MAX` — a 900 × 640 form at 1080p draws its text 25 % larger in a
## 1536 × 864 logical panel; a 1600 × 960 designer gets 1.125×. The zoom never
## goes below 1 and never makes the panel's content minimum overflow the
## screen. Kept as before: content-sized panels (a `want` axis of 0: small
## dialogs) and panels that keep the timeline in view.
const FULLSCREEN := true
const ZOOM_MAX := 1.25


## The rectangle a modal may use: the visible canvas minus a margin on every
## side, and minus the timeline bar when `keep_timeline` or when the panel
## would draw under it.
static func area(ci: CanvasItem, margin: float = MARGIN, keep_timeline: bool = false) -> Rect2:
	var vp := ci.get_viewport()
	if vp == null:
		return Rect2()
	var r := vp.get_visible_rect()
	var bottom := r.size.y - timeline_clearance(ci, keep_timeline)
	return Rect2(r.position + Vector2(margin, margin),
		Vector2(maxf(r.size.x - margin * 2.0, 0.0), maxf(bottom - margin * 2.0, 0.0)))


## How much of the screen bottom a modal must leave for the timeline: none
## when it draws over the bar (the usual case), the bar's height otherwise.
static func timeline_clearance(n: Node, keep_timeline: bool = false) -> float:
	if keep_timeline or not draws_over_timeline(n):
		return HudLayout.timeline_height()
	return 0.0


## True when `n` (a CanvasItem, or a CanvasLayer such as ModalFrame) is drawn
## over the timeline bar: on a higher canvas layer, or after the bar on the
## same one. True when there is no bar.
static func draws_over_timeline(n: Node) -> bool:
	var tl := ServiceLocator.timeline_ui() as CanvasItem
	if tl == null or not is_instance_valid(tl) or n == null or not tl.is_inside_tree() \
			or not n.is_inside_tree():
		return true
	var la: CanvasLayer = n as CanvasLayer
	if la == null and n is CanvasItem:
		la = (n as CanvasItem).get_canvas_layer_node()
	var lb := tl.get_canvas_layer_node()
	var a := la.layer if la != null else 0
	var b := lb.layer if lb != null else 0
	if a != b:
		return a > b
	if la != lb:
		return la != null and lb != null and la.is_greater_than(lb)
	return n.is_greater_than(tl)


## Centre `panel` (anchored top-left) in `area()`, `want` or smaller.
static func fit(panel: Control, want: Vector2, margin: float = MARGIN,
		keep_timeline: bool = false) -> void:
	if panel == null or not panel.is_inside_tree():
		return
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.custom_minimum_size = Vector2.ZERO
	if fills_screen(want, keep_timeline):
		fill(panel, want)
		return
	panel.scale = Vector2.ONE
	_apply_content_column(panel, 0.0)
	var a := area(panel, margin, keep_timeline)
	# A size of 0 on an axis = "as big as its content" (a content-sized panel).
	var content := panel.get_combined_minimum_size()
	var w := Vector2(want.x if want.x >= 1.0 else content.x, want.y if want.y >= 1.0 else content.y)
	panel.size = Vector2(minf(w.x, a.size.x), minf(w.y, a.size.y))
	# Centre on the size it actually took (it cannot go below its content).
	var s := panel.size
	var pos := a.position + (a.size - s) * 0.5
	panel.global_position = Vector2(maxf(pos.x, a.position.x), maxf(pos.y, a.position.y))


## True when a modal of this `want` goes full screen (see FULLSCREEN).
static func fills_screen(want: Vector2, keep_timeline: bool = false) -> bool:
	return FULLSCREEN and not keep_timeline and want.x >= 1.0 and want.y >= 1.0


## The zoom a full-screen modal of `want` gets on a screen area of `avail`
## (and with `content` its minimum size, so the content still fits).
## `min_logical` (a DesignerShell's fold thresholds): where the screen itself
## is at least that big, the zoom stops short of shrinking the panel's logical
## size below it. Without it a modal that wants less than 1600 x 900 was
## zoomed 1.25x at 1080p, its logical width fell to 1536 and its left column
## folded away on a screen with room for it.
static func zoom_for(avail: Vector2, want: Vector2, content: Vector2 = Vector2.ZERO,
		min_logical: Vector2 = Vector2.ZERO) -> float:
	if avail.x <= 0.0 or avail.y <= 0.0:
		return 1.0
	var z := minf(avail.x / maxf(want.x, 1.0), avail.y / maxf(want.y, 1.0))
	if content.x >= 1.0:
		z = minf(z, avail.x / content.x)
	if content.y >= 1.0:
		z = minf(z, avail.y / content.y)
	if min_logical.x >= 1.0 and avail.x >= min_logical.x:
		z = minf(z, avail.x / min_logical.x)
	if min_logical.y >= 1.0 and avail.y >= min_logical.y:
		z = minf(z, avail.y / min_logical.y)
	return clampf(z, 1.0, ZOOM_MAX)


## A panel's `min_logical` (see zoom_for): meta "ui_fit_min_logical".
static func min_logical_of(ci: CanvasItem) -> Vector2:
	if ci != null and ci.has_meta("ui_fit_min_logical"):
		return ci.get_meta("ui_fit_min_logical") as Vector2
	return Vector2.ZERO


## The logical size a full-screen modal of `want` lays out in (the screen
## divided by its zoom). DesignerShell folds its left column on this.
static func fill_logical_size(ci: CanvasItem, want: Vector2) -> Vector2:
	var a := area(ci, 0.0)
	return a.size / zoom_for(a.size, want, Vector2.ZERO, min_logical_of(ci))


## Fill the screen with `panel` (anchored top-left), its contents zoomed.
static func fill(panel: Control, want: Vector2) -> void:
	var a := area(panel, 0.0)
	panel.pivot_offset = Vector2.ZERO
	panel.scale = Vector2.ONE
	_apply_content_column(panel, 0.0)
	var content := panel.get_combined_minimum_size()
	var z := zoom_for(a.size, want, content, min_logical_of(panel))
	panel.scale = Vector2(z, z)
	panel.size = a.size / z
	panel.global_position = a.position
	_apply_content_column(panel, panel.size.x)


## A full-screen DIALOG lays its content in a centred column instead of edge
## to edge (a form stretched over 1900 px puts each label a metre from its
## control). `max_w` is the column's width in the panel's own pixels; 0 = off.
## Works on a PanelContainer: the side content margins of its "panel" style
## grow to centre the column. Call before or after keep_fitted.
static func set_content_column(panel: Control, max_w: float) -> void:
	if panel == null:
		return
	panel.set_meta("ui_fit_content_max_w", max_w)
	if panel.is_inside_tree() and panel.is_visible_in_tree() and panel.has_meta("ui_fit_want"):
		_refit.call_deferred(panel)


static func _apply_content_column(panel: Control, width: float) -> void:
	if not (panel is PanelContainer) or not panel.has_meta("ui_fit_content_max_w"):
		return
	var max_w := float(panel.get_meta("ui_fit_content_max_w"))
	var sb: StyleBox = null
	if panel.has_meta("ui_fit_column_style"):
		sb = panel.get_meta("ui_fit_column_style") as StyleBox
	else:
		var base := panel.get_theme_stylebox("panel")
		if base == null:
			return
		sb = base.duplicate() as StyleBox
		panel.set_meta("ui_fit_column_style", sb)
		panel.set_meta("ui_fit_column_base", Vector2(base.content_margin_left, base.content_margin_right))
		panel.add_theme_stylebox_override("panel", sb)
	var base_m := panel.get_meta("ui_fit_column_base") as Vector2
	var side := 0.0
	if max_w >= 1.0 and width > max_w:
		side = (width - max_w) * 0.5
	sb.content_margin_left = maxf(base_m.x, side)
	sb.content_margin_right = maxf(base_m.y, side)


## `fit` now and again whenever the window or the timeline changes size, or
## the panel is shown. While the panel is visible it also claims the HUD
## (`HudLayout.claim_modal`: the first-person HUD hides under a modal) unless
## `claim_hud` is false. It covers the timeline unless `keep_timeline`.
## Safe to call more than once.
static func keep_fitted(panel: Control, want: Vector2, margin: float = MARGIN,
		claim_hud: bool = true, keep_timeline: bool = false) -> void:
	if panel == null:
		return
	panel.set_meta("ui_fit_want", want)
	panel.set_meta("ui_fit_margin", margin)
	panel.set_meta("ui_fit_claim", claim_hud)
	panel.set_meta("ui_fit_keep_timeline", keep_timeline)
	# A fitted panel that claims the HUD is a modal: the UI audit lets it cover
	# the timeline bar and the HUD (UiAudit.MODAL_META).
	if claim_hud:
		panel.set_meta("ui_modal", true)
	if panel.has_meta("ui_fit_wired"):
		_refit.call_deferred(panel)
		return
	panel.set_meta("ui_fit_wired", true)
	var refit := func() -> void: _refit.call_deferred(panel)
	panel.visibility_changed.connect(refit)
	panel.minimum_size_changed.connect(refit)
	panel.tree_exiting.connect(func() -> void:
		HudLayout.release(_claim_owner(panel))
		# `refit` captures the panel and hangs off the VIEWPORT, which outlives
		# it: every later window resize (and the resize at shutdown) called it
		# on a freed panel — the "Lambda capture at index 0 was freed" errors
		# the harness counted after a modal was freed. Unhook it here.
		var vp_out := panel.get_viewport()
		if vp_out != null and vp_out.size_changed.is_connected(refit):
			vp_out.size_changed.disconnect(refit))
	panel.tree_entered.connect(func() -> void:
		var vp := panel.get_viewport()
		if vp != null and not vp.size_changed.is_connected(refit):
			vp.size_changed.connect(refit)
		refit.call())
	if panel.is_inside_tree():
		var vp := panel.get_viewport()
		if vp != null and not vp.size_changed.is_connected(refit):
			vp.size_changed.connect(refit)
		refit.call()


## One-line adoption for an existing modal: its intended size is read off the
## panel (the larger of its minimum size and its centre-anchored offsets), and
## a panel parked in a CenterContainer is lifted out of it — the container
## would re-centre it on the whole screen every sort. Call after the panel is
## parented.
static func adopt(panel: Control, margin: float = MARGIN, claim_hud: bool = true,
		keep_timeline: bool = false) -> void:
	if panel == null:
		return
	var want := panel.custom_minimum_size
	want.x = maxf(want.x, absf(panel.offset_right - panel.offset_left))
	want.y = maxf(want.y, absf(panel.offset_bottom - panel.offset_top))
	var p := panel.get_parent()
	if p is CenterContainer and p.get_parent() != null:
		var host := p.get_parent()
		p.remove_child(panel)
		host.add_child(panel)
		host.move_child(panel, p.get_index() + 1)
	keep_fitted(panel, want, margin, claim_hud, keep_timeline)


static func _claim_owner(panel: Control) -> String:
	return "ui_fit_%d" % panel.get_instance_id()


## `panel_v` is untyped on purpose: the call is deferred, and a modal freed
## in the same frame as its last visibility change (a CanvasLayer that
## queue_frees itself on close) reaches here as a freed object, which a
## `Control` parameter refuses BEFORE the body's own guard can run
## ("Cannot convert argument 1 from Object to Object").
static func _refit(panel_v: Variant) -> void:
	if not is_instance_valid(panel_v) or not (panel_v is Control):
		return
	var panel := panel_v as Control
	var shown := panel.is_inside_tree() and panel.is_visible_in_tree()
	if bool(panel.get_meta("ui_fit_claim", true)):
		var owner := _claim_owner(panel)
		if shown and not HudLayout.has_claim(owner):
			HudLayout.claim_modal(owner)
		elif not shown and HudLayout.has_claim(owner):
			HudLayout.release(owner)
	if not shown:
		return
	fit(panel, panel.get_meta("ui_fit_want", panel.size), float(panel.get_meta("ui_fit_margin", MARGIN)),
		bool(panel.get_meta("ui_fit_keep_timeline", false)))


## Make every text control under `root` shrinkable (see the header). Run it
## after building; it is idempotent (tamed controls are marked). Free-standing
## labels (not in a row) wrap when `wrap_free_labels`, else ellipsize too.
static func tame_widths(root: Node, wrap_free_labels: bool = false) -> void:
	if root == null:
		return
	for n in root.find_children("*", "Control", true, false):
		if n.has_meta("ui_tamed"):
			continue
		if n is Label:
			var l := n as Label
			if l.autowrap_mode != TextServer.AUTOWRAP_OFF or l.clip_text \
					or l.text_overrun_behavior != TextServer.OVERRUN_NO_TRIMMING:
				continue
			l.set_meta("ui_tamed", true)
			var in_row := l.get_parent() is HBoxContainer
			# In a row only an EXPANDING label may shorten: a shrink-sized one
			# would collapse to its ellipsis ("…") at its minimum width.
			if in_row and not (l.size_flags_horizontal & Control.SIZE_EXPAND):
				continue
			if in_row or not wrap_free_labels:
				l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				if l.tooltip_text.is_empty():
					# Read at hover time, so a live value never shows stale text.
					l.mouse_filter = Control.MOUSE_FILTER_PASS
					l.mouse_entered.connect(func() -> void: l.tooltip_text = l.text)
			else:
				l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		elif n is OptionButton:
			var o := n as OptionButton
			o.set_meta("ui_tamed", true)
			o.fit_to_longest_item = false
			o.clip_text = true
			o.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		elif n is Button:
			var b := n as Button
			b.set_meta("ui_tamed", true)
			var shrinks := not (b.get_parent() is HBoxContainer) or bool(b.size_flags_horizontal & Control.SIZE_EXPAND)
			if shrinks and not b.clip_text and b.autowrap_mode == TextServer.AUTOWRAP_OFF and b.text.length() > 12:
				b.clip_text = true
				b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
				if b.tooltip_text.is_empty():
					b.tooltip_text = b.text

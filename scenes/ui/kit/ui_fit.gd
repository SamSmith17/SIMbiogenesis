class_name UiFit
extends RefCounted

## Make a panel fit the screen it is on.
##
## Two problems recur across the hand-built modals and docks, and this file
## solves each once:
##   - SIZING. A modal centred on the whole screen at a fixed 1160 × 740 lands
##     on the timeline at 1080p and runs off the screen at 720p (UI scale 125 %
##     leaves a 1536 × 864 canvas). `keep_fitted(panel, want)` places the panel
##     in the area ABOVE the timeline, never bigger than it, and re-fits on
##     every resize. The panel's content must scroll — this cannot shrink a
##     container below its children's minimum.
##   - WIDTH. One label or option button whose minimum width is wider than its
##     column stretches the whole column past its parent (the graph inspector
##     was 20 px past its sidebar, the Site Report's header 240 px past the
##     modal). `tame_widths(root)` makes every text control under `root`
##     shrinkable: a label in a row ellipsizes with its full text on hover,
##     option buttons stop sizing to their longest item, long buttons clip.

const MARGIN := 24.0


## The rectangle a modal may use: the visible canvas minus the timeline bar,
## minus a margin on every side.
static func area(ci: CanvasItem, margin: float = MARGIN) -> Rect2:
	var vp := ci.get_viewport()
	if vp == null:
		return Rect2()
	var r := vp.get_visible_rect()
	var bottom := r.size.y - HudLayout.timeline_height()
	return Rect2(r.position + Vector2(margin, margin),
		Vector2(maxf(r.size.x - margin * 2.0, 0.0), maxf(bottom - margin * 2.0, 0.0)))


## Centre `panel` (anchored top-left) in `area()`, `want` or smaller.
static func fit(panel: Control, want: Vector2, margin: float = MARGIN) -> void:
	if panel == null or not panel.is_inside_tree():
		return
	var a := area(panel, margin)
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.custom_minimum_size = Vector2.ZERO
	# A size of 0 on an axis = "as big as its content" (a content-sized panel).
	var content := panel.get_combined_minimum_size()
	var w := Vector2(want.x if want.x >= 1.0 else content.x, want.y if want.y >= 1.0 else content.y)
	panel.size = Vector2(minf(w.x, a.size.x), minf(w.y, a.size.y))
	# Centre on the size it actually took (it cannot go below its content).
	var s := panel.size
	var pos := a.position + (a.size - s) * 0.5
	panel.global_position = Vector2(maxf(pos.x, a.position.x), maxf(pos.y, a.position.y))


## `fit` now and again whenever the window or the timeline changes size, or
## the panel is shown. While the panel is visible it also claims the HUD
## (`HudLayout.claim_modal`: the first-person HUD hides under a modal) unless
## `claim_hud` is false. Safe to call more than once.
static func keep_fitted(panel: Control, want: Vector2, margin: float = MARGIN,
		claim_hud: bool = true) -> void:
	if panel == null:
		return
	panel.set_meta("ui_fit_want", want)
	panel.set_meta("ui_fit_margin", margin)
	panel.set_meta("ui_fit_claim", claim_hud)
	if panel.has_meta("ui_fit_wired"):
		_refit.call_deferred(panel)
		return
	panel.set_meta("ui_fit_wired", true)
	var refit := func() -> void: _refit.call_deferred(panel)
	panel.visibility_changed.connect(refit)
	panel.minimum_size_changed.connect(refit)
	panel.tree_exiting.connect(func() -> void: HudLayout.release(_claim_owner(panel)))
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
static func adopt(panel: Control, margin: float = MARGIN, claim_hud: bool = true) -> void:
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
	keep_fitted(panel, want, margin, claim_hud)


static func _claim_owner(panel: Control) -> String:
	return "ui_fit_%d" % panel.get_instance_id()


static func _refit(panel: Control) -> void:
	if not is_instance_valid(panel):
		return
	var shown := panel.is_inside_tree() and panel.is_visible_in_tree()
	if bool(panel.get_meta("ui_fit_claim", true)):
		var owner := _claim_owner(panel)
		if shown and not HudLayout.has_claim(owner):
			HudLayout.claim_modal(owner)
		elif not shown and HudLayout.has_claim(owner):
			HudLayout.release(owner)
	if not shown:
		return
	fit(panel, panel.get_meta("ui_fit_want", panel.size), float(panel.get_meta("ui_fit_margin", MARGIN)))


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

class_name UiScreenLayout
extends RefCounted

## Viewport-aware layout helpers for UILayer / CanvasLayer controls.

## Fallback when TimelineUI.get_stack_height() is unavailable.
## Matches slim chrome (62) + tracks (~96) + bottom pad (4) ≈ 162.
const TIMELINE_BAR_HEIGHT := 158.0
const TIMELINE_MARGIN := 4.0
const SIDE_MARGIN := 12.0


static func timeline_stack_height() -> float:
	return TIMELINE_BAR_HEIGHT + TIMELINE_MARGIN


static func pin_fullscreen(control: Control) -> void:
	if control == null:
		return
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0


static func pin_bottom_panel(panel: Control, height: float,
		stack_clearance: float = timeline_stack_height(),
		side_margin: float = SIDE_MARGIN) -> void:
	if panel == null:
		return
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = side_margin
	panel.offset_right = -side_margin
	panel.offset_bottom = -stack_clearance
	panel.offset_top = -(stack_clearance + height)
	panel.custom_minimum_size = Vector2(0.0, height)


static func pin_above_timeline(panel: Control, height: float,
		stack_clearance: float = timeline_stack_height(),
		side_margin: float = SIDE_MARGIN) -> void:
	pin_bottom_panel(panel, height, stack_clearance, side_margin)


## Bottom dock that overlaps the timeline bar (higher z-order panel only).
static func pin_over_timeline(panel: Control, height: float,
		side_margin: float = SIDE_MARGIN) -> void:
	if panel == null:
		return
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.anchor_left = 0.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = side_margin
	panel.offset_right = -side_margin
	panel.offset_bottom = -TIMELINE_MARGIN
	panel.offset_top = -(TIMELINE_MARGIN + height)
	panel.custom_minimum_size = Vector2(0.0, height)


## Card docked to the lower-right, clear of the timeline stack. For fault /
## education cards, which must not sit on top of the thing they are explaining —
## a centered card buried the destroy FX it was describing.
static func clamped_corner_card(panel: Control, desired: Vector2,
		stack_clearance: float = timeline_stack_height()) -> void:
	if panel == null:
		return
	var screen := _viewport_size(panel)
	var w := minf(desired.x, screen.x * 0.92)
	var h := minf(desired.y, maxf(screen.y - stack_clearance - SIDE_MARGIN * 2.0, 120.0))
	panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	panel.anchor_left = 1.0
	panel.anchor_top = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -(w + SIDE_MARGIN)
	panel.offset_right = -SIDE_MARGIN
	panel.offset_bottom = -stack_clearance
	panel.offset_top = -(stack_clearance + h)
	panel.custom_minimum_size = Vector2(w, h)


static func clamped_center(panel: Control, desired: Vector2) -> void:
	if panel == null:
		return
	# Centred in the area ABOVE the timeline (the live bar height): centred on
	# the whole window, a tall panel sat on the timeline at 720p.
	var screen := _viewport_size(panel)
	var tl := HudLayout.timeline_height()
	var w := minf(desired.x, screen.x - UiFit.MARGIN * 2.0)
	var h := minf(desired.y, maxf(screen.y - tl - UiFit.MARGIN * 2.0, 120.0))
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -w * 0.5
	panel.offset_right = w * 0.5
	panel.offset_top = -h * 0.5 - tl * 0.5
	panel.offset_bottom = h * 0.5 - tl * 0.5
	panel.custom_minimum_size = Vector2(w, h)


static func _viewport_size(control: Control) -> Vector2:
	var vp := control.get_viewport()
	if vp != null:
		return vp.get_visible_rect().size
	return Vector2(1280.0, 720.0)

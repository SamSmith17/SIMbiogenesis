class_name TouchScrollHandler
extends RefCounted
## Two-finger vertical scroll for sidebar ScrollContainers (library / inspector).

var _scroll: ScrollContainer = null
var _host: Control = null
var _touch_positions: Dictionary = {}
var _two_finger_scrolling: bool = false
var _last_mid: Vector2 = Vector2.ZERO


func bind(scroll: ScrollContainer, host: Control) -> void:
	_scroll = scroll
	_host = host


func handle(event: InputEvent) -> bool:
	if _scroll == null or _host == null:
		return false
	if not is_instance_valid(_scroll) or not is_instance_valid(_host):
		return false

	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			if not _global_point_inside_host(st.position):
				return false
			_touch_positions[st.index] = st.position
			if _touch_positions.size() >= 2 and _all_touches_inside_host():
				_two_finger_scrolling = true
				_last_mid = _touch_midpoint()
				return true
			return false
		else:
			var was_scrolling := _two_finger_scrolling
			_touch_positions.erase(st.index)
			if _touch_positions.size() < 2:
				_two_finger_scrolling = false
			return was_scrolling

	if event is InputEventScreenDrag:
		if not _two_finger_scrolling or _touch_positions.size() < 2:
			return false
		var sd := event as InputEventScreenDrag
		if not _touch_positions.has(sd.index):
			return false
		_touch_positions[sd.index] = sd.position
		if not _all_touches_inside_host():
			return false
		var mid := _touch_midpoint()
		_apply_scroll_delta(mid.y - _last_mid.y)
		_last_mid = mid
		return true

	if event is InputEventPanGesture:
		if not _global_point_inside_host(event.position):
			return false
		_apply_scroll_delta(event.delta.y)
		return true

	return false


func _touch_midpoint() -> Vector2:
	var sum := Vector2.ZERO
	for pos: Vector2 in _touch_positions.values():
		sum += pos
	return sum / float(_touch_positions.size())


func _global_point_inside_host(global_pos: Vector2) -> bool:
	var local := _host.get_global_transform_with_canvas().affine_inverse() * global_pos
	return Rect2(Vector2.ZERO, _host.size).has_point(local)


func _all_touches_inside_host() -> bool:
	for pos: Vector2 in _touch_positions.values():
		if not _global_point_inside_host(pos):
			return false
	return true


func _apply_scroll_delta(delta_y: float) -> void:
	if absf(delta_y) < 0.01:
		return
	var vbar := _scroll.get_v_scroll_bar()
	if vbar == null:
		return
	var next := float(_scroll.scroll_vertical) - delta_y
	next = clampf(next, vbar.min_value, vbar.max_value)
	_scroll.scroll_vertical = int(next)

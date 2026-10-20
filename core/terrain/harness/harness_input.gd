class_name HarnessInput
extends RefCounted

## Real input events for harness runs and the feature tour, as one static
## toolkit. These are the shapes the capture modes proved one at a time
## (playtest_harness `_lc_press/_lc_move/_lc_click/_lc_drag`, `_ae_key`,
## `_bs_find_button/_bs_center`, `_water_screen`) — copied here so new code has
## one place to reach for them. The existing captures still carry their own
## copies; they can be pointed here when somebody next touches them.
##
## Mouse events go through `Viewport.push_input` (the GUI and the 3D tools both
## see them, exactly as a real click), in VIEWPORT (logical, 1920×1080-ish)
## coordinates — `in_local_coords = true`, so a click lands on the control it
## was aimed at whatever the window's real size. Actions go through
## `Input.parse_input_event` with the action's OWN bound event, so a handler
## that tests `is_action_pressed("x")` sees the key the player would press.


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func mouse_press(vp: Viewport, pos: Vector2, pressed: bool, double: bool = false,
		ctrl: bool = false, shift: bool = false,
		button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.double_click = double
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	ev.position = pos
	ev.global_position = pos
	vp.push_input(ev, true)
	await _tree().process_frame


static func mouse_move(vp: Viewport, pos: Vector2, ctrl: bool = false, shift: bool = false,
		held: bool = false) -> void:
	# warp_mouse takes WINDOW pixels; `pos` is in viewport (logical) coords.
	# Warping to the logical point put the real cursor elsewhere whenever the
	# window is not the 1920×1080 base (1280×720 at UI scale 1.25: 1.2× off),
	# and the OS's own motion event then dragged every hover / wire drag there.
	Input.warp_mouse(vp.get_final_transform() * pos)
	_push_motion(vp, pos, ctrl, shift, held)
	await _tree().process_frame


## One motion event, no frame wait (see click()).
static func _push_motion(vp: Viewport, pos: Vector2, ctrl: bool, shift: bool, held: bool) -> void:
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	mm.global_position = pos
	mm.ctrl_pressed = ctrl
	mm.shift_pressed = shift
	if held:
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	vp.push_input(mm, true)


## The press and the release are a frame apart, and a REAL mouse-motion event
## delivered in that frame cancels the click: BaseButton re-evaluates
## `pressing_inside` from every motion's position while it is held, and with
## the mouse captured (first person) every real motion reports the window
## CENTRE, nowhere near the button, so the release emits button_up and no
## `pressed`. Under Movie Maker a frame is many times longer in real time, so
## a stray motion (the player touching the mouse, Windows re-centring the
## captured cursor) lands in that window far more often — the render_sim tour
## stop failed only in `-Mode record` for exactly this. A held motion at the
## release point pushed in the SAME frame as the release (no await between
## them) puts `pressing_inside` back before the button sees the release;
## nothing real can be processed between two synchronous push_input calls.
static func click(vp: Viewport, pos: Vector2, double: bool = false) -> void:
	await mouse_move(vp, pos)
	await mouse_press(vp, pos, true, double)
	_push_motion(vp, pos, false, false, true)
	await mouse_press(vp, pos, false)


static func drag(vp: Viewport, a: Vector2, b: Vector2, steps: int = 12,
		ctrl: bool = false, shift: bool = false) -> void:
	await mouse_move(vp, a, ctrl, shift)
	await mouse_press(vp, a, true, false, ctrl, shift)
	var n := maxi(steps, 1)
	for i in range(1, n + 1):
		await mouse_move(vp, a.lerp(b, float(i) / float(n)), ctrl, shift, true)
	# Same guard as click(): the last held motion and the release in one frame.
	_push_motion(vp, b, ctrl, shift, true)
	await mouse_press(vp, b, false, false, ctrl, shift)


static func key(vp: Viewport, code: Key, ctrl: bool = false, shift: bool = false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		ev.ctrl_pressed = ctrl
		ev.shift_pressed = shift
		vp.push_input(ev, true)
		await _tree().process_frame


## Press and release an InputMap action through its first bound key (or mouse
## button), via the global input pipeline. Returns false when the action has no
## event to send.
static func press_action(action: String) -> bool:
	var ev := first_event(action)
	if ev == null:
		return false
	var down := ev.duplicate() as InputEvent
	_set_pressed(down, true)
	Input.parse_input_event(down)
	await _tree().process_frame
	var up := ev.duplicate() as InputEvent
	_set_pressed(up, false)
	Input.parse_input_event(up)
	await _tree().process_frame
	return true


static func first_event(action: String) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey or ev is InputEventMouseButton:
			return ev
	return null


static func _set_pressed(ev: InputEvent, pressed: bool) -> void:
	if ev is InputEventKey:
		(ev as InputEventKey).pressed = pressed
	elif ev is InputEventMouseButton:
		(ev as InputEventMouseButton).pressed = pressed


## Human label for an action's bindings: "G", "Shift+T", "F5 / Mouse 4".
## Joypad events are left out (the docs are for keyboard players).
static func action_label(action: String) -> String:
	if not InputMap.has_action(action):
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for ev in InputMap.action_get_events(action):
		var s := event_label(ev)
		if not s.is_empty() and not (s in parts):
			parts.append(s)
	return " / ".join(parts)


static func event_label(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_NONE and k.key_label != KEY_NONE:
			code = k.key_label
		if code == KEY_NONE:
			return ""
		var mods: PackedStringArray = PackedStringArray()
		if k.ctrl_pressed:
			mods.append("Ctrl")
		if k.shift_pressed:
			mods.append("Shift")
		if k.alt_pressed:
			mods.append("Alt")
		mods.append(OS.get_keycode_string(code))
		return "+".join(mods)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "Left click"
			MOUSE_BUTTON_RIGHT: return "Right click"
			MOUSE_BUTTON_MIDDLE: return "Middle click"
			_: return "Mouse %d" % int((ev as InputEventMouseButton).button_index)
	return ""


## A visible Button whose text is `text` (exact), or whose text CONTAINS it
## when `partial`.
static func find_button(root: Node, text: String, partial: bool = false) -> Button:
	if root == null:
		return null
	for n in root.find_children("*", "Button", true, false):
		var b := n as Button
		if not b.is_visible_in_tree():
			continue
		if b.text == text or (partial and b.text.find(text) >= 0):
			return b
	return null


static func center_of(c: Control) -> Vector2:
	var r := c.get_global_rect()
	return r.position + r.size / 2.0


## Screen position of a ground point (xz) a little above the surface.
static func ground_screen(cam: Camera3D, loader: Node, w: Vector2, lift: float = 0.3) -> Vector2:
	var y := 0.0
	if loader != null and loader.has_method("ground_height_at"):
		y = float(loader.call("ground_height_at", w.x, w.y))
	return cam.unproject_position(Vector3(w.x, y + lift, w.y))

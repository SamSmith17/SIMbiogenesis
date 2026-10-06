class_name ModifierKeys
extends RefCounted

## Ctrl / Alt as the INPUT EVENTS report them — the selection modifier for
## crosshair focus (props, camps, lights) and the J light IK spheres.
##
## Why not Input.is_key_pressed(KEY_CTRL): that reads Godot's key table, which
## goes stale when a release is never delivered — classically Alt+Tab (the Alt
## release lands in another window) — and then every Ctrl/Alt-gated highlight
## stays on "as you walk around". Every InputEventWithModifiers (each mouse
## motion included) carries the OS's CURRENT modifier state, so taking the
## latest event's flags heals a stuck key the moment the mouse moves.
## interaction_focus feeds this from _input and clears it on focus loss.

static var _ctrl := false
static var _alt := false
static var _shift := false


static func observe(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		match k.keycode:
			KEY_CTRL:
				_ctrl = k.pressed
				_alt = k.alt_pressed
				_shift = k.shift_pressed
				return
			KEY_ALT:
				_alt = k.pressed
				_ctrl = k.ctrl_pressed
				_shift = k.shift_pressed
				return
			KEY_SHIFT:
				_shift = k.pressed
				_ctrl = k.ctrl_pressed
				_alt = k.alt_pressed
				return
	if event is InputEventWithModifiers:
		var m := event as InputEventWithModifiers
		_ctrl = m.ctrl_pressed
		_alt = m.alt_pressed
		_shift = m.shift_pressed


static func reset() -> void:
	_ctrl = false
	_alt = false
	_shift = false


static func ctrl() -> bool:
	return _ctrl


static func alt() -> bool:
	return _alt


## Shift with a selection drag = duplicate (J lights).
static func shift() -> bool:
	return _shift


## The crosshair selection modifier (Alt documented, Ctrl accepted).
static func selecting() -> bool:
	return _ctrl or _alt

extends Node

## Lives INSIDE each extra Window Wall window and hands that window's input to
## the view. A native `Window` only emits `window_input` for events the OS
## delivered to it, never for `push_input` — so a relay NODE is what makes the
## extra windows both drivable by the harness and responsive to a real key
## press when one of them has focus (the Phase 0 spike measured exactly that).
##
## ⚠ The view can CLOSE from inside the call below — Esc is handled here — and
## closing frees every extra window, which frees THIS node and the viewport it
## lives in while this function is still on the stack. So the viewport is
## captured BEFORE calling in and re-validated after, and nothing touches
## `self` past that point. Reaching for `get_viewport()` afterwards is the
## "Cannot call method 'get_viewport' on a previously freed instance" crash.

var view: Node = null
var slot := -1


func _input(event: InputEvent) -> void:
	if view == null or not is_instance_valid(view):
		return
	var vp := get_viewport()
	if not bool(view.call("handle_window_event", event, slot)):
		return
	if is_instance_valid(vp):
		vp.set_input_as_handled()

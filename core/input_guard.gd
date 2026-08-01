class_name InputGuard
extends RefCounted

## Shared guards for global keyboard shortcuts. Static-only utility — never
## instantiated, never an autoload (same shape as TerrainCacheSettings).
##
## Why this exists: "does a text field have focus?" was reimplemented inline in
## several handlers and simply omitted in others, so typing a letter into the
## location picker or a save-slot name fired game shortcuts and the character
## was swallowed by set_input_as_handled(). The canonical spelling now lives in
## one place, short enough that there is no excuse to skip it:
##
##     func _unhandled_input(e: InputEvent) -> void:
##         if InputGuard.blocked(get_viewport()):
##             return
##
## `key_pressed()` additionally normalises to physical_keycode, which is the
## layout-independent field every InputMap action in this project uses. Raw
## handlers that compared `.keycode` drifted on AZERTY/Dvorak while everything
## around them stayed put.

## True when a text field owns keyboard focus, so a letter key is being TYPED
## rather than used as a shortcut. Checked against the concrete Godot text
## controls; CodeEdit/TextEdit and SpinBox's internal LineEdit are all covered
## because SpinBox focuses its LineEdit child, not itself.
static func text_focused(vp: Viewport) -> bool:
	if vp == null:
		return false
	var fo: Control = vp.gui_get_focus_owner()
	return fo is LineEdit or fo is TextEdit


## True when a global shortcut must NOT fire: either a text field has focus, or
## a blocking modal is on CursorController's stack.
##
## Resolves CursorController by path rather than as a bare autoload identifier
## so this file still compiles under `--headless --script` selftests, which run
## without autoloads registered.
static func blocked(vp: Viewport) -> bool:
	if text_focused(vp):
		return true
	if vp == null:
		return false
	var tree := vp.get_tree()
	if tree == null or tree.root == null:
		return false
	var cc := tree.root.get_node_or_null("CursorController")
	if cc != null and cc.has_method("has_blocking_modal"):
		return bool(cc.call("has_blocking_modal"))
	return false


## True for a fresh (non-echo) press of `keycode`, compared on physical_keycode
## with a fallback to keycode for events that only carry the latter (synthetic
## events and some IME paths).
static func key_pressed(e: InputEvent, keycode: Key) -> bool:
	if e is not InputEventKey:
		return false
	var k := e as InputEventKey
	if not k.pressed or k.echo:
		return false
	var code := k.physical_keycode if k.physical_keycode != 0 else k.keycode
	return code == keycode

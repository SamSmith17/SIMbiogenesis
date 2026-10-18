class_name InputOverrides
extends RefCounted

## The player's key bindings over the project's InputMap — the data layer of
## Settings → Controls. PURE except for the file and the InputMap it is asked
## to touch, so core/input_map_selftest.gd can drive it on a TEMP path.
##
## File: user://input_overrides.cfg
##   [meta]      version = 1
##   [bindings]  <action> = "<binding>"
## One binding per action, as text, so the file reads and diffs by hand:
##   "key <physical keycode> [ctrl] [shift] [alt] [meta]"   e.g. "key 71 ctrl"
##   "mouse <button index>"                                  e.g. "mouse 4"
##   "none"                                                  (unbound on keyboard)
## Physical keycodes on purpose — the project's own rule (input_map_selftest):
## a binding by keycode moves on AZERTY / Dvorak. A line that does not parse
## is reported and skipped, never applied as something else.
##
## Applied once at boot (CursorController._ready → apply_saved): for every
## overridden action the KEYBOARD AND MOUSE events are erased and the one
## binding added; joypad events stay. The F1 help overlay, the tour's title
## cards and the interaction prompt all read the InputMap (or ask
## is_overridden first), so a rebound key shows everywhere.

const PATH := "user://input_overrides.cfg"
const SECTION := "bindings"
const META_SECTION := "meta"
const VERSION := 1
const NONE := "none"

## Mouse buttons a binding may use: never the two the UI and the look use.
const MOUSE_MIN_BUTTON := MOUSE_BUTTON_MIDDLE

static var _cache: Dictionary = {}
static var _cache_path := ""
static var _cache_valid := false


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

## "key 71 ctrl shift" / "mouse 4" / "" (an event this format cannot hold).
static func encode(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_NONE:
			return ""
		var parts := PackedStringArray(["key", str(int(code))])
		if k.ctrl_pressed:
			parts.append("ctrl")
		if k.shift_pressed:
			parts.append("shift")
		if k.alt_pressed:
			parts.append("alt")
		if k.meta_pressed:
			parts.append("meta")
		return " ".join(parts)
	if ev is InputEventMouseButton:
		var b := int((ev as InputEventMouseButton).button_index)
		if b < MOUSE_MIN_BUTTON:
			return ""
		return "mouse %d" % b
	return ""


## The event a binding names; null for "none" and for anything malformed.
static func decode(text: String) -> InputEvent:
	var parts := text.strip_edges().to_lower().split(" ", false)
	if parts.size() < 2:
		return null
	match parts[0]:
		"key":
			if not parts[1].is_valid_int():
				return null
			var code := int(parts[1])
			if code <= 0 or (code & KEY_CODE_MASK) != code:
				return null
			var k := InputEventKey.new()
			k.physical_keycode = code as Key
			for i in range(2, parts.size()):
				match parts[i]:
					"ctrl": k.ctrl_pressed = true
					"shift": k.shift_pressed = true
					"alt": k.alt_pressed = true
					"meta": k.meta_pressed = true
					_: return null
			return k
		"mouse":
			if parts.size() != 2 or not parts[1].is_valid_int():
				return null
			var b := int(parts[1])
			if b < MOUSE_MIN_BUTTON or b > MOUSE_BUTTON_XBUTTON2:
				return null
			var m := InputEventMouseButton.new()
			m.button_index = b as MouseButton
			return m
	return null


## Well-formed: "none", or something decode() accepts.
static func is_valid(text: String) -> bool:
	return text.strip_edges().to_lower() == NONE or decode(text) != null


## "71|1000" — what makes two bindings the same key (the selftest's own rule).
static func signature(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		if code == KEY_NONE:
			return ""
		return "%d|%d%d%d%d" % [int(code), 1 if k.ctrl_pressed else 0, 1 if k.shift_pressed else 0,
			1 if k.alt_pressed else 0, 1 if k.meta_pressed else 0]
	if ev is InputEventMouseButton:
		return "m%d" % int((ev as InputEventMouseButton).button_index)
	return ""


# ---------------------------------------------------------------------------
# File
# ---------------------------------------------------------------------------

## action -> binding text, well-formed entries only (a malformed line is
## printed and dropped). {} when there is no file.
static func read(path: String = PATH) -> Dictionary:
	var out := {}
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK or not cfg.has_section(SECTION):
		return out
	for action in cfg.get_section_keys(SECTION):
		var v := str(cfg.get_value(SECTION, action, ""))
		if is_valid(v):
			out[str(action)] = v.strip_edges().to_lower()
		else:
			push_warning("InputOverrides: ignoring '%s = %s' in %s (not a binding)" % [action, v, path])
	return out


static func write(overrides: Dictionary, path: String = PATH) -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value(META_SECTION, "version", VERSION)
	var keys := overrides.keys()
	keys.sort()
	for action in keys:
		cfg.set_value(SECTION, str(action), str(overrides[action]))
	var err := cfg.save(path)
	if path == _cache_path:
		_cache_valid = false
	return err


## The saved overrides, cached for the hot readers (labels).
static func saved(path: String = PATH) -> Dictionary:
	if not _cache_valid or _cache_path != path:
		_cache = read(path)
		_cache_path = path
		_cache_valid = true
	return _cache


static func is_overridden(action: String, path: String = PATH) -> bool:
	return saved(path).has(action)


# ---------------------------------------------------------------------------
# The project's own bindings
# ---------------------------------------------------------------------------

## The actions project.godot's [input] section defines (not Godot's built-in
## ui_* defaults), each with its ORIGINAL events. Parsed the way
## input_map_selftest does: the names off the file, the events off
## ProjectSettings, so keycode vs physical_keycode survives.
static func project_actions() -> Dictionary:
	var out := {}
	var f := FileAccess.open("res://project.godot", FileAccess.READ)
	if f == null:
		return out
	var in_input := false
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("["):
			in_input = (line == "[input]")
			continue
		if not in_input or line.is_empty() or line.begins_with(";"):
			continue
		var eq := line.find("=")
		if eq <= 0 or not line.substr(eq + 1).begins_with("{"):
			continue
		var action := line.substr(0, eq).strip_edges()
		if action.is_empty():
			continue
		out[action] = default_events(action)
	f.close()
	return out


## The events project.godot gives an action (copies). [] for an unknown one.
static func default_events(action: String) -> Array:
	var cfg: Variant = ProjectSettings.get_setting("input/" + action)
	var out: Array = []
	if cfg is Dictionary:
		for ev in ((cfg as Dictionary).get("events", []) as Array):
			if ev is InputEvent:
				out.append((ev as InputEvent).duplicate())
	return out


# ---------------------------------------------------------------------------
# The live InputMap
# ---------------------------------------------------------------------------

## Put one binding on an action: its keyboard / mouse events go, joypad
## events stay, the binding (if any) is added. Returns false for an action
## the InputMap does not have.
static func apply_one(action: String, binding: String) -> bool:
	if not InputMap.has_action(action):
		return false
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey or ev is InputEventMouseButton:
			InputMap.action_erase_event(action, ev)
	var new_ev := decode(binding)
	if new_ev != null:
		InputMap.action_add_event(action, new_ev)
	return true


## Every override in `overrides` onto the InputMap; the number applied.
static func apply(overrides: Dictionary) -> int:
	var n := 0
	for action in overrides:
		if apply_one(str(action), str(overrides[action])):
			n += 1
	return n


static func apply_saved(path: String = PATH) -> int:
	return apply(saved(path))


## Back to project.godot's events for one action (all of them, joypad too).
static func restore_default(action: String) -> void:
	if not InputMap.has_action(action):
		return
	InputMap.action_erase_events(action)
	for ev in default_events(action):
		InputMap.action_add_event(action, ev)


## Settings → Controls: bind `action` to `ev` (or "none"), on the InputMap
## and in the file. Refuses an event the format cannot hold.
static func set_binding(action: String, ev: InputEvent, path: String = PATH) -> bool:
	var text := NONE if ev == null else encode(ev)
	if text.is_empty():
		return false
	var ovr := saved(path).duplicate()
	ovr[action] = text
	if write(ovr, path) != OK:
		return false
	apply_one(action, text)
	return true


## Settings → Controls → ↺: drop the override and put the default back.
static func clear_binding(action: String, path: String = PATH) -> void:
	var ovr := saved(path).duplicate()
	if ovr.has(action):
		ovr.erase(action)
		write(ovr, path)
	restore_default(action)


static func clear_all(path: String = PATH) -> void:
	for action in saved(path).keys():
		restore_default(str(action))
	write({}, path)


## The other actions on the InputMap that `ev` would also fire — shown as a
## warning, never a refusal (the project has deliberate overlaps).
static func conflicts(action: String, ev: InputEvent) -> PackedStringArray:
	var out := PackedStringArray()
	var sig := signature(ev)
	if sig.is_empty():
		return out
	for other in InputMap.get_actions():
		var name := str(other)
		if name == action:
			continue
		for oev in InputMap.action_get_events(name):
			if signature(oev) == sig:
				out.append(name)
				break
	return out

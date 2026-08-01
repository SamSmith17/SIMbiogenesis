extends SceneTree

## Offline deterministic selftest for the project's InputMap (project.godot's
## [input] section).
##
## Run: Godot.exe.exe --headless --path . --script core/input_map_selftest.gd
##
## Why this exists: keybinding collisions and focus-guard omissions are a
## recurring bug class here, and they are invisible to every other selftest
## because they live in project.godot, not in code. Three defects shipped at
## once — Shift driving both `sprint` and `drone_ascend`, V driving both
## `toggle_camera` and `vegetation_edit`, and `placed_props_edit` bound to
## NOTHING (which made the Placed Props panel unreachable from either of its two
## keyboard openers). A hand-maintained list in a markdown file does not catch
## that; this does.
##
## It reads ProjectSettings' `input/*` properties rather than
## `InputMap.get_actions()` on purpose: that yields EXACTLY the project-defined
## actions, with none of Godot's ~40 built-in `ui_*` defaults, and it hands back
## the raw InputEvent objects so `keycode` vs `physical_keycode` can be told
## apart (InputMap normalises away the distinction we are trying to police).
##
## Adding an intentional overlap: put it in ALLOWED_OVERLAPS with a reason that
## names the file:line doing the disambiguation. If you cannot name one, the
## overlap is a bug, not a design.

## Key overlaps that are deliberate and disambiguated in code. Order-independent:
## the pair is matched as a set.
const ALLOWED_OVERLAPS: Array = [
	{
		"actions": ["interact", "vegetation_area_edit"],
		"reason": "disambiguated by aim context in gameplay/interaction_focus.gd:872-878",
	},
]

## Actions deliberately left unbound on keyboard (gamepad-only, or bound at
## runtime). An action with no events at all is otherwise a dead action.
const ALLOWED_UNBOUND: Array = []

var _fails := 0
var _checks := 0


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


# _initialize (not _init): ProjectSettings is fully populated by engine start,
# but this keeps the entry point identical to every other selftest here.
func _initialize() -> void:
	var actions := _project_actions()
	_check("project defines input actions", actions.size() > 0,
		"found none — did the [input] section move?")

	_test_every_action_is_bound(actions)
	_test_physical_keycodes(actions)
	_test_no_key_collisions(actions)
	_test_whitelist_is_live(actions)

	if _fails == 0:
		print("INPUT MAP SELFTEST PASS  (%d checks, %d actions)" % [_checks, actions.size()])
	else:
		print("INPUT MAP SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


## action_name -> Array[InputEvent], for project-defined actions ONLY.
##
## The action NAMES come from parsing project.godot's [input] section, not from
## ProjectSettings.get_property_list() — that list also carries Godot's ~40
## built-in `ui_*` defaults (ui_text_delete_all_to_right, ui_close_dialog.macos,
## …), several of which legitimately have empty bindings or use `keycode`, and
## none of which this project controls. Filtering by a `ui_` prefix instead would
## wrongly skip `ui_accept`/`ui_cancel`, which this project DOES override.
##
## The event objects still come from ProjectSettings, so the raw
## keycode/physical_keycode distinction survives.
func _project_actions() -> Dictionary:
	var out: Dictionary = {}
	var f := FileAccess.open("res://project.godot", FileAccess.READ)
	if f == null:
		_check("project.godot readable", false, "could not open res://project.godot")
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
		var cfg: Variant = ProjectSettings.get_setting("input/" + action)
		out[action] = ((cfg as Dictionary).get("events", []) as Array) \
			if cfg is Dictionary else []
	f.close()
	return out


## An action with an empty events array is dead: every handler keyed to it is
## unreachable. This is exactly how `placed_props_edit` orphaned its panel.
func _test_every_action_is_bound(actions: Dictionary) -> void:
	for action: String in actions.keys():
		if action in ALLOWED_UNBOUND:
			continue
		var events: Array = actions[action]
		_check("action '%s' has a binding" % action, events.size() > 0,
			"empty events array — every handler for this action is unreachable")


## Key events must use physical_keycode so bindings stay put on AZERTY/Dvorak.
## Mixing the two is how KEY_Y / KEY_C drifted away from every other shortcut.
func _test_physical_keycodes(actions: Dictionary) -> void:
	for action: String in actions.keys():
		for ev: Variant in actions[action]:
			if ev is not InputEventKey:
				continue
			var k := ev as InputEventKey
			if k.physical_keycode == 0 and k.keycode != 0:
				_check("action '%s' uses physical_keycode" % action, false,
					"bound via keycode %d (%s) — moves on non-QWERTY layouts" % [
						k.keycode, OS.get_keycode_string(k.keycode)])


## Two actions on the same key+modifier combination both fire from one press
## unless something consumes the event first. Whitelist the intentional ones.
func _test_no_key_collisions(actions: Dictionary) -> void:
	var by_key: Dictionary = {}   # signature -> Array[action]
	for action: String in actions.keys():
		for ev: Variant in actions[action]:
			if ev is not InputEventKey:
				continue
			var sig := _key_signature(ev as InputEventKey)
			if sig.is_empty():
				continue
			var owners: Array = by_key.get(sig, [])
			if action not in owners:
				owners.append(action)
			by_key[sig] = owners

	for sig: String in by_key.keys():
		var owners: Array = by_key[sig]
		if owners.size() < 2:
			continue
		owners.sort()
		# NOTE the parentheses: `%` binds tighter than `+`, so building this
		# message as "a " + "b" % [x] would format the SECOND literal and drop
		# the substitution silently (the same precedence trap already fixed once
		# in GraphFaultCardModal).
		var detail := ("bound to %s — both fire from one press. Disambiguate in "
			+ "code and add to ALLOWED_OVERLAPS with the file:line, or rebind one.") \
			% ", ".join(owners)
		_check("key %s is not double-bound" % _describe_signature(sig),
			_is_allowed_overlap(owners), detail)


## A whitelist entry naming actions that no longer collide is stale and hides
## the next real collision on that key. Fail on it rather than let it rot.
func _test_whitelist_is_live(actions: Dictionary) -> void:
	for entry: Dictionary in ALLOWED_OVERLAPS:
		var pair: Array = entry.get("actions", []) as Array
		_check("whitelist entry %s has a reason" % [pair],
			not str(entry.get("reason", "")).is_empty())
		for action: Variant in pair:
			_check("whitelisted action '%s' still exists" % action,
				actions.has(str(action)),
				"ALLOWED_OVERLAPS names an action the project no longer defines")


func _key_signature(k: InputEventKey) -> String:
	var code := k.physical_keycode if k.physical_keycode != 0 else k.keycode
	if code == 0:
		return ""
	return "%d|%d%d%d%d" % [code,
		1 if k.ctrl_pressed else 0, 1 if k.shift_pressed else 0,
		1 if k.alt_pressed else 0, 1 if k.meta_pressed else 0]


func _describe_signature(sig: String) -> String:
	var parts := sig.split("|")
	if parts.size() != 2:
		return sig
	var mods := parts[1]
	var out := ""
	if mods.length() == 4:
		if mods[0] == "1": out += "Ctrl+"
		if mods[1] == "1": out += "Shift+"
		if mods[2] == "1": out += "Alt+"
		if mods[3] == "1": out += "Meta+"
	return out + OS.get_keycode_string(int(parts[0]))


func _is_allowed_overlap(owners: Array) -> bool:
	for entry: Dictionary in ALLOWED_OVERLAPS:
		var pair: Array = (entry.get("actions", []) as Array).duplicate()
		pair.sort()
		if pair == owners:
			return true
	return false

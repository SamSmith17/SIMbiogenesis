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

## Key overlaps that are deliberate AND disambiguated in code. Order-independent:
## the pair is matched as a set. Every entry must name the file:line that does
## the disambiguating — if you cannot, it belongs in KNOWN_CONFLICTS instead.
const ALLOWED_OVERLAPS: Array = [
	{
		"actions": ["interact", "vegetation_area_edit"],
		"reason": "disambiguated by aim context in gameplay/interaction_focus.gd:872-878",
	},
	{
		"actions": ["sprint", "drone_ascend"],
		"reason": "mode-exclusive: sprint is polled only in scenes/gameplay/player.gd:549, "
			+ "drone_ascend only in scenes/gameplay/fpv_drone.gd:309, and the player and "
			+ "the drone are never both driving",
	},
	{
		"actions": ["mp_chat", "ui_accept"],
		"reason": "scenes/ui/multiplayer_chat_hud.gd:139 handles mp_chat in _unhandled_input, "
			+ "so a focused Control consumes Enter as ui_accept first; it further guards on "
			+ "visible + session active + not composing + no blocking modal",
	},
	{
		"actions": ["toggle_light_menu", "toggle_pallet_rack"],
		"reason": "contextual: scenes/gameplay/govee_lights.gd:914 only handles the key while "
			+ "the player is in range of a light and consumes it, so main.gd's pallet-rack "
			+ "branch in _unhandled_input runs everywhere else",
	},
	{
		"actions": ["charge", "camp_scatter"],
		"reason": "resolved 2026-08-05: `charge` is now event-driven in "
			+ "scenes/gameplay/player.gd:_unhandled_input (consumes only when it actually "
			+ "starts charging), and terrain_loader.gd's camp_scatter branch (now the "
			+ "toolbar's Camps section; the legacy dock moved to Shift+C) yields the "
			+ "event when player.charge_available() — deterministic in either "
			+ "_unhandled_input order. The old polling from _physics_process ignored "
			+ "set_input_as_handled() and fired BOTH.",
	},
]

## Overlaps that are REAL bugs — tracked, deliberately not failing the build yet,
## and never to be laundered into ALLOWED_OVERLAPS. Keeping them separate is the
## point: ALLOWED_OVERLAPS means "resolved", this means "known and unresolved".
const KNOWN_CONFLICTS: Array = []

## Actions deliberately left unbound on keyboard (gamepad-only, or bound at
## runtime). An action with no events at all is otherwise a dead action.
const ALLOWED_UNBOUND: Array = []

## Actions that are deliberately CONTROLLER-ONLY. Each entry names the keyboard
## path that stands in for it (or why none is needed). A working handler behind
## a joypad-only binding is invisible to every keyboard player — toggle_solar_ui
## shipped that way and the Solar HUD could not be toggled from a keyboard at
## all — so gamepad-only is a declared choice here or it is a bug.
const ALLOWED_KEYBOARD_UNBOUND: Dictionary = {
	"jump": "no keyboard jump verb by design; walking gameplay never requires it",
	"look_left": "mouse-look is the keyboard path",
	"look_right": "mouse-look is the keyboard path",
	"look_up": "mouse-look is the keyboard path",
	"look_down": "mouse-look is the keyboard path",
	"use_tool": "LMB fallback hardcoded in scenes/gameplay/player.gd (use_tool poll)",
	"toggle_tool": "keyboard uses equip_tool/unequip_tool (1 / 0) instead",
	"sim_speed_up": "timeline-bar speed buttons are the keyboard path (timeline_ui.gd)",
	"sim_speed_down": "timeline-bar speed buttons are the keyboard path (timeline_ui.gd)",
}

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
	_test_keyboard_coverage(actions)
	_test_no_key_collisions(actions)
	_test_whitelist_is_live(actions)
	_test_override_format(actions)

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
			# A code outside KEY_CODE_MASK can never match a real key event.
			# The projection actions shipped with Godot 3 F-key values
			# (1677724x) and were dead for months — only the hardcoded
			# fallbacks in projection_canvas.gd kept the feature alive.
			var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode
			if code != 0 and (code & KEY_CODE_MASK) != code:
				_check("action '%s' keycode is a valid Godot 4 key" % action, false,
					"%d exceeds KEY_CODE_MASK — a Godot 3 keycode, unmatchable in Godot 4" % code)


## Every action must be reachable from a keyboard/mouse unless it is declared
## controller-only in ALLOWED_KEYBOARD_UNBOUND. Both directions are policed:
## an undeclared joypad-only action fails, and a declared entry that has since
## gained a keyboard binding fails as a stale whitelist row.
func _test_keyboard_coverage(actions: Dictionary) -> void:
	for action: String in actions.keys():
		var has_kb := false
		for ev: Variant in actions[action]:
			if ev is InputEventKey or ev is InputEventMouseButton:
				has_kb = true
				break
		var declared: bool = ALLOWED_KEYBOARD_UNBOUND.has(action)
		if not has_kb and not declared:
			_check("action '%s' reachable from keyboard" % action, false,
				"joypad-only binding with no ALLOWED_KEYBOARD_UNBOUND entry — "
				+ "keyboard players cannot fire it")
		elif has_kb and declared:
			_check("ALLOWED_KEYBOARD_UNBOUND entry for '%s' is live" % action, false,
				"now has a keyboard binding — drop the stale whitelist row")


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
		if _matches(KNOWN_CONFLICTS, owners):
			# Reported, not failed — see KNOWN_CONFLICTS.
			print("  KNOWN CONFLICT: %s bound to %s" % [
				_describe_signature(sig), ", ".join(owners)])
			continue
		# NOTE the parentheses: `%` binds tighter than `+`, so building this
		# message as "a " + "b" % [x] would format the SECOND literal and drop
		# the substitution silently (the same precedence trap already fixed once
		# in GraphFaultCardModal).
		var detail := ("bound to %s — both fire from one press. Disambiguate in "
			+ "code and add to ALLOWED_OVERLAPS with the file:line, or rebind one.") \
			% ", ".join(owners)
		_check("key %s is not double-bound" % _describe_signature(sig),
			_matches(ALLOWED_OVERLAPS, owners), detail)


## A whitelist entry naming actions that no longer collide is stale and hides
## the next real collision on that key. Fail on it rather than let it rot.
##
## `ui_accept` is exempt from the existence check: it is a Godot built-in that
## this project overrides, so it is real even when project.godot's [input]
## section is not where the name comes from.
func _test_whitelist_is_live(actions: Dictionary) -> void:
	for table: Array in [ALLOWED_OVERLAPS, KNOWN_CONFLICTS]:
		for entry: Dictionary in table:
			var pair: Array = entry.get("actions", []) as Array
			_check("whitelist entry %s has a reason" % [pair],
				not str(entry.get("reason", "")).is_empty())
			for action: Variant in pair:
				var name := str(action)
				if not InputMap.has_action(name):
					_check("whitelisted action '%s' still exists" % name, false,
						"names an action neither project.godot nor the engine defines")
					continue
				_check("whitelisted action '%s' still exists" % name,
					actions.has(name) or name.begins_with("ui_"))


## The player's rebinding file (core/input_overrides.gd, Settings →
## Controls): the text format round-trips, a malformed line is dropped rather
## than applied as something else, the file round-trips through a TEMP path,
## applying an override replaces an action's key / mouse events and keeps its
## joypad ones, ↺ restores project.godot's events exactly, "none" unbinds,
## and the project-action parser agrees with this file's own. Loaded by path:
## the selftest must not depend on the global class cache.
func _test_override_format(actions: Dictionary) -> void:
	var io: Variant = load("res://core/input_overrides.gd")
	_check("InputOverrides loads", io != null)
	if io == null:
		return
	# Encoding.
	var k := InputEventKey.new()
	k.physical_keycode = KEY_G
	k.ctrl_pressed = true
	k.shift_pressed = true
	_check("a key with modifiers encodes", io.encode(k) == "key %d ctrl shift" % int(KEY_G),
		"got '%s'" % io.encode(k))
	var back: Variant = io.decode(io.encode(k))
	_check("…and decodes back to the same physical key + modifiers",
		back is InputEventKey and (back as InputEventKey).physical_keycode == KEY_G
		and (back as InputEventKey).ctrl_pressed and (back as InputEventKey).shift_pressed
		and not (back as InputEventKey).alt_pressed and (back as InputEventKey).keycode == KEY_NONE)
	var m := InputEventMouseButton.new()
	m.button_index = MOUSE_BUTTON_XBUTTON1
	_check("a mouse side button encodes as 'mouse 8'", io.encode(m) == "mouse 8", "got '%s'" % io.encode(m))
	var mb: Variant = io.decode("mouse 8")
	_check("…and decodes", mb is InputEventMouseButton and (mb as InputEventMouseButton).button_index == MOUSE_BUTTON_XBUTTON1)
	var lmb := InputEventMouseButton.new()
	lmb.button_index = MOUSE_BUTTON_LEFT
	_check("the left and right mouse buttons are never a binding",
		io.encode(lmb) == "" and io.decode("mouse 1") == null and io.decode("mouse 2") == null)
	for bad in ["key", "key abc", "key 71 hyper", "key 0", "key 16777281", "mouse", "mouse x", "pedal 3", ""]:
		_check("malformed '%s' decodes to null" % bad, io.decode(bad) == null)
	_check("'none' is valid (unbound) but decodes to null", io.is_valid("none") and io.decode("none") == null)
	_check("a Godot 3 keycode is refused (outside KEY_CODE_MASK)", io.decode("key 16777241") == null)
	# File round trip on a TEMP path.
	var path := "user://input_overrides_selftest_%d.cfg" % Time.get_ticks_usec()
	var written := {"toggle_help": "key %d" % int(KEY_F6), "interact": "mouse 4", "junk_action": "key 71 ctrl"}
	_check("write() returns OK", io.write(written, path) == OK)
	var cfg := ConfigFile.new()
	cfg.load(path)
	cfg.set_value("bindings", "broken_action", "key banana")
	cfg.save(path)
	var read: Dictionary = io.read(path)
	_check("read() returns every well-formed entry and drops the malformed one",
		read.size() == 3 and read.get("toggle_help", "") == "key %d" % int(KEY_F6)
		and read.get("interact", "") == "mouse 4" and not read.has("broken_action"),
		"got %s" % str(read))
	_check("the file carries its format version", int(cfg.get_value("meta", "version", 0)) == 1)
	# Apply on the live InputMap: toggle_help (a project action with a key
	# binding) gets F6; a joypad event added first survives; the default
	# comes back exactly.
	var action := "toggle_help"
	_check("the sample action exists in the project", actions.has(action))
	if actions.has(action):
		var pad := InputEventJoypadButton.new()
		pad.button_index = JOY_BUTTON_BACK
		InputMap.action_add_event(action, pad)
		var n: int = io.apply(read)
		_check("apply() counts the actions the InputMap has (not the junk one)", n == 2, "applied %d" % n)
		var evs := InputMap.action_get_events(action)
		var keys := 0
		var f6 := false
		var pads := 0
		for ev in evs:
			if ev is InputEventKey:
				keys += 1
				f6 = f6 or (ev as InputEventKey).physical_keycode == KEY_F6
			elif ev is InputEventJoypadButton:
				pads += 1
		_check("the override replaced the key events with F6 and kept the joypad event",
			keys == 1 and f6 and pads == 1, "keys %d f6 %s pads %d" % [keys, str(f6), pads])
		# Against an action the file above did NOT touch (interact's key is
		# gone by now — it was overridden to a mouse button).
		var other := "move_forward"
		var other_key: InputEvent = null
		for oev in (actions.get(other, []) as Array):
			if oev is InputEventKey:
				other_key = oev
				break
		_check("conflicts() names another action on the same key",
			other_key != null and other in Array(io.conflicts(action, io.decode(io.encode(other_key)))))
		io.restore_default(action)
		io.restore_default("interact")
		var want: Array = io.default_events(action)
		var got := InputMap.action_get_events(action)
		var same := want.size() == got.size()
		for i in mini(want.size(), got.size()):
			same = same and io.signature(want[i]) == io.signature(got[i]) \
				and (want[i] as InputEvent).get_class() == (got[i] as InputEvent).get_class()
		_check("restore_default() puts project.godot's events back, joypad included",
			same and got.size() == (actions[action] as Array).size(), "want %d got %d" % [want.size(), got.size()])
		_check("'none' unbinds the keyboard", io.apply_one(action, "none")
			and InputMap.action_get_events(action).size() == (actions[action] as Array).size() - 1)
		io.restore_default(action)
	# The parser the UI uses agrees with this file's own.
	var theirs: Dictionary = io.project_actions()
	var mine := actions.keys()
	mine.sort()
	var ours := theirs.keys()
	ours.sort()
	_check("InputOverrides.project_actions() lists exactly the project's actions", mine == ours,
		"%d vs %d" % [mine.size(), ours.size()])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


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


func _matches(table: Array, owners: Array) -> bool:
	for entry: Dictionary in table:
		var pair: Array = (entry.get("actions", []) as Array).duplicate()
		pair.sort()
		if pair == owners:
			return true
	return false

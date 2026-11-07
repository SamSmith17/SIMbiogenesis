extends VBoxContainer

## The WHEN / IF / THEN automation cards (Home Assistant shaped), as one
## reusable widget: the graph inspector uses it for a load's
## specs.graph_automations, and a designer (the TC Process Lab's Control tab)
## can use it for a design's own sensors and actuators.
##
## The editor owns a working copy of the automation array. Every edit emits
## `automations_changed(autos)` with the WHOLE array; the owner persists it.
## Edits that change the card layout (a row added, a kind changed, a card
## expanded) also ask for a rebuild: with `auto_rebuild` the editor rebuilds
## itself, otherwise it emits `rebuild_requested` (the inspector rebuilds its
## whole form, which makes a fresh editor from the model).
##
## Fed by a PROVIDER, a Dictionary of what the rules can read and drive
## (every key optional):
##   numeric:      Callable() -> [{label, key}]  numeric signals (entity ids);
##                 key "__custom__" = a typed entity id
##   states:       Callable() -> [{label, key}]  state entities (+ "__custom__")
##   state_values: Callable(entity_id) -> [{label, key}]  values to match
##   targets:      Callable() -> [{label, key}]  actuators of the rule's item
##                 for scene_node actions; key "" = the whole item. No list
##                 (or an empty one) = no Target row, the whole item.
##   settable:     Callable() -> [{label, key, min?, max?, step?, unit?}]
##                 entities a set_value action can write (+ "__custom__")
##   action_labels: {kind: label}  the THEN menu's wording per action kind
##   action_kinds: [kind]  which action kinds the menu offers
##                 (default scene_node, set_value, delay)
##   templates:    [{label, specs: [automation]}]  the "+ Preset..." menu
##
## Spec shapes (the same AutomationSim and the live engine read):
##   triggers   time {at_hour} | sun {event, offset_hours} |
##              numeric {entity_id, above?, below?} | state {entity_id, to_state}
##   conditions time {after_hour, before_hour} | sun {state} |
##              numeric {entity_id, above?, below?} | state {entity_id, states}
##   actions    scene_node {command, target?} | set_value {entity_id, value} |
##              delay {delay_seconds}

signal automations_changed(autos: Array)
signal rebuild_requested()
signal automation_removed(auto_id: String)
signal push_requested(auto_id: String)
signal ab_requested(auto_id: String)
signal message(text: String)

const C_BG      := UITheme.C_BG
const C_PANEL   := UITheme.C_PANEL_RAISED
const C_BORDER  := UITheme.C_BORDER
const C_PRIMARY := UITheme.C_PRIMARY
const C_TEXT    := UITheme.C_TEXT
const C_TEXT_S  := UITheme.C_TEXT_S
const C_TEXT_M  := UITheme.C_TEXT_M
const C_AMBER   := UITheme.C_AMBER

const KIND_TRIGGER   := "trigger"
const KIND_CONDITION := "condition"
const KIND_ACTION    := "action"
const CUSTOM := "__custom__"

const DEFAULT_ACTION_KINDS := ["scene_node", "set_value", "delay"]
const DEFAULT_ACTION_LABELS := {
	"scene_node": "Turn on/off/toggle",
	"set_value":  "Set a value",
	"delay":      "Delay (seconds)",
}

var provider: Dictionary = {}
## auto_id -> bool, which cards are open. Pass the owner's own dictionary to
## keep it across rebuilds (Dictionaries are shared by reference).
var expanded: Dictionary = {}
## () -> String, a fresh automation id.
var id_factory: Callable = Callable()
var show_ab := true
var show_push := true
var empty_hint := "No automations yet. Pick a preset below, or build a custom WHEN → THEN rule."
var auto_rebuild := false

var _autos: Array = []
var _id_counter := 0


func _init() -> void:
	add_theme_constant_override("separation", 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


## Load `autos` and build the cards now (synchronously, so an owner that
## walks its form afterwards sees every control).
func setup(autos: Array, provider_: Dictionary = {}) -> void:
	provider = provider_
	_autos = autos.duplicate(true)
	rebuild()


func get_automations() -> Array:
	return _autos.duplicate(true)


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	if _autos.is_empty():
		_hint(empty_hint)
	else:
		for i in range(_autos.size()):
			_build_card(i)
	_build_footer()


# ---------------------------------------------------------------------------
# Commits
# ---------------------------------------------------------------------------

func _commit(structural: bool) -> void:
	automations_changed.emit(_autos.duplicate(true))
	if structural:
		_request_rebuild()


func _request_rebuild() -> void:
	if auto_rebuild:
		call_deferred("rebuild")
	else:
		rebuild_requested.emit()


## Write `value` at `path` (["alias"] or ["triggers", 0, "at_hour"]) on
## automation `ai`. null erases the leaf.
func patch_field(ai: int, path: Array, value: Variant, structural: bool = false) -> void:
	if ai < 0 or ai >= _autos.size():
		return
	var aut: Dictionary = (_autos[ai] as Dictionary).duplicate(true)
	apply_path(aut, path, value)
	_autos[ai] = aut
	_commit(structural)


func _new_id() -> String:
	if id_factory.is_valid():
		return str(id_factory.call())
	_id_counter += 1
	return "autom_%d_%d" % [Time.get_ticks_msec(), _id_counter]


func _add_template(tpl_idx: int) -> void:
	var tpls: Array = provider.get("templates", []) as Array
	if tpl_idx < 0 or tpl_idx >= tpls.size():
		return
	var tpl: Dictionary = tpls[tpl_idx] as Dictionary
	for s in (tpl.get("specs", []) as Array):
		var spec: Dictionary = (s as Dictionary).duplicate(true)
		spec["id"] = _new_id()
		spec["enabled"] = true
		_autos.append(spec)
		expanded[spec["id"]] = false
	_commit(true)
	message.emit("Added %s" % UiText.count((tpl.get("specs", []) as Array).size(), "automation"))


func _add_custom() -> void:
	var new_id := _new_id()
	_autos.append({
		"id":         new_id,
		"alias":      "New automation",
		"enabled":    true,
		"triggers":   [{"kind": "time", "at_hour": 18.0}],
		"conditions": [],
		"actions":    [default_sub_spec(KIND_ACTION, _first_action_kind())],
	})
	expanded[new_id] = true
	_commit(true)


func _delete(ai: int) -> void:
	if ai < 0 or ai >= _autos.size():
		return
	var removed_id := str((_autos[ai] as Dictionary).get("id", ""))
	_autos.remove_at(ai)
	if not removed_id.is_empty():
		automation_removed.emit(removed_id)
		expanded.erase(removed_id)
	_commit(true)


func _add_sub(ai: int, kind: String) -> void:
	if ai < 0 or ai >= _autos.size():
		return
	var aut: Dictionary = (_autos[ai] as Dictionary).duplicate(true)
	var field := kind_to_field(kind)
	var arr: Array = (aut.get(field, []) as Array).duplicate(true)
	arr.append(default_sub_spec(kind, _first_action_kind()))
	aut[field] = arr
	_autos[ai] = aut
	_commit(true)


func _remove_sub(ai: int, kind: String, si: int) -> void:
	if ai < 0 or ai >= _autos.size():
		return
	var aut: Dictionary = (_autos[ai] as Dictionary).duplicate(true)
	var field := kind_to_field(kind)
	var arr: Array = (aut.get(field, []) as Array).duplicate(true)
	if si < 0 or si >= arr.size():
		return
	arr.remove_at(si)
	aut[field] = arr
	_autos[ai] = aut
	_commit(true)


func _sub_kind_changed(ai: int, kind: String, si: int, new_kind: String) -> void:
	if ai < 0 or ai >= _autos.size():
		return
	var aut: Dictionary = (_autos[ai] as Dictionary).duplicate(true)
	var field := kind_to_field(kind)
	var arr: Array = (aut.get(field, []) as Array).duplicate(true)
	if si < 0 or si >= arr.size():
		return
	var fresh := default_sub_spec(kind, _first_action_kind())
	fresh["kind"] = new_kind
	var old: Dictionary = arr[si] as Dictionary
	if old.has("alias"):
		fresh["alias"] = old["alias"]
	arr[si] = _reset_sub_for_kind(fresh, new_kind)
	aut[field] = arr
	_autos[ai] = aut
	_commit(true)


# ---------------------------------------------------------------------------
# Cards
# ---------------------------------------------------------------------------

## One automation card: header (enabled, expand, name, A/B, delete), then a
## one-line summary when closed or the WHEN / IF / THEN editor when open.
func _build_card(ai: int) -> void:
	var aut: Dictionary = _autos[ai] as Dictionary
	var auto_id: String = str(aut.get("id", ""))

	var card_pc := PanelContainer.new()
	var card_sb := StyleBoxFlat.new()
	card_sb.bg_color = Color(C_PANEL.r * 0.75, C_PANEL.g * 0.75, C_PANEL.b * 0.75, 1.0)
	card_sb.set_corner_radius_all(3)
	card_sb.set_border_width_all(1)
	card_sb.border_color = Color(C_BORDER.r, C_BORDER.g, C_BORDER.b, 0.6)
	card_sb.content_margin_left = 6.0
	card_sb.content_margin_right = 6.0
	card_sb.content_margin_top = 4.0
	card_sb.content_margin_bottom = 4.0
	card_pc.add_theme_stylebox_override("panel", card_sb)
	card_pc.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var card_vbox := VBoxContainer.new()
	card_vbox.add_theme_constant_override("separation", 2)
	card_pc.add_child(card_vbox)

	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 4)
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_vbox.add_child(hdr)

	var enabled_cb := CheckBox.new()
	enabled_cb.button_pressed = bool(aut.get("enabled", true))
	enabled_cb.focus_mode = Control.FOCUS_NONE
	enabled_cb.tooltip_text = "Enable / disable this automation"
	enabled_cb.toggled.connect(func(on: bool) -> void: patch_field(ai, ["enabled"], on))
	hdr.add_child(enabled_cb)

	var is_open: bool = bool(expanded.get(auto_id, false))
	var expand_btn := Button.new()
	IconButton.style(expand_btn, "chevron-down" if is_open else "chevron-right",
			"Collapse" if is_open else "Expand")
	expand_btn.pressed.connect(func() -> void:
		expanded[auto_id] = not is_open
		_request_rebuild()
	)
	hdr.add_child(expand_btn)

	var alias_lbl := Label.new()
	alias_lbl.text = str(aut.get("alias", "Automation"))
	alias_lbl.clip_text = true
	alias_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	alias_lbl.add_theme_color_override("font_color", C_TEXT)
	alias_lbl.add_theme_font_size_override("font_size", 11)
	alias_lbl.tooltip_text = summarize(aut)
	hdr.add_child(alias_lbl)

	if show_ab:
		var ab_btn := Button.new()
		IconButton.style(ab_btn, "chart-column", "A/B this automation — simulate the next week with and without it")
		ab_btn.pressed.connect(func() -> void: ab_requested.emit(auto_id))
		hdr.add_child(ab_btn)

	var del_btn := Button.new()
	IconButton.style(del_btn, "trash-2", "Delete automation")
	del_btn.pressed.connect(_delete.bind(ai))
	hdr.add_child(del_btn)

	if not is_open:
		var sum_lbl := Label.new()
		sum_lbl.text = summarize(aut)
		sum_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sum_lbl.add_theme_color_override("font_color", C_TEXT_M)
		sum_lbl.add_theme_font_size_override("font_size", 10)
		card_vbox.add_child(sum_lbl)
	else:
		var alias_edit := LineEdit.new()
		alias_edit.placeholder_text = "Name"
		alias_edit.text = str(aut.get("alias", ""))
		alias_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		style_edit(alias_edit, false)
		var alias_commit := func() -> void: patch_field(ai, ["alias"], alias_edit.text)
		alias_edit.text_submitted.connect(func(_t: String) -> void: alias_commit.call())
		alias_edit.focus_exited.connect(alias_commit)
		card_vbox.add_child(alias_edit)

		_build_subsection(card_vbox, "WHEN  (triggers - any fires)", Color(0.55, 0.95, 0.55),
			KIND_TRIGGER, ai, (aut.get("triggers", []) as Array))
		_build_subsection(card_vbox, "IF  (conditions - all must match, optional)", C_AMBER,
			KIND_CONDITION, ai, (aut.get("conditions", []) as Array))
		_build_subsection(card_vbox, "THEN  (actions run in order)", C_PRIMARY,
			KIND_ACTION, ai, (aut.get("actions", []) as Array))

		if show_push:
			var push_row := HBoxContainer.new()
			push_row.add_theme_constant_override("separation", 6)
			var push_btn := Button.new()
			push_btn.text = "Push to Home Assistant..."
			push_btn.flat = true
			push_btn.focus_mode = Control.FOCUS_NONE
			push_btn.tooltip_text = "Export this rule to HA (requires HA entity under Advanced)"
			push_btn.add_theme_color_override("font_color", C_TEXT_S)
			push_btn.add_theme_font_size_override("font_size", 10)
			push_btn.pressed.connect(func() -> void: push_requested.emit(auto_id))
			push_row.add_child(push_btn)
			card_vbox.add_child(push_row)

		var id_lbl := Label.new()
		id_lbl.text = "ID: %s" % auto_id
		id_lbl.add_theme_color_override("font_color", C_TEXT_M)
		id_lbl.add_theme_font_size_override("font_size", 9)
		card_vbox.add_child(id_lbl)

	add_child(wrap_margin(card_pc, 12, 3))


func _build_subsection(parent: VBoxContainer, title: String, accent: Color,
		kind: String, ai: int, items_arr: Array) -> void:
	var spacer1 := Control.new()
	spacer1.custom_minimum_size = Vector2(0, 4)
	parent.add_child(spacer1)

	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", 4)
	var lbl := Label.new()
	lbl.text = title
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.add_theme_color_override("font_color", accent)
	lbl.add_theme_font_size_override("font_size", 9)
	hdr.add_child(lbl)
	var add_btn := Button.new()
	add_btn.text = "+"
	add_btn.flat = true
	add_btn.focus_mode = Control.FOCUS_NONE
	add_btn.custom_minimum_size = Vector2(18, 0)
	add_btn.add_theme_color_override("font_color", accent)
	add_btn.tooltip_text = "Add %s" % kind
	add_btn.pressed.connect(_add_sub.bind(ai, kind))
	hdr.add_child(add_btn)
	parent.add_child(hdr)

	if items_arr.is_empty() and kind != KIND_CONDITION:
		var empty_lbl := Label.new()
		empty_lbl.text = "(none)"
		empty_lbl.add_theme_color_override("font_color", C_TEXT_M)
		empty_lbl.add_theme_font_size_override("font_size", 9)
		parent.add_child(empty_lbl)
		return

	for idx in range(items_arr.size()):
		_build_sub_row(parent, kind, ai, idx, (items_arr[idx] as Dictionary))


func _build_sub_row(parent: VBoxContainer, kind: String, ai: int, si: int, sub: Dictionary) -> void:
	var row_pc := PanelContainer.new()
	var row_sb := StyleBoxFlat.new()
	row_sb.bg_color = Color(C_BG.r * 1.2, C_BG.g * 1.2, C_BG.b * 1.2, 1.0)
	row_sb.set_border_width(SIDE_LEFT, 2)
	match kind:
		KIND_TRIGGER:
			row_sb.border_color = Color(0.3, 0.9, 0.3, 0.8)
		KIND_CONDITION:
			row_sb.border_color = Color(C_AMBER.r, C_AMBER.g, C_AMBER.b, 0.8)
		_:
			row_sb.border_color = Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.8)
	row_sb.set_corner_radius_all(2)
	row_sb.content_margin_left = 5.0
	row_sb.content_margin_right = 4.0
	row_sb.content_margin_top = 3.0
	row_sb.content_margin_bottom = 3.0
	row_pc.add_theme_stylebox_override("panel", row_sb)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	row_pc.add_child(vbox)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 4)
	var kind_opt := OptionButton.new()
	kind_opt.focus_mode = Control.FOCUS_NONE
	kind_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind_opt.add_theme_font_size_override("font_size", 10)
	var opts := kind_options(kind)
	var cur_kind := str(sub.get("kind", ""))
	var found := false
	for k_def in opts:
		kind_opt.add_item(k_def.get("label", ""), k_def.get("id", 0))
		if str(k_def.get("key", "")) == cur_kind:
			kind_opt.select(kind_opt.item_count - 1)
			found = true
	if not found and not cur_kind.is_empty():
		# A kind this menu does not offer (an action kind the owner left out):
		# show it rather than silently showing the first entry.
		kind_opt.add_item(cur_kind, 1000)
		kind_opt.select(kind_opt.item_count - 1)
	kind_opt.item_selected.connect(func(sel_idx: int) -> void:
		var id_sel: int = kind_opt.get_item_id(sel_idx)
		for k_def in opts:
			if int(k_def.get("id", -1)) == id_sel:
				_sub_kind_changed(ai, kind, si, str(k_def.get("key", "")))
				return
	)
	top.add_child(kind_opt)

	var rm := Button.new()
	IconButton.style(rm, "x", "Remove this row")
	rm.pressed.connect(_remove_sub.bind(ai, kind, si))
	top.add_child(rm)
	vbox.add_child(top)

	_build_sub_fields(vbox, kind, ai, [kind_to_field(kind), si], sub)

	parent.add_child(row_pc)


func _build_sub_fields(parent: VBoxContainer, kind: String, ai: int, path_base: Array, sub: Dictionary) -> void:
	var sub_kind: String = str(sub.get("kind", ""))
	var patch := func(key: String) -> Callable:
		return func(v: Variant) -> void: patch_field(ai, path_base + [key], v)
	match kind:
		KIND_TRIGGER:
			match sub_kind:
				"time":
					add_spin_row(parent, "At hour", float(sub.get("at_hour", 18.0)), 0.0, 24.0, 0.25, patch.call("at_hour"))
				"sun":
					add_enum_row(parent, "Event", [
							{"label": "Sunset", "key": "sunset"},
							{"label": "Sunrise", "key": "sunrise"}
						], str(sub.get("event", "sunset")), patch.call("event"))
					add_spin_row(parent, "Offset (h)", float(sub.get("offset_hours", 0.0)), -6.0, 6.0, 0.25,
						patch.call("offset_hours"))
				"numeric":
					_build_numeric_fields(parent, ai, path_base, sub)
				"state":
					add_enum_row(parent, "Node / device", _states(),
						_state_entity_key(str(sub.get("entity_id", ""))),
						func(v: String) -> void:
							var patch_eid := "" if v == CUSTOM else v
							var patch_to := str(sub.get("to_state", "on"))
							if v.begins_with("tank."):
								patch_to = "overflow"
							elif v.begins_with("node."):
								patch_to = "on"
							# One commit so the rebuild never lands between the two.
							if ai >= 0 and ai < _autos.size():
								var aut_s: Dictionary = (_autos[ai] as Dictionary).duplicate(true)
								apply_path(aut_s, path_base + ["entity_id"], patch_eid)
								apply_path(aut_s, path_base + ["to_state"], patch_to)
								_autos[ai] = aut_s
							_commit(true))
					var seid := str(sub.get("entity_id", ""))
					if _state_entity_key(seid) == CUSTOM:
						add_text_row(parent, "Device / entity", seid, patch.call("entity_id"))
					add_enum_row(parent, "To state", _state_values(seid),
						str(sub.get("to_state", "on")), patch.call("to_state"))
		KIND_CONDITION:
			match sub_kind:
				"time":
					add_spin_row(parent, "After hr", float(sub.get("after_hour", 0.0)), 0.0, 24.0, 0.25,
						patch.call("after_hour"))
					add_spin_row(parent, "Before hr", float(sub.get("before_hour", 24.0)), 0.0, 24.0, 0.25,
						patch.call("before_hour"))
				"numeric":
					_build_numeric_fields(parent, ai, path_base, sub)
				"sun":
					add_enum_row(parent, "Sun", [
							{"label": "Above horizon", "key": "above_horizon"},
							{"label": "Below horizon", "key": "below_horizon"}
						], str(sub.get("state", "above_horizon")), patch.call("state"))
				"state":
					add_enum_row(parent, "Node / device", _states(),
						_state_entity_key(str(sub.get("entity_id", ""))),
						func(v: String) -> void:
							var patch_eid2 := "" if v == CUSTOM else v
							if ai >= 0 and ai < _autos.size():
								var aut_c: Dictionary = (_autos[ai] as Dictionary).duplicate(true)
								apply_path(aut_c, path_base + ["entity_id"], patch_eid2)
								if v.begins_with("tank."):
									apply_path(aut_c, path_base + ["states"], ["overflow"])
								elif v.begins_with("node."):
									apply_path(aut_c, path_base + ["states"], ["on"])
								_autos[ai] = aut_c
							_commit(true))
					var seid2 := str(sub.get("entity_id", ""))
					if _state_entity_key(seid2) == CUSTOM:
						add_text_row(parent, "Device / entity", seid2, patch.call("entity_id"))
					var cur_states: Array = sub.get("states", []) as Array
					var joined := ""
					for s in cur_states:
						if joined != "":
							joined += ","
						joined += str(s)
					add_enum_row(parent, "Match state", _state_values(seid2),
						str(cur_states[0]) if not cur_states.is_empty() else "on",
						func(v: String) -> void: patch_field(ai, path_base + ["states"], [v], true))
					add_text_row(parent, "States (csv)", joined,
						func(v: String) -> void:
							var arr: Array = []
							for part in v.split(","):
								var t := part.strip_edges()
								if not t.is_empty():
									arr.append(t)
							patch_field(ai, path_base + ["states"], arr))
		KIND_ACTION:
			match sub_kind:
				"scene_node":
					var targets := _targets()
					if not targets.is_empty():
						add_enum_row(parent, "Target", targets, str(sub.get("target", "")),
							func(v: String) -> void:
								var tv: Variant = v
								if v.is_empty():
									tv = null   # the whole item: no target key at all
								patch_field(ai, path_base + ["target"], tv, true))
					add_enum_row(parent, "Command", [
							{"label": "Turn ON", "key": "turn_on"},
							{"label": "Turn OFF", "key": "turn_off"},
							{"label": "Toggle", "key": "toggle"}
						], str(sub.get("command", "turn_on")), patch.call("command"))
				"set_value":
					var settable := _settable()
					var eid := str(sub.get("entity_id", ""))
					var key := _option_key(settable, eid)
					add_enum_row(parent, "Entity", settable, key,
						func(v: String) -> void:
							patch_field(ai, path_base + ["entity_id"], "number." if v == CUSTOM else v, true))
					if key == CUSTOM:
						add_text_row(parent, "Entity id", eid, patch.call("entity_id"))
					var o := _option(settable, key)
					var unit := str(o.get("unit", ""))
					add_spin_row(parent, "Value" if unit.is_empty() else "Value (%s)" % unit,
						float(sub.get("value", 0.0)),
						float(o.get("min", -1.0e6)), float(o.get("max", 1.0e6)), float(o.get("step", 0.01)),
						patch.call("value"))
				"delay":
					add_spin_row(parent, "Delay (s)", float(sub.get("delay_seconds", 5.0)), 0.0, 3600.0, 1.0,
						patch.call("delay_seconds"))


## The numeric trigger / condition fields: signal, custom id, above, below.
func _build_numeric_fields(parent: VBoxContainer, ai: int, path_base: Array, sub: Dictionary) -> void:
	add_enum_row(parent, "Signal", _numeric(),
		_numeric_signal_key(str(sub.get("entity_id", _numeric_default()))),
		func(v: String) -> void:
			patch_field(ai, path_base + ["entity_id"], "sensor." if v == CUSTOM else v, true))
	var eid := str(sub.get("entity_id", _numeric_default()))
	if _numeric_signal_key(eid) == CUSTOM:
		add_text_row(parent, "Entity id", eid,
			func(v: String) -> void: patch_field(ai, path_base + ["entity_id"], v))
	add_optional_spin_row(parent, "Above", sub.get("above", null), 0.0, 100.0, 1.0,
		func(v: Variant) -> void: patch_field(ai, path_base + ["above"], v))
	add_optional_spin_row(parent, "Below", sub.get("below", null), 0.0, 100.0, 1.0,
		func(v: Variant) -> void: patch_field(ai, path_base + ["below"], v))


func _build_footer() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var tpls: Array = provider.get("templates", []) as Array
	if not tpls.is_empty():
		var std_btn := MenuButton.new()
		std_btn.text = "+ Preset..."
		std_btn.flat = true
		std_btn.focus_mode = Control.FOCUS_NONE
		std_btn.add_theme_color_override("font_color", C_PRIMARY)
		std_btn.add_theme_font_size_override("font_size", 11)
		std_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var popup := std_btn.get_popup()
		popup.clear()
		for i in range(tpls.size()):
			popup.add_item(str((tpls[i] as Dictionary).get("label", "Template")), i)
		popup.id_pressed.connect(_add_template)
		row.add_child(std_btn)

	var custom_btn := Button.new()
	custom_btn.text = "+ Custom rule"
	custom_btn.flat = true
	custom_btn.focus_mode = Control.FOCUS_NONE
	custom_btn.add_theme_color_override("font_color", C_PRIMARY)
	custom_btn.add_theme_font_size_override("font_size", 11)
	custom_btn.pressed.connect(_add_custom)
	row.add_child(custom_btn)

	add_child(wrap_margin(row, 12, 8))


func _hint(text: String) -> void:
	if text.is_empty():
		return
	var hint := Label.new()
	hint.text = text
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", C_TEXT_M)
	hint.add_theme_font_size_override("font_size", 10)
	add_child(wrap_margin(hint, 12, 4))


# ---------------------------------------------------------------------------
# Provider lookups
# ---------------------------------------------------------------------------

func _call_list(key: String, fallback: Array, arg: Variant = null) -> Array:
	var c: Variant = provider.get(key, null)
	if c is Callable and (c as Callable).is_valid():
		var r: Variant = (c as Callable).call(arg) if arg != null else (c as Callable).call()
		if r is Array:
			return r
	return fallback


func _numeric() -> Array:
	return _call_list("numeric", [{"label": "Custom (HA entity…)", "key": CUSTOM}])


func _numeric_default() -> String:
	return str(provider.get("numeric_default", "sensor.battery_level"))


func _states() -> Array:
	return _call_list("states", [{"label": "Custom (HA / device id…)", "key": CUSTOM}])


func _state_values(entity_id: String) -> Array:
	return _call_list("state_values", [{"label": "On", "key": "on"}, {"label": "Off", "key": "off"}], entity_id)


func _targets() -> Array:
	return _call_list("targets", [])


func _settable() -> Array:
	var s := _call_list("settable", [])
	for o in s:
		if str((o as Dictionary).get("key", "")) == CUSTOM:
			return s
	s = s.duplicate()
	s.append({"label": "Custom (number. / input_number. entity…)", "key": CUSTOM})
	return s


func _first_action_kind() -> String:
	var kinds: Array = provider.get("action_kinds", DEFAULT_ACTION_KINDS) as Array
	return str(kinds[0]) if not kinds.is_empty() else "scene_node"


static func _option_key(options: Array, entity_id: String) -> String:
	for o in options:
		var k := str((o as Dictionary).get("key", ""))
		if k == entity_id and k != CUSTOM:
			return k
	return CUSTOM


static func _option(options: Array, key: String) -> Dictionary:
	for o in options:
		if str((o as Dictionary).get("key", "")) == key:
			return o as Dictionary
	return {}


func _numeric_signal_key(entity_id: String) -> String:
	return _option_key(_numeric(), entity_id)


func _state_entity_key(entity_id: String) -> String:
	if entity_id.is_empty():
		return CUSTOM
	return _option_key(_states(), entity_id)


## The kind dropdown per row type.
func kind_options(kind: String) -> Array:
	match kind:
		KIND_TRIGGER:
			return [
				{"id": 0, "key": "time",    "label": "Time of day"},
				{"id": 1, "key": "sun",     "label": "Sunrise / sunset"},
				{"id": 2, "key": "numeric", "label": "Fill level / power signal"},
				{"id": 3, "key": "state",   "label": "Graph / device state"},
			]
		KIND_CONDITION:
			return [
				{"id": 0, "key": "time",    "label": "Time window"},
				{"id": 1, "key": "sun",     "label": "Sun above/below horizon"},
				{"id": 2, "key": "numeric", "label": "Fill level / power signal"},
				{"id": 3, "key": "state",   "label": "Graph / device state"},
			]
	# Action ids are fixed per kind (scene_node 0, delay 1, set_value 2) so
	# the menu order can change without moving a saved selection.
	var ids := {"scene_node": 0, "delay": 1, "set_value": 2}
	var labels: Dictionary = DEFAULT_ACTION_LABELS.duplicate()
	labels.merge(provider.get("action_labels", {}) as Dictionary, true)
	var out: Array = []
	for k in (provider.get("action_kinds", DEFAULT_ACTION_KINDS) as Array):
		var ks := str(k)
		out.append({"id": int(ids.get(ks, 10 + out.size())), "key": ks, "label": str(labels.get(ks, ks))})
	return out


static func kind_to_field(kind: String) -> String:
	match kind:
		KIND_TRIGGER:
			return "triggers"
		KIND_CONDITION:
			return "conditions"
	return "actions"


## A fresh trigger / condition / action row.
static func default_sub_spec(kind: String, action_kind: String = "scene_node") -> Dictionary:
	match kind:
		KIND_TRIGGER:
			return {"kind": "time", "at_hour": 18.0}
		KIND_CONDITION:
			return {"kind": "time", "after_hour": 0.0, "before_hour": 24.0}
	return _reset_sub_for_kind({}, action_kind)


## A row switched to `new_kind`: that kind's defaults, the alias kept.
static func _reset_sub_for_kind(sub: Dictionary, new_kind: String) -> Dictionary:
	var fresh: Dictionary
	match new_kind:
		"time":
			fresh = {"kind": "time", "at_hour": 18.0, "after_hour": 0.0, "before_hour": 24.0}
		"sun":
			fresh = {"kind": "sun", "event": "sunset", "offset_hours": 0.0, "state": "above_horizon"}
		"numeric":
			fresh = {"kind": "numeric", "entity_id": "sensor.battery_level"}
		"state":
			fresh = {"kind": "state", "entity_id": "", "to_state": "on", "states": []}
		"scene_node":
			fresh = {"kind": "scene_node", "command": "turn_on"}
		"set_value":
			fresh = {"kind": "set_value", "entity_id": "number.", "value": 0.0}
		"delay":
			fresh = {"kind": "delay", "delay_seconds": 5.0}
		_:
			fresh = {"kind": new_kind}
	if sub.has("alias"):
		fresh["alias"] = sub["alias"]
	return fresh


## Walks `target` along `path` (keys or ints) and writes `value` at the leaf
## (null erases a dictionary key). Intermediate containers are duplicated on
## the way down so shared references are never mutated.
static func apply_path(target: Variant, path: Array, value: Variant) -> void:
	if path.is_empty():
		return
	var cur: Variant = target
	for i in range(path.size() - 1):
		var key: Variant = path[i]
		if cur is Dictionary:
			var d := cur as Dictionary
			var nxt: Variant = d.get(key)
			if nxt is Dictionary:
				nxt = (nxt as Dictionary).duplicate(true)
			elif nxt is Array:
				nxt = (nxt as Array).duplicate(true)
			d[key] = nxt
			cur = nxt
		elif cur is Array:
			var a := cur as Array
			var idx := int(key)
			if idx < 0 or idx >= a.size():
				return
			var nxt2: Variant = a[idx]
			if nxt2 is Dictionary:
				nxt2 = (nxt2 as Dictionary).duplicate(true)
			elif nxt2 is Array:
				nxt2 = (nxt2 as Array).duplicate(true)
			a[idx] = nxt2
			cur = nxt2
	var leaf: Variant = path[path.size() - 1]
	if cur is Dictionary:
		if value == null:
			(cur as Dictionary).erase(leaf)
		else:
			(cur as Dictionary)[leaf] = value
	elif cur is Array:
		(cur as Array)[int(leaf)] = value


# ---------------------------------------------------------------------------
# Summaries
# ---------------------------------------------------------------------------

## One line: "When <triggers>  →  <actions>" (+ the condition count).
static func summarize(aut: Dictionary) -> String:
	var trigs: Array = aut.get("triggers", []) as Array
	var acts:  Array = aut.get("actions",  []) as Array
	var conds: Array = aut.get("conditions", []) as Array
	var when_s := ""
	for t in trigs:
		var piece := summarize_trigger(t as Dictionary)
		if not piece.is_empty():
			when_s += ("  or  " if not when_s.is_empty() else "") + piece
	if when_s.is_empty():
		when_s = "(no trigger)"
	var then_s := ""
	for a in acts:
		var piece := summarize_action(a as Dictionary)
		if not piece.is_empty():
			then_s += (" → " if not then_s.is_empty() else "") + piece
	if then_s.is_empty():
		then_s = "(no action)"
	var txt := "When %s  →  %s" % [when_s, then_s]
	if not conds.is_empty():
		txt += "\nIf: %s" % UiText.count(conds.size(), "condition")
	return txt


static func summarize_trigger(t: Dictionary) -> String:
	match str(t.get("kind", "")):
		"time":
			return "time %s" % fmt_hour(float(t.get("at_hour", 0.0)))
		"sun":
			var event := str(t.get("event", "sunset"))
			var off := float(t.get("offset_hours", 0.0))
			if absf(off) < 0.01:
				return event
			return "%s %s%.1fh" % [event, ("+" if off > 0 else ""), off]
		"numeric":
			var ent := str(t.get("entity_id", ""))
			var friendly := ent.trim_prefix("sensor.")
			match ent:
				"sensor.battery_level":
					friendly = "battery SOC"
				"sensor.solar_power":
					friendly = "solar W"
				"sensor.load_power":
					friendly = "load W"
				_:
					if ent.begins_with("tank.") and ent.ends_with(".level"):
						friendly = "fill %s" % ent.trim_prefix("tank.").trim_suffix(".level")
					elif ent.begins_with("resource.") and ent.ends_with(".level"):
						friendly = ent.trim_prefix("resource.").trim_suffix(".level") + " fill"
			var parts: Array = []
			if t.has("above") and t.get("above") != null:
				parts.append("> %.0f" % float(t.get("above")))
			if t.has("below") and t.get("below") != null:
				parts.append("< %.0f" % float(t.get("below")))
			return "%s %s" % [friendly, " ".join(PackedStringArray(parts))]
		"state":
			return "%s = %s" % [str(t.get("entity_id", "")), str(t.get("to_state", ""))]
	return ""


static func summarize_action(a: Dictionary) -> String:
	match str(a.get("kind", "")):
		"scene_node":
			var verb := "turn on"
			match str(a.get("command", "turn_on")):
				"turn_off":
					verb = "turn off"
				"toggle":
					verb = "toggle"
			var target := str(a.get("target", ""))
			return verb if target.is_empty() else "%s %s" % [verb, target]
		"set_value":
			return "set %s = %s" % [str(a.get("entity_id", "")), String.num(float(a.get("value", 0.0)), 3)]
		"delay":
			return "wait %.0fs" % float(a.get("delay_seconds", 0.0))
	return ""


static func fmt_hour(h: float) -> String:
	var hi := int(h)
	var mi := int(round((h - hi) * 60.0))
	if mi >= 60:
		mi = 0
		hi += 1
	return "%02d:%02d" % [hi, mi]


# ---------------------------------------------------------------------------
# Small editable rows
# ---------------------------------------------------------------------------

static func wrap_margin(ctrl: Control, h: int, v: int) -> MarginContainer:
	var mc := MarginContainer.new()
	mc.add_theme_constant_override("margin_left", h)
	mc.add_theme_constant_override("margin_right", h)
	mc.add_theme_constant_override("margin_top", v)
	mc.add_theme_constant_override("margin_bottom", v)
	mc.add_child(ctrl)
	return mc


static func style_edit(edit: LineEdit, small: bool) -> void:
	var sb_n := StyleBoxFlat.new()
	sb_n.bg_color              = Color(C_BG.r, C_BG.g, C_BG.b, 0.8)
	sb_n.border_color          = C_BORDER
	sb_n.set_border_width_all(1)
	sb_n.set_corner_radius_all(3)
	var mg := 3.0 if small else 4.0
	sb_n.content_margin_left   = mg
	sb_n.content_margin_right  = mg
	sb_n.content_margin_top    = 2.0
	sb_n.content_margin_bottom = 2.0
	var sb_f := sb_n.duplicate() as StyleBoxFlat
	sb_f.border_color = C_PRIMARY
	edit.add_theme_stylebox_override("normal",  sb_n)
	edit.add_theme_stylebox_override("focus",   sb_f)
	edit.add_theme_stylebox_override("read_only", sb_n)
	edit.add_theme_color_override("font_color",        C_TEXT)
	edit.add_theme_color_override("cursor_color",      C_PRIMARY)
	edit.add_theme_color_override("selection_color",   Color(C_PRIMARY.r, C_PRIMARY.g, C_PRIMARY.b, 0.35))
	edit.add_theme_font_size_override("font_size", 11)


static func small_label(txt: String) -> Label:
	var lbl := Label.new()
	lbl.text = txt
	lbl.custom_minimum_size = Vector2(68, 0)
	lbl.add_theme_color_override("font_color", C_TEXT_S)
	lbl.add_theme_font_size_override("font_size", 10)
	return lbl


static func add_spin_row(parent: VBoxContainer, label: String, value: float,
		min_v: float, max_v: float, step: float, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(small_label(label))
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = value
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_edit(sb.get_line_edit(), true)
	sb.value_changed.connect(func(v: float) -> void: commit.call(v))
	row.add_child(sb)
	parent.add_child(row)


## A bound that may be off (null): a checkbox beside the spin.
static func add_optional_spin_row(parent: VBoxContainer, label: String, current: Variant,
		min_v: float, max_v: float, step: float, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(small_label(label))
	var active: bool = current != null and not (current is String)
	var cb := CheckBox.new()
	cb.button_pressed = active
	cb.focus_mode = Control.FOCUS_NONE
	row.add_child(cb)
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = step
	sb.value = float(current) if active else 50.0
	sb.editable = active
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_edit(sb.get_line_edit(), true)
	row.add_child(sb)
	cb.toggled.connect(func(on: bool) -> void:
		sb.editable = on
		if on:
			commit.call(sb.value)
		else:
			commit.call(null)
	)
	sb.value_changed.connect(func(v: float) -> void:
		if cb.button_pressed:
			commit.call(v)
	)
	parent.add_child(row)


static func add_text_row(parent: VBoxContainer, label: String, value: String, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(small_label(label))
	var ed := LineEdit.new()
	ed.text = value
	ed.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_edit(ed, false)
	var do_commit := func() -> void: commit.call(ed.text)
	ed.text_submitted.connect(func(_t: String) -> void: do_commit.call())
	ed.focus_exited.connect(do_commit)
	row.add_child(ed)
	parent.add_child(row)


static func add_enum_row(parent: VBoxContainer, label: String, options: Array,
		current_key: String, commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.add_child(small_label(label))
	var opt := OptionButton.new()
	opt.focus_mode = Control.FOCUS_NONE
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.add_theme_font_size_override("font_size", 10)
	var keys: Array = []
	for i in range(options.size()):
		var o: Dictionary = options[i] as Dictionary
		opt.add_item(str(o.get("label", "")), i)
		keys.append(str(o.get("key", "")))
		if str(o.get("key", "")) == current_key:
			opt.select(i)
	opt.item_selected.connect(func(idx: int) -> void:
		if idx >= 0 and idx < keys.size():
			commit.call(keys[idx])
	)
	row.add_child(opt)
	parent.add_child(row)

extends Node

## The loop closer on the graph (resource composition plan Phase 7): shows
## ONE LoopPlanner plan as ghosts (GraphSuggestions) when the player asks,
## with a chip to accept it (Tab), see the other plans, test it for a week
## against the world as it is, or dismiss it (Esc). A child of the
## SystemGraphView ("LoopCloser"); the view's delegates call in here.
##
## Nothing appears by itself. The only passive cue is the open-loop badge on
## group cards (a count, refreshed every 2 s while the graph is open).

const BADGE_EVERY_S := 2.0
const MAX_LOOPS := 8

var view: Node = null
var _sugg: Dictionary = {}
var _plans: Array = []
var _open: Dictionary = {}
var _scope := ""
## The machine "Close the … loop" was asked from ("" = a tank, a wire, a list).
var _from := ""
var _chip: PanelContainer = null
var _chip_lbl: Label = null
var _btn_other: Button = null
var _dismissed: Dictionary = {}
var _dismissed_path := "-"
## The 3D ring view the ghost made flat ("" = none).
var _restore_3d := ""
var _badge_acc := 0.0
var _badge_key := ""


func setup(v: Node) -> void:
	view = v
	var gc: Node = _canvas()
	if gc != null and gc.has_signal("open_loops_badge_pressed") \
			and not gc.is_connected("open_loops_badge_pressed", _on_badge_pressed):
		gc.connect("open_loops_badge_pressed", _on_badge_pressed)


func _canvas() -> Node:
	return view.get("_graph_canvas") if view != null else null


func _model() -> GraphModel:
	return view.get("model") if view != null else null


func active() -> bool:
	return not _sugg.is_empty()


func suggestion() -> Dictionary:
	return _sugg


# --- asking -------------------------------------------------------------------

## The open loops of a scope with their plans: [{open, plans}].
func loops(scope: String, only_kinds: Array = []) -> Array:
	var m := _model()
	if m == null:
		return []
	return LoopPlanner.plan_scope(m, scope, MAX_LOOPS, {}, only_kinds)


## "Close this loop" on a tank, a wire or a machine: the first plan not
## dismissed for that kind in the scope the player is in. false = nothing
## open there (a toast says so).
func close_loop_for_kind(kind: String, scope: String = "", from_item: String = "") -> bool:
	if scope.is_empty():
		scope = str(view.get("_active_scope_id"))
	_from = from_item
	var k := ChainWiring.kind(kind)
	for row in loops(scope, [k]):
		var od: Dictionary = row["open"]
		if str(od["kind"]) != k:
			continue
		if (row["plans"] as Array).is_empty():
			_toast("Nothing in the library closes the %s loop yet." % _nm(k), ToastUI.Level.WARN)
			return false
		show_plans(scope, od, row["plans"], _first_shown(scope, od, row["plans"]))
		return true
	_toast("The %s loop is closed here: nothing is left over or brought in." % _nm(k))
	return false


func _first_shown(scope: String, od: Dictionary, plans: Array) -> int:
	_load_dismissed()
	for i in plans.size():
		if not GraphSuggestions.is_dismissed(_dismissed, scope, od, plans[i]):
			return i
	return 0


## The machines and loops an item takes part in that are open in its scope:
## [{open, plans}] (the inspector's "Close the … loop" buttons).
func loops_touching(item_id: String) -> Array:
	var m := _model()
	if m == null:
		return []
	var it := m.get_item(item_id)
	if it.is_empty():
		return []
	var kinds: Dictionary = {}
	for ins in [true, false]:
		for p in ChainWiring.ports(str(it.get("type", "")), it.get("specs", {}), ins):
			kinds[str(p[0])] = true
	var out: Array = []
	for row in loops(str(it.get("scope_id", "root")), kinds.keys()):
		if kinds.has(str(row["open"]["kind"])):
			out.append(row)
	return out


## Show plan `index` of `plans` for the open loop `od` in `scope`.
func show_plans(scope: String, od: Dictionary, plans: Array, index: int = 0, from_item: String = "-") -> void:
	if from_item != "-":
		_from = from_item
	var m := _model()
	if m == null or plans.is_empty():
		return
	if not bool(view.get("visible")):
		view.call("open_graph_view")
	if str(view.get("_active_scope_id")) != scope:
		_toast("Open the system it is in first.", ToastUI.Level.WARN)
		return
	var gc: Node = _canvas()
	# The ghost is drawn on the flat graph: a 3D ring view goes flat while it
	# is up and comes back when it is accepted or dismissed.
	if gc != null and not str(gc.call("view_3d_mode")).is_empty():
		if _restore_3d.is_empty():
			_restore_3d = str(gc.call("view_3d_mode"))
		view.call("set_graph_3d", "", false)
	if str(view.get("_graph_view_mode")) != GraphSiteLayout.VIEW_FREEFORM:
		view.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	_scope = scope
	_open = od
	_plans = plans
	index = posmod(index, plans.size())
	_sugg = GraphSuggestions.build(m, scope, od, plans[index], index, plans.size(), _from)
	if gc != null:
		gc.call("set_suggestion", _sugg)
	_show_chip()
	if gc != null:
		gc.call("frame_suggestion", _chip.get_combined_minimum_size().x + 28.0 if _chip != null else 0.0)


func next_plan() -> void:
	if not active() or _plans.size() < 2:
		return
	show_plans(_scope, _open, _plans, int(_sugg["index"]) + 1, _from)


func clear() -> void:
	_sugg = {}
	var gc: Node = _canvas()
	if gc != null:
		gc.call("set_suggestion", {})
	if _chip != null:
		_chip.visible = false
	if not _restore_3d.is_empty() and view != null:
		var m3 := _restore_3d
		_restore_3d = ""
		view.call("set_graph_3d", m3, false)


# --- answering ----------------------------------------------------------------

## Add the ghost's machines and wires: ONE undo step. Returns the new ids.
func accept() -> Array:
	if not active():
		return []
	var m := _model()
	var machines := int(_sugg.get("machines", 0))
	var gaps := int(_sugg.get("gaps", 0))
	if m == null or (machines == 0 and gaps == 0):
		return []
	view.set("_history_suppress", true)
	var ids := ChainWiring.apply(m, _scope, {"items": _sugg["items"], "conns": _sugg["conns"]})
	view.set("_history_suppress", false)
	view.call("_push_history")
	if view.has_method("_update_undo_redo_btns"):
		view.call("_update_undo_redo_btns")
	if view.has_method("_schedule_graph_autosave"):
		view.call("_schedule_graph_autosave")
	var bits := PackedStringArray()
	if machines > 0:
		bits.append(UiText.count(machines, "machine"))
	if gaps > 0:
		bits.append(UiText.count(gaps, "gap node"))
	if ids.size() > machines + gaps:
		bits.append(UiText.count(ids.size() - machines - gaps, "tank"))
	var text := "Added %s to close the %s loop." % [GapBrief._and(bits), _nm(str(_open.get("kind", "")))]
	if gaps > 0:
		text += " Run the clock: each gap node measures what its machine must do."
	clear()
	_toast(text, ToastUI.Level.OK)
	_badge_key = ""
	return ids


## Hide it and remember it (per world): Close loops… lists it greyed.
func dismiss() -> void:
	if not active():
		return
	_load_dismissed()
	_dismissed[GraphSuggestions.dismiss_id(_sugg)] = int(Time.get_unix_time_from_system())
	GraphSuggestions.save_dismissed(_dismissed_path, _dismissed)
	clear()
	_toast("Dismissed. Close loops… still lists it.")


func is_dismissed(scope: String, od: Dictionary, plan: Dictionary) -> bool:
	_load_dismissed()
	return GraphSuggestions.is_dismissed(_dismissed, scope, od, plan)


func _load_dismissed() -> void:
	var p := GraphSuggestions.path_for_view(view)
	if p == _dismissed_path:
		return
	_dismissed_path = p
	_dismissed = GraphSuggestions.load_dismissed(p)


## "Test a week": a fork of the world WITH the plan, compared with the world
## as it is over the next week (the A vs B window; it hands the world back).
func test_week() -> void:
	if not active():
		return
	var m := _model()
	var main := ServiceLocator.main()
	if m == null or main == null or not main.has_method("open_compare_view"):
		return
	var path := ExperimentStore.path_for_view(view)
	if path.is_empty():
		_toast("Experiments need a world. Load one first.", ToastUI.Level.WARN)
		return
	var copy := GraphModel.new()
	copy.deserialize(m.serialize())
	ChainWiring.apply(copy, _scope, {"items": _sugg["items"], "conns": _sugg["conns"]})
	var name := "Close the %s loop" % _nm(str(_open.get("kind", "")))
	var store := ExperimentStore.load_from(path)
	var fid := store.find_by_name(name)
	if fid.is_empty():
		fid = store.add_fork(name, copy.serialize(), str(_sugg.get("text", "")))
	else:
		store.set_fork_graph(fid, copy.serialize())
	store.save_to(path)
	main.call("open_compare_view", PackedFloat64Array([NAN, NAN]), {"mode": "ab", "a": ExperimentStore.CURRENT,
		"b": fid, "span": "next_7d", "run": true})


# --- the chip -----------------------------------------------------------------

func _show_chip() -> void:
	var gc: Control = _canvas()
	if gc == null:
		return
	if _chip == null:
		_chip = PanelContainer.new()
		_chip.name = "LoopCloserChip"
		_chip.add_theme_stylebox_override("panel", UITheme.card_style())
		_chip.mouse_filter = Control.MOUSE_FILTER_STOP
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 6)
		_chip.add_child(v)
		_chip_lbl = Label.new()
		_chip_lbl.custom_minimum_size = Vector2(360.0, 0.0)
		_chip_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_chip_lbl.add_theme_color_override("font_color", UITheme.C_TEXT)
		v.add_child(_chip_lbl)
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		v.add_child(h)
		h.add_child(_button("Accept", "loopcloser_accept", "Add these machines and wires (Tab)", func() -> void: accept()))
		_btn_other = _button("Other options", "loopcloser_other", "The next plan for this loop", func() -> void: next_plan())
		h.add_child(_btn_other)
		h.add_child(_button("Test a week", "loopcloser_test",
			"Run the next week with and without it (the A vs B window)", func() -> void: test_week()))
		h.add_child(_button("Dismiss", "loopcloser_dismiss", "Hide it; Close loops… still lists it (Esc)", func() -> void: dismiss()))
		gc.add_child(_chip)
	_chip_lbl.text = str(_sugg.get("text", ""))
	_btn_other.text = "Other options (%d of %d)" % [int(_sugg["index"]) + 1, int(_sugg["count"])]
	_btn_other.disabled = int(_sugg["count"]) < 2
	_chip.reset_size()
	_chip.visible = true
	_place_chip()


func _button(text: String, nm: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.name = nm
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(b)
	b.pressed.connect(cb)
	return b


func _place_chip() -> void:
	var gc: Control = _canvas()
	if _chip == null or gc == null:
		return
	var r: Rect2 = gc.call("suggestion_screen_rect")
	if r.size == Vector2.ZERO:
		_chip.visible = false
		return
	_chip.visible = true
	var sz := _chip.get_combined_minimum_size()
	# Beside the ghost (right, else left), so it never covers the wire that
	# joins the ghost to what it closes; else on its far side from that.
	var pos := Vector2(r.end.x + 14.0, r.position.y)
	if pos.x + sz.x > gc.size.x - 8.0:
		pos.x = r.position.x - sz.x - 14.0
	if pos.x < 8.0:
		# Away from what it joins: below a plan that takes from above (a
		# sink), above one that feeds what is below (a source).
		var below := str(_open.get("side", "sink")) == "sink"
		pos = Vector2(r.position.x, r.end.y + 12.0 if below else r.position.y - sz.y - 12.0)
		if below and pos.y + sz.y > gc.size.y - 8.0:
			pos.y = r.position.y - sz.y - 12.0
		elif not below and pos.y < 8.0:
			pos.y = r.end.y + 12.0
	pos.x = clampf(pos.x, 8.0, maxf(8.0, gc.size.x - sz.x - 8.0))
	pos.y = clampf(pos.y, 8.0, maxf(8.0, gc.size.y - sz.y - 8.0))
	_chip.position = pos


func chip() -> Control:
	return _chip


# --- every frame ----------------------------------------------------------------

func _process(delta: float) -> void:
	if view == null or not bool(view.get("visible")):
		return
	if active():
		_place_chip()
	_badge_acc += delta
	if _badge_acc >= BADGE_EVERY_S:
		_badge_acc = 0.0
		_refresh_badges()


## Open loops inside each group card of the scope on show.
func _refresh_badges() -> void:
	var m := _model()
	var gc: Node = _canvas()
	if m == null or gc == null:
		return
	var scope := str(view.get("_active_scope_id"))
	var key := "%s|%d|%d" % [scope, m.struct_rev, m.user_rev]
	if key == _badge_key:
		return
	_badge_key = key
	var counts: Dictionary = {}
	for it in m.get_items_in_scope(scope):
		var d: Dictionary = it
		var child := str(d.get("child_scope_id", ""))
		if str(d.get("type", "")) != "compound" or child.is_empty() or GraphSolarArrays.is_solar_array(d):
			continue
		var n := (LoopPlanner.find_open(m, child)["open"] as Array).size()
		if n > 0:
			counts[str(d.get("id", ""))] = n
	gc.set("open_loop_badges", counts)
	gc.call("queue_redraw")


func _on_badge_pressed(item_id: String) -> void:
	var m := _model()
	if m == null:
		return
	var child := str(m.get_item(item_id).get("child_scope_id", ""))
	if child.is_empty():
		return
	view.call("focus_graph_item", item_id, true)
	open_list.call_deferred(child)


## Close loops…: every open loop of a scope and its plans.
func open_list(scope: String = "") -> void:
	if scope.is_empty():
		scope = str(view.get("_active_scope_id"))
	var scr: Script = load("res://scenes/ui/close_loops_modal.gd")
	if scr == null:
		return
	var md: Node = scr.new()
	var host: Node = view.get_viewport() if (view != null and view.get_viewport() != null) else get_tree().root
	host.add_child(md)
	md.call("open_for", self, scope)


# --- Gap nodes and their briefs (resource composition plan Phase 8) ----------

## Every gap node on the graph: [{id, scope, title}].
func gaps() -> Array:
	var m := _model()
	var out: Array = []
	if m == null:
		return out
	for it in GraphNesting.walk_items(m, "root"):
		var d: Dictionary = it
		if str(d.get("type", "")) == "processor" and DesignGap.is_gap(d.get("specs", {})):
			out.append({"id": str(d["id"]), "scope": str(d.get("scope_id", "root")),
				"title": str((d["specs"] as Dictionary).get("name", "Gap"))})
	return out


## The gap node's meter: the flow engine's live one, else the one saved on it.
func gap_meter(item_id: String) -> GapMeter:
	var fe: Variant = view.get("_resource_flow") if view != null else null
	if fe != null and (fe as Object).has_method("gap_meter"):
		var live: GapMeter = (fe as Object).call("gap_meter", item_id)
		if live != null:
			return live
	var sp: Dictionary = (_model().get_item(item_id).get("specs", {}) as Dictionary)
	return GapMeter.from_dict(sp.get("gap_meter", {}) if sp.get("gap_meter", {}) is Dictionary else {})


## Mean kWh/day of solar the site curtailed (made but could not use) over
## the last `days`, from SolarUI's energy timeline (raw − delivered). NAN =
## not known.
func curtailed_kwh_day(days: float = 7.0) -> float:
	var solar: Node = view.call("_find_solar_ui") if view != null and view.has_method("_find_solar_ui") else null
	if solar == null:
		return NAN
	var tl: Variant = solar.get("energy_timeline")
	var main := ServiceLocator.main()
	if tl == null or main == null:
		return NAN
	var now := float(main.call("get_absolute_hours"))
	var raw := float((tl as Object).call("integrate_channel", now - days * 24.0, now, "raw"))
	var got := float((tl as Object).call("integrate_channel", now - days * 24.0, now, "solar"))
	if raw <= 0.0:
		return NAN
	return maxf(raw - got, 0.0) / days


func brief_for(item_id: String) -> Dictionary:
	var sp: Dictionary = (_model().get_item(item_id).get("specs", {}) as Dictionary)
	return GapBrief.make(sp, gap_meter(item_id), {"curtailed_kwh_day": curtailed_kwh_day()})


## Write the brief to user://design_challenges/. → the .md path.
func export_brief(item_id: String) -> String:
	var path := GapBrief.export(brief_for(item_id))
	if path.is_empty():
		_toast("Could not write the brief.", ToastUI.Level.WARN)
	else:
		_toast("Brief saved: %s" % ProjectSettings.globalize_path(path))
	return path


## "Add a gap node here": a loop nothing in the library closes gets a gap
## node, shown as a ghost like any plan (Tab accepts it).
func show_gap_for(scope: String, od: Dictionary) -> void:
	show_plans(scope, od, [GraphSuggestions.gap_plan(od)], 0, "")


## "Design this gap": the gap node goes into a group of its own, its wires
## becoming the group's ports, to be filled with real machines.
func design_gap(item_id: String) -> String:
	var m := _model()
	if m == null or not DesignGap.is_gap(m.get_item(item_id).get("specs", {})):
		return ""
	var title := str((m.get_item(item_id)["specs"] as Dictionary).get("name", "Gap")).trim_prefix("Gap: ")
	var sel: Array[String] = [item_id]
	view.set("_selected_item_ids", sel)
	var cid := str(view.call("_group_selected_items", false, "", "Design: %s" % title,
		{"design_gap_of": item_id}, 1))
	if not cid.is_empty():
		_toast("Open the group and build the machine inside; the gap node's brief stays there until you remove it.")
	return cid


## "Replace with a gap node": a group's measured boundary flows become a gap
## node in its place, its outside wires moved onto the gap's ports. One undo
## step (Ctrl+Z puts the group back).
func replace_with_gap(comp_id: String) -> String:
	var m := _model()
	if m == null:
		return ""
	var comp := m.get_item(comp_id)
	if comp.is_empty() or str(comp.get("type", "")) != "compound":
		return ""
	var scope := str(comp.get("scope_id", "root"))
	var fe: Variant = view.get("_resource_flow")
	var ins: Array = []
	var outs: Array = []
	var moves: Array = []
	for c in m.get_connections_in_scope(scope):
		var cd: Dictionary = c
		if str(cd.get("polarity", "")) != "resource":
			continue
		var into := str(cd.get("target_item_id", "")) == comp_id
		var outof := str(cd.get("source_item_id", "")) == comp_id
		if not into and not outof:
			continue
		var k := ChainWiring.kind(str(cd.get("resource_type", "")))
		var rate := 0.0
		if fe != null and (fe as Object).has_method("get_connection_flow"):
			rate = float(((fe as Object).call("get_connection_flow", str(cd.get("id", ""))) as Dictionary).get("rate", 0.0))
		if into:
			moves.append([cd.duplicate(), true, ins.size()])
			ins.append({"kind": k, "rate": snappedf(rate, 0.001)})
		else:
			moves.append([cd.duplicate(), false, outs.size()])
			outs.append({"kind": k, "rate": snappedf(rate, 0.001)})
	if ins.is_empty() and outs.is_empty():
		_toast("That group has no resource wires to measure.", ToastUI.Level.WARN)
		return ""
	var title := str((comp.get("specs", {}) as Dictionary).get("name", "group"))
	var gid: String = m.generate_item_id()
	view.set("_history_suppress", true)
	m.add_item({"id": gid, "type": "processor", "scope_id": scope, "x": float(comp.get("x", 0.0)),
		"y": float(comp.get("y", 0.0)), "width": 160.0, "height": 120.0,
		"specs": DesignGap.make_specs("Gap: what %s does" % title, ins, outs)})
	for mv in moves:
		var cd2: Dictionary = mv[0]
		m.remove_connection(str(cd2["id"]))
		var row := {"scope_id": scope, "polarity": "resource", "resource_type": str(cd2.get("resource_type", ""))}
		if bool(mv[1]):
			row["source_item_id"] = str(cd2["source_item_id"])
			row["source_handle_id"] = str(cd2["source_handle_id"])
			row["target_item_id"] = gid
			row["target_handle_id"] = "res_in_%d" % int(mv[2])
		else:
			row["source_item_id"] = gid
			row["source_handle_id"] = "res_out_%d" % int(mv[2])
			row["target_item_id"] = str(cd2["target_item_id"])
			row["target_handle_id"] = str(cd2["target_handle_id"])
		m.add_connection(row)
	m.remove_item(comp_id)
	view.set("_history_suppress", false)
	view.call("_push_history")
	if view.has_method("_update_undo_redo_btns"):
		view.call("_update_undo_redo_btns")
	if view.has_method("_schedule_graph_autosave"):
		view.call("_schedule_graph_autosave")
	_toast("Replaced %s with a gap node: run the clock and it measures what the group did. Ctrl+Z puts it back." % title)
	return gid


## Design challenges: every gap node with its brief.
func open_challenges() -> void:
	var scr: Script = load("res://scenes/ui/design_challenges_modal.gd")
	if scr == null:
		return
	var md: Node = scr.new()
	var host: Node = view.get_viewport() if (view != null and view.get_viewport() != null) else get_tree().root
	host.add_child(md)
	md.call("open_for", self)


func _nm(kind: String) -> String:
	return GraphSuggestions.kind_word(kind)


func _toast(text: String, level: int = ToastUI.Level.INFO) -> void:
	if view != null and view.has_method("_show_toast"):
		view.call("_show_toast", text, 3.0, level)

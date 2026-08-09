extends Control

## Site Projects panel — the player surface for the unified camp-lifecycle
## mechanic: every queued project (delivery unload, linkage build, breakdown)
## with live phase status, crew/quorum badges, a planned-schedule strip with
## live status colouring, pause/cancel, and the WHAT-IF table (crew size ×
## night shift → makespan, pure NpcCrewPlan.schedule compute — honestly a
## plan, not a simulation).
##
## Instantiated lazily by SystemGraphView (record_book / routines pattern),
## styled through UITheme, signals wired in _ready. No class_name — the
## ui_compile selftest sweeps it.

const MODAL_NAME := "site_projects"

const C_DONE := Color(0.30, 0.72, 0.42)
const C_ACTIVE := Color(0.92, 0.70, 0.25)
const C_PENDING := Color(0.45, 0.48, 0.56)
const C_SKIPPED := Color(0.60, 0.42, 0.42)

var _bridge = null                 # NpcPopulationBridge
var _active := false
var _dim: ColorRect = null
var _panel: PanelContainer = null
var _list: VBoxContainer = null
var _np_label: LineEdit = null
var _np_hours: SpinBox = null
var _np_crew: SpinBox = null
var _np_where: Button = null
var _np_err: Label = null
## Where a hand-authored project stands, Vector2.INF for "wherever they are".
var _np_site := Vector2.INF
var _empty_lbl: Label = null
var _refresh_accum := 0.0
## What-if crew sizes swept per linkage project.
const WHATIF_CREWS: Array = [2, 4, 6, 8, 12, 16]
## Sim-backed comparison. Panel-level, NOT card-level: _refresh() destroys and
## rebuilds every card, so a lab owned by a card would die mid-run and the
## results would never survive to be shown.
var _lab: NpcExperimentLab = null
var _lab_sig := ""
var _lab_rows: Array = []
var _lab_summary: Dictionary = {}
var _lab_progress := 0.0


func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_build_ui()


func open(bridge) -> void:
	_bridge = bridge
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	move_to_front()
	_refresh()
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))


func close() -> void:
	if not _active:
		return
	# Stop an in-flight run, but KEEP the rows: reopening should be instant.
	if _lab != null and is_instance_valid(_lab):
		_lab.cancel()
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	CursorController.release_modal(MODAL_NAME)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum >= 0.75:
		_refresh_accum = 0.0
		_refresh()


# --- construction ------------------------------------------------------------

func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.55)
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UITheme.panel_style())
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -480
	_panel.offset_right = 480
	_panel.offset_top = -330
	_panel.offset_bottom = 330
	add_child(_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	_panel.add_child(vb)

	var head := HBoxContainer.new()
	vb.add_child(head)
	var title := Label.new()
	title.text = "👷 Site Projects"
	title.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := Button.new()
	UITheme.style_button(close_btn)
	close_btn.text = "✕"
	close_btn.tooltip_text = "Close (Esc)"
	close_btn.pressed.connect(close)
	head.add_child(close_btn)

	vb.add_child(_new_project_row())

	var hint := Label.new()
	hint.text = "End-to-end crew work: unload → fabricate → raise → operate → break down → pack out. World changes land when the labour is actually done."
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vb.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	scroll.add_child(_list)

	_empty_lbl = Label.new()
	_empty_lbl.text = "No projects yet. Deliver a kit (Packing Lab → 🚚) or queue a build (Linkage Lab → 👷)."
	_empty_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_list.add_child(_empty_lbl)


# --- authoring ----------------------------------------------------------------

## Hand-author a project: a name, a size of job, a crew, and a PLACE.
##
## Deliberately narrow. Effects, dependencies, hauls and carry legs are the
## project compiler's vocabulary — the delivery and linkage generators emit
## them, and exposing them here would be a modding surface, not a game one.
## What the player gets is the thing they cannot otherwise get: work of their
## own, standing somewhere they chose, that the crew will muster for.
func _new_project_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_np_label = LineEdit.new()
	_np_label.placeholder_text = "New project — what is being built"
	_np_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_np_label)
	_np_hours = SpinBox.new()
	_np_hours.min_value = 0.5
	_np_hours.max_value = 400.0
	_np_hours.step = 0.5
	_np_hours.value = 8.0
	_np_hours.prefix = "≈"
	_np_hours.suffix = " person-h"
	row.add_child(_np_hours)
	_np_crew = SpinBox.new()
	_np_crew.min_value = 1
	_np_crew.max_value = 32
	_np_crew.value = 2
	_np_crew.prefix = "crew "
	row.add_child(_np_crew)
	_np_where = Button.new()
	UITheme.style_button(_np_where)
	_np_where.text = "Where…"
	_np_where.tooltip_text = "Pick where the work happens — the crew walks there"
	_np_where.pressed.connect(_on_np_where)
	row.add_child(_np_where)
	var add := Button.new()
	UITheme.style_button(add)
	add.text = "Queue"
	add.tooltip_text = "Put this job on the board as a project"
	add.pressed.connect(_on_np_queue)
	row.add_child(add)
	var wrap := VBoxContainer.new()
	wrap.add_theme_constant_override("separation", 2)
	wrap.add_child(row)
	_np_err = Label.new()
	_np_err.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_np_err.add_theme_color_override("font_color", UITheme.C_WARN)
	_np_err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_np_err.visible = false
	wrap.add_child(_np_err)
	return wrap


## Report a failure where the player can actually see it.
##
## This used to overwrite the LineEdit's placeholder, which is invisible the
## moment anyone types a character — so "the board is full" was, in practice,
## the button silently doing nothing.
func _np_error(text: String) -> void:
	if _np_err == null:
		return
	_np_err.text = text
	_np_err.visible = not text.is_empty()


func _on_np_where() -> void:
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_settlement_view"):
		_np_error("The settlement view is not available here.")
		return
	var view: Variant = main.call("open_settlement_view")
	if view == null or not view.has_method("pick_point_once"):
		_np_error("The settlement view is not available here.")
		return
	# Close only once the pick is actually armed — closing first and then
	# bailing stranded the player with no UI at all.
	close()
	view.call("pick_point_once", func(p: Vector2) -> void:
		if p != Vector2.INF:
			_np_site = p
			_np_where.text = "@ %d, %d" % [int(p.x), int(p.y)]
		open(_bridge))


func _on_np_queue() -> void:
	if _bridge == null:
		return
	var label := _np_label.text.strip_edges()
	if label.is_empty():
		_np_error("Give the project a name.")
		return
	# Whichever habitat is running: this is a settlement-wide job, and the
	# board it lands on is the one with people on it.
	var iid := ""
	for r in _bridge.all_site_projects():
		iid = str((r as Dictionary).get("iid", ""))
		break
	if iid.is_empty() and _bridge.has_method("pop_driven_item_ids"):
		var ids: Array = _bridge.call("pop_driven_item_ids")
		if not ids.is_empty():
			iid = str(ids[0])
	if iid.is_empty():
		_np_error("Nobody to do the work — turn on Population Simulation for a habitat first.")
		return
	# ONE task. Splitting a hand-authored job into phases would be inventing
	# structure the player did not describe; the generators do that because
	# they know what the phases ARE.
	var rows := [{
		"id": "work", "label": label,
		"work_s": maxf(float(_np_hours.value), 0.5) * 3600.0,
		"min_workers": 1, "max_workers": int(_np_crew.value),
		"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
	}]
	var target: Dictionary = {}
	if _np_site != Vector2.INF:
		target = {"kind": "pos", "x": _np_site.x, "z": _np_site.y}
	var made := str(_bridge.create_site_project(iid, "custom", label, "",
		_np_site if _np_site != Vector2.INF else Vector2.ZERO, rows,
		{"start_h": 7.0, "end_h": 19.0}, target))
	if made.is_empty():
		# Leave the typed label in place — clearing it on failure both erased
		# the player's input AND wiped this very error one line later.
		_np_error("The board is full — finish or cancel something first.")
		return
	_np_label.text = ""
	_np_error("")
	_np_site = Vector2.INF
	_np_where.text = "Where…"
	_refresh()


# --- refresh -----------------------------------------------------------------

## Packed linkage crates that could be raised again — the management surface's
## own road back up, so a teardown is reversible from the same panel that
## watched it happen (the crate's edit drawer is the other entry point).
func _rebuildable_crates() -> Array:
	var main := get_tree().current_scene
	var loader: Node = TerrainSurfaceQuery.find_terrain_loader(main) \
		if main != null else null
	if loader == null or not loader.has_method("placed_prop_records"):
		return []
	var out: Array = []
	for r in (loader.call("placed_prop_records") as Array):
		var rec := r as Dictionary
		if rec.get("linkage_spec") is Dictionary \
				and bool(rec.get("packed", false)) \
				and str(rec.get("stowed_in", "")).is_empty() \
				and not (rec.get("build_state") is Dictionary):
			out.append(rec)
	return out


func _rebuild_row(rec: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "📦 Packed structure at %d, %d" % [
		int(rec.get("x", 0.0)), int(rec.get("z", 0.0))]
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	var btn := Button.new()
	UITheme.style_button(btn)
	btn.text = "👷 Rebuild…"
	btn.tooltip_text = "Queue the raise: the crew unfolds the frame, re-bolts the ring and re-mounts the panels"
	var pid := str(rec.get("id", ""))
	btn.pressed.connect(func() -> void:
		var res := PlacedPropService.queue_linkage_rebuild(
			get_tree().current_scene, pid)
		if not bool(res.get("ok", false)):
			_np_error(str(res.get("error", "Could not queue the rebuild")))
			return
		_np_error("")
		_refresh())
	row.add_child(btn)
	return row


func _refresh() -> void:
	if _bridge == null:
		return
	for child in _list.get_children():
		if child != _empty_lbl:
			child.queue_free()
	var rows: Array = _bridge.all_site_projects()
	var crates := _rebuildable_crates()
	for c in crates:
		_list.add_child(_rebuild_row(c as Dictionary))
	_empty_lbl.visible = rows.is_empty() and crates.is_empty()
	# Newest first — the project just queued is the one being watched.
	rows.sort_custom(func(a, b) -> bool:
		return float((a["project"] as Dictionary).get("created_h", 0.0)) \
			> float((b["project"] as Dictionary).get("created_h", 0.0)))
	for row in rows:
		_list.add_child(_project_card(str(row["iid"]), row["project"] as Dictionary))


func _project_card(iid: String, project: Dictionary) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	card.add_child(vb)
	var board = _bridge.chore_board_for(iid)
	var roll: Dictionary = SiteProject.rollup(project, board)
	var state := str(project.get("state", "active"))
	var paused := bool(project.get("paused", false))

	# Header row: glyph + label + state + controls.
	var head := HBoxContainer.new()
	vb.add_child(head)
	var glyph: String = str({
		SiteProject.KIND_DELIVERY: "🚚",
		SiteProject.KIND_LINKAGE_BUILD: "🏗",
		SiteProject.KIND_LINKAGE_BREAKDOWN: "📦",
	}.get(str(project.get("kind", "")), "👷"))
	var name_lbl := Label.new()
	name_lbl.text = "%s %s" % [glyph, str(project.get("label", "Project"))]
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_lbl)
	# The click-through that closes the loop between the plan and the work:
	# stop reading the Gantt, go and watch this site.
	var site_d: Dictionary = project.get("site", {})
	var site := Vector2(float(site_d.get("x", 0.0)), float(site_d.get("z", 0.0)))
	var watch := Button.new()
	UITheme.style_button(watch)
	watch.text = "Watch"
	watch.tooltip_text = "Open the settlement view over this site"
	watch.pressed.connect(func() -> void:
		var main := get_tree().current_scene
		if main == null or not main.has_method("open_settlement_view"):
			return
		close()
		main.call("open_settlement_view", site))
	head.add_child(watch)
	var state_lbl := Label.new()
	state_lbl.text = ("⏸ paused" if paused else state)
	state_lbl.add_theme_color_override("font_color",
		C_DONE if state == "done" else (C_SKIPPED if state == "cancelled" else UITheme.C_TEXT_S))
	head.add_child(state_lbl)
	if state == "active":
		var pause_btn := Button.new()
		UITheme.style_button(pause_btn)
		pause_btn.text = "Resume" if paused else "Pause"
		pause_btn.pressed.connect(func() -> void:
			_bridge.set_project_paused(iid, str(project.get("id", "")), not paused)
			_refresh())
		head.add_child(pause_btn)
		var cancel_btn := Button.new()
		UITheme.style_button(cancel_btn)
		cancel_btn.text = "Cancel"
		cancel_btn.tooltip_text = "Removes the remaining phases. Completed work keeps its effects."
		cancel_btn.pressed.connect(func() -> void:
			_bridge.cancel_project(iid, str(project.get("id", "")))
			_refresh())
		head.add_child(cancel_btn)

	# Rollup: progress bar + plan-vs-actual line.
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = float(roll.get("progress", 0.0))
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	vb.add_child(bar)
	var plan: Dictionary = project.get("plan", {})
	var meta := Label.new()
	var plan_txt := ""
	if plan.has("makespan_s"):
		plan_txt = "planned %.1f h with %d crew · " % [
			float(plan.get("makespan_s", 0.0)) / 3600.0, int(plan.get("crew", 0))]
	var elapsed := maxf(_now_h() - float(project.get("created_h", 0.0)), 0.0)
	meta.text = "%s%d/%d phases done · %.1f h since queued" % [
		plan_txt, int(roll.get("done", 0)), int(roll.get("total", 0)), elapsed]
	meta.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vb.add_child(meta)

	# Planned-schedule strip with live status colouring (green done / amber
	# active fill / dim pending / red skipped). Planned bars come from the
	# scheduler's promise at queue time — the honest "plan vs what actually
	# happened" read at a glance.
	var timeline: Array = plan.get("timeline", [])
	if not timeline.is_empty():
		vb.add_child(_gantt_strip(project, board, timeline))

	# Phase rows.
	for t in project.get("tasks", []):
		vb.add_child(_task_row(t as Dictionary, board))

	# What-if table for linkage builds (needs the stored fab counts).
	if str(project.get("kind", "")) == SiteProject.KIND_LINKAGE_BUILD \
			and (plan.get("fab_counts", {}) as Dictionary).size() > 0 \
			and state == "active":
		vb.add_child(_whatif_block(iid, plan.get("fab_counts", {}) as Dictionary))
	# The simulated comparison sits under the planned one for EVERY active
	# project kind — the gap between the two columns is the point.
	if state == "active":
		vb.add_child(_experiment_block(iid, project))
	return card


func _task_row(task: Dictionary, board) -> Control:
	var row := HBoxContainer.new()
	var status := str(task.get("status", "pending"))
	var chore: Dictionary = board.find(str(task.get("chore_id", ""))) \
		if board != null else {}
	var chip := Label.new()
	var col := C_PENDING
	var mark := "○"
	match status:
		"done":
			col = C_DONE
			mark = "●"
		"skipped":
			col = C_SKIPPED
			mark = "⊘"
		_:
			if not (chore.get("workers", []) as Array).is_empty():
				col = C_ACTIVE
				mark = "◐"
	chip.text = mark
	chip.add_theme_color_override("font_color", col)
	row.add_child(chip)
	var lbl := Label.new()
	lbl.text = str(task.get("label", ""))
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)
	if status == "pending" and not chore.is_empty():
		var workers := (chore.get("workers", []) as Array).size()
		var min_w := int(chore.get("min_workers", 1))
		var crew := Label.new()
		if workers > 0 and workers < min_w:
			crew.text = "%d/%d ppl — gathering" % [workers, min_w]
			crew.add_theme_color_override("font_color", C_ACTIVE)
		elif workers > 0:
			crew.text = "%d ppl" % workers
			crew.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		elif min_w > 1:
			crew.text = "needs %d ppl" % min_w
			crew.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		row.add_child(crew)
		var hours := maxf(float(chore.get("chore_hours", 0.0)), 0.001)
		var pb := ProgressBar.new()
		pb.min_value = 0.0
		pb.max_value = 1.0
		pb.value = clampf(float(chore.get("progress_h", 0.0)) / hours, 0.0, 1.0)
		pb.show_percentage = false
		pb.custom_minimum_size = Vector2(90, 6)
		row.add_child(pb)
	return row


## Custom-drawn schedule strip: one lane per planned task, bar span = the
## scheduler's planned window, colour = live status.
func _gantt_strip(project: Dictionary, board, timeline: Array) -> Control:
	var strip := Control.new()
	strip.custom_minimum_size = Vector2(0, maxi(timeline.size() * 8 + 4, 20))
	var status_by_task: Dictionary = {}
	var active_frac: Dictionary = {}
	for t in project.get("tasks", []):
		var task: Dictionary = t
		var tid := str(task.get("task_id", ""))
		status_by_task[tid] = str(task.get("status", "pending"))
		var chore: Dictionary = board.find(str(task.get("chore_id", ""))) \
			if board != null else {}
		if not chore.is_empty():
			active_frac[tid] = clampf(float(chore.get("progress_h", 0.0))
				/ maxf(float(chore.get("chore_hours", 0.0)), 0.001), 0.0, 1.0)
	var span := 1.0
	for r in timeline:
		span = maxf(span, float((r as Dictionary).get("end_s", 0.0)))
	strip.draw.connect(func() -> void:
		var w := strip.size.x
		for i in timeline.size():
			var r := timeline[i] as Dictionary
			var tid := str(r.get("task_id", ""))
			var x0 := float(r.get("start_s", 0.0)) / span * w
			var x1 := maxf(float(r.get("end_s", 0.0)) / span * w, x0 + 2.0)
			var y := 2.0 + i * 8.0
			var status := str(status_by_task.get(tid, "pending"))
			var base := C_PENDING
			base.a = 0.35
			strip.draw_rect(Rect2(x0, y, x1 - x0, 6), base)
			match status:
				"done":
					strip.draw_rect(Rect2(x0, y, x1 - x0, 6), C_DONE)
				"skipped":
					strip.draw_rect(Rect2(x0, y, x1 - x0, 6), C_SKIPPED)
				_:
					var f := float(active_frac.get(tid, 0.0))
					if f > 0.0:
						strip.draw_rect(Rect2(x0, y, (x1 - x0) * f, 6), C_ACTIVE)
	)
	return strip


## The experiment loop: makespan across crew sizes and night shift, computed
## instantly from the scheduler. Honestly labelled a plan — needs, weather
## and morale will stretch it; the point is the SHAPE (where more hands stop
## helping, what the raise gates on).
func _whatif_block(iid: String, counts: Dictionary) -> Control:
	var vb := VBoxContainer.new()
	var head := Label.new()
	head.text = "What-if (planned makespan — the sim will stretch it):"
	head.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vb.add_child(head)
	var tasks := NpcCrewPlan.linkage_fab_tasks(counts)
	var roster: int = _bridge.roster_size_for(iid)
	var line := ""
	for crew in WHATIF_CREWS:
		var sched := NpcCrewPlan.schedule(tasks, int(crew))
		var txt := "%.1fh" % (float(sched.get("makespan_s", 0.0)) / 3600.0) \
			if bool(sched.get("feasible", false)) else "can't raise"
		var cell := "%d ppl: %s" % [int(crew), txt]
		if int(crew) == roster:
			cell = "▶ " + cell
		line += cell + "   "
	var lbl := Label.new()
	lbl.text = line.strip_edges()
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(lbl)
	var board = _bridge.chore_board_for(iid)
	if board != null:
		var night := CheckBox.new()
		night.text = "Night shift (site rule — chores ignore daily windows)"
		night.button_pressed = bool(board.rules.get("night_shift", false))
		night.toggled.connect(func(on: bool) -> void:
			board.rules["night_shift"] = on)
		vb.add_child(night)
	return vb


## The SIMULATED comparison, sitting under the planned one. Deliberately behind
## a button: a run is seconds of CPU, and this panel rebuilds every card every
## 0.75 s — auto-running would restart it four times a second. Results are
## cached on the PANEL (not the card) under a signature, so the rebuild
## repaints them instead of recomputing.
func _experiment_block(iid: String, project: Dictionary) -> Control:
	var vb := VBoxContainer.new()
	var sig := ""
	var setup: Dictionary = {}
	if _bridge.has_method("experiment_setup"):
		setup = _bridge.experiment_setup(iid, str(project.get("id", "")),
			get_tree().current_scene)
	if setup.is_empty():
		return vb
	sig = NpcExperimentLab.signature_for(setup)

	if _lab != null and _lab.is_running():
		var bar := ProgressBar.new()
		bar.min_value = 0.0
		bar.max_value = 1.0
		bar.value = _lab_progress
		bar.custom_minimum_size = Vector2(0, 10)
		vb.add_child(bar)
		var wait := Label.new()
		wait.text = "Simulating variants…"
		wait.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		vb.add_child(wait)
		return vb

	if sig == _lab_sig and not _lab_rows.is_empty():
		vb.add_child(_experiment_table())
		var again := Button.new()
		UITheme.style_button(again)
		again.text = "Re-run"
		again.pressed.connect(func() -> void: _start_experiment(setup, sig))
		vb.add_child(again)
		return vb

	var run := Button.new()
	UITheme.style_button(run)
	run.text = "🔬 Run sim comparison"
	run.tooltip_text = "Simulates the real crew under each rule — needs, morale, weather and daily windows included"
	run.pressed.connect(func() -> void: _start_experiment(setup, sig))
	vb.add_child(run)
	return vb


func _start_experiment(setup: Dictionary, sig: String) -> void:
	if _lab == null or not is_instance_valid(_lab):
		_lab = NpcExperimentLab.new()
		# Child of the PANEL, not the card — cards are destroyed and rebuilt
		# every refresh, which would kill a run in flight.
		add_child(_lab)
		_lab.progress.connect(func(f: float) -> void:
			# NEVER _refresh() from here: progress fires per frame, and a
			# refresh rebuilds every card. Store it; the 0.75 s tick paints it.
			_lab_progress = f)
		_lab.results_ready.connect(func(rows: Array, summary: Dictionary) -> void:
			_lab_rows = rows
			_lab_summary = summary
			_refresh())
	_lab_sig = sig
	_lab_rows = []
	_lab_progress = 0.0
	_lab.start(setup)


func _experiment_table() -> Control:
	var vb := VBoxContainer.new()
	var head := Label.new()
	head.text = "Simulated (real crew — needs, morale, weather, windows):"
	head.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	vb.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	vb.add_child(grid)
	for h in ["Variant", "Simulated", "Planned", "Drag"]:
		var hl := Label.new()
		hl.text = h
		hl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		grid.add_child(hl)
	for r in _lab_rows:
		var rd := r as Dictionary
		var name_lbl := Label.new()
		name_lbl.text = str(rd.get("label", ""))
		grid.add_child(name_lbl)
		var status := str(rd.get("status", ""))
		var val := Label.new()
		match status:
			"done":
				val.text = "%.1f h" % float(rd.get("makespan_h", 0.0))
			"dnf":
				val.text = "—"
				val.tooltip_text = str(rd.get("dnf_reason", ""))
				val.add_theme_color_override("font_color", C_SKIPPED)
			"na":
				val.text = "n/a"
				val.add_theme_color_override("font_color", UITheme.C_TEXT_S)
			_:
				val.text = str(rd.get("dnf_reason", "—"))
				val.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		grid.add_child(val)
		var plan_lbl := Label.new()
		plan_lbl.text = "%.1f h" % float(rd.get("plan_h", 0.0)) \
			if float(rd.get("plan_h", 0.0)) > 0.0 else "—"
		grid.add_child(plan_lbl)
		var drag := Label.new()
		# -1 = no task graph to compare against. Show nothing rather than
		# claiming the whole makespan was overhead.
		var dh := float(rd.get("drag_h", -1.0))
		drag.text = "+%.1f h" % dh if (status == "done" and dh >= 0.0) else ""
		drag.add_theme_color_override("font_color", C_ACTIVE)
		grid.add_child(drag)
	if not _lab_summary.is_empty() and not str(_lab_summary.get("best_label", "")).is_empty():
		var best := Label.new()
		if not bool(_lab_summary.get("baseline_done", false)):
			best.text = "Fastest: %s (%.1f h) — as it stands, the job never finishes" % [
				str(_lab_summary["best_label"]), float(_lab_summary.get("best_h", 0.0))]
		elif float(_lab_summary.get("saving_h", 0.0)) > 0.01:
			best.text = "Fastest: %s — %.1f h saved over how it stands" % [
				str(_lab_summary["best_label"]),
				float(_lab_summary.get("saving_h", 0.0))]
		else:
			best.text = "Nothing beats how it stands (%.1f h)" % \
				float(_lab_summary.get("baseline_h", 0.0))
		best.add_theme_color_override("font_color", C_DONE)
		vb.add_child(best)
	var caveat := Label.new()
	caveat.text = "Fresh crew from the current hour · today's weather held · straight-line routes, no terrain · 15-minute resolution."
	caveat.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	caveat.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(caveat)
	return vb


func _now_h() -> float:
	var main := get_tree().current_scene
	if main != null and main.has_method("get_absolute_hours"):
		return float(main.call("get_absolute_hours"))
	return 0.0

extends Node

## Solar Bootcamp director: level state machine + sandbox lifecycle. Created
## lazily as a child of SystemGraphView (which owns the sandbox mechanics —
## see begin/end_tutorial_sandbox); this node owns FLOW: which level is
## active, goal evaluation, briefs/debriefs, unlock grants, the HUD.
##
## States: INACTIVE → (enter sandbox) BRIEF → BUILD → DEBRIEF → next level…
## Run-levels (def.is_run_level(), curriculum 8+) are skipped until the bake
## engine phase lands.

const _HUD_SCRIPT := preload("res://scenes/ui/tutorial_hud.gd")
const EVAL_INTERVAL_S := 0.5

enum State { INACTIVE, BRIEF, BUILD, DEBRIEF }

var _gv: Control = null
var _hud: Control = null
var _state: int = State.INACTIVE
var _level: TutorialLevelDef = null
var _faults_seen: Dictionary = {}
var _eval_acc: float = 0.0


func bind_graph_view(gv: Control) -> void:
	_gv = gv
	if _gv.has_signal("electrical_fault_observed") \
			and not _gv.is_connected("electrical_fault_observed", _on_fault_observed):
		_gv.connect("electrical_fault_observed", _on_fault_observed)
	if _gv.has_signal("sandbox_interrupted") \
			and not _gv.is_connected("sandbox_interrupted", _on_sandbox_interrupted):
		_gv.connect("sandbox_interrupted", _on_sandbox_interrupted)


func is_active() -> bool:
	return _state != State.INACTIVE


func toggle() -> void:
	if is_active():
		exit_tutorial()
	else:
		start()


## Enter the bootcamp at `level_id` (or the first incomplete level).
func start(level_id: String = "") -> void:
	if _gv == null or is_active():
		return
	var lid := level_id
	if lid.is_empty():
		lid = ProgressStore.first_incomplete_level(TutorialCatalog.ordered_ids())
	if lid.is_empty():
		lid = str(TutorialCatalog.ordered_ids()[0])  # all done — replay from 1
	var def := TutorialCatalog.by_id(lid)
	if def == null or def.is_run_level():
		# Run-levels arrive with the bake engine; never strand the player.
		def = TutorialCatalog.by_id(str(TutorialCatalog.ordered_ids()[0]))
		if def == null:
			return
	if not bool(_gv.call("begin_tutorial_sandbox")):
		return
	_gv.call("open_graph_view")
	_ensure_hud()
	_load_level(def)


func exit_tutorial() -> void:
	if not is_active():
		return
	_state = State.INACTIVE
	_level = null
	_faults_seen.clear()
	if _hud != null:
		_hud.call("hide_hud")
	if _gv != null:
		_gv.call("clear_tutorial_palette")
		_gv.call("end_tutorial_sandbox")


func _on_sandbox_interrupted() -> void:
	# External load won the canvas — stand down without touching graph state.
	_state = State.INACTIVE
	_level = null
	_faults_seen.clear()
	if _hud != null:
		_hud.call("hide_hud")
	if _gv != null:
		_gv.call("clear_tutorial_palette")


func _load_level(def: TutorialLevelDef) -> void:
	_level = def
	_faults_seen.clear()
	_eval_acc = 0.0
	_gv.call("tutorial_clear_graph")
	_gv.call("tutorial_seed_level", def.seed, def.seed_wires)
	_gv.call("set_tutorial_palette", def.allowed_presets)
	if _hud != null:
		_hud.call("show_level", def.index, def.title, _objective_line(def))
	_state = State.BRIEF
	_show_brief()


func _objective_line(def: TutorialLevelDef) -> String:
	match str(def.goal.get("kind", "")):
		"fault_observed":
			return "Follow the briefing — failure is the objective."
		"build":
			var bits: Array[String] = []
			if float(def.goal.get("min_deliverable_w", 0.0)) > 0.0:
				bits.append("deliver ≥ %.0f W" % float(def.goal.get("min_deliverable_w", 0.0)))
			if float(def.goal.get("min_bus_v", 0.0)) > 0.0:
				bits.append("bank ≥ %.0f V" % float(def.goal.get("min_bus_v", 0.0)))
			if int(def.goal.get("series", 0)) > 0:
				bits.append("array %dS%dP" % [int(def.goal.get("series", 0)), int(def.goal.get("parallel", 0))])
			if bits.is_empty():
				return "Follow the briefing."
			return "Wire it so you " + " and ".join(bits)
	return "Follow the briefing."


func _show_brief() -> void:
	_gv.call("show_tutorial_card", {
		"title": "Level %d — %s" % [_level.index, _level.title],
		"title_color": UITheme.C_PRIMARY,
		"body": _level.brief_bbcode,
		"actions": [{"label": "Let's go", "callback": Callable(self, "_on_brief_done")}],
	})


func _on_brief_done() -> void:
	if _state == State.BRIEF:
		_state = State.BUILD


func _on_fault_observed(reason: String, _item_id: String) -> void:
	if not is_active():
		return
	_faults_seen[reason] = true
	# A fault card is showing right now; evaluate on the next tick so a
	# success-via-fault level completes immediately after (queued card).
	_eval_acc = EVAL_INTERVAL_S


func _process(delta: float) -> void:
	if _state != State.BUILD and _state != State.BRIEF:
		return
	_eval_acc += delta
	if _eval_acc < EVAL_INTERVAL_S:
		return
	_eval_acc = 0.0
	if _level == null or _gv == null:
		return
	var model: GraphModel = _gv.get("model")
	if model == null:
		return
	var ctx := TutorialGoals.build_ctx(model, _faults_seen)
	var res := TutorialGoals.evaluate(_level.goal, ctx)
	if _hud != null:
		_hud.call("set_progress", str(res.get("progress", "")))
	if bool(res.get("met", false)) and _state == State.BUILD:
		_complete_level()


func _complete_level() -> void:
	_state = State.DEBRIEF
	ProgressStore.mark_level_complete(_level.id)
	if not _level.unlocks.is_empty():
		ProgressStore.grant(_level.unlocks)
	# New unlocks appear once the per-level palette lifts (level advance/exit).
	var next_id := TutorialCatalog.next_after(_level.id)
	var next_def := TutorialCatalog.by_id(next_id) if not next_id.is_empty() else null
	var actions: Array = []
	if next_def != null and not next_def.is_run_level():
		actions.append({"label": "Next level", "callback": Callable(self, "_on_next_level")})
	actions.append({"label": "Exit bootcamp", "callback": Callable(self, "exit_tutorial")})
	var body := _level.debrief_bbcode
	if next_def == null or next_def.is_run_level():
		body += "\n\n[color=#8899aa]That's the bootcamp for now — the 24-hour " \
				+ "run levels are on their way. Your unlocks are saved.[/color]"
	_gv.call("show_tutorial_card", {
		"title": "✓ Level %d complete" % _level.index,
		"title_color": UITheme.C_GREEN,
		"body": body,
		"actions": actions,
	})


func _on_next_level() -> void:
	var next_id := TutorialCatalog.next_after(_level.id)
	var def := TutorialCatalog.by_id(next_id) if not next_id.is_empty() else null
	if def == null or def.is_run_level():
		exit_tutorial()
		return
	_load_level(def)


func _ensure_hud() -> void:
	if _hud != null and is_instance_valid(_hud):
		return
	_hud = _HUD_SCRIPT.new()
	_hud.name = "TutorialHud"
	_gv.add_child(_hud)
	_hud.connect("briefing_requested", func() -> void:
		if _level != null:
			_show_brief())
	_hud.connect("exit_requested", exit_tutorial)

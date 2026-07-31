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
## Run-levels: the director's own bake engine (separate from ChallengeRunner's).
var _run_engine: ChallengeBakeEngine = null
## World state to hand back on exit — tutorial runs advance the clock and
## battery inside the sandbox; none of it may leak to the player's world.
var _pre_clock_abs := NAN
var _pre_battery_kwh := NAN


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
	if def == null:
		def = TutorialCatalog.by_id(str(TutorialCatalog.ordered_ids()[0]))
		if def == null:
			return
	if not bool(_gv.call("begin_tutorial_sandbox")):
		return
	# Levels 10-12 iterate on the graph the player built in the level before —
	# begin_tutorial_sandbox always starts from an empty canvas, so resuming
	# into one of these (a new session, or straight from the level picker)
	# needs that graph restored, or there is nothing left to build on.
	if def.carry_graph:
		_gv.call("restore_tutorial_sandbox_snapshot")
	# Snapshot the world the sandbox will perturb (runs advance the clock,
	# bake commits move the battery) so exit hands everything back.
	var m := _main_node()
	_pre_clock_abs = float(m.call("get_absolute_hours")) if m != null else NAN
	var su := _solar_ui()
	_pre_battery_kwh = float(su.call("get_battery_kwh_stored")) if su != null else NAN
	_gv.call("open_graph_view")
	_ensure_hud()
	_load_level(def)


func exit_tutorial() -> void:
	if not is_active():
		return
	_end_run_presentation()
	_state = State.INACTIVE
	_level = null
	_faults_seen.clear()
	if _run_engine != null and _run_engine.is_active():
		_run_engine.abort()
	if _hud != null:
		_hud.call("hide_hud")
	if _gv != null:
		_gv.call("clear_tutorial_palette")
		_gv.call("end_tutorial_sandbox")
	# Hand the world back exactly as we found it.
	var m := _main_node()
	if m != null and not is_nan(_pre_clock_abs):
		m.call("set_absolute_hours", _pre_clock_abs)
	var su := _solar_ui()
	if su != null and not is_nan(_pre_battery_kwh) \
			and su.has_method("reanchor_live_battery"):
		su.call("reanchor_live_battery", _pre_battery_kwh)
	_pre_clock_abs = NAN
	_pre_battery_kwh = NAN


func _on_sandbox_interrupted() -> void:
	_end_run_presentation()
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
	if _run_engine != null and _run_engine.is_active():
		_run_engine.abort()  # a parked breakpoint never outlives its level
	if not def.carry_graph:
		_gv.call("tutorial_clear_graph")
		_gv.call("tutorial_seed_level", def.seed, def.seed_wires)
	# Full Library everywhere (design decision 2026-07-30): levels no longer
	# restrict the palette — allowed_presets is retained in the defs as
	# curriculum metadata but not enforced. Clearing (rather than skipping)
	# also lifts any filter a previous session left behind.
	_gv.call("clear_tutorial_palette")
	if _hud != null:
		_hud.call("show_level", def.index, def.title, _objective_line(def),
			def.is_run_level())
	_state = State.BRIEF
	_show_brief()


func _objective_line(def: TutorialLevelDef) -> String:
	match str(def.goal.get("kind", "")):
		"fault_observed":
			return "Follow the briefing — failure is the objective."
		"run_clean":
			var min_util := float(def.goal.get("min_useful_utilization_pct", 0.0))
			if min_util > 0.0:
				return "Run 24 h cleanly with ≥ %.0f%% of the sun put to work." % min_util
			return "Run a full 24 h without a power failure."
		"ac_load_wired":
			return "Power an appliance from the controller's AC output."
		"compound_containing":
			return "Combine the controller + battery into one super-node (Ctrl+G)."
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
		"actions": [
			{"label": "↺ Start Over", "callback": Callable(self, "_on_start_over")},
			{"label": "Let's go", "callback": Callable(self, "_on_brief_done")},
		],
	})


func _on_brief_done() -> void:
	if _state == State.BRIEF:
		_state = State.BUILD


## TEMPORARY testing affordance (per playtest request): jump back to level 1
## without hunting for a way to un-stick a resumed-blank carry_graph level.
## Remove this action once the resume-persistence fix above is confirmed —
## it bypasses no unlock gating (allowed_presets still gates each level's
## Library while it's active), but it IS a one-click, no-confirmation reset of
## curriculum progress that has no place in a shipped build.
func _on_start_over() -> void:
	if _gv == null:
		return
	ProgressStore.reset_tutorial_progress()
	exit_tutorial()
	start(str(TutorialCatalog.ordered_ids()[0]))


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
	# While a run is baking / playing back, the engine narrates progress.
	if _run_engine != null and _run_engine.is_active() \
			and _run_engine.phase() != ChallengeBakeEngine.Phase.AWAIT_RETRY:
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


# ---- Run-levels (▶ Run 24 h → bake → playback → verdict) -------------------

func _on_run_requested() -> void:
	if _level == null or not _level.is_run_level() or _state != State.BUILD:
		return
	# Never fight the challenge runner's engine for the world.
	var m := _main_node()
	var runner: Node = m.get_node_or_null("ChallengeRunner") if m != null else null
	if runner != null and bool(runner.call("is_active")):
		_gv.call("show_tutorial_card", {"title": "Challenge in progress",
			"body": "Finish or abort the active 🎯 challenge first.",
			"title_color": UITheme.C_AMBER})
		return
	_ensure_run_engine()
	if _run_engine.phase() == ChallengeBakeEngine.Phase.AWAIT_RETRY:
		if _run_engine.retry():
			_begin_run_presentation()
			if _hud != null:
				_hud.call("set_run_busy", true)
				_hud.call("set_progress", "Re-running the same day…")
		return
	var su := _solar_ui()
	if m == null or su == null:
		return
	var def := ChallengeDef.from_dict({
		"id": "bootcamp_run_%s" % _level.id,
		"title": _level.title,
		"run_mode": "prebake",
		"span": str(_level.run.get("span", "day")),
		"fail_on_power_failure": bool(_level.run.get("fail_on_power_failure", true)),
		"fail_on_starvation": false,
		"require_no_starvation": false,
	})
	var start_abs := float(m.call("get_absolute_hours"))
	if _run_engine.start(m, _gv, su, def, start_abs):
		_begin_run_presentation()
		if _hud != null:
			_hud.call("set_run_busy", true)
			_hud.call("set_progress", "Running the day…")


## A 24-hour run used to be a static 2D screen: the graph is up, which sets
## disable_3d on the root viewport, so there was no sun and no world — the one
## thing that makes "daylight charges the battery" legible. The in-graph SoI
## preview renders into its own SubViewport sharing the root World3D and is NOT
## covered by that block, so switching it to live re-render shows the site with
## the sun tracking the playhead, behind the graph the player is reading.
func _begin_run_presentation() -> void:
	if _gv != null and _gv.has_method("set_live_world_preview"):
		_gv.call("set_live_world_preview", true)
	var su := _solar_ui()
	if su != null and su.has_method("set_clear_sky_override"):
		su.call("set_clear_sky_override", true)


## Must run on EVERY path out of a run — success, failure-parked, level change
## and bootcamp exit — or the graph keeps paying for a live 3D re-render (the
## preview service calls it the view's dominant cost) and the world stays stuck
## on a forced clear sky.
func _end_run_presentation() -> void:
	if _gv != null and _gv.has_method("set_live_world_preview"):
		_gv.call("set_live_world_preview", false)
	var su := _solar_ui()
	if su != null and su.has_method("set_clear_sky_override"):
		su.call("set_clear_sky_override", false)


func _ensure_run_engine() -> void:
	if _run_engine != null and is_instance_valid(_run_engine):
		return
	_run_engine = ChallengeBakeEngine.new()
	_run_engine.name = "TutorialRunEngine"
	add_child(_run_engine)
	# Playback streams behind the bake, so this reads as run progress rather
	# than a loading bar the player is stuck behind.
	_run_engine.bake_progress.connect(func(frac: float, _cursor: float) -> void:
		if _hud != null and frac < 1.0:
			_hud.call("set_progress", "Running the day… %d%%" % int(frac * 100.0)))
	_run_engine.bake_failed_at.connect(func(_abs_h: float, _reason: String) -> void:
		if _hud != null:
			_hud.call("set_progress", "It didn't make it — watching the day…"))
	_run_engine.retry_ready.connect(_on_run_retry_ready)
	_run_engine.run_succeeded.connect(_on_run_succeeded)


func _on_run_retry_ready(abs_h: float, reason: String, _attempts_n: int) -> void:
	_end_run_presentation()
	if _hud != null:
		_hud.call("set_run_busy", false)
		_hud.call("set_progress", "Failed %.1f h in — fix it, then ▶ Run again" %
			maxf(abs_h - float(_run_engine.get("_start_abs")), 0.0))
	_gv.call("show_tutorial_card", {
		"title": "Power failure",
		"body": ("The system went dark: [b]%s[/b]\n\nThe timeline is parked at the " +
			"moment it failed. Fix the system — more storage, more panels, fewer " +
			"loads at night — then press [b]▶ Run[/b] to replay the SAME day.")
			% ChallengeDef.reason_label(reason),
	})


func _on_run_succeeded(bake_result: Dictionary) -> void:
	_end_run_presentation()
	if _hud != null:
		_hud.call("set_run_busy", false)
	if _level == null:
		return
	var verdict := TutorialGoals.evaluate_run(_level.goal, bake_result)
	if _hud != null:
		_hud.call("set_progress", str(verdict.get("progress", "")))
	if bool(verdict.get("met", false)):
		_complete_level({
			"useful_utilization_pct": float(bake_result.get("useful_utilization_pct", 0.0)),
			"attempts": int(bake_result.get("attempts", 1)),
		})
	else:
		# Clean run but under the utilization bar: explain, invite another run.
		_gv.call("show_tutorial_card", {
			"title": "Survived — now optimize",
			"title_color": UITheme.C_AMBER,
			"body": ("The day completed, but only [b]%.0f%%[/b] of the available sun " +
				"did useful work (loads served + charge banked). Target: [b]%.0f%%[/b].\n\n" +
				"Add loads, size them up, or automate them to soak up the midday " +
				"surplus — then ▶ Run the same day again.") % [
					float(bake_result.get("useful_utilization_pct", 0.0)),
					float(_level.goal.get("min_useful_utilization_pct", 0.0))],
		})


func _complete_level(stats: Dictionary = {}) -> void:
	_state = State.DEBRIEF
	ProgressStore.mark_level_complete(_level.id, stats)
	if not _level.unlocks.is_empty():
		ProgressStore.grant(_level.unlocks)
	# New unlocks appear once the per-level palette lifts (level advance/exit).
	var next_id := TutorialCatalog.next_after(_level.id)
	var next_def := TutorialCatalog.by_id(next_id) if not next_id.is_empty() else null
	var actions: Array = []
	if next_def != null:
		actions.append({"label": "Next level", "callback": Callable(self, "_on_next_level")})
	actions.append({"label": "Exit bootcamp", "callback": Callable(self, "exit_tutorial")})
	# Name what was earned. ProgressStore.grant() is a silent static write, so
	# without this the player is told "level complete" and never learns which
	# components just appeared in their Library.
	var earned := unlock_labels(_level.unlocks)
	var body := _level.debrief_bbcode
	if not earned.is_empty():
		body += "\n\n[color=#26e577]★ Unlocked:[/color] [b]%s[/b]" % "  ·  ".join(earned)
	# Success-via-fault levels complete on the same frame as the destroy boom —
	# give the bang two seconds to land before the reward sounds.
	var sfx_delay := 2.0 if str(_level.goal.get("kind", "")) == "fault_observed" else 0.0
	_celebrate_unlocks(earned, sfx_delay)
	_gv.call("show_tutorial_card", {
		"title": "✓ Level %d complete" % _level.index,
		"title_color": UITheme.C_GREEN,
		"body": body,
		"actions": actions,
	})


## Human-readable names for "cat:<id>" / "preset:<label>" / "unlock_all" grant
## entries, so the reward can be shown rather than silently applied.
static func unlock_labels(unlocks: Array) -> Array:
	var out: Array = []
	for raw in unlocks:
		var s := str(raw)
		if s == "unlock_all":
			out.append("the full component library")
		elif s.begins_with("preset:"):
			out.append(s.trim_prefix("preset:"))
		elif s.begins_with("cat:"):
			var cid := s.trim_prefix("cat:")
			var label := cid.capitalize()
			for cat in ComponentPresets.CATEGORIES:
				if str((cat as Dictionary).get("id", "")) == cid:
					label = str((cat as Dictionary).get("label", label))
					break
			out.append(label)
	return out


## Fanfare + a chip per unlock. Chips ride the existing "+N UP" celebration
## path in ToastUI (already used when a fabricated part lands), so unlocks look
## like the game's other rewards rather than a bespoke popup.
##
## `delay_s`: hold the celebration back. Levels whose WIN is an explosion
## (success_via_fault — level 1's short circuit) complete on the same frame as
## the destroy boom, and chime-on-top-of-blast read as one confusing noise.
## Two seconds lets the bang land as a bang before the reward says "…and that
## was the right thing to do."
func _celebrate_unlocks(earned: Array, delay_s: float = 0.0) -> void:
	var m := _main_node()
	var sfx := m.get_node_or_null("/root/UiSound") if m != null else null
	if delay_s > 0.0:
		var hold := get_tree().create_timer(delay_s)
		hold.timeout.connect(func() -> void:
			_celebrate_unlocks(earned, 0.0), CONNECT_ONE_SHOT)
		return
	if earned.is_empty():
		if sfx != null:
			sfx.call("play_ui", UiSfx.SUCCESS)
		return
	if sfx != null:
		sfx.call("play_ui", UiSfx.FANFARE)
	if m == null or not m.has_method("show_part_up"):
		return
	# Stagger so several unlocks read as a run of rewards, not one clump.
	var delay := 0.0
	for label in earned:
		var txt := str(label)
		if delay <= 0.0:
			m.call("show_part_up", txt, 1)
		else:
			var t := get_tree().create_timer(delay)
			t.timeout.connect(func() -> void:
				if is_instance_valid(m):
					m.call("show_part_up", txt, 1), CONNECT_ONE_SHOT)
		delay += 0.45


func _on_next_level() -> void:
	var next_id := TutorialCatalog.next_after(_level.id)
	var def := TutorialCatalog.by_id(next_id) if not next_id.is_empty() else null
	if def == null:
		exit_tutorial()
		return
	_load_level(def)


func _main_node() -> Node:
	if _gv == null:
		return null
	var ul := _gv.get_parent()
	return ul.get_parent() if ul != null else null


func _solar_ui() -> Node:
	var m := _main_node()
	if m == null:
		return null
	var su: Node = m.get_node_or_null("UILayer/SolarUI")
	if su == null:
		su = m.find_child("SolarUI", true, false)
	return su


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
	_hud.connect("run_requested", _on_run_requested)
	_hud.connect("run_speed_requested", func(mult: float) -> void:
		if _run_engine != null and is_instance_valid(_run_engine):
			_run_engine.set_play_speed(mult))
	_hud.connect("run_skip_requested", func() -> void:
		if _run_engine != null and is_instance_valid(_run_engine):
			_run_engine.skip_to_result())

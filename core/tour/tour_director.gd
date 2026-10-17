class_name TourDirector
extends Node

## Runs the feature tour: an opening card, then every selected stop in file
## order (reset → title card → setup + run raced against the stop's budget →
## teardown → reset), then a closing card and `tour_manifest.json`.
##
## One stop going wrong never ends the tour: an overrun is cancelled and the
## tour moves on, and each stop prints exactly one verdict line
## ("tour PASS <id>" / "tour FAIL <id> — why") so the harness summary counts
## stops. The manifest carries per-stop frame numbers (Engine frames drawn) and
## wall-clock offsets so tools/tour.ps1 can cut the recording into chapters.
##
## Launched by playtest_harness `--capture=tour` (registry entry "tour"); the
## run happens in the harness sandbox, so nothing a stop does reaches the
## player's real world.

const MANIFEST_VERSION := 1
const INTRO_HOLD_S := 3.0
const OUTRO_HOLD_S := 3.0
const CARD_HOLD_S := 2.6
## Time the title card gets to itself before the demo starts moving.
const CARD_LEAD_S := 0.7
const TEARDOWN_BUDGET_S := 20.0

## Options (set before run()):
var shots_dir := "user://screenshots/tour"
var stop_ids: PackedStringArray = PackedStringArray()
var chapters: PackedStringArray = PackedStringArray()
var world_alias := ""
var include_optional := false
var pace := 1.0
var captions_on := true
var cards_on := true
## The harness report, to notice a script error raised during a stop.
var report: Object = null
var world_label := ""
## Movie Maker rate passed by tools/tour.ps1 (0 = read it off the command line).
var movie_fps_hint := 0
## Feature count on the opening card when the tour spans several worlds
## (tools/tour.ps1 runs one pass per world; 0 = this pass's count).
var intro_count := 0
## UI audit at every hero shot: "off", "report" (findings logged, never a
## FAIL) or "strict" (any ERROR finding fails the stop).
var audit_mode := "report"

var captions: TourCaptions = null
var _results: Array = []
## Tour time in seconds (game frames' delta, so a Movie Maker recording, whose
## frames are a fixed 1/fps apart however slowly they render, keeps budgets
## and chapter offsets in VIDEO time).
var _clock := 0.0
var _tour_t0 := 0.0
## Where the player stood when the tour began: every stop starts from there.
var _home := Transform3D()
var _home_cam_pitch := 0.0
var _has_home := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After SolarUI, which re-pushes clouds and rain from the weather each frame.
	process_priority = 1000


## Set by TourContext.clear_sky(); released by every baseline.
var clear_sky_hold := false
## What the hold switched off (microclimate fog), handed back on release.
var _clear_applied := false
var _clear_mc_was := true


## The crosshair prompt ("[O] Fly FPV Drone") is about where the PLAYER
## stands, not the feature on screen; InteractionFocus re-shows it every
## frame, so it is held hidden every frame while the tour runs.
var _prompt: CanvasLayer = null
var _prompt_was := false


func _process(delta: float) -> void:
	_clock += delta
	if clear_sky_hold:
		_apply_clear_sky()
	elif _clear_applied:
		_release_clear_sky()
	if _prompt != null and is_instance_valid(_prompt) and _prompt.visible:
		_prompt.visible = false


func _apply_clear_sky() -> void:
	var main: Node = null
	for child in get_tree().root.get_children():
		if "day_time" in child and "sun" in child:
			main = child
			break
	if main == null:
		return
	if not _clear_applied:
		_clear_applied = true
		var mc := get_node_or_null("/root/Microclimate")
		if mc != null:
			_clear_mc_was = bool(mc.get("enabled"))
			mc.call("set_enabled", false)
	main.set("clouds_cutoff", 1.0)
	main.set("clouds_weight", 0.0)
	main.set("cirrus_amount", 0.0)
	var precip := main.get_node_or_null("PrecipitationVfx") as Node3D
	if precip != null:
		precip.visible = false
	var env: Variant = main.get("environment")
	if env is WorldEnvironment and env.environment != null and env.environment.sky != null:
		var mat: Material = env.environment.sky.sky_material
		if mat is ShaderMaterial:
			mat.set_shader_parameter("clouds_cutoff", 1.0)
			mat.set_shader_parameter("clouds_weight", 0.0)
			mat.set_shader_parameter("cirrus_amount", 0.0)


## Hand back what the clear-sky hold switched off (the clouds themselves come
## back on the weather's next push).
func _release_clear_sky() -> void:
	_clear_applied = false
	var mc := get_node_or_null("/root/Microclimate")
	if mc != null:
		mc.call("set_enabled", _clear_mc_was)
	for child in get_tree().root.get_children():
		if "day_time" in child and "sun" in child:
			var precip := child.get_node_or_null("PrecipitationVfx") as Node3D
			if precip != null:
				precip.visible = true
			break


func run() -> Dictionary:
	DirAccess.make_dir_recursive_absolute(shots_dir)
	captions = TourCaptions.new()
	captions.name = "TourCaptions"
	add_child(captions)
	var all := TourCatalog.all_stops()
	var chosen := TourCatalog.select(all, stop_ids, chapters, world_alias, include_optional)
	print("tour: %d of %d stop(s) on %s — %s" % [chosen.size(), all.size(),
		world_alias if not world_alias.is_empty() else "any world",
		", ".join(chosen.map(func(s: TourStop) -> String: return s.id))])
	var t0 := _clock
	_tour_t0 = t0
	var f0 := Engine.get_frames_drawn()
	var ctx := _make_ctx()
	ctx.refresh_handles()
	if ctx.player != null:
		_home = ctx.player.global_transform
		var pc := ctx.player.get_node_or_null("CameraArm/Camera3D") as Camera3D
		_home_cam_pitch = pc.rotation.x if pc != null else 0.0
		_has_home = true
	# The "[O] Fly FPV Drone" style prompts are about where the PLAYER stands,
	# not about the feature on screen — off for the whole tour.
	if ctx.main != null:
		_prompt = ctx.main.get_node_or_null("UILayer/InteractionPromptUI") as CanvasLayer
	_prompt_was = _prompt != null and _prompt.visible
	_baseline(ctx, NAN)
	var n_intro := intro_count if intro_count > 0 else chosen.size()
	if cards_on and not chosen.is_empty():
		captions.show_full("SIMbiogenesis", "A quick tour of what it can do — %s" % UiText.count(n_intro, "feature"), INTRO_HOLD_S * pace)
		await ctx.wait(INTRO_HOLD_S + 1.1)
	for s0 in chosen:
		await _run_stop(s0 as TourStop)
	if cards_on and not chosen.is_empty():
		ctx.refresh_handles()
		captions.show_full("That's the tour", "SIMbiogenesis · %s · docs/FEATURES.md" % UiText.count(n_intro, "feature"), OUTRO_HOLD_S * pace)
		await ctx.wait(OUTRO_HOLD_S + 1.1)
	if _prompt != null and is_instance_valid(_prompt):
		_prompt.visible = _prompt_was
	_prompt = null
	var passed := _results.filter(func(r: Dictionary) -> bool: return r["status"] == "PASS").size()
	var manifest := {
		"version": MANIFEST_VERSION,
		"generated": Time.get_datetime_string_from_system(),
		"git_commit": _git_commit(),
		"world": world_alias,
		"world_label": world_label,
		"resolution": [int(get_viewport().get_visible_rect().size.x), int(get_viewport().get_visible_rect().size.y)],
		"pace": pace,
		"movie": _movie_info(),
		"start_frame": f0,
		"end_frame": Engine.get_frames_drawn(),
		"duration_s": snappedf(_clock - t0, 0.01),
		"chapters_order": TourStop.CHAPTERS,
		"stops": _results,
		"passed": passed,
		"total": _results.size(),
	}
	var f := FileAccess.open("%s/tour_manifest.json" % shots_dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("tour: %d of %d stop(s) passed — %s" % [passed, _results.size(),
		ProjectSettings.globalize_path(shots_dir)])
	captions.queue_free()
	return manifest


func _make_ctx() -> TourContext:
	var ctx := TourContext.new()
	ctx.host = self
	ctx.captions = captions
	ctx.pace = pace
	ctx.audit_mode = audit_mode
	return ctx


func _run_stop(stop: TourStop) -> void:
	var ctx := _make_ctx()
	ctx.stop = stop
	ctx.refresh_handles()
	ctx.stop_dir = "%s/stops/%s" % [shots_dir, stop.id]
	DirAccess.make_dir_recursive_absolute(ctx.stop_dir)
	_baseline(ctx, stop.hour)
	await ctx.frames(2)
	UiAudit.reset_canvas_truncations()
	var err0 := _script_error_count()
	var t0 := _clock
	var f0 := Engine.get_frames_drawn()
	var hints := TourContext.open_hints(stop)
	print("tour: ▶ %s — %s" % [stop.id, stop.title])
	if cards_on:
		captions.show_card(stop.chapter, stop.title, stop.summary, hints, CARD_HOLD_S * pace)
	await ctx.wait(CARD_LEAD_S)
	var done := [false]
	_body(stop, ctx, done)
	var budget := stop.budget_s * maxf(pace, 0.5)
	var timed_out := false
	while not done[0]:
		if _script_error_count() > err0:
			ctx.failures.append("a script error was raised during the stop")
			break
		if _clock - t0 > budget:
			timed_out = true
			ctx.failures.append("ran past its %.0f s budget" % budget)
			break
		await get_tree().process_frame
	if not done[0]:
		ctx.cancelled = true
		ctx.release_held()
		var grace := _clock + 3.0
		while not done[0] and _clock < grace:
			await get_tree().process_frame
	# Teardown runs un-cancelled: it is what puts the game back.
	ctx.cancelled = false
	var tdone := [false]
	_teardown(stop, ctx, tdone)
	var tdead := _clock + TEARDOWN_BUDGET_S
	while not tdone[0] and _clock < tdead:
		await get_tree().process_frame
	if not tdone[0]:
		ctx.failures.append("teardown did not finish")
	if ctx.hero_png.is_empty():
		ctx.failures.append("no hero screenshot")
	if not ctx.ui_audit.is_empty():
		HarnessReport.write_json("%s/ui_audit.json" % ctx.stop_dir, ctx.ui_audit)
		# Lower-case "uiaudit" and "error(s)": report mode must never trip the
		# harness's FAIL token counter.
		print("uiaudit %s: %s" % [stop.id, UiAudit.summary_line(ctx.ui_audit)])
		if audit_mode == "strict" and int(ctx.ui_audit.get("errors", 0)) > 0:
			ctx.failures.append("UI audit: %s" % UiAudit.summary_line(ctx.ui_audit))
	ctx.refresh_handles()
	_baseline(ctx, NAN)
	await ctx.frames(3)
	var secs := _clock - t0
	var status := "PASS" if ctx.failures.is_empty() else ("TIMEOUT" if timed_out else "FAIL")
	var rec := stop.meta()
	rec["open_hints"] = Array(hints)
	rec["key"] = HarnessInput.action_label(stop.action)
	rec["status"] = status
	rec["failures"] = Array(ctx.failures)
	rec["notes"] = Array(ctx.notes)
	rec["secs"] = snappedf(secs, 0.1)
	rec["start_frame"] = f0
	rec["end_frame"] = Engine.get_frames_drawn()
	rec["start_s"] = snappedf(t0 - _tour_t0, 0.01)
	rec["end_s"] = snappedf(_clock - _tour_t0, 0.01)
	rec["dir"] = "stops/%s" % stop.id
	rec["hero"] = "stops/%s/hero.jpg" % stop.id if not ctx.hero_jpg.is_empty() else ""
	rec["hero_png"] = "stops/%s/hero.png" % stop.id if not ctx.hero_png.is_empty() else ""
	rec["shots"] = ctx.shots
	if not ctx.ui_audit.is_empty():
		rec["ui_audit"] = {"errors": ctx.ui_audit.get("errors", 0), "warnings": ctx.ui_audit.get("warnings", 0),
			"counts": ctx.ui_audit.get("counts", {}), "file": "stops/%s/ui_audit.json" % stop.id}
	_results.append(rec)
	if status == "PASS":
		print("tour PASS %s (%.1f s)" % [stop.id, secs])
	else:
		print("tour FAIL %s (%.1f s) — %s" % [stop.id, secs, "; ".join(ctx.failures)])


func _body(stop: TourStop, ctx: TourContext, done: Array) -> void:
	await stop.setup(ctx)
	if not ctx.cancelled:
		await stop.run(ctx)
	done[0] = true


func _teardown(stop: TourStop, ctx: TourContext, done: Array) -> void:
	await stop.teardown(ctx)
	done[0] = true


func _script_error_count() -> int:
	if report == null:
		return 0
	var arr: Variant = report.get("script_errors")
	return (arr as Array).size() if arr is Array else 0


## Put the game in its tour-neutral state: first person, on foot, no overlay
## or lab up, no forced weather, HUD shown, tour camera released, the clock
## running at real time (people walk, clouds move) at `hour` if given.
func _baseline(ctx: TourContext, hour: float) -> void:
	clear_sky_hold = false
	ctx.release_held()
	ctx.release_camera()
	var main := ctx.main
	if main == null:
		return
	var graph := ctx.graph
	if graph != null:
		if graph.has_method("close_hydro_lab"):
			graph.call("close_hydro_lab")
		if bool(graph.get("visible")) and graph.has_method("close_graph_view"):
			graph.call("close_graph_view")
	var soi := ctx.autoload("SoiService")
	if soi != null and bool(soi.get("snowglobe_active")):
		soi.call("exit_snowglobe")
	if main.has_method("close_festival_mode"):
		main.call("close_festival_mode")
	var sv: Variant = main.get("settlement_view")
	if sv != null and is_instance_valid(sv) and bool(sv.call("is_open")):
		sv.call("close")
	var p := ctx.player
	if p != null:
		if bool(p.get("is_riding")) and p.has_method("_dismount_vehicle"):
			p.call("_dismount_vehicle")
		if _has_home and not bool(p.get("is_riding")):
			p.global_transform = _home
			if p is CharacterBody3D:
				(p as CharacterBody3D).velocity = Vector3.ZERO
			var pc := p.get_node_or_null("CameraArm/Camera3D") as Camera3D
			if pc != null:
				pc.rotation.x = _home_cam_pitch
	var pp := ctx.klass("PlayerPrefs")
	if pp != null and str(pp.call("camera_mode")) != "first":
		pp.call("set_camera_mode", "first")
	if ctx.loader != null:
		var tb: Variant = ctx.loader.get("_edit_toolbar_ui")
		if tb != null and is_instance_valid(tb) and bool((tb as Control).visible) and (tb as Object).has_method("_exit_mode"):
			tb.call("_exit_mode")
	var xw := ctx.autoload("ExtremeWeather")
	if xw != null and xw.has_method("clear_forced"):
		xw.call("clear_forced")
	if bool(main.get("analemma_mode")):
		main.set("analemma_mode", false)
	for c in main.get_children():
		if c is CanvasLayer and c.name == "UILayer":
			(c as CanvasLayer).visible = true
	ctx.run_clock(1.0)
	if not is_nan(hour):
		ctx.set_hour(hour)


func _git_commit() -> String:
	var out: Array = []
	if OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], out) == 0 \
			and not out.is_empty():
		return str(out[0]).strip_edges()
	return ""


## Is Godot's Movie Maker writing this run (`--write-movie <file>`), and at
## what rate (`--fixed-fps`, else the project's movie_writer fps)?
func _movie_info() -> Dictionary:
	var path := ""
	var fps := int(ProjectSettings.get_setting("editor/movie_writer/fps", 60))
	var args := OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "--write-movie" and i + 1 < args.size():
			path = args[i + 1]
		elif args[i] == "--fixed-fps" and i + 1 < args.size():
			fps = int(args[i + 1])
	if movie_fps_hint > 0:
		fps = movie_fps_hint
	return {"recording": not path.is_empty() or movie_fps_hint > 0, "file": path, "fps": fps}

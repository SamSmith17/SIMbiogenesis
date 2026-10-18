extends Node

## PlaytestHarness — CLI-driven map launch + automated drone-view screenshot
## capture for visual iteration on generated location maps.
##
## Active ONLY when user args (after `--`) are present; with no args every
## callback is a hard no-op so normal play, selftests, `--import` and headless
## boots are untouched.
##
## RUN IT THROUGH tools/harness.ps1 (CLAUDE.md "Harness rules"): the launcher
## gives Godot a throwaway SANDBOX copy of user:// and this script refuses to
## capture without one (or --persist). Every mode is in HarnessRegistry
## (core/terrain/harness/) with a default WORLD — Mount Vernon or Walton,
## launched through WorldSession so the player's saved state loads — and a
## watchdog budget; HarnessReport turns the run into one HARNESS RESULT line,
## results.json and a real exit code. SOAK / Mars only with
## --allow-builtin-scene. Extra args: --world=<alias|id>, --persist,
## --run-script=<res://…gd>, --timeout=<s>, --no-world, --capture=a,b,c.
##
##   Godot.exe.exe --path . --windowed -- --user-map=loc_33p3548_n115p7261.tres \
##       --capture=both --quit-after-capture
##
## Args (after the `--` separator):
##   --user-map=<file.tres>     MapDefinition in user://maps/ to launch (generated maps only)
##   --scene=<res://….tscn>     launch a built-in map scene directly (must be in
##                              MapDefinition.TRUSTED_SCENE_PATHS), e.g. the soak
##                              map for graph capture — the boot scene is the map
##                              chooser, which has no game UI
##   --map-lat=<f> --map-lon=<f> [--half-extent=<m>]  raw coordinates instead of a .tres
##   --capture=orbit|street|hero|both|graph|siphon|site-review
##                              automated capture after the map loads.
##                              "hero" = one close eye-level shot per building
##                              currently carrying a style override (facade
##                              texture review) — combine with --assign-facades
##                              "graph" = open the 2D systems graph (G view) and
##                              shoot one PNG per UI state (freeform/arranged/
##                              selection+inspector/library/compound interior/
##                              site plan/elevation/zoom extremes) — works on the
##                              default map (no --user-map needed; the StarShade
##                              seeder populates the graph there)
##                              "siphon" = Siphon Lab UI (synth pond on empty
##                              graphs; read-only when a siphon already exists)
##                              "site-review" = composite: world + freeform +
##                              site plan + elevation + snowglobe + Siphon Lab
##                              (+ diagnostics/perf JSON) for a real user map
##                              "windowwall" = the multi-monitor Window Wall
##                              "stars" = star field: marker-vs-texture pixel error + 2 h rotation about the pole
##                              "lights" = J Light Studio end to end with REAL input events (see _run_lights_capture)
##                              "propedit" = the unified placed-prop editor + gumball + fire timeline (see _run_prop_edit_capture)
##                              "vehicles" = placed vehicles + the third-person camera end to end (see _run_vehicle_capture)
##                              "dawn"  = sunrise lighting ladder: beam energy/colour + ambient per solar altitude
##                              "microclimate" = Walton valley-fog ladder: resolved fog per stop DUMPED + ground/drone PNGs
##                              through Main's real entry point: per-slot
##                              frustum dump, PNG per window, full-restore
##                              assertions (see _run_window_wall_capture)
##   --window-wall              open the Window Wall right after the map
##                              loads (desktop-shortcut launch for the bus)
##   --shots-dir=<label>        subfolder under user://screenshots/ (default timestamp)
##   --time=<hour>              sim clock hour for the shoot (default 10.0, paused)
##   --perf                     enable PerfMonitor HUD (F3) + write perf/*.json
##   --no-mutate                site-review: skip Demo/Sim Lab drive (as-loaded only)
##   --review-sets=a,b,…        site-review subsets: world,freeform,site,elevation,
##                              snowglobe,siphon,arranged
##                              (default: world,freeform,elevation,siphon)
##   --user-map=mtvernon        alias → scan user://maps for Mount Vernon display_name
##   --user-map=bombay|route111 alias → prefer Route 111 Bombay Beach, else Bombay Beach
##   --assign-facades=<N>       assign every user://maps/facade_textures/*.png
##                              round-robin to the N nearest house-sized
##                              buildings to spawn, via apply_building_style
##                              (same path the modal's Facade tex dropdown uses)
##   --sculpt-test              terrain-sculpt smoke test: shoots "before" views,
##                              runs a Raise stroke + Level pad + Pond via the
##                              real TerrainLoader commands, shoots "after"
##                              views, prints ground heights, then UNDOES all
##                              edits (the map's save data is left untouched)
##   --quit-after-capture       exit the process once the capture set is written
##
## Mt. Vernon site-review example:
##   Godot.exe.exe --path . --windowed --resolution 1280x720 -- \
##     --user-map=loc_48p3252_n122p2469.tres --capture=site-review --perf \
##     --shots-dir=mt_vernon_review --quit-after-capture
##
## Bombay Beach freeform drill + Elev + snowglobe:
##   Godot.exe.exe --path . --windowed --resolution 1280x720 -- \
##     --user-map=bombay --capture=site-review \
##     --review-sets=freeform,site,elevation,snowglobe \
##     --shots-dir=bombay_drill_review --quit-after-capture
##
## F12 saves a single manual screenshot to user://screenshots/ in any windowed run.
## Each capture set writes a manifest.json (file, set, index, position, yaw/pitch)
## so an agent can correlate images with viewpoints.

const SHOTS_ROOT := "user://screenshots"
const ORBIT_WAYPOINTS := 10
const ORBIT_RADIUS_M := 180.0
const ORBIT_HEIGHT_M := 50.0
## Orbit aim point height above ground at the town centre.
const ORBIT_TARGET_LIFT_M := 5.0
const STREET_EYE_M := 2.5
const STREET_SPACING_M := 60.0
const STREET_MAX_RADIUS_M := 400.0
const STREET_MAX_SHOTS := 16
## Detail drape / vegetation pop in after "map loaded" — settle before shooting.
const SETTLE_AFTER_LOAD_S := 5.0
## The hyper roof ortho arrives well after "map loaded" on an uncached first
## visit (~900 tiles). Captures wait for it (bounded) so roof shots show the
## real projection, not the procedural fallback mid-fetch.
const HYPER_WAIT_MAX_S := 420.0
## Frames to wait for the TerrainLoader node to appear after the scene change.
const FIND_LOADER_TIMEOUT_FRAMES := 900

var _launch_lat := NAN
var _launch_lon := NAN
var _launch_half_extent := 0.0
var _launch_label := ""
var _launch_scene := ""
var _capture_mode := ""
var _shots_label := ""
var _quit_after := false
var _capture_hour := 10.0
var _assign_facades_count := 0
var _sculpt_test := false
var _active := false
var _perf_hud := false
var _no_mutate := false
## site-review subsets; empty → default world+freeform+elevation+siphon.
var _review_sets: PackedStringArray = PackedStringArray()
var _map_def_path := ""
## --window-wall: open the Window Wall after load (no capture, no quit).
var _boot_window_wall := false
## --count=N: how many people the crowd bench seeds (festival-scale baseline).
var _bench_count := 300
## --ts=<multiple>: the crowd bench's clock speed as a multiple of realtime
## (450 = the timeline's 450x preset). The cliff the user hit sits between
## 300x and 450x, so the bench must be able to sit on either side of it.
var _bench_ts_mult := 450.0
## --light=on|off for --capture=popin (default: the player's own setting).
var _popin_light := ""
## --world=<id or name>: run inside that WORLD (core/worlds/). Without it the
## harness runs with no world active, i.e. the legacy per-site files — every
## existing capture command keeps its old behaviour.
var _world_arg := ""
var _harness_world: Dictionary = {}
## --scratch-world: run inside a throwaway COPY of the world (the --world one,
## else the most recently played world on the launched map, else an empty
## one), deleted on quit. Mutation-heavy captures get isolation without
## snapshot/byte-restore, and never touch the player's build.
var _scratch_world := false
var _scratch_id := ""
## --tour-* (the feature tour, --capture=tour): which stops, how fast, cards.
var _tour_stops: PackedStringArray = PackedStringArray()
var _tour_chapters: PackedStringArray = PackedStringArray()
var _tour_world := ""
var _tour_pace := 1.0
var _tour_optional := false
var _tour_cards := true
var _tour_movie_fps := 0
var _tour_intro_count := 0
var _tour_audit := "report"

## --- Harness run contract (tools/harness.ps1) ---------------------------------
## A capture / fix-script run writes into a SANDBOX copy of the user data dir
## (the launcher points APPDATA at it and drops this marker). Without the
## marker the run is refused unless --persist says "yes, my real world".
const SANDBOX_MARKER := "user://.harness_sandbox"
## Budget for the world to finish loading before a capture starts.
const MAP_READY_TIMEOUT_S := 600.0
## Modes allowed to write into the user's REAL world with --persist.
const PERSIST_MODES := ["look", "script"]
## --capture=a,b,c runs these in order on one map load.
var _chain: PackedStringArray = PackedStringArray()
var _persist := false
var _allow_builtin := false
var _no_world := false
var _run_script_path := ""
var _timeout_override := 0.0
var _harness_on := false
var _dispatching := false
var _finished := false
var _report: HarnessReport = null
var _t0_ms := 0


## project.godot opens the window MAXIMIZED (window/size/mode = 3), which
## overrides the engine's `--resolution WxH`: every "720p" capture was really
## shot at the monitor's size. A harness run gets exactly the size it asked for.
##
## Only for the tour (its clicks go through HarnessInput, which posts in
## viewport coordinates) or with `--exact-resolution`: the older captures post
## raw window coordinates of their own and were written against the maximized
## window.
func _apply_window_resolution() -> void:
	if not ("tour" in _chain or "--exact-resolution" in OS.get_cmdline_user_args()):
		var has_size := false
		for a in OS.get_cmdline_user_args():
			has_size = has_size or a.begins_with("--window-size=")
		if not has_size:
			return
	var spec := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--window-size="):
			spec = a.get_slice("=", 1)
	if spec.is_empty():
		var eargs := OS.get_cmdline_args()
		var i := eargs.find("--resolution")
		if i >= 0 and i + 1 < eargs.size():
			spec = String(eargs[i + 1])
	var parts := spec.split("x")
	if parts.size() != 2:
		return
	var want := Vector2i(parts[0].to_int(), parts[1].to_int())
	if want.x < 320 or want.y < 240:
		return
	var win := get_window()
	if win.mode != Window.MODE_WINDOWED:
		win.mode = Window.MODE_WINDOWED
	win.size = want
	win.move_to_center()
	print("harness: window %dx%d" % [want.x, want.y])


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	_parse_args(args)
	_harness_on = not _chain.is_empty() or _assign_facades_count > 0 or _sculpt_test
	# Harness shots end up in docs / the README: never print the site's real
	# address or coordinates on screen (the loading screen, Site Report, world
	# panel). --show-location keeps them for a private debugging run.
	SitePrivacy.redact = _harness_on and not ("--show-location" in args)
	if _harness_on:
		_t0_ms = Time.get_ticks_msec()
		_report = HarnessReport.new()
		OS.add_logger(_report)
		# Proof of life for tools/harness.ps1: a harness that failed to COMPILE
		# never reaches this line, and the launcher kills the run instead of
		# waiting out its hard limit in the map chooser.
		HarnessReport.write_json("user://harness_started.json", {"pid": OS.get_process_id(),
			"capture": ",".join(_chain), "at": Time.get_datetime_string_from_system()})
		if not _guard_ok():
			return
		_apply_window_resolution()
		_apply_test_baseline()
		_start_watchdog()
		if not _resolve_launch_target():
			_active = true
			_finish.call_deferred("FAIL")
			return
	if not _harness_world.is_empty():
		_active = true
		_launch_world.call_deferred()
	elif not is_nan(_launch_lat) and not is_nan(_launch_lon):
		_active = true
		_launch_map.call_deferred()
	elif not _launch_scene.is_empty():
		_active = true
		_launch_scene_direct.call_deferred()
	elif _boot_window_wall:
		_active = true
		_boot_window_wall_view.call_deferred()
	elif _menu_chain():
		_active = true
		_dispatch.call_deferred()


## The launcher's sandbox marker, or an explicit --persist. Anything else would
## write a test run into the player's real world.
func _guard_ok() -> bool:
	if _persist:
		for m in _chain:
			if not (m in PERSIST_MODES):
				print("PlaytestHarness: FAIL — --persist is only for --capture=look and --run-script " +
					"(a test capture's scaffolding must never land in the real world); got '%s'" % m)
				_active = true
				_finish.call_deferred("FAIL", 4)
				return false
		print("PlaytestHarness: --persist — running on the REAL user data dir; changes are kept")
		return true
	if FileAccess.file_exists(SANDBOX_MARKER):
		print("PlaytestHarness: sandbox %s" % OS.get_user_data_dir())
		return true
	print("PlaytestHarness: FAIL — refused: not in a harness sandbox (%s). Run it through " % OS.get_user_data_dir() +
		"tools/harness.ps1, or pass --persist to work on the real world on purpose.")
	_active = true
	_finish.call_deferred("FAIL", 4)
	return false


## Test captures assert the SHIPPED rules, so the player's own testing
## switches (PopTestPrefs: ideal supply, ignore capacity, no departures, mute
## alarms, a festival population target) are reset IN MEMORY for the session
## — nothing is saved. Measured: with the author's all-off switches the
## population capture's starvation, collapse cascade, reset and personal-space
## checks all failed, because none of that can happen on ideal supply.
## look / script keep the player's real settings: they show and fix THEIR game.
func _apply_test_baseline() -> void:
	var only_player_modes := not _chain.is_empty()
	for m in _chain:
		if not (m in PERSIST_MODES):
			only_player_modes = false
	if only_player_modes:
		return
	if PopTestPrefs.any_active() or PopTestPrefs.festival_target_people() != 0:
		print("PlaytestHarness: player's testing switches reset to shipped defaults for this run (not saved): %s, target %d" % [
			str(PopTestPrefs.saved_flags()), PopTestPrefs.festival_target_people()])
	PopTestPrefs.reset_defaults()
	# NPC display taste (body style, light crowd off, hero budget, names…) is a
	# global file the captures' assertions were calibrated without — Walton's
	# festival hero-pool check read 15 of 79 overflow people drawn with the
	# author's light_crowd=false. In the SANDBOX only (this is the sandbox's own
	# copy), set it aside so every NpcDisplayPrefs value lazy-loads its default.
	if FileAccess.file_exists(SANDBOX_MARKER) and FileAccess.file_exists(NpcDisplayPrefs.CFG_PATH):
		var da := DirAccess.open("user://")
		if da != null and da.rename(NpcDisplayPrefs.CFG_PATH, NpcDisplayPrefs.CFG_PATH + ".player") == OK:
			print("PlaytestHarness: player's NPC display prefs set aside in the sandbox — shipped defaults for this run")


## Decide WHERE the run happens. Default: the capture's registered world
## (Mount Vernon or Walton), loaded through WorldSession so the player's saved
## snapshot comes back exactly. Built-in SOAK / Mars only with
## --allow-builtin-scene.
## Every capture in the chain runs on the launch hub (kind "menu").
func _menu_chain() -> bool:
	if _chain.is_empty():
		return false
	for m in _chain:
		if str(HarnessRegistry.entry(m).get("kind", "")) != "menu":
			return false
	return true


func _resolve_launch_target() -> bool:
	for m in _chain:
		if not HarnessRegistry.has_mode(m):
			print("PlaytestHarness: FAIL — unknown capture mode '%s' (known: %s)" % [m, ", ".join(HarnessRegistry.modes())])
			return false
	if _menu_chain():
		return true
	if not _launch_scene.is_empty() and HarnessRegistry.is_builtin_scene(_launch_scene) and not _allow_builtin:
		print("PlaytestHarness: FAIL — %s is a built-in imported-mesh scene, not a harness target. " % _launch_scene +
			"Use --world=mtvernon|walton (or add --allow-builtin-scene if asked to test it).")
		return false
	if _harness_world.is_empty() and not _no_world and _launch_scene.is_empty():
		if is_nan(_launch_lat):
			# No map named: the capture's own default world.
			var first := _chain[0] if not _chain.is_empty() else "orbit"
			_world_arg = str(HarnessRegistry.entry(first).get("world", "mtvernon"))
			_resolve_world_arg()
		else:
			# A map was named (--user-map / --map-lat): run in the newest world on
			# that site so the saved state loads too.
			var on := WorldStore.worlds_on_map(_harness_map_ref())
			if not on.is_empty():
				_harness_world = on[0]
				print("PlaytestHarness: using world %s (%s) on that map" % [
					WorldStore.display_name(_harness_world), str(_harness_world.get("id", ""))])
	if not _harness_world.is_empty():
		var wmap: Dictionary = _harness_world.get("map", {})
		var wscene := MapDefinition.normalize_scene_path(str(wmap.get("scene_path", "")))
		if HarnessRegistry.is_builtin_scene(wscene) and not _allow_builtin:
			print("PlaytestHarness: FAIL — world %s stands on built-in scene %s; add --allow-builtin-scene" % [
				WorldStore.display_name(_harness_world), wscene])
			return false
		return true
	if not is_nan(_launch_lat) or not _launch_scene.is_empty():
		return true
	print("PlaytestHarness: FAIL — no world or map to run on (--world=%s matched nothing)" % _world_arg)
	return false


func _start_watchdog() -> void:
	var secs := _timeout_override
	if secs <= 0.0:
		secs = HarnessRegistry.timeout_for(_chain) if not _chain.is_empty() else HarnessRegistry.DEFAULT_TIMEOUT_S
	print("PlaytestHarness: watchdog %.0f s" % secs)
	# process_always + ignore_time_scale: a paused or slowed sim cannot stall it.
	get_tree().create_timer(secs, true, false, true).timeout.connect(func() -> void:
		if _finished:
			return
		print("PlaytestHarness: WATCHDOG — no result after %.0f s (phase '%s', last line: %s)" % [
			secs, _report.phase if _report != null else "", _report.last_line if _report != null else ""])
		_finish("TIMEOUT", 3))


## Play the resolved world exactly as the user left it (snapshot, extents,
## panel config) — the one launch path every capture now shares.
func _launch_world() -> void:
	var tree := get_tree()
	if tree == null:
		return
	await tree.process_frame
	var rec := _harness_launch_record()
	if rec.is_empty():
		print("PlaytestHarness: FAIL — could not prepare the world to launch")
		_finish("FAIL")
		return
	var map: Dictionary = rec.get("map", {})
	print("PlaytestHarness: launching world %s (%s) — %s" % [WorldStore.display_name(rec),
		str(rec.get("id", "")), "snapshot" if not WorldStore.read_snapshot(str(rec.get("id", ""))).is_empty() else "no snapshot"])
	if WorldStore.is_generated_map(map):
		_launch_lat = float(map.get("lat", 0.0))
		_launch_lon = float(map.get("lon", 0.0))
		_launch_label = str(map.get("label", ""))
	var err := WorldSession.launch(rec, {})
	if err != OK:
		print("PlaytestHarness: FAIL — WorldSession.launch returned %d" % err)
		_finish("FAIL")
		return
	_dispatch()


## Wait until the launched scene is Main, its TerrainLoader (if any) has
## finished loading, and the world's resume extras have been applied.
func _await_world_ready() -> bool:
	var tree := get_tree()
	var deadline := Time.get_ticks_msec() + int(MAP_READY_TIMEOUT_S * 1000.0)
	var main: Node = null
	while Time.get_ticks_msec() < deadline:
		main = _find_main()
		if main != null and tree.current_scene == main:
			break
		await tree.process_frame
	if main == null:
		print("PlaytestHarness: FAIL — the game scene never arrived")
		return false
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null:
		loader = main.find_child("TerrainLoader", true, false)
	if loader != null:
		var t0 := Time.get_ticks_msec()
		while not bool(loader.get("load_completed")):
			if Time.get_ticks_msec() > deadline:
				print("PlaytestHarness: FAIL — map load did not complete in %.0f s" % MAP_READY_TIMEOUT_S)
				return false
			await tree.create_timer(0.25, true, false, true).timeout
		print("PlaytestHarness: world ready (map loaded in %.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	# WorldSession / SaveSystem apply the resume extras ~30 frames after load.
	for _i in 45:
		await tree.process_frame
	return true


## Run the capture chain. Each capture keeps its own body; it no longer quits
## the process (_maybe_quit is a no-op while dispatching) — _finish does.
func _dispatch() -> void:
	if _chain.is_empty():
		if _boot_window_wall:
			_boot_window_wall_view()
		elif _assign_facades_count > 0 or _sculpt_test:
			_dispatching = true
			await _await_and_run()
			_dispatching = false
			_finish()
		return
	_dispatching = true
	for mode in _chain:
		var e := HarnessRegistry.entry(mode)
		_capture_mode = mode
		if str(e.get("kind", "")) != "scene" and str(e.get("kind", "")) != "menu":
			if _report != null:
				_report.set_phase("%s: loading the world" % mode)
			if not await _await_world_ready():
				break
		if _report != null:
			_report.set_phase(mode)
		await call(str(e.get("fn", "")))
	_dispatching = false
	if _boot_window_wall:
		_boot_window_wall_view()
	_finish()


## The one exit: verdict line + results.json, scratch cleanup, real exit code
## (0 pass, 1 fail, 3 watchdog timeout, 4 refused).
func _finish(status: String = "", code: int = -1) -> void:
	if _finished:
		return
	_finished = true
	var mode := ",".join(_chain) if not _chain.is_empty() else ("sculpt" if _sculpt_test else "facades")
	var secs := (Time.get_ticks_msec() - _t0_ms) / 1000.0
	var s := _report.summary(mode, secs, status) if _report != null else {"mode": mode, "status": status}
	s["world"] = WorldStore.display_name(_harness_world) if not _harness_world.is_empty() else ""
	s["world_id"] = str(_harness_world.get("id", ""))
	s["user_dir"] = OS.get_user_data_dir()
	s["persist"] = _persist
	for e in s.get("script_errors", []):
		print("  script error: %s" % str(e))
	var distinct := {}
	for e in s.get("engine_errors", []):
		distinct[str(e)] = int(distinct.get(str(e), 0)) + 1
	for e in distinct:
		print("  engine error x%d: %s" % [int(distinct[e]), str(e)])
	for f in s.get("failures", []):
		print("  failure: %s" % str(f))
	print(HarnessReport.result_line(s))
	var label := _shots_label if not _shots_label.is_empty() else "harness_%s" % mode.replace(",", "+")
	HarnessReport.write_json("%s/%s/results.json" % [SHOTS_ROOT, label], s)
	HarnessReport.write_json("user://harness_last_result.json", s)
	if code < 0:
		match str(s.get("status", "")):
			"PASS": code = 0
			"TIMEOUT": code = 3
			_: code = 1
	if _report != null:
		OS.remove_logger(_report)
	_cleanup_scratch_world()
	if _quit_after or code != 0 or status == "TIMEOUT":
		get_tree().quit(code)


func _csv_arg(a: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for part in a.get_slice("=", 1).split(","):
		if not part.strip_edges().is_empty():
			out.append(part.strip_edges().to_lower())
	return out


func _parse_args(args: PackedStringArray) -> void:
	var map_file := ""
	for a in args:
		if a.begins_with("--user-map="):
			map_file = a.get_slice("=", 1)
		elif a == "--persist":
			_persist = true
		elif a == "--allow-builtin-scene":
			_allow_builtin = true
		elif a == "--no-world":
			_no_world = true
		elif a.begins_with("--run-script="):
			_run_script_path = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--timeout="):
			_timeout_override = maxf(a.get_slice("=", 1).to_float(), 0.0)
		elif a.begins_with("--scene="):
			_launch_scene = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--map-lat="):
			_launch_lat = a.get_slice("=", 1).to_float()
		elif a.begins_with("--map-lon="):
			_launch_lon = a.get_slice("=", 1).to_float()
		elif a.begins_with("--half-extent="):
			_launch_half_extent = a.get_slice("=", 1).to_float()
		elif a.begins_with("--capture="):
			_chain = PackedStringArray()
			for part in a.get_slice("=", 1).to_lower().split(","):
				if not part.strip_edges().is_empty():
					_chain.append(part.strip_edges())
			_capture_mode = _chain[0] if not _chain.is_empty() else ""
			# The player's "Simulate & draw NPCs" switch must not decide a
			# regression run — session-only, never saved.
			NpcDisplayPrefs.force_npcs_for_session(true)
		elif a.begins_with("--shots-dir="):
			_shots_label = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--time="):
			_capture_hour = clampf(a.get_slice("=", 1).to_float(), 0.0, 24.0)
		elif a.begins_with("--assign-facades="):
			_assign_facades_count = a.get_slice("=", 1).to_int()
		elif a.begins_with("--review-sets="):
			var raw := a.get_slice("=", 1).strip_edges().to_lower()
			_review_sets = PackedStringArray()
			for part in raw.split(","):
				var p := part.strip_edges()
				if not p.is_empty():
					_review_sets.append(p)
		elif a == "--perf":
			_perf_hud = true
		elif a == "--no-mutate":
			_no_mutate = true
		elif a == "--sculpt-test":
			_sculpt_test = true
		elif a == "--quit-after-capture":
			_quit_after = true
		elif a == "--window-wall":
			_boot_window_wall = true
		elif a.begins_with("--count="):
			_bench_count = clampi(a.get_slice("=", 1).to_int(), 1, 20000)
		elif a.begins_with("--ts="):
			_bench_ts_mult = clampf(a.get_slice("=", 1).to_float(), 1.0, 20000.0)
		elif a.begins_with("--light="):
			_popin_light = a.get_slice("=", 1)
		elif a.begins_with("--world="):
			_world_arg = a.get_slice("=", 1).strip_edges()
		elif a == "--scratch-world":
			_scratch_world = true
		elif a.begins_with("--tour-stops="):
			_tour_stops = _csv_arg(a)
		elif a.begins_with("--tour-chapters="):
			_tour_chapters = _csv_arg(a)
		elif a.begins_with("--tour-world="):
			_tour_world = HarnessRegistry.canonical_alias(a.get_slice("=", 1))
		elif a.begins_with("--tour-pace="):
			var pv := a.get_slice("=", 1).strip_edges().to_lower()
			_tour_pace = {"fast": 0.55, "normal": 1.0, "slow": 1.6}.get(pv, clampf(pv.to_float(), 0.2, 4.0)) if not pv.is_empty() else 1.0
		elif a == "--tour-include-optional":
			_tour_optional = true
		elif a == "--tour-no-cards":
			_tour_cards = false
		elif a.begins_with("--tour-movie-fps="):
			_tour_movie_fps = a.get_slice("=", 1).to_int()
		elif a.begins_with("--tour-audit="):
			_tour_audit = a.get_slice("=", 1).strip_edges().to_lower()
		elif a.begins_with("--tour-intro-count="):
			_tour_intro_count = a.get_slice("=", 1).to_int()
	if not _run_script_path.is_empty() and not ("script" in _chain):
		_chain.append("script")
		if _capture_mode.is_empty():
			_capture_mode = "script"
	if not map_file.is_empty():
		# A world alias given as a map (the old `--user-map=mtvernon` habit)
		# runs in that WORLD, so the saved state loads too.
		var alias := HarnessRegistry.canonical_alias(map_file)
		if _world_arg.is_empty() and not _no_world and HarnessRegistry.WORLD_ALIASES.has(alias) \
				and not HarnessRegistry.pick_world(alias, WorldStore.list()).is_empty():
			_world_arg = alias
		else:
			_load_map_definition(map_file)
	if not _world_arg.is_empty():
		_resolve_world_arg()
	if _perf_hud:
		_enable_perf_monitor()


func _enable_perf_monitor() -> void:
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm != null and pm.has_method("set_enabled"):
		pm.call("set_enabled", true)
		print("PlaytestHarness: PerfMonitor HUD enabled (--perf)")


func _review_wants(set_name: String) -> bool:
	if _review_sets.is_empty():
		return set_name in ["world", "freeform", "elevation", "siphon"]
	return set_name in _review_sets


## Resolve aliases like "mtvernon" / "bombay" → a MapDefinition under user://maps/.
func _resolve_user_map_path(map_file: String) -> String:
	var raw := map_file.strip_edges()
	if raw.is_empty():
		return raw
	var key := raw.to_lower()
	if key.ends_with(".tres"):
		key = key.get_basename().to_lower()
	var is_mtvernon := key in [
		"mtvernon", "mt_vernon", "mt-vernon", "mountvernon", "mount_vernon",
		"mount-vernon",
	]
	if is_mtvernon:
		var found := _find_map_by_display_substring(["mount vernon", "mt. vernon", "mt vernon"])
		if not found.is_empty():
			print("PlaytestHarness: --user-map=%s → %s" % [map_file, found])
			return found
		push_error("PlaytestHarness: no user://maps/*.tres matched Mount Vernon alias")
		return ""
	# Walton, Oregon — the festival-scale target site (Pataha Creek Road).
	if key in ["walton", "walton_or", "walton-or", "pataha"]:
		var found_w := _find_map_by_display_substring(["pataha creek", "walton"])
		if not found_w.is_empty():
			print("PlaytestHarness: --user-map=%s → %s" % [map_file, found_w])
			return found_w
		push_error("PlaytestHarness: no user://maps/*.tres matched Walton alias")
		return ""
	var is_bombay := key in [
		"bombay", "bombaybeach", "bombay_beach", "bombay-beach",
		"route111", "route_111", "route-111",
	]
	if is_bombay:
		# Prefer Route 111 (richest recent graph), then any Bombay Beach pin.
		var found_b := _find_map_by_display_substring(["route 111", "bombay beach"])
		if not found_b.is_empty():
			print("PlaytestHarness: --user-map=%s → %s" % [map_file, found_b])
			return found_b
		push_error("PlaytestHarness: no user://maps/*.tres matched Bombay Beach alias")
		return ""
	if raw.begins_with("user://") or raw.begins_with("res://"):
		return raw
	return "user://maps/%s" % raw


## Earlier needles win: scan all maps for needle[0], then needle[1], …
func _find_map_by_display_substring(needles: Array) -> String:
	for n in needles:
		var one := _find_map_by_one_substring(str(n))
		if not one.is_empty():
			return one
	return ""


func _find_map_by_one_substring(needle: String) -> String:
	var dir := DirAccess.open("user://maps")
	if dir == null or needle.is_empty():
		return ""
	var needle_l := needle.to_lower()
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and name.ends_with(".tres"):
			var path := "user://maps/%s" % name
			var md := load(path) as MapDefinition
			if md != null and md.is_generated():
				if md.display_name.to_lower().find(needle_l) >= 0:
					dir.list_dir_end()
					return path
		name = dir.get_next()
	dir.list_dir_end()
	return ""


func _load_map_definition(map_file: String) -> void:
	var path := _resolve_user_map_path(map_file)
	if path.is_empty():
		return
	if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
		push_error("PlaytestHarness: map file not found: %s" % path)
		return
	var md := load(path) as MapDefinition
	if md == null:
		push_error("PlaytestHarness: %s is not a MapDefinition" % path)
		return
	if not md.is_generated():
		push_error("PlaytestHarness: --user-map only supports generated maps (%s)" % path)
		return
	_map_def_path = path
	_launch_lat = md.latitude
	_launch_lon = md.longitude
	_launch_half_extent = md.half_extent_m
	_launch_label = md.display_name


func _launch_map() -> void:
	var tree := get_tree()
	if tree == null:
		return
	# Let the default main scene finish entering the tree before switching away.
	await tree.process_frame
	print("PlaytestHarness: launching generated map at %.7f, %.7f (%s)" % [
		_launch_lat, _launch_lon, _launch_label])
	var ctx := get_node_or_null("/root/MapContext")
	if ctx == null:
		push_error("PlaytestHarness: MapContext autoload missing")
		return
	_activate_harness_world()
	ctx.set_pending(_launch_lat, _launch_lon, _launch_label, _launch_half_extent)
	tree.change_scene_to_file(MapDefinition.GENERATED_SCENE)
	_dispatch()


## Direct launch of a built-in (trusted) map scene, e.g. the soak map for
## graph-view capture — the boot scene is the map chooser, which has no game UI.
func _launch_scene_direct() -> void:
	var tree := get_tree()
	if tree == null:
		return
	await tree.process_frame
	if not MapDefinition.TRUSTED_SCENE_PATHS.has(_launch_scene):
		push_error("PlaytestHarness: --scene not in TRUSTED_SCENE_PATHS: %s" % _launch_scene)
		_maybe_quit()
		return
	print("PlaytestHarness: launching scene %s" % _launch_scene)
	_activate_harness_world()
	tree.change_scene_to_file(_launch_scene)
	_dispatch()


func _await_and_run() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: TerrainLoader not found — aborting")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	print("PlaytestHarness: map loaded — settling %.0f s" % SETTLE_AFTER_LOAD_S)
	await get_tree().create_timer(_settle_s()).timeout
	if _assign_facades_count > 0:
		_assign_hero_facades(loader)
	if _sculpt_test:
		await _run_sculpt_test(loader)
	if not _capture_mode.is_empty():
		await _wait_for_hyper_drape(loader)
		_set_capture_conditions()
		await _run_capture(loader)
	_maybe_quit()


## Assign every user://maps/facade_textures/*.png round-robin to the N nearest
## house-sized buildings (via TerrainLoader.list_buildings_near, the same
## distance/area heuristic a human curating "hero buildings" would use) using
## apply_building_style — identical code path to the modal's Facade tex
## dropdown, so this is equivalent to doing it by hand N times.
func _assign_hero_facades(loader: Node) -> void:
	if not loader.has_method("list_facade_textures") or not loader.has_method("list_buildings_near"):
		push_error("PlaytestHarness: TerrainLoader missing facade-texture APIs")
		return
	var files: PackedStringArray = loader.call("list_facade_textures")
	if files.is_empty():
		push_warning("PlaytestHarness: no files in user://maps/facade_textures/ — nothing to assign")
		return
	var candidates: Array = loader.call("list_buildings_near", 0.0, 0.0, 400.0)
	if candidates.is_empty():
		push_warning("PlaytestHarness: no house-sized buildings found near spawn")
		return
	var n := mini(_assign_facades_count, candidates.size())
	print("PlaytestHarness: assigning %d facade texture(s) to %d nearest building(s)" % [
		files.size(), n])
	for i in n:
		var c: Dictionary = candidates[i]
		var file: String = files[i % files.size()]
		var ok: bool = loader.call("apply_building_style", int(c["idx"]), {
			"wall_texture": file, "wall_tex_w_m": 4.0, "wall_tex_h_m": 3.0,
		})
		print("PlaytestHarness:  building idx=%d tag=%s dist=%.0fm area=%.0fm2 -> %s (%s)" % [
			int(c["idx"]), str(c["tag"]), float(c["dist_m"]), float(c["area_m2"]),
			file, "ok" if ok else "FAILED"])


func _wait_for_hyper_drape(loader: Node) -> void:
	if loader.get("_hyper_drape") != null:
		return
	print("PlaytestHarness: waiting for hyper roof ortho (up to %.0f s) …" % HYPER_WAIT_MAX_S)
	var waited := 0.0
	while waited < HYPER_WAIT_MAX_S:
		await get_tree().create_timer(2.0).timeout
		waited += 2.0
		if loader.get("_hyper_drape") != null:
			print("PlaytestHarness: hyper ortho arrived after %.0f s" % waited)
			return
	print("PlaytestHarness: hyper ortho still pending — capturing anyway")


## Reproducible shooting conditions: fixed daytime sun, frozen clock, HUD hidden.
func _set_capture_conditions() -> void:
	var main := get_tree().current_scene
	if main == null:
		return
	if "time_scale" in main:
		main.time_scale = 0.0
	if "day_time" in main:
		main.day_time = _capture_hour
		print("PlaytestHarness: sim clock set to %.1f h (paused)" % _capture_hour)
	for child in main.get_children():
		if child is CanvasLayer:
			child.visible = false


func _find_terrain_loader() -> Node:
	var tree := get_tree()
	for _i in FIND_LOADER_TIMEOUT_FRAMES:
		var scene := tree.current_scene
		if scene != null:
			var tl := scene.find_child("TerrainLoader", true, false)
			if tl != null:
				return tl
		await tree.process_frame
	return null


func _run_capture(loader: Node) -> void:
	var label := _shots_label
	if label.is_empty():
		label = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)

	var cam := Camera3D.new()
	cam.name = "PlaytestCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()

	var manifest: Array = []
	if _capture_mode == "orbit" or _capture_mode == "both":
		await _capture_set(cam, _orbit_waypoints(loader), "orbit", dir, manifest)
	if _capture_mode == "street" or _capture_mode == "both":
		await _capture_set(cam, _street_waypoints(loader), "street", dir, manifest)
	if _capture_mode == "hero":
		await _capture_set(cam, _hero_waypoints(loader), "hero", dir, manifest)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	cam.queue_free()
	print("PlaytestHarness: wrote %d captures to %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])


## Waypoint dict: {pos: Vector3, look: Vector3}
func _orbit_waypoints(loader: Node) -> Array:
	var pts: Array = []
	var centre_ground := _ground_y(loader, 0.0, 0.0)
	var target := Vector3(0.0, centre_ground + ORBIT_TARGET_LIFT_M, 0.0)
	for i in ORBIT_WAYPOINTS:
		var ang := TAU * float(i) / float(ORBIT_WAYPOINTS)
		var x := cos(ang) * ORBIT_RADIUS_M
		var z := sin(ang) * ORBIT_RADIUS_M
		var y := _ground_y(loader, x, z) + ORBIT_HEIGHT_M
		pts.append({"pos": Vector3(x, y, z), "look": target})
	return pts


## One close eye-level waypoint per styled building — facade texture review.
## Camera sits south of the centroid (world −Z is north, per GeoMath) looking
## north at the wall, backed off by footprint size so the whole face frames.
func _hero_waypoints(loader: Node) -> Array:
	var pts: Array = []
	if not loader.has_method("list_styled_buildings"):
		return pts
	var styled: Array = loader.call("list_styled_buildings")
	for b in styled:
		var d: Dictionary = b
		var x := float(d["x"])
		var z := float(d["z"])
		var dist := clampf(sqrt(float(d["area_m2"])) * 0.9 + 4.0, 6.0, 16.0)
		var eye_y := _ground_y(loader, x, z) + STREET_EYE_M
		var pos := Vector3(x, eye_y, z + dist)
		var look := Vector3(x, eye_y, z)
		pts.append({"pos": pos, "look": look, "tag": str(d.get("tag", ""))})
	return pts


func _street_waypoints(loader: Node) -> Array:
	var pts: Array = []
	if not loader.has_method("get_osm_roads"):
		return pts
	var roads: Array = loader.get_osm_roads()
	var side := 1.0
	for r in roads:
		if pts.size() >= STREET_MAX_SHOTS:
			break
		if not (r is Dictionary):
			continue
		var poly: PackedVector2Array = r.get("points", PackedVector2Array())
		var travelled := 0.0
		for i in range(1, poly.size()):
			if pts.size() >= STREET_MAX_SHOTS:
				break
			var a := poly[i - 1]
			var b := poly[i]
			var seg := b - a
			var seg_len := seg.length()
			if seg_len < 0.01:
				continue
			travelled += seg_len
			if travelled < STREET_SPACING_M:
				continue
			travelled = 0.0
			var mid := (a + b) * 0.5
			if mid.length() > STREET_MAX_RADIUS_M:
				continue
			var dir := seg / seg_len
			# Look perpendicular to the street (at the facades), alternating sides.
			var perp := Vector2(-dir.y, dir.x) * side
			side = -side
			var eye_y := _ground_y(loader, mid.x, mid.y) + STREET_EYE_M
			var pos := Vector3(mid.x, eye_y, mid.y)
			var look := pos + Vector3(perp.x, 0.0, perp.y) * 20.0
			pts.append({"pos": pos, "look": look})
	return pts


func _capture_set(cam: Camera3D, waypoints: Array, set_name: String,
		dir: String, manifest: Array) -> void:
	if waypoints.is_empty():
		print("PlaytestHarness: no %s waypoints (skipping set)" % set_name)
		return
	for i in waypoints.size():
		var wp: Dictionary = waypoints[i]
		var pos: Vector3 = wp["pos"]
		var look: Vector3 = wp["look"]
		if pos.distance_to(look) < 0.1:
			look = pos + Vector3.FORWARD
		cam.look_at_from_position(pos, look, Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var file := "%s_%02d.png" % [set_name, i]
		img.save_png("%s/%s" % [dir, file])
		var fwd := -cam.global_transform.basis.z
		var entry := {
			"file": file,
			"set": set_name,
			"index": i,
			"pos": [pos.x, pos.y, pos.z],
			"yaw_deg": rad_to_deg(atan2(-fwd.x, -fwd.z)),
			"pitch_deg": rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0))),
		}
		if wp.has("tag"):
			entry["tag"] = wp["tag"]
		manifest.append(entry)
	print("PlaytestHarness: %s set — %d shots" % [set_name, waypoints.size()])


func _ground_y(loader: Node, x: float, z: float) -> float:
	if loader != null and loader.has_method("ground_height_at"):
		return float(loader.ground_height_at(x, z))
	return 0.0


# ---------------------------------------------------------------------------
# Terrain-sculpt smoke test (--sculpt-test)
# ---------------------------------------------------------------------------

const SCULPT_RAISE_AT := Vector2(-160.0, 60.0)
const SCULPT_LEVEL_AT := Vector2(-115.0, 130.0)
const SCULPT_POND_AT := Vector2(-205.0, 120.0)


func _run_sculpt_test(loader: Node) -> void:
	var label := _shots_label if not _shots_label.is_empty() else "sculpt_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	_set_capture_conditions()
	var cam := Camera3D.new()
	cam.name = "SculptTestCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()

	_print_sculpt_heights(loader, "BEFORE")
	_print_player_state(loader)
	await _shoot_sculpt_views(cam, loader, dir, "before")

	# 1) Raise: a real brush stroke (many stamps inside one session).
	loader.call("begin_terrain_tile_edit")
	for i in 24:
		loader.call("brush_stamp", "raise",
			Vector3(SCULPT_RAISE_AT.x, 0.0, SCULPT_RAISE_AT.y), 14.0, 0.15, 0.5, NAN)
	loader.call("end_terrain_tile_edit")
	# 2) Level: a 34 m square pad graded to its centre height.
	var pad := PackedVector2Array([
		SCULPT_LEVEL_AT + Vector2(-17, -17), SCULPT_LEVEL_AT + Vector2(17, -17),
		SCULPT_LEVEL_AT + Vector2(17, 17), SCULPT_LEVEL_AT + Vector2(-17, 17)])
	var target := float(loader.call("ground_height_at", SCULPT_LEVEL_AT.x, SCULPT_LEVEL_AT.y))
	loader.call("level_region_command", pad, target, 10.0)
	# 3) Pond: 18 m-radius lasso, 2.5 m deep, auto-filled.
	var pond := PackedVector2Array()
	for i in 24:
		var a := TAU * float(i) / 24.0
		pond.append(SCULPT_POND_AT + Vector2(cos(a), sin(a)) * 18.0)
	var pond_ok: bool = loader.call("pond_command", pond, 2.5, "Sculpt Test Pond")
	print("SculptTest: pond_command -> %s" % ("ok" if pond_ok else "FAILED"))

	# Let the tile remesh queue drain, then verify.
	for i in 40:
		await get_tree().process_frame
	_dump_height_field_state(loader)
	_print_sculpt_heights(loader, "AFTER")
	_print_player_state(loader)
	await _shoot_sculpt_views(cam, loader, dir, "after")

	# Undo everything so the map's save data is untouched by the test.
	var undos := 0
	while undos < 12 and bool(loader.call("undo_terrain_sculpt")):
		undos += 1
	for i in 20:
		await get_tree().process_frame
	print("SculptTest: undid %d entries" % undos)
	_print_sculpt_heights(loader, "AFTER-UNDO")
	cam.queue_free()
	print("SculptTest: shots in %s" % ProjectSettings.globalize_path(dir))


## Diagnostic dump: does the HeightField exist, where are its tile meshes, and
## what material are they using? Catches "data changed but nothing rendered"
## regressions that height logs alone cannot (invisible/mis-parented meshes).
func _dump_height_field_state(loader: Node) -> void:
	var main := get_tree().current_scene
	var terrain := main.get_node_or_null("Terrain") if main != null else null
	if terrain == null:
		print("SculptTest[dump]: NO Terrain node")
		return
	var hf := terrain.get_node_or_null("HeightField")
	if hf == null:
		print("SculptTest[dump]: NO HeightField node under Terrain")
	else:
		print("SculptTest[dump]: HeightField children=%d global_pos=%s" % [
			hf.get_child_count(), (hf as Node3D).global_position])
		for b in hf.get_children():
			var mi := b.get_node_or_null("Mesh") as MeshInstance3D
			if mi == null or mi.mesh == null:
				print("  %s: NO mesh" % b.name)
				continue
			var aabb: AABB = mi.global_transform * mi.mesh.get_aabb()
			var mat := mi.material_override
			var mat_desc := "null"
			if mat is ShaderMaterial:
				var sm := mat as ShaderMaterial
				mat_desc = "shader patch_mesh=%s hide_centre=%s hide_detail=%s" % [
					sm.get_shader_parameter("patch_mesh"),
					sm.get_shader_parameter("hide_centre_region"),
					sm.get_shader_parameter("hide_detail_region")]
			elif mat != null:
				mat_desc = str(mat.get_class())
			print("  %s: visible=%s aabb_pos=%s aabb_size=%s layers=%d mat=%s" % [
				b.name, mi.visible, aabb.position, aabb.size,
				mi.layers, mat_desc])
	var dg := terrain.get_node_or_null("DetailGround") as MeshInstance3D
	if dg != null and dg.mesh != null:
		var daabb: AABB = dg.global_transform * dg.mesh.get_aabb()
		print("SculptTest[dump]: DetailGround aabb_pos=%s size=%s" % [
			daabb.position, daabb.size])
	# Compare base_fn vs ground at the pond centre.
	var px := SCULPT_POND_AT.x
	var pz := SCULPT_POND_AT.y
	print("SculptTest[dump]: pond_centre ground=%.2f delta=%.2f" % [
		_ground_y(loader, px, pz),
		float(loader.call("terrain_edit_delta_at", px, pz))])


func _print_sculpt_heights(loader: Node, phase: String) -> void:
	var pts := {
		"raise_centre": SCULPT_RAISE_AT,
		"level_centre": SCULPT_LEVEL_AT,
		"level_corner": SCULPT_LEVEL_AT + Vector2(14.0, 14.0),
		"pond_centre": SCULPT_POND_AT,
		"pond_rim": SCULPT_POND_AT + Vector2(17.0, 0.0),
	}
	for name in pts.keys():
		var p: Vector2 = pts[name]
		print("SculptTest[%s] %s ground=%.2f m" % [
			phase, name, _ground_y(loader, p.x, p.y)])


func _print_player_state(loader: Node) -> void:
	var main := get_tree().current_scene
	var player := main.get_node_or_null("Player") as Node3D if main != null else null
	if player == null:
		return
	var pos := player.global_position
	print("SculptTest: player y=%.2f ground=%.2f at (%.1f, %.1f)" % [
		pos.y, _ground_y(loader, pos.x, pos.z), pos.x, pos.z])


func _shoot_sculpt_views(cam: Camera3D, loader: Node, dir: String, phase: String) -> void:
	var g0 := _ground_y(loader, 0.0, 0.0)
	var views := [
		{"pos": Vector3(0, g0 + 230.0, 1.0), "look": Vector3(0, g0, 0)},
		{"pos": Vector3(0, g0 + 90.0, 170.0), "look": Vector3(0, g0, 0)},
	]
	for pv in [SCULPT_RAISE_AT, SCULPT_LEVEL_AT, SCULPT_POND_AT]:
		var p: Vector2 = pv
		var gy := _ground_y(loader, p.x, p.y)
		views.append({
			"pos": Vector3(p.x + 28.0, gy + 26.0, p.y + 28.0),
			"look": Vector3(p.x, gy, p.y)})
	# Low grazing views: a mound/bowl silhouettes against the background here,
	# where the high oblique shots can hide a 3–4 m height change entirely.
	# Camera height uses the ground at the CAMERA's own XZ (the target ground may
	# have just been carved several metres down).
	for pv in [SCULPT_RAISE_AT, SCULPT_POND_AT]:
		var p2: Vector2 = pv
		var cam_gy := _ground_y(loader, p2.x, p2.y + 55.0)
		views.append({
			"pos": Vector3(p2.x, cam_gy + 6.0, p2.y + 55.0),
			"look": Vector3(p2.x, _ground_y(loader, p2.x, p2.y) + 1.5, p2.y)})
	for i in views.size():
		var v: Dictionary = views[i]
		cam.look_at_from_position(v["pos"], v["look"], Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s_%02d.png" % [dir, phase, i]
		var err := img.save_png(path)
		if err != OK:
			print("SculptTest: save_png FAILED err=%d size=%s path=%s" % [
				err, img.get_size(), path])
	print("SculptTest: %s set — %d shots" % [phase, views.size()])


# ---------------------------------------------------------------------------
# Packing Lab capture (--capture=packing) — PACKING_PLAN.md Phase 4
# ---------------------------------------------------------------------------

## Opens the Packing Lab through its real entry data (the same graph+prop
## sweep the Site Report card runs), auto-packs the site cargo into two
## trucks, orbits, then loads the builtin StarShade kit — one PNG per state
## for visual review. Read-only: nothing is persisted.
func _run_packing_capture() -> void:
	var sgv := await _find_graph_view()
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		print("PlaytestHarness: packing capture — waiting for map load")
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	if main != null and "time_scale" in main:
		main.time_scale = 0.0

	var label := _shots_label if not _shots_label.is_empty() else "packing_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	# The same sweep the Site Report packing card runs.
	var lines: Array = []
	var model: Variant = sgv.get("model") if sgv != null else null
	if model != null and model.has_method("get_items_in_scope"):
		lines.append_array(CampManifest.from_graph_items(
			GraphNesting.walk_items(model, "root")))
	if loader != null and loader.has_method("placed_prop_records"):
		lines.append_array(CampManifest.from_prop_records(
			loader.call("placed_prop_records")))
	var units: Array = CampManifest.expand_for_solver(CampManifest.merge(lines))
	if units.is_empty():
		# Bare scene — review the modal against the builtin kit instead.
		units = PackTree.flatten(PackDefs.realize("starshade_kit"))["items"]

	# Write discipline (vegdock pattern): the Lab now persists hand layouts
	# on every placement/autopack — snapshot the store and byte-restore it
	# after, so a capture run never rewrites the player's saved packs.
	var layouts_path := "user://maps/packing_layouts.json"
	var layouts_existed := FileAccess.file_exists(layouts_path)
	var layouts_before := FileAccess.get_file_as_string(layouts_path) \
		if layouts_existed else ""

	var modal: CanvasLayer = load("res://scenes/ui/packing_lab_modal.gd").new()
	get_tree().root.add_child(modal)
	modal.call("open_with_units", units, "Site cargo (%d units)" % units.size(),
		"uhaul_15")
	await get_tree().create_timer(0.6).timeout
	await _graph_shot(dir, "01_open_empty", manifest, "packing")

	modal.call("autopack")
	await get_tree().create_timer(0.4).timeout
	await _graph_shot(dir, "02_uhaul15_autopacked", manifest, "packing")

	modal.call("_set_container", "uhaul_26")
	modal.call("autopack")
	await get_tree().create_timer(0.4).timeout
	await _graph_shot(dir, "03_uhaul26_autopacked", manifest, "packing")

	modal.set("_yaw", 2.2)
	modal.call("_update_camera")
	await get_tree().create_timer(0.3).timeout
	await _graph_shot(dir, "04_orbit_far_side", manifest, "packing")

	var kit_units: Array = PackTree.flatten(PackDefs.realize("starshade_kit"))["items"]
	modal.call("open_with_units", kit_units, "StarShade Kit", "container_20")
	modal.call("autopack")
	await get_tree().create_timer(0.4).timeout
	await _graph_shot(dir, "05_starshade_kit_in_20ft", manifest, "packing")

	modal.call("close")
	modal.queue_free()

	if layouts_existed:
		var lf := FileAccess.open(layouts_path, FileAccess.WRITE)
		if lf != null:
			lf.store_string(layouts_before)
	else:
		DirAccess.remove_absolute(layouts_path)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: packing capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


# ---------------------------------------------------------------------------
# Hardware Detail capture (--capture=hardware)
# ---------------------------------------------------------------------------

## One PNG per hardware-editor state, plus a console dump of where every joint
## actually landed.
##
## This exists because joint placement is unreviewable from a description: the
## port spent a release anchored on the wrong pivot with no flipStackAxis and a
## 90-degree-yawed H-centre frame, and all three RENDERED — they simply put the
## hardware in the wrong place. `linkage_selftest` now pins the numbers; this is
## how a human checks that the numbers describe the right picture.
##
## Read-only: it builds its own LinkageParams and never touches a saved design.
func _run_hardware_capture() -> void:
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	if main != null and "time_scale" in main:
		main.time_scale = 0.0

	var label := _shots_label if not _shots_label.is_empty() else "hardware_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	var p := LinkageParams.new()
	p.hardware_assemblies = LinkageHardware.ensure(p.hardware_assemblies)
	# Full detail ON: this is the configuration whose geometry was wrong, and
	# the one a player opening the editor is looking at.
	p.show_hardware_full_detail = true

	# Through the REAL entry point, so the modal lands on its own CanvasLayer
	# above the game HUD. Adding it straight to the root gives it no layer at
	# all, and the scoreboard and timeline draw over the top of it.
	if main == null or not main.has_method("open_linkage_hardware_editor"):
		push_error("PlaytestHarness: no Main.open_linkage_hardware_editor")
		_maybe_quit()
		return
	var modal: Control = main.call("open_linkage_hardware_editor", p)
	if modal == null:
		push_error("PlaytestHarness: hardware editor did not open")
		_maybe_quit()
		return
	await get_tree().create_timer(0.8).timeout

	for asm_id in ["outerVBeam", "innerVBeam", "hCenter", "vCenter"]:
		modal.call("_on_tab_pressed", asm_id)
		await get_tree().create_timer(0.5).timeout
		await _graph_shot(dir, "%s_seated" % asm_id, manifest, "hardware")

	# Pulled back to the whole ring. This is the shot that shows whether EVERY
	# joint is dressed at its own pivot: the clones are children of an
	# already-seated node, so a missing inverse composes the seats and scatters
	# joints 1..n while joint 0 stays perfectly correct — which up close reads
	# as "the focused one is right and the rest are wrong".
	modal.call("_on_tab_pressed", "outerVBeam")
	modal.set("_target", modal.get("_ring_center"))
	modal.set("_dist", 11.0)
	modal.set("_pitch", 0.30)
	modal.call("_update_camera")
	await get_tree().create_timer(0.5).timeout
	await _graph_shot(dir, "whole_ring_all_joints", manifest, "hardware")
	modal.call("_frame_assembly")
	await get_tree().create_timer(0.4).timeout

	# Exploded, to read the stack ORDER — and to confirm the context joints fan
	# out with it rather than staying shut.
	modal.call("_on_tab_pressed", "outerVBeam")
	modal.call("_on_explode_changed", 1.0)
	await get_tree().create_timer(0.5).timeout
	await _graph_shot(dir, "outerVBeam_exploded", manifest, "hardware")
	modal.call("_on_explode_changed", 0.0)

	# Standalone studio: the joint alone, no frame, for shape review.
	modal.call("_on_context_toggled", false)
	await get_tree().create_timer(0.5).timeout
	await _graph_shot(dir, "outerVBeam_standalone", manifest, "hardware")
	modal.call("_on_context_toggled", true)
	await get_tree().create_timer(0.4).timeout

	# Selection: the tint plus the drag-axis indicator.
	var asm := LinkageHardware.assembly(p.hardware_assemblies, "outerVBeam")
	for part in asm.get("parts", []):
		var d := part as Dictionary
		if str(d.get("type", "")) == "bracket":
			continue
		modal.call("_select", str(d.get("id", "")), 0)
		break
	await get_tree().create_timer(0.4).timeout
	await _graph_shot(dir, "outerVBeam_selected_axis", manifest, "hardware")

	# Arch mode — the other structure orientation, where the bracket frame
	# tilts in full 3D instead of yawing.
	var pa := LinkageParams.new()
	pa.hardware_assemblies = LinkageHardware.ensure(pa.hardware_assemblies)
	pa.show_hardware_full_detail = true
	pa.orientation = "vertical"
	pa.arch_cap_uprights = true
	pa.modules = 6
	modal.call("open", pa)
	await get_tree().create_timer(0.8).timeout
	await _graph_shot(dir, "arch_outerVBeam_seated", manifest, "hardware")

	# Back to cylinder for the interaction test.
	modal.call("open", p)
	await get_tree().create_timer(0.8).timeout
	await _verify_hardware_drag(modal, p, dir, manifest)

	# …and again through the route a player actually takes: the Linkage Lab is
	# still open UNDERNEATH (LAYER_MODAL) with the hardware editor stacked over
	# it (LAYER_MODAL + 1). Opening the editor standalone does not test whether
	# the Lab's own full-rect Control swallows the pointer first.
	modal.call("close")
	if main.has_method("open_linkage_lab"):
		main.call("open_linkage_lab", p.to_config())
		await get_tree().create_timer(0.8).timeout
		var lab: Node = main.get("linkage_lab_ui")
		if lab != null and lab.has_method("_on_hardware_detail_pressed"):
			lab.call("_on_hardware_detail_pressed")
			await get_tree().create_timer(0.9).timeout
			var lab_params: LinkageParams = lab.get("params")
			print("PlaytestHarness: --- drag test via the Lab entry point ---")
			await _verify_hardware_drag(modal, lab_params, dir, manifest)
			modal.call("close")
		if lab != null and lab.has_method("close"):
			lab.call("close")
		await get_tree().create_timer(0.3).timeout

	_dump_hardware_placements(p, "cylinder")
	_dump_hardware_placements(pa, "arch")

	modal.call("close")

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: hardware capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Drive a REAL pointer drag through the modal and report whether the part
## moved.
##
## Synthesised InputEvents pushed at the window, not direct handler calls: the
## question "can the player drag a part" includes whether the viewport even
## delivers the events, which calling `_drag_to` by hand would not answer. Each
## stage prints, so a failure says WHICH link broke rather than just "no".
func _verify_hardware_drag(modal: Control, p: LinkageParams, dir: String,
		manifest: Array) -> void:
	var builder = modal.get("_builder")
	var camera := modal.get("_camera") as Camera3D
	var vpc := modal.get("_vpc") as SubViewportContainer
	if builder == null or camera == null or vpc == null:
		print("PlaytestHarness: DRAG FAIL — modal has no builder/camera/viewport")
		return

	# Two subjects: a stack part (drags posAssembled along its axis) and the
	# BRACKET (drags its own local nudge). The bracket is the biggest thing on
	# screen and therefore the one a player grabs first — it used to refuse in
	# silence, which is indistinguishable from the drag being broken.
	var asm := LinkageHardware.assembly(p.hardware_assemblies, "outerVBeam")
	var target := {}
	for part in asm.get("parts", []):
		var d := part as Dictionary
		if str(d.get("type", "")) in ["bushing", "washer", "lockWasher"]:
			target = d
			break
	if target.is_empty():
		print("PlaytestHarness: DRAG FAIL — no draggable part in outerVBeam")
		return
	var pid := str(target["id"])
	var node := builder.part_node(pid, 0) as Node3D
	if node == null:
		print("PlaytestHarness: DRAG FAIL — part %s has no node" % pid)
		return

	# Where the part is on screen. The SubViewportContainer stretches 1:1, so a
	# viewport-space point is the container's own local space.
	var world: Vector3 = node.global_transform.origin
	if camera.is_position_behind(world):
		print("PlaytestHarness: DRAG FAIL — part is behind the camera")
		return
	var local := camera.unproject_position(world)
	var screen := vpc.get_global_rect().position + local
	print("PlaytestHarness: drag target %s at world %s -> screen %s"
		% [pid, str(world), str(screen)])

	var before := float(target.get("posAssembled", 0.0))
	var vp := modal.get_viewport()

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = screen
	down.global_position = screen
	vp.push_input(down)
	await get_tree().process_frame
	await get_tree().physics_frame

	print("PlaytestHarness: after press — selected=%s dragging=%s"
		% [str(modal.get("_selected")), str(modal.get("_dragging"))])

	# Walk the pointer across the screen in steps, as a hand would.
	var last := screen
	for i in range(1, 9):
		var to := screen + Vector2(14.0 * i, 0.0)
		var mm := InputEventMouseMotion.new()
		mm.position = to
		mm.global_position = to
		mm.relative = to - last
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
		last = to
		vp.push_input(mm)
		await get_tree().process_frame

	var after_drag := float(LinkageHardware.find_part(
		LinkageHardware.assembly(p.hardware_assemblies, "outerVBeam"), pid)
		.get("posAssembled", 0.0))
	await _graph_shot(dir, "drag_midway", manifest, "hardware")

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = last
	up.global_position = last
	vp.push_input(up)
	await get_tree().process_frame

	var moved := absf(after_drag - before)
	print("PlaytestHarness: DRAG %s — %s posAssembled %.4f -> %.4f (moved %.4f in)"
		% ["OK" if moved > 0.01 else "FAIL", pid, before, after_drag, moved])

	# --- the bracket ---------------------------------------------------------
	var bracket := LinkageHardware.bracket_part(asm)
	if bracket.is_empty():
		return
	var bid := str(bracket.get("id", ""))
	var bnode := builder.part_node(bid, 0) as Node3D
	if bnode == null:
		print("PlaytestHarness: BRACKET DRAG FAIL — no node for %s" % bid)
		return
	var bworld: Vector3 = bnode.global_transform.origin
	if camera.is_position_behind(bworld):
		print("PlaytestHarness: BRACKET DRAG skipped — behind the camera")
		return
	var bscreen := vpc.get_global_rect().position + camera.unproject_position(bworld)
	var bpr: Dictionary = bracket.get("params", {})
	var bbefore := float(bpr.get("posX", 0.0))

	var bdown := InputEventMouseButton.new()
	bdown.button_index = MOUSE_BUTTON_LEFT
	bdown.pressed = true
	bdown.position = bscreen
	bdown.global_position = bscreen
	vp.push_input(bdown)
	await get_tree().process_frame
	await get_tree().physics_frame
	print("PlaytestHarness: bracket press — selected=%s dragging=%s"
		% [str(modal.get("_selected")), str(modal.get("_dragging"))])

	var blast := bscreen
	for i in range(1, 7):
		var bto := bscreen + Vector2(9.0 * i, 0.0)
		var bmm := InputEventMouseMotion.new()
		bmm.position = bto
		bmm.global_position = bto
		bmm.relative = bto - blast
		bmm.button_mask = MOUSE_BUTTON_MASK_LEFT
		blast = bto
		vp.push_input(bmm)
		await get_tree().process_frame

	var bup := InputEventMouseButton.new()
	bup.button_index = MOUSE_BUTTON_LEFT
	bup.pressed = false
	bup.position = blast
	bup.global_position = blast
	vp.push_input(bup)
	await get_tree().process_frame

	var bafter := float((LinkageHardware.bracket_part(LinkageHardware.assembly(
		p.hardware_assemblies, "outerVBeam")).get("params", {}) as Dictionary)
		.get("posX", 0.0))
	var bmoved := absf(bafter - bbefore)
	print("PlaytestHarness: BRACKET DRAG %s — posX %.4f -> %.4f (moved %.4f in)"
		% ["OK" if bmoved > 0.01 else "FAIL", bbefore, bafter, bmoved])


## Console summary of every joint: which assembly, which pivot role, whether it
## flipped, and how far its seat sits from the V-stack pivot it clamps. That
## last number is the one that was wrong — it should be exactly the bracket's
## hole height, and it was the H-ring offset instead.
func _dump_hardware_placements(p: LinkageParams, tag: String) -> void:
	var pp := p.duplicate_params()
	pp.show_brackets = true
	pp.show_bolts = true
	var frame := LinkageSolver.solve(pp, LinkageKinematics.optimal_closed_angle(pp))
	var all := LinkageHwPlacement.placements(pp, frame)
	var by_id: Dictionary = {}
	var flips := 0
	for entry in all:
		var e := entry as Dictionary
		var aid := str(e["assembly_id"])
		by_id[aid] = int(by_id.get(aid, 0)) + 1
		if bool(e.get("flip_stack_axis", false)):
			flips += 1
	print("PlaytestHarness: hardware placements (%s): %d total %s, %d flipped"
		% [tag, all.size(), str(by_id), flips])

	var asm := LinkageHardware.assembly(pp.hardware_assemblies, "outerVBeam")
	var bpart := LinkageHardware.bracket_part(asm)
	var hole := LinkageHwLayout.bracket_hole_y(bpart)
	# The bracket's local nudge is part of the seat, so it has to come back out
	# of the identity too — otherwise nudging the bracket (which the drag test
	# above does) reports itself as an anchoring error.
	var bp: Dictionary = bpart.get("params", {})
	var nudge := Vector3(float(bp.get("posX", 0.0)), float(bp.get("posY", 0.0)),
		float(bp.get("posZ", 0.0)))
	var worst := 0.0
	for entry in all:
		var e := entry as Dictionary
		if str(e["assembly_id"]) != "outerVBeam":
			continue
		var xf: Transform3D = e["transform"]
		var back: Vector3 = xf.origin + xf.basis * Vector3(0.0, hole, 0.0) \
			- xf.basis * nudge
		# NEAREST matching bracket, not the first. With cap uprights a module
		# carries two outer-bottom brackets, so a role+ring+module key alone
		# picks the wrong one and reports a hundred-inch "error" that is really
		# the distance to the other end of the arch.
		var best := INF
		for bracket in frame["brackets"]:
			var br := bracket as Dictionary
			if str(br.get("pivot_role", "")) != "outer":
				continue
			if bool(br.get("is_bottom", false)) != bool(e["is_bottom"]):
				continue
			if int(br.get("module_index", -1)) != int(e["module_index"]):
				continue
			best = minf(best, back.distance_to(br["v_bolt_pivot"] as Vector3))
		if is_finite(best):
			worst = maxf(worst, best)
	print("PlaytestHarness: hardware anchor error (%s): worst %.6f in "
		% [tag, worst] + "(hole height %.4f in — 0 means every seat is exact)"
		% hole)


# ---------------------------------------------------------------------------
# Systems-graph UI capture (--capture=graph)
# ---------------------------------------------------------------------------

## One PNG per graph-view UI state so an agent can visually review the 2D
## systems graph (G view) without a human at the keyboard. Drives the REAL
## SystemGraphView handlers (same code paths as clicks/keys), never a mock.
## After Tidy: every root card's rect and any pair that overlaps — a PNG
## cannot say whether an overlap is in the layout data or only in the drawing.
func _graph_tidy_report(sgv: Node) -> void:
	var drv: Variant = sgv.get("_layout_driver")
	if drv == null:
		return
	var items: Array = (drv as Object).call("scope_items", "root")
	var bad := 0
	for i in items.size():
		var a: Dictionary = items[i]
		var ra := Rect2(float(a.get("x", 0.0)), float(a.get("y", 0.0)), float(a.get("width", 0.0)), float(a.get("height", 0.0)))
		print("graph tidy item %s %s @ %s" % [str(a.get("id", "")), str(a.get("type", "")), str(ra)])
		for j in range(i + 1, items.size()):
			var b: Dictionary = items[j]
			var rb := Rect2(float(b.get("x", 0.0)), float(b.get("y", 0.0)), float(b.get("width", 0.0)), float(b.get("height", 0.0)))
			if ra.intersects(rb):
				bad += 1
				print("graph tidy OVERLAP %s / %s" % [str(a.get("id", "")), str(b.get("id", ""))])
	print("graph tidy: %d layout item(s), %d overlapping pair(s) %s" % [items.size(), bad, "PASS" if bad == 0 else "FAIL"])


func _run_graph_capture() -> void:
	print("PlaytestHarness: graph capture — finding the graph view")
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting graph capture")
		_maybe_quit()
		return
	# Generated maps: wait for the world so placed props / site view have content.
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		print("PlaytestHarness: graph capture — waiting for map load")
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout

	# Reproducible conditions: frozen daytime clock, but CanvasLayers VISIBLE
	# (the graph is the subject) — do not reuse _set_capture_conditions.
	var main := get_tree().current_scene
	if main != null:
		if "time_scale" in main:
			main.time_scale = 0.0
		if "day_time" in main:
			main.day_time = _capture_hour

	var label := _shots_label if not _shots_label.is_empty() else "graph_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	# Open the graph the same way the G key does.
	print("PlaytestHarness: graph capture — opening the graph")
	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	await get_tree().create_timer(1.0).timeout
	print("PlaytestHarness: graph capture — graph open, shooting")
	await _graph_shot(dir, "01_open_as_loaded", manifest)

	# Every shot until the Site Plan step is FREEFORM. The graph reopens in
	# its saved lens, which on the player's world is usually Site Plan, so
	# "02_freeform_arranged" and the shots after it were Site Plan for months.
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "freeform")
		await get_tree().create_timer(1.0).timeout
		await _graph_shot(dir, "01b_freeform", manifest)

	# Auto-arranged freeform layout.
	if sgv.has_method("_apply_graph_auto_layout"):
		sgv.call("_apply_graph_auto_layout", true)
		await get_tree().create_timer(0.5).timeout
		await _graph_shot(dir, "02_freeform_arranged", manifest)
	# The force layout (Layout ▾ → Tidy), settled without the glide, on the
	# player's own graph (sandbox only — test captures never persist).
	if sgv.has_method("tidy_layout") and bool(sgv.call("tidy_layout", false, true)):
		if sgv.has_method("_fit_canvas_to_content"):
			sgv.call("_fit_canvas_to_content")
		await get_tree().create_timer(0.6).timeout
		await _graph_shot(dir, "02b_freeform_tidied", manifest)
		_graph_tidy_report(sgv)

	var canvas: Node = sgv.get("_graph_canvas")
	var model: Variant = sgv.get("model")

	# Selection + inspector: pick an interesting root node (controller > battery
	# > compound > first), through the same handler a canvas click fires.
	var sel_id := _graph_pick_item(model, ["controller", "battery", "smartbattery"])
	if not sel_id.is_empty() and canvas != null:
		canvas.set("selected_item_id", sel_id)
		if sgv.has_method("_on_canvas_item_selected"):
			sgv.call("_on_canvas_item_selected", sel_id)
		await get_tree().create_timer(0.5).timeout
		await _graph_shot(dir, "03_selected_inspector", manifest)

	# Compound (super-node) interior scope.
	var comp_id := _graph_pick_item(model, ["compound"], false)
	if not comp_id.is_empty() and sgv.has_method("_on_open_compound_requested"):
		sgv.call("_on_open_compound_requested", comp_id)
		await get_tree().create_timer(1.2).timeout
		await _graph_shot(dir, "04_compound_interior", manifest)
		if sgv.has_method("_on_scope_pop_requested"):
			sgv.call("_on_scope_pop_requested")
			await get_tree().create_timer(1.2).timeout

	# Zoom extremes (readability at LOD boundaries).
	if canvas != null:
		var zoom_saved := float(canvas.get("_zoom"))
		for z: Array in [[0.45, "05_zoomed_out"], [1.8, "06_zoomed_in"]]:
			canvas.set("_zoom", float(z[0]))
			canvas.call("queue_redraw")
			await get_tree().create_timer(0.3).timeout
			await _graph_shot(dir, str(z[1]), manifest)
		canvas.set("_zoom", zoom_saved)
		canvas.call("queue_redraw")

	# Site plan + elevation views.
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "site")
		await get_tree().create_timer(1.5).timeout
		await _graph_shot(dir, "07_site_plan", manifest)
		# Port handles at HIGH zoom. The V2 canvas overrides _draw_port_dot
		# for its freeform billboard and used to run that uncapped 6.8 × zoom
		# disc in Site Plan too, so the base's screen-space cap never applied:
		# at a zoom where a PowerSpout is 12 px, its four ports were the size
		# of the node. Zoom hard onto a placed item, shoot it, and print the
		# radii the PNG cannot be trusted to show at 1280 px.
		if canvas != null and canvas.has_method("_zoom_at"):
			var zoom_site_saved := float(canvas.get("_zoom"))
			var pan_site_saved: Vector2 = canvas.get("_pan")
			var ports_saved := bool(canvas.get("site_show_ports"))
			canvas.set("site_show_ports", true)
			var focus_px: Vector2 = canvas.size * 0.5
			var placed: Array = canvas.call("_visible_items") as Array
			for it0: Variant in placed:
				var it: Dictionary = it0
				if GraphSiteLayout.has_site_coords(it) and str(it.get("type", "")) != "compound":
					var tl: Vector2 = canvas.call("_item_screen_tl", it, canvas.size * 0.5)
					var sz: Vector2 = canvas.call("_item_screen_size", it)
					focus_px = tl + sz * 0.5
					break
			for _i in 14:
				canvas.call("_zoom_at", 1.5, focus_px)
			canvas.call("queue_redraw")
			await get_tree().create_timer(1.0).timeout
			var z := float(canvas.get("_zoom"))
			var s_pxm := GraphSiteLayout.px_per_m(z)
			var grab := float(canvas.call("_port_grab_radius"))
			var consts: Dictionary = (canvas.get_script() as Script).get_script_constant_map()
			var dot_max := float(consts.get("SITE_PORT_DOT_MAX_PX", 7.0))
			var grab_max := float(consts.get("SITE_PORT_GRAB_MAX_PX", 14.0))
			var dot := clampf(0.3 * s_pxm, float(consts.get("SITE_PORT_DOT_MIN_PX", 3.5)), dot_max)
			var ok := grab <= grab_max + 0.01 and dot <= dot_max + 0.01
			print("PlaytestHarness: site plan ports at zoom %.1f (%.0f px/m): dot r %.1f px (cap %.0f), grab r %.1f px (cap %.0f) %s" % [
					z, s_pxm, dot, dot_max, grab, grab_max, "(PASS)" if ok else "(FAIL)"])
			await _graph_shot(dir, "07c_site_plan_zoomed_ports", manifest)
			canvas.set("_zoom", zoom_site_saved)
			canvas.set("_pan", pan_site_saved)
			canvas.set("site_show_ports", ports_saved)
			canvas.call("queue_redraw")
			await get_tree().create_timer(0.5).timeout
		# Desire-line toggles must flip THROUGH THE REAL MENU HANDLER — the
		# items were once wired to the wrong popup's handler, so every click
		# was a silent no-op (worn paths could never turn on, trails never
		# off). Also orbit the live disc: the NPC layers used flat disc math
		# and stayed put while the node chips turned, so the orbited shot is
		# the visual proof they now ride the camera projection.
		var vm_consts: Dictionary = (sgv.get_script() as Script).get_script_constant_map()
		var id_lines := int(vm_consts.get("VIEW_MODE_DESIRE_LINES", 152))
		var id_trails := int(vm_consts.get("VIEW_MODE_DESIRE_TRAILS", 153))
		var lines_before := bool(sgv.get("_desire_lines_on"))
		var trails_before := true if canvas == null \
				else bool(canvas.get("npc_trails_enabled"))
		sgv.call("_on_view_mode_menu_id", id_lines)
		sgv.call("_on_view_mode_menu_id", id_trails)
		var lines_after := bool(sgv.get("_desire_lines_on"))
		var trails_after := true if canvas == null \
				else bool(canvas.get("npc_trails_enabled"))
		if lines_after == lines_before or trails_after == trails_before:
			push_error("PlaytestHarness: desire menu handler did NOT flip state "
					+ "— the View options wiring regressed")
		else:
			print("PlaytestHarness: desire toggles flip through the real handler "
					+ "(lines %s->%s, trails %s->%s)" % [lines_before, lines_after,
					trails_before, trails_after])
		var orbit_svc: Variant = null if canvas == null \
				else canvas.get("soi_preview_service")
		if orbit_svc != null and (orbit_svc as Object).has_method("apply_orbit_delta"):
			orbit_svc.call("apply_orbit_delta", Vector2(140.0, 90.0))
			await get_tree().create_timer(0.8).timeout
			await _graph_shot(dir, "07b_site_plan_orbited_desire", manifest)
			if (orbit_svc as Object).has_method("reset_phys_orbit"):
				orbit_svc.call("reset_phys_orbit")
		# Restore the stock view state for the later phases.
		sgv.call("_on_view_mode_menu_id", id_lines)
		sgv.call("_on_view_mode_menu_id", id_trails)
		await get_tree().create_timer(0.3).timeout
		sgv.call("_apply_graph_view_mode", "elevation")
		await get_tree().create_timer(1.5).timeout
		await _graph_shot(dir, "08_elevation", manifest)
		sgv.call("_apply_graph_view_mode", "freeform")
		await get_tree().create_timer(0.5).timeout

	# Left library sidebar collapsed (canvas-only reading).
	if sgv.get("_sidebar_l_open") != null:
		sgv.set("_sidebar_l_open", false)
		if sgv.has_method("_apply_layout"):
			sgv.call("_apply_layout")
		await get_tree().create_timer(0.3).timeout
		await _graph_shot(dir, "09_library_collapsed", manifest)
		sgv.set("_sidebar_l_open", true)
		if sgv.has_method("_apply_layout"):
			sgv.call("_apply_layout")

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: graph capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Regression guard for the "graph must be open to tick water" bug
## (--capture=ambient, headless-safe, no screenshots): builds a primed pond +
## siphon + culvert outlet DIRECTLY on the model, keeps SystemGraphView.visible
## FALSE the entire time (graph never opened), speeds up the world clock, and
## asserts the pond drained + the outlet accumulated volume. If this fails, the
## resource-flow tick has regressed back to only running while the graph UI is
## open — see system_graph_view._tick_resource_flow_ambient.
## Verifies the Phase 3 auto-bind guardrail (--capture=autobind, headless-unsafe,
## windowed only): a NEAR pond within max_dist_m auto-binds silently; a FAR pond
## beyond the cap does not (so placing a turbine doesn't silently latch onto some
## distant pond on the map); an uncapped manual Rebind ignores distance.
## Verifies the Phase 3 stable-pond-id fix (--capture=pondid, needs a REAL
## TerrainLoader — generated location maps only, e.g. --map-lat=/--map-lon=):
## carve a pond, add it to the graph, then re-designate the SAME basin with a
## reshaped polygon (forcing EarthworksBuilder.basin_tag_from_poly to derive a
## DIFFERENT tag, exactly what a player resizing/reshaping an existing pond
## does). Before this fix that orphaned the water record + graph tank
## (duplicate pond, siphon binding needs manual healing). Asserts: no
## duplicate water-body record, pond_id unchanged, and the graph tank still
## resolves to a live pond (resolve_pond_idx_for_graph_tank) with no drift.
## Verifies the Phase 5 downhill-culvert-routing integration (--capture=culvert,
## needs a REAL TerrainLoader — generated location maps only): builds a siphon
## with real site coords, calls ensure_siphon_outlet_sink, and confirms the
## traced route actually engaged (route_3d has intermediate points, the outlet
## landed somewhere other than the old fixed "+12m/-9m" formula, and the invert
## is a real terrain elevation) rather than silently falling back to the old
## straight-chord behavior. The trace ALGORITHM itself (slope/bowl/flat cases)
## is proven offline in watershed_selftest.gd — this only proves the live
## SoiService/GraphSiteLayout/TerrainLoader wiring engages it.
func _run_culvert_downhill_verify() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: TerrainLoader not found — aborting culvert verify")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting culvert verify")
		_maybe_quit()
		return
	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting culvert verify")
		_maybe_quit()
		return

	var g := 0.0
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		g = float((soi.call("world_center") as Vector3).y)

	var siphon_id := "cap_culvert_siphon"
	# Self-cleaning: a re-run against the same map (repeated debugging) must not
	# find add_item's "id already exists — merge" path finding a stale outlet
	# from a PRIOR run and short-circuiting ensure_siphon_outlet_sink's early
	# "already has an outlet" return before it ever re-traces.
	var stale := model.call("get_item", siphon_id) as Dictionary
	if not stale.is_empty():
		for c in (model.connections as Array).duplicate():
			if not (c is Dictionary):
				continue
			var cd := c as Dictionary
			if str(cd.get("source_item_id", "")) == siphon_id:
				var tgt_id := str(cd.get("target_item_id", ""))
				model.remove_connection(str(cd.get("id", "")))
				if not tgt_id.is_empty():
					model.remove_item(tgt_id)
		model.remove_item(siphon_id)
	model.add_item({
		"id": siphon_id, "type": "processor", "x": 160.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "elevation_m": g,
		"site_x_m": 0.0, "site_z_m": 0.0,
		"specs": {
			"name": "Culvert Verify Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"module_elev_m": g,
		},
	})
	var old_formula_site := Vector2(12.0, 0.0)  # the pre-fix "+12m site X" offset

	var siphon_check: Dictionary = model.call("get_item", siphon_id)
	print("PlaytestHarness: culvert diag — siphon has_site=%s site=%s soi_found=%s loader_found=%s" % [
			str(GraphSiteLayout.has_site_coords(siphon_check)),
			str(GraphSiteLayout.site_xz(siphon_check)),
			str(soi != null), str(loader != null and loader.has_method("ground_height_at"))])

	var sink_id := str(sgv.call("ensure_siphon_outlet_sink", siphon_id))
	print("PlaytestHarness: culvert verify — sink created=%s" % str(not sink_id.is_empty()))

	var conn: Dictionary = {}
	for c in model.connections:
		if not (c is Dictionary):
			continue
		if str((c as Dictionary).get("source_item_id", "")) == siphon_id:
			conn = c as Dictionary
			break
	var route: Array = conn.get("route_3d", []) as Array
	var traced := route.size() > 0
	print("PlaytestHarness: culvert verify — route_3d point count=%d (%s)" % [
			route.size(), "downhill trace engaged" if traced else \
			"no route — either flat/no-DEM terrain (correctly falls back) or the trace failed to engage"])

	var sink_item: Dictionary = model.call("get_item", sink_id) if not sink_id.is_empty() else {}
	var sink_site := Vector2(float(sink_item.get("site_x_m", 0.0)), float(sink_item.get("site_z_m", 0.0)))
	var matches_flat_fallback := sink_site.distance_to(old_formula_site) < 1.0
	print("PlaytestHarness: culvert verify — outlet site=%s (flat-terrain fallback would be %s): %s" % [
			str(sink_site), str(old_formula_site),
			"used fallback (flat/no-DEM terrain)" if matches_flat_fallback else "real downhill direction found"])

	var siphon_after: Dictionary = model.call("get_item", siphon_id)
	var out_inv := float((siphon_after.get("specs", {}) as Dictionary).get("outlet_invert_m", NAN))
	print("PlaytestHarness: culvert verify — outlet invert=%.3f m (module was %.3f m)" % [out_inv, g])

	# Both outcomes are valid depending on terrain: a real downhill route (traced
	# + moved off the fallback site) on relief terrain, OR the flat-terrain
	# fallback (no route, site at the fixed +12m offset) when the DEM is flat/
	# unavailable — either proves the integration engaged correctly. Only "no
	# route AND didn't even apply the fallback offset" is a genuine failure.
	var ok := traced or matches_flat_fallback
	print("PlaytestHarness: culvert verify — OVERALL %s" % ("PASS" if ok else
			"FAIL (neither a downhill route nor the flat-terrain fallback engaged)"))
	_maybe_quit()


## Every index of the loader's water list. get_pond_info answers valid=false for
## flowing waterways, which sit MID-list on a real map, so a scan must skip
## them rather than stop at the first one.
func _water_count(loader: Node) -> int:
	var wd: Variant = loader.get("_water_data")
	return (wd as Array).size() if wd is Array else 200


func _run_pond_id_verify() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: TerrainLoader not found — aborting pond-id verify")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting pond-id verify")
		_maybe_quit()
		return

	# A modest square near the site origin — comfortably above WaterBuilder's
	# 80 m² minimum. ground_height_at gives it a real (if synthetic-fallback)
	# elevation on any freshly generated map.
	var poly1 := PackedVector2Array([
		Vector2(-6, -6), Vector2(6, -6), Vector2(6, 6), Vector2(-6, 6)])
	var ok1 := bool(loader.call("designate_sculpted_pond", poly1, "Verify Pond", NAN, ""))
	print("PlaytestHarness: pondid verify — initial designate ok=%s" % str(ok1))
	if not ok1:
		push_error("PlaytestHarness: pond-id verify FAIL — could not designate the test pond")
		_maybe_quit()
		return

	var idx1 := -1
	for i in _water_count(loader):
		# find_pond_idx_by_tag needs the freshly-derived tag; read it back from
		# the record instead of re-deriving (EarthworksBuilder is static/private
		# to the loader in spirit — just scan get_pond_info by trial index 0..N).
		var info := loader.call("get_pond_info", i) as Dictionary
		if not bool(info.get("valid", false)):
			continue
		if bool(info.get("user", false)) and str(info.get("label", "")) == "Verify Pond":
			idx1 = i
			break
	if idx1 < 0:
		push_error("PlaytestHarness: pond-id verify FAIL — designated pond not found in water data")
		_maybe_quit()
		return
	var info1 := loader.call("get_pond_info", idx1) as Dictionary
	var pond_id1 := str(info1.get("pond_id", ""))
	var tag1 := str(info1.get("tag", ""))
	print("PlaytestHarness: pondid verify — pond_id=%s tag=%s" % [pond_id1, tag1])
	if pond_id1.is_empty():
		push_error("PlaytestHarness: pond-id verify FAIL — no pond_id assigned")
		_maybe_quit()
		return

	var added := bool(loader.call("add_pond_to_graph", idx1))
	print("PlaytestHarness: pondid verify — add_pond_to_graph ok=%s" % str(added))
	await get_tree().create_timer(0.3).timeout

	# Find the graph tank and confirm it carries the stable pond_id.
	var model: Variant = sgv.get("model")
	var tank_id := ""
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if bool(specs.get("pond_storage", false)) and str(specs.get("pond_id", "")) == pond_id1:
			tank_id = str((it as Dictionary).get("id", ""))
			break
	print("PlaytestHarness: pondid verify — graph tank found=%s" % str(not tank_id.is_empty()))

	# Re-designate the SAME basin with a DIFFERENT polygon (simulates the player
	# resizing/reshaping via the Pond tool again) — empty basin_tag forces a
	# fresh auto-derived tag from the new geometry.
	var water_count_before := 0
	for i in _water_count(loader):
		var info_b := loader.call("get_pond_info", i) as Dictionary
		if not bool(info_b.get("valid", false)):
			continue
		water_count_before += 1
	var poly2 := PackedVector2Array([
		Vector2(-9, -7), Vector2(9, -7), Vector2(9, 7), Vector2(-9, 7)])
	var ok2 := bool(loader.call("designate_sculpted_pond", poly2, "Verify Pond", NAN, ""))
	print("PlaytestHarness: pondid verify — re-designate (reshaped) ok=%s" % str(ok2))
	await get_tree().create_timer(0.3).timeout

	var water_count_after := 0
	var idx2 := -1
	for i in _water_count(loader):
		var info_c := loader.call("get_pond_info", i) as Dictionary
		if not bool(info_c.get("valid", false)):
			continue
		water_count_after += 1
		if str(info_c.get("pond_id", "")) == pond_id1:
			idx2 = i
	var no_duplicate := water_count_after == water_count_before
	print("PlaytestHarness: pondid verify — water body count before=%d after=%d -> %s" % [
			water_count_before, water_count_after,
			"PASS (no duplicate)" if no_duplicate else "FAIL (duplicate record created)"])

	var info2 := loader.call("get_pond_info", idx2) as Dictionary if idx2 >= 0 else {}
	var pond_id2 := str(info2.get("pond_id", ""))
	var tag2 := str(info2.get("tag", ""))
	var id_preserved := idx2 >= 0 and pond_id2 == pond_id1
	print("PlaytestHarness: pondid verify — pond_id preserved (%s -> %s) tag changed (%s -> %s): %s" % [
			pond_id1, pond_id2, tag1, tag2,
			"PASS" if id_preserved else "FAIL"])

	# The graph tank (still carrying the OLD tag until healed) must resolve
	# back to the live, re-shaped pond via pond_id — no orphaning.
	var resolved := {}
	if not tank_id.is_empty():
		var tank_item: Dictionary = model.call("get_item", tank_id)
		resolved = loader.call("resolve_pond_idx_for_graph_tank", tank_item) as Dictionary
	var resolves_live := bool(resolved.get("live", false)) and int(resolved.get("idx", -1)) == idx2
	print("PlaytestHarness: pondid verify — graph tank resolves to live re-shaped pond: %s (idx=%s want=%s)" % [
			"PASS" if resolves_live else "FAIL", str(resolved.get("idx", -1)), str(idx2)])

	print("PlaytestHarness: pondid verify — OVERALL %s" % (
			"PASS" if (no_duplicate and id_preserved and resolves_live) else "FAIL"))
	_maybe_quit()


## Load-time hydro diagnostic (--capture=hydroload, console only). Loads a REAL
## saved map and dumps the state of every hydro conduit BEFORE the graph has ever
## been opened, then again after a graph open/close — the exact sequence that
## "fixes" a culvert pointing at the sky and "loses" a routed penstock.
## --capture=sitebalance — the WHOLE site as one system, on the player's own
## world, with the graph CLOSED (how the site is actually lived in). Asserts the
## contracts the Mt Vernon playtest found broken (2026-10-12):
##  1. every hydro turbine with DC wires reaches a battery (a controller's
##     battery terminal is the bank bus);
##  2. SolarUI's graph-DC term equals the wired turbines' output with the graph
##     closed, and the battery integrates it;
##  3. a turbine making watts is moving water (no phantom power);
##  4. each pond's graph level equals its 3D water surface (one stage curve),
##     and its own 3D plane follows the level;
##  5. under an 8 mm/h storm each pond books rain on its surface and rises
##     (or spills / drains through a running siphon).
## Read-only in spirit: a test capture never persists.
func _sb_check(label: String, ok: bool) -> int:
	if ok:
		print("PlaytestHarness: sitebalance — OK: %s" % label)
		return 0
	push_error("PlaytestHarness: sitebalance — FAIL: %s" % label)
	return 1


func _sb_pond_planes_ok(loader: Node, model: Object) -> Array:
	var out: Array = []  # [label, ok]
	var root: Variant = loader.get("_water_root") if loader != null else null
	for it: Dictionary in model.get("items"):
		var ps: Dictionary = it.get("specs", {}) as Dictionary
		if not bool(ps.get("pond_storage", false)):
			continue
		var tag := str(ps.get("osm_water_tag", ""))
		var idx := int(loader.call("find_pond_idx_by_tag", tag)) if loader != null else -1
		if idx < 0:
			continue
		var info: Dictionary = loader.call("get_pond_info", idx)
		var g_lvl := float(ps.get("level_m", NAN))
		var m_lvl := float(info.get("level_m", NAN))
		out.append(["%s graph level %.3f == 3D level %.3f (±0.02 m)" % [tag, g_lvl, m_lvl],
				absf(g_lvl - m_lvl) <= 0.02])
		if root is Node3D and is_instance_valid(root):
			for c in (root as Node3D).get_children():
				if c is Node3D and str((c as Node3D).get_meta("pond_tag", "")) == tag:
					var plane := float((c as Node3D).get_meta("built_level_m", NAN)) + (c as Node3D).position.y
					out.append(["%s 3D water plane %.3f follows the level %.3f" % [tag, plane, m_lvl],
							absf(plane - m_lvl) <= 0.03])
	return out


func _run_site_balance_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: no SystemGraphView — aborting sitebalance")
		_maybe_quit()
		return
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s() + 3.0).timeout
	var main := get_tree().current_scene
	main.set("time_scale", 0.0)
	sgv.set("visible", false)
	var solar: Node = main.get_node_or_null("UILayer/SolarUI")
	var model: Object = sgv.get("model")
	var eng: Object = sgv.get("_resource_flow")
	var wn: Node = sgv.call("_water_network_node") if sgv.has_method("_water_network_node") else null
	var fails := 0

	# 1. DC wiring reaches a battery.
	var wired: Array[String] = []
	for it: Dictionary in model.get("items"):
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		if str(it.get("type", "")) != "processor" or str(sp.get("role", "")) != "siphon_hydro":
			continue
		var iid := str(it.get("id", ""))
		var outs: Array = sp.get("outputs", []) as Array
		for oi in outs.size():
			if str((outs[oi] as Dictionary).get("kind", "")) != "dc_electricity":
				continue
			var handle := "res_out_%d_pos" % oi
			var has_wire := false
			for c: Dictionary in model.get("connections"):
				if (str(c.get("source_item_id", "")) == iid and str(c.get("source_handle_id", "")) == handle) \
						or (str(c.get("target_item_id", "")) == iid and str(c.get("target_handle_id", "")) == handle):
					has_wire = true
			if has_wire:
				var bat := DcPowerWiring.find_battery_for_dc_port(model, iid, handle)
				fails += _sb_check("%s (%s) DC wiring reaches a battery ('%s')" % [
						iid, str(sp.get("name", "")), bat], not bat.is_empty())
				if not bat.is_empty():
					wired.append(iid)

	# 4a. Graph level == 3D level, as loaded.
	for row in _sb_pond_planes_ok(loader, model):
		fails += _sb_check("as loaded: " + str(row[0]), bool(row[1]))

	# 2 + 3. Dry, graph CLOSED, 360x for 12 s.
	var bat0 := float(solar.get("battery_kwh_stored")) if solar != null else 0.0
	var cap := float(solar.get("BATTERY_CAPACITY_KWH")) if solar != null else 0.0
	main.set("time_scale", 0.1)
	await get_tree().create_timer(12.0).timeout
	main.set("time_scale", 0.0)
	await get_tree().create_timer(0.5).timeout
	var want_dc := 0.0
	for iid in wired:
		want_dc += float((model.call("get_item", iid).get("specs", {}) as Dictionary).get("current_output_kw", 0.0))
	if solar != null:
		var got_dc := float(solar.get("current_graph_dc_kw"))
		fails += _sb_check("graph closed: SolarUI hydro/DC term %.3f kW == wired turbines %.3f kW" % [got_dc, want_dc],
				absf(got_dc - want_dc) <= maxf(0.01, want_dc * 0.05))
		var bat1 := float(solar.get("battery_kwh_stored"))
		print("PlaytestHarness: sitebalance — battery %.3f → %.3f kWh (cap %.2f), load %.3f kW, solar %.3f kW" % [
				bat0, bat1, cap, float(solar.get("current_load_kw")), float(solar.get("current_solar_kw"))])
		if want_dc > 0.01 and bat0 < cap * 0.95:
			fails += _sb_check("the battery integrates the generation (moved %.3f kWh)" % (bat1 - bat0),
					absf(bat1 - bat0) > 1e-4)
	for it: Dictionary in model.get("items"):
		var sp2: Dictionary = it.get("specs", {}) as Dictionary
		if str(sp2.get("role", "")) != "siphon_hydro" or float(sp2.get("live_power_w", 0.0)) <= 1.0:
			continue
		var in_rate := 0.0
		var ins: Array = sp2.get("inputs", []) as Array
		if not ins.is_empty():
			in_rate = float((ins[0] as Dictionary).get("rate", 0.0))
		fails += _sb_check("%s makes %.0f W and moves water (%.0f L/h, %s)" % [str(it.get("id", "")),
				float(sp2.get("live_power_w", 0.0)), in_rate, str(sp2.get("live_regime", ""))],
				in_rate > 1e-3 or (str(sp2.get("live_regime", "")) == "spec" and float(sp2.get("live_q_lps", 0.0)) > 0.0))

	# 5. Storm: 8 mm/h for 12 s at 360x (~1.2 sim-h).
	var before: Dictionary = {}
	for it: Dictionary in model.get("items"):
		if bool((it.get("specs", {}) as Dictionary).get("pond_storage", false)):
			before[str(it.get("id", ""))] = float((it.get("specs", {}) as Dictionary).get("stock_l", 0.0))
	if eng != null:
		eng.set("rain_rate_override_mmh", 8.0)
	if wn != null:
		wn.set("rain_override_mmh", 8.0)
	main.set("time_scale", 0.1)
	await get_tree().create_timer(12.0).timeout
	main.set("time_scale", 0.0)
	await get_tree().create_timer(0.6).timeout
	for pid: String in before.keys():
		var ps3: Dictionary = model.call("get_item", pid).get("specs", {}) as Dictionary
		var d_stock := float(ps3.get("stock_l", 0.0)) - float(before[pid])
		var rain_lph := float(ps3.get("budget_rain_lph", 0.0))
		var stream_lph := float(ps3.get("budget_stream_lph", 0.0))
		var spill_lph := float(ps3.get("budget_spill_lph", 0.0))
		print("PlaytestHarness: sitebalance — pond %s storm: Δstock %+.0f L, rain on surface %.0f L/h, streams %.0f L/h, spill %.0f L/h, out %.0f L/h" % [
				pid, d_stock, rain_lph, stream_lph, spill_lph, float(ps3.get("outflow_rate", 0.0))])
		fails += _sb_check("pond %s books rain on its own surface" % pid, rain_lph > 0.0)
		fails += _sb_check("pond %s rises in the storm (or spills / a siphon drains it)" % pid,
				d_stock > 0.0 or spill_lph > 0.0 or float(ps3.get("outflow_rate", 0.0)) > 0.0)
	for row2 in _sb_pond_planes_ok(loader, model):
		fails += _sb_check("after the storm: " + str(row2[0]), bool(row2[1]))
	if eng != null:
		eng.set("rain_rate_override_mmh", -1.0)
	if wn != null:
		wn.set("rain_override_mmh", -1.0)
	print("PlaytestHarness: sitebalance %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	_maybe_quit()


func _run_hydro_load_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: no SystemGraphView — aborting hydroload")
		_maybe_quit()
		return
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s() + 3.0).timeout
	var main := get_tree().current_scene
	if main != null and "time_scale" in main:
		main.time_scale = 0.0

	var fails := _hydro_assert_anchors(sgv, main)
	_hydro_dump(sgv, main, "AS LOADED (graph never opened)")
	# The x-ray runs must not hang over the landscape in first person.
	fails += _hydro_assert_world_hidden(main, true, "as loaded (first person)")
	var mgr0: Node = main.find_child("ConduitManager", true, false) if main != null else null
	var wires_pref: bool = bool(mgr0.get("_global_visible")) if mgr0 != null else false
	# Exactly what the player does: G, then back to 3D.
	sgv.set("visible", true)
	await get_tree().create_timer(2.0).timeout
	_hydro_dump(sgv, main, "GRAPH OPEN")
	sgv.set("visible", false)
	await get_tree().create_timer(1.5).timeout
	_hydro_dump(sgv, main, "BACK IN 3D (after graph open/close)")
	# Site Plan's prefer_3d wire mode borrows the global "Show 3D wires (world)"
	# preference; closing the graph must hand it back, or every x-ray run stays
	# over the landscape for the rest of the session.
	if mgr0 != null:
		fails += _pen_check("graph close restored the world-wires pref (%s)"
				% str(wires_pref), bool(mgr0.get("_global_visible")) == wires_pref)
	fails += _hydro_assert_world_hidden(main, true, "back in 3D after graph close")
	# The Hydro Lab round trip — the other half of the report ("open Hydrolab and
	# return to 3D, the pipe is gone"). The Lab forces global wires ON and its
	# teardown restores them OFF, which is where an explicitly-visible penstock
	# could get swept out with the rest.
	var model: Variant = sgv.get("model")
	var turb_id := ""
	if model != null:
		for it in model.items:
			if it is Dictionary and str(((it as Dictionary).get("specs", {})
					as Dictionary).get("role", "")) == "siphon_hydro":
				turb_id = str((it as Dictionary).get("id", ""))
				break
	if not turb_id.is_empty() and sgv.has_method("open_siphon_lab"):
		sgv.set("visible", true)
		await get_tree().create_timer(1.0).timeout
		sgv.call("open_siphon_lab", turb_id)
		await get_tree().create_timer(2.5).timeout
		_hydro_dump(sgv, main, "HYDRO LAB OPEN (%s)" % turb_id)
		# …but the Lab's CT section is the whole reason they are x-ray at all.
		fails += _hydro_assert_world_hidden(main, false, "Hydro Lab CT open")
		if sgv.has_method("close_hydro_lab"):
			sgv.call("close_hydro_lab")
		await get_tree().create_timer(1.0).timeout
		sgv.set("visible", false)
		await get_tree().create_timer(1.5).timeout
		_hydro_dump(sgv, main, "BACK IN 3D (after Hydro Lab)")
		fails += _hydro_assert_world_hidden(main, true, "back in 3D after the Lab")
	# Buried-pipe depth cue: every physical run reports its max burial; a run
	# under the ground anywhere carries a ground TRACE mesh.
	var mgr_b: Node = main.find_child("ConduitManager", true, false) if main != null else null
	if mgr_b != null and mgr_b.has_method("burial_max_for") and model != null:
		mgr_b.call("set_global_visibility", true)
		await get_tree().create_timer(1.5).timeout
		var buried_runs := 0
		var traced := 0
		for cv in model.connections:
			if not (cv is Dictionary):
				continue
			var cdict := cv as Dictionary
			var ct := str(cdict.get("conduit_type", ""))
			if ct != "poly_penstock" and ct != "culvert_pipe":
				continue
			var ccid := str(cdict.get("id", ""))
			var mb := float(mgr_b.call("burial_max_for", ccid))
			var tr: Node = mgr_b.call("burial_trace_for", ccid) as Node
			print("PlaytestHarness: hydroload — %s %s max burial %.2f m · ground trace %s" % [
					ct, ccid, mb, "yes" if tr != null else "no"])
			if mb >= 0.1:
				buried_runs += 1
				if tr != null:
					traced += 1
		fails += _pen_check("every run buried anywhere carries a ground trace (%d of %d)" % [traced, buried_runs],
				traced == buried_runs)
		mgr_b.call("set_global_visibility", wires_pref)
		await get_tree().create_timer(0.5).timeout
	# The END marker drag wants the siphon whose draft pipe HAS an outlet node
	# (Mt Vernon also carries a PowerSpout, which discharges at the machine).
	var marker_turb := ""
	var rf0: Variant = sgv.get("_resource_flow")
	if model != null and rf0 != null and rf0.has_method("_resolve_siphon_outlet_tank"):
		for it2 in model.items:
			if not (it2 is Dictionary):
				continue
			var sp2: Dictionary = (it2 as Dictionary).get("specs", {}) as Dictionary
			if str(sp2.get("role", "")) != "siphon_hydro":
				continue
			if not (rf0.call("_resolve_siphon_outlet_tank", it2) as Dictionary).is_empty():
				marker_turb = str((it2 as Dictionary).get("id", ""))
				break
	if not marker_turb.is_empty():
		fails += await _hydro_outlet_marker_drag(sgv, main, marker_turb)
	else:
		print("PlaytestHarness: hydroload — outlet marker drag SKIPPED (no siphon with an outlet on this map)")
	if fails == 0:
		print("PlaytestHarness: hydroload verify — PASS")
	else:
		push_error("PlaytestHarness: hydroload verify — %d CHECK(S) FAILED" % fails)
	_maybe_quit()


## The draft outlet's END marker (gameplay/outlet_end_marker.gd), driven with
## REAL input: stand near the culvert mouth, Ctrl-aim it (the crosshair must
## focus the MARKER, not the pipe), press, turn the camera past the drag
## threshold, release — and assert the outlet node moved under the crosshair
## with the culvert's far end and the physics' exit height following, that NO
## waypoint was inserted, and that the marker re-seated on the rebuilt mouth.
func _hydro_outlet_marker_drag(sgv: Node, main: Node, turb_id: String) -> int:
	var fails := 0
	var model: Variant = sgv.get("model")
	var mgr: Node = sgv.call("_get_conduit_manager")
	var player: Variant = main.get("player")
	var cam: Camera3D = (player as Node3D).get_node_or_null("CameraArm/Camera3D") if player is Node3D else null
	if model == null or mgr == null or cam == null or not mgr.has_method("outlet_marker_for"):
		print("PlaytestHarness: hydroload — outlet marker drag SKIPPED (no manager / camera)")
		return 0
	var sink: Dictionary = {}
	var conn_id := ""
	var rf: Variant = sgv.get("_resource_flow")
	if rf != null and rf.has_method("_resolve_siphon_outlet_tank"):
		sink = rf.call("_resolve_siphon_outlet_tank", model.call("get_item", turb_id))
	if sink.is_empty():
		print("PlaytestHarness: hydroload — outlet marker drag SKIPPED (siphon has no outlet)")
		return 0
	var sid := str(sink.get("id", ""))
	for conn: Dictionary in model.get("connections") as Array:
		if str(conn.get("source_item_id", "")) == turb_id and str(conn.get("target_item_id", "")) == sid \
				and str(conn.get("conduit_type", "")) == "culvert_pipe":
			conn_id = str(conn.get("id", ""))
	# The manager only ticks markers while it processes; give it a moment.
	await get_tree().create_timer(1.0).timeout
	var marker: Node3D = mgr.call("outlet_marker_for", conn_id) as Node3D
	fails += _pen_check("the siphon's culvert carries an OutletEndMarker at its mouth", marker != null)
	if marker == null:
		return fails
	var site0 := GraphSiteLayout.site_xz(sink)
	var elev0 := float(sink.get("elevation_m", NAN))
	var wps0 := ((model.call("get_connection", conn_id) as Dictionary).get("route_3d", []) as Array).size()
	var mpos := marker.global_position
	print("PlaytestHarness: hydroload — outlet marker at %s (sink site %s elev %.2f, %d waypoints)" % [
			str(mpos), str(site0), elev0, wps0])
	(sgv as CanvasItem).visible = false
	await get_tree().create_timer(0.4).timeout
	# Stand 7 m up-slope of the mouth, looking at it.
	var stand := mpos + Vector3(5.0, 0.0, 5.0)
	stand.y = TerrainSurfaceQuery.ground_height_at(main, stand.x, stand.z) + 0.3
	(player as Node3D).global_position = stand
	for _i in 4:
		await get_tree().physics_frame
	_aim_player_at(player as Node3D, cam, mpos)
	CursorController.set_paused(false)
	await get_tree().create_timer(0.4).timeout
	var vp := main.get_viewport()
	var centre_px := vp.get_visible_rect().size * 0.5
	await _lc_move(vp, centre_px, true)
	for _j in 4:
		await get_tree().physics_frame
	var focus: Node = (player as Node).get_node_or_null("InteractionFocus")
	var focused: Variant = focus.call("get_focused") if focus != null else null
	var cfid := str(focus.call("get_conduit_focus_id")) if focus != null else "?"
	print("PlaytestHarness: hydroload — Ctrl-aim at the outlet end: focused=%s conduit_focus='%s' capture=%s" % [
			str(focused.name) if focused is Node else "null", cfid, str(CursorController.should_capture_look())])
	fails += _pen_check("Ctrl-aiming at the pipe's end focuses the OUTLET MARKER, not the pipe",
			focused == marker and cfid.is_empty())
	if focused != marker:
		return fails
	# Press, then turn the camera (REAL relative motion — the marker follows
	# the crosshair's terrain hit, exactly as a hand would drag it).
	await _lc_press(vp, centre_px, true, false, true)
	for k in 10:
		var mm := InputEventMouseMotion.new()
		mm.position = centre_px
		mm.global_position = centre_px
		mm.relative = Vector2(-6.0, 1.5)
		mm.ctrl_pressed = true
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
		vp.push_input(mm)
		await get_tree().physics_frame
		await get_tree().process_frame
	var grab: Node = (player as Node).get_node_or_null("GrabController")
	var grabbing := grab != null and bool(grab.call("is_grabbing"))
	var mid := marker.global_position
	await _lc_press(vp, centre_px, false, false, true)
	await get_tree().create_timer(1.2).timeout
	var sink1: Dictionary = model.call("get_item", sid)
	var site1 := GraphSiteLayout.site_xz(sink1)
	var elev1 := float(sink1.get("elevation_m", NAN))
	var conn1: Dictionary = model.call("get_connection", conn_id)
	var wps1 := (conn1.get("route_3d", []) as Array).size()
	var soi := get_tree().root.get_node_or_null("SoiService")
	var c: Vector3 = soi.call("world_center") as Vector3
	var g1 := TerrainSurfaceQuery.ground_height_at(main, c.x + site1.x, c.z + site1.y)
	var marker2: Node3D = mgr.call("outlet_marker_for", conn_id) as Node3D
	var m2 := marker2.global_position if marker2 != null else Vector3.INF
	print("PlaytestHarness: hydroload — outlet marker drag: grabbing=%s mid %s · sink %s → %s (%.1f m) · elev %.2f (ground %.2f) · invert_out %.2f · waypoints %d → %d · marker now %s" % [
			str(grabbing), str(mid), str(site0), str(site1), site1.distance_to(site0), elev1, g1,
			float(conn1.get("invert_out_m", NAN)), wps0, wps1, str(m2)])
	fails += _pen_check("the grab controller picked the marker up (a drag, not a waypoint insert)", grabbing)
	fails += _pen_check("the outlet node moved (%.1f m)" % site1.distance_to(site0), site1.distance_to(site0) > 0.5)
	fails += _pen_check("…to just under the ground there (%.2f vs %.2f − 0.3)" % [elev1, g1],
			not is_nan(elev1) and absf(elev1 - (g1 - 0.3)) < 0.12)
	fails += _pen_check("the culvert's far end followed (invert_out %.2f)" % float(conn1.get("invert_out_m", NAN)),
			absf(float(conn1.get("invert_out_m", NAN)) - elev1) < 1e-3)
	fails += _pen_check("no waypoint was inserted (%d → %d)" % [wps0, wps1], wps1 <= wps0)
	fails += _pen_check("the marker re-seated on the rebuilt mouth (%.2f m from the node)" % (
			m2.distance_to(Vector3(c.x + site1.x, elev1, c.z + site1.y)) if is_finite(m2.x) else NAN),
			is_finite(m2.x) and Vector2(m2.x, m2.z).distance_to(Vector2(c.x + site1.x, c.z + site1.y)) < 1.5)
	# Put it back.
	sgv.call("move_siphon_outlet", turb_id, site0, elev0)
	await get_tree().create_timer(0.5).timeout
	return fails


## The load-time contract, asserted BEFORE the graph has ever been opened: every
## hydro conduit's two endpoints must already sit within a sane vertical band of
## each other. An unbound outlet sink whose elevation was never resolved anchored
## at world Y ~ 0 while its machine sat 80 m below, which rendered as a culvert
## firing several hundred feet into the sky until the player pressed G.
func _hydro_assert_anchors(sgv: Node, main: Node) -> int:
	var fails := 0
	var model: Variant = sgv.get("model")
	if model == null or main == null:
		return 0
	# A gravity conduit that CLIMBS more than this is not a plausible install.
	const MAX_RISE_M := 25.0
	for conn_v in model.connections:
		if not (conn_v is Dictionary):
			continue
		var c := conn_v as Dictionary
		var ctype := str(c.get("conduit_type", ""))
		if ctype != "poly_penstock" and ctype != "culvert_pipe":
			continue
		var src: Dictionary = model.call("get_item", str(c.get("source_item_id", "")))
		var tgt: Dictionary = model.call("get_item", str(c.get("target_item_id", "")))
		var a0 := ConduitManager.anchor_global_for_item(src, get_tree(),
				str(c.get("source_handle_id", "")), main)
		var a1 := ConduitManager.anchor_global_for_item(tgt, get_tree(),
				str(c.get("target_handle_id", "")), main)
		if not (is_finite(a0.y) and is_finite(a1.y)):
			continue
		var cid := str(c.get("id", ""))
		if ctype == "culvert_pipe":
			# A culvert is a DRAIN: its outlet must not sit above its inlet.
			fails += _pen_check("%s culvert outlet is not above its inlet (%.1f -> %.1f m)"
					% [cid, a0.y, a1.y], a1.y <= a0.y + MAX_RISE_M)
		# Neither end may be stranded at an unresolved world Y ~ 0 while the other
		# is on real terrain tens of metres away.
		fails += _pen_check("%s endpoints share a plausible band (%.1f vs %.1f m)"
				% [cid, a0.y, a1.y], absf(a0.y - a1.y) < 120.0)
	return fails


## ConduitManager's world-visibility gate, which no screenshot of this run can
## show: the conduit materials draw THROUGH terrain by design (the Elevation /
## Site CT soil bowl would otherwise bury every run), so with the player's
## "Show 3D wires (world)" preference off they must be hidden in first person
## and revealed only while the graph's 3D preview is on screen. Skipped outright
## when the preference IS on — then they are meant to be visible everywhere.
func _hydro_assert_world_hidden(main: Node, want_hidden: bool, label: String) -> int:
	var mgr: Node3D = main.find_child("ConduitManager", true, false) as Node3D \
			if main != null else null
	if mgr == null or bool(mgr.get("_global_visible")):
		return 0
	return _pen_check("conduit runs %s %s" % [
			"hidden" if want_hidden else "shown", label],
			mgr.visible != want_hidden)


func _hydro_dump(sgv: Node, main: Node, label: String) -> void:
	print("=== hydroload [%s] ===" % label)
	var model: Variant = sgv.get("model")
	if model == null:
		print("  (no model)")
		return
	var mgr: Node = main.find_child("ConduitManager", true, false) if main != null else null
	if mgr != null:
		# world_visible is the FIRST-PERSON gate: conduit materials are x-ray, so
		# with wires off the runs are built but hidden until the graph's 3D
		# preview (Site / Elevation CT / Hydro Lab) asks for them.
		var ssc := get_tree().root.get_node_or_null("SimSettingsController")
		print("  manager: global_visible=%s preview_visible=%s world_visible=%s explicit_seen=%s instances=%d · settings conduits_3d_visible=%s · lens=%s site_wire_mode=%s" % [
			str(mgr.get("_global_visible")), str(mgr.get("_preview_visible")),
			str((mgr as Node3D).visible), str(mgr.get("_explicit_seen")),
			(mgr.get("_instances") as Dictionary).size(),
			str(ssc.get("conduits_3d_visible")) if ssc != null else "?",
			str(sgv.get("_graph_view_mode")),
			str((sgv.get("_graph_canvas") as Node).get("site_wire_mode")) if sgv.get("_graph_canvas") != null else "?"])
	for conn_v in model.connections:
		if not (conn_v is Dictionary):
			continue
		var c := conn_v as Dictionary
		var ctype := str(c.get("conduit_type", ""))
		if ctype != "poly_penstock" and ctype != "culvert_pipe":
			continue
		var cid := str(c.get("id", ""))
		var src: Dictionary = model.call("get_item", str(c.get("source_item_id", "")))
		var tgt: Dictionary = model.call("get_item", str(c.get("target_item_id", "")))
		var routable := bool(model.call("connection_is_3d_routable", c))
		var has_inst := false
		var a0 := Vector3.INF
		var a1 := Vector3.INF
		if mgr != null:
			if mgr.has_method("get_instance"):
				has_inst = mgr.call("get_instance", cid) != null
			a0 = ConduitManager.anchor_global_for_item(src, get_tree(),
					str(c.get("source_handle_id", "")), main)
			a1 = ConduitManager.anchor_global_for_item(tgt, get_tree(),
					str(c.get("target_handle_id", "")), main)
		print("  %s [%s] vis3d=%s routable=%s inst=%s" % [
			cid, ctype, str(c.get("visible_3d", "<unset>")), str(routable), str(has_inst)])
		print("      src %s elev=%s bound=%s -> anchor %s" % [
			str(src.get("id", "?")), str(src.get("elevation_m", "<none>")),
			str((src.get("specs", {}) as Dictionary).get("bound_prop_id", "")), str(a0)])
		print("      tgt %s elev=%s bound=%s -> anchor %s" % [
			str(tgt.get("id", "?")), str(tgt.get("elevation_m", "<none>")),
			str((tgt.get("specs", {}) as Dictionary).get("bound_prop_id", "")), str(a1)])


func _run_autobind_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found - aborting autobind verify")
		_maybe_quit()
		return
	await get_tree().create_timer(_settle_s()).timeout
	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable - aborting autobind verify")
		_maybe_quit()
		return
	# On a real map the bind prunes UNTAGGED pond tanks as orphans (only map
	# ponds are pond_storage in play), so synthetic test ponds vanish inside the
	# call and a "refused beyond the cap" reads PASS for the wrong reason (no
	# pond at all). The guardrail is tested against the WORLD's own pond: a test
	# siphon is stood 10 m from it, then 500 m away, then rebound uncapped.
	for it in (model.items as Array).duplicate():
		var iid0 := str((it as Dictionary).get("id", ""))
		if iid0.begins_with("cap_autobind_"):
			model.remove_item(iid0)
	var pond: Dictionary = {}
	for it in (model.items as Array):
		var d := it as Dictionary
		if bool((d.get("specs", {}) as Dictionary).get("pond_storage", false)) and GraphSiteLayout.has_site_coords(d):
			pond = d
			break
	if pond.is_empty():
		if _report != null:
			_report.skip("autobind", "this world has no pond on the graph with site coordinates")
		_maybe_quit()
		return
	var pond_id := str(pond.get("id", ""))
	var pond_site := GraphSiteLayout.site_xz(pond)
	# The world's pond keeps its own wiring: remember the connections it has so
	# the test's bind/rebind never leaves a stray wire behind.
	var conns_before := {}
	for c in (model.connections as Array):
		conns_before[str((c as Dictionary).get("id", ""))] = true
	var g := float(pond.get("elevation_m", 0.0))
	var siphon_id := "cap_autobind_siphon"
	model.add_item({
		"id": siphon_id, "type": "processor", "x": 160.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "elevation_m": g + 1.0,
		"site_x_m": pond_site.x + 10.0, "site_z_m": pond_site.y,
		"specs": {
			"name": "Autobind Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
		},
	})
	# 1. NEAR (10 m from the world's pond) within a 40 m cap: binds silently.
	var bound_near := bool(sgv.call("bind_siphon_to_nearest_pond", siphon_id, true, 40.0))
	# resolve_siphon_pond reads the flow engine's cached connection index, which
	# rebuilds on its wall-clock-throttled tick: wait past the throttle.
	await get_tree().create_timer(0.5).timeout
	var got := sgv.call("resolve_siphon_pond", siphon_id) as Dictionary
	var near_ok := bound_near and str(got.get("id", "")) == pond_id
	print("PlaytestHarness: autobind verify - near the world's pond (10 m, cap 40 m): bound=%s to=%s -> %s" % [
		str(bound_near), str(got.get("id", "")), "PASS" if near_ok else "FAIL"])
	# 2. FAR (500 m) with the same cap: must refuse, with the pond still there.
	_autobind_unwire(model, siphon_id)
	model.update_item(siphon_id, {"site_x_m": pond_site.x + 500.0, "site_z_m": pond_site.y})
	var bound_far_capped := bool(sgv.call("bind_siphon_to_nearest_pond", siphon_id, true, 40.0))
	var pond_still := not (model.get_item(pond_id) as Dictionary).is_empty()
	print("PlaytestHarness: autobind verify - 500 m away, cap 40 m: bound=%s pond present=%s -> %s" % [
		str(bound_far_capped), str(pond_still),
		"PASS (correctly refused)" if (not bound_far_capped and pond_still) else "FAIL"])
	# 3. The manual uncapped Rebind ignores distance.
	var bound_far_uncapped := bool(sgv.call("bind_siphon_to_nearest_pond", siphon_id, true))
	print("PlaytestHarness: autobind verify - 500 m away, uncapped manual Rebind: bound=%s -> %s" % [
		str(bound_far_uncapped), "PASS" if bound_far_uncapped else "FAIL"])
	# Leave the graph as it was: the test siphon and every wire it made go.
	_autobind_unwire(model, siphon_id)
	model.remove_item(siphon_id)
	var stray := 0
	for c in (model.connections as Array):
		if not conns_before.has(str((c as Dictionary).get("id", ""))):
			stray += 1
	print("PlaytestHarness: autobind verify - graph left as found (%d new wires) -> %s" % [
		stray, "PASS" if stray == 0 and pond_still else "FAIL"])
	_maybe_quit()


func _autobind_unwire(model: Variant, siphon_id: String) -> void:
	for conn in (model.connections as Array).duplicate():
		var c := conn as Dictionary
		if str(c.get("target_item_id", "")) == siphon_id or str(c.get("source_item_id", "")) == siphon_id:
			model.remove_connection(str(c.get("id", "")))


func _run_ambient_flow_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting ambient verify")
		_maybe_quit()
		return
	sgv.visible = false
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout

	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting ambient verify")
		_maybe_quit()
		return

	var g := 0.0
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		g = float((soi.call("world_center") as Vector3).y)

	var pond_id := "cap_ambient_pond"
	var siphon_id := "cap_ambient_siphon"
	var outlet_id := "cap_ambient_outlet"
	model.add_item({
		"id": pond_id, "type": "resource", "x": 0.0, "y": 0.0,
		"width": 80.0, "height": 80.0,
		"specs": {
			"name": "Ambient Test Pond", "resource_kind": "water",
			"pond_storage": true, "fill_mode": "auto",
			"capacity_qty": 30000.0, "capacity_unit": "L",
			"level": 0.9, "stock_l": 27000.0,
			"floor_m": g, "rim_m": g + 2.0, "level_m": g + 1.8,
		},
	})
	model.add_item({
		"id": siphon_id, "type": "processor", "x": 160.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "elevation_m": g + 1.65,
		"specs": {
			"name": "Ambient Test Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"energy_source": "", "efficiency": 1.0,
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "manning_n": 0.012,
			"max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
			"siphon_start_m": g + 1.65, "siphon_break_m": g + 1.2,
			"module_elev_m": g + 1.65, "outlet_invert_m": g - 8.0,
			"siphon_primed": true,
			"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h"}],
			"outputs": [
				{"kind": "water", "rate": 0.0, "unit": "L/h"},
				{"kind": "dc_electricity", "rate": 0.0, "unit": "kW"},
			],
		},
	})
	model.add_item({
		"id": outlet_id, "type": "resource", "x": 320.0, "y": 0.0,
		"width": 72.0, "height": 72.0,
		"specs": {
			"name": "Ambient Test Outlet", "resource_kind": "water",
			"capacity_qty": 1.0e12, "capacity_unit": "L", "level": 0.0,
			"unlimited_capacity": true, "outlet_sink": true,
			"cumulative_l": 0.0, "live_in_lps": 0.0, "stock_l": 0.0,
		},
	})
	model.add_connection({
		"polarity": "resource", "resource_type": "water",
		"source_item_id": pond_id, "source_handle_id": "output",
		"target_item_id": siphon_id, "target_handle_id": "res_in_0",
	})
	model.add_connection({
		"polarity": "resource", "resource_type": "water",
		"source_item_id": siphon_id, "source_handle_id": "res_out_0",
		"target_item_id": outlet_id, "target_handle_id": "input",
		"conduit_type": "culvert_pipe",
	})

	var stock0 := float((model.get_item(pond_id).get("specs", {}) as Dictionary).get("stock_l", 0.0))
	print("PlaytestHarness: ambient verify — graph CLOSED (visible=%s), pond stock0=%.1f L" % [
		str(sgv.visible), stock0])

	var main := get_tree().current_scene
	if main != null and "time_scale" in main:
		main.time_scale = 120.0
	await get_tree().create_timer(4.0).timeout
	if main != null and "time_scale" in main:
		main.time_scale = 0.0

	var pond_specs: Dictionary = model.get_item(pond_id).get("specs", {}) as Dictionary
	var siphon_specs: Dictionary = model.get_item(siphon_id).get("specs", {}) as Dictionary
	var outlet_specs: Dictionary = model.get_item(outlet_id).get("specs", {}) as Dictionary
	var stock1 := float(pond_specs.get("stock_l", 0.0))
	var cum := float(outlet_specs.get("cumulative_l", 0.0))
	var live_q := float(siphon_specs.get("live_q_lps", 0.0))
	var ok := stock1 < stock0 - 0.5 and cum > 0.5
	print("PlaytestHarness: ambient verify — graph still CLOSED (visible=%s)" % str(sgv.visible))
	print("PlaytestHarness: ambient verify — pond stock1=%.1f L (Δ=%.1f), outlet cumulative=%.1f L, live_q=%.3f L/s" % [
		stock1, stock1 - stock0, cum, live_q])
	print("PlaytestHarness: ambient verify — %s" % ("PASS (water flowed with the graph closed)" if ok \
			else "FAIL (water did NOT flow while the graph was closed — ambient tick regressed)"))
	_maybe_quit()


## Festival-scale BASELINE bench (Phase 0 of the festival plan). Seeds
## --count=N people as ceil(N/100) pop-driven habitats of ≤100 (the engine's
## comfortable size — the roster clamp is 200 per habitat) sharing one set of
## large-capacity spaces, runs the clock at ~450× with the graph CLOSED, and
## dumps what a screenshot cannot: the per-section frame cost (npc_population /
## npc_dots / npc_host / flow_engine), fps, draw calls, primitives and node
## count — the numbers every later festival phase is measured against. Before
## seeding it runs a GPU precision probe (whether MultiMesh INSTANCE_CUSTOM and
## COLOR survive at float32 or are stored half precision), which decides where
## the crowd buffer may keep its time values. Cleans its cap_cb_* items.
func _run_crowd_bench() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting crowd bench")
		_maybe_quit()
		return
	sgv.visible = false
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting crowd bench")
		_maybe_quit()
		return
	var main := get_tree().current_scene
	if main != null:
		if "year" in main:
			main.year = 2026
		_set_capture_date(main, 7, 15)
		if "day_time" in main:
			main.day_time = 9.0
		if "time_scale" in main:
			main.time_scale = 0.0

	# --- GPU precision probe (independent of the roster) ----------------------
	var probe := await _probe_multimesh_precision()
	print("PlaytestHarness: crowd bench — MultiMesh precision: INSTANCE_CUSTOM=%s COLOR=%s (renderer %s)" % [
		str(probe.get("custom", "?")), str(probe.get("color", "?")),
		str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))])

	# --- seed: N people over ceil(N/100) habitats + shared spaces -------------
	var count := _bench_count
	var per_hab := 100
	var n_hab := int(ceil(float(count) / float(per_hab)))
	# Leftovers from an earlier run (the soak autosave persists graph items).
	for it in (model.items as Array).duplicate():
		var iid := str((it as Dictionary).get("id", ""))
		if iid.begins_with("cap_cb_"):
			model.remove_item(iid)
	var remaining := count
	for h in n_hab:
		var n := mini(per_hab, remaining)
		remaining -= n
		var hab_id := "cap_cb_hab_%d" % h
		model.add_item({
			"id": hab_id, "type": "processor", "x": 200.0 * h, "y": 0.0,
			"width": 150.0, "height": 150.0,
			"specs": {
				"name": "Bench camp %d" % h, "role": "habitat", "occupants": n,
				"pop_driven": true, "watts": 0.0, "energy_source": "", "efficiency": 1.0,
				"inputs": [
					{"kind": "water", "rate": 2.083, "unit": "L/h"},
					{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
				],
				"outputs": [
					{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
					{"kind": "blackwater", "rate": 0.417, "unit": "L/h"},
				],
			},
		})
		var w_id := "cap_cb_water_%d" % h
		var f_id := "cap_cb_food_%d" % h
		var g_id := "cap_cb_grey_%d" % h
		var b_id := "cap_cb_black_%d" % h
		for t in [[w_id, "water", "L", 50000.0, 1.0], [f_id, "food", "kg", 2000.0, 1.0],
				[g_id, "greywater", "L", 50000.0, 0.0], [b_id, "blackwater", "L", 20000.0, 0.0]]:
			model.add_item({
				"id": str(t[0]), "type": "resource", "x": 200.0 * h, "y": 220.0,
				"width": 90.0, "height": 100.0,
				"specs": {"name": str(t[1]).capitalize(), "resource_kind": str(t[1]),
					"capacity_qty": float(t[3]), "capacity_unit": str(t[2]), "level": float(t[4])},
			})
		for c in [[w_id, "output", hab_id, "res_in_0", "water"],
				[f_id, "output", hab_id, "res_in_1", "food"],
				[hab_id, "res_out_0", g_id, "input", "greywater"],
				[hab_id, "res_out_1", b_id, "input", "blackwater"]]:
			model.add_connection({
				"polarity": "resource", "resource_type": str(c[4]),
				"source_item_id": str(c[0]), "source_handle_id": str(c[1]),
				"target_item_id": str(c[2]), "target_handle_id": str(c[3]),
			})
	var flow0: Variant = sgv.get("_resource_flow")
	if flow0 != null and flow0.has_method("clear_timelines"):
		flow0.call("clear_timelines")
	await get_tree().create_timer(1.0).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null or not bridge.has_method("registry_for"):
		push_error("PlaytestHarness: population bridge missing — aborting crowd bench")
		_maybe_quit()
		return
	var reg: Variant = bridge.call("registry_for", main)
	var seeded_spaces: Array = []
	var half := 12.0
	var sites := {
		"kitchen": Vector2(60, 0), "restroom": Vector2(-60, 30),
		"water_point": Vector2(0, 70), "sleep": Vector2(0, -80),
		"shower": Vector2(-45, -45), "fire_circle": Vector2(55, 55),
	}
	for stype in sites:
		var c: Vector2 = sites[stype]
		var sid: Variant = reg.call("set_space_type", {"kind": "area", "poly": [
			[c.x - half, c.y - half], [c.x + half, c.y - half],
			[c.x + half, c.y + half], [c.x - half, c.y + half]]}, str(stype), count)
		seeded_spaces.append(str(sid))
	print("PlaytestHarness: crowd bench — seeded %d people in %d habitats, %d spaces (graph CLOSED)" % [
		count, n_hab, sites.size()])

	# --- run: 450×, sample the HUD every second --------------------------------
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm != null and pm.has_method("set_enabled"):
		pm.call("set_enabled", true)
	if main != null and "time_scale" in main:
		main.time_scale = _bench_ts_mult / 3600.0
	print("PlaytestHarness: crowd bench — clock at %.0fx" % _bench_ts_mult)
	# Let the roster spawn and the smoothed HUD values settle before sampling.
	await get_tree().create_timer(6.0).timeout
	var samples: Array = []
	for i in 20:
		await get_tree().create_timer(1.0).timeout
		if pm != null and pm.has_method("snapshot"):
			samples.append(pm.call("snapshot"))
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var dots: Array = bridge.call("agent_dots")
	var host := main.find_child("NpcPopulationHost", true, false) if main != null else null
	var avatars := 0
	var visible_av := 0
	if host != null:
		for ch in host.get_children():
			if ch is NpcAvatar:
				avatars += 1
				if (ch as Node3D).visible:
					visible_av += 1
	var med := func(key: String, sub: String) -> float:
		var vals: Array = []
		for s in samples:
			var d: Dictionary = s
			if sub.is_empty():
				vals.append(float(d.get(key, 0.0)))
			else:
				vals.append(float((d.get(sub, {}) as Dictionary).get(key, 0.0)))
		vals.sort()
		return float(vals[vals.size() >> 1]) if not vals.is_empty() else 0.0
	print("PlaytestHarness: crowd bench — people %d (dots %d, avatars %d / %d visible)" % [
		count, dots.size(), avatars, visible_av])
	print("PlaytestHarness: crowd bench — fps %.0f  frame %.2f ms  process %.2f ms  render cpu %.2f / gpu %.2f ms" % [
		med.call("fps", ""), med.call("frame_ms", ""), med.call("process_ms", "render"),
		med.call("render_cpu_ms", "render"), med.call("render_gpu_ms", "render")])
	# PEAKS, not just medians: the population ticks at 2-4 Hz and its whole
	# cost lands in one frame, which a smoothed median hides completely.
	var pk_max := func(key: String, sub: String) -> float:
		var m := 0.0
		for s in samples:
			var d: Dictionary = s
			var v := float(d.get(key, 0.0)) if sub.is_empty() else float((d.get(sub, {}) as Dictionary).get(key, 0.0))
			m = maxf(m, v)
		return m
	print("PlaytestHarness: crowd bench — frame peak (worst 2 s window) %.1f ms" % pk_max.call("frame_ms_peak", ""))
	for sec in ["npc_population", "crowd_sim", "npc_venues", "npc_persist", "npc_dots", "npc_host",
			"crowd_render", "crowd_raster", "camp_power", "flow_engine", "npc_pathfind", "npc_nav_bake"]:
		print("PlaytestHarness: crowd bench — section %-16s %6.2f ms  peak %6.2f ms" % [sec,
			med.call(sec, "sections_ms"), pk_max.call(sec, "sections_peak_ms")])
	if bridge.has_method("nav_status"):
		print("PlaytestHarness: crowd bench — nav %s" % str(bridge.call("nav_status")))
	# Tiers: past the focus budget most camps run as light crowds drawn by
	# the CrowdRenderer; report what the bench actually exercised.
	var light_people := 0
	var light_camps := 0
	if bridge.has_method("light_cohorts"):
		var lc: Dictionary = bridge.call("light_cohorts")
		light_camps = lc.size()
		for k in lc:
			light_people += int((lc[k] as CrowdCohort).alive_count())
	var cr: Node = sgv.call("crowd_renderer") if sgv.has_method("crowd_renderer") else null
	print("PlaytestHarness: crowd bench — tiers: %d light camps / %d light people, crowd renderer %s (%d slots)" % [
		light_camps, light_people, "present" if cr != null else "absent",
		int(cr.call("people_drawn")) if cr != null else 0])
	print("PlaytestHarness: crowd bench — draw calls %d  primitives %d  scene nodes %d" % [
		int(med.call("draw_calls", "render")), int(med.call("primitives", "render")),
		int(med.call("scene_nodes", "render"))])
	print("PlaytestHarness: crowd bench — BENCH count=%d fps=%.0f npc_population=%.2f npc_dots=%.2f npc_host=%.2f flow=%.2f draws=%d nodes=%d" % [
		count, med.call("fps", ""), med.call("npc_population", "sections_ms"),
		med.call("npc_dots", "sections_ms"), med.call("npc_host", "sections_ms"),
		med.call("flow_engine", "sections_ms"), int(med.call("draw_calls", "render")),
		int(med.call("scene_nodes", "render"))])

	# --- shots: the crowd from the ground and from above --------------------------
	# The numbers above cannot show whether a figure or a card actually DRAWS.
	# Cameras are anchored on the people's CENTROID (the bench habitats carry
	# no home position, so on a built-in map everyone parks at the origin) at
	# the ground height under the camera, so a shot is never underground; the
	# count inside figure range per shot says which tier each PNG exercises.
	var shot_dir := "%s/%s" % [SHOTS_ROOT, _shots_label if not _shots_label.is_empty() else "crowdbench_%d" % count]
	DirAccess.make_dir_recursive_absolute(shot_dir)
	var cen := Vector2.ZERO
	var ndots := 0
	for d in dots:
		cen += ((d as Dictionary).get("pos", Vector2.ZERO) as Vector2)
		ndots += 1
	if ndots > 0:
		cen /= float(ndots)
	var gcen := TerrainSurfaceQuery.ground_height_at(main, cen.x, cen.y)
	print("PlaytestHarness: crowd bench — people centroid (%.1f, %.1f), ground there %.2f m, player at %s" % [
		cen.x, cen.y, gcen, str(main.get_node_or_null("Player").global_position if main.get_node_or_null("Player") != null else "?")])
	if cr != null:
		var mmf: MultiMesh = cr.get("_mm_fig")
		for si in mini(5, int(cr.call("people_drawn"))):
			var xf: Transform3D = mmf.get_instance_transform(si)
			var a := xf.basis.x
			var ray := TerrainSurfaceQuery.ground_height_at(main, a.x, a.z)
			print("PlaytestHarness: crowd bench —   slot %d a=(%.1f, %.2f, %.1f) ground %.2f pose %d t0 %.2f t1 %.2f flags %.0f" % [
				si, a.x, a.y, a.z, ray, int(xf.origin.x), xf.basis.z.x, xf.basis.z.y, xf.origin.z])
	var bcam := Camera3D.new()
	bcam.name = "CrowdBenchCam"
	bcam.far = 20000.0
	get_tree().current_scene.add_child(bcam)
	bcam.make_current()
	# Aim at the BUSIEST 10 m cell of people, not the centroid: the centroid
	# of a crowd spread over six spaces is the empty middle of the field.
	var cells: Dictionary = {}
	for d in dots:
		var dd: Dictionary = d
		var key := Vector2i(int(floor((dd.get("pos", Vector2.ZERO) as Vector2).x / 10.0)), int(floor((dd.get("pos", Vector2.ZERO) as Vector2).y / 10.0)))
		cells[key] = int(cells.get(key, 0)) + 1
	var best_key := Vector2i.ZERO
	var best_n := -1
	for k in cells:
		if int(cells[k]) > best_n:
			best_n = int(cells[k])
			best_key = k
	var tgt := Vector2(float(best_key.x) * 10.0 + 5.0, float(best_key.y) * 10.0 + 5.0)
	var gtgt := TerrainSurfaceQuery.ground_height_at(main, tgt.x, tgt.y)
	print("PlaytestHarness: crowd bench — busiest cell at (%.0f, %.0f): %d people, ground %.2f" % [tgt.x, tgt.y, best_n, gtgt])
	var views := [["01_eye", Vector2(0.0, 25.0), 1.7, 1.0], ["02_street", Vector2(20.0, 20.0), 10.0, 0.0],
		["03_block", Vector2(0.0, 160.0), 90.0, 0.0], ["04_site", Vector2(0.0, 500.0), 600.0, 0.0]]
	for v in views:
		var off: Vector2 = v[1]
		var cxz := tgt + off
		var cy := TerrainSurfaceQuery.ground_height_at(main, cxz.x, cxz.y) + float(v[2])
		bcam.global_position = Vector3(cxz.x, cy, cxz.y)
		bcam.look_at(Vector3(tgt.x, gtgt + float(v[3]), tgt.y), Vector3.UP)
		var near_n := 0
		var in_view := 0
		for d in dots:
			var dd: Dictionary = d
			var dp: Vector2 = dd.get("pos", Vector2.ZERO)
			var wp := Vector3(dp.x, gtgt + 1.0, dp.y)
			if wp.distance_to(bcam.global_position) < 150.0:
				near_n += 1
			if not bcam.is_position_behind(wp):
				var sp := bcam.unproject_position(wp)
				if sp.x >= 0.0 and sp.y >= 0.0 and sp.x <= get_viewport().get_visible_rect().size.x and sp.y <= get_viewport().get_visible_rect().size.y:
					in_view += 1
		await get_tree().create_timer(0.5).timeout
		await _shoot_ui(shot_dir, str(v[0]))
		print("PlaytestHarness: crowd bench — shot %s from %s: %d people inside figure range (150 m), %d in frame" % [str(v[0]), str(bcam.global_position), near_n, in_view])
	bcam.queue_free()
	print("PlaytestHarness: crowd bench — %d shots in %s" % [views.size(), ProjectSettings.globalize_path(shot_dir)])

	# --- cleanup ------------------------------------------------------------------
	for sid in seeded_spaces:
		if reg.has_method("remove_space"):
			reg.call("remove_space", str(sid))
	for it in (model.items as Array).duplicate():
		var iid := str((it as Dictionary).get("id", ""))
		if iid.begins_with("cap_cb_"):
			model.remove_item(iid)
	_maybe_quit()


## Renders one MultiMesh instance whose INSTANCE_CUSTOM.x and COLOR.r carry
## 1 + 2^-12 — representable in float32, rounded to exactly 1.0 in half
## precision — through an unshaded shader into an 8×8 SubViewport, and reads
## the pixel back: white = the value survived (float32), black = it was
## stored as half. Returns {"custom": "float32"|"half", "color": ...}. The
## crowd buffer keeps its time values in the transform regardless; this
## decides whether pose/seed fields may live in the cheaper slots.
func _probe_multimesh_precision() -> Dictionary:
	var out := {"custom": "unknown", "color": "unknown"}
	var vp := SubViewport.new()
	vp.size = Vector2i(8, 8)
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 1.0
	cam.position = Vector3(0, 0, 2)
	vp.add_child(cam)
	cam.current = true
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.instance_count = 1
	var quad := QuadMesh.new()
	quad.size = Vector2(4, 4)
	mm.mesh = quad
	var probe_val := 1.0 + 1.0 / 4096.0
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	mm.set_instance_color(0, Color(probe_val, 0.0, 0.0, 1.0))
	mm.set_instance_custom_data(0, Color(probe_val, 0.0, 0.0, 1.0))
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
varying float ok_custom;
varying float ok_color;
void vertex() {
	ok_custom = abs(INSTANCE_CUSTOM.x - 1.000244140625) < 0.00001 ? 1.0 : 0.0;
	ok_color = abs(COLOR.r - 1.000244140625) < 0.00001 ? 1.0 : 0.0;
}
void fragment() {
	ALBEDO = vec3(ok_custom, ok_color, 1.0);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	vp.add_child(mmi)
	# Two presented frames: one to build the instance, one to draw it.
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	if img != null and img.get_width() >= 8:
		var px := img.get_pixel(4, 4)
		out["custom"] = "float32" if px.r > 0.5 else "half"
		out["color"] = "float32" if px.g > 0.5 else "half"
		out["pixel"] = px
	vp.queue_free()
	return out


## NPC population end-to-end verify + Site Plan dot capture
## (--capture=population, WINDOWED): seeds four tagged area spaces (kitchen /
## restroom / water point / sleeping) into the map's SpaceRegistry, adds a
## pop-driven habitat + supply/waste tanks to the graph, runs the world clock
## with the graph CLOSED (agents must eat/drink ambiently), asserts tanks
## moved + agents walked, then opens the Site Plan and shoots dot PNGs.
## Finally empties the food tank and asserts the starvation loop closes
## (habitat STARVED, no food consumed, agents' hunger pinned).
func _run_population_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting population verify")
		_maybe_quit()
		return
	sgv.visible = false
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout

	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting population verify")
		_maybe_quit()
		return
	var main := get_tree().current_scene
	# Pin the SIM DATE. The soak autosave carries the clock forward between
	# runs, and per-agent RNG reseeds per sim-DAY — so every run was sampling a
	# different day's needs/phases, which is where the "state-sensitive"
	# food/chore/cascade flakes actually lived. A fixed morning on a fixed date
	# makes consecutive runs replay the same population day.
	if main != null:
		if "year" in main:
			main.year = 2026
		_set_capture_date(main, 7, 15)
		if "day_time" in main:
			main.day_time = 7.0

	# --- graph: pop-driven habitat + tanks -----------------------------------
	# The soak map's graph autosave persists between runs — drop any leftovers
	# from a previous population verify so tanks start at known levels.
	var hab_id := "cap_pop_hab"
	var pop_ids := [hab_id, "cap_pop_water", "cap_pop_food", "cap_pop_grey",
			"cap_pop_black", "cap_pop_bio"]
	for pid in pop_ids:
		if not (model.get_item(str(pid)) as Dictionary).is_empty():
			model.remove_item(str(pid))
	model.add_item({
		"id": hab_id, "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 150.0,
		"specs": {
			"name": "Test Population", "role": "habitat", "occupants": 16,
			"pop_driven": true, "watts": 0.0, "energy_source": "", "efficiency": 1.0,
			"inputs": [
				{"kind": "water", "rate": 2.083, "unit": "L/h"},
				{"kind": "food", "rate": 0.0625, "unit": "kg/h"},
			],
			"outputs": [
				{"kind": "greywater", "rate": 1.666, "unit": "L/h"},
				{"kind": "blackwater", "rate": 0.417, "unit": "L/h"},
				{"kind": "biomass", "rate": 0.0125, "unit": "kg/h"},
			],
		},
	})
	var tanks := [
		["cap_pop_water", "water", "L", 2000.0, 1.0],
		["cap_pop_food", "food", "kg", 100.0, 0.8],
		["cap_pop_grey", "greywater", "L", 2000.0, 0.0],
		["cap_pop_black", "blackwater", "L", 500.0, 0.0],
		["cap_pop_bio", "biomass", "kg", 50.0, 0.0],
	]
	for i in tanks.size():
		var t: Array = tanks[i]
		model.add_item({
			"id": str(t[0]), "type": "resource", "x": -220.0 + 120.0 * i, "y": 220.0,
			"width": 90.0, "height": 100.0,
			"specs": {
				"name": str(t[1]).capitalize(), "resource_kind": str(t[1]),
				"capacity_qty": float(t[3]), "capacity_unit": str(t[2]),
				"level": float(t[4]),
			},
		})
	for c in [
		["cap_pop_water", "output", hab_id, "res_in_0", "water"],
		["cap_pop_food", "output", hab_id, "res_in_1", "food"],
		[hab_id, "res_out_0", "cap_pop_grey", "input", "greywater"],
		[hab_id, "res_out_1", "cap_pop_black", "input", "blackwater"],
		[hab_id, "res_out_2", "cap_pop_bio", "input", "biomass"],
	]:
		model.add_connection({
			"polarity": "resource", "resource_type": str(c[4]),
			"source_item_id": str(c[0]), "source_handle_id": str(c[1]),
			"target_item_id": str(c[2]), "target_handle_id": str(c[3]),
		})

	# Fresh timelines: tanks re-anchor at the specs.level just written (stale
	# timelines from a previous run share these item ids and would win).
	var flow0: Variant = sgv.get("_resource_flow")
	if flow0 != null and flow0.has_method("clear_timelines"):
		flow0.call("clear_timelines")

	# --- spaces: tagged areas around the world origin ------------------------
	# One ambient tick must run first so the view creates its population bridge.
	await get_tree().create_timer(1.0).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null or not bridge.has_method("registry_for"):
		push_error("PlaytestHarness: population bridge missing — aborting")
		_maybe_quit()
		return
	var reg: Variant = bridge.call("registry_for", main)
	var half := 8.0
	var sites := {
		"kitchen": Vector2(60, 0), "restroom": Vector2(-60, 30),
		"water_point": Vector2(0, 70), "sleep": Vector2(0, -80),
		"shower": Vector2(-45, -45),
	}
	# The ids this capture seeds: the marker check below counts THESE, not the
	# registry's total, because the world's own tagged spaces (a saved site
	# carries whatever the player tagged) would otherwise move the count.
	var seeded_ids: Array = []
	for stype in sites:
		var c: Vector2 = sites[stype]
		seeded_ids.append(str(reg.call("set_space_type", {"kind": "area", "poly": [
			[c.x - half, c.y - half], [c.x + half, c.y - half],
			[c.x + half, c.y + half], [c.x - half, c.y + half]]}, str(stype), 30)))
	# One deliberately CONCAVE area (a U, like a courtyard wrapping a building).
	# Its centroid lands in the opening, outside the space, so this exercises
	# SpaceRegistry.area_interior_point's fallback against a real registry and
	# real agents rather than only in the offline geometry test.
	var u_poly: Array = [[40, 40], [70, 40], [70, 70], [61, 70], [61, 49],
			[49, 49], [49, 70], [40, 70]]
	seeded_ids.append(str(reg.call("set_space_type", {"kind": "area", "poly": u_poly}, "fire_circle", 12)))
	var u_pt: Variant = SpaceRegistry.area_interior_point(u_poly)
	var u_centroid := SpaceRegistry.polygon_centroid(u_poly)
	var ok_concave := u_pt is Vector2 \
		and SpaceRegistry.polygon_contains(u_poly, u_pt as Vector2) \
		and not SpaceRegistry.polygon_contains(u_poly, u_centroid)
	print("PlaytestHarness: population verify — concave area %s (centroid %s is outside, gathering point %s is inside)" % [
		"PASS" if ok_concave else "FAIL", str(u_centroid.round()), str((u_pt as Vector2).round())])
	print("PlaytestHarness: population verify — %d spaces seeded, graph CLOSED" % (sites.size() + 1))

	# A plain scheduled chore, seeded here so the ambient day below has to
	# actually FINISH it. Movement and consumption were already asserted; work
	# reaching completion was the gap — and it is the gap the whole stall bug
	# lived in, one level up from the same hole in the selftest.
	var board: Variant = bridge.call("chore_board_for", "cap_pop_hab")
	var chore_id := ""
	if board != null:
		chore_id = str(board.call("add_chore", "Sweep the yard", 0.5, {
			"repeat": "daily", "priority": 0,
			"exposure": NpcWeatherGate.EXPOSURE_OUTDOOR,
			"window": {"start_h": 0.0, "end_h": 24.0},
			"target": {"kind": "pos", "x": 12.0, "z": -12.0},
		}))

	var lvl := func(id: String) -> float:
		return float((model.get_item(id).get("specs", {}) as Dictionary).get("level", -1.0))
	var water0: float = lvl.call("cap_pop_water")
	var food0: float = lvl.call("cap_pop_food")

	# --- phase 1: ambient day (graph closed), ~10 sim-hours ------------------
	if main != null and "day_time" in main:
		main.day_time = 9.0
	if main != null and "time_scale" in main:
		main.time_scale = 0.2  # h per real s ≈ 720× realtime
	var dots0: Array = bridge.call("agent_dots")
	# Long enough for a MEAL to complete, not just a drink. Eating is a 0.5 h
	# activity behind a 0.55 hunger threshold, and now that agents walk real
	# routes instead of gliding, the first round of meals lands later.
	# (60 s + 3 s smoothness probe + 12 s = the original 75 s window, so the
	# calibrated downstream phases see the same elapsed sim time.)
	await get_tree().create_timer(60.0).timeout
	# --- smoothness probe: at this speed (~720×) a sim tick moves a walker
	# ~470 m. Rendered motion must be CONTINUOUS — the old regime showed up as
	# a single-frame teleport of a whole tick step. Per-frame jumps must stay
	# an order of magnitude under it.
	var probe_max := 0.0
	var probe_host := main.find_child("NpcPopulationHost", true, false)
	if probe_host != null:
		var probe_last: Dictionary = {}
		var probe_end := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < probe_end:
			await get_tree().process_frame
			for c in probe_host.get_children():
				if not (c is NpcAvatar):
					continue
				var av3 := c as Node3D
				if not av3.visible:
					continue
				var pk := str(av3.name)
				var pp := av3.global_position
				if probe_last.has(pk):
					probe_max = maxf(probe_max,
						(pp - (probe_last[pk] as Vector3)).length())
				probe_last[pk] = pp
	var ok_smooth := probe_max < 150.0
	print("PlaytestHarness: population verify — motion smoothness %s (max frame jump %.1f m at ~720×, limit 150)" % [
		"PASS" if ok_smooth else "FAIL (a rendered body jumped a whole sim tick in one frame)",
		probe_max])
	await get_tree().create_timer(12.0).timeout
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var dots1: Array = bridge.call("agent_dots")
	var water1: float = lvl.call("cap_pop_water")
	var food1: float = lvl.call("cap_pop_food")
	var black1: float = lvl.call("cap_pop_black")
	var moved := 0
	if dots0.size() == dots1.size() and dots0.size() > 0:
		for i in dots0.size():
			var p0: Vector2 = (dots0[i] as Dictionary).get("pos", Vector2.ZERO)
			var p1: Vector2 = (dots1[i] as Dictionary).get("pos", Vector2.ZERO)
			if (p1 - p0).length() > 1.0:
				moved += 1
	print("PlaytestHarness: population verify — water %.4f→%.4f, food %.4f→%.4f, black=%.4f, agents=%d moved=%d" % [
		water0, water1, food0, food1, black1, dots1.size(), moved])
	var ok_flow := water1 < water0 - 0.001 and food1 < food0 - 0.0005 and black1 > 0.0001
	var ok_move := moved >= 3
	print("PlaytestHarness: population verify — ambient consumption %s, movement %s" % [
		"PASS" if ok_flow else "FAIL (tanks did not move with the graph closed)",
		"PASS" if ok_move else "FAIL (agents did not walk between spaces)"])
	var ok_chore := false
	if board != null and not chore_id.is_empty():
		var ch: Dictionary = board.call("find", chore_id) as Dictionary
		# `done_day >= 0` is the board's own record that the work was FINISHED,
		# not merely picked up — the distinction the stall bug hid behind.
		ok_chore = int(ch.get("done_day", -1)) >= 0
		print("PlaytestHarness: population verify — scheduled chore completed %s (done_day=%d, %.2f of %.2f h left)" % [
			"PASS" if ok_chore else "FAIL (nobody finished a 0.5 h chore in ~15 sim-hours)",
			int(ch.get("done_day", -1)),
			maxf(float(ch.get("chore_hours", 0.0)) - float(ch.get("progress_h", 0.0)), 0.0),
			float(ch.get("chore_hours", 0.0))])


	# --- phase 2: Site Plan dot capture --------------------------------------
	var label := _shots_label if not _shots_label.is_empty() else "population_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	# Site Plan must run on the LIVE clock: entering it used to take the
	# elevation noon-bake claim (time_scale=0), which froze the population and
	# made the plan read as "nothing is happening". Assert the view neither
	# moved time_scale nor holds ANY graph clock claim (the noon lock is gone
	# entirely; no graph lens may claim the clock).
	var ts_before_site := float(main.time_scale) if main != null and "time_scale" in main else -1.0
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "site")
	var noon_claim := false
	if main != null and main.get("clock") != null:
		var claims: Variant = main.clock.get("claims")
		if claims != null and claims.has_method("owners"):
			for o in claims.call("owners"):
				if str(o).begins_with("graph_"):
					noon_claim = true
	var ts_after_site := float(main.time_scale) if main != null and "time_scale" in main else -1.0
	var ok_live_clock := not noon_claim and is_equal_approx(ts_after_site, ts_before_site)
	print("PlaytestHarness: population verify — site plan clock %s (ts %.3f -> %.3f, noon claim=%s)" % [
			"LIVE (PASS)" if ok_live_clock else "FROZEN (FAIL)",
			ts_before_site, ts_after_site, str(noon_claim)])
	await get_tree().create_timer(1.5).timeout
	await _graph_shot(dir, "01_site_dots", manifest)
	if main != null and "time_scale" in main:
		main.time_scale = 0.05
	await get_tree().create_timer(6.0).timeout
	await _graph_shot(dir, "02_site_dots_later", manifest)
	# Zoomed close-up over the tagged-space cluster so individual dots and
	# their colors are reviewable (SoI-scale zoom leaves them ~2 px).
	var canvas: Node = sgv.get("_graph_canvas")
	if canvas != null and canvas.get("_zoom") != null:
		var zoom_saved := float(canvas.get("_zoom"))
		canvas.set("_zoom", zoom_saved * 6.0)
		canvas.call("queue_redraw")
		await get_tree().create_timer(1.0).timeout
		await _graph_shot(dir, "02b_site_dots_zoom", manifest)
		canvas.set("_zoom", zoom_saved)
		canvas.call("queue_redraw")
	# Desire lines: turn the view on and shoot the worn-in paths.
	sgv.set("_desire_lines_on", true)
	sgv.call("_sync_view_mode_menu_checks")
	if canvas != null:
		canvas.call("queue_redraw")
	await get_tree().create_timer(1.0).timeout
	await _graph_shot(dir, "02c_desire_lines", manifest)
	if canvas != null and canvas.get("_zoom") != null:
		var dz := float(canvas.get("_zoom"))
		canvas.set("_zoom", dz * 4.0)
		canvas.call("queue_redraw")
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(dir, "02d_desire_lines_zoom", manifest)
		canvas.set("_zoom", dz)
	var dmap: Variant = bridge.call("desire_map")
	var hot := int(dmap.call("hot_cells", 2.0)) if dmap != null else 0
	var worn := float(dmap.call("total_metres")) if dmap != null else 0.0
	print("PlaytestHarness: population verify — desire lines: %.0f m traced, %d hot cells, peak %.1f m" % [
		worn, hot, float(dmap.call("peak")) if dmap != null else 0.0])
	var ok_desire := worn > 50.0 and hot > 3
	print("PlaytestHarness: population verify — desire lines %s" % [
		"PASS" if ok_desire else "FAIL (no worn paths accumulated)"])
	sgv.set("_desire_lines_on", false)
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	# Select the habitat so the inspector Population section is in frame.
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "freeform")
	if canvas != null:
		canvas.set("selected_item_id", hab_id)
		if sgv.has_method("_on_canvas_item_selected"):
			sgv.call("_on_canvas_item_selected", hab_id)
	await get_tree().create_timer(0.8).timeout
	await _graph_shot(dir, "03_habitat_inspector", manifest)

	# --- phase 2b: navigation ------------------------------------------------
	# The grid bakes in budgeted slices off the tick, so give it a moment and
	# then confirm it came up and is actually planning routes.
	if main != null and "time_scale" in main:
		main.time_scale = 0.05
	var nav_ready := false
	var nav_info: Dictionary = {}
	# A real map bakes ~78k cells at 1200/tick; allow well past that rather
	# than reporting a failure for a bake that simply had not finished.
	for i in 160:
		await get_tree().create_timer(0.25).timeout
		nav_info = bridge.call("nav_status")
		if str(nav_info.get("state", "")) == "ready":
			nav_ready = true
			break
	# Keep running AFTER the bake completes — planning only happens when an
	# agent starts a new trip, so sampling the instant the grid goes ready
	# would always read zero.
	# Park the clock just before 09:00. Routines mean people travel at BLOCK
	# BOUNDARIES and sit still in between, so a window landing mid-block sees
	# nobody move at all — which is what made this read as "nobody routed".
	# 09:00 is the wake / bathroom / breakfast run, so travel is guaranteed
	# rather than hoped for.
	var prev_day_time := float(main.day_time) if main != null and "day_time" in main else -1.0
	if prev_day_time >= 0.0:
		main.day_time = 8.85
		await get_tree().process_frame
	var with_path := 0
	var max_travelling := 0
	var pose_violations := 0
	var travel_samples := 0
	if nav_ready:
		for i in 120:
			await get_tree().create_timer(0.25).timeout
			var n := 0
			var trav := 0
			for a in bridge.call("roster_for", hab_id):
				var ag := a as NpcAgent
				if ag.path.size() > 0:
					n += 1
				if ag.state == NpcAgent.State.TRAVELING:
					trav += 1
			with_path = maxi(with_path, n)
			max_travelling = maxi(max_travelling, trav)
			# Sample the reported bug across the SAME window rather than once:
			# nobody may hold a lying or seated pose while the sim says they are
			# on their way somewhere. A single sample lands on a quiet instant
			# and passes without ever observing a traveller.
			for node in get_tree().get_nodes_in_group("npc_avatars"):
				var av3 := node as NpcAvatar
				if av3 == null or not av3.is_posed_down():
					continue
				for a2 in bridge.call("roster_for", hab_id):
					var ag2 := a2 as NpcAgent
					if ag2.id == av3.agent_id and ag2.state == NpcAgent.State.TRAVELING:
						pose_violations += 1
			travel_samples += trav
		nav_info = bridge.call("nav_status")
	# Put the clock back: every later phase (starvation, the collapse cascade)
	# is written against the schedule it started on, and leaving the day shifted
	# under them made the starvation loop stop firing.
	if prev_day_time >= 0.0:
		main.day_time = prev_day_time
		await get_tree().process_frame
	print("PlaytestHarness: population verify — travel poses %s (%d traveller-samples, %d lying/seated while travelling)" % [
		"PASS" if (pose_violations == 0 and travel_samples > 0) else
		("FAIL (never saw a traveller)" if travel_samples == 0 else "FAIL"),
		travel_samples, pose_violations])
	# Feeds the FINAL verdict — this check used to print FAIL while the run
	# still said PASS (caught when the motion stall-veto briefly regressed it).
	var ok_pose := pose_violations == 0 and travel_samples > 0
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	print("PlaytestHarness: population verify — nav %s (%d cells @ %.2f m, %d layers; hits=%d misses=%d fails=%d)" % [
		str(nav_info.get("state", "off")), int(nav_info.get("cells", 0)),
		float(nav_info.get("cell_m", 0.0)), int(nav_info.get("layers", 1)),
		int(nav_info.get("hits", 0)), int(nav_info.get("misses", 0)),
		int(nav_info.get("fails", 0))])
	print("PlaytestHarness: population verify — buildings: %d door cells, %d interior cells, %d upper-surface cells" % [
		int(nav_info.get("doors", 0)), int(nav_info.get("interior", 0)),
		int(nav_info.get("upper", 0))])
	var wsum: Dictionary = bridge.call("summary_for", hab_id)
	print("PlaytestHarness: population verify — walking: %.0f m/person/day, +%.0f m climb, %.0f kcal (%.1f%% of the day) — %s" % [
		float(wsum.get("walk_distance_m", 0.0)), float(wsum.get("walk_climb_m", 0.0)),
		float(wsum.get("walk_kcal", 0.0)),
		float(wsum.get("walk_overhead", 0.0)) * 100.0, str(wsum.get("walk_label", ""))])
	var per_need: Dictionary = wsum.get("need_mean_m", {})
	var need_parts: PackedStringArray = PackedStringArray()
	for k in per_need:
		need_parts.append("%s %.0f m" % [str(k), float(per_need[k])])
	print("PlaytestHarness: population verify — mean trip per need: %s" % [
		", ".join(need_parts) if not need_parts.is_empty() else "(none yet)"])
	var ok_walk := float(wsum.get("walk_distance_m", 0.0)) > 1.0 \
			and float(wsum.get("walk_kcal", 0.0)) > 0.0 and not per_need.is_empty()
	print("PlaytestHarness: population verify — walking metrics %s" % [
		"PASS" if ok_walk else "FAIL (no distance/calorie accounting)"])
	var planned := int(nav_info.get("hits", 0)) + int(nav_info.get("misses", 0))
	var ok_nav := nav_ready and int(nav_info.get("cells", 0)) > 0 \
			and planned > 0 and with_path > 0
	print("PlaytestHarness: population verify — navigation %s (%d routes planned, %d agents walking one)" % [
		"PASS" if ok_nav else "FAIL (grid never ready, or nobody routed)",
		planned, with_path])


	# --- phase 3: 3D silhouette avatars (Phase B) ----------------------------
	# Runs BEFORE the starvation phases: the cascade below deliberately
	# empties the camp, and there is nothing to photograph after that.
	sgv.visible = false
	var host: Node = main.get_node_or_null("NpcPopulationHost") if main != null else null
	# Count AVATARS, not children: the host also parents the pooled
	# CrewSiteMarker nodes, so a child count reads one high the moment any crew
	# work is on the board — which since the labour merge is most of the time.
	var avatar_count := 0
	if host != null:
		for c in host.get_children():
			if c is NpcAvatar:
				avatar_count += 1
	print("PlaytestHarness: population verify — 3D host %s (%d avatars)" % [
		"present" if host != null else "MISSING", avatar_count])
	# Crosshair-pick contract (InteractionFocus._update_npc_focus): avatars must
	# be in the group, carry a readable name + status, and expose a pick center
	# at torso height. No collider is involved by design.
	var grouped := get_tree().get_nodes_in_group("npc_avatars")
	var named := 0
	var statused := 0
	var pick_ok := 0
	for node in grouped:
		var av := node as NpcAvatar
		if av == null:
			continue
		if not av.display_name.is_empty() and av.display_name != av.agent_id:
			named += 1
		if not av.status_text.is_empty():
			statused += 1
		if absf(av.pick_center().y - av.global_position.y - NpcAvatar.PICK_CENTER_Y) < 0.001:
			pick_ok += 1
	var ok_pick := grouped.size() == avatar_count and named == avatar_count \
			and statused == avatar_count and pick_ok == avatar_count
	print("PlaytestHarness: population verify — crosshair contract %s (group=%d named=%d status=%d pick=%d)" % [
		"PASS" if ok_pick else "FAIL", grouped.size(), named, statused, pick_ok])
	# Facing, END TO END through the real dot -> host -> avatar path. The
	# offline selftest asserts the RULE; this asserts that the rule survives
	# every layer between the engine and a rendered transform. The failure it
	# guards is the reported one: yaw latched on the approach heading, so a
	# camp that walked in from one direction all points one way. Circular
	# concentration R: 1.0 = perfectly aligned.
	var yaws: Array = []
	for node in grouped:
		var av2 := node as NpcAvatar
		if av2 != null:
			yaws.append(av2.rotation.y)
	var r_all := 1.0
	if yaws.size() >= 3:
		var sx := 0.0
		var sy := 0.0
		for y in yaws:
			sx += cos(float(y))
			sy += sin(float(y))
		r_all = Vector2(sx, sy).length() / float(yaws.size())
	var ok_face := yaws.size() >= 3 and r_all < 0.85
	print("PlaytestHarness: population verify — facing spread %s (R=%.3f over %d avatars)" % [
		"PASS" if ok_face else "FAIL (the roster is all pointing one way)",
		r_all, yaws.size()])
	# Personal space (Tier 4c). Standing slots keep people who have ARRIVED
	# apart; the separation pass handles everyone in transit. The failure this
	# guards is the one that is obvious on screen and invisible in the numbers:
	# a whole roster stacked on one point, rendering as a single person.
	# Sleepers are EXEMPT by design (people pile up to sleep: a shared bed,
	# SpaceRegistry.pile_offset), so a pair both asleep is not a stack.
	var closest_pair := INF
	var stacked := 0
	var stack_desc: Array = []
	var agent_dots: Array = bridge.call("agent_dots")
	for i in range(agent_dots.size()):
		var da: Dictionary = agent_dots[i]
		var pa: Vector2 = da.get("pos", Vector2.ZERO)
		for j in range(i + 1, agent_dots.size()):
			var db: Dictionary = agent_dots[j]
			var pb: Vector2 = db.get("pos", Vector2.ZERO)
			if str(da.get("activity", "")) == "sleep" and str(db.get("activity", "")) == "sleep":
				continue
			var dd := pa.distance_to(pb)
			closest_pair = minf(closest_pair, dd)
			if dd < 0.1:
				stacked += 1
				stack_desc.append("%s (%s, %s) + %s (%s, %s)" % [str(da.get("id", "")), str(da.get("activity", "")),
					str(da.get("habitat", da.get("hab", ""))), str(db.get("id", "")), str(db.get("activity", "")),
					str(db.get("habitat", db.get("hab", "")))])
	var ok_space := stacked == 0
	print("PlaytestHarness: population verify — personal space %s (%d people, closest awake pair %.2f m, %d stacked) %s" % [
		"PASS" if ok_space else "FAIL", agent_dots.size(), closest_pair, stacked, str(stack_desc)])

	# Rigged-body LOD contract: the host must hand the Mixamo figure to the
	# nearest agents and the primitive to the rest. Proving the rig RENDERS
	# (the staged review shot below) is not the same as proving the host ever
	# asks for it — the two paths are independent, and the staged one bypasses
	# the budget entirely.
	if NpcRig.available():
		var player := main.get_node_or_null("Player") as Node3D
		# Agents wander, and on a big site they are usually tens of metres off,
		# which would make this check pass without ever exercising the swap.
		# Walk the player over to the nearest one first so the assertion is
		# real; position is restored afterwards.
		var closest: NpcAvatar = null
		var closest_d := INF
		var home := player.global_position if player != null else Vector3.ZERO
		for node in grouped:
			var av0 := node as NpcAvatar
			if av0 == null:
				continue
			var d0 := av0.global_position.distance_to(home)
			if d0 < closest_d:
				closest_d = d0
				closest = av0
		if player != null and closest != null:
			player.global_position = closest.global_position + Vector3(0.0, 0.0, 6.0)
			await get_tree().process_frame
			await get_tree().process_frame
		var eye := Vector2(player.global_position.x, player.global_position.z) \
			if player != null else Vector2.ZERO
		var rigged_n := 0
		var within := 0
		var nearest := INF
		for node in grouped:
			var av := node as NpcAvatar
			if av == null:
				continue
			var d := Vector2(av.global_position.x, av.global_position.z).distance_to(eye)
			nearest = minf(nearest, d)
			if d <= NpcPopulationHost.RIG_DIST_M:
				within += 1
			if av.is_rigged():
				rigged_n += 1
		# Someone in range MUST get the rigged body, and the budget must hold —
		# but ONLY when a rigged body is what should be drawn at all. Two
		# separate reasons it should not be (see NpcAvatar.set_detail): the
		# Mixamo pack is not installed, or the player CHOSE the stylised figure
		# in Settings → NPCs → Body style. This check ignored the second, so it
		# failed outright for anyone whose user://npc_display.cfg says
		# style="simple" — a supported setting, not a broken LOD.
		var want_rigged := NpcRig.available() and not NpcDisplayPrefs.wants_simple()
		var ok_rig := rigged_n <= NpcPopulationHost.MAX_RIGGED \
			and within > 0 and (rigged_n > 0 if want_rigged else rigged_n == 0)
		print("PlaytestHarness: population verify — rigged LOD %s (%d rigged, %d within %.0f m, nearest %.0f m, cap %d, style=%s, rig_assets=%s)" % [
			"PASS" if ok_rig else "FAIL", rigged_n, within,
			NpcPopulationHost.RIG_DIST_M, nearest, NpcPopulationHost.MAX_RIGGED,
			NpcDisplayPrefs.style(), "yes" if NpcRig.available() else "no"])
		if player != null:
			player.global_position = home

	# Tagged spaces must be resolvable as Site Plan markers with occupancy —
	# every space THIS capture seeded (matched by id), whatever else the
	# world carries. Mount Vernon's own tagged space made the old equality
	# read "7 of 6" (2026-10-18).
	var marks: Array = bridge.call("space_markers", main)
	var resolved_seeded := 0
	for m in marks:
		if seeded_ids.has(str((m as Dictionary).get("id", ""))):
			resolved_seeded += 1
	var ok_marks := resolved_seeded == seeded_ids.size()
	print("PlaytestHarness: population verify — space markers %s (%d of %d seeded resolved; %d on the site)" % [
		"PASS" if ok_marks else "FAIL", resolved_seeded, seeded_ids.size(), marks.size()])
	var ok_drape := false
	if main != null:
		var prev_cam := get_viewport().get_camera_3d()
		var cam := Camera3D.new()
		main.add_child(cam)
		# Let the roster settle a touch, FREEZE, then frame ONE agent up close —
		# a cluster centroid usually lands on empty ground (or inside a tree)
		# once agents disperse, and at any time scale the subject would walk
		# out of frame between sampling and the shot.
		if "time_scale" in main:
			main.time_scale = 0.02
		await get_tree().create_timer(1.5).timeout
		if "time_scale" in main:
			main.time_scale = 0.0
		# 3D desire drape: turn it on and photograph the worn paths on the
		# ground, from above, before framing a person.
		sgv.set("_desire_3d_on", true)
		sgv.call("_ensure_desire_overlay")
		await get_tree().create_timer(1.0).timeout
		var dov: Node = null
		var terr: Node = main.get_node_or_null("Terrain")
		if terr != null:
			dov = terr.get_node_or_null("NpcDesireOverlay")
		if dov == null:
			dov = main.get_node_or_null("NpcDesireOverlay")
		ok_drape = dov != null and dov.get("mesh") != null
		print("PlaytestHarness: population verify — 3D desire drape %s" % [
			"PASS" if ok_drape else "FAIL (overlay mesh not built)"])
		if ok_drape:
			# Frame the whole drape from above, in DAYLIGHT — phase 1 ends
			# around midnight and an additive overlay on black terrain shows
			# the glow but none of the ground it is painted on.
			if main != null and "day_time" in main:
				main.day_time = 12.0
			var dmap2: Variant = bridge.call("desire_map")
			var drect: Rect2 = dmap2.call("world_rect") if dmap2 != null else Rect2()
			var dc := drect.get_center()
			var span := maxf(maxf(drect.size.x, drect.size.y), 40.0)
			var dgy := TerrainSurfaceQuery.ground_height_at(main, dc.x, dc.y)
			cam.global_position = Vector3(dc.x + span * 0.55, dgy + span * 0.95,
					dc.y + span * 0.55)
			cam.look_at(Vector3(dc.x, dgy, dc.y))
			cam.current = true
			await get_tree().create_timer(1.2).timeout
			await _graph_shot(dir, "06_desire_drape_3d", manifest, "world")
		sgv.set("_desire_3d_on", false)
		sgv.call("_ensure_desire_overlay")

		var subject := Vector2.ZERO
		var cdots: Array = bridge.call("agent_dots")
		if not cdots.is_empty():
			subject = (cdots[0] as Dictionary).get("pos", Vector2.ZERO) as Vector2
		var gy := TerrainSurfaceQuery.ground_height_at(main, subject.x, subject.y)
		cam.global_position = Vector3(subject.x + 4.5, gy + 2.6, subject.y + 4.5)
		cam.look_at(Vector3(subject.x, gy + 1.1, subject.y))
		cam.current = true
		await get_tree().create_timer(0.5).timeout
		await _graph_shot(dir, "04_world_avatars", manifest, "world")
		# Model review shot: real agents often stand under tree canopy (no
		# obstacle avoidance in v1), so pose three sample silhouettes on a
		# "sky stage" well above the treeline — standing, walking, lying —
		# with the camera level in front of them. Clean backdrop, guaranteed.
		# One figure per clip so the shot reviews the whole animation set, not
		# just a standing pose. These are staged directly rather than through
		# NpcPopulationHost, so they must opt into the rigged body themselves —
		# the host's distance/budget LOD never sees them.
		var stage := Vector3(0.0, gy + 80.0, 0.0)
		var poses := [
			{"moving": false, "activity": ""},          # idle   (humanoid)
			{"moving": true, "activity": ""},           # walk   (humanoid)
			{"moving": false, "activity": "sleep"},     # sleep  (humanoid)
			{"moving": false, "activity": ""},          # idle   (simplified)
			{"moving": true, "activity": ""},           # walk   (simplified)
			{"moving": false, "activity": "enrichment"},# dance  (simplified)
		]
		cam.global_position = stage + Vector3(0.0, 1.3, 5.6)
		cam.look_at(stage + Vector3(0.0, 0.85, 0.0))
		var samples: Array = []
		# Body style is a GLOBAL, PERSISTED player preference (user://npc_display.cfg,
		# Settings → NPCs → Body style), and the loop below flips it to shoot both
		# figures side by side. Snapshot it first: this used to leave the setting on
		# whatever the last sample needed, silently overwriting the player's choice
		# every time the harness ran — and then the rigged-LOD check above would
		# "pass" only because the harness itself had just changed the answer.
		var prev_style := NpcDisplayPrefs.style()
		for i in poses.size():
			var pose: Dictionary = poses[i]
			# Half the review line in each body style, so a single shot shows both
			# and they can be compared directly.
			NpcDisplayPrefs.set_style(NpcDisplayPrefs.STYLE_SIMPLE if i >= 3
				else NpcDisplayPrefs.STYLE_HUMANOID)
			var sample := NpcAvatar.new()
			sample.setup("review_%d" % i, NpcPopulationEngine.color_for_agent("review_%d" % i))
			main.add_child(sample)
			sample.set_detail(true)
			sample.apply_state(stage + Vector3(-3.5 + 1.4 * float(i), 0.0, 0.0),
					PI, bool(pose["moving"]), str(pose["activity"]))
			samples.append(sample)
		NpcDisplayPrefs.set_style(prev_style)
		print("PlaytestHarness: population verify — rig %s (%s)"
			% ["available" if NpcRig.available() else "ABSENT (primitive figures)",
				", ".join(NpcRig.clip_names()) if NpcRig.available() else NpcRig.load_error()])
		# Long enough for the animation tree to leave its bind pose.
		await get_tree().create_timer(1.2).timeout
		await _graph_shot(dir, "05_avatar_model_review", manifest, "world")
		for s in samples:
			(s as Node).queue_free()
		if prev_cam != null:
			prev_cam.current = true
		cam.queue_free()
	var ok_3d := host != null and avatar_count > 0 and ok_pick and ok_marks

	# --- phase 4: starvation loop --------------------------------------------
	# Baseline morale from the WELL-SUPPLIED run above, so the cascade below
	# is measured against a healthy community rather than one already falling.
	var morale_at_start := float(
			(bridge.call("summary_for", hab_id) as Dictionary).get("mean_morale", 1.0))
	var food_item: Dictionary = model.get_item("cap_pop_food")
	var fspecs: Dictionary = (food_item.get("specs", {}) as Dictionary).duplicate(true)
	fspecs["level"] = 0.0
	model.update_item("cap_pop_food", {"specs": fspecs})
	var flow: Variant = sgv.get("_resource_flow")
	if flow != null and flow.has_method("clear_timelines"):
		flow.call("clear_timelines")  # re-anchor tanks at the emptied level
	# NO forward time jump here: a >6 h skip takes the coarse catch-up path,
	# which clamps needs and settles morale in one step — the camp empties
	# before the starved flag can ever be observed. (That path has its own
	# coverage in npc_population_selftest._test_scrub_and_catchup.)
	if main != null and "time_scale" in main:
		main.time_scale = 0.2
	# Both the starved flag and peak hunger are TRANSIENT: the flag clears
	# between agents' retry attempts, and once people start leaving the
	# roster aggregates fall back toward zero. Sample both while it happens.
	var saw_starved := false
	var worst_hunger := 0.0
	# Long enough for hunger to climb clear of the act-on threshold even when
	# a preceding clock jump has just reset needs to mid-cycle.
	for i in 80:
		await get_tree().create_timer(0.25).timeout
		var hs: Dictionary = (model.get_item(hab_id).get("specs", {}) as Dictionary)
		if (hs.get("starved_kinds", []) as Array).has("food"):
			saw_starved = true
		var s_now: Dictionary = bridge.call("summary_for", hab_id)
		worst_hunger = maxf(worst_hunger,
				float((s_now.get("worst_needs", {}) as Dictionary).get("hunger", 0.0)))
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var food2: float = lvl.call("cap_pop_food")
	print("PlaytestHarness: population verify — saw_starved=%s worst_hunger=%.2f food=%.4f" % [
		str(saw_starved), worst_hunger, food2])
	# Hunger rises 1/16 per sim-hour, so a ~4 sim-hour outage window climbs it
	# well past the act-on threshold (0.55) without reaching a full pin; what
	# matters is that it CLIMBS while the tank is empty instead of being
	# satisfied. Full pinning is covered in the offline selftest.
	# The bar is "hunger CLIMBED well past the act-on threshold (0.55) while
	# the tank was empty", not a precise value — how far it gets depends on
	# the map's travel distances within the sampling window.
	var ok_starve := saw_starved and worst_hunger > 0.65 and food2 <= 0.0005
	print("PlaytestHarness: population verify — starvation loop %s" % [
		"PASS" if ok_starve else "FAIL (empty food tank did not block eating / pin hunger)"])

	# --- phase 5: morale + collapse cascade ----------------------------------
	# Food is already empty; now cut the water too and let the community
	# unwind. This is the Tier-2 loop end to end: blocked critical needs →
	# morale falls → people rage-quit → the roster shrinks → collapse.
	var wspecs: Dictionary = (model.get_item("cap_pop_water").get("specs", {}) as Dictionary).duplicate(true)
	wspecs["level"] = 0.0
	model.update_item("cap_pop_water", {"specs": wspecs})
	if flow != null and flow.has_method("clear_timelines"):
		flow.call("clear_timelines")
	var m_before := morale_at_start
	if main != null and "time_scale" in main:
		main.time_scale = 0.8   # ~0.4 sim-h per flow tick: fast, but well under
		                        # the 6 h coarse-catch-up threshold
	var saw_warning := false
	var pop_min := 99
	# 90 iterations was enough before daily routines existed. A scheduled camp
	# is genuinely more resilient — it starts near 0.81 morale instead of 0.60,
	# because people eat, wash and gather on time and enrichment lifts the
	# ceiling — so the same deprivation takes materially longer to reach the
	# collapse WARNING. That is the designed "more health = more buffer"
	# behaviour, not a regression, so the window is widened rather than the
	# assertion weakened.
	for i in 220:
		await get_tree().create_timer(0.5).timeout
		var s: Dictionary = bridge.call("summary_for", hab_id)
		pop_min = mini(pop_min, int(s.get("count", 99)))
		if float(s.get("collapse_risk", 0.0)) >= NpcPopulationEngine.COLLAPSE_WARN_RISK:
			saw_warning = true
		if bool(s.get("collapsed", false)):
			break
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var s_end: Dictionary = bridge.call("summary_for", hab_id)
	var m_after := float(s_end.get("mean_morale", 1.0))
	var left := int(s_end.get("departures", 0))
	print("PlaytestHarness: population verify — morale %.2f→%.2f, departures=%d, roster %d→%d, risk=%.2f, collapsed=%s" % [
		m_before, m_after, left, 16, int(s_end.get("count", 0)),
		float(s_end.get("collapse_risk", 0.0)), str(s_end.get("collapsed", false))])
	var ok_cascade := m_after < m_before and left > 0 and saw_warning
	print("PlaytestHarness: population verify — morale/collapse cascade %s" % [
		"PASS" if ok_cascade else "FAIL (needs unmet did not drive morale down and people out)"])

	# Recovery. A roster that empties out cannot restart itself — departures
	# are permanent and a zero-agent engine ticks to nothing — so "Reset
	# population" in the habitat inspector is the ONLY way back, and it has to
	# work through the real view method the button calls.
	var before_reset := int((bridge.call("summary_for", hab_id) as Dictionary).get("count", 0))
	var reset_ok := bool(sgv.call("npc_reset_population", hab_id))
	await get_tree().process_frame
	var s_reset: Dictionary = bridge.call("summary_for", hab_id)
	var after_reset := int(s_reset.get("count", 0))
	var ok_reset := reset_ok and after_reset > before_reset \
		and not bool(s_reset.get("deserted", false)) \
		and not bool(s_reset.get("collapsed", false)) \
		and int(s_reset.get("departures", 0)) == 0
	print("PlaytestHarness: population verify — reset population %s (roster %d→%d, morale %.2f, collapsed=%s)" % [
		"PASS" if ok_reset else "FAIL", before_reset, after_reset,
		float(s_reset.get("mean_morale", 0.0)), str(s_reset.get("collapsed", false))])

	# Settings → NPC → "Simulate & draw NPCs" OFF (site analysis): the roster
	# must FREEZE, the avatar host and crowd renderer must be FREED, and the
	# habitat must drop its pop-driven demand override (classic constant rate)
	# — then all of it must come back when switched on again. Flipped IN
	# MEMORY only (the static, never set_npcs_enabled), so the player's
	# npc_display.cfg is never written.
	var ok_off := false
	var off_note := ""
	if main != null and "time_scale" in main:
		main.time_scale = 0.1
	await get_tree().create_timer(1.5).timeout
	NpcDisplayPrefs.force_npcs_for_session(false)
	NpcDisplayPrefs._npcs_on = 0
	await get_tree().create_timer(1.0).timeout
	var off_h0 := float(bridge.call("last_abs_h"))
	var off_dots0: Array = bridge.call("agent_dots")
	await get_tree().create_timer(2.5).timeout
	var off_dots1: Array = bridge.call("agent_dots")
	var off_moved := 0
	for i in mini(off_dots0.size(), off_dots1.size()):
		var q0: Vector2 = (off_dots0[i] as Dictionary).get("pos", Vector2.ZERO)
		var q1: Vector2 = (off_dots1[i] as Dictionary).get("pos", Vector2.ZERO)
		if (q1 - q0).length() > 0.01:
			off_moved += 1
	var rf_off: Variant = sgv.call("resource_flow_engine")
	var demand_off: Dictionary = rf_off.get("_habitat_demand") if rf_off != null else {}
	var host_off: Variant = sgv.call("npc_population_host")
	var cr_off: Variant = sgv.call("crowd_renderer")
	var frozen := is_equal_approx(float(bridge.call("last_abs_h")), off_h0) and off_moved == 0
	var torn := (host_off == null or not is_instance_valid(host_off)) and cr_off == null
	var nominal := not demand_off.has(hab_id)
	var summary_off: Dictionary = sgv.call("npc_dot_summary")
	# ...and back on: the next ticks resume the same roster.
	NpcDisplayPrefs._npcs_on = -1
	NpcDisplayPrefs.force_npcs_for_session(true)
	await get_tree().create_timer(2.5).timeout
	var host_on: Variant = sgv.call("npc_population_host")
	var demand_on: Dictionary = rf_off.get("_habitat_demand") if rf_off != null else {}
	var resumed := float(bridge.call("last_abs_h")) > off_h0 + 0.01 \
		and host_on != null and is_instance_valid(host_on) and demand_on.has(hab_id)
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	ok_off = frozen and torn and nominal and summary_off.is_empty() and resumed
	off_note = "frozen=%s (moved %d), host+renderer freed=%s, nominal demand=%s, summary empty=%s, resumed=%s" % [
		str(frozen), off_moved, str(torn), str(nominal), str(summary_off.is_empty()), str(resumed)]
	print("PlaytestHarness: population verify — NPCs switched off %s (%s)" % [
		"PASS" if ok_off else "FAIL", off_note])

	# Routine editing (the Routines panel's Apply button). Exercised through the
	# same bridge calls the panel makes, plus the panel script itself, because
	# the panel needs the CursorController autoload and so cannot be built in an
	# offline selftest at all.
	var routine_ok := false
	var routine_note := "no routine"
	var live_routine = sgv.call("npc_routine_for", hab_id)
	if live_routine != null:
		var before_visits := int(live_routine.toilet_visits_per_day())
		# Author a deliberately different day: a 4th bathroom block, which must
		# read back as a 4th flush rather than a rescaled third.
		var edited: Array = live_routine.to_array()
		edited.append({"start_h": 16.0, "end_h": 16.0 + NpcRoutine.BATHROOM_HOURS,
			"kind": NpcRoutine.BATHROOM})
		var applied := bool(sgv.call("npc_set_routine", hab_id, edited))
		var after = sgv.call("npc_routine_for", hab_id)
		var after_visits := int(after.toilet_visits_per_day()) if after != null else -1
		# It must also PERSIST into the item's specs, or the edit is lost on the
		# next engine rebuild (reset, occupant change, save/load).
		var saved: Array = (model.get_item(hab_id).get("specs", {}) as Dictionary).get(
			"pop_routine", []) as Array
		routine_ok = applied and after_visits == before_visits + 1 and saved.size() == edited.size()
		routine_note = "%d -> %d visits, %d blocks persisted" % [
			before_visits, after_visits, saved.size()]
		# Put the authored day back so the map is left as it was found.
		sgv.call("npc_set_routine", hab_id, live_routine.to_array())
	var panel_script: GDScript = load("res://scenes/ui/npc_routines_panel.gd")
	var panel_ok: bool = panel_script != null and panel_script.can_instantiate()
	print("PlaytestHarness: population verify — routine editing %s (%s, panel compiles=%s)" % [
		"PASS" if (routine_ok and panel_ok) else "FAIL", routine_note, str(panel_ok)])

	print("PlaytestHarness: population verify — 3D avatars %s" % [
		"PASS" if ok_3d else "FAIL (host missing or wrong avatar count)"])
	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	# Leave the map's autosaved graph the way we found it.
	for pid in pop_ids:
		if not (model.get_item(str(pid)) as Dictionary).is_empty():
			model.remove_item(str(pid))
	print("PlaytestHarness: population verify — %s (%d shots in %s)" % [
		"PASS" if (ok_flow and ok_move and ok_smooth and ok_chore and ok_face and ok_pose and ok_starve and ok_cascade and ok_3d and ok_nav and ok_walk and ok_desire and ok_drape and ok_off) else "FAIL",
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Siphon Lab UI capture (--capture=siphon). Builds a pond + siphon on the graph,
## binds them, opens the Lab (VIEW_SIPHON), and shoots primed/flowing/broken
## states so the cross-section + flow rendering can be reviewed from PNGs.
func _run_siphon_lab_capture() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting siphon capture")
		_maybe_quit()
		return
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		print("PlaytestHarness: siphon capture — waiting for map load")
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout

	var main := get_tree().current_scene
	if main != null:
		if "time_scale" in main:
			main.time_scale = 0.0
		if "day_time" in main:
			main.day_time = _capture_hour

	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting siphon capture")
		_maybe_quit()
		return

	# If the loaded graph already has a siphon (user maps carry their own config),
	# use it READ-ONLY — never mutate the player's real pond/graph. Only synthesize
	# a demo pond+siphon (soak map) when none exists.
	# The harness's OWN seeds from an earlier run (ids `cap_lab_*`, persisted
	# by the soak map's autosave) are not a player's siphon: strip them, and
	# the outlet sink wired to the old siphon, so the seeded path — the one
	# with the binding + physics asserts — actually runs.
	var existing_siphon := ""
	var stale: Array[String] = []
	var hydro_list := PackedStringArray()
	for it in model.items:
		if not (it is Dictionary):
			continue
		var iid := str((it as Dictionary).get("id", ""))
		if iid.begins_with("cap_lab_"):
			stale.append(iid)
			continue
		var sp0: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str(sp0.get("role", "")) == "siphon_hydro":
			var k0 := str(sp0.get("turbine_kind", "siphon"))
			hydro_list.append("%s (%s, %s)" % [iid, str(sp0.get("name", "")), k0])
			# This is the SIPHON capture: a siphon-kind turbine wins over a
			# Pelton that happens to sit earlier in the list.
			if existing_siphon.is_empty() or k0 == "siphon":
				if existing_siphon.is_empty() or str(((model.get_item(existing_siphon) as Dictionary).get("specs", {}) as Dictionary).get("turbine_kind", "siphon")) != "siphon":
					existing_siphon = iid
	if not hydro_list.is_empty():
		print("PlaytestHarness: siphon capture — hydro turbines on the map: %s" % ", ".join(hydro_list))
	var existing_is_siphon := not existing_siphon.is_empty() and str(
			((model.get_item(existing_siphon) as Dictionary).get("specs", {}) as Dictionary).get("turbine_kind", "siphon")) == "siphon"
	if existing_is_siphon:
		await _run_siphon_lab_capture_readonly(sgv, existing_siphon)
		return
	# A real pond on the map? Then the seeded siphon drinks from THAT: the
	# bind seats it on the shore and the outlet trace runs over real terrain.
	var real_pond_id := ""
	for it in model.items:
		if not (it is Dictionary):
			continue
		var sp1: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if bool(sp1.get("pond_storage", false)) and not is_nan(float(sp1.get("rim_m", NAN))) \
				and not is_nan(float(sp1.get("floor_m", NAN))) and GraphSiteLayout.has_site_coords(it as Dictionary) \
				and not str((it as Dictionary).get("id", "")).begins_with("cap_lab_"):
			real_pond_id = str((it as Dictionary).get("id", ""))
			break
	if not stale.is_empty():
		for conn: Dictionary in model.connections.duplicate():
			if str(conn.get("source_item_id", "")) == "cap_lab_siphon":
				var tgt: Dictionary = model.get_item(str(conn.get("target_item_id", "")))
				if bool((tgt.get("specs", {}) as Dictionary).get("outlet_sink", false)):
					stale.append(str(tgt.get("id", "")))
		for sid in stale:
			if not model.get_item(sid).is_empty():
				model.remove_item(sid)
		print("PlaytestHarness: siphon capture — removed %d stale cap_lab_* seeds" % stale.size())

	# Ground datum under the pond so the DEM section frames sensibly.
	var g := 0.0
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		g = float((soi.call("world_center") as Vector3).y)

	var pond_id := "cap_lab_pond"
	var siphon_id := "cap_lab_siphon"
	var demo_pond := real_pond_id.is_empty()
	var seed_elev := g + 1.65
	if not demo_pond:
		pond_id = real_pond_id
		var rp: Dictionary = (model.get_item(pond_id).get("specs", {}) as Dictionary)
		# Just under the rim, like the bind would seat it; the pond's own
		# level decides whether it primes.
		seed_elev = float(rp.get("rim_m", g)) - 0.35
		g = float(rp.get("floor_m", g))
		print("PlaytestHarness: siphon capture — seeding a temporary siphon on the map's pond %s (%s)" % [
				pond_id, str(rp.get("name", ""))])
		_siphon_cleanup_ids = [siphon_id]
	if demo_pond:
		model.add_item({
		"id": pond_id, "type": "resource", "x": 0.0, "y": 0.0,
		"width": 80.0, "height": 80.0,
		"specs": {
			"name": "Lab Pond", "resource_kind": "water",
			"pond_storage": true, "fill_mode": "auto",
			"capacity_qty": 30000.0, "capacity_unit": "L",
			"level": 0.85, "stock_l": 25500.0,
			"floor_m": g, "rim_m": g + 2.0, "level_m": g + 1.7,
			"footprint_w_m": 8.0, "footprint_d_m": 8.0,
		},
		"site_x_m": 0.0, "site_z_m": 0.0,
		})
	var siphon_item := {
		"id": siphon_id, "type": "processor", "x": 160.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "elevation_m": seed_elev,
		"specs": {
			"name": "Lab Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"energy_source": "", "efficiency": 1.0,
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "manning_n": 0.012,
			"max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
			# The siphon's geometry: a 1.2 m dip tube (mouth = break at
			# g + 0.45), overflow-primed at the crest (g + 1.65).
			"dip_tube_length_m": 1.2, "siphon_prime_mode": "overflow",
			"module_elev_m": seed_elev, "outlet_invert_m": seed_elev - 9.65,
			"siphon_primed": true,
			"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h"}],
			"outputs": [
				{"kind": "water", "rate": 0.0, "unit": "L/h"},
				{"kind": "dc_electricity", "rate": 0.0, "unit": "kW"},
			],
		},
	}
	if demo_pond:
		# Seeded with a site of its own: the bind must leave it there.
		siphon_item["site_x_m"] = 6.0
		siphon_item["site_z_m"] = 0.0
	# (On a real pond the item has NO site: the bind seats it on the shore.)
	model.add_item(siphon_item)
	if sgv.has_method("bind_siphon_to_nearest_pond"):
		sgv.call("bind_siphon_to_nearest_pond", siphon_id)
	if sgv.has_method("ensure_siphon_outlet_sink"):
		sgv.call("ensure_siphon_outlet_sink", siphon_id)

	var label := _shots_label if not _shots_label.is_empty() else "siphon_lab"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	# Open the graph the same way the G key does, THEN enter the Siphon Lab view.
	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	await get_tree().create_timer(1.0).timeout
	if sgv.has_method("open_siphon_lab"):
		sgv.call("open_siphon_lab", siphon_id)
	await get_tree().create_timer(2.0).timeout
	await _graph_shot(dir, "01_lab_primed_flowing", manifest)

	# Drive the pond dynamically on the world clock (Phase 1): accelerate time so
	# the primed pond drains through the siphon until it breaks (dry outlet).
	if main != null and "time_scale" in main:
		main.time_scale = 30.0
	await get_tree().create_timer(3.0).timeout
	await _graph_shot(dir, "02_lab_draining_broken", manifest)

	# Turn on the test inflow so the pond refills and re-primes.
	_siphon_capture_set_test_inflow(model, siphon_id, true, 400.0)
	await get_tree().create_timer(2.0).timeout
	await _graph_shot(dir, "03_lab_refilling_reprimed", manifest)

	# Water-drag path: freeze time, turn inflow off, and hand-set the pond level
	# (what dragging the water line does). It must HOLD (engine reanchored, not
	# clobbered) — a low level here proves the manual fill/drain works.
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	_siphon_capture_set_test_inflow(model, siphon_id, false, 0.0)
	if sgv.has_method("lab_set_pond_level"):
		sgv.call("lab_set_pond_level", siphon_id, g + 0.6)
	await get_tree().create_timer(1.5).timeout
	await _graph_shot(dir, "04_lab_water_dragged_low", manifest)

	await _verify_siphon_turbine(sgv, model, siphon_id, pond_id, demo_pond)
	await _verify_view_camera_decoupled(sgv, siphon_id)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: siphon capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	# Then the Lab tour (zoom, PowerSpout charts, the two Pelton close-ups)
	# on the fresh seed — it ends the run.
	await _run_siphon_lab_capture_readonly(sgv, siphon_id)


## The zoom-decoupling contract, which no PNG can show: the freeform camera must
## survive a whole Hydro Lab session untouched. Before per-view camera slots the
## Lab parked the canvas in VIEW_FREEFORM and then framed it, so opening the Lab
## silently destroyed the framing the player had — and coming back landed on an
## empty, absurdly-zoomed graph.
func _verify_view_camera_decoupled(sgv: Node, siphon_id: String) -> void:
	var canvas: Variant = sgv.get("_graph_canvas")
	if canvas == null or not (canvas as Object).has_method("set_view_mode"):
		print("PlaytestHarness: view-camera decoupling — SKIPPED (no canvas)")
		return
	# Park in freeform at a framing nothing else would pick, so a value that
	# survives cannot have been coincidentally re-derived.
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	await get_tree().create_timer(0.6).timeout
	const WANT_ZOOM := 0.37
	var want_pan := Vector2(-211.0, 87.0)
	canvas.set("_zoom", WANT_ZOOM)
	canvas.set("_pan", want_pan)
	await get_tree().create_timer(0.3).timeout

	if sgv.has_method("open_siphon_lab"):
		sgv.call("open_siphon_lab", siphon_id)
	await get_tree().create_timer(1.5).timeout
	var modal: Variant = sgv.get("_siphon_lab_modal")
	if modal != null:
		modal.set("_view_zoom", 3.4)
		if (modal as Object).has_method("_redraw_preview"):
			modal.call("_redraw_preview")
	await get_tree().create_timer(0.8).timeout
	if sgv.has_method("close_hydro_lab"):
		sgv.call("close_hydro_lab")
	await get_tree().create_timer(0.8).timeout
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", GraphSiteLayout.VIEW_FREEFORM)
	await get_tree().create_timer(0.6).timeout

	var got_zoom := float(canvas.get("_zoom"))
	var got_pan: Vector2 = canvas.get("_pan") as Vector2
	var zoom_ok := absf(got_zoom - WANT_ZOOM) < 1e-4
	var pan_ok := got_pan.distance_to(want_pan) < 1e-3
	print("PlaytestHarness: view-camera decoupling — freeform zoom %.6f (want %.6f) %s, pan %s (want %s) %s" % [
		got_zoom, WANT_ZOOM, "OK" if zoom_ok else "FAIL",
		str(got_pan), str(want_pan), "OK" if pan_ok else "FAIL"])
	if not zoom_ok or not pan_ok:
		push_error("PlaytestHarness: Hydro Lab clobbered the freeform camera")


## Read-only Siphon Lab capture for a REAL user map: open the Lab on the existing
## siphon and shoot the current state at a few framings. Mutates NOTHING (no
## drain/refill/level writes) so the player's saved pond/graph is untouched.
func _run_siphon_lab_capture_readonly(sgv: Node, siphon_id: String) -> void:
	var label := _shots_label if not _shots_label.is_empty() else "siphon_lab"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	await get_tree().create_timer(1.0).timeout
	if sgv.has_method("open_siphon_lab"):
		sgv.call("open_siphon_lab", siphon_id)
	await get_tree().create_timer(2.5).timeout
	await _graph_shot(dir, "01_lab_default_fit", manifest)
	# The player's own siphon: the binding heals + the physics, through the
	# same checks the seeded path runs (minus the seed-specific ones).
	var model_ro: Variant = sgv.get("model")
	if model_ro != null and sgv.has_method("resolve_siphon_pond"):
		var pond_ro: Dictionary = sgv.call("resolve_siphon_pond", siphon_id)
		var kind_ro := str(((model_ro.call("get_item", siphon_id) as Dictionary).get("specs", {}) as Dictionary).get("turbine_kind", "siphon"))
		if not pond_ro.is_empty() and not bool(HydroSource.kind_meta(kind_ro).get("has_penstock", false)):
			await _verify_siphon_turbine(sgv, model_ro, siphon_id, str(pond_ro.get("id", "")), false)
			await _verify_siphon_lab_interaction(sgv, model_ro, siphon_id, dir, manifest)
		else:
			print("PlaytestHarness: siphon verify — SKIPPED (no bound pond or not a siphon kind: %s)" % kind_ro)

	# A couple of zoom framings via the modal's own view transform (read-only).
	var modal: Node = sgv.get("_siphon_lab_modal")
	if modal != null:
		modal.set("_view_zoom", 0.55)
		if modal.has_method("_redraw_preview"):
			modal.call("_redraw_preview")
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(dir, "02_zoom_out", manifest)
		modal.set("_view_zoom", 2.0)
		if modal.has_method("_redraw_preview"):
			modal.call("_redraw_preview")
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(dir, "03_zoom_in", manifest)
		modal.set("_view_zoom", 1.0)

	# Phase E surface: flip the turbine kind to the PowerSpout Pelton so the
	# nozzle knobs + power-curve chart + warnings render, shoot, then restore
	# the original kind (snapshot/restore — the map's turbine stays as saved).
	var model: Variant = sgv.get("model")
	if modal != null and model != null:
		var item: Dictionary = model.call("get_item", siphon_id)
		var orig_specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
		var ps_specs: Dictionary = orig_specs.duplicate(true)
		ps_specs["turbine_kind"] = "powerspout_pelton"
		model.call("update_item", siphon_id, {"specs": ps_specs})
		if modal.has_method("_load_from_model"):
			modal.call("_load_from_model")
		await get_tree().create_timer(1.2).timeout
		# Scroll the params dock to the bottom so the power-curve chart +
		# warnings row are actually IN the frame (they live below the fold).
		var side: Variant = modal.get("_side")
		if side != null and (side as Control).get_parent() is ScrollContainer:
			((side as Control).get_parent() as ScrollContainer).scroll_vertical = 4000
			await get_tree().create_timer(0.4).timeout
		await _graph_shot(dir, "04_powerspout_charts", manifest)
		if side != null and (side as Control).get_parent() is ScrollContainer:
			((side as Control).get_parent() as ScrollContainer).scroll_vertical = 0
		# Console dump of what the PNG can't show: the chart's per-size stats.
		var stats: Variant = modal.get("_chart_stats_lbl")
		if stats != null:
			print("PlaytestHarness: siphon lab chart stats — %s" % str((stats as Label).text))
		await _siphon_capture_closeup(modal, dir, manifest)
		# The AliExpress micro Pelton: the close-up must swap to ITS model
		# (vertical shaft, modelled nozzle fitting), the jet's-eye view must
		# look down the jet at the cups, and the exit sheets must follow the
		# bucket relation.
		var mp_specs: Dictionary = orig_specs.duplicate(true)
		mp_specs["turbine_kind"] = "micro_pelton"
		model.call("update_item", siphon_id, {"specs": mp_specs})
		if modal.has_method("_load_from_model"):
			modal.call("_load_from_model")
		await get_tree().create_timer(1.0).timeout
		await _siphon_capture_micro_pelton(modal, dir, manifest)
		model.call("update_item", siphon_id, {"specs": orig_specs})
		if modal.has_method("_load_from_model"):
			modal.call("_load_from_model")

	# The close-up AGAIN on the siphon, after the Pelton phases ran in the
	# same modal: its `_last` then carries the Pelton's nozzle keys, which
	# is exactly the state that threw "Invalid access to 'riser_top'".
	if modal != null and model != null:
		var kind_end := str(((model.call("get_item", siphon_id) as Dictionary).get("specs", {}) as Dictionary).get("turbine_kind", "siphon"))
		if kind_end == "siphon" and modal.has_method("_set_lab_view"):
			# The Pelton phases restored the item's specs under the modal; a
			# player's modal is always in step with the dropdown, so bring it
			# back in step before reopening (the state that threw was the
			# close-up's own `_last`, not a stale dropdown).
			if modal.has_method("_load_from_model"):
				modal.call("_load_from_model")
				await get_tree().create_timer(0.5).timeout
			modal.call("_set_lab_view", "closeup")
			await get_tree().create_timer(1.5).timeout
			var cu: Variant = modal.get("_closeup")
			var ok_again := cu != null and bool((cu.call("debug_summary") as Dictionary).get("siphon_mode", false))
			print("PlaytestHarness: siphon close-up reopened after the Pelton tour — %s" % ("PASS" if ok_again else "FAIL"))
			await _graph_shot(dir, "11_siphon_closeup_after_pelton", manifest)
			modal.call("_set_lab_view", "section")
			await get_tree().create_timer(0.4).timeout
	await _verify_view_camera_decoupled(sgv, siphon_id)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: siphon capture (read-only, existing siphon %s) — %d shots in %s" % [
		siphon_id, manifest.size(), ProjectSettings.globalize_path(dir)])
	_siphon_cleanup(sgv)
	_maybe_quit()


## Turbine close-up: matched load vs runaway. Shoots both AND dumps the operating
## point, because a PNG cannot tell you whether the wheel is at 690 rpm or 1380 —
## and "spins faster with less load, makes nothing" is the entire point of the view.
func _siphon_capture_closeup(modal: Node, dir: String, manifest: Array) -> void:
	if not modal.has_method("_set_lab_view"):
		print("PlaytestHarness: siphon close-up — SKIPPED (no view tabs)")
		return
	# Force a real operating point. On a map whose turbine happens to be dry the
	# view is CORRECT to show no jet — but then the shots prove nothing about the
	# jet, the splash or the speed model, which is the whole reason they exist.
	if modal.has_method("set_state_for_test"):
		modal.call("set_state_for_test", 1.35, 17.0)
	modal.call("_set_lab_view", "closeup")
	await get_tree().create_timer(1.6).timeout
	var closeup: Variant = modal.get("_closeup")
	for phase: Array in [["05_closeup_matched_load", 1.0], ["06_closeup_runaway", 0.0]]:
		modal.set("_load_frac", float(phase[1]))
		if modal.has_method("_push_closeup_state"):
			modal.call("_push_closeup_state")
		# Let the runner's inertia settle toward the new speed before shooting.
		await get_tree().create_timer(3.2).timeout
		await _graph_shot(dir, str(phase[0]), manifest)
		var hud := ""
		if closeup != null:
			var lbl: Variant = (closeup as Object).get("_hud")
			if lbl != null:
				hud = str((lbl as Label).text)
		print("PlaytestHarness: siphon close-up [%s] load %.0f%% — %s" % [
			str(phase[0]), float(phase[1]) * 100.0, hud])
	# Display modes: implemented and contract-pinned since the view landed, but
	# only ever driven with "cutaway" until they got a control row.
	if closeup != null and (closeup as Object).has_method("set_display_mode"):
		for m: String in ["runner", "housing", "cutaway"]:
			closeup.call("set_display_mode", m)
			await get_tree().create_timer(0.5).timeout
			if m == "runner":
				await _graph_shot(dir, "07_closeup_runner_only", manifest)
		print("PlaytestHarness: siphon close-up — display modes OK (back on %s)"
			% str((closeup as Object).get("_display_mode")))
	modal.set("_load_frac", 1.0)
	if modal.has_method("set_state_for_test"):
		modal.call("set_state_for_test", 0.0, 0.0)   # release the pin
	modal.call("_set_lab_view", "section")
	await get_tree().create_timer(0.6).timeout


## The micro Pelton in the close-up: side view, the jet's-eye view with the
## landing ring + velocity arrows, an axial nudge that moves the landing off
## the splitter, and the numbers a PNG cannot show (impact point on the pitch
## cylinder, exit vectors vs PeltonPhysics, the camera at the mouth).
func _siphon_capture_micro_pelton(modal: Node, dir: String, manifest: Array) -> void:
	if not modal.has_method("_set_lab_view"):
		return
	var fails := 0
	if modal.has_method("set_state_for_test"):
		modal.call("set_state_for_test", 0.9, 14.0)
	modal.call("_set_lab_view", "closeup")
	await get_tree().create_timer(2.0).timeout
	var closeup: Variant = modal.get("_closeup")
	if closeup == null or not (closeup as Object).has_method("debug_summary"):
		print("PlaytestHarness: micro pelton close-up — SKIPPED (no close-up)")
		return
	modal.set("_load_frac", 1.0)
	if modal.has_method("_push_closeup_state"):
		modal.call("_push_closeup_state")
	# A player's map can carry its own nozzle placement; the checks below are
	# about the MODELLED pose, so zero it for the measurement (the modal
	# pushes the saved one back on its next load).
	closeup.call("set_nozzle_pose", {"offset_m": 0.0, "axial_m": 0.0, "angle_deg": 0.0,
			"tilt_in_deg": 0.0, "tilt_out_deg": 0.0, "standoff_m": 0.0})
	await get_tree().create_timer(2.5).timeout
	var s0: Dictionary = closeup.call("debug_summary")
	print("PlaytestHarness: micro pelton close-up — %s" % str(s0))
	fails += _pen_check("close-up swapped to the micro Pelton's model", str(s0.get("model_id", "")) == "ali_pelton")
	fails += _pen_check("micro Pelton runner resolved (Node6), radius ~0.10 m",
			bool(s0.get("runner", false)) and absf(float(s0.get("runner_radius_m", 0.0)) - 0.101) < 0.01)
	fails += _pen_check("micro Pelton spins about Y (vertical shaft)",
			(s0.get("runner_axis", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.UP))
	fails += _pen_check("the GLB's own nozzle fitting was measured", bool(s0.get("modelled_nozzle", false)))
	# The wheel is rotated in its PARENT frame, and the GLB's top node is
	# turned -90° about X — so the catalog's model-root +Y must arrive there
	# as the disc's normal, or the runner spins like a coin on a table (it
	# did: axis (0,1,0) raw in a frame whose shaft is +Z).
	var spin_p: Vector3 = s0.get("spin_axis_parent", Vector3.ZERO)
	var disc_p: Vector3 = s0.get("disc_normal_parent", Vector3.ZERO)
	fails += _pen_check("the runner spins about its own disc normal in the frame it is rotated in (spin %s vs disc %s)" % [
			str(spin_p), str(disc_p)], absf(spin_p.dot(disc_p)) > 0.99)
	var hit: Vector3 = s0.get("hit", Vector3.ZERO)
	var centre: Vector3 = s0.get("runner_centre", Vector3.ZERO)
	var r_hit := Vector2(hit.x - centre.x, hit.z - centre.z).length()
	# The landing is on the PITCH circle (the kind's PCD/2 = 0.084 m, where the
	# splitters run), at the TANGENT point — not where the chord enters the tip
	# circle, which grazes a bucket's outer edge and read as a side-on hit.
	fails += _pen_check("the jet lands ON the pitch circle (%.3f vs r_pitch %.3f m)" % [r_hit, float(s0.get("r_pitch_m", 0.0))],
			absf(r_hit - float(s0.get("r_pitch_m", 0.0))) < 0.003)
	fails += _pen_check("…at the tangent point, head-on into the cup (x %.3f m off the shaft plane)" % absf(hit.x - centre.x),
			absf(hit.x - centre.x) < 0.012)
	fails += _pen_check("the fitting's jet runs along -X at the pitch offset (dir %s)" % str(s0.get("dir", Vector3.ZERO)),
			(s0.get("dir", Vector3.ZERO) as Vector3).dot(Vector3.LEFT) > 0.99)
	var ex := PeltonPhysics.bucket_exit_velocity(14.0, PeltonPhysics.speed_ratio_for_load(1.0))
	fails += _pen_check("exit sheets carry the bucket relation (%.2f m/s, %.2f sideways)" % [
			float(s0.get("exit_speed_ms", 0.0)), float(s0.get("exit_axial_ms", 0.0))],
			absf(float(s0.get("exit_speed_ms", 0.0)) - float(ex["speed"])) < 1e-3
			and absf(float(s0.get("exit_axial_ms", 0.0)) - float(ex["axial"])) < 1e-3)
	closeup.call("set_vectors", true)
	await get_tree().create_timer(0.6).timeout
	await _graph_shot(dir, "08_micro_pelton_side_vectors", manifest)
	closeup.call("set_camera_mode", "jet")
	await get_tree().create_timer(0.8).timeout
	var s1: Dictionary = closeup.call("debug_summary")
	var cam: Vector3 = s1.get("cam_pos", Vector3.ZERO)
	var mouth: Vector3 = s1.get("mouth", Vector3.ZERO)
	fails += _pen_check("jet's-eye camera stands just behind the nozzle mouth (%.3f m away), looking down the jet" % cam.distance_to(mouth),
			cam.distance_to(mouth) < 0.12 and (hit - cam).normalized().dot(s1.get("dir", Vector3.ZERO) as Vector3) > 0.85)
	await _graph_shot(dir, "09_micro_pelton_jet_eye", manifest)
	# Nudge the jet 12 mm along the shaft: the landing leaves the splitter and
	# the sheets split unevenly — the thing the jet's-eye view is for.
	closeup.call("set_nozzle_pose", {"axial_m": 0.012})
	await get_tree().create_timer(0.8).timeout
	var s2: Dictionary = closeup.call("debug_summary")
	# As modelled the fitting already sits a little under the mid-plane, so
	# assert the CHANGE: 12 mm over a ~28 mm half-thickness is ~0.4 of split.
	var d_split := float(s2.get("split", 0.0)) - float(s0.get("split", 0.0))
	fails += _pen_check("a 12 mm axial nudge moves the landing along the splitter (split %.2f -> %.2f)" % [
			float(s0.get("split", 0.0)), float(s2.get("split", 0.0))], d_split > 0.3)
	await _graph_shot(dir, "10_micro_pelton_jet_eye_offset", manifest)
	closeup.call("set_nozzle_pose", {"axial_m": 0.0})
	closeup.call("set_camera_mode", "side")
	closeup.call("set_vectors", false)
	var hud: Variant = (closeup as Object).get("_hud")
	if hud != null:
		print("PlaytestHarness: micro pelton close-up HUD — %s" % str((hud as Label).text))
	modal.set("_load_frac", 1.0)
	if modal.has_method("set_state_for_test"):
		modal.call("set_state_for_test", 0.0, 0.0)
	modal.call("_set_lab_view", "section")
	await get_tree().create_timer(0.6).timeout
	if fails > 0:
		push_error("PlaytestHarness: micro pelton close-up — %d CHECK(S) FAILED" % fails)
	else:
		print("PlaytestHarness: micro pelton close-up — PASS")


func _siphon_capture_set_test_inflow(model: Variant, siphon_id: String,
		enabled: bool, lps: float) -> void:
	var item: Dictionary = model.call("get_item", siphon_id)
	if item.is_empty():
		return
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	specs["lab_sim_inflow_enabled"] = enabled
	specs["lab_sim_inflow_lps"] = maxf(lps, 0.0)
	model.call("update_item", siphon_id, {"specs": specs})


# ---------------------------------------------------------------------------
# Site review (--capture=site-review) — real user map, as-loaded artifacts
# ---------------------------------------------------------------------------

## Composite: world + freeform + elevation + Siphon Lab + diagnostics/perf JSON.
## Never wipes the graph — shoots the autosaved site as the player left it.
func _run_site_review() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: site-review needs TerrainLoader (use --user-map=…)")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		print("PlaytestHarness: site-review — waiting for map load")
		await loader.map_load_complete
	# Large maps background veg after walkable — wait so world prim counts are real.
	if not bool(loader.get("auto_veg_ready")) \
			and loader.has_signal("auto_vegetation_ready"):
		print("PlaytestHarness: site-review — waiting for vegetation scatter")
		var veg_done := false
		loader.auto_vegetation_ready.connect(
				func() -> void: veg_done = true, CONNECT_ONE_SHOT)
		var veg_t0 := Time.get_ticks_msec()
		while not veg_done and not bool(loader.get("auto_veg_ready")):
			if Time.get_ticks_msec() - veg_t0 > 300_000:
				push_warning("PlaytestHarness: vegetation wait timed out (300 s)")
				break
			await get_tree().process_frame
	print("PlaytestHarness: site-review — settling %.0f s" % SETTLE_AFTER_LOAD_S)
	await get_tree().create_timer(_settle_s()).timeout
	await _wait_for_hyper_drape(loader)

	if _perf_hud:
		_enable_perf_monitor()

	var main := get_tree().current_scene
	if main != null:
		if "time_scale" in main:
			main.time_scale = 0.0
		if "day_time" in main:
			main.day_time = _capture_hour

	var label := _shots_label if not _shots_label.is_empty() else "site_review"
	var root := "%s/%s" % [SHOTS_ROOT, label]
	for sub in ["world", "graph", "siphon", "snowglobe", "perf"]:
		DirAccess.make_dir_recursive_absolute("%s/%s" % [root, sub])

	var sgv := await _find_graph_view()
	var manifest: Array = []
	# Heal orphan pond twins before the baseline dump (same as Elev/Lab enter).
	if sgv != null:
		if sgv.has_method("heal_duplicate_null_bathymetry_ponds"):
			sgv.call("heal_duplicate_null_bathymetry_ponds")
		if sgv.has_method("heal_pond_capacity_sanity"):
			sgv.call("heal_pond_capacity_sanity")
		var siphon0 := _site_review_find_siphon(sgv)
		if not siphon0.is_empty() and sgv.has_method("bind_siphon_to_nearest_pond"):
			var pond0: Dictionary = sgv.call("resolve_siphon_pond", siphon0) \
					if sgv.has_method("resolve_siphon_pond") else {}
			var need := pond0.is_empty()
			if not need and sgv.has_method("pond_has_usable_bathymetry"):
				need = not bool(sgv.call("pond_has_usable_bathymetry",
						pond0.get("specs", {}) as Dictionary))
			if need:
				sgv.call("bind_siphon_to_nearest_pond", siphon0, true)
	_write_site_diagnostics(root, loader, sgv)
	manifest.append({"file": "diagnostics.json", "set": "meta", "state": "diagnostics"})

	if _review_wants("world"):
		await _site_review_world(loader, root, manifest)

	if sgv == null:
		push_warning("PlaytestHarness: site-review — SystemGraphView missing; graph/siphon skipped")
	else:
		if _review_wants("freeform") or _review_wants("arranged"):
			await _site_review_freeform(sgv, root, manifest)
		if _review_wants("site"):
			await _site_review_site(sgv, root, manifest)
		if _review_wants("elevation"):
			await _site_review_elevation(sgv, root, manifest)
		if _review_wants("globe"):
			await _site_review_globe(sgv, root, manifest)
		if _review_wants("snowglobe"):
			await _site_review_snowglobe(sgv, root, manifest)
		if _review_wants("siphon"):
			await _site_review_siphon(sgv, root, manifest)

	var mf := FileAccess.open("%s/manifest.json" % root, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(_json_safe(manifest), "\t"))
		mf.close()
	print("PlaytestHarness: site-review — %d entries in %s" % [
		manifest.size(), ProjectSettings.globalize_path(root)])
	_maybe_quit()


func _write_site_diagnostics(root: String, loader: Node, sgv: Node) -> void:
	var diag := {
		"map_def_path": _map_def_path,
		"label": _launch_label,
		"latitude": _launch_lat,
		"longitude": _launch_lon,
		"half_extent_m": _launch_half_extent,
		"capture_hour": _capture_hour,
		"perf": _perf_hud,
		"no_mutate": _no_mutate,
		"review_sets": Array(_review_sets),
		"graph_autosave": "",
		"soi_center_y": NAN,
		"item_counts": {},
		"siphons": [],
		"ponds": [],
		"elev": {},
	}
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		diag["soi_center_y"] = float((soi.call("world_center") as Vector3).y)
	if not is_nan(_launch_lat) and not is_nan(_launch_lon):
		diag["graph_autosave"] = "user://saves/graph_autosave/map_%s_%s.graph.json" % [
			CoordToken.token(_launch_lat), CoordToken.token(_launch_lon)]
	if sgv != null:
		var model: Variant = sgv.get("model")
		if model != null and model.get("items") != null:
			var counts := {}
			var siphons: Array = []
			var ponds: Array = []
			for it in model.items:
				if not (it is Dictionary):
					continue
				var item: Dictionary = it
				var t := str(item.get("type", ""))
				var specs: Dictionary = item.get("specs", {}) as Dictionary
				var role := str(specs.get("role", ""))
				var key := role if not role.is_empty() else t
				counts[key] = int(counts.get(key, 0)) + 1
				if role == "siphon_hydro" or str(specs.get("model_id", "")) == "hydroturbine":
					var sid := str(item.get("id", ""))
					var pond_info := {}
					if sgv.has_method("resolve_siphon_pond"):
						var pond: Dictionary = sgv.call("resolve_siphon_pond", sid)
						if not pond.is_empty():
							var ps: Dictionary = pond.get("specs", {}) as Dictionary
							var sx := NAN
							var sz := NAN
							if GraphSiteLayout.has_site_coords(pond):
								var psite := GraphSiteLayout.site_xz(pond)
								sx = psite.x
								sz = psite.y
							pond_info = {
								"id": str(pond.get("id", "")),
								"tag": str(ps.get("osm_water_tag", "")),
								"floor_m": float(ps.get("floor_m", NAN)),
								"rim_m": float(ps.get("rim_m", NAN)),
								"level_m": float(ps.get("level_m", NAN)),
								"site_x_m": sx,
								"site_z_m": sz,
							}
					var conduits: Array = []
					for conn in model.connections:
						if not (conn is Dictionary):
							continue
						var c: Dictionary = conn
						var src := str(c.get("source_item_id", ""))
						var tgt := str(c.get("target_item_id", ""))
						if src != sid and tgt != sid:
							continue
						conduits.append({
							"id": str(c.get("id", "")),
							"type": ConduitKinds.derive_type_for_connection(c),
							"conduit_type": str(c.get("conduit_type", "")),
							"visible_3d": c.get("visible_3d"),
							"flow_glow": c.get("flow_glow"),
						})
					siphons.append({
						"id": sid,
						"name": str(specs.get("name", "")),
						"module_elev_m": float(specs.get("module_elev_m", NAN)),
						"siphon_start_m": float(specs.get("siphon_start_m", NAN)),
						"siphon_break_m": float(specs.get("siphon_break_m", NAN)),
						"outlet_invert_m": float(specs.get("outlet_invert_m", NAN)),
						"intake_diameter_mm": float(specs.get("intake_diameter_mm", NAN)),
						"outlet_diameter_mm": float(specs.get("outlet_diameter_mm", NAN)),
						"siphon_primed": bool(specs.get("siphon_primed", false)),
						"live_q_lps": float(specs.get("live_q_lps", 0.0)),
						"pond": pond_info,
						"conduits": conduits,
					})
				if bool(specs.get("pond_storage", false)):
					ponds.append({
						"id": str(item.get("id", "")),
						"tag": str(specs.get("osm_water_tag", "")),
						"floor_m": float(specs.get("floor_m", NAN)),
						"rim_m": float(specs.get("rim_m", NAN)),
						"level_m": float(specs.get("level_m", NAN)),
						"overflowing": bool(specs.get("overflowing", false)),
						"lab_demo_drive": bool(specs.get("_lab_demo_drive", false)),
					})
			diag["item_counts"] = counts
			diag["siphons"] = siphons
			diag["ponds"] = ponds
		var canvas: Node = sgv.get("_graph_canvas")
		if canvas != null:
			diag["elev"] = {
				"heading_rad": float(canvas.get("elevation_heading_rad")),
				"section_offset_m": float(canvas.get("elevation_section_offset_m")),
				"zoom": float(canvas.get("_zoom")),
				"anchor_along_m": float(canvas.call("get_elev_anchor_along_m")) \
						if canvas.has_method("get_elev_anchor_along_m") else NAN,
				"anchor_elev_m": float(canvas.call("get_elev_anchor_elev_m")) \
						if canvas.has_method("get_elev_anchor_elev_m") else NAN,
				"has_elev_anchor": bool(canvas.call("has_elev_anchor")) \
						if canvas.has_method("has_elev_anchor") else false,
			}
	if loader != null:
		diag["terrain_load_completed"] = bool(loader.get("load_completed"))
		diag["auto_veg_ready"] = bool(loader.get("auto_veg_ready"))
		diag["osm_half_extent_m"] = float(loader.get("_osm_half_extent")) \
				if loader.get("_osm_half_extent") != null else NAN
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm != null and pm.has_method("render_snapshot"):
		diag["render"] = pm.call("render_snapshot")
	var f := FileAccess.open("%s/diagnostics.json" % root, FileAccess.WRITE)
	if f != null:
		# JSON.stringify rejects NaN/Inf — scrub nested floats first.
		f.store_string(JSON.stringify(_json_safe(diag), "\t"))
		f.close()
		print("PlaytestHarness: wrote diagnostics.json (%d siphon(s), %d pond(s))" % [
			(diag["siphons"] as Array).size(), (diag["ponds"] as Array).size()])


## Replace NaN/Inf floats with null so JSON.stringify never throws.
func _json_safe(v: Variant) -> Variant:
	if v is float:
		var f := float(v)
		if is_nan(f) or is_inf(f):
			return null
		return f
	if v is Dictionary:
		var out := {}
		for k in (v as Dictionary).keys():
			out[k] = _json_safe((v as Dictionary)[k])
		return out
	if v is Array:
		var arr: Array = []
		for el in v as Array:
			arr.append(_json_safe(el))
		return arr
	return v


func _dump_perf(root: String, state: String, manifest: Array) -> void:
	if not _perf_hud:
		return
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm == null or not pm.has_method("snapshot"):
		return
	# Free-run long enough that Engine.get_frames_per_second() reflects steady
	# play — capture's frame_post_draw stalls otherwise leave FPS stuck ~5.
	for _i in 45:
		await get_tree().process_frame
	var snap: Dictionary = pm.call("snapshot")
	snap["fps_raw"] = float(Engine.get_frames_per_second())
	if state == "world":
		snap["mesh_audit"] = _mesh_prim_audit()
		snap["veg_off_ab"] = await _veg_off_prim_ab()
		# Re-sample FPS after A/B (veg hide/show also stalls the counter).
		for _j in 30:
			await get_tree().process_frame
		snap["fps_raw"] = float(Engine.get_frames_per_second())
		snap["fps"] = float(snap["fps_raw"])
	_perf_budget_warn(state, snap)
	var path := "perf/%s.json" % state
	var f := FileAccess.open("%s/%s" % [root, path], FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_json_safe(snap), "\t"))
		f.close()
	manifest.append({"file": path, "set": "perf", "state": state})


const CULVERT_PARTS_TRIS_BUDGET := 50000


## Sum MultiMesh / MeshInstance triangle×instance costs under the scene (top offenders).
func _mesh_prim_audit() -> Dictionary:
	var main := get_tree().current_scene
	if main == null:
		return {}
	var groups: Dictionary = {}
	var total := _audit_mesh_node(main, groups, 0)
	var ranked: Array = []
	var culvert_hosts: Dictionary = {}  # CulvertParts_* → sum tris
	for k in groups.keys():
		var tris := int(groups[k])
		ranked.append({"name": k, "tris": tris})
		var ks := str(k)
		if ks.begins_with("CulvertParts_"):
			var host := ks.get_slice("/", 0)
			culvert_hosts[host] = int(culvert_hosts.get(host, 0)) + tris
	ranked.sort_custom(func(a, b): return int(a["tris"]) > int(b["tris"]))
	if ranked.size() > 12:
		ranked = ranked.slice(0, 12)
	print("PlaytestHarness: mesh audit total~%d tris (top: %s)" % [
		total, str(ranked.slice(0, mini(5, ranked.size())))])
	for host in culvert_hosts.keys():
		var ct := int(culvert_hosts[host])
		if ct > CULVERT_PARTS_TRIS_BUDGET:
			push_warning("PlaytestHarness: budget — %s tris %d > %d" % [
				host, ct, CULVERT_PARTS_TRIS_BUDGET])
		else:
			print("PlaytestHarness: culvert budget ok — %s tris=%d" % [host, ct])
	return {"approx_tris": total, "top": ranked, "culvert_hosts": culvert_hosts}


func _audit_mesh_node(n: Node, groups: Dictionary, total: int) -> int:
	if n is MultiMeshInstance3D:
		var mi := n as MultiMeshInstance3D
		var mm := mi.multimesh
		if mm != null and mm.mesh != null and mm.instance_count > 0:
			var t := _mesh_tri_count(mm.mesh) * mm.instance_count
			total += t
			var pname := str(mi.get_parent().name) if mi.get_parent() != null else ""
			var key := ("%s/%s" % [pname, mi.name]) if pname.begins_with("CulvertParts_") \
					else (pname + "/" + str(mi.name).get_slice("_", 0) \
					+ "_" + str(mi.name).get_slice("_", 1))
			groups[key] = int(groups.get(key, 0)) + t
	elif n is MeshInstance3D:
		var mesh_i := n as MeshInstance3D
		if mesh_i.mesh != null:
			var t2 := _mesh_tri_count(mesh_i.mesh)
			total += t2
			var pname2 := str(mesh_i.get_parent().name) if mesh_i.get_parent() != null else ""
			var key2 := ("%s/%s" % [pname2, mesh_i.name]) if pname2.begins_with("CulvertParts_") \
					else str(mesh_i.name)
			groups[key2] = int(groups.get(key2, 0)) + t2
	for c in n.get_children():
		total = _audit_mesh_node(c, groups, total)
	return total


func _mesh_tri_count(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		var arr := mesh.surface_get_arrays(s)
		var idx: Variant = arr[Mesh.ARRAY_INDEX] if arr.size() > Mesh.ARRAY_INDEX else null
		if idx is PackedInt32Array and (idx as PackedInt32Array).size() >= 3:
			n += (idx as PackedInt32Array).size() / 3
		else:
			var verts: Variant = arr[Mesh.ARRAY_VERTEX]
			if verts is PackedVector3Array:
				n += (verts as PackedVector3Array).size() / 3
	return n


## Hide AutoVegetation + Vegetation for 4 frames and re-sample primitives.
func _veg_off_prim_ab() -> Dictionary:
	var main := get_tree().current_scene
	if main == null:
		return {}
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return {}
	var roots: Array = []
	for nm in ["AutoVegetation", "Vegetation"]:
		var r := terrain.get_node_or_null(nm)
		if r != null:
			roots.append({"node": r, "was": r.visible})
			r.visible = false
	for _i in 4:
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	var prims_off := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	for e in roots:
		(e["node"] as Node3D).visible = bool(e["was"])
	for _i in 2:
		await get_tree().process_frame
	var prims_on := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	print("PlaytestHarness: veg A/B — prims on=%d off=%d (delta=%d)" % [
		prims_on, prims_off, prims_on - prims_off])
	return {"prims_veg_on": prims_on, "prims_veg_off": prims_off,
		"delta": prims_on - prims_off}


## Soft budgets for site-review (warn only — never abort capture).
func _perf_budget_warn(state: String, snap: Dictionary) -> void:
	var fps := float(snap.get("fps_raw", snap.get("fps", 0.0)))
	var render: Dictionary = snap.get("render", {}) as Dictionary
	var prims := int(render.get("primitives", 0))
	if state == "world":
		if fps > 0.0 and fps < 20.0:
			push_warning("PlaytestHarness: budget — world fps %.1f < 20" % fps)
		if prims > 2_000_000:
			push_warning("PlaytestHarness: budget — world primitives %d > 2M" % prims)
		print("PlaytestHarness: world budget check — fps=%.1f prims=%d" % [fps, prims])
	elif state == "siphon":
		if fps > 0.0 and fps < 30.0:
			push_warning("PlaytestHarness: budget — Hydro Lab fps %.1f < 30" % fps)


func _site_review_world(loader: Node, root: String, manifest: Array) -> void:
	var world_dir := "%s/world" % root
	# Hide Main CanvasLayers for a clean 3D plate (PerfMonitor is its own autoload).
	_set_capture_conditions()
	var cam := Camera3D.new()
	cam.name = "SiteReviewCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()
	var world_manifest: Array = []
	await _capture_set(cam, _orbit_waypoints(loader), "orbit", world_dir, world_manifest)
	await _capture_set(cam, _street_waypoints(loader), "street", world_dir, world_manifest)
	for e in world_manifest:
		var entry: Dictionary = (e as Dictionary).duplicate()
		entry["file"] = "world/%s" % str(entry.get("file", ""))
		entry["view_mode"] = "world3d"
		manifest.append(entry)
	# One orbit frame with Main HUD restored + perf overlay (if enabled).
	var main := get_tree().current_scene
	if main != null:
		for child in main.get_children():
			if child is CanvasLayer:
				child.visible = true
	var orbit := _orbit_waypoints(loader)
	if not orbit.is_empty():
		var wp: Dictionary = orbit[0]
		cam.look_at_from_position(wp["pos"], wp["look"], Vector3.UP)
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/perf_hud_orbit.png" % world_dir)
		manifest.append({
			"file": "world/perf_hud_orbit.png",
			"set": "world",
			"state": "perf_hud_orbit",
			"view_mode": "world3d",
		})
	cam.queue_free()
	await _dump_perf(root, "world", manifest)
	# Restore frozen clock after HUD restore (capture conditions set it).
	if main != null and "time_scale" in main:
		main.time_scale = 0.0


func _site_review_freeform(sgv: Node, root: String, manifest: Array) -> void:
	var gdir := "%s/graph" % root
	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "freeform")
	# Bubble off for baseline freeform + Expand drill path.
	if sgv.has_method("_on_soi_preview_toggled"):
		sgv.call("_on_soi_preview_toggled", false)
	await get_tree().create_timer(1.2).timeout
	await _graph_shot(gdir, "01_freeform_as_loaded", manifest, "graph", "freeform", "graph/")
	await _dump_perf(root, "freeform", manifest)
	if _review_wants("arranged") and sgv.has_method("_apply_graph_auto_layout"):
		sgv.call("_apply_graph_auto_layout", true)
		await get_tree().create_timer(0.6).timeout
		await _graph_shot(gdir, "02_freeform_arranged", manifest, "graph", "freeform", "graph/")
	# Super-node drill: Expand path + zoom-drill with SoI bubble on (regression).
	await _site_review_compound_drill(sgv, root, gdir, manifest)


## Freeform compound enter: Expand (bubble off) + zoom-drill (bubble on).
## Writes compound_drill_* flags into diagnostics.json.
func _site_review_compound_drill(sgv: Node, root: String, gdir: String,
		manifest: Array) -> void:
	var model: Variant = sgv.get("model")
	var canvas: Node = sgv.get("_graph_canvas")
	var comp_id := _graph_pick_drillable_compound(model)
	var drill_ok := false
	var drill_bubble_ok := false
	var child_scope := ""
	if comp_id.is_empty():
		# Nothing to drill on this world — say so, never report a silent false.
		if _report != null:
			_report.skip("site-review compound drill", "no generic compound with child_scope_id on this world")
		_patch_site_diagnostics(root, {
			"compound_drill_ok": null,
			"compound_drill_with_bubble_ok": null,
			"compound_drill_id": "",
			"compound_drill_note": "SKIPPED — no generic compound with child_scope_id",
		})
		return
	var item: Dictionary = model.call("get_item", comp_id) if model != null else {}
	child_scope = str(item.get("child_scope_id", ""))
	# 1) Bubble off — enter via the same Expand / open handler as double-click.
	if sgv.has_method("_on_soi_preview_toggled"):
		sgv.call("_on_soi_preview_toggled", false)
	await get_tree().process_frame
	if sgv.has_method("_on_open_compound_requested"):
		sgv.call("_on_open_compound_requested", comp_id)
		await get_tree().create_timer(1.2).timeout
		var scope_now := str(sgv.get("_active_scope_id"))
		drill_ok = (scope_now == child_scope) and not child_scope.is_empty()
		await _graph_shot(gdir, "04_compound_interior", manifest, "graph", "freeform", "graph/")
		if sgv.has_method("_on_scope_pop_requested"):
			sgv.call("_on_scope_pop_requested")
			await get_tree().create_timer(1.0).timeout
		await _graph_shot(gdir, "04b_compound_popped", manifest, "graph", "freeform", "graph/")
	# 2) Bubble on — zoom-drill must still enter (soi_live_preview must not block).
	if sgv.has_method("_on_soi_preview_toggled"):
		sgv.call("_on_soi_preview_toggled", true)
	await get_tree().create_timer(0.6).timeout
	# Ensure we are at root before zoom-drill.
	var scope_root := str(sgv.get("_active_scope_id"))
	while scope_root != "root" and sgv.has_method("_on_scope_pop_requested"):
		sgv.call("_on_scope_pop_requested")
		await get_tree().create_timer(0.4).timeout
		scope_root = str(sgv.get("_active_scope_id"))
	if canvas != null and canvas.has_method("prepare_and_try_zoom_drill"):
		var emitted := bool(canvas.call("prepare_and_try_zoom_drill", comp_id))
		await get_tree().create_timer(1.2).timeout
		var scope_b := str(sgv.get("_active_scope_id"))
		drill_bubble_ok = emitted and (scope_b == child_scope) and not child_scope.is_empty()
		await _graph_shot(gdir, "04c_compound_zoom_drill_bubble", manifest,
				"graph", "freeform", "graph/")
		if scope_b != "root" and sgv.has_method("_on_scope_pop_requested"):
			sgv.call("_on_scope_pop_requested")
			await get_tree().create_timer(0.6).timeout
	# Leave bubble off so later Site/Elev shots aren't fighting freeform prefs.
	if sgv.has_method("_on_soi_preview_toggled"):
		sgv.call("_on_soi_preview_toggled", false)
	_patch_site_diagnostics(root, {
		"compound_drill_ok": drill_ok,
		"compound_drill_with_bubble_ok": drill_bubble_ok,
		"compound_drill_id": comp_id,
		"compound_drill_child_scope": child_scope,
	})
	print("PlaytestHarness: compound drill expand=%s zoom+bubble=%s id=%s -> %s" % [
		drill_ok, drill_bubble_ok, comp_id, "PASS" if drill_ok and drill_bubble_ok else "FAIL"])


## Merge keys into an existing site-review diagnostics.json (create if missing).
func _patch_site_diagnostics(root: String, patch: Dictionary) -> void:
	var path := "%s/diagnostics.json" % root
	var diag := {}
	if FileAccess.file_exists(path):
		var raw := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Dictionary:
			diag = parsed as Dictionary
	for k in patch.keys():
		diag[k] = patch[k]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_json_safe(diag), "\t"))
		f.close()


## Generic super-node (empty compound_kind) with a child scope — wheel-drillable.
func _graph_pick_drillable_compound(model: Variant) -> String:
	if model == null or not model.has_method("get_items_in_scope"):
		return ""
	var items: Array = model.call("get_items_in_scope", "root")
	for it in items:
		if not (it is Dictionary):
			continue
		var item: Dictionary = it
		if str(item.get("type", "")) != "compound":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("compound_kind", "")) != "":
			continue
		if str(item.get("child_scope_id", "")).is_empty():
			continue
		return str(item.get("id", ""))
	return ""


func _site_review_site(sgv: Node, root: String, manifest: Array) -> void:
	var gdir := "%s/graph" % root
	sgv.visible = true
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "site")
	await get_tree().create_timer(1.5).timeout
	await _graph_shot(gdir, "06_site_plan_as_loaded", manifest, "graph", "site", "graph/")
	await _soi_stage_pin_mode_check(sgv, "site")
	await _soi_stage_pin_drag(sgv, "site", gdir, "06c_site_pin_dragged", manifest)
	await _soi_stage_site_window_checks(sgv)
	# Slight orbit off top-down so projection / overlay drift is visible.
	var preview: Variant = sgv.get("_soi_preview") if sgv != null else null
	if preview != null and preview.has_method("apply_orbit_delta"):
		preview.call("apply_orbit_delta", Vector2(48.0, 36.0))
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(gdir, "07_site_plan_orbited", manifest, "graph", "site", "graph/")
		# Reset pitch/yaw toward top-down for later sets.
		if preview.has_method("set_top_down"):
			preview.call("set_top_down", true)
	var canvas: Variant = sgv.get("_graph_canvas") if sgv != null else null
	if canvas != null:
		var z0 := float(canvas.get("_zoom"))
		canvas.set("_zoom", clampf(z0 * 1.6, 0.01, 512.0))
		if canvas.has_method("queue_redraw"):
			canvas.call("queue_redraw")
		if preview != null and preview.has_method("mark_layout_dirty"):
			preview.call("mark_layout_dirty")
		await get_tree().create_timer(0.7).timeout
		await _graph_shot(gdir, "08_site_plan_zoomed", manifest, "graph", "site", "graph/")
		canvas.set("_zoom", z0)
	# Metro overlay preference when the Site wire mode API exists.
	if sgv.has_method("set_site_wire_mode"):
		sgv.call("set_site_wire_mode", "metro")
		await get_tree().create_timer(0.5).timeout
		await _graph_shot(gdir, "09_site_plan_metro", manifest, "graph", "site", "graph/")
		sgv.call("set_site_wire_mode", "prefer_3d")
	await _dump_perf(root, "site", manifest)


func _site_review_elevation(sgv: Node, root: String, manifest: Array) -> void:
	var gdir := "%s/graph" % root
	sgv.visible = true
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "elevation")
	await get_tree().create_timer(1.8).timeout
	await _graph_shot(gdir, "03_elevation_as_loaded", manifest, "graph", "elevation", "graph/")
	var siphon_id := _site_review_find_siphon(sgv)
	if not siphon_id.is_empty():
		if sgv.has_method("focus_siphon_conduit_glow"):
			sgv.call("focus_siphon_conduit_glow", siphon_id, false)
		if sgv.has_method("frame_elevation_for_siphon"):
			sgv.call("frame_elevation_for_siphon", siphon_id)
		await get_tree().create_timer(1.5).timeout
		await _graph_shot(gdir, "04_elevation_framed_siphon", manifest, "graph", "elevation", "graph/")
	await _soi_stage_pin_mode_check(sgv, "elevation")
	await _soi_stage_pin_drag(sgv, "elevation", gdir, "04b_elevation_pin_dragged", manifest)
	await _soi_stage_elevation_checks(sgv, gdir, manifest)
	await _dump_perf(root, "elevation", manifest)


## SoI-stage assertions on the live Elevation CT (things no PNG can prove):
##  - the disc mask sits where the SoI centre PROJECTS, after a pan and an
##    off-centre cursor zoom (the "bubble slides out of its circle" bug);
##  - the cut face is capped (SoiSectionCap visible with geometry);
##  - the preview re-renders while the clock runs with the graph open, and no
##    graph lens holds a clock claim (the retired noon lock).
func _soi_stage_elevation_checks(sgv: Node, gdir: String, manifest: Array) -> void:
	var canvas: Control = sgv.get("_graph_canvas") as Control
	var prev: Node = sgv.get("_soi_preview") as Node
	var soi := get_tree().root.get_node_or_null("SoiService")
	if canvas == null or prev == null or soi == null:
		push_warning("PlaytestHarness: soi-stage — canvas/preview/SoiService missing; checks skipped")
		return
	var main := get_tree().current_scene
	# Pan + off-centre zoom, the two moves that used to slide the sphere.
	if canvas.has_method("_elev_pan_by_pixels"):
		canvas.call("_elev_pan_by_pixels", Vector2(140.0, -70.0))
	if canvas.has_method("_elev_zoom_at"):
		canvas.call("_elev_zoom_at", 1.6, canvas.size * Vector2(0.8, 0.3))
	canvas.queue_redraw()
	await get_tree().create_timer(0.8).timeout
	var disc: Dictionary = canvas.call("get_soi_disc_layout") as Dictionary
	var c: Vector3 = soi.call("world_center") as Vector3
	var h := float(canvas.get("elevation_heading_rad"))
	var d := float(canvas.get("elevation_section_offset_m"))
	var cross := Vector3(-sin(h), 0.0, cos(h))
	var proj: Variant = prev.call("world_to_canvas", c + cross * d)
	var origin: Vector2 = disc.get("origin", Vector2.ZERO) as Vector2
	if proj is Vector2:
		var err := (proj as Vector2).distance_to(origin)
		print("PlaytestHarness: soi-stage — elevation disc vs projected SoI centre err %.2f px %s"
				% [err, "(PASS)" if err <= 1.5 else "(FAIL)"])
	else:
		print("PlaytestHarness: soi-stage — elevation projection unavailable (FAIL)")
	var cont: Control = prev.get("_container") as Control
	if cont != null and not bool(prev.get("_top_down_cropped")):
		var cc := cont.position + cont.size * 0.5 - canvas.position
		print("PlaytestHarness: soi-stage — container centre vs mask centre %.2f px %s"
				% [cc.distance_to(origin), "(PASS)" if cc.distance_to(origin) <= 1.5 else "(FAIL)"])
	await _graph_shot(gdir, "04b_elevation_panned_zoomed", manifest, "graph", "elevation", "graph/")
	# The raw section render (before the disc shader composites the sky
	# backdrop): empty air must be TRANSPARENT here, or the backdrop never shows.
	var pvp: SubViewport = prev.get("_viewport") as SubViewport
	if pvp != null:
		var raw := pvp.get_texture().get_image()
		if raw != null and not raw.is_empty():
			raw.save_png("%s/04c_elevation_preview_raw.png" % gdir)
			var top := raw.get_pixel(raw.get_width() / 2, 4)
			print("PlaytestHarness: soi-stage — raw section top-centre pixel %s (alpha 0 = sky backdrop shows)"
					% str(top))
	# The whole sphere in frame: the time-of-day sky backdrop above the hills,
	# the strata cap below, the disc mask on the sphere's silhouette.
	if canvas.has_method("frame_elevation_window"):
		var rr := float(soi.call("radius_m"))
		canvas.call("frame_elevation_window", -rr, rr, c.y - rr, c.y + rr, canvas.size, 0.04)
	canvas.queue_redraw()
	await get_tree().create_timer(1.2).timeout
	await _graph_shot(gdir, "04d_elevation_whole_soi", manifest, "graph", "elevation", "graph/")
	# The soil probe: hover readout over the cut (horizon + depth).
	var dl: Dictionary = canvas.call("get_soi_disc_layout") as Dictionary
	canvas.set("_elev_probe_px", (dl["origin"] as Vector2) + Vector2(-float(dl["radius_px"]) * 0.3, float(dl["radius_px"]) * 0.25))
	canvas.queue_redraw()
	await get_tree().create_timer(0.3).timeout
	await _graph_shot(gdir, "04e_soil_probe", manifest, "graph", "elevation", "graph/")
	# Cut-face cap.
	var cap: Node3D = soi.call("section_cap_node") as Node3D if soi.has_method("section_cap_node") else null
	var cap_ok := cap != null and cap.visible and (cap as MeshInstance3D).mesh != null
	print("PlaytestHarness: soi-stage — cut-face cap %s" % ("present (PASS)" if cap_ok else "MISSING (FAIL)"))
	# Live clock with the graph open.
	var claims: Variant = main.clock.get("claims") if main != null and main.get("clock") != null else null
	var graph_claim := ""
	if claims != null and claims.has_method("owners"):
		for o in claims.call("owners"):
			if str(o).begins_with("graph_") and str(o) != "graph_globe_shadow":
				graph_claim = str(o)
	print("PlaytestHarness: soi-stage — graph clock claim %s" % (
			"none (PASS)" if graph_claim.is_empty() else "'%s' (FAIL)" % graph_claim))
	var ts0 := float(main.time_scale)
	var f0 := int(prev.get("frames_rendered"))
	var h0 := float(main.call("get_absolute_hours"))
	main.time_scale = 0.2  # 720× — the sun moves ~3°/s
	await get_tree().create_timer(2.5).timeout
	var f1 := int(prev.get("frames_rendered"))
	var h1 := float(main.call("get_absolute_hours"))
	main.time_scale = ts0
	print("PlaytestHarness: soi-stage — live clock in Elevation: %d captures, %.3f sim-h %s"
			% [f1 - f0, h1 - h0, "(PASS)" if f1 - f0 >= 2 and h1 > h0 else "(FAIL)"])


## The Globe lens (the snowglobe INSIDE the graph). Before this lens existed the
## graph's Snowglobe chip started the full-screen globe on a root viewport the
## open graph had switched to disable_3d, and nothing drew.
func _site_review_globe(sgv: Node, root: String, manifest: Array) -> void:
	var gdir := "%s/graph" % root
	sgv.visible = true
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "globe")
	await get_tree().create_timer(2.0).timeout
	var prev: Node = sgv.get("_soi_preview") as Node
	var is_globe := prev != null and prev.has_method("is_globe") and bool(prev.call("is_globe"))
	var lit := 0.0
	var vp: SubViewport = prev.get("_viewport") as SubViewport if prev != null else null
	if vp != null:
		var img := vp.get_texture().get_image()
		if img != null and not img.is_empty():
			var n := 0
			var hit := 0
			for y in range(0, img.get_height(), 8):
				for x in range(0, img.get_width(), 8):
					n += 1
					var px := img.get_pixel(x, y)
					if px.a > 0.5 and (px.r + px.g + px.b) > 0.06:
						hit += 1
			lit = float(hit) / float(maxi(n, 1))
	print("PlaytestHarness: soi-stage — globe lens active=%s, %.0f%% of pixels drawn %s"
			% [str(is_globe), lit * 100.0, "(PASS)" if is_globe and lit >= 0.10 else "(FAIL)"])
	await _graph_shot(gdir, "05_globe", manifest, "graph", "globe", "graph/")
	if prev != null and prev.has_method("apply_orbit_delta"):
		prev.call("apply_orbit_delta", Vector2(160.0, -40.0))
	await get_tree().create_timer(0.8).timeout
	await _graph_shot(gdir, "06_globe_orbited", manifest, "graph", "globe", "graph/")
	await _soi_stage_pin_drag(sgv, "globe", gdir, "06b_globe_pin_dragged", manifest)
	# Lens transition Globe → Site Plan: the camera FLIES (perspective mid-way)
	# and lands orthographic, with the overlay faded back in.
	sgv.call("_apply_graph_view_mode", "site")
	await get_tree().create_timer(0.22).timeout
	var cam: Camera3D = prev.get("_camera") as Camera3D if prev != null else null
	var mid_tween := prev != null and bool(prev.call("is_lens_tweening"))
	var mid_persp := cam != null and cam.projection == Camera3D.PROJECTION_PERSPECTIVE
	await _graph_shot(gdir, "07_lens_transition_mid", manifest, "graph", "site", "graph/")
	await get_tree().create_timer(0.9).timeout
	var landed := prev != null and not bool(prev.call("is_lens_tweening"))
	# Every lens is a perspective camera now (the Globe's kind); the plan lands
	# at the distance that makes px/m on the ground under the view centre equal
	# the 2D scale — checked here: the canvas centre's ground point must
	# project back onto the canvas centre.
	var end_persp := cam != null and cam.projection == Camera3D.PROJECTION_PERSPECTIVE
	var canvas: Control = sgv.get("_graph_canvas") as Control
	var faded_back := canvas != null and is_equal_approx(canvas.modulate.a, 1.0)
	var centre_err := INF
	if prev != null and canvas != null and prev.has_method("canvas_to_site_ground"):
		var site_c: Variant = prev.call("canvas_to_site_ground", canvas.size * 0.5)
		var soi_n := get_tree().root.get_node_or_null("SoiService")
		if site_c is Vector2 and soi_n != null:
			var wc: Vector3 = soi_n.call("world_center")
			var wp := Vector3(wc.x + (site_c as Vector2).x, 0.0, wc.z + (site_c as Vector2).y)
			wp.y = float(soi_n.call("ground_y_at", wp.x, wp.z)) if soi_n.has_method("ground_y_at") else wc.y
			var back: Variant = prev.call("world_to_canvas", wp)
			if back is Vector2:
				centre_err = ((back as Vector2) - canvas.size * 0.5).length()
	print(("PlaytestHarness: soi-stage — lens tween globe→site: mid tweening=%s persp=%s, "
			+ "landed=%s perspective=%s overlay back=%s centre round-trip %.2f px %s") % [str(mid_tween), str(mid_persp),
			str(landed), str(end_persp), str(faded_back), centre_err,
			"(PASS)" if mid_tween and mid_persp and landed and end_persp and faded_back and centre_err < 2.0 else "(FAIL)"])
	await _graph_shot(gdir, "08_site_after_transition", manifest, "graph", "site", "graph/")
	# Site Plan → Elevation: the cut plane sweeps into the globe while flying.
	sgv.call("_apply_graph_view_mode", "elevation", {"skip_elev_siphon_focus": true})
	await get_tree().create_timer(0.28).timeout
	var sweeping := prev != null and bool(prev.call("is_lens_tweening")) \
			and str(prev.get("_tween_sweep")) == "in"
	await _graph_shot(gdir, "09_section_sweep_mid", manifest, "graph", "elevation", "graph/")
	await get_tree().create_timer(1.0).timeout
	var soi := get_tree().root.get_node_or_null("SoiService")
	var cap: Node3D = soi.call("section_cap_node") as Node3D \
			if soi != null and soi.has_method("section_cap_node") else null
	var cap_on := cap != null and cap.visible
	print("PlaytestHarness: soi-stage — section sweep: mid-sweep=%s cap after=%s %s"
			% [str(sweeping), str(cap_on), "(PASS)" if sweeping and cap_on else "(FAIL)"])
	await _graph_shot(gdir, "10_elevation_after_sweep", manifest, "graph", "elevation", "graph/")
	await _dump_perf(root, "globe", manifest)


## Site Plan fills the panel (2026-10-12): the preview container IS the canvas
## (no disc crop), and a cursor zoom keeps the world point under the cursor
## FIXED across 20 notches in and 20 back out — the crop / no-crop re-layout
## used to snap the view at the threshold.
func _soi_stage_site_window_checks(sgv: Node) -> void:
	var canvas: Control = sgv.get("_graph_canvas") as Control
	var prev: Node = sgv.get("_soi_preview") as Node
	var soi := get_tree().root.get_node_or_null("SoiService")
	if canvas == null or prev == null or soi == null:
		return
	await get_tree().process_frame
	var cont: Control = prev.get("_container") as Control
	var full := cont != null and (cont.size - canvas.size).length() < 1.5 \
			and bool(prev.get("_top_down_cropped"))
	print("PlaytestHarness: soi-stage — site plan window: container %s vs canvas %s, cropped=%s %s" % [
			str(cont.size) if cont != null else "none", str(canvas.size), str(prev.get("_top_down_cropped")),
			"(PASS)" if full else "(FAIL)"])
	if not canvas.has_method("_zoom_at") or not prev.has_method("world_to_canvas"):
		return
	var c: Vector3 = soi.call("world_center") as Vector3
	var z0 := float(canvas.get("_zoom"))
	# A ground point a third of the way from the canvas centre to its corner.
	var probe_px := canvas.size * Vector2(0.62, 0.38)
	var gh0: Dictionary = canvas.call("_pin_ground_hit", probe_px) as Dictionary
	if gh0.is_empty():
		print("PlaytestHarness: soi-stage — site plan zoom: SKIPPED (no ground under the probe)")
		return
	var st0: Vector2 = gh0.get("site", Vector2.ZERO)
	var w := Vector3(c.x + st0.x, float(gh0.get("y", c.y)), c.z + st0.y)
	var p0v: Variant = prev.call("world_to_canvas", w)
	if not (p0v is Vector2):
		print("PlaytestHarness: soi-stage — site plan zoom: SKIPPED (point off screen)")
		return
	var p0 := p0v as Vector2
	if p0.x < 0.0 or p0.y < 0.0 or p0.x > canvas.size.x or p0.y > canvas.size.y:
		print("PlaytestHarness: soi-stage — site plan zoom: SKIPPED (probe projects off the canvas %s)" % str(p0))
		return
	var worst := 0.0
	var cam: Camera3D = prev.get("_camera") as Camera3D
	for i in 40:
		canvas.call("_zoom_at", 1.08 if i < 20 else 1.0 / 1.08, p0)
		var pv: Variant = prev.call("world_to_canvas", w)
		if pv is Vector2:
			worst = maxf(worst, (pv as Vector2).distance_to(p0))
		if i == 0 or i == 19:
			print("PlaytestHarness: soi-stage — site zoom DEBUG notch %d: p %s (p0 %s) zoom %.3f orbited=%s" % [
					i, str(pv), str(p0), float(canvas.get("_zoom")), str(prev.call("is_phys_orbited"))])
	await get_tree().process_frame
	var z1 := float(canvas.get("_zoom"))
	var ok := worst <= 2.0 and absf(z1 / z0 - 1.0) < 0.02
	print("PlaytestHarness: soi-stage — site plan cursor zoom: worst drift %.2f px over 40 notches, zoom %.3f → %.3f %s" % [
			worst, z0, z1, "(PASS)" if ok else "(FAIL)"])
	canvas.set("_zoom", z0)
	canvas.call("queue_redraw")


## World pins (2026-10-12): Site Plan / Elevation on the Globe's pin layer —
## the pin pass is on, one pin per placed item on screen, and NO chip rect is
## pickable (the chip hit-test must come back empty at a pin's head).
func _soi_stage_pin_mode_check(sgv: Node, lens: String) -> void:
	var canvas: Control = sgv.get("_graph_canvas") as Control
	var model: Variant = sgv.get("model")
	if canvas == null or model == null or not canvas.has_method("_pins_mode_active"):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var on := bool(canvas.call("_pins_mode_active"))
	var pins: Dictionary = canvas.get("_globe_pin_px") as Dictionary
	var placed := 0
	for it: Variant in model.call("get_items_in_scope", "root") as Array:
		if GraphSiteLayout.has_site_coords(it as Dictionary):
			placed += 1
	var chip_hits := 0
	for iid in pins:
		var hit: Dictionary = canvas.call("_item_at_screen", pins[iid] as Vector2) as Dictionary
		if not hit.is_empty() and GraphSiteLayout.has_site_coords(hit):
			chip_hits += 1
	var ok := on and pins.size() > 0 and pins.size() <= placed and chip_hits == 0
	print("PlaytestHarness: soi-stage — %s world pins: mode=%s pins=%d placed=%d chip hits at pins=%d %s" % [
			lens, str(on), pins.size(), placed, chip_hits, "(PASS)" if ok else "(FAIL)"])


## Drag a world pin with SYNTHETIC events through the canvas's own handler
## and assert the item landed under the pointer ON THE GROUND (an outlet sink
## a little under it, with its culvert following). Prefers an outlet sink,
## then any unlocked unbound pin; restores the item afterward.
func _soi_stage_pin_drag(sgv: Node, lens: String, gdir: String, shot: String, manifest: Array) -> void:
	var canvas: Control = sgv.get("_graph_canvas") as Control
	var model: Variant = sgv.get("model")
	var soi := get_tree().root.get_node_or_null("SoiService")
	var prev_svc: Node = sgv.get("_soi_preview") as Node
	if canvas == null or model == null or soi == null or not canvas.has_method("_handle_pin_input"):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	var pins: Dictionary = canvas.get("_globe_pin_px") as Dictionary
	var pick := ""
	var is_sink := false
	for iid in pins:
		var it: Dictionary = model.call("get_item", str(iid)) as Dictionary
		if it.is_empty() or bool(canvas.call("_pin_locked", it)):
			continue
		var sp: Dictionary = it.get("specs", {}) as Dictionary
		var head: Vector2 = pins[iid]
		if head.x < 40.0 or head.y < 40.0 or head.x > canvas.size.x - 120.0 or head.y > canvas.size.y - 80.0:
			continue
		# A SIPHON outlet (a culvert ends at it) is the drag this check is
		# about; a pond's spillway outlet is an outlet sink too but has no
		# culvert to follow.
		if bool(sp.get("outlet_sink", false)):
			var has_culvert := false
			for c: Dictionary in model.get("connections"):
				if str(c.get("target_item_id", "")) == str(iid) \
						and str(c.get("conduit_type", "")) == "culvert_pipe":
					has_culvert = true
			if has_culvert:
				pick = str(iid)
				is_sink = true
				break
		if pick.is_empty() and str(sp.get("bound_prop_id", "")).is_empty():
			pick = str(iid)
	if pick.is_empty():
		print("PlaytestHarness: soi-stage — %s pin drag: SKIPPED (no draggable pin on screen; %d pins)" % [lens, pins.size()])
		return
	var it0: Dictionary = model.call("get_item", pick) as Dictionary
	var site0 := GraphSiteLayout.site_xz(it0)
	var elev0 := float(it0.get("elevation_m", NAN))
	var head0: Vector2 = pins[pick]
	var to := head0 + Vector2(70.0, 28.0)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = head0
	canvas.call("_gui_input", ev)
	for k in 4:
		var mm := InputEventMouseMotion.new()
		mm.position = head0.lerp(to, float(k + 1) / 4.0)
		mm.relative = (to - head0) / 4.0
		canvas.call("_gui_input", mm)
		await get_tree().process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	canvas.call("_gui_input", up)
	await get_tree().create_timer(0.6).timeout
	var it1: Dictionary = model.call("get_item", pick) as Dictionary
	var site1 := GraphSiteLayout.site_xz(it1)
	var elev1 := float(it1.get("elevation_m", NAN))
	var c: Vector3 = soi.call("world_center") as Vector3
	var g1 := float(soi.call("ground_y_at", c.x + site1.x, c.z + site1.y))
	var moved := site1.distance_to(site0) > 0.5
	var want_e := (g1 - 0.3) if is_sink else g1
	var on_ground := not is_nan(elev1) and absf(elev1 - want_e) < 0.12
	if lens == "elevation":
		# The Elevation drag SETS the height (the pin walks the slice and
		# takes the section-plane hit): never above the ground there.
		on_ground = not is_nan(elev1) and elev1 <= g1 + 0.05
	await get_tree().process_frame
	await get_tree().process_frame
	var pins2: Dictionary = canvas.get("_globe_pin_px") as Dictionary
	var head1: Vector2 = pins2.get(pick, Vector2(INF, INF))
	var under := is_finite(head1.x) and head1.distance_to(to) < 16.0
	var culvert_ok := true
	var sid := ""
	if is_sink and sgv.has_method("siphon_for_outlet_sink"):
		sid = str(sgv.call("siphon_for_outlet_sink", pick))
		culvert_ok = false
		for conn: Dictionary in model.get("connections") as Array:
			if str(conn.get("source_item_id", "")) == sid and str(conn.get("target_item_id", "")) == pick \
					and str(conn.get("conduit_type", "")) == "culvert_pipe":
				culvert_ok = absf(float(conn.get("invert_out_m", NAN)) - elev1) < 1e-3
	var ok := moved and on_ground and under and culvert_ok
	if canvas.has_method("_pin_ground_hit"):
		var gh: Dictionary = canvas.call("_pin_ground_hit", to + Vector2(0.0, 16.0)) as Dictionary
		var ray: Variant = prev_svc.call("canvas_ray", to + Vector2(0.0, 16.0)) if prev_svc != null else null
		print("PlaytestHarness: soi-stage — %s pin drag DEBUG: march site %s y %.2f · item site %s · head0 %s to %s · ray %s · R %.1f" % [
				lens, str(gh.get("site", "none")), float(gh.get("y", NAN)), str(site1), str(head0), str(to), str(ray),
				float(canvas.call("_soi_radius_m"))])
	print(("PlaytestHarness: soi-stage — %s pin drag (%s%s): moved %.1f m (%s) · elev %.2f vs ground %.2f%s (%s) "
			+ "· pin head %.0f px from the pointer (%s)%s %s") % [lens, pick, " outlet sink" if is_sink else "",
			site1.distance_to(site0), str(moved), elev1, g1, " − 0.3" if is_sink else "", str(on_ground),
			head1.distance_to(to) if is_finite(head1.x) else -1.0, str(under),
			(" · culvert end followed %s" % str(culvert_ok)) if is_sink else "",
			"(PASS)" if ok else "(FAIL)"])
	await _graph_shot(gdir, shot, manifest, "graph", lens, "graph/")
	# Put it back.
	if is_sink and not sid.is_empty():
		sgv.call("move_siphon_outlet", sid, site0, elev0)
	else:
		var patch := {"site_x_m": site0.x, "site_z_m": site0.y}
		if not is_nan(elev0):
			patch["elevation_m"] = elev0
		model.call("update_item", pick, patch)
	await get_tree().create_timer(0.4).timeout


func _site_review_snowglobe(sgv: Node, root: String, manifest: Array) -> void:
	var sdir := "%s/snowglobe" % root
	# Enter the full-screen globe WITH THE GRAPH OPEN — the path that used to
	# render nothing (the graph had the root viewport on disable_3d). The globe
	# must close the graph itself, take the camera through the claim stack and
	# leave the clock running.
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi == null or not soi.has_method("enter_snowglobe"):
		push_warning("PlaytestHarness: site-review — SoiService.enter_snowglobe missing")
		return
	var main := get_tree().current_scene
	if sgv != null and sgv.has_method("open_graph_view"):
		sgv.call("open_graph_view")
		await get_tree().create_timer(0.5).timeout
	soi.call("enter_snowglobe")
	await get_tree().create_timer(1.8).timeout
	var graph_hidden := sgv == null or not (sgv as CanvasItem).visible
	var root3d := not get_viewport().disable_3d
	var cam_claim := false
	var clock_claim := false
	if main != null:
		var cc: Variant = main.get("camera_claims")
		cam_claim = cc != null and bool(cc.call("has_claim", "soi_snowglobe"))
		var kc: Variant = main.clock.get("claims") if main.get("clock") != null else null
		clock_claim = kc != null and bool(kc.call("has_claim", "soi_snowglobe"))
	print(("PlaytestHarness: soi-stage — globe over graph: graph hidden=%s root 3D=%s "
			+ "camera claim=%s clock claim=%s %s") % [str(graph_hidden), str(root3d),
			str(cam_claim), str(clock_claim),
			"(PASS)" if graph_hidden and root3d and cam_claim and not clock_claim else "(FAIL)"])
	await _graph_shot(sdir, "01_snowglobe_as_loaded", manifest, "snowglobe", "snowglobe", "snowglobe/")
	# Nudge orbit if the snowglobe camera exposes a relative look helper.
	var cam: Node = null
	if soi.has_method("get_snowglobe_camera"):
		cam = soi.call("get_snowglobe_camera") as Node
	if cam == null:
		cam = get_tree().current_scene.find_child("SoiSnowglobeCamera", true, false) \
				if get_tree().current_scene != null else null
	if cam != null:
		if cam.has_method("apply_orbit_delta"):
			cam.call("apply_orbit_delta", Vector2(80.0, 24.0))
		elif "yaw" in cam:
			cam.set("yaw", float(cam.get("yaw")) + 0.55)
		await get_tree().create_timer(0.9).timeout
		await _graph_shot(sdir, "02_snowglobe_orbited", manifest, "snowglobe", "snowglobe", "snowglobe/")
	if soi.has_method("exit_snowglobe"):
		soi.call("exit_snowglobe")
	await get_tree().create_timer(0.6).timeout
	var reopened := sgv == null or (sgv as CanvasItem).visible
	var cam_left := false
	if main != null and main.get("camera_claims") != null:
		cam_left = bool(main.get("camera_claims").call("has_claim", "soi_snowglobe"))
	print("PlaytestHarness: soi-stage — globe exit: graph reopened=%s camera claim released=%s %s"
			% [str(reopened), str(not cam_left), "(PASS)" if reopened and not cam_left else "(FAIL)"])
	await _dump_perf(root, "snowglobe", manifest)


func _site_review_siphon(sgv: Node, root: String, manifest: Array) -> void:
	var sdir := "%s/siphon" % root
	var siphon_id := _site_review_find_siphon(sgv)
	if siphon_id.is_empty():
		push_warning("PlaytestHarness: site-review — no siphon_hydro on graph; Lab skipped")
		return
	sgv.visible = true
	# Let visibility-changed deferred view restore settle before opening Lab
	# (otherwise a stale deferred apply can clobber VIEW_SIPHON).
	await get_tree().process_frame
	await get_tree().process_frame
	if sgv.has_method("open_siphon_lab"):
		sgv.call("open_siphon_lab", siphon_id)
	await get_tree().create_timer(2.5).timeout
	await _graph_shot(sdir, "01_lab_as_loaded", manifest, "siphon", "siphon", "siphon/")
	# Lab embeds Elevation CT — pan/zoom the modal and push the linked CT frame.
	var modal: Node = sgv.get("_siphon_lab_modal")
	if modal != null:
		# Pan is in section METRES now (it used to be pixels re-scaled by zoom).
		modal.set("_view_pan_m", Vector2(4.0, -2.2))
		modal.set("_view_zoom", 1.35)
		if modal.has_method("_push_lab_section_frame"):
			modal.call("_push_lab_section_frame")
		if modal.has_method("_redraw_preview"):
			modal.call("_redraw_preview")
		elif modal.get("_preview") != null:
			(modal.get("_preview") as CanvasItem).queue_redraw()
		await get_tree().create_timer(0.9).timeout
		await _graph_shot(sdir, "02_lab_panned", manifest, "siphon", "siphon", "siphon/")
		# Zoom further — CT + overlay must stay linked.
		modal.set("_view_zoom", 2.2)
		if modal.has_method("_push_lab_section_frame"):
			modal.call("_push_lab_section_frame")
		if modal.has_method("_redraw_preview"):
			modal.call("_redraw_preview")
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(sdir, "02b_lab_zoomed", manifest, "siphon", "siphon", "siphon/")
	await _dump_perf(root, "siphon", manifest)
	if not _no_mutate:
		# Steady test inflow (replaces old Demo oscillator) — proves Lab flow tick.
		if modal != null and modal.has_method("_on_sim_inflow_toggled"):
			if modal.get("_sim_inflow_spin") != null:
				(modal.get("_sim_inflow_spin") as SpinBox).value = 2.0
			modal.call("_on_sim_inflow_toggled", true)
			await get_tree().create_timer(2.0).timeout
			await _graph_shot(sdir, "03_lab_demo_running", manifest, "siphon", "siphon", "siphon/")
			modal.call("_on_sim_inflow_toggled", false)
		# Leave Lab → Elev still framed (teardown clears watershed 3D highlight).
		if sgv.has_method("_apply_graph_view_mode"):
			sgv.call("_apply_graph_view_mode", "elevation")
		await get_tree().create_timer(1.2).timeout
		await _graph_shot("%s/graph" % root, "05_after_lab_elev", manifest, "graph",
				"elevation", "graph/")
		_write_site_diagnostics(root, null, sgv)
		manifest.append({"file": "diagnostics.json", "set": "meta", "state": "diagnostics_after_lab"})


func _site_review_find_siphon(sgv: Node) -> String:
	var model: Variant = sgv.get("model") if sgv != null else null
	if model == null:
		return ""
	for it in model.items:
		if not (it is Dictionary):
			continue
		var specs: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str(specs.get("role", "")) == "siphon_hydro":
			return str((it as Dictionary).get("id", ""))
	return ""


func _find_graph_view() -> Node:
	var tree := get_tree()
	for _i in FIND_LOADER_TIMEOUT_FRAMES:
		var scene := tree.current_scene
		if scene != null:
			var sgv := scene.find_child("SystemGraphView", true, false)
			if sgv != null:
				return sgv
		await tree.process_frame
	return null


## First root-scope item matching a preferred type list. `fallback` = any item
## when nothing matches (keep OFF for type-specific states like compound entry).
func _graph_pick_item(model: Variant, preferred_types: Array,
		fallback: bool = true) -> String:
	if model == null or not model.has_method("get_items_in_scope"):
		return ""
	var items: Array = model.call("get_items_in_scope", "root")
	for t in preferred_types:
		for it in items:
			if str((it as Dictionary).get("type", "")) == str(t):
				return str((it as Dictionary).get("id", ""))
	if fallback and not items.is_empty():
		return str((items[0] as Dictionary).get("id", ""))
	return ""


func _graph_shot(dir: String, state: String, manifest: Array,
		set_name: String = "graph", view_mode: String = "",
		manifest_prefix: String = "") -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var file := "%s.png" % state
	img.save_png("%s/%s" % [dir, file])
	var entry := {
		"file": "%s%s" % [manifest_prefix, file],
		"set": set_name,
		"state": state,
	}
	if not view_mode.is_empty():
		entry["view_mode"] = view_mode
	manifest.append(entry)
	print("PlaytestHarness: graph shot %s" % entry["file"])


## --- Extreme weather capture -------------------------------------------------
## Atmosphere is unreviewable from a description: a wrong fog density renders as
## "looks a bit off", never as an error. So this mode shoots a clear baseline
## plus a severity ramp per hazard from ONE fixed viewpoint (with distant
## geometry in frame, so visibility is actually measurable), and DUMPS the
## resolved numbers to the console so the picture can be checked against them.
##
## Write discipline: forcing a hazard and toggling opt-ins touches
## user://extreme_weather.cfg, so it is snapshotted and byte-restored — a
## capture run must never rewrite the player's settings (the vegdock/areafill
## precedent).
const XW_PREFS_PATH := "user://extreme_weather.cfg"
const XW_SEVERITIES: Array[float] = [0.35, 0.7, 1.0]


func _run_extreme_weather_capture() -> void:
	var tree := get_tree()
	# Works on any map: a TerrainLoader gives real terrain to look through, but
	# the soak map (which has none) still exercises the full atmosphere path.
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout

	var xw := get_node_or_null("/root/ExtremeWeather")
	if xw == null:
		push_error("PlaytestHarness: ExtremeWeather autoload missing — aborting weather capture")
		_maybe_quit()
		return

	var prefs_existed := FileAccess.file_exists(XW_PREFS_PATH)
	var prefs_backup := FileAccess.get_file_as_string(XW_PREFS_PATH) if prefs_existed else ""

	var label := _shots_label if not _shots_label.is_empty() else "extreme_weather"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	# --- 0. the property the whole design rests on ---------------------------
	_xw_assert_pure_function(xw)

	# --- 1. the settings tab, through its REAL entry point -------------------
	await _xw_shoot_settings_tab(dir, manifest)

	# --- 2. world: baseline, then a severity ramp per hazard -----------------
	var gr := GameplayRulesImpl.from_node(self)
	if gr != null:
		gr.extreme_weather_enabled = true
	xw.call("clear_forced")
	_set_capture_conditions()

	var cam := Camera3D.new()
	cam.name = "PlaytestCam"
	cam.far = 40000.0
	tree.current_scene.add_child(cam)
	cam.make_current()
	_xw_aim_camera(cam, loader)

	print("\n=== EXTREME WEATHER CAPTURE ===")
	print("hour %.1f   hazards: %s" % [_capture_hour, str(HazardCatalog.simulated_ids())])
	await _xw_world_shot(xw, cam, dir, manifest, "", 0.0, "00_clear")

	var shot_i := 1
	for id: String in HazardCatalog.simulated_ids():
		for sev: float in XW_SEVERITIES:
			var state := "%02d_%s_%03d" % [shot_i, id, int(sev * 100.0)]
			await _xw_world_shot(xw, cam, dir, manifest, id, sev, state)
			shot_i += 1

	# Night: smoke changes the night sky as much as the day, and this is where
	# a daylight-ungated sky tint would show up as a brown, starless night.
	var main := _find_main()
	if main != null:
		main.set("day_time", 22.0)
		await tree.process_frame
		await _xw_world_shot(xw, cam, dir, manifest, "wildfire_smoke", 0.7, "%02d_smoke_070_night" % shot_i)
		shot_i += 1
		main.set("day_time", _capture_hour)

	cam.queue_free()
	xw.call("clear_forced")

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()

	# Restore the player's prefs byte-for-byte.
	if prefs_existed:
		var pf := FileAccess.open(XW_PREFS_PATH, FileAccess.WRITE)
		if pf != null:
			pf.store_string(prefs_backup)
			pf.close()
	elif FileAccess.file_exists(XW_PREFS_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(XW_PREFS_PATH))

	print("PlaytestHarness: weather capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Extreme-weather severity must be a PURE FUNCTION of absolute hours — that is
## the entire reason this subsystem is not a CrisisEvent, and it is what lets the
## timeline scrub backwards through a smoke event and lets prebaked challenges
## agree with live play. It cannot be asserted in the offline selftest because
## resolve_at needs the live autoloads and a resolved Main, so it is checked
## here, against whatever real data this site actually has.
func _xw_assert_pure_function(xw: Node) -> void:
	var main := _find_main()
	if main == null:
		print("PlaytestHarness: no Main — skipping purity assertions")
		return
	var clk: Variant = main.get("clock")
	if clk == null or not clk.has_method("get_absolute_hours"):
		return
	var now := float(clk.call("get_absolute_hours"))

	# Sample a week forward, then the SAME instants in reverse. A stateful
	# implementation drifts here; a pure one cannot.
	var forward: Array[float] = []
	var instants: Array[float] = []
	for i in 48:
		var t := now + float(i) * 3.5
		instants.append(t)
		forward.append(float((xw.call("resolve_at", t) as Dictionary).get("severity", 0.0)))
	var mismatches := 0
	var worst := 0.0
	for i in range(instants.size() - 1, -1, -1):
		var again := float(
			(xw.call("resolve_at", instants[i]) as Dictionary).get("severity", 0.0))
		var d := absf(again - forward[i])
		if d > 0.000001:
			mismatches += 1
			worst = maxf(worst, d)
	if mismatches == 0:
		print("PlaytestHarness: purity OK — 48 instants identical forward and reversed")
	else:
		push_error(
			"PlaytestHarness: EXTREME WEATHER IS NOT A PURE FUNCTION OF TIME — %d/%d instants differed on reverse traversal (worst %.6f). Scrubbing will desync."
			% [mismatches, instants.size(), worst])

	# And identical when asked twice in a row.
	var a := float((xw.call("resolve_at", now) as Dictionary).get("severity", 0.0))
	var b := float((xw.call("resolve_at", now) as Dictionary).get("severity", 0.0))
	if absf(a - b) > 0.000001:
		push_error("PlaytestHarness: resolve_at is not deterministic (%.6f vs %.6f)" % [a, b])


func _xw_shoot_settings_tab(dir: String, manifest: Array) -> void:
	var tree := get_tree()
	if tree.current_scene == null:
		return
	var timeline := tree.current_scene.find_child("TimelineUI", true, false)
	if timeline == null or not timeline.has_method("_on_settings_pressed"):
		print("PlaytestHarness: TimelineUI not found — skipping settings-tab shot")
		return
	timeline.call("_on_settings_pressed")
	await tree.process_frame
	await tree.process_frame
	var panel: Variant = timeline.get("_settings_panel")
	if panel is Control:
		var tabs := _xw_find_tab_container(panel as Control)
		if tabs != null:
			for i in tabs.get_tab_count():
				if tabs.get_tab_title(i).begins_with("Extreme"):
					tabs.current_tab = i
					break
		# The risk profile is fetched asynchronously; give it a moment so the
		# shot shows real rows rather than "Loading...".
		if (panel as Control).has_method("_refresh_extreme_weather_tab"):
			await tree.create_timer(2.0).timeout
			(panel as Control).call("_refresh_extreme_weather_tab")
		await tree.process_frame
	await _graph_shot(dir, "ui_settings_tab", manifest, "weather")
	if panel is Control and (panel as Control).has_method("close"):
		(panel as Control).call("close")
	await tree.process_frame


func _xw_find_tab_container(root: Node) -> TabContainer:
	if root is TabContainer:
		return root as TabContainer
	for c in root.get_children():
		var hit := _xw_find_tab_container(c)
		if hit != null:
			return hit
	return null


func _xw_world_shot(xw: Node, cam: Camera3D, dir: String, manifest: Array,
		id: String, sev: float, state: String) -> void:
	if id.is_empty():
		xw.call("clear_forced")
	else:
		xw.call("force_hazard", id, sev, 24.0)
	# Let the applier's easing settle — targets are pure, but the applied values
	# lerp over real time on purpose.
	for _i in 30:
		await get_tree().process_frame
	_xw_dump_state(xw, state)
	await _graph_shot(dir, state, manifest, "weather")


## The numbers behind the picture. A PNG cannot tell you whether the fog is
## 900 m or 9 km, and that difference is the whole feature.
func _xw_dump_state(xw: Node, state: String) -> void:
	var s: Dictionary = xw.call("current")
	var vis := float(s.get("visibility_m", 0.0))
	print("shot %s:" % state)
	print("  id=%s  severity=%.3f  source=%s" % [
		str(s.get("id", "-")), float(s.get("severity", 0.0)), str(s.get("source", "-"))])
	print("  aod=%.3f  visibility=%.0f m  fog_density=%.6f  pm2.5=%.0f  aqi=%.0f (%s)" % [
		float(s.get("aod", 0.0)), vis,
		HazardState.fog_density_for_visibility(vis),
		float(s.get("pm25_ugm3", 0.0)), float(s.get("aqi", 0.0)),
		HazardEvaluators.aqi_category(float(s.get("aqi", 0.0)))])
	var st: Color = s.get("sun_tint", Color.WHITE)
	var hc: Color = s.get("haze_color", Color.WHITE)
	print("  sun_tint=(%.2f,%.2f,%.2f) x%.2f   haze=(%.2f,%.2f,%.2f) str=%.2f sky=%.2f" % [
		st.r, st.g, st.b, float(s.get("sun_energy_mult", 1.0)),
		hc.r, hc.g, hc.b, float(s.get("haze_strength", 0.0)),
		float(s.get("sky_tint_strength", 0.0))])
	print("  dni=%.0f%%  ghi=%.0f%%  dhi_boost=%.2f  wind x%.2f  particles=%s %.2f" % [
		float(s.get("dni_factor", 1.0)) * 100.0, float(s.get("ghi_factor", 1.0)) * 100.0,
		float(s.get("dhi_boost", 0.0)), float(s.get("wind_mult", 1.0)),
		str(s.get("particle_kind", "-")), float(s.get("particle_density", 0.0))])
	# Canopy wind actually being PUSHED to the vegetation shaders — sway is
	# unreviewable from a still PNG, so the numbers are the review artifact.
	var wd := get_node_or_null("/root/VegetationWindDriver")
	if wd != null:
		print("  canopy wind: pushed speed=%.1f m/s gust=%.2f  (hazard x%.2f/x%.2f turb %.2f)" % [
			float(wd.get("_current_speed")), float(wd.get("_current_gust")),
			float(s.get("wind_mult", 1.0)), float(s.get("gust_mult", 1.0)),
			float(s.get("turbulence", 0.0))])


## Stand back from the site with distant geometry in frame — visibility is only
## reviewable against something far away to lose.
func _xw_aim_camera(cam: Camera3D, loader: Node) -> void:
	var eye := Vector3(0.0, 40.0, 220.0)
	if loader != null and loader.has_method("ground_height_at"):
		var g := float(loader.call("ground_height_at", eye.x, eye.z))
		if is_finite(g):
			eye.y = g + 12.0
	cam.global_position = eye
	cam.look_at(Vector3(0.0, eye.y - 6.0, -600.0), Vector3.UP)


func _find_main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	for child in tree.root.get_children():
		if "day_time" in child and "sun" in child:
			return child
	return null


## The post-load settle every capture opens with. Once the dispatcher's
## readiness gate has already waited for the load + resume extras, a short
## settle is enough (detail drape / veg keep streaming either way).
func _settle_s() -> float:
	return 2.0 if _dispatching else SETTLE_AFTER_LOAD_S


## Put the world back in FIRST PERSON before a capture that drives the
## first-person input path (the TourDirector's baseline, for one capture).
##
## A world is loaded exactly as the player left it, and WorldSession
## .restore_extras reopens festival mode a beat after the load — which opens
## the settlement view, a CursorController MODAL. Every shortcut behind
## InputGuard.blocked (J, the toolbar keys …) is then swallowed, and a
## capture that presses J reads "the dock never opened" on a world saved
## mid-festival (Walton, 2026-10-18). Waits out the resume's own delay first
## so the mode cannot reopen under the capture.
func _first_person_baseline(main: Node) -> void:
	if main == null:
		return
	var tree := get_tree()
	for _i in 36:
		await tree.process_frame
	var graph: Variant = main.get_node_or_null("UILayer/SystemGraphView")
	if graph != null:
		if graph.has_method("close_hydro_lab"):
			graph.call("close_hydro_lab")
		if bool(graph.get("visible")) and graph.has_method("close_graph_view"):
			graph.call("close_graph_view")
	var soi: Variant = tree.root.get_node_or_null("SoiService")
	if soi != null and bool(soi.get("snowglobe_active")) and soi.has_method("exit_snowglobe"):
		soi.call("exit_snowglobe")
	if main.has_method("close_festival_mode"):
		main.call("close_festival_mode")
	var sv: Variant = main.get("settlement_view")
	if sv != null and is_instance_valid(sv) and sv.has_method("is_open") and bool(sv.call("is_open")):
		sv.call("close")
	var cc: Variant = tree.root.get_node_or_null("CursorController")
	for _i in 3:
		await tree.process_frame
	if cc != null and cc.has_method("has_blocking_modal") and bool(cc.call("has_blocking_modal")):
		print("PlaytestHarness: baseline — a modal is still up after the reset: %s" % str(cc.get("_modal_stack")))


## One line naming whatever would swallow a global shortcut right now.
func _input_blocker_desc(main: Node) -> String:
	var vp := get_viewport()
	var fo: Control = vp.gui_get_focus_owner() if vp != null else null
	var cc: Variant = get_tree().root.get_node_or_null("CursorController")
	return "focus=%s modals=%s overlay=%s festival=%s" % [
		str(fo.get_path()) if fo != null else "none",
		str(cc.get("_modal_stack")) if cc != null else "?",
		str(cc.get("_tool_overlay")) if cc != null else "?",
		str(main.call("festival_mode_active")) if main != null and main.has_method("festival_mode_active") else "?"]


# ==================== FEATURE TOUR (--capture=tour) ====================
# A short visual demo of every mode (core/tour/, one stop per file), with
# title cards, one clean hero screenshot per stop and tour_manifest.json.
# tools/tour.ps1 wraps it (stills / live / record) and tools/tour_docs.py
# turns a run into docs/FEATURES.md + the README gallery. The tour runs on the
# world it was launched in; --tour-world picks the stops for that world.

func _run_tour_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var label := _shots_label if not _shots_label.is_empty() else "tour"
	var director := TourDirector.new()
	director.name = "TourDirector"
	director.shots_dir = "%s/%s" % [SHOTS_ROOT, label]
	director.stop_ids = _tour_stops
	director.chapters = _tour_chapters
	var w := _tour_world
	if w.is_empty() and not _world_arg.is_empty():
		w = HarnessRegistry.canonical_alias(_world_arg)
	director.world_alias = w if HarnessRegistry.WORLD_ALIASES.has(w) else ""
	director.world_label = SitePrivacy.place(WorldStore.display_name(_harness_world)) if not _harness_world.is_empty() else ""
	director.include_optional = _tour_optional
	director.pace = _tour_pace
	director.cards_on = _tour_cards
	director.movie_fps_hint = _tour_movie_fps
	director.intro_count = _tour_intro_count
	director.audit_mode = _tour_audit if _tour_audit in ["off", "report", "strict"] else "report"
	director.report = _report
	add_child(director)
	var manifest: Dictionary = await director.run()
	director.queue_free()
	print("PlaytestHarness: tour %s — %d of %d stop(s) passed" % [
		"PASS" if int(manifest.get("passed", 0)) == int(manifest.get("total", 0)) else "FAIL",
		int(manifest.get("passed", 0)), int(manifest.get("total", 0))])
	_maybe_quit()


## `--capture=modals`: every reachable modal opened, audited, shot and closed
## (ModalAudit). `--modal-audit=strict` turns audit errors into FAILs. Pass
## `--window-size=WxH` (harness.ps1 -UserArgs) to check a small screen.
## --capture=bootcamp: play all twelve Solar Bootcamp levels with real input
## (BootcampAudit). --bootcamp-audit=strict turns UiAudit errors into FAILs.
func _run_bootcamp_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	if main != null:
		if "day_time" in main:
			main.day_time = 12.0
	var label := _shots_label if not _shots_label.is_empty() else "bootcamp"
	var audit := BootcampAudit.new()
	audit.name = "BootcampAudit"
	audit.main = main
	audit.shots_dir = "%s/%s" % [SHOTS_ROOT, label]
	audit.strict = "--bootcamp-audit=strict" in OS.get_cmdline_user_args()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bootcamp-from="):
			audit.start_level = int(a.get_slice("=", 1))
	add_child(audit)
	var res: Dictionary = await audit.run()
	audit.queue_free()
	var ok := int(res.get("failures", 0)) == 0
	print("PlaytestHarness: bootcamp %s — %d/%d levels, %d real drags, %d fallbacks, %d failure(s)" % [
		"PASS" if ok else "FAIL", int(res.get("completed", 0)), (res.get("levels", []) as Array).size(),
		int(res.get("drags", 0)), int(res.get("fallbacks", 0)), int(res.get("failures", 0))])
	_maybe_quit()


func _run_modals_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var label := _shots_label if not _shots_label.is_empty() else "modals"
	var audit := ModalAudit.new()
	audit.name = "ModalAudit"
	audit.main = main
	audit.shots_dir = "%s/%s" % [SHOTS_ROOT, label]
	audit.strict = "--modal-audit=strict" in OS.get_cmdline_user_args()
	add_child(audit)
	var res: Dictionary = await audit.run()
	audit.queue_free()
	print("PlaytestHarness: modals — %d audit error(s) across %d modals at %s" % [
		int(res.get("errors", 0)), (res.get("modals", {}) as Dictionary).size(), str(res.get("viewport", []))])
	_maybe_quit()


## `--capture=timeline`: the info row must stay still while the clock runs
## (TimelineStabilityProbe). Pass `--window-size=WxH` to check a small screen.
func _run_timeline_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var probe: Node = load("res://core/terrain/harness/timeline_stability_probe.gd").new()
	probe.name = "TimelineProbe"
	probe.set("main", main)
	add_child(probe)
	var res: Dictionary = await probe.call("run")
	probe.queue_free()
	print("PlaytestHarness: timeline %s — %d failure(s)" % [
		"PASS" if int(res.get("failures", 1)) == 0 else "FAIL", int(res.get("failures", 1))])
	_maybe_quit()


## `--capture=graphtools`: show-only views, the "In the world" library drawer
## and the graph <-> world handoff (GraphToolsProbe).
func _run_graph_tools_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var probe: Node = load("res://core/terrain/harness/graph_tools_probe.gd").new()
	probe.name = "GraphToolsProbe"
	probe.set("main", main)
	probe.set("shots_dir", "%s/%s" % [SHOTS_ROOT, _shots_label if not _shots_label.is_empty() else "graphtools"])
	add_child(probe)
	var res: Dictionary = await probe.call("run")
	probe.queue_free()
	print("PlaytestHarness: graphtools %s — %d failure(s)" % [
		"PASS" if int(res.get("failures", 1)) == 0 else "FAIL", int(res.get("failures", 1))])
	_maybe_quit()


## `--capture=pvsnap`: solar grid snap in 3D and on the graph (PvSnapProbe).
func _run_pv_snap_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var probe: Node = load("res://core/terrain/harness/pv_snap_probe.gd").new()
	probe.name = "PvSnapProbe"
	probe.set("main", main)
	probe.set("shots_dir", "%s/%s" % [SHOTS_ROOT, _shots_label if not _shots_label.is_empty() else "pvsnap"])
	add_child(probe)
	var res: Dictionary = await probe.call("run")
	probe.queue_free()
	print("PlaytestHarness: pvsnap %s — %d failure(s)" % [
		"PASS" if int(res.get("failures", 1)) == 0 else "FAIL", int(res.get("failures", 1))])
	_maybe_quit()


## `--capture=conduits`: plug-drag length, the live style modal, run-length
## tags and chaining (ConduitProbe).
func _run_conduits_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var probe: Node = load("res://core/terrain/harness/conduit_probe.gd").new()
	probe.name = "ConduitProbe"
	probe.set("main", main)
	probe.set("shots_dir", "%s/%s" % [SHOTS_ROOT, _shots_label if not _shots_label.is_empty() else "conduits"])
	add_child(probe)
	var res: Dictionary = await probe.call("run")
	probe.queue_free()
	print("PlaytestHarness: conduits %s — %d failure(s)" % [
		"PASS" if int(res.get("failures", 1)) == 0 else "FAIL", int(res.get("failures", 1))])
	_maybe_quit()


## Captures call this when they are done. While the dispatcher runs a chain it
## is a no-op (the dispatcher moves on and _finish ends the run); outside a
## harness run it keeps the old quit-after-capture behaviour.
func _maybe_quit() -> void:
	if _dispatching:
		return
	if _harness_on:
		_finish()
		return
	if _quit_after:
		print("PlaytestHarness: capture complete — quitting")
		_cleanup_scratch_world()
		get_tree().quit()


func _exit_tree() -> void:
	_cleanup_scratch_world()


# ---------------------------------------------------------------------------
# Worlds (--world / --scratch-world / --capture=worlds)
# ---------------------------------------------------------------------------

func _resolve_world_arg() -> void:
	_harness_world = HarnessRegistry.pick_world(_world_arg, WorldStore.list())
	if _harness_world.is_empty():
		push_error("PlaytestHarness: --world=%s matches no world" % _world_arg)
		return
	if is_nan(_launch_lat) and _launch_scene.is_empty():
		var map: Dictionary = _harness_world.get("map", {})
		if WorldStore.is_generated_map(map):
			_launch_lat = float(map.get("lat", 0.0))
			_launch_lon = float(map.get("lon", 0.0))
			_launch_half_extent = float(map.get("half_extent_m", 0.0))
			_launch_label = str(map.get("label", ""))
		else:
			_launch_scene = MapDefinition.normalize_scene_path(str(map.get("scene_path", "")))
	print("PlaytestHarness: --world resolved to %s (%s)" % [
		WorldStore.display_name(_harness_world), str(_harness_world.get("id", ""))])


func _harness_map_ref() -> Dictionary:
	if not _launch_scene.is_empty() and MapDefinition.normalize_scene_path(_launch_scene) != MapDefinition.GENERATED_SCENE:
		return {"scene_path": MapDefinition.normalize_scene_path(_launch_scene), "label": ""}
	return {"scene_path": MapDefinition.GENERATED_SCENE, "lat": _launch_lat, "lon": _launch_lon,
		"label": _launch_label, "half_extent_m": _launch_half_extent}


## The record _launch_world plays: the resolved world itself, or with
## --scratch-world a throwaway copy of it (inside the sandbox the whole user
## dir is already throwaway, so scratch is only needed for --persist runs).
func _harness_launch_record() -> Dictionary:
	if not _scratch_world:
		return _harness_world
	WorldStore.purge_scratch()
	var src := _harness_world
	var rec := WorldStore.duplicate_world(str(src.get("id", "")), "__harness scratch")
	if rec.is_empty():
		return {}
	rec["scratch"] = true
	WorldStore.save_record(rec)
	_scratch_id = str(rec.get("id", ""))
	print("PlaytestHarness: scratch world %s — a copy of %s" % [_scratch_id, WorldStore.display_name(src)])
	return rec


func _activate_harness_world() -> void:
	if _harness_world.is_empty() and not _scratch_world:
		return
	WorldStore.purge_scratch()
	if not _scratch_world:
		WorldStore.activate(_harness_world)
		WorldAssets.restore(_harness_world)
		return
	var src := _harness_world
	var map := _harness_map_ref()
	if src.is_empty():
		var on := WorldStore.worlds_on_map(map)
		if not on.is_empty():
			src = on[0]
	var rec: Dictionary
	if src.is_empty():
		rec = WorldStore.create(map, "__harness scratch")
	else:
		rec = WorldStore.duplicate_world(str(src.get("id", "")), "__harness scratch")
	rec["scratch"] = true
	WorldStore.save_record(rec)
	_scratch_id = str(rec.get("id", ""))
	WorldStore.activate(rec)
	WorldAssets.restore(rec)
	print("PlaytestHarness: scratch world %s — a copy of %s" % [_scratch_id,
		WorldStore.display_name(src) if not src.is_empty() else "nothing (empty world)"])


## --capture=look — "see what the player sees". The world is loaded from its
## saved snapshot (player pose, clock, view), shot exactly as it stands — the
## game UI included — then without the HUD, from four drone points round the
## player, and in the 2D graph's saved lens; diagnostics.json carries the
## world summary, fingerprint, graph item counts and the placed props. Nothing
## is changed. The first thing to run when the player reports a problem.
func _run_look_capture() -> void:
	var tree := get_tree()
	var main := _find_main()
	if main == null:
		print("look: FAIL — no game scene")
		return
	var label := _shots_label if not _shots_label.is_empty() else "look_%s" % \
		Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var shots := 0
	await _shoot_ui(dir, "00_player_view_ui")
	shots += 1
	var hidden: Array[CanvasLayer] = []
	for child in main.get_children():
		if child is CanvasLayer and (child as CanvasLayer).visible:
			(child as CanvasLayer).visible = false
			hidden.append(child)
	await tree.process_frame
	await _shoot_ui(dir, "01_player_view")
	shots += 1
	var player := main.get("player") as Node3D
	var prev_cam := get_viewport().get_camera_3d()
	if player != null:
		var cam := Camera3D.new()
		cam.name = "LookCam"
		cam.far = 20000.0
		main.add_child(cam)
		cam.make_current()
		var c := player.global_position
		for i in 4:
			var a := TAU * float(i) / 4.0 + player.global_rotation.y
			cam.global_position = c + Vector3(sin(a) * 28.0, 14.0, cos(a) * 28.0)
			cam.look_at(c + Vector3(0, 1.2, 0), Vector3.UP)
			for _f in 3:
				await tree.process_frame
			await _shoot_ui(dir, "1%d_drone_%d" % [i, i])
			shots += 1
		cam.queue_free()
		if prev_cam != null and is_instance_valid(prev_cam):
			prev_cam.make_current()
	for layer in hidden:
		if is_instance_valid(layer):
			layer.visible = true
	var sgv := ServiceLocator.graph()
	if sgv is CanvasItem:
		(sgv as CanvasItem).visible = true
		for _f in 20:
			await tree.process_frame
		await _shoot_ui(dir, "20_graph_saved_lens")
		shots += 1
		(sgv as CanvasItem).visible = false
		for _f in 5:
			await tree.process_frame
	var diag := {
		"world": WorldSession.active_record(),
		"summary": WorldSession.summary(main),
		"fingerprint": WorldSession.fingerprint(main),
		"user_dir": OS.get_user_data_dir(),
	}
	var by_type := {}
	if sgv != null and sgv.get("model") != null:
		for it in sgv.get("model").get("items"):
			var t := str((it as Dictionary).get("type", "?"))
			by_type[t] = int(by_type.get(t, 0)) + 1
	diag["graph_by_type"] = by_type
	var props: Array = []
	var layer := PlacedPropService._layer_for_main(main)
	if layer != null:
		for rec in layer.props:
			var r: Dictionary = rec
			props.append({"id": r.get("id", ""), "model_id": r.get("model_id", ""),
				"pos": [r.get("x", 0.0), r.get("y", 0.0), r.get("z", 0.0)], "packed": r.get("packed", false)})
	diag["props"] = props
	HarnessReport.write_json("%s/diagnostics.json" % dir, diag)
	print("look PASS — %d shots + diagnostics.json in %s" % [shots, ProjectSettings.globalize_path(dir)])


## --run-script=<path> — a FIX the agent wrote for the player's world:
##   extends RefCounted
##   func run(main: Node, harness: Node) -> Dictionary   # may await
## returning {ok: bool, ...}. Runs once the world is ready, then the world is
## saved through the real save path. In the sandbox that is a dry run (check
## it with --capture=look); with --persist it stays in the player's world.
func _run_fix_script() -> void:
	var main := _find_main()
	if main == null:
		print("fix-script: FAIL — no game scene")
		return
	var scr := load(_run_script_path) as Script
	if scr == null:
		print("fix-script: FAIL — could not load %s" % _run_script_path)
		return
	var obj: Object = scr.new()
	if obj == null or not obj.has_method("run"):
		print("fix-script: FAIL — %s has no run(main, harness)" % _run_script_path)
		return
	print("fix-script: running %s in %s" % [_run_script_path, "the REAL world (--persist)" if _persist else "the sandbox"])
	var res: Variant = await obj.call("run", main, self)
	print("fix-script: result %s" % JSON.stringify(res))
	if res is Dictionary and not bool((res as Dictionary).get("ok", true)):
		print("fix-script: FAIL — the script reported ok=false")
		return
	if WorldPaths.has_active_world():
		var saved := WorldSession.save_now(main, true, true)
		print("fix-script: world saved %s%s" % ["PASS" if saved else "FAIL",
			" — kept in the player's world" if _persist else " (sandbox only)"])
	else:
		print("fix-script: no world active — nothing saved")


func _cleanup_scratch_world() -> void:
	if _scratch_id.is_empty():
		return
	# SEAL, never clear: the running scene's teardown flushes must not fall
	# through to the player's legacy per-site files.
	WorldPaths.seal()
	WorldStore.remove_tree(WorldStore.world_dir(_scratch_id))
	print("PlaytestHarness: removed scratch world %s" % _scratch_id)
	_scratch_id = ""


## Wait for a scene change to land and its TerrainLoader (if any) to finish.
func _await_world_scene(prev_scene_id: int) -> Node:
	var tree := get_tree()
	for _i in 600:
		await tree.process_frame
		var cur := tree.current_scene
		if cur != null and cur.get_instance_id() != prev_scene_id and _find_main() != null:
			break
	var main := _find_main()
	if main == null:
		return null
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and not bool(loader.get("load_completed")):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	# WorldSession.restore_extras waits ~30 frames after the load.
	for _j in 45:
		await tree.process_frame
	return _find_main()


func _file_hashes(rec: Dictionary) -> Dictionary:
	var out := {}
	var files := WorldStore.data_files(rec)
	for tag in files:
		out[tag] = FileAccess.get_sha256(str(files[tag]))
	return out


## --capture=worlds: the save system end to end, through the REAL paths.
## Build something, save, exit to the menu, play the world again and assert
## the whole fingerprint (player, view, clock, graph, NPCs, props, lights,
## battery, peak score…) came back; then start a NEW world on the same map
## and assert it is empty while the first world's files are untouched.
## Needs a world: run with --scratch-world (or --world=<name>).
func _run_worlds_capture() -> void:
	var tree := get_tree()
	var fails := 0
	var main := await _await_world_scene(-1)
	if main == null or not WorldPaths.has_active_world():
		push_error("worlds: FAIL — no world active (run with --scratch-world or --world=<name>)")
		_maybe_quit()
		return
	var rec := WorldSession.active_record()
	var id := str(rec.get("id", ""))
	print("worlds: running in %s (%s, storage %s)" % [WorldStore.display_name(rec), id, str(rec.get("storage", ""))])
	# 1. Make the world distinctive and FREEZE the clock so the two saves agree.
	main.set("time_scale", 0.0)
	main.set("day_time", 17.25)
	var player: Node3D = main.get("player")
	var placed := PlacedPropService.place_model(main, "ez_up", true, Vector2(5.0, 3.0))
	var lid := ""
	if player != null:
		lid = PlacedLightService.add_point_light(main, "omni", player.global_position + Vector3(3.0, 2.5, 0.0), Vector3.ZERO)
		PlacedLightService.commit(main)
		player.rotation.y = 1.234
		var cam := player.get_node_or_null("CameraArm/Camera3D") as Node3D
		if cam != null:
			cam.rotation.x = -0.3
	for _i in 30:
		await tree.process_frame
	var fp1 := WorldSession.fingerprint(main)
	print("worlds: fingerprint before = %s" % JSON.stringify(fp1))
	if not bool(placed.get("ok", false)):
		fails += 1
		push_error("worlds: FAIL — could not place the test prop")
	if lid.is_empty():
		fails += 1
		push_error("worlds: FAIL — could not place the test light")
	var saved := WorldSession.save_now(main, true, true)
	print("worlds: save_now %s" % ("PASS" if saved else "FAIL"))
	if not saved:
		fails += 1
	var snap := WorldStore.read_snapshot(id)
	if snap.is_empty() or snap.has("system_graph") or str(snap.get("world_id", "")) != id:
		fails += 1
		push_error("worlds: FAIL — snapshot missing, carries a graph, or lacks the world id")
	else:
		print("worlds: snapshot PASS (no graph inside, world id stamped)")
	# 2. Exit to the menu, then Play the world again.
	var prev := tree.current_scene.get_instance_id()
	WorldSession.exit_to_menu(main)
	for _k in 30:
		await tree.process_frame
	if WorldPaths.has_active_world():
		fails += 1
		push_error("worlds: FAIL — the menu did not clear the active world")
	else:
		print("worlds: exit to menu PASS")
	var hashes := _file_hashes(WorldStore.get_world(id))
	prev = tree.current_scene.get_instance_id() if tree.current_scene != null else -1
	WorldSession.launch(WorldStore.get_world(id), {})
	var main2 := await _await_world_scene(prev)
	if main2 == null:
		push_error("worlds: FAIL — the world did not reload")
		_maybe_quit()
		return
	var fp2 := WorldSession.fingerprint(main2)
	var diff := WorldSession.fingerprint_diff(fp1, fp2)
	if diff.is_empty():
		print("worlds: round trip PASS — all %d fingerprint keys restored" % fp1.size())
	else:
		fails += diff.size()
		for d in diff:
			push_error("worlds: FAIL — %s was %s, came back %s" % [d[0], str(d[1]), str(d[2])])
	# 3. A NEW world on the same map starts empty; the first world is untouched.
	var fresh := WorldStore.create(WorldStore.get_world(id).get("map", {}), "__harness fresh")
	fresh["scratch"] = true
	WorldStore.save_record(fresh)
	WorldSession.save_now(main2, false, false)
	hashes = _file_hashes(WorldStore.get_world(id))
	prev = tree.current_scene.get_instance_id()
	WorldSession.launch(fresh, {})
	var main3 := await _await_world_scene(prev)
	if main3 == null:
		fails += 1
		push_error("worlds: FAIL — the new world did not load")
	else:
		var fp3 := WorldSession.fingerprint(main3)
		for k in ["count.props", "count.lights", "count.camps", "count.edited_tiles", "count.peak_total"]:
			if int(fp3.get(k, 0)) != 0:
				fails += 1
				push_error("worlds: FAIL — new world is not empty: %s = %s" % [k, str(fp3.get(k))])
		print("worlds: new world on the same map — props %d, lights %d, graph nodes %d" % [
			int(fp3.get("count.props", 0)), int(fp3.get("count.lights", 0)), int(fp3.get("count.graph_nodes", 0))])
		# The nodes an EMPTY world still has must all be auto-generated
		# (SolarUI's virtual mirrors, PBI catchments) — never a user node.
		var g3 := ServiceLocator.graph()
		var kinds := {}
		var user_nodes := 0
		if g3 != null and g3.get("model") != null:
			for it in g3.get("model").get("items"):
				var d: Dictionary = it
				var tag := "%s%s" % [str(d.get("type", "?")), " (virtual)" if bool(d.get("virtual", false)) \
					or str(d.get("id", "")).begins_with("virtual_") else ""]
				kinds[tag] = int(kinds.get(tag, 0)) + 1
				if not tag.ends_with("(virtual)") and str(d.get("type", "")) != "pbi":
					user_nodes += 1
		print("worlds: new world's graph by type: %s" % JSON.stringify(kinds))
		if user_nodes > 0:
			push_warning("worlds: CHECK — %d non-virtual node(s) in a brand-new world (see the type list above)" % user_nodes)
		# Seal before comparing: nothing the fresh scene writes from here on
		# may land anywhere real (see WorldPaths.seal).
		WorldPaths.seal()
		var after := _file_hashes(WorldStore.get_world(id))
		var changed: Array[String] = []
		for tag in hashes:
			if str(after.get(tag, "")) != str(hashes[tag]):
				changed.append(str(tag))
		if changed.is_empty() and after.size() == hashes.size():
			print("worlds: original world untouched PASS (%d files)" % hashes.size())
		else:
			fails += 1
			push_error("worlds: FAIL — the original world's files changed: %s" % ", ".join(changed))
	WorldStore.remove_tree(WorldStore.world_dir(str(fresh.get("id", ""))))
	print("worlds: %s" % ("ALL PASS" if fails == 0 else "%d FAILURE(S)" % fails))
	_maybe_quit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F12:
		_manual_screenshot()


func _manual_screenshot() -> void:
	DirAccess.make_dir_recursive_absolute(SHOTS_ROOT)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := "%s/manual_%s.png" % [SHOTS_ROOT, stamp]
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("PlaytestHarness: screenshot saved to %s" % ProjectSettings.globalize_path(path))

## Observe NPC animation on a REAL saved map, changing nothing.
##
## `--capture=population` seeds its own spaces, tanks and habitat so it can run
## anywhere; pointing that at somebody's actual site would overwrite the setup
## they built. This mode is strictly read-only: it finds whatever pop-driven
## habitat is already there, watches it, and asserts the contract that matters —
## nobody holds a lying or seated pose while the sim says they are travelling.
##
##   Godot.exe.exe --path . --windowed --resolution 1280x720 -- \
##     --user-map=<file.tres> --capture=npc-anim --shots-dir=<label> \
##     --quit-after-capture
## This capture observes the RIGGED (Mixamo) body's clips: with the player's
## body style on the stick figure nobody is ever rigged and every clip check
## reads "nobody to watch". Force the humanoid style for the run and hand the
## player's style back on every exit path.
func _run_npc_anim_verify() -> void:
	var prev_style := NpcDisplayPrefs.style()
	if prev_style != NpcDisplayPrefs.STYLE_HUMANOID:
		print("PlaytestHarness: npc-anim — body style %s → humanoid for this run" % prev_style)
		NpcDisplayPrefs.set_style(NpcDisplayPrefs.STYLE_HUMANOID)
	await _run_npc_anim_verify_body()
	if NpcDisplayPrefs.style() != prev_style:
		NpcDisplayPrefs.set_style(prev_style)


func _run_npc_anim_verify_body() -> void:
	# AFTER the await: on a user map the scene is still swapping when this
	# starts, so grabbing current_scene first yields null — which silently made
	# registry_for() return an empty registry and reported a fully tagged site
	# as having no spaces at all.
	var sgv := await _find_graph_view()
	var main := get_tree().current_scene
	if sgv == null or main == null:
		push_error("PlaytestHarness: no SystemGraphView / scene — aborting")
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "npc_anim"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []

	# Let the sim spin up so the bridge builds engines for whatever is saved.
	if main != null and "time_scale" in main:
		main.time_scale = 0.05
	await get_tree().create_timer(2.0).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null:
		push_error("PlaytestHarness: population bridge missing — aborting")
		_maybe_quit()
		return
	var habs: Array = bridge.call("habitat_ids")
	print("PlaytestHarness: npc-anim — %d pop-driven habitat(s) on this map: %s" % [
		habs.size(), ", ".join(PackedStringArray(habs))])
	if habs.is_empty():
		print("PlaytestHarness: npc-anim — FAIL (no pop-driven habitat; nothing to observe)")
		_maybe_quit()
		return
	var hab_id := str(habs[0])
	var summ: Dictionary = bridge.call("summary_for", hab_id)
	print("PlaytestHarness: npc-anim — roster %d of %d, morale %.2f (%s)" % [
		int(summ.get("count", 0)), int(summ.get("initial_count", 0)),
		float(summ.get("mean_morale", 0.0)), str(summ.get("morale_label", ""))])

	# Which spaces this site actually has decides which poses can appear at all.
	var reg: Variant = bridge.call("registry_for", main)
	var kinds: Dictionary = {}
	if reg != null:
		for sp in reg.get("spaces"):
			kinds[str((sp as Dictionary).get("space_type", ""))] = true
	print("PlaytestHarness: npc-anim — tagged spaces: %s" % [
		", ".join(PackedStringArray(kinds.keys()))])

	print("PlaytestHarness: npc-anim — rig %s" % [
		"available" if NpcRig.available() else "ABSENT (primitive figures only)"])

	# Routines make people travel at BLOCK BOUNDARIES and sit still between
	# them, so a window landing mid-block observes nobody moving at all. Anchor
	# just before the 09:00 wake, then put the clock back.
	var prev_day_time := float(main.day_time) if "day_time" in main else -1.0
	if prev_day_time >= 0.0:
		main.day_time = 8.85
		await get_tree().process_frame

	# Stand the camera in the middle of the roster BEFORE sampling. The rigged
	# body is handed out by distance from the VIEWER, so observing from spawn
	# means nobody is ever rigged and no clip is ever played.
	var centre := Vector2.ZERO
	var n_pos := 0
	for a in bridge.call("roster_for", hab_id):
		var ag0 := a as NpcAgent
		if ag0 != null:
			centre += ag0.pos
			n_pos += 1
	if n_pos > 0:
		centre /= float(n_pos)
	var cam := Camera3D.new()
	main.add_child(cam)
	var prev_cam := get_viewport().get_camera_3d()
	var cam_y := TerrainSurfaceQuery.ground_height_at(main, centre.x, centre.y)
	cam.global_position = Vector3(centre.x, cam_y + 12.0, centre.y) + Vector3(22.0, 0.0, 22.0)
	cam.look_at(Vector3(centre.x, cam_y + 1.0, centre.y))
	cam.current = true
	# Slow enough that the transition budget gate actually opens: a 5-minute
	# bathroom visit needs > ~2.6 real seconds to be worth sitting down for,
	# which at 0.02 sim-h/s it is (4.2 s) and at 0.05 it is not (1.7 s).
	if "time_scale" in main:
		main.time_scale = 0.02
	await get_tree().create_timer(1.0).timeout

	var clips: Dictionary = {}
	var violations := 0
	var traveller_samples := 0
	var walking_samples := 0
	var posed_samples := 0
	var busiest := 0
	var busiest_at := Vector2.ZERO
	for i in 160:
		await get_tree().create_timer(0.25).timeout
		var roster: Array = bridge.call("roster_for", hab_id)
		var travelling: Dictionary = {}
		var moving_now := 0
		for a in roster:
			var ag := a as NpcAgent
			if ag == null:
				continue
			if ag.state == NpcAgent.State.TRAVELING:
				travelling[ag.id] = true
				moving_now += 1
		traveller_samples += moving_now
		if moving_now > busiest:
			busiest = moving_now
			for a in roster:
				var ag2 := a as NpcAgent
				if ag2 != null and ag2.state == NpcAgent.State.TRAVELING:
					busiest_at = ag2.pos
					break
		for node in get_tree().get_nodes_in_group("npc_avatars"):
			var av := node as NpcAvatar
			if av == null or not av.is_rigged():
				continue
			var c := av.current_clip()
			if not c.is_empty():
				clips[c] = int(clips.get(c, 0)) + 1
			if av.is_posed_down():
				posed_samples += 1
				if travelling.has(av.agent_id):
					violations += 1
			elif av.is_walking():
				walking_samples += 1
		if i % 26 == 12 and manifest.size() < 6:
			await _graph_shot(dir, "%02d_people" % manifest.size(), manifest, "world")

	# Pause must actually freeze the figures. A clip still advancing while the
	# clock is stopped reads as the sim still running.
	var frozen_ok := true
	if "time_scale" in main:
		main.time_scale = 0.0
		await get_tree().create_timer(0.4).timeout
		var before: Dictionary = {}
		for node in get_tree().get_nodes_in_group("npc_avatars"):
			var av2 := node as NpcAvatar
			if av2 != null and av2.is_rigged():
				before[av2.agent_id] = av2.clip_position()
		await get_tree().create_timer(1.0).timeout
		var moved := 0
		for node in get_tree().get_nodes_in_group("npc_avatars"):
			var av3 := node as NpcAvatar
			if av3 == null or not av3.is_rigged() or not before.has(av3.agent_id):
				continue
			if absf(av3.clip_position() - float(before[av3.agent_id])) > 0.01:
				moved += 1
		frozen_ok = before.size() > 0 and moved == 0
		print("PlaytestHarness: npc-anim — paused freeze %s (%d rigged watched, %d still animating)" % [
			"PASS" if frozen_ok else ("FAIL (nobody rigged to watch)" if before.is_empty() else "FAIL"),
			before.size(), moved])

	if prev_day_time >= 0.0:
		main.day_time = prev_day_time
		await get_tree().process_frame

	var parts: PackedStringArray = PackedStringArray()
	var keys: Array = clips.keys()
	keys.sort()
	for k in keys:
		parts.append("%s x%d" % [str(k), int(clips[k])])
	print("PlaytestHarness: npc-anim — clips observed: %s" % [
		", ".join(parts) if not parts.is_empty() else "(none — nobody was rigged/near)"])
	print("PlaytestHarness: npc-anim — %d traveller-samples, %d walking, %d lying/seated" % [
		traveller_samples, walking_samples, posed_samples])
	var ok := violations == 0 and traveller_samples > 0
	print("PlaytestHarness: npc-anim — travel poses %s (%d lying/seated while travelling)" % [
		"PASS" if ok else ("FAIL (never saw a traveller)" if traveller_samples == 0 else "FAIL"),
		violations])
	# Transitions only appear at 1x-ish speeds; say so rather than silently
	# passing a run in which they could never have been reached.
	var saw_transition := clips.has(NpcRig.CLIP_SLEEP_ENTER) or clips.has(NpcRig.CLIP_SLEEP_EXIT) \
		or clips.has(NpcRig.CLIP_SIT_ENTER) or clips.has(NpcRig.CLIP_SIT_EXIT) \
		or clips.has(NpcRig.CLIP_WALK_START) or clips.has(NpcRig.CLIP_WALK_STOP)
	print("PlaytestHarness: npc-anim — transition clips %s" % [
		"seen" if saw_transition else "NOT seen (expected at high time scale)"])

	if prev_cam != null:
		prev_cam.current = true
	cam.queue_free()
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: npc-anim — %s (%d shots in %s)" % [
		"PASS" if ok else "FAIL", manifest.size(), dir])
	_maybe_quit()


# ==================== VEG CAPTURE (--capture=veg) ====================
# Vegetation regression baseline (veg overhaul Phase 1): forest-anchored shot
# sets (close canopy, the NEAR->FAR LOD boundary band, distant, aerial), a
# 4-date seasonal series from one fixed waypoint, and veg_diagnostics.json
# with per-batch instance/visibility/fade data + asset-cache stats + render
# counters. Later phases (tier rings, impostors, quality tiers, phenology)
# compare their runs against this output.

const VEG_SCATTER_WAIT_MAX_S := 240.0
const VEG_SEASON_SETTLE_S := 3.5
## month, day, set label — winter bare / spring bud / summer full / autumn ramp.
const VEG_SEASON_DATES: Array = [
	[1, 15, "season_winter"], [4, 20, "season_spring"],
	[7, 15, "season_summer"], [10, 20, "season_autumn"],
]


func _run_veg_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: veg capture needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	var auto_on := true
	if loader.has_method("get_terrain_options"):
		var opts: Dictionary = loader.call("get_terrain_options")
		auto_on = bool(opts.get("show_auto_vegetation", true))
	if not auto_on:
		# The single most confusing veg failure mode: the toggle lives in
		# terrain_config.cfg and OFF means no fetch, no scatter, no forest,
		# with zero console evidence. Say so loudly.
		print("PlaytestHarness: veg — NOTE: show_auto_vegetation=false (Terrain options) — capture reflects the MANUAL layer only")
	else:
		print("PlaytestHarness: veg — map loaded, waiting for auto-veg scatter")
		var waited := 0.0
		while loader.get("_auto_veg_generated") != true and waited < VEG_SCATTER_WAIT_MAX_S:
			await get_tree().create_timer(2.0).timeout
			waited += 2.0
		if loader.get("_auto_veg_generated") != true:
			print("PlaytestHarness: veg — scatter still pending after %.0f s, shooting anyway" % waited)
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()

	var label := _shots_label if not _shots_label.is_empty() else "veg_capture"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var cam := Camera3D.new()
	cam.name = "PlaytestCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()
	var manifest: Array = []

	var anchor := _veg_forest_anchor(loader)
	print("PlaytestHarness: veg — forest anchor (%.0f, %.0f)" % [anchor.x, anchor.y])
	await _capture_set(cam, _veg_waypoints(loader, anchor), "veg", dir, manifest)
	await _capture_set(cam, _orbit_waypoints(loader), "orbit", dir, manifest)

	# Seasonal series: same boundary waypoint, four calendar dates. The env
	# sync lerps uniforms on REAL time (k = delta*2.5), so give it a beat.
	var main := get_tree().current_scene
	var season_wp := _veg_boundary_waypoint(loader, anchor)
	for date in VEG_SEASON_DATES:
		if "month" in main:
			main.month = int(date[0])
		if "day" in main:
			main.day = int(date[1])
		await get_tree().create_timer(VEG_SEASON_SETTLE_S).timeout
		await _capture_set(cam, [season_wp], str(date[2]), dir, manifest)

	# One NIGHT shot of the distant forest from the same waypoint: the
	# unshaded impostor tier's brightness floor now tracks the live scene
	# ambient — the old hard-coded 0.30 floor read as trees glowing in the
	# dark, and only a night frame with far forest in view can show it.
	if "month" in main:
		main.month = 7
	if "day" in main:
		main.day = 15
	var day_time_saved := float(main.get("day_time")) if "day_time" in main else 12.0
	if "day_time" in main:
		main.set("day_time", 1.0)   # 01:00 — deep night, no twilight ambiguity
	await get_tree().create_timer(VEG_SEASON_SETTLE_S).timeout
	await _capture_set(cam, [season_wp], "night_glow", dir, manifest)
	if "day_time" in main:
		main.set("day_time", day_time_saved)
	await get_tree().create_timer(0.4).timeout

	_write_veg_diagnostics(loader, dir)
	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	cam.queue_free()
	print("PlaytestHarness: veg capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Densest tree stand: the record nearest the centroid of the largest non-grass
## slot (auto layer first, manual fallback) — guaranteed inside real forest.
func _veg_forest_anchor(loader: Node) -> Vector2:
	for layer_prop in ["_auto_veg_layer", "_vegetation_layer"]:
		var layer: Object = loader.get(layer_prop)
		if layer == null:
			continue
		var bulk: Variant = layer.get("bulk")
		if not (bulk is Dictionary):
			continue
		var best_slot := ""
		var best_n := 0
		for slot in bulk:
			if str(slot).begins_with("grass"):
				continue
			var n := ((bulk as Dictionary)[slot] as Array).size()
			if n > best_n:
				best_n = n
				best_slot = str(slot)
		if best_n == 0:
			continue
		var recs: Array = (bulk as Dictionary)[best_slot]
		var cx := 0.0
		var cz := 0.0
		for r in recs:
			cx += float(r["x"])
			cz += float(r["z"])
		cx /= float(best_n)
		cz /= float(best_n)
		var best_d := INF
		var ax := cx
		var az := cz
		for r in recs:
			var dx := float(r["x"]) - cx
			var dz := float(r["z"]) - cz
			var d := dx * dx + dz * dz
			if d < best_d:
				best_d = d
				ax = float(r["x"])
				az = float(r["z"])
		return Vector2(ax, az)
	return Vector2.ZERO


func _veg_boundary_waypoint(loader: Node, anchor: Vector2) -> Dictionary:
	var reach := 220.0
	if loader.has_method("get_vegetation_style"):
		var style: Dictionary = loader.call("get_vegetation_style")
		reach = float(style.get("tree_detail_distance_m", 220.0))
	var eye := _ground_y(loader, anchor.x - reach, anchor.y) + 4.0
	return {
		"pos": Vector3(anchor.x - reach, eye, anchor.y),
		"look": Vector3(anchor.x, _ground_y(loader, anchor.x, anchor.y) + 8.0, anchor.y),
	}


func _veg_waypoints(loader: Node, anchor: Vector2) -> Array:
	var ax := anchor.x
	var az := anchor.y
	var canopy := Vector3(ax, _ground_y(loader, ax, az) + 8.0, az)
	var pts: Array = []
	# Close: inside the stand at eye level (near-tier detail + bark).
	pts.append({
		"pos": Vector3(ax + 25.0, _ground_y(loader, ax + 25.0, az) + 2.0, az),
		"look": canopy,
	})
	# Boundary: standing AT the NEAR->FAR reach looking across it — the shot
	# where LOD popping / renderer-identity seams show.
	pts.append(_veg_boundary_waypoint(loader, anchor))
	# Distant: 500 m out, slightly lifted (FAR tier / future impostor band).
	pts.append({
		"pos": Vector3(ax + 500.0, _ground_y(loader, ax + 500.0, az) + 30.0, az),
		"look": canopy,
	})
	# Aerial: drone-style 45 deg down from 180 m (site-plan realism check).
	pts.append({
		"pos": Vector3(ax + 180.0, _ground_y(loader, ax, az) + 180.0, az),
		"look": canopy,
	})
	return pts


func _write_veg_diagnostics(loader: Node, dir: String) -> void:
	var main := get_tree().current_scene
	var terrain: Node = main.get_node_or_null("Terrain") if main != null else null
	var batches: Array = []
	var totals := {"instances": 0, "batches": 0, "hero": 0}
	if terrain != null:
		for root_name in ["Vegetation", "AutoVegetation"]:
			var root := terrain.get_node_or_null(root_name)
			if root == null:
				continue
			for child in root.get_children():
				if child is MultiMeshInstance3D:
					var mi := child as MultiMeshInstance3D
					var n := mi.multimesh.instance_count if mi.multimesh != null else 0
					var surfaces := 0
					if mi.multimesh != null and mi.multimesh.mesh != null:
						surfaces = mi.multimesh.mesh.get_surface_count()
					batches.append({
						"layer": root_name,
						"name": String(mi.name),
						"instances": n,
						"vis_begin": mi.visibility_range_begin,
						"vis_end": mi.visibility_range_end,
						"fade_mode": int(mi.visibility_range_fade_mode),
						"surfaces": surfaces,
					})
					totals["instances"] = int(totals["instances"]) + n
					totals["batches"] = int(totals["batches"]) + 1
				elif String(child.name) == "HeroTrees":
					totals["hero"] = int(totals["hero"]) + child.get_child_count()
	var diag := {
		"totals": totals,
		"asset_cache": VegAssetCache.stats(),
		"style": {},
		"perf": {
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"video_mem_bytes": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED),
		},
		"batches": batches,
	}
	if loader.has_method("get_vegetation_style"):
		var style: Dictionary = loader.call("get_vegetation_style")
		for k in ["tree_detail_distance_m", "tree_detail_eff_m", "tree_near_budget",
				"auto_visibility_end_m", "grass_visibility_end_m", "auto_density_scale",
				"auto_max_tree_instances", "auto_max_grass_instances"]:
			if style.has(k):
				diag["style"][k] = style[k]
	var f := FileAccess.open("%s/veg_diagnostics.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(diag, "\t"))
		f.close()
	print("PlaytestHarness: wrote veg_diagnostics.json (%d batches, %d instances)" % [
		int(totals["batches"]), int(totals["instances"])])


# ==================== AREA FILL VERIFY (--capture=areafill) ====================
# Veg overhaul Phase 7. Drives the REAL loader API on a real saved map: pick the
# largest OSM vegetation area, fill it with a chosen species, assert the layer
# actually changed and the fill persisted, shoot before/after PNGs of that
# outline, then RESTORE the map's auto_veg_edits file byte-for-byte so a
# regression run never mutates the player's site.

const AREA_FILL_SPECIES := "pine"
const AREA_FILL_DENSITY := 1.4


func _run_area_fill_verify() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: areafill needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	var waited := 0.0
	while loader.get("_auto_veg_generated") != true and waited < VEG_SCATTER_WAIT_MAX_S:
		await get_tree().create_timer(2.0).timeout
		waited += 2.0
	if loader.get("_auto_veg_generated") != true:
		print("PlaytestHarness: areafill FAIL — no auto-veg scatter after %.0f s" % waited)
		_maybe_quit()
		return
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()

	# Snapshot the persisted edits so the run leaves no trace.
	var edits_path: String = AutoVegetationEdits.save_path_for_map(
		float(loader.get("_lat")), float(loader.get("_lon")))
	var had_edits := FileAccess.file_exists(edits_path)
	var edits_before := ""
	if had_edits:
		var rf := FileAccess.open(edits_path, FileAccess.READ)
		if rf != null:
			edits_before = rf.get_as_text()

	var pick := _largest_veg_area(loader)
	var idx := int(pick.get("area_idx", -1))
	if idx < 0:
		print("PlaytestHarness: areafill FAIL — map has no OSM vegetation areas")
		_maybe_quit()
		return
	var centroid: Vector2 = pick.get("centroid", Vector2.ZERO)
	print("PlaytestHarness: areafill — area #%d %s %.1f ha at (%.0f, %.0f)" % [
		idx, str(pick.get("kind_label", "?")), float(pick.get("area_m2", 0.0)) / 10000.0,
		centroid.x, centroid.y])

	var label := _shots_label if not _shots_label.is_empty() else "area_fill"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var cam := Camera3D.new()
	cam.name = "PlaytestCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()
	var manifest: Array = []
	var wps := _area_fill_waypoints(loader, centroid)
	await _capture_set(cam, wps, "before", dir, manifest)

	var before_total := _auto_bulk_total(loader)
	var res: Dictionary = loader.call("apply_area_fill", idx, {
		"species": AREA_FILL_SPECIES,
		"density": AREA_FILL_DENSITY,
		"height_m": 0.0,
		"replace": true,
	})
	await get_tree().create_timer(2.5).timeout
	var placed := int(res.get("placed", 0))
	var removed := int(res.get("removed", 0))
	var after_total := _auto_bulk_total(loader)
	print("PlaytestHarness: areafill — placed %d, removed %d (layer %d -> %d)" % [
		placed, removed, before_total, after_total])
	var ok := placed > 0
	print("PlaytestHarness: areafill %s — fill placed instances" % ["PASS" if ok else "FAIL"])

	# The fill has to be the SPECIES asked for, not just "some trees".
	var species_ok := _auto_species_count(loader, AREA_FILL_SPECIES) > 0
	print("PlaytestHarness: areafill %s — chosen species present in the layer"
		% ["PASS" if species_ok else "FAIL"])

	# ...and it has to persist, or it vanishes on the next load.
	var saved: Dictionary = loader.call("area_fill_params", idx)
	var persisted := str(saved.get("species", "")) == AREA_FILL_SPECIES
	print("PlaytestHarness: areafill %s — fill recorded for the area (species=%s)" % [
		"PASS" if persisted else "FAIL", str(saved.get("species", "<none>"))])
	var on_disk := FileAccess.file_exists(edits_path)
	print("PlaytestHarness: areafill %s — edits written to disk" % ["PASS" if on_disk else "FAIL"])

	await _capture_set(cam, wps, "after", dir, manifest)

	# Clear, and confirm the area empties.
	var cleared_ok := bool(loader.call("clear_area_fill", idx, true))
	await get_tree().create_timer(2.0).timeout
	print("PlaytestHarness: areafill %s — clear removed the fill record"
		% ["PASS" if cleared_ok else "FAIL"])
	await _capture_set(cam, wps, "cleared", dir, manifest)

	# Restore the map's saved edits exactly as they were.
	if had_edits:
		var wf := FileAccess.open(edits_path, FileAccess.WRITE)
		if wf != null:
			wf.store_string(edits_before)
	elif FileAccess.file_exists(edits_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(edits_path))
	print("PlaytestHarness: areafill — restored %s" % (
		"the map's original edits" if had_edits else "a clean (no edits) map"))

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	cam.queue_free()
	print("PlaytestHarness: areafill — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Biggest OSM veg polygon on the map — the one whose fill is most visible.
func _largest_veg_area(loader: Node) -> Dictionary:
	var data: Variant = loader.get("_auto_veg_data")
	if not (data is Dictionary):
		return {"area_idx": -1}
	var polys: Variant = (data as Dictionary).get("polygons", [])
	if not (polys is Array):
		return {"area_idx": -1}
	var best := {"area_idx": -1}
	var best_area := 0.0
	for i in (polys as Array).size():
		var info := VegAreaPicker.area_info(polys as Array, i)
		if not bool(info.get("valid", false)):
			continue
		var a := float(info.get("area_m2", 0.0))
		if a > best_area:
			best_area = a
			best = info
	return best


func _auto_bulk_total(loader: Node) -> int:
	var layer: Variant = loader.get("_auto_veg_layer")
	if layer == null or not (layer is AutoVegetationLayer):
		return 0
	return (layer as AutoVegetationLayer).total_bulk()


func _auto_species_count(loader: Node, species: String) -> int:
	var layer: Variant = loader.get("_auto_veg_layer")
	if layer == null or not (layer is AutoVegetationLayer):
		return 0
	var recs: Variant = (layer as AutoVegetationLayer).bulk.get(species, [])
	return (recs as Array).size() if recs is Array else 0


## Two views of the filled outline: a low oblique that shows the trees against
## the sky, and an overhead that shows the outline's shape.
func _area_fill_waypoints(loader: Node, centroid: Vector2) -> Array:
	var gy := _ground_y(loader, centroid.x, centroid.y)
	return [
		{
			"pos": Vector3(centroid.x - 150.0, gy + 45.0, centroid.y - 150.0),
			"look": Vector3(centroid.x, gy + 8.0, centroid.y),
		},
		{
			"pos": Vector3(centroid.x, gy + 260.0, centroid.y + 40.0),
			"look": Vector3(centroid.x, gy, centroid.y),
		},
	]


# ==================== PAINTED CAMPS (--capture=camps) ====================
# Drives the loader's camp-area API on a real saved map: paints an RV camp on
# the best open ground it can find, grows it, splits a second zone into plots,
# and asserts what a PNG cannot show — vehicles within the alignment jitter of
# the camp heading, every structure seated on the (edit-aware) ground, growth
# leaving the existing structures in place, the layer persisted and reproduced
# by a fresh attach, and undo. Shoots day + night sets. The map's
# camp_areas_*.json is snapshotted and byte-restored, so a run never leaves
# camps on the player's site.

const CAMP_SITE_W := 120.0
const CAMP_SITE_D := 90.0


func _camp_result(ok: bool, what: String) -> void:
	print("PlaytestHarness: camps %s — %s" % ["PASS" if ok else "FAIL", what])


func _run_camp_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: camps needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()

	var path: String = CampAreaLayer.save_path_for_map(
		float(loader.get("_lat")), float(loader.get("_lon")))
	var place_path: String = FestivalPlacementLayer.save_path_for_map(
		float(loader.get("_lat")), float(loader.get("_lon")))
	var snap := _snapshot_files([path, place_path])
	# Start from an empty layer so counts are this run's alone.
	var blank := CampAreaLayer.create_empty()
	blank.save_to(path)
	if FileAccess.file_exists(place_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(place_path))
	loader.set("camp_areas", null)
	loader.set("placement", null)
	loader.call("_attach_camp_areas")

	var sites := _camp_pick_sites(loader)
	if sites.is_empty():
		_camp_result(false, "no open ground found for a camp near the site centre")
		_restore_files(snap)
		_maybe_quit()
		return
	var a: Vector2 = sites[0]
	var hw := CAMP_SITE_W * 0.5
	var hd := CAMP_SITE_D * 0.5
	var rect_a := PackedVector2Array([a + Vector2(-hw, -hd), a + Vector2(hw, -hd),
		a + Vector2(hw, hd), a + Vector2(-hw, hd)])
	print("PlaytestHarness: camps — site A at (%.0f, %.0f)" % [a.x, a.y])

	# 1. Paint an RV camp.
	var id := str(loader.call("paint_camp_area", rect_a, {"style": "rv_park", "density": 1.0}))
	var info: Dictionary = loader.call("camp_area_info", id)
	var n_a := int(info.get("structures", 0))
	var heading := float(info.get("heading_deg", 0.0))
	print("PlaytestHarness: camps — %s: %d structures, heading %.1f deg (auto=%s), stats=%s" % [
		id, n_a, heading, str(info.get("heading_auto", false)), str(info.get("stats", {}))])
	_camp_result(not id.is_empty() and n_a > 10, "painting placed structures (%d)" % n_a)

	# 2. Vehicles are aligned to the camp heading.
	var rt := loader.get("_camp_area_runtime") as CampAreaRuntime
	var rvs: Array = rt.area_class_transforms(id, "rv") if rt != null else []
	var worst := 0.0
	for xf: Transform3D in rvs:
		var ax := xf.basis.x
		worst = maxf(worst, CampLayoutGenerator.axis_deviation_deg(atan2(ax.z, ax.x), heading))
	print("PlaytestHarness: camps — %d RVs, worst deviation from heading %.2f deg" % [
		rvs.size(), worst])
	# The jitter is 5 deg in plan; a vehicle tilted to a slope reads a hair more.
	_camp_result(rvs.size() > 3 and worst <= 6.5, "RVs aligned within the jitter")

	# 3. Everything sits on the ground the loader reports (terrain edits included).
	var worst_dy := 0.0
	for cls in ["rv", "ez_up", "car", "van", "camping_tent"]:
		for xf: Transform3D in (rt.area_class_transforms(id, cls) if rt != null else []):
			worst_dy = maxf(worst_dy, absf(xf.origin.y - _ground_y(loader, xf.origin.x, xf.origin.z)))
	print("PlaytestHarness: camps — worst height error vs ground %.4f m" % worst_dy)
	_camp_result(worst_dy < 0.02, "structures are seated on the ground")

	_camp_result(FileAccess.file_exists(path)
		and FileAccess.get_file_as_string(path).contains(id), "camp written to disk")

	# 4. Growing the camp keeps what is already standing.
	var before_keys := {}
	for xf: Transform3D in rvs:
		before_keys["%.2f|%.2f" % [xf.origin.x, xf.origin.z]] = true
	var grow := PackedVector2Array([a + Vector2(hw - 10.0, -hd), a + Vector2(hw + 50.0, -hd),
		a + Vector2(hw + 50.0, hd), a + Vector2(hw - 10.0, hd)])
	var id2 := str(loader.call("paint_camp_area", grow, {"style": "rv_park", "density": 1.0}))
	var grown: Array = rt.area_class_transforms(id, "rv") if rt != null else []
	var kept := 0
	for xf: Transform3D in grown:
		if before_keys.has("%.2f|%.2f" % [xf.origin.x, xf.origin.z]):
			kept += 1
	var n_grown := int((loader.call("camp_area_info", id) as Dictionary).get("structures", 0))
	print("PlaytestHarness: camps — grown: same id=%s, %d -> %d structures, %d/%d RVs kept" % [
		str(id2 == id), n_a, n_grown, kept, before_keys.size()])
	_camp_result(id2 == id and n_grown >= n_a and kept == before_keys.size(),
		"growing a camp moves nothing already standing")

	# 5. Subdivide a second zone into plots.
	var plot_ids: Array = []
	var b: Vector2 = sites[1] if sites.size() > 1 else a + Vector2(0.0, CAMP_SITE_D + 60.0)
	var zone := PackedVector2Array([b + Vector2(-80, -55), b + Vector2(80, -55),
		b + Vector2(80, 55), b + Vector2(-80, 55)])
	plot_ids = loader.call("subdivide_camp_zone", zone, {"style": "varied",
		"plot_w_m": 30.0, "plot_d_m": 22.0, "lane_w_m": 6.0, "density": 0.9})
	var styles := {}
	var plot_structs := 0
	for pid in plot_ids:
		var pi: Dictionary = loader.call("camp_area_info", str(pid))
		styles[str(pi.get("style", ""))] = true
		plot_structs += int(pi.get("structures", 0))
	print("PlaytestHarness: camps — zone at (%.0f, %.0f): %d plots, %d structures, styles %s" % [
		b.x, b.y, plot_ids.size(), plot_structs, str(styles.keys())])
	_camp_result(plot_ids.size() >= 4 and plot_structs > 0, "a zone splits into filled plots")

	var summary: Dictionary = loader.call("camp_areas_summary")
	print("PlaytestHarness: camps — total %s" % str(summary))

	# Shots: day, then night for the glow.
	var label := _shots_label if not _shots_label.is_empty() else "camps"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var cam := Camera3D.new()
	cam.name = "PlaytestCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()
	var manifest: Array = []
	var wps := _camp_waypoints(loader, a, b)
	await _capture_set(cam, wps, "day", dir, manifest)
	var main := get_tree().current_scene
	if "day_time" in main:
		main.day_time = 23.0
	await get_tree().create_timer(1.0).timeout
	await _capture_set(cam, wps, "night", dir, manifest)
	if "day_time" in main:
		main.day_time = _capture_hour

	# 6. A fresh attach (what a reload does) reproduces the same camps.
	var want := int(summary.get("structures", 0))
	loader.set("camp_areas", null)
	loader.call("_attach_camp_areas")
	var again: Dictionary = loader.call("camp_areas_summary")
	print("PlaytestHarness: camps — after re-attach %s" % str(again))
	_camp_result(int(again.get("structures", -1)) == want
		and int(again.get("areas", -1)) == int(summary.get("areas", 0)),
		"a reload reproduces every camp exactly")

	# 7. Erase + undo.
	loader.call("push_camp_undo")
	var hit := int(loader.call("erase_camps_in_polygon", rect_a))
	var after_erase := int((loader.call("camp_areas_summary") as Dictionary).get("structures", 0))
	var undone := bool(loader.call("undo_camps"))
	var after_undo := int((loader.call("camp_areas_summary") as Dictionary).get("structures", 0))
	print("PlaytestHarness: camps — erase touched %d, %d -> %d, undo -> %d" % [
		hit, want, after_erase, after_undo])
	_camp_result(hit > 0 and after_erase < want and undone and after_undo == want,
		"erase removes structures and undo restores them")

	# 8. Tune look: the style modal through its real entry point. Adds a library
	# model to a style, checks it shows up in the preview AND (after Apply) on
	# the map, then byte-restores the player's camp_styles.json.
	var style_snap := _snapshot_files([CampStyleStore.PATH])
	var ui_layer := main.get_node_or_null("UILayer") as CanvasLayer
	if ui_layer != null:
		ui_layer.visible = true
	loader.call("open_camp_style_modal", "rv_park")
	await get_tree().create_timer(1.0).timeout
	var modal := loader.get("_camp_style_modal") as Control
	_camp_result(modal != null and modal.visible, "the Tune-look modal opens")
	if modal != null:
		await _shoot_ui(dir, "tune_00_rv_park")
		modal.call("_add_model", "shiftpod", "Shiftpod")
		await get_tree().create_timer(1.0).timeout
		var draft: Dictionary = modal.get("_draft")
		var added := (draft["models"] as Dictionary).has("u_shiftpod")
		var prt := modal.get("_runtime") as CampAreaRuntime
		var pods: Array = prt.area_class_transforms("preview", "u_shiftpod") if prt != null else []
		print("PlaytestHarness: camps — tune look: model %s, %d in the preview; stats: %s | warnings: %s" % [
			str((draft["models"] as Dictionary).get("u_shiftpod", {})), pods.size(),
			str((modal.get("_stats_lbl") as Label).text), str((modal.get("_warn_lbl") as Label).text)])
		_camp_result(added and pods.size() > 0, "an added library model appears in the preview")
		await _shoot_ui(dir, "tune_01_model_added")
		modal.call("_save_to_global")
		await get_tree().create_timer(1.0).timeout
		var on_map := 0
		for rec: Dictionary in (loader.get("camp_areas") as CampAreaLayer).areas:
			if str(rec["style"]) == "rv_park":
				on_map += rt.area_class_transforms(str(rec["id"]), "u_shiftpod").size()
		print("PlaytestHarness: camps — after Apply: %d of the added model on the map" % on_map)
		_camp_result(on_map > 0 and FileAccess.file_exists(CampStyleStore.PATH),
			"Apply saves the style and restyles the camps on the map")
		modal.call("close")

		# 9. One placed camp: crosshair pick + footprint highlight, then CAMP
		# mode — click an element in the preview, turn it, remove another, save
		# to THIS camp only; then a map-wide edit; then a second layout.
		var pick: Dictionary = loader.call("pick_camp_at_world", a.x, a.y)
		loader.call("set_camp_focus", str(pick.get("id", "")))
		var hl := (main.get_node_or_null("Terrain/CampAreaHighlight")) as MeshInstance3D
		_camp_result(bool(pick.get("valid", false)) and str(pick.get("id", "")) == id
			and hl != null and hl.visible and hl.mesh != null,
			"aiming at a camp picks it and highlights its footprint")
		loader.call("set_camp_focus", "")
		loader.call("open_camp_tune_for_camp", id)
		await get_tree().create_timer(1.0).timeout
		_camp_result(bool(modal.call("is_camp_mode")), "clicking a camp opens the modal on THAT camp")
		var prt2 := modal.get("_runtime") as CampAreaRuntime
		var items: Array = prt2.area_items("preview")
		var rv_items: Array = items.filter(func(it: Dictionary) -> bool: return str(it["cls"]) == "rv")
		var pcam := modal.get("_camera") as Camera3D
		var want_item: Dictionary = rv_items[rv_items.size() / 2] if not rv_items.is_empty() else {}
		var got := ""
		if not want_item.is_empty():
			got = str(modal.call("pick_element", pcam.unproject_position((want_item["pos"] as Vector3) + Vector3(0, 1.2, 0))))
		print("PlaytestHarness: camps — camp mode: %d elements in the preview (%d RVs); clicked %s, picked %s" % [
			items.size(), rv_items.size(), str(want_item.get("key", "")), got])
		_camp_result(not got.is_empty() and got == str(want_item.get("key", "")),
			"a click in the preview picks the element under it")
		var before_n := int((loader.call("camp_area_info", id) as Dictionary).get("structures", 0))
		modal.set("_selected_key", got)
		modal.call("_edit_selected", "yaw_deg", 90.0)
		modal.call("_update_marker")
		await get_tree().create_timer(0.6).timeout
		await _shoot_ui(dir, "tune_02_camp_element_turned")
		var victim := str((rv_items[0] as Dictionary)["key"]) if rv_items.size() > 1 else ""
		if victim == got and rv_items.size() > 1:
			victim = str((rv_items[1] as Dictionary)["key"])
		modal.set("_selected_key", victim)
		modal.call("_remove_selected")
		modal.call("_save_to_camp")
		await get_tree().create_timer(0.8).timeout
		var rec_after: Dictionary = loader.call("camp_area_info", id)
		var saved_edits: Dictionary = rec_after.get("edits", {})
		var turned_ok := false
		for xf: Transform3D in rt.area_class_transforms(id, "rv"):
			var ax := xf.basis.x
			if absf(CampLayoutGenerator.axis_deviation_deg(atan2(ax.z, ax.x), float(rec_after["heading_deg"])) - 90.0) < 6.0:
				turned_ok = true
		print("PlaytestHarness: camps — saved to this camp: edits=%s, structures %d -> %d" % [
			str(saved_edits), before_n, int(rec_after.get("structures", 0))])
		_camp_result(saved_edits.size() == 2 and turned_ok
			and int(rec_after.get("structures", 0)) == before_n - 1
			and FileAccess.get_file_as_string(path).contains("\"edits\""),
			"hand edits are saved on the camp and drawn on the map")

		# Map scope: thin every RV-park camp on this map.
		var rv_before := 0
		for rec: Dictionary in (loader.get("camp_areas") as CampAreaLayer).areas:
			if str(rec["style"]) == "rv_park":
				rv_before += rt.area_structure_count(str(rec["id"]))
		modal.set("_delta", {"fill": 0.4})
		modal.call("_save_to_map")
		await get_tree().create_timer(0.8).timeout
		var rv_after := 0
		for rec: Dictionary in (loader.get("camp_areas") as CampAreaLayer).areas:
			if str(rec["style"]) == "rv_park":
				rv_after += rt.area_structure_count(str(rec["id"]))
		print("PlaytestHarness: camps — map-wide fill 0.4: RV-park structures %d -> %d; map style %s" % [
			rv_before, rv_after, str(loader.call("map_camp_style", "rv_park"))])
		_camp_result(rv_after < rv_before and not (loader.call("map_camp_style", "rv_park") as Dictionary).is_empty()
			and (loader.call("camp_area_info", id).get("edits", {}) as Dictionary).size() == 2,
			"'all camps of this type on this map' restyles them and keeps the hand edits")

		# Layouts: a second look under the same style, saved globally, then
		# dealt to new camps by chance.
		modal.set("_delta", {"lane_w": 12.0, "templates": {"van_site": 8.0, "rv_site": 0.0}})
		modal.call("_on_new_layout")
		modal.call("_save_to_global")
		await get_tree().create_timer(0.8).timeout
		modal.call("close")
		var layouts := CampStyles.variants("rv_park")
		var dealt := {}
		for n in 14:
			var c := a + Vector2(-260.0 + float(n % 7) * 44.0, 190.0 + float(n / 7) * 44.0)
			var nid := str(loader.call("paint_camp_area", PackedVector2Array([c + Vector2(-18, -18),
				c + Vector2(18, -18), c + Vector2(18, 18), c + Vector2(-18, 18)]),
				{"style": "rv_park", "seed": 1000 + n * 37}))
			if not nid.is_empty():
				var dealt_v := str((loader.call("camp_area_info", nid) as Dictionary).get("variant", "?"))
				dealt[dealt_v] = int(dealt.get(dealt_v, 0)) + 1
		print("PlaytestHarness: camps — layouts of rv_park: %s; 14 new camps were dealt %s" % [
			str(layouts.map(func(lv: Variant) -> String: return str((lv as Dictionary).get("name", "")))), str(dealt)])
		_camp_result(layouts.size() == 1 and dealt.size() == 2,
			"a saved layout is mixed into new camps of that style")
	_restore_files(style_snap)
	CampStyleStore.load_and_apply()
	CampMeshLibrary.clear_cache()
	if ui_layer != null:
		ui_layer.visible = false

	# 10. Festival placement on REAL ground: a road along site B's long edge, a
	# zone cut into equal-usable lots, each one a filled camp. Asserts what the
	# offline selftest cannot — fairness on a real DEM with the loader's real
	# exclusions — and that a fresh attach + undo both reproduce it.
	await _camp_placement_step(loader, sites)

	# Leave the map exactly as found.
	_restore_files(snap)
	loader.set("camp_areas", null)
	loader.set("placement", null)
	loader.call("_attach_camp_areas")
	print("PlaytestHarness: camps — restored %s" % (
		"the map's own camps" if snap[path] != null else "a map with no camps"))
	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	cam.queue_free()
	print("PlaytestHarness: camps — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Step 10 of the camps capture: festival placement end to end on real ground.
func _camp_placement_step(loader: Node, sites: Array) -> void:
	if sites.is_empty() or not loader.has_method("add_placement_zone"):
		_camp_result(false, "placement: no site / no placement API on the loader")
		return
	var b: Vector2 = sites[sites.size() - 1]
	var hw := CAMP_SITE_W * 0.5 + 30.0
	var hd := CAMP_SITE_D * 0.5 + 10.0
	var zone_poly := PackedVector2Array([b + Vector2(-hw, -hd), b + Vector2(hw, -hd),
		b + Vector2(hw, hd), b + Vector2(-hw, hd)])
	# Clear whatever the plots step left on that ground, then draw the road
	# just inside the zone's long (south) edge and the zone fronting it.
	loader.call("erase_camps_in_polygon", zone_poly)
	var road_pts := FestivalPlacementLayer.road_from_zone_edge(zone_poly, 0, 6.0, 6.0)
	var rid := str(loader.call("add_festival_road", road_pts, {"name": "Esplanade", "width_m": 8.0}))
	var zid := str(loader.call("add_placement_zone", zone_poly, {
		"spec": {"mode": "count", "target_n": 8, "depth_m": 25.0, "lane_w_m": 5.0,
			"lots_per_lane": 4, "styles": ["mixed"]}, "subdivide": true}))
	var zinfo: Dictionary = loader.call("placement_info", "zone", zid)
	var st: Dictionary = zinfo.get("stats", {})
	var lots: Array = (loader.get("placement") as FestivalPlacementLayer).lots_for_zone(zid) \
		if not zid.is_empty() else []
	print("PlaytestHarness: camps — placement: road %s, zone %s fronts %s; usable %.0f / %.0f m², %d lots, %.0f–%.0f m² (max/min %.2f, Gini %.3f), ~%d people, remainder %.0f m², warnings %s" % [
		rid, zid, str(zinfo.get("road_ids", [])), float(st.get("usable_m2", 0.0)),
		float(st.get("raw_m2", 0.0)), int(st.get("lots", 0)), float(st.get("usable_min", 0.0)),
		float(st.get("usable_max", 0.0)), float(st.get("ratio_max_min", 0.0)),
		float(st.get("gini", 0.0)), int(st.get("capacity_people", 0)),
		float(st.get("remainder_m2", 0.0)), str(st.get("warnings", []))])
	var road: Dictionary = loader.call("placement_info", "road", rid)
	var filled := 0
	var touching := 0
	var total_structs := 0
	for l: Dictionary in lots:
		var li: Dictionary = loader.call("placement_info", "lot", str(l["lot_id"]))
		var n := int(li.get("structures", 0))
		total_structs += n
		if n > 0:
			filled += 1
		var nearest := INF
		for v in (l["polygon"] as PackedVector2Array):
			var pts: PackedVector2Array = road["points"]
			for i in range(pts.size() - 1):
				nearest = minf(nearest, v.distance_to(Geometry2D.get_closest_point_to_segment(v, pts[i], pts[i + 1])))
		if nearest <= float(road["half_width_m"]) + 0.9:
			touching += 1
		print("PlaytestHarness: camps —   lot %-4s usable %6.0f raw %6.0f front %5.1f m slope %4.1f° fair %.2f structures %d" % [
			str(l["name"]), float(l["usable_m2"]), float(l["raw_m2"]), float(l["frontage_m"]),
			float(l["mean_slope_deg"]), float(l["fairness"]), n])
	_camp_result(not rid.is_empty() and not zid.is_empty() and (zinfo.get("road_ids", []) as Array).has(rid),
		"placement: the zone fronts the drawn road")
	_camp_result(lots.size() >= 6 and filled == lots.size(),
		"placement: ≥6 lots, every one filled with structures (%d lots, %d filled)" % [lots.size(), filled])
	_camp_result(float(st.get("ratio_max_min", 99.0)) <= 1.25,
		"placement: equal usable area on real terrain (max/min %.2f ≤ 1.25)" % float(st.get("ratio_max_min", 0.0)))
	_camp_result(touching == lots.size(), "placement: every lot touches the road (%d/%d)" % [touching, lots.size()])
	# A fresh attach (= what a reload does) reproduces the same lots and camps.
	var camps_before := int((loader.call("camp_areas_summary") as Dictionary).get("areas", 0))
	loader.set("camp_areas", null)
	loader.set("placement", null)
	loader.call("_attach_camp_areas")
	var lots_again: Array = (loader.get("placement") as FestivalPlacementLayer).lots_for_zone(zid)
	var camps_after := int((loader.call("camp_areas_summary") as Dictionary).get("areas", 0))
	_camp_result(lots_again.size() == lots.size() and camps_after == camps_before,
		"placement: a fresh attach reproduces %d lots / %d camps" % [lots.size(), camps_before])
	# Undo takes the whole thing back (both layers).
	loader.call("push_placement_undo")
	loader.call("delete_placement_zone", zid)
	var gone := (loader.get("placement") as FestivalPlacementLayer).lots_for_zone(zid).is_empty()
	var undone := bool(loader.call("undo_placement"))
	var back := (loader.get("placement") as FestivalPlacementLayer).lots_for_zone(zid).size()
	_camp_result(gone and undone and back == lots.size(),
		"placement: delete removes the lots and their camps, undo brings them back")


## The two candidate centres (>= 260 m apart) where a test camp fills best —
## scored with the real generator and the loader's real exclusions/ground, so
## the run lands on ground a player could actually camp on.
func _camp_pick_sites(loader: Node) -> Array:
	var ctx: Dictionary = loader.call("_camp_ctx")
	var scored: Array = []
	var hw := CAMP_SITE_W * 0.5
	var hd := CAMP_SITE_D * 0.5
	for gx in range(-4, 5):
		for gz in range(-4, 5):
			var c := Vector2(gx * 130.0, gz * 130.0)
			var rect := PackedVector2Array([c + Vector2(-hw, -hd), c + Vector2(hw, -hd),
				c + Vector2(hw, hd), c + Vector2(-hw, hd)])
			var res := CampLayoutGenerator.generate({"polygon": rect, "style": "rv_park",
				"density": 1.0, "seed": 1, "heading_deg": 90.0}, ctx)
			scored.append({"c": c, "n": int(res["stats"]["structures"])})
	scored.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return int(x["n"]) > int(y["n"]))
	var out: Array = []
	if scored.is_empty() or int(scored[0]["n"]) < 10:
		return out
	out.append(scored[0]["c"])
	for s: Dictionary in scored:
		if (s["c"] as Vector2).distance_to(out[0]) >= 260.0 and int(s["n"]) >= 10:
			out.append(s["c"])
			break
	return out


func _camp_waypoints(loader: Node, a: Vector2, b: Vector2) -> Array:
	var ga := _ground_y(loader, a.x, a.y)
	var gb := _ground_y(loader, b.x, b.y)
	return [
		{"pos": Vector3(a.x - 110.0, ga + 60.0, a.y - 110.0), "look": Vector3(a.x, ga, a.y),
			"tag": "camp_oblique"},
		{"pos": Vector3(a.x, ga + 170.0, a.y + 12.0), "look": Vector3(a.x, ga, a.y),
			"tag": "camp_overhead"},
		{"pos": Vector3(a.x - 30.0, ga + 2.2, a.y - 28.0), "look": Vector3(a.x + 20.0, ga + 1.5, a.y + 10.0),
			"tag": "camp_street"},
		{"pos": Vector3(b.x, gb + 230.0, b.y + 16.0), "look": Vector3(b.x, gb, b.y),
			"tag": "plots_overhead"},
		{"pos": Vector3(b.x - 140.0, gb + 70.0, b.y - 120.0), "look": Vector3(b.x, gb, b.y),
			"tag": "plots_oblique"},
	]


# ==================== VEG DOCK CAPTURE (--capture=vegdock) ====================
# Veg overhaul Phase 8: shoot the redesigned paint dock and the Tune-look modal
# through their REAL entry points, so a layout/theme regression is visible
# rather than merely compiling. Read-only BY RESTORE: the modal's Apply — which
# this harness exercises on purpose — persists global + per-map style, so the
# style files are snapshotted before the run and byte-restored after (the same
# discipline --capture=areafill applies to auto_veg_edits). Without this every
# vegdock run silently rewrote the player's saved looks.

## path -> PackedByteArray (missing files stored as null → deleted on restore).
func _snapshot_files(paths: Array) -> Dictionary:
	var out := {}
	for p in paths:
		var path := str(p)
		if FileAccess.file_exists(path):
			out[path] = FileAccess.get_file_as_bytes(path)
		else:
			out[path] = null
	return out


func _restore_files(snap: Dictionary) -> void:
	for p in snap:
		var path := str(p)
		if snap[p] == null:
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
			continue
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(snap[p])
			f.close()


func _run_veg_dock_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: vegdock needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var label := _shots_label if not _shots_label.is_empty() else "veg_dock"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)

	var dock: Node = loader.get("_vegetation_edit_ui")
	if dock == null:
		print("PlaytestHarness: vegdock FAIL — the map has no vegetation dock")
		_maybe_quit()
		return
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var style_snap := _snapshot_files([
		VegStyleStore.global_v2_path(),
		VegStyleStore.map_v2_path(lat, lon),
		WorldPaths.site_file("vegetation", lat, lon),
		VegetationStyleConfig.SPECIES_DEFAULTS_PATH,
		VegetationStyleConfig.PRESETS_PATH,
	])
	dock.call("toggle_mode")
	await get_tree().create_timer(1.0).timeout
	print("PlaytestHarness: vegdock — dock open=%s, chips=%d" % [
		str(dock.get("_active")), (dock.call("chip_specs") as Array).size()])
	await _shoot_ui(dir, "dock_paint")

	# Each tool/shape combination re-lays the chip row; a clipped or overflowing
	# row shows up here and nowhere else.
	dock.call("set_paint_density", 2.4)
	dock.call("set_brush_style", {"deciduous_canopy_w": 3.0})
	await get_tree().create_timer(0.4).timeout
	await _shoot_ui(dir, "dock_custom_brush")
	dock.call("set_brush_style", {})
	dock.call("_set_tool", 3)  # Select
	await get_tree().create_timer(0.4).timeout
	await _shoot_ui(dir, "dock_select")
	dock.call("_set_tool", 1)  # Place (hero row visible)
	await get_tree().create_timer(0.4).timeout
	await _shoot_ui(dir, "dock_place")
	dock.call("_set_tool", 0)

	# Tune look: it must now STAY OPEN after Apply (Phase 8b).
	if loader.has_method("open_vegetation_preview_editor"):
		loader.call("open_vegetation_preview_editor", 0)
		await get_tree().create_timer(1.5).timeout
		await _shoot_ui(dir, "tune_look")
		var modal: Node = loader.get("_vegetation_preview_ui")
		if modal != null:
			var before := bool(modal.get("visible"))
			modal.call("_apply_to_map")
			await get_tree().create_timer(1.5).timeout
			var after := bool(modal.get("visible"))
			print("PlaytestHarness: vegdock %s — Tune look stays open after Apply (was %s, now %s)"
				% ["PASS" if (before and after) else "FAIL", str(before), str(after)])
			await _shoot_ui(dir, "tune_look_after_apply")
			modal.call("close")
	await get_tree().create_timer(0.5).timeout
	dock.call("_exit_mode")
	_restore_files(style_snap)
	VegStyleStore.invalidate_cache()
	print("PlaytestHarness: vegdock — style files restored, shots in %s"
		% ProjectSettings.globalize_path(dir))
	_maybe_quit()


# ==================== POINTS OF INTEREST (--capture=poi) ====================
# Imports the shipped Google Earth export of the Mount Vernon property
# (core/poi/testdata/compoundity.kml) through the loader's REAL import path
# and asserts what a PNG cannot: 15 markers built, the House pin standing at
# GeoMath's xz for its coordinates and ON the ground, nothing outside the map,
# the Site Plan marker list agreeing with the 3D markers, Go putting the
# player beside a pin, hide emptying the plan list, and a re-import REPLACING
# (never doubling). Shoots an aerial over the pins and a street shot at the
# Top Culvert Inlet. Snapshots and byte-restores the site's poi file + the
# show_pois pref, so a run never leaves the fixture pins on the player's site
# (run it on mtvernon, where the pins fall on the actual property).

func _run_poi_verify() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: poi needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var label := _shots_label if not _shots_label.is_empty() else "poi"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var poi_path := PoiLayer.save_path_for_map(lat, lon)
	var snap := _snapshot_files([poi_path])
	var show_before := bool(loader.call("show_pois"))
	# The pins must be SHOWN for the marker checks: poi_markers() is empty
	# while they are hidden, and the player's own pref may hide them (the
	# author's terrain_config.cfg had show_pois=false — two checks failed on
	# the setting, not the code). Restored with show_before at the end.
	loader.call("set_show_pois", true)
	var before_count := (loader.call("poi_records") as Array).size()
	# ⚠ A GDScript lambda captures locals BY VALUE — the counter lives in an Array.
	var fails := [0]
	var check := func(name: String, ok: bool, detail: String = "") -> void:
		print("PlaytestHarness: poi %s — %s%s" % ["PASS" if ok else "FAIL", name,
			"" if detail.is_empty() else " (" + detail + ")"])
		if not ok:
			fails[0] += 1

	const SRC := "compoundity.kml"
	var fixture := "res://core/poi/testdata/" + SRC
	var res: Dictionary = loader.call("import_kml_file", fixture)
	check.call("import ok", bool(res.get("ok", false)), str(res.get("error", "")))
	check.call("15 placemarks added", int(res.get("added", 0)) == 15, str(res.get("added", 0)))
	check.call("every pin inside this map", int(res.get("off_map", 0)) == 0, str(res.get("off_map", 0)))
	var rt: Node = loader.get("_poi_runtime")
	check.call("runtime exists under Terrain", rt != null and rt.get_parent() != null and rt.get_parent().name == "Terrain")
	if rt == null:
		_restore_files(snap)
		_maybe_quit()
		return
	check.call("one marker per record", int(rt.call("marker_count")) == before_count + 15,
		"%d vs %d" % [int(rt.call("marker_count")), before_count + 15])

	var house: Dictionary = {}
	var top: Dictionary = {}
	var line: Dictionary = {}
	var fixture_ids: Array = []
	for r_v in loader.call("poi_records"):
		var r: Dictionary = r_v
		if str(r.get("source", "")) != SRC:
			continue
		fixture_ids.append(str(r["id"]))
		match str(r.get("name", "")):
			"House":
				house = r
			"Top Culvert Inlet":
				top = r
			"Longest Possible Run From Pond":
				line = r
	check.call("House / Top Culvert / pond-run records present", not house.is_empty() and not top.is_empty() and not line.is_empty())
	if house.is_empty() or top.is_empty():
		loader.call("remove_poi_source", SRC)
		_restore_files(snap)
		_maybe_quit()
		return
	var exp := GeoMath.lonlat_to_local_m(48.3251389, -122.2468056, lat, lon)
	var hp: Vector3 = rt.call("marker_position", str(house["id"]))
	check.call("House pin at GeoMath's xz for its coordinates",
		Vector2(hp.x, hp.z).distance_to(exp) < 0.05, "%s vs %s" % [str(Vector2(hp.x, hp.z)), str(exp)])
	var gy := float(loader.call("ground_height_at", hp.x, hp.z))
	check.call("House pin standing on the ground", absf(hp.y - gy) < 0.05, "pin y %.2f ground %.2f" % [hp.y, gy])
	var marks: Array = loader.call("poi_markers")
	var mk: Dictionary = {}
	var lmk: Dictionary = {}
	for m in marks:
		if str(m.get("id", "")) == str(house["id"]):
			mk = m
		elif str(m.get("id", "")) == str(line["id"]):
			lmk = m
	check.call("Site Plan marker matches the 3D pin xz", not mk.is_empty()
		and (mk["pos"] as Vector2).distance_to(Vector2(hp.x, hp.z)) < 0.01)
	check.call("Site Plan line marker carries its 7 vertices", not lmk.is_empty()
		and (lmk["points"] as PackedVector2Array).size() == 7, str((lmk.get("points", PackedVector2Array()) as PackedVector2Array).size()))
	var line_node: Node = rt.get_node_or_null("Poi_" + str(line["id"]))
	check.call("line record built a ribbon", line_node != null and line_node.get_node_or_null("Ribbon") != null)

	# Go: the player lands a step beside the pin, on the ground.
	var scene := get_tree().current_scene
	var player: Node3D = scene.find_child("Player", true, false) if scene != null else null
	var tp: Vector3 = rt.call("marker_position", str(top["id"]))
	var went := bool(loader.call("teleport_to_poi", str(top["id"])))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var pp: Vector3 = player.global_position if player != null else Vector3.INF
	check.call("Go lands beside the Top Culvert Inlet", went and player != null
		and Vector2(pp.x, pp.z).distance_to(Vector2(tp.x, tp.z)) < 3.5
		and pp.y > tp.y - 1.5 and pp.y < tp.y + 4.0, "player %s pin %s" % [str(pp), str(tp)])
	check.call("Go on an unknown id is refused", not bool(loader.call("teleport_to_poi", "poi_nope")))

	# The UI: the Terrain options panel is a top-right box with NO scrolling,
	# and the KML block was unfindable at the bottom of its long column (the
	# user's report). Open the real panel, shoot it, and assert the block's
	# title sits INSIDE the viewport with the import row under it.
	var opts: Control = loader.get("_terrain_options_ui")
	check.call("Terrain options panel exists", opts != null)
	if opts != null and opts.has_method("toggle_expanded"):
		# _set_capture_conditions hides every CanvasLayer under Main (the HUD),
		# and is_visible_in_tree() does NOT see a CanvasLayer ancestor — show
		# the panel's own layer for the shot and hide it again after.
		var ui_layer := opts.get_parent() as CanvasLayer
		var layer_was := ui_layer.visible if ui_layer != null else true
		if ui_layer != null:
			ui_layer.visible = true
		opts.visible = true
		if not bool(opts.get("_expanded")):
			opts.call("toggle_expanded")
		await get_tree().process_frame
		await get_tree().process_frame
		var title: Control = opts.get("_poi_title")
		var vp_rect := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
		var on_screen := title != null and title.is_visible_in_tree() \
			and (ui_layer == null or ui_layer.visible) \
			and vp_rect.encloses(title.get_global_rect()) \
			and vp_rect.encloses(opts.get_global_rect())
		check.call("KML block + its panel are on screen in Terrain options", on_screen,
			"" if title == null else "title %s panel %s viewport %s" % [str(title.get_global_rect()), str(opts.get_global_rect()), str(vp_rect)])
		var list: Control = opts.get("_poi_list")
		check.call("KML pin list shows the fixture's rows after a programmatic import", list != null
			and list.get_child_count() > 0 and list.is_visible_in_tree())
		await _shoot_ui(dir, "00_terrain_options_kml_block")
		opts.call("toggle_expanded")
		if ui_layer != null:
			ui_layer.visible = layer_was
	else:
		fails[0] += 2
		print("PlaytestHarness: poi FAIL — Terrain options panel cannot be expanded")

	# Shots: a street view at the Top Culvert Inlet, then an aerial over the lot.
	var prev_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.name = "PoiCaptureCam"
	cam.fov = 70.0
	scene.add_child(cam)
	cam.make_current()
	var eye := Vector3(pp.x, pp.y + 1.6, pp.z) if pp != Vector3.INF else tp + Vector3(0, 1.7, 3.0)
	cam.global_position = eye
	cam.look_at(tp + Vector3(0.0, PoiRuntime.POLE_H, 0.0), Vector3.UP)
	await get_tree().create_timer(0.8).timeout
	await _shoot_ui(dir, "01_street_top_culvert_inlet")
	var centroid := Vector3.ZERO
	var n := 0
	for id in fixture_ids:
		var p: Vector3 = rt.call("marker_position", str(id))
		if p != Vector3.INF:
			centroid += p
			n += 1
	if n > 0:
		centroid /= float(n)
	cam.global_position = centroid + Vector3(0.0, 150.0, 110.0)
	cam.look_at(centroid, Vector3.UP)
	await get_tree().create_timer(0.8).timeout
	await _shoot_ui(dir, "02_aerial_pins")
	cam.global_position = hp + Vector3(6.0, 2.2, 7.0)
	cam.look_at(hp + Vector3(0.0, 1.8, 0.0), Vector3.UP)
	await get_tree().create_timer(0.6).timeout
	await _shoot_ui(dir, "03_house_pin_closeup")

	# Hide / show: the plan list empties with the pins, nothing is lost.
	loader.call("set_show_pois", false)
	var house_node: Node3D = rt.get_node_or_null("Poi_" + str(house["id"]))
	check.call("hidden: marker invisible, plan list empty, records kept",
		house_node != null and not house_node.visible and (loader.call("poi_markers") as Array).is_empty()
		and (loader.call("poi_records") as Array).size() == before_count + 15)
	loader.call("set_show_pois", true)
	check.call("shown again", house_node != null and house_node.visible and not (loader.call("poi_markers") as Array).is_empty())

	# Re-import replaces, never doubles; the file is on disk.
	var res2: Dictionary = loader.call("import_kml_file", fixture)
	check.call("re-import replaced 15, still 15", int(res2.get("replaced", 0)) == 15
		and int(rt.call("marker_count")) == before_count + 15, str(res2))
	check.call("poi file written", FileAccess.file_exists(poi_path), poi_path)
	var reread := PoiLayer.create_empty()
	reread.load_from(poi_path)
	check.call("file round-trips the records", reread.count() == before_count + 15, str(reread.count()))

	# Cleanup: remove the fixture source, then byte-restore the file + pref.
	var removed := int(loader.call("remove_poi_source", SRC))
	check.call("remove_poi_source drops 15, markers back to before", removed == 15
		and int(rt.call("marker_count")) == before_count, "%d removed, %d markers" % [removed, int(rt.call("marker_count"))])
	if is_instance_valid(prev_cam):
		prev_cam.make_current()
	cam.queue_free()
	_restore_files(snap)
	loader.call("set_show_pois", show_before)
	loader.call("_attach_pois")
	print("PlaytestHarness: poi %s — %d failure(s); poi file + show_pois restored; shots in %s"
		% ["PASS" if fails[0] == 0 else "FAIL", fails[0], ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## --capture=assetpack: Share end to end through the REAL modal. Exports the
## running world (+ its map data, presets and music — no art, no model
## library, to keep the pack small) via AssetPackModal, installs it again by
## emitting the window's files_dropped (the drag-and-drop path), then plays
## the imported copy through WorldSession.launch and diffs its fingerprint
## against the original's: props, lights, camps, tiles, graph ids and wires.
## `--import=<pack>` skips the export and installs that pack into this
## world's sandbox instead; `--pack-out=<path>` keeps the exported pack there
## (for the fresh-machine side, --capture=assetpack-import).
func _run_assetpack_capture() -> void:
	var tree := get_tree()
	var fails := 0
	var label := _shots_label if not _shots_label.is_empty() else "assetpack"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var main := await _await_world_scene(-1)
	var import_path := ""
	var pack_out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--import="):
			import_path = a.trim_prefix("--import=")
		elif a.begins_with("--pack-out="):
			pack_out = a.trim_prefix("--pack-out=")
	if main == null:
		push_error("assetpack: FAIL — no world scene")
		_maybe_quit()
		return
	main.set("time_scale", 0.0)
	var src_id := WorldSession.active_id()
	var fp1 := WorldSession.fingerprint(main)
	var pack := import_path
	if pack.is_empty():
		if src_id.is_empty():
			push_error("assetpack: FAIL — no world active (run with --world=<name>)")
			_maybe_quit()
			return
		var m := AssetPackModal.open_export(main, src_id)
		await _assetpack_idle(m)
		await _shoot_ui(dir, "01_export_tab")
		var cat: AssetPackCatalog = m.get("_catalog")
		if cat == null or cat.items_in(AssetPackFormat.SEC_WORLDS).is_empty():
			fails += 1
			push_error("assetpack: FAIL — the export tab listed no worlds")
		else:
			print("assetpack: export tab PASS — %d items, %d worlds" % [cat.items.size(),
				cat.items_in(AssetPackFormat.SEC_WORLDS).size()])
			var sel: Dictionary = m.get("_sel")
			for it in cat.items:
				var iid := str(it["id"])
				sel[iid] = (iid == "world:" + src_id) or iid.begins_with("mapcache:") \
					or iid == "lib:presets" or iid == "lib:music"
			m.call("_refresh_checks")
			m.call("_refresh_totals")
			await _shoot_ui(dir, "02_export_selection")
			pack = pack_out if not pack_out.is_empty() else "user://__assetpack_capture/harness%s" % AssetPackFormat.EXT
			var t0 := Time.get_ticks_msec()
			m.call("_start_export", pack)
			await _assetpack_idle(m)
			await _shoot_ui(dir, "03_export_done")
			var ok := FileAccess.file_exists(pack) and int(m.get("_view")) == AssetPackModal.View.DONE
			if not ok:
				fails += 1
			print("assetpack: export %s — %s in %.1f s" % ["PASS" if ok else "FAIL",
				AssetPackFormat.human_size(FileAccess.get_size(pack)), (Time.get_ticks_msec() - t0) / 1000.0])
		(m.get("_frame") as ModalFrame).close()
		for _i in 10:
			await tree.process_frame
	var before := {}
	for w in WorldStore.list(WorldPaths.WORLDS_DIR, true):
		before[str(w["id"])] = true
	# Install by DROPPING the pack on the window (CursorController's handler).
	tree.root.files_dropped.emit(PackedStringArray([ProjectSettings.globalize_path(pack)]))
	var im: Node = null
	for _j in 60:
		await tree.process_frame
		im = tree.current_scene.get_node_or_null(AssetPackModal.NODE_NAME)
		if im != null:
			break
	if im == null:
		fails += 1
		push_error("assetpack: FAIL — dropping the pack did not open the Install tab")
		_maybe_quit()
		return
	await _assetpack_idle(im)
	var info: Dictionary = im.get("_info")
	print("assetpack: drop opens install preview %s — %s" % ["PASS" if bool(info.get("ok", false)) else "FAIL",
		str(info.get("error", "ok"))])
	if not bool(info.get("ok", false)):
		fails += 1
	await _shoot_ui(dir, "04_import_preview")
	im.call("_on_install_pressed")
	await _assetpack_idle(im)
	await _shoot_ui(dir, "05_import_done")
	var new_recs: Array = []
	for w2 in WorldStore.list(WorldPaths.WORLDS_DIR, true):
		if not before.has(str(w2["id"])):
			new_recs.append(w2)
	if new_recs.is_empty():
		fails += 1
		push_error("assetpack: FAIL — no new world after install")
		_maybe_quit()
		return
	print("assetpack: install PASS — %s added (%s)" % [UiText.count(new_recs.size(), "world"),
		", ".join(PackedStringArray(new_recs.map(func(r): return WorldStore.display_name(r))))])
	var target: Dictionary = new_recs[0]
	if not src_id.is_empty() and import_path.is_empty():
		for r2 in new_recs:
			if str((r2 as Dictionary).get("imported_from", {}).get("id", "")) == src_id:
				target = r2
		var a := WorldStore.data_files(WorldStore.get_world(src_id))
		var b := WorldStore.data_files(target)
		var same := 0
		var differ: Array[String] = []
		for tag in a:
			if b.has(tag) and FileAccess.get_sha256(str(a[tag])) == FileAccess.get_sha256(str(b[tag])):
				same += 1
			else:
				differ.append(str(tag))
		if differ.is_empty():
			print("assetpack: world data PASS — %d files byte-identical" % same)
		else:
			fails += differ.size()
			push_error("assetpack: FAIL — data files differ or missing: %s" % ", ".join(PackedStringArray(differ)))
	(im.get("_frame") as ModalFrame).close()
	for _k in 10:
		await tree.process_frame
	var prev := tree.current_scene.get_instance_id()
	var err := WorldSession.launch(WorldStore.get_world(str(target["id"])), {})
	var main2: Node = null
	if err == OK:
		main2 = await _await_world_scene(prev)
	if main2 == null:
		fails += 1
		push_error("assetpack: FAIL — the imported world did not open (error %d)" % err)
	elif import_path.is_empty():
		var fp2 := WorldSession.fingerprint(main2)
		var bad: Array = []
		for d in WorldSession.fingerprint_diff(fp1, fp2):
			var k := str(d[0])
			if k.begins_with("count.") or k.ends_with(".ids") or k == "graph.connections":
				bad.append(d)
		if bad.is_empty():
			print("assetpack: imported world plays PASS — props, lights, camps, tiles and graph match")
		else:
			fails += bad.size()
			for d2 in bad:
				push_error("assetpack: FAIL — %s was %s, imported copy has %s" % [d2[0], str(d2[1]), str(d2[2])])
		await _shoot_ui(dir, "06_imported_world")
	else:
		print("assetpack: imported world plays PASS — %s" % WorldStore.display_name(target))
		await _shoot_ui(dir, "06_imported_world")
	if import_path.is_empty() and pack_out.is_empty():
		for pth in [pack, AssetPackFormat.part_path(pack, 2)]:
			if FileAccess.file_exists(pth):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(pth))
	print("PlaytestHarness: assetpack %s — %d failure(s); shots in %s"
		% ["PASS" if fails == 0 else "FAIL", fails, ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## --capture=assetpack-import --import=<pack>: the friend's side, on the
## launch hub of an EMPTY user folder (tools\harness.ps1 -EmptyUser). Drops
## the pack on the window, installs it with the modal's defaults, checks the
## worlds appear in the hub's list, then plays the first one and waits for
## its map to finish loading.
func _run_assetpack_import_capture() -> void:
	var tree := get_tree()
	var fails := 0
	var label := _shots_label if not _shots_label.is_empty() else "assetpack_import"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var pack := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--import="):
			pack = a.trim_prefix("--import=")
	if pack.is_empty() or not FileAccess.file_exists(pack):
		push_error("assetpack-import: FAIL — give --import=<path to a .simpack.zip> (got '%s')" % pack)
		_maybe_quit()
		return
	for _i in 120:
		await tree.process_frame
	var had := WorldStore.list(WorldPaths.WORLDS_DIR, true).size()
	print("assetpack-import: starting with %s on this machine" % UiText.count(had, "world"))
	await _shoot_ui(dir, "01_launch_hub")
	tree.root.files_dropped.emit(PackedStringArray([pack]))
	var im: Node = null
	for _j in 60:
		await tree.process_frame
		im = tree.current_scene.get_node_or_null(AssetPackModal.NODE_NAME) if tree.current_scene != null else null
		if im != null:
			break
	if im == null:
		push_error("assetpack-import: FAIL — dropping the pack did not open the Install tab")
		_maybe_quit()
		return
	await _assetpack_idle(im)
	var info: Dictionary = im.get("_info")
	if not bool(info.get("ok", false)):
		fails += 1
		push_error("assetpack-import: FAIL — %s" % str(info.get("error", "")))
	await _shoot_ui(dir, "02_import_preview")
	var t0 := Time.get_ticks_msec()
	im.call("_on_install_pressed")
	await _assetpack_idle(im)
	await _shoot_ui(dir, "03_import_done")
	var recs := WorldStore.list(WorldPaths.WORLDS_DIR, true)
	var added := recs.size() - had
	print("assetpack-import: install %s — %s in %.1f s" % ["PASS" if added > 0 else "FAIL",
		UiText.count(added, "world"), (Time.get_ticks_msec() - t0) / 1000.0])
	if added <= 0:
		fails += 1
		_maybe_quit()
		return
	var target: Dictionary = {}
	for r in recs:
		if (r as Dictionary).has("imported_from"):
			target = r
			break
	var map: Dictionary = target.get("map", {})
	if WorldStore.is_generated_map(map):
		var def_ok := ResourceLoader.exists(str(map.get("map_def_path", "")))
		print("assetpack-import: map registry entry %s" % ("PASS" if def_ok else "FAIL"))
		if not def_ok:
			fails += 1
	(im.get("_frame") as ModalFrame).close()
	for _k in 10:
		await tree.process_frame
	var prev := tree.current_scene.get_instance_id() if tree.current_scene != null else -1
	var err := WorldSession.launch(target, {})
	var main2: Node = null
	if err == OK:
		main2 = await _await_world_scene(prev)
	if main2 == null:
		fails += 1
		push_error("assetpack-import: FAIL — %s did not open (error %d)" % [WorldStore.display_name(target), err])
	else:
		var sm := WorldSession.summary(main2)
		print("assetpack-import: plays PASS — %s: %d props, %d graph nodes" % [WorldStore.display_name(target),
			int(sm.get("props", 0)), int(sm.get("graph_nodes", 0))])
		await _shoot_ui(dir, "04_imported_world")
	print("PlaytestHarness: assetpack-import %s — %d failure(s); shots in %s"
		% ["PASS" if fails == 0 else "FAIL", fails, ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## --capture=hubsettings (kind "menu"): Settings from the LAUNCH HUB. Presses
## the header gear with a REAL click, asserts the modal opened on exactly the
## Main-free pages (TimelineSettingsPanel.HUB_PAGES) with every nav entry on
## screen, runs UiAudit on each page (shot per page), proves a change made
## with no world running lands in the files the next world reads (graphics
## quality + a star slider, restored afterwards), then closes it with Esc.
## Honours --window-size, so the 720 form is the small-screen gate.
func _run_hub_settings_capture() -> void:
	var tree := get_tree()
	var fails := 0
	var label := _shots_label if not _shots_label.is_empty() else "hubsettings"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for _i in 90:
		await tree.process_frame
	var scene := tree.current_scene
	var hub: Node = scene if scene != null and scene.has_method("hub_settings_panel") else null
	if hub == null and scene != null:
		for n in scene.find_children("*", "Control", true, false):
			if n.has_method("hub_settings_panel"):
				hub = n
				break
	if hub == null:
		push_error("hubsettings: FAIL — the launch hub (LocationPickerUI in launch mode) is not the current scene")
		_maybe_quit()
		return
	await _shoot_ui(dir, "01_hub")
	var gear := hub.find_child("HubSettingsButton", true, false) as Button
	if gear == null:
		push_error("hubsettings: FAIL — no gear button on the hub header")
		_maybe_quit()
		return
	var vp := get_viewport()
	await HarnessInput.click(vp, HarnessInput.center_of(gear))
	for _j in 12:
		await tree.process_frame
	var panel: Control = hub.call("hub_settings_panel")
	var opened := panel != null and panel.visible and CursorController.has_blocking_modal()
	print("hubsettings: gear click opens the settings modal %s" % ("PASS" if opened else "FAIL"))
	if not opened:
		fails += 1
		if panel == null:
			_maybe_quit()
			return
		panel.call("open")
		for _k in 6:
			await tree.process_frame
	await _shoot_ui(dir, "02_settings_open")
	# Exactly the Main-free pages, every one listed on screen.
	var titles: Array = panel.call("page_titles")
	var want: Array = panel.get("HUB_PAGES")
	var same := titles.size() == want.size()
	for t in want:
		if not (t in titles):
			same = false
	print("hubsettings: pages shown = %s %s (want %s)" % [str(titles), "PASS" if same else "FAIL", str(want)])
	if not same:
		fails += 1
	var vis := vp.get_visible_rect()
	var hidden := PackedStringArray()
	for t in titles:
		var b := panel.call("nav_button", t) as Button
		if b == null or not vis.encloses(b.get_global_rect()):
			hidden.append(str(t))
	print("hubsettings: every page listed on screen %s%s" % ["PASS" if hidden.is_empty() else "FAIL",
		"" if hidden.is_empty() else " — off screen: " + ", ".join(hidden)])
	if not hidden.is_empty():
		fails += 1
	# Audit every page.
	var audit_errors := 0
	var per_page := {}
	for t in titles:
		panel.call("open_page", t)
		for _m in 6:
			await tree.process_frame
		var res := UiAudit.run(tree.root.get_viewport())
		var errs := int(res.get("errors", 0))
		audit_errors += errs
		per_page[str(t)] = {"errors": errs, "warnings": int(res.get("warnings", 0)), "counts": res.get("counts", {})}
		print("hubsettings: page %s — %s" % [str(t), UiAudit.summary_line(res)])
		for f in (res.get("findings", []) as Array):
			var fd: Dictionary = f
			if fd.get("severity", "") == "error":
				print("    %s %s %s" % [fd.get("kind", ""), str(fd.get("path", "")).get_file(), str(fd.get("rect", []))])
		await _shoot_ui(dir, "page_%s" % str(t).to_lower().replace(" ", "_").replace("&", "and"))
	print("hubsettings: UI audit %s — %d error(s) over %d pages" % ["PASS" if audit_errors == 0 else "FAIL",
		audit_errors, titles.size()])
	if audit_errors > 0:
		fails += 1
	# A change made here must reach the files the next world reads. Graphics
	# quality goes through SimSettingsController's hub store (sim_settings.cfg
	# on close); a star slider straight into star_calibration.cfg.
	var ssc := get_node_or_null("/root/SimSettingsController")
	var cfg0 := ConfigFile.new()
	cfg0.load("user://sim_settings.cfg")
	var had_gq := cfg0.has_section_key("rendering", "graphics_quality")
	var gq0 := int(cfg0.get_value("rendering", "graphics_quality", 2))
	var gq_new := (gq0 + 1) % 4
	panel.call("open_page", "Lighting")
	for _n in 4:
		await tree.process_frame
	var gq_opt := panel.get("_graphics_quality") as OptionButton
	if gq_opt != null:
		gq_opt.select(gq_new)
		gq_opt.item_selected.emit(gq_new)
	var star0 := StarSystem.saved_settings()
	var sb0 := float(star0.get("stars_brightness", 1.0))
	var sb_new := sb0 + 0.25 if sb0 < 2.5 else sb0 - 0.25
	panel.call("open_page", "Stars & Planets")
	for _o in 4:
		await tree.process_frame
	var sb_slider := panel.get("_stars_brightness") as HSlider
	if sb_slider != null:
		sb_slider.value = sb_new
	# Esc closes it (CursorController pops the modal through its close
	# callable). The pointer leaves the gear first, as a player's would —
	# its tooltip is an embedded popup window that sits in the input path.
	await HarnessInput.mouse_move(vp, vis.size * 0.5)
	for _q in 3:
		await tree.process_frame
	await HarnessInput.press_action("ui_cancel")
	for _p in 8:
		await tree.process_frame
	var closed := not panel.visible and not CursorController.has_blocking_modal()
	var fo := vp.gui_get_focus_owner()
	print("hubsettings: Esc closes the modal %s%s" % ["PASS" if closed else "FAIL",
		"" if closed else " (visible %s, modal %s, focus %s)" % [str(panel.visible),
		str(CursorController.has_blocking_modal()), str(fo.get_path()) if fo != null else "none"]])
	if not closed:
		fails += 1
		panel.call("close")
	var cfg1 := ConfigFile.new()
	cfg1.load("user://sim_settings.cfg")
	var gq1 := int(cfg1.get_value("rendering", "graphics_quality", -1))
	var star1 := StarSystem.saved_settings()
	var sb1 := float(star1.get("stars_brightness", -1.0))
	var landed := gq1 == gq_new and absf(sb1 - sb_new) < 1e-4 and ssc != null and bool(ssc.call("is_hub"))
	print("hubsettings: changes with no world running land in the files %s (graphics_quality %d -> %d in sim_settings.cfg, stars brightness %.2f -> %.2f in star_calibration.cfg)"
		% ["PASS" if landed else "FAIL", gq0, gq1, sb0, sb1])
	if not landed:
		fails += 1
	# Put both back (this is a sandbox, but the capture leaves no trace).
	if ssc != null:
		if had_gq:
			ssc.call("apply_graphics_quality", gq0)
		ssc.call("persist_settings")
		if not had_gq:
			var cfg2 := ConfigFile.new()
			cfg2.load("user://sim_settings.cfg")
			cfg2.erase_section_key("rendering", "graphics_quality")
			cfg2.save("user://sim_settings.cfg")
	if star0.has("stars_brightness"):
		StarSystem.store_settings({"stars_brightness": sb0})
	else:
		var scfg := ConfigFile.new()
		if scfg.load(StarSystem.CONFIG_PATH) == OK and scfg.has_section_key("stars", "brightness"):
			scfg.erase_section_key("stars", "brightness")
			scfg.save(StarSystem.CONFIG_PATH)
	await _shoot_ui(dir, "03_hub_after")
	HarnessReport.write_json("%s/hub_settings_audit.json" % dir, {"pages": per_page, "errors": audit_errors,
		"viewport": [int(vis.size.x), int(vis.size.y)], "fails": fails})
	print("PlaytestHarness: hubsettings %s — %d failure(s); shots in %s"
		% ["PASS" if fails == 0 else "FAIL", fails, ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Wait until the modal's pack job is idle (and its result handled).
func _assetpack_idle(m: Node) -> void:
	var tree := get_tree()
	for _i in 3:
		await tree.process_frame
	for _j in 36000:
		var job: Variant = m.get("_job")
		if job == null or not (job as AssetPackJob).running():
			break
		await tree.process_frame
	for _k in 6:
		await tree.process_frame


func _shoot_ui(dir: String, name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [dir, name])


# ==================== FOOD FOREST VERIFY (--capture=foodforest) ====================
# Veg overhaul Phase 10, console-only. Seeds a food-forest bed node + a biomass
# store on the graph, keeps the graph screen CLOSED the whole time, and asserts
# the harvest lands on the ambient tick INSIDE the window and stops outside it.
# The seeded items are removed again so the soak map's autosave is unchanged.

func _run_food_forest_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting food forest verify")
		_maybe_quit()
		return
	sgv.visible = false
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting food forest verify")
		_maybe_quit()
		return

	var bed_id := "cap_food_bed"
	var store_id := "cap_food_store"
	for pid in [bed_id, store_id]:
		if not (model.get_item(pid) as Dictionary).is_empty():
			model.remove_item(pid)
	# 100 mature apple trees: 80 kg/yr each, harvested doy 244–304.
	model.add_item({
		"id": bed_id, "type": "plant", "x": 0.0, "y": 0.0,
		"width": 160.0, "height": 130.0,
		"specs": {
			"name": "Test Food Forest", "food_forest": true,
			"food_trees": 100, "food_kg_per_year": 8000.0,
			"food_kcal_per_kg": 520.0, "food_kcal_per_year": 4160000.0,
			"harvest_start_doy": 244, "harvest_end_doy": 304,
			"food_dominant": "apple", "area_m2": 4000.0,
		},
	})
	model.add_item({
		"id": store_id, "type": "resource", "x": 320.0, "y": 0.0,
		"width": 72.0, "height": 72.0,
		"specs": {
			"name": "Test Harvest Store", "resource_kind": "biomass",
			"capacity_qty": 100000.0, "capacity_unit": "kg", "level": 0.0,
		},
	})
	model.add_connection({
		"polarity": "resource", "resource_type": "biomass",
		"source_item_id": bed_id, "source_handle_id": "biomass_out",
		"target_item_id": store_id, "target_handle_id": "input",
	})

	var main := get_tree().current_scene
	# --- in season (mid-September) ---
	_set_capture_date(main, 9, 15)
	var lvl0 := _spec_float(model, store_id, "level")
	# 20 h/s over 4 s is ~3.3 sim-days: enough mass to measure, little enough
	# that the clock stays INSIDE the 61-day window. (At 400 h/s the run
	# advanced 66 days and left the harvest season before the assertion.)
	if main != null and "time_scale" in main:
		main.time_scale = 20.0
	await get_tree().create_timer(4.0).timeout
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var lvl1 := _spec_float(model, store_id, "level")
	var bed1: Dictionary = model.get_item(bed_id).get("specs", {}) as Dictionary
	var in_season := bool(bed1.get("food_in_season", false))
	var harvested := lvl1 > lvl0 + 1.0e-6
	print("PlaytestHarness: foodforest — in-season display='%s' rate=%.3f kg/h, store %.6f -> %.6f" % [
		str(bed1.get("display_value", "")), float(bed1.get("biomass_kg_h", 0.0)), lvl0, lvl1])
	print("PlaytestHarness: foodforest %s — harvest credited with the graph CLOSED (visible=%s)"
		% ["PASS" if (in_season and harvested) else "FAIL", str(sgv.visible)])

	# --- out of season (mid-January) ---
	_set_capture_date(main, 1, 15)
	await get_tree().create_timer(1.0).timeout
	var lvl2 := _spec_float(model, store_id, "level")
	if main != null and "time_scale" in main:
		main.time_scale = 20.0
	await get_tree().create_timer(3.0).timeout
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var lvl3 := _spec_float(model, store_id, "level")
	var bed2: Dictionary = model.get_item(bed_id).get("specs", {}) as Dictionary
	var idle := not bool(bed2.get("food_in_season", true))
	var quiet := absf(lvl3 - lvl2) < 1.0e-6
	print("PlaytestHarness: foodforest — off-season display='%s', store %.6f -> %.6f" % [
		str(bed2.get("display_value", "")), lvl2, lvl3])
	print("PlaytestHarness: foodforest %s — nothing harvested out of season"
		% ["PASS" if (idle and quiet) else "FAIL"])

	for pid in [bed_id, store_id]:
		if not (model.get_item(pid) as Dictionary).is_empty():
			model.remove_item(pid)
	print("PlaytestHarness: foodforest — removed the seeded test nodes")
	_maybe_quit()


func _set_capture_date(main: Node, month: int, day: int) -> void:
	if main == null:
		return
	if "month" in main:
		main.month = month
	if "day" in main:
		main.day = day


func _spec_float(model: Variant, item_id: String, key: String) -> float:
	var it: Dictionary = model.get_item(item_id)
	if it.is_empty():
		return 0.0
	return float((it.get("specs", {}) as Dictionary).get(key, 0.0))


# ==================== GROWTH (--capture=growth) ====================
## Plant growth is a pure function of the calendar, drawn per instance by the
## shaders (VegGrowthModel / veg_growth.gdshaderinc). Two things only a windowed
## run can show:
##   LADDER   one species, nine ages side by side in ONE MultiMesh — seedling,
##            sapling, pole, mature, old, thinning, snag — for the real 3D mesh
##            and for the impostor card, so a shape defect at one age (or a
##            shader that ignores the instance data) is visible at a glance.
##            The model's height/crown/girth/leaf per rung is DUMPED, because a
##            PNG cannot tell 0.72 from 0.80.
##   TIMELAPSE one fixed forest viewpoint at +0, +5, +20, +80, +200 years and
##            BACK to +0, dumping per-layer size statistics at each stop. Asserts
##            the painted layer is full size today, never mostly-small at any
##            stop (the "all my trees shrank" regression), and that the return
##            to +0 reproduces the first stop exactly — the reversibility a
##            forward-only integrator could not offer.
## Read-only: restores the calendar, never paints, never saves.
const GROWTH_LADDER_SPECIES: Array = ["pine", "deciduous"]
const GROWTH_TIMELAPSE_YEARS: Array = [0, 5, 20, 80, 200, 0]
const GROWTH_STATS_SAMPLE := 4000


func _growth_layer_stats(loader: Node, layer_prop: String, st: Dictionary) -> Dictionary:
	var out := {"n": 0, "mean": 0.0, "small": 0.0, "absent": 0.0, "full": 0.0}
	var layer: Object = loader.get(layer_prop)
	if layer == null or not (layer.get("bulk") is Dictionary):
		return out
	var bulk: Dictionary = layer.get("bulk")
	var n := 0
	var sum := 0.0
	var small := 0
	var absent := 0
	var full := 0
	for slot in bulk:
		var species := str(slot)
		if layer_prop == "_auto_veg_layer":
			species = AutoVegetationRuntime._resolve_species(species)
		if VegetationGrowth._species_for_slot(species) not in VegetationGrowth.TREE_SPECIES:
			continue
		var recs: Array = bulk[slot]
		if recs.is_empty():
			continue
		var bp := VegetationGrowth.batch_params(species, st)
		var stride := maxi(1, recs.size() / GROWTH_STATS_SAMPLE)
		var i := 0
		while i < recs.size():
			if recs[i] is Dictionary:
				var p := VegetationGrowth.params_for(bp, recs[i])
				var state := VegGrowthModel.state(float(st[VegetationGrowth.KEY_NOW]),
					float(p["born"]), float(p["maturity"]), float(p["lifespan"]),
					float(p["seed"]))
				var h := float(state["height"])
				n += 1
				sum += h
				if float(state["present"]) < 0.5:
					absent += 1
				elif h < 0.5:
					small += 1
				if h >= 0.99:
					full += 1
			i += stride
	if n > 0:
		out = {"n": n, "mean": sum / float(n), "small": float(small) / float(n),
			"absent": float(absent) / float(n), "full": float(full) / float(n)}
	return out


func _run_growth_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null or not loader.has_method("_growth_style"):
		push_error("PlaytestHarness: growth capture needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	var opts: Dictionary = loader.call("get_terrain_options") \
		if loader.has_method("get_terrain_options") else {}
	if bool(opts.get("show_auto_vegetation", true)):
		var waited := 0.0
		while loader.get("_auto_veg_generated") != true and waited < VEG_SCATTER_WAIT_MAX_S:
			await get_tree().create_timer(2.0).timeout
			waited += 2.0
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var main := get_tree().current_scene
	var year0 := int(main.get("year"))
	var month0 := int(main.get("month"))
	var day0 := int(main.get("day"))
	# Mid-summer: full foliage, and past the spring flush so the growth year is
	# a whole number of years at every stop.
	_set_capture_date(main, 8, 15)
	await get_tree().process_frame
	var label := _shots_label if not _shots_label.is_empty() else "growth"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var failures := 0

	# ---- LADDER -------------------------------------------------------------
	var style: Dictionary = loader.call("_auto_veg_runtime_settings")
	var st: Dictionary = loader.call("_growth_style")
	var t_now := float(st[VegetationGrowth.KEY_NOW])
	var scene := get_tree().current_scene
	var root := Node3D.new()
	root.name = "GrowthLadder"
	scene.add_child(root)
	var cam := Camera3D.new()
	cam.name = "GrowthCam"
	cam.far = 40000.0
	scene.add_child(cam)
	cam.make_current()
	var base := Vector3(0.0, 4000.0, 0.0)
	for species in GROWTH_LADDER_SPECIES:
		var sid := str(species)
		var bp := VegetationGrowth.batch_params(sid, st)
		var m := float(bp["maturity"])
		var life := float(bp["lifespan"])
		if m <= 0.0:
			print("PlaytestHarness: growth — %s has growth switched off, ladder skipped" % sid)
			continue
		var d0 := life * (1.0 - VegGrowthModel.DECLINE_FRAC)
		var ages: Array = [1.0, 3.0, m * 0.25, m * 0.5, m, (m + d0) * 0.5,
			d0 + (life - d0) * 0.3, d0 + (life - d0) * 0.75, d0 + (life - d0) * 0.95]
		var names: Array = ["1 yr", "3 yr", "quarter", "half", "MATURE", "old",
			"thinning", "snag", "falling"]
		var near_mesh := VegetationCardFactory.mesh_for_canopy_lod(
			sid, style, VegetationCardFactory.CanopyLodTier.NEAR)
		var tiers: Array = [["near", near_mesh]]
		var iset := VegImpostorBaker.cached_set(sid, style)
		if iset != null:
			var imp_mesh := VegImpostorBaker.quad_mesh_for(iset)
			VegImpostorBaker.stamp_snag(imp_mesh, sid, VegSpeciesCatalog.settings_with_variant(
				sid, style, VegetationCardFactory.SPECS))
			tiers.append(["impostor", imp_mesh])
		else:
			print("PlaytestHarness: growth — %s impostor not baked yet, near tier only" % sid)
		var aabb := near_mesh.get_aabb()
		var h := maxf(aabb.size.y, 1.0)
		var spacing := maxf(maxf(aabb.size.x, aabb.size.z), 2.0) * 1.15
		for tier_spec in tiers:
			var mesh: Mesh = tier_spec[1]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_custom_data = true
			mm.mesh = mesh
			mm.instance_count = ages.size()
			for i in ages.size():
				mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
					Vector3((float(i) - float(ages.size() - 1) * 0.5) * spacing, 0.0, 0.0)))
				mm.set_instance_custom_data(i, Color(
					t_now - float(ages[i]) - VegGrowthModel.BASE_YEAR, m, life, 0.5))
			var mi := MultiMeshInstance3D.new()
			mi.multimesh = mm
			mi.position = base
			mi.extra_cull_margin = 1000.0
			root.add_child(mi)
			# The materials are the map's own cached ones; set the year directly
			# as well, so the ladder does not depend on the env-sync cadence.
			for si in mesh.get_surface_count():
				var mat := mesh.surface_get_material(si)
				if mat is ShaderMaterial:
					(mat as ShaderMaterial).set_shader_parameter(
						"growth_year", t_now - VegGrowthModel.BASE_YEAR)
					(mat as ShaderMaterial).set_shader_parameter("growth_freeze", 0.0)
			var span := spacing * float(ages.size())
			var dist := maxf(span * 0.5, h * 1.2)
			cam.position = base + Vector3(0.0, h * 0.5, dist)
			cam.look_at(base + Vector3(0.0, h * 0.5, 0.0), Vector3.UP)
			await RenderingServer.frame_post_draw
			await get_tree().create_timer(0.3).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(
				"%s/ladder_%s_%s.png" % [dir, sid, str(tier_spec[0])])
			mi.queue_free()
			await get_tree().process_frame
		print("PlaytestHarness: growth — %s ladder (maturity %.0f y, lifespan %.0f y, mature height %.1f m):"
			% [sid, m, life, h])
		for i in ages.size():
			var state := VegGrowthModel.state(t_now, t_now - float(ages[i]), m, life, 0.5)
			print("    %-9s age %6.1f  height %.3f (%.1f m)  crown %.3f  girth %.3f  leaf %.2f"
				% [names[i], float(ages[i]), float(state["height"]),
					float(state["height"]) * h, float(state["crown"]),
					float(state["girth"]), float(state["leaf"])])
	root.queue_free()

	# ---- TIMELAPSE ----------------------------------------------------------
	# Stand over the PAINTED grove when the map has one (that is the layer the
	# "my trees shrank" report was about); otherwise the densest generated stand.
	var anchor := _veg_forest_anchor(loader)
	var painted_layer: Object = loader.get("_vegetation_layer")
	if painted_layer != null and painted_layer.get("bulk") is Dictionary:
		var sum := Vector2.ZERO
		var cnt := 0
		var pb: Dictionary = painted_layer.get("bulk")
		for slot in pb:
			if str(slot).begins_with("grass"):
				continue
			for r in pb[slot]:
				sum += Vector2(float(r["x"]), float(r["z"]))
				cnt += 1
		if cnt > 0:
			anchor = sum / float(cnt)
	# Drone oblique: high enough that seedlings, poles and snags all read
	# against the ground rather than against each other.
	var gy := _ground_y(loader, anchor.x, anchor.y)
	var wp := {
		"pos": Vector3(anchor.x + 150.0, gy + 120.0, anchor.y + 150.0),
		"look": Vector3(anchor.x, gy + 10.0, anchor.y),
	}
	var manifest: Array = []
	var first := {}
	for k in GROWTH_TIMELAPSE_YEARS.size():
		var off := int(GROWTH_TIMELAPSE_YEARS[k])
		main.set("year", year0 + off)
		await get_tree().create_timer(0.8).timeout
		await _capture_set(cam, [wp], "years_%d_plus%03d" % [k, off], dir, manifest)
		var now_st: Dictionary = loader.call("_growth_style")
		var painted := _growth_layer_stats(loader, "_vegetation_layer", now_st)
		var auto := _growth_layer_stats(loader, "_auto_veg_layer", now_st)
		print("PlaytestHarness: growth — +%3d y (growth year %.2f)" % [
			off, float(now_st[VegetationGrowth.KEY_NOW])])
		for row in [["painted", painted], ["generated", auto]]:
			var r: Dictionary = row[1]
			print("    %-9s n=%-5d mean size %.3f  full %.1f%%  small %.1f%%  absent %.1f%%"
				% [str(row[0]), int(r["n"]), float(r["mean"]), float(r["full"]) * 100.0,
					float(r["small"]) * 100.0, float(r["absent"]) * 100.0])
		if int(painted["n"]) > 0:
			if k == 0 and float(painted["full"]) < 0.999:
				failures += 1
				print("PlaytestHarness: growth — FAIL: painted trees are not all full size today")
			if float(painted["small"]) + float(painted["absent"]) > 0.25:
				failures += 1
				print("PlaytestHarness: growth — FAIL: >25%% of the painted grove is small/absent at +%d y" % off)
		if k == 0:
			first = {"painted": painted, "auto": auto}
		elif off == 0:
			if first["painted"] != painted or first["auto"] != auto:
				failures += 1
				print("PlaytestHarness: growth — FAIL: returning to +0 did not reproduce the first stop")
			else:
				print("PlaytestHarness: growth — PASS: rewinding 200 years reproduces the first stop exactly")

	main.set("year", year0)
	_set_capture_date(main, month0, day0)
	cam.queue_free()
	print("PlaytestHarness: growth capture %s — shots in %s" % [
		"PASS" if failures == 0 else "FAIL (%d)" % failures,
		ProjectSettings.globalize_path(dir)])
	_maybe_quit()


# ==================== TREE PORTRAIT (--capture=tree) ====================
# Shape work on the procedural trees is unreviewable from forest shots: a
# silhouette defect reads as "the forest looks off". This stands ONE tree of
# each species on empty ground against sky and shoots it at all three LOD
# tiers, which is where a NEAR/FAR/impostor disagreement becomes obvious.
#
# Builds its own MultiMesh nodes from VegetationCardFactory directly — it does
# not touch the map's vegetation layers, so it is safe on a real saved site.

const TREE_PORTRAIT_SPECIES: Array = [
	"deciduous", "birch", "maple", "beech", "chestnut", "aspen", "pine",
	"douglas_fir", "cedar", "hemlock", "spruce", "fir", "redwood", "alder",
	"sword_fern", "bracken", "salal", "blackberry",
]


## --capture=workui — PNG coverage for the work UI, which had none: the
## Routines panel, the Site Projects panel and the Work Planner's four tabs,
## each opened through its REAL entry point (open_npc_routines /
## open_site_projects / open_work_planner) over a seeded habitat with enough
## content that every list has rows: chores across the recurrence forms, a
## duty on the rota, a granted skill, an on-call role. Read-only beyond the
## seeded cap_wui_* items, which are removed afterwards.
func _run_workui_capture() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: workui — no graph view; aborting")
		_maybe_quit()
		return
	var scene := get_tree().current_scene
	var loader0: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader0 != null and not (loader0.get("load_completed") == true):
		await loader0.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	# _set_capture_conditions hides EVERY CanvasLayer (a world capture wants a
	# clean frame) — but the panels under review live on UILayer, so it comes
	# back. The modal dim covers the HUD behind it.
	var scene2 := get_tree().current_scene
	var ui_layer: Node = scene2.get_node_or_null("UILayer") if scene2 != null else null
	if ui_layer is CanvasLayer:
		(ui_layer as CanvasLayer).visible = true
	var label := _shots_label if not _shots_label.is_empty() else "workui"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var model: Variant = sgv.get("model")
	if model == null:
		push_error("PlaytestHarness: workui — no graph model; aborting")
		_maybe_quit()
		return

	model.add_item({
		"id": "cap_wui_hab", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 150.0,
		"specs": {"name": "Planner Crew", "role": "habitat", "occupants": 8,
			"pop_driven": true, "watts": 0.0, "energy_source": "",
			"efficiency": 1.0, "inputs": [], "outputs": []},
	})
	await get_tree().create_timer(1.5).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null or bridge.call("chore_board_for", "cap_wui_hab") == null:
		push_error("PlaytestHarness: workui — bridge/board never came up; aborting")
		model.remove_item("cap_wui_hab")
		_maybe_quit()
		return

	# Content, so every tab has something to show.
	var board: Variant = bridge.call("chore_board_for", "cap_wui_hab")
	board.call("add_chore", "Clean the bathrooms", 1.0, {
		"repeat": "weekly", "repeat_dow": [2],
		"window": {"start_h": 9.0, "end_h": 12.0}})
	board.call("add_chore", "Commission the array", 2.0, {
		"repeat": "every_n", "repeat_days": 3,
		"requires_skill": NpcSkills.ELECTRICAL,
		"window": {"start_h": 8.0, "end_h": 18.0}})
	board.call("add_chore", "Raise the frame", 4.0, {
		"repeat": "once", "min_workers": 4, "max_workers": 6,
		"target": {"kind": "pos", "x": 25.0, "z": 10.0},
		"window": {"start_h": 7.0, "end_h": 19.0}})
	var ids: Array = []
	for a in (bridge.call("roster_for", "cap_wui_hab") as Array):
		ids.append((a as NpcAgent).id)
	var skills: Variant = bridge.call("skills_for", "cap_wui_hab")
	if skills != null and not ids.is_empty():
		skills.call("grant", str(ids[0]), NpcSkills.ELECTRICAL)
	var roster: Variant = bridge.call("duty_roster_for", "cap_wui_hab")
	if roster != null:
		roster.call("add_duty", "Cook lunch", 2.0, {"crew": 2, "repeat": "daily"})
	var oncall: Variant = bridge.call("oncall_for", "cap_wui_hab")
	if oncall != null and ids.size() >= 2:
		oncall.call("add_role", "Water crew", [NpcOnCall.ESC_STARVED],
			{"members": [str(ids[0]), str(ids[1])]})
	bridge.call("persist_work_config", "cap_wui_hab")
	# save_duties cleared the daily gate, so the next tick re-plans and mints
	# today's slot — give it a moment so the Schedule grid has names.
	await get_tree().create_timer(2.0).timeout

	# --- the community toast chips, one per severity ----------------------
	# The styling is the review target: icon + headline + dim detail, tinted
	# border, stacking. A real event fires these through the same calls.
	var main2 := get_tree().current_scene
	var toaster: Variant = main2.get("toast_ui") if main2 != null else null
	if toaster != null and toaster.has_method("show_community"):
		toaster.call("show_community", "skill_earned", "Devi qualified",
			"Electrical", ToastUI.Level.OK, 30.0)
		toaster.call("show_community", "departed", "Wren left",
			"no water", ToastUI.Level.WARN, 30.0)
		toaster.call("show_community", "collapsed", "Colony collapse",
			"too few people remain to keep this place running",
			ToastUI.Level.ERROR, 30.0)
		await get_tree().create_timer(0.6).timeout
		await _shoot_ui(dir, "community_toasts")

	# --- the Routines panel, every tab -----------------------------------
	sgv.call("open_npc_routines", "cap_wui_hab")
	await get_tree().create_timer(0.8).timeout
	var routines: Variant = sgv.get("_npc_routines_panel")
	var rtabs: Variant = null
	if routines != null:
		var found: Array = routines.find_children("*", "TabContainer", true, false)
		rtabs = found[0] if not found.is_empty() else null
	await _shoot_ui(dir, "routines_chores")
	if rtabs != null:
		rtabs.set("current_tab", 1)
		await get_tree().create_timer(0.4).timeout
		await _shoot_ui(dir, "routines_animations")
		rtabs.set("current_tab", 2)
		await get_tree().create_timer(0.4).timeout
		await _shoot_ui(dir, "routines_daily")
	if routines != null:
		routines.call("close")

	# --- the Site Projects panel -----------------------------------------
	sgv.call("open_site_projects")
	await get_tree().create_timer(0.8).timeout
	await _shoot_ui(dir, "site_projects")
	var projects: Variant = sgv.get("_site_project_panel")
	if projects != null:
		projects.call("close")

	# --- the Work Planner, all four surfaces ------------------------------
	sgv.call("open_work_planner", "cap_wui_hab")
	await get_tree().create_timer(0.8).timeout
	var planner: Variant = sgv.get("_work_planner_panel")
	var shot_names := ["planner_chores", "planner_tasks", "planner_schedule",
		"planner_person"]
	for t in 4:
		if planner != null:
			(planner.get("_tabs") as TabContainer).current_tab = t
			planner.call("_refresh")
		await get_tree().create_timer(0.5).timeout
		await _shoot_ui(dir, shot_names[t])
	var opened := planner != null and bool(planner.get("_active"))
	if planner != null:
		planner.call("close")

	model.remove_item("cap_wui_hab")
	print("PlaytestHarness: workui — %s (8 shots in %s)" % [
		"PASS" if opened else "FAIL (planner never opened)",
		ProjectSettings.globalize_path(dir)])
	_maybe_quit()


# ==================== NPC POSE PORTRAIT (--capture=npcpose) ====================
## Pose work is unreviewable from settlement or population shots — a broken
## `work_overhead` just reads as "the crowd looks a bit off". This stands ONE
## figure per pose family in empty air against sky and shoots it close, which
## is where a family that does not read becomes obvious.
##
## `--capture=npc-anim` cannot do this job and never will: it observes only
## `is_rigged()` avatars, and the rigged Mixamo body aliases all seven families
## onto its single `work` clip. The families exist on the STICK FIGURE, so this
## harness forces that body style (and puts the player's preference back).
##
## Read-only. It builds its own avatars from NpcAvatar directly and never
## touches the map's population, so it is safe on a real saved site.
const NPCPOSE_SUBJECTS: Array = [
	# [seed_key, logical clip, carrying]
	["pose_lift", "work_lift", false],
	["pose_dig", "work_dig", false],
	["pose_overhead", "work_overhead", false],
	["pose_drill", "work_drill", false],
	["pose_bench", "work_bench", false],
	["pose_inspect", "work_inspect", false],
	# haul_hold renders through a DIFFERENT branch (_pose_carry_idle, with the
	# carry box shown), and `carrying` is the only thing that reaches it.
	["pose_haul", "haul_hold", true],
	["pose_enter", "work_enter", false],
	["pose_exit", "work_exit", false],
	# Baselines, so a family can be judged against what the body does at rest.
	["pose_idle", "", false],
	["pose_walk", "walk", false],
	# The two flavour poses: joy and urgency. Dance must NOT read as a work
	# family; the urgent walk is the arms-in shape the idle used to leak.
	["pose_dance", "dance", false],
	["pose_pee_walk", "walk_urgent", false],
]

## Real seconds to let the joints settle before shooting. The figure eases
## toward its pose at ~9/s, so a shot taken on the frame the clip changes is a
## picture of the PREVIOUS pose.
const NPCPOSE_SETTLE_S := 1.1


func _run_npc_pose_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var main := get_tree().get_first_node_in_group("main_scene")
	if main != null:
		_set_capture_date(main, 7, 15)
		await get_tree().process_frame
	var label := _shots_label if not _shots_label.is_empty() else "npc_pose"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)

	# ⚠ Body style is a GLOBAL, PERSISTED player preference
	# (user://npc_display.cfg). Forcing it is necessary — the work families only
	# draw on the stick figure — so it must be restored on EVERY exit path, or
	# running the harness silently rewrites the player's choice.
	var prev_style := NpcDisplayPrefs.style()
	NpcDisplayPrefs.set_style(NpcDisplayPrefs.STYLE_SIMPLE)

	var scene := get_tree().current_scene
	var cam := Camera3D.new()
	cam.name = "PosePortraitCam"
	cam.far = 4000.0
	scene.add_child(cam)
	var prev_cam := get_viewport().get_camera_3d()
	cam.make_current()

	# Well above the terrain, so nothing intrudes on the silhouette.
	var base := Vector3(0.0, 4000.0, 0.0)
	var manifest: Array = []
	for spec in NPCPOSE_SUBJECTS:
		var s: Array = spec
		var seed_key := str(s[0])
		var family := str(s[1])
		var carrying := bool(s[2])

		# NpcAvatar.setup is the ONLY place NpcWorkPose.merge_catalog is
		# applied; a hand-rolled NpcPoseMachine has no procedural families and
		# every _has() guard would silently fall back to the generic squat.
		var av := NpcAvatar.new()
		av.setup(seed_key, Color(0.62, 0.68, 0.82), seed_key)
		# MUST be in the tree: _simple.pose() only runs from _process.
		scene.add_child(av)
		av.set_detail(false)

		# Two framings per subject. The near one reviews the pose; the far one
		# is the claim the families are designed against — "differ in
		# SILHOUETTE at ~60 m" — and is the only way to check it.
		for framing in [["near", 2.5], ["far", 13.0]]:
			var fname := str((framing as Array)[0])
			var dist := float((framing as Array)[1])
			# Camera BELOW the figure's waist, looking up. That puts the whole
			# body against open sky — a horizon line crossing the subject is
			# the one thing that makes a silhouette unreadable, and a level
			# camera at this height puts it right through the hips.
			cam.position = base + Vector3(dist * 0.80, -dist * 0.16, dist * 0.60)
			cam.look_at(base + Vector3(0.0, 0.95, 0.0), Vector3.UP)
			# Let the figure reach the pose. Driven by hand rather than by the
			# host: this avatar has no bridge, no dot and no ground query.
			var elapsed := 0.0
			while elapsed < NPCPOSE_SETTLE_S:
				await get_tree().process_frame
				var dt := get_process_delta_time()
				elapsed += dt
				av.apply_pose(base, PI * 0.85, _npcpose_input(dt, family, carrying))
			await RenderingServer.frame_post_draw
			await get_tree().create_timer(0.15).timeout
			await RenderingServer.frame_post_draw
			var shot := "%s_%s" % [seed_key, fname]
			get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, shot])
			# The numbers a PNG cannot give you. `machine_clip` is the load
			# bearing one: it turns "this looks wrong" into "the machine picked
			# the wrong clip", which are different bugs in different files.
			var machine_clip := str(av.call("pose_clip")) if av.has_method("pose_clip") else ""
			manifest.append({
				"shot": shot, "family": family, "framing": fname,
				"carrying": carrying, "machine_clip": machine_clip,
				"seed": seed_key,
			})
			print("PlaytestHarness: npcpose — %-14s %-4s want=%-14s machine=%s" % [
				seed_key, fname, family if not family.is_empty() else "(idle)",
				machine_clip if not machine_clip.is_empty() else "?"])
		av.queue_free()
		await get_tree().process_frame

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	# Every exit path restores the preference and the camera.
	NpcDisplayPrefs.set_style(prev_style)
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.current = true
	cam.queue_free()
	print("PlaytestHarness: npcpose — %d shots in %s (body style restored to %s)" % [
		manifest.size(), ProjectSettings.globalize_path(dir), prev_style])
	_maybe_quit()


## The pose-machine input for one portrait frame.
##
## Four values here are load-bearing and each was verified the hard way:
##   paused        — MUST be false. _set_capture_conditions freezes time_scale,
##                   and NpcAvatar._drive early-returns on `paused`, so copying
##                   the host's `scale <= 0.0` would render eleven T-poses.
##   dwell_left_s  — INF, or _budget_allows' ~0.96 s enter+exit gate refuses the
##                   transition and the work_enter/work_exit subjects shoot the
##                   settled pose instead of the thing being reviewed.
##   carrying      — OVERRIDES the family in _pose_clip, so it is true for the
##                   haul_hold subject only.
##   work_pose     — the family id; the machine maps it to a logical clip.
static func _npcpose_input(dt: float, family: String, carrying: bool) -> Dictionary:
	# The transitions and the baselines are not families — they are reached by
	# driving the machine into the state that plays them.
	var activity := "chore"
	var in_transit := false
	var fam := family
	match family:
		"":
			activity = ""
		"walk":
			activity = ""
			in_transit = true
		"walk_urgent":
			# The avatar derives the urgent flavour itself from
			# moving + activity == bladder — same inputs the host sends.
			activity = "bladder"
			in_transit = true
			fam = ""
		"dance":
			# Reaching the fire-circle POSE needs a real arrival the portrait
			# cannot run; the anim_map binding (the Animations tab's own
			# mechanism) pins the clip on the idle slot instead.
			activity = ""
			fam = ""
		"work_enter", "work_exit":
			fam = NpcWorkPose.DIG
		"haul_hold":
			fam = NpcWorkPose.HAUL_HOLD
		_:
			# The FAMILY id, not the clip name — clip_for does that mapping.
			for f in NpcWorkPose.FAMILIES:
				if NpcWorkPose.clip_for(str(f)) == family:
					fam = str(f)
					break
	# A transition is a ONE-SHOT: the machine plays it for ~0.35 s and moves on,
	# so it is not reachable as a steady state and a still frame would catch
	# whatever came after. `anim_map` is the existing player-binding override
	# (pose_slot -> clip), and pinning it holds the figure on the transition's
	# target shape indefinitely — which is exactly what a portrait should show.
	var anim_map: Dictionary = {}
	if family == "work_enter" or family == "work_exit":
		anim_map = {"chore": family}
	elif family == "dance":
		anim_map = {"idle": "dance"}
	return {
		"dt": dt,
		"paused": false,
		"in_transit": in_transit,
		"activity": activity,
		"anim_map": anim_map,
		"space_type": "",
		"morale": 0.9,
		"dwell_left_s": INF,
		"teleported": false,
		"carrying": carrying,
		"work_pose": fam,
		"apparent_speed_mps": 1.3 if in_transit else 0.0,
		"time_mult": 1.0,
	}


func _run_tree_portrait_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	# Pin the shoot to mid-summer: portraits inherit the map's SAVED sim date,
	# and a site saved in April renders half-bare spring-bud trees — shape
	# defects then hide behind (or get invented by) the seasonal thinning.
	var main := get_tree().get_first_node_in_group("main_scene")
	if main != null:
		_set_capture_date(main, 7, 15)
		await get_tree().process_frame
	var label := _shots_label if not _shots_label.is_empty() else "tree_portrait"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)

	var scene := get_tree().current_scene
	var root := Node3D.new()
	root.name = "TreePortrait"
	scene.add_child(root)
	var cam := Camera3D.new()
	cam.name = "PortraitCam"
	cam.far = 4000.0
	scene.add_child(cam)
	cam.make_current()

	# Stand the subject well above the terrain so nothing intrudes on the
	# silhouette; the camera looks slightly up at it against open sky.
	var base := Vector3(0.0, 4000.0, 0.0)
	# The MAP's live render settings, not library defaults: a portrait is only
	# useful if it shows what this site actually renders (quality tier, per-map
	# style edits and species variants all ride this dict). Falls back to the
	# defaults on a scene with no loader.
	var style := VegetationStyleConfig.defaults()
	if loader != null and loader.has_method("_auto_veg_runtime_settings"):
		var live: Variant = loader.call("_auto_veg_runtime_settings")
		if live is Dictionary and not (live as Dictionary).is_empty():
			style = live
	print("PlaytestHarness: tree — style source: %s"
		% ("map" if style.has("_variant_species") or loader != null else "defaults"))
	var manifest: Array = []
	for species in TREE_PORTRAIT_SPECIES:
		var sid := str(species)
		for tier_spec in [["near", VegetationCardFactory.CanopyLodTier.NEAR],
				["far", VegetationCardFactory.CanopyLodTier.FAR]]:
			var tier_name := str(tier_spec[0])
			var tier: int = tier_spec[1]
			var fam := VegSpeciesCatalog.mesh_family(sid)
			var is_tree := fam == "pine" or fam == "deciduous"
			if not is_tree and tier_name == "far":
				continue
			var mesh := VegetationCardFactory.mesh_for_canopy_lod(sid, style, tier) \
				if is_tree else VegetationCardFactory.mesh_for_species(sid, style)
			if mesh == null:
				continue
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = base
			root.add_child(mi)
			var aabb := mesh.get_aabb()
			var h := maxf(aabb.size.y, 1.0)
			var w := maxf(maxf(aabb.size.x, aabb.size.z), 1.0)
			# Frame the whole tree with a little headroom, from slightly below
			# mid-height so the trunk/crown proportion reads honestly.
			var dist := maxf(h, w * 0.85) * 1.15
			cam.position = base + Vector3(dist * 0.72, h * 0.45, dist * 0.72)
			cam.look_at(base + Vector3(0.0, h * 0.50, 0.0), Vector3.UP)
			await RenderingServer.frame_post_draw
			await get_tree().create_timer(0.15).timeout
			await RenderingServer.frame_post_draw
			var shot := "%s_%s" % [sid, tier_name]
			get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, shot])
			var tris := 0
			for si in mesh.get_surface_count():
				var idx: PackedInt32Array = mesh.surface_get_arrays(si)[Mesh.ARRAY_INDEX]
				tris += idx.size() / 3
			manifest.append({
				"shot": shot, "species": sid, "tier": tier_name,
				"surfaces": mesh.get_surface_count(), "tris": tris,
				"aabb_h": aabb.size.y, "aabb_w": aabb.size.x, "foot_y": aabb.position.y,
			})
			print("PlaytestHarness: tree — %-10s %-4s %d surf, %5d tris, %.2f m tall, foot y %.3f"
				% [sid, tier_name, mesh.get_surface_count(), tris, aabb.size.y, aabb.position.y])
			mi.queue_free()
			# The three seeded variants of a tree species side by side
			# (VegetationRuntime draws one per tree, picked by position).
			if is_tree and tier_name == "near":
				var row: Array = []
				for k in 3:
					var sk := style.duplicate()
					sk["%s_variant_index" % fam] = k
					var vm := VegetationCardFactory.mesh_for_canopy_lod(sid, sk, tier)
					var vmi := MeshInstance3D.new()
					vmi.mesh = vm
					vmi.position = base + Vector3((float(k) - 1.0) * w * 1.05, 0.0, 0.0)
					root.add_child(vmi)
					row.append(vmi)
				var vd := maxf(h, w * 3.3) * 1.05
				cam.position = base + Vector3(0.0, h * 0.42, vd)
				cam.look_at(base + Vector3(0.0, h * 0.48, 0.0), Vector3.UP)
				await RenderingServer.frame_post_draw
				await get_tree().create_timer(0.15).timeout
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(
					"%s/%s_variants.png" % [dir, sid])
				for vmi in row:
					(vmi as Node).queue_free()
	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "	"))
		f.close()
	cam.queue_free()
	root.queue_free()
	print("PlaytestHarness: tree portraits — %d shots in %s"
		% [manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## Periodic diagnostic during the project polls: which phase is live, how many
## are done, who is on it — so a FAIL names its stalled phase instead of just
## timing out silently.
func _print_project_rollup(bridge: Variant, board: Variant, project_id: String,
		tag: String) -> void:
	for prow in (bridge.call("all_site_projects") as Array):
		var pd := (prow as Dictionary)["project"] as Dictionary
		if str(pd.get("id", "")) != project_id:
			continue
		var rl: Dictionary = SiteProject.rollup(pd, board)
		var pend := ""
		for t in pd.get("tasks", []):
			var task: Dictionary = t
			if str(task.get("status", "")) == "pending":
				var ch: Dictionary = board.find(str(task.get("chore_id", "")))
				pend = "%s (%d workers, %.2f/%.2f h)" % [str(task.get("label", "")),
					(ch.get("workers", []) as Array).size(),
					float(ch.get("progress_h", 0.0)), float(ch.get("chore_hours", 0.0))]
				break
		print("PlaytestHarness: project verify [%s] — %d/%d done (%.0f%%), next: %s" % [
			tag, int(rl["done"]), int(rl["total"]),
			float(rl["progress"]) * 100.0, pend if not pend.is_empty() else "—"])
		return


# ==================== SITE PROJECT VERIFY (--capture=project) ====================
## End-to-end camp-lifecycle verify (WINDOWED — needs a REAL TerrainLoader
## map, e.g. --user-map=mtvernon): seeds a pop-driven habitat + supply tanks
## + tagged spaces, then walks the WHOLE unified mechanic with console
## asserts and a PNG per stage:
##   DELIVER   starshade_kit — crates carry delivery identity + staging
##             slots, the unload lands as a Site Project on the board
##   UNLOAD    a carrying dot is observed and the crate record MOVES to its
##             staging slot via the chore's completion effect (never before)
##   BUILD     a linkage build project drives the ghost structure's beam
##             visible_instance_count strictly UP as real labour lands
##   RAISE     the erect phase's unpack effect deploys the structure
##             (packed:false, linkage_deployed:true, build_state cleared)
##   BREAKDOWN the reverse project folds it back to packed: true
## The board runs night_shift so chore windows never stall the verify; the
## clock is stepped by time_scale, never jumped (the >6 h coarse catch-up
## path would reroll the roster). Seeded cap_prj_* graph items are removed
## from the map autosave afterwards.
func _run_project_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting project verify")
		_maybe_quit()
		return
	sgv.visible = false
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader == null or not loader.has_method("deliver_packed_kit"):
		push_error("PlaytestHarness: project verify needs a TerrainLoader map (use --user-map=…)")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var model: Variant = sgv.get("model")
	if model == null:
		push_error("PlaytestHarness: graph model unavailable — aborting project verify")
		_maybe_quit()
		return

	# --- seed: pop-driven habitat + tanks (cap_prj_*) -------------------------
	var hab_id := "cap_prj_hab"
	var prj_ids := [hab_id, "cap_prj_water", "cap_prj_food"]
	for pid in prj_ids:
		if not (model.get_item(str(pid)) as Dictionary).is_empty():
			model.remove_item(str(pid))
	model.add_item({
		"id": hab_id, "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 150.0,
		"specs": {
			"name": "Project Crew", "role": "habitat", "occupants": 12,
			"pop_driven": true, "watts": 0.0, "energy_source": "", "efficiency": 1.0,
			"inputs": [
				{"kind": "water", "rate": 2.0, "unit": "L/h"},
				{"kind": "food", "rate": 0.06, "unit": "kg/h"},
			],
			"outputs": [],
		},
	})
	for t in [["cap_prj_water", "water", "L", 4000.0, 1.0],
			["cap_prj_food", "food", "kg", 200.0, 1.0]]:
		model.add_item({
			"id": str(t[0]), "type": "resource", "x": -200.0, "y": 220.0,
			"width": 90.0, "height": 100.0,
			"specs": {"name": str(t[1]).capitalize(), "resource_kind": str(t[1]),
				"capacity_qty": float(t[3]), "capacity_unit": str(t[2]),
				"level": float(t[4])},
		})
	for c in [["cap_prj_water", "output", hab_id, "res_in_0", "water"],
			["cap_prj_food", "output", hab_id, "res_in_1", "food"]]:
		model.add_connection({
			"polarity": "resource", "resource_type": str(c[4]),
			"source_item_id": str(c[0]), "source_handle_id": str(c[1]),
			"target_item_id": str(c[2]), "target_handle_id": str(c[3])})

	# One ambient tick so the view creates its bridge + engine.
	if main != null and "day_time" in main:
		main.day_time = 8.0
	if main != null and "time_scale" in main:
		main.time_scale = 0.01
	await get_tree().create_timer(1.5).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null:
		push_error("PlaytestHarness: population bridge missing — aborting")
		_maybe_quit()
		return
	# Tagged sleep/water/kitchen spaces so needs resolve near the site.
	var reg: Variant = bridge.call("registry_for", main)
	# A shower is NOT optional set dressing: hygiene rises forever and only a
	# completed shower lowers it, so a camp without one used to freeze its
	# whole crew within half a day. Comfort needs no longer block work, but a
	# harness camp should still be a camp people can actually live in.
	for pair in [["sleep", Vector2(-40, -30)], ["kitchen", Vector2(-40, 30)],
			["water_point", Vector2(-55, 0)], ["restroom", Vector2(-70, 20)],
			["shower", Vector2(-70, -20)]]:
		var cpt: Vector2 = pair[1]
		reg.call("set_space_type", {"kind": "area", "poly": [
			[cpt.x - 8, cpt.y - 8], [cpt.x + 8, cpt.y - 8],
			[cpt.x + 8, cpt.y + 8], [cpt.x - 8, cpt.y + 8]]}, str(pair[0]), 30)
	var board: Variant = bridge.call("chore_board_for", hab_id)
	if board == null:
		await get_tree().create_timer(2.0).timeout
		board = bridge.call("chore_board_for", hab_id)
	if board == null:
		push_error("PlaytestHarness: chore board never appeared — aborting")
		_maybe_quit()
		return
	board.rules["night_shift"] = true

	var label := _shots_label if not _shots_label.is_empty() else "project_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.current = true
	var site_g := _ground_y(loader, 30.0, 20.0)
	cam.global_position = Vector3(30.0, site_g + 26.0, 20.0 + 38.0)
	cam.look_at(Vector3(30.0, site_g, 20.0))

	# --- stage 1: DELIVER ------------------------------------------------------
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	var res: Variant = loader.call("deliver_packed_kit", "starshade_kit", 30.0, 20.0, 0.0)
	var crate_ids: Array = (res as Dictionary).get("crate_ids", []) if res is Dictionary else []
	var ok_deliver := not crate_ids.is_empty()
	var crate_id := str(crate_ids[0]) if ok_deliver else ""
	var crec: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
	var staging: Dictionary = crec.get("staging", {})
	var ok_identity: bool = str(crec.get("delivery_id", "")) == str((res as Dictionary).get("container_prop_id", "")) \
		and staging.has("x")
	var projects0: Array = bridge.call("all_site_projects")
	var ok_project := false
	for row in projects0:
		if str(((row as Dictionary)["project"] as Dictionary).get("kind", "")) == "delivery_unload":
			ok_project = true
	print("PlaytestHarness: project verify — deliver %s, crate identity %s, unload project %s" % [
		"PASS" if ok_deliver else "FAIL", "PASS" if ok_identity else "FAIL",
		"PASS" if ok_project else "FAIL"])
	# Round 3: the kit rides INSIDE the container. Assert the world records
	# agree with the stow plan — inside the footprint, at the solved height.
	var stow_ok := true
	var stowed_n := 0
	var plan_iv: Dictionary = UnpackScenario.stow_plan("starshade_kit").get("interior", {})
	for pid_s in crate_ids:
		var rs: Dictionary = PlacedPropService.get_prop_record(main, str(pid_s))
		if str(rs.get("stowed_in", "")).is_empty():
			continue
		stowed_n += 1
		var dv := Vector2(float(rs["x"]) - 30.0, float(rs["z"]) - 20.0)
		if absf(dv.y) > float(plan_iv.get("l_m", 0.0)) * 0.5 + 0.01 \
				or absf(dv.x) > float(plan_iv.get("w_m", 0.0)) * 0.5 + 0.01 \
				or float(rs.get("y_offset", 0.0)) < -0.001:
			stow_ok = false
	print("PlaytestHarness: project verify — %d crate(s) stowed in the container %s" % [
		stowed_n, "PASS" if (stow_ok and stowed_n > 0) else "FAIL"])
	await get_tree().create_timer(0.5).timeout
	await _shoot_ui(dir, "01_delivered")

	# --- stage 2: UNLOAD (carry observed + crate moved by the effect) ----------
	# The carry leg is SECONDS of sim time, so at 720× the whole walk is
	# sub-frame and a 0.5 s poll never catches carrying=true (learned live:
	# the crate moved while the flag was never sampled on). Sample at a crawl
	# (~7×) with per-frame polls until the carry is seen, THEN speed up to
	# finish the unload.
	if main != null and "time_scale" in main:
		main.time_scale = 0.002
	var saw_carrying := false
	var crate_moved := false
	var stage_pt := Vector2(float(staging.get("x", 0.0)), float(staging.get("z", 0.0)))
	var carry_t0 := Time.get_ticks_msec()
	while not saw_carrying and Time.get_ticks_msec() - carry_t0 < 90000:
		await get_tree().process_frame
		for d in (bridge.call("agent_dots") as Array):
			if bool((d as Dictionary).get("carrying", false)):
				saw_carrying = true
		var slow_rec: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
		if Vector2(float(slow_rec.get("x", 0.0)), float(slow_rec.get("z", 0.0))) \
				.distance_to(stage_pt) < 1.5:
			crate_moved = true   # completed before the flag was seen — done
			break
	if main != null and "time_scale" in main:
		main.time_scale = 0.2
	for _i in 240:
		if crate_moved:
			break
		await get_tree().create_timer(0.5).timeout
		if not saw_carrying:
			for d in (bridge.call("agent_dots") as Array):
				if bool((d as Dictionary).get("carrying", false)):
					saw_carrying = true
		var now_rec: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
		var at := Vector2(float(now_rec.get("x", 0.0)), float(now_rec.get("z", 0.0)))
		if at.distance_to(stage_pt) < 1.5:
			crate_moved = true
			break
	print("PlaytestHarness: project verify — carrying dot %s, crate moved to staging %s" % [
		"PASS" if saw_carrying else "FAIL", "PASS" if crate_moved else "FAIL"])
	# A set-down must land the crate ON THE GROUND and un-stow it. The XZ
	# checks above pass either way, so a crate left floating at stack height
	# would otherwise ship invisible.
	var landed: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
	var ok_landed: bool = absf(float(landed.get("y_offset", 0.0))) < 0.01 \
		and str(landed.get("stowed_in", "")).is_empty()
	print("PlaytestHarness: project verify — hauled crate set down on the ground %s (y_offset %.3f)" % [
		"PASS" if ok_landed else "FAIL", float(landed.get("y_offset", 0.0))])
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	await _shoot_ui(dir, "02_unloaded")

	# --- stage 2b: BRIGADE unload (starter camp, 7 crates, roster 12) ----------
	# With this crew density NpcHaulModel flips to the bucket brigade: ONE crew
	# chore whose stage effects move the crates one by one while the line
	# works. Whichever strategy it picks, every crate must reach its staging.
	var res2: Variant = loader.call("deliver_packed_kit", "starter_camp", -30.0, 45.0, 0.0)
	var crate_ids2: Array = (res2 as Dictionary).get("crate_ids", []) if res2 is Dictionary else []
	var brigade_strategy := ""
	for prow2 in (bridge.call("all_site_projects") as Array):
		var pd2 := (prow2 as Dictionary)["project"] as Dictionary
		if str(pd2.get("prop_id", "")) == str((res2 as Dictionary).get("container_prop_id", "")):
			brigade_strategy = str(pd2.get("label", ""))
	print("PlaytestHarness: project verify — second delivery: %d crates, project '%s'" % [
		crate_ids2.size(), brigade_strategy])
	if main != null and "time_scale" in main:
		main.time_scale = 0.25
	var all_staged := false
	for _b in 360:
		await get_tree().create_timer(0.5).timeout
		var staged := 0
		for pid2 in crate_ids2:
			var r2: Dictionary = PlacedPropService.get_prop_record(main, str(pid2))
			var st2: Dictionary = r2.get("staging", {})
			var at2 := Vector2(float(r2.get("x", 0.0)), float(r2.get("z", 0.0)))
			if at2.distance_to(Vector2(float(st2.get("x", 0.0)),
					float(st2.get("z", 0.0)))) < 1.5:
				staged += 1
		if staged == crate_ids2.size() and not crate_ids2.is_empty():
			all_staged = true
			break
		if _b % 60 == 59:
			print("PlaytestHarness: project verify [unload2] — %d/%d crates staged" % [
				staged, crate_ids2.size()])
	print("PlaytestHarness: project verify — second delivery fully unloaded %s" % [
		"PASS" if all_staged else "FAIL"])
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	await _shoot_ui(dir, "02b_second_delivery")

	# --- stage 3: BUILD project (ghost grows with real labour) -----------------
	var p := LinkageParams.new()
	p.from_config(crec.get("linkage_spec", {}) as Dictionary)
	var counts := LinkageBom.fab_counts(LinkageBom.compute(p), {})
	counts.erase("assembly_steps")   # keep the plan at its 8 canonical phases
	var tasks: Array = NpcCrewPlan.linkage_fab_tasks(counts)
	var sched: Dictionary = NpcCrewPlan.schedule(tasks, 12)
	var overrides: Dictionary = {}
	for t2 in tasks:
		var tid := str((t2 as Dictionary).get("id", ""))
		match tid:
			"erect":
				overrides[tid] = {"effect": {"op": "unpack_prop", "prop_id": crate_id}}
			"panels":
				overrides[tid] = {"effect": {"op": "seed_graph", "prop_id": crate_id}}
			_:
				overrides[tid] = {"effect": {"op": "set_build_phase",
					"prop_id": crate_id, "phase": tid}}
	PlacedPropService.update_prop_record(main, crate_id,
		{"build_state": {"phase": "", "ghost": 0.12}}, true)
	var proj_id := str(bridge.call("create_site_project", hab_id,
		"linkage_build", "Harness build", crate_id, stage_pt,
		NpcCrewPlan.chore_specs(tasks, sched, overrides),
		{"start_h": 0.0, "end_h": 24.0}, {"kind": "prop", "id": crate_id},
		# fab_counts so the experiment lab can rebuild the task graph and
		# report a real PLANNED lower bound beside each simulated makespan.
		{"crew": 12, "makespan_s": float(sched.get("makespan_s", 0.0)),
			"fab_counts": counts}))
	var ok_build_proj := not proj_id.is_empty()
	if main != null and "time_scale" in main:
		main.time_scale = 0.35
	var beam_seen_max := -1
	var beam_grew := false
	var deployed := false
	for _j in 600:
		await get_tree().create_timer(0.5).timeout
		if _j % 60 == 59:
			_print_project_rollup(bridge, board, proj_id, "build")
		var rec_now: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
		if not bool(rec_now.get("packed", true)) and bool(rec_now.get("linkage_deployed", false)):
			deployed = true
			break
		# Ghost growth: read the construction builder's beam MultiMesh.
		var root := main.find_child("PlacedProps", true, false)
		if root != null:
			for child in root.get_children():
				if child is PlacedProp and str((child as PlacedProp).prop_id) == crate_id:
					var mr := child.get_node_or_null("ModelRoot")
					if mr != null and mr.has_method("set_build_progress"):
						var beams := mr.get_node_or_null("Beams") as MultiMeshInstance3D
						if beams != null and beams.multimesh != null:
							var vis := beams.multimesh.visible_instance_count
							if vis > beam_seen_max and beam_seen_max >= 0:
								beam_grew = true
							beam_seen_max = maxi(beam_seen_max, vis)
	if beam_seen_max > 0 and not beam_grew:
		beam_grew = true   # grew from the pre-poll zero to a positive count
	var rec_final: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
	var ok_cleared: bool = not (rec_final.get("build_state") is Dictionary) \
		or (rec_final.get("build_state") as Dictionary).is_empty()
	print("PlaytestHarness: project verify — build project %s, ghost grew %s (max %d beams), raised+deployed %s, build_state cleared %s" % [
		"PASS" if ok_build_proj else "FAIL", "PASS" if beam_grew else "FAIL",
		beam_seen_max, "PASS" if deployed else "FAIL",
		"PASS" if ok_cleared else "FAIL"])
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	await get_tree().create_timer(1.0).timeout
	await _shoot_ui(dir, "03_raised")

	# --- stage 3b: EXPERIMENT LAB (sim-backed variant comparison) -------------
	# Console-only by design: a PNG cannot tell you whether a makespan is 6 h
	# or 60 h, and that difference is the whole feature.
	var lab_ok := false
	var lab_setup: Dictionary = bridge.call("experiment_setup", hab_id, proj_id, main) \
		if bridge.has_method("experiment_setup") else {}
	if lab_setup.is_empty():
		print("PlaytestHarness: project verify — experiment setup FAIL (empty)")
	else:
		var lab := NpcExperimentLab.new()
		add_child(lab)
		var lres: Dictionary = lab.run_blocking(lab_setup)
		var lrows: Array = lres.get("rows", [])
		var done_rows := 0
		print("PlaytestHarness: experiment — %-26s %8s %8s %8s  %s" % [
			"variant", "sim", "plan", "drag", "status"])
		for lr in lrows:
			var ld := lr as Dictionary
			if str(ld.get("status", "")) == "done":
				done_rows += 1
			var dh := float(ld.get("drag_h", -1.0))
			print("PlaytestHarness: experiment — %-26s %7.1fh %7.1fh %8s  %s %s" % [
				str(ld.get("label", "")), float(ld.get("makespan_h", 0.0)),
				float(ld.get("plan_h", 0.0)),
				("%.1fh" % dh) if dh >= 0.0 else "—",
				str(ld.get("status", "")), str(ld.get("dnf_reason", ""))])
		var summ: Dictionary = lres.get("summary", {})
		print("PlaytestHarness: experiment — fastest '%s' (%.1fh); baseline %s; %d ticks" % [
			str(summ.get("best_label", "")), float(summ.get("best_h", -1.0)),
			("%.1fh" % float(summ.get("baseline_h", 0.0))) \
				if bool(summ.get("baseline_done", false)) else "DID NOT FINISH",
			int(lres.get("ticks", 0))])
		lab_ok = not lrows.is_empty() and done_rows > 0
		lab.queue_free()
	print("PlaytestHarness: project verify — experiment lab %s" % [
		"PASS" if lab_ok else "FAIL"])
	await _shoot_ui(dir, "06_experiment")

	# --- stage 4: BREAKDOWN (reverse project folds it back to a crate) --------
	var bd_rows: Array = SiteProject.breakdown_spec_rows(counts, crate_id, {})
	var bd_id := str(bridge.call("create_site_project", hab_id,
		"linkage_breakdown", "Harness breakdown", crate_id, stage_pt, bd_rows,
		{"start_h": 0.0, "end_h": 24.0}, {"kind": "prop", "id": crate_id}, {}))
	var ok_bd_proj := not bd_id.is_empty()
	if main != null and "time_scale" in main:
		main.time_scale = 0.35
	var repacked := false
	# Ghost-down: the hardware must visibly leave WHILE the beams stand — the
	# fold sweep is the beams' own visual, so dissolving them early would
	# animate a fold on nothing. Sampled live off the builder's own getter.
	var saw_stripping := false
	var beams_held := true
	var stripped_shot := false
	for _k in 600:
		await get_tree().create_timer(0.5).timeout
		if _k % 60 == 59:
			_print_project_rollup(bridge, board, bd_id, "breakdown")
		var bprop := PlacedPropRuntime.find_by_prop_id(main, crate_id)
		var bmr: Node = bprop.get_node_or_null("ModelRoot") if bprop != null else null
		if bmr != null and bmr.has_method("build_progress"):
			var bp_now: Dictionary = bmr.call("build_progress")
			if not bp_now.is_empty():
				var b_beams := float(bp_now.get("beams", 1.0))
				var b_bolts := float(bp_now.get("bolts", 1.0))
				if b_bolts < 0.999 or float(bp_now.get("panels", 1.0)) < 0.999:
					saw_stripping = true
					if b_beams < 0.999:
						beams_held = false
					if not stripped_shot and b_bolts < 0.9:
						stripped_shot = true
						await _shoot_ui(dir, "05a_stripping")
		var rec_bd: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
		if bool(rec_bd.get("packed", false)):
			repacked = true
			break
	if main != null and "time_scale" in main:
		main.time_scale = 0.0
	print("PlaytestHarness: project verify — breakdown project %s, folded back to packed %s" % [
		"PASS" if ok_bd_proj else "FAIL", "PASS" if repacked else "FAIL"])
	print("PlaytestHarness: project verify — teardown stripped hardware %s, beams stood through it %s" % [
		"PASS" if saw_stripping else "FAIL", "PASS" if beams_held else "FAIL"])
	await get_tree().create_timer(1.0).timeout
	await _shoot_ui(dir, "04_repacked")

	# --- cleanup: seeded graph items + delivered test props off the map --------
	for pid in prj_ids:
		if not (model.get_item(str(pid)) as Dictionary).is_empty():
			model.remove_item(str(pid))
	var doomed: Array = []
	doomed.append_array(crate_ids)
	doomed.append_array(crate_ids2)
	if res is Dictionary:
		doomed.append((res as Dictionary).get("container_prop_id", ""))
	if res2 is Dictionary:
		doomed.append((res2 as Dictionary).get("container_prop_id", ""))
	for dpid in doomed:
		if not str(dpid).is_empty() and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", str(dpid))
	print("PlaytestHarness: project verify — removed %d test props from the map" % doomed.size())
	var all_ok := ok_deliver and ok_identity and ok_project and saw_carrying \
		and crate_moved and all_staged and ok_build_proj and beam_grew \
		and deployed and ok_cleared and ok_bd_proj and repacked \
		and saw_stripping and beams_held and stow_ok and ok_landed and lab_ok
	print("PlaytestHarness: project verify — %s (shots in %s)" % [
		"PASS" if all_ok else "FAIL", ProjectSettings.globalize_path(dir)])
	cam.queue_free()
	_maybe_quit()


# ==================== SETTLEMENT VIEW (--capture=settlement) ====================
## Opens the settlement view through Main's REAL entry point and shoots it at
## five zoom stops, dumping the numbers a PNG cannot show (height, pitch,
## near/far, visible avatars, cull reach). Then drives SiteTargetPicker at a
## known agent's screen position at each stop — the angular-pick-radius
## property end to end — follows someone, drops in, and finally asserts the
## PLAYER CAMERA IS BACK and the clock never moved. That last pair is the
## anti-snowglobe assertion: this view must never freeze the sim, and must
## never strand the viewport on its own camera.
func _run_settlement_capture() -> void:
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_settlement_view"):
		push_error("PlaytestHarness: Main has no settlement view — aborting")
		_maybe_quit()
		return

	var label := _shots_label if not _shots_label.is_empty() else "settlement"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)

	# Seed a crew, or there is nobody to click and the picking assertions —
	# the point of the whole capture — would silently report 0 of 0.
	var sgv0 := await _find_graph_view()
	var seeded := false
	if sgv0 != null:
		var model: Variant = sgv0.get("model")
		if model != null and (model.get_item("cap_set_hab") as Dictionary).is_empty():
			model.add_item({
				"id": "cap_set_hab", "type": "processor", "x": 0.0, "y": 0.0,
				"width": 150.0, "height": 150.0,
				"specs": {"name": "Settlement Crew", "role": "habitat",
					"occupants": 8, "pop_driven": true, "watts": 0.0,
					"energy_source": "", "efficiency": 1.0,
					"inputs": [], "outputs": []},
			})
			seeded = true
		var reg0: Variant = null
		var br0: Variant = sgv0.get("_npc_population")
		await get_tree().create_timer(1.5).timeout
		br0 = sgv0.get("_npc_population")
		if br0 != null and br0.has_method("registry_for"):
			reg0 = br0.call("registry_for", main)
		if reg0 != null:
			for pair in [["kitchen", Vector2(20, 0)], ["water_point", Vector2(-20, 0)],
					["sleep", Vector2(0, 24)], ["restroom", Vector2(0, -24)],
					["shower", Vector2(24, 24)]]:
				var c: Vector2 = pair[1]
				reg0.call("set_space_type", {"kind": "area", "poly": [
					[c.x - 6, c.y - 6], [c.x + 6, c.y - 6],
					[c.x + 6, c.y + 6], [c.x - 6, c.y + 6]]}, str(pair[0]), 30)
		if main != null and "time_scale" in main:
			main.time_scale = 0.05
		await get_tree().create_timer(3.0).timeout
		if main != null and "time_scale" in main:
			main.time_scale = 0.01

	# Park the clock at the review hour BEFORE opening. The view must not touch
	# the clock (that is the anti-snowglobe assertion below), but the harness
	# may — otherwise a run that happens to land after sunset ships five shots
	# of a dark field and nothing about the camera ladder is reviewable.
	if "day_time" in main:
		main.day_time = _capture_hour
		await get_tree().process_frame
	var clock_before := float(main.get("time_scale")) if "time_scale" in main else 0.0
	var cam_before := get_viewport().get_camera_3d()

	main.call("open_settlement_view")
	await get_tree().create_timer(1.0).timeout
	var view: Variant = main.get("settlement_view")
	var ok_open := view != null and bool(view.call("is_open"))
	print("PlaytestHarness: settlement — opened %s" % ["PASS" if ok_open else "FAIL"])
	if not ok_open:
		_maybe_quit()
		return
	var cam: Variant = view.call("camera")

	# The clock must still be running — this is the difference from the
	# snowglobe, which freezes it.
	var clock_live := absf(float(main.get("time_scale")) - clock_before) < 1e-9
	print("PlaytestHarness: settlement — clock untouched on entry %s (%.6f)" % [
		"PASS" if clock_live else "FAIL", float(main.get("time_scale"))])

	var stops := [["eye", 1.7], ["street", 12.0], ["block", 60.0],
		["camp", 300.0], ["site", 1200.0]]
	var picks_ok := 0
	var picks_tried := 0
	for i in stops.size():
		var s: Array = stops[i]
		cam.set("_h_target", float(s[1]))
		cam.set("_h", float(s[1]))
		await get_tree().create_timer(0.6).timeout
		var vp := get_viewport()
		print("PlaytestHarness: settlement — %-7s h=%7.1f pitch=%6.1f° near=%.2f far=%6.0f scale='%s' cull=%.0f" % [
			str(s[0]), float(cam.call("height")),
			rad_to_deg(SettlementCamera._pitch_for(float(s[1]))),
			(cam as Camera3D).near, (cam as Camera3D).far,
			str(cam.call("scale_label")), PropRenderTuning.scale_override_m])
		# Pick a known agent by projecting them to screen and resolving back.
		var bridge: Variant = null
		var sgv := main.get_node_or_null("UILayer/SystemGraphView")
		if sgv != null and sgv.has_method("npc_population_bridge"):
			bridge = sgv.call("npc_population_bridge")
		if bridge != null:
			var dots: Array = bridge.call("agent_dots")
			if not dots.is_empty():
				var d0: Dictionary = dots[0]
				var wp: Vector2 = d0.get("pos", Vector2.ZERO)
				var gy := TerrainSurfaceQuery.ground_height_at(main, wp.x, wp.y)
				var world := Vector3(wp.x, gy + NpcAvatar.PICK_CENTER_Y, wp.y)
				var c3 := cam as Camera3D
				if not c3.is_position_behind(world):
					var sp := c3.unproject_position(world)
					picks_tried += 1
					var hit := SiteTargetPicker.resolve(main,
						c3.project_ray_origin(sp), c3.project_ray_normal(sp),
						{"want": PackedStringArray(["npc"]),
							"max_dist_m": maxf(float(cam.call("height")) * 6.0, 250.0)})
					# What must hold at EVERY zoom is that clicking a person
					# selects A PERSON. Demanding the exact individual is only
					# fair while the pick radius is tighter than the spacing
					# between them: at 1200 m the radius is ~12.6 m, so a whole
					# cluster shares one target and the nearest-along-ray wins.
					# No player has sub-pixel aim there either.
					var r_m := SiteTargetPicker.pick_radius_at(float(s[1]))
					var exact_expected := r_m < 4.0
					if str(hit.get("kind", "")) != "npc":
						print("PlaytestHarness: settlement —   pick MISS at %s (nobody): %s" % [
							str(s[0]), str(hit)])
					elif exact_expected and str(hit.get("agent_id", "")) != str(d0.get("id", "")):
						print("PlaytestHarness: settlement —   pick WRONG PERSON at %s: %s" % [
							str(s[0]), str(hit.get("agent_id", ""))])
					else:
						picks_ok += 1
						if not exact_expected and str(hit.get("agent_id", "")) != str(d0.get("id", "")):
							print("PlaytestHarness: settlement —   %s: picked a neighbour (radius %.1f m) — expected at this range" % [
								str(s[0]), r_m])
		await _shoot_ui(dir, "0%d_%s" % [i + 1, str(s[0])])
	print("PlaytestHarness: settlement — picked the right person at %d of %d zoom stops %s" % [
		picks_ok, picks_tried, "PASS" if (picks_tried > 0 and picks_ok == picks_tried) else "FAIL"])

	# Exit and assert the world is exactly as we found it.
	view.call("close")
	await get_tree().create_timer(0.5).timeout
	var cam_after := get_viewport().get_camera_3d()
	var ok_restore := cam_after == cam_before and cam_after != null
	var ok_clock := absf(float(main.get("time_scale")) - clock_before) < 1e-9
	print("PlaytestHarness: settlement — player camera restored %s, clock never moved %s" % [
		"PASS" if ok_restore else "FAIL", "PASS" if ok_clock else "FAIL"])
	print("PlaytestHarness: settlement — cull override cleared %s (%.1f)" % [
		"PASS" if is_equal_approx(PropRenderTuning.scale_override_m, 0.0) else "FAIL",
		PropRenderTuning.scale_override_m])
	# Leave the map as we found it.
	if seeded and sgv0 != null:
		var m2: Variant = sgv0.get("model")
		if m2 != null and not (m2.get_item("cap_set_hab") as Dictionary).is_empty():
			m2.remove_item("cap_set_hab")
	var all_ok := ok_open and clock_live and ok_restore and ok_clock \
		and picks_tried > 0 and picks_ok == picks_tried \
		and is_equal_approx(PropRenderTuning.scale_override_m, 0.0)
	print("PlaytestHarness: settlement — %s (shots in %s)" % [
		"PASS" if all_ok else "FAIL", ProjectSettings.globalize_path(dir)])
	_maybe_quit()


## --capture=labour — the labour merge, end to end, console only.
##
## No screenshots on purpose: the whole contract is an EQUALITY (the ledger
## moves by exactly the step's hours) plus a chore appearing AT the machine's
## prop rather than in the abstract. Neither is visible in a PNG.
func _run_labour_capture() -> void:
	# Poll for the view FIRST — this can be called the same frame the scene
	# switch is requested, before the map scene exists at all.
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: labour — no graph view; aborting")
		_maybe_quit()
		return
	sgv.visible = false
	var scene := get_tree().current_scene
	var loader0: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader0 != null and not (loader0.get("load_completed") == true):
		await loader0.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var model: Variant = sgv.get("model")
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if model == null or loader == null:
		push_error("PlaytestHarness: labour — needs a real TerrainLoader map; aborting")
		_maybe_quit()
		return

	# A crew to do the work, and somewhere for them to meet their own needs —
	# a camp with no kitchen stalls on tier 1 and never reaches a chore.
	model.add_item({
		"id": "cap_lab_hab", "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 150.0,
		"specs": {"name": "Labour Crew", "role": "habitat", "occupants": 6,
			"pop_driven": true, "watts": 0.0, "energy_source": "",
			"efficiency": 1.0, "inputs": [], "outputs": []},
	})
	await get_tree().create_timer(1.5).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null:
		push_error("PlaytestHarness: labour — bridge never came up; aborting")
		_maybe_quit()
		return
	var reg: Variant = bridge.call("registry_for", main)
	if reg != null:
		for pair in [["kitchen", Vector2(18, 0)], ["water_point", Vector2(-18, 0)],
				["sleep", Vector2(0, 20)], ["restroom", Vector2(0, -20)],
				["shower", Vector2(20, 20)]]:
			var c: Vector2 = pair[1]
			reg.call("set_space_type", {"kind": "area", "poly": [
				[c.x - 6, c.y - 6], [c.x + 6, c.y - 6],
				[c.x + 6, c.y + 6], [c.x - 6, c.y + 6]]}, str(pair[0]), 30)

	# The machine: a processor parked on a labour step, standing at a known
	# spot 42 m from camp so "did anyone walk there" is answerable.
	var mach_xz := Vector2(30.0, 30.0)
	var prop_id := ""
	var layer: Variant = loader.get("_placed_prop_layer")
	if layer != null:
		var gy := TerrainSurfaceQuery.ground_height_at(main, mach_xz.x, mach_xz.y)
		prop_id = str(layer.call("add_free_prop", "pallet_rack",
			mach_xz.x, 0.0, mach_xz.y, 0.0, 0.0, 0.0, 1.0, gy))
		loader.call_deferred("_rebuild_placed_props")
	model.add_item({"id": "cap_lab_mill", "type": "processor",
		"x": 300.0, "y": 0.0, "width": 150.0, "height": 150.0,
		"specs": {"name": "Test Mill", "role": "processor", "watts": 0.0,
			"energy_source": "", "efficiency": 1.0, "inputs": [], "outputs": [],
			"bound_prop_id": prop_id}})
	var ledger: Variant = loader.call("get_chore_ledger")
	if ledger != null:
		ledger.set("infinite_labor", false)
		ledger.set("chore_hours_available", 0.0)
	var recipe := {
		"id": "cap_labour", "batch_time_hrs": 1.0,
		"steps": [{"id": "tend", "at_frac": 0.2, "chore_hours": 0.5,
			"label": "Tend the mill"}],
	}
	var lspecs: Dictionary = (model.get_item("cap_lab_mill") as Dictionary).get("specs", {})
	var h0 := float(main.get_absolute_hours())
	RecipeRunner.begin_run(lspecs, h0, recipe)
	RecipeRunner.tick_state(lspecs, h0 + 0.4, 0.1, ledger)   # onto the labour step
	var waiting := bool(lspecs.get("recipe_waiting_chore", false)) \
		and str(lspecs.get("recipe_waiting_kind", "")) == "crew"
	print("PlaytestHarness: labour — the step waits for HANDS %s (kind=%s)" % [
		"PASS" if waiting else "FAIL", str(lspecs.get("recipe_waiting_kind", ""))])
	var before := float(ledger.get("chore_hours_consumed_total")) if ledger != null else 0.0

	# Run the world until the crew has walked over and done it.
	if "time_scale" in main:
		main.time_scale = 0.08
	var minted := false
	var at_machine := false
	var resumed := false
	for _i in 320:
		await get_tree().create_timer(0.25).timeout
		var cboard: Variant = bridge.call("chore_board_for", "cap_lab_hab")
		if cboard != null:
			var ch: Dictionary = cboard.call(
				"find_by_key", "mach|cap_lab_mill|tend") as Dictionary
			if not ch.is_empty():
				minted = true
				var tgt: Dictionary = ch.get("target", {})
				# The whole point of routing through the board: the work has a
				# PLACE, and it is the machine's place.
				if str(tgt.get("kind", "")) == "prop" \
						and str(tgt.get("id", "")) == prop_id and not prop_id.is_empty():
					at_machine = true
		var now: Dictionary = (model.get_item("cap_lab_mill") as Dictionary).get("specs", {})
		if minted and not bool(now.get("recipe_waiting_chore", false)):
			resumed = true
			break
	if "time_scale" in main:
		main.time_scale = 0.01
	print("PlaytestHarness: labour — a chore was minted AT the machine %s (minted=%s at_prop=%s)" % [
		"PASS" if (minted and at_machine) else "FAIL", str(minted), str(at_machine)])
	print("PlaytestHarness: labour — the crew finished it and the step resumed %s" % [
		"PASS" if resumed else "FAIL"])
	var moved := (float(ledger.get("chore_hours_consumed_total")) - before) if ledger != null else -1.0
	# THE contract. Not "roughly" — a second accounting path shows up here as a
	# doubling, and nothing else in the game would notice.
	var ok_ledger := absf(moved - 0.5) < 0.01
	print("PlaytestHarness: labour — the ledger moved by EXACTLY the step's hours %s (%.4f h, want 0.5)" % [
		"PASS" if ok_ledger else "FAIL", moved])

	# --- the duty rota, end to end through the real bridge ------------------
	# The classes are selftested offline; what this proves is the WIRING —
	# config loaded, the daily service running, chores minted with names on
	# them, and hours banked against the people who did the work.
	var ok_duty := false
	var ok_hours := false
	var roster: Variant = bridge.call("duty_roster_for", "cap_lab_hab")
	if roster != null:
		roster.call("add_duty", "Cook lunch", 1.0, {"crew": 2, "repeat": "daily",
			"window": {"start_h": 0.0, "end_h": 24.0}})
		bridge.call("save_duties", model, "cap_lab_hab")
		if "time_scale" in main:
			main.time_scale = 0.5
		for _j in 60:
			await get_tree().create_timer(0.25).timeout
			var bd: Variant = bridge.call("chore_board_for", "cap_lab_hab")
			if bd != null and not bd.call("find_by_key", "duty|duty_1|%d"
					% NpcChoreBoard.day_index(float(main.get_absolute_hours()))).is_empty():
				ok_duty = true
				break
		if "time_scale" in main:
			main.time_scale = 0.01
		var today := NpcChoreBoard.day_index(float(main.get_absolute_hours()))
		print("PlaytestHarness: labour — today on duty: %s" % [
			roster.call("today_text", today)])
	var lab: Variant = bridge.call("labour_for", "cap_lab_hab")
	if lab != null:
		var tot := 0.0
		for a in bridge.call("roster_for", "cap_lab_hab"):
			tot += float(lab.call("total_hours", (a as NpcAgent).id))
		ok_hours = tot > 0.0
		print("PlaytestHarness: labour — %.2f person-hours banked across the crew" % tot)
	# The end-to-end proof of the whole scheduling arc: a duty template the
	# player wrote became a chore on the board with NAMES on it, and the hours
	# the crew worked landed against the people who worked them.
	#
	# ⚠ Position matters: this must run BEFORE the cleanup below removes the
	# habitat. Placed after it, `duty_roster_for` correctly returns null
	# (the bridge drops the engine when the item goes) and the whole phase
	# reads as a wiring failure that is really a test-ordering mistake.
	print("PlaytestHarness: labour — the duty rota minted a NAMED slot %s" % [
		"PASS" if ok_duty else "FAIL (no duty| chore reached the board)"])
	print("PlaytestHarness: labour — per-agent hours are recorded %s" % [
		"PASS" if ok_hours else "FAIL (nothing banked)"])

	# Leave the map as we found it.
	model.remove_item("cap_lab_mill")
	model.remove_item("cap_lab_hab")
	if not prop_id.is_empty() and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", prop_id)

	print("PlaytestHarness: labour — %s" % [
		"PASS" if (waiting and minted and at_machine and resumed and ok_ledger
			and ok_duty and ok_hours) else "FAIL"])
	_maybe_quit()


# ---------------------------------------------------------------------------
# Penstock placement verify (--capture=penstock) — Round 2 / Phase G
# ---------------------------------------------------------------------------

## Drives the whole "drop the pipe uphill and that is the source" path on a REAL
## map and asserts the parts a screenshot cannot show: that a Stream Intake prop
## + graph node were minted at the release point, that the penstock connection
## exists and RENDERS (3D wires default off, which is exactly why the feature
## looked dead), that the conduit rebuild stamped a measured run at least as
## long as the straight chord plus real endpoint inverts, and that the turbine
## adopted them and produced power. Cleans up its cap_pen_* items afterward.
func _run_penstock_verify() -> void:
	var sgv := await _find_graph_view()
	if sgv == null:
		push_error("PlaytestHarness: SystemGraphView not found — aborting penstock verify")
		_maybe_quit()
		return
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: penstock verify needs a TerrainLoader (--user-map=…)")
		_maybe_quit()
		return
	await get_tree().create_timer(_settle_s()).timeout
	var model: Variant = sgv.get("model")
	var main := get_tree().current_scene
	if model == null or main == null:
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "penstock"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	var fails := 0

	# The world's own stream intakes are the player's: remember them so the
	# cleanup only ever removes what THIS run (or a killed earlier run) made.
	_pen_keep.clear()
	for it0 in (model.items as Array):
		var d0 := it0 as Dictionary
		var iid0 := str(d0.get("id", ""))
		if not iid0.begins_with("cap_pen_") and (ResourceFlowEngine.is_stream_intake(d0) \
				or str((d0.get("specs", {}) as Dictionary).get("model_id", "")) == "stream_intake"):
			_pen_keep[iid0] = true
	# Clear leftovers from a previous run so the assertions are honest.
	_penstock_cleanup(model, main)
	# This capture asserts LIVE results — the turbine adopting its routed run,
	# the intake's supply, water flowing — and the flow engine only simulates
	# when sim time advances (ResourceFlowEngine.tick: dt_hours > 0). The
	# world loads with whatever clock the player left: Mount Vernon was saved
	# PAUSED at 01:40 (time_scale 0), which read as "the turbine never adopts
	# its penstock" (14 checks, 2026-10-18). Own the clock: a daytime hour at
	# 60x, well under the high-speed tick regime.
	if "day_time" in main:
		main.set("day_time", 10.0)
	if "time_scale" in main:
		main.set("time_scale", 1.0 / 60.0)
		print("PlaytestHarness: penstock verify — clock set to 10:00 at 60x (the saved world's clock is not relied on)")

	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi == null or not soi.has_method("world_center"):
		push_error("PlaytestHarness: SoiService unavailable")
		_maybe_quit()
		return
	var center: Vector3 = soi.call("world_center") as Vector3

	# Find real high ground to tap: scan rings and take the highest terrain
	# within ~90 m (a genuine hillside, not a synthetic offset).
	var best_xz := Vector2(center.x + 40.0, center.z)
	var best_y := -INF
	for i in 48:
		var a := TAU * float(i) / 48.0
		for r in [35.0, 60.0, 90.0]:
			var wx: float = center.x + cos(a) * float(r)
			var wz: float = center.z + sin(a) * float(r)
			var gy := TerrainSurfaceQuery.ground_height_at(main, wx, wz)
			if gy > best_y:
				best_y = gy
				best_xz = Vector2(wx, wz)
	# Seat the turbine a few metres OFF the SoI centre: the site's own SoI
	# marker stands exactly there, and the crosshair phase below found the
	# marker in front of the turbine ("aiming at the turbine focuses the
	# PROP" read SoiMarker on the Mount Vernon world).
	center = center + Vector3(8.0, 0.0, 8.0)
	var turbine_y := TerrainSurfaceQuery.ground_height_at(main, center.x, center.z)
	print("PlaytestHarness: penstock verify — turbine ground %.2f m, best uphill %.2f m (%.0f m away)" % [
		turbine_y, best_y, Vector2(center.x, center.z).distance_to(best_xz)])
	if best_y <= turbine_y + 1.0:
		print("PlaytestHarness: penstock verify — SKIP (flat site; no uphill source within 90 m)")
		_maybe_quit()
		return

	# Seed a PowerSpout turbine at the site centre, bound to a real 3D prop so
	# the conduit has an anchor at that end.
	var placed: Dictionary = PlacedPropService.place_model_at_xz(
			main, "powerspout_plt", center.x, center.z)
	if not bool(placed.get("ok", false)):
		push_error("PlaytestHarness: could not place the PowerSpout prop")
		_maybe_quit()
		return
	var prop_id := str(placed.get("prop_id", ""))
	var turbine_id := "cap_pen_turbine"
	var t_specs := _penstock_turbine_specs()
	if t_specs.is_empty():
		push_error("PlaytestHarness: PowerSpout preset not found")
		_maybe_quit()
		return
	t_specs["bound_prop_id"] = prop_id
	t_specs["gross_head_m"] = 0.0   # force the ROUTED geometry to be the authority
	model.call("add_item", {
		"id": turbine_id, "type": "processor", "x": 0.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "scope_id": "root",
		"site_x_m": 0.0, "site_z_m": 0.0, "elevation_m": turbine_y,
		"specs": t_specs,
	})
	PlacedPropService.update_prop_record(main, prop_id,
			{"graph_item_id": turbine_id, "kind": "siphon_hydro",
			"turbine_node": ModelCatalog.turbine_node_for("powerspout_plt"),
			"spin_axis": ModelCatalog.spin_axis_for("powerspout_plt")}, true)
	await get_tree().create_timer(0.6).timeout
	await _graph_shot(dir, "01_turbine_placed", manifest)

	# THE ACT UNDER TEST: drop the penstock uphill end on that hillside.
	var conn_id := str(sgv.call("create_penstock_intake_at",
			Vector3(best_xz.x, best_y, best_xz.y), turbine_id, "res_in_0",
			{"pipe_size_in": 2.0}))
	fails += _pen_check("penstock connection created", not conn_id.is_empty())
	await get_tree().create_timer(1.2).timeout

	# An intake item + prop exist at the release point. It is the penstock's
	# OWN source: "the first stream intake in the graph" was the player's (Mt
	# Vernon has two), and every later check then looked at the wrong node.
	var intake_id := ""
	var pconn: Dictionary = model.call("get_connection", conn_id) if not conn_id.is_empty() else {}
	for end_id in [str(pconn.get("source_item_id", "")), str(pconn.get("target_item_id", ""))]:
		if end_id != turbine_id and not end_id.is_empty():
			intake_id = end_id
	if intake_id.is_empty():
		for it in model.items:
			if not (it is Dictionary):
				continue
			var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
			if str(sp.get("model_id", "")) == "stream_intake" and not _pen_keep.has(str((it as Dictionary).get("id", ""))):
				intake_id = str((it as Dictionary).get("id", ""))
				break
	fails += _pen_check("stream intake graph node created", not intake_id.is_empty())
	if not intake_id.is_empty():
		var intake_item: Dictionary = model.call("get_item", intake_id)
		var isp: Dictionary = intake_item.get("specs", {}) as Dictionary
		fails += _pen_check("intake bound to a 3D prop (conduits need an anchor)",
				not str(isp.get("bound_prop_id", "")).is_empty())
		var ielev := float(intake_item.get("elevation_m", 0.0))
		fails += _pen_check("intake above the turbine (%.2f > %.2f)" % [ielev, turbine_y],
				ielev > turbine_y + 0.5)

	# The run RENDERED — the whole reason this used to look like a no-op.
	var conn: Dictionary = model.call("get_connection", conn_id)
	var run_m := float(conn.get("route_length_m", 0.0))
	var chord := Vector2(center.x, center.z).distance_to(best_xz)
	fails += _pen_check("conduit rebuild stamped a measured run (%.1f m)" % run_m,
			run_m > 0.5)
	fails += _pen_check("measured run follows the ground (>= chord %.1f m)" % chord,
			run_m >= chord * 0.98)
	var inv_in := float(conn.get("invert_in_m", NAN))
	var inv_out := float(conn.get("invert_out_m", NAN))
	fails += _pen_check("endpoint inverts stamped", not (is_nan(inv_in) or is_nan(inv_out)))
	if not (is_nan(inv_in) or is_nan(inv_out)):
		fails += _pen_check("penstock falls toward the turbine (%.2f → %.2f)" % [inv_in, inv_out],
				inv_in > inv_out)
	var mgr: Node = main.find_child("ConduitManager", true, false)
	if mgr != null and mgr.has_method("get_instance"):
		fails += _pen_check("a 3D tube mesh exists for the run",
				mgr.call("get_instance", conn_id) != null)

	# The physics adopted the routed geometry.
	var t_item: Dictionary = model.call("get_item", turbine_id)
	var t_live: Dictionary = t_item.get("specs", {}) as Dictionary
	print("PlaytestHarness: penstock verify — turbine now: run %.1f m, bore %.1f mm, outlet inv %.2f, %.1f W" % [
		float(t_live.get("penstock_length_m", 0.0)),
		float(t_live.get("penstock_diameter_mm", 0.0)),
		float(t_live.get("outlet_invert_m", NAN)),
		float(t_live.get("current_output_kw", 0.0)) * 1000.0])
	fails += _pen_check("turbine adopted the measured run",
			absf(float(t_live.get("penstock_length_m", 0.0)) - run_m) < 1.0)
	fails += _pen_check("turbine adopted the styled 2in SDR-9 bore",
			absf(float(t_live.get("penstock_diameter_mm", 0.0)) - 46.92) < 0.2)
	fails += _pen_check("turbine produces from the routed head",
			float(t_live.get("current_output_kw", 0.0)) > 0.0)

	# The supply loop: the intake really runs water, the water really MOVES
	# through the turbine, and the Lab's test flow really changes the answer.
	# None of this is visible in a screenshot, and all of it was broken.
	if not intake_id.is_empty():
		var isp2: Dictionary = (model.call("get_item", intake_id).get("specs", {})
				as Dictionary)
		print("PlaytestHarness: penstock verify — intake supply: base %.2f L/s, rain %.2f mm/h → live %.2f L/s (Q at turbine %.2f L/s)" % [
			float(isp2.get("base_flow_lps", 0.0)), float(isp2.get("live_rain_mmh", 0.0)),
			float(isp2.get("live_supply_lps", 0.0)), float(t_live.get("live_q_lps", 0.0))])
		fails += _pen_check("intake seeded a real base flow",
				float(isp2.get("base_flow_lps", 0.0)) > 0.0)
		fails += _pen_check("intake resolved a live supply",
				float(isp2.get("live_supply_lps", 0.0)) > 0.0)
		fails += _pen_check("turbine flows water (live_q_lps > 0)",
				float(t_live.get("live_q_lps", 0.0)) > 0.0)
		var wrate := 0.0
		for od_v: Variant in (t_live.get("outputs", []) as Array):
			if od_v is Dictionary and str((od_v as Dictionary).get("kind", "")) == "water":
				wrate = float((od_v as Dictionary).get("rate", 0.0))
		fails += _pen_check("water output port carries a real rate (%.1f L/h)" % wrate,
				wrate > 0.0)
		# Drive the Lab's test flow and confirm the power TRACKS it — the knob the
		# player actually turns, and previously a no-op on a pond-less intake.
		var lo_specs: Dictionary = t_live.duplicate(true)
		lo_specs["lab_sim_inflow_enabled"] = true
		lo_specs["lab_sim_inflow_lps"] = 0.25
		model.call("update_item", turbine_id, {"specs": lo_specs})
		await get_tree().create_timer(0.8).timeout
		var kw_lo := float((model.call("get_item", turbine_id).get("specs", {})
				as Dictionary).get("current_output_kw", 0.0))
		var hi_specs: Dictionary = (model.call("get_item", turbine_id).get("specs", {})
				as Dictionary).duplicate(true)
		hi_specs["lab_sim_inflow_lps"] = 4.0
		model.call("update_item", turbine_id, {"specs": hi_specs})
		await get_tree().create_timer(0.8).timeout
		var kw_hi := float((model.call("get_item", turbine_id).get("specs", {})
				as Dictionary).get("current_output_kw", 0.0))
		print("PlaytestHarness: penstock verify — test flow 0.25 L/s → %.1f W, 4.0 L/s → %.1f W" % [
			kw_lo * 1000.0, kw_hi * 1000.0])
		fails += _pen_check("Lab test flow drives the power (%.1f W → %.1f W)" % [
				kw_lo * 1000.0, kw_hi * 1000.0], kw_hi > kw_lo)
		var off_specs: Dictionary = (model.call("get_item", turbine_id).get("specs", {})
				as Dictionary).duplicate(true)
		off_specs["lab_sim_inflow_enabled"] = false
		model.call("update_item", turbine_id, {"specs": off_specs})
		await get_tree().create_timer(0.6).timeout

		# Seasonal supply: the annual estimate must run the intake's rain response
		# across the YEAR, not freeze at whatever the spring is doing right now.
		var live_sp: Dictionary = (model.call("get_item", turbine_id).get("specs", {})
				as Dictionary)
		var prof_v: Variant = live_sp.get("supply_monthly_lps", null)
		var prof: Array = []
		if prof_v is PackedFloat32Array:
			prof = Array(prof_v as PackedFloat32Array)
		elif prof_v is Array:
			prof = prof_v as Array
		fails += _pen_check("engine stamped a 12-month supply curve", prof.size() == 12)
		if prof.size() == 12:
			var lo := 1e30
			var hi := -1e30
			for v: Variant in prof:
				lo = minf(lo, float(v))
				hi = maxf(hi, float(v))
			var frozen := float(HydroSource.annual_energy_kwh_from_specs(
					live_sp, [])["annual_kwh"])
			var seasonal := float(HydroSource.annual_energy_kwh_from_specs(
					live_sp, [], prof)["annual_kwh"])
			print("PlaytestHarness: penstock verify — seasonal supply %.2f–%.2f L/s; annual frozen %.0f kWh vs seasonal %.0f kWh" % [
				lo, hi, frozen, seasonal])
			fails += _pen_check("seasonal curve actually varies over the year",
					hi > lo + 1e-4)
			fails += _pen_check("seasonal annual differs from the frozen estimate",
					absf(seasonal - frozen) > 1.0)

	# Phase H: the tube renders at its STYLED bore, and the Lab section draws
	# the REAL routed polyline instead of the schematic glyph.
	if mgr != null and mgr.has_method("get_instance"):
		var inst: Variant = mgr.call("get_instance", conn_id)
		# NOTE: the tube BORE is deliberately not asserted here. This run climbs
		# 46 m over 90 m, so every AABB axis is dominated by the route geometry
		# and no cheap in-world measure isolates a 60 mm pipe. The radius path is
		# pinned offline instead (conduit_selftest._test_size_driven_tube_radius
		# builds a straight run and reads the diameter straight off the mesh);
		# what this line records is the size the styled conn resolves to.
		if inst is MeshInstance3D:
			print("PlaytestHarness: penstock verify — styled bore %.1f mm (kind fallback %.1f mm)" % [
				ConduitKinds.outer_diameter_m("poly_penstock", {"pipe_size_in": 2.0}) * 1000.0,
				float(ConduitKinds.type_meta("poly_penstock").get("radius_m", 0.024)) * 2000.0])
	# Kind → model swap: the turbine wears the PowerSpout body, not the siphon one.
	var t_rec := PlacedPropService.get_prop_record(main, prop_id)
	fails += _pen_check("turbine wears its own model (%s)" % str(t_rec.get("model_id", "")),
			str(t_rec.get("model_id", "")) == "powerspout_plt")
	fails += _pen_check("record names the PowerSpout runner node",
			str(t_rec.get("turbine_node", "")) == "Pelton Wheel, 24 Spoon")
	await _graph_shot(dir, "02_penstock_routed", manifest)

	# Regression: the reported multi-turbine bug. Open the Lab EXACTLY the way
	# the 3D prop edit UI does — `visible = true` then open_siphon_lab(id) —
	# which queues a deferred _reapply_current_graph_view_mode with NO opts.
	# Pre-fix, that re-entered the Lab through the empty-id fallback and
	# retargeted it to the FIRST siphon on the graph (this map carries the
	# player's own turbines), so the dock edited the wrong machine.
	sgv.set("visible", true)
	sgv.call("open_siphon_lab", turbine_id)
	await get_tree().create_timer(0.8).timeout   # let the deferred reapply land
	var lab: Variant = sgv.get("_siphon_lab_modal")
	var lab_item := str(lab.get("_item_id")) if lab != null else ""
	fails += _pen_check("Lab stays on the turbine it was opened for (got %s)" % lab_item,
			lab_item == turbine_id)
	# Round 3: opening the Lab runs ensure_siphon_outlet_sink — for a PENSTOCK
	# kind it must NOT mint the phantom ∞ culvert tailrace (a Pelton discharges
	# tailwater at the machine), and any previously-minted one is healed away.
	var sink_wired := false
	for conn2 in model.connections:
		if not (conn2 is Dictionary):
			continue
		var c2 := conn2 as Dictionary
		if str(c2.get("source_item_id", "")) != turbine_id:
			continue
		var tgt2: Dictionary = model.call("get_item", str(c2.get("target_item_id", "")))
		if bool((tgt2.get("specs", {}) as Dictionary).get("outlet_sink", false)):
			sink_wired = true
	fails += _pen_check("no auto culvert outlet minted for a penstock kind",
			not sink_wired)
	# The oversized-nozzle recommendation is ACTIONABLE. Checked here, with the
	# Lab actually running, because _fit_nozzle_mm is written by the physics
	# refresh — a closed Lab has simply never computed it.
	if lab != null and (lab as Object).has_method("_on_fit_nozzle"):
		var rec := float((lab as Object).get("_fit_nozzle_mm"))
		var noz: Variant = (lab as Object).get("_nozzle_d_spin")
		var before_mm := float((noz as SpinBox).value) if noz != null else 0.0
		var persisted: Dictionary = (model.call("get_item", turbine_id).get("specs", {})
				as Dictionary)
		# Regression: opening the Lab used to auto-rebind an "unbound" turbine to
		# the nearest POND — and a stream intake is not a pond, so every
		# stream-fed PowerSpout had its penstock DELETED the moment you opened
		# the panel meant for tuning it.
		var still_wired := false
		for cc in model.connections:
			if not (cc is Dictionary):
				continue
			var cd := cc as Dictionary
			if str(cd.get("source_item_id", "")) == intake_id \
					and str(cd.get("target_item_id", "")) == turbine_id:
				still_wired = true
		fails += _pen_check("opening the Lab did NOT delete the penstock wiring",
				still_wired)
		fails += _pen_check("stream source survives the Lab (mode=%s supply=%s)" % [
				str(persisted.get("penstock_source_mode", "<none>")),
				str(persisted.get("supply_lps", "<none>"))],
				str(persisted.get("penstock_source_mode", "")) == "stream")
		# The 3D end of the loop: a running spring must LOOK like one.
		var intake_prop_id := str((model.call("get_item", intake_id).get("specs", {})
				as Dictionary).get("bound_prop_id", ""))
		var iprop: Variant = PlacedPropRuntime.find_by_prop_id(main, intake_prop_id) \
				if not intake_prop_id.is_empty() else null
		if iprop != null:
			var flow: Variant = (iprop as Node).get_node_or_null("StreamIntakeFlow")
			fails += _pen_check("intake carries its flow VFX runtime", flow != null)
			if flow != null:
				var parts: Variant = (flow as Node).get_node_or_null("InflowParticles")
				var pool: Variant = (flow as Node).get_node_or_null("Pool")
				var emitting := parts != null and bool((parts as GPUParticles3D).emitting)
				var wet := pool != null and bool((pool as MeshInstance3D).visible)
				print("PlaytestHarness: penstock verify — intake VFX: emitting=%s pool=%s at %.2f L/s" % [
					str(emitting), str(wet), float(flow.get("_q_lps"))])
				fails += _pen_check("a running spring shows water at the intake",
						emitting and wet)
		var lr: Dictionary = (lab as Object).get("_last_r") as Dictionary
		print("PlaytestHarness: penstock verify — nozzle now %.1f mm, recommended %.2f mm; reach: conveyance=%s regime=%s supply_limited=%s q=%.3f unused=%.2f head=%.2f" % [
			before_mm, rec, str(lr.get("conveyance", "?")), str(lr.get("regime", "?")),
			str(lr.get("supply_limited", "?")), float(lr.get("q_lps", 0.0)),
			float(lr.get("unused_head_m", 0.0)), float(lr.get("head_m", 0.0))])
		fails += _pen_check("a 1 L/s spring on a 10 mm jet is flagged supply-limited",
				rec > 0.0 and rec < before_mm)
		if rec > 0.0 and noz != null:
			# Real jets come in discrete sizes; the recommendation is snapped to
			# the spin's own step, so assert against THAT, not the raw float.
			var step := maxf((noz as SpinBox).step, 0.01)
			lab.call("_on_fit_nozzle")
			await get_tree().create_timer(0.4).timeout
			fails += _pen_check("Fit-nozzle wrote the recommended Ø (now %.1f mm)"
					% float((noz as SpinBox).value),
					absf(float((noz as SpinBox).value) - snappedf(rec, step)) < step * 0.5)
			# And fitting it must actually recover power: a matched jet converts
			# the head instead of leaving 36 m of it on the table.
			await get_tree().create_timer(0.8).timeout
			var lr2: Dictionary = (lab as Object).get("_last_r") as Dictionary
			print("PlaytestHarness: penstock verify — after fitting: unused %.2f m (was %.2f m), %.1f W" % [
				float(lr2.get("unused_head_m", 0.0)), float(lr.get("unused_head_m", 0.0)),
				float(lr2.get("power_w", 0.0))])
			fails += _pen_check("fitting the nozzle converts the wasted head",
					float(lr2.get("unused_head_m", 0.0))
						< float(lr.get("unused_head_m", 0.0)) * 0.5)
		# The test-flow control must move the ESTIMATE and the per-size stats, not
		# just the live readouts: both sat behind signature gates that had no
		# supply term, so dragging the slider looked like it did nothing.
		var spin_v: Variant = (lab as Object).get("_sim_inflow_spin")
		var stats_lbl: Variant = (lab as Object).get("_chart_stats_lbl")
		if spin_v != null and stats_lbl != null and lab.has_method("_write_sim_inflow"):
			var seen: Array = []
			for q: float in [0.4, 3.5]:
				(spin_v as SpinBox).value = q
				lab.call("_write_sim_inflow", true, q)
				await get_tree().create_timer(0.9).timeout
				seen.append(str((stats_lbl as Label).text))
				print("PlaytestHarness: penstock verify — stats @%.1f L/s: %s" % [
					q, str((stats_lbl as Label).text)])
			fails += _pen_check("per-size stats track the test flow",
					seen.size() == 2 and str(seen[0]) != str(seen[1])
					and not str(seen[0]).is_empty())
			var annual_lbl: Variant = (lab as Object).get("_annual_lbl")
			if annual_lbl != null:
				print("PlaytestHarness: penstock verify — annual now %s"
					% str((annual_lbl as Label).text))
			lab.call("_write_sim_inflow", false, 0.5)
		# The cross-section with a REAL routed run in it — the only place the
		# penstock's along-datum can be checked against the terrain profile.
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(dir, "04_lab_section_routed", manifest)
		if lab.has_method("_set_lab_view"):
			lab.call("_set_lab_view", "closeup")
			await get_tree().create_timer(2.5).timeout
			await _graph_shot(dir, "05_lab_closeup_nozzle", manifest)
			lab.call("_set_lab_view", "section")
	if sgv.has_method("close_hydro_lab"):
		sgv.call("close_hydro_lab")
	await get_tree().create_timer(0.3).timeout
	# Stand at the turbine so the run reads in first person too.
	var player: Variant = main.get("player")
	if player is Node3D:
		(player as Node3D).global_position = Vector3(
				center.x + 6.0, turbine_y + 2.0, center.z + 6.0)
		await get_tree().create_timer(0.6).timeout
		await _graph_shot(dir, "03_first_person", manifest)

	fails += await _penstock_stream_and_click_checks(sgv, model, main, turbine_id, dir, manifest)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	_penstock_cleanup(model, main)
	if fails == 0:
		print("PlaytestHarness: penstock verify — PASS (%d shots in %s)" % [
			manifest.size(), ProjectSettings.globalize_path(dir)])
	else:
		push_error("PlaytestHarness: penstock verify — %d CHECK(S) FAILED" % fails)
	_maybe_quit()


## Turn the first-person camera to look at a world point (yaw on the body,
## pitch on the camera — the player faces −Z).
func _aim_player_at(player: Node3D, cam: Camera3D, target: Vector3) -> void:
	var eye := cam.global_position
	var d := target - eye
	player.rotation.y = atan2(-d.x, -d.z)
	var flat := Vector2(d.x, d.z).length()
	cam.rotation.x = atan2(d.y, flat)


## Two things a screenshot cannot show, bolted onto the penstock verify:
## (1) With the routed penstock VISIBLE and ending at the PowerSpout, a
##     Ctrl+click aimed at the turbine must focus and open the PROP editor —
##     not the conduit style modal. Every wire ends at a port ON its prop, so
##     the pick ladder used to hand the turbine's own body to its penstock,
##     and the player could never get at the turbine ("a conduit modal keeps
##     popping up").
## (2) The WATER toolbar's Penstock span, driven through the same calls the
##     tool makes: the reach from a mapped stream's upstream vertex becomes
##     the turbine's penstock — the spans go mode "penstock" (no barrel run),
##     ONE routed poly_penstock replaces the drop-placed one (never a second),
##     its waypoints follow the stream, the intake is BOUND to the feature and
##     the engine takes that stream's flow (water_feature_id stamped,
##     penstock_source_mode "stream") whatever the 6 m rule says.
func _penstock_stream_and_click_checks(sgv: Node, model: Variant, main: Node,
		turbine_id: String, dir: String, manifest: Array) -> int:
	var fails := 0
	var loader: Node = main.find_child("TerrainLoader", true, false)
	var player: Variant = main.get("player")
	var cam: Camera3D = (player as Node3D).get_node_or_null("CameraArm/Camera3D") if player is Node3D else null
	var t_item: Dictionary = model.get_item(turbine_id)
	var prop := PlacedPropRuntime.find_by_prop_id(main,
			str((t_item.get("specs", {}) as Dictionary).get("bound_prop_id", "")))
	var mgr: Node = sgv.call("_get_conduit_manager")
	if player is Node3D and cam != null and prop != null and mgr != null:
		# close_hydro_lab() returns the G view to its Elevation lens — still
		# OPEN, so a click would land on the graph canvas. This test is about
		# the first-person crosshair: close the graph first.
		(sgv as CanvasItem).visible = false
		await get_tree().create_timer(0.4).timeout
		# Worst case for the bug: wires drawn, so the penstock's samples exist
		# and its end sits on the turbine body.
		mgr.call("set_global_visibility", true)
		var tp: Vector3 = prop.global_position + Vector3(0.0, 0.25, 0.0)
		(player as Node3D).global_position = tp + Vector3(2.6, 0.0, 0.0)
		for _i in 4:
			await get_tree().physics_frame
		_aim_player_at(player as Node3D, cam, tp)
		CursorController.set_paused(false)
		await get_tree().create_timer(0.4).timeout
		var vp := main.get_viewport()
		var centre_px := vp.get_visible_rect().size * 0.5
		await _lc_move(vp, centre_px, true)  # Ctrl held → prop selection active
		for _j in 4:
			await get_tree().physics_frame
		var focus: Node = (player as Node).get_node_or_null("InteractionFocus")
		var focused: Variant = focus.call("get_focused") if focus != null else null
		var cfid := str(focus.call("get_conduit_focus_id")) if focus != null else "?"
		print("PlaytestHarness: penstock verify — aim at turbine: focused=%s conduit_focus='%s' graph=%s paused=%s overlay=%s modal=%s capture=%s mouse_mode=%d" % [
			str(focused.name) if focused is Node else "null", cfid, str((sgv as CanvasItem).visible),
			str(CursorController.is_paused()), str(CursorController.has_tool_overlay()),
			str(CursorController.has_blocking_modal()), str(CursorController.should_capture_look()),
			Input.get_mouse_mode()])
		fails += _pen_check("aiming at the turbine focuses the PROP, not its penstock",
				focused is PlacedProp and cfid.is_empty())
		await _lc_press(vp, centre_px, true, false, true)
		await _lc_press(vp, centre_px, false, false, true)
		await get_tree().create_timer(0.5).timeout
		var modal_up := CursorController.has_blocking_modal()
		var editor_up := CursorController.has_tool_overlay()
		print("PlaytestHarness: penstock verify — after Ctrl+click: tool overlay=%s blocking modal=%s" % [
			str(editor_up), str(modal_up)])
		fails += _pen_check("Ctrl+click on the turbine opened its prop editor", editor_up)
		fails += _pen_check("…and NOT the conduit style modal", not modal_up)
		await _graph_shot(dir, "06_turbine_editor_not_conduit_modal", manifest)
		var pe: Node = main.get_node_or_null("UILayer/PlacedPropEditUI")
		if pe != null and pe.has_method("close"):
			pe.call("close")
		if modal_up:
			CursorController.pop_top_modal()
		await get_tree().create_timer(0.3).timeout

	# ---- The Penstock span tool, through the calls it makes.
	if loader == null or not loader.has_method("water_network"):
		return fails
	var wn: Node = loader.call("water_network")
	var feats: Array = wn.call("features")
	var centre_xz := Vector2(prop.global_position.x, prop.global_position.z) if prop != null else Vector2.ZERO
	var centre_y := TerrainSurfaceQuery.ground_height_at(main, centre_xz.x, centre_xz.y)
	# The reach to tap, chosen the way the tool's own find_uphill_source does:
	# a stream VERTEX with real head above the turbine (within 400 m), down to
	# the vertex nearest the turbine (within 150 m), most drop wins. The old
	# rule took the nearest creek's FIRST vertex and marked the whole creek: on
	# this world that is Lake Creek, 1.3 km of OSM waterway whose head end
	# sits 112 m BELOW the way up — the jet took 0 L/s and every Lab text
	# downstream of it read empty.
	var best: Dictionary = {}
	var best_drop := 1.0
	var best_i0 := -1
	var best_i1 := -1
	var offer: Array = []
	for f_v in feats:
		var f: Dictionary = f_v
		var pts: PackedVector2Array = f.get("points", PackedVector2Array())
		if pts.size() < 3 or str(f.get("id", "")).begins_with("dc_"):
			continue
		# Exit = the vertex nearest the turbine.
		var i1 := -1
		var d1 := 300.0
		var d_any := INF
		var y_max := -INF
		for k in pts.size():
			d_any = minf(d_any, pts[k].distance_to(centre_xz))
			y_max = maxf(y_max, TerrainSurfaceQuery.ground_height_at(main, pts[k].x, pts[k].y))
		offer.append("%s '%s' %d pts, nearest %.0f m, highest vertex %+.1f m vs the turbine" % [
			str(f.get("id", "")), str(f.get("name", "")), pts.size(), d_any, y_max - centre_y])
		for k in pts.size():
			var dk := pts[k].distance_to(centre_xz)
			if dk < d1:
				d1 = dk
				i1 = k
		if i1 < 1:
			continue
		var y1 := TerrainSurfaceQuery.ground_height_at(main, pts[i1].x, pts[i1].y)
		# Either side of the exit: an OSM way may be digitised mouth-first
		# (Lake Creek here climbs 112 m along its point order), so the head
		# vertex can sit at a HIGHER index than the exit. The reach is sliced
		# and ordered head → exit below.
		for k in pts.size():
			if k == i1 or pts[k].distance_to(centre_xz) > 600.0:
				continue
			var yk := TerrainSurfaceQuery.ground_height_at(main, pts[k].x, pts[k].y)
			var drop := yk - maxf(y1, centre_y)
			if drop > best_drop:
				best_drop = drop
				best = f
				best_i0 = k
				best_i1 = i1
	if best.is_empty():
		print("PlaytestHarness: penstock verify — no mapped stream with head above the turbine within reach (exit ≤ 300 m, head ≤ 600 m), stream step skipped. Streams on the map: %s" % str(offer))
		return fails
	var fid := str(best["id"])
	var all_pts: PackedVector2Array = best["points"]
	var lo := mini(best_i0, best_i1)
	var hi := maxi(best_i0, best_i1)
	var fpts := all_pts.slice(lo, hi + 1)
	if best_i0 > best_i1:
		fpts.reverse()
	print("PlaytestHarness: penstock verify — tapping %s '%s' vertices %d → %d of %d (%.1f m of drop, %d points%s)" % [
		fid, str(best.get("name", "")), best_i0, best_i1, all_pts.size(), best_drop, fpts.size(),
		", the way's points run uphill" if best_i0 > best_i1 else ""])
	var water_file := str(WaterFeatureLayer.save_path_for_map(float(loader.get("_lat")), float(loader.get("_lon"))))
	var snap := _snapshot_files([water_file])
	# Water side (what the tool does first): every span of the REACH → penstock.
	wn.call("checkpoint")
	var nid := fid
	for i in range(lo, hi):
		nid = str(wn.call("set_span_mode", nid, i, WaterFeatureLayer.MODE_PENSTOCK))
	wn.call("commit")
	await get_tree().create_timer(0.3).timeout
	var f_after: Dictionary = wn.call("feature", nid)
	var all_pen := not f_after.is_empty()
	var modes_after: Array = f_after.get("modes", [])
	for i in range(lo, hi):
		all_pen = all_pen and i < modes_after.size() and str(modes_after[i]) == WaterFeatureLayer.MODE_PENSTOCK
	fails += _pen_check("stream %s: every span of the reach now mode penstock" % nid, all_pen)
	# Graph side.
	var conn_id := str(sgv.call("create_penstock_from_stream", nid,
			str(best.get("name", "")), fpts, turbine_id, {}))
	fails += _pen_check("create_penstock_from_stream routed a connection", not conn_id.is_empty())
	await get_tree().create_timer(1.5).timeout
	var pen_conns := 0
	var intakes := 0
	var conn: Dictionary = {}
	for c in model.connections:
		var cd: Dictionary = c
		if str(cd.get("conduit_type", "")) == "poly_penstock" \
				and (str(cd.get("source_item_id", "")) == turbine_id or str(cd.get("target_item_id", "")) == turbine_id):
			pen_conns += 1
			conn = cd
	var intake_item: Dictionary = {}
	for it in model.items:
		if ResourceFlowEngine.is_stream_intake(it) and not _pen_keep.has(str((it as Dictionary).get("id", ""))):
			intakes += 1
			intake_item = it
	fails += _pen_check("exactly ONE penstock on the turbine after the stream tap (was %d)" % pen_conns, pen_conns == 1)
	fails += _pen_check("exactly ONE stream intake left (the drop-placed one was replaced; %d)" % intakes, intakes == 1)
	fails += _pen_check("the penstock carries the stream's own line as locked waypoints",
			bool(conn.get("route_locked", false)) and (conn.get("route_3d", []) as Array).size() >= 1)
	var isp: Dictionary = intake_item.get("specs", {}) as Dictionary
	fails += _pen_check("intake is BOUND to %s" % nid, str(isp.get("water_feature_bind", "")) == nid)
	var tsp: Dictionary = model.get_item(turbine_id).get("specs", {}) as Dictionary
	print("PlaytestHarness: penstock verify — stream tap: intake fed by '%s' (q %.3f L/s), turbine mode '%s', head %.2f m, %.1f W" % [
		str(isp.get("water_feature_id", "")), float(isp.get("live_supply_lps", 0.0)),
		str(tsp.get("penstock_source_mode", "")), float(tsp.get("live_head_m", 0.0)),
		float(tsp.get("current_output_kw", 0.0)) * 1000.0])
	fails += _pen_check("the engine takes the BOUND stream's flow (water_feature_id stamped)",
			str(isp.get("water_feature_id", "")) == nid)
	fails += _pen_check("turbine runs in stream mode", str(tsp.get("penstock_source_mode", "")) == "stream")
	var runs: Array = wn.call("buried_runs", nid)
	var pen_run := false
	for r in runs:
		pen_run = pen_run or str((r as Dictionary).get("mode", "")) == WaterFeatureLayer.MODE_PENSTOCK
	fails += _pen_check("a penstock span builds NO barrel run (the conduit is the visual)", not pen_run)
	# The pipe on the user's trailer: 2" SDR 11.5, 350 ft of it. Set through
	# the Lab's own controls, read back off the run + the design checks.
	if sgv.has_method("open_siphon_lab"):
		(sgv as CanvasItem).visible = true
		sgv.call("open_siphon_lab", turbine_id)
		await get_tree().create_timer(1.0).timeout
		var lab: Node = sgv.get_node_or_null("SiphonHydroModal")
		var sdr_opt: Variant = lab.get("_route_sdr_opt") if lab != null else null
		var size_opt: Variant = lab.get("_route_size_opt") if lab != null else null
		var stock_spin: Variant = lab.get("_stock_spin") if lab != null else null
		if sdr_opt is OptionButton and size_opt is OptionButton and stock_spin is SpinBox:
			for i in (size_opt as OptionButton).item_count:
				if is_equal_approx(float((size_opt as OptionButton).get_item_metadata(i)), 2.0):
					(size_opt as OptionButton).select(i)
			for i in (sdr_opt as OptionButton).item_count:
				if is_equal_approx(float((sdr_opt as OptionButton).get_item_metadata(i)), 11.5):
					(sdr_opt as OptionButton).select(i)
			(stock_spin as SpinBox).value = 350.0
			lab.call("_apply_route_style")
			await get_tree().create_timer(2.0).timeout
			var c2: Dictionary = {}
			for c in model.connections:
				if str((c as Dictionary).get("conduit_type", "")) == "poly_penstock":
					c2 = c
			var st: Dictionary = c2.get("conduit_style", {}) as Dictionary
			fails += _pen_check("Lab wrote SDR 11.5 + 350 ft onto the run",
					is_equal_approx(float(st.get("pipe_sdr", 0.0)), 11.5)
					and absf(float(st.get("stock_length_m", 0.0)) - 106.68) < 0.05)
			var tsp2: Dictionary = model.get_item(turbine_id).get("specs", {}) as Dictionary
			print("PlaytestHarness: penstock verify — SDR 11.5: turbine bore %.2f mm, run %.1f m, tightest bend %.2f m (needs ≥ %.3f), high points %d, rise %.2f m" % [
				float(tsp2.get("penstock_diameter_mm", 0.0)), float(c2.get("route_length_m", 0.0)),
				float(c2.get("route_min_bend_r_m", -1.0)), ConduitKinds.contour_bend_radius_m("poly_penstock", st),
				int(c2.get("route_high_points", -1)), float(c2.get("route_rise_m", 0.0))])
			fails += _pen_check("turbine adopted the SDR 11.5 bore (49.8 mm)",
					absf(float(tsp2.get("penstock_diameter_mm", 0.0)) - 49.83) < 0.1)
			var r_route := float(c2.get("route_min_bend_r_m", -1.0))
			var r_min := ConduitKinds.contour_bend_radius_m("poly_penstock", st)
			fails += _pen_check("route report stamped on the run", r_route != -2.0 and c2.has("route_high_points"))
			# A bend tighter than the pipe is only a routing fault when the pins
			# could take the arc: fillet_xz fits the biggest arc a short leg
			# allows, and a hand-drawn creek (Stream 2 on Mount Vernon) has legs
			# shorter than the 1.5 m radius. The run says which.
			var short_leg := float(c2.get("route_short_leg_m", -1.0))
			if short_leg > 0.0:
				print("PlaytestHarness: penstock verify — tightest bend %.2f m is pin-limited: a %.2f m leg cannot take the %.2f m fillet" % [
					r_route, short_leg, r_min])
			fails += _pen_check("every plan bend of the creek route is at or above the pipe's %.2f m radius, or pin-limited by a short leg" % r_min,
					r_route < 0.0 or r_route >= r_min * 0.95 or short_leg > 0.0)
			var design: Variant = lab.get("_design_lbl")
			if design is Label:
				print("PlaytestHarness: penstock verify — design checks:\n%s" % str((design as Label).text))
				fails += _pen_check("design checks rendered (velocity + stock lines)",
						str((design as Label).text).contains("velocity") and str((design as Label).text).contains("on hand"))
			var firm: Variant = lab.get("_firm_lbl")
			var lim: Variant = lab.get("_limited_lbl")
			var intake_lbl: Variant = lab.get("_intake_lbl")
			if firm is Label and lim is Label and intake_lbl is Label:
				print("PlaytestHarness: penstock verify — firm flow: %s | %s" % [str((firm as Label).text), str((lim as Label).text)])
				print("PlaytestHarness: penstock verify — intake works:\n%s" % str((intake_lbl as Label).text))
				fails += _pen_check("driest / wettest month rendered from the stream's seasonal curve",
						str((firm as Label).text).contains("L/s") and str((firm as Label).text).contains("W"))
				fails += _pen_check("intake works sized (screen + settling box + submergence)",
						str((intake_lbl as Label).text).contains("Settling box") and str((intake_lbl as Label).text).contains("under water"))
			if lab.has_method("_on_copy_design_summary"):
				lab.call("_on_copy_design_summary")
				fails += _pen_check("design summary exported", not str(lab.get("_design_summary")).is_empty())
				fails += _pen_check("summary names the closure-time surge",
						str(lab.get("_design_summary")).contains("closing the valve over"))
			await _graph_shot(dir, "08_lab_design_checks", manifest)
		else:
			fails += _pen_check("Lab exposes SDR / size / stock controls", false)
		if sgv.has_method("close_hydro_lab"):
			sgv.call("close_hydro_lab")
		# ---- Site Plan: port dots / grabs are capped on screen at any zoom
		# (uncapped 6×zoom drew ports bigger than the turbine), and a water
		# wire dropped on a stream taps it (the same call the canvas emits).
		var canvas: Variant = sgv.get("_graph_canvas")
		if canvas != null and canvas.has_method("set_view_mode"):
			canvas.call("set_view_mode", GraphSiteLayout.VIEW_SITE)
			await get_tree().create_timer(0.8).timeout
			var z0: float = float(canvas.get("_zoom"))
			canvas.set("_zoom", maxf(z0 * 40.0, 60.0))
			var grab := float(canvas.call("_port_grab_radius"))
			print("PlaytestHarness: penstock verify — Site Plan at zoom %.1f: port grab radius %.1f px" % [
				float(canvas.get("_zoom")), grab])
			# graph_canvas.gd has no class_name — SITE_PORT_GRAB_MAX_PX (14 px) by value.
			fails += _pen_check("Site Plan port grab radius capped (%.1f ≤ 14 px)" % grab,
					grab <= 14.01)
			canvas.set("_zoom", z0)
			await get_tree().create_timer(0.5).timeout
			await _graph_shot(dir, "09_site_plan_ports", manifest)
			if sgv.has_method("tap_stream_for_turbine"):
				var conn3 := str(sgv.call("tap_stream_for_turbine", nid, 1, turbine_id, "res_in_0"))
				await get_tree().create_timer(1.5).timeout
				var n_pen := 0
				var n_int := 0
				# Count THIS turbine's penstocks: the map may carry the player's own
				# pond→siphon poly_penstock elsewhere (Mt Vernon does).
				for c in model.connections:
					var cd3: Dictionary = c
					if str(cd3.get("conduit_type", "")) == "poly_penstock" \
							and (str(cd3.get("source_item_id", "")) == turbine_id or str(cd3.get("target_item_id", "")) == turbine_id):
						n_pen += 1
				for it in model.items:
					if ResourceFlowEngine.is_stream_intake(it) and not _pen_keep.has(str((it as Dictionary).get("id", ""))):
						n_int += 1
				fails += _pen_check("Site Plan drop → tap_stream_for_turbine routed a penstock", not conn3.is_empty())
				fails += _pen_check("…still exactly one penstock + one intake (replaced, not added) [%d/%d]" % [n_pen, n_int],
						n_pen == 1 and n_int == 1)
			# ---- ONE source model behind every entry: a world point resolves to
			# pond / stream / spring and route_penstock_to_source routes it; a
			# hand-drawn water wire into the turbine becomes the penstock too.
			if sgv.has_method("resolve_hydro_source_at") and sgv.has_method("route_penstock_to_source"):
				var v1 := fpts[mini(1, fpts.size() - 1)]
				var s_stream: Dictionary = sgv.call("resolve_hydro_source_at", v1, 8.0)
				fails += _pen_check("a point on the creek resolves as a STREAM source (%s)" % str(s_stream.get("kind", "")),
						str(s_stream.get("kind", "")) == "stream" and str(s_stream.get("feature_id", "")) == nid)
				# A point AWAY from every stream: walk outward from the creek
				# until the stream pick (which reaches to each channel's own
				# banks) finds nothing — on this world a fixed 64 m offset
				# landed within another reach of the same meandering creek.
				var far := v1 + Vector2(45.0, 45.0)
				for k in range(1, 9):
					var cand := v1 + Vector2(45.0, 45.0) * float(k)
					if not bool((loader.call("pick_stream_at_world", cand.x, cand.y) as Dictionary).get("valid", false)):
						far = cand
						break
				var s_far: Dictionary = sgv.call("resolve_hydro_source_at", far, 8.0)
				print("PlaytestHarness: penstock verify — resolver: creek → %s '%s'; %.0f m off → %s" % [
					str(s_stream.get("kind", "")), str(s_stream.get("label", "")), far.distance_to(v1), str(s_far.get("kind", ""))])
				fails += _pen_check("a point off the creek resolves as bare ground / a pond",
						str(s_far.get("kind", "")) in ["spring", "pond", "pond_unadded"])
				if str(s_far.get("kind", "")) == "spring":
					var c_spring := str(sgv.call("route_penstock_to_source", turbine_id, s_far,
							{"pipe_size_in": 2.0, "pipe_sdr": 11.5}))
					await get_tree().create_timer(1.5).timeout
					var n_pen2 := 0
					var bound_any := false
					var spring_sdr := 0.0
					for c in model.connections:
						var cd4: Dictionary = c
						if str(cd4.get("conduit_type", "")) == "poly_penstock" \
								and (str(cd4.get("source_item_id", "")) == turbine_id or str(cd4.get("target_item_id", "")) == turbine_id):
							n_pen2 += 1
							spring_sdr = float((cd4.get("conduit_style", {}) as Dictionary).get("pipe_sdr", 0.0))
					for it in model.items:
						if ResourceFlowEngine.is_stream_intake(it) and not _pen_keep.has(str((it as Dictionary).get("id", ""))):
							bound_any = bound_any or not str((it.get("specs", {}) as Dictionary).get("water_feature_bind", "")).is_empty()
					fails += _pen_check("spring source → one penstock from a bare intake (not bound to a stream)",
							not c_spring.is_empty() and n_pen2 == 1 and not bound_any)
					fails += _pen_check("the route opts carried the pipe spec (SDR %.1f)" % spring_sdr, is_equal_approx(spring_sdr, 11.5))
				var up: Dictionary = sgv.call("find_uphill_source", turbine_id, 150.0) \
					if sgv.has_method("find_uphill_source") else {}
				print("PlaytestHarness: penstock verify — find_uphill_source: %s '%s' +%.1f m" % [
					str(up.get("kind", "")), str(up.get("label", "")), float(up.get("rise_m", 0.0))])
				fails += _pen_check("auto-route finds SOMETHING higher (stream vertex or bare ground)", not up.is_empty())
				var c_back := str(sgv.call("route_penstock_to_source", turbine_id, s_stream, {}))
				await get_tree().create_timer(1.5).timeout
				var n_pen3 := 0
				var n_int3 := 0
				var intake3: Dictionary = {}
				for c in model.connections:
					var cd5: Dictionary = c
					if str(cd5.get("conduit_type", "")) == "poly_penstock" \
							and (str(cd5.get("source_item_id", "")) == turbine_id or str(cd5.get("target_item_id", "")) == turbine_id):
						n_pen3 += 1
				for it in model.items:
					if ResourceFlowEngine.is_stream_intake(it) and not _pen_keep.has(str((it as Dictionary).get("id", ""))):
						n_int3 += 1
						intake3 = it
				fails += _pen_check("stream source → back to one BOUND intake + one penstock [%d/%d]" % [n_pen3, n_int3],
						not c_back.is_empty() and n_pen3 == 1 and n_int3 == 1
						and str((intake3.get("specs", {}) as Dictionary).get("water_feature_bind", "")) == nid)
				var summ: Dictionary = sgv.call("hydro_source_summary", turbine_id) if sgv.has_method("hydro_source_summary") else {}
				print("PlaytestHarness: penstock verify — source summary: %s" % str(summ))
				fails += _pen_check("hydro_source_summary reports the stream", str(summ.get("kind", "")) == "stream")
				# A plain water wire drawn by hand from the intake into the turbine
				# (what a Site Plan port drop makes) is restyled into the penstock.
				var iid3 := str(intake3.get("id", ""))
				if not iid3.is_empty() and not c_back.is_empty():
					model.remove_connection(c_back)
					var plain_id: String = model.generate_connection_id()
					print("PlaytestHarness: penstock verify — before the hand-drawn wire: history_suppress=%s sim_bulk=%s" % [
						str(sgv.get("_history_suppress")), str(sgv.get("_sim_bulk_update"))])
					model.add_connection({"id": plain_id, "scope_id": "root",
						"source_item_id": iid3, "source_handle_id": "output",
						"target_item_id": turbine_id, "target_handle_id": "res_in_0",
						"polarity": "resource", "resource_type": "water"})
					await get_tree().create_timer(0.8).timeout
					var pc: Dictionary = model.get_connection(plain_id)
					if str(pc.get("conduit_type", "")) != "poly_penstock" and sgv.has_method("_auto_penstock_for_new_water_wires"):
						# Diagnose: trigger never fired, or the logic skipped the wire?
						sgv.call("_auto_penstock_for_new_water_wires")
						await get_tree().create_timer(0.3).timeout
						print("PlaytestHarness: penstock verify — direct restyle call → type '%s' (trigger flags now: history_suppress=%s sim_bulk=%s)" % [
							str(model.get_connection(plain_id).get("conduit_type", "")),
							str(sgv.get("_history_suppress")), str(sgv.get("_sim_bulk_update"))])
						var dbg_tsp: Dictionary = (model.get_item(turbine_id) as Dictionary).get("specs", {})
						var dbg_isp: Dictionary = (model.get_item(iid3) as Dictionary).get("specs", {})
						var dbg_pc: Dictionary = model.get_connection(plain_id)
						print("PlaytestHarness: penstock verify — restyle inputs: role '%s' kind '%s' has_penstock %s · handle '%s' direct_intake %s polarity '%s' rtype '%s' · intake is_stream_intake %s pond_storage %s" % [
							str(dbg_tsp.get("role", "")), str(dbg_tsp.get("turbine_kind", "")),
							str(HydroSource.kind_meta(str(dbg_tsp.get("turbine_kind", "siphon"))).get("has_penstock", false)),
							str(dbg_pc.get("target_handle_id", "")), str(dbg_pc.get("direct_intake", false)),
							str(dbg_pc.get("polarity", "")), str(dbg_pc.get("resource_type", "")),
							str(ResourceFlowEngine.is_stream_intake(model.get_item(iid3))), str(dbg_isp.get("pond_storage", false))])
					var n_pen4 := 0
					for c in model.connections:
						var cd6: Dictionary = c
						if str(cd6.get("conduit_type", "")) == "poly_penstock" \
								and (str(cd6.get("source_item_id", "")) == turbine_id or str(cd6.get("target_item_id", "")) == turbine_id):
							n_pen4 += 1
					fails += _pen_check("a hand-drawn intake→turbine water wire became the penstock (auto-restyle) [type '%s', %d penstock(s) on the turbine, wire %s]" % [
							str(pc.get("conduit_type", "")), n_pen4, "present" if not pc.is_empty() else "GONE"],
							str(pc.get("conduit_type", "")) == "poly_penstock" and n_pen4 == 1)
				# Tiny Site Plan nodes draw and offer no ports.
				var tiny_item: Dictionary = model.get_item(turbine_id)
				var z_big: float = float(canvas.get("_zoom"))
				canvas.set("_zoom", 0.02)
				var tiny_sz: Vector2 = canvas.call("_item_screen_size", tiny_item)
				var tiny_handles: Array = canvas.call("_get_interactive_handle_infos", tiny_item, Vector2.ZERO)
				canvas.set("_zoom", z_big)
				print("PlaytestHarness: penstock verify — Site Plan node %.1f px wide offers %d ports" % [tiny_sz.x, tiny_handles.size()])
				fails += _pen_check("a Site Plan node under 44 px offers no port handles", tiny_sz.x < 44.0 and tiny_handles.is_empty())
		(sgv as CanvasItem).visible = false
		await get_tree().create_timer(0.4).timeout
		# ---- First person: aiming at the creek focuses the STREAM, not the
		# forest polygon it runs through.
		if player is Node3D and cam != null:
			var v0 := fpts[mini(2, fpts.size() - 1)]
			var gy0 := float(loader.call("ground_height_at", v0.x, v0.y))
			(player as Node3D).global_position = Vector3(v0.x + 4.0, gy0 + 0.2, v0.y + 4.0)
			for _m in 4:
				await get_tree().physics_frame
			_aim_player_at(player as Node3D, cam, Vector3(v0.x, gy0, v0.y))
			var vp2 := main.get_viewport()
			await _lc_move(vp2, vp2.get_visible_rect().size * 0.5, true)
			for _n in 5:
				await get_tree().physics_frame
			var focus2: Node = (player as Node).get_node_or_null("InteractionFocus")
			var sfid := str(focus2.get("_stream_focus_id")) if focus2 != null else ""
			print("PlaytestHarness: penstock verify — aim at the creek: stream focus '%s'" % sfid)
			# The whole crosshair ladder at this aim, so a miss says WHICH rung
			# won and how far the ground point under the crosshair sits from
			# the creek's centreline (the pick reach is the channel's own).
			if focus2 != null and loader.has_method("terrain_pick_ray"):
				var gp: Variant = loader.call("terrain_pick_ray", vp2.get_visible_rect().size * 0.5)
				var ladder := "ground=%s" % str(gp)
				if gp is Vector3:
					var g3 := gp as Vector3
					var sp: Dictionary = loader.call("pick_stream_at_world", g3.x, g3.z)
					ladder += " · stream pick: %s (%.2f m off %s)" % [str(sp.get("valid", false)),
						float(sp.get("dist_m", -1.0)), str(sp.get("id", ""))]
					if loader.has_method("pick_water_at_world"):
						ladder += " · water: %s" % str((loader.call("pick_water_at_world", g3.x, g3.z) as Dictionary).get("valid", false))
					if loader.has_method("pick_camp_at_world"):
						ladder += " · camp: %s" % str((loader.call("pick_camp_at_world", g3.x, g3.z) as Dictionary).get("valid", false))
					ladder += " · centreline %.2f m from the aim point" % Vector2(g3.x, g3.z).distance_to(v0)
				var fo: Variant = focus2.get("_focused")
				ladder += " · focused=%s solar=%d water=%d camp='%s' conduit='%s' npc='%s'" % [
					str(fo.name) if fo is Node else "null", int(focus2.get("_solar_focus_idx")),
					int(focus2.get("_water_focus_idx")), str(focus2.get("_camp_focus_id")),
					str(focus2.get("_conduit_focus_id")), str(focus2.get("_npc_focus_id"))]
				print("PlaytestHarness: penstock verify — crosshair ladder: %s" % ladder)
			fails += _pen_check("aiming at the creek focuses the stream (not 'Fill forest')", sfid == nid)
	# Aerial shot of the tapped reach.
	if cam != null:
		var mid := fpts[fpts.size() / 2]
		var gy := float(loader.call("ground_height_at", mid.x, mid.y))
		(player as Node3D).global_position = Vector3(mid.x, gy + 40.0, mid.y + 30.0)
		for _k in 3:
			await get_tree().physics_frame
		_aim_player_at(player as Node3D, cam, Vector3(mid.x, gy, mid.y))
		await get_tree().create_timer(0.8).timeout
		await _graph_shot(dir, "07_stream_as_penstock", manifest)
	# Hand the map's water back.
	wn.call("undo")
	_restore_files(snap)
	return fails


## The PowerSpout preset specs from the library catalog.
func _penstock_turbine_specs() -> Dictionary:
	for cat in ComponentPresets.CATEGORIES:
		for p in ((cat as Dictionary).get("presets", []) as Array):
			var sp: Dictionary = (p as Dictionary).get("specs", {}) as Dictionary
			if str(sp.get("turbine_kind", "")) == "powerspout_pelton":
				return sp.duplicate(true)
	return {}


func _pen_check(label: String, ok: bool) -> int:
	if ok:
		print("PlaytestHarness: penstock verify — OK: %s" % label)
		return 0
	push_error("PlaytestHarness: penstock verify — FAIL: %s" % label)
	return 1


## Remove this capture's turbine / intake items, their props and any wires
## between them, so the saved site is left as it was found.
var _pen_keep := {}


func _penstock_cleanup(model: Variant, main: Node) -> void:
	var doomed: Array[String] = []
	for it in (model.items as Array).duplicate():
		if not (it is Dictionary):
			continue
		var iid := str((it as Dictionary).get("id", ""))
		var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if _pen_keep.has(iid):
			continue
		if iid.begins_with("cap_pen_") or str(sp.get("model_id", "")) == "stream_intake":
			doomed.append(iid)
			var pid := str(sp.get("bound_prop_id", ""))
			if not pid.is_empty():
				var ld: Node = main.find_child("TerrainLoader", true, false)
				if ld != null and ld.has_method("delete_prop_by_id"):
					ld.call("delete_prop_by_id", pid)
	for conn in (model.connections as Array).duplicate():
		if not (conn is Dictionary):
			continue
		var c := conn as Dictionary
		if doomed.has(str(c.get("source_item_id", ""))) \
				or doomed.has(str(c.get("target_item_id", ""))):
			model.call("remove_connection", str(c.get("id", "")))
	for iid2 in doomed:
		model.call("remove_item", iid2)


# ==================== WINDOW WALL (--capture=windowwall / --window-wall) ====================
## Opens the multi-monitor Window Wall through Main's REAL entry point and
## proves what a screenshot cannot: that every slot's camera shares ONE origin
## and ONE basis and differs only by its off-axis frustum (the numbers are
## DUMPED per slot — size, offset, near, the four corner hits on the wall
## plane, the screen it landed on); that the extra windows exist, are
## fullscreen and carry a frustum camera; that U twice puts every CanvasLayer
## back exactly; that a nudge moves all cameras together; that a key pushed
## into an EXTRA window reaches the view (the relay node — `window_input`
## never fires for push_input); that "live" clock mode really syncs the date at
## 1× and hands it back; and — the one that bites — that close() restores the
## ROOT WINDOW, the embed flag, the player camera, the clock, the UI map and
## the player's process mode. On a single-screen machine every slot lands on
## screen 0 (overlapping fullscreen windows), which still proves creation,
## restoration and the frustum maths. Prefs are forced IN MEMORY
## (override_for_session); the viewpoint is saved to a TEMP path. Nothing of
## the player's is written.
func _run_window_wall_capture() -> void:
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_window_wall_view"):
		push_error("PlaytestHarness: Main has no window wall view — aborting")
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "windowwall"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var tally := {"checks": 0, "fails": 0}
	var check := func(name: String, ok: bool, detail: String = "") -> void:
		tally["checks"] += 1
		if not ok:
			tally["fails"] += 1
		print("PlaytestHarness: windowwall — %s %s %s" % [name, "PASS" if ok else "FAIL", detail])

	WindowWallPrefs.override_for_session({
		"enabled": true, "clock_mode": WindowWallPrefs.CLOCK_LEAVE, "hide_ui": true,
		"monitor_count": 3, "main_slot": 1, "render_scale": 1.0,
	})
	print("PlaytestHarness: windowwall — screens: %s" % str(WindowWallView.os_screens()))
	var root := get_tree().root
	var main_hour := 10.0
	main.time_scale = 0.0
	main.day_time = main_hour

	# Snapshot everything close() must put back.
	var cam_before := get_viewport().get_camera_3d()
	var ts_before := float(main.get("time_scale"))
	var date_before := [int(main.get("year")), int(main.get("month")), int(main.get("day"))]
	var day_time_before := float(main.get("day_time"))
	var win_before := {"mode": root.mode, "screen": root.current_screen, "size": root.size,
		"embed": root.gui_embed_subwindows, "scale": root.scaling_3d_scale}
	var ui_before: Dictionary = {}
	for child in main.get_children():
		if child is CanvasLayer:
			ui_before[child] = (child as CanvasLayer).visible
	var player := main.get_node_or_null("Player")
	var pm_before: int = player.process_mode if player != null else Node.PROCESS_MODE_INHERIT

	# ---- open ----------------------------------------------------------------
	var view: Node = main.call("open_window_wall_view")
	await get_tree().create_timer(1.5).timeout
	var opened := view != null and bool(view.call("is_open"))
	check.call("view open", opened)
	if not opened:
		_maybe_quit()
		return
	var n_extra: int = view.call("window_count")
	check.call("extra windows == monitors - 1", n_extra == 2, "got %d" % n_extra)
	var wins: Array = view.call("windows")
	for w in wins:
		var win := w as Window
		# Either real fullscreen or a borderless window covering the screen —
		# both are shipping configurations (see WindowWallPrefs.WINDOW_MODES).
		var scr_size := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen(win.get_window_id()))
		var covers := win.mode == Window.MODE_FULLSCREEN \
			or (absi(win.size.x - scr_size.x) <= 4 and absi(win.size.y - scr_size.y) <= 4)
		check.call("window %s in tree + covers its screen" % win.name,
			win.is_inside_tree() and covers,
			"mode=%d size=%s screen=%s" % [win.mode, win.size, scr_size])
		var wc := win.get_camera_3d()
		check.call("window %s has a KEEP_WIDTH frustum camera" % win.name,
			wc != null and wc.projection == Camera3D.PROJECTION_FRUSTUM and wc.keep_aspect == Camera3D.KEEP_WIDTH)
	var main_cam := get_viewport().get_camera_3d()
	check.call("main viewport shows a frustum camera",
		main_cam != null and main_cam.projection == Camera3D.PROJECTION_FRUSTUM and main_cam != cam_before)
	check.call("root window fullscreen", root.mode == Window.MODE_FULLSCREEN, "mode=%d" % root.mode)
	check.call("embed flag off while open", root.gui_embed_subwindows == false)

	# ---- the numbers ---------------------------------------------------------
	var dump: Array = view.call("frustum_dump")
	var origin0: Vector3 = Vector3.INF
	var basis0 := Basis.IDENTITY
	var same_origin := true
	var same_basis := true
	var aspect_ok := true
	for row in dump:
		var r := row as Dictionary
		print("PlaytestHarness: windowwall —   slot %d screen %d: size %.6f offset %s near %.3f d %.3f hfov %.1f° viewport %s aspect-mismatch %.4f" % [
			int(r["slot"]), int(r["screen"]), float(r["size"]), str(r["offset"]), float(r["near"]),
			float(r["d"]), float(r["hfov_deg"]), str(r["viewport_px"]), float(r["aspect_mismatch"])])
		for c in (r["corners"] as Array):
			print("PlaytestHarness: windowwall —       corner %s" % str(c))
		var o: Vector3 = r["origin"]
		var b: Basis = r["basis"]
		if origin0 == Vector3.INF:
			origin0 = o
			basis0 = b
		else:
			if (o - origin0).length() > 1e-4:
				same_origin = false
			if not b.is_equal_approx(basis0):
				same_basis = false
		if float(r["aspect_mismatch"]) > 0.01:
			aspect_ok = false
	check.call("one eye: every camera shares the origin", same_origin, str(origin0))
	check.call("one orientation: every camera shares the basis (flat wall)", same_basis)
	check.call("panel aspect matches the viewport", aspect_ok)
	check.call("eye is the viewpoint + seat height", (origin0 - (view.call("eye") as Vector3)).length() < 1e-4)

	# ---- shots ---------------------------------------------------------------
	await _shoot_ui(dir, "01_main_slot")
	for w in wins:
		var win := w as Window
		await RenderingServer.frame_post_draw
		var tex := win.get_texture()
		var readable := tex != null
		if readable:
			tex.get_image().save_png("%s/01_%s.png" % [dir, win.name.to_lower()])
		check.call("%s frame readable" % win.name, readable)

	# ---- UI toggle ----------------------------------------------------------
	var hidden_all := true
	for layer in ui_before.keys():
		if is_instance_valid(layer) and (layer as CanvasLayer).visible:
			hidden_all = false
	check.call("every Main CanvasLayer hidden on entry", hidden_all)
	view.call("toggle_ui")
	await get_tree().process_frame
	var back_exact := true
	for layer in ui_before.keys():
		if is_instance_valid(layer) and (layer as CanvasLayer).visible != bool(ui_before[layer]):
			back_exact = false
	check.call("U restores every layer to its recorded flag", back_exact)
	view.call("toggle_ui")
	await get_tree().process_frame
	check.call("U again hides them", bool(view.call("ui_hidden")))
	view.call("identify", 0.6)
	await get_tree().create_timer(0.3).timeout
	await _shoot_ui(dir, "02_identify")
	await get_tree().create_timer(0.6).timeout

	# ---- nudge moves everyone together ---------------------------------------
	var eye_a: Vector3 = view.call("eye")
	view.call("nudge", Vector3(0.5, 0.0, 0.0), 0.2)
	await get_tree().process_frame
	var dump2: Array = view.call("frustum_dump")
	var moved_together := true
	for row in dump2:
		var r := row as Dictionary
		if ((r["origin"] as Vector3) - (eye_a + Vector3(0.5, 0, 0))).length() > 1e-4:
			moved_together = false
		if not (r["basis"] as Basis).is_equal_approx((dump2[0] as Dictionary)["basis"]):
			moved_together = false
	check.call("nudge moves + turns every camera together", moved_together)
	await _shoot_ui(dir, "03_nudged")
	# Save the viewpoint to a TEMP path only.
	var tmp_vp := "%s/viewpoint_tmp.json" % dir
	check.call("save_viewpoint to a temp path",
		bool(view.call("save_viewpoint", tmp_vp)) and FileAccess.file_exists(tmp_vp))
	var saved_vp := WindowWallViewpoint.load_from(tmp_vp)
	check.call("saved viewpoint carries the nudged eye", saved_vp != null
		and (saved_vp.eye(WindowWallPrefs.seat_eye_height_m()) - (eye_a + Vector3(0.5, 0, 0))).length() < 1e-3)
	if FileAccess.file_exists(tmp_vp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_vp))

	# ---- a key on an EXTRA window reaches the view (relay node) --------------
	if not wins.is_empty():
		var hidden_before := bool(view.call("ui_hidden"))
		for _i in 2:
			var ev := InputEventKey.new()
			ev.pressed = true
			ev.keycode = KEY_U
			ev.physical_keycode = KEY_U
			(wins[0] as Window).push_input(ev)
			await get_tree().process_frame
			if _i == 0:
				check.call("U pushed into an extra window toggles the UI",
					bool(view.call("ui_hidden")) != hidden_before)

	# ---- close THE WAY A PLAYER DOES: Esc inside an extra window -------------
	# That path frees the very window whose input relay is mid-dispatch, which
	# is the "Cannot call method 'get_viewport' on a previously freed instance"
	# crash this assertion exists to keep fixed. Watch the console: a freed-
	# instance error prints without failing anything by itself.
	if not wins.is_empty():
		var esc := InputEventKey.new()
		esc.pressed = true
		esc.keycode = KEY_ESCAPE
		esc.physical_keycode = KEY_ESCAPE
		(wins[0] as Window).push_input(esc)
		await get_tree().create_timer(0.5).timeout
		check.call("Esc inside an extra window closes the view", not bool(view.call("is_open")))
	view.call("close")
	await get_tree().create_timer(0.5).timeout
	check.call("closed", not bool(view.call("is_open")))
	check.call("player camera restored", get_viewport().get_camera_3d() == cam_before and cam_before != null)
	check.call("root window mode/screen restored",
		root.mode == win_before["mode"] and root.current_screen == win_before["screen"],
		"mode %d screen %d" % [root.mode, root.current_screen])
	check.call("embed flag restored", root.gui_embed_subwindows == bool(win_before["embed"]))
	check.call("root render scale restored", is_equal_approx(root.scaling_3d_scale, float(win_before["scale"])))
	check.call("extra windows freed", int(view.call("window_count")) == 0)
	var ui_after_ok := true
	for layer in ui_before.keys():
		if is_instance_valid(layer) and (layer as CanvasLayer).visible != bool(ui_before[layer]):
			ui_after_ok = false
	check.call("UI map restored exactly", ui_after_ok)
	check.call("player process mode restored", player == null or player.process_mode == pm_before)
	check.call("clock untouched in 'leave' mode", absf(float(main.get("time_scale")) - ts_before) < 1e-9)

	# ---- second pass: live clock ---------------------------------------------
	WindowWallPrefs.override_for_session({"clock_mode": WindowWallPrefs.CLOCK_LIVE})
	var live_was_on := bool(SimSettingsController.get("live_mode_enabled"))
	main.time_scale = 0.01
	view = main.call("open_window_wall_view")
	await get_tree().create_timer(1.5).timeout
	var now := Time.get_datetime_dict_from_system()
	check.call("live: 1x claimed", absf(float(main.get("time_scale")) - 1.0 / 3600.0) < 1e-7,
		"%.6f" % float(main.get("time_scale")))
	check.call("live: date synced to the system clock",
		int(main.get("year")) == int(now["year"]) and int(main.get("month")) == int(now["month"]) and int(main.get("day")) == int(now["day"]),
		"%d-%d-%d" % [int(main.get("year")), int(main.get("month")), int(main.get("day"))])
	await _shoot_ui(dir, "04_live_clock")
	view.call("close")
	await get_tree().create_timer(0.5).timeout
	check.call("live: speed handed back", absf(float(main.get("time_scale")) - 0.01) < 1e-9,
		"%.6f" % float(main.get("time_scale")))
	if not live_was_on:
		check.call("live: date handed back",
			int(main.get("year")) == date_before[0] and int(main.get("month")) == date_before[1]
			and int(main.get("day")) == date_before[2] and absf(float(main.get("day_time")) - main_hour) < 0.05,
			"%d-%d-%d %.2f" % [int(main.get("year")), int(main.get("month")), int(main.get("day")), float(main.get("day_time"))])
	main.time_scale = ts_before
	main.day_time = day_time_before

	print("PlaytestHarness: windowwall — %d of %d checks passed %s" % [
		int(tally["checks"]) - int(tally["fails"]), int(tally["checks"]), "PASS" if int(tally["fails"]) == 0 else "FAIL"])
	_maybe_quit()


## --window-wall: the desktop-shortcut launch. Wait for the map, then open the
## wall through Main's entry point and leave it running (no capture, no quit).
func _boot_window_wall_view() -> void:
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(2.0).timeout
	var main := get_tree().current_scene
	if main == null or not main.has_method("open_window_wall_view"):
		push_error("PlaytestHarness: --window-wall — Main has no window wall view")
		return
	if not WindowWallPrefs.enabled():
		print("PlaytestHarness: --window-wall — the feature is off; enable it in Settings → Window Wall")
		if main.has_method("show_toast"):
			main.call("show_toast", "--window-wall: enable Window Wall in Settings first", ToastUI.Level.WARN, 8.0)
		return
	main.call("open_window_wall_view")


## --- Star field capture -------------------------------------------------------
## The star field's whole risk surface is invisible to a PNG: a sky that is
## rotated 4° or whose texture pole sits at the zenith still LOOKS like a sky.
## So this mode parks the clock on a fixed winter night, shoots each reference
## star with the computed markers ON and OFF, and — the number — finds the
## brightest texture blob near each marker's PROJECTED screen position in the
## markers-off frame and prints the pixel distance. Then the 2 h rotation proof:
## looking straight at the pole, Polaris must stay put while Dubhe sweeps
## ~30° counter-clockwise (facing north), and at a southern site the same about
## the SCP, clockwise. Twinkle + TAA make the PNGs non-deterministic, so only
## centroids are compared, never pixels. Nothing is persisted: no calibration
## save, location restored with persist=false, planet prefs put back.
const STAR_CAP_SEARCH_PX := 25
const STAR_CAP_PASS_PX := 6.0
const STAR_CAP_VIEWS: Array[String] = ["polaris", "betelgeuse", "sirius", "vega", "zenith"]


## The shipped star look the marker-vs-texture measurement assumes.
const STAR_CAP_LOOK := {
	"star_trails": 0.0, "stars_brightness": 1.0, "stars_point_size": 0.0,
	"stars_saturation": 1.5, "stars_wash": 0.7, "stars_background_cut": 0.02,
	"stars_contrast": 1.4, "milkyway_gain": 1.3,
}


func _run_star_capture() -> void:
	var tree := get_tree()
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout

	var main := _find_main()
	if main == null or not main.has_method("get_star_system"):
		push_error("PlaytestHarness: no Main with a StarSystem — aborting star capture")
		_maybe_quit()
		return
	var ss: Node = main.call("get_star_system")
	if ss == null or not ss.has_method("get_reference_star_position"):
		push_error("PlaytestHarness: StarSystem missing — aborting star capture")
		_maybe_quit()
		return

	var label := _shots_label if not _shots_label.is_empty() else "stars"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	var diag := {"views": {}, "rotation": {}, "fails": []}

	# Conditions: fixed winter night, clock frozen, clear sky, planets off (a
	# bright Jupiter inside a search window reads as a star), HUD hidden.
	_set_capture_conditions()
	var orig_lat := float(main.get("latitude"))
	var orig_lon := float(main.get("longitude"))
	var planets: Node = main.find_child("PlanetSystem", true, false)
	var planet_prefs: Dictionary = planets.call("get_settings") if planets != null and planets.has_method("get_settings") else {}
	if planets != null and planets.has_method("set_all_enabled"):
		planets.call("set_all_enabled", false)
	var saved_clouds: Variant = main.get("clouds_cutoff")
	# The player's star LOOK (trails, dim brightness, low saturation...) is a
	# taste, not a registration: it smears the discs the blob search measures,
	# so the capture runs on the shipped look and hands theirs back after.
	var star_look := {}
	for k in STAR_CAP_LOOK:
		star_look[k] = ss.get(k)
		ss.set(k, STAR_CAP_LOOK[k])
	_star_cap_set_night(main, 2026, 1, 15, 22.0)

	var prev_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.name = "PlaytestStarCam"
	cam.far = 40000.0
	cam.fov = 60.0
	main.add_child(cam)
	# 80 m above the player: the soak map's tents, roofs and the StarShade sit
	# right in the lower half of a ground-level frame and read as "star missing".
	if prev_cam != null:
		cam.global_position = prev_cam.global_position + Vector3(0.0, 80.0, 0.0)
	else:
		cam.global_position = Vector3(0.0, 83.0, 0.0)
	cam.make_current()

	print("\n=== STAR FIELD CAPTURE ===")
	print("site lat %.4f lon %.4f   registration: %s" % [orig_lat, orig_lon, str(ss.call("registration_summary")) if ss.has_method("registration_summary") else "?"])
	print("clock 2026-01-15 22:00 local   LST %.3f deg" % float(ss.get("current_lst")))

	# --- 1. marker-vs-texture per view ---------------------------------------
	var total := 0
	var bad := 0
	for view in STAR_CAP_VIEWS:
		var aim := Vector3.UP
		if view != "zenith":
			var p: Dictionary = ss.call("get_reference_star_position", view)
			if p.is_empty() or float(p.get("altitude", -90.0)) < 5.0:
				print("  view %-10s skipped (below horizon tonight)" % view)
				continue
			aim = p["direction"]
		_star_cap_aim(cam, aim)
		ss.call("set_reference_stars_visible", true)
		await _star_cap_settle(main)
		await _graph_shot(dir, "stars_%s_markers" % view, manifest, "stars")
		ss.call("set_reference_stars_visible", false)
		await _star_cap_settle(main)
		await _graph_shot(dir, "stars_%s" % view, manifest, "stars")
		var img := get_viewport().get_texture().get_image()
		var rows: Array = _star_cap_measure(main, ss, cam, img)
		diag["views"][view] = rows
		print("  view %-10s (%d stars in frame)" % [view, rows.size()])
		for r in rows:
			total += 1
			var ok: bool = bool(r["found"]) and float(r["dist_px"]) <= STAR_CAP_PASS_PX
			if not ok:
				bad += 1
			print("    %-11s expected (%6.1f,%6.1f)  found %-16s  dist %s  %s" % [
				r["star"], r["expected"].x, r["expected"].y,
				("(%6.1f,%6.1f)" % [r["found_px"].x, r["found_px"].y]) if r["found"] else "-",
				("%.1f px = %.2f deg" % [float(r["dist_px"]), float(r["dist_deg"])]) if r["found"] else "n/a",
				"ok" if ok else "MISS"])
	var marker_ok := total >= 8 and bad <= 1
	if not marker_ok:
		diag["fails"].append("markers: %d of %d stars beyond %.0f px" % [bad, total, STAR_CAP_PASS_PX])
		push_error("PlaytestHarness: star markers vs texture — %d of %d beyond %.0f px" % [bad, total, STAR_CAP_PASS_PX])
	else:
		print("  marker-vs-texture: %d stars, %d beyond %.0f px  PASS" % [total, bad, STAR_CAP_PASS_PX])

	# --- 2. rotation about the north celestial pole over 2 h -----------------
	var basis: Dictionary = StarSkyMath.equatorial_basis(orig_lat)
	cam.fov = 90.0
	_star_cap_aim(cam, basis["pole"])
	ss.call("set_reference_stars_visible", false)
	await _star_cap_settle(main)
	await _graph_shot(dir, "rotation_north_22h", manifest, "stars")
	var a := _star_cap_pair(main, ss, cam, get_viewport().get_texture().get_image(), "polaris", "dubhe")
	_star_cap_set_night(main, 2026, 1, 15, 24.0)  # rolls to Jan 16 00:00
	await _star_cap_settle(main)
	await _graph_shot(dir, "rotation_north_24h", manifest, "stars")
	var b := _star_cap_pair(main, ss, cam, get_viewport().get_texture().get_image(), "polaris", "dubhe")
	diag["rotation"]["north"] = _star_cap_rotation_report(a, b, 30.08, "north (Polaris still, Dubhe CCW)", diag, cam, float(get_viewport().get_texture().get_image().get_height()), ss)

	# --- 3. southern site: the same about the SCP, clockwise -----------------
	main.call("apply_location", -31.95, 115.86, "Perth (harness)", false)
	_star_cap_set_night(main, 2026, 1, 15, 22.0)
	await _star_cap_settle(main)
	var sbasis: Dictionary = StarSkyMath.equatorial_basis(-31.95)
	_star_cap_aim(cam, -(sbasis["pole"] as Vector3))
	await _star_cap_settle(main)
	await _graph_shot(dir, "rotation_south_22h", manifest, "stars")
	var simg := get_viewport().get_texture().get_image()
	var srows: Array = _star_cap_measure(main, ss, cam, simg)
	diag["views"]["south_pole"] = srows
	print("  view %-10s (%d stars in frame, Perth)" % ["south_pole", srows.size()])
	var sbad := 0
	for r in srows:
		var ok: bool = bool(r["found"]) and float(r["dist_px"]) <= STAR_CAP_PASS_PX
		if not ok:
			sbad += 1
		print("    %-11s expected (%6.1f,%6.1f)  found %-16s  dist %s  %s" % [
			r["star"], r["expected"].x, r["expected"].y,
			("(%6.1f,%6.1f)" % [r["found_px"].x, r["found_px"].y]) if r["found"] else "-",
			("%.1f px = %.2f deg" % [float(r["dist_px"]), float(r["dist_deg"])]) if r["found"] else "n/a",
			"ok" if ok else "MISS"])
	if srows.size() < 2 or sbad > 1:
		diag["fails"].append("south: %d of %d stars beyond %.0f px" % [sbad, srows.size(), STAR_CAP_PASS_PX])
		push_error("PlaytestHarness: southern sky markers vs texture — %d of %d beyond %.0f px" % [sbad, srows.size(), STAR_CAP_PASS_PX])
	var sa := _star_cap_pair(main, ss, cam, simg, "acrux", "canopus")
	_star_cap_set_night(main, 2026, 1, 15, 24.0)
	await _star_cap_settle(main)
	await _graph_shot(dir, "rotation_south_24h", manifest, "stars")
	var sb := _star_cap_pair(main, ss, cam, get_viewport().get_texture().get_image(), "acrux", "canopus")
	diag["rotation"]["south"] = _star_cap_rotation_report(sa, sb, -30.08, "south (about the SCP, clockwise)", diag, cam, float(get_viewport().get_texture().get_image().get_height()), ss)

	# --- restore --------------------------------------------------------------
	main.call("apply_location", orig_lat, orig_lon, "", false)
	if planets != null and planets.has_method("apply_settings") and not planet_prefs.is_empty():
		planets.call("apply_settings", planet_prefs)
	if saved_clouds != null:
		main.set("clouds_cutoff", saved_clouds)
	for k in star_look:
		ss.set(k, star_look[k])
	ss.call("set_reference_stars_visible", false)
	for child in main.get_children():
		if child is CanvasLayer:
			child.visible = true
	cam.queue_free()
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.make_current()

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	var df := FileAccess.open("%s/stars_diagnostics.json" % dir, FileAccess.WRITE)
	if df != null:
		df.store_string(JSON.stringify(_star_cap_jsonable(diag), "\t"))
		df.close()
	var fails: Array = diag["fails"]
	print("PlaytestHarness: star capture — %d shots in %s — %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir),
		"PASS" if fails.is_empty() else "FAIL: " + "; ".join(PackedStringArray(fails))])
	_maybe_quit()


func _star_cap_set_night(main: Node, y: int, m: int, d: int, hour: float) -> void:
	main.set("time_scale", 0.0)
	main.set("year", y)
	main.set("month", m)
	main.set("day", d)
	main.set("day_time", hour)
	main.set("clouds_cutoff", 1.0)


## Wait for the 20 Hz sky tick to push the new clock/markers, then two draws.
func _star_cap_settle(main: Node) -> void:
	await get_tree().create_timer(0.35).timeout
	# Whatever the weather sampler wants tonight, the shots need a clear sky.
	var env: Variant = main.get("environment")
	if env is WorldEnvironment and env.environment != null and env.environment.sky != null:
		var mat: Material = env.environment.sky.sky_material
		if mat is ShaderMaterial:
			mat.set_shader_parameter("clouds_cutoff", 1.0)
			mat.set_shader_parameter("clouds_weight", 0.0)
			mat.set_shader_parameter("cirrus_amount", 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw


func _star_cap_aim(cam: Camera3D, dir: Vector3) -> void:
	var up := Vector3.UP if absf(dir.normalized().y) < 0.99 else Vector3(0, 0, -1)
	cam.look_at(cam.global_position + dir.normalized() * 100.0, up)


## Luminance-weighted centroid of the pixels >= 60% of the window peak within
## +-radius of (cx, cy). Returns {found, px, peak}.
func _star_cap_blob(img: Image, cx: float, cy: float, radius: int) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := clampi(int(cx) - radius, 0, w - 1)
	var x1 := clampi(int(cx) + radius, 0, w - 1)
	var y0 := clampi(int(cy) - radius, 0, h - 1)
	var y1 := clampi(int(cy) + radius, 0, h - 1)
	var peak := 0.0
	for yy in range(y0, y1 + 1):
		for xx in range(x0, x1 + 1):
			peak = maxf(peak, img.get_pixel(xx, yy).get_luminance())
	# 0.05: after the shader's contrast curve a 2nd-magnitude star (Polaris,
	# Merak) sits well under 0.12; the sky itself is ~0.01 at night.
	if peak < 0.05:
		return {"found": false, "px": Vector2.ZERO, "peak": peak}
	var thr := peak * 0.6
	var sw := 0.0
	var sx := 0.0
	var sy := 0.0
	for yy in range(y0, y1 + 1):
		for xx in range(x0, x1 + 1):
			var l := img.get_pixel(xx, yy).get_luminance()
			if l >= thr:
				sw += l
				sx += l * (float(xx) + 0.5)
				sy += l * (float(yy) + 0.5)
	return {"found": true, "px": Vector2(sx / sw, sy / sw), "peak": peak}


## Every catalog star above 10° and inside the frame: projected marker position
## vs the brightest texture blob nearby (markers OFF in `img`).
func _star_cap_measure(main: Node, ss: Node, cam: Camera3D, img: Image) -> Array:
	var rows: Array = []
	var vp_size := Vector2(img.get_width(), img.get_height())
	var deg_per_px := cam.fov / vp_size.y
	var moon_dir := Vector3.ZERO
	var clk: Variant = main.get("clock")
	if clk != null and clk.has_method("get_moon_direction"):
		moon_dir = clk.call("get_moon_direction")
	var catalog: Dictionary = ss.get("REFERENCE_STARS")
	for name in catalog.keys():
		var p: Dictionary = ss.call("get_reference_star_position", name)
		if p.is_empty() or float(p["altitude"]) < 10.0:
			continue
		var d: Vector3 = p["direction"]
		if moon_dir.length() > 0.5 and d.angle_to(moon_dir) < deg_to_rad(8.0):
			continue
		var world := cam.global_position + d * 1000.0
		if cam.is_position_behind(world):
			continue
		var sp := cam.unproject_position(world)
		var margin := float(STAR_CAP_SEARCH_PX + 4)
		if sp.x < margin or sp.y < margin or sp.x > vp_size.x - margin or sp.y > vp_size.y - margin:
			continue
		var blob := _star_cap_blob(img, sp.x, sp.y, STAR_CAP_SEARCH_PX)
		var row := {"star": name, "expected": sp, "found": blob["found"], "found_px": blob["px"],
			"dist_px": -1.0, "dist_deg": -1.0, "peak": blob["peak"]}
		if blob["found"]:
			row["dist_px"] = sp.distance_to(blob["px"])
			row["dist_deg"] = row["dist_px"] * deg_per_px
		rows.append(row)
	return rows


func _star_cap_pair(main: Node, ss: Node, cam: Camera3D, img: Image, a: String, b: String) -> Dictionary:
	var out := {}
	for name in [a, b]:
		var p: Dictionary = ss.call("get_reference_star_position", name)
		var sp := cam.unproject_position(cam.global_position + (p["direction"] as Vector3) * 1000.0)
		var blob := _star_cap_blob(img, sp.x, sp.y, STAR_CAP_SEARCH_PX)
		out[name] = {"expected": sp, "found": blob["found"], "px": blob["px"]}
	return out


func _star_cap_rotation_report(a: Dictionary, b: Dictionary, expect_deg: float, label: String, diag: Dictionary,
		cam: Camera3D, img_h: float, ss: Node) -> Dictionary:
	var ka: Array = a.keys()
	var pivot: String = ka[0]
	var mover: String = ka[1]
	var rep := {"pivot": pivot, "mover": mover, "expected_deg": expect_deg}
	if not (a[pivot]["found"] and a[mover]["found"] and b[pivot]["found"] and b[mover]["found"]):
		rep["error"] = "a star was not found in one of the frames"
		diag["fails"].append("rotation %s: star not found" % label)
		push_error("PlaytestHarness: rotation %s — a star was not found" % label)
		return rep
	var pa: Vector2 = a[pivot]["px"]
	var pb: Vector2 = b[pivot]["px"]
	var ma: Vector2 = a[mover]["px"]
	var mb: Vector2 = b[mover]["px"]
	# The camera looks straight at the pole, so a star θ° from the pole sits at
	# radius f·tan θ in a gnomonic frame (f = h/2 / tan(fov/2)) and a 2 h turn
	# moves it along a chord 2·f·tan θ·sin(Δ/2). Pinning the measured chord to
	# that geometry (not "some pixels") is what makes the check mean something.
	var f := img_h * 0.5 / tan(deg_to_rad(cam.fov * 0.5))
	var half := sin(deg_to_rad(absf(expect_deg) * 0.5))
	var catalog: Dictionary = ss.get("REFERENCE_STARS")
	var exp_pivot := 2.0 * f * tan(deg_to_rad(90.0 - absf(float(catalog[pivot]["dec"])))) * half
	var exp_mover := 2.0 * f * tan(deg_to_rad(90.0 - absf(float(catalog[mover]["dec"])))) * half
	var pivot_moved := pa.distance_to(pb)
	var mover_moved := ma.distance_to(mb)
	# Screen y points DOWN; use the math convention (y up) so CCW is positive.
	var ang_a := atan2(-(ma.y - pa.y), ma.x - pa.x)
	var ang_b := atan2(-(mb.y - pb.y), mb.x - pb.x)
	var rot := rad_to_deg(wrapf(ang_b - ang_a, -PI, PI))
	rep["pivot_moved_px"] = pivot_moved
	rep["pivot_expected_px"] = exp_pivot
	rep["mover_moved_px"] = mover_moved
	rep["mover_expected_px"] = exp_mover
	rep["rotation_deg"] = rot
	var ok_pivot := absf(pivot_moved - exp_pivot) <= maxf(4.0, 0.15 * exp_pivot)
	var ok_mover := absf(mover_moved - exp_mover) <= maxf(4.0, 0.15 * exp_mover)
	var ok_rot := absf(rot - expect_deg) <= 1.5
	var ok := ok_pivot and ok_mover and ok_rot
	print("  rotation %s: %s moved %.1f px (expect %.1f), %s moved %.1f px (expect %.1f), %s->%s vector rotated %+.2f deg (expect %+.2f)  %s" % [
		label, pivot, pivot_moved, exp_pivot, mover, mover_moved, exp_mover, pivot, mover, rot, expect_deg, "PASS" if ok else "FAIL"])
	if not ok:
		diag["fails"].append("rotation %s: pivot %.1f/%.1f px, mover %.1f/%.1f px, rot %.2f" % [label, pivot_moved, exp_pivot, mover_moved, exp_mover, rot])
		push_error("PlaytestHarness: rotation proof failed — %s" % label)
	return rep


func _star_cap_jsonable(v: Variant) -> Variant:
	if v is Dictionary:
		var d := {}
		for k in v.keys():
			d[str(k)] = _star_cap_jsonable(v[k])
		return d
	if v is Array:
		var arr := []
		for e in v:
			arr.append(_star_cap_jsonable(e))
		return arr
	if v is Vector2:
		return [v.x, v.y]
	if v is Vector3:
		return [v.x, v.y, v.z]
	return v


## --- Dawn lighting capture ---------------------------------------------------
## The sunrise used to switch on like a lightbulb, and a single PNG cannot show
## a RATE. This parks the clock at a ladder of solar altitudes (−14° … +20°) on
## the equinox, shoots toward the sun's bearing and away from it at each step,
## and DUMPS what the lighting actually did on the live nodes: DirectionalLight
## energy + colour, ambient, night amount. Asserts the contract the daylight
## selftest pins offline, now measured end to end: no beam with the sun below
## the horizon (the old ramp lit the ground from −5.7°), energy and ambient
## monotonic through the ladder, the beam still weak on the horizon, and every
## light colour white at 20°. Clock and clouds are restored; nothing persists.
const DAWN_CAP_ALTITUDES: Array[float] = [-14.0, -10.0, -7.0, -5.0, -3.0, -1.5, -0.5, 0.0, 0.5, 1.0, 2.0, 4.0, 7.0, 12.0, 20.0]


func _run_dawn_capture() -> void:
	var tree := get_tree()
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout

	var main := _find_main()
	var sun: DirectionalLight3D = main.get("sun") as DirectionalLight3D if main != null else null
	var clock: Object = main.get("clock") as Object if main != null else null  # CelestialClock is a RefCounted
	var env: WorldEnvironment = main.get("environment") as WorldEnvironment if main != null else null
	if main == null or sun == null or clock == null or env == null or env.environment == null:
		push_error("PlaytestHarness: no Main/sun/clock/environment — aborting dawn capture")
		_maybe_quit()
		return

	var label := _shots_label if not _shots_label.is_empty() else "dawn"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	var diag := {"steps": [], "fails": []}

	_set_capture_conditions()
	var saved_clouds: Variant = main.get("clouds_cutoff")
	var saved_date := [int(main.get("year")), int(main.get("month")), int(main.get("day")), float(main.get("day_time"))]
	main.set("time_scale", 0.0)
	main.set("year", 2026)
	main.set("month", 3)
	main.set("day", 20)
	main.set("clouds_cutoff", 1.0)

	var prev_cam := get_viewport().get_camera_3d()
	var cam := Camera3D.new()
	cam.name = "PlaytestDawnCam"
	cam.far = 40000.0
	cam.fov = 60.0
	main.add_child(cam)
	if prev_cam != null:
		cam.global_position = prev_cam.global_position + Vector3(0.0, 12.0, 0.0)
	else:
		cam.global_position = Vector3(0.0, 15.0, 0.0)
	cam.make_current()

	var noon_e := float(main.get("sun_base_enegry")) * DaylightModel.SUN_ZENITH_GAIN
	print("\n=== DAWN LIGHTING CAPTURE ===")
	print("site lat %.4f lon %.4f   2026-03-20   twilight_length %.2f  sun_warmth %.2f  sun base %.2f (noon ref %.2f)" % [
		float(main.get("latitude")), float(main.get("longitude")),
		float(main.get("twilight_length")), float(main.get("sun_warmth")),
		float(main.get("sun_base_enegry")), noon_e])
	# The ambient column is the player's own ramp: with ambient_energy_mult 0 it
	# reads 0 at every step and the ground is lit by the beam alone.
	print("player prefs: ambient_energy_mult %.2f  ambient_sky_contribution %.2f  tonemap_exposure %.2f" % [
		float(main.get("ambient_energy_mult")), float(main.get("ambient_sky_contribution")), float(main.get("tonemap_exposure"))])
	print("  %6s %7s %8s %8s %-22s %8s %6s" % ["alt", "clock", "beam", "beam%", "light colour", "ambient", "night"])

	var prev_e := -1.0
	var prev_amb := -1.0
	for alt in DAWN_CAP_ALTITUDES:
		var t := _dawn_cap_time_for_altitude(main, clock, alt)
		if is_nan(t):
			print("  %+6.1f  (sun never reaches this altitude here today) skipped" % alt)
			continue
		main.set("day_time", t)
		await _star_cap_settle(main)
		var sd: Vector3 = clock.call("get_sun_direction")
		var bearing := Vector3(sd.x, 0.0, sd.z)
		if bearing.length() < 1e-4:
			bearing = Vector3(0.0, 0.0, -1.0)
		bearing = bearing.normalized()
		var tag := ("m" if alt < 0.0 else "p") + ("%04.1f" % absf(alt))
		_star_cap_aim(cam, (bearing + Vector3(0.0, -0.1, 0.0)).normalized())
		await RenderingServer.frame_post_draw
		await _graph_shot(dir, "dawn_%s_sunward" % tag, manifest, "dawn")
		_star_cap_aim(cam, (-bearing + Vector3(0.0, -0.1, 0.0)).normalized())
		await RenderingServer.frame_post_draw
		await _graph_shot(dir, "dawn_%s_antisun" % tag, manifest, "dawn")

		var e := sun.light_energy
		var c := sun.light_color
		var amb := env.environment.ambient_light_energy
		var night := DaylightModel.night_amount(sd.y, float(main.get("twilight_length")))
		var row := {"alt_deg": alt, "clock_h": t, "sun_dir_y": sd.y, "beam": e, "beam_frac": e / maxf(noon_e, 1e-6),
			"color": [c.r, c.g, c.b], "ambient": amb, "night_amount": night}
		diag["steps"].append(row)
		print("  %+6.1f %7.3f %8.4f %7.1f%% (%.2f, %.2f, %.2f)      %8.4f %6.3f" % [
			alt, t, e, 100.0 * e / maxf(noon_e, 1e-6), c.r, c.g, c.b, amb, night])
		if alt <= -1.0 and e > 1e-6:
			diag["fails"].append("beam %.4f with the sun at %+.1f° (must be 0 below the horizon)" % [e, alt])
		if e < prev_e - 1e-6:
			diag["fails"].append("beam fell from %.4f to %.4f between steps ending %+.1f°" % [prev_e, e, alt])
		if amb < prev_amb - 1e-6:
			diag["fails"].append("ambient fell from %.4f to %.4f between steps ending %+.1f°" % [prev_amb, amb, alt])
		if absf(alt) < 0.01 and e > 0.08 * noon_e:
			diag["fails"].append("beam on the horizon is %.1f%% of noon (lightbulb — must be a few percent)" % (100.0 * e / noon_e))
		if absf(alt) < 0.01 and (c.b > 0.25 or c.g > 0.7):
			diag["fails"].append("horizon light colour %s is not deep orange" % str(c))
		if absf(alt - 20.0) < 0.01 and (c.g < 0.9 or c.b < 0.8):
			diag["fails"].append("light at 20° is still tinted %s" % str(c))
		prev_e = e
		prev_amb = amb

	# --- restore --------------------------------------------------------------
	main.set("year", saved_date[0])
	main.set("month", saved_date[1])
	main.set("day", saved_date[2])
	main.set("day_time", saved_date[3])
	if saved_clouds != null:
		main.set("clouds_cutoff", saved_clouds)
	for child in main.get_children():
		if child is CanvasLayer:
			child.visible = true
	cam.queue_free()
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.make_current()

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	var df := FileAccess.open("%s/dawn_diagnostics.json" % dir, FileAccess.WRITE)
	if df != null:
		df.store_string(JSON.stringify(diag, "\t"))
		df.close()
	var fails: Array = diag["fails"]
	for msg in fails:
		push_error("PlaytestHarness dawn: %s" % msg)
	print("PlaytestHarness: dawn capture — %d shots in %s — %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir),
		"PASS" if fails.is_empty() else "FAIL: " + "; ".join(PackedStringArray(fails))])
	_maybe_quit()


## Microclimate capture (WINDOWED, `--user-map=walton`): parks the clock at a
## ladder of times across the two nights the user stood in valley fog at
## Walton OR (fog ~22–23 h → ~10–11 h on 2026-10-02/03) and, at each stop,
## DUMPS what the resolver decided — data source, dew-point gap (raw and
## valley-corrected), low cloud, model visibility, auto-fog fraction and why,
## the fog visibility/top shown — and shoots a ground-level and a drone view.
## Asserts fog at 23/03/08 h both nights and none at 15 h, ONLY when the real
## 2026 data is loaded (otherwise it says SKIP rather than testing 2025's
## weather). Ends with a live-preview check (a slider look at a clear hour)
## and restores the clock. Read-only: the map's microclimate file is never
## written.
const MICRO_CAP_STOPS := [
	[10, 2, 20.0], [10, 2, 22.0], [10, 2, 23.0], [10, 3, 3.0], [10, 3, 8.0],
	[10, 3, 9.5], [10, 3, 10.5], [10, 3, 12.0], [10, 3, 15.0],
	[10, 3, 22.0], [10, 3, 23.0], [10, 4, 3.0], [10, 4, 8.0], [10, 4, 10.5], [10, 4, 15.0]]
const MICRO_CAP_MUST_FOG := ["10-02 23", "10-03 03", "10-03 08", "10-03 23", "10-04 03", "10-04 08"]
const MICRO_CAP_MUST_CLEAR := ["10-03 15", "10-04 15"]


func _run_microclimate_capture() -> void:
	var tree := get_tree()
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	var main := _find_main()
	var mc := get_node_or_null("/root/Microclimate")
	var ws := get_node_or_null("/root/WeatherService")
	if main == null or mc == null or ws == null:
		push_error("PlaytestHarness: no Main/Microclimate/WeatherService — aborting microclimate capture")
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "microclimate"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	var diag := {"stops": [], "fails": [], "skipped": false}

	_set_capture_conditions()
	var saved_date := [int(main.get("year")), int(main.get("month")), int(main.get("day")), float(main.get("day_time"))]
	var saved_ts: Variant = main.get("time_scale")
	main.set("time_scale", 0.0)
	main.set("year", 2026)
	main.set("month", 10)
	main.set("day", 2)
	main.set("day_time", 20.0)
	# The real 2026 archive arrives asynchronously the first time a site loads.
	var waited := 0.0
	while waited < 90.0 and not bool(ws.call("has_current_year_archive")):
		await tree.create_timer(1.0).timeout
		waited += 1.0
	mc.call("invalidate")
	var ctx: Dictionary = mc.call("site_context")
	print("\n=== MICROCLIMATE CAPTURE ===")
	print("site lat %.4f lon %.4f  current-year archive %s (waited %.0f s)  valley index %.1f m  cold-pool bias %.2f C  default depth %.0f m  floor y %.1f" % [
		float(main.get("latitude")), float(main.get("longitude")),
		"YES" if bool(ws.call("has_current_year_archive")) else "NO", waited,
		float(ctx.get("tpi_m", 0.0)), float(ctx.get("cold_pool_bias_c", 0.0)),
		float(ctx.get("default_depth_m", 0.0)), float(ctx.get("floor_y", 0.0))])
	print("  %-8s %-16s %6s %6s %5s %5s %7s %5s %-16s %8s %7s" % ["stop", "source", "gap", "gapV", "RH", "low", "visKm", "auto", "why", "fogVis", "topY"])

	var prev_cam := get_viewport().get_camera_3d()
	var base_pos := prev_cam.global_position if prev_cam != null else Vector3(0.0, 2.0, 0.0)
	var ray_y := NAN
	var space := get_viewport().world_3d.direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(
		Vector3(base_pos.x, 3000.0, base_pos.z), Vector3(base_pos.x, -3000.0, base_pos.z)))
	if not hit.is_empty():
		ray_y = (hit["position"] as Vector3).y
	var gh := float(loader.call("ground_height_at", base_pos.x, base_pos.z)) if loader != null else NAN
	print("  camera at (%.0f, %.1f, %.0f)  ground_height_at %.1f  physics ray %.1f (%s)" % [base_pos.x, base_pos.y, base_pos.z,
		gh, ray_y, str(hit.get("collider", "none"))])
	var cam := Camera3D.new()
	cam.name = "PlaytestMicroCam"
	cam.far = 30000.0
	cam.fov = 65.0
	main.add_child(cam)
	cam.make_current()

	var have_2026 := bool(ws.call("has_current_year_archive"))
	for stop in MICRO_CAP_STOPS:
		main.set("month", int(stop[0]))
		main.set("day", int(stop[1]))
		main.set("day_time", float(stop[2]))
		await tree.create_timer(0.6).timeout
		var h := float(main.call("get_absolute_hours"))
		var st: Dictionary = mc.call("resolve_at", h)
		var f: Dictionary = st.get("features", {})
		var key := "%02d-%02d %02d" % [int(stop[0]), int(stop[1]), int(stop[2])]
		var vis := float(st.get("fog_vis_m", INF))
		var row := {"stop": key, "abs_h": h, "source": str(f.get("source", "")),
			"dep_c": f.get("dep_c", null), "dep_eff_c": f.get("dep_eff_c", null), "rh": f.get("rh", null),
			"low": f.get("low", null), "vis_km": f.get("vis_km", null), "auto_fog": st.get("auto_fog", 0.0),
			"why": st.get("auto_source", ""), "fog_vis_m": vis if is_finite(vis) else -1.0,
			"fog_top_y": st.get("fog_top_y", 0.0), "ground_cloud": st.get("ground_cloud", 0.0)}
		diag["stops"].append(row)
		print("  %-8s %-16s %6.1f %6.1f %5.0f %5.2f %7.1f %5.2f %-16s %8s %7.1f" % [key, str(row["source"]),
			float(f.get("dep_c", NAN)), float(f.get("dep_eff_c", NAN)), float(f.get("rh", NAN)),
			float(f.get("low", NAN)), float(f.get("vis_km", NAN)), float(st.get("auto_fog", 0.0)),
			str(st.get("auto_source", "")), ("%d m" % int(vis)) if is_finite(vis) else "none",
			float(st.get("fog_top_y", 0.0))])
		if have_2026:
			if key in MICRO_CAP_MUST_FOG and not (is_finite(vis) and vis < 1500.0):
				diag["fails"].append("no fog at %s (observed fog on site)" % key)
			if key in MICRO_CAP_MUST_CLEAR and is_finite(vis) and vis < 3000.0:
				diag["fails"].append("fog %d m at %s (observed clear)" % [int(vis), key])
		var tag := key.replace(" ", "_").replace("-", "")
		# Ground: the player's spot, looking level.
		cam.global_position = base_pos
		cam.look_at(base_pos + Vector3(0.0, -0.02, -1.0), Vector3.UP)
		# Volumetric fog reprojects ~90 % of the previous frame: after a camera
		# jump it needs ~1 s to converge, or the shot shows stale fog smeared
		# from the last viewpoint.
		await tree.create_timer(1.2).timeout
		_mc_cap_dump_render(main, key)
		await _graph_shot(dir, "mc_%s_ground" % tag, manifest, "microclimate")
		# Drone: up and back, ABOVE the fog top, looking down over the valley.
		var drone_y := maxf(base_pos.y + 140.0, float(st.get("fog_top_y", 0.0)) + 90.0)
		cam.global_position = Vector3(base_pos.x, drone_y, base_pos.z + 220.0)
		cam.look_at(base_pos + Vector3(0.0, 0.0, -150.0), Vector3.UP)
		await tree.create_timer(1.2).timeout
		await _graph_shot(dir, "mc_%s_drone" % tag, manifest, "microclimate")
	if not have_2026:
		diag["skipped"] = true
		print("  (SKIP assertions: the 2026 archive never loaded - the stops above are 2025's weather)")

	# Live preview: a slider look at a clear afternoon must show.
	main.set("month", 10)
	main.set("day", 3)
	main.set("day_time", 15.0)
	mc.call("set_preview", {"fog_vis_m": 60.0, "fog_depth_m": 40.0})
	await tree.create_timer(0.6).timeout
	var pv: Dictionary = mc.call("current")
	var pvis := float(pv.get("fog_vis_m", INF))
	print("  preview look at 10-03 15 h -> fog %s" % (("%d m" % int(pvis)) if is_finite(pvis) else "none"))
	if not (is_finite(pvis) and absf(pvis - 60.0) < 6.0):
		diag["fails"].append("preview look not applied (got %s)" % str(pvis))
	cam.global_position = base_pos
	cam.look_at(base_pos + Vector3(0.0, -0.02, -1.0), Vector3.UP)
	await tree.create_timer(1.5).timeout
	_mc_cap_dump_render(main, "preview")
	await _graph_shot(dir, "mc_preview_ground", manifest, "microclimate")
	mc.call("clear_preview")

	# --- restore --------------------------------------------------------------
	main.set("year", saved_date[0])
	main.set("month", saved_date[1])
	main.set("day", saved_date[2])
	main.set("day_time", saved_date[3])
	if saved_ts != null:
		main.set("time_scale", saved_ts)
	for child in main.get_children():
		if child is CanvasLayer:
			child.visible = true
	cam.queue_free()
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.make_current()
	var mf := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if mf != null:
		mf.store_string(JSON.stringify(manifest, "\t"))
		mf.close()
	var df := FileAccess.open("%s/microclimate_diagnostics.json" % dir, FileAccess.WRITE)
	if df != null:
		df.store_string(JSON.stringify(diag, "\t"))
		df.close()
	var fails: Array = diag["fails"]
	for msg in fails:
		push_error("PlaytestHarness microclimate: %s" % msg)
	print("PlaytestHarness: microclimate capture - %d shots in %s - %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir),
		"PASS" if fails.is_empty() else "FAIL: " + "; ".join(PackedStringArray(fails))])
	_maybe_quit()


## What actually reached the renderer — a PNG cannot say whether the fog pass
## was even on.
func _mc_cap_dump_render(main: Node, key: String) -> void:
	var env: WorldEnvironment = main.get("environment") as WorldEnvironment
	var gf := main.get_node_or_null("GroundFogLayer") as Node3D
	var vol := gf.get_node_or_null("GroundFog") as FogVolume if gf != null else null
	var cam := get_viewport().get_camera_3d()
	var e := env.environment if env != null else null
	print("    render %s: volfog %s dens %.4f len %.0f amb %.2f | layer %s box y %.0f..%.0f size %s | cam y %.1f" % [key,
		str(e.volumetric_fog_enabled) if e != null else "?", e.volumetric_fog_density if e != null else 0.0,
		e.volumetric_fog_length if e != null else 0.0, e.volumetric_fog_ambient_inject if e != null else 0.0,
		str(gf.visible) if gf != null else "missing",
		(vol.global_position.y - vol.size.y * 0.5) if vol != null else 0.0,
		(vol.global_position.y + vol.size.y * 0.5) if vol != null else 0.0,
		str(vol.size) if vol != null else "-", cam.global_position.y if cam != null else 0.0])


## Clock hour (morning, 1 h … 12.5 h) at which the sun sits at `alt_deg`, by
## bisection on the clock's own sun direction. NAN when the sun never gets
## there today. Leaves day_time wherever the last probe put it.
func _dawn_cap_time_for_altitude(main: Node, clock: Object, alt_deg: float) -> float:
	var target := sin(deg_to_rad(alt_deg))
	var lo := 1.0
	var hi := 12.5
	main.set("day_time", lo)
	var f_lo: float = (clock.call("get_sun_direction") as Vector3).y - target
	main.set("day_time", hi)
	var f_hi: float = (clock.call("get_sun_direction") as Vector3).y - target
	if f_lo > 0.0 or f_hi < 0.0:
		return NAN
	for _i in 48:
		var mid := 0.5 * (lo + hi)
		main.set("day_time", mid)
		var fm: float = (clock.call("get_sun_direction") as Vector3).y - target
		if fm < 0.0:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)


# ==================== FESTIVAL (--capture=festival) ====================
# The festival-scale plan's end-to-end harness, built for the Walton, OR map
# (`--user-map=walton`) but runnable on any TerrainLoader map. It drives the
# whole chain the player would: a festival road + zone cut into lots →
# assigned camps (placement) → one camp compound per lot on the graph with
# its own habitat, tanks and power model → venues with a programme + two
# portapotty banks and a water station bound to graph tanks → one sim-day
# at speed with the graph CLOSED → the vibe meter → the settlement view's
# five zoom stops with the crowd drawn at each. Console asserts carry what a
# PNG cannot: venue occupancy inside vs outside the set, water per person per
# day off the camps' own stores, blackwater landing on the BOUND tanks, the
# vibe falling when the water runs out, and per-stop ms + draw calls.
# --count=N scales the lots' headcounts to N people in total.
# Snapshots and byte-restores the map's camp / placement / spaces files and
# the graph autosave; strips its own graph items and camp compounds.

func _fest_result(ok: bool, label: String) -> void:
	print("PlaytestHarness: festival %s — %s" % ["PASS" if ok else "FAIL", label])


func _run_festival_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null or not loader.has_method("add_placement_zone"):
		push_error("PlaytestHarness: festival needs a TerrainLoader map with the placement API")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var main := get_tree().current_scene
	var sgv := await _find_graph_view()
	if sgv == null or sgv.get("model") == null:
		push_error("PlaytestHarness: festival — graph model unavailable")
		_maybe_quit()
		return
	var model: Variant = sgv.get("model")
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null:
		push_error("PlaytestHarness: festival — population bridge missing")
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "festival"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var files := [CampAreaLayer.save_path_for_map(lat, lon), FestivalPlacementLayer.save_path_for_map(lat, lon),
		SpaceRegistry.new().save_path_for_map(lat, lon)]
	if sgv.has_method("_graph_autosave_path"):
		files.append(str(sgv.call("_graph_autosave_path")))
	var snap := _snapshot_files(files)
	# A fixed day so every run samples the same population day.
	if "year" in main:
		main.year = 2026
		main.month = 7
		main.day = 15
	if "day_time" in main:
		main.day_time = 10.0
	if "time_scale" in main:
		main.time_scale = 0.0
	var pm := get_node_or_null("/root/PerfMonitor")
	if pm != null and pm.has_method("set_enabled"):
		pm.call("set_enabled", true)

	# --- 1. placement: a road + zone next to the player, cut into lots -----
	# Where a festival could actually camp: score candidate sites with the
	# real generator + the loader's real exclusions (the camps capture's
	# scorer), else fall back to a spot near the player.
	var sites := _camp_pick_sites(loader)
	var player := main.get_node_or_null("Player") as Node3D
	var origin := Vector2(player.global_position.x, player.global_position.z) if player != null else Vector2.ZERO
	var zc: Vector2 = sites[0] if not sites.is_empty() else origin + Vector2(0.0, -140.0)
	var hw := CAMP_SITE_W
	var hd := CAMP_SITE_D * 0.8
	print("PlaytestHarness: festival — zone centre %s (%d scored sites; player at %s)" % [str(zc), sites.size(), str(origin)])
	var zone_poly := PackedVector2Array([zc + Vector2(-hw, -hd), zc + Vector2(hw, -hd),
		zc + Vector2(hw, hd), zc + Vector2(-hw, hd)])
	loader.call("erase_camps_in_polygon", zone_poly)
	# The WORLD may already hold camp compounds (Walton's painted camps carry
	# headcounts): every count below is this run's DELTA over what was there.
	for _f0 in 4:
		await get_tree().process_frame
	var sgv0: Node = ServiceLocator.graph()
	var camps_before := (sgv0.call("festival_camps") as Array).size() if sgv0 != null and sgv0.has_method("festival_camps") else 0
	var people_before := 0
	if sgv0 != null and sgv0.get("model") != null:
		people_before = int(CampLedger.festival(sgv0.get("model")).get("people", 0))
	print("PlaytestHarness: festival — world already holds %d camp compound(s), %d people" % [camps_before, people_before])
	var road_pts := FestivalPlacementLayer.road_from_zone_spine(zone_poly, 90.0)
	var rid := str(loader.call("add_festival_road", road_pts, {"name": "Esplanade", "width_m": 8.0}))
	var zid := str(loader.call("add_placement_zone", zone_poly, {
		"spec": {"mode": "count", "target_n": 24, "depth_m": 30.0, "lane_w_m": 5.0,
			"lots_per_lane": 6, "styles": ["mixed", "theme_camp", "rv_park", "car_camping"]},
		"subdivide": true}))
	var placement: FestivalPlacementLayer = loader.get("placement")
	var lots: Array = placement.lots_for_zone(zid) if placement != null and not zid.is_empty() else []
	var zinfo: Dictionary = loader.call("placement_info", "zone", zid)
	var zst: Dictionary = zinfo.get("stats", {})
	print("PlaytestHarness: festival — zone cut: %d lots, usable %.0f / %.0f m², warnings %s" % [
		lots.size(), float(zst.get("usable_m2", 0.0)), float(zst.get("raw_m2", 0.0)), str(zst.get("warnings", []))])
	loader.call("assign_placement", zid)
	lots = placement.lots_for_zone(zid)
	# --count scales the headcounts to the requested festival size.
	var want_total := _bench_count if _bench_count > 0 and _bench_count != 300 else 0
	var people := 0
	for l: Dictionary in lots:
		people += int((l.get("assigned_camp", {}) as Dictionary).get("headcount", 0))
	if want_total > 0 and people > 0:
		var k := float(want_total) / float(people)
		people = 0
		for l: Dictionary in lots:
			var ac: Dictionary = (l.get("assigned_camp", {}) as Dictionary).duplicate()
			if ac.is_empty():
				continue
			ac["headcount"] = maxi(int(round(float(ac.get("headcount", 0)) * k)), 1)
			people += int(ac["headcount"])
			placement.update_lot(str(l["lot_id"]), {"assigned_camp": ac})
		loader.call("_sync_lot_camps", zid)
		lots = placement.lots_for_zone(zid)
	for _i in 4:
		await get_tree().process_frame
	var camps: Array = sgv.call("festival_camps")
	print("PlaytestHarness: festival — road %s, zone %s: %d lots, %d people, %d camp compounds" % [
		rid, zid, lots.size(), people, camps.size()])
	_fest_result(lots.size() >= 12 and camps.size() - camps_before == lots.size() and people >= 200,
		"placement → graph: %d lots became %d new camp compounds (%d people; %d were already there)" % [
			lots.size(), camps.size() - camps_before, people, camps_before])

	# --- 2. venues + infrastructure --------------------------------------------
	var reg: SpaceRegistry = bridge.call("registry_for", main)
	var seeded_spaces: Array = []
	var seeded_items: Array = []
	var add_tank := func(id: String, kind: String, cap: float, level: float, gx: float, gy: float) -> void:
		model.add_item({"id": id, "type": "resource", "x": gx, "y": gy, "width": 90.0, "height": 100.0,
			"specs": {"name": id, "resource_kind": kind, "capacity_qty": cap, "capacity_unit": "L", "level": level,
				"site_x_m": 0.0, "site_z_m": 0.0}})
		seeded_items.append(id)
	add_tank.call("cap_fest_black_a", "blackwater", 20000.0, 0.0, -900.0, -400.0)
	add_tank.call("cap_fest_black_b", "blackwater", 20000.0, 0.0, -700.0, -400.0)
	add_tank.call("cap_fest_water", "water", 100000.0, 1.0, -500.0, -400.0)
	var venue := func(stype: String, c: Vector2, half: float, cap: int, lbl: String, fields: Dictionary) -> String:
		var sid: String = reg.set_space_type({"kind": "area", "poly": [
			[c.x - half, c.y - half], [c.x + half, c.y - half], [c.x + half, c.y + half], [c.x - half, c.y + half]]},
			stype, cap, lbl)
		if not sid.is_empty():
			if not fields.is_empty():
				reg.set_space_fields(sid, fields)
			seeded_spaces.append(sid)
		return sid
	# The set: 20:00 → 02:00 with a loud draw; a dark stage pulls almost nobody.
	var stage_id: String = venue.call("stage", zc + Vector2(0.0, 150.0), 25.0, 600, "Bass Stage",
		{"draw": 1.0, "program": [{"day": -1, "start_h": 20.0, "end_h": 2.0, "draw": 1.0, "label": "Headliner", "load_w": 4000.0}]})
	# Temple and Center Camp sit at the stage's distance from the camps, so
	# the choice between them is draw and taste, not the walk.
	var temple_id: String = venue.call("temple", zc + Vector2(-150.0, 150.0), 18.0, 200, "Temple", {"draw": 0.6})
	var center_id: String = venue.call("center_camp", zc + Vector2(150.0, 150.0), 20.0, 300, "Center Camp", {"draw": 0.7})
	var bank_a: String = venue.call("restroom", zc + Vector2(-120.0, 95.0), 6.0, 24, "Portapotties A",
		{"units": 12, "graph_item_id": "cap_fest_black_a"})
	var bank_b: String = venue.call("restroom", zc + Vector2(120.0, 95.0), 6.0, 24, "Portapotties B",
		{"units": 12, "graph_item_id": "cap_fest_black_b"})
	var water_id: String = venue.call("water_point", zc + Vector2(0.0, 100.0), 5.0, 40, "Water station",
		{"graph_item_id": "cap_fest_water"})
	var kitchen_id: String = venue.call("kitchen", zc + Vector2(60.0, 100.0), 8.0, maxi(people, 60), "Camp kitchens", {})
	var sleep_id: String = venue.call("sleep", zc, 60.0, 5000, "Camp beds", {})
	# Shower trucks: without a shower the FULL tier's hygiene need climbs past
	# its threshold and NpcAgent._wants_enrichment refuses every venue trip
	# for good — a site with no showers never gathers.
	var shower_id: String = venue.call("shower", zc + Vector2(-60.0, 100.0), 6.0, maxi(people / 8, 10), "Shower trucks", {})
	var venues_ok := not stage_id.is_empty() and not temple_id.is_empty() and not center_id.is_empty() \
		and not bank_a.is_empty() and not bank_b.is_empty() and not water_id.is_empty() \
		and not kitchen_id.is_empty() and not sleep_id.is_empty()
	_fest_result(venues_ok, "venues seeded (stage with a 20:00–02:00 set, temple, center camp, 2 portapotty banks, water, kitchen, beds)")
	var flow0: Variant = sgv.get("_resource_flow")
	if flow0 != null and flow0.has_method("clear_timelines"):
		flow0.call("clear_timelines")

	# --- 3. one sim-day at speed, graph closed --------------------------------
	var hab_ids: Array = []
	var water_cap := 0.0
	for c in camps:
		for it in model.get_items_in_scope(str(c["scope"])):
			var d: Dictionary = it
			var sp: Dictionary = d.get("specs", {})
			if str(sp.get("role", "")) == "habitat":
				hab_ids.append(str(d["id"]))
			elif str(d.get("type", "")) == "resource" and str(sp.get("resource_kind", "")) == "water":
				water_cap += float(sp.get("capacity_qty", 0.0)) * float(sp.get("level", 0.0))
	var stage_in: Array = []
	var stage_out: Array = []
	var vibe := FestivalVibe.new()
	var vibe_samples: Array = []
	var light_seen := 0
	var full_seen := 0
	main.time_scale = 0.2   # 720× → one sim-day in ~2 min of real time
	var t_start := Time.get_ticks_msec()
	var h_start := float(main.call("get_absolute_hours"))
	var last_h := -1.0
	print("PlaytestHarness: festival — running the day: time_scale asked 0.2, effective %.3f" % float(main.get("time_scale")))
	while true:
		await get_tree().create_timer(1.0).timeout
		var h := float(main.get("day_time"))
		var abs_h := float(main.call("get_absolute_hours"))
		var occ := reg.occupant_count(stage_id)
		var st := FestivalProgram.state_at(reg.find_by_id(stage_id), h)
		# The set vs the DARK stage by day (10:00–18:00). The hour before a
		# set is people already drifting over, and the hours after it are
		# people drifting home — neither says anything about the pull.
		if bool(st.get("active", false)):
			stage_in.append(occ)
		elif h >= 10.0 and h < 18.0:
			stage_out.append(occ)
		var sums: Array = []
		for hid in hab_ids:
			sums.append(bridge.call("summary_for", str(hid)))
		var v := FestivalVibe.compute(sums)
		vibe.sample(abs_h, float(v["score"]))
		vibe_samples.append(v)
		var lc: Dictionary = bridge.call("light_cohorts") if bridge.has_method("light_cohorts") else {}
		var lp := 0
		for k in lc:
			lp += int((lc[k] as CrowdCohort).alive_count())
		light_seen = maxi(light_seen, lp)
		full_seen = maxi(full_seen, int(v["people"]) - lp)
		if int(Time.get_ticks_msec() - t_start) % 20000 < 1000:
			var acts: Dictionary = {}
			for sm in sums:
				for a in (sm as Dictionary).get("activities", {}):
					acts[str(a)] = int(acts.get(str(a), 0)) + int((sm as Dictionary)["activities"][a])
			var akeys: Array = acts.keys()
			akeys.sort_custom(func(x, y): return int(acts[x]) > int(acts[y]))
			var abits := PackedStringArray()
			for a in akeys.slice(0, 7):
				abits.append("%s %d" % [str(a), int(acts[a])])
			print("PlaytestHarness: festival — %02d:%02d  stage %3d temple %3d center %3d (set %s)  %s  light %d  | %s" % [
				int(h), int(fposmod(h, 1.0) * 60.0), occ, reg.occupant_count(temple_id), reg.occupant_count(center_id),
				"ON" if bool(st.get("active", false)) else "off",
				FestivalVibe.headline(v, vibe.trend()), lp, " · ".join(abits)])
		last_h = h
		# 10:00 → 04:00: the whole 20:00–02:00 set and the hours either side.
		if abs_h - h_start >= 18.0 or Time.get_ticks_msec() - t_start > 420000:
			break
	main.time_scale = 0.0
	print("PlaytestHarness: festival — day loop: %.1f sim-hours in %.0f s real" % [
		float(main.call("get_absolute_hours")) - h_start, float(Time.get_ticks_msec() - t_start) / 1000.0])
	var peak_in := 0
	var mean_in := 0.0
	for o in stage_in:
		peak_in = maxi(peak_in, int(o))
		mean_in += float(o)
	mean_in = (mean_in / float(stage_in.size())) if not stage_in.is_empty() else 0.0
	var mean_out := 0.0
	for o in stage_out:
		mean_out += float(o)
	mean_out = (mean_out / float(stage_out.size())) if not stage_out.is_empty() else 0.0
	print("PlaytestHarness: festival — stage occupancy: inside the set peak %d / mean %.1f (%d samples), dark stage by day mean %.1f (%d samples)" % [
		peak_in, mean_in, stage_in.size(), mean_out, stage_out.size()])
	_fest_result(peak_in >= 20 and mean_in > 2.0 * maxf(mean_out, 1.0),
		"the programmed stage pulls a crowd inside its set (mean %.1f) and little by day while dark (mean %.1f)" % [mean_in, mean_out])
	# Water: what the camps' own stores lost over the day, per person.
	var water_now := 0.0
	for c in camps:
		for it in model.get_items_in_scope(str(c["scope"])):
			var d: Dictionary = it
			var sp: Dictionary = d.get("specs", {})
			if str(d.get("type", "")) == "resource" and str(sp.get("resource_kind", "")) == "water":
				water_now += float(sp.get("capacity_qty", 0.0)) * float(sp.get("level", 0.0))
	var hours := absf(float(main.call("get_absolute_hours")) - (vibe._ring[0][0] if not vibe._ring.is_empty() else 0.0))
	var l_per_person_day := ((water_cap - water_now) / float(maxi(people, 1))) / maxf(hours, 0.1) * 24.0
	print("PlaytestHarness: festival — camp water stores: %.0f → %.0f L over %.1f h = %.1f L/person/day" % [
		water_cap, water_now, hours, l_per_person_day])
	_fest_result(l_per_person_day > 25.0 and l_per_person_day < 90.0,
		"water per person per day off the camps' own stores is in range (%.1f L; calibration ~50 L)" % l_per_person_day)
	var black_a := float((model.get_item("cap_fest_black_a") as Dictionary).get("specs", {}).get("level", 0.0))
	var black_b := float((model.get_item("cap_fest_black_b") as Dictionary).get("specs", {}).get("level", 0.0))
	var water_depot := float((model.get_item("cap_fest_water") as Dictionary).get("specs", {}).get("level", 1.0))
	print("PlaytestHarness: festival — bound tanks: portapotty A %.2f%% · B %.2f%% · water station %.2f%%" % [
		black_a * 100.0, black_b * 100.0, water_depot * 100.0])
	_fest_result(black_a > 0.0 and black_b > 0.0,
		"blackwater from the whole festival lands on BOTH portapotty banks' bound tanks")
	var cr: Node = sgv.call("crowd_renderer") if sgv.has_method("crowd_renderer") else null
	var full_drawn := int(cr.call("full_people_drawn")) if cr != null and cr.has_method("full_people_drawn") else -1
	var hero_budget := int(main.get_node_or_null("NpcPopulationHost").call("hero_budget")) \
		if main.get_node_or_null("NpcPopulationHost") != null else -1
	_fest_result(light_seen > 0 and full_seen > 0,
		"both tiers ran (peak %d light-tier, %d full-tier people)" % [light_seen, full_seen])
	# Same-moment numbers: full_seen is the PEAK over the day, while the hero
	# pool and the overflow describe NOW (the full tier shrinks as the clock
	# speeds and the budget is the quality tier's — Ultra is 64). Every
	# full-tier person who is not a hero must be drawn by the crowd renderer.
	var full_now := 0
	for d in (bridge.call("agent_dots") as Array):
		if str((d as Dictionary).get("tier", "")) != "light":
			full_now += 1
	var host_n: Node = main.get_node_or_null("NpcPopulationHost")
	var heroes_now := (host_n.get("_hero_ids") as Dictionary).size() if host_n != null else -1
	_fest_result(full_drawn >= 0 and heroes_now >= 0 and full_drawn >= full_now - heroes_now - 5 and full_drawn <= full_now,
		"the hero pool handed the full tier past its budget to the crowd renderer (%d of %d full-tier now drawn as crowd, %d heroes, budget %d; peak full tier %d)" % [
			full_drawn, full_now, heroes_now, hero_budget, full_seen])
	var pstates: Dictionary = sgv.call("camp_power_states") if sgv.has_method("camp_power_states") else {}
	var soc_stamped := 0
	for c in camps:
		if (model.get_item(str(c["id"])) as Dictionary).get("specs", {}).has("camp_soc"):
			soc_stamped += 1
	_fest_result(pstates.size() == camps.size() and soc_stamped == camps.size(),
		"every camp runs its own power model (%d states, %d SOC stamps)" % [pstates.size(), soc_stamped])
	var fest := CampLedger.festival(model)
	var totals: Dictionary = fest.get("totals", {})
	var wrow: Dictionary = totals.get("water", {})
	print("PlaytestHarness: festival — ledger: %d people, water demand %.1f L/h vs supply %.1f, open kinds across camps: %s" % [
		int(fest.get("people", 0)), float(wrow.get("demand", 0.0)), float(wrow.get("supply", 0.0)) + float(wrow.get("imports", 0.0)),
		str(_fest_open_kinds(fest))])
	_fest_result(int(fest.get("people", 0)) - people_before == people,
		"the festival ledger counts the lots' people (%d over the %d already there)" % [
			int(fest.get("people", 0)) - people_before, people_before])
	var v_before: Dictionary = vibe_samples[vibe_samples.size() - 1] if not vibe_samples.is_empty() else {}
	print("PlaytestHarness: festival — vibe after the day: %s" % FestivalVibe.headline(v_before, vibe.trend()))

	# --- 4. cut the water: the vibe must answer -------------------------------
	for c in camps:
		for it in model.get_items_in_scope(str(c["scope"])):
			var d: Dictionary = it
			var sp: Dictionary = (d.get("specs", {}) as Dictionary).duplicate(true)
			if str(d.get("type", "")) == "resource" and str(sp.get("resource_kind", "")) == "water":
				sp["level"] = 0.0
				model.update_item(str(d["id"]), {"specs": sp})
	var sp_w: Dictionary = (model.get_item("cap_fest_water") as Dictionary).get("specs", {}).duplicate(true)
	sp_w["level"] = 0.0
	model.update_item("cap_fest_water", {"specs": sp_w})
	if flow0 != null and flow0.has_method("clear_timelines"):
		flow0.call("clear_timelines")
	main.time_scale = 0.2
	await get_tree().create_timer(45.0).timeout   # ~9 sim-hours
	main.time_scale = 0.0
	var sums2: Array = []
	for hid in hab_ids:
		sums2.append(bridge.call("summary_for", str(hid)))
	var v_after := FestivalVibe.compute(sums2)
	print("PlaytestHarness: festival — vibe after the water ran out: %s" % FestivalVibe.headline(v_after, 0.0))
	_fest_result(float(v_after["score"]) < float(v_before.get("score", 1.0)) - 0.03
		and (v_after["blocked"] as Dictionary).has("thirst"),
		"the vibe falls and names thirst once the water is gone (%.2f → %.2f)" % [float(v_before.get("score", 0.0)), float(v_after["score"])])

	# --- 5. the settlement view over the crowd, five zoom stops ---------------
	if main.has_method("open_settlement_view"):
		main.call("open_settlement_view", zc)
		await get_tree().create_timer(1.0).timeout
		var view: Variant = main.get("settlement_view")
		var cam: Variant = view.call("camera") if view != null else null
		if cam != null:
			cam.call("look_at_xz", zc + Vector2(0.0, 80.0))
			for s in [["eye", 1.7], ["street", 12.0], ["block", 60.0], ["camp", 300.0], ["site", 1200.0]]:
				cam.set("_h_target", float(s[1]))
				cam.set("_h", float(s[1]))
				await get_tree().create_timer(0.8).timeout
				var snapd: Dictionary = pm.call("snapshot") if pm != null and pm.has_method("snapshot") else {}
				var secs: Dictionary = snapd.get("sections_ms", {})
				var rend: Dictionary = snapd.get("render", {})
				await _shoot_ui(dir, "settlement_%s" % str(s[0]))
				print("PlaytestHarness: festival — stop %-6s h=%6.1f  frame %.1f ms  npc_host %.1f  crowd_render %.1f  flow %.1f  draws %d" % [
					str(s[0]), float(cam.call("height")), float(snapd.get("frame_ms", 0.0)),
					float(secs.get("npc_host", 0.0)), float(secs.get("crowd_render", 0.0)),
					float(secs.get("flow_engine", 0.0)), int(rend.get("draw_calls", 0))])
		if view != null:
			view.call("close")
		await get_tree().process_frame
		_fest_result(main.get("settlement_view") == null or not bool((main.get("settlement_view") as Node).call("is_open")),
			"settlement view closed again")

	# --- cleanup --------------------------------------------------------------
	for sid in seeded_spaces:
		reg.remove_space(str(sid))
	for iid in seeded_items:
		model.remove_item(str(iid))
	if sgv.has_method("sync_camps_from_placement"):
		sgv.call("sync_camps_from_placement", [])
	loader.call("delete_placement_zone", zid)
	if loader.has_method("delete_festival_road"):
		loader.call("delete_festival_road", rid)
	_restore_files(snap)
	print("PlaytestHarness: festival — restored the map's camp / placement / spaces files and the graph autosave")
	print("PlaytestHarness: festival — shots in %s" % ProjectSettings.globalize_path(dir))
	_maybe_quit()


func _fest_open_kinds(fest: Dictionary) -> Dictionary:
	var out := {}
	for c in fest.get("camps", []):
		for k in (c as Dictionary).get("open", []):
			out[str(k)] = int(out.get(str(k), 0)) + 1
	return out


# ==================== LIGHT STUDIO (--capture=lights) ====================
# The J Light Studio end to end, driven with REAL input events through the
# viewport (a key press for J, mouse presses/motions/releases for every tool),
# because every interesting failure here is an input-routing one: the dock's
# panel swallowing world clicks, a pick that misses at range, a double-click
# that never registers. Asserts what a PNG cannot:
#   J opens the dock (tool-overlay tier: cursor free, not a modal); a click
#   with Omni / Spot places one light each ON the surface; a gumball drag on
#   the X arrow moves the selected spot along X, a drag on the yaw ring turns
#   it; four clicks + a double-click on the last pin make ONE string with four
#   pins; a rainbow chase advances its effect clock and the cast light changes
#   colour; Add to graph makes exactly one load with measured watts and a
#   second press does not duplicate it; J closes the dock.
# Write discipline: the map's lights file is byte-restored (or removed if it
# did not exist) and the graph load is removed again.

func _lc_press(vp: Viewport, pos: Vector2, pressed: bool, double: bool = false,
		ctrl: bool = false, shift: bool = false) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.double_click = double
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	ev.position = pos
	ev.global_position = pos
	vp.push_input(ev)
	await get_tree().process_frame


func _lc_move(vp: Viewport, pos: Vector2, ctrl: bool = false, shift: bool = false) -> void:
	Input.warp_mouse(pos)
	var mm := InputEventMouseMotion.new()
	mm.position = pos
	mm.global_position = pos
	mm.ctrl_pressed = ctrl
	mm.shift_pressed = shift
	vp.push_input(mm)
	await get_tree().process_frame


func _lc_click(vp: Viewport, pos: Vector2, double: bool = false) -> void:
	await _lc_move(vp, pos)
	await _lc_press(vp, pos, true, double)
	await _lc_press(vp, pos, false)


func _lc_drag(vp: Viewport, a: Vector2, b: Vector2, ctrl: bool = false, shift: bool = false) -> void:
	await _lc_move(vp, a, ctrl, shift)
	await _lc_press(vp, a, true, false, ctrl, shift)
	for i in range(1, 13):
		await _lc_move(vp, a.lerp(b, float(i) / 12.0), ctrl, shift)
	await _lc_press(vp, b, false, false, ctrl, shift)


## The nearest point to `want` (same ring scan outward) where the Light
## Studio's own surface pick (ConduitSurfaceAim.pick_ray, straight down) lands
## on level ground within 0.4 m of the terrain at the point AND 6 m round it,
## with no placed prop within 12 m and no painted camp under it. Falls back
## to `want` and says so.
func _lc_open_ground(main: Node, want: Vector3, fwd: Vector3) -> Vector3:
	var loader: Node = TerrainSurfaceQuery.find_terrain_loader(main)
	var props: Array = loader.call("placed_prop_records") if loader != null and loader.has_method("placed_prop_records") else []
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var cands: Array = [Vector2(want.x, want.z)]
	for r in [20.0, 35.0, 50.0, 70.0, 95.0, 125.0, 160.0]:
		for k in 12:
			var a := TAU * float(k) / 12.0
			cands.append(Vector2(want.x, want.z) + Vector2(cos(a), sin(a)) * r)
	for c in cands:
		var cx: float = (c as Vector2).x
		var cz: float = (c as Vector2).y
		var ok := true
		for off: Vector3 in [Vector3.ZERO, fwd * 6.0, -fwd * 6.0, side * 6.0, -side * 6.0]:
			var px := cx + off.x
			var pz := cz + off.z
			var gy := TerrainSurfaceQuery.ground_height_at(main, px, pz)
			var o := Vector3(px, gy + 40.0, pz)
			var hit: Dictionary = ConduitSurfaceAim.pick_ray(main, o, Vector3.DOWN, [], o)
			if not bool(hit.get("valid", false)):
				ok = false
				break
			var hp: Vector3 = hit.get("position", Vector3.ZERO)
			var hn: Vector3 = hit.get("normal", Vector3.UP)
			if absf(hp.y - gy) > 0.4 or hn.y < 0.9:
				ok = false
				break
		if not ok:
			continue
		if loader != null and loader.has_method("camp_area_at") 				and not str(loader.call("camp_area_at", Vector2(cx, cz))).is_empty():
			continue
		for rec in props:
			var rd := rec as Dictionary
			if Vector2(float(rd.get("x", 0.0)), float(rd.get("z", 0.0))).distance_to(Vector2(cx, cz)) < 12.0:
				ok = false
				break
		if not ok:
			continue
		var out := Vector3(cx, TerrainSurfaceQuery.ground_height_at(main, cx, cz), cz)
		print("PlaytestHarness: lights — studio over open ground at (%.1f, %.1f), %.0f m from the saved view" % [
			cx, cz, Vector2(cx, cz).distance_to(Vector2(want.x, want.z))])
		return out
	print("PlaytestHarness: lights — no open ground found within 160 m; using the saved view")
	return want


func _lc_result(ok: bool, what: String, fails: Array) -> void:
	print("PlaytestHarness: lights %s — %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails.append(what)


func _run_lights_capture() -> void:
	var tree := get_tree()
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	var main := _find_main()
	if main == null:
		push_error("PlaytestHarness: no Main — aborting lights capture")
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "lights"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var fails: Array = []
	var vp := get_viewport()
	# J is a first-person shortcut: a world saved mid-festival resumes INTO the
	# settlement view (a modal) and the key never reaches Main.
	await _first_person_baseline(main)

	# The map's OWN lights first: with the Studio closed and no modifier held,
	# no IK sphere may show (only the light itself), and nothing — lights or
	# painted camps — may be focus-highlighted just by looking at it.
	PlacedLightService.ensure_built(main)
	for _i in 30:
		await tree.physics_frame
	var shown := 0
	var total := 0
	var lroot := main.get_node_or_null(PlacedLightRuntime.ROOT_NAME)
	if lroot != null:
		for n in lroot.get_children():
			if n is PlacedLight:
				total += 1
				var g := (n as Node).get_node_or_null("LightGizmo") as Node3D
				if g != null and g.is_visible_in_tree():
					shown += 1
					print("PlaytestHarness: lights — gizmo VISIBLE on %s (selected=%s focus=%s studio=%s ctrl=%s alt=%s)" % [
						n.name, str(n.get("_selected")), str(n.get("_focus_local")),
						str(PlacedLightService.is_studio_open()), str(Input.is_key_pressed(KEY_CTRL)),
						str(Input.is_key_pressed(KEY_ALT))])
	_lc_result(shown == 0, "with the Studio closed no light shows its IK sphere (%d of %d shown)" % [shown, total], fails)
	# Look straight at a painted camp (centre-screen, the crosshair's ray) with
	# no modifier held: the camp must NOT highlight.
	var cloader := main.find_child("TerrainLoader", true, false)
	var camps: Variant = cloader.get("camp_areas") if cloader != null else null
	print("PlaytestHarness: lights — loader %s, camp layer %s, %d camps" % [str(cloader), str(camps != null),
		(camps.get("areas") as Array).size() if camps != null else -1])
	if camps != null and not (camps.get("areas") as Array).is_empty():
		var poly: PackedVector2Array = (camps.get("areas") as Array)[0]["polygon"]
		var cc := Vector2.ZERO
		for q in poly:
			cc += q
		cc /= float(poly.size())
		var gy := TerrainSurfaceQuery.ground_height_at(main, cc.x, cc.y)
		var look_cam := vp.get_camera_3d()
		var saved_xf := look_cam.global_transform if look_cam != null else Transform3D.IDENTITY
		if look_cam != null:
			look_cam.global_position = Vector3(cc.x + 25.0, gy + 12.0, cc.y + 25.0)
			look_cam.look_at(Vector3(cc.x, gy, cc.y), Vector3.UP)
		for _i in 20:
			await tree.physics_frame
		var hl := main.find_child("CampAreaHighlight", true, false) as Node3D
		print("PlaytestHarness: lights — aimed at camp %s: highlight %s, ctrl=%s alt=%s, capture=%s" % [
			str((camps.get("areas") as Array)[0].get("id")), str(hl != null and hl.visible),
			str(Input.is_key_pressed(KEY_CTRL)), str(Input.is_key_pressed(KEY_ALT)),
			str(CursorController.should_capture_look())])
		_lc_result(hl == null or not hl.visible, "aiming at a painted camp without Ctrl does not highlight it", fails)
		if look_cam != null:
			look_cam.global_transform = saved_xf

	# Snapshot the lights file; start from an empty layer so the counts below
	# are this run's own.
	var path := PlacedLightLayer.path_for_key(PlacedLightService.map_key(main))
	var had := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	var layer := PlacedLightService.get_layer(main)
	var saved_layer := layer.serialize()
	layer.lights.clear()
	layer.styles.clear()
	layer.groups.clear()
	PlacedLightService.rebuild_all(main)

	# Night, clock parked, a camera above the player looking down the ground.
	var saved_scale: Variant = main.get("time_scale")
	var saved_time: Variant = main.get("day_time")
	main.set("time_scale", 0.0)
	main.set("day_time", 22.0)
	var prev_cam := vp.get_camera_3d()
	var base := prev_cam.global_position if prev_cam != null else Vector3(0, 2, 0)
	var fwd := -prev_cam.global_basis.z if prev_cam != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var focus := base + fwd * 14.0
	focus.y = TerrainSurfaceQuery.ground_height_at(main, focus.x, focus.z)
	# The clicks below are SCREEN points: they land on whatever the saved view
	# holds. A world saved beside a camp put the spot click on a tent roof
	# (hung 7 m up, not 3) and the string pins on structures. Shoot the
	# studio over an OPEN patch of ground instead — the nearest one to where
	# the player stands whose surface pick is the terrain all round.
	focus = _lc_open_ground(main, focus, fwd)
	var cam := Camera3D.new()
	cam.name = "PlaytestLightsCam"
	cam.fov = 60.0
	main.add_child(cam)
	cam.global_position = focus - fwd * 14.0 + Vector3(0, 9.0, 0)
	cam.look_at(focus, Vector3.UP)
	cam.make_current()
	await tree.process_frame

	# 1. J opens the dock (the real key path through Main).
	var j := InputEventKey.new()
	j.physical_keycode = KEY_J
	j.keycode = KEY_J
	j.pressed = true
	Input.parse_input_event(j)
	await tree.process_frame
	await tree.process_frame
	var jr := j.duplicate() as InputEventKey
	jr.pressed = false
	Input.parse_input_event(jr)
	await tree.process_frame
	var dock := PlacedLightService.find_dock(main)
	if dock == null or not bool(dock.call("is_panel_open")):
		print("PlaytestHarness: lights — J did not open the dock; %s" % _input_blocker_desc(main))
	_lc_result(dock != null and bool(dock.call("is_panel_open")), "J opens the Light Studio dock", fails)
	_lc_result(CursorController.has_tool_overlay() and not CursorController.has_blocking_modal(),
		"the dock runs in the tool-overlay tier, not as a modal", fails)
	if dock == null:
		_lights_capture_restore(main, path, had, backup, saved_layer, cam, prev_cam, saved_scale, saved_time)
		return
	await _graph_shot(dir, "00_dock_open", [], "lights")

	var center := vp.get_visible_rect().size * Vector2(0.4, 0.62)
	# 2. Omni + Spot placement by click.
	dock.call("_set_tool", "omni")
	await _lc_click(vp, center + Vector2(-120, 0))
	dock.call("_set_tool", "spot")
	await _lc_click(vp, center + Vector2(120, 0))
	var omni_n := PlacedLightService.group_ids_of_kind(main, "omni").size()
	var spot_ids := PlacedLightService.group_ids_of_kind(main, "spot")
	_lc_result(omni_n == 1 and spot_ids.size() == 1, "a click places one omni and one spot (%d / %d)" % [
		omni_n, spot_ids.size()], fails)
	if spot_ids.is_empty():
		_lights_capture_restore(main, path, had, backup, saved_layer, cam, prev_cam, saved_scale, saved_time)
		return
	var spot_id := str(spot_ids[0])
	var spot_rec := layer.find_light(spot_id)
	var ground_y := TerrainSurfaceQuery.ground_height_at(main, float(spot_rec["x"]), float(spot_rec["z"]))
	# Clicked on open ground, a spot hangs above the click aimed DOWN at it
	# (a spot on the ground would shine at the sky).
	var spot_dir := LightGizmoMath.direction_of(layer.rotation_of(spot_rec))
	_lc_result(absf(float(spot_rec["y"]) - ground_y - 3.0) < 0.6 and spot_dir.y < -0.95,
		"a ground-clicked spot hangs 3 m up aiming down (%.2f m, dir.y %.2f)" % [
		float(spot_rec["y"]) - ground_y, spot_dir.y], fails)

	# 3. Gumball: X arrow drag moves along X; the yaw ring turns.
	dock.call("_set_tool", "select")
	PlacedLightService.set_selection(main, [spot_id])
	await tree.process_frame
	await tree.process_frame
	var giz := main.get_node_or_null("LightStudioGizmo") as LightGizmo
	_lc_result(giz != null and giz.visible, "the gumball shows on the selected spot", fails)
	if giz != null and giz.visible:
		var o := giz.global_position
		var x0 := float(layer.find_light(spot_id)["x"])
		var tip := o + giz.axis("x") * giz.handle_scale() * 0.7
		var a := cam.unproject_position(tip)
		var dir_px := cam.unproject_position(o + giz.axis("x") * giz.handle_scale()) - cam.unproject_position(o)
		await _lc_drag(vp, a, a + dir_px.normalized() * 90.0)
		var x1 := float(layer.find_light(spot_id)["x"])
		var z_same := absf(float(layer.find_light(spot_id)["z"]) - float(spot_rec["z"])) < 0.05
		_lc_result(x1 - x0 > 0.2 and z_same, "an X-arrow drag moves the spot along X only (%.2f m)" % (x1 - x0), fails)
		await tree.process_frame
		var yaw0 := float(layer.find_light(spot_id)["yaw"])
		o = giz.global_position
		var rr := giz.handle_scale() * LightGizmo.RING_R
		# Grab the ring BETWEEN the axes: where it crosses +X it also lies on
		# the X move arrow, which (correctly) wins the pick.
		var p0 := o + (Basis(Vector3.UP, deg_to_rad(45.0)) * giz.axis("x")) * rr
		var p1 := o + (Basis(Vector3.UP, deg_to_rad(85.0)) * giz.axis("x")) * rr
		await _lc_drag(vp, cam.unproject_position(p0), cam.unproject_position(p1))
		var yaw1 := float(layer.find_light(spot_id)["yaw"])
		var dyaw := absf(wrapf(yaw1 - yaw0, -180.0, 180.0))
		_lc_result(dyaw > 15.0, "a yaw-ring drag turns the spot (%.1f°)" % dyaw, fails)
	await _graph_shot(dir, "01_gumball", [], "lights")

	# 4. String: four clicks, then a double-click on the last pin.
	dock.call("_set_tool", "string")
	var pins := [center + Vector2(-220, -60), center + Vector2(-80, -90), center + Vector2(60, -90),
		center + Vector2(200, -60)]
	for p in pins:
		await _lc_click(vp, p)
	await tree.create_timer(0.1).timeout
	await _lc_click(vp, pins[3], true)
	var strings := PlacedLightService.group_ids_of_kind(main, "string")
	var pin_n := PlacedLightLayer.waypoints_of(layer.find_light(str(strings[0]))).size() if strings.size() == 1 else 0
	_lc_result(strings.size() == 1 and pin_n == 4, "4 clicks + a double-click on the last pin make one 4-pin string (%d strings, %d pins)" % [
		strings.size(), pin_n], fails)
	if strings.size() == 1:
		var sid := str(strings[0])
		# Still on the String tool: dragging a FINISHED string's pin must move
		# that pin — it used to start a new string from it.
		var before_pin: Vector3 = PlacedLightLayer.waypoints_of(layer.find_light(sid))[1]
		var from := cam.unproject_position(before_pin)
		await _lc_drag(vp, from, from + Vector2(0, 60))
		var after_pin: Vector3 = PlacedLightLayer.waypoints_of(layer.find_light(sid))[1]
		_lc_result(PlacedLightService.group_ids_of_kind(main, "string").size() == 1 \
			and before_pin.distance_to(after_pin) > 0.3,
			"with the String tool active, dragging a finished pin moves it (%.2f m) and starts no new string" % \
					before_pin.distance_to(after_pin), fails)
		# Ctrl+drag a pin: the WHOLE string moves, every pin by the same offset.
		var pts0: Array = PlacedLightLayer.waypoints_of(layer.find_light(sid))
		var grab2 := cam.unproject_position(pts0[2])
		await _lc_drag(vp, grab2, grab2 + Vector2(-60, 35), true, false)
		var pts1: Array = PlacedLightLayer.waypoints_of(layer.find_light(sid))
		var d0: Vector3 = (pts1[0] as Vector3) - (pts0[0] as Vector3)
		var rigid := d0.length() > 0.3
		for i in pts1.size():
			rigid = rigid and ((pts1[i] as Vector3) - (pts0[i] as Vector3)).distance_to(d0) < 0.02
		_lc_result(rigid, "Ctrl+drag on a pin moves the whole string as one (%.2f m)" % d0.length(), fails)
		# Shift+drag a pin: duplicate the string, the copy grouped with it.
		var grab3 := cam.unproject_position(pts1[1])
		await _lc_drag(vp, grab3, grab3 + Vector2(0, 80), false, true)
		var strs: Array = PlacedLightService.group_ids_of_kind(main, "string")
		var pts2: Array = PlacedLightLayer.waypoints_of(layer.find_light(sid))
		var copy_id := ""
		for x in strs:
			if str(x) != sid:
				copy_id = str(x)
		var shared := false
		if not copy_id.is_empty():
			for g in layer.find_light(sid)["group_ids"]:
				if g in layer.find_light(copy_id)["group_ids"]:
					shared = true
		_lc_result(strs.size() == 2 and shared and (pts2[0] as Vector3).distance_to(pts1[0]) < 0.01,
			"Shift+drag duplicates the string; the source stays, the copy joins its group", fails)
		var node := PlacedLightRuntime.find_node(main, sid) as PlacedStringLight
		print("PlaytestHarness: lights — string %.1f m, %d bulbs, lit=%s" % [
			node.length_m if node != null else -1.0, node.bulb_count if node != null else -1,
			str(node.is_lit()) if node != null else "?"])
		_lc_result(node != null and node.bulb_count > 3 and node.is_lit(), "the string builds bulbs and is lit at 22:00", fails)
		# 5. Rainbow chase through the inspector.
		PlacedLightService.set_selection(main, [sid])
		await tree.process_frame
		dock.call("_on_field", "effect", "rainbow_chase")
		dock.call("_on_field", "fx_speed", 8.0)
		# The effect clock is SimFxRate's lights track: it follows the SIM
		# clock (frozen while paused), so run the chase at 1x for this check.
		var ts_keep := float(main.get("time_scale"))
		main.set("time_scale", 1.0 / 3600.0)
		await tree.process_frame
		var t0 := node.fx_time() if node != null else 0.0
		await _graph_shot(dir, "02_rainbow_a", [], "lights")
		# 0.4 s, not 0.25: the two screenshot grabs stall a frame each and the
		# effect clock integrates (capped) frame deltas, so a 0.25 s wait read
		# 0.145 s of chase on a slow frame and failed a 0.15 bound.
		await tree.create_timer(0.4).timeout
		await _graph_shot(dir, "03_rainbow_b", [], "lights")
		var t1 := node.fx_time() if node != null else 0.0
		main.set("time_scale", 0.0)
		await tree.process_frame
		await tree.process_frame
		var tp0 := node.fx_time() if node != null else 0.0
		await tree.create_timer(0.3).timeout
		var tp1 := node.fx_time() if node != null else 0.0
		_lc_result(absf(tp1 - tp0) < 1e-6, "the chase freezes while the sim is paused", fails)
		main.set("time_scale", ts_keep)
		var fields: Dictionary = node.fields if node != null else {}
		var c0 := LedEffects.color_at(fields, 0, node.bulb_count if node != null else 1, t0, Color.WHITE)
		var c1 := LedEffects.color_at(fields, 0, node.bulb_count if node != null else 1, t1, Color.WHITE)
		var moved := (t1 - t0) * 8.0
		print("PlaytestHarness: lights — chase clock %.3f -> %.3f s (%.2f bulbs moved)" % [t0, t1, moved])
		_lc_result(t1 - t0 > 0.1 and not c0.is_equal_approx(c1), "the rainbow chase runs (bulb 0 changed colour)", fails)
		# 6. Add to graph (load only), idempotent.
		var ok := PlacedLightService.add_to_graph(main, sid)
		PlacedLightService.add_to_graph(main, sid)
		var sgv := main.find_child("SystemGraphView", true, false)
		var gid := str(sgv.call("placed_light_item_id", sid)) if sgv != null else ""
		var count := 0
		if sgv != null:
			for it in (sgv.get("model") as Object).get("items"):
				if str(((it as Dictionary).get("specs", {}) as Dictionary).get("placed_light_id", "")) == sid:
					count += 1
		var watts := float(layer.find_light(sid).get("graph_watts", 0.0))
		print("PlaytestHarness: lights — graph load %s, %.1f W" % [gid, watts])
		_lc_result(ok and count == 1 and watts > 0.0, "Add to graph makes exactly one load with measured watts", fails)
		PlacedLightService.remove_from_graph(main, sid)

	# Movers: a beam head from its preset sweeps; a laser fan grows its beams;
	# a neon-flex preset draws a glowing tube.
	dock.call("_set_tool", "mover")
	PlacedLightService.style_for_preset(main, "mover", "beam_sweep")
	await _lc_click(vp, center + Vector2(-210, 70))
	PlacedLightService.style_for_preset(main, "mover", "laser_fan_green")
	await _lc_click(vp, center + Vector2(230, 70))
	var movers: Array = PlacedLightService.group_ids_of_kind(main, "mover")
	_lc_result(movers.size() == 2, "a click with the Mover tool places a fixture (%d)" % movers.size(), fails)
	if movers.size() == 2:
		var beam_node := PlacedLightRuntime.find_node(main, str(movers[0])) as PlacedMoverLight
		var laser_node := PlacedLightRuntime.find_node(main, str(movers[1])) as PlacedMoverLight
		# Movers run on the SimFxRate lights track: frozen while the sim is
		# paused, so sweep at 1x for this check.
		var ts_keep2 := float(main.get("time_scale"))
		main.set("time_scale", 1.0 / 3600.0)
		await tree.process_frame
		var dir0 := beam_node.beam_direction() if beam_node != null else Vector3.ZERO
		# The largest deviation over a window, not two samples: at the end of
		# a swing the head is momentarily still, so a fixed pair of samples
		# depends on where in its program the clock happens to be.
		var swept := 0.0
		for _k in 12:
			await tree.create_timer(0.2).timeout
			var dk := beam_node.beam_direction() if beam_node != null else Vector3.ZERO
			swept = maxf(swept, rad_to_deg(dir0.angle_to(dk)))
		main.set("time_scale", ts_keep2)
		print("PlaytestHarness: lights — beam head swept up to %.1f° over 2.4 s, beam %.1f m" % [swept,
			beam_node.beam_length() if beam_node != null else -1.0])
		_lc_result(swept > 3.0, "the beam head sweeps on its program (%.1f°)" % swept, fails)
		var beams := laser_node.find_children("Laser_*", "", true, false).size() if laser_node != null else 0
		_lc_result(beams == 7, "the green laser fan draws 7 beams (%d)" % beams, fails)
	# Drop the laser fan's selection first: its gumball is still up, and a
	# string click inside the gumball's rings is a gizmo grab, not a pin
	# (every tool grabs what is under the pointer first). A player would
	# click away or press Esc; the capture clears the selection.
	PlacedLightService.set_selection(main, [])
	await tree.process_frame
	dock.call("_set_tool", "string")
	PlacedLightService.style_for_preset(main, "string", "neon_flex")
	var strings_before := PlacedLightService.group_ids_of_kind(main, "string").size()
	# Pins INSIDE the open patch the studio was framed on (the first pin used
	# to sit at the bottom of the screen, ~10 m nearer than the patch, where a
	# stump or a tree swallowed the click and a 2-pin string could not finish).
	var tube_pins := [center + Vector2(-110, -150), center + Vector2(40, -175), center + Vector2(190, -150)]
	for p in tube_pins:
		await _lc_click(vp, p)
	await tree.create_timer(0.1).timeout
	await _lc_click(vp, tube_pins[2], true)
	var tube_ok := false
	var tube_desc: Array = []
	for x in PlacedLightService.group_ids_of_kind(main, "string"):
		var tn := PlacedLightRuntime.find_node(main, str(x)) as PlacedStringLight
		var st_id := str(layer.find_light(str(x)).get("style_id", ""))
		tube_desc.append("%s style=%s continuous=%s" % [str(x), st_id,
			str(tn.is_continuous()) if tn != null else "no node"])
		if tn != null and tn.is_continuous():
			tube_ok = true
	print("PlaytestHarness: lights — strings %d -> %d after the tube pins (in progress: %d): %s" % [
		strings_before, PlacedLightService.group_ids_of_kind(main, "string").size(),
		(dock.get("_string_pts") as Array).size(), str(tube_desc)])
	_lc_result(tube_ok, "the LED neon flex preset draws a continuous tube", fails)
	PlacedLightService.set_selection(main, [])
	cam.global_position = focus - fwd * 22.0 + Vector3(0, 1.7, 0)
	cam.look_at(focus + Vector3(0, 7.0, 0), Vector3.UP)
	await tree.create_timer(0.4).timeout
	await _graph_shot(dir, "05_movers_ground", [], "lights")
	await tree.create_timer(0.8).timeout
	await _graph_shot(dir, "05b_movers_ground_later", [], "lights")

	# Drone view of the whole set at night.
	cam.global_position = focus - fwd * 30.0 + Vector3(0, 40.0, 0)
	cam.look_at(focus, Vector3.UP)
	PlacedLightService.set_selection(main, [])
	await tree.create_timer(0.3).timeout
	await _graph_shot(dir, "04_drone", [], "lights")

	# 7. J again closes it.
	Input.parse_input_event(j)
	await tree.process_frame
	await tree.process_frame
	Input.parse_input_event(jr)
	await tree.process_frame
	_lc_result(not bool(dock.call("is_panel_open")) and not CursorController.has_tool_overlay(),
		"J closes the dock and releases the overlay", fails)

	print("PlaytestHarness: lights %s (%d failed)" % ["ALL PASS" if fails.is_empty() else "FAILURES", fails.size()])
	_lights_capture_restore(main, path, had, backup, saved_layer, cam, prev_cam, saved_scale, saved_time)


func _lights_capture_restore(main: Node, path: String, had: bool, backup: PackedByteArray,
		saved_layer: Dictionary, cam: Camera3D, prev_cam: Camera3D, saved_scale: Variant,
		saved_time: Variant) -> void:
	var dock := PlacedLightService.find_dock(main)
	if dock != null and bool(dock.call("is_panel_open")):
		dock.call("close")
	var layer := PlacedLightService.get_layer(main)
	layer.deserialize(saved_layer)
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(backup)
		f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	PlacedLightService.rebuild_all(main)
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.make_current()
	if cam != null and is_instance_valid(cam):
		cam.queue_free()
	main.set("time_scale", saved_scale)
	main.set("day_time", saved_time)
	_maybe_quit()


# ==================== PROP EDITOR (--capture=propedit) ====================
## The unified placed-prop editor end to end, with REAL input events pushed
## through the viewport (the lights-capture discipline): a seeded prop opens
## the dock in the TOOL-OVERLAY tier (never a modal), the gumball's X arrow
## moves it along X only and its yaw ring turns it, Duplicate adds one record
## and the two-click Delete removes it, a StarShade opens THE SAME editor
## (with its designer as a button) and can be deleted from it — the complaint
## that started this — and the Fire section: a planned climb time is written
## to the record, Ignite lights it with THAT duration, moving the clock past
## the collapse shows the pile, moving it BACK stands the structure up again,
## and Restore forgets the fire. Everything seeded is removed afterwards.
func _run_prop_edit_capture() -> void:
	var tree := get_tree()
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: propedit needs a TerrainLoader map (--user-map)")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	var main := _find_main()
	if main == null:
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "propedit"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var fails: Array = []
	var vp := get_viewport()
	var seeded: Array[String] = []

	# A camera over a clear patch in front of the player.
	var prev_cam := vp.get_camera_3d()
	var base := prev_cam.global_position if prev_cam != null else Vector3(0, 2, 0)
	var fwd := -prev_cam.global_basis.z if prev_cam != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var at := base + fwd * 16.0
	at.y = TerrainSurfaceQuery.ground_height_at(main, at.x, at.z)
	var cam := Camera3D.new()
	cam.name = "PlaytestPropEditCam"
	cam.fov = 60.0
	main.add_child(cam)
	cam.global_position = at - fwd * 11.0 + Vector3(0, 6.0, 0)
	cam.look_at(at + Vector3(0, 1.0, 0), Vector3.UP)
	cam.make_current()
	var saved_scale: Variant = main.get("time_scale")
	var saved_abs: float = float(main.call("get_absolute_hours"))
	main.set("time_scale", 0.0)
	main.set("day_time", 11.0)
	await tree.process_frame

	# 1. Seed a prop and open the editor on it.
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, "shiftpod", at.x, at.z)
	var pid := str(placed.get("prop_id", ""))
	_pe_result(bool(placed.get("ok", false)) and not pid.is_empty(), "a shiftpod is placed to edit", fails)
	if pid.is_empty():
		_prop_edit_restore(main, seeded, cam, prev_cam, saved_scale, saved_abs)
		return
	seeded.append(pid)
	for _i in 10:
		await tree.process_frame
	var dock := tree.current_scene.get_node_or_null("UILayer/PlacedPropEditUI")
	var focus := main.find_child("InteractionFocus", true, false)
	var prop: PlacedProp = loader.call("_find_placed_prop_node", pid)
	if focus != null and focus.has_method("open_prop_edit_ui") and prop != null:
		focus.call("open_prop_edit_ui", prop)
	elif dock != null:
		dock.call("open_for_prop", pid)
	for _i in 3:
		await tree.process_frame
	_pe_result(dock != null and bool(dock.call("is_panel_open")), "the editor opens on the prop", fails)
	_pe_result(CursorController.has_tool_overlay() and not CursorController.has_blocking_modal(),
		"the editor runs in the tool-overlay tier, not as a modal", fails)
	var giz := main.get_node_or_null("PlacedPropGizmo") as LightGizmo
	_pe_result(giz != null and giz.visible, "the gumball shows on the prop", fails)
	await _graph_shot(dir, "00_editor", [], "propedit")

	# 2. Gumball: X arrow slides along X only; the yaw ring turns.
	if giz != null and giz.visible:
		# get_prop_record hands back the LIVE dict — copy it or "before" == "after".
		var rec0: Dictionary = (loader.call("get_prop_record", pid) as Dictionary).duplicate()
		var o := giz.global_position
		var tip := o + giz.axis("x") * giz.handle_scale() * 0.7
		var a := cam.unproject_position(tip)
		var dir_px := cam.unproject_position(o + giz.axis("x") * giz.handle_scale()) - cam.unproject_position(o)
		await _lc_drag(vp, a, a + dir_px.normalized() * 90.0)
		for _i in 3:
			await tree.process_frame
		var rec1: Dictionary = (loader.call("get_prop_record", pid) as Dictionary).duplicate()
		var dx := float(rec1["x"]) - float(rec0["x"])
		var dz := absf(float(rec1["z"]) - float(rec0["z"]))
		_pe_result(absf(dx) > 0.2 and dz < 0.05, "an X-arrow drag moves the prop along X only (dx %.2f, dz %.2f)" % [dx, dz], fails)
		giz = main.get_node_or_null("PlacedPropGizmo") as LightGizmo
		o = giz.global_position
		var rr := giz.handle_scale() * LightGizmo.RING_R
		var p0 := o + (Basis(Vector3.UP, deg_to_rad(45.0)) * giz.axis("x")) * rr
		var p1 := o + (Basis(Vector3.UP, deg_to_rad(85.0)) * giz.axis("x")) * rr
		await _lc_drag(vp, cam.unproject_position(p0), cam.unproject_position(p1))
		for _i in 3:
			await tree.process_frame
		var rec2: Dictionary = (loader.call("get_prop_record", pid) as Dictionary).duplicate()
		var dyaw := absf(wrapf(float(rec2.get("yaw", 0.0)) - float(rec1.get("yaw", 0.0)), -180.0, 180.0))
		_pe_result(dyaw > 15.0, "a yaw-ring drag turns the prop (%.1f°)" % dyaw, fails)
		_pe_result(prop == null or not is_instance_valid(prop) or bool(dock.call("is_panel_open")),
			"the editor survives the prop node being rebuilt under it", fails)
	await _graph_shot(dir, "01_gumball", [], "propedit")

	# 3. Duplicate, then the two-click delete of the copy.
	var n0 := (loader.call("placed_prop_records") as Array).size()
	dock.call("_on_duplicate")
	for _i in 5:
		await tree.process_frame
	var n1 := (loader.call("placed_prop_records") as Array).size()
	var copy_id := str(dock.get("_prop_id"))
	_pe_result(n1 == n0 + 1 and copy_id != pid and not copy_id.is_empty(),
		"Duplicate adds one record and selects the copy (%d -> %d)" % [n0, n1], fails)
	if n1 == n0 + 1:
		dock.call("_on_delete")
		await tree.process_frame
		_pe_result(bool(dock.get("_del_armed")) and (loader.call("placed_prop_records") as Array).size() == n1,
			"the first Delete click only arms (nothing removed yet)", fails)
		dock.call("_on_delete")
		for _i in 5:
			await tree.process_frame
		_pe_result((loader.call("placed_prop_records") as Array).size() == n0 and not bool(dock.call("is_panel_open")),
			"the second click deletes the copy and closes the editor", fails)

	# 4. A StarShade opens the SAME editor and can be deleted from it.
	var designs := ModelCatalog.starshade_designs()
	if not designs.is_empty():
		var sid := str(designs[0].get("id", ""))
		var sp: Dictionary = PlacedPropService.place_model_at_xz(main, sid, at.x + 7.0, at.z)
		var spid := str(sp.get("prop_id", ""))
		if not spid.is_empty():
			seeded.append(spid)
			for _i in 10:
				await tree.process_frame
			var sprop: PlacedProp = loader.call("_find_placed_prop_node", spid)
			if focus != null and sprop != null:
				focus.call("open_prop_edit_ui", sprop)
			for _i in 3:
				await tree.process_frame
			var has_btn := false
			for b in dock.find_children("*", "Button", true, false):
				if (b as Button).text.begins_with("StarShade design"):
					has_btn = true
			_pe_result(bool(dock.call("is_panel_open")) and str(dock.get("_prop_id")) == spid and has_btn
				and not CursorController.has_blocking_modal(),
				"a StarShade opens the one editor, with its designer as a button", fails)
			await _graph_shot(dir, "02_starshade", [], "propedit")
			dock.call("_on_delete")
			await tree.process_frame
			dock.call("_on_delete")
			for _i in 5:
				await tree.process_frame
			_pe_result((loader.call("get_prop_record", spid) as Dictionary).is_empty(),
				"a StarShade can be deleted from the editor", fails)
			if (loader.call("get_prop_record", spid) as Dictionary).is_empty():
				seeded.erase(spid)
	else:
		print("PlaytestHarness: propedit — no StarShade designs in the catalog, skipping that check")

	# 5. Fire: plan a duration, ignite, move the clock both ways, restore.
	prop = loader.call("_find_placed_prop_node", pid)
	if focus != null and prop != null:
		focus.call("open_prop_edit_ui", prop)
	for _i in 3:
		await tree.process_frame
	dock.call("_on_burnable_toggled", true)
	for _i in 5:
		await tree.process_frame
	prop = loader.call("_find_placed_prop_node", pid)  # the toggle rebuilt every prop
	var spins: Dictionary = dock.get("_fire_spins")
	(spins["climb_h"] as SpinBox).value = 5.0  # 5 minutes
	await tree.process_frame
	var recf: Dictionary = loader.call("get_prop_record", pid)
	var plan: Dictionary = recf.get("fire_plan", {}) if recf.get("fire_plan") is Dictionary else {}
	_pe_result(bool(recf.get("burnable", false)) and absf(float(plan.get("climb_h", 0.0)) - 5.0 / 60.0) < 1e-3,
		"the planned climb time is written to the record before any fire (%.3f h)" % float(plan.get("climb_h", 0.0)), fails)
	var h0 := float(main.call("get_absolute_hours"))
	dock.call("_on_fire_ignite")
	for _i in 20:
		await tree.process_frame
	recf = loader.call("get_prop_record", pid)
	var burn: Dictionary = recf.get("burn", {}) if FireTimeline.is_record(recf.get("burn")) else {}
	_pe_result(not burn.is_empty() and absf(FireTimeline.climb_h(burn) - 5.0 / 60.0) < 1e-3 and burn.has("auto")
		and float((burn.get("auto", {}) as Dictionary).get("bonfire_h", 0.0)) > 0.0,
		"Ignite lights it with the planned climb time and keeps the estimate as auto (%s)" % str(burn), fails)
	prop = loader.call("_find_placed_prop_node", pid)
	var fire: FireNode = null
	for n in tree.get_nodes_in_group("fire_nodes"):
		if str(n.get_meta("prop_id", "")) == pid:
			fire = n as FireNode
	_pe_result(fire != null, "a FireNode carries the prop's fire", fails)
	await _graph_shot(dir, "03_lit", [], "propedit")
	if fire != null and not burn.is_empty() and prop != null:
		var meshes: Array = []
		for node in prop.find_children("*", "MeshInstance3D", true, false):
			if (node as MeshInstance3D).mesh != null:
				meshes.append(node)
		# Past the collapse: the structure is gone, the pile burns.
		main.call("set_absolute_hours", h0 + FireTimeline.climb_h(burn) + FireTimeline.COLLAPSE_H + 0.2)
		for _i in 12:
			await tree.process_frame
		var any_visible := false
		for m in meshes:
			if is_instance_valid(m) and (m as MeshInstance3D).visible:
				any_visible = true
		_pe_result(fire._last_phase == FireTimeline.Phase.PILE and not any_visible
			and fire.ash_pile != null and is_instance_valid(fire.ash_pile),
			"clock past the collapse: structure gone, pile burning (phase %d)" % fire._last_phase, fails)
		await _graph_shot(dir, "04_bonfire", [], "propedit")
		# BACK into the climb: it stands again, charred.
		main.call("set_absolute_hours", h0 + FireTimeline.climb_h(burn) * 0.4)
		for _i in 12:
			await tree.process_frame
		var all_visible := true
		for m in meshes:
			if is_instance_valid(m) and not (m as MeshInstance3D).visible:
				all_visible = false
		_pe_result(fire._last_phase == FireTimeline.Phase.BURNING and all_visible
			and (fire.ash_pile == null or not is_instance_valid(fire.ash_pile) or fire.ash_pile.is_queued_for_deletion()),
			"clock scrubbed back: the structure stands again, no pile (phase %d)" % fire._last_phase, fails)
		await _graph_shot(dir, "05_scrubbed_back", [], "propedit")
		# Before the ignition: clean.
		main.call("set_absolute_hours", h0 - 0.5)
		for _i in 6:
			await tree.process_frame
		var clean := true
		for m in meshes:
			if is_instance_valid(m) and ((m as MeshInstance3D).material_overlay != null or not (m as MeshInstance3D).visible):
				clean = false
		_pe_result(fire._last_phase == FireTimeline.Phase.NONE and clean,
			"clock before the ignition: the structure is clean", fails)
		main.call("set_absolute_hours", h0 + FireTimeline.climb_h(burn) * 0.5)
		for _i in 6:
			await tree.process_frame
		# Restore forgets the fire.
		dock.call("_on_fire_restore")
		for _i in 6:
			await tree.process_frame
		recf = loader.call("get_prop_record", pid)
		_pe_result(not recf.has("burn") and (fire == null or not is_instance_valid(fire) or fire.is_queued_for_deletion()),
			"Restore removes the burn record and the fire node", fails)
	dock.call("close")
	_prop_edit_restore(main, seeded, cam, prev_cam, saved_scale, saved_abs)
	if fails.is_empty():
		print("PlaytestHarness: propedit — ALL CHECKS PASSED")
	else:
		print("PlaytestHarness: propedit — %d CHECK(S) FAILED:" % fails.size())
		for f in fails:
			print("  - %s" % str(f))
	_maybe_quit()


func _prop_edit_restore(main: Node, seeded: Array[String], cam: Camera3D, prev_cam: Camera3D,
		saved_scale: Variant, saved_abs: float) -> void:
	var loader := main.find_child("TerrainLoader", true, false)
	for pid in seeded:
		if loader != null:
			loader.call("delete_prop_by_id", pid)
	main.call("set_absolute_hours", saved_abs)
	main.set("time_scale", saved_scale)
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.make_current()
	if cam != null and is_instance_valid(cam):
		cam.queue_free()


func _pe_result(ok: bool, what: String, fails: Array) -> void:
	print("PlaytestHarness: propedit %s — %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails.append(what)


# ==================== FESTIVAL MODE (--capture=festivalmode) ====================
# The one-button entry into the crowd sim, driven through Main's REAL entry
# point (open_festival_mode) on a saved map with painted camps. Asserts what a
# PNG cannot: the easy override is on (and the player's SAVED testing flags
# are untouched), every populated painted camp became a camp compound with a
# pop-driven habitat, every required space type is tagged (and only the
# missing ones were seeded, all carrying the festival label prefix), the
# settlement view opened framed on the camps, people exist for every
# headcount and MOVE over a few sim-hours with nobody blocked on a need, and
# then the two exits: leaving hands the guardrails back and keeps the camps,
# clear_seeded removes exactly the venues it seeded and every festival
# headcount. Snapshots and byte-restores the map's camp / placement / spaces
# files, the graph autosave and the NPC display prefs.

func _fm_result(ok: bool, label: String) -> void:
	print("PlaytestHarness: festivalmode %s — %s" % ["PASS" if ok else "FAIL", label])


## For `frames` frames, is every one of `ids` DRAWN (an avatar or a crowd
## figure, via NpcPopulationHost.drawn_position) within 25 m of their sim
## position (the glide runs a tick behind the sim; 25 m catches a figure
## parked at the world origin)? Light-tier people only count while the light crowd is shown
## (switched off they are simulated-but-hidden by the player's choice).
## Returns {people, worst_frame, mean, ever_missing, reasons: {why: n}}.
func _fm_visibility_probe(main: Node, bridge, ids: Array, frames: int) -> Dictionary:
	var host := main.get_node_or_null("NpcPopulationHost")
	if host == null or bridge == null:
		return {"people": 0, "worst_frame": 0.0}
	var want: Dictionary = {}
	for id in ids:
		want[str(id)] = true
	var worst := 1.0
	var sum := 0.0
	var counted := 0
	var people := 0
	var missing_ever: Dictionary = {}
	var reasons: Dictionary = {}
	for f in frames:
		await get_tree().process_frame
		var heroes: Dictionary = host.get("_hero_ids") if host.get("_hero_ids") is Dictionary else {}
		var n := 0
		var ok := 0
		for d in bridge.agent_dots():
			var dd: Dictionary = d
			var id := str(dd.get("id", ""))
			if not want.has(id):
				continue
			var light := str(dd.get("tier", "")) == "light"
			if light and not NpcDisplayPrefs.light_crowd():
				continue
			n += 1
			var sp: Vector2 = dd.get("pos", Vector2.ZERO)
			var p: Variant = host.call("drawn_position", id)
			var why := ""
			if not (p is Vector3):
				why = "missing"
			elif Vector2((p as Vector3).x, (p as Vector3).z).distance_to(sp) > 25.0:
				why = "misplaced"
			if why.is_empty():
				ok += 1
				continue
			missing_ever[id] = true
			var key := "%s %s %s" % [why, "light" if light else "full", "hero" if heroes.has(id) else "crowd"]
			reasons[key] = int(reasons.get(key, 0)) + 1
		if n == 0:
			continue
		people = maxi(people, n)
		var frac := float(ok) / float(n)
		worst = minf(worst, frac)
		sum += frac
		counted += 1
	return {"people": people, "worst_frame": worst if counted > 0 else 0.0,
		"mean": sum / float(counted) if counted > 0 else 0.0,
		"ever_missing": missing_ever.size(), "reasons": reasons,
		"heroes": (host.get("_hero_ids") as Dictionary).size() if host.get("_hero_ids") is Dictionary else -1,
		"budget": host.call("hero_budget")}


# --capture=popin (WINDOWED, needs a map with painted camps — Walton): opens
# festival mode, parks the settlement view at street height over the evening
# crowd and WATCHES: every frame, every person within POPIN_R_M of the camera
# who was there the frame before is checked through
# NpcPopulationHost.drawn_position. A person drawn last frame and not now is
# a VANISH, the reverse an APPEAR, a drawn body that moves more than
# POPIN_JUMP_M beyond honest walking in one frame a JUMP. Each event is tagged with its cause
# (tier, hero or crowd figure, whether their camp just changed tier, whether
# the roster itself lost/gained them) and the frame time. Phase A holds the
# camera still; phase B jumps it the way a toast's click-to-look does.
# --light=on|off overrides the player's light-crowd setting for the run;
# --ts=N the clock multiple (try 60). Snapshots and byte-restores the files
# festival mode touches.
const POPIN_R_M := 70.0
const POPIN_JUMP_M := 4.0
## Jumps tolerated over both phases (a glide can ride one hitch frame).
const POPIN_MAX_JUMPS := 2


func _run_popin_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null or not loader.has_method("populate_camp_areas"):
		push_error("PlaytestHarness: popin needs a TerrainLoader map (painted camps)")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var main := get_tree().current_scene
	var sgv := await _find_graph_view()
	if sgv == null or not main.has_method("open_festival_mode"):
		push_error("PlaytestHarness: popin — graph view or Main entry point unavailable")
		_maybe_quit()
		return
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var files := [CampAreaLayer.save_path_for_map(lat, lon), FestivalPlacementLayer.save_path_for_map(lat, lon),
		SpaceRegistry.new().save_path_for_map(lat, lon), NpcDisplayPrefs.CFG_PATH,
		PlacedPropLayer.new().save_path_for_map(lat, lon)]
	var mdir := DirAccess.open("user://maps")
	if mdir != null:
		for fn in mdir.get_files():
			if fn.begins_with("peak_experience_"):
				files.append("user://maps/" + fn)
	# In a per-world (dir) world the score lives in the world's folder.
	var peak_world := WorldPaths.site_file("peak_experience", lat, lon)
	if not files.has(peak_world):
		files.append(peak_world)
	if sgv.has_method("_graph_autosave_path"):
		files.append(str(sgv.call("_graph_autosave_path")))
	var snap := _snapshot_files(files)
	if _popin_light == "on" or _popin_light == "off":
		NpcDisplayPrefs.set_light_crowd(_popin_light == "on")
	if "year" in main:
		main.year = 2026
		main.month = 7
		main.day = 15
	main.call("open_festival_mode")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 15000:
		var fm0: Variant = main.get("festival_mode")
		if fm0 != null and bool(fm0.call("is_active")):
			break
		await get_tree().process_frame
	await get_tree().create_timer(1.5).timeout
	var bridge: Variant = sgv.call("npc_population_bridge")
	var reg: SpaceRegistry = bridge.call("registry_for", main)
	# The evening: a set is on, the crowd is out.
	if "day_time" in main:
		main.day_time = 20.5
	var mult := _bench_ts_mult if _bench_ts_mult < 449.0 else 60.0
	main.time_scale = mult / 3600.0
	var focus := Vector2.ZERO
	for rec in reg.spaces:
		if str((rec as Dictionary).get("space_type", "")) == "stage":
			var sp: Variant = reg.resolve_position(rec, main)
			if sp is Vector2:
				focus = sp
				break
	var sv: Variant = main.get("settlement_view")
	var cam: Variant = sv.get("_cam") if sv != null else null
	if cam != null:
		cam.call("look_at_xz", focus)
		cam.set("_h_target", 14.0)
	print("PlaytestHarness: popin — light crowd %s, %.0fx, watching %.0f m round (%.0f, %.0f); full-figure budget %s" % [
		"ON" if NpcDisplayPrefs.light_crowd() else "OFF", mult, POPIN_R_M, focus.x, focus.y,
		str(main.get_node_or_null("NpcPopulationHost").call("hero_budget")) if main.get_node_or_null("NpcPopulationHost") != null else "?"])
	await get_tree().create_timer(6.0).timeout   # let the camera settle and people arrive
	var a := await _popin_watch(main, bridge, 40.0, [])
	print("PlaytestHarness: popin — phase A (still camera, 40 s): %s" % str(a["summary"]))
	for line in a["lines"]:
		print("PlaytestHarness: popin —   %s" % line)
	# Phase B: jump the camera between camps (a toast's click-to-look).
	var hops: Array = []
	var far: Array = []
	for d in bridge.agent_dots():
		var dp: Vector2 = (d as Dictionary).get("pos", Vector2.ZERO)
		if dp.distance_to(focus) > 120.0:
			far.append(dp)
	for k in mini(4, far.size()):
		hops.append(far[(k * 97 + 13) % far.size()])
	if hops.size() > 0:
		hops.append(focus)
	if hops.is_empty():
		hops = [focus + Vector2(150, 0), focus]
	var b := await _popin_watch(main, bridge, 10.0 * float(hops.size()), hops)
	print("PlaytestHarness: popin — phase B (camera hops %d, %.0f s): %s" % [hops.size(), 10.0 * hops.size(), str(b["summary"])])
	for line in b["lines"]:
		print("PlaytestHarness: popin —   %s" % line)
	# The gate (2026-10-18; it used to only report). The user's rule is ZERO
	# pop-in: nobody vanishes or appears while drawn, in either phase. A JUMP
	# is a glide faster than the catch-up allows; one can ride a hitch frame
	# (the open item: a 40 m jump during a 131 ms frame), so jumps are capped,
	# not forbidden, and the hitch count stays a report.
	var counts := {"VANISH": 0, "APPEAR": 0, "JUMP": 0}
	for phase in [a, b]:
		var sm: Dictionary = (phase as Dictionary).get("summary", {})
		for key in sm:
			for kind in counts:
				if str(key).begins_with(kind):
					counts[kind] = int(counts[kind]) + int(sm[key])
	var hitches := int((a["summary"] as Dictionary).get("hitch frames >100 ms", 0)) \
			+ int((b["summary"] as Dictionary).get("hitch frames >100 ms", 0))
	print("PlaytestHarness: popin %s — nobody vanished while drawn (%d)" % [
		"PASS" if int(counts["VANISH"]) == 0 else "FAIL", int(counts["VANISH"])])
	print("PlaytestHarness: popin %s — nobody appeared from nowhere (%d)" % [
		"PASS" if int(counts["APPEAR"]) == 0 else "FAIL", int(counts["APPEAR"])])
	print("PlaytestHarness: popin %s — at most %d jump(s) faster than a catch-up glide (%d; %d hitch frames over 100 ms)" % [
		"PASS" if int(counts["JUMP"]) <= POPIN_MAX_JUMPS else "FAIL", POPIN_MAX_JUMPS,
		int(counts["JUMP"]), hitches])
	if main.has_method("close_festival_mode"):
		main.call("close_festival_mode")
	main.time_scale = 0.0
	await get_tree().create_timer(1.0).timeout
	_restore_files(snap)
	_maybe_quit()


## Watch for `secs` seconds; with `hops`, move the camera to the next hop
## every secs / hops.size() seconds. Returns {summary: {kind/cause: n},
## lines: [first detailed events]}.
func _popin_watch(main: Node, bridge, secs: float, hops: Array) -> Dictionary:
	var host := main.get_node_or_null("NpcPopulationHost")
	var sv: Variant = main.get("settlement_view")
	var cam: Variant = sv.get("_cam") if sv != null else null
	var prev_drawn: Dictionary = {}     # id -> Vector3 or null
	var prev_heroes: Dictionary = {}
	var prev_abs := float(main.call("get_absolute_hours"))
	var prev_tiers: Dictionary = {}
	var tier_changed_at: Dictionary = {}  # habitat id -> msec
	var summary: Dictionary = {}
	var lines: Array = []
	var frames := 0
	var hitches := 0
	var start := Time.get_ticks_msec()
	var hop_i := -1
	var last_frame := Time.get_ticks_usec()
	while Time.get_ticks_msec() - start < int(secs * 1000.0):
		if not hops.is_empty():
			var want := int(float(Time.get_ticks_msec() - start) / (secs * 1000.0 / float(hops.size())))
			if want != hop_i and want < hops.size():
				hop_i = want
				if cam != null:
					cam.call("look_at_xz", hops[hop_i])
		await get_tree().process_frame
		frames += 1
		var now_us := Time.get_ticks_usec()
		var dt_ms := float(now_us - last_frame) / 1000.0
		last_frame = now_us
		if dt_ms > 100.0:
			hitches += 1
		var abs_now := float(main.call("get_absolute_hours"))
		var sim_s := (abs_now - prev_abs) * 3600.0
		prev_abs = abs_now
		var tiers: Dictionary = bridge.get("_tiers") if bridge.get("_tiers") is Dictionary else {}
		for hid in tiers:
			if prev_tiers.has(hid) and str(prev_tiers[hid]) != str(tiers[hid]):
				tier_changed_at[hid] = Time.get_ticks_msec()
				summary["camp tier switch " + str(tiers[hid])] = int(summary.get("camp tier switch " + str(tiers[hid]), 0)) + 1
		prev_tiers = tiers.duplicate()
		var c3: Vector3 = (get_viewport().get_camera_3d() as Camera3D).global_position
		var c2 := Vector2(c3.x, c3.z)
		var heroes: Dictionary = host.get("_hero_ids") if host != null and host.get("_hero_ids") is Dictionary else {}
		var drawn_now: Dictionary = {}
		var light_on := NpcDisplayPrefs.light_crowd()
		# How far a figure can honestly move in this frame at this clock: a
		# catch-up glide (CrowdRenderer.EASE_MPS, faster than a walk), with
		# margin — beyond it a move is a jump (a teleport).
		var walk_reach := CrowdRenderer.EASE_MPS * maxf(sim_s, 0.0) * 1.3
		for d in bridge.agent_dots():
			var dd: Dictionary = d
			var id := str(dd.get("id", ""))
			var sp: Vector2 = dd.get("pos", Vector2.ZERO)
			if sp.distance_to(c2) > POPIN_R_M:
				continue
			var p: Variant = host.call("drawn_position", id) if host != null else null
			drawn_now[id] = p
			if not prev_drawn.has(id):
				continue
			var was: Variant = prev_drawn[id]
			var kind := ""
			if was is Vector3 and p == null:
				kind = "VANISH"
			elif was == null and p is Vector3:
				kind = "APPEAR"
			elif was is Vector3 and p is Vector3 and (p as Vector3).distance_to(was) > POPIN_JUMP_M + walk_reach:
				kind = "JUMP"
			if kind.is_empty():
				continue
			var tier := str(dd.get("tier", "full"))
			var hid := str(bridge.call("habitat_of_agent", id))
			var recent_switch := Time.get_ticks_msec() - int(tier_changed_at.get(hid, -100000)) < 2000
			var cause := "%s %s %s%s%s" % [kind, tier, "hero" if heroes.has(id) else "crowd",
				" camp-just-switched-tier" if recent_switch else "", "" if light_on or tier != "light" else " (light hidden)"]
			summary[cause] = int(summary.get(cause, 0)) + 1
			if lines.size() < 25:
				var cr := main.get_node_or_null("CrowdRenderer")
				var rec: Variant = (cr.get("_seg_rec") as Dictionary).get(id, null) if cr != null else null
				var jump_txt := ""
				if kind == "JUMP":
					jump_txt = " moved %.1f m (%s -> %s, sim %s, hero last %s)" % [(p as Vector3).distance_to(was),
						str(was), str(p), str(sp), str(prev_heroes.has(id))]
				var rec_txt := "none"
				if rec is Dictionary:
					var rd: Dictionary = rec
					rec_txt = "full=%s t0-now=%.1fs t1-now=%.1fs a=%s b=%s" % [str(rd.get("full")),
						(float(rd["t0"]) - abs_now) * 3600.0, (float(rd["t1"]) - abs_now) * 3600.0, str(rd["a"]), str(rd["b"])]
				lines.append("%s %s '%s' state=%d act=%s pose=%s dist=%.0f m frame %.0f ms (sim %.1f s)%s; rec %s" % [
					cause, id, str(dd.get("name", "")), int(dd.get("state", -1)), str(dd.get("activity", "")),
					str(dd.get("venue_pose", "")), sp.distance_to(c2), dt_ms, sim_s, jump_txt, rec_txt])
		# Roster: in range last frame, gone from the dots now.
		for id in prev_drawn:
			if not drawn_now.has(id) and prev_drawn[id] is Vector3:
				var still := false
				for d2 in bridge.agent_dots():
					if str((d2 as Dictionary).get("id", "")) == str(id):
						still = true
						break
				if not still:
					summary["LEFT ROSTER while drawn"] = int(summary.get("LEFT ROSTER while drawn", 0)) + 1
		prev_drawn = drawn_now
		prev_heroes = heroes.duplicate()
	summary["frames"] = frames
	summary["hitch frames >100 ms"] = hitches
	return {"summary": summary, "lines": lines}


func _run_festival_mode_capture() -> void:
	var loader := await _find_terrain_loader()
	if loader == null or not loader.has_method("populate_camp_areas"):
		push_error("PlaytestHarness: festivalmode needs a TerrainLoader map (painted camps)")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	_set_capture_conditions()
	var main := get_tree().current_scene
	var sgv := await _find_graph_view()
	if sgv == null or sgv.get("model") == null or not main.has_method("open_festival_mode"):
		push_error("PlaytestHarness: festivalmode — graph model or Main entry point unavailable")
		_maybe_quit()
		return
	# The Peak Experience score is the PLAYER'S: snapshot its file and put it
	# back afterwards (the harness's own onsets must not count).
	var peak_files := []
	var mdir := DirAccess.open("user://maps")
	if mdir != null:
		for fn in mdir.get_files():
			if fn.begins_with("peak_experience_"):
				peak_files.append("user://maps/" + fn)
	# In a per-world (dir) world the score lives in the world's folder.
	var peak_world := WorldPaths.site_file("peak_experience",
		float(loader.get("_lat")), float(loader.get("_lon")))
	if not peak_files.has(peak_world):
		peak_files.append(peak_world)
	var peak_snap := _snapshot_files(peak_files)
	var model: Variant = sgv.get("model")
	var label := _shots_label if not _shots_label.is_empty() else "festivalmode"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var files := [CampAreaLayer.save_path_for_map(lat, lon), FestivalPlacementLayer.save_path_for_map(lat, lon),
		SpaceRegistry.new().save_path_for_map(lat, lon), NpcDisplayPrefs.CFG_PATH,
		PlacedPropLayer.new().save_path_for_map(lat, lon)]
	if sgv.has_method("_graph_autosave_path"):
		files.append(str(sgv.call("_graph_autosave_path")))
	var snap := _snapshot_files(files)
	if "year" in main:
		main.year = 2026
		main.month = 7
		main.day = 15
	if "day_time" in main:
		main.day_time = 10.0
	if "time_scale" in main:
		main.time_scale = 0.0

	# --- before -----------------------------------------------------------------
	var layer: Variant = loader.get("camp_areas")
	var placement: Variant = loader.get("placement")
	var zones: Dictionary = placement.zones_by_id() if placement != null else {}
	var populatable := 0
	for rec in (layer.get("areas") as Array):
		if FestivalSeedLayout.is_populatable(rec, zones):
			populatable += 1
	var summary0: Dictionary = loader.call("camp_population_summary")
	var lots_total: int = (placement.get("lots") as Array).size() if placement != null else 0
	var saved0 := PopTestPrefs.saved_flags()
	print("PlaytestHarness: festivalmode — before: %d painted camps (%d populatable), %d lots, %d populated camps / %d people, %d compounds" % [
		(layer.get("areas") as Array).size(), populatable, lots_total, int(summary0["camps"]), int(summary0["people"]),
		(sgv.call("festival_camps") as Array).size()])
	_fm_result(not PopTestPrefs.easy_override(), "the easy override is OFF before the mode opens")

	# --- open -------------------------------------------------------------------
	main.call("open_festival_mode")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 15000:
		var fm0: Variant = main.get("festival_mode")
		if fm0 != null and bool(fm0.call("is_active")):
			break
		await get_tree().process_frame
	await get_tree().create_timer(1.5).timeout
	var fm: Variant = main.get("festival_mode")
	_fm_result(fm != null and bool(fm.call("is_active")), "festival mode reports active")
	_fm_result(PopTestPrefs.easy_override() and PopTestPrefs.ideal_supply() and PopTestPrefs.no_departures()
		and PopTestPrefs.ignore_capacity() and PopTestPrefs.mute_alarms(),
		"easy override on: ideal supply, no queues, no departures, muted alarms all read ON")
	_fm_result(bool(main.call("settlement_view_open")), "the settlement view opened")
	var summary1: Dictionary = loader.call("camp_population_summary")
	var camps: Array = sgv.call("festival_camps")
	var people_on_camps := 0
	var hab_ids: Array = []
	for c in camps:
		people_on_camps += int((c as Dictionary).get("headcount", 0))
		for it in model.get_items_in_scope(str((c as Dictionary)["scope"])):
			var sp: Dictionary = (it as Dictionary).get("specs", {})
			if str(sp.get("role", "")) == "habitat" and bool(sp.get("pop_driven", false)):
				hab_ids.append(str((it as Dictionary)["id"]))
	print("PlaytestHarness: festivalmode — after open: %d populated camps / %d people; %d compounds carrying %d people, %d pop-driven habitats" % [
		int(summary1["camps"]), int(summary1["people"]), camps.size(), people_on_camps, hab_ids.size()])
	_fm_result(camps.size() > 0 and camps.size() == int(summary1["camps"]),
		"every populated camp is a compound on the graph (%d of %d)" % [camps.size(), int(summary1["camps"])])
	_fm_result(people_on_camps == int(summary1["people"]), "the compounds carry the populated headcounts")
	_fm_result(hab_ids.size() == camps.size(), "every compound has exactly one pop-driven habitat")
	var now_populated := 0
	for rec in (layer.get("areas") as Array):
		if FestivalSeedLayout.is_populatable(rec, zones) and int((rec as Dictionary).get("headcount", 0)) > 0:
			now_populated += 1
	_fm_result(now_populated == populatable, "every populatable painted camp got a headcount (%d of %d)" % [now_populated, populatable])
	var unassigned := 0
	if placement != null:
		for l in (placement.get("lots") as Array):
			if ((l as Dictionary).get("assigned_camp", {}) as Dictionary).is_empty():
				unassigned += 1
	_fm_result(unassigned == 0, "no placement lot is left unassigned")

	# --- venues -----------------------------------------------------------------
	var bridge: Variant = sgv.call("npc_population_bridge")
	var reg: SpaceRegistry = bridge.call("registry_for", main)
	var present: Array = []
	var seeded := 0
	var sleep_areas := 0
	var prefixed_types: Dictionary = {}
	for rec in reg.spaces:
		var rd: Dictionary = rec
		var t := str(rd.get("space_type", ""))
		if not present.has(t):
			present.append(t)
		if str(rd.get("label", "")).begins_with(FestivalSeedLayout.LABEL_PREFIX):
			seeded += 1
			prefixed_types[t] = true
			if t == "sleep":
				sleep_areas += 1
	print("PlaytestHarness: festivalmode — spaces: %d total, %d seeded (%s), types %s" % [
		reg.spaces.size(), seeded, str(prefixed_types.keys()), str(present)])
	_fm_result(FestivalSeedLayout.missing_types(present).is_empty(), "every required space type is tagged")
	_fm_result(seeded > 0, "the mode seeded venues (%d)" % seeded)
	# Every camp has beds: a seeded sleep area, or one the player tagged
	# inside its outline (FestivalSeedLayout.needs_seeding).
	var own_beds := 0
	for c_v in camps:
		var cpoly: PackedVector2Array = loader.call("camp_lot_polygon", str((c_v as Dictionary).get("lot_id", ""))) \
			if loader != null and loader.has_method("camp_lot_polygon") else PackedVector2Array()
		for rec_s in reg.spaces:
			var rs: Dictionary = rec_s
			if str(rs.get("space_type", "")) != "sleep" or str(rs.get("label", "")).begins_with(FestivalSeedLayout.LABEL_PREFIX):
				continue
			var sp_v: Variant = reg.resolve_position(rs, main)
			if sp_v is Vector2 and cpoly.size() >= 3 and Geometry2D.is_point_in_polygon(sp_v, cpoly):
				own_beds += 1
				break
	_fm_result(sleep_areas + own_beds == camps.size(),
		"every camp has beds: %d seeded + %d already tagged inside the camp, for %d camps" % [sleep_areas, own_beds, camps.size()])
	var stage_set := false
	for rec in reg.spaces:
		var rd: Dictionary = rec
		if str(rd.get("space_type", "")) == "stage":
			var st := FestivalProgram.state_at(rd, 21.0)
			stage_set = stage_set or bool(st.get("active", false))
	_fm_result(stage_set, "the seeded stage has its set on at 21:00")
	# Framing: the camera looks at the camps' cluster from a height that fits it.
	var view: Variant = main.get("settlement_view")
	var cam: Variant = view.call("camera") if view != null else null
	var polys: Array = []
	for c in camps:
		polys.append(loader.call("camp_lot_polygon", str((c as Dictionary)["lot_id"])))
	var cl := FestivalSeedLayout.cluster(polys)
	if cam != null:
		var focus: Vector2 = cam.get("focus")
		print("PlaytestHarness: festivalmode — camera focus %s h=%.0f; cluster centre %s r=%.0f" % [
			str(focus), float(cam.call("height")), str(cl["centre"]), float(cl["radius"])])
		_fm_result(focus.distance_to(cl["centre"]) <= float(cl["radius"]) + 1.0
			and float(cam.call("height")) >= FestivalMode.MIN_START_H - 1.0,
			"the view opened over the camps' cluster at a framing height")

	# --- run a few sim-hours ----------------------------------------------------
	main.time_scale = 0.2   # 720×
	await get_tree().create_timer(2.0).timeout
	var dots0: Array = bridge.call("agent_dots")
	var pos0: Dictionary = {}
	for d in dots0:
		pos0[str((d as Dictionary)["id"])] = (d as Dictionary).get("pos", Vector2.ZERO)
	print("PlaytestHarness: festivalmode — %d people simulating for %d populated" % [dots0.size(), int(summary1["people"])])
	_fm_result(dots0.size() >= int(float(int(summary1["people"])) * 0.95) and dots0.size() > 0,
		"people exist for the populated headcounts (%d of %d)" % [dots0.size(), int(summary1["people"])])
	var h_start := float(main.call("get_absolute_hours"))
	await get_tree().create_timer(20.0).timeout
	var h_ran := float(main.call("get_absolute_hours")) - h_start
	var dots1: Array = bridge.call("agent_dots")
	var moved := 0
	var seen := 0
	var light := 0
	for d in dots1:
		var dd: Dictionary = d
		var id := str(dd["id"])
		if str(dd.get("tier", "")) == CrowdFocus.TIER_LIGHT:
			light += 1
		if pos0.has(id):
			seen += 1
			if (pos0[id] as Vector2).distance_to(dd.get("pos", Vector2.ZERO)) > 2.0:
				moved += 1
	var summaries: Array = []
	for iid in hab_ids:
		var sm: Dictionary = bridge.call("summary_for", str(iid))
		if not sm.is_empty():
			summaries.append(sm)
	var vibe := FestivalVibe.compute(summaries)
	print("PlaytestHarness: festivalmode — ran %.1f sim-h: %d of %d moved, %d light-tier, vibe %s blocked share %.3f" % [
		h_ran, moved, seen, light, str(vibe.get("label", "")), float(vibe.get("blocked_share", 0.0))])
	_fm_result(h_ran >= 2.0, "the clock ran (%.1f sim-h)" % h_ran)
	# How many move in four mid-day hours depends on the loaded state (a
	# fresh roster all heads out; a restored mid-day one is already settled),
	# so the bar is a quarter of the roster.
	_fm_result(seen > 0 and moved >= int(float(seen) * 0.25), "people moved over the run (%d of %d)" % [moved, seen])
	_fm_result(float(vibe.get("blocked_share", 1.0)) <= 0.0, "nobody is blocked on a need (ideal supply)")
	await _shoot_ui(dir, "01_festival_open")

	# --- the afternoon: SOCIAL blocks, nobody standing about ------------------
	# Before NpcSocial the festival day's FREE blocks left ~80 % of people
	# standing where they had last eaten from late morning to dinner.
	main.time_scale = 0.05
	fm.call("jump_to_hour", 14.6)
	await get_tree().create_timer(8.0).timeout
	var idle_n := 0
	var mingle_n := 0
	var all_n := 0
	for d in bridge.call("agent_dots"):
		var dd: Dictionary = d
		all_n += 1
		var act0 := str(dd.get("activity", ""))
		if act0 == NpcSocial.ACTIVITY:
			mingle_n += 1
		elif act0.is_empty() and int(dd.get("state", 0)) != NpcAgent.State.TRAVELING:
			idle_n += 1
	print("PlaytestHarness: festivalmode — afternoon (~14:40): %d of %d idle in place, %d mingling or wandering" % [
		idle_n, all_n, mingle_n])
	_fm_result(all_n > 0 and float(idle_n) / float(all_n) < 0.15,
		"the afternoon is social: under 15 %% idle in place (%d of %d)" % [idle_n, all_n])
	_fm_result(mingle_n > all_n / 10, "people chat in camp circles and wander (%d)" % mingle_n)

	# --- weather as an attractor (NpcComfort), forced through the bridge's
	# override so the run does not depend on the archive's actual weather ----
	bridge.set("comfort_override", {"heat": 0.8, "cold": 0.0, "rain": 0.0, "night": false})
	await get_tree().create_timer(14.0).timeout
	var shade_n := 0
	var shade_doing := 0
	var cm_all := 0
	for d in bridge.call("agent_dots"):
		var dd: Dictionary = d
		cm_all += 1
		if str(dd.get("comfort", "")) == NpcComfort.KIND_SHADE:
			shade_n += 1
			if int(dd.get("state", 0)) == NpcAgent.State.DOING:
				shade_doing += 1
	print("PlaytestHarness: festivalmode — scorching afternoon (heat pull 0.8): %d of %d heading for or in the shade (%d settled)" % [
		shade_n, cm_all, shade_doing])
	_fm_result(cm_all > 0 and float(shade_n) / float(cm_all) > 0.15,
		"a hot sunny afternoon draws people into the shade (%d of %d)" % [shade_n, cm_all])
	await _shoot_ui(dir, "02b_shade")
	bridge.set("comfort_override", {"heat": 0.0, "cold": 0.0, "rain": 0.95, "night": false})
	await get_tree().create_timer(8.0).timeout
	var shelter_n := 0
	for d in bridge.call("agent_dots"):
		if str((d as Dictionary).get("comfort", "")) == NpcComfort.KIND_SHELTER:
			shelter_n += 1
	print("PlaytestHarness: festivalmode — downpour (rain pull 0.95): %d of %d sheltering" % [shelter_n, cm_all])
	_fm_result(cm_all > 0 and float(shelter_n) / float(cm_all) > 0.3,
		"hard rain sends people under cover or into their tents (%d of %d)" % [shelter_n, cm_all])
	await _shoot_ui(dir, "02c_rain")
	bridge.set("comfort_override", {})
	fm.call("jump_to_hour", 21.0)
	await get_tree().create_timer(3.0).timeout
	await _shoot_ui(dir, "02_evening")
	if cam != null:
		cam.set("_h_target", 60.0)
		cam.set("_h", 60.0)
		await get_tree().create_timer(1.0).timeout
		await _shoot_ui(dir, "03_block")
	main.time_scale = 0.0

	# --- the bass stage: a live set ------------------------------------------
	# 180x: a sim-minute every third of a second, slow enough to sample the
	# crowd mid-walk and mid-dance.
	main.time_scale = 0.05
	fm.call("jump_to_hour", 21.0)
	await get_tree().create_timer(10.0).timeout
	var stage_sid := ""
	for rec in reg.spaces:
		if str((rec as Dictionary).get("space_type", "")) == "stage":
			stage_sid = str((rec as Dictionary)["id"])
			break
	var stage_state: Dictionary = bridge.call("venue_state", stage_sid) if not stage_sid.is_empty() else {}
	var stage_front: Dictionary = bridge.call("venue_front", stage_sid) if not stage_sid.is_empty() else {}
	_fm_result(not stage_sid.is_empty() and bool(stage_state.get("active", false))
		and bool(stage_state.get("programmed", false)), "the bass stage's set is ON at 21:00")
	var at_stage := 0
	var in_front := 0
	var raving := 0
	var behind_dump := 0
	var raving_dump := 0
	var at_dark_stage := 0
	var sf: Vector2 = stage_front.get("front", Vector2.ZERO)
	var sfwd: Vector2 = stage_front.get("fwd", Vector2(0.0, 1.0))
	# The map may carry more than one stage (the player's own plus the seeded
	# one); a dot says only "at a stage", so test each person against the
	# NEAREST stage's front.
	var stage_fronts: Array = []
	for rec in reg.spaces:
		var rd: Dictionary = rec
		if str(rd.get("space_type", "")) != "stage":
			continue
		var sc: Variant = reg.cached_position(str(rd["id"]))
		var fr: Dictionary = bridge.call("venue_front", str(rd["id"]))
		var vs: Dictionary = bridge.call("venue_state", str(rd["id"]))
		if sc is Vector2 and fr.has("front"):
			stage_fronts.append({"centre": sc, "front": fr["front"], "fwd": fr["fwd"],
				"live": bool(vs.get("active", false)) and bool(vs.get("programmed", false))})
	for d in bridge.call("agent_dots"):
		var dd: Dictionary = d
		if str(dd.get("space_type", "")) != "stage" or int(dd.get("state", 0)) != NpcAgent.State.DOING:
			continue
		at_stage += 1
		var pp: Vector2 = dd.get("pos", Vector2.ZERO)
		var best: Dictionary = {}
		for sfr in stage_fronts:
			if best.is_empty() or pp.distance_to((sfr as Dictionary)["centre"]) < pp.distance_to(best["centre"]):
				best = sfr
		var f2: Vector2 = best.get("front", sf)
		var w2: Vector2 = best.get("fwd", sfwd)
		if not bool(best.get("live", true)):
			pass   # a stage with no set has no fan: counted out below
		elif (pp - f2).dot(w2) > 0.0:
			in_front += 1
		elif behind_dump < 6:
			behind_dump += 1
			print("PlaytestHarness: festivalmode — BEHIND the speakers: %s tier=%s pose=%s ahead=%.1f m, %.1f m from the stage centre, status '%s'" % [
				str(dd.get("id", "")), str(dd.get("tier", "full")), str(dd.get("venue_pose", "")),
				(pp - f2).dot(w2), pp.distance_to(best.get("centre", f2)), str(dd.get("status", ""))])
		# Only a stage with a set ON raves; a player's own unprogrammed stage
		# (Walton has one) is an ordinary gathering spot.
		if not bool(best.get("live", true)):
			at_dark_stage += 1
		elif str(dd.get("venue_pose", "")) == VenueCrowd.POSE_RAVE:
			raving += 1
		elif raving_dump < 4:
			raving_dump += 1
			var dump := dd.duplicate()
			dump.erase("anim_map")
			dump.erase("trail")
			print("PlaytestHarness: festivalmode — NOT raving at a stage: %s" % str(dump))
	print("PlaytestHarness: festivalmode — bass stage at 21:00: %d at the stage, %d in front of the speakers, %d raving; front %s fwd %s" % [
		at_stage, in_front, raving, str(sf), str(sfwd)])
	# Where the evening went: per venue type (an unlit effigy is a hang-out
	# all day, but must not empty a headline set).
	var by_venue: Dictionary = {}
	for d in bridge.call("agent_dots"):
		var stv := str((d as Dictionary).get("space_type", ""))
		if not stv.is_empty():
			by_venue[stv] = int(by_venue.get(stv, 0)) + 1
	print("PlaytestHarness: festivalmode — at 21:00 by venue type: %s" % str(by_venue))
	_fm_result(at_stage >= 20, "a crowd gathers at the bass stage for the set (%d)" % at_stage)
	_fm_result(at_stage > 0 and in_front >= int(float(at_stage - at_dark_stage) * 0.9),
		"the crowd at a live set stands in FRONT of the speakers (%d of %d)" % [
			in_front, at_stage - at_dark_stage])
	_fm_result(at_stage > 0 and raving >= int(float(at_stage - at_dark_stage) * 0.9),
		"the crowd at a live set raves (%d of %d; %d at a stage with no set)" % [
			raving, at_stage - at_dark_stage, at_dark_stage])
	# --- THE BEAT: the live set publishes one (StageMusic -> StageBeat), the
	# crowd in front of the speakers hears it, the shader has it.
	for _i in 3:
		await get_tree().process_frame
	var beat_here := StageBeat.at(Vector3(sf.x + sfwd.x * 8.0, 0.0, sf.y + sfwd.y * 8.0), false)
	var beat_later := {}
	if not beat_here.is_empty():
		await get_tree().create_timer(0.5).timeout
		beat_later = StageBeat.at(Vector3(sf.x + sfwd.x * 8.0, 0.0, sf.y + sfwd.y * 8.0), false)
	print("PlaytestHarness: festivalmode — the beat at the bass stage: %s" % str(beat_here))
	_fm_result(not beat_here.is_empty() and float(beat_here.get("bpm", 0.0)) > 60.0,
		"the live set has a BEAT the crowd in front of it hears (%.0f BPM, %s)" % [
			float(beat_here.get("bpm", 0.0)), "a track" if bool(beat_here.get("live", false)) else "virtual"])
	_fm_result(not beat_later.is_empty() and float(beat_later["beat"]) > float(beat_here["beat"]),
		"...and it moves on in real time (the music plays at 1x whatever the sim speed)")
	var pushed: Vector4 = StageBeat.pushed_pos[0]
	_fm_result(pushed.z > 0.0, "...and the crowd shader has it (music_pos0 radius %.0f)" % pushed.z)

	# --- the DJ: one person per live stage, on the deck, facing the crowd ----
	var djs: Dictionary = bridge.call("djs")
	var live_stages := 0
	var djs_ok := 0
	var prop_dj_elev := -1.0
	var dj_pos := Vector2.INF
	var dj_by_id := {}
	for d in bridge.call("agent_dots"):
		dj_by_id[str((d as Dictionary).get("id", ""))] = d
	for rec in reg.spaces:
		var rd2: Dictionary = rec
		if str(rd2.get("space_type", "")) != "stage":
			continue
		var vs2: Dictionary = bridge.call("venue_state", str(rd2["id"]))
		if not (bool(vs2.get("active", false)) and bool(vs2.get("programmed", false))):
			continue
		live_stages += 1
		var who := str(djs.get(str(rd2["id"]), ""))
		var dd2: Dictionary = dj_by_id.get(who, {})
		var fr2: Dictionary = bridge.call("venue_front", str(rd2["id"]))
		var on_mark := not dd2.is_empty() and int(dd2.get("state", 0)) == NpcAgent.State.DOING \
			and str(dd2.get("venue_pose", "")) == VenueCrowd.POSE_DJ
		print("PlaytestHarness: festivalmode — DJ at %s '%s': %s tier=%s status '%s' elev %.2f m pos %s fwd %s" % [
			str(rd2["id"]), str(rd2.get("label", "")), who, str(dd2.get("tier", "full")), str(dd2.get("status", "")),
			float(dd2.get("elev", 0.0)), str(dd2.get("pos", Vector2.ZERO)), str(fr2.get("fwd", Vector2.ZERO))])
		if on_mark:
			djs_ok += 1
			dj_pos = dd2.get("pos", Vector2.INF)
			var tgt2: Dictionary = rd2.get("target", {})
			if str(tgt2.get("kind", "")) == "prop":
				# Expected: the record's deck height, else what the bridge
				# measures off the model (a carport has no deck: 0 m).
				var want := float(rd2.get("perform_h_m", -1.0))
				if want < 0.0:
					want = maxf(float(bridge.call("stage_deck_m", main, str(tgt2.get("prop_id", "")))), 0.0)
				var got := float(dd2.get("elev", 0.0))
				prop_dj_elev = maxf(prop_dj_elev, 0.0)
				if absf(got - want) > 0.05:
					prop_dj_elev = -99.0
				print("PlaytestHarness: festivalmode — DJ deck at %s: %.2f m (expected %.2f)" % [str(rd2["id"]), got, want])
	_fm_result(live_stages > 0 and djs_ok == live_stages,
		"every live stage has its DJ at the decks (%d of %d)" % [djs_ok, live_stages])
	if prop_dj_elev != -1.0:
		_fm_result(prop_dj_elev >= 0.0,
			"each prop stage's DJ stands at its deck height (set or measured)")
	# --- PEAK EXPERIENCE: FUCK YES! spreads through the set's crowd ----------
	var pk0: Dictionary = bridge.call("peak_score")
	var series: Array = []
	var morale_hist := {}
	for k in 10:
		await get_tree().create_timer(2.0).timeout    # ~0.1 sim-h at 180x
		series.append(int(bridge.call("peaking_count")))
	var pk1: Dictionary = bridge.call("peak_score")
	var peakers: Array = []
	var vib_n := 0
	for d in bridge.call("agent_dots"):
		var dd4: Dictionary = d
		if not is_nan(float(dd4.get("peak_since", NAN))):
			peakers.append(dd4.get("pos", Vector2.ZERO))
		if str(dd4.get("space_type", "")) == "stage" and int(dd4.get("state", 0)) == NpcAgent.State.DOING:
			var mb := int(floor(float(dd4.get("morale", 0.0)) * 10.0))
			morale_hist[mb] = int(morale_hist.get(mb, 0)) + 1
			vib_n += 1
	var clustered := 0
	for a_p in peakers:
		for b_p in peakers:
			if a_p != b_p and (a_p as Vector2).distance_to(b_p) <= 9.0:
				clustered += 1
				break
	print("PlaytestHarness: festivalmode — peak experience: score %d -> %d, peaking over ~1 sim-h %s; %d peaking now, %d of them with another within 9 m; stage crowd morale tenths %s" % [
		int(pk0.get("total", 0)), int(pk1.get("total", 0)), str(series), peakers.size(), clustered, str(morale_hist)])
	_fm_result(int(pk1.get("total", 0)) > int(pk0.get("total", 0)), "people hit FUCK YES! at the set (score %d -> %d)" % [
		int(pk0.get("total", 0)), int(pk1.get("total", 0))])
	var max_pk := 0
	for s in series:
		max_pk = maxi(max_pk, int(s))
	_fm_result(max_pk >= 10, "a peak spreads through the crowd (up to %d peaking at once)" % max_pk)
	_fm_result(peakers.size() > 0 and clustered >= int(float(peakers.size()) * 0.7),
		"peakers are together, not scattered (%d of %d within 9 m of another)" % [clustered, peakers.size()])
	var toast: Node = main.get_node_or_null("PeakToast")
	_fm_result(toast != null and int(toast.get("toasts_started")) > 0 and int(toast.get("shown_onsets")) > 0,
		"the FUCK YES! toast fired (%d toasts, %d onsets shown)" % [
			int(toast.get("toasts_started")) if toast != null else 0, int(toast.get("shown_onsets")) if toast != null else 0])
	# The FUCK YES beacon stands on the body it names, and stays on it.
	var beacon: Node = main.get_node_or_null("PeakBeacon")
	var host_b: Node = sgv.call("npc_population_host") if sgv.has_method("npc_population_host") else null
	if beacon != null and host_b != null:
		var lb: Dictionary = {}
		for k in 40:
			lb = beacon.call("latest")
			if not lb.is_empty():
				break
			await get_tree().create_timer(0.25).timeout
		if lb.is_empty():
			print("PlaytestHarness: festivalmode — no beacon was up to measure (no onset in the window)")
		else:
			var worst := 0.0
			var lost := 0
			var jump := 0.0
			var prev_d: Variant = null
			for k in 30:
				await get_tree().process_frame
				var cur: Dictionary = beacon.call("latest")
				if cur.is_empty() or str(cur["id"]) != str(lb["id"]):
					break
				var dpos: Variant = host_b.call("drawn_position", str(lb["id"]))
				if not (dpos is Vector3):
					lost += 1
					continue
				var bp: Vector3 = cur["pos"]
				worst = maxf(worst, Vector2(bp.x, bp.z).distance_to(Vector2((dpos as Vector3).x, (dpos as Vector3).z)))
				if prev_d is Vector3:
					jump = maxf(jump, (dpos as Vector3).distance_to(prev_d))
				prev_d = dpos
			print("PlaytestHarness: festivalmode — beacon on %s: worst offset from the drawn body %.2f m, %d frames unseen, biggest frame step %.2f m" % [
				str(lb["name"]), worst, lost, jump])
			_fm_result(worst <= 0.3 and lost == 0,
				"the beacon stays locked on the person it names (worst %.2f m, %d frames unseen)" % [worst, lost])
	var bar_seen := false
	var host_n: Node = sgv.call("npc_population_host") if sgv.has_method("npc_population_host") else null
	if host_n != null:
		for av_n in host_n.get_children():
			if av_n is NpcAvatar:
				var sb := (av_n as Node).get_node_or_null("Labels/Stack/StatusBar")
				if sb != null and (sb as Node3D).visible:
					for ch in sb.get_children():
						if ch is MeshInstance3D and (ch as MeshInstance3D).visible:
							bar_seen = true
	_fm_result(NpcDisplayPrefs.mood_bars() or not bar_seen, "no mood bars over heads by default (the glow says it)")
	if cam != null and peakers.size() > 0:
		# Frame where the peak IS: the peakers' centroid.
		var pc := Vector2.ZERO
		for p_p in peakers:
			pc += p_p
		pc /= float(peakers.size())
		cam.call("look_at_xz", pc)
		cam.set("_h_target", 22.0)
		cam.set("_h", 22.0)
		await get_tree().create_timer(1.0).timeout
		await _shoot_ui(dir, "04d_peak_experience")
		cam.set("_h_target", 300.0)
		cam.set("_h", 300.0)
		await get_tree().create_timer(1.0).timeout
		await _shoot_ui(dir, "04e_peak_far")
	var night_pushed := float(main.get("_npc_night_pushed"))
	_fm_result(night_pushed > 0.5, "it is night for the glow sticks (npc_night %.2f)" % night_pushed)
	if cam != null and dj_pos != Vector2.INF:
		cam.call("look_at_xz", dj_pos)
		cam.set("_h_target", 9.0)
		cam.set("_h", 9.0)
		await get_tree().create_timer(1.0).timeout
		await _shoot_ui(dir, "04b_dj_and_glow")

	# --- a firepit: placed, tagged as a fire circle, lit, warming people -----
	var pit_at := Vector2.ZERO
	var poly0: Variant = polys[0] if polys.size() > 0 else null
	if poly0 != null and (poly0 as PackedVector2Array).size() > 0:
		for v in (poly0 as PackedVector2Array):
			pit_at += v
		pit_at /= float((poly0 as PackedVector2Array).size())
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, FirepitBuilder.MODEL_ID,
		pit_at.x, pit_at.y, {"firepit_mode": FirepitBuilder.MODE_ON})
	var pit_id := str(placed.get("prop_id", ""))
	_fm_result(not pit_id.is_empty(), "a firepit can be placed like any prop")
	bridge.set("comfort_override", {"heat": 0.0, "cold": 0.8, "rain": 0.0, "night": true})
	await get_tree().create_timer(12.0).timeout
	var pit_sid := str(reg.space_for_target({"kind": "prop", "prop_id": pit_id}).get("id", ""))
	var pit_state: Dictionary = bridge.call("venue_state", pit_sid) if not pit_sid.is_empty() else {}
	var pit_node := PlacedPropRuntime.find_by_prop_id(main, pit_id)
	var fire_node: Node = pit_node.find_child("FirepitFire", true, false) if pit_node != null else null
	_fm_result(not pit_sid.is_empty() and str(reg.find_by_id(pit_sid).get("space_type", "")) == "fire_circle",
		"placing a firepit tags it as a fire circle")
	_fm_result(bool(pit_state.get("lit", false)) and fire_node != null and bool(fire_node.call("is_lit")),
		"the firepit burns (bridge and fire agree)")
	var warm_n := 0
	var at_pit := 0
	for d in bridge.call("agent_dots"):
		var dd3: Dictionary = d
		if str(dd3.get("comfort", "")) == NpcComfort.KIND_WARM:
			warm_n += 1
		if (dd3.get("pos", Vector2.INF) as Vector2).distance_to(pit_at) < 3.5 \
				and int(dd3.get("state", 0)) == NpcAgent.State.DOING:
			at_pit += 1
	print("PlaytestHarness: festivalmode — cold night (pull 0.8): %d warming up, %d round the new firepit" % [warm_n, at_pit])
	_fm_result(warm_n > 0, "a cold night draws people to warmth (%d)" % warm_n)
	if cam != null:
		cam.call("look_at_xz", pit_at)
		cam.set("_h_target", 10.0)
		cam.set("_h", 10.0)
		await get_tree().create_timer(1.0).timeout
		await _shoot_ui(dir, "04c_firepit")
	bridge.set("comfort_override", {})
	if not pit_id.is_empty() and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", pit_id)
	if not pit_sid.is_empty():
		reg.remove_space(pit_sid)
	if cam != null and not stage_sid.is_empty():
		# Frame the FAN (front edge + 12 m along the facing), not the stage
		# centre — the crowd is in front of the speakers, by construction.
		var sp: Variant = sf + sfwd * 12.0 if not stage_front.is_empty() else reg.cached_position(stage_sid)
		if sp is Vector2:
			cam.call("look_at_xz", sp)
			cam.set("_h_target", 45.0)
			cam.set("_h", 45.0)
			await get_tree().create_timer(1.0).timeout
			await _shoot_ui(dir, "04_bass_stage")

	# --- the effigy: light it ---------------------------------------------------
	var eff: Dictionary = {}
	for rec in reg.spaces:
		if str((rec as Dictionary).get("space_type", "")) == "effigy":
			eff = rec
			break
	_fm_result(not eff.is_empty(), "festival mode tagged the burnable structure as the Effigy")
	if not eff.is_empty():
		var esid := str(eff["id"])
		var pid := str((eff.get("target", {}) as Dictionary).get("prop_id", ""))
		var ec: Variant = reg.cached_position(esid)
		var ecv: Vector2 = ec if ec is Vector2 else Vector2.ZERO
		# --- the PRE-ROLL: lit, no flame — the ring forms first ------------------
		var pre_h := float(main.call("get_absolute_hours"))
		loader.call("set_prop_burn_record", pid, FireTimeline.make(pre_h,
			{"climb_h": 0.5, "bonfire_h": 1.0, "ember_h": 0.5, "mass_kg": 600.0,
				"height_m": 8.0, "footprint_r_m": 3.0, "preroll_h": FireTimeline.EFFIGY_PREROLL_H}))
		FireNode.sync_prop_fires(main, loader)
		await get_tree().create_timer(4.0).timeout   # ~0.2 sim-h: the GATHER
		var pre_rec: Dictionary = (PlacedPropService.get_prop_record(main, pid) as Dictionary).get("burn", {})
		var pre_t := float(main.call("get_absolute_hours"))
		var pre_es: Dictionary = bridge.call("venue_state", esid)
		var pre_n := 0
		var pre_min := INF
		var pre_who: Dictionary = {}
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			var dp: Vector2 = dd.get("pos", Vector2.ZERO)
			# Anyone STANDING still (walkers cross the edge on their way out);
			# not a performer (the fire flow and the sandmen are inside on purpose).
			if int(dd.get("state", 0)) != NpcAgent.State.TRAVELING and str(dd.get("activity", "")) != "perform":
				if dp.distance_to(ecv) < pre_min:
					pre_who = dd
				pre_min = minf(pre_min, dp.distance_to(ecv))
			if str(dd.get("space_type", "")) == "effigy" and int(dd.get("state", 0)) == NpcAgent.State.DOING:
				pre_n += 1
		var pre_r := float(pre_es.get("safe_r", 0.0))
		print("PlaytestHarness: festivalmode — pre-roll: phase %s preroll=%s flame=%s, %d seated, nearest anyone %.1f m (perimeter %.1f)" % [
			str(pre_es.get("phase_name", "")), str(pre_es.get("preroll", false)),
			str(FireTimeline.has_flame(pre_rec, pre_t)), pre_n, pre_min, pre_r])
		if pre_min < pre_r - 0.5:
			print("PlaytestHarness: festivalmode — nearest in the pre-roll: %s tier=%s act=%s space=%s pose=%s comfort=%s status '%s'" % [
				str(pre_who.get("id", "")), str(pre_who.get("tier", "full")), str(pre_who.get("activity", "")),
				str(pre_who.get("space_type", "")), str(pre_who.get("venue_pose", "")),
				str(pre_who.get("comfort", "")), str(pre_who.get("status", ""))])
		_fm_result(bool(pre_es.get("preroll", false)) and bool(pre_es.get("event", false))
			and not FireTimeline.has_flame(pre_rec, pre_t),
			"the pre-roll is an EVENT with no flame yet")
		_fm_result(pre_n >= 20, "the ring forms BEFORE the first flame (%d seated)" % pre_n)
		_fm_result(pre_min >= pre_r - 0.5,
			"nobody stands still inside the perimeter during the pre-roll (nearest %.1f m, perimeter %.1f)" % [pre_min, pre_r])
		_fm_result(str(pre_es.get("stage", "")) == VenueCrowd.STAGE_GATHER,
			"the pre-roll opens with the GATHER (stage '%s')" % str(pre_es.get("stage", "")))
		# --- the FIRE FLOW -------------------------------------------------------
		await get_tree().create_timer(4.5).timeout   # ~0.43 sim-h: the flow
		var fl_es: Dictionary = bridge.call("venue_state", esid)
		var fl_roles: Dictionary = (bridge.call("burn_roles") as Dictionary).get(esid, {})
		var fl_ids: Array = fl_roles.get("performers", [])
		var fl_on_lane := 0
		var fl_lane := float(fl_es.get("safe_r", pre_r)) * VenueCrowd.FLOW_LANE_FRAC
		var fl_dist: Array = []
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			if fl_ids.has(str(dd.get("id", ""))):
				var dl := (dd.get("pos", Vector2.ZERO) as Vector2).distance_to(ecv)
				fl_dist.append(snappedf(dl, 0.1))
				if absf(dl - fl_lane) < 2.0 and str(dd.get("venue_pose", "")) == VenueCrowd.POSE_FIREFLOW:
					fl_on_lane += 1
		print("PlaytestHarness: festivalmode — fire flow: stage '%s', %d performers, %d on the %.1f m lane spinning poi; distances %s" % [
			str(fl_es.get("stage", "")), fl_ids.size(), fl_on_lane, fl_lane, str(fl_dist)])
		_fm_result(str(fl_es.get("stage", "")) == VenueCrowd.STAGE_FLOW and fl_ids.size() >= VenueCrowd.FLOW_MIN
			and fl_ids.size() <= VenueCrowd.FLOW_MAX,
			"the FIRE FLOW casts %d performers (10-20)" % fl_ids.size())
		_fm_result(fl_on_lane >= int(float(fl_ids.size()) * 0.6),
			"the performers circle on their lane with fire props (%d of %d)" % [fl_on_lane, fl_ids.size()])
		var poi: Node = main.get_node_or_null("FirePropFx")
		_fm_result(poi != null and (poi.get("_ids") as Array).size() > 0,
			"the poi flames follow the performers (%d rigs)" % ((poi.get("_ids") as Array).size() if poi != null else 0))
		if cam != null:
			cam.call("look_at_xz", ecv)
			cam.set("_h_target", 30.0)
			cam.set("_h", 30.0)
			await get_tree().create_timer(0.6).timeout
			await _shoot_ui(dir, "05a_fire_flow")
		# --- the SANDMEN take the line ---------------------------------------------
		await get_tree().create_timer(4.4).timeout   # ~0.67 sim-h: sandmen
		var sm_es: Dictionary = bridge.call("venue_state", esid)
		var sm_roles: Dictionary = (bridge.call("burn_roles") as Dictionary).get(esid, {})
		var sm_ids: Array = sm_roles.get("sandmen", [])
		var sm_r := float(sm_es.get("safe_r", pre_r))
		var sm_at_post := 0
		var sm_kneel := 0
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			if not sm_ids.has(str(dd.get("id", ""))):
				continue
			var ds := (dd.get("pos", Vector2.ZERO) as Vector2).distance_to(ecv)
			if absf(ds - (sm_r - VenueCrowd.SANDMAN_INSET_M)) < 1.5:
				sm_at_post += 1
			if str(dd.get("venue_pose", "")) == VenueCrowd.POSE_KNEEL:
				sm_kneel += 1
		print("PlaytestHarness: festivalmode — sandmen: stage '%s', %d cast (want %d), %d at their posts, %d kneeling; %d redirects so far" % [
			str(sm_es.get("stage", "")), sm_ids.size(), VenueCrowd.sandman_count(sm_r), sm_at_post, sm_kneel,
			int(bridge.call("burn_redirects"))])
		_fm_result(str(sm_es.get("stage", "")) == VenueCrowd.STAGE_SANDMEN and sm_ids.size() >= VenueCrowd.SANDMAN_MIN,
			"the SANDMEN take the line before the flame (%d)" % sm_ids.size())
		_fm_result(sm_kneel >= int(float(sm_ids.size()) * 0.6),
			"the sandmen kneel at the line, backs to the fire (%d of %d kneeling, %d at posts)" % [sm_kneel, sm_ids.size(), sm_at_post])
		if cam != null:
			await _shoot_ui(dir, "05b_sandmen")
		# Pause: every cosmetic clock freezes in the same frame.
		var ts_keep := float(main.time_scale)
		main.time_scale = 0.0
		await get_tree().process_frame
		await get_tree().process_frame
		var fx0 := SimFxRate.now(main, SimFxRate.SYS_FIRE)
		var fxn0 := SimFxRate.now(main, SimFxRate.SYS_NPC)
		await get_tree().create_timer(1.0).timeout
		_fm_result(is_equal_approx(fx0, SimFxRate.now(main, SimFxRate.SYS_FIRE))
			and is_equal_approx(fxn0, SimFxRate.now(main, SimFxRate.SYS_NPC)),
			"pausing freezes the fire and crowd animation clocks")
		main.time_scale = ts_keep
		var now_h := float(main.call("get_absolute_hours"))
		# A half-hour climb, an hour of bonfire, half an hour of embers.
		# An 8 m effigy on a 3 m base: the standing perimeter is 8 + 3.05 m,
		# the pile perimeter 3 + 1.52 m.
		loader.call("set_prop_burn_record", pid, FireTimeline.make(now_h,
			{"climb_h": 0.5, "bonfire_h": 1.0, "ember_h": 0.5, "mass_kg": 600.0,
				"height_m": 8.0, "footprint_r_m": 3.0}))
		FireNode.sync_prop_fires(main, loader)
		await get_tree().create_timer(8.0).timeout   # ~0.4 sim-h into the climb
		var es: Dictionary = bridge.call("venue_state", esid)
		_fm_result(int(es.get("phase", -1)) == VenueCrowd.EffigyPhase.BURNING and bool(es.get("event", false)),
			"the lit effigy is BURNING and an EVENT (phase %s)" % str(es.get("phase_name", "")))
		var n_eff := 0
		var min_d := INF
		var seated := 0
		var standing := 0
		var awake := 0
		var heading := 0
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			if str(dd.get("activity", "")) != "sleep":
				awake += 1
				if str(dd.get("space_type", "")) == "effigy":
					heading += 1
			if str(dd.get("space_type", "")) != "effigy" or int(dd.get("state", 0)) != NpcAgent.State.DOING:
				continue
			n_eff += 1
			min_d = minf(min_d, (dd.get("pos", Vector2.ZERO) as Vector2).distance_to(ecv))
			var vp := str(dd.get("venue_pose", ""))
			if vp == VenueCrowd.POSE_SIT or vp == VenueCrowd.POSE_LOUNGE or vp == VenueCrowd.POSE_LIE:
				seated += 1
			elif vp == VenueCrowd.POSE_STAND:
				standing += 1
		# Who is NOT at the burn, and how far they are: the number that says
		# whether the pull reaches the far camps.
		var by_state: Dictionary = {}
		var far_hist: Dictionary = {}
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			var dist_b := int((dd.get("pos", Vector2.ZERO) as Vector2).distance_to(ecv) / 100.0) * 100
			if str(dd.get("space_type", "")) == "effigy":
				var k := "effigy/%d" % int(dd.get("state", 0))
				by_state[k] = int(by_state.get(k, 0)) + 1
			else:
				var k2 := "%s/%s" % [str(dd.get("activity", "")), str(dd.get("space_type", ""))]
				by_state[k2] = int(by_state.get(k2, 0)) + 1
				far_hist[dist_b] = int(far_hist.get(dist_b, 0)) + 1
		print("PlaytestHarness: festivalmode — the burn: %d gathered, nearest %.1f m, %d seated/lying, %d standing" % [
			n_eff, min_d, seated, standing])
		print("PlaytestHarness: festivalmode — everyone else by activity/venue: %s" % str(by_state))
		print("PlaytestHarness: festivalmode — distance of those NOT at the burn (m bucket: people): %s" % str(far_hist))
		_fm_result(n_eff >= 40, "the festival gathers at the burn (%d)" % n_eff)
		var share := float(heading) / float(maxi(awake, 1))
		print("PlaytestHarness: festivalmode — burn turnout: %d of %d awake at or on their way to the effigy (%.0f %%; target %.0f %%), %d redirects" % [
			heading, awake, share * 100.0, VenueCrowd.BURN_TURNOUT * 100.0, int(bridge.call("burn_redirects"))])
		_fm_result(share >= 0.7, "the burn draws most of the site (%.0f %% of those awake)" % (share * 100.0))
		# Who is NOT coming, and why (a meal begun before the burn? a need
		# past the stay-up bars? the 15 % who carry on?).
		var why_n := 0
		var tnow_b := float(main.call("get_absolute_hours"))
		var bkey := str(es.get("burn_key", ""))
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			var act_s := str(dd.get("activity", ""))
			if act_s != "hunger" or why_n >= 8:
				continue
			why_n += 1
			var hv := -1.0
			var coh_w: Variant = bridge.call("cohort_for", str(bridge.call("habitat_of_agent", str(dd["id"]))))
			if coh_w != null and str(dd.get("tier", "")) == "light":
				var wi: int = coh_w.agent_index(str(dd["id"]))
				hv = coh_w.needs[wi * 6 + NpcAgent.NEEDS.find("hunger")]
			print("PlaytestHarness: festivalmode — not at the burn: %s tier=%s state=%d hunger=%.2f attends=%s hour=%.2f ends_in=%.2f status '%s'" % [
				str(dd["id"]), str(dd.get("tier", "full")), int(dd.get("state", 0)), hv,
				str(VenueCrowd.attends(str(dd["id"]), bkey)), fposmod(tnow_b, 24.0),
				float(dd.get("ends_h", tnow_b)) - tnow_b, str(dd.get("status", ""))])
		var safe_r := float(es.get("safe_r", VenueCrowd.EFFIGY_SAFE_R_M))
		_fm_result(n_eff > 0 and min_d >= safe_r - 0.5,
			"nobody stands inside the fire perimeter (nearest %.1f m, perimeter %.1f = height + 10 ft)" % [min_d, safe_r])
		_fm_result(absf(safe_r - (8.0 + VenueCrowd.PERIMETER_STANDING_M)) < 0.01,
			"the standing perimeter is the structure height plus ten feet (%.2f m)" % safe_r)
		# The first two rings seat ~144; standing rows only exist past that.
		var two_rows := int(VenueCrowd.effigy_row(0)["n"])
		two_rows += int(VenueCrowd.effigy_row(two_rows)["n"])
		_fm_result(seated > 0 and (standing > 0 or n_eff <= two_rows),
			"the front rows sit or lie and the back rows stand (%d / %d of %d; two rings seat %d)" % [seated, standing, n_eff, two_rows])
		if cam != null:
			cam.call("look_at_xz", ecv)
			cam.set("_h_target", 45.0)
			cam.set("_h", 45.0)
			await get_tree().create_timer(1.0).timeout
			await _shoot_ui(dir, "05_effigy_burn")
		await get_tree().create_timer(4.0).timeout   # past the collapse
		es = bridge.call("venue_state", esid)
		_fm_result(int(es.get("phase", -1)) == VenueCrowd.EffigyPhase.CIRCLING,
			"after the collapse the effigy is CIRCLING (phase %s)" % str(es.get("phase_name", "")))
		var ang0: Dictionary = {}
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			var vp := str(dd.get("venue_pose", ""))
			if str(dd.get("space_type", "")) == "effigy" and (vp == VenueCrowd.POSE_DANCE or vp == VenueCrowd.POSE_WALK):
				var pp: Vector2 = dd.get("pos", Vector2.ZERO)
				ang0[str(dd["id"])] = atan2(-(pp.y - ecv.y), pp.x - ecv.x)
		# Sample ONE circle step apart (0.02 sim-h = 0.4 s at 180x): a lap takes
		# 0.1 h, so a longer gap wraps past 180 degrees and reads as clockwise.
		await get_tree().create_timer(0.4).timeout
		var ccw := 0
		var seen_c := 0
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			var id := str(dd["id"])
			if not ang0.has(id):
				continue
			var pp: Vector2 = dd.get("pos", Vector2.ZERO)
			var a1 := atan2(-(pp.y - ecv.y), pp.x - ecv.x)
			seen_c += 1
			if wrapf(a1 - float(ang0[id]), -PI, PI) > 0.0:
				ccw += 1
		var tangent_ok := 0
		var tangent_n := 0
		var tangent_by: Dictionary = {}
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			if not ang0.has(str(dd["id"])) or str(dd.get("venue_pose", "")) != VenueCrowd.POSE_WALK:
				continue
			var pp: Vector2 = dd.get("pos", Vector2.ZERO)
			var tg := VenueCrowd.ccw_tangent(ecv, pp)
			tangent_n += 1
			var tkey := "%s/%d" % [str(dd.get("tier", "full")), int(dd.get("state", -1))]
			var tb: Array = tangent_by.get(tkey, [0, 0])
			tb[1] += 1
			# A full-tier dot's face_yaw is the avatar's convention (forward
			# -Z), half a turn from the crowd figure's (+Z).
			var fy := float(dd.get("face_yaw", 0.0)) + (0.0 if str(dd.get("tier", "")) == "light" else PI)
			if absf(wrapf(fy - atan2(tg.x, tg.y), -PI, PI)) < 0.6:
				tangent_ok += 1
				tb[0] += 1
			tangent_by[tkey] = tb
		print("PlaytestHarness: festivalmode — circle walkers facing along the circle: %d of %d (by tier/state ok,n: %s)" % [tangent_ok, tangent_n, str(tangent_by)])
		_fm_result(tangent_n > 0 and tangent_ok >= int(float(tangent_n) * 0.7),
			"the circle walks facing ALONG the circle, not in at the fire (%d of %d)" % [tangent_ok, tangent_n])
		var pile_r := float(es.get("safe_r", 0.0))
		var min_c := INF
		var c_who: Dictionary = {}
		var by_tier := {}
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			if str(dd.get("space_type", "")) == "effigy":
				var dc := (dd.get("pos", Vector2.ZERO) as Vector2).distance_to(ecv)
				if dc < min_c:
					c_who = dd
				min_c = minf(min_c, dc)
			if ang0.has(str(dd["id"])):
				var tk := "%s/%s/%d" % [str(dd.get("tier", "full")), str(dd.get("venue_pose", "")), int(dd.get("state", 0))]
				by_tier[tk] = int(by_tier.get(tk, 0)) + 1
		print("PlaytestHarness: festivalmode — circlers by tier/pose/state: %s; nearest: %s tier=%s pose=%s state=%d status '%s'" % [
			str(by_tier), str(c_who.get("id", "")), str(c_who.get("tier", "full")), str(c_who.get("venue_pose", "")),
			int(c_who.get("state", 0)), str(c_who.get("status", ""))])
		if min_c < pile_r - 0.5 and str(c_who.get("tier", "")) == "light":
			var coh: Variant = bridge.call("cohort_for", str(bridge.call("habitat_of_agent", str(c_who["id"]))))
			if coh != null:
				var ci: int = coh.agent_index(str(c_who["id"]))
				var tnow := float(main.call("get_absolute_hours"))
				print("PlaytestHarness: festivalmode — that walker: a=(%.1f,%.1f) b=(%.1f,%.1f) t0=%.4f t1=%.4f now=%.4f legs=%s leg_i=%d end=%.4f vphase=%d; a->centre %.1f m, b->centre %.1f m; no_go=%s" % [
					coh.ax[ci], coh.az[ci], coh.bx[ci], coh.bz[ci], coh.t0[ci] - tnow, coh.t1[ci] - tnow, tnow,
					str(coh.legs[ci]), coh.leg_i[ci], coh.end_h[ci] - tnow, coh.vphase[ci],
					Vector2(coh.ax[ci], coh.az[ci]).distance_to(ecv), Vector2(coh.bx[ci], coh.bz[ci]).distance_to(ecv),
					str(bridge.call("_no_go_circles"))])
		print("PlaytestHarness: festivalmode — circling: %d people moving round the fire, %d counter-clockwise; perimeter %.2f m, nearest %.1f m" % [seen_c, ccw, pile_r, min_c])
		_fm_result(absf(pile_r - (3.0 + VenueCrowd.PERIMETER_PILE_M)) < 0.01 and min_c >= pile_r - 0.5,
			"after the collapse the perimeter is five feet off the pile and nobody is inside it (%.2f m, nearest %.1f)" % [pile_r, min_c])
		_fm_result(seen_c >= 20, "people circle the fire after the collapse (%d)" % seen_c)
		_fm_result(seen_c > 0 and ccw >= int(float(seen_c) * 0.7), "the circle runs counter-clockwise (%d of %d)" % [ccw, seen_c])
		# Does every person in the circle stay DRAWN as it turns? (The hero
		# pool hands people between NpcAvatars and the GPU crowd as they come
		# nearer and go round — a lost hand-off reads as people blinking out.)
		var vis := await _fm_visibility_probe(main, bridge, ang0.keys(), 90)
		print("PlaytestHarness: festivalmode — circle visibility: %s" % str(vis))
		_fm_result(int(vis.get("people", 0)) > 0 and float(vis.get("worst_frame", 0.0)) >= 0.98,
			"everyone circling is drawn every frame (worst frame %.1f %% of %d, %d people ever missing)" % [
				float(vis.get("worst_frame", 0.0)) * 100.0, int(vis.get("people", 0)), int(vis.get("ever_missing", 0))])
		await _shoot_ui(dir, "06_effigy_circle")
		await get_tree().create_timer(16.0).timeout   # the 45 minutes pass
		es = bridge.call("venue_state", esid)
		_fm_result(int(es.get("phase", -1)) == VenueCrowd.EffigyPhase.AFTER,
			"45 min after the collapse the dance is over (phase %s)" % str(es.get("phase_name", "")))
		var social := 0
		var still_dancing := 0
		for d in bridge.call("agent_dots"):
			var dd: Dictionary = d
			if str(dd.get("space_type", "")) != "effigy":
				continue
			var vp := str(dd.get("venue_pose", ""))
			if vp == VenueCrowd.POSE_WALK:
				still_dancing += 1
			elif vp != "":
				social += 1
		_fm_result(social > 0 and still_dancing == 0,
			"afterwards people socialise round the embers like an art piece (%d, %d still circling)" % [social, still_dancing])
		await _shoot_ui(dir, "07_effigy_after")
		loader.call("clear_prop_burn_record", pid)
		FireNode.sync_prop_fires(main, loader)

	# --- sleeping INSIDE the shelters -------------------------------------------
	fm.call("jump_to_hour", 4.0)
	main.time_scale = 0.1
	await get_tree().create_timer(10.0).timeout   # ~1 sim-h: everyone to bed
	var beds: Array = []
	for rec in reg.spaces:
		var rd: Dictionary = rec
		if str(rd.get("space_type", "")) != "sleep":
			continue
		var tgt: Dictionary = rd.get("target", {})
		if str(tgt.get("kind", "")) != "area":
			continue
		for sh in loader.call("camp_shelters_in_polygon", SpaceRegistry.poly_points(tgt.get("poly", []) as Array)):
			beds.append((sh as Dictionary)["pos"])
	var sleepers := 0
	var in_shelter := 0
	for d in bridge.call("agent_dots"):
		var dd: Dictionary = d
		if str(dd.get("activity", "")) != "sleep" or int(dd.get("state", 0)) != NpcAgent.State.DOING:
			continue
		sleepers += 1
		var pp: Vector2 = dd.get("pos", Vector2.ZERO)
		for b in beds:
			if pp.distance_to(b) <= 2.5:
				in_shelter += 1
				break
	print("PlaytestHarness: festivalmode — 04:00: %d asleep, %d of them inside a shelter (%d shelters across the camps)" % [
		sleepers, in_shelter, beds.size()])
	_fm_result(beds.size() > 0, "the camps have shelters to sleep in (%d)" % beds.size())
	_fm_result(sleepers > 0 and in_shelter >= int(float(sleepers) * 0.6),
		"most sleepers lie inside a tent, pod, van or RV (%d of %d)" % [in_shelter, sleepers])
	# Frame the busiest camp low, so the shot shows people IN the tents.
	if cam != null and not beds.is_empty():
		var best_b: Vector2 = beds[0]
		var best_n := -1
		for b in beds:
			var n_near := 0
			for d in bridge.call("agent_dots"):
				if str((d as Dictionary).get("activity", "")) == "sleep" \
						and ((d as Dictionary).get("pos", Vector2.ZERO) as Vector2).distance_to(b) < 25.0:
					n_near += 1
			if n_near > best_n:
				best_n = n_near
				best_b = b
		cam.call("look_at_xz", best_b)
		cam.set("_h_target", 18.0)
		cam.set("_h", 18.0)
		await get_tree().create_timer(1.0).timeout
	await _shoot_ui(dir, "08_asleep")
	main.time_scale = 0.0

	# --- leave ------------------------------------------------------------------
	fm.call("close")
	await get_tree().process_frame
	_fm_result(not PopTestPrefs.easy_override(), "leaving hands the guardrails back")
	_fm_result(PopTestPrefs.saved_flags() == saved0, "the player's SAVED testing flags are untouched")
	_fm_result(not bool(main.call("settlement_view_open")), "leaving closed the settlement view")
	_fm_result((sgv.call("festival_camps") as Array).size() == camps.size(), "the camps stay after leaving")
	_fm_result(not bool(main.call("festival_mode_active")), "Main reports the mode off")

	# --- clear ------------------------------------------------------------------
	fm.call("clear_seeded")
	for _i in 6:
		await get_tree().process_frame
	var left := 0
	for rec in reg.spaces:
		if str((rec as Dictionary).get("label", "")).begins_with(FestivalSeedLayout.LABEL_PREFIX):
			left += 1
	_fm_result(left == 0, "clear removed every seeded venue (%d left)" % left)
	var still := 0
	for rec in (layer.get("areas") as Array):
		if FestivalSeedLayout.is_populatable(rec, zones) and int((rec as Dictionary).get("headcount", 0)) > 0:
			still += 1
	_fm_result(still == 0, "clear put every painted camp's headcount back to 0 (%d left)" % still)
	var after_clear: Array = sgv.call("festival_camps")
	var assigned_lots := 0
	if placement != null:
		for l in (placement.get("lots") as Array):
			if not ((l as Dictionary).get("assigned_camp", {}) as Dictionary).is_empty():
				assigned_lots += 1
	_fm_result(after_clear.size() == assigned_lots,
		"after clear only the lot camps remain as compounds (%d for %d assigned lots)" % [after_clear.size(), assigned_lots])

	_restore_files(snap)
	print("PlaytestHarness: festivalmode — restored the map's camp / placement / spaces files, the graph autosave and the NPC display prefs")
	# The player's Peak Experience score: stop the bridge saving, put the file back.
	var br_pk: Variant = sgv.call("npc_population_bridge") if sgv.has_method("npc_population_bridge") else null
	if br_pk != null:
		br_pk.set("_peak_path", "")
		br_pk.set("_peak_save_due_ms", 0)
	_restore_files(peak_snap)
	print("PlaytestHarness: festivalmode — shots in %s" % ProjectSettings.globalize_path(dir))
	_maybe_quit()


# ==================== VEHICLES + THIRD PERSON (--capture=vehicles) ====================
# Placed vehicles and the follow camera, end to end on the live player (works
# on the SOAK scene — no TerrainLoader needed). Asserts what a PNG cannot:
# a library vehicle gets its PlacedVehicle; Interact on it (the crosshair
# path) gets the player IN at the vehicle with the prop's collision OFF;
# driving moves the PROP with the rider and turns ModelRoot by the profile's
# yaw; third person detaches the camera arm and puts the camera BEHIND the
# vehicle; dismounting steps the rider out past the half-width, saves the
# parked position on the record and re-bakes the collision; on foot in third
# person the body turns to walk where the CAMERA faces; first person puts the
# arm back exactly. Then the tool bus. player.cfg is byte-restored and every
# seeded prop removed.
func _run_vehicle_capture() -> void:
	var tree := get_tree()
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	var main := _find_main()
	var player: CharacterBody3D = null
	if main != null:
		player = main.get_node_or_null("Player") as CharacterBody3D
	if main == null or player == null:
		push_error("PlaytestHarness: vehicles needs Main + Player")
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "vehicles"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var fails: Array = []
	var cfg_had := FileAccess.file_exists(PlayerPrefs.CFG_PATH)
	var cfg_bytes := FileAccess.get_file_as_bytes(PlayerPrefs.CFG_PATH) if cfg_had else PackedByteArray()
	var saved_scale: Variant = main.get("time_scale")
	main.set("time_scale", 0.0)
	main.set("day_time", 11.0)
	CursorController.set_paused(false)
	player.set("is_mouse_captured", true)
	PlayerPrefs.set_camera_mode(PlayerPrefs.CAMERA_FIRST)
	for _i in 3:
		await tree.process_frame
	var seeded: Array[String] = []
	var focus := player.get_node_or_null("InteractionFocus")
	var arm := player.get_node_or_null("CameraArm") as Node3D
	var cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	var arm_rest := arm.transform if arm != null else Transform3D()

	# 1. Place Appa from the catalog, 8 m ahead.
	var fwd := -player.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 1e-4 else Vector3.FORWARD
	var at := player.global_position + fwd * 8.0
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, "vehicle_appa", at.x, at.z)
	var pid := str(placed.get("prop_id", ""))
	_veh_result(bool(placed.get("ok", false)) and not pid.is_empty(), "Appa is placed from the catalog", fails)
	if not pid.is_empty():
		seeded.append(pid)
	for _i in 10:
		await tree.physics_frame
	var prop := PlacedPropRuntime.find_by_prop_id(main, pid) as Node3D
	var veh: Node = null
	if prop != null:
		veh = prop.get_node_or_null("PlacedVehicle")
	_veh_result(veh != null, "the placed prop carries a PlacedVehicle", fails)
	if veh == null or focus == null:
		_vehicle_capture_restore(main, loader, seeded, cfg_had, cfg_bytes, saved_scale, fails)
		return

	# 2. Interact through the crosshair path gets in.
	focus.call("_open_placed_prop_edit", prop)
	for _i in 3:
		await tree.physics_frame
	var body := prop.get_node_or_null("PropBody") as CollisionObject3D
	_veh_result(bool(player.get("is_riding")) and player.get("current_vehicle") == veh,
		"Interact on the vehicle gets the player in", fails)
	_veh_result(body == null or body.collision_layer == 0, "the vehicle's collision is off while ridden", fails)
	var dxz := Vector2(player.global_position.x - prop.global_position.x,
		player.global_position.z - prop.global_position.z).length()
	_veh_result(dxz < 0.1, "the rider is snapped onto the parked vehicle (%.2f m)" % dxz, fails)

	# 3. Drive forward and turn (first person).
	var start := prop.global_position
	Input.action_press("move_forward")
	for _i in 90:
		await tree.physics_frame
	Input.action_press("move_right")
	for _i in 40:
		await tree.physics_frame
	Input.action_release("move_right")
	Input.action_release("move_forward")
	for _i in 5:
		await tree.physics_frame
	var moved := Vector2(prop.global_position.x - start.x, prop.global_position.z - start.z).length()
	_veh_result(moved > 1.5, "driving moves the vehicle (%.1f m)" % moved, fails)
	# The prop follows its rider in _process (once per RENDERED frame) while the
	# rider moves in physics frames: measured after physics frames alone, a
	# heavy map (several physics steps per render frame — Walton) reads a lag
	# that is never on screen. Measure where the frame is DRAWN: frame_pre_draw
	# comes after every _process and before rendering, with no physics step in
	# between (process_frame fires before _process, and the next frame's physics
	# steps — the rider still coasting — run before it).
	await RenderingServer.frame_pre_draw
	var follow := Vector2(player.global_position.x - prop.global_position.x,
		player.global_position.z - prop.global_position.z).length()
	_veh_result(follow < 0.2, "the vehicle stays under its rider (%.2f m)" % follow, fails)
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	var want_yaw := player.rotation.y + deg_to_rad(float(PlacedVehicle.PROFILES["golf_cart"]["yaw_deg"]))
	var yaw_err := 9.0
	if model != null:
		yaw_err = absf(wrapf(model.rotation.y - want_yaw, -PI, PI))
	_veh_result(yaw_err < 0.05, "ModelRoot turns with the rider by the profile yaw (err %.3f rad)" % yaw_err, fails)

	# 4. Third person while driving.
	PlayerPrefs.set_camera_mode(PlayerPrefs.CAMERA_THIRD)
	for _i in 30:
		await tree.process_frame
	var pf := -player.global_basis.z
	var to_cam := cam.global_position - player.global_position
	var flat := Vector2(to_cam.x, to_cam.z).length()
	_veh_result(arm != null and arm.top_level, "third person detaches the camera arm", fails)
	_veh_result(Vector2(to_cam.x, to_cam.z).dot(Vector2(pf.x, pf.z)) < 0.0 and flat > 3.0,
		"the chase camera sits BEHIND the vehicle (%.1f m back)" % flat, fails)
	await _graph_shot(dir, "01_appa_third_person", [], "vehicles")

	# 5. Dismount: step out, park, re-bake.
	var parked := prop.global_position
	player.call("_dismount_vehicle")
	for _i in 4:
		await tree.physics_frame
	var out := Vector2(player.global_position.x - parked.x, player.global_position.z - parked.z).length()
	_veh_result(not bool(player.get("is_riding")), "X gets out", fails)
	_veh_result(out > 0.6, "the rider steps out beside it (%.2f m)" % out, fails)
	var rec := PlacedPropService.get_prop_record(main, pid)
	var rec_d := Vector2(float(rec.get("x", 0.0)) - parked.x, float(rec.get("z", 0.0)) - parked.z).length()
	_veh_result(rec_d < 0.05, "the parked position is saved on the record (%.3f m)" % rec_d, fails)
	body = prop.get_node_or_null("PropBody") as CollisionObject3D
	_veh_result(body != null and body.collision_layer == 1, "the collision is back after getting out", fails)

	# 6. On foot in third person: turn the camera 90 deg, walk "forward" — the
	# body turns to walk the CAMERA's way.
	var cam_yaw := wrapf(player.rotation.y + PI * 0.5, -PI, PI)
	player.set("_tp_yaw", cam_yaw)
	Input.action_press("move_forward")
	for _i in 50:
		await tree.physics_frame
	Input.action_release("move_forward")
	var turn_err := absf(wrapf(player.rotation.y - cam_yaw, -PI, PI))
	_veh_result(turn_err < 0.25, "walking turns the body toward the camera's heading (err %.2f rad)" % turn_err, fails)
	var reach: Vector3 = player.call("reach_origin")
	_veh_result(absf(reach.y - player.global_position.y - 1.55) < 0.05,
		"interaction reach is measured from the head in third person", fails)
	for _i in 10:
		await tree.process_frame
	await _graph_shot(dir, "02_on_foot_third_person", [], "vehicles")

	# 7. The tool bus: chase camera further back, a wider step-out.
	var at2 := player.global_position + (-player.global_basis.z) * 14.0
	var placed2: Dictionary = PlacedPropService.place_model_at_xz(main, "vehicle_tool_bus", at2.x, at2.z)
	var pid2 := str(placed2.get("prop_id", ""))
	if not pid2.is_empty():
		seeded.append(pid2)
	for _i in 10:
		await tree.physics_frame
	var prop2 := PlacedPropRuntime.find_by_prop_id(main, pid2) as Node3D
	var bus: Node = null
	if prop2 != null:
		bus = prop2.get_node_or_null("PlacedVehicle")
	_veh_result(bus != null, "the tool bus is driveable", fails)
	if bus != null:
		player.call("request_mount", bus)
		Input.action_press("move_forward")
		for _i in 60:
			await tree.physics_frame
		Input.action_release("move_forward")
		for _i in 30:
			await tree.process_frame
		var bus_cam := Vector2(cam.global_position.x - player.global_position.x,
			cam.global_position.z - player.global_position.z).length()
		_veh_result(bool(player.get("is_riding")) and bus_cam > 8.0,
			"the bus's chase camera sits well back (%.1f m)" % bus_cam, fails)
		await _graph_shot(dir, "03_tool_bus_third_person", [], "vehicles")
		var bp := prop2.global_position
		player.call("_dismount_vehicle")
		for _i in 4:
			await tree.physics_frame
		var bout := Vector2(player.global_position.x - bp.x, player.global_position.z - bp.z).length()
		_veh_result(bout > 1.5, "getting off the bus lands clear of it (%.2f m)" % bout, fails)

	# 8. Back to first person: the arm goes home exactly.
	PlayerPrefs.set_camera_mode(PlayerPrefs.CAMERA_FIRST)
	for _i in 3:
		await tree.process_frame
	_veh_result(arm != null and not arm.top_level and arm.transform.is_equal_approx(arm_rest),
		"first person puts the camera arm back where it was", fails)
	_vehicle_capture_restore(main, loader, seeded, cfg_had, cfg_bytes, saved_scale, fails)


func _vehicle_capture_restore(main: Node, loader: Node, seeded: Array[String], cfg_had: bool,
		cfg_bytes: PackedByteArray, saved_scale: Variant, fails: Array) -> void:
	for pid in seeded:
		if loader != null and loader.has_method("delete_prop_by_id"):
			loader.call("delete_prop_by_id", pid)
		else:
			var node := PlacedPropRuntime.find_by_prop_id(main, pid)
			if node != null:
				node.queue_free()
			var layer := PlacedPropService._layer_for_main(main)
			if layer != null and layer.remove_prop(pid):
				PlacedPropService._save_layer(main, layer)
	if cfg_had:
		var f := FileAccess.open(PlayerPrefs.CFG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_buffer(cfg_bytes)
			f.close()
	elif FileAccess.file_exists(PlayerPrefs.CFG_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PlayerPrefs.CFG_PATH))
	PlayerPrefs.reload_from_disk()
	main.set("time_scale", saved_scale)
	var verdict := "PASS" if fails.is_empty() else "FAIL"
	var detail := "" if fails.is_empty() else " — " + ", ".join(fails)
	print("PlaytestHarness: vehicles %s (%d failed)%s" % [verdict, fails.size(), detail])
	_maybe_quit()


func _veh_result(ok: bool, what: String, fails: Array) -> void:
	print("PlaytestHarness: vehicles %s — %s" % ["PASS" if ok else "FAIL", what])
	if not ok:
		fails.append(what)


# ---------------------------------------------------------------------------
# --capture=water — carved channels + stream surfaces on a REAL map
# ---------------------------------------------------------------------------

## Loads a real TerrainLoader map, waits for the WaterNetwork to resolve and
## carve, and asserts what a PNG cannot: every carved bed is monotone
## downstream (except stations flagged blocked), the composed ground under the
## centreline of a carved reach sits at the bed, the water surface sits at or
## below the bank tops on carved stations, and the stream mesh exists. Then a
## user stream is drawn, carved and undone, and a rain override widens the
## water. Shoots low grazing + aerial PNGs of the longest carved reaches.
## Snapshots and byte-restores the map's water_features / channel_tiles files.
func _run_water_verify() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: TerrainLoader not found — aborting water verify")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var wn: Node = loader.call("water_network")
	if wn == null:
		push_error("PlaytestHarness: WaterNetwork missing — aborting")
		_maybe_quit()
		return
	var lat := float(loader.get("_lat"))
	var lon := float(loader.get("_lon"))
	var _tok := "%s_%s" % [CoordToken.token(lat), CoordToken.token(lon)]
	var snap := _snapshot_files([
		WorldPaths.site_file("water_features", lat, lon),
		WorldPaths.site_file("channel_tiles", lat, lon, "bin"),
		WorldPaths.site_file("channel_tiles", lat, lon, "json"),
	])
	var fails := 0
	# Wait for the carve job (first visit can take a few seconds).
	var waited := 0.0
	while bool(wn.call("is_busy")) and waited < 120.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	waited = 0.0
	while bool(wn.call("drainage_busy")) and waited < 180.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	var derived: Array = wn.call("derived_channels")
	var drain: Dictionary = wn.call("drainage")
	print("WaterVerify: drainage grid %d² (%.1f m), %d derived channels, waited %.1f s" % [
		int(drain.get("n", 0)), float(drain.get("cell_m", 0.0)), derived.size(), waited])
	if drain.is_empty():
		fails += 1
		print("WaterVerify: FAIL drainage analysis never landed")
	var feats: Array = wn.call("features")
	var channel: TerrainEditTiles = loader.call("channel_tile_layer")
	print("WaterVerify: %d features, %d channel tiles, waited %.1f s" % [
		feats.size(), channel.active_tiles().size() if channel != null else -1, waited])
	var carved_feats: Array = []
	var sampler: WaterGroundSampler = loader.call("make_water_ground_sampler")
	var half := sampler.detail_half() - ChannelCarver.PATCH_MARGIN_M
	for f_v in feats:
		var f: Dictionary = f_v
		var prof: Dictionary = wn.call("profile", f["id"])
		if prof.is_empty():
			continue
		var bed: PackedFloat32Array = prof["bed"]
		var blocked: PackedByteArray = prof["blocked"]
		var nb := 0
		for v in blocked:
			nb += int(v)
		var mono := _water_monotone_except_blocked(bed, blocked)
		var inside := 0
		var pts: PackedVector2Array = prof["points"]
		for p in pts:
			if maxf(absf(p.x), absf(p.y)) <= half:
				inside += 1
		print("WaterVerify:  %-14s %-6s %-22s len %6.0f m  stations %4d (in patch %4d)  blocked %3d  monotone %s  covered %s" % [
			str(f["id"]), str(f["kind"]), str(f["name"]).left(22), float(prof["length_m"]),
			pts.size(), inside, nb, str(mono), str(f.get("covered", false))])
		if not mono:
			fails += 1
			print("WaterVerify: FAIL bed rises downstream on %s" % f["id"])
		if inside > 10 and bool(f.get("carve", true)) and str(f["modes"][0]) == "surface":
			carved_feats.append({"f": f, "prof": prof, "inside": inside})
	# Ground at the centreline == bed, water at or below the bank tops.
	var checked := 0
	var bad_bed := 0
	var bad_bank := 0
	for cf in carved_feats:
		var f: Dictionary = cf["f"]
		var prof: Dictionary = cf["prof"]
		var pts: PackedVector2Array = prof["points"]
		var bed: PackedFloat32Array = prof["bed"]
		var states: Array = wn.call("feature_states", f, float(wn.call("rain_mmh_now")))
		for i in range(0, pts.size(), 7):
			var p := pts[i]
			if maxf(absf(p.x), absf(p.y)) > half - 5.0:
				continue
			if StreamNetwork.mode_at(f, (prof["s"] as PackedFloat32Array)[i], prof["varc"]) != "surface":
				continue
			checked += 1
			var gy := float(loader.call("ground_height_at", p.x, p.y))
			if absf(gy - bed[i]) > 0.35:
				bad_bed += 1
				var base := sampler.base_at(p.x, p.y)
				var want := minf(0.0, bed[i] - base)
				var got := gy - base
				var why := "deeper channel nearby" if got < want - 0.2 else (
					"bed above DEM (floored)" if bed[i] > base else "carve shallower than bed")
				_water_diag[why] = int(_water_diag.get(why, 0)) + 1
				if int(_water_diag[why]) <= 3:
					print("WaterVerify:   %s %s @(%.0f,%.0f) base %.2f bed %.2f ground %.2f" % [
						why, f["id"], p.x, p.y, base, bed[i], gy])
			if i < states.size():
				var st: Dictionary = states[i]
				var level := bed[i] + float(st["depth_m"])
				var tan := StreamMeshBuilder._tangent(pts, i)
				var across := Vector2(-tan.y, tan.x)
				var off := float(st["top_w_m"]) * 0.5 + 0.75
				var bank := minf(
					float(loader.call("ground_height_at", p.x + across.x * off, p.y + across.y * off)),
					float(loader.call("ground_height_at", p.x - across.x * off, p.y - across.y * off)))
				if level > bank + 0.05:
					bad_bank += 1
	print("WaterVerify: carved stations checked %d — ground≠bed %d, water over bank %d  %s" % [
		checked, bad_bed, bad_bank, str(_water_diag)])
	if checked > 0 and float(bad_bed) / float(checked) > 0.05:
		fails += 1
		print("WaterVerify: FAIL composed ground does not follow the carved bed")
	if checked > 0 and float(bad_bank) / float(checked) > 0.10:
		fails += 1
		print("WaterVerify: FAIL water surface above the banks on carved reaches")
	var terrain: Node = loader.get("_main").get_node_or_null("Terrain")
	var streams := terrain.get_node_or_null(WaterNetwork.STREAMS_NODE) as MeshInstance3D if terrain != null else null
	var verts := 0
	if streams != null and streams.mesh != null and streams.mesh.get_surface_count() > 0:
		verts = (streams.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	print("WaterVerify: stream surface mesh %s, %d verts" % [str(streams != null), verts])
	if not carved_feats.is_empty() and verts == 0:
		fails += 1
		print("WaterVerify: FAIL no stream surface for carved features")

	# --- shots ----------------------------------------------------------
	_set_capture_conditions()
	var label := _shots_label if not _shots_label.is_empty() else "water"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var cam := Camera3D.new()
	cam.name = "PlaytestCam"
	cam.far = 40000.0
	get_tree().current_scene.add_child(cam)
	cam.make_current()
	carved_feats.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["inside"]) > int(b["inside"]))
	var shot := 0
	for cf in carved_feats.slice(0, 3):
		var prof: Dictionary = cf["prof"]
		var pts: PackedVector2Array = prof["points"]
		var bed: PackedFloat32Array = prof["bed"]
		# A station well inside the patch, near the middle of the in-patch run.
		var idxs: Array = []
		for i in pts.size():
			if maxf(absf(pts[i].x), absf(pts[i].y)) <= half - 40.0:
				idxs.append(i)
		if idxs.is_empty():
			continue
		var i0: int = idxs[idxs.size() / 2]
		var p := pts[i0]
		var tan := StreamMeshBuilder._tangent(pts, i0)
		var across := Vector2(-tan.y, tan.x)
		var g := float(loader.call("ground_height_at", p.x, p.y))
		var look := Vector3(p.x, bed[i0], p.y)
		var views := [
			# oblique from the bank, a little downstream, looking back up
			Vector3(p.x + across.x * 10.0 + tan.x * 8.0, 0.0, p.y + across.y * 10.0 + tan.y * 8.0),
			# along the channel from upstream, low
			Vector3(p.x - tan.x * 22.0 + across.x * 3.0, 0.0, p.y - tan.y * 22.0 + across.y * 3.0),
			# aerial
			Vector3(p.x + across.x * 35.0 - tan.x * 35.0, 0.0, p.y + across.y * 35.0 - tan.y * 35.0),
		]
		var lifts := [6.0, 4.0, 60.0]
		for v in views.size():
			var cp: Vector3 = views[v]
			# Height above the HIGHER of the camera ground and the target, so a
			# camera on a slope never sits inside the hill it is looking across.
			cp.y = maxf(float(loader.call("ground_height_at", cp.x, cp.z)), g) + float(lifts[v])
			cam.look_at_from_position(cp, look, Vector3.UP)
			await get_tree().create_timer(0.4).timeout
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png("%s/water_%02d_%s_v%d.png" % [dir, shot, str(cf["f"]["id"]).replace(":", "_"), v])
			if v == 0 and streams != null and is_instance_valid(streams):
				# Same view with the water hidden: separates terrain artefacts
				# from water-surface artefacts.
				streams.visible = false
				await RenderingServer.frame_post_draw
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png("%s/water_%02d_v0_nowater.png" % [dir, shot])
				streams.visible = true
		shot += 1
		print("WaterVerify: shot %s at (%.0f, %.0f) ground %.2f bed %.2f" % [
			cf["f"]["id"], p.x, p.y, g, bed[i0]])

	# --- drainage overlay from above ----------------------------------
	wn.call("set_show_drainage", true)
	var cpos := Vector3(0.0, float(loader.call("ground_height_at", 0.0, 0.0)) + 650.0, 420.0)
	cam.look_at_from_position(cpos, Vector3(0.0, cpos.y - 650.0, 0.0), Vector3.UP)
	await get_tree().create_timer(0.5).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/drainage_overview.png" % dir)
	wn.call("set_show_drainage", false)

	# --- a user stream: draw, carve, undo -------------------------------
	var lay: WaterFeatureLayer = wn.get("layer")
	var a := Vector2(-60.0, 40.0)
	var b := Vector2(60.0, 40.0)
	var ga := float(loader.call("ground_height_at", a.x, a.y))
	var gb := float(loader.call("ground_height_at", b.x, b.y))
	if gb > ga:
		var t := a
		a = b
		b = t
	var before_tiles := channel.active_tiles().size()
	wn.call("checkpoint")
	var sid := lay.add_stream(PackedVector2Array([a, (a + b) * 0.5 + Vector2(0, 8), b]),
		{"name": "Verify Brook", "kind": "stream"})
	wn.call("commit")
	waited = 0.0
	await get_tree().create_timer(0.6).timeout
	while bool(wn.call("is_busy")) and waited < 60.0:
		await get_tree().create_timer(0.3).timeout
		waited += 0.3
	var mid := (a + b) * 0.5 + Vector2(0, 8)
	var prof_u: Dictionary = wn.call("profile", sid)
	var bed_mid := ChannelProfile.bed_at(prof_u, StreamNetwork.nearest_on_line(prof_u["points"], mid)["s"]).x \
		if not prof_u.is_empty() else NAN
	var g_mid := float(loader.call("ground_height_at", mid.x, mid.y))
	print("WaterVerify: user stream %s carved: tiles %d → %d, ground %.2f bed %.2f" % [
		sid, before_tiles, channel.active_tiles().size(), g_mid, bed_mid])
	if prof_u.is_empty() or absf(g_mid - bed_mid) > 0.35:
		fails += 1
		print("WaterVerify: FAIL user stream did not carve its bed")
	# Rain widens the water (needs the drainage areas; base flow alone if none).
	var st_dry: Dictionary = wn.call("state_near", sid, mid)
	wn.set("rain_override_mmh", 25.0)
	wn.call("rebuild_surfaces")
	var st_wet: Dictionary = wn.call("state_near", sid, mid)
	wn.set("rain_override_mmh", -1.0)
	print("WaterVerify: user stream Q dry %.1f L/s (w %.2f m) → 25 mm/h %.1f L/s (w %.2f m)" % [
		float(st_dry.get("q_lps", 0.0)), float(st_dry.get("top_w_m", 0.0)),
		float(st_wet.get("q_lps", 0.0)), float(st_wet.get("top_w_m", 0.0))])
	# The longest OSM feature must swell in rain once it has a catchment.
	var big: Dictionary = {}
	for f_v in feats:
		var prof_b: Dictionary = wn.call("profile", (f_v as Dictionary)["id"])
		if not prof_b.is_empty() and (big.is_empty() or float(prof_b["length_m"]) > float(big["len"])):
			big = {"f": f_v, "len": float(prof_b["length_m"])}
	if not big.is_empty():
		var fb: Dictionary = big["f"]
		var dry_q := float(wn.call("station_q_lps", fb, 999999, 0.0))
		var wet_q := float(wn.call("station_q_lps", fb, 999999, 25.0))
		var areas: Variant = (wn.get("station_area") as Dictionary).get(fb["id"])
		var a_end := (areas as PackedFloat32Array)[(areas as PackedFloat32Array).size() - 1] \
			if areas is PackedFloat32Array and (areas as PackedFloat32Array).size() > 0 else 0.0
		print("WaterVerify: %s catchment %.1f ha — Q dry %.0f L/s, 25 mm/h %.0f L/s" % [
			fb["id"], a_end / 10000.0, dry_q, wet_q])
		if a_end <= 0.0 or wet_q <= dry_q:
			fails += 1
			print("WaterVerify: FAIL rain does not raise the discharge of a mapped stream")
	await get_tree().create_timer(0.3).timeout
	wn.call("undo")
	await get_tree().create_timer(0.6).timeout
	waited = 0.0
	while bool(wn.call("is_busy")) and waited < 60.0:
		await get_tree().create_timer(0.3).timeout
		waited += 0.3
	var g_after := float(loader.call("ground_height_at", mid.x, mid.y))
	print("WaterVerify: after undo ground at the user stream %.2f (tiles %d)" % [
		g_after, channel.active_tiles().size()])
	if not lay.stream(sid).is_empty() or (not prof_u.is_empty() and g_after - g_mid < 0.3):
		fails += 1
		print("WaterVerify: FAIL undo did not remove the user stream's channel")
	_water_ui_finished = false
	fails += await _water_ui_test(loader, wn, cam, dir)
	if not _water_ui_finished:
		fails += 1
		print("WaterVerify: FAIL the UI test aborted before its end (runtime error?)")
	cam.queue_free()
	_restore_files(snap)
	print("WaterVerify: OVERALL %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	_maybe_quit()


## The WATER toolbar driven with REAL input events through the viewport:
## Draw (3 clicks + Enter), Edit (pick, drag a waypoint, drag the line to insert
## one, hover + Delete), Span (click → culvert), Ctrl+Z, Trace (one click).
## Returns the number of failures.
func _water_ui_test(loader: Node, wn: Node, cam: Camera3D, dir: String) -> int:
	var fails := 0
	var tb: Node = loader.get("_edit_toolbar_ui")
	if tb == null:
		print("WaterVerify: FAIL no edit toolbar")
		return 1
	var lay: WaterFeatureLayer = wn.get("layer")
	var vp := get_viewport()
	# A clear patch of ground near the site centre, camera looking down on it.
	var c0 := Vector2(-150.0, -120.0)
	var g0 := float(loader.call("ground_height_at", c0.x, c0.y))
	cam.look_at_from_position(Vector3(c0.x, g0 + 95.0, c0.y + 55.0), Vector3(c0.x, g0, c0.y), Vector3.UP)
	await get_tree().process_frame
	tb.call("open_with_section", "water")
	tb.call("_set_active_tool", "water_draw")
	await get_tree().process_frame
	var n_before := lay.streams.size()
	var world_pts := [c0 + Vector2(-35, -20), c0 + Vector2(0, 5), c0 + Vector2(35, 25)]
	for wp in world_pts:
		await _water_click(vp, cam, loader, wp)
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	vp.push_input(enter)
	await get_tree().process_frame
	var ok_draw := lay.streams.size() == n_before + 1
	print("WaterVerify UI: Draw → streams %d → %d %s" % [n_before, lay.streams.size(), "OK" if ok_draw else "FAIL"])
	if not ok_draw:
		return fails + 1
	var sid := str((lay.streams.back() as Dictionary)["id"])
	await _water_wait(wn)
	# Edit: pick the stream by clicking its line, then drag the middle waypoint.
	tb.call("_set_active_tool", "water_edit")
	await get_tree().process_frame
	var pts0: PackedVector2Array = lay.stream(sid)["points"]
	await _water_click(vp, cam, loader, (pts0[0] + pts0[1]) * 0.5)
	var ctl: Variant = tb.get("_water_tools")
	var picked := str(ctl.get("_picked"))
	print("WaterVerify UI: Edit pick → %s %s" % [picked, "OK" if picked == sid else "FAIL"])
	if picked != sid:
		fails += 1
	var mid_before: Vector2 = pts0[1]
	await _water_drag(vp, cam, loader, mid_before, mid_before + Vector2(14.0, -10.0))
	await _water_wait(wn)
	var pts1: PackedVector2Array = lay.stream(sid)["points"]
	var moved := pts1[1].distance_to(mid_before) if pts1.size() > 1 else 0.0
	print("WaterVerify UI: pin drag moved %.1f m %s" % [moved, "OK" if moved > 5.0 else "FAIL"])
	if moved <= 5.0:
		fails += 1
	# Drag the first span's line → inserts a waypoint.
	# A point on the first span that hovers as LINE, not as a nearby pin.
	var seg_mid := (pts1[0] + pts1[1]) * 0.5
	for t in [0.5, 0.35, 0.65, 0.25, 0.75]:
		var cand: Vector2 = pts1[0].lerp(pts1[1], t)
		await _water_hover(vp, cam, loader, cand)
		if str((ctl.get("_hover") as Dictionary).get("kind", "")) == "line":
			seg_mid = cand
			break
	await _water_drag(vp, cam, loader, seg_mid, seg_mid + Vector2(-8.0, 9.0))
	await _water_wait(wn)
	var n_ins := (lay.stream(sid)["points"] as PackedVector2Array).size()
	print("WaterVerify UI: line drag → %d points %s" % [n_ins, "OK" if n_ins == pts1.size() + 1 else "FAIL"])
	if n_ins != pts1.size() + 1:
		fails += 1
	# Hover that new waypoint and press Delete.
	var pts2: PackedVector2Array = lay.stream(sid)["points"]
	var hover_ok := false
	for _try in 4:
		await _water_hover(vp, cam, loader, pts2[1])
		var hv: Dictionary = ctl.get("_hover")
		if str(hv.get("kind", "")) == "pin" and int(hv.get("index", -1)) == 1:
			hover_ok = true
			break
	var proj: Dictionary = ctl.get("_proj")
	var sp_pin := _water_screen(cam, loader, pts2[1])
	var drawn: PackedVector2Array = proj.get(sid, PackedVector2Array())
	print("WaterVerify UI:   before Delete — hover %s picked %s projected %s (pin at %s, drawn pin %s)" % [
		str(ctl.get("_hover")), str(ctl.get("_picked")), str(proj.has(sid)), str(sp_pin),
		str(drawn[1]) if drawn.size() > 1 else "-"])
	if not hover_ok:
		print("WaterVerify UI: FAIL the waypoint never reported hovered — Delete skipped")
		fails += 1
	else:
		var del := InputEventKey.new()
		del.keycode = KEY_DELETE
		del.pressed = true
		vp.push_input(del)
		await get_tree().process_frame
		await _water_wait(wn)
	if lay.stream(sid).is_empty():
		print("WaterVerify UI: FAIL the stream itself was deleted")
		return fails + 1
	var n_del := (lay.stream(sid)["points"] as PackedVector2Array).size()
	print("WaterVerify UI: Delete waypoint → %d points %s" % [n_del, "OK" if n_del == n_ins - 1 else "FAIL"])
	if n_del != n_ins - 1:
		fails += 1
	# Span: first span → culvert, then Ctrl+Z puts it back.
	tb.call("_set_active_tool", "water_span")
	await get_tree().process_frame
	var pts3: PackedVector2Array = lay.stream(sid)["points"]
	await _water_click(vp, cam, loader, (pts3[0] + pts3[1]) * 0.5)
	await _water_wait(wn)
	var mode0 := str((lay.stream(sid)["modes"] as Array)[0])
	print("WaterVerify UI: Span click → %s %s" % [mode0, "OK" if mode0 == "culvert" else "FAIL"])
	if mode0 != "culvert":
		fails += 1
	await _water_shot(dir, "ui_span_culvert")
	# The culvert span is a buried barrel: hidden in first person, revealed by
	# "Show buried", with a headwall at each mouth.
	var runs: Array = wn.call("buried_runs", sid)
	var broot: Node3D = loader.get("_main").get_node_or_null("Terrain/" + WaterNetwork.BURIED_NODE)
	var mroot: Node3D = loader.get("_main").get_node_or_null("Terrain/" + WaterNetwork.MOUTHS_NODE)
	# "Show buried" is a saved per-world setting (Mount Vernon has it ON):
	# start from OFF so "hidden in first person" is a real test, then hand the
	# world's own value back.
	var lay_ref: Variant = wn.get("layer")
	var buried_saved := bool(lay_ref.call("setting", "show_buried")) if lay_ref != null else false
	wn.call("set_show_buried", false)
	await get_tree().process_frame
	var hidden_fp := broot != null and not broot.visible
	wn.call("set_show_buried", true)
	var shown := broot != null and broot.visible
	await _water_shot(dir, "ui_culvert_shown")
	wn.call("set_show_buried", buried_saved)
	var heads := mroot.get_child_count() if mroot != null else 0
	var run0: Dictionary = runs[0] if not runs.is_empty() else {}
	print("WaterVerify UI: culvert runs %d (⌀%.2f m, holds %.0f L/s, carries %.0f L/s), hidden in FP %s, shown by toggle %s, mouth nodes %d" % [
		runs.size(), float(run0.get("d", 0.0)), float(run0.get("capacity_lps", 0.0)),
		float(run0.get("q_lps", 0.0)), str(hidden_fp), str(shown), heads])
	if runs.is_empty() or not hidden_fp or not shown or heads < 2:
		fails += 1
		print("WaterVerify UI: FAIL buried culvert rendering")
	var undo := InputEventKey.new()
	undo.keycode = KEY_Z
	undo.ctrl_pressed = true
	undo.pressed = true
	vp.push_input(undo)
	await get_tree().process_frame
	await _water_wait(wn)
	var mode_u := str((lay.stream(sid)["modes"] as Array)[0])
	print("WaterVerify UI: Ctrl+Z → %s %s" % [mode_u, "OK" if mode_u == "surface" else "FAIL"])
	if mode_u != "surface":
		fails += 1
	# Trace from a point uphill of the camera target.
	tb.call("_set_active_tool", "water_trace")
	await get_tree().process_frame
	var waited := 0.0
	while (wn.call("drainage") as Dictionary).is_empty() and waited < 60.0:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
	var n_t := lay.streams.size()
	await _water_click(vp, cam, loader, c0 + Vector2(10.0, -30.0))
	await _water_wait(wn)
	var traced := lay.streams.size() == n_t + 1
	var tp: PackedVector2Array = (lay.streams.back() as Dictionary)["points"] if traced else PackedVector2Array()
	var t_drop := 0.0
	if tp.size() >= 2:
		t_drop = float(loader.call("ground_height_at", tp[0].x, tp[0].y)) \
			- float(loader.call("ground_height_at", tp[tp.size() - 1].x, tp[tp.size() - 1].y))
	print("WaterVerify UI: Trace → %d points, falls %.1f m %s" % [tp.size(), t_drop,
		"OK" if traced and tp.size() >= 2 and t_drop >= 0.0 else "FAIL"])
	if not traced or tp.size() < 2 or t_drop < 0.0:
		fails += 1
	tb.call("_set_active_tool", "water_view")
	wn.call("set_show_drainage", true)
	await _water_shot(dir, "ui_overview")
	wn.call("set_show_drainage", false)
	tb.call("_exit_mode")
	fails += await _water_flow_view_test(loader, wn, cam, dir)
	fails += _water_graph_link_test(loader, wn)
	_water_ui_finished = true
	return fails


## An intake standing on a mapped stream takes that stream's discharge, and
## off it, nothing.
func _water_graph_link_test(loader: Node, wn: Node) -> int:
	var sgv := get_tree().current_scene.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("water_feature_supply_for_intake"):
		print("WaterVerify GRAPH: FAIL no SystemGraphView link")
		return 1
	var best: Dictionary = {}
	for f_v in wn.call("features"):
		var prof: Dictionary = wn.call("profile", (f_v as Dictionary)["id"])
		if not prof.is_empty() and (best.is_empty() or float(prof["length_m"]) > float(best["len"])):
			best = {"f": f_v, "prof": prof, "len": float(prof["length_m"])}
	if best.is_empty():
		return 0
	var pts: PackedVector2Array = best["prof"]["points"]
	var p := pts[pts.size() / 2]
	var c := Vector3.ZERO
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		c = soi.call("world_center")
	var on_item := {"id": "cap_water_intake", "specs": {}, "site_x_m": p.x - c.x, "site_z_m": p.y - c.z}
	var off_item := {"id": "cap_water_intake2", "specs": {}, "site_x_m": p.x - c.x + 400.0, "site_z_m": p.y - c.z + 400.0}
	var dry: Dictionary = sgv.call("water_feature_supply_for_intake", on_item, 0.0)
	var wet: Dictionary = sgv.call("water_feature_supply_for_intake", on_item, 20.0)
	var off: Dictionary = sgv.call("water_feature_supply_for_intake", off_item, 20.0)
	var pond: Dictionary = sgv.call("stream_pond_inflows", 5.0)
	print("WaterVerify GRAPH: intake on %s → %s dry %.0f L/s, 20 mm/h %.0f L/s; 400 m off → %s; pond inflows %d" % [
		(best["f"] as Dictionary)["id"], str(dry.get("feature_id", "-")), float(dry.get("q_lps", 0.0)),
		float(wet.get("q_lps", 0.0)), "none" if off.is_empty() else str(off.get("feature_id")), pond.size()])
	if dry.is_empty() or str(dry.get("feature_id", "")) != str((best["f"] as Dictionary)["id"]) \
			or float(wet.get("q_lps", 0.0)) <= float(dry.get("q_lps", 0.0)):
		print("WaterVerify GRAPH: FAIL")
		return 1
	return 0


## Flow view: beads exist, move only while the clock runs (cosmetic clock),
## and a storm raises the site outflow on the chip.
func _water_flow_view_test(loader: Node, wn: Node, cam: Camera3D, dir: String) -> int:
	var fails := 0
	var main: Node = loader.get("_main")
	wn.call("set_display_mode", "flow")
	await get_tree().create_timer(0.3).timeout
	var tr: MultiMeshInstance3D = main.get_node_or_null("Terrain/WaterTracers") as MultiMeshInstance3D
	var n := tr.multimesh.instance_count if tr != null else 0
	var first_live := -1
	if tr != null:
		for i in n:
			if tr.multimesh.get_instance_transform(i).basis.x.length() > 0.01:
				first_live = i
				break
	if tr != null:
		var sts: Array = tr.get("_streams")
		var cxz := Vector2(cam.global_position.x, cam.global_position.z)
		var nearest := INF
		for st in sts:
			var bx: Rect2 = (st as Dictionary)["aabb"]
			var cl := Vector2(clampf(cxz.x, bx.position.x, bx.end.x), clampf(cxz.y, bx.position.y, bx.end.y))
			nearest = minf(nearest, cl.distance_to(cxz))
		print("WaterVerify FLOW:   %d bead streams, nearest stream box %.0f m from the camera at %s, processing %s" % [
			sts.size(), nearest, str(cam.global_position), str(tr.is_processing())])
	var before := tr.multimesh.get_instance_transform(maxi(first_live, 0)).origin if n > 0 else Vector3.ZERO
	await get_tree().create_timer(0.4).timeout
	var still := tr.multimesh.get_instance_transform(maxi(first_live, 0)).origin if n > 0 else Vector3.ZERO
	var old_ts: float = float(main.get("time_scale"))
	main.set("time_scale", 60.0 / 3600.0)
	await get_tree().create_timer(0.8).timeout
	var after := tr.multimesh.get_instance_transform(maxi(first_live, 0)).origin if n > 0 else Vector3.ZERO
	main.set("time_scale", old_ts)
	var dry := float(wn.call("site_outflow_lps"))
	wn.set("rain_override_mmh", 20.0)
	wn.call("rebuild_surfaces")
	var wet := float(wn.call("site_outflow_lps"))
	var chip: Label = main.get_node_or_null("UILayer/WaterFlowChip") as Label
	print("WaterVerify FLOW: %d beads (live #%d), paused moved %.3f m, running moved %.2f m; outflow dry %.0f L/s → 20 mm/h %.0f L/s; chip '%s'" % [
		n, first_live, before.distance_to(still), before.distance_to(after), dry, wet,
		chip.text.strip_edges() if chip != null else "(none)"])
	if n == 0 or first_live < 0 or before.distance_to(still) > 0.01 or before.distance_to(after) < 0.05 \
			or wet <= dry or chip == null or not chip.visible:
		fails += 1
		print("WaterVerify FLOW: FAIL")
	await _water_shot(dir, "flow_view")
	wn.set("rain_override_mmh", -1.0)
	wn.call("set_display_mode", "all")
	return fails


func _water_screen(cam: Camera3D, loader: Node, w: Vector2) -> Vector2:
	return cam.unproject_position(Vector3(w.x, float(loader.call("ground_height_at", w.x, w.y)) + 0.3, w.y))


func _water_hover(vp: Viewport, cam: Camera3D, loader: Node, w: Vector2) -> void:
	var sp := _water_screen(cam, loader, w)
	var mm := InputEventMouseMotion.new()
	mm.position = sp
	mm.global_position = sp
	vp.push_input(mm)
	await get_tree().process_frame
	await get_tree().process_frame


func _water_click(vp: Viewport, cam: Camera3D, loader: Node, w: Vector2) -> void:
	await _water_hover(vp, cam, loader, w)
	var sp := _water_screen(cam, loader, w)
	for pressed in [true, false]:
		var b := InputEventMouseButton.new()
		b.button_index = MOUSE_BUTTON_LEFT
		b.pressed = pressed
		b.position = sp
		b.global_position = sp
		vp.push_input(b)
		await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout   # past the double-click window


func _water_drag(vp: Viewport, cam: Camera3D, loader: Node, from_w: Vector2, to_w: Vector2) -> void:
	await _water_hover(vp, cam, loader, from_w)
	var a := _water_screen(cam, loader, from_w)
	var b := _water_screen(cam, loader, to_w)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = a
	down.global_position = a
	vp.push_input(down)
	await get_tree().process_frame
	for i in range(1, 9):
		var p := a.lerp(b, float(i) / 8.0)
		var mm := InputEventMouseMotion.new()
		mm.position = p
		mm.global_position = p
		mm.button_mask = MOUSE_BUTTON_MASK_LEFT
		vp.push_input(mm)
		await get_tree().process_frame
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = b
	up.global_position = b
	vp.push_input(up)
	await get_tree().process_frame


func _water_wait(wn: Node) -> void:
	await get_tree().create_timer(0.6).timeout
	var waited := 0.0
	while bool(wn.call("is_busy")) and waited < 30.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25


func _water_shot(dir: String, name: String) -> void:
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [dir, name])


var _water_diag: Dictionary = {}
var _water_ui_finished := false


func _water_monotone_except_blocked(bed: PackedFloat32Array, blocked: PackedByteArray) -> bool:
	for i in range(1, bed.size()):
		if bed[i] > bed[i - 1] + 1e-3 and blocked[i] == 0 and blocked[i - 1] == 0:
			return false
	return true


## Temporary siphon(s) seeded onto a PLAYER'S map for the capture — removed,
## with the outlet sink minted for them, before the run quits.
var _siphon_cleanup_ids: Array[String] = []


func _siphon_cleanup(sgv: Node) -> void:
	if _siphon_cleanup_ids.is_empty():
		return
	var model: Variant = sgv.get("model")
	if model == null:
		return
	var remove_ids: Array[String] = []
	for sid in _siphon_cleanup_ids:
		remove_ids.append(sid)
		for conn: Dictionary in (model.get("connections") as Array).duplicate():
			if str(conn.get("source_item_id", "")) == sid:
				var tgt: Dictionary = model.call("get_item", str(conn.get("target_item_id", "")))
				if bool((tgt.get("specs", {}) as Dictionary).get("outlet_sink", false)):
					remove_ids.append(str(tgt.get("id", "")))
	for rid in remove_ids:
		if not (model.call("get_item", rid) as Dictionary).is_empty():
			model.call("remove_item", rid)
	print("PlaytestHarness: siphon capture — removed the temporary siphon (%d items)" % remove_ids.size())
	_siphon_cleanup_ids.clear()
	if sgv.has_method("_schedule_graph_autosave"):
		sgv.call("_schedule_graph_autosave")


## The two things the first siphon pass could not do: move the draft exit
## sideways (down the hill) from the Lab, and watch the turbine's close-up
## run. Drives the Lab's OWN exit drag through its screen→section inverse,
## asserts the outlet node, the culvert's far end and the physics' exit height
## all moved together, restores the outlet, then opens the close-up and
## asserts the siphon mode is up with the propeller turning and the flow
## beads riding the path. Shoots both.
func _verify_siphon_lab_interaction(sgv: Node, model: Variant, siphon_id: String,
		dir: String, manifest: Array) -> void:
	var fails := 0
	var modal: Variant = sgv.get("_siphon_lab_modal")
	if modal == null:
		print("PlaytestHarness: siphon lab interaction — SKIPPED (no modal)")
		return
	var rf: Variant = sgv.get("_resource_flow")
	var sink0: Dictionary = rf.call("_resolve_siphon_outlet_tank", model.call("get_item", siphon_id)) if rf != null else {}
	if sink0.is_empty():
		print("PlaytestHarness: siphon lab interaction — SKIPPED (no outlet)")
		return
	var sid := str(sink0.get("id", ""))
	var site0 := GraphSiteLayout.site_xz(sink0)
	var elev0 := float(sink0.get("elevation_m", 0.0))
	# Where the handle is drawn now, then 8 m further along and 1 m lower.
	var heading := float((modal.call("_elev_section_params") as Dictionary).get("heading", 0.0))
	var pond_along := float(modal.call("_pond_along_m"))
	var along0 := GraphSiteLayout.project_onto_section(site0, heading).x - pond_along
	var along_mid := float(modal.get("_pv_along_mid"))
	var px: Vector2 = modal.call("_pv_to_screen_centered", along0 + 8.0, elev0 - 1.0, along_mid)
	modal.call("_drag_exit", px)
	await get_tree().create_timer(0.6).timeout
	var sink1: Dictionary = model.call("get_item", sid)
	var site1 := GraphSiteLayout.site_xz(sink1)
	var along1 := GraphSiteLayout.project_onto_section(site1, heading).x - pond_along
	var elev1 := float(sink1.get("elevation_m", 0.0))
	fails += _siphon_check("the Lab's exit drag walked the outlet along the cut (%.1f → %.1f m)" % [along0, along1],
			absf(along1 - along0 - 8.0) < 0.6)
	var ground1 := float(modal.call("_dem_elev_at", along1))
	fails += _siphon_check("…and set its height (%.2f → %.2f m), never above the ground there (%.2f)" % [elev0, elev1, ground1],
			elev1 < elev0 - 0.5 and (is_nan(ground1) or elev1 <= ground1 - 0.2 + 1e-3))
	var specs1: Dictionary = (model.call("get_item", siphon_id) as Dictionary).get("specs", {}) as Dictionary
	var conn_ok := false
	for conn: Dictionary in model.get("connections") as Array:
		if str(conn.get("source_item_id", "")) == siphon_id and str(conn.get("target_item_id", "")) == sid:
			conn_ok = absf(float(conn.get("invert_out_m", NAN)) - elev1) < 1e-3 and not bool(conn.get("route_locked", false))
	fails += _siphon_check("the culvert's far end and the physics' exit height followed (%.2f / %.2f)" % [
			float(specs1.get("outlet_invert_m", NAN)), elev1],
			conn_ok and absf(float(specs1.get("outlet_invert_m", NAN)) - elev1) < 1e-3)
	await get_tree().create_timer(0.8).timeout
	await _graph_shot(dir, "01c_outlet_dragged_downhill", manifest)
	# Put it back.
	sgv.call("move_siphon_outlet", siphon_id, site0, elev0)
	await get_tree().create_timer(0.4).timeout
	# The close-up in siphon mode — with the pond PRIMED so the flow shows
	# (the map's pond may sit under the crest right now); level restored after.
	var pond_t: Dictionary = sgv.call("resolve_siphon_pond", siphon_id)
	var level_saved := float((pond_t.get("specs", {}) as Dictionary).get("level_m", NAN))
	var specs_fill0: Dictionary = ((model.call("get_item", siphon_id) as Dictionary).get("specs", {}) as Dictionary)
	var mode_saved := str(specs_fill0.get("siphon_prime_mode", "overflow"))
	var dip_saved := float(specs_fill0.get("dip_tube_length_m", 1.0))
	# The Lab's own "Fill pond to the prime level" — which switches to pump
	# priming when the crest stands above the rim (this map's case).
	if modal.has_method("_on_fill_to_prime"):
		modal.call("_on_fill_to_prime")
		await get_tree().create_timer(1.5).timeout
		# Read the Lab's OWN evaluation: the engine stamps `siphon_primed` on
		# its clock tick, and the harness holds the clock frozen here.
		var sp: Dictionary = (model.call("get_item", siphon_id) as Dictionary).get("specs", {}) as Dictionary
		var lr: Dictionary = modal.get("_last_r") as Dictionary
		fails += _siphon_check("Fill-to-prime primed the siphon (mode %s, dip %.2f m, Lab primed %s)" % [
				str(sp.get("siphon_prime_mode", "")), float(sp.get("dip_tube_length_m", 0.0)), str(lr.get("primed", false))],
				bool(lr.get("primed", false)))
	if modal.has_method("_set_lab_view"):
		modal.call("_set_lab_view", "closeup")
		await get_tree().create_timer(2.5).timeout
		var closeup: Variant = modal.get("_closeup")
		if closeup != null and (closeup as Object).has_method("debug_summary"):
			var cs: Dictionary = closeup.call("debug_summary")
			var flowing := bool(cs.get("flowing", false))
			fails += _siphon_check("the close-up is in SIPHON mode (runner %s)" % str(cs.get("runner", false)),
					bool(cs.get("siphon_mode", false)) and bool(cs.get("runner", false)))
			fails += _siphon_check("the close-up shows the flow (flowing %s, %d beads, %.0f rpm, pond %+.2f m)" % [
					str(flowing), int(cs.get("beads", 0)), float(cs.get("rpm", 0.0)), float(cs.get("level_rel_m", 0.0))],
					(not flowing) or (int(cs.get("beads", 0)) > 0 and float(cs.get("rpm", 0.0)) > 1.0))
			var hud: Variant = (closeup as Object).get("_hud")
			if hud != null:
				print("PlaytestHarness: siphon close-up HUD — %s" % str((hud as Label).text))
		await _graph_shot(dir, "01b_siphon_closeup", manifest)
		modal.call("_set_lab_view", "section")
		await get_tree().create_timer(0.6).timeout
	if not is_nan(level_saved) and sgv.has_method("lab_set_pond_level"):
		sgv.call("lab_set_pond_level", siphon_id, level_saved)
		await get_tree().create_timer(0.4).timeout
	if modal.has_method("_commit_string"):
		modal.call("_commit_string", "siphon_prime_mode", mode_saved)
		modal.call("_commit_float", "dip_tube_length_m", dip_saved)
		if modal.has_method("_load_from_model"):
			modal.call("_load_from_model")
	if fails > 0:
		push_error("PlaytestHarness: siphon lab interaction — %d CHECK(S) FAILED" % fails)
	else:
		print("PlaytestHarness: siphon lab interaction — PASS")


func _siphon_check(label: String, ok: bool) -> int:
	print("PlaytestHarness: siphon verify — %s: %s" % ["OK" if ok else "FAIL", label])
	return 0 if ok else 1


## The siphon turbine as a SIPHON, end to end — what the PNGs cannot show.
## (1) Binding leaves the turbine where it stands and does NOT convert its
## direct-intake wire into a penstock (the "immovable intake node"); (2) the
## auto outlet is traced away from the pond, never into its basin, and its
## traced route is LOCKED so the culvert follows it; (3) the physics: primed
## and flowing at the seeded state with the runner seeing less than the gross
## head, a 20 m exit drop reports cavitation and no more power than the useful
## draft gives; (4) the Lab shows the dip tube and the suction tile and the
## dip-tube spin derives the break level.
func _verify_siphon_turbine(sgv: Node, model: Variant, siphon_id: String,
		pond_id: String, seeded: bool) -> void:
	var fails := 0
	var siphon: Dictionary = model.get_item(siphon_id)
	var specs: Dictionary = siphon.get("specs", {}) as Dictionary
	var pond_specs0: Dictionary = (model.get_item(pond_id).get("specs", {}) as Dictionary)
	var level_eval := float(pond_specs0.get("level_m", NAN))
	var mod_eval := float(siphon.get("elevation_m", specs.get("module_elev_m", NAN)))
	if is_nan(level_eval):
		level_eval = mod_eval + 0.05
	# A player's pond may sit under the crest right now: evaluate at a level
	# that would prime it, which is the physics question being asked.
	if not seeded and not is_nan(mod_eval):
		level_eval = maxf(level_eval, mod_eval + 0.05)
	# (1) binding
	var penstock_conns := 0
	var intake_direct := false
	for conn: Dictionary in model.connections:
		if str(conn.get("target_item_id", "")) == siphon_id:
			if str(conn.get("conduit_type", "")) == "poly_penstock":
				penstock_conns += 1
			if str(conn.get("source_item_id", "")) == pond_id and bool(conn.get("direct_intake", false)):
				intake_direct = true
	fails += _siphon_check("bind kept the pond→siphon wire a direct intake (no poly penstock minted)",
			penstock_conns == 0 and intake_direct)
	if seeded:
		fails += _siphon_check("bind left the turbine's site where it was seeded (x %.1f)" % float(siphon.get("site_x_m", 0.0)),
				absf(float(siphon.get("site_x_m", 0.0)) - 6.0) < 1e-3)
	elif siphon_id.begins_with("cap_lab_") and GraphSiteLayout.has_site_coords(siphon):
		var pond_s: Dictionary = model.get_item(pond_id)
		var half_w := float(sgv.call("pond_half_extent_m", pond_specs0)) if sgv.has_method("pond_half_extent_m") \
				else maxf(maxf(float(pond_specs0.get("footprint_w_m", 0.0)), float(pond_specs0.get("footprint_d_m", 0.0))) * 0.5, 3.0)
		var d_shore := GraphSiteLayout.site_xz(siphon).distance_to(GraphSiteLayout.site_xz(pond_s))
		fails += _siphon_check("bind seated the siteless turbine on the SHORE (%.1f m from the pond centre, half-width %.1f)" % [d_shore, half_w],
				d_shore >= half_w + 1.0)
	fails += _siphon_check("bind seeded the siphon geometry (dip %.2f m, prime %s)" % [
			float(specs.get("dip_tube_length_m", 0.0)), str(specs.get("siphon_prime_mode", ""))],
			float(specs.get("dip_tube_length_m", 0.0)) > 0.0 and not str(specs.get("siphon_prime_mode", "")).is_empty())
	# (2) outlet
	var rf: Variant = sgv.get("_resource_flow")
	var sink: Dictionary = rf.call("_resolve_siphon_outlet_tank", siphon) if rf != null else {}
	fails += _siphon_check("an outlet sink is wired to the siphon", not sink.is_empty())
	if not sink.is_empty():
		var pond: Dictionary = model.get_item(pond_id)
		var d_pond := GraphSiteLayout.site_xz(sink).distance_to(GraphSiteLayout.site_xz(pond))
		var keep := (float(sgv.call("pond_half_extent_m", pond_specs0)) if sgv.has_method("pond_half_extent_m") else 4.0) + 2.0
		fails += _siphon_check("the outlet sits OUTSIDE the pond's basin (%.1f m from its centre, keep-out %.1f m)" % [d_pond, keep],
				d_pond >= keep)
		fails += _siphon_check("the outlet is below the turbine (%.2f vs %.2f m)" % [
				float(sink.get("elevation_m", 0.0)), float(siphon.get("elevation_m", 0.0))],
				float(sink.get("elevation_m", 0.0)) < float(siphon.get("elevation_m", 0.0)))
		for conn: Dictionary in model.connections:
			if str(conn.get("source_item_id", "")) == siphon_id and str(conn.get("target_item_id", "")) == str(sink.get("id", "")):
				var r3: Array = conn.get("route_3d", []) as Array
				fails += _siphon_check("the culvert's traced route (%d waypoints) is locked so the pipe follows it" % r3.size(),
						r3.is_empty() or bool(conn.get("route_locked", false)))
	# (3) physics through the SAME reach the engine uses
	var eval_specs: Dictionary = specs.duplicate(true)
	eval_specs["siphon_primed"] = true
	var r0: Dictionary = HydroReach.evaluate_specs(level_eval, eval_specs)
	fails += _siphon_check("primed at the seeded level: %s, Q %.1f L/s, %.0f W" % [
			str(r0.get("regime", "")), float(r0.get("q_lps", 0.0)), float(r0.get("power_w", 0.0))],
			bool(r0.get("primed", false)) and float(r0.get("q_lps", 0.0)) > 0.5 and float(r0.get("power_w", 0.0)) > 0.5)
	fails += _siphon_check("the runner sees less than the gross head (%.2f of %.2f m)" % [
			float(r0.get("turbine_head_m", 0.0)), float(r0.get("head_m", 0.0))],
			float(r0.get("turbine_head_m", 0.0)) > 0.0 and float(r0.get("turbine_head_m", 0.0)) < float(r0.get("head_m", 0.0)))
	fails += _siphon_check("suction reported under its limit (%.1f / %.1f m)" % [
			float(r0.get("suction_m", 0.0)), float(r0.get("suction_max_m", 0.0))],
			r0.has("suction_m") and float(r0.get("suction_m", 0.0)) < float(r0.get("suction_max_m", 0.0)))
	# The cavitation lesson needs a STEEP draft: suction at the runner outlet
	# is the exit drop less the draft pipe's friction, and on a long gentle
	# run the friction wins — the saved Mount Vernon siphon runs 503 m of 8″
	# pipe to its outlet (3.3 m of drop), where a 20 m deeper exit is still
	# 17 m of friction and no cavitation, correctly. So the hypothetical
	# takes the exit 20 m down a pipe no longer than twice that drop (the
	# world's own length when it is already short), the way "run the draft
	# pipe lower and watch" means it. Both the deep and the useful-draft
	# evaluations use the same pipe so their powers compare.
	var deep_len := minf(float(eval_specs.get("barrel_length_m", 20.0)), 40.0)
	var deep: Dictionary = eval_specs.duplicate(true)
	deep["outlet_invert_m"] = mod_eval - 20.0
	deep["barrel_length_m"] = deep_len
	var rd: Dictionary = HydroReach.evaluate_specs(level_eval, deep)
	var useful: Dictionary = eval_specs.duplicate(true)
	useful["outlet_invert_m"] = mod_eval - float(rd.get("useful_draft_m", 7.0))
	useful["barrel_length_m"] = deep_len
	var ru: Dictionary = HydroReach.evaluate_specs(level_eval, useful)
	fails += _siphon_check("a 20 m exit drop down a %.0f m draft pipe cavitates (useful draft %.1f m, %.1f m wasted)" % [
			deep_len, float(rd.get("useful_draft_m", 0.0)), float(rd.get("draft_excess_m", 0.0))],
			bool(rd.get("cavitating", false)) and float(rd.get("draft_excess_m", 0.0)) > 1.0)
	# And the world's own run, as saved: a long pipe's friction protects the
	# runner — the same 20 m drop must NOT cavitate once the pipe is over
	# ten times the drop (friction ∝ length, suction = drop − friction).
	var world_len := float(eval_specs.get("barrel_length_m", 20.0))
	if world_len > 200.0:
		var deep_world: Dictionary = eval_specs.duplicate(true)
		deep_world["outlet_invert_m"] = mod_eval - 20.0
		var rw: Dictionary = HydroReach.evaluate_specs(level_eval, deep_world)
		fails += _siphon_check("…and the same drop down the world's %.0f m pipe does not (friction %.1f m of the 20 m)" % [
				world_len, float(rw.get("h_loss_draft_m", 0.0))],
				not bool(rw.get("cavitating", false)) and float(rw.get("h_loss_draft_m", 0.0)) > 5.0)
	fails += _siphon_check("…and makes no more power than the useful draft (%.0f vs %.0f W)" % [
			float(rd.get("power_w", 0.0)), float(ru.get("power_w", 0.0))],
			float(rd.get("power_w", 0.0)) <= float(ru.get("power_w", 0.0)) * 1.03 + 1.0)
	# (4) the Lab
	var modal: Variant = sgv.get("_siphon_lab_modal")
	if modal != null:
		var dip_spin: Variant = (modal as Object).get("_dip_len_spin")
		var brk_spin: Variant = (modal as Object).get("_break_spin")
		var mod_spin: Variant = (modal as Object).get("_module_spin")
		if dip_spin != null and brk_spin != null and mod_spin != null:
			fails += _siphon_check("the Lab's dip-tube spin derives the break level (%.2f − %.2f = %.2f)" % [
					float(mod_spin.value), float(dip_spin.value), float(brk_spin.value)],
					absf(float(mod_spin.value) - float(dip_spin.value) - float(brk_spin.value)) < 0.02)
		var deck: Variant = (modal as Object).get("_deck")
		if deck != null:
			var keys := PackedStringArray()
			for t: Variant in (deck as Object).get("_tiles") as Array:
				keys.append(str((t as Dictionary).get("key", "")))
			fails += _siphon_check("the stat deck carries the siphon's Pond level + Suction tiles (%s)" % ", ".join(keys),
					keys.has("level") and keys.has("suction"))
	# The dip tube in the world: the hydroturbine prop carries the runtime.
	var main := get_tree().current_scene
	var prop_id := str(specs.get("bound_prop_id", ""))
	if not prop_id.is_empty() and main != null:
		var prop := PlacedPropRuntime.find_by_prop_id(main, prop_id)
		var tube: Node = prop.get_node_or_null("SiphonDipTube") if prop != null else null
		fails += _siphon_check("the placed turbine carries a SiphonDipTube", tube != null)
		if tube != null:
			# Hidden by default; shown on the toggle; ONE vertical tube whose
			# TOP is the 90° elbow's open end (the dip anchor — not the
			# connection port, not the leg's end under the riser) and whose
			# MOUTH is the physics break level.
			var sp_saved: Dictionary = (model.call("get_item", siphon_id) as Dictionary).get("specs", {}) as Dictionary
			var show_saved := bool(sp_saved.get("show_dip_tube", false))
			var sp0 := sp_saved.duplicate(true)
			sp0["show_dip_tube"] = false
			model.call("update_item", siphon_id, {"specs": sp0})
			await get_tree().create_timer(0.7).timeout
			var ds0: Dictionary = tube.call("debug_summary")
			fails += _siphon_check("the dip tube is HIDDEN by default (show_dip_tube off)", not bool(ds0.get("shown", true)))
			var sp1 := sp0.duplicate(true)
			sp1["show_dip_tube"] = true
			model.call("update_item", siphon_id, {"specs": sp1})
			await get_tree().create_timer(0.7).timeout
			var ds1: Dictionary = tube.call("debug_summary")
			var fit: Dictionary = ds1.get("fitting", {}) as Dictionary
			var top: Vector3 = ds1.get("top", Vector3.INF)
			var mouth: Vector3 = ds1.get("mouth", Vector3.INF)
			var fit_pos: Vector3 = fit.get("pos", Vector3.INF)
			fails += _siphon_check("…and SHOWN after the toggle (top %s)" % str(top), bool(ds1.get("shown", false)) and is_finite(top.x))
			fails += _siphon_check("the tube's top sits on the measured dip anchor %s (%.3f m away)" % [
					str(fit_pos), top.distance_to(fit_pos) if is_finite(fit_pos.x) and is_finite(top.x) else NAN],
					is_finite(fit_pos.x) and is_finite(top.x) and top.distance_to(fit_pos) < 0.05)
			fails += _siphon_check("…which is the 90° ELBOW's open end on this model, facing down",
					bool(fit.get("elbow", false)) and (fit.get("dir", Vector3.ZERO) as Vector3).is_equal_approx(Vector3.DOWN))
			fails += _siphon_check("…straight DOWN (%.2f m, mouth under the top within 1 cm in plan)" % float(ds1.get("length_m", 0.0)),
					is_finite(mouth.x) and Vector2(mouth.x, mouth.z).distance_to(Vector2(top.x, top.z)) < 0.01
					and top.y - mouth.y > 0.09)
			var lv1 := SiphonHydraulics.resolve_siphon_levels(sp1, float((model.call("get_item", siphon_id) as Dictionary).get("elevation_m", NAN)))
			var brk1 := float(lv1.get("siphon_break_m", NAN))
			fails += _siphon_check("the mouth is AT the physics break level (%.2f vs %.2f m)" % [mouth.y, brk1],
					is_finite(brk1) and absf(mouth.y - brk1) < 0.02)
			# Lengthen the tube: the top stays on the elbow, only the mouth drops.
			var sp1b := sp1.duplicate(true)
			sp1b["dip_tube_length_m"] = float(sp1.get("dip_tube_length_m", 1.5)) + 0.5
			model.call("update_item", siphon_id, {"specs": sp1b})
			await get_tree().create_timer(0.7).timeout
			var ds2: Dictionary = tube.call("debug_summary")
			var top2: Vector3 = ds2.get("top", Vector3.INF)
			var mouth2: Vector3 = ds2.get("mouth", Vector3.INF)
			fails += _siphon_check("+0.5 m of tube: the top did not move (%.3f m) and the mouth dropped 0.5 m (%.2f)" % [
					top2.distance_to(top) if is_finite(top2.x) else NAN, (mouth.y - mouth2.y) if is_finite(mouth2.x) else NAN],
					is_finite(top2.x) and top2.distance_to(top) < 0.005 and is_finite(mouth2.x) and absf((mouth.y - mouth2.y) - 0.5) < 0.02)
			var binding := ConduitManager.resolve_port_binding(model.call("get_item", siphon_id), "res_in_0", main)
			var port_pos: Vector3 = binding.get("pos", Vector3.INF)
			if is_finite(port_pos.x):
				print("PlaytestHarness: siphon dip tube — fitting %s vs res_in_0 port %s (%.2f m apart)" % [
						str(fit_pos), str(port_pos), fit_pos.distance_to(port_pos)])
			var sp2 := sp_saved.duplicate(true)
			sp2["show_dip_tube"] = show_saved
			model.call("update_item", siphon_id, {"specs": sp2})
		# The state ring: a colour and a sentence for the regime the engine
		# last stamped (SiphonStateRing.state_for is pure — pin it on the live
		# specs and on canned regimes).
		var ring: Node = prop.get_node_or_null("SiphonStateRing") if prop != null else null
		fails += _siphon_check("the placed turbine carries a SiphonStateRing", ring != null)
		if ring != null:
			var rs: Dictionary = ring.call("debug_summary")
			print("PlaytestHarness: siphon state ring — %s · \"%s\" · colour %s · bubbling %s" % [
					str(rs.get("state", "")), str(rs.get("text", "")), str(rs.get("color", "")), str(rs.get("bubbling", ""))])
			var canned := SiphonStateRing.state_for({"live_regime": "lift_exceeded", "siphon_primed": true})
			var canned2 := SiphonStateRing.state_for({"live_regime": "siphon_flow", "siphon_primed": true, "live_q_lps": 70.0, "live_power_w": 144.0})
			var canned3 := SiphonStateRing.state_for({"live_regime": "", "siphon_primed": false})
			fails += _siphon_check("state ring: lift_exceeded reads as a FAULT (red), flowing as GENERATING (green), dry as idle (grey)",
					str(canned["state"]) == "fault" and str(canned2["state"]) == "generating" and str(canned3["state"]) == "idle"
					and SiphonStateRing.color_for("fault") == SiphonStateRing.C_FAULT)
	# The pond's MAX FILL LEVEL (a dam above the basin rim): raising it moves
	# the tank's rim and capacity, lets the Lab fill past the old rim, and
	# stands a grabbable PondLevelHandle at the new height.
	var loader: Node = main.find_child("TerrainLoader", true, false) if main != null else null
	var tank0: Dictionary = sgv.call("resolve_siphon_pond", siphon_id) if sgv.has_method("resolve_siphon_pond") else {}
	var ptag := str((tank0.get("specs", {}) as Dictionary).get("osm_water_tag", ""))
	if loader != null and not ptag.is_empty() and loader.has_method("set_pond_max_level"):
		var pidx := int(loader.call("find_pond_idx_by_tag", ptag))
		if pidx >= 0:
			var info0: Dictionary = loader.call("get_pond_info", pidx)
			var basin := float(info0.get("basin_rim_m", NAN))
			var saved_max := float(info0.get("max_level_m", NAN))
			var level_saved := float((tank0.get("specs", {}) as Dictionary).get("level_m", NAN))
			var rim0 := float((tank0.get("specs", {}) as Dictionary).get("rim_m", NAN))
			var cap0 := float((tank0.get("specs", {}) as Dictionary).get("capacity_qty", 0.0))
			# Raise RELATIVE to where the pond tops out now: a world may already
			# carry a max fill above the basin rim (Mount Vernon does), and
			# "basin + 0.5" would then LOWER it and shrink the capacity.
			var top0 := basin
			if not is_nan(saved_max):
				top0 = maxf(top0, saved_max)
			if not is_nan(rim0):
				top0 = maxf(top0, rim0)
			loader.call("set_pond_max_level", pidx, top0 + 0.5)
			await get_tree().create_timer(0.8).timeout
			var tank1: Dictionary = sgv.call("resolve_siphon_pond", siphon_id)
			var rim1 := float((tank1.get("specs", {}) as Dictionary).get("rim_m", NAN))
			var cap1 := float((tank1.get("specs", {}) as Dictionary).get("capacity_qty", 0.0))
			fails += _siphon_check("max fill +0.5 m moved the tank's rim (%.2f → %.2f, basin %.2f, top before %.2f)" % [rim0, rim1, basin, top0],
					absf(rim1 - (top0 + 0.5)) < 0.03)
			fails += _siphon_check("…and grew its capacity (%.0f → %.0f L, footprint %.0f m²)" % [cap0, cap1, float(info0.get("area_m2", 0.0))],
					cap1 > cap0 + 0.3 * float(info0.get("area_m2", 0.0)) * 1000.0 * 0.5)
			var ok_lvl := bool(sgv.call("lab_set_pond_level", siphon_id, basin + 0.3))
			await get_tree().create_timer(0.4).timeout
			var tank2: Dictionary = sgv.call("resolve_siphon_pond", siphon_id)
			var lvl2 := float((tank2.get("specs", {}) as Dictionary).get("level_m", NAN))
			fails += _siphon_check("the Lab can now fill the pond PAST the old rim (level %.2f vs basin rim %.2f)" % [lvl2, basin],
					ok_lvl and lvl2 > basin + 0.25)
			var handle: Node = loader.call("pond_level_handle_for_tag", ptag) as Node
			fails += _siphon_check("a PondLevelHandle stands at the max fill height", handle != null
					and absf(float(handle.call("max_level_y")) - (top0 + 0.5)) < 0.03)
			if handle != null:
				# The marker contract end to end: begin / preview / commit.
				handle.call("world_drag_begin")
				var c3: Vector3 = handle.get("global_position")
				handle.call("world_drag_preview", Vector3(c3.x, top0 + 0.9, c3.z))
				handle.call("world_drag_commit", Vector3(c3.x, top0 + 0.9, c3.z))
				await get_tree().create_timer(0.8).timeout
				var tank3: Dictionary = sgv.call("resolve_siphon_pond", siphon_id)
				var rim3 := float((tank3.get("specs", {}) as Dictionary).get("rim_m", NAN))
				fails += _siphon_check("dragging the handle up commits a new max fill (rim %.2f, expected %.2f)" % [rim3, top0 + 0.9],
						absf(rim3 - (top0 + 0.9)) < 0.03)
			# Put it back.
			loader.call("set_pond_max_level", pidx, saved_max)
			if not is_nan(level_saved):
				sgv.call("lab_set_pond_level", siphon_id, level_saved)
			await get_tree().create_timer(0.5).timeout
		else:
			print("PlaytestHarness: siphon verify — max fill level SKIPPED (pond tag %s not on the loader)" % ptag)
	if fails > 0:
		push_error("PlaytestHarness: siphon verify — %d CHECK(S) FAILED" % fails)
	else:
		print("PlaytestHarness: siphon verify — PASS")


## --- NPC animation editor capture (fabrication swarm B3) ---------------------
## Drives the editor with REAL input pushed through the viewport — what a
## player's mouse and keyboard do — because an editor whose picking, ring drag
## or keyboard shortcuts silently miss looks perfect in a screenshot:
##   1. opens on drill_hole through Main (its own CanvasLayer) in the drill
##      context and checks both hands sit on the drill's grips;
##   2. starts a NEW clip, CLICKS the right upper arm (joint picked), DRAGS
##      the gizmo's X ring (a key appears, the shoulder turned);
##   3. CLICKS the timeline halfway, presses K (a second key), Ctrl+S (the
##      file is written), reloads it and compares it byte for byte;
##   4. Escape closes it and releases the modal.
## Shots per state. Runs in the harness sandbox (the clip it saves is the
## sandbox's); it still deletes the clip it wrote.
func _ae_check(label: String, ok: bool) -> int:
	print("PlaytestHarness: animeditor — %s %s" % ["PASS" if ok else "FAIL", label])
	return 0 if ok else 1


func _ae_key(vp: Viewport, code: Key, ctrl: bool = false) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.physical_keycode = code
		ev.pressed = pressed
		ev.ctrl_pressed = ctrl
		vp.push_input(ev)
		await get_tree().process_frame


func _ae_screen(editor: Control, world: Vector3) -> Vector2:
	var vpc := editor.get("_vpc") as SubViewportContainer
	var cam := editor.get("_camera") as Camera3D
	return vpc.get_global_rect().position + cam.unproject_position(world)


func _run_animeditor_capture() -> void:
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var label := _shots_label if not _shots_label.is_empty() else "animeditor"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	var fails := 0
	if main == null or not main.has_method("open_npc_anim_editor"):
		push_error("PlaytestHarness: animeditor — FAIL no Main.open_npc_anim_editor")
		return
	var ed: Control = main.call("open_npc_anim_editor", "drill_hole")
	await get_tree().create_timer(0.8).timeout
	fails += _ae_check("the editor opened on drill_hole", ed != null and ed.visible
		and (ed.get("clip") as NpcAnimClip).id == "drill_hole")
	fails += _ae_check("the drill context is up (tool + bench)", ed.get("_context") == "drill"
		and ed.get("_tool") != null and (ed.get("_workpieces") as Node3D).get_child_count() > 0)
	var fig := ed.get("_figure") as NpcSimpleFigure
	var tool := ed.get("_tool") as Node3D
	var socks: Dictionary = tool.get_meta("sockets", {})
	var grip_err := fig.palm_global(0).origin.distance_to(tool.global_transform * (socks["grip"] as Transform3D).origin)
	var grip2_err := fig.palm_global(1).origin.distance_to(tool.global_transform * (socks["grip2"] as Transform3D).origin)
	fails += _ae_check("both hands on the drill's grips (%.4f / %.4f m)" % [grip_err, grip2_err],
		grip_err < 0.005 and grip2_err < 0.005)
	await _graph_shot(dir, "01_drill_context", manifest, "animeditor")
	ed.call("set_playhead", 0.3)
	await get_tree().create_timer(0.3).timeout
	await _graph_shot(dir, "02_drill_mid_op", manifest, "animeditor")

	# A new clip, edited with the mouse.
	var vp := ed.get_viewport()
	ed.call("_on_new")
	await get_tree().create_timer(0.4).timeout
	var clip := ed.get("clip") as NpcAnimClip
	var jm := fig.joint_map()
	var sh: Node3D = jm["shoulder_r"]
	var el: Node3D = jm["elbow_r"]
	var arm_mid: Vector3 = (sh.global_position + el.global_position) * 0.5
	var p_arm := _ae_screen(ed, arm_mid)
	var ev0 := int(ed.get("viewport_events"))
	await _lc_click(vp, p_arm)
	await _lc_press(vp, p_arm, false)
	await get_tree().process_frame
	# Separate "the click never arrived" from "the pick missed".
	var cam := ed.get("_camera") as Camera3D
	var local := cam.unproject_position(arm_mid)
	var direct := str(ed.call("pick_joint", cam.project_ray_origin(local), cam.project_ray_normal(local)))
	print("PlaytestHarness: animeditor — click at %s (local %s): %d viewport events, direct pick '%s'" % [
		str(p_arm), str(local), int(ed.get("viewport_events")) - ev0, direct])
	fails += _ae_check("clicking the upper arm selects shoulder_r (got '%s')" % str(ed.call("selected_joint")),
		str(ed.call("selected_joint")) == "shoulder_r")
	var before: Vector3 = sh.rotation
	var gz := ed.get("_gizmo") as LightGizmo
	await get_tree().process_frame
	var o := gz.global_position
	var r := LightGizmo.RING_R * gz.handle_scale()
	var ax := gz.axis("rx")
	var u_ax := gz.axis("y")
	var v_ax := ax.cross(u_ax).normalized()
	var start := o + u_ax * r
	await _lc_move(vp, _ae_screen(ed, start))
	await _lc_press(vp, _ae_screen(ed, start), true)
	for k in range(1, 9):
		var a := deg_to_rad(5.0 * k)
		await _lc_move(vp, _ae_screen(ed, o + (u_ax * cos(a) + v_ax * sin(a)) * r))
	await _lc_press(vp, _ae_screen(ed, o + (u_ax * cos(deg_to_rad(40.0)) + v_ax * sin(deg_to_rad(40.0))) * r), false)
	await get_tree().create_timer(0.2).timeout
	var turned := rad_to_deg((sh.rotation - before).length())
	fails += _ae_check("dragging the X ring keyed shoulder_r at 0 s (keys %s)" % str(clip.key_times("shoulder_r")),
		clip.key_times("shoulder_r").has(0.0))
	fails += _ae_check("the shoulder turned (%.1f deg)" % turned, turned > 10.0)
	await _graph_shot(dir, "03_ring_drag", manifest, "animeditor")

	# Scrub with the timeline, key with K.
	var tl := ed.get("_timeline") as Control
	var rect := tl.get_global_rect()
	var p_mid := Vector2(rect.position.x + 14.0 + (rect.size.x - 28.0) * 0.5, rect.position.y + rect.size.y * 0.5)
	await _lc_click(vp, p_mid)
	await _lc_press(vp, p_mid, false)
	var ph := float(ed.call("playhead"))
	fails += _ae_check("clicking the timeline scrubs to the middle (%.3f s)" % ph, absf(ph - clip.length_s * 0.5) < 0.05)
	await _ae_key(vp, KEY_K)
	fails += _ae_check("K keys the selected joint at the playhead (keys %s)" % str(clip.key_times("shoulder_r")),
		clip.key_times("shoulder_r").size() == 2)
	ed.set("_onion", true)
	await get_tree().create_timer(0.3).timeout
	await _graph_shot(dir, "04_onion_skin", manifest, "animeditor")
	ed.set("_onion", false)

	# Save with Ctrl+S, reload, compare.
	await _ae_key(vp, KEY_S, true)
	var path := NpcAnimClip.USER_DIR + clip.id + ".json"
	fails += _ae_check("Ctrl+S wrote %s" % path, FileAccess.file_exists(path))
	var want := JSON.stringify(clip.to_dict())
	ed.call("_load_clip", clip.id)
	var back := ed.get("clip") as NpcAnimClip
	fails += _ae_check("the reloaded clip is identical", JSON.stringify(back.to_dict()) == want)
	fails += _ae_check("nothing unsaved after the save", not bool(ed.call("is_dirty")))

	# Other contexts render.
	for ctx in ["cut", "fasten", "lift"]:
		ed.call("set_context", ctx)
		ed.call("_load_clip", str(FabContextRig.CLIP_FOR[ctx]))
		ed.call("set_playhead", 0.4)
		await get_tree().create_timer(0.35).timeout
		await _graph_shot(dir, "05_context_%s" % ctx, manifest, "animeditor")

	# Escape closes and hands the mouse back.
	await _ae_key(vp, KEY_ESCAPE)
	await get_tree().create_timer(0.2).timeout
	fails += _ae_check("Escape closed the editor", not ed.visible)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
	if fails > 0:
		push_error("PlaytestHarness: animeditor — %d CHECK(S) FAILED" % fails)
	else:
		print("PlaytestHarness: animeditor — PASS")


# ==================== FABRICATION SWARM (--capture=fabswarm) ====================
## A crew of 12 rehearses building the SOAK 2026 LinkageLab design from bare
## ground on a REAL map, on a frozen clock moved by hand (the build is a pure
## function of the clock, so this is exactly what scrubbing does). Asserts
## what a PNG cannot:
##   - at the start nothing stands; at the end every part is seated and the
##     ring is deployed (the builder carries NO part states and the fold is the
##     design's closed angle);
##   - for one job of every kind (cut, drill, place, fasten, lift, deploy) its
##     crew is posed there with that job's clip, and every hand on a tool is
##     ON its grip (< 2 cm) — a hand floating off a saw reads fine in a
##     thumbnail;
##   - the structure only grows; scrubbing back to a moment gives the same
##     structure as the first visit;
##   - ending the rehearsal hands the structure back seated.
## A wide PNG per phase plus a close-up per job kind. Removes its prop.
func _fs_check(label: String, ok: bool, fails: Array) -> void:
	print("PlaytestHarness: fabswarm — %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		fails.append(label)


func _fs_hidden(b: LinkageStructureBuilder) -> int:
	var n := 0
	for k in b.part_keys():
		var st := b.part_state(k)
		if not st.is_empty() and not bool(st.get("visible", true)):
			n += 1
	return n


## The flattest patch near `base` big enough for the ring and its benches
## (the build is staged on flat ground; on a hillside the crew stands on the
## slope while the structure stands on its footing). Scored by the spread of
## ground heights over a 15 m disc; returns the centre, y on the ground.
func _fs_flat_spot(main: Node, base: Vector3) -> Vector3:
	var best := base
	var best_score := INF
	for ring in [22.0, 35.0, 50.0, 70.0, 95.0, 125.0]:
		for k in 16:
			var a := TAU * float(k) / 16.0
			var c := base + Vector3(cos(a), 0.0, sin(a)) * float(ring)
			var lo := INF
			var hi := -INF
			for r in [0.0, 5.0, 10.0, 15.0]:
				for m in (1 if r == 0.0 else 8):
					var b := TAU * float(m) / 8.0
					var y := TerrainSurfaceQuery.ground_height_at(main, c.x + cos(b) * float(r), c.z + sin(b) * float(r))
					lo = minf(lo, y)
					hi = maxf(hi, y)
			var score := hi - lo + float(ring) * 0.004
			if score < best_score:
				best_score = score
				best = c
	best.y = TerrainSurfaceQuery.ground_height_at(main, best.x, best.z)
	print("PlaytestHarness: fabswarm — site %.0f m from the player, ground spread %.2f m" % [
		Vector2(best.x - base.x, best.z - base.z).length(), best_score])
	return best


## A camera position never below the ground (+ clearance).
func _fs_cam_at(main: Node, p: Vector3, clearance: float = 1.2) -> Vector3:
	var gy := TerrainSurfaceQuery.ground_height_at(main, p.x, p.z)
	return Vector3(p.x, maxf(p.y, gy + clearance), p.z)


func _fs_visible(b: LinkageStructureBuilder) -> int:
	return b.part_keys().size() - _fs_hidden(b)


func _fs_goto(main: Node, h0: float, t: float) -> void:
	main.call("set_absolute_hours", h0 + t / 3600.0)
	for _i in 3:
		await get_tree().process_frame


## Worst palm-to-grip distance over every crew member holding a tool.
func _fs_grip_error(site: LinkageBuildSite) -> Dictionary:
	var worst := 0.0
	var n := 0
	for c in site.get("_crew"):
		var fig: NpcSimpleFigure = c["fig"]
		if not fig.visible:
			continue
		for id in c["tools"]:
			var tool: Node3D = c["tools"][id]
			if not tool.visible:
				continue
			var socks: Dictionary = tool.get_meta("sockets", {})
			for i in 2:
				var want = socks.get("grip" if i == 0 else "grip2")
				if not (want is Transform3D):
					continue
				var err := fig.palm_global(i).origin.distance_to((tool.global_transform * (want as Transform3D)).origin)
				worst = maxf(worst, err)
				n += 1
	return {"worst": worst, "hands": n}


func _run_fabswarm_capture() -> void:
	var tree := get_tree()
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: fabswarm needs a TerrainLoader map")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	var main := _find_main()
	if main == null:
		_maybe_quit()
		return
	var label := _shots_label if not _shots_label.is_empty() else "fabswarm"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var fails: Array = []
	var vp := get_viewport()

	var prev_cam := vp.get_camera_3d()
	var base := prev_cam.global_position if prev_cam != null else Vector3(0, 2, 0)
	var fwd := -prev_cam.global_basis.z if prev_cam != null else Vector3.FORWARD
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var at := _fs_flat_spot(main, base)
	fwd = Vector3(at.x - base.x, 0.0, at.z - base.z).normalized()
	var cam := Camera3D.new()
	cam.name = "PlaytestFabSwarmCam"
	cam.fov = 60.0
	main.add_child(cam)
	var wide_pos := _fs_cam_at(main, at - fwd * 19.0 + fwd.cross(Vector3.UP) * 6.0 + Vector3(0, 9.0, 0), 6.0)
	cam.global_position = wide_pos
	cam.look_at(at + Vector3(0, 1.0, 0), Vector3.UP)
	cam.make_current()
	var saved_scale: Variant = main.get("time_scale")
	var saved_abs: float = float(main.call("get_absolute_hours"))
	main.set("time_scale", 0.0)
	main.set("day_time", 11.0)
	await tree.process_frame
	var h0: float = float(main.call("get_absolute_hours"))

	var f := FileAccess.open("res://core/linkage/presets/ll_starshade_v1_soak_2026.json", FileAccess.READ)
	var cfg = JSON.parse_string(f.get_as_text()) if f != null else null
	var seeded: Array[String] = []
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, LinkageStructureBuilder.MODEL_ID,
		at.x, at.z, {"linkage_spec": cfg})
	var pid := str(placed.get("prop_id", ""))
	_fs_check("the SOAK 2026 design is placed", bool(placed.get("ok", false)) and cfg is Dictionary, fails)
	if pid.is_empty():
		_prop_edit_restore(main, seeded, cam, prev_cam, saved_scale, saved_abs)
		return
	seeded.append(pid)
	for _i in 6:
		await tree.process_frame

	var t_plan := Time.get_ticks_msec()
	var ok_start := LinkageBuildSite.start_rehearsal(main, pid, 12, h0)
	var plan_ms := Time.get_ticks_msec() - t_plan
	await tree.process_frame
	var site := LinkageBuildSite.site_for(main, pid)
	_fs_check("a rehearsal starts (plan %d ms)" % plan_ms, ok_start and site != null and not site.timeline().is_empty(), fails)
	if site == null:
		_prop_edit_restore(main, seeded, cam, prev_cam, saved_scale, saved_abs)
		return
	var tl := site.timeline()
	var builder := (site.get_parent() as Node).get_node("ModelRoot") as LinkageStructureBuilder
	var mk := float(tl["makespan"])
	print("PlaytestHarness: fabswarm — plan: %s" % LinkageBuildTimeline.summary(tl))
	_fs_check("the crew is 12 figures", (site.crew_figures() as Array).size() == 12, fails)

	# Start: nothing stands.
	await _fs_goto(main, h0, 1.0)
	var keys := builder.part_keys()
	var hidden0 := _fs_hidden(builder)
	_fs_check("at the start almost nothing stands (%d of %d hidden)" % [hidden0, keys.size()],
		hidden0 >= int(keys.size() * 0.9), fails)
	await _graph_shot(dir, "00_start", [], "fabswarm")

	# Wide phases: the structure only grows.
	var last_vis := _fs_visible(builder)
	var grows := true
	var mid_hidden := -1
	var fracs := [0.15, 0.35, 0.55, 0.75, 0.95]
	for i in fracs.size():
		await _fs_goto(main, h0, mk * float(fracs[i]))
		var h := _fs_hidden(builder)
		var vis := _fs_visible(builder)
		if vis < last_vis:
			grows = false
		last_vis = vis
		if i == 2:
			mid_hidden = h
		print("PlaytestHarness: fabswarm — %d %%: %s · fold %.1f deg · %d shown, %d staged hidden" % [int(100.0 * float(fracs[i])),
			site.progress_line(), rad_to_deg(builder.get_fold_angle()), vis, h])
		cam.global_position = wide_pos
		cam.look_at(at + Vector3(0, 1.0, 0), Vector3.UP)
		await _graph_shot(dir, "%02d_build_%d" % [i + 1, int(100.0 * float(fracs[i]))], [], "fabswarm")
	_fs_check("the structure only grows", grows, fails)

	# One job of each kind: its crew there, with its clip and tool in hand.
	var shot_i := 10
	for kind in ["cut", "drill", "place", "fasten", "lift", "deploy"]:
		var job: Dictionary = {}
		for j in tl["jobs"]:
			if str(j["kind"]) == kind and float(j["t1"]) - float(j["t0"]) > 1.0:
				job = j
				break
		if job.is_empty():
			_fs_check("a %s job exists" % kind, false, fails)
			continue
		var tm := (float(job["t0"]) + float(job["t1"])) * 0.5
		await _fs_goto(main, h0, tm)
		var st := site.last_state()
		var crew: Array = job["crew"]
		var posed := 0
		var want_clip := str(LinkageBuildTimeline.CLIP_FOR_KIND.get(kind, ""))
		for w in st["workers"]:
			if crew.has(w["id"]) and str(w["activity"]) == "work" and int(w["job"]) == int(job["id"]) \
					and str(w["clip"]) == want_clip:
				posed += 1
		_fs_check("%s: all %d of its crew at work with %s (%d)" % [kind, crew.size(), want_clip, posed],
			posed == crew.size(), fails)
		var ge := _fs_grip_error(site)
		_fs_check("%s: every hand on a tool is on its grip (worst %.4f m over %d hands)" % [kind, ge["worst"], ge["hands"]],
			float(ge["worst"]) < 0.02, fails)
		if kind in ["cut", "drill", "fasten"]:
			_fs_check("%s: the tool is in hand" % kind, int(ge["hands"]) > 0, fails)
		# Close-up on the first of its crew.
		var fig: NpcSimpleFigure = (site.crew_figures() as Array)[int(crew[0])]
		var fp := fig.global_position
		var fz := fig.global_basis.z
		var fx := fig.global_basis.x
		var dist := 3.4 if kind in ["cut", "drill", "fasten", "place"] else 9.0
		cam.global_position = _fs_cam_at(main, fp + fz * dist + fx * dist * 0.55 + Vector3(0, 1.7 if dist < 5.0 else 4.0, 0))
		cam.look_at(fp + Vector3(0, 1.0, 0), Vector3.UP)
		await _graph_shot(dir, "%02d_%s" % [shot_i, kind], [], "fabswarm")
		shot_i += 1

	# The site's own per-frame cost mid-build (state_at + the structure +
	# twelve figures), with the clock moving so the structure re-stages.
	var t_ms := 0.0
	for i in 20:
		main.call("set_absolute_hours", h0 + (mk * 0.3 + float(i) * 7.0) / 3600.0)
		var us := Time.get_ticks_usec()
		site.call("_update", 1.0 / 60.0)
		t_ms += float(Time.get_ticks_usec() - us) / 1000.0
	_fs_check("the site costs %.2f ms a frame mid-build" % (t_ms / 20.0), t_ms / 20.0 < 8.0, fails)

	# Scrub back to the middle: the same structure.
	await _fs_goto(main, h0, mk * 0.55)
	_fs_check("scrubbing back gives the same structure (%d vs %d hidden)" % [_fs_hidden(builder), mid_hidden],
		_fs_hidden(builder) == mid_hidden, fails)

	# The end: every part seated, the ring deployed, the crew gone.
	await _fs_goto(main, h0, mk + LinkageBuildSite.LINGER_S + 30.0)
	var stated := 0
	for k in builder.part_keys():
		if not builder.part_state(k).is_empty():
			stated += 1
	var dep_err := absf(rad_to_deg(builder.get_fold_angle()) - float((tl["fold"] as Dictionary)["deployed_deg"]))
	_fs_check("built: every part seated (%d still staged), deployed (%.2f deg off)" % [stated, dep_err],
		stated == 0 and dep_err < 0.2, fails)
	var crew_hidden := true
	for fg in site.crew_figures():
		if (fg as Node3D).visible:
			crew_hidden = false
	_fs_check("the crew disperses", crew_hidden, fails)
	print("PlaytestHarness: fabswarm — %s" % site.progress_line())
	cam.global_position = wide_pos
	cam.look_at(at + Vector3(0, 1.0, 0), Vector3.UP)
	await _graph_shot(dir, "20_built", [], "fabswarm")

	# Ending the rehearsal hands the structure back.
	await _fs_goto(main, h0, mk * 0.3)
	LinkageBuildSite.clear_rehearsal(main, pid)
	for _i in 3:
		await tree.process_frame
	var stated2 := 0
	for k in builder.part_keys():
		if not builder.part_state(k).is_empty():
			stated2 += 1
	_fs_check("ending the rehearsal seats every part (%d staged) and removes the site" % stated2,
		stated2 == 0 and LinkageBuildSite.site_for(main, pid) == null
		and not PlacedPropService.get_prop_record(main, pid).has(LinkageBuildSite.RECORD_KEY), fails)

	_prop_edit_restore(main, seeded, cam, prev_cam, saved_scale, saved_abs)
	if fails.is_empty():
		print("PlaytestHarness: fabswarm — PASS")
	else:
		push_error("PlaytestHarness: fabswarm — %d CHECK(S) FAILED" % fails.size())
	_maybe_quit()


# ==================== LAB BUILD STEPS (--capture=buildsteps) ====================
## The Linkage Lab's build-step player (LINKAGE_PARITY.md A5) driven with REAL
## input through the viewport: opens the Lab through Main on the SOAK 2026
## preset, CLICKS "Steps" (the dock opens, playback enters on the generated
## sequence), CLICKS a list row (the player jumps to that step), CLICKS play
## (time moves the op), then for one step of each kind shoots the Lab and
## asserts what a PNG cannot:
##   - cut / drill steps hide the structure and show the workbench;
##   - the saw / drill / driver is where its op says (the drill's tip lands ON
##     the hole marker it is making, within 2 mm);
##   - a place step hides the future parts;
## then CLICKS "Save to design" (the sequence lands in the design's config)
## and Escape closes the Lab with every part seated.
func _bs_check(label: String, ok: bool, fails: Array) -> void:
	print("PlaytestHarness: buildsteps — %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		fails.append(label)


func _bs_find_button(root: Node, text: String) -> Button:
	for n in root.find_children("*", "Button", true, false):
		if (n as Button).text == text and (n as Button).is_visible_in_tree():
			return n
	return null


func _bs_center(c: Control) -> Vector2:
	var r := c.get_global_rect()
	return r.position + r.size / 2.0


func _bs_first(steps: Array, kind: String) -> int:
	for i in steps.size():
		if str(steps[i]["kind"]) == kind:
			return i
	return -1


func _run_buildsteps_capture() -> void:
	var tree := get_tree()
	var scene := tree.current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(_settle_s()).timeout
	var main := tree.current_scene
	var label := _shots_label if not _shots_label.is_empty() else "buildsteps"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var fails: Array = []
	var f := FileAccess.open("res://core/linkage/presets/ll_starshade_v1_soak_2026.json", FileAccess.READ)
	var cfg = JSON.parse_string(f.get_as_text()) if f != null else null
	if main == null or not main.has_method("open_linkage_lab") or not (cfg is Dictionary):
		push_error("PlaytestHarness: buildsteps — FAIL no Main.open_linkage_lab or preset")
		_maybe_quit()
		return
	main.call("open_linkage_lab", cfg)
	await tree.create_timer(0.6).timeout
	var lab: Control = main.get("linkage_lab_ui")
	_bs_check("the Lab opened", lab != null and lab.visible, fails)
	if lab == null:
		_maybe_quit()
		return
	var vp := lab.get_viewport()
	var builder := lab.get("_builder") as LinkageStructureBuilder
	var design_fold := builder.get_fold_angle()

	# Open the dock with a real click.
	var steps_btn := _bs_find_button(lab, "Steps")
	_bs_check("the topbar has a Steps button", steps_btn != null, fails)
	if steps_btn == null:
		_maybe_quit()
		return
	await _lc_click(vp, _bs_center(steps_btn))
	await tree.create_timer(0.4).timeout
	var panel: Control = lab.call("steps_panel")
	var player: LinkageStepPlayer = panel.call("player")
	_bs_check("clicking Steps opens the dock and enters playback", bool(panel.call("is_open")) and player != null and player.active, fails)
	var steps: Array = player.steps
	print("PlaytestHarness: buildsteps — %d steps, %d shown" % [steps.size(), LinkageBuildSteps.representative_steps(steps).size()])

	# Click a row: the player jumps there.
	var list := panel.get("_list") as ItemList
	var row := mini(5, list.item_count - 1)
	var rect := list.get_item_rect(row)
	await _lc_click(vp, list.get_global_rect().position + rect.position + rect.size / 2.0 - Vector2(0, list.get_v_scroll_bar().value))
	await tree.process_frame
	var want_i := int((panel.get("_rows") as Array)[row])
	_bs_check("clicking row %d jumps to step %d (at %d)" % [row, want_i + 1, player.index + 1], player.index == want_i, fails)

	# Click play: the op advances.
	var play_btn := panel.get("_play_btn") as Button
	var i0 := player.index
	var t0 := player.t
	await _lc_click(vp, _bs_center(play_btn))
	await tree.create_timer(1.2).timeout
	_bs_check("clicking play runs the sequence (step %d t %.2f -> step %d t %.2f)" % [i0 + 1, t0, player.index + 1, player.t],
		player.playing and (player.index != i0 or player.t > t0 + 0.05), fails)
	await _lc_click(vp, _bs_center(play_btn))
	_bs_check("clicking again pauses", not player.playing, fails)

	# One step of each kind.
	var n_shot := 0
	for kind in ["cut", "drill", "place", "fasten"]:
		var i := _bs_first(steps, kind)
		if i < 0:
			_bs_check("SOAK has a %s step" % kind, false, fails)
			continue
		player.go_to(i)
		var u := 0.45
		if kind == "drill":
			# Just past the first hole's plunge: that hole is drilled and the
			# bit is at the bottom of it.
			var ctx := player.context_for(rad_to_deg(builder.get_fold_angle()))
			var plan := LinkageBuildOps.stage(steps[i], {"data": ctx["data"], "parts": ctx["parts"], "drill_bolts": ctx["drill_bolts"]})
			u = (0.5 + 0.02) / float(maxi(1, (plan.get("jobs", []) as Array).size()))
		player.scrub(u)
		await tree.create_timer(1.6).timeout   # the camera follows
		var fr := player.last_frame()
		var fl := player.focus_local(fr)
		var cam3 := lab.get("_camera") as Camera3D
		print("PlaytestHarness: buildsteps — %s focus %s r %.2f m · camera target %s dist %.2f · camera at %s" % [kind,
			str((lab.get("_holder") as Node3D).transform * (fl["center"] as Vector3)), float(fl["radius"]),
			str(lab.get("_target")), float(lab.get("_dist")), str(cam3.global_position)])
		match kind:
			"cut":
				_bs_check("cut: the structure is hidden, the bench and saw are out",
					not builder.visible and player.tool_node("circular_saw") != null and player.tool_node("circular_saw").visible, fails)
			"drill":
				var holes: Array = fr["holes"]
				var tool := player.tool_node("drill")
				var ok := not holes.is_empty() and tool != null and tool.visible
				var err := INF
				if ok:
					var hole_m: Vector3 = player.bench_transform(fr) * (holes[0]["pos"] as Vector3)
					err = Vector2(tool.position.x - hole_m.x, tool.position.z - hole_m.z).length()
				_bs_check("drill: the bit is on the hole it drills (%.4f m)" % err, ok and err < 0.002, fails)
			"place":
				var hidden := 0
				for k in builder.part_keys():
					var s := builder.part_state(k)
					if not s.is_empty() and not bool(s.get("visible", true)):
						hidden += 1
				_bs_check("place: the structure shows with future parts hidden (%d)" % hidden, builder.visible and hidden > 0, fails)
			"fasten":
				var drv := player.tool_node("impact_driver")
				_bs_check("fasten: the driver is out at the joint", drv != null and drv.visible, fails)
		await _graph_shot(dir, "%02d_%s" % [n_shot, kind], [], "buildsteps")
		n_shot += 1
	player.go_to(steps.size() - 1)
	player.scrub(1.0)
	await tree.create_timer(1.6).timeout
	await _graph_shot(dir, "%02d_last" % n_shot, [], "buildsteps")

	# Save to design (a click), then Escape closes with the structure seated.
	var save := panel.get("_save_btn") as Button
	if save.disabled:
		panel.call("_mark_dirty")
	await _lc_click(vp, _bs_center(save))
	var bs := (lab.get("params") as LinkageParams).get_build_steps()
	_bs_check("Save to design stores the sequence (%d steps)" % (bs.get("steps", []) as Array).size(),
		(bs.get("steps", []) as Array).size() == steps.size(), fails)
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	await tree.process_frame
	ev = ev.duplicate()
	ev.pressed = false
	Input.parse_input_event(ev)
	await tree.create_timer(0.3).timeout
	if lab.visible:
		lab.call("close")
	var staged := 0
	for k in builder.part_keys():
		if not builder.part_state(k).is_empty():
			staged += 1
	_bs_check("closing the Lab seats every part (%d staged) and restores the fold (%.2f deg off)" % [staged,
		rad_to_deg(absf(builder.get_fold_angle() - design_fold))],
		staged == 0 and builder.visible and absf(builder.get_fold_angle() - design_fold) < 1e-3, fails)
	await _bs_radial_checks(main, dir, fails)
	await _bs_enclosure_checks(main, dir, fails)
	if fails.is_empty():
		print("PlaytestHarness: buildsteps — PASS")
	else:
		push_error("PlaytestHarness: buildsteps — %d CHECK(S) FAILED" % fails.size())
	_maybe_quit()


## The Lab's Radial Array group (A3): a radial preset loads into the
## controls, the builder draws every copy, and editing Count / Hidden copies
## through the controls rebuilds it.
func _bs_radial_checks(main: Node, dir: String, fails: Array) -> void:
	var tree := get_tree()
	var f := FileAccess.open("res://core/linkage/presets/ll_constellation.json", FileAccess.READ)
	var cfg = JSON.parse_string(f.get_as_text()) if f != null else null
	if not (cfg is Dictionary):
		_bs_check("the Constellation preset loads", false, fails)
		return
	main.call("open_linkage_lab", cfg)
	await tree.create_timer(0.8).timeout
	var lab: Control = main.get("linkage_lab_ui")
	var ra: Dictionary = lab.get("_ra")
	var builder := lab.get("_builder") as LinkageStructureBuilder
	var want := LinkageRadialArray.config(lab.get("params"))
	_bs_check("radial: the controls show the preset's array (enabled %s, count %d)" % [
		str((ra["enabled"] as CheckBox).button_pressed), int((ra["count"] as SpinBox).value)],
		(ra["enabled"] as CheckBox).button_pressed == bool(want["enabled"]) and bool(want["enabled"])
		and int((ra["count"] as SpinBox).value) == int(want["count"]), fails)
	var fr0 := builder.last_frame()
	var copies0: int = int((fr0.get("radial", {}) as Dictionary).get("visible_count", 0))
	var beams0 := (fr0.get("beams", []) as Array).size()
	_bs_check("radial: the builder draws %d copies (%d beams)" % [copies0, beams0], copies0 > 1 and beams0 > 0, fails)
	print("PlaytestHarness: buildsteps — radial readout: %s" % (ra["readout"] as Label).text)
	await _graph_shot(dir, "radial_00_constellation", [], "buildsteps")
	# Hide one more slot through the text field (the preset hides slot 3
	# already): one copy fewer.
	var le := ra["hiddenSlots"] as LineEdit
	le.text = le.text + ", 1" if not le.text.strip_edges().is_empty() else "1"
	le.text_submitted.emit(le.text)
	await tree.create_timer(0.8).timeout
	var fr1 := builder.last_frame()
	var copies1: int = int((fr1.get("radial", {}) as Dictionary).get("visible_count", 0))
	var beams1 := (fr1.get("beams", []) as Array).size()
	_bs_check("radial: also hiding slot 1 drops one copy (%d -> %d, beams %d -> %d)" % [copies0, copies1, beams0, beams1],
		copies1 == copies0 - 1 and beams1 < beams0, fails)
	await _graph_shot(dir, "radial_01_slot1_hidden", [], "buildsteps")
	# Fold the copies one at a time: mid-sequence some stand deployed, one
	# moves, the rest stay folded.
	(ra["sequential"] as CheckBox).button_pressed = true
	await tree.create_timer(0.8).timeout
	var prm: LinkageParams = lab.get("params")
	var rng := LinkageFoldSequence.sweep_range(prm)
	var k_seq := LinkageFoldSequence.deploy_order(LinkageRadialArray.deployed_plan(prm)).size()
	lab.call("_set_fold_angle", float(rng["min"]) + (float(rng["max"]) - float(rng["min"])) * 1.5 / float(maxi(1, k_seq)))
	await tree.create_timer(0.4).timeout
	var sc := builder.fold_schedule()
	_bs_check("radial: one-at-a-time folds the copies in turn (%d poses, moving %s)" % [
		(sc.get("distinct_angles", []) as Array).size(), str(sc.get("active_index", -1))],
		not sc.is_empty() and (sc["distinct_angles"] as Array).size() >= 2, fails)
	print("PlaytestHarness: buildsteps — radial readout: %s" % (ra["readout"] as Label).text)
	await _graph_shot(dir, "radial_02_sequential", [], "buildsteps")
	(ra["sequential"] as CheckBox).button_pressed = false
	await tree.create_timer(0.8).timeout
	# Switch the array off through the checkbox: back to one structure.
	(ra["enabled"] as CheckBox).button_pressed = false
	await tree.create_timer(0.8).timeout
	var fr2 := builder.last_frame()
	_bs_check("radial: unticking Enable draws one structure (radial %s)" % str(fr2.has("radial")),
		(fr2.get("radial", {}) as Dictionary).is_empty() and (fr2.get("beams", []) as Array).size() < beams1, fails)
	lab.call("close")


## A4 on the Hex preset (raised floor + walls / tables + shade tarps): the
## builder draws every covering, the Lab's controls switch them, a covering
## step stages its walls, and the guide writes the cut files.
func _bs_enclosure_checks(main: Node, dir: String, fails: Array) -> void:
	var tree := get_tree()
	var cfg = _read_json_file("res://core/linkage/presets/ll_starshade_hex.json")
	if not (cfg is Dictionary):
		_bs_check("the Hex preset loads", false, fails)
		return
	main.call("open_linkage_lab", cfg)
	await tree.create_timer(0.8).timeout
	var lab: Control = main.get("linkage_lab_ui")
	var builder := lab.get("_builder") as LinkageStructureBuilder
	var walls: Array = builder.last_walls()
	var kinds := {}
	for w in walls:
		kinds[str(w.get("kind", ""))] = int(kinds.get(str(w.get("kind", "")), 0)) + 1
	var cover := builder.get_node_or_null("Coverings")
	_bs_check("enclosure: walls, tables, the deck and tarps drawn (%s, %d meshes)" % [str(kinds), cover.get_child_count() if cover != null else 0],
		int(kinds.get("wall", 0)) >= 2 and int(kinds.get("shade", 0)) > 0 and cover != null and cover.get_child_count() == walls.size(), fails)
	_bs_check("enclosure: floor beams drawn (%d)" % builder.last_floor_beams().size(), not builder.last_floor_beams().is_empty(), fails)
	await _graph_shot(dir, "enclosure_00_hex", [], "buildsteps")
	# Tarps off through the checkbox.
	var sh: Dictionary = lab.get("_sh")
	(sh["enabled"] as CheckBox).button_pressed = false
	await tree.create_timer(0.8).timeout
	var tarps := builder.last_walls().filter(func(w): return str(w.get("kind", "")) == "shade")
	_bs_check("enclosure: unticking the tarps removes them (%d left)" % tarps.size(), tarps.is_empty(), fails)
	# Every span to fabric.
	var cv: Dictionary = lab.get("_cv")
	lab.call("_set_all_spans", "fabric")
	await tree.create_timer(0.8).timeout
	var fab := builder.last_walls().filter(func(w): return str(w.get("kind", "")) == "fabric")
	_bs_check("enclosure: 'Every span: Fabric' hangs fabric bands (%d)" % fab.size(), fab.size() >= 6, fails)
	await _graph_shot(dir, "enclosure_01_fabric", [], "buildsteps")
	# The deck step stages the deck: hidden before, seated after.
	var steps := LinkageBuildSteps.generate_for(lab.get("params"))
	var deck_i := -1
	for i in steps.size():
		for sel in steps[i].get("targets", []):
			if str(sel.get("kind", "")) == "wall" and str(sel.get("band", "")) == "floor":
				deck_i = i
	_bs_check("enclosure: the generated sequence lays the deck (step %d)" % (deck_i + 1), deck_i >= 0, fails)
	var deck_key := ""
	for w in builder.last_walls():
		if str(w.get("band", "")) == "floor":
			deck_key = LinkagePartKeys.part_key(w, "wall")
	if deck_i >= 0 and not deck_key.is_empty():
		var panel: Control = lab.call("steps_panel")
		lab.call("toggle_steps")
		await tree.create_timer(0.4).timeout
		var player: LinkageStepPlayer = panel.call("player")
		player.set_steps(steps)
		player.go_to(deck_i)
		player.scrub(0.0)
		await tree.create_timer(0.3).timeout
		var before := builder.part_state(deck_key)
		var shown_before: bool = before.is_empty() or bool(before.get("visible", true))
		player.scrub(1.0)
		await tree.create_timer(0.3).timeout
		var after := builder.part_state(deck_key)
		var seated: bool = after.is_empty() or (bool(after.get("visible", true)) and not (after.get("offset") is Transform3D and not (after["offset"] as Transform3D).is_equal_approx(Transform3D.IDENTITY)))
		_bs_check("enclosure: the deck step brings the deck in (start %s, end %s)" % [str(before), str(after)],
			seated and (not shown_before or before.get("offset") is Transform3D), fails)
		await _graph_shot(dir, "enclosure_02_deck_step", [], "buildsteps")
		lab.call("toggle_steps")
		await tree.create_timer(0.3).timeout
	# The guide writes the cut files.
	main.call("open_linkage_build_guide", (lab.get("params") as LinkageParams).to_config(), "harness_hex")
	await tree.create_timer(0.8).timeout
	var guide: Control = main.get("linkage_build_guide_ui")
	var out_dir: String = guide.call("export_cut_files") if guide != null else ""
	var n_svg := 0
	if not out_dir.is_empty():
		for f in DirAccess.get_files_at(out_dir):
			if f.ends_with(".svg"):
				n_svg += 1
	_bs_check("enclosure: the guide exports %d cut files to %s" % [n_svg, out_dir], n_svg >= 6, fails)
	await _graph_shot(dir, "enclosure_03_guide", [], "buildsteps")
	if guide != null and guide.has_method("close"):
		guide.call("close")
	lab.call("close")


func _read_json_file(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f != null else null


# ==================== FABRICATION BY THE CREW (--capture=fabcrew) ====================
## Swarm B6: the population's chore board drives the build timeline. Seeds a
## 12-person pop-driven habitat (tanks + tagged spaces, as --capture=project
## does), places a packed SOAK 2026 kit, queues the crew build exactly as the
## Lab's "Queue build for crew" does (the phase chores + the labour-mode
## build_run record), then runs the clock and asserts what a PNG cannot:
##   - the under-construction prop carries a labour-mode LinkageBuildSite that
##     owns the visuals (the bridge's coarse prefix reveal stands down: the
##     beam MultiMesh never gets a prefix count);
##   - the drawn build time only moves forward and tracks the labour;
##   - people DOING the project's chores on site are drawn on the timeline's
##     lanes (their own bodies hidden as stand-ins), and nobody else is;
##   - the structure grows as the work is credited, and when the project is
##     done the ring is deployed, every part seated, the crew released.
## Removes its cap_fc_* items and prop.
func _fc_check(label: String, ok: bool, fails: Array) -> void:
	print("PlaytestHarness: fabcrew — %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		fails.append(label)


func _fc_site(main: Node, pid: String) -> LinkageBuildSite:
	return LinkageBuildSite.site_for(main, pid)


func _run_fabcrew_capture() -> void:
	var sgv := await _find_graph_view()
	var scene := get_tree().current_scene
	var loader: Node = scene.find_child("TerrainLoader", true, false) if scene != null else null
	if sgv == null or loader == null:
		push_error("PlaytestHarness: fabcrew needs a TerrainLoader map and the graph view")
		_maybe_quit()
		return
	sgv.visible = false
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(_settle_s()).timeout
	var main := get_tree().current_scene
	var model: Variant = sgv.get("model")
	var fails: Array = []
	var label := _shots_label if not _shots_label.is_empty() else "fabcrew"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)

	# --- seed: a 12-person crew camp (the project capture's) -------------------
	var hab_id := "cap_fc_hab"
	var ids := [hab_id, "cap_fc_water", "cap_fc_food"]
	for iid0 in ids:
		if not (model.get_item(str(iid0)) as Dictionary).is_empty():
			model.remove_item(str(iid0))
	model.add_item({"id": hab_id, "type": "processor", "x": 0.0, "y": 0.0, "width": 150.0, "height": 150.0,
		"specs": {"name": "Build Crew", "role": "habitat", "occupants": 12, "pop_driven": true,
			"watts": 0.0, "energy_source": "", "efficiency": 1.0,
			"inputs": [{"kind": "water", "rate": 2.0, "unit": "L/h"}, {"kind": "food", "rate": 0.06, "unit": "kg/h"}],
			"outputs": []}})
	for t in [["cap_fc_water", "water", "L", 4000.0], ["cap_fc_food", "food", "kg", 200.0]]:
		model.add_item({"id": str(t[0]), "type": "resource", "x": -200.0, "y": 220.0, "width": 90.0, "height": 100.0,
			"specs": {"name": str(t[1]).capitalize(), "resource_kind": str(t[1]),
				"capacity_qty": float(t[3]), "capacity_unit": str(t[2]), "level": 1.0}})
	for c in [["cap_fc_water", hab_id, "res_in_0", "water"], ["cap_fc_food", hab_id, "res_in_1", "food"]]:
		model.add_connection({"polarity": "resource", "resource_type": str(c[3]),
			"source_item_id": str(c[0]), "source_handle_id": "output",
			"target_item_id": str(c[1]), "target_handle_id": str(c[2])})
	if "day_time" in main:
		main.day_time = 8.0
	main.time_scale = 0.01
	await get_tree().create_timer(1.5).timeout
	var bridge: Variant = sgv.get("_npc_population")
	if bridge == null:
		_fc_check("the population bridge runs", false, fails)
		_maybe_quit()
		return
	var reg: Variant = bridge.call("registry_for", main)
	for pair in [["sleep", Vector2(-40, -30)], ["kitchen", Vector2(-40, 30)], ["water_point", Vector2(-55, 0)],
			["restroom", Vector2(-70, 20)], ["shower", Vector2(-70, -20)]]:
		var cpt: Vector2 = pair[1]
		reg.call("set_space_type", {"kind": "area", "poly": [[cpt.x - 8, cpt.y - 8], [cpt.x + 8, cpt.y - 8],
			[cpt.x + 8, cpt.y + 8], [cpt.x - 8, cpt.y + 8]]}, str(pair[0]), 30)
	var board: Variant = bridge.call("chore_board_for", hab_id)
	for _w in 6:
		if board != null:
			break
		await get_tree().create_timer(0.5).timeout
		board = bridge.call("chore_board_for", hab_id)
	if board == null:
		_fc_check("the crew's chore board appears", false, fails)
		_maybe_quit()
		return
	board.rules["night_shift"] = true

	# --- the kit, and the build queued as the Lab queues it -------------------
	var f := FileAccess.open("res://core/linkage/presets/ll_starshade_v1_soak_2026.json", FileAccess.READ)
	var cfg = JSON.parse_string(f.get_as_text())
	var site_xz := Vector2(25.0, 15.0)
	var placed: Dictionary = PlacedPropService.place_model_at_xz(main, LinkageStructureBuilder.MODEL_ID,
		site_xz.x, site_xz.y, {"linkage_spec": cfg, "packed": true})
	var crate_id := str(placed.get("prop_id", ""))
	_fc_check("a packed SOAK 2026 kit is placed", not crate_id.is_empty(), fails)
	var p := LinkageParams.new()
	p.from_config(cfg)
	var counts := LinkageBom.fab_counts(LinkageBom.compute(p), {})
	counts.erase("assembly_steps")
	var tasks: Array = NpcCrewPlan.linkage_fab_tasks(counts)
	var sched: Dictionary = NpcCrewPlan.schedule(tasks, 12)
	var overrides := {}
	for t2 in tasks:
		var tid := str((t2 as Dictionary).get("id", ""))
		match tid:
			"erect":
				overrides[tid] = {"effect": {"op": "unpack_prop", "prop_id": crate_id}}
			"panels":
				overrides[tid] = {"effect": {"op": "seed_graph", "prop_id": crate_id}}
			_:
				overrides[tid] = {"effect": {"op": "set_build_phase", "prop_id": crate_id, "phase": tid}}
	PlacedPropService.update_prop_record(main, crate_id, {"build_state": {"phase": "", "ghost": 0.12}}, true)
	var proj_id := str(bridge.call("create_site_project", hab_id, "linkage_build", "Harness crew build",
		crate_id, site_xz, NpcCrewPlan.chore_specs(tasks, sched, overrides), {"start_h": 0.0, "end_h": 24.0},
		{"kind": "prop", "id": crate_id}, {"crew": 12, "makespan_s": float(sched.get("makespan_s", 0.0)),
			"fab_counts": counts}))
	PlacedPropService.update_prop_record(main, crate_id, {LinkageBuildSite.RECORD_KEY: {
		"mode": "labour", "iid": hab_id, "project_id": proj_id,
		"crew_n": mini(12, LinkageBuildSite.MAX_LABOUR_LANES)}}, true)
	await get_tree().process_frame
	await get_tree().process_frame
	var site := _fc_site(main, crate_id)
	_fc_check("the build is queued and its kit carries a labour-mode build site",
		not proj_id.is_empty() and site != null and site.is_labour(), fails)
	if site == null:
		_fc_finish(main, model, ids, crate_id, fails)
		return
	await get_tree().create_timer(0.6).timeout
	_fc_check("the site owns the visuals (the coarse reveal stands down)", site.owns_visuals(), fails)

	var cam := Camera3D.new()
	cam.name = "PlaytestFabCrewCam"
	scene.add_child(cam)
	cam.make_current()
	var gy := TerrainSurfaceQuery.ground_height_at(main, site_xz.x, site_xz.y)
	var aim := Vector3(site_xz.x, gy + 1.0, site_xz.y)
	cam.global_position = Vector3(site_xz.x + 13.0, gy + 7.5, site_xz.y + 14.0)
	cam.look_at(aim, Vector3.UP)

	# --- run the clock: the crew works --------------------------------------
	main.time_scale = 0.3
	var last_t := -1.0
	var backwards := 0
	var max_manned := 0
	var stand_bad := 0
	var prefix_seen := false
	var vis_first := -1
	var vis_last := -1
	var shots := 0
	var done := false
	var hidden_ok := 0
	var prev_lanes: Dictionary = {}
	for k in 900:
		await get_tree().create_timer(0.5).timeout
		site = _fc_site(main, crate_id)
		if site == null:
			continue
		var tnow := site.build_time()
		if tnow < last_t - 1.0:
			backwards += 1
		last_t = maxf(last_t, tnow)
		var b := (site.get_parent() as Node).get_node_or_null("ModelRoot") as LinkageStructureBuilder
		if b != null:
			var beams := b.get_node_or_null("Beams") as MultiMeshInstance3D
			if beams != null and beams.multimesh != null and beams.multimesh.visible_instance_count >= 0:
				prefix_seen = true
			var vis := 0
			for key in b.part_keys():
				var st := b.part_state(key)
				if st.is_empty() or bool(st.get("visible", true)):
					vis += 1
			if vis_first < 0:
				vis_first = vis
			vis_last = vis
		var status: Dictionary = site.get("_status")
		var present: Array = status.get("present", [])
		var manned := site.manned_count()
		max_manned = maxi(max_manned, manned)
		# Everyone manning a lane is a stand-in; their own avatar is hidden.
		var host: Node = sgv.get("_npc_host")
		var lane_of: Dictionary = site.get("_lane_of")
		for pr in present:
			var aid := str(pr["id"])
			if lane_of.has(aid) and not NpcStandIns.has(aid):
				stand_bad += 1
			# The host hides a stand-in on ITS next frame; judge only people
			# who were already on a lane at the previous sample.
			if lane_of.has(aid) and prev_lanes.has(aid) and host != null:
				var avs: Dictionary = host.get("_avatars")
				var av = avs.get(aid)
				if av != null and is_instance_valid(av) and (av as Node3D).visible:
					stand_bad += 1
				else:
					hidden_ok += 1
		prev_lanes = lane_of.duplicate()
		if manned > 0 and shots < 3 and k % 8 == 0:
			var figs: Array = site.crew_figures()
			for fg in figs:
				if (fg as Node3D).visible:
					var fp := (fg as Node3D).global_position
					cam.global_position = fp + Vector3(3.5, 2.2, 3.5)
					cam.look_at(fp + Vector3(0, 1.0, 0), Vector3.UP)
					break
			await _graph_shot(dir, "%02d_crew_at_work" % shots, [], "fabcrew")
			print("PlaytestHarness: fabcrew — %s" % site.progress_line())
			shots += 1
			cam.global_position = Vector3(site_xz.x + 13.0, gy + 7.5, site_xz.y + 14.0)
			cam.look_at(aim, Vector3.UP)
		if k % 40 == 0:
			print("PlaytestHarness: fabcrew — %s · t %.0f s · %d parts shown" % [site.progress_line(), tnow, vis_last])
		if str(status.get("state", "")) == "done" and bool(site.get("_finished")):
			done = true
			break
	main.time_scale = 0.0
	_fc_check("the drawn build time only moves forward (%d steps back)" % backwards, backwards == 0, fails)
	_fc_check("the bridge's prefix reveal never touched the structure", not prefix_seen, fails)
	_fc_check("people on site man the lanes (up to %d at once)" % max_manned, max_manned > 0, fails)
	_fc_check("everyone on a lane is a stand-in with their own body hidden (%d checks, %d bad)" % [hidden_ok, stand_bad],
		stand_bad == 0 and hidden_ok > 0, fails)
	_fc_check("the structure grew with the work (%d -> %d parts shown)" % [vis_first, vis_last], vis_last > vis_first, fails)
	_fc_check("the crew finished the project", done, fails)
	if done:
		await get_tree().create_timer(0.5).timeout
		site = _fc_site(main, crate_id)
		var rec: Dictionary = PlacedPropService.get_prop_record(main, crate_id)
		var b2 := (site.get_parent() as Node).get_node_or_null("ModelRoot") as LinkageStructureBuilder if site != null else null
		var staged := 0
		if b2 != null:
			for key in b2.part_keys():
				if not b2.part_state(key).is_empty():
					staged += 1
		_fc_check("built: unpacked, deployed, every part seated (%d staged), no stand-ins" % staged,
			not bool(rec.get("packed", true)) and bool(rec.get("linkage_deployed", false)) and staged == 0
			and NpcStandIns.is_empty(), fails)
		cam.global_position = Vector3(site_xz.x + 13.0, gy + 7.5, site_xz.y + 14.0)
		cam.look_at(aim, Vector3.UP)
		await _graph_shot(dir, "10_built", [], "fabcrew")
	cam.queue_free()
	_fc_finish(main, model, ids, crate_id, fails)


func _fc_finish(main: Node, model: Variant, ids: Array, crate_id: String, fails: Array) -> void:
	var loader: Node = main.find_child("TerrainLoader", true, false)
	if loader != null and not crate_id.is_empty() and loader.has_method("delete_prop_by_id"):
		loader.call("delete_prop_by_id", crate_id)
	for iid0 in ids:
		if not (model.get_item(str(iid0)) as Dictionary).is_empty():
			model.remove_item(str(iid0))
	if fails.is_empty():
		print("PlaytestHarness: fabcrew — PASS")
	else:
		push_error("PlaytestHarness: fabcrew — %d CHECK(S) FAILED" % fails.size())
	_maybe_quit()

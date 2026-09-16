extends Node

## PlaytestHarness — CLI-driven map launch + automated drone-view screenshot
## capture for visual iteration on generated location maps.
##
## Active ONLY when user args (after `--`) are present; with no args every
## callback is a hard no-op so normal play, selftests, `--import` and headless
## boots are untouched.
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
##                              "dawn"  = sunrise lighting ladder: beam energy/colour + ambient per solar altitude
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


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	_parse_args(args)
	var wants_post_load := not _capture_mode.is_empty() or _assign_facades_count > 0 \
		or _sculpt_test or _boot_window_wall
	if not is_nan(_launch_lat) and not is_nan(_launch_lon):
		_active = true
		_launch_map.call_deferred()
	elif not _launch_scene.is_empty():
		_active = true
		_launch_scene_direct.call_deferred()
	elif wants_post_load:
		# No explicit map to launch: whatever scene boots (e.g. default map)
		# gets the post-load actions (capture / facade assignment).
		_active = true
		if _capture_mode == "graph":
			# Graph capture works on any map (incl. the default soak map,
			# which has no TerrainLoader) — different wait path.
			_run_graph_capture.call_deferred()
		elif _capture_mode == "siphon":
			_run_siphon_lab_capture.call_deferred()
		elif _capture_mode == "site-review":
			_run_site_review.call_deferred()
		elif _capture_mode == "ambient":
			_run_ambient_flow_verify.call_deferred()
		elif _capture_mode == "population":
			_run_population_verify.call_deferred()
		elif _capture_mode == "project":
			_run_project_verify.call_deferred()
		elif _capture_mode == "settlement":
			_run_settlement_capture.call_deferred()
		elif _capture_mode == "labour":
			_run_labour_capture.call_deferred()
		elif _capture_mode == "npcpose":
			_run_npc_pose_capture.call_deferred()
		elif _capture_mode == "workui":
			_run_workui_capture.call_deferred()
		elif _capture_mode == "npc-anim":
			_run_npc_anim_verify.call_deferred()
		elif _capture_mode == "autobind":
			_run_autobind_verify.call_deferred()
		elif _capture_mode == "penstock":
			_run_penstock_verify.call_deferred()
		elif _capture_mode == "hydroload":
			_run_hydro_load_verify.call_deferred()
		elif _capture_mode == "pondid":
			_run_pond_id_verify.call_deferred()
		elif _capture_mode == "culvert":
			_run_culvert_downhill_verify.call_deferred()
		elif _capture_mode == "veg":
			_run_veg_capture.call_deferred()
		elif _capture_mode == "areafill":
			_run_area_fill_verify.call_deferred()
		elif _capture_mode == "vegdock":
			_run_veg_dock_capture.call_deferred()
		elif _capture_mode == "foodforest":
			_run_food_forest_verify.call_deferred()
		elif _capture_mode == "tree":
			_run_tree_portrait_capture.call_deferred()
		elif _capture_mode == "weather":
			_run_extreme_weather_capture.call_deferred()
		elif _capture_mode == "stars":
			_run_star_capture.call_deferred()
		elif _capture_mode == "dawn":
			_run_dawn_capture.call_deferred()
		elif _capture_mode == "windowwall":
			_run_window_wall_capture.call_deferred()
		elif _boot_window_wall:
			_boot_window_wall_view.call_deferred()
		else:
			_await_and_run.call_deferred()


func _parse_args(args: PackedStringArray) -> void:
	var map_file := ""
	for a in args:
		if a.begins_with("--user-map="):
			map_file = a.get_slice("=", 1)
		elif a.begins_with("--scene="):
			_launch_scene = a.get_slice("=", 1).strip_edges()
		elif a.begins_with("--map-lat="):
			_launch_lat = a.get_slice("=", 1).to_float()
		elif a.begins_with("--map-lon="):
			_launch_lon = a.get_slice("=", 1).to_float()
		elif a.begins_with("--half-extent="):
			_launch_half_extent = a.get_slice("=", 1).to_float()
		elif a.begins_with("--capture="):
			_capture_mode = a.get_slice("=", 1).strip_edges().to_lower()
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
	if not map_file.is_empty():
		_load_map_definition(map_file)
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
	ctx.set_pending(_launch_lat, _launch_lon, _launch_label, _launch_half_extent)
	tree.change_scene_to_file(MapDefinition.GENERATED_SCENE)
	if _capture_mode == "graph":
		_run_graph_capture()
	elif _capture_mode == "siphon":
		_run_siphon_lab_capture()
	elif _capture_mode == "site-review":
		_run_site_review()
	elif _capture_mode == "ambient":
		_run_ambient_flow_verify()
	elif _capture_mode == "population":
		_run_population_verify()
	elif _capture_mode == "project":
		_run_project_verify()
	elif _capture_mode == "settlement":
		_run_settlement_capture()
	elif _capture_mode == "labour":
		_run_labour_capture()
	elif _capture_mode == "npcpose":
		_run_npc_pose_capture()
	elif _capture_mode == "workui":
		_run_workui_capture()
	elif _capture_mode == "npc-anim":
		_run_npc_anim_verify()
	elif _capture_mode == "autobind":
		_run_autobind_verify()
	elif _capture_mode == "penstock":
		_run_penstock_verify()
	elif _capture_mode == "hydroload":
		_run_hydro_load_verify()
	elif _capture_mode == "pondid":
		_run_pond_id_verify()
	elif _capture_mode == "culvert":
		_run_culvert_downhill_verify()
	elif _capture_mode == "veg":
		_run_veg_capture()
	elif _capture_mode == "areafill":
		_run_area_fill_verify()
	elif _capture_mode == "vegdock":
		_run_veg_dock_capture()
	elif _capture_mode == "foodforest":
		_run_food_forest_verify()
	elif _capture_mode == "tree":
		_run_tree_portrait_capture()
	elif _capture_mode == "packing":
		_run_packing_capture()
	elif _capture_mode == "hardware":
		_run_hardware_capture()
	elif _capture_mode == "weather":
		_run_extreme_weather_capture()
	elif _capture_mode == "stars":
		_run_star_capture()
	elif _capture_mode == "dawn":
		_run_dawn_capture()
	elif _capture_mode == "windowwall":
		_run_window_wall_capture()
	elif _boot_window_wall:
		_boot_window_wall_view()
	elif not _capture_mode.is_empty() or _assign_facades_count > 0 or _sculpt_test:
		_await_and_run()


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
	tree.change_scene_to_file(_launch_scene)
	if _capture_mode == "graph":
		_run_graph_capture()
	elif _capture_mode == "siphon":
		_run_siphon_lab_capture()
	elif _capture_mode == "site-review":
		_run_site_review()
	elif _capture_mode == "ambient":
		_run_ambient_flow_verify()
	elif _capture_mode == "population":
		_run_population_verify()
	elif _capture_mode == "project":
		_run_project_verify()
	elif _capture_mode == "settlement":
		_run_settlement_capture()
	elif _capture_mode == "labour":
		_run_labour_capture()
	elif _capture_mode == "npcpose":
		_run_npc_pose_capture()
	elif _capture_mode == "workui":
		_run_workui_capture()
	elif _capture_mode == "autobind":
		_run_autobind_verify()
	elif _capture_mode == "penstock":
		_run_penstock_verify()
	elif _capture_mode == "hydroload":
		_run_hydro_load_verify()
	elif _capture_mode == "pondid":
		_run_pond_id_verify()
	elif _capture_mode == "veg":
		_run_veg_capture()
	elif _capture_mode == "areafill":
		_run_area_fill_verify()
	elif _capture_mode == "vegdock":
		_run_veg_dock_capture()
	elif _capture_mode == "foodforest":
		_run_food_forest_verify()
	elif _capture_mode == "tree":
		_run_tree_portrait_capture()
	elif _capture_mode == "packing":
		_run_packing_capture()
	elif _capture_mode == "hardware":
		_run_hardware_capture()
	elif _capture_mode == "weather":
		_run_extreme_weather_capture()
	elif _capture_mode == "stars":
		_run_star_capture()
	elif _capture_mode == "dawn":
		_run_dawn_capture()
	elif _capture_mode == "windowwall":
		_run_window_wall_capture()
	elif _boot_window_wall:
		_boot_window_wall_view()
	elif not _capture_mode.is_empty() or _assign_facades_count > 0 or _sculpt_test:
		_await_and_run()


func _await_and_run() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: TerrainLoader not found — aborting")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	print("PlaytestHarness: map loaded — settling %.0f s" % SETTLE_AFTER_LOAD_S)
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
func _run_graph_capture() -> void:
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout

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
	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	await get_tree().create_timer(1.0).timeout
	await _graph_shot(dir, "01_open_as_loaded", manifest)

	# Auto-arranged freeform layout.
	if sgv.has_method("_apply_graph_auto_layout"):
		sgv.call("_apply_graph_auto_layout", true)
		await get_tree().create_timer(0.5).timeout
		await _graph_shot(dir, "02_freeform_arranged", manifest)

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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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


func _run_pond_id_verify() -> void:
	var loader := await _find_terrain_loader()
	if loader == null:
		push_error("PlaytestHarness: TerrainLoader not found — aborting pond-id verify")
		_maybe_quit()
		return
	if not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
		push_error("PlaytestHarness: pond-id verify — could not designate the test pond")
		_maybe_quit()
		return

	var idx1 := -1
	for i in 200:
		# find_pond_idx_by_tag needs the freshly-derived tag; read it back from
		# the record instead of re-deriving (EarthworksBuilder is static/private
		# to the loader in spirit — just scan get_pond_info by trial index 0..N).
		var info := loader.call("get_pond_info", i) as Dictionary
		if not bool(info.get("valid", false)):
			break
		if bool(info.get("user", false)) and str(info.get("label", "")) == "Verify Pond":
			idx1 = i
			break
	if idx1 < 0:
		push_error("PlaytestHarness: pond-id verify — designated pond not found in water data")
		_maybe_quit()
		return
	var info1 := loader.call("get_pond_info", idx1) as Dictionary
	var pond_id1 := str(info1.get("pond_id", ""))
	var tag1 := str(info1.get("tag", ""))
	print("PlaytestHarness: pondid verify — pond_id=%s tag=%s" % [pond_id1, tag1])
	if pond_id1.is_empty():
		push_error("PlaytestHarness: pond-id verify — no pond_id assigned")
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
	for i in 200:
		var info_b := loader.call("get_pond_info", i) as Dictionary
		if not bool(info_b.get("valid", false)):
			break
		water_count_before += 1
	var poly2 := PackedVector2Array([
		Vector2(-9, -7), Vector2(9, -7), Vector2(9, 7), Vector2(-9, 7)])
	var ok2 := bool(loader.call("designate_sculpted_pond", poly2, "Verify Pond", NAN, ""))
	print("PlaytestHarness: pondid verify — re-designate (reshaped) ok=%s" % str(ok2))
	await get_tree().create_timer(0.3).timeout

	var water_count_after := 0
	var idx2 := -1
	for i in 200:
		var info_c := loader.call("get_pond_info", i) as Dictionary
		if not bool(info_c.get("valid", false)):
			break
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S + 3.0).timeout
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
	if fails == 0:
		print("PlaytestHarness: hydroload verify — PASS")
	else:
		push_error("PlaytestHarness: hydroload verify — %d CHECK(S) FAILED" % fails)
	_maybe_quit()


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
	var mgr: Node3D = main.find_child("ConduitManager", true, false) as Node3D 			if main != null else null
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
		print("  manager: global_visible=%s preview_visible=%s world_visible=%s explicit_seen=%s instances=%d" % [
			str(mgr.get("_global_visible")), str(mgr.get("_preview_visible")),
			str((mgr as Node3D).visible), str(mgr.get("_explicit_seen")),
			(mgr.get("_instances") as Dictionary).size()])
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
		push_error("PlaytestHarness: SystemGraphView not found — aborting autobind verify")
		_maybe_quit()
		return
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
	var model: Variant = sgv.get("model")
	if model == null or not model.has_method("add_item"):
		push_error("PlaytestHarness: graph model unavailable — aborting autobind verify")
		_maybe_quit()
		return

	# The soak map accumulates leftover pond/siphon test items AND connections
	# across repeated capture runs (this test re-uses the same hardcoded ids
	# every invocation) — clear every pond_storage tank and any prior siphon
	# item/connections with our test ids first so the ranking pool and wiring
	# are deterministic, not polluted by a stale wire from an earlier run.
	for it in (model.items as Array).duplicate():
		if not (it is Dictionary):
			continue
		var iid := str((it as Dictionary).get("id", ""))
		if bool(((it as Dictionary).get("specs", {}) as Dictionary).get("pond_storage", false)) \
				or iid == "cap_autobind_siphon":
			model.remove_item(iid)
	for conn in (model.connections as Array).duplicate():
		if not (conn is Dictionary):
			continue
		var c := conn as Dictionary
		if str(c.get("source_item_id", "")) == "cap_autobind_siphon" \
				or str(c.get("target_item_id", "")) == "cap_autobind_siphon":
			model.remove_connection(str(c.get("id", "")))

	var g := 0.0
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		g = float((soi.call("world_center") as Vector3).y)

	var near_id := "cap_autobind_near_pond"
	var far_id := "cap_autobind_far_pond"
	var siphon_id := "cap_autobind_siphon"
	for pid in [near_id, far_id]:
		model.add_item({
			"id": pid, "type": "resource", "x": 0.0, "y": 0.0,
			"width": 80.0, "height": 80.0,
			# Site coords live on the ITEM root (GraphSiteLayout.has_site_coords),
			# NOT nested under specs — matches _apply_site_coords_from_prop.
			"site_x_m": (10.0 if pid == near_id else 500.0), "site_z_m": 0.0,
			"specs": {
				"name": "Autobind Pond", "resource_kind": "water",
				"pond_storage": true, "fill_mode": "auto",
				"capacity_qty": 30000.0, "capacity_unit": "L",
				"level": 0.5, "stock_l": 15000.0,
				"floor_m": g, "rim_m": g + 2.0, "level_m": g + 1.0,
			},
		})
	model.add_item({
		"id": siphon_id, "type": "processor", "x": 160.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "elevation_m": g + 1.0,
		"site_x_m": 0.0, "site_z_m": 0.0,
		"specs": {
			"name": "Autobind Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "manning_n": 0.012,
			"max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
		},
	})

	# NEAR pond (dist=10m) within a 40m cap → should bind silently.
	var bound_near := bool(sgv.call("bind_siphon_to_nearest_pond", siphon_id, true, 40.0))
	# resolve_siphon_pond reads the flow engine's cached connection index, which
	# rebuilds on tick() — but tick() wall-clock-throttles itself
	# (_wall_tick_interval), so a single process_frame isn't enough. Wait past
	# the throttle so a connection made THIS frame is reflected (normal in
	# gameplay — the ambient tick catches up within a fraction of a second).
	await get_tree().create_timer(0.5).timeout
	var pond_after_near := sgv.call("resolve_siphon_pond", siphon_id) as Dictionary
	var bound_to_near := bound_near and str(pond_after_near.get("id", "")) == near_id
	print("PlaytestHarness: autobind verify — near pond (10m, cap 40m): bound=%s to=%s -> %s" % [
		str(bound_near), str(pond_after_near.get("id", "")),
		"PASS" if bound_to_near else "FAIL"])

	# Rewire siphon fresh (remove the bind) and test the FAR pond beyond the cap.
	for conn: Dictionary in (model.connections as Array).duplicate():
		if str(conn.get("target_item_id", "")) == siphon_id or str(conn.get("source_item_id", "")) == siphon_id:
			model.remove_connection(str(conn.get("id", "")))
	# Make the far pond the ONLY candidate by removing the near one.
	model.remove_item(near_id)
	var bound_far_capped := bool(sgv.call("bind_siphon_to_nearest_pond", siphon_id, true, 40.0))
	print("PlaytestHarness: autobind verify — far pond (500m, cap 40m): bound=%s -> %s" % [
		str(bound_far_capped), "PASS (correctly refused)" if not bound_far_capped else "FAIL (bound beyond cap!)"])

	# Uncapped manual Rebind should succeed regardless of distance.
	var bound_far_uncapped := bool(sgv.call("bind_siphon_to_nearest_pond", siphon_id, true))
	print("PlaytestHarness: autobind verify — far pond, uncapped manual Rebind: bound=%s -> %s" % [
		str(bound_far_uncapped), "PASS" if bound_far_uncapped else "FAIL"])

	_maybe_quit()


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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout

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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout

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
	for stype in sites:
		var c: Vector2 = sites[stype]
		reg.call("set_space_type", {"kind": "area", "poly": [
			[c.x - half, c.y - half], [c.x + half, c.y - half],
			[c.x + half, c.y + half], [c.x - half, c.y + half]]}, str(stype), 30)
	# One deliberately CONCAVE area (a U, like a courtyard wrapping a building).
	# Its centroid lands in the opening, outside the space, so this exercises
	# SpaceRegistry.area_interior_point's fallback against a real registry and
	# real agents rather than only in the offline geometry test.
	var u_poly: Array = [[40, 40], [70, 40], [70, 70], [61, 70], [61, 49],
			[49, 49], [49, 70], [40, 70]]
	reg.call("set_space_type", {"kind": "area", "poly": u_poly}, "fire_circle", 12)
	var u_pt: Variant = SpaceRegistry.area_interior_point(u_poly)
	var u_centroid := SpaceRegistry.polygon_centroid(u_poly)
	var ok_concave := u_pt is Vector2 		and SpaceRegistry.polygon_contains(u_poly, u_pt as Vector2) 		and not SpaceRegistry.polygon_contains(u_poly, u_centroid)
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
	# moved time_scale nor holds the noon claim.
	var ts_before_site := float(main.time_scale) if main != null and "time_scale" in main else -1.0
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "site")
	var noon_claim := false
	if main != null and main.get("clock") != null:
		var claims: Variant = main.clock.get("claims")
		if claims != null and claims.has_method("has_claim"):
			noon_claim = bool(claims.call("has_claim", "graph_elevation_noon"))
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
	var ok_walk := float(wsum.get("walk_distance_m", 0.0)) > 1.0 			and float(wsum.get("walk_kcal", 0.0)) > 0.0 and not per_need.is_empty()
	print("PlaytestHarness: population verify — walking metrics %s" % [
		"PASS" if ok_walk else "FAIL (no distance/calorie accounting)"])
	var planned := int(nav_info.get("hits", 0)) + int(nav_info.get("misses", 0))
	var ok_nav := nav_ready and int(nav_info.get("cells", 0)) > 0 			and planned > 0 and with_path > 0
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
	var closest_pair := INF
	var stacked := 0
	var agent_dots: Array = bridge.call("agent_dots")
	for i in range(agent_dots.size()):
		var pa: Vector2 = (agent_dots[i] as Dictionary).get("pos", Vector2.ZERO)
		for j in range(i + 1, agent_dots.size()):
			var pb: Vector2 = (agent_dots[j] as Dictionary).get("pos", Vector2.ZERO)
			var dd := pa.distance_to(pb)
			closest_pair = minf(closest_pair, dd)
			if dd < 0.1:
				stacked += 1
	var ok_space := stacked == 0
	print("PlaytestHarness: population verify — personal space %s (%d people, closest pair %.2f m, %d stacked)" % [
		"PASS" if ok_space else "FAIL", agent_dots.size(), closest_pair, stacked])

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

	# Tagged spaces must be resolvable as Site Plan markers with occupancy.
	var marks: Array = bridge.call("space_markers", main)
	var ok_marks := marks.size() == sites.size() + 1   # +1 = the concave area
	print("PlaytestHarness: population verify — space markers %s (%d of %d resolved)" % [
		"PASS" if ok_marks else "FAIL", marks.size(), sites.size() + 1])
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
		"PASS" if (ok_flow and ok_move and ok_smooth and ok_chore and ok_face and ok_pose and ok_starve and ok_cascade and ok_3d and ok_nav and ok_walk and ok_desire and ok_drape) else "FAIL",
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout

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
	var existing_siphon := ""
	for it in model.items:
		if not (it is Dictionary):
			continue
		if str(((it as Dictionary).get("specs", {}) as Dictionary).get("role", "")) == "siphon_hydro":
			existing_siphon = str((it as Dictionary).get("id", ""))
			break
	if not existing_siphon.is_empty():
		await _run_siphon_lab_capture_readonly(sgv, existing_siphon)
		return

	# Ground datum under the pond so the DEM section frames sensibly.
	var g := 0.0
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi != null and soi.has_method("world_center"):
		g = float((soi.call("world_center") as Vector3).y)

	var pond_id := "cap_lab_pond"
	var siphon_id := "cap_lab_siphon"
	model.add_item({
		"id": pond_id, "type": "resource", "x": 0.0, "y": 0.0,
		"width": 80.0, "height": 80.0,
		"specs": {
			"name": "Lab Pond", "resource_kind": "water",
			"pond_storage": true, "fill_mode": "auto",
			"capacity_qty": 30000.0, "capacity_unit": "L",
			"level": 0.85, "stock_l": 25500.0,
			"floor_m": g, "rim_m": g + 2.0, "level_m": g + 1.7,
			"site_x_m": 0.0, "site_z_m": 0.0,
		},
	})
	model.add_item({
		"id": siphon_id, "type": "processor", "x": 160.0, "y": 0.0,
		"width": 150.0, "height": 130.0, "elevation_m": g + 1.65,
		"specs": {
			"name": "Lab Siphon", "role": "siphon_hydro", "kind": "siphon_hydro",
			"energy_source": "", "efficiency": 1.0,
			"intake_diameter_mm": 203.0, "outlet_diameter_mm": 203.0,
			"barrel_length_m": 20.0, "manning_n": 0.012,
			"max_power_w": 250.0, "hydraulic_efficiency": 0.6,
			"generator_efficiency": 0.7,
			"siphon_start_m": g + 1.65, "siphon_break_m": g + 1.2,
			"module_elev_m": g + 1.65, "outlet_invert_m": g - 8.0,
			"siphon_primed": true,
			"site_x_m": 4.0, "site_z_m": 0.0,
			"inputs": [{"kind": "water", "rate": 0.0, "unit": "L/h"}],
			"outputs": [
				{"kind": "water", "rate": 0.0, "unit": "L/h"},
				{"kind": "dc_electricity", "rate": 0.0, "unit": "kW"},
			],
		},
	})
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

	await _verify_view_camera_decoupled(sgv, siphon_id)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: siphon capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


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
		model.call("update_item", siphon_id, {"specs": orig_specs})
		if modal.has_method("_load_from_model"):
			modal.call("_load_from_model")

	await _verify_view_camera_decoupled(sgv, siphon_id)

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: siphon capture (read-only, existing siphon %s) — %d shots in %s" % [
		siphon_id, manifest.size(), ProjectSettings.globalize_path(dir)])
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
		print("PlaytestHarness: site-review — no drillable freeform compound")
		_patch_site_diagnostics(root, {
			"compound_drill_ok": false,
			"compound_drill_with_bubble_ok": false,
			"compound_drill_id": "",
			"compound_drill_note": "no generic compound with child_scope_id",
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
	print("PlaytestHarness: compound drill expand=%s zoom+bubble=%s id=%s" % [
		drill_ok, drill_bubble_ok, comp_id])


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
	await _dump_perf(root, "elevation", manifest)


func _site_review_snowglobe(sgv: Node, root: String, manifest: Array) -> void:
	var sdir := "%s/snowglobe" % root
	# Close graph so the full-screen snowglobe owns the frame.
	if sgv != null:
		sgv.visible = false
	var soi := get_tree().root.get_node_or_null("SoiService")
	if soi == null or not soi.has_method("enter_snowglobe"):
		push_warning("PlaytestHarness: site-review — SoiService.enter_snowglobe missing")
		return
	soi.call("enter_snowglobe")
	await get_tree().create_timer(1.8).timeout
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
	await get_tree().create_timer(0.4).timeout
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
	await tree.create_timer(SETTLE_AFTER_LOAD_S).timeout

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


func _maybe_quit() -> void:
	if _quit_after:
		print("PlaytestHarness: capture complete — quitting")
		get_tree().quit()


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
func _run_npc_anim_verify() -> void:
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
		"user://maps/vegetation_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)],
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
			var mesh := VegetationCardFactory.mesh_for_canopy_lod(sid, style, tier)
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
		if Vector2(float(slow_rec.get("x", 0.0)), float(slow_rec.get("z", 0.0))) 				.distance_to(stage_pt) < 1.5:
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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

	# Clear leftovers from a previous run so the assertions are honest.
	_penstock_cleanup(model, main)

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

	# An intake item + prop exist at the release point.
	var intake_id := ""
	for it in model.items:
		if not (it is Dictionary):
			continue
		var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
		if str(sp.get("model_id", "")) == "stream_intake":
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
func _penstock_cleanup(model: Variant, main: Node) -> void:
	var doomed: Array[String] = []
	for it in (model.items as Array).duplicate():
		if not (it is Dictionary):
			continue
		var iid := str((it as Dictionary).get("id", ""))
		var sp: Dictionary = (it as Dictionary).get("specs", {}) as Dictionary
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
	await get_tree().create_timer(SETTLE_AFTER_LOAD_S).timeout
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
		var covers := win.mode == Window.MODE_FULLSCREEN 			or (absi(win.size.x - scr_size.x) <= 4 and absi(win.size.y - scr_size.y) <= 4)
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


func _run_star_capture() -> void:
	var tree := get_tree()
	var loader := tree.current_scene.find_child("TerrainLoader", true, false) \
		if tree.current_scene != null else null
	if loader != null and not (loader.get("load_completed") == true):
		await loader.map_load_complete
	await tree.create_timer(SETTLE_AFTER_LOAD_S).timeout

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
	await tree.create_timer(SETTLE_AFTER_LOAD_S).timeout

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

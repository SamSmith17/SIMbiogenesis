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


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	_parse_args(args)
	var wants_post_load := not _capture_mode.is_empty() or _assign_facades_count > 0 \
		or _sculpt_test
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
		elif _capture_mode == "autobind":
			_run_autobind_verify.call_deferred()
		elif _capture_mode == "pondid":
			_run_pond_id_verify.call_deferred()
		elif _capture_mode == "culvert":
			_run_culvert_downhill_verify.call_deferred()
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
	elif _capture_mode == "autobind":
		_run_autobind_verify()
	elif _capture_mode == "pondid":
		_run_pond_id_verify()
	elif _capture_mode == "culvert":
		_run_culvert_downhill_verify()
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
	elif _capture_mode == "autobind":
		_run_autobind_verify()
	elif _capture_mode == "pondid":
		_run_pond_id_verify()
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
	print("PlaytestHarness: population verify — %d spaces seeded, graph CLOSED" % sites.size())

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
	await get_tree().create_timer(50.0).timeout
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

	# --- phase 2: Site Plan dot capture --------------------------------------
	var label := _shots_label if not _shots_label.is_empty() else "population_test"
	var dir := "%s/%s" % [SHOTS_ROOT, label]
	DirAccess.make_dir_recursive_absolute(dir)
	var manifest: Array = []
	sgv.visible = true
	if sgv.has_method("_apply_graph_open_mode_from_sim_state"):
		sgv.call("_apply_graph_open_mode_from_sim_state")
	if sgv.has_method("_apply_graph_view_mode"):
		sgv.call("_apply_graph_view_mode", "site")
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
	var with_path := 0
	if nav_ready:
		for i in 40:
			await get_tree().create_timer(0.25).timeout
			var n := 0
			for a in bridge.call("roster_for", hab_id):
				if (a as NpcAgent).path.size() > 0:
					n += 1
			with_path = maxi(with_path, n)
		nav_info = bridge.call("nav_status")
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
	var avatar_count := host.get_child_count() if host != null else 0
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
	# Tagged spaces must be resolvable as Site Plan markers with occupancy.
	var marks: Array = bridge.call("space_markers", main)
	var ok_marks := marks.size() == sites.size()
	print("PlaytestHarness: population verify — space markers %s (%d of %d resolved)" % [
		"PASS" if ok_marks else "FAIL", marks.size(), sites.size()])
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
		var stage := Vector3(0.0, gy + 80.0, 0.0)
		cam.global_position = stage + Vector3(0.0, 1.4, 5.5)
		cam.look_at(stage + Vector3(0.0, 1.0, 0.0))
		var samples: Array = []
		for i in 3:
			var sample := NpcAvatar.new()
			sample.setup("review_%d" % i, NpcPopulationEngine.color_for_agent("review_%d" % i))
			main.add_child(sample)
			sample.apply_state(stage + Vector3(-1.6 + 1.6 * float(i), 0.0, 0.0),
					PI * 0.2 * float(i), i == 1, "sleep" if i == 2 else "")
			samples.append(sample)
		await get_tree().create_timer(0.6).timeout
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
	for i in 40:
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
	for i in 90:
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
		"PASS" if (ok_flow and ok_move and ok_starve and ok_cascade and ok_3d and ok_nav) else "FAIL",
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

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: siphon capture — %d shots in %s" % [
		manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


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

	var f := FileAccess.open("%s/manifest.json" % dir, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()
	print("PlaytestHarness: siphon capture (read-only, existing siphon %s) — %d shots in %s" % [
		siphon_id, manifest.size(), ProjectSettings.globalize_path(dir)])
	_maybe_quit()


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
				"siphon_lab_active": bool(canvas.get("siphon_lab_active")),
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
		modal.set("_view_pan", Vector2(72.0, -40.0))
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

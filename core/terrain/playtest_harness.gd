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
##   --map-lat=<f> --map-lon=<f> [--half-extent=<m>]  raw coordinates instead of a .tres
##   --capture=orbit|street|hero|both  automated capture after the map loads.
##                              "hero" = one close eye-level shot per building
##                              currently carrying a style override (facade
##                              texture review) — combine with --assign-facades
##   --shots-dir=<label>        subfolder under user://screenshots/ (default timestamp)
##   --time=<hour>              sim clock hour for the shoot (default 10.0, paused)
##   --assign-facades=<N>       assign every user://maps/facade_textures/*.png
##                              round-robin to the N nearest house-sized
##                              buildings to spawn, via apply_building_style
##                              (same path the modal's Facade tex dropdown uses)
##   --quit-after-capture       exit the process once the capture set is written
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
var _capture_mode := ""
var _shots_label := ""
var _quit_after := false
var _capture_hour := 10.0
var _assign_facades_count := 0
var _active := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		return
	_parse_args(args)
	var wants_post_load := not _capture_mode.is_empty() or _assign_facades_count > 0
	if not is_nan(_launch_lat) and not is_nan(_launch_lon):
		_active = true
		_launch_map.call_deferred()
	elif wants_post_load:
		# No explicit map to launch: whatever scene boots (e.g. default map)
		# gets the post-load actions (capture / facade assignment).
		_active = true
		_await_and_run.call_deferred()


func _parse_args(args: PackedStringArray) -> void:
	var map_file := ""
	for a in args:
		if a.begins_with("--user-map="):
			map_file = a.get_slice("=", 1)
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
		elif a == "--quit-after-capture":
			_quit_after = true
	if not map_file.is_empty():
		_load_map_definition(map_file)


func _load_map_definition(map_file: String) -> void:
	var path := map_file
	if not path.begins_with("user://") and not path.begins_with("res://"):
		path = "user://maps/%s" % map_file
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
	if not _capture_mode.is_empty() or _assign_facades_count > 0:
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

extends SceneTree

## Full-scene boot self-test at Mount St. Helens. Sets MapContext, loads
## generated_location.tscn, waits for TerrainLoader to finish, validates player
## grounding and detail patch collision policy.
## Run:
##   godot --headless --path . --script core/terrain/site_boot_selftest.gd

const LAT := 46.2445
const LON := -121.0722
const LABEL := "Mount St. Helens"
const MAX_WAIT_S := 180.0

var _failures := 0
var _checks := 0
var _elapsed := 0.0
var _done := false
var _built_at := -1.0
var _boot_started := false


func _initialize() -> void:
	print("SITE BOOT SELFTEST  %s  (%.4f, %.4f)" % [LABEL, LAT, LON])


func _process(delta: float) -> bool:
	if _done:
		return true
	_elapsed += delta
	if not _boot_started:
		var ctx := get_root().get_node_or_null("MapContext")
		if ctx == null:
			if _elapsed >= 5.0:
				_finish("MapContext autoload missing")
			return false
		ctx.set_pending(LAT, LON, LABEL, 0.0)
		change_scene_to_file("res://scenes/maps/generated_location.tscn")
		_boot_started = true
		return false
	var main := current_scene
	if main == null:
		if _elapsed >= MAX_WAIT_S:
			_finish("scene never loaded")
		return false
	var loader := main.get_node_or_null("TerrainLoader")
	if loader == null:
		if _elapsed >= MAX_WAIT_S:
			_finish("TerrainLoader missing")
		return false
	if loader.get("_built") != true:
		if _elapsed >= MAX_WAIT_S:
			_finish("terrain never built (timeout %.0fs)" % _elapsed)
		return false
	if _built_at < 0.0:
		_built_at = _elapsed
		print("  terrain built at %.1f s — waiting for background layers…" % _built_at)
	# Allow background fetch + auto-veg after walkable gate.
	if _elapsed - _built_at < 45.0:
		return false
	_validate(main, loader)
	_done = true
	if _failures == 0:
		print("SITE BOOT SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("SITE BOOT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)
	return true
	return true


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _validate(main: Node, loader: Node) -> void:
	var terrain := main.get_node_or_null("Terrain")
	_check("Terrain node exists", terrain != null)
	if terrain != null:
		_check("DetailGround exists", terrain.get_node_or_null("DetailGround") != null)
		var has_detail := terrain.get_node_or_null("DetailGround") != null
		var detail_col := terrain.get_node_or_null("DetailCollision")
		_check("DetailCollision when hi-res", (detail_col != null) if has_detail else (detail_col == null))
		_check("TerrainCollision exists", terrain.get_node_or_null("TerrainCollision") != null)

	var player := main.get_node_or_null("Player") as CharacterBody3D
	if player != null and loader.has_method("_ground_height_at"):
		var gy: float = loader.call("_ground_height_at", player.global_position.x, player.global_position.z)
		var gap := player.global_position.y - gy
		print("  player y=%.2f, ground=%.2f, gap=%.2f m" % [player.global_position.y, gy, gap])
		_check("player above ground", gap >= 0.5 and gap < 50.0, "gap %.2f m" % gap)

	if loader.has_method("get_terrain_options"):
		var opts: Dictionary = loader.call("get_terrain_options")
		_check("terrain options readable", not opts.is_empty())

	var auto_veg: Object = loader.get("_auto_veg_layer") as Object
	if auto_veg != null:
		var hero: Array = auto_veg.get("hero") as Array
		var total: int = int(auto_veg.call("total_bulk")) + hero.size()
		var near_200: int = auto_veg.call("count_within_radius", 0.0, 0.0, 200.0)
		var nearest: float = auto_veg.call("nearest_distance", 0.0, 0.0)
		print("  auto-veg: %d instances; %d within 200 m; nearest %.0f m" % [
			total, near_200, nearest])
		_check("auto-veg generated", total > 100, "got %d" % total)

	print("  boot elapsed %.1f s" % _elapsed)


func _finish(reason: String) -> void:
	_done = true
	_check("boot completed", false, reason)
	print("SITE BOOT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	quit(1)

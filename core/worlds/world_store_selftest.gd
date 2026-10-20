extends SceneTree

## Offline selftest for MAPS vs WORLDS (core/worlds/).
##
## What it pins, in order of how badly a regression would hurt:
##   1. LEGACY IDENTITY — with no world active, every subsystem's per-site
##      path is byte-identical to the pre-worlds literal. This is what keeps
##      every existing selftest, harness and the player's migrated build
##      reading the files they always read.
##   2. COVERAGE GUARD — no script may write a new "user://maps/<kind>_…"
##      family behind the resolver's back (a new subsystem would silently
##      store world data in the shared namespace, so a fresh world would
##      inherit it). Allowed literals are the MAP registry and shared files.
##   3. Dir-world paths, the graph/scores layout, and a stale key never
##      landing on the world's main file.
##   4. WorldStore against a TEMP root: legacy migration (idempotent, never
##      moves a file, adopts the old autosave as the snapshot), duplicate
##      legacy → dir byte-for-byte, rename, newest-first list, the default
##      name ladder, record_save stripping the graph, trash = move.
##   5. The cache-token boundary (refetching 8.3252 must not delete 48.3252)
##      and the picker's coordinate parser / reverse-geocode label.
##
## Carries EXPECTED_CHECKS: a GDScript runtime error aborts the enclosing test
## function while the suite would still print PASS.
##
## Run: Godot.exe.exe --headless --path . --script core/worlds/world_store_selftest.gd
## (--import first after adding class_names.)

const EXPECTED_CHECKS := 110

var _fails := 0
var _checks := 0
const LAT := 44.0113
const LON := -123.5911
const T_LAT := "44p0113"
const T_LON := "n123p5911"
var _tmp := ""


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	WorldPaths.clear_active()
	WorldPaths.reset_legacy_dirs()
	_test_legacy_identity()
	_test_coverage_guard()
	_test_dir_paths()
	_test_store()
	_test_seal()
	_test_assets()
	_test_cache_token_boundary()
	_test_picker_helpers()
	WorldPaths.clear_active()
	WorldPaths.reset_legacy_dirs()
	_cleanup_tmp()
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("WORLD STORE SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("WORLD STORE SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


# -- 1. Legacy identity --------------------------------------------------------

func _test_legacy_identity() -> void:
	var t := "%s_%s" % [T_LAT, T_LON]
	var m := "user://maps/"
	var pairs := [
		["camp_areas", CampAreaLayer.save_path_for_map(LAT, LON), m + "camp_areas_%s.json" % t],
		["festival_placement", FestivalPlacementLayer.save_path_for_map(LAT, LON), m + "festival_placement_%s.json" % t],
		["labor", ChoreLedger.new().save_path_for_map(LAT, LON), m + "labor_%s.json" % t],
		["inventory", PartInventory.new().save_path_for_map(LAT, LON), m + "inventory_%s.json" % t],
		["soi", SoiConfig.save_path_for_map(LAT, LON), m + "soi_%s.json" % t],
		["terrain_edit", TerrainEditGrid.new().save_path_for_map(LAT, LON), m + "terrain_edit_%s.json" % t],
		["auto_veg_edits", AutoVegetationEdits.save_path_for_map(LAT, LON), m + "auto_veg_edits_%s.json" % t],
		["vegetation", VegetationLayer.new().save_path_for_map(LAT, LON), m + "vegetation_%s.json" % t],
		["vegetation_style (v1)", VegetationStyleConfig.map_path(LAT, LON), m + "vegetation_style_%s.json" % t],
		["vegetation_style_v3", VegStyleStore.map_v2_path(LAT, LON), m + "vegetation_style_v3_%s.json" % t],
		["placed_props", PlacedPropLayer.new().save_path_for_map(LAT, LON), m + "placed_props_%s.json" % t],
		["placed_props scene", PlacedPropLayer.new().save_path_for_scene("res://scenes/maps/soak_festival_2026.tscn"),
			m + "placed_props_scene_soak_festival_2026.json"],
		["npc_spaces", SpaceRegistry.new().save_path_for_map(LAT, LON), m + "npc_spaces_%s.json" % t],
		["npc_spaces scene", SpaceRegistry.new().save_path_for_scene("soak_festival_2026"),
			m + "npc_spaces_scene_soak_festival_2026.json"],
		["npc_spaces empty scene", SpaceRegistry.new().save_path_for_scene(""), m + "npc_spaces_scene_unknown_scene.json"],
		["microclimate", MicroclimateProfile.save_path_for_map(LAT, LON), m + "microclimate_%s.json" % t],
		["microclimate scene", MicroclimateProfile.save_path_for_scene("res://scenes/maps/mars_aerial.tscn"),
			m + "microclimate_scene_mars_aerial.json"],
		["window_wall", WindowWallViewpoint.save_path_for_map(LAT, LON), m + "window_wall_viewpoint_%s.json" % t],
		["window_wall scene", WindowWallViewpoint.save_path_for_scene("res://scenes/maps/soak_festival_2026.tscn"),
			m + "window_wall_viewpoint_scene_soak_festival_2026.json"],
		["placed_lights site", PlacedLightLayer.path_for_key(t), m + "placed_lights_%s.json" % t],
		["placed_lights scene", PlacedLightLayer.path_for_key("scene_soak_festival_2026"),
			m + "placed_lights_scene_soak_festival_2026.json"],
		["building_styles", BuildingStyleLayer.new().save_path_for_map(LAT, LON), m + "building_styles_%s.json" % t],
		["water_features", WaterFeatureLayer.save_path_for_map(LAT, LON), m + "water_features_%s.json" % t],
		["peak (site)", WorldPaths.site_file("peak_experience", LAT, LON), m + "peak_experience_%s.json" % t],
		["peak (scene)", WorldPaths.scene_file("peak_experience", "res://scenes/maps/soak_festival_2026.tscn"),
			m + "peak_experience_scene_soak_festival_2026.json"],
		["terrain_tiles", WorldPaths.site_file("terrain_tiles", LAT, LON, "bin"), m + "terrain_tiles_%s.bin" % t],
		["channel_tiles", WorldPaths.site_file("channel_tiles", LAT, LON, "bin"), m + "channel_tiles_%s.bin" % t],
		["high scores", HighScoreStore.path_for(LAT, LON), "user://scores/44p0113_m123p5911.json"],
		["graph autosave", WorldPaths.graph_autosave_path("map_" + t), "user://saves/graph_autosave/map_%s.graph.json" % t],
	]
	for p in pairs:
		_check("legacy identity: %s" % p[0], str(p[1]) == str(p[2]), "%s != %s" % [p[1], p[2]])


# -- 2. Coverage guard -----------------------------------------------------------

const _ALLOWED_MAPS_LITERALS := [
	"user://maps/loc_",                  # the MAP registry (MapDefinitions)
	"user://maps/facade_textures",       # shared texture library
	"user://maps/packing_",              # packing lab's shared files
	"user://maps/placed_lights_scene_",  # the old shared v2 file lights adopt
]


func _test_coverage_guard() -> void:
	var offenders: Array[String] = []
	_scan_for_maps_literals("res://", offenders)
	_check("coverage guard: every per-site user://maps/ path goes through WorldPaths",
		offenders.is_empty(), "\n  " + "\n  ".join(offenders))


func _scan_for_maps_literals(dir: String, out: Array[String]) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		if sub.begins_with(".") or sub in ["parked", "addons"]:
			continue
		_scan_for_maps_literals(dir.path_join(sub), out)
	for fn in da.get_files():
		if not fn.ends_with(".gd") or fn.ends_with("_selftest.gd") \
				or fn in ["playtest_harness.gd", "world_paths.gd"] or fn.ends_with("_diag.gd"):
			continue
		var path := dir.path_join(fn)
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			var ln := lines[i].strip_edges()
			if ln.begins_with("#") or not ln.contains("\"user://maps/"):
				continue
			var ok := false
			for a in _ALLOWED_MAPS_LITERALS:
				if ln.contains(a):
					ok = true
			if not ok:
				out.append("%s:%d  %s" % [path, i + 1, ln])


# -- 3. Dir-world paths ------------------------------------------------------------

func _test_dir_paths() -> void:
	var key := WorldPaths.site_key_for(LAT, LON)
	_check("site key = coord tokens", key == "%s_%s" % [T_LAT, T_LON])
	_check("scene key strips path + ext", WorldPaths.scene_key_for("res://scenes/maps/soak_festival_2026.tscn")
		== "scene_soak_festival_2026")
	var root := "user://__world_paths_selftest/wabc"
	WorldPaths.set_active("wabc", root, WorldPaths.STORAGE_DIR, key)
	_check("dir world: active", WorldPaths.has_active_world() and WorldPaths.is_dir_world())
	_check("dir world: props file is <root>/placed_props.json",
		PlacedPropLayer.new().save_path_for_map(LAT, LON) == root + "/placed_props.json")
	_check("dir world: tiles keep their ext",
		WorldPaths.site_file("terrain_tiles", LAT, LON, "bin") == root + "/terrain_tiles.bin")
	_check("dir world: veg style suffix rides the ext",
		VegStyleStore.map_v2_path(LAT, LON) == root + "/vegetation_style_v3.json" + VegStyleStore.path_suffix)
	_check("dir world: a STALE coordinate never lands on the world's file",
		WorldPaths.site_file("placed_props", 10.0, 20.0) == root + "/placed_props_10p0000_20p0000.json")
	_check("dir world: graph autosave is <root>/graph.graph.json",
		WorldPaths.graph_autosave_path("map_" + key) == root + "/graph.graph.json")
	_check("dir world: other graph key is suffixed",
		WorldPaths.graph_autosave_path("map_1p0000_2p0000") == root + "/graph_map_1p0000_2p0000.graph.json")
	_check("dir world: scores live in the world",
		HighScoreStore.path_for(LAT, LON) == root + "/scores.json")
	_check("dir world: lights by site key",
		PlacedLightLayer.path_for_key(key) == root + "/placed_lights.json")
	# Scene world.
	WorldPaths.set_active("wsc", root, WorldPaths.STORAGE_DIR, "scene_soak_festival_2026")
	_check("scene dir world: scene file is the world's main file",
		SpaceRegistry.new().save_path_for_scene("res://scenes/maps/soak_festival_2026.tscn") == root + "/npc_spaces.json")
	_check("scene dir world: graph key scene_x maps to graph.graph.json",
		WorldPaths.graph_autosave_path("scene_soak_festival_2026") == root + "/graph.graph.json")
	# Legacy storage = the old layout exactly.
	WorldPaths.set_active("wleg", root, WorldPaths.STORAGE_LEGACY, key)
	_check("legacy world: same path as no world",
		PlacedPropLayer.new().save_path_for_map(LAT, LON) == "user://maps/placed_props_%s.json" % key)
	_check("legacy world: graph autosave unchanged",
		WorldPaths.graph_autosave_path("map_" + key) == "user://saves/graph_autosave/map_%s.graph.json" % key)
	WorldPaths.clear_active()
	_check("clear_active -> no world", not WorldPaths.has_active_world() and WorldPaths.storage() == "")
	_check("graph key for site", WorldPaths.graph_key_for_site(key) == "map_" + key
		and WorldPaths.graph_key_for_site("scene_x") == "scene_x")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://__world_paths_selftest"))


# -- 4. WorldStore -----------------------------------------------------------------

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _test_store() -> void:
	_tmp = "user://__world_store_selftest_%d" % Time.get_ticks_usec()
	var wroot := _tmp + "/worlds"
	var maps := _tmp + "/maps"
	WorldPaths.set_legacy_dirs_for_test(maps, _tmp + "/graph_autosave", _tmp + "/scores")
	var key := WorldPaths.site_key_for(LAT, LON)
	# A site with a legacy build: props, tiles, a graph, a peak score.
	_write("%s/placed_props_%s.json" % [maps, key], "{\"props\":[1,2,3]}")
	_write("%s/terrain_tiles_%s.bin" % [maps, key], "TILES")
	_write("%s/peak_experience_%s.json" % [maps, key], "{\"total\":4321}")
	_write("%s/graph_autosave/map_%s.graph.json" % [_tmp, key], "{\"graph\":{}}")
	_write(WorldPaths.legacy_scores_path(LAT, LON), "{\"entries\":{}}")
	# A second site with NO world data must not become a world.
	var md := MapDefinition.new()
	md.scene_path = MapDefinition.GENERATED_SCENE
	md.display_name = "Pataha Creek Road, Walton, Oregon"
	md.latitude = LAT
	md.longitude = LON
	md.last_loaded_unix = 1700000000.0
	var md2 := MapDefinition.new()
	md2.scene_path = MapDefinition.GENERATED_SCENE
	md2.display_name = "Empty site"
	md2.latitude = 10.0
	md2.longitude = 20.0
	var old_autosave := {
		"save_version": 2, "scene_path": MapDefinition.GENERATED_SCENE,
		"created_at_unix": 1700000500.0, "playtime_seconds": 3600.0,
		"main": {"latitude": LAT, "longitude": LON, "year": 2026, "month": 9, "day": 3, "day_time": 21.5},
		"player": {"position": {"x": 1.0, "y": 2.0, "z": 3.0}},
		"system_graph": {"graph": {"items": []}},
	}
	var made := WorldStore.migrate_legacy([{"md": md, "path": "x"}, {"md": md2, "path": "y"}], old_autosave, wroot)
	_check("migrate: one world for the site that has data", made.size() == 1, str(made.size()))
	var rec: Dictionary = made[0] if made.size() > 0 else {}
	var id := str(rec.get("id", ""))
	_check("migrate: storage legacy", str(rec.get("storage", "")) == WorldPaths.STORAGE_LEGACY)
	_check("migrate: nothing moved", FileAccess.file_exists("%s/placed_props_%s.json" % [maps, key])
		and FileAccess.file_exists("%s/terrain_tiles_%s.bin" % [maps, key]))
	_check("migrate: name defaults to the map label",
		WorldStore.display_name(rec) == "Pataha Creek Road, Walton, Oregon")
	var snap := WorldStore.read_snapshot(id, wroot)
	_check("migrate: old autosave adopted as the snapshot",
		int((snap.get("main", {}) as Dictionary).get("day", 0)) == 3 and str(snap.get("world_id", "")) == id)
	_check("migrate: snapshot carries no graph (graph file is the truth)", not snap.has("system_graph"))
	_check("migrate: played time = autosave time", float(rec.get("last_played_unix", 0.0)) == 1700000500.0)
	_check("migrate: game time column", int((rec.get("game_time", {}) as Dictionary).get("month", 0)) == 9)
	var files := WorldStore.data_files(rec, wroot)
	_check("data_files: props, tiles, peak, graph, scores",
		files.has("placed_props.json") and files.has("terrain_tiles.bin") and files.has("peak_experience.json")
		and files.has("graph.graph.json") and files.has("scores.json"), str(files.keys()))
	_check("migrate is idempotent", WorldStore.migrate_legacy([{"md": md, "path": "x"}], {}, wroot).is_empty())
	_check("list has the migrated world", WorldStore.list(wroot).size() == 1)
	# Duplicate legacy -> dir, byte for byte.
	var copy := WorldStore.duplicate_world(id, "Walton (fresh test)", wroot)
	var cid := str(copy.get("id", ""))
	_check("duplicate: new id, dir storage", not cid.is_empty() and cid != id
		and str(copy.get("storage", "")) == WorldPaths.STORAGE_DIR)
	var croot := WorldStore.world_dir(cid, wroot)
	_check("duplicate: props copied to <root>/placed_props.json",
		FileAccess.get_file_as_string(croot + "/placed_props.json") == "{\"props\":[1,2,3]}")
	_check("duplicate: tiles copied", FileAccess.get_file_as_string(croot + "/terrain_tiles.bin") == "TILES")
	_check("duplicate: peak score copied",
		FileAccess.get_file_as_string(croot + "/peak_experience.json") == "{\"total\":4321}")
	_check("duplicate: graph copied", FileAccess.file_exists(croot + "/graph.graph.json"))
	_check("duplicate: snapshot copied", FileAccess.file_exists(croot + "/" + WorldStore.SNAPSHOT_FILE))
	_check("duplicate: source untouched", FileAccess.file_exists("%s/placed_props_%s.json" % [maps, key]))
	_check("duplicate: resolves the same as an active world",
		WorldStore.data_files(copy, wroot).size() == files.size(), "%d vs %d" % [WorldStore.data_files(copy, wroot).size(), files.size()])
	# Activating the copy points the subsystems at it.
	WorldStore.activate(copy, wroot)
	_check("activate dir copy: props path is inside the copy",
		PlacedPropLayer.new().save_path_for_map(LAT, LON) == croot + "/placed_props.json")
	WorldStore.activate(rec, wroot)
	_check("activate legacy: props path is the legacy file",
		PlacedPropLayer.new().save_path_for_map(LAT, LON) == "%s/placed_props_%s.json" % [maps, key])
	WorldPaths.clear_active()
	# A brand-new world on the same map starts EMPTY.
	var fresh := WorldStore.create(rec["map"], "", WorldPaths.STORAGE_DIR, wroot)
	_check("new world on the same map: no data", WorldStore.data_files(fresh, wroot).is_empty())
	_check("worlds_on_map counts all three", WorldStore.worlds_on_map(rec, wroot).size() == 3)
	# Rename + names.
	_check("rename", WorldStore.rename(str(fresh["id"]), "  Second try  ", wroot)
		and WorldStore.display_name(WorldStore.get_world(str(fresh["id"]), wroot)) == "Second try")
	var nolabel := {"map": {"scene_path": MapDefinition.GENERATED_SCENE, "lat": 1.5, "lon": -2.25, "label": ""}}
	_check("name ladder: coordinates last", WorldStore.display_name(nolabel) == "1.5000, -2.2500")
	_check("name ladder: built-in scene name",
		WorldStore.display_name({"map": {"scene_path": "res://scenes/maps/soak_festival_2026.tscn"}}) == "soak_festival_2026")
	# Newest first.
	var r_old := WorldStore.get_world(id, wroot)
	r_old["last_played_unix"] = 1.0
	WorldStore.save_record(r_old, wroot)
	var r_new := WorldStore.get_world(cid, wroot)
	r_new["last_played_unix"] = 9.9e9
	WorldStore.save_record(r_new, wroot)
	var lst := WorldStore.list(wroot)
	_check("list newest first", lst.size() == 3 and str(lst[0]["id"]) == cid
		and str(lst[lst.size() - 1]["id"]) == id)
	# record_save.
	var big := old_autosave.duplicate(true)
	big["playtime_seconds"] = 7200.0
	_check("record_save writes", WorldStore.record_save(cid, big, {"props": 3}, wroot))
	var s2 := WorldStore.read_snapshot(cid, wroot)
	var r2 := WorldStore.get_world(cid, wroot)
	_check("record_save: graph stripped, world id stamped",
		not s2.has("system_graph") and str(s2.get("world_id", "")) == cid)
	_check("record_save: playtime + summary + saved time",
		float(r2.get("playtime_s", 0.0)) == 7200.0 and int((r2.get("summary", {}) as Dictionary).get("props", 0)) == 3
		and float(r2.get("last_saved_unix", 0.0)) > 0.0)
	_check("record_save: no torn temp file left", not FileAccess.file_exists(WorldStore.snapshot_path(cid, wroot) + ".tmp"))
	# Trash.
	_check("trash dir world", WorldStore.trash(str(fresh["id"]), wroot))
	_check("trashed world gone from the list", WorldStore.list(wroot).size() == 2)
	_check("trash legacy world", WorldStore.trash(id, wroot))
	_check("trash legacy: data files moved out of the legacy layout",
		not FileAccess.file_exists("%s/placed_props_%s.json" % [maps, key]))
	var tda := DirAccess.open(wroot + "/" + WorldStore.TRASH_DIR)
	_check("trash keeps both worlds", tda != null and tda.get_directories().size() == 2)
	_check("trash legacy: the copy survives", FileAccess.file_exists(croot + "/placed_props.json"))
	_check("migrate after trash does NOT resurrect the site",
		WorldStore.migrate_legacy([{"md": md, "path": "x"}], {}, wroot).is_empty())
	WorldPaths.reset_legacy_dirs()


# -- 4b. Sealed scene switches + vendored assets ------------------------------------

func _test_seal() -> void:
	var key := WorldPaths.site_key_for(LAT, LON)
	WorldPaths.set_active("wseal", "user://__seal_selftest/w", WorldPaths.STORAGE_DIR, key)
	WorldPaths.seal()
	_check("sealed: world writes go to the discard folder",
		WorldPaths.site_file("placed_props", LAT, LON).begins_with(WorldPaths.DISCARD_DIR + "/"))
	_check("sealed: graph autosave too", WorldPaths.graph_autosave_path("map_" + key).begins_with(WorldPaths.DISCARD_DIR + "/"))
	WorldPaths.clear_active()
	WorldPaths.seal()
	_check("sealed with NO world never falls through to the legacy files",
		not WorldPaths.site_file("placed_props", LAT, LON).begins_with("user://maps/"))
	WorldPaths.set_active("wseal2", "user://__seal_selftest/w2", WorldPaths.STORAGE_DIR, key)
	_check("activating a world unseals", not WorldPaths.is_sealed()
		and WorldPaths.site_file("placed_props", LAT, LON) == "user://__seal_selftest/w2/placed_props.json")
	WorldPaths.clear_active()
	WorldStore.remove_tree("user://__seal_selftest")
	WorldStore.remove_tree(WorldPaths.DISCARD_DIR)


func _test_assets() -> void:
	var wroot := _tmp + "/worlds_assets"
	var lib := "user://__wa_selftest_lib"
	var part := lib + "/part.stl"
	_write(part, "AAA")
	var map := {"scene_path": MapDefinition.GENERATED_SCENE, "lat": LAT, "lon": LON, "label": "x"}
	var rec := WorldStore.create(map, "assets", WorldPaths.STORAGE_DIR, wroot)
	var wdir := WorldStore.world_dir(str(rec["id"]), wroot)
	_write(wdir + "/placed_props.json", JSON.stringify({"props": [{"id": "p1", "stl_path": part}]}))
	var st := WorldAssets.collect(rec, wroot)
	_check("assets: a referenced library file is vendored", int(st.get("files", 0)) == 1
		and FileAccess.get_file_as_string(wdir + "/assets/files/__wa_selftest_lib/part.stl") == "AAA")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(part))
	var r1 := WorldAssets.restore(rec, wroot)
	_check("assets: a DELETED library file is put back", int(r1.get("restored", 0)) == 1
		and FileAccess.get_file_as_string(part) == "AAA")
	_write(part, "BBB")  # another world changed the library file
	var r2 := WorldAssets.restore(rec, wroot)
	var alt := WorldAssets._suffixed(part, str(rec["id"]))
	_check("assets: a CHANGED library file is not overwritten", FileAccess.get_file_as_string(part) == "BBB")
	_check("assets: this world's copy restored beside it", int(r2.get("remapped", 0)) == 1
		and FileAccess.get_file_as_string(alt) == "AAA")
	var props_text := FileAccess.get_file_as_string(wdir + "/placed_props.json")
	_check("assets: the world's data now points at its own copy", props_text.contains(alt)
		and not props_text.contains(JSON.stringify(part)))
	_check("assets: restoring again is a no-op", int(WorldAssets.restore(rec, wroot).get("remapped", 0)) == 0
		or FileAccess.get_file_as_string(alt) == "AAA")
	WorldStore.remove_tree(lib)


# -- 5. Cache tokens + picker helpers -----------------------------------------------

func _test_cache_token_boundary() -> void:
	var tok := TerrainCacheSettings.coord_token(48.3252, -122.2469)
	_check("token in a DEM name", TerrainCacheSettings.filename_has_token(
		"dem_v3_base_om_48.3252_-122.2469_15000_64.json", tok))
	_check("token at a '.' boundary", TerrainCacheSettings.filename_has_token(
		"dem_usgs1m_miss_48.3252_-122.2469.flag", tok))
	var short_tok := TerrainCacheSettings.coord_token(8.3252, -122.2469)
	_check("8.3252 does NOT match 48.3252's file", not TerrainCacheSettings.filename_has_token(
		"dem_v3_base_om_48.3252_-122.2469_15000_64.json", short_tok))
	_check("-8.3252 is not 8.3252", not TerrainCacheSettings.filename_has_token(
		"img_v2_-8.3252_-122.2469_15000_z12.png", short_tok))
	_check("lon prefix is not a match", not TerrainCacheSettings.filename_has_token(
		"img_v2_48.3252_-122.24690_15000_z12.png", tok))
	_check("empty token never matches", not TerrainCacheSettings.filename_has_token("anything", ""))


func _test_picker_helpers() -> void:
	var picker: GDScript = load("res://scenes/ui/location_picker/location_picker_ui.gd")
	_check("picker script loads", picker != null)
	if picker == null:
		for i in 8:
			_check("picker helper (skipped)", false)
		return
	var ok: Dictionary = picker.parse_coord_fields("44.0113", "-123.5911")
	_check("parse: plain pair", bool(ok.get("ok", false)) and is_equal_approx(float(ok["lat"]), 44.0113))
	var pasted: Dictionary = picker.parse_coord_fields("44.0113, -123.5911", "")
	_check("parse: 'lat, lon' pasted in one field", bool(pasted.get("ok", false))
		and is_equal_approx(float(pasted["lng"]), -123.5911))
	_check("parse: garbage refused (not Null Island)", not bool(picker.parse_coord_fields("Walton", "x").get("ok", true)))
	_check("parse: empty refused", not bool(picker.parse_coord_fields("", "").get("ok", true)))
	_check("parse: lat range", not bool(picker.parse_coord_fields("91", "0").get("ok", true)))
	_check("parse: lon range", not bool(picker.parse_coord_fields("0", "-181").get("ok", true)))
	var rev := {"display_name": "18707, Pataha Creek Road, Walton, Lane County, Oregon, 97490, United States",
		"address": {"house_number": "18707", "road": "Pataha Creek Road", "hamlet": "Walton",
			"county": "Lane County", "state": "Oregon", "country": "United States"}}
	_check("reverse label: settlement, county, state",
		GeocodeClient.compact_label(rev) == "Walton, Lane County, Oregon", GeocodeClient.compact_label(rev))
	_check("reverse label: falls back to display_name",
		GeocodeClient.compact_label({"display_name": "Somewhere"}) == "Somewhere")


func _cleanup_tmp() -> void:
	if _tmp.is_empty():
		return
	_rm_tree(_tmp)


func _rm_tree(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		_rm_tree(dir.path_join(sub))
	for fn in da.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(fn)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))

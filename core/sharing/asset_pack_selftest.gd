extends SceneTree

## Offline selftest for asset packs (core/sharing/).
##
## Everything runs against TEMP roots under user://__asset_pack_selftest_*:
## a fake "sender" user folder (two worlds — one in DIR storage, one LEGACY —
## map caches for two sites, libraries, settings and a set of SECRETS each
## carrying a sentinel string), a fake project folder of gitignored art (plus
## a script hidden inside it), and an empty "friend" user + project folder.
##
## What it pins, most important first:
##   1. No secret ever reaches a pack: every part's raw bytes are searched
##      for each sentinel. No code either, even inside an art folder.
##   2. The reader refuses unsafe packs whole: zip-slip, absolute paths,
##      code, text resources / raw .cfg as user data, unlisted entries, a
##      missing part.
##   3. Round trip: what the friend gets is byte-identical world data in a
##      NEW world (DIR layout, a legacy world included), the map cache, the
##      libraries, .cfg values re-encoded faithfully, art + .import sidecars.
##   4. Never at the friend's expense: a second import is another new world
##      with a "(from …)" name, a differing library file is kept both ways,
##      settings are opt-in and backed up, damaged files are reported.
##   5. The pieces: the format rules, the prefs codec, site matching at each
##      cache's own precision, multi-part splitting.
##
## Carries EXPECTED_CHECKS: a GDScript runtime error aborts the enclosing test
## function while the suite would still print PASS.
##
## Run: Godot.exe.exe --headless --path . --script core/sharing/asset_pack_selftest.gd
## (--import first after adding class_names.)

const EXPECTED_CHECKS := 116

const LAT := 44.0113
const LON := -123.5911
const LAT2 := 48.3252
const LON2 := -122.2469
const SENTINELS := ["SECRET_OPENTOPO_9f3", "SECRET_HA_TOKEN_77a", "SECRET_REFRESH_51c",
	"SECRET_WEBHOOK_e02", "SECRET_MP_NAME_4b1", "SECRET_LOC_1d9", "SECRET_SCAD_EXE_aa0"]

var _fails := 0
var _checks := 0
var _tmp := ""


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	WorldPaths.clear_active()
	_tmp = "user://__asset_pack_selftest_%d" % Time.get_ticks_usec()
	_test_format()
	_test_prefs_codec()
	_test_site_matching()
	_seed_sender()
	_test_catalog_and_roundtrip()
	_test_reader_refusals()
	WorldPaths.reset_legacy_dirs()
	WorldPaths.clear_active()
	_rm_tree(_tmp)
	if _checks != EXPECTED_CHECKS:
		_fails += 1
		push_error("FAIL: ran %d checks, expected %d (a runtime error aborted a test?)" % [_checks, EXPECTED_CHECKS])
	if _fails == 0:
		print("ASSET PACK SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("ASSET PACK SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


# -- 5. Format rules ------------------------------------------------------------------

func _test_format() -> void:
	var F := AssetPackFormat
	_check("entry: manifest", F.entry_allowed("simpack.json"))
	_check("entry: world json", F.entry_allowed("worlds/w1/placed_props.json"))
	_check("entry: world assets glb", F.entry_allowed("worlds/w1/assets/files/models/m.glb"))
	_check("entry: zip-slip refused", not F.entry_allowed("worlds/../../evil.json"))
	_check("entry: absolute refused", not F.entry_allowed("/etc/passwd"))
	_check("entry: drive refused", not F.entry_allowed("C:/x.json"))
	_check("entry: script refused in art", not F.entry_allowed("project/Imported Models/x.gd"))
	_check("entry: tres refused as user data", not F.entry_allowed("worlds/w1/evil.tres"))
	_check("entry: raw cfg refused as user data", not F.entry_allowed("library/resource_kinds.cfg"))
	_check("entry: cfgjson library ok", F.entry_allowed("library/resource_kinds.cfgjson"))
	_check("entry: secret cfgjson refused", not F.entry_allowed("library/terrain_config.cfgjson"))
	_check("entry: secret setting refused", not F.entry_allowed("settings/ha_connection.cfgjson"))
	_check("entry: shareable setting ok", F.entry_allowed("settings/npc_display.cfgjson"))
	_check("entry: art glb ok", F.entry_allowed("project/Imported Models/NPC/Walking.fbx"))
	_check("entry: art .import ok", F.entry_allowed("project/Imported Models/NPC/Walking.fbx.import"))
	_check("entry: art root blob ok", F.entry_allowed("project/Mars 2026 New.glb"))
	_check("entry: non-art project file refused", not F.entry_allowed("project/core/terrain/x.png"))
	_check("entry: mapcache outside caches refused", not F.entry_allowed("mapcache/models/x.glb"))
	_check("entry: communities refused", not F.entry_allowed("library/communities/1.json"))
	_check("entry: tools exe refused", not F.entry_allowed("library/tools/openscad/openscad.exe"))
	_check("part path 1", F.part_path("C:/a/x.simpack.zip", 1) == "C:/a/x.simpack.zip")
	_check("part path 3", F.part_path("C:/a/x.simpack.zip", 3) == "C:/a/x.simpack.003.zip",
		F.part_path("C:/a/x.simpack.zip", 3))
	_check("base part from part 2", AssetPackReader.base_part("C:/a/x.simpack.002.zip") == "C:/a/x.simpack.zip")
	_check("safezip target escape", SafeZip.target_under("C:/root", "a/../../b").is_empty())
	_check("safezip target ok", SafeZip.target_under("C:/root", "a/b.json") == "C:/root/a/b.json")


# -- 5. Prefs codec ---------------------------------------------------------------------

func _test_prefs_codec() -> void:
	var cf := ConfigFile.new()
	cf.set_value("a", "i", 7)
	cf.set_value("a", "f", 0.25)
	cf.set_value("a", "whole_f", 2.0)
	cf.set_value("a", "s", "hello")
	cf.set_value("a", "c", Color(0.1, 0.2, 0.3, 0.4))
	cf.set_value("a", "v", Vector2(3, 4))
	cf.set_value("a", "psa", PackedStringArray(["x", "y"]))
	cf.set_value("a", "nested", {"k": [1, 2.5, "z"]})
	cf.set_value("a", "abs_path", "C:/Users/someone/Pictures/stars.png")
	cf.set_value("b", "obj", RefCounted.new())
	var txt := JSON.stringify(AssetPackPrefs.encode_config(cf))
	var back := AssetPackPrefs.decode_text(txt)
	_check("prefs decode ok", back != null)
	if back == null:
		return
	_check("prefs int stays int", typeof(back.get_value("a", "i")) == TYPE_INT and int(back.get_value("a", "i")) == 7)
	_check("prefs float", is_equal_approx(float(back.get_value("a", "f")), 0.25))
	_check("prefs whole float stays float", typeof(back.get_value("a", "whole_f")) == TYPE_FLOAT)
	_check("prefs string", str(back.get_value("a", "s")) == "hello")
	_check("prefs color", (back.get_value("a", "c") as Color).is_equal_approx(Color(0.1, 0.2, 0.3, 0.4)))
	_check("prefs vector2", back.get_value("a", "v") == Vector2(3, 4))
	_check("prefs packed strings", back.get_value("a", "psa") == PackedStringArray(["x", "y"]))
	var nested: Variant = back.get_value("a", "nested")
	_check("prefs nested", nested is Dictionary and int((nested as Dictionary)["k"][0]) == 1
		and typeof((nested as Dictionary)["k"][0]) == TYPE_INT)
	_check("prefs absolute path dropped", not back.has_section_key("a", "abs_path"))
	_check("prefs object dropped", not back.has_section("b"))
	_check("prefs decode refuses Object tag",
		AssetPackPrefs.decode_text('{"a": {"x": {"__t": "Object", "v": []}}}') == null)
	_check("prefs decode refuses non-dict", AssetPackPrefs.decode_text("[1, 2]") == null)


# -- 5. Site matching -----------------------------------------------------------------------

func _test_site_matching() -> void:
	_check("site 4dp", AssetPackCatalog.file_names_site("dem_v2_base_openmeteo_44.0113_-123.5911_15000_16.json", LAT, LON))
	_check("site 5dp (AI patch)", AssetPackCatalog.file_names_site("ai_v1_44.01131_-123.59108_r50.png", LAT, LON))
	_check("site 2dp (climate)", AssetPackCatalog.file_names_site("climate_proj_1_44.01_-123.59.json", LAT, LON))
	_check("site 8.3252 is not 48.3252", not AssetPackCatalog.file_names_site("img_v1_8.3252_-122.2469_1500_z17.png", LAT2, LON2))
	_check("site neighbour not matched", not AssetPackCatalog.file_names_site("osm_v6_44.0114_-123.5911_1500.json", LAT, LON))


# -- Seeding ------------------------------------------------------------------------------------

func _u(rel: String) -> String:
	return "%s/sender/%s" % [_tmp, rel]


func _p(rel: String) -> String:
	return "%s/sender_project/%s" % [_tmp, rel]


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _seed_sender() -> void:
	var t1 := TerrainCacheSettings.coord_token(LAT, LON)
	var t2 := TerrainCacheSettings.coord_token(LAT2, LON2)
	# A DIR world on site 1.
	var map1 := {"scene_path": MapDefinition.GENERATED_SCENE, "lat": LAT, "lon": LON, "label": "Walton"}
	var rec1 := {"version": 1, "id": "wdir1", "name": "Festival", "storage": "dir", "map": map1,
		"last_played_unix": 200.0}
	_write(_u("worlds/wdir1/world.json"), JSON.stringify(rec1))
	_write(_u("worlds/wdir1/snapshot.json"), '{"player": {"x": 1}}')
	_write(_u("worlds/wdir1/placed_props.json"),
		'{"props": [{"id": "p1", "model_id": "vawt", "x": 1.0}, {"id": "p2", "model_id": "user_m1"}]}')
	_write(_u("worlds/wdir1/camp_areas.json"), '{"areas": []}')
	_write(_u("worlds/wdir1/assets/assets.json"), '{"version": 1, "files": {}}')
	_write(_u("worlds/wdir1/assets/files/resource_kinds.cfg"), '[kinds]\nwater="Water"\n')
	# A LEGACY world on site 2 (its data in the legacy maps dir).
	WorldPaths.set_legacy_dirs_for_test(_u("maps"), _u("saves/graph_autosave"), _u("scores"))
	var map2 := {"scene_path": MapDefinition.GENERATED_SCENE, "lat": LAT2, "lon": LON2, "label": "Mount Vernon"}
	var rec2 := {"version": 1, "id": "wleg1", "name": "", "storage": "legacy", "migrated": true, "map": map2,
		"last_played_unix": 100.0}
	_write(_u("worlds/wleg1/world.json"), JSON.stringify(rec2))
	var key2 := WorldPaths.site_key_for(LAT2, LON2)
	_write(_u("maps/placed_props_%s.json" % key2), '{"props": [{"id": "q1", "model_id": "shiftpod"}]}')
	_write(_u("worlds/_trash/old/world.json"), "{}")
	# Map caches: both sites + a third that must stay home.
	_write(_u("terrain_cache/extents_%s.json" % t1), '{"half_extent_m": 3000}')
	_write(_u("terrain_cache/dem/dem_v2_base_x_%s_15000_256.json" % t1), "[1,2,3]")
	_write(_u("terrain_cache/imagery/img_v1_%s_1500_z17.png" % t1), "PNGDATA1")
	_write(_u("terrain_cache/ai_imagery/ai_v1_44.01131_-123.59108_r50.png"), "AIPATCH")
	_write(_u("terrain_cache/dem/dem_v2_base_x_%s_15000_256.json" % t2), "[4,5,6]")
	_write(_u("terrain_cache/dem/dem_v2_base_x_1.0000_2.0000_15000_256.json"), "[7]")
	_write(_u("weather_cache/forecast_v2_%s.json" % t1), '{"f": 1}')
	# Libraries.
	_write(_u("models/catalog.json"),
		'[{"id": "user_m1", "label": "Dome", "path": "user://models/user_m1.glb"}]')
	_write(_u("models/user_m1.glb"), "GLB-BYTES")
	_write(_u("stage_audio/set.ogg"), "OGG-BYTES-ORIGINAL")
	_write(_u("camp_styles.json"), '{"styles": {"rv": {}}}')
	_write(_u("resource_kinds.cfg"), '[kinds]\nwater="Water"\nbiogas=3\n')
	# Settings (shareable) + one with an absolute path in it.
	_write(_u("npc_display.cfg"), '[npc]\nmood_bars=false\nfull_figures=24\n')
	_write(_u("star_calibration.cfg"), '[look]\nbrightness=1.5\nstarmap="C:/Users/someone/stars.png"\n')
	# Secrets, each with a sentinel.
	_write(_u("terrain_config.cfg"), '[opentopography]\napi_key="%s"\n' % SENTINELS[0])
	_write(_u("ha_connection.cfg"), '[connection]\ntoken="%s"\n' % SENTINELS[1])
	_write(_u("discord_auth.cfg"), '[auth]\nrefresh_token="%s"\n' % SENTINELS[2])
	_write(_u("communities/123.json"), '{"directory_webhook": "%s"}' % SENTINELS[3])
	_write(_u("mp_prefs.cfg"), '[mp]\ndisplay_name="%s"\n' % SENTINELS[4])
	_write(_u("location_prefs.cfg"), '[loc]\nlabel="%s"\n' % SENTINELS[5])
	_write(_u("tools/openscad/openscad.exe"), SENTINELS[6])
	_write(_u("logs/godot.log"), "log")
	_write(_u("veg_impostors/x.res"), "res")
	# Game art.
	_write(_p("Imported Models/NPC/Walking.fbx"), "FBX")
	_write(_p("Imported Models/NPC/Walking.fbx.import"), '[remap]\nimporter="scene"\nuid="uid://abc"\n')
	_write(_p("Imported Models/NPC/evil.gd"), "extends Node")
	_write(_p("Imported Models/Wind/VAWT.glb"), "VAWT")
	_write(_p("Imported Models/Soak Terrain/Camps/RV.glb"), "RV")
	_write(_p("Mars 2026 New.glb"), "MARS")
	_write(_p("core/not_art.png"), "NOPE")


# -- 1, 3, 4. Catalog + round trip --------------------------------------------------------------

func _test_catalog_and_roundtrip() -> void:
	var cat := AssetPackCatalog.build({"user_root": _u("").trim_suffix("/"),
		"project_root": _p("").trim_suffix("/"),
		"shipped_paths": {"vawt": "res://Imported Models/Wind/VAWT.glb",
			"shiftpod": "res://Imported Models/Soak Terrain/Camps/Shiftpod.glb"}})
	var worlds := cat.items_in(AssetPackFormat.SEC_WORLDS)
	_check("catalog: two worlds (trash skipped)", worlds.size() == 2, str(worlds.size()))
	_check("catalog: two map sites", cat.items_in(AssetPackFormat.SEC_MAPCACHE).size() == 2)
	var mc1 := cat.item("mapcache:" + TerrainCacheSettings.coord_token(LAT, LON))
	_check("catalog: site 1 cache has dem + imagery + AI + weather", (mc1.get("files", []) as Array).size() == 4,
		str((mc1.get("files", []) as Array).map(func(e): return e["zip"])))
	_check("catalog: mapcache parent is the world", (mc1.get("parents", []) as Array).has("world:wdir1"))
	_check("catalog: map data on by default", bool(mc1.get("default_on", false)))
	var w1 := cat.item("world:wdir1")
	_check("catalog: world needs its map data", (w1.get("needs", []) as Array).has(mc1.get("id", "")))
	_check("catalog: world needs the art its props use", (w1.get("needs", []) as Array).has("art:im:Wind"),
		str(w1.get("needs", [])))
	_check("catalog: painted camps need camp art", (w1.get("needs", []) as Array).has("art:camps"))
	_check("catalog: legacy world needs camp art via shiftpod",
		(cat.item("world:wleg1").get("needs", []) as Array).has("art:camps"))
	_check("catalog: models library", not cat.item("lib:models").is_empty())
	_check("catalog: music library", not cat.item("lib:music").is_empty())
	_check("catalog: presets library", not cat.item("lib:presets").is_empty())
	_check("catalog: settings off by default", not bool(cat.item("set:npc_display.cfg").get("default_on", true)))
	_check("catalog: art groups", not cat.item("art:npc").is_empty() and not cat.item("art:mars").is_empty())
	var art_needed := cat.art_needed_by({"world:wdir1": true})
	_check("catalog: world picks NPC + player + its art", art_needed.has("art:npc") and art_needed.has("art:im:Wind")
		and not art_needed.has("art:mars"), str(art_needed))
	var all_zip: Array = []
	var all_src: Array = []
	for it in cat.items:
		for e in it.get("files", []):
			all_zip.append(str(e["zip"]))
			all_src.append(str(e.get("src", "")))
	var leaked := false
	for s in all_src + all_zip:
		for bad in ["terrain_config", "ha_connection", "discord_auth", "communities", "mp_prefs",
				"location_prefs", "openscad", "logs/", "veg_impostors", "_trash", "evil.gd", "not_art"]:
			if str(s).contains(bad):
				leaked = true
				push_error("leak: %s" % s)
	_check("catalog: no secret / cache / code / non-art file offered", not leaked)
	_check("catalog: .import sidecar travels with its asset",
		all_zip.has("project/Imported Models/NPC/Walking.fbx.import"))
	_check("catalog: a .cfg travels as .cfgjson", all_zip.has("library/resource_kinds.cfgjson")
		and all_zip.has("worlds/wdir1/assets/files/resource_kinds.cfgjson"))

	# Tick everything and write, small parts to force a split.
	var sel := {}
	for it in cat.items:
		sel[str(it["id"])] = true
	var resolved := cat.resolve(sel)
	_check("resolve: legacy world in DIR layout",
		(resolved["entries"] as Array).any(func(e): return str(e["zip"]) == "worlds/wleg1/placed_props.json"))
	var meta := AssetPackWriter.build_meta(resolved, "Tester", _p("").trim_suffix("/"))
	_check("meta: two worlds listed", (meta["worlds"] as Array).size() == 2)
	_check("meta: needs reimport (art ticked)", bool(meta["needs_reimport"]))
	var base := "%s/out/share.simpack.zip" % _tmp
	var w := AssetPackWriter.write(base, resolved["entries"], meta, null, 1024)
	_check("write ok", bool(w["ok"]), str(w["error"]))
	_check("write split into several parts", (w["parts"] as Array).size() > 1, str((w["parts"] as Array).size()))
	# Every entry DECOMPRESSED (a deflated secret would not show in the raw
	# bytes), plus the raw bytes (names, manifest).
	var txt := ""
	for pth in w["parts"]:
		txt += FileAccess.get_file_as_bytes(str(pth)).get_string_from_ascii()
		var zr := ZIPReader.new()
		zr.open(str(pth))
		for fn in zr.get_files():
			txt += fn + " " + zr.read_file(fn).get_string_from_ascii()
		zr.close()
	var clean := true
	for s2 in SENTINELS:
		if txt.contains(s2):
			clean = false
			push_error("sentinel in pack: %s" % s2)
	_check("pack bytes carry no secret sentinel", clean)
	_check("pack carries no absolute path from settings", not txt.contains("C:/Users/someone"))
	_check("write refuses a file bigger than a part",
		not bool(AssetPackWriter.write("%s/out/big.simpack.zip" % _tmp,
			[{"zip": "library/models/x.glb", "data": PackedByteArray([1, 2, 3, 4, 5])}], {}, null, 4)["ok"]))

	# Read it (from part 2, which must lead back to part 1).
	var info := AssetPackReader.open(str(w["parts"][1]), "res://", _tmp)
	_check("reader ok", bool(info["ok"]), str(info["error"]))
	_check("reader found every part", (info["parts"] as Array).size() == (w["parts"] as Array).size())
	_check("reader: worlds section", (info["sections"] as Dictionary).has("worlds"))
	_check("reader: every file hashed", (info["hashes"] as Dictionary).size()
		== ((info["manifest"] as Dictionary)["files"] as Dictionary).size())

	# Install into an empty friend (settings off, art on).
	var friend := "%s/friend" % _tmp
	var fproj := "%s/friend_project" % _tmp
	var ins := AssetPackInstaller.create(info, {"worlds": "all", "settings": false, "art": true},
		{"user_root": friend, "project_root": fproj, "restore_assets": false})
	var r := ins.extract()
	r = ins.finish()
	_check("install ok", bool(r["ok"]), str(r["error"]))
	_check("install: two new worlds", (r["worlds"] as Array).size() == 2)
	var new_ids: Array = (r["worlds"] as Array).map(func(x): return str(x["id"]))
	_check("install: new ids", not new_ids.has("wdir1") and not new_ids.has("wleg1"), str(new_ids))
	var listed := WorldStore.list(friend + "/worlds")
	_check("install: friend's world list shows both", listed.size() == 2)
	var fest: Dictionary = {}
	var vern: Dictionary = {}
	for rec in listed:
		if str(rec.get("imported_from", {}).get("id", "")) == "wdir1":
			fest = rec
		elif str(rec.get("imported_from", {}).get("id", "")) == "wleg1":
			vern = rec
	_check("install: records are DIR storage", str(fest.get("storage", "")) == "dir"
		and str(vern.get("storage", "")) == "dir" and not vern.has("migrated"))
	var fdir := WorldStore.world_dir(str(fest.get("id", "")), friend + "/worlds")
	_check("install: world data byte-identical",
		FileAccess.get_file_as_string(fdir + "/placed_props.json")
		== FileAccess.get_file_as_string(_u("worlds/wdir1/placed_props.json")))
	_check("install: snapshot came along", FileAccess.file_exists(fdir + "/snapshot.json"))
	var vdir := WorldStore.world_dir(str(vern.get("id", "")), friend + "/worlds")
	_check("install: legacy world's data now in its own folder",
		FileAccess.get_file_as_string(vdir + "/placed_props.json")
		== FileAccess.get_file_as_string(_u("maps/placed_props_%s.json" % WorldPaths.site_key_for(LAT2, LON2))))
	var vcf := ConfigFile.new()
	_check("install: vendored .cfg decoded back",
		vcf.load(fdir + "/assets/files/resource_kinds.cfg") == OK and str(vcf.get_value("kinds", "water", "")) == "Water")
	var t1 := TerrainCacheSettings.coord_token(LAT, LON)
	_check("install: map cache present", FileAccess.file_exists("%s/terrain_cache/imagery/img_v1_%s_1500_z17.png" % [friend, t1])
		and FileAccess.file_exists("%s/terrain_cache/extents_%s.json" % [friend, t1]))
	_check("install: other site's cache not shipped",
		not FileAccess.file_exists("%s/terrain_cache/dem/dem_v2_base_x_1.0000_2.0000_15000_256.json" % friend))
	_check("install: library files", FileAccess.file_exists(friend + "/models/user_m1.glb")
		and FileAccess.file_exists(friend + "/stage_audio/set.ogg"))
	var lcf := ConfigFile.new()
	_check("install: library .cfg int kept", lcf.load(friend + "/resource_kinds.cfg") == OK
		and typeof(lcf.get_value("kinds", "biogas")) == TYPE_INT)
	_check("install: settings left alone unless asked", not FileAccess.file_exists(friend + "/npc_display.cfg"))
	_check("install: no secret reached the friend", not FileAccess.file_exists(friend + "/terrain_config.cfg")
		and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(friend + "/communities")))
	_check("install: art + sidecar written", FileAccess.file_exists(fproj + "/Imported Models/NPC/Walking.fbx")
		and FileAccess.file_exists(fproj + "/Imported Models/NPC/Walking.fbx.import")
		and FileAccess.file_exists(fproj + "/Mars 2026 New.glb"))
	_check("install: script never written", not FileAccess.file_exists(fproj + "/Imported Models/NPC/evil.gd"))
	_check("install: wants a reimport", ins.needs_reimport())

	# Second import over a friend who has changed things.
	_write(friend + "/stage_audio/set.ogg", "FRIENDS-OWN-TRACK")
	_write(friend + "/npc_display.cfg", "[npc]\nmood_bars=true\n")
	_write(friend + "/camp_styles.json", '{"styles": {"mine": {}}}')
	var ins2 := AssetPackInstaller.create(info, {"worlds": "all", "settings": true, "art": true},
		{"user_root": friend, "project_root": fproj, "restore_assets": false})
	ins2.extract()
	var r2 := ins2.finish()
	_check("reinstall ok", bool(r2["ok"]), str(r2["error"]))
	_check("reinstall: four worlds now", WorldStore.list(friend + "/worlds").size() == 4)
	var names: Array = WorldStore.list(friend + "/worlds").map(func(x): return WorldStore.display_name(x))
	_check("reinstall: clashing name marked", names.has("Festival (from Tester)"), str(names))
	_check("reinstall: first import untouched",
		FileAccess.get_file_as_string(fdir + "/placed_props.json")
		== FileAccess.get_file_as_string(_u("worlds/wdir1/placed_props.json")))
	_check("reinstall: friend's own track kept", FileAccess.get_file_as_string(friend + "/stage_audio/set.ogg")
		== "FRIENDS-OWN-TRACK")
	_check("reinstall: sender's track kept beside it",
		FileAccess.get_file_as_string(friend + "/stage_audio/set__from_tester.ogg") == "OGG-BYTES-ORIGINAL")
	_check("reinstall: single-file preset library keeps theirs",
		FileAccess.get_file_as_string(friend + "/camp_styles.json").contains("mine"))
	var ncf := ConfigFile.new()
	_check("reinstall: settings applied when asked", ncf.load(friend + "/npc_display.cfg") == OK
		and ncf.get_value("npc", "mood_bars", true) == false and int(ncf.get_value("npc", "full_figures", 0)) == 24)
	_check("reinstall: old settings backed up", not str(r2["backup_dir"]).is_empty()
		and FileAccess.get_file_as_string(str(r2["backup_dir"]) + "/npc_display.cfg").contains("mood_bars=true"))
	var scf := ConfigFile.new()
	_check("reinstall: absolute path never landed", scf.load(friend + "/star_calibration.cfg") == OK
		and not scf.has_section_key("look", "starmap") and is_equal_approx(float(scf.get_value("look", "brightness", 0.0)), 1.5))
	_check("reinstall: art already there is skipped", int(r2["art_files"]) == 0 and not ins2.needs_reimport())

	# A damaged file is reported and not written.
	var bad_info: Dictionary = info.duplicate(true)
	var bad_zip := "library/models/user_m1.glb"
	(bad_info["hashes"] as Dictionary)[bad_zip] = "00"
	var friend2 := "%s/friend2" % _tmp
	var ins3 := AssetPackInstaller.create(bad_info, {"worlds": [], "art": false},
		{"user_root": friend2, "project_root": "", "restore_assets": false})
	ins3.extract()
	var r3 := ins3.finish()
	_check("damaged: reported", (r3["damaged"] as Array).has(bad_zip))
	_check("damaged: not written", not FileAccess.file_exists(friend2 + "/models/user_m1.glb"))
	_check("pick worlds: none chosen => none imported", WorldStore.list(friend2 + "/worlds").is_empty())
	_check("pick worlds: art off => no project writes", int(r3["art_files"]) == 0)


# -- 2. Reader refusals ------------------------------------------------------------------------

func _test_reader_refusals() -> void:
	var dir := "%s/bad" % _tmp
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var man := {"format": 1, "parts": 1, "files": {}}
	_check("refuse: zip-slip entry", _refused(dir + "/slip.zip", man, {"../evil.json": "x"}))
	_check("refuse: script entry", _refused(dir + "/script.zip", man, {"library/hack.gd": "x"}))
	_check("refuse: text resource as user data", _refused(dir + "/tres.zip", man, {"worlds/w/x.tres": "x"}))
	_check("refuse: raw cfg", _refused(dir + "/cfg.zip", man, {"settings/ui_prefs.cfg": "x"}))
	_check("refuse: unlisted entry", _refused(dir + "/unlisted.zip", man, {"library/models/a.glb": "x"}))
	var man_new := {"format": 99, "parts": 1, "files": {}}
	_check("refuse: newer format", _refused(dir + "/new.zip", man_new, {}))
	var man_parts := {"format": 1, "parts": 2, "part_names": ["two.simpack.zip", "two.simpack.002.zip"], "files": {}}
	_check("refuse: missing part", _refused(dir + "/two.simpack.zip", man_parts, {}))
	_check("refuse: not a pack", _refused(dir + "/plain.zip", {}, {"readme.txt": "x"}))
	var ok_man := {"format": 1, "parts": 1, "files": {"library/models/a.glb": {"size": 1, "part": 1}}}
	_check("accept: a clean pack", not _refused(dir + "/clean.zip", ok_man, {"library/models/a.glb": "x"}))
	_check("looks_like_pack", AssetPackReader.looks_like_pack(dir + "/clean.zip")
		and not AssetPackReader.looks_like_pack(dir + "/plain.zip"))


## Write a zip with `manifest` (if non-empty) + `entries`; true = refused.
func _refused(path: String, manifest: Dictionary, entries: Dictionary) -> bool:
	var zp := ZIPPacker.new()
	zp.open(path)
	if not manifest.is_empty():
		zp.start_file(AssetPackFormat.MANIFEST)
		zp.write_file(JSON.stringify(manifest).to_utf8_buffer())
		zp.close_file()
	for k in entries:
		zp.start_file(str(k))
		zp.write_file(str(entries[k]).to_utf8_buffer())
		zp.close_file()
	zp.close()
	return not bool(AssetPackReader.open(path, "res://", _tmp)["ok"])


func _rm_tree(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for sub in da.get_directories():
		_rm_tree(dir.path_join(sub))
	for fn in da.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(fn)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))

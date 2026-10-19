class_name AssetPackCatalog
extends RefCounted

## Everything that COULD go in an asset pack, as a flat list of tickable
## items with sizes. Pure file walking — no scene, no autoload — so it runs on
## a worker thread and the selftest can point it at TEMP roots.
##
## An item:
##   {id, section, label, sub, size, default_on, files: Array[entry],
##    needs: Array[item id], parents: Array[item id] (mapcache only),
##    world_id, thumb}
## An entry is {zip, src} (copy a file) or {zip, data} (bytes made here — a
## rewritten world record, a .cfg re-encoded as JSON).
##
## Sections and their items:
##   worlds    one per world (record rewritten to DIR storage, data files
##             renamed to the DIR layout — a legacy world travels like a new
##             one — snapshot, thumb, vendored assets/, the map's extents)
##   mapcache  one per map SITE, exported only when one of its `parents`
##             (the worlds on that site) is ticked
##   library   the player's content libraries
##   settings  whitelisted preference files (AssetPackPrefs), off by default
##   project   gitignored game art in groups (only with a project root)

const TERRAIN_CACHE_SUBDIRS := ["dem", "imagery", "osm_vectors", "osm_vegetation", "ai_imagery", "mapillary"]

## [id, label, sub, user-relative dirs/files]
const LIBRARY_GROUPS := [
	["models", "Custom 3D models", "Models you imported (GLB) and their catalog", ["models"]],
	["music", "Stage music", "Tracks your stages and venues play", ["stage_audio"]],
	["presets", "Looks, presets and recipes",
		"Vegetation looks, camp styles, component presets, recipes, conduit styles, pack kits",
		["resource_kinds.cfg", "process_recipes.json", "workflow_recipes.json", "user_presets.json",
			"camp_styles.json", "pack_defs.json", "conduit_kinds.cfg", "conduit_style_presets.json",
			"vegetation_style_v3.json", "vegetation_species_defaults.json", "vegetation_presets.cfg",
			"maps/packing_layouts.json", "maps/packing_custom_items.json"]],
	["npc_anims", "NPC animations", "Clips made in the animation editor", ["npc_anims"]],
	["player_characters", "Player characters", "Custom player bodies", ["player_characters"]],
	["fab_tools", "Fabrication tools", "Tool models the crews hold", ["fab_tools"]],
	["linkage", "Linkage Lab designs", "Saved Linkage Lab designs", ["linkage_designs"]],
	["graphs", "Saved graphs", "Named graphs and .esim site packages", ["saves/graphs", "saves/esim"]],
	["machines", "Machines and print jobs", "Machine profiles, G-code jobs, prints", ["machines"]],
	["scad", "Parametric parts", "Parts rendered in the SCAD store", ["scad_parts"]],
	["facades", "Facade textures", "Wall textures for styled buildings", ["maps/facade_textures"]],
	["photocards", "Tree photocards", "Photo cards for vegetation species", ["veg_photocards"]],
	["starmap", "Custom star map", "An uploaded sky texture", ["starmaps"]],
]

const SETTINGS_LABELS := {
	"perf_prefs.cfg": "Graphics quality", "ui_prefs.cfg": "Interface", "sim_settings.cfg": "Simulation",
	"toolbar_prefs.cfg": "Edit toolbar", "audio_prefs.cfg": "Sound", "npc_display.cfg": "NPC display",
	"player.cfg": "Player body and camera", "planet_prefs.cfg": "Planets", "climate_prefs.cfg": "Climate",
	"weather_gen_engine.cfg": "Weather engine", "extreme_weather.cfg": "Extreme weather",
	"pop_testing.cfg": "Population testing switches", "star_calibration.cfg": "Star look",
	"solar_panel_config.cfg": "Solar panel and battery",
}

## Game art groups: [id, label, sub, rule]. A file belongs to the FIRST group
## whose rule matches (see _art_group_of).
const ART_GROUPS := [
	["art:npc", "NPC character pack", "The Mixamo people and their clips (Imported Models/NPC)"],
	["art:player", "Player character", "The player's body and animations (Player Character)"],
	["art:camps", "Camp components", "RVs, tents, shade structures used by painted camps"],
	["art:soak", "SOAK festival map", "The SOAK 2026 scene and its terrain"],
	["art:mars", "Mars map", "The Mars aerial scene, terrain tiles and textures"],
	["art:starshades", "StarShade models", "StarShade, Center Camp, Man Effigy"],
	["art:starshade_fbx", "StarShade FBX sets", "StarShade FBX + Pretty Version trees"],
	["art:trees", "Hero trees", "Detailed tree models"],
	["art:vehicles", "Vehicles and loose models", "Appa, buses, camper van, skid steer, …"],
	["art:pbr", "PBR material sets", "Wood and metal texture sets"],
]

var user_root := "user://"
var worlds_root := "user://worlds"
## "" = no art section (an exported build cannot install art).
var project_root := ""
var items: Array[Dictionary] = []
var _by_id: Dictionary = {}
## Shipped model id -> project-relative path (for "what my worlds need").
var _shipped_paths: Dictionary = {}


## Build the catalog. opts: user_root, worlds_root, project_root,
## shipped_paths ({model_id: "res://…"}; defaults to ModelCatalog's).
static func build(opts: Dictionary = {}) -> AssetPackCatalog:
	var c := AssetPackCatalog.new()
	c.user_root = str(opts.get("user_root", "user://"))
	c.worlds_root = str(opts.get("worlds_root", c.user_root.path_join("worlds")))
	c.project_root = str(opts.get("project_root", ""))
	if opts.has("shipped_paths"):
		c._shipped_paths = opts["shipped_paths"]
	elif not c.project_root.is_empty():
		c._shipped_paths = shipped_model_paths()
	c._build_worlds()
	c._build_library()
	c._build_settings()
	if not c.project_root.is_empty():
		c._build_art()
	for it in c.items:
		c._by_id[str(it["id"])] = it
	return c


func item(id: String) -> Dictionary:
	return _by_id.get(id, {})


func items_in(section: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for it in items:
		if str(it["section"]) == section:
			out.append(it)
	return out


## The default tick set (mapcache items default on, but only export when a
## parent world is ticked).
func default_selection() -> Dictionary:
	var sel := {}
	for it in items:
		if bool(it.get("default_on", false)):
			sel[str(it["id"])] = true
	return sel


## Resolve a tick set into the entries to pack, deduplicated by zip path,
## plus the items actually included. A mapcache item counts only with a
## ticked parent world.
func resolve(selection: Dictionary) -> Dictionary:
	var entries: Array = []
	var seen := {}
	var included: Array[Dictionary] = []
	var total := 0
	for it in items:
		var id := str(it["id"])
		if not selection.get(id, false):
			continue
		if str(it["section"]) == AssetPackFormat.SEC_MAPCACHE:
			var any_parent := false
			for p in it.get("parents", []):
				if selection.get(str(p), false):
					any_parent = true
			if not any_parent:
				continue
		included.append(it)
		var files: Array = it.get("files", [])
		if str(it["section"]) == AssetPackFormat.SEC_WORLDS:
			# Worlds are re-read here: the writer runs WorldAssets.collect
			# right before resolving, which can add vendored files.
			files = world_entries(it.get("rec", {}))
		for e in files:
			var z := str(e["zip"])
			if seen.has(z):
				continue
			seen[z] = true
			entries.append(e)
			total += entry_size(e)
	return {"entries": entries, "items": included, "bytes": total}


func size_of_selection(selection: Dictionary) -> int:
	var total := 0
	for it in items:
		var id := str(it["id"])
		if not selection.get(id, false):
			continue
		if str(it["section"]) == AssetPackFormat.SEC_MAPCACHE:
			var any_parent := false
			for p in it.get("parents", []):
				if selection.get(str(p), false):
					any_parent = true
			if not any_parent:
				continue
		total += int(it.get("size", 0))
	return total


## The art groups the ticked worlds use (+ the people and the player, which
## every world shows).
func art_needed_by(selection: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var any_world := false
	for it in items_in(AssetPackFormat.SEC_WORLDS):
		if not selection.get(str(it["id"]), false):
			continue
		any_world = true
		for n in it.get("needs", []):
			if str(n).begins_with("art:") and _by_id.has(str(n)) and not out.has(str(n)):
				out.append(str(n))
	if any_world:
		for always in ["art:npc", "art:player"]:
			if _by_id.has(always) and not out.has(always):
				out.append(always)
	# A map group pulls in what its scene depends on.
	var i := 0
	while i < out.size():
		for n in item(out[i]).get("needs", []):
			if _by_id.has(str(n)) and not out.has(str(n)):
				out.append(str(n))
		i += 1
	return out


static func entry_size(e: Dictionary) -> int:
	if e.has("data"):
		return (e["data"] as PackedByteArray).size()
	return maxi(FileAccess.get_size(str(e["src"])), 0)


static func shipped_model_paths() -> Dictionary:
	var out := {}
	for m in ModelCatalog._shipped_models():
		var p := str(m.get("source_path", m.get("path", "")))
		if p.begins_with("res://"):
			out[str(m.get("id", ""))] = p
	return out


# -- Worlds ----------------------------------------------------------------------

func _build_worlds() -> void:
	var sites := {}   # coord token -> mapcache item
	for rec in WorldStore.list(worlds_root):
		var id := str(rec.get("id", ""))
		var files := world_entries(rec)
		var size := 0
		for e in files:
			size += entry_size(e)
		var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
		var wid := "world:" + id
		var needs: Array = []
		var sub := str(map.get("label", ""))
		if WorldStore.is_generated_map(map):
			var lat := float(map.get("lat", 0.0))
			var lon := float(map.get("lon", 0.0))
			var tok := TerrainCacheSettings.coord_token(lat, lon)
			var mid := "mapcache:" + tok
			if not sites.has(tok):
				var mfiles := site_cache_entries(lat, lon)
				var msize := 0
				for e in mfiles:
					msize += entry_size(e)
				sites[tok] = {"id": mid, "section": AssetPackFormat.SEC_MAPCACHE,
					"label": "Map data", "sub": "Elevation, aerial imagery, OSM, weather · %s" % tok.replace("_", ", "),
					"size": msize, "default_on": true, "files": mfiles, "parents": [], "needs": []}
			(sites[tok]["parents"] as Array).append(wid)
			needs.append(mid)
		else:
			var scene := MapDefinition.normalize_scene_path(str(map.get("scene_path", "")))
			if scene == MapDefinition.SOAK_SCENE_CANONICAL:
				needs.append("art:soak")
				sub = "SOAK festival map"
			elif scene == MapDefinition.MARS_SCENE_CANONICAL:
				needs.append("art:mars")
				sub = "Mars map"
		for g in _art_used_by_world(rec):
			if not needs.has(g):
				needs.append(g)
		var thumb := WorldStore.thumb_path(id, worlds_root)
		items.append({"id": wid, "section": AssetPackFormat.SEC_WORLDS,
			"label": WorldStore.display_name(rec), "sub": sub, "size": size,
			"default_on": false, "files": files, "needs": needs, "world_id": id,
			"rec": rec, "thumb": thumb if FileAccess.file_exists(thumb) else ""})
	for tok in sites:
		items.append(sites[tok])


## Every pack entry for one world, in DIR layout under worlds/<id>/.
func world_entries(rec: Dictionary) -> Array:
	var out: Array = []
	var id := str(rec.get("id", ""))
	if id.is_empty():
		return out
	var pre := "%s/%s/" % [AssetPackFormat.SEC_WORLDS, id]
	var wdir := WorldStore.world_dir(id, worlds_root)
	var r := rec.duplicate(true)
	r["storage"] = WorldPaths.STORAGE_DIR
	r.erase("migrated")
	out.append({"zip": pre + WorldStore.RECORD_FILE, "data": JSON.stringify(r, "\t").to_utf8_buffer()})
	for meta in [WorldStore.SNAPSHOT_FILE, WorldStore.THUMB_FILE]:
		var p := wdir.path_join(meta)
		if FileAccess.file_exists(p):
			out.append({"zip": pre + meta, "src": p})
	var files := WorldStore.data_files(rec, worlds_root)
	for tag in files:
		var src := str(files[tag])
		if AssetPackFormat.user_data_allowed(str(tag)):
			_add_user_entry(out, pre + str(tag), src)
	for rel in walk_files(wdir.path_join(WorldAssets.ASSETS_DIR)):
		var src2 := wdir.path_join(WorldAssets.ASSETS_DIR).path_join(rel)
		if AssetPackFormat.user_data_allowed(rel):
			_add_user_entry(out, pre + WorldAssets.ASSETS_DIR + "/" + rel, src2)
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	if WorldStore.is_generated_map(map):
		var ext := "extents_%s.json" % TerrainCacheSettings.coord_token(float(map.get("lat", 0.0)),
			float(map.get("lon", 0.0)))
		var ep := user_root.path_join("terrain_cache").path_join(ext)
		if FileAccess.file_exists(ep):
			out.append({"zip": "%s/terrain_cache/%s" % [AssetPackFormat.SEC_MAPCACHE, ext], "src": ep})
	return out


## A user file as a pack entry: a .cfg is re-encoded (AssetPackPrefs).
static func _add_user_entry(out: Array, zip_path: String, src: String) -> void:
	if AssetPackFormat.ext_of(src) == "cfg":
		var txt := AssetPackPrefs.encode_file(src)
		if not txt.is_empty():
			out.append({"zip": AssetPackFormat.transport_name(zip_path), "data": txt.to_utf8_buffer()})
		return
	out.append({"zip": zip_path, "src": src})


## Shipped art a world's props and camps use, as art group ids.
func _art_used_by_world(rec: Dictionary) -> Array:
	var out: Array = []
	if _shipped_paths.is_empty():
		return out
	var files := WorldStore.data_files(rec, worlds_root)
	var re := RegEx.new()
	re.compile("\"model_id\"\\s*:\\s*\"([^\"]+)\"")
	for tag in files:
		var t := str(tag)
		if t.begins_with("camp_areas"):
			if not out.has("art:camps"):
				out.append("art:camps")
			continue
		if not t.begins_with("placed_props"):
			continue
		var text := FileAccess.get_file_as_string(str(files[tag]))
		for m in re.search_all(text):
			var p := str(_shipped_paths.get(m.get_string(1), ""))
			if p.is_empty():
				continue
			var g := _art_group_of(p.trim_prefix("res://"))
			if not g.is_empty() and not out.has(g):
				out.append(g)
	return out


# -- Map cache -------------------------------------------------------------------

## The site's files in terrain_cache/* and weather_cache/. A cache file names
## its site as "<lat>_<lon>" at whatever precision its service uses (4
## decimals for DEM/imagery/OSM, 5 for the AI patch, 2 for climate
## projections), so each name is compared at its OWN precision.
func site_cache_entries(lat: float, lon: float) -> Array:
	var out: Array = []
	for sub in TERRAIN_CACHE_SUBDIRS:
		var dir := user_root.path_join("terrain_cache").path_join(str(sub))
		for fn in list_files(dir):
			if file_names_site(fn, lat, lon) and AssetPackFormat.user_data_allowed(fn):
				out.append({"zip": "%s/terrain_cache/%s/%s" % [AssetPackFormat.SEC_MAPCACHE, sub, fn],
					"src": dir.path_join(fn)})
	var wdir := user_root.path_join("weather_cache")
	for fn2 in list_files(wdir):
		if file_names_site(fn2, lat, lon) and AssetPackFormat.user_data_allowed(fn2):
			out.append({"zip": "%s/weather_cache/%s" % [AssetPackFormat.SEC_MAPCACHE, fn2],
				"src": wdir.path_join(fn2)})
	return out


static var _site_re: RegEx = null


static func file_names_site(fn: String, lat: float, lon: float) -> bool:
	if _site_re == null:
		_site_re = RegEx.new()
		_site_re.compile("(?:^|_)(-?\\d+)\\.(\\d+)_(-?\\d+)\\.(\\d+)(?=[_.]|$)")
	for m in _site_re.search_all(fn):
		var la := float(m.get_string(1) + "." + m.get_string(2))
		var lo := float(m.get_string(3) + "." + m.get_string(4))
		# Half a unit of the name's own last digit — never tighter than the
		# 4-decimal token's, so a finer name (the AI patch) still matches a
		# site whose stored coordinate was rounded differently.
		var tol_a := maxf(0.5 * pow(10.0, -m.get_string(2).length()), 0.00005) + 1e-9
		var tol_o := maxf(0.5 * pow(10.0, -m.get_string(4).length()), 0.00005) + 1e-9
		if absf(la - lat) <= tol_a and absf(lo - lon) <= tol_o:
			return true
	return false


# -- Library + settings ------------------------------------------------------------

func _build_library() -> void:
	for g in LIBRARY_GROUPS:
		var files: Array = []
		for rel in g[3]:
			var p := user_root.path_join(str(rel))
			if FileAccess.file_exists(p):
				if AssetPackFormat.user_data_allowed(str(rel)):
					_add_user_entry(files, "%s/%s" % [AssetPackFormat.SEC_LIBRARY, rel], p)
			else:
				for sub in walk_files(p):
					var full := "%s/%s" % [str(rel), sub]
					if AssetPackFormat.user_data_allowed(full):
						_add_user_entry(files, "%s/%s" % [AssetPackFormat.SEC_LIBRARY, full], p.path_join(sub))
		if files.is_empty():
			continue
		var size := 0
		for e in files:
			size += entry_size(e)
		items.append({"id": "lib:" + str(g[0]), "section": AssetPackFormat.SEC_LIBRARY,
			"label": str(g[1]), "sub": "%s · %s" % [str(g[2]), UiText.count(files.size(), "file")],
			"size": size, "default_on": true, "files": files, "needs": []})


func _build_settings() -> void:
	for fn in AssetPackPrefs.SHAREABLE:
		var p := user_root.path_join(str(fn))
		if not FileAccess.file_exists(p):
			continue
		var txt := AssetPackPrefs.encode_file(p)
		if txt.is_empty():
			continue
		var data := txt.to_utf8_buffer()
		items.append({"id": "set:" + str(fn), "section": AssetPackFormat.SEC_SETTINGS,
			"label": str(SETTINGS_LABELS.get(fn, str(fn).get_basename().capitalize())), "sub": str(fn),
			"size": data.size(), "default_on": false, "needs": [],
			"files": [{"zip": "%s/%s" % [AssetPackFormat.SEC_SETTINGS, AssetPackFormat.transport_name(str(fn))],
				"data": data}]})


# -- Game art ------------------------------------------------------------------------

## Which art group a project-relative file belongs to ("" = not art).
static func _art_group_of(rel: String) -> String:
	var r := rel.trim_suffix(".import")
	if not AssetPackFormat.is_art_path(r):
		return ""
	if r.begins_with("Imported Models/NPC/"):
		return "art:npc"
	if r.begins_with("Player Character/"):
		return "art:player"
	if r.begins_with("Imported Models/Soak Terrain/Camps/"):
		return "art:camps"
	if r.begins_with("Imported Models/Soak Terrain/") or r == "scenes/maps/soak_festival_2026.tscn" \
			or r == "maps/soak_camp_map.tres" or r == "scenes/gameplay/Tree.tscn":
		return "art:soak"
	if r.begins_with("Imported Models/Mars Aerial/") or r.begins_with("Imported Models/Newest Mars Model/") \
			or r.begins_with("Imported Models/Mars") or r == "scenes/maps/mars_aerial.tscn" \
			or r == "maps/mars_aerial_map.tres" or r == "main.tscn" \
			or (not r.contains("/") and (r.begins_with("Mars") or r.begins_with("10m_") \
				or r.begins_with("motorhome"))):
		return "art:mars"
	if r.begins_with("Imported Models/StarShades/"):
		return "art:starshades"
	if r.begins_with("StarShade FBX/") or r.begins_with("Starshade Pretty Version"):
		return "art:starshade_fbx"
	if r.begins_with("Imported Models/Trees/"):
		return "art:trees"
	if r.begins_with("Wood034_1K-JPG/") or r.begins_with("Metal051C_1K-JPG/"):
		return "art:pbr"
	if r.begins_with("Imported Models/"):
		var rest := r.trim_prefix("Imported Models/")
		if not rest.contains("/"):
			return "art:vehicles"
		return "art:im:" + rest.get_slice("/", 0)
	return "art:other"


func _build_art() -> void:
	var groups := {}   # id -> {files, size}
	var candidates: Array[String] = []
	for d in AssetPackFormat.ART_DIRS:
		for rel in walk_files(project_root.path_join(str(d))):
			candidates.append("%s/%s" % [d, rel])
	for f in AssetPackFormat.ART_FILES:
		for suffix in ["", ".import"]:
			if FileAccess.file_exists(project_root.path_join(str(f) + suffix)):
				candidates.append(str(f) + suffix)
	for fn in list_files(project_root):
		if AssetPackFormat.is_art_path(fn) and not AssetPackFormat.ART_FILES.has(fn):
			candidates.append(fn)
	for rel in candidates:
		var g := _art_group_of(rel)
		if g.is_empty():
			continue
		if not groups.has(g):
			groups[g] = {"files": [], "size": 0}
		var src := project_root.path_join(rel)
		(groups[g]["files"] as Array).append({"zip": "%s/%s" % [AssetPackFormat.SEC_ART, rel], "src": src})
		groups[g]["size"] = int(groups[g]["size"]) + maxi(FileAccess.get_size(src), 0)
	var labels := {}
	for row in ART_GROUPS:
		labels[str(row[0])] = [str(row[1]), str(row[2])]
	var order: Array = []
	for row in ART_GROUPS:
		if groups.has(str(row[0])):
			order.append(str(row[0]))
	var rest: Array = []
	for g in groups:
		if not order.has(g):
			rest.append(g)
	rest.sort()
	order.append_array(rest)
	for g in order:
		var lab: Array = labels.get(g, [])
		var label := str(lab[0]) if not lab.is_empty() else \
			(str(g).trim_prefix("art:im:") + " models" if str(g).begins_with("art:im:") else "Other art")
		var sub := str(lab[1]) if not lab.is_empty() else "Imported Models/" + str(g).trim_prefix("art:im:")
		var n := (groups[g]["files"] as Array).size()
		items.append({"id": g, "section": AssetPackFormat.SEC_ART, "label": label,
			"sub": "%s · %s" % [sub, UiText.count(n, "file")], "size": int(groups[g]["size"]),
			"default_on": false, "files": groups[g]["files"], "needs": _map_scene_needs(str(g))})


## A map scene's art depends on other groups (SOAK's scene uses the hero
## trees and the camp components): found from the scene's dependency closure,
## so a ticked map always brings what it needs to open.
func _map_scene_needs(g: String) -> Array:
	var scene := ""
	if g == "art:soak":
		scene = MapDefinition.SOAK_SCENE_CANONICAL
	elif g == "art:mars":
		scene = MapDefinition.MARS_SCENE_CANONICAL
	# ResourceLoader only answers for THIS project (a selftest's TEMP
	# project root has no import data to ask).
	if scene.is_empty() or not _is_live_project():
		return []
	var out: Array = []
	for p in dependency_closure(scene):
		var grp := _art_group_of(str(p).trim_prefix("res://"))
		if not grp.is_empty() and grp != g and not out.has(grp):
			out.append(grp)
	return out


func _is_live_project() -> bool:
	if project_root == "res://":
		return true
	return project_root.replace("\\", "/").trim_suffix("/") \
		== ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")


## Every res:// path a resource depends on, recursively (ResourceLoader's own
## list is one level deep — see MapDefinition.is_scene_fully_available).
static func dependency_closure(path: String) -> Array:
	var seen := {}
	var stack: Array = [path]
	while not stack.is_empty():
		var p := str(stack.pop_back())
		if seen.has(p) or not ResourceLoader.exists(p):
			continue
		seen[p] = true
		for dep in ResourceLoader.get_dependencies(p):
			var d := str(dep)
			var i := d.rfind("res://")
			if i >= 0:
				stack.append(d.substr(i))
	return seen.keys()


# -- Walk ------------------------------------------------------------------------

## The files directly in `dir` ([] when it does not exist — get_files_at
## logs an error for a missing folder).
static func list_files(dir: String) -> PackedStringArray:
	if not _dir_exists(dir):
		return PackedStringArray()
	return DirAccess.get_files_at(dir)


static func _dir_exists(dir: String) -> bool:
	return DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir))


## Every file under `dir`, as paths relative to it (forward slashes).
static func walk_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	if not _dir_exists(dir):
		return out
	var stack: Array = [""]
	while not stack.is_empty():
		var rel := str(stack.pop_back())
		var full := dir if rel.is_empty() else dir.path_join(rel)
		for fn in DirAccess.get_files_at(full):
			out.append(fn if rel.is_empty() else "%s/%s" % [rel, fn])
		for sub in DirAccess.get_directories_at(full):
			stack.append(sub if rel.is_empty() else "%s/%s" % [rel, sub])
	out.sort()
	return out

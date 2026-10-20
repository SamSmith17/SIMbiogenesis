class_name AssetPackFormat
extends RefCounted

## The asset pack (".simpack.zip") contract, shared by the writer, the reader
## and the installer so the three cannot disagree about what may travel.
##
## A pack is a plain zip (or several: Godot's ZIPPacker silently corrupts an
## archive past 4 GB — measured on 4.7.1 — so a big pack is split into parts
## of at most PART_MAX_BYTES, "<name>.simpack.zip", "<name>.simpack.002.zip",
## …). Paths are rooted by section:
##
##   simpack.json                 the manifest (part 1 only; read first)
##   worlds/<id>/…                one world in DIR layout (record, snapshot,
##                                thumb, data files, assets/)
##   mapcache/terrain_cache/…     the site's DEM / imagery / OSM / AI patch
##   mapcache/weather_cache/…     the site's weather archive + forecast
##   library/<user-relative>      custom models, music, animations, presets
##   settings/<name>.cfgjson      whitelisted preferences
##   project/<res-relative>       gitignored game art + its .import sidecars
##
## Hard rules:
##   * no secret file is ever written or read (SECRET_FILES / SECRET_DIRS);
##   * no code is ever written or read (CODE_EXTENSIONS) — anywhere;
##   * a user-data section carries only DATA_EXTENSIONS; a Godot text resource
##     (.tres / .tscn) never travels as user data (one can embed a script),
##     and a .cfg travels re-encoded as JSON primitives (".cfgjson", see
##     AssetPackPrefs) so an untrusted file is never fed to the Variant parser;
##   * project art must live under one of the gitignored ART roots.

const FORMAT := 1
const MANIFEST := "simpack.json"
## At the end of every part: the SHA-256 of each file in it.
const HASHES := "simpack.hashes.json"
const EXT := ".simpack.zip"
## Under 4 GiB with room for the central directory.
const PART_MAX_BYTES := 3_500_000_000
## Files are streamed into the zip in chunks this size.
const CHUNK_BYTES := 4 * 1024 * 1024

const SEC_WORLDS := "worlds"
const SEC_MAPCACHE := "mapcache"
const SEC_LIBRARY := "library"
const SEC_SETTINGS := "settings"
const SEC_ART := "project"
const SECTIONS := [SEC_WORLDS, SEC_MAPCACHE, SEC_LIBRARY, SEC_SETTINGS, SEC_ART]

const CFG_JSON_EXT := ".cfgjson"

## Never exported, never imported, never offered.
const SECRET_FILES := [
	"ha_connection.cfg", "uisp_settings.cfg", "terrain_config.cfg", "keys_config.cfg",
	"discord_auth.cfg", "discord_config.cfg", "discord_cache.cfg", "mp_prefs.cfg",
	"mp_telemetry.log", "solar_ui_ha_entities.cfg", "location_prefs.cfg",
	"automations.yaml", "progress.json",
]
const SECRET_PREFIXES := ["ha_automation_"]
const SECRET_DIRS := ["communities", "tools"]
## Regenerable or machine-local folders: never part of a pack.
const CACHE_DIRS := [
	"veg_impostors", "shader_cache", "vulkan", "logs", "screenshots", "site_reports",
	"graph_previews", "climelapses", "scratch", "objectdb_snapshots", "pack_backups",
]

const CODE_EXTENSIONS := [
	"gd", "gdc", "gde", "cs", "gdextension", "gdnlib", "dll", "so", "dylib", "exe",
	"bat", "cmd", "com", "msi", "ps1", "psm1", "sh", "py", "pyc", "js", "vbs", "jar",
	"scr", "lnk",
]
## What a user-data entry may be.
const DATA_EXTENSIONS := [
	"json", "bin", "png", "jpg", "jpeg", "webp", "glb", "gltf", "fbx", "stl", "obj",
	"mp3", "ogg", "wav", "gcode", "txt", "csv", "esim", "flag", "cfgjson", "svg",
]
## Stored, not deflated: already compressed.
const STORE_EXTENSIONS := ["glb", "png", "jpg", "jpeg", "webp", "mp3", "ogg", "ctex", "fbx"]

## The gitignored art (.gitignore "GitHub lite" + local maps + root blobs).
## The root art moved under these folders on 2026-10-20 (Wood034 into
## "Imported Models/Materials/", the Mars/motorhome/Starshade blobs into
## "Imported Models/Mars Aerial/" and "Starshade Pretty Version/"); the old
## locations stay listed so packs made before then still install.
const ART_DIRS := [
	"Imported Models", "StarShade FBX", "Starshade Pretty Version", "Player Character",
	"Wood034_1K-JPG", "Metal051C_1K-JPG",
]
const ART_FILES := [
	"scenes/maps/soak_festival_2026.tscn", "scenes/maps/mars_aerial.tscn",
	"maps/soak_camp_map.tres", "maps/mars_aerial_map.tres",
	"scenes/maps/mars_main_legacy.tscn", "main.tscn",
	"scenes/gameplay/Tree.tscn",
]
## Root-level blobs from before 2026-10-20, as glob patterns matched against the
## bare file name (kept so older packs still install).
const ART_ROOT_GLOBS := [
	"10m_*.obj", "10m_*.STL", "Mars *.glb", "Mars*.jpg", "Mars*.png", "motorhome.glb",
	"motorhome_*.jpg", "Starshade Pretty Version*.glb", "Starshade Pretty Version*.jpg",
	"Starshade Pretty Version*.png", "Bombay Beach*.jpg",
]


static func ext_of(path: String) -> String:
	return path.get_extension().to_lower()


static func is_code(path: String) -> bool:
	return CODE_EXTENSIONS.has(ext_of(path))


## A user-relative path ("worlds/x/a.json", "models/m.glb") that must never
## leave or enter this machine.
static func is_secret_user_path(rel: String) -> bool:
	var r := rel.replace("\\", "/").trim_prefix("/")
	var first := r.get_slice("/", 0)
	if SECRET_DIRS.has(first):
		return true
	var fn := r.get_file()
	if SECRET_FILES.has(fn):
		return true
	for p in SECRET_PREFIXES:
		if fn.begins_with(p):
			return true
	return false


static func is_cache_user_path(rel: String) -> bool:
	return CACHE_DIRS.has(rel.replace("\\", "/").trim_prefix("/").get_slice("/", 0))


## How a user file is named inside the pack: a .cfg becomes ".cfgjson".
static func transport_name(rel: String) -> String:
	return rel + "json" if ext_of(rel) == "cfg" else rel


## The user file a pack entry lands on (the inverse of transport_name).
static func user_name(transport: String) -> String:
	return transport.trim_suffix("json") if transport.ends_with(CFG_JSON_EXT) else transport


## May this user-relative file travel as user data at all?
static func user_data_allowed(rel: String) -> bool:
	if is_secret_user_path(rel) or is_cache_user_path(rel) or is_code(rel):
		return false
	var e := ext_of(rel)
	return e == "cfg" or DATA_EXTENSIONS.has(e)


## Is this project-relative path part of the gitignored art (a .import
## sidecar counts as its asset)?
static func is_art_path(rel: String) -> bool:
	var r := rel.replace("\\", "/").trim_prefix("/")
	if r.ends_with(".import"):
		r = r.trim_suffix(".import")
	if r.is_empty() or is_code(r) or not SafeZip.entry_is_safe(r):
		return false
	for d in ART_DIRS:
		if r.begins_with(str(d) + "/"):
			return true
	if ART_FILES.has(r):
		return true
	if not r.contains("/"):
		for g in ART_ROOT_GLOBS:
			if r.match(str(g)):
				return true
	return false


## Is a zip entry acceptable for its section? (The reader refuses the whole
## pack when one is not.)
static func entry_allowed(entry: String) -> bool:
	if not SafeZip.entry_is_safe(entry) or is_code(entry):
		return false
	if entry == MANIFEST or entry == HASHES:
		return true
	var sec := entry.get_slice("/", 0)
	var rest := entry.substr(sec.length() + 1)
	if rest.is_empty():
		return false
	match sec:
		SEC_ART:
			return is_art_path(rest)
		SEC_WORLDS, SEC_LIBRARY:
			return _transport_allowed(rest)
		SEC_MAPCACHE:
			return (rest.begins_with("terrain_cache/") or rest.begins_with("weather_cache/")) \
				and _transport_allowed(rest)
		SEC_SETTINGS:
			return not rest.contains("/") and rest.ends_with(CFG_JSON_EXT) \
				and AssetPackPrefs.is_shareable(user_name(rest))
	return false


static func _transport_allowed(rest: String) -> bool:
	var e := ext_of(rest)
	if e == "cfg" or e == "tres" or e == "tscn" or e == "res":
		return false
	if not DATA_EXTENSIONS.has(e):
		return false
	return not is_secret_user_path(user_name(rest)) and not is_cache_user_path(user_name(rest))


## "<base>.simpack.zip" -> part n (1-based; part 1 is the base name).
static func part_path(base_path: String, n: int) -> String:
	if n <= 1:
		return base_path
	var stem := base_path.trim_suffix(EXT) if base_path.ends_with(EXT) else base_path.get_basename()
	return "%s.simpack.%03d.zip" % [stem, n]


## The game commit when running from a git checkout ("" otherwise).
static func game_commit(project_root: String = "res://") -> String:
	var head_path := project_root.path_join(".git/HEAD")
	if not FileAccess.file_exists(head_path):
		return ""
	var head := FileAccess.get_file_as_string(head_path).strip_edges()
	if not head.begins_with("ref:"):
		return head.substr(0, 40)
	var ref := head.trim_prefix("ref:").strip_edges()
	var ref_path := project_root.path_join(".git").path_join(ref)
	if FileAccess.file_exists(ref_path):
		return FileAccess.get_file_as_string(ref_path).strip_edges().substr(0, 40)
	var packed := project_root.path_join(".git/packed-refs")
	if FileAccess.file_exists(packed):
		for line in FileAccess.get_file_as_string(packed).split("\n"):
			if line.ends_with(" " + ref):
				return line.get_slice(" ", 0).substr(0, 40)
	return ""


## True when the game runs from a project folder (editor / GitHub clone),
## where gitignored art can be installed and imported.
static func running_from_source() -> bool:
	return not OS.has_feature("template")


static func human_size(bytes: int) -> String:
	var b := float(bytes)
	if b < 1024.0:
		return "%d B" % bytes
	for u in ["KB", "MB", "GB", "TB"]:
		b /= 1024.0
		if b < 1024.0 or u == "TB":
			return ("%.0f %s" if b >= 100.0 else "%.1f %s") % [b, u]
	return "%d B" % bytes

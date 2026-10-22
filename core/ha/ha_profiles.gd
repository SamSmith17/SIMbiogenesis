class_name HaProfiles
extends RefCounted
## Saved Home Assistant instances (pure file I/O; every function takes its path
## so the selftest runs against a TEMP file).
##
## One global, SECRET file (user://ha_profiles.cfg — never in a world, never in
## an asset pack, see AssetPackFormat.SECRET_FILES): each saved instance is a
## name + address + token + what we learned the last time it worked. A world
## may name one of them (world.json "ha_profile_id"); the rest use the default.
##
## The old single-connection file (user://ha_connection.cfg) is migrated once
## into the first profile and left on disk.

const PATH := "user://ha_profiles.cfg"
const LEGACY_PATH := "user://ha_connection.cfg"
const LEGACY_PLACEHOLDER_URL := "ws://YOUR_HA_IP:8123/api/websocket"
const LEGACY_PLACEHOLDER_TOKEN := "YOUR_LONG_LIVED_TOKEN"

const PROFILE_KEYS := ["name", "url", "token", "last_ok_unix", "ha_version", "location_name"]


## {profiles: Array[Dictionary], default_id, auto_connect, legacy_entities}.
## Each profile: {id, name, url, token, last_ok_unix (0 = never), ha_version,
## location_name}.
static func load_all(path: String = PATH, legacy_path: String = LEGACY_PATH) -> Dictionary:
	var out := {"profiles": [], "default_id": "", "auto_connect": true, "legacy_entities": ""}
	var cfg := ConfigFile.new()
	if cfg.load(path) == OK:
		out["default_id"] = str(cfg.get_value("settings", "default_profile", ""))
		out["auto_connect"] = bool(cfg.get_value("settings", "auto_connect", true))
		out["legacy_entities"] = str(cfg.get_value("settings", "legacy_entities", ""))
		for sec in cfg.get_sections():
			if not sec.begins_with("profile."):
				continue
			var p := {"id": sec.substr(8)}
			p["name"] = str(cfg.get_value(sec, "name", ""))
			p["url"] = str(cfg.get_value(sec, "url", ""))
			p["token"] = str(cfg.get_value(sec, "token", ""))
			p["last_ok_unix"] = int(cfg.get_value(sec, "last_ok_unix", 0))
			p["ha_version"] = str(cfg.get_value(sec, "ha_version", ""))
			p["location_name"] = str(cfg.get_value(sec, "location_name", ""))
			(out["profiles"] as Array).append(p)
	elif not legacy_path.is_empty():
		var legacy := migrate_legacy(legacy_path)
		if not legacy.is_empty():
			var p: Dictionary = legacy["profile"]
			(out["profiles"] as Array).append(p)
			out["default_id"] = p["id"]
			out["legacy_entities"] = legacy.get("entities", "")
			save_all(out, path)
	if str(out["default_id"]).is_empty() and not (out["profiles"] as Array).is_empty():
		out["default_id"] = str((out["profiles"] as Array)[0]["id"])
	return out


## {profile, entities} from the old file, {} when there is nothing usable.
static func migrate_legacy(legacy_path: String) -> Dictionary:
	var cfg := ConfigFile.new()
	if cfg.load(legacy_path) != OK:
		return {}
	var url := str(cfg.get_value("connection", "url", "")).strip_edges()
	var tok := str(cfg.get_value("connection", "token", "")).strip_edges()
	if url.is_empty() or url == LEGACY_PLACEHOLDER_URL:
		return {}
	if tok == LEGACY_PLACEHOLDER_TOKEN:
		tok = ""
	var p := make(url, tok, "Home Assistant")
	return {"profile": p, "entities": str(cfg.get_value("connection", "entities", ""))}


static func save_all(data: Dictionary, path: String = PATH) -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("settings", "default_profile", str(data.get("default_id", "")))
	cfg.set_value("settings", "auto_connect", bool(data.get("auto_connect", true)))
	if not str(data.get("legacy_entities", "")).is_empty():
		cfg.set_value("settings", "legacy_entities", str(data["legacy_entities"]))
	for p in data.get("profiles", []):
		if not (p is Dictionary) or str(p.get("id", "")).is_empty():
			continue
		var sec := "profile.%s" % p["id"]
		for k in PROFILE_KEYS:
			cfg.set_value(sec, k, p.get(k, 0 if k == "last_ok_unix" else ""))
	return cfg.save(path) == OK


## A new profile dict (not saved). The id is stable for a given address so a
## re-added instance replaces its old entry instead of duplicating it.
static func make(url: String, token: String, name: String = "") -> Dictionary:
	var n := HaUrl.normalize(url)
	var key := str(n["url"]) if bool(n.get("ok", false)) else url.strip_edges()
	return {
		"id": "ha_%08x" % (hash(key.to_lower()) & 0x7fffffff),
		"name": name, "url": url.strip_edges(), "token": token,
		"last_ok_unix": 0, "ha_version": "", "location_name": "",
	}


static func find(data: Dictionary, id: String) -> Dictionary:
	for p in data.get("profiles", []):
		if p is Dictionary and str(p.get("id", "")) == id:
			return p
	return {}


## Insert or replace by id; returns the id.
static func upsert(data: Dictionary, profile: Dictionary) -> String:
	var id := str(profile.get("id", ""))
	if id.is_empty():
		return ""
	var arr: Array = data.get("profiles", [])
	for i in arr.size():
		if arr[i] is Dictionary and str(arr[i].get("id", "")) == id:
			arr[i] = profile
			data["profiles"] = arr
			return id
	arr.append(profile)
	data["profiles"] = arr
	if str(data.get("default_id", "")).is_empty():
		data["default_id"] = id
	return id


static func remove(data: Dictionary, id: String) -> void:
	var arr: Array = data.get("profiles", [])
	for i in range(arr.size() - 1, -1, -1):
		if arr[i] is Dictionary and str(arr[i].get("id", "")) == id:
			arr.remove_at(i)
	data["profiles"] = arr
	if str(data.get("default_id", "")) == id:
		data["default_id"] = str(arr[0]["id"]) if not arr.is_empty() else ""


## Name for the instance list: the player's name, else HA's location name,
## else the address.
static func label(p: Dictionary) -> String:
	for k in ["name", "location_name"]:
		var s := str(p.get(k, "")).strip_edges()
		if not s.is_empty():
			return s
	return HaUrl.short(str(p.get("url", "")))

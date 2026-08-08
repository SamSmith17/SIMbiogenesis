class_name SimCommunity
extends RefCounted

## The single blob a server owner configures once and hands their members.
##
## Two interchangeable forms over one schema: a plain `.simcommunity` JSON file
## (diffable, regenerable) and a `SMBC1:` one-liner that pastes into a Discord
## message. The one-liner reuses MpJoinCode's exact codec shape —
## prefix + base64(gzip(JSON)) — because that is already proven to survive a
## Discord paste.
##
## `validate()` is a SECURITY BOUNDARY, not a convenience. The webhook URLs in
## here are write credentials that the host will POST to, and every id is
## interpolated into a URL, so a hand-pasted file is untrusted input.

const PREFIX := "SMBC1:"
const VERSION := 1
const KIND := "simbiogenesis.community"

const MAX_NAME_LEN := 64
const MAX_ROLE_IDS := 16
const WEBHOOK_PREFIXES := [
	"https://discord.com/api/webhooks/",
	"https://discordapp.com/api/webhooks/",
]


static func make(fields: Dictionary = {}) -> Dictionary:
	return {
		"v": VERSION,
		"kind": KIND,
		"name": str(fields.get("name", "")),
		"client_id": str(fields.get("client_id", "")),
		"guild_id": str(fields.get("guild_id", "")),
		"role_ids": _string_array(fields.get("role_ids", [])),
		"voice_channel_id": str(fields.get("voice_channel_id", "")),
		"text_channel_hint": str(fields.get("text_channel_hint", "")),
		"directory_channel_id": str(fields.get("directory_channel_id", "")),
		"directory_webhook": str(fields.get("directory_webhook", "")),
		"directory_message_id": str(fields.get("directory_message_id", "")),
		"relay_webhook": str(fields.get("relay_webhook", "")),
		"issued_at": int(fields.get("issued_at", 0)),
		"issuer": str(fields.get("issuer", "")),
	}


## {ok, code} / {ok:false, error}
static func encode(community: Dictionary) -> Dictionary:
	var check := validate(community)
	if not bool(check.get("ok", false)):
		return check
	var body: Dictionary = check["community"]
	var raw := JSON.stringify(body).to_utf8_buffer()
	var compressed := raw.compress(FileAccess.COMPRESSION_GZIP)
	return {
		"ok": true,
		"code": PREFIX + Marshalls.raw_to_base64(compressed),
		"community": body,
	}


## {ok, community} / {ok:false, error}
static func decode(code: String) -> Dictionary:
	var trimmed := code.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "error": "Empty community code"}
	if not trimmed.begins_with(PREFIX):
		return {"ok": false, "error": "Community code must start with %s" % PREFIX}
	var compressed := Marshalls.base64_to_raw(trimmed.substr(PREFIX.length()))
	if compressed.is_empty():
		return {"ok": false, "error": "Invalid community-code encoding"}
	var raw := compressed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {"ok": false, "error": "Could not decompress community code"}
	return from_json_text(raw.get_string_from_utf8())


static func to_json_text(community: Dictionary) -> String:
	return JSON.stringify(community, "\t")


static func from_json_text(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Community file is not JSON"}
	return validate(parsed as Dictionary)


## The gate. Returns {ok, community} with a normalized copy, or {ok:false, error}.
static func validate(raw: Dictionary) -> Dictionary:
	var ver := int(raw.get("v", 0))
	if ver != VERSION:
		return {"ok": false, "error": "Unsupported community version %d (need %d)" % [ver, VERSION]}
	var kind := str(raw.get("kind", KIND))
	if kind != KIND:
		return {"ok": false, "error": "Not a SIMbiogenesis community file"}

	var guild := str(raw.get("guild_id", "")).strip_edges()
	if not DiscordConfig.is_snowflake(guild):
		return {"ok": false, "error": "guild_id is not a Discord id"}

	# Every id is interpolated into an API URL or a deep link.
	for key in ["voice_channel_id", "directory_channel_id", "directory_message_id", "client_id", "issuer"]:
		var v := str(raw.get(key, "")).strip_edges()
		if not v.is_empty() and not DiscordConfig.is_snowflake(v):
			return {"ok": false, "error": "%s is not a Discord id" % key}

	var roles := _string_array(raw.get("role_ids", []))
	if roles.size() > MAX_ROLE_IDS:
		return {"ok": false, "error": "Too many role ids (max %d)" % MAX_ROLE_IDS}
	for r in roles:
		if not DiscordConfig.is_snowflake(str(r)):
			return {"ok": false, "error": "role id %s is not a Discord id" % r}

	# THE load-bearing check: these URLs are write credentials the host POSTs
	# to. Without this, a pasted community file silently redirects the host's
	# relayed chat — and anything else we send — to an attacker's endpoint.
	for key in ["directory_webhook", "relay_webhook"]:
		var w := str(raw.get(key, "")).strip_edges()
		if w.is_empty():
			continue
		if not _is_webhook_url(w):
			return {"ok": false, "error": "%s must be a https://discord.com/api/webhooks/… URL" % key}

	var name := str(raw.get("name", "")).strip_edges()
	if name.length() > MAX_NAME_LEN:
		name = name.substr(0, MAX_NAME_LEN)

	var out := make(raw)
	out["name"] = name
	out["guild_id"] = guild
	out["role_ids"] = roles
	return {"ok": true, "community": out}


## Public because the directory re-checks a webhook URL immediately before
## POSTing to it. `validate()` already enforces this, but the check is cheap and
## the consequence of missing it (credentials or chat sent to an attacker's
## endpoint) is not the kind of thing to guard in only one place.
static func is_webhook_url(url: String) -> bool:
	return _is_webhook_url(url)


static func _is_webhook_url(url: String) -> bool:
	var u := url.strip_edges()
	for p in WEBHOOK_PREFIXES:
		if u.begins_with(str(p)):
			# Require an id/token tail so a bare prefix is not accepted.
			var tail := u.substr(str(p).length())
			return tail.count("/") == 1 and not tail.begins_with("/") and not tail.ends_with("/")
	return false


## Directory and relay should be SEPARATE webhooks where possible: one can then
## be revoked without killing the other. Surfaced as a warning, not an error.
static func warnings(community: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var d := str(community.get("directory_webhook", "")).strip_edges()
	var r := str(community.get("relay_webhook", "")).strip_edges()
	if not d.is_empty() and d == r:
		out.append("Directory and chat relay share one webhook — revoking either kills both.")
	if str(community.get("directory_webhook", "")).is_empty():
		out.append("No directory webhook: Play together cannot find a host.")
	if (community.get("role_ids", []) as Array).is_empty():
		out.append("No role ids: every member of the server can join.")
	return out


## Path this community persists to. One file per community keeps them
## individually diffable and deletable.
static func storage_path(community: Dictionary) -> String:
	var guild := str(community.get("guild_id", "")).strip_edges()
	if not DiscordConfig.is_snowflake(guild):
		return ""
	return "%s/%s.json" % [DiscordConfig.COMMUNITY_DIR, guild]


## ── Storage ──────────────────────────────────────────────────────────────────
##
## One JSON file per community under `user://communities/`, so each stays
## individually diffable and deletable, plus a pointer to the active one in
## `mp_prefs.cfg`. Save/load only — no HTTP — so the selftest can snapshot and
## restore these files the way the veg harnesses already do.

const PREFS_PATH := "user://mp_prefs.cfg"


## {ok, community, path} / {ok:false, error}
static func save_to_disk(raw: Dictionary) -> Dictionary:
	var check := validate(raw)
	if not bool(check.get("ok", false)):
		return check
	var community: Dictionary = check["community"]
	var path := storage_path(community)
	if path.is_empty():
		return {"ok": false, "error": "Community has no usable guild id"}
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(DiscordConfig.COMMUNITY_DIR))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Could not write %s" % path}
	f.store_string(to_json_text(community))
	f.close()
	return {"ok": true, "community": community, "path": path}


## Every community on disk, newest-imported first is not meaningful here so this
## is simply sorted by name for a stable dropdown order.
static func list_on_disk() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DiscordConfig.COMMUNITY_DIR)
	if dir == null:
		return out
	for file in dir.get_files():
		if not str(file).ends_with(".json"):
			continue
		var f := FileAccess.open("%s/%s" % [DiscordConfig.COMMUNITY_DIR, file], FileAccess.READ)
		if f == null:
			continue
		var parsed := from_json_text(f.get_as_text())
		f.close()
		if bool(parsed.get("ok", false)):
			out.append(parsed["community"])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0)
	return out


static func load_from_disk(guild_id: String) -> Dictionary:
	if not DiscordConfig.is_snowflake(guild_id):
		return {}
	var f := FileAccess.open("%s/%s.json" % [DiscordConfig.COMMUNITY_DIR, guild_id], FileAccess.READ)
	if f == null:
		return {}
	var parsed := from_json_text(f.get_as_text())
	f.close()
	return parsed["community"] if bool(parsed.get("ok", false)) else {}


static func forget(guild_id: String) -> void:
	if not DiscordConfig.is_snowflake(guild_id):
		return
	var path := "%s/%s.json" % [DiscordConfig.COMMUNITY_DIR, guild_id]
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if active_guild_id() == guild_id:
		set_active(null)


static func set_active(community) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PREFS_PATH)
	var guild := ""
	if community is Dictionary:
		guild = str((community as Dictionary).get("guild_id", ""))
	cfg.set_value("mp", "active_community", guild)
	cfg.save(PREFS_PATH)


static func active_guild_id() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PREFS_PATH) != OK:
		return ""
	return str(cfg.get_value("mp", "active_community", ""))


## The community the game should be using right now: the explicitly chosen one,
## else the only one on disk, else {}. Falling back to "the only one" means a
## member who imports a single file never has to also pick it.
static func active() -> Dictionary:
	var chosen := load_from_disk(active_guild_id())
	if not chosen.is_empty():
		return chosen
	var all := list_on_disk()
	return all[0] if all.size() == 1 else {}


static func _string_array(v: Variant) -> Array:
	var out: Array = []
	if v is PackedStringArray:
		for s in (v as PackedStringArray):
			out.append(str(s))
		return out
	if v is Array:
		for s in (v as Array):
			var t := str(s).strip_edges()
			if not t.is_empty():
				out.append(t)
	return out

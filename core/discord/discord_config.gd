class_name DiscordConfig
extends RefCounted

## Shared constants + client-id resolution for the Discord integration.
##
## Pure: no HTTP, no scene access, no autoload lookups except an explicit
## ConfigFile read. Everything security-relevant in this subsystem lives in a
## pure `class_name` file so `core/discord/discord_selftest.gd` can feed it
## fixtures offline — the same relationship MpHardening/MpJoinCode already have
## to MultiplayerSession.

const API_BASE := "https://discord.com/api/v10"
const AUTHORIZE_URL := "https://discord.com/oauth2/authorize"
const TOKEN_URL := API_BASE + "/oauth2/token"
const OAUTH_ME_URL := API_BASE + "/oauth2/@me"
const USERS_ME_URL := API_BASE + "/users/@me"
const CDN_BASE := "https://cdn.discordapp.com"

## Only host any bearer token may be sent to. `DiscordHttp` enforces this so a
## hand-pasted community file cannot redirect an authenticated request
## somewhere else (see `SimCommunity.validate`, which guards the webhook URLs
## from the other direction).
const ALLOWED_API_HOSTS := ["discord.com", "discordapp.com"]

## The app's client id is NOT a secret — it appears in every authorize URL —
## so it may ship as a constant. It is left empty here because this repo has no
## registered Discord application yet; until one exists, sign-in is offered only
## when a community file or user://discord_config.cfg supplies an id.
const DEFAULT_CLIENT_ID := ""

const CONFIG_PATH := "user://discord_config.cfg"
const AUTH_PATH := "user://discord_auth.cfg"
const COMMUNITY_DIR := "user://communities"

## Discord requires an EXACTLY registered redirect URI, so the loopback port
## cannot be dynamic. Register all three in the dev portal and bind the first
## that is free; the bound one defines the redirect_uri used in BOTH the
## authorize URL and the token exchange (PKCE requires them identical). If all
## three are busy we fail loudly rather than fall back to an unregistered port,
## which would only produce an opaque `invalid_request` from Discord.
## Deliberately adjacent to MultiplayerSession's 34197/34198 so the reserved
## block reads as one range.
const REDIRECT_PORTS := [34199, 34200, 34201]
const REDIRECT_PATH := "/cb"

## Membership + roles on a KNOWN guild id needs only `guilds.members.read`.
## The broader `guilds` scope returns the user's ENTIRE server list and is
## deliberately NOT requested by default: a host who receives a guest's token
## (see the admission design) should not be able to enumerate the other
## communities that guest belongs to.
const SCOPES_DEFAULT := ["identify", "guilds.members.read"]
const SCOPE_BROWSE_GUILDS := "guilds"


## redirect_uri for a bound loopback port. Must be byte-identical between the
## authorize request and the token exchange, so both callers use this.
static func redirect_uri(port: int) -> String:
	return "http://127.0.0.1:%d%s" % [port, REDIRECT_PATH]


static func all_redirect_uris() -> PackedStringArray:
	var out := PackedStringArray()
	for p in REDIRECT_PORTS:
		out.append(redirect_uri(int(p)))
	return out


## Resolution order, strongest first:
##   1. the active community file (a community running its own Discord app gets
##      its own consent screen and its own rate-limit bucket),
##   2. user://discord_config.cfg  [discord] client_id=   (dev override; same
##      config-then-constant shape as ai_imagery_service.gd's key lookup),
##   3. the shipped constant.
static func resolve_client_id(community: Dictionary = {}) -> String:
	var from_community := str(community.get("client_id", "")).strip_edges()
	if not from_community.is_empty():
		return from_community
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		var k := str(cfg.get_value("discord", "client_id", "")).strip_edges()
		if not k.is_empty():
			return k
	return DEFAULT_CLIENT_ID


## True when a bearer token may be sent to this URL.
static func is_allowed_api_url(url: String) -> bool:
	var host := _host_of(url)
	if host.is_empty():
		return false
	for h in ALLOWED_API_HOSTS:
		if host == str(h):
			return true
	return false


## Scheme + host of an https URL, lowercased; "" when the URL is not https or
## is malformed. Deliberately strict — this feeds a security check.
static func _host_of(url: String) -> String:
	var u := url.strip_edges().to_lower()
	if not u.begins_with("https://"):
		return ""
	var rest := u.substr(8)
	var cut := rest.length()
	for sep in ["/", "?", "#"]:
		var i := rest.find(sep)
		if i >= 0 and i < cut:
			cut = i
	var host := rest.substr(0, cut)
	# Reject userinfo (https://discord.com@evil.example/…) and empty hosts.
	if host.is_empty() or host.contains("@"):
		return ""
	# Strip an explicit port; a non-443 port on discord.com is not something we
	# ever produce, so treat it as a mismatch rather than normalising it away.
	if host.contains(":"):
		return ""
	return host


## Discord snowflake: 17-20 decimal digits. Used to validate every guild /
## channel / role / user id that arrives from a pasted community file before it
## is interpolated into a URL.
static func is_snowflake(s: String) -> bool:
	var t := s.strip_edges()
	if t.length() < 17 or t.length() > 20:
		return false
	for i in t.length():
		var c := t.unicode_at(i)
		if c < 48 or c > 57:
			return false
	return true


## Standard base64 -> base64url with padding stripped (RFC 4648 §5).
## Godot's Marshalls.raw_to_base64 emits STANDARD base64, so PKCE needs this;
## getting it wrong is the single most likely defect in the whole auth flow,
## which is why discord_selftest pins it against the RFC 7636 vector.
static func b64url(raw: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(raw).replace("+", "-").replace("/", "_").replace("=", "")

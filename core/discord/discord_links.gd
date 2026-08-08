class_name DiscordLinks
extends RefCounted

## Deep links into the Discord client, and the validation that has to happen
## before any of them reach `OS.shell_open`.
##
## Voice is deliberately NOT implemented in-engine: `discord://-/channels/{g}/{c}`
## drops the player straight into the community's own voice channel, which is
## the whole "let Discord handle the hard stuff" position. The alternative — a
## Discord Social SDK GDExtension — needs a C++ build per platform and this repo
## has no proven macOS native-build pipeline (both existing native addons ship
## Windows/Linux binaries only).

const APP_SCHEME := "discord://-"
const WEB_BASE := "https://discord.com/channels"

## Prefixes `open_invite` accepts. Prefix matching is intentional and matches
## the shape multiplayer_selftest already pins (including the negative case
## `https://evil.example/discord.gg/x`, which must stay rejected).
const INVITE_PREFIXES := [
	"https://discord.gg/",
	"https://discord.com/invite/",
	"https://discord.com/",
	"http://discord.gg/",
]


## discord://-/channels/{guild}/{channel} — navigates the installed client to a
## channel, including a voice channel. Returns "" when either id is not a
## snowflake, so a hand-pasted community file cannot inject path or scheme
## fragments into a shell_open.
static func voice_deep_link(guild_id: String, channel_id: String) -> String:
	if not (DiscordConfig.is_snowflake(guild_id) and DiscordConfig.is_snowflake(channel_id)):
		return ""
	return "%s/channels/%s/%s" % [APP_SCHEME, guild_id.strip_edges(), channel_id.strip_edges()]


## The https equivalent, used for the "didn't open?" fallback.
static func voice_web_url(guild_id: String, channel_id: String) -> String:
	if not (DiscordConfig.is_snowflake(guild_id) and DiscordConfig.is_snowflake(channel_id)):
		return ""
	return "%s/%s/%s" % [WEB_BASE, guild_id.strip_edges(), channel_id.strip_edges()]


## Permanent link to the directory message — this is the "stable link" a server
## owner pins: the message is edited in place forever, so its URL never changes.
static func message_url(guild_id: String, channel_id: String, message_id: String) -> String:
	if not DiscordConfig.is_snowflake(message_id):
		return ""
	var base := voice_web_url(guild_id, channel_id)
	if base.is_empty():
		return ""
	return "%s/%s" % [base, message_id.strip_edges()]


## Avatar URL for a verified guest, used as the webhook `avatar_url` override so
## relayed chat reads like real Discord messages. "" when the user has no custom
## avatar (Discord serves a default we do not need to reproduce).
static func avatar_url(user_id: String, avatar_hash: String, size: int = 64) -> String:
	var h := avatar_hash.strip_edges()
	if h.is_empty() or not DiscordConfig.is_snowflake(user_id):
		return ""
	for i in h.length():
		var c := h.unicode_at(i)
		var hex := (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)
		if not hex and c != 95:  # animated avatars are prefixed "a_"
			return ""
	var ext := "gif" if h.begins_with("a_") else "png"
	return "%s/avatars/%s/%s.%s?size=%d" % [CDN(), user_id.strip_edges(), h, ext, size]


static func CDN() -> String:
	return DiscordConfig.CDN_BASE


## Kept as-is from mp_chat_controller.is_valid_discord_url so the existing
## selftest keeps passing, extended for the app scheme.
static func is_valid_invite_url(url: String) -> bool:
	var u := url.strip_edges()
	if u.is_empty():
		return false
	for p in INVITE_PREFIXES:
		if u.begins_with(str(p)):
			return true
	return false


## True for a link we are willing to hand to OS.shell_open.
static func is_openable(url: String) -> bool:
	var u := url.strip_edges()
	if u.begins_with(APP_SCHEME + "/"):
		return not u.contains(" ")
	return is_valid_invite_url(u) or u.begins_with(WEB_BASE + "/")

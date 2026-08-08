extends SceneTree

## Offline checks for the Discord integration's PURE logic — PKCE, the community
## file codec, the session-directory record and its election arbitration, the
## host-side admission verdicts, deep links, reachability classification, chat
## relay batching, telemetry redaction, and join-code v3 back-compat.
##
## Nothing here touches the network. That is the point: every security-relevant
## decision in this subsystem was deliberately factored into a pure `class_name`
## file so it can be fed fixtures here rather than only being exercised against
## a live Discord app.
##
## Run: Godot.exe.exe --headless --path . --import
##      Godot.exe.exe --headless --path . --script core/discord/discord_selftest.gd

const PkceScript := preload("res://core/discord/discord_pkce.gd")
const LinksScript := preload("res://core/discord/discord_links.gd")
const CommunityScript := preload("res://core/discord/community_file.gd")
const DirScript := preload("res://core/discord/directory_record.gd")
const GateScript := preload("res://core/discord/gate_rules.gd")
const BatcherScript := preload("res://core/discord/relay_batcher.gd")
const ReachScript := preload("res://core/multiplayer/mp_reachability.gd")
const HardeningScript := preload("res://core/multiplayer/mp_hardening.gd")
const JoinCodeScript := preload("res://core/multiplayer/mp_join_code.gd")

## A join code produced by the v2 encoder, frozen as a literal so a codec change
## cannot silently invalidate the codes already sitting in people's Discord
## messages. Generated independently of MpJoinCode.encode (standard gzip), which
## is what makes it a real regression fixture rather than a tautology.
const FROZEN_V2_CODE := "SMB2:H4sIAAAAAAAC/y2NUQ6CMBBEr2L2uzZ0WRF6AK9hqmyQAG1TChoJd3dJ/JyZNzMbrGBRQR/BgmlQm6rWRhOCghhSBluSaa4KchjYC+Mez1Yy7yYWdUvhy/60HvjkZGODofetJB17Ti7zAY8u93lppUC1LvEif2Pw3d87G0SNVDW7Av7IBpkCiaguCgUvN9/jG2xOC+8/YsYox60AAAA="

var _fails := 0
var _asserts := 0


func _init() -> void:
	call_deferred("_run_all")


func _run_all() -> void:
	var checks := 0
	for entry in [
		["pkce_rfc7636_vector", _test_pkce_rfc7636],
		["pkce_mint_and_urls", _test_pkce_mint_and_urls],
		["pkce_callback_parse", _test_pkce_callback_parse],
		["config_url_and_snowflake", _test_config_url_and_snowflake],
		["community_roundtrip", _test_community_roundtrip],
		["community_rejects_bad_input", _test_community_rejects],
		["directory_render_parse", _test_directory_render_parse],
		["directory_staleness", _test_directory_staleness],
		["directory_election", _test_directory_election],
		["gate_oauth_me", _test_gate_oauth_me],
		["gate_member", _test_gate_member],
		["gate_iso8601", _test_gate_iso8601],
		["links", _test_links],
		["reachability_classify", _test_reachability_classify],
		["reachability_upnp_text", _test_reachability_upnp_text],
		["relay_batcher", _test_relay_batcher],
		["telemetry_redaction", _test_redaction],
		["admission_states", _test_admission],
		["join_code_v3", _test_join_code_v3],
		["join_code_reads_frozen_v2", _test_join_code_frozen_v2],
		["identity_offline_contract", _test_identity_offline],
		["identity_loopback_bind", _test_identity_loopback],
		["community_store", _test_community_store],
		["relay_filters_and_gates", _test_relay_gates],
	]:
		var before := _fails
		(entry[1] as Callable).call()
		checks += 1
		if _fails > before:
			push_error("discord_selftest.%s failed" % str(entry[0]))

	# Run last and awaited: the election deliberately waits out a real confirm
	# delay, and that delay IS the mechanism being tested.
	var before_live := _fails
	checks += 1
	await _test_directory_election_live()
	if _fails > before_live:
		push_error("discord_selftest.directory_election_live failed")

	if _fails == 0:
		print("discord_selftest: PASS (%d checks, %d assertions)" % [checks, _asserts])
	else:
		push_error("discord_selftest: FAIL (%d assertions failed over %d checks)" % [_fails, checks])
	quit(1 if _fails > 0 else 0)


func _ok(cond: bool, msg: String) -> void:
	_asserts += 1
	if not cond:
		_fails += 1
		push_error("  assert: %s" % msg)


func _eq(got: Variant, want: Variant, msg: String) -> void:
	_ok(str(got) == str(want), "%s (got %s, want %s)" % [msg, got, want])


# ── PKCE ─────────────────────────────────────────────────────────────────────

## RFC 7636 Appendix B. The single highest-value test in this file: it catches
## every base64url and padding mistake at once, offline, and a slip here would
## otherwise surface only as an opaque `invalid_grant` from Discord's token
## endpoint with nothing to debug.
func _test_pkce_rfc7636() -> void:
	var verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	_eq(PkceScript.challenge_for(verifier),
		"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
		"RFC 7636 challenge")
	_ok(PkceScript.is_valid_verifier(verifier), "RFC verifier passes shape check")


func _test_pkce_mint_and_urls() -> void:
	var a: Dictionary = PkceScript.mint()
	var b: Dictionary = PkceScript.mint()
	_ok(str(a["verifier"]) != str(b["verifier"]), "two mints differ")
	_ok(PkceScript.is_valid_verifier(str(a["verifier"])), "minted verifier is legal")
	_eq(str(a["verifier"]).length(), 43, "32 bytes -> 43 base64url chars")
	for field in ["verifier", "challenge", "state"]:
		var v := str(a[field])
		_ok(not (v.contains("+") or v.contains("/") or v.contains("=")),
			"%s is base64url, not standard base64" % field)
	_eq(PkceScript.challenge_for(str(a["verifier"])), str(a["challenge"]), "challenge matches verifier")

	# Verifier shape rejection.
	_ok(not PkceScript.is_valid_verifier("short"), "too-short verifier rejected")
	_ok(not PkceScript.is_valid_verifier("a+b/c=" .repeat(10)), "non-unreserved verifier rejected")

	var redirect: String = DiscordConfig.redirect_uri(34199)
	_eq(redirect, "http://127.0.0.1:34199/cb", "redirect uri shape")
	var url: String = PkceScript.authorize_url("123", redirect,
		DiscordConfig.SCOPES_DEFAULT, str(a["challenge"]), str(a["state"]))
	_ok(url.begins_with(DiscordConfig.AUTHORIZE_URL + "?"), "authorize url base")
	_ok(url.contains("response_type=code"), "authorization-code grant, not implicit")
	_ok(url.contains("code_challenge_method=S256"), "S256 challenge method")
	_ok(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A34199%2Fcb"), "redirect is uri-encoded")
	_ok(url.contains("scope=identify%20guilds.members.read"), "minimal scope set")
	# The broad `guilds` scope must not creep into the default: a host receiving
	# a guest's token could otherwise enumerate every server that guest is in.
	_ok(not url.contains("scope=identify%20guilds%20"), "no broad guilds scope by default")

	var body: String = PkceScript.token_exchange_body("123", "abc", redirect, str(a["verifier"]))
	_ok(body.contains("grant_type=authorization_code"), "exchange grant type")
	_ok(body.contains("code_verifier=%s" % str(a["verifier"])), "exchange carries the verifier")
	_ok(not body.contains("client_secret"), "public client: no secret in the exchange")


func _test_pkce_callback_parse() -> void:
	var good: Dictionary = PkceScript.parse_callback("GET /cb?code=AAA&state=BBB HTTP/1.1")
	_ok(bool(good["ok"]), "callback parses")
	_eq(good["code"], "AAA", "callback code")
	_eq(good["state"], "BBB", "callback state")

	var cancelled: Dictionary = PkceScript.parse_callback(
		"GET /cb?error=access_denied&error_description=The+user+cancelled HTTP/1.1")
	_ok(bool(cancelled["ok"]), "cancel is a recognised outcome")
	_eq(cancelled["error"], "access_denied", "cancel reason")
	_eq(cancelled["code"], "", "cancel carries no code")

	# A favicon probe must never be mistaken for the callback.
	var probe: Dictionary = PkceScript.parse_callback("GET /favicon.ico HTTP/1.1")
	_ok(not bool(probe["ok"]), "non-callback path ignored")
	_eq(probe["path"], "/favicon.ico", "probe path reported for the 404")

	_ok(not bool((PkceScript.parse_callback("garbage") as Dictionary)["ok"]), "garbage rejected")


# ── Config ───────────────────────────────────────────────────────────────────

func _test_config_url_and_snowflake() -> void:
	_ok(DiscordConfig.is_allowed_api_url("https://discord.com/api/v10/users/@me"), "discord.com allowed")
	_ok(DiscordConfig.is_allowed_api_url("https://discordapp.com/api/webhooks/1/x"), "legacy host allowed")
	_ok(not DiscordConfig.is_allowed_api_url("http://discord.com/api"), "plain http refused")
	_ok(not DiscordConfig.is_allowed_api_url("https://evil.example/discord.com/api"), "path spoof refused")
	# Userinfo is the classic bypass: https://discord.com@evil.example/ resolves
	# to evil.example while reading as discord.com.
	_ok(not DiscordConfig.is_allowed_api_url("https://discord.com@evil.example/api"), "userinfo spoof refused")
	_ok(not DiscordConfig.is_allowed_api_url("https://discord.com.evil.example/api"), "suffix spoof refused")
	_ok(not DiscordConfig.is_allowed_api_url(""), "empty refused")

	_ok(DiscordConfig.is_snowflake("123456789012345678"), "18-digit snowflake")
	_ok(DiscordConfig.is_snowflake("12345678901234567"), "17-digit snowflake")
	_ok(not DiscordConfig.is_snowflake("1234567890123456"), "16 digits rejected")
	_ok(not DiscordConfig.is_snowflake("123456789012345678901"), "21 digits rejected")
	_ok(not DiscordConfig.is_snowflake("12345678901234567a"), "non-digit rejected")
	_ok(not DiscordConfig.is_snowflake("../../etc/passwd"), "path fragment rejected")

	_eq(DiscordConfig.all_redirect_uris().size(), DiscordConfig.REDIRECT_PORTS.size(),
		"one redirect uri per reserved port")


# ── Community file ───────────────────────────────────────────────────────────

func _sample_community() -> Dictionary:
	return {
		"v": 1,
		"kind": "simbiogenesis.community",
		"name": "Bombay Beach Builders",
		"client_id": "111111111111111111",
		"guild_id": "222222222222222222",
		"role_ids": ["333333333333333333"],
		"voice_channel_id": "444444444444444444",
		"directory_channel_id": "555555555555555555",
		"directory_webhook": "https://discord.com/api/webhooks/666666666666666666/abcdef",
		"directory_message_id": "777777777777777777",
		"relay_webhook": "https://discord.com/api/webhooks/888888888888888888/ghijkl",
	}


func _test_community_roundtrip() -> void:
	var src := _sample_community()
	var enc: Dictionary = CommunityScript.encode(src)
	_ok(bool(enc["ok"]), "community encodes")
	var code := str(enc["code"])
	_ok(code.begins_with(CommunityScript.PREFIX), "community code prefix")

	var dec: Dictionary = CommunityScript.decode(code)
	_ok(bool(dec["ok"]), "community decodes")
	var got: Dictionary = dec["community"]
	for key in ["guild_id", "voice_channel_id", "directory_webhook", "directory_message_id", "name"]:
		_eq(got[key], src[key], "round-trip %s" % key)
	_eq((got["role_ids"] as Array).size(), 1, "round-trip role count")

	# JSON file form is the same schema.
	var text: String = CommunityScript.to_json_text(got)
	var reparsed: Dictionary = CommunityScript.from_json_text(text)
	_ok(bool(reparsed["ok"]), "json text form parses")
	_eq((reparsed["community"] as Dictionary)["guild_id"], src["guild_id"], "json text guild id")

	_eq(CommunityScript.storage_path(got),
		"%s/%s.json" % [DiscordConfig.COMMUNITY_DIR, src["guild_id"]], "storage path")

	# Sharing one webhook for both jobs is legal but worth warning about.
	var shared := _sample_community()
	shared["relay_webhook"] = shared["directory_webhook"]
	var warns: PackedStringArray = CommunityScript.warnings(
		(CommunityScript.validate(shared) as Dictionary)["community"])
	_ok(warns.size() > 0, "shared webhook warns")


func _test_community_rejects() -> void:
	_ok(not bool((CommunityScript.decode("nope") as Dictionary)["ok"]), "wrong prefix rejected")
	_ok(not bool((CommunityScript.decode("") as Dictionary)["ok"]), "empty rejected")

	var bad_ver := _sample_community()
	bad_ver["v"] = 99
	_ok(not bool((CommunityScript.validate(bad_ver) as Dictionary)["ok"]), "bad version rejected")

	var bad_kind := _sample_community()
	bad_kind["kind"] = "something.else"
	_ok(not bool((CommunityScript.validate(bad_kind) as Dictionary)["ok"]), "wrong kind rejected")

	var bad_guild := _sample_community()
	bad_guild["guild_id"] = "not-an-id"
	_ok(not bool((CommunityScript.validate(bad_guild) as Dictionary)["ok"]), "non-snowflake guild rejected")

	var many := _sample_community()
	var roles: Array = []
	for i in CommunityScript.MAX_ROLE_IDS + 2:
		roles.append("33333333333333333%d" % (i % 10))
	many["role_ids"] = roles
	_ok(not bool((CommunityScript.validate(many) as Dictionary)["ok"]), "too many roles rejected")

	# THE security case. Without this, a pasted community file silently
	# redirects the host's relayed chat to an attacker's endpoint.
	for evil in [
		"https://evil.example/api/webhooks/1/x",
		"http://discord.com/api/webhooks/1/x",
		"https://discord.com/api/webhooks/",
		"https://discord.com.evil.example/api/webhooks/1/x",
	]:
		var bad := _sample_community()
		bad["relay_webhook"] = evil
		_ok(not bool((CommunityScript.validate(bad) as Dictionary)["ok"]),
			"non-discord webhook rejected: %s" % evil)


# ── Directory record ─────────────────────────────────────────────────────────

func _live_record(now: int, claim := "aaaa", seq := 4) -> Dictionary:
	return {
		"v": DirScript.VERSION,
		"seq": seq,
		"host": DirScript.host_block({
			"claim": claim, "user": "222222222222222222", "name": "Sam",
			"pub": "203.0.113.9:34197", "lan": "192.168.1.42:34197",
			"code": "SMB2:x", "map": {"label": "Mount Vernon"},
			"peers": 3, "started": now - 600, "hb": now - 5,
		}),
	}


func _test_directory_render_parse() -> void:
	var now := 1_800_000_000
	var rec := _live_record(now)
	var content: String = DirScript.render(rec, _sample_community())
	_ok(content.contains("Sam is hosting"), "human header names the host")
	_ok(content.contains(DirScript.FENCE), "machine block fenced")
	_ok(content.length() <= DirScript.MAX_CONTENT, "content within Discord's limit")

	var parsed: Dictionary = DirScript.parse(content)
	_ok(bool(parsed["ok"]), "render round-trips through parse")
	var back: Dictionary = parsed["record"]
	_eq((back["host"] as Dictionary)["claim"], "aaaa", "claim survives")
	_eq(back["seq"], 4, "seq survives")

	# Empty state renders and parses too.
	var empty: Dictionary = DirScript.parse(DirScript.render(DirScript.blank()))
	_ok(bool(empty["ok"]), "blank record parses")
	_ok(not DirScript.has_host(empty["record"]), "blank record has no host")

	# Someone typed over the message. The caller must be able to tell this from
	# garbage, because stomping a human conversation in that channel is worse
	# than failing to publish.
	var human: Dictionary = DirScript.parse("hey does anyone know when we're playing?")
	_ok(not bool(human["ok"]), "prose is not a record")
	_ok(bool(human["human_text"]), "prose flagged as human text")

	var wrong_ver: Dictionary = DirScript.parse("%s\n{\"v\":99}\n%s" % [DirScript.FENCE, DirScript.FENCE_END])
	_ok(not bool(wrong_ver["ok"]), "unknown record version rejected")


func _test_directory_staleness() -> void:
	var now := 1_800_000_000
	var rec := _live_record(now)
	_ok(not DirScript.is_stale(rec, now), "fresh heartbeat is live")

	# Boundary, both sides.
	(rec["host"] as Dictionary)["hb"] = now - DirScript.STALE_SEC
	_ok(not DirScript.is_stale(rec, now), "exactly STALE_SEC old is still live")
	(rec["host"] as Dictionary)["hb"] = now - DirScript.STALE_SEC - 1
	_ok(DirScript.is_stale(rec, now), "one second past STALE_SEC is stale")

	(rec["host"] as Dictionary)["hb"] = 0
	_ok(DirScript.is_stale(rec, now), "no heartbeat is stale")
	_ok(DirScript.is_stale(DirScript.blank(), now), "empty record is stale")

	var live := _live_record(now)
	_ok(DirScript.live_host_other_than(live, "mine", now), "someone else is hosting")
	_ok(not DirScript.live_host_other_than(live, "aaaa", now), "that host is us")

	_ok(DirScript.status_text(live, now).contains("Sam"), "status names the host")
	_ok(DirScript.status_text(DirScript.blank(), now).contains("Nobody"), "empty status is inviting")


func _test_directory_election() -> void:
	var now := 1_800_000_000

	# Two clients race. Discord serialises the PATCHes and last write wins the
	# stored content, so after the same fixed confirm delay exactly one of them
	# reads back its own claim.
	var observed := DirScript.blank()
	var mine: Dictionary = DirScript.claim_record(observed,
		{"claim": "mine", "name": "A", "hb": now})
	var theirs: Dictionary = DirScript.claim_record(observed,
		{"claim": "theirs", "name": "B", "hb": now})
	_eq(mine["seq"], 1, "claim increments seq")
	_eq(theirs["seq"], 1, "both racers derive the same seq from the same read")

	# Whoever's PATCH landed last is what both then read.
	_eq(DirScript.arbitrate(theirs, "theirs", now), "won", "winner sees its own claim")
	_eq(DirScript.arbitrate(theirs, "mine", now), "lost", "loser sees the winner's claim")
	var winners := 0
	for claim in ["mine", "theirs"]:
		if DirScript.arbitrate(theirs, claim, now) == "won":
			winners += 1
	_eq(winners, 1, "exactly one winner")

	# Nothing readable -> retry, never a silent double-host.
	_eq(DirScript.arbitrate(DirScript.blank(), "mine", now), "retry", "empty read retries")
	var stale_foreign := _live_record(now, "someone_else", 9)
	(stale_foreign["host"] as Dictionary)["hb"] = now - DirScript.STALE_SEC - 60
	_eq(DirScript.arbitrate(stale_foreign, "mine", now), "retry", "stale foreign claim retries")
	_eq(DirScript.arbitrate(theirs, "", now), "lost", "no claim cannot win")

	# The +8 s reconfirm: a winner stands down if a LIVE later claim appeared.
	var later := _live_record(now, "someone_else", 7)
	_ok(DirScript.should_vacate(later, "mine", 5, now), "later live claim wins the reconfirm")
	_ok(not DirScript.should_vacate(later, "someone_else", 5, now), "our own claim never vacates")
	var earlier := _live_record(now, "someone_else", 3)
	_ok(not DirScript.should_vacate(earlier, "mine", 5, now), "earlier claim does not displace us")

	# A read that went backwards is a stale cache; ignoring it is what keeps the
	# two racers agreeing about which write was last.
	_ok(DirScript.seq_regressed({"seq": 3}, 5), "regressed seq detected")
	_ok(not DirScript.seq_regressed({"seq": 6}, 5), "advancing seq accepted")

	var vacated: Dictionary = DirScript.vacate_record(theirs)
	_ok(not DirScript.has_host(vacated), "vacate clears the host")
	_ok(int(vacated["seq"]) > int(theirs["seq"]), "vacate advances seq")

	_eq(DirScript.mint_claim().length(), 32, "claim token is 16 bytes of hex")
	_ok(DirScript.mint_claim() != DirScript.mint_claim(), "claim tokens differ")


# ── Gate rules ───────────────────────────────────────────────────────────────

func _oauth_me(app_id := "111111111111111111", scopes := ["identify", "guilds.members.read"],
		expires := "2099-01-01T00:00:00.000000+00:00") -> Dictionary:
	return {
		"application": {"id": app_id},
		"scopes": scopes,
		"expires": expires,
		"user": {"id": "222222222222222222", "username": "sam", "global_name": "Sam", "avatar": "abc"},
	}


func _test_gate_oauth_me() -> void:
	var now := 1_800_000_000
	var ok: Dictionary = GateScript.check_oauth_me(_oauth_me(), "111111111111111111", now)
	_ok(bool(ok["ok"]), "valid token accepted")
	_eq(ok["user_id"], "222222222222222222", "user id extracted")

	# The anti-replay defence: a token minted by ANY other Discord app must not
	# be accepted here, and users grant tokens to other apps freely.
	var wrong: Dictionary = GateScript.check_oauth_me(
		_oauth_me("999999999999999999"), "111111111111111111", now)
	_ok(not bool(wrong["ok"]), "token from another application rejected")
	_ok(bool(wrong["fatal"]), "wrong application is a fatal rejection")

	var no_scope: Dictionary = GateScript.check_oauth_me(
		_oauth_me("111111111111111111", ["identify"]), "111111111111111111", now)
	_ok(not bool(no_scope["ok"]), "missing guilds.members.read rejected")

	var expired: Dictionary = GateScript.check_oauth_me(
		_oauth_me("111111111111111111", ["identify", "guilds.members.read"],
			"2001-01-01T00:00:00+00:00"), "111111111111111111", now)
	_ok(not bool(expired["ok"]), "expired token rejected")

	_ok(not bool((GateScript.check_oauth_me({}, "111111111111111111", now) as Dictionary)["ok"]),
		"empty body rejected")

	# No configured application is a HOST misconfiguration, not a guest fault.
	var unconfigured: Dictionary = GateScript.check_oauth_me(_oauth_me(), "", now)
	_ok(not bool(unconfigured["ok"]), "no client id configured -> refuse")
	_ok(not bool(unconfigured["fatal"]), "…but not blamed on the guest")

	_ok(bool((GateScript.error_for_status(401, "me") as Dictionary)["fatal"]), "401 is fatal")
	_ok(not bool((GateScript.error_for_status(503, "me") as Dictionary)["fatal"]), "5xx is transient")
	_ok(str((GateScript.error_for_status(404, "member") as Dictionary)["error"]).contains("member"),
		"404 on the member call says 'not a member'")


func _test_gate_member() -> void:
	var member := {"roles": ["333333333333333333", "444444444444444444"],
		"nick": "Sammy", "user": {"id": "222222222222222222"}}

	var has: Dictionary = GateScript.check_member(member, ["333333333333333333"])
	_ok(bool(has["ok"]), "required role present")
	_eq(has["nick"], "Sammy", "nick extracted")

	var lacks: Dictionary = GateScript.check_member(member, ["999999999999999999"])
	_ok(not bool(lacks["ok"]), "required role absent")

	# An empty role list is a deliberate configuration statement — membership
	# alone is enough — mirroring MpHardening.trusted_key_allowed's empty case.
	_ok(bool((GateScript.check_member(member, []) as Dictionary)["ok"]), "no roles required -> membership suffices")

	# 404 from Discord arrives as an empty body.
	_ok(not bool((GateScript.check_member({}, []) as Dictionary)["ok"]), "non-member rejected")

	# Any one of several roles is enough.
	_ok(bool((GateScript.check_member(member,
		["999999999999999999", "444444444444444444"]) as Dictionary)["ok"]), "any listed role passes")


func _test_gate_iso8601() -> void:
	# Discord emits fractional seconds and an explicit offset; Godot's parser
	# accepts neither, so the leading 19 chars are taken as UTC.
	var t: int = GateScript.parse_iso8601("2026-08-12T20:07:11.898000+00:00")
	_ok(t > 0, "Discord-shaped timestamp parses")
	_eq(t, int(Time.get_unix_time_from_datetime_string("2026-08-12T20:07:11")), "fraction and offset ignored")
	_eq(GateScript.parse_iso8601(""), 0, "empty timestamp is 'unknown'")
	_eq(GateScript.parse_iso8601("not a date"), 0, "garbage timestamp is 'unknown'")
	# "Unknown" must read as no-expiry, never as expired.
	var no_exp: Dictionary = GateScript.check_oauth_me(
		_oauth_me("111111111111111111", ["identify", "guilds.members.read"], ""),
		"111111111111111111", 1_800_000_000)
	_ok(bool(no_exp["ok"]), "unparseable expiry does not reject a valid token")


# ── Links ────────────────────────────────────────────────────────────────────

func _test_links() -> void:
	var g := "222222222222222222"
	var c := "444444444444444444"
	_eq(LinksScript.voice_deep_link(g, c), "discord://-/channels/%s/%s" % [g, c], "voice deep link")
	_eq(LinksScript.voice_web_url(g, c), "https://discord.com/channels/%s/%s" % [g, c], "voice web url")
	_ok(LinksScript.message_url(g, c, "777777777777777777").ends_with("777777777777777777"),
		"permanent directory message link")

	# A hand-pasted community file must not be able to inject into shell_open.
	for bad in ["../../evil", "222222222222222222/../x", "", "abc"]:
		_eq(LinksScript.voice_deep_link(g, bad), "", "rejects channel id %s" % bad)
		_eq(LinksScript.voice_deep_link(bad, c), "", "rejects guild id %s" % bad)

	_ok(LinksScript.avatar_url("222222222222222222", "abc123").contains("/avatars/"), "avatar url")
	_ok(LinksScript.avatar_url("222222222222222222", "a_abc123").contains(".gif"),
		"animated avatar uses gif")
	_eq(LinksScript.avatar_url("222222222222222222", ""), "", "no avatar hash -> no url")
	_eq(LinksScript.avatar_url("222222222222222222", "../evil"), "", "non-hex avatar hash rejected")

	# Preserve the shape multiplayer_selftest already pins, including the spoof.
	_ok(LinksScript.is_valid_invite_url("https://discord.gg/abc"), "invite accepted")
	_ok(LinksScript.is_valid_invite_url("https://discord.com/invite/abc"), "invite path accepted")
	_ok(not LinksScript.is_valid_invite_url("https://evil.example/discord.gg/x"), "invite spoof rejected")
	_ok(not LinksScript.is_valid_invite_url(""), "empty invite rejected")

	_ok(LinksScript.is_openable(LinksScript.voice_deep_link(g, c)), "deep link is openable")
	_ok(LinksScript.is_openable("https://discord.gg/abc"), "invite is openable")
	_ok(not LinksScript.is_openable("file:///etc/passwd"), "file url not openable")
	_ok(not LinksScript.is_openable("https://evil.example/"), "arbitrary url not openable")


# ── Reachability ─────────────────────────────────────────────────────────────

func _test_reachability_classify() -> void:
	for ip in ["10.0.0.1", "172.16.5.5", "172.31.255.254", "192.168.1.42", "127.0.0.1", "169.254.1.1"]:
		_ok(ReachScript.is_private_ipv4(ip), "%s is private" % ip)
	for ip in ["172.15.0.1", "172.32.0.1", "203.0.113.9", "8.8.8.8"]:
		_ok(not ReachScript.is_private_ipv4(ip), "%s is not private" % ip)

	# 100.64.0.0/10 — carrier-grade NAT. A host behind it CANNOT be forwarded,
	# so telling them to check their router would be actively wrong advice.
	for ip in ["100.64.0.1", "100.100.5.5", "100.127.255.254"]:
		_ok(ReachScript.is_cgnat(ip), "%s is CGNAT" % ip)
	for ip in ["100.63.255.255", "100.128.0.1", "100.0.0.1"]:
		_ok(not ReachScript.is_cgnat(ip), "%s is outside the CGNAT block" % ip)

	_ok(ReachScript.is_routable_public("203.0.113.9"), "public address is routable")
	_ok(not ReachScript.is_routable_public("100.64.0.1"), "CGNAT is not routable")
	_ok(not ReachScript.is_routable_public("192.168.1.1"), "private is not routable")
	_ok(not ReachScript.is_routable_public("garbage"), "garbage is not routable")

	_ok(ReachScript.same_subnet16("192.168.1.5", "192.168.9.9"), "same /16")
	_ok(not ReachScript.same_subnet16("192.168.1.5", "10.0.0.1"), "different /16")

	var addrs := [
		{"h": "192.168.1.42", "p": 34197, "k": "lan"},
		{"h": "203.0.113.9", "p": 34197, "k": "pub"},
	]
	# Same LAN -> try LAN first.
	var near: Array = ReachScript.candidate_order(addrs, "192.168.1.7")
	_eq((near[0] as Dictionary)["k"], "lan", "same-subnet client tries LAN first")
	# Different network -> public first. The naive "always LAN first" costs
	# every internet player a pointless timeout on an unreachable address.
	var far: Array = ReachScript.candidate_order(addrs, "10.1.2.3")
	_eq((far[0] as Dictionary)["k"], "pub", "remote client tries public first")
	_eq(far.size(), 2, "no candidate is dropped")
	_eq(ReachScript.candidate_order([], "10.1.2.3").size(), 0, "no addresses -> no candidates")
	_eq(ReachScript.candidate_order([{"h": "", "p": 0, "k": "lan"}], "10.1.2.3").size(), 0,
		"malformed candidate dropped")


func _test_reachability_upnp_text() -> void:
	# Sweep every engine constant so a new one cannot render to a player as a
	# bare number.
	_ok(ClassDB.class_exists("UPNP"), "UPNP is available in this build")
	var names: PackedStringArray = ClassDB.class_get_enum_constants("UPNP", "UPNPResult")
	_ok(names.size() > 0, "UPNPResult enum is reachable")
	for n in names:
		var code: int = ClassDB.class_get_integer_constant("UPNP", n)
		var text: String = ReachScript.upnp_error_text(code)
		_ok(not text.is_empty(), "%s has text" % n)
		_ok(not text.begins_with("UPnP error "), "%s has specific text (add it to the match)" % n)

	var no_gw := {"gateway": false, "code": UPNP.UPNP_RESULT_NO_GATEWAY, "mapped": false, "external_ip": ""}
	_ok(ReachScript.diagnosis(no_gw, 34197).contains("Tailscale"), "no gateway suggests a VPN")
	var cgnat := {"gateway": true, "code": UPNP.UPNP_RESULT_SUCCESS, "mapped": true, "external_ip": "100.64.3.4"}
	_ok(ReachScript.diagnosis(cgnat, 34197).contains("carrier-grade"), "CGNAT named explicitly")
	var good := {"gateway": true, "code": UPNP.UPNP_RESULT_SUCCESS, "mapped": true, "external_ip": "203.0.113.9"}
	var text_good: String = ReachScript.diagnosis(good, 34197)
	_ok(text_good.contains("203.0.113.9"), "success reports the public address")
	# We run no external server, so we cannot honestly claim the port is open.
	_ok(text_good.contains("not verified"), "success is honest about being unverified")


# ── Relay batcher ────────────────────────────────────────────────────────────

func _test_relay_batcher() -> void:
	var b: DiscordRelayBatcher = BatcherScript.new()
	b.configure("Mount Vernon")

	b.enqueue("Sam", "hello", "https://cdn.discordapp.com/avatars/1/a.png")
	b.enqueue("Sam", "again")
	b.enqueue("Jo", "hi")
	b.enqueue("Kit", "hey")
	b.enqueue("Lee", "yo")
	var out: Array = b.build_flush(0.0)
	_ok(out.size() <= BatcherScript.MAX_EXECUTES_PER_FLUSH,
		"at most %d executes per flush" % BatcherScript.MAX_EXECUTES_PER_FLUSH)

	# The rule that stops an in-game "@everyone" pinging the whole server.
	for p_v in out:
		var p: Dictionary = p_v
		_ok(p.has("allowed_mentions"), "payload declares allowed_mentions")
		_eq(((p["allowed_mentions"] as Dictionary)["parse"] as Array).size(), 0,
			"allowed_mentions.parse is empty")
		_ok(str(p["content"]).length() <= BatcherScript.MAX_CONTENT, "content within limit")
	_eq(str((out[0] as Dictionary)["username"]), "Sam", "first run keeps its author")
	_ok(str((out[0] as Dictionary)["content"]).contains("hello")
		and str((out[0] as Dictionary)["content"]).contains("again"),
		"consecutive lines from one author merge")
	_ok(str((out[-1] as Dictionary)["content"]).contains("**Jo:**"), "overflow authors are inlined")
	_eq(b.pending(), 0, "flush empties the queue")
	_eq(b.build_flush(0.0).size(), 0, "nothing to flush twice")

	# Overflow is counted and reported, never silently lost.
	for i in BatcherScript.MAX_QUEUE + 5:
		b.enqueue("Spammer", "msg %d" % i)
	_ok(b.dropped() > 0, "queue overflow counted")
	var out2: Array = b.build_flush(0.0)
	var joined := ""
	for p2 in out2:
		joined += str((p2 as Dictionary)["content"])
	_ok(joined.contains("dropped"), "dropped count surfaces to the channel")

	# 429 handling: requeue at the front, then cool down after repeats.
	b.enqueue("Sam", "important")
	var payloads: Array = b.build_flush(0.0)
	b.requeue_payload(payloads[0] as Dictionary)
	_ok(b.pending() > 0, "429 requeues rather than drops")
	var wait: float = b.note_429(1.5, 0.0)
	_ok(wait >= 1.5, "429 honours retry_after")
	_ok(b.is_cooling_down(0.5), "cooling down blocks the next flush")
	_eq(b.build_flush(0.5).size(), 0, "no sends while cooling down")
	b.note_429(1.0, 10.0)
	var long_wait: float = b.note_429(1.0, 10.0)
	_eq(long_wait, BatcherScript.COOLDOWN_SEC, "three consecutive 429s trigger the cool-down")

	# Long messages are truncated, not rejected.
	var b2: DiscordRelayBatcher = BatcherScript.new()
	b2.enqueue("Sam", "x".repeat(BatcherScript.MAX_CONTENT * 2))
	var long_out: Array = b2.build_flush(0.0)
	_ok(str((long_out[0] as Dictionary)["content"]).length() <= BatcherScript.MAX_CONTENT,
		"oversized message truncated")

	# Empty input is a no-op.
	var b3: DiscordRelayBatcher = BatcherScript.new()
	b3.enqueue("Sam", "   ")
	_eq(b3.pending(), 0, "whitespace-only message ignored")


# ── Telemetry redaction ──────────────────────────────────────────────────────

func _test_redaction() -> void:
	var payload := {
		"peer_id": 7,
		"hello": {
			"discord_token": "SECRETVALUE",
			"name": "Sam",
			"nested": [{"access_token": "ALSOSECRET"}, {"ok": true}],
		},
		"join_code": "SMB2:whatever",
		"code": 429,
	}
	var red: Dictionary = HardeningScript.redact(payload)
	var text := JSON.stringify(red)
	_ok(not text.contains("SECRETVALUE"), "top-level nested token redacted")
	_ok(not text.contains("ALSOSECRET"), "token inside an array redacted")
	_ok(not text.contains("SMB2:whatever"), "join code redacted (it carries the session token)")
	_ok(text.contains("Sam"), "non-secret fields survive")
	# HTTP/UPnP status codes are named `code` all over this project; redacting
	# them would gut diagnostics while protecting nothing.
	_ok(text.contains("429"), "status codes are not redacted")
	_eq(int(red["peer_id"]), 7, "scalars pass through")

	# The original must not be mutated — the caller may still need the token.
	_eq(((payload["hello"] as Dictionary)["discord_token"]), "SECRETVALUE", "redact copies, never mutates")

	# Cycles/depth cannot hang the logger.
	var deep: Dictionary = {}
	var cur := deep
	for i in 20:
		var next: Dictionary = {}
		cur["n"] = next
		cur = next
	_ok(HardeningScript.redact(deep) != null, "deep nesting is bounded")


# ── Admission states ─────────────────────────────────────────────────────────

func _test_admission() -> void:
	var peers := {2: {"name": "A", "ready": true}, 3: {"name": "B", "ready": false}}
	var pending := {3: {"started_ms": 1000}}

	_ok(HardeningScript.peer_is_admitted(peers, 1), "host is always admitted")
	_ok(HardeningScript.peer_is_admitted(peers, 2), "ready peer is admitted")
	_ok(not HardeningScript.peer_is_admitted(peers, 3), "pending peer is not admitted")
	_ok(not HardeningScript.peer_is_admitted(peers, 99), "unknown peer is not admitted")

	var admitted: Dictionary = HardeningScript.admission_decision(peers, pending, 2)
	_ok(bool(admitted["allow"]), "admitted peer allowed")

	# The distinction that matters: a slow Discord round-trip must HOLD the peer,
	# not kick it. The rate-limit path kicks; this one must not.
	var waiting: Dictionary = HardeningScript.admission_decision(peers, pending, 3)
	_ok(not bool(waiting["allow"]), "pending peer is not allowed to act")
	_ok(bool(waiting["pending"]), "…but is flagged pending, so the caller holds instead of kicking")

	var stranger: Dictionary = HardeningScript.admission_decision(peers, pending, 99)
	_ok(not bool(stranger["allow"]), "unknown peer not allowed")
	_ok(not bool(stranger["pending"]), "unknown peer is not pending")

	var timeout_ms := int(HardeningScript.ADMISSION_TIMEOUT_SEC * 1000.0)
	_eq(HardeningScript.expired_admissions(pending, 1000 + timeout_ms).size(), 0,
		"exactly at the timeout is not yet expired")
	_eq(HardeningScript.expired_admissions(pending, 1000 + timeout_ms + 1).size(), 1,
		"one millisecond past the timeout expires")
	_eq(HardeningScript.expired_admissions({}, 999_999).size(), 0, "nothing pending, nothing expires")


# ── Join code v3 ─────────────────────────────────────────────────────────────

func _test_join_code_v3() -> void:
	var enc: Dictionary = JoinCodeScript.encode({
		"addrs": [
			{"h": "192.168.1.42", "p": 34197, "k": "lan"},
			{"h": "203.0.113.9", "p": 34197, "k": "pub"},
		],
		"token": "tok",
		"name": "Mount Vernon",
		"exp": 4_102_444_800,
		"has_pw": true,
		"dsc": {"g": "222222222222222222", "need": true},
		"map": {"kind": "generated", "latitude": 48.3252, "longitude": -122.2469},
	})
	_ok(bool(enc["ok"]), "v3 encodes")
	_eq((enc["payload"] as Dictionary)["v"], 3, "emits v3")

	var dec: Dictionary = JoinCodeScript.decode(str(enc["code"]), 1)
	_ok(bool(dec["ok"]), "v3 decodes")
	_eq((dec["addrs"] as Array).size(), 2, "both candidates survive")
	# Every existing consumer still reads ip/port; the ladder is purely additive.
	_eq(dec["ip"], "192.168.1.42", "top-level ip mirrors the LAN address")
	_eq(dec["port"], 34197, "top-level port preserved")
	_ok(bool(dec["has_pw"]), "password flag preserved")
	_ok(JoinCodeScript.needs_discord(dec), "Discord requirement advertised up front")
	_eq(JoinCodeScript.discord_guild(dec), "222222222222222222", "guild hint preserved")
	_eq((dec["map"] as Dictionary)["latitude"], 48.3252, "map identity preserved")

	# A bare ip:port still works and carries no Discord requirement.
	var bare: Dictionary = JoinCodeScript.decode("10.0.0.5:34197")
	_ok(bool(bare["ok"]) and bool(bare["bare"]), "bare ip:port still accepted")
	_ok(not JoinCodeScript.needs_discord(bare), "bare code needs no Discord")

	# Unknown versions must still be rejected.
	_ok(not bool((JoinCodeScript.decode("SMB2:" + Marshalls.raw_to_base64(
		JSON.stringify({"v": 999}).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)))
		as Dictionary)["ok"]), "unknown version rejected")

	# Expiry still enforced.
	var expiring: Dictionary = JoinCodeScript.encode({"ip": "10.0.0.1", "port": 1, "exp": 100})
	_ok(not bool((JoinCodeScript.decode(str(expiring["code"]), 200) as Dictionary)["ok"]),
		"expired code rejected")


## Codes already pasted into people's Discord messages must keep working. This
## literal was produced by the v2 encoder and is frozen here so a codec change
## cannot silently invalidate them.
func _test_join_code_frozen_v2() -> void:
	var dec: Dictionary = JoinCodeScript.decode(FROZEN_V2_CODE, 1)
	_ok(bool(dec["ok"]), "frozen v2 code still decodes: %s" % str(dec.get("error", "")))
	if not bool(dec["ok"]):
		return
	_eq(dec["ip"], "192.168.1.42", "v2 ip")
	_eq(dec["port"], 34197, "v2 port")
	_eq(dec["token"], "abcd", "v2 token")
	_eq(dec["name"], "Frozen v2", "v2 name")
	_ok(bool(dec["has_pw"]), "v2 password flag")
	_eq((dec["map"] as Dictionary)["latitude"], 48.3252, "v2 map identity")
	# A v2 code has no candidate list, so one is synthesised from ip/port —
	# otherwise the connect ladder would have nothing to try.
	_eq((dec["addrs"] as Array).size(), 1, "v2 synthesises a single candidate")
	_eq(((dec["addrs"] as Array)[0] as Dictionary)["k"], "lan", "v2 address is treated as LAN")
	_ok(not JoinCodeScript.needs_discord(dec), "v2 code carries no Discord requirement")


# ── DiscordIdentity (offline contract) ───────────────────────────────────────
#
# The autoload is looked up by node path, never by the bare `DiscordIdentity`
# identifier: a bare autoload reference in a `--script` selftest is a documented
# trap in this project — it fails the compile and silently aborts the test
# function while PASS still prints.

func _identity() -> Node:
	return root.get_node_or_null("DiscordIdentity")


func _test_identity_offline() -> void:
	var id := _identity()
	_ok(id != null, "DiscordIdentity autoload is registered")
	if id == null:
		return
	# A fresh install has no credentials and must behave as "Discord is simply
	# not part of this session" rather than erroring anywhere.
	_ok(not bool(id.call("is_signing_in")), "not signing in at rest")
	if not bool(id.call("is_signed_in")):
		_eq(id.call("present_token"), "", "no token to present when signed out")
		_ok(str(id.call("status_text")).contains("Not signed in"), "status says signed out")

	# With no application configured, sign-in must refuse with something the
	# player can act on rather than opening a browser to a broken URL.
	if str(id.call("client_id", {})).is_empty():
		_ok(not bool(id.call("is_available", {})), "unavailable without a client id")
		var res: Dictionary = id.call("begin_sign_in", {})
		_ok(not bool(res.get("ok", false)), "sign-in refused with no client id")
		_ok(str(res.get("error", "")).contains("community"),
			"refusal points at the community file / config")

	# A community file supplies its own application id, so importing one is
	# enough to make sign-in available.
	_eq(DiscordConfig.resolve_client_id({"client_id": "111111111111111111"}),
		"111111111111111111", "community client id wins")

	# An invalid guild must not reach the network.
	var got := {}
	id.connect("membership_checked", func(g: String, r: Dictionary) -> void:
		got[g] = r, CONNECT_ONE_SHOT)
	id.call("fetch_membership", "not-a-guild")
	_ok(got.has("not-a-guild"), "invalid guild answered synchronously")
	if got.has("not-a-guild"):
		_ok(not bool((got["not-a-guild"] as Dictionary).get("ok", false)), "invalid guild rejected")


## Binding the loopback callback listener touches no network — but it is the
## step that fails opaquely in the field (a second copy of the game holding the
## port), so the "all ports busy" path is worth pinning.
func _test_identity_loopback() -> void:
	var held: Array = []
	for port in DiscordConfig.REDIRECT_PORTS:
		var s := TCPServer.new()
		if s.listen(int(port), "127.0.0.1") == OK:
			held.append(s)
	_ok(held.size() > 0, "at least one redirect port is bindable on this machine")

	var id := _identity()
	if id != null and held.size() == DiscordConfig.REDIRECT_PORTS.size():
		# Every registered port is occupied — sign-in must refuse loudly rather
		# than fall back to an unregistered port Discord would reject.
		var res: Dictionary = id.call("begin_sign_in", {"client_id": "111111111111111111"})
		_ok(not bool(res.get("ok", false)), "sign-in refuses when every redirect port is busy")
		_ok(str(res.get("error", "")).contains("busy"), "refusal names the port conflict")
		if bool(res.get("ok", false)):
			id.call("cancel_sign_in")
	for s in held:
		(s as TCPServer).stop()

	# The redirect URI must be byte-identical between the authorize request and
	# the token exchange, and must match what is registered in the dev portal.
	for port in DiscordConfig.REDIRECT_PORTS:
		var uri: String = DiscordConfig.redirect_uri(int(port))
		_ok(uri.begins_with("http://127.0.0.1:"), "redirect %s is loopback" % uri)
		_ok(uri.ends_with(DiscordConfig.REDIRECT_PATH), "redirect %s ends with the callback path" % uri)


# ── Community store (touches user://, snapshots and restores) ────────────────
#
# Same write-discipline the veg harnesses already follow: a selftest must never
# leave a player's imported communities or active-community pointer changed.

func _snapshot_paths() -> Array:
	var out: Array = []
	var dir := DirAccess.open(DiscordConfig.COMMUNITY_DIR)
	if dir != null:
		for f in dir.get_files():
			out.append("%s/%s" % [DiscordConfig.COMMUNITY_DIR, f])
	out.append(SimCommunity.PREFS_PATH)
	return out


func _snapshot(paths: Array) -> Dictionary:
	var snap: Dictionary = {}
	for p in paths:
		if FileAccess.file_exists(p):
			var f := FileAccess.open(p, FileAccess.READ)
			if f != null:
				snap[p] = f.get_buffer(f.get_length())
				f.close()
		else:
			snap[p] = null
	return snap


func _restore(snap: Dictionary) -> void:
	for p in snap:
		if snap[p] == null:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(str(p)))
			continue
		var f := FileAccess.open(str(p), FileAccess.WRITE)
		if f != null:
			f.store_buffer(snap[p] as PackedByteArray)
			f.close()


func _test_community_store() -> void:
	var test_guild := "999999999999999999"
	var test_path := "%s/%s.json" % [DiscordConfig.COMMUNITY_DIR, test_guild]
	var paths := _snapshot_paths()
	if not paths.has(test_path):
		paths.append(test_path)
	var snap := _snapshot(paths)
	var had_active := SimCommunity.active_guild_id()

	var community := _sample_community()
	community["guild_id"] = test_guild
	community["name"] = "Selftest Community"
	var saved: Dictionary = SimCommunity.save_to_disk(community)
	_ok(bool(saved.get("ok", false)), "community saves to disk")
	_ok(FileAccess.file_exists(test_path), "community file exists at its guild-keyed path")

	var loaded: Dictionary = SimCommunity.load_from_disk(test_guild)
	_eq(loaded.get("name", ""), "Selftest Community", "load round-trips the name")
	_eq(loaded.get("directory_webhook", ""), community["directory_webhook"], "webhook survives disk")

	var listed: Array = SimCommunity.list_on_disk()
	var found := false
	for c in listed:
		if str((c as Dictionary).get("guild_id", "")) == test_guild:
			found = true
	_ok(found, "saved community appears in the list")

	SimCommunity.set_active(loaded)
	_eq(SimCommunity.active_guild_id(), test_guild, "active pointer persists")
	_eq((SimCommunity.active() as Dictionary).get("guild_id", ""), test_guild, "active() resolves it")

	# A file that fails validation must never reach disk — the webhook in it is
	# a credential the host would POST to.
	var evil := community.duplicate(true)
	evil["relay_webhook"] = "https://evil.example/api/webhooks/1/x"
	_ok(not bool((SimCommunity.save_to_disk(evil) as Dictionary).get("ok", false)),
		"a community with a non-Discord webhook is never persisted")

	_eq(SimCommunity.load_from_disk("not-a-guild"), {}, "invalid guild loads nothing")

	SimCommunity.forget(test_guild)
	_ok(not FileAccess.file_exists(test_path), "forget removes the file")

	_restore(snap)
	_eq(SimCommunity.active_guild_id(), had_active,
		"selftest restored the player's active community")


# ── Directory election, end to end ───────────────────────────────────────────
#
# The pure `arbitrate`/`should_vacate` checks above prove the DECISION; this
# proves the WIRING — read, claim, wait out the confirm window, re-read, decide
# — against a stand-in for Discord's webhook endpoints. No network, no Discord
# application, no user:// writes (the message id is pre-set so every write is a
# PATCH rather than a mint).

class FakeDiscordHttp extends Node:
	## Behaves like the webhook message endpoints: GET returns whatever the last
	## write stored, PATCH/POST replace it.
	var content := ""
	var calls: Array = []
	var fail_patch := false

	func get_json(_url: String, on_done: Callable, _bearer: String = "") -> void:
		calls.append("GET")
		on_done.call_deferred({"ok": true, "code": 200, "body": {"content": content},
			"raw": "", "error": ""})

	func patch_json(_url: String, payload: Dictionary, on_done: Callable,
			_bearer: String = "", _no_retry: bool = false) -> void:
		calls.append("PATCH")
		if fail_patch:
			on_done.call_deferred({"ok": false, "code": 429, "body": {}, "raw": "",
				"error": "rate limited"})
			return
		content = str(payload.get("content", ""))
		on_done.call_deferred({"ok": true, "code": 200, "body": {}, "raw": "", "error": ""})

	func post_json(_url: String, payload: Dictionary, on_done: Callable,
			_bearer: String = "") -> void:
		calls.append("POST")
		content = str(payload.get("content", ""))
		on_done.call_deferred({"ok": true, "code": 200,
			"body": {"id": "777777777777777777", "channel_id": "555555555555555555"},
			"raw": "", "error": ""})


func _test_directory_election_live() -> void:
	var dir := root.get_node_or_null("DiscordDirectory")
	_ok(dir != null, "DiscordDirectory autoload is registered")
	if dir == null:
		return

	var community := _sample_community()
	var fake := FakeDiscordHttp.new()
	root.add_child(fake)
	var saved_http = dir.get("_http")
	dir.set("_http", fake)
	dir.call("set_community", community)
	_ok(bool(dir.call("is_configured")), "sample community configures the directory")
	_ok(str(dir.call("permanent_link")).contains("777777777777777777"),
		"permanent link points at the directory message")

	var outcomes: Array = []
	var cb := func(won: bool, _rec: Dictionary) -> void: outcomes.append(won)
	dir.connect("election_result", cb)

	# 1. Nobody hosting -> we take the seat.
	fake.content = DirScript.render(DirScript.blank(), community)
	dir.call("play_together")
	await _await_outcome(outcomes, 8.0)
	_eq(outcomes.size(), 1, "empty directory produced one election result")
	if outcomes.size() == 1:
		_ok(bool(outcomes[0]), "won the election over an empty directory")
	_eq(dir.get("state"), DiscordDirectoryState_HOSTING(), "winner is in the HOSTING state")
	# The published message must be readable back — a directory nobody can parse
	# is a directory nobody can join through.
	var parsed: Dictionary = DirScript.parse(fake.content)
	_ok(bool(parsed.get("ok", false)), "published content parses back")
	_ok(DirScript.has_host(parsed.get("record", {}) as Dictionary), "published record names a host")

	# 2. A LIVE foreign host -> stand down and offer the join instead.
	dir.call("vacate")
	dir.set("_highest_seq", 0)
	var now := int(Time.get_unix_time_from_system())
	fake.content = DirScript.render({"v": 1, "seq": 90, "host": DirScript.host_block({
		"claim": "someone_else", "name": "Sam", "code": "SMB2:x",
		"map": {"label": "Mount Vernon"}, "peers": 2, "started": now - 60, "hb": now,
	})}, community)
	outcomes.clear()
	dir.call("play_together")
	await _await_outcome(outcomes, 8.0)
	_eq(outcomes.size(), 1, "live host produced one election result")
	if outcomes.size() == 1:
		_ok(not bool(outcomes[0]), "did NOT claim over a live host")

	# 3. The same host gone quiet -> the seat is free again. This is what makes
	#    "first person to join becomes the host" work after a crash.
	dir.set("_highest_seq", 0)
	fake.content = DirScript.render({"v": 1, "seq": 91, "host": DirScript.host_block({
		"claim": "someone_else", "name": "Sam", "code": "SMB2:x", "peers": 2,
		"started": now - 9999, "hb": now - DirScript.STALE_SEC - 60,
	})}, community)
	outcomes.clear()
	dir.call("play_together")
	await _await_outcome(outcomes, 8.0)
	_eq(outcomes.size(), 1, "stale host produced one election result")
	if outcomes.size() == 1:
		_ok(bool(outcomes[0]), "a stale host frees the seat")

	dir.call("vacate")
	dir.disconnect("election_result", cb)
	dir.set("_http", saved_http)
	dir.call("set_community", {})
	fake.queue_free()


## DiscordDirectory.State.HOSTING without reaching into the enum by name.
func DiscordDirectoryState_HOSTING() -> int:
	return 4


func _await_outcome(outcomes: Array, timeout_sec: float) -> void:
	var waited := 0.0
	while outcomes.is_empty() and waited < timeout_sec:
		await create_timer(0.05).timeout
		waited += 0.05


# ── Chat relay gating ────────────────────────────────────────────────────────

func _test_relay_gates() -> void:
	var session := root.get_node_or_null("MultiplayerSession")
	_ok(session != null, "MultiplayerSession autoload is registered")
	if session == null:
		return
	var relay: Node = session.get("discord_relay")
	_ok(relay != null, "chat relay is a child of the session")
	if relay == null:
		return
	if bool(session.call("is_active")):
		session.call("leave_session", false)

	# Refuses cleanly rather than half-enabling.
	_ok(not bool((relay.call("set_enabled", true) as Dictionary).get("ok", false)),
		"relay refuses without a webhook")
	_ok(not bool(relay.get("enabled")), "refused relay stays off")

	relay.call("set_community", {
		"name": "Selftest", "guild_id": "222222222222222222",
		"text_channel_hint": "#sim-lobby",
		"relay_webhook": "https://discord.com/api/webhooks/1234567890/abc",
	})
	_ok(bool(relay.call("is_configured")), "webhook configures the relay")
	# Only the host relays: a client doing it would post every message N times
	# and would need the webhook write credential.
	_ok(not bool((relay.call("set_enabled", true) as Dictionary).get("ok", false)),
		"a non-host cannot enable the relay")

	var hosted: Dictionary = session.call("host_session", 34214, "Relay", {})
	_ok(bool(hosted.get("ok", false)), "hosted for the relay check")
	_ok(bool((relay.call("set_enabled", true) as Dictionary).get("ok", false)),
		"host can enable the relay")
	_ok(str(relay.call("notice_text")).contains("mirrored"),
		"enabling announces itself — mirroring chat silently is a trust violation")

	var batcher = relay.get("_batcher")
	batcher.call("clear")
	relay.call("on_chat_message", {"peer_id": 2, "name": "Sam", "text": "hello", "system": false})
	relay.call("on_chat_message", {"peer_id": 0, "name": "System", "text": "joined", "system": true})
	# The trap this test exists for: `rpc_chat_deliver` hardcodes system:false,
	# so a BROADCAST system line (peer 0) — including the relay's own "chat is
	# being mirrored" notice — would be copied into the channel.
	relay.call("on_chat_message", {"peer_id": 0, "name": "System", "text": "notice", "system": false})
	_eq(int(batcher.call("pending")), 1, "only the real player line is relayed")
	var payloads: Array = batcher.call("build_flush", 0.0)
	_eq(payloads.size(), 1, "one payload")
	if payloads.size() == 1:
		_eq((payloads[0] as Dictionary)["username"], "Sam", "payload keeps the author")
		_eq((payloads[0] as Dictionary)["content"], "hello", "payload carries the message")

	relay.call("set_enabled", false)
	relay.call("set_community", {})
	session.call("leave_session", false)

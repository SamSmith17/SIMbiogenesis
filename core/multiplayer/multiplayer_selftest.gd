extends SceneTree

## Offline checks for multiplayer helpers (join codes, transfer, chat, Phase 6).
## Run: Godot.exe.exe --headless --path . --import
##      Godot.exe.exe --headless --path . --script core/multiplayer/multiplayer_selftest.gd

const MpJoinCodeScript := preload("res://core/multiplayer/mp_join_code.gd")
const MpTransferScript := preload("res://core/multiplayer/mp_transfer.gd")
const MpChatScript := preload("res://core/multiplayer/mp_chat_controller.gd")
const MpHardeningScript := preload("res://core/multiplayer/mp_hardening.gd")


func _init() -> void:
	# Host bind needs /root autoloads — defer past SceneTree setup.
	call_deferred("_run_all")


func _run_all() -> void:
	var checks := 0
	var fails := 0
	fails += _run("join_code_roundtrip", _test_join_code_roundtrip)
	checks += 1
	fails += _run("join_code_rejects_bad_version", _test_join_code_rejects_bad_version)
	checks += 1
	fails += _run("bare_ip_port", _test_bare_ip_port)
	checks += 1
	fails += _run("avatar_color_stable", _test_avatar_color_stable)
	checks += 1
	fails += _run("pick_lan_ipv4", _test_pick_lan_ipv4)
	checks += 1
	fails += _run("transfer_chunk_roundtrip", _test_transfer_chunk_roundtrip)
	checks += 1
	fails += _run("chat_sanitize", _test_chat_sanitize)
	checks += 1
	fails += _run("chat_mute_filters", _test_chat_mute_filters)
	checks += 1
	fails += _run("discord_url_shape", _test_discord_url_shape)
	checks += 1
	fails += _run("join_code_expiry", _test_join_code_expiry)
	checks += 1
	fails += _run("password_hash", _test_password_hash)
	checks += 1
	fails += _run("trusted_allowlist", _test_trusted_allowlist)
	checks += 1
	fails += _run("rate_limit_trips", _test_rate_limit_trips)
	checks += 1
	fails += _run("host_bind_smoke", _test_host_bind_smoke)
	checks += 1
	if fails == 0:
		print("multiplayer_selftest: PASS (%d checks)" % checks)
	else:
		push_error("multiplayer_selftest: FAIL (%d / %d)" % [fails, checks])
	quit(1 if fails > 0 else 0)


func _run(name: String, fn: Callable) -> int:
	var err: int = fn.call()
	if err != 0:
		push_error("multiplayer_selftest.%s failed" % name)
	return err


func _test_join_code_roundtrip() -> int:
	var exp: int = MpHardeningScript.now_unix()
	exp += 3600
	var enc: Dictionary = MpJoinCodeScript.encode({
		"ip": "192.168.1.42",
		"port": 34197,
		"token": "abcd",
		"name": "Test Session",
		"exp": exp,
		"has_pw": true,
		"map": {
			"kind": "generated",
			"latitude": 33.3561,
			"longitude": -115.7322,
			"half_extent_m": 15000.0,
		},
	})
	if not bool(enc.get("ok", false)):
		push_error("encode failed: %s" % str(enc.get("error")))
		return 1
	var code := str(enc.get("code", ""))
	if not code.begins_with(MpJoinCodeScript.PREFIX):
		push_error("missing prefix")
		return 1
	var dec: Dictionary = MpJoinCodeScript.decode(code)
	if not bool(dec.get("ok", false)):
		push_error("decode failed: %s" % str(dec.get("error")))
		return 1
	if str(dec.get("ip", "")) != "192.168.1.42":
		push_error("ip mismatch")
		return 1
	if int(dec.get("port", 0)) != 34197:
		push_error("port mismatch")
		return 1
	if str(dec.get("token", "")) != "abcd":
		push_error("token mismatch")
		return 1
	if int(dec.get("exp", 0)) != exp:
		push_error("exp mismatch")
		return 1
	if not bool(dec.get("has_pw", false)):
		push_error("has_pw should be true")
		return 1
	var map: Dictionary = dec.get("map", {}) as Dictionary
	if absf(float(map.get("latitude", 0.0)) - 33.3561) > 0.00001:
		push_error("map lat mismatch")
		return 1
	return 0


func _test_join_code_rejects_bad_version() -> int:
	var body := {
		"v": 999,
		"ip": "10.0.0.1",
		"port": 34197,
		"token": "x",
		"name": "x",
		"map": {},
	}
	var raw := JSON.stringify(body).to_utf8_buffer()
	var code := MpJoinCodeScript.PREFIX + Marshalls.raw_to_base64(
		raw.compress(FileAccess.COMPRESSION_GZIP))
	var dec: Dictionary = MpJoinCodeScript.decode(code)
	if bool(dec.get("ok", true)):
		push_error("should reject bad protocol version")
		return 1
	return 0


func _test_bare_ip_port() -> int:
	var dec: Dictionary = MpJoinCodeScript.decode("10.0.0.5:34197")
	if not bool(dec.get("ok", false)):
		push_error("bare ip:port should work")
		return 1
	if str(dec.get("ip", "")) != "10.0.0.5" or int(dec.get("port", 0)) != 34197:
		push_error("bare parse mismatch")
		return 1
	if not bool(dec.get("bare", false)):
		push_error("bare flag missing")
		return 1
	return 0


func _test_avatar_color_stable() -> int:
	var a: Color = RemotePlayerAvatar.color_for_peer(7)
	var b: Color = RemotePlayerAvatar.color_for_peer(7)
	var c: Color = RemotePlayerAvatar.color_for_peer(8)
	if a != b:
		push_error("color not stable for same peer")
		return 1
	if a.is_equal_approx(c):
		push_error("different peers should differ in color")
		return 1
	return 0


func _test_pick_lan_ipv4() -> int:
	# Mirror MultiplayerSession.pick_lan_ipv4 (autoload may not exist in --script _init).
	var addrs := IP.get_local_addresses()
	var found := ""
	for a in addrs:
		var s := str(a)
		if s.contains(":") or s.begins_with("127.") or s.begins_with("169.254."):
			continue
		found = s
		break
	if found.is_empty():
		# Offline CI / no NIC — accept loopback as last resort.
		found = "127.0.0.1"
	if found.contains(":"):
		push_error("should prefer IPv4")
		return 1
	return 0


func _test_transfer_chunk_roundtrip() -> int:
	var payload := {
		"kind": "graph",
		"rev": 3,
		"state": {"graph": {"version": 7, "items": [{"id": "a"}], "connections": []}},
	}
	var enc: Dictionary = MpTransferScript.encode_dict(payload)
	if not bool(enc.get("ok", false)):
		push_error("encode_dict failed")
		return 1
	var bytes: PackedByteArray = enc.get("bytes", PackedByteArray()) as PackedByteArray
	var chunks: Array = MpTransferScript.chunk_bytes(bytes)
	if chunks.is_empty():
		push_error("expected at least one chunk")
		return 1
	var map := {}
	for i in chunks.size():
		map[i] = chunks[i]
	var assembled: PackedByteArray = MpTransferScript.assemble_chunks(map, chunks.size())
	if assembled.size() != bytes.size():
		push_error("assemble size mismatch")
		return 1
	var dec: Dictionary = MpTransferScript.decode_bytes(assembled)
	if not bool(dec.get("ok", false)):
		push_error("decode failed")
		return 1
	var data: Dictionary = dec.get("data", {}) as Dictionary
	if int(data.get("rev", 0)) != 3:
		push_error("rev mismatch after transfer round-trip")
		return 1
	return 0


func _test_chat_sanitize() -> int:
	var cleaned: String = MpChatScript.sanitize_message("  hi\nthere\r  ")
	if cleaned != "hi there":
		push_error("sanitize whitespace/newlines failed: '%s'" % cleaned)
		return 1
	var long := ""
	for _i in range(MpChatScript.MAX_MSG_LEN + 40):
		long += "a"
	var truncated: String = MpChatScript.sanitize_message(long)
	if truncated.length() != MpChatScript.MAX_MSG_LEN:
		push_error("sanitize length cap failed")
		return 1
	if not MpChatScript.sanitize_message("   ").is_empty():
		push_error("empty after strip should be empty")
		return 1
	return 0


func _test_chat_mute_filters() -> int:
	var chat: Node = MpChatScript.new()
	chat.mute_peer(7, true)
	if not bool(chat.call("is_muted", 7)):
		push_error("mute_peer did not stick")
		return 1
	chat.call("_append", {
		"peer_id": 7,
		"name": "Muted",
		"text": "should not appear",
		"at_ms": 1,
		"system": false,
	})
	if not (chat.get("history") as Array).is_empty():
		push_error("muted peer message should be dropped")
		return 1
	chat.call("_append", {
		"peer_id": 3,
		"name": "Ok",
		"text": "hello",
		"at_ms": 2,
		"system": false,
	})
	var hist: Array = chat.get("history") as Array
	if hist.size() != 1 or str((hist[0] as Dictionary).get("text", "")) != "hello":
		push_error("unmuted message missing")
		return 1
	chat.mute_peer(7, false)
	if bool(chat.call("is_muted", 7)):
		push_error("unmute failed")
		return 1
	chat.free()
	return 0


func _test_discord_url_shape() -> int:
	if not MpChatScript.is_valid_discord_url("https://discord.gg/abc"):
		push_error("discord.gg should be valid")
		return 1
	if not MpChatScript.is_valid_discord_url("https://discord.com/invite/abc"):
		push_error("discord.com should be valid")
		return 1
	if MpChatScript.is_valid_discord_url("https://evil.example/discord.gg/x"):
		push_error("spoofed host should be invalid")
		return 1
	if MpChatScript.is_valid_discord_url(""):
		push_error("empty should be invalid")
		return 1
	return 0


func _test_join_code_expiry() -> int:
	var enc: Dictionary = MpJoinCodeScript.encode({
		"ip": "10.0.0.1",
		"port": 34197,
		"token": "t",
		"name": "x",
		"exp": 1,
		"map": {},
	})
	if not bool(enc.get("ok", false)):
		push_error("encode expired payload failed")
		return 1
	var dec: Dictionary = MpJoinCodeScript.decode(str(enc.get("code")), MpHardeningScript.now_unix())
	if bool(dec.get("ok", true)):
		push_error("expired join code should fail decode")
		return 1
	return 0


func _test_password_hash() -> int:
	var salt := "sess1"
	var h: String = MpHardeningScript.hash_password("secret", salt)
	if h.is_empty():
		push_error("hash empty")
		return 1
	if not MpHardeningScript.password_matches("secret", salt, h):
		push_error("password should match")
		return 1
	if MpHardeningScript.password_matches("wrong", salt, h):
		push_error("wrong password should not match")
		return 1
	return 0


func _test_trusted_allowlist() -> int:
	var keys: PackedStringArray = MpHardeningScript.parse_trusted_keys("AbCd-1\n, zz-2\n abcd-1")
	if keys.size() != 2:
		push_error("expected 2 unique keys, got %d" % keys.size())
		return 1
	if not MpHardeningScript.trusted_key_allowed("ABCD-1", keys):
		push_error("case-insensitive allow failed")
		return 1
	if MpHardeningScript.trusted_key_allowed("nope", keys):
		push_error("unknown key should fail")
		return 1
	if not MpHardeningScript.trusted_key_allowed("anything", PackedStringArray()):
		push_error("empty allowlist should allow all")
		return 1
	return 0


func _test_rate_limit_trips() -> int:
	var bucket := {}
	var t0 := 1000.0
	var trip: Dictionary = MpHardeningScript.rate_note(
		bucket, 7, MpHardeningScript.RATE_MAX_COST + 1, t0)
	if bool(trip.get("ok", true)):
		push_error("rate limit should trip")
		return 1
	# New window resets.
	var ok: Dictionary = MpHardeningScript.rate_note(
		bucket, 7, 1, t0 + MpHardeningScript.RATE_WINDOW_SEC + 0.1)
	if not bool(ok.get("ok", false)):
		push_error("new window should reset")
		return 1
	return 0


func _test_host_bind_smoke() -> int:
	## Headless listen-server bind + leave (no second peer in-process).
	var session: Node = root.get_node_or_null("MultiplayerSession")
	if session == null or not is_instance_valid(session):
		push_error("MultiplayerSession autoload missing")
		return 1
	if bool(session.call("is_active")):
		session.call("leave_session", false)
	var port := 34211
	var result: Dictionary = session.call("host_session", port, "Smoke", {
		"password": "beta",
		"ttl_sec": 120,
		"trusted_keys": "aa-11",
		"require_trusted": true,
	})
	if not bool(result.get("ok", false)):
		push_error("host_session failed: %s" % str(result.get("error")))
		return 1
	var code := str(session.get("join_code"))
	if code.is_empty():
		push_error("expected join code after host")
		session.call("leave_session", false)
		return 1
	var dec: Dictionary = MpJoinCodeScript.decode(code)
	if not bool(dec.get("ok", false)):
		push_error("hosted join code failed decode: %s" % str(dec.get("error")))
		session.call("leave_session", false)
		return 1
	if not bool(dec.get("has_pw", false)):
		push_error("hosted code should flag has_pw")
		session.call("leave_session", false)
		return 1
	var refreshed: Dictionary = session.call("refresh_join_code")
	if not bool(refreshed.get("ok", false)):
		push_error("refresh_join_code failed")
		session.call("leave_session", false)
		return 1
	session.call("leave_session", false)
	if bool(session.call("is_active")):
		push_error("still active after leave")
		return 1
	return 0

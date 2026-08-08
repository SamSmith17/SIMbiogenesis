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
	fails += _run("admission_gate", _test_admission_gate)
	checks += 1
	fails += _run("possession_rules", _test_possession_rules)
	checks += 1
	fails += _run("possession_sim_contract", _test_possession_sim_contract)
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
	# A hosted code must always carry at least the LAN candidate, and the
	# top-level ip/port must keep mirroring it — every pre-v3 consumer
	# (_connect_pending, the LAN beacon, the lobby) still reads those.
	var addrs: Array = dec.get("addrs", []) as Array
	if addrs.is_empty():
		push_error("hosted code carries no candidate addresses")
		session.call("leave_session", false)
		return 1
	if str((addrs[0] as Dictionary).get("h", "")) != str(dec.get("ip", "")):
		push_error("first candidate must mirror the top-level ip")
		session.call("leave_session", false)
		return 1
	if int(dec.get("port", 0)) != port:
		push_error("hosted code port mismatch")
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


func _test_admission_gate() -> int:
	## The gate that stops a CONNECTED-but-unverified peer from acting.
	##
	## This matters because rpc_hello has only ever been advisory: once ENet
	## connects, a peer can invoke any @rpc("any_peer") handler before it has
	## said hello at all. Async Discord verification stretches that window from
	## ~0 ms to seconds, so the hold has to be real.
	var session: Node = root.get_node_or_null("MultiplayerSession")
	if session == null or not is_instance_valid(session):
		push_error("MultiplayerSession autoload missing")
		return 1
	if bool(session.call("is_active")):
		session.call("leave_session", false)
	var result: Dictionary = session.call("host_session", 34212, "Admission", {})
	if not bool(result.get("ok", false)):
		push_error("host_session failed: %s" % str(result.get("error")))
		return 1

	var fails := 0
	var peers: Dictionary = session.get("peers")

	if not bool(session.call("peer_admitted", 1)):
		push_error("host itself must be admitted")
		fails += 1
	if bool(session.call("peer_admitted", 42)):
		push_error("unknown peer must not be admitted")
		fails += 1
	if bool(session.call("note_peer_traffic", 42, 1)):
		push_error("unknown peer's traffic must be dropped")
		fails += 1

	# A peer mid-verification: held, but explicitly NOT kicked. The rate-limit
	# path kicks; a slow Discord round-trip must not, or a legitimate joiner
	# whose presence packets arrive first gets punished for being fast.
	peers[7] = {"name": "Pending", "ready": false, "pending": true}
	(session.get("_pending_admission") as Dictionary)[7] = {
		"name": "Pending", "started_ms": Time.get_ticks_msec(), "epoch": 1,
	}
	if bool(session.call("peer_admitted", 7)):
		push_error("pending peer must not be admitted")
		fails += 1
	if bool(session.call("note_peer_traffic", 7, 1)):
		push_error("pending peer's traffic must be dropped")
		fails += 1
	if not (session.get("peers") as Dictionary).has(7):
		push_error("dropping a pending peer's traffic must NOT disconnect it")
		fails += 1
	# The hello handshake legitimately precedes admission, so it opts out.
	if not bool(session.call("note_peer_traffic", 7, 1, false)):
		push_error("hello path must bypass the admitted check")
		fails += 1

	# Admitting flips every one of the above.
	session.call("_admit_peer", 7, "Pending")
	if not bool(session.call("peer_admitted", 7)):
		push_error("admitted peer should pass")
		fails += 1
	if not bool(session.call("note_peer_traffic", 7, 1)):
		push_error("admitted peer's traffic should pass")
		fails += 1
	if (session.get("_pending_admission") as Dictionary).has(7):
		push_error("admitting must clear the pending entry")
		fails += 1

	# Discord requirement is advertised in the join code so a joiner can be told
	# to sign in BEFORE connecting rather than connecting and being kicked.
	session.call("set_discord_requirement", {"guild_id": "222222222222222222"}, true)
	if not bool(session.get("require_discord")):
		push_error("valid guild should enable the Discord requirement")
		fails += 1
	var dec: Dictionary = MpJoinCodeScript.decode(str(session.get("join_code")))
	if not MpJoinCodeScript.needs_discord(dec):
		push_error("join code should advertise the Discord requirement")
		fails += 1
	if MpJoinCodeScript.discord_guild(dec) != "222222222222222222":
		push_error("join code should carry the guild id")
		fails += 1
	if bool(session.call("can_satisfy_discord", dec)):
		push_error("a signed-out client cannot satisfy a Discord-gated host")
		fails += 1

	# A malformed guild must not be able to arm the gate — a gate that is on but
	# can never pass would lock everyone out with no obvious cause.
	session.call("set_discord_requirement", {"guild_id": "nope"}, true)
	if bool(session.get("require_discord")):
		push_error("invalid guild must not enable the Discord requirement")
		fails += 1

	# Timeout sweep: a verification that never comes back must release the peer
	# rather than leaving it connected and mute forever.
	var pending: Dictionary = session.get("_pending_admission")
	pending.clear()
	pending[9] = {"name": "Stuck", "started_ms": Time.get_ticks_msec() - 60_000, "epoch": 2}
	session.call("_sweep_pending_admissions")
	if pending.has(9):
		push_error("expired admission should have been swept")
		fails += 1

	session.call("set_discord_requirement", {}, false)
	session.call("leave_session", false)
	return fails


func _test_possession_rules() -> int:
	## Pure arbitration for "who is driving which person".
	var fails := 0
	var controlled := {}

	var ok: Dictionary = MpPossession.can_possess("cap_npc_0", 2, controlled, true)
	if not bool(ok.get("ok", false)):
		push_error("a free agent should be possessable")
		fails += 1
	controlled["cap_npc_0"] = 2

	# Two players cannot inhabit the same person.
	if bool((MpPossession.can_possess("cap_npc_0", 3, controlled, true) as Dictionary).get("ok", false)):
		push_error("a taken agent must not be possessable by someone else")
		fails += 1
	# …and one player cannot hold two bodies: both would be driven to the same
	# position and there would be no way to say which one they are.
	if bool((MpPossession.can_possess("cap_npc_1", 2, controlled, true) as Dictionary).get("ok", false)):
		push_error("one peer must not hold two agents")
		fails += 1
	# A person who has left the camp is not a body.
	if bool((MpPossession.can_possess("cap_npc_9", 4, controlled, false) as Dictionary).get("ok", false)):
		push_error("a departed agent must not be possessable")
		fails += 1
	if bool((MpPossession.can_possess("", 4, controlled, true) as Dictionary).get("ok", false)):
		push_error("empty agent id must be refused")
		fails += 1

	if MpPossession.agent_of_peer(controlled, 2) != "cap_npc_0":
		push_error("agent_of_peer lookup failed")
		fails += 1
	if not MpPossession.agent_of_peer(controlled, 99).is_empty():
		push_error("unknown peer should hold nothing")
		fails += 1
	var freed: Array = MpPossession.release_for_peer(controlled, 2)
	if freed.size() != 1 or str(freed[0]) != "cap_npc_0":
		push_error("release_for_peer should return the held agent")
		fails += 1

	# Time-scale warning: throttled by cooldown AND bracket, because rpc_clock
	# lands at 2 Hz. main.gd defaults time_scale to 0.01 (~36x realtime), which
	# is why the threshold is a tuned multiplier and not "> 1".
	var slow: Dictionary = MpPossession.time_scale_warning(
		MpPossession.REALTIME_SCALE, 0, -1, 1000)
	if bool(slow.get("warn", false)):
		push_error("realtime must not warn")
		fails += 1
	var fast: Dictionary = MpPossession.time_scale_warning(
		MpPossession.REALTIME_SCALE * 100.0, 0, -1, 1000)
	if not bool(fast.get("warn", false)):
		push_error("100x should warn")
		fails += 1
	var repeat: Dictionary = MpPossession.time_scale_warning(
		MpPossession.REALTIME_SCALE * 100.0, 1000, int(fast.get("bracket", 0)), 1005)
	if bool(repeat.get("warn", false)):
		push_error("same bracket inside the cooldown must not re-warn")
		fails += 1
	var faster: Dictionary = MpPossession.time_scale_warning(
		MpPossession.REALTIME_SCALE * 5000.0, 1000, int(fast.get("bracket", 0)), 1005)
	if not bool(faster.get("warn", false)):
		push_error("a big speed jump should warn again even inside the cooldown")
		fails += 1
	if absf(MpPossession.speed_multiplier(MpPossession.REALTIME_SCALE) - 1.0) > 0.001:
		push_error("realtime should read as 1x")
		fails += 1
	return fails


func _test_possession_sim_contract() -> int:
	## What the SIM must do with a person a human is driving. Each of these is a
	## way the feature silently breaks rather than erroring.
	var fails := 0
	var engine := NpcPopulationEngine.new()
	engine.configure(4, "cap", Vector2.ZERO)
	var agent: NpcAgent = engine.agents[0]
	agent.controlled_by_peer = 7
	agent.state = NpcAgent.State.DOING
	agent.activity = "thirst"

	var ctx := engine._make_ctx({})
	var before := agent.pos
	# Needs keep rising and morale keeps moving — possession is not a way to opt
	# out of being a person.
	var thirst_before := float(agent.needs.get("thirst", 0.0))
	var billed: Dictionary = agent.step(100.0, 0.5, ctx)
	if float(agent.needs.get("thirst", 0.0)) <= thirst_before:
		push_error("a possessed agent's needs must keep rising")
		fails += 1
	# …and they still bill the resource economy for what they are doing.
	if billed.is_empty():
		push_error("a possessed agent doing an activity must still consume")
		fails += 1
	# The FSM must not move them: their position is authored by the player.
	if agent.pos != before:
		push_error("the FSM must not move a possessed agent")
		fails += 1
	if agent.state != NpcAgent.State.DOING:
		push_error("the FSM must not re-plan a possessed agent")
		fails += 1

	# A >6 h jump takes the coarse catch-up path, which force-resets state and
	# rerolls needs — that would yank the body out from under the player.
	agent.state = NpcAgent.State.DOING
	agent.activity = "thirst"
	engine._catch_up(200.0, 12.0, ctx)
	if agent.state != NpcAgent.State.DOING or agent.activity != "thirst":
		push_error("catch-up must skip a possessed agent")
		fails += 1
	var other: NpcAgent = engine.agents[1]
	if other.state != NpcAgent.State.IDLE:
		push_error("catch-up must still reset everyone else")
		fails += 1

	# Possession is transient: persisting it would restore an agent frozen with
	# no controller after a reload.
	var snap: Dictionary = agent.snapshot()
	if snap.has("controlled_by_peer"):
		push_error("controlled_by_peer must never be persisted")
		fails += 1
	var restored := NpcAgent.from_snapshot(snap)
	if restored != null and restored.controlled_by_peer != 0:
		push_error("a restored agent must not come back possessed")
		fails += 1

	# They must not rage-quit out from under the player.
	agent.quit_pressure = 999.0
	var roster_before := engine.agents.size()
	engine._process_departures(300.0, ctx)
	if engine.agents.size() != roster_before:
		push_error("a possessed agent must not depart")
		fails += 1
	if engine.find_agent(agent.id) == null:
		push_error("the possessed agent should still be in the roster")
		fails += 1

	# The dot payload has to carry the flag, or the 3D layer animates a
	# player-driven person as a wandering NPC.
	var dots: Array = engine.agent_dots()
	var found := false
	for d in dots:
		if str((d as Dictionary).get("id", "")) == agent.id:
			found = bool((d as Dictionary).get("possessed", false))
	if not found:
		push_error("agent_dots must report possession")
		fails += 1
	return fails

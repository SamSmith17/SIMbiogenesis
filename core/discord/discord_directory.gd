extends Node

## "Who is playing right now?" — answered by ONE Discord message, with no
## server of ours.
##
## Discord's webhook message endpoints need no authentication at all, so a
## single message is both readable and writable by every member who holds the
## community file. The message is created once and **edited in place forever**,
## which is the whole point: its Discord link never changes, so a server owner
## can pin it and that pin is the permanent "join my map" link.
##
## All the concurrency correctness lives in `SimDirRecord` (pure, selftested).
## This file fetches, sequences, and owns the state machine.
##
## Deliberate limitation, stated so nobody mistakes it for a bug: the directory
## is a CONVENIENCE, not a security boundary. Anyone holding the community file
## can post in that channel or overwrite this message. Admission control is
## `DiscordGate`; a stomper causes a nuisance, not a breach.

signal directory_changed(record: Dictionary)
signal directory_error(reason: String)
## `won` false means someone else is hosting — `record` says who.
signal election_result(won: bool, record: Dictionary)

enum State { IDLE, READING, CLAIMING, CONFIRMING, HOSTING, LOST }

## Polling only runs while the lobby is open or we are hosting: the webhook
## route budget (~5 req / 2 s) is shared by everyone in the community.
const POLL_SEC := 20.0
const MAX_CLAIM_ATTEMPTS := 3

var community: Dictionary = {}
var record: Dictionary = {}
var state: int = State.IDLE
var last_error: String = ""

var _http: Node = null
var _poll_accum := 0.0
var _polling := false
var _busy := false
var _highest_seq := 0
var _my_claim := ""
var _my_seq := 0
var _claim_attempts := 0
var _reconfirm_at := 0.0
var _last_publish: Dictionary = {}


func _ready() -> void:
	name = "DiscordDirectory"
	set_process(false)
	community = SimCommunity.active()


func _http_client() -> Node:
	if _http != null and is_instance_valid(_http):
		return _http
	var id := get_node_or_null("/root/DiscordIdentity")
	if id != null:
		_http = id.get("http")
	return _http


# ── Configuration ────────────────────────────────────────────────────────────

func set_community(p_community: Dictionary) -> void:
	community = p_community.duplicate(true)
	record = {}
	_highest_seq = 0
	last_error = ""
	directory_changed.emit(record)


func is_configured() -> bool:
	return SimCommunity.is_webhook_url(str(community.get("directory_webhook", "")))


## The permanent link a server owner pins. Empty until the message exists.
func permanent_link() -> String:
	return DiscordLinks.message_url(
		str(community.get("guild_id", "")),
		str(community.get("directory_channel_id", "")),
		str(community.get("directory_message_id", "")))


func status_text() -> String:
	if not is_configured():
		return "No community imported — paste a SMBC1: code to find your group's sessions."
	match state:
		State.READING: return "Checking who's playing…"
		State.CLAIMING, State.CONFIRMING: return "Claiming the session…"
	if not last_error.is_empty():
		return last_error
	if record.is_empty():
		return "Haven't checked yet."
	return SimDirRecord.status_text(record, _now())


# ── Polling ──────────────────────────────────────────────────────────────────

func start_polling(on: bool) -> void:
	_polling = on and is_configured()
	set_process(_polling or state == State.HOSTING)
	if _polling:
		_poll_accum = POLL_SEC  # read immediately


func _process(delta: float) -> void:
	if state == State.HOSTING:
		_poll_accum += delta
		if _poll_accum >= float(SimDirRecord.HEARTBEAT_SEC):
			_poll_accum = 0.0
			heartbeat()
		if _reconfirm_at > 0.0 and Time.get_ticks_msec() / 1000.0 >= _reconfirm_at:
			_reconfirm_at = 0.0
			_run_reconfirm()
		return
	if not _polling:
		return
	_poll_accum += delta
	if _poll_accum >= POLL_SEC:
		_poll_accum = 0.0
		refresh()


# ── Read ─────────────────────────────────────────────────────────────────────

func refresh(on_done: Callable = Callable()) -> void:
	if not is_configured():
		_fail("No community imported", on_done)
		return
	var http := _http_client()
	if http == null:
		_fail("Discord client unavailable", on_done)
		return
	if state == State.IDLE:
		state = State.READING
	http.call("get_json", _message_url(), func(res: Dictionary) -> void:
		_on_read(res, on_done))


func _on_read(res: Dictionary, on_done: Callable) -> void:
	if state == State.READING:
		state = State.IDLE
	if not bool(res.get("ok", false)):
		if int(res.get("code", 0)) == 404:
			_fail("The directory message is gone — ask the owner for a new community file", on_done)
		else:
			_fail(str(res.get("error", "Could not read the directory")), on_done)
		return
	var content := str((res.get("body", {}) as Dictionary).get("content", ""))
	var parsed: Dictionary = SimDirRecord.parse(content)
	if not bool(parsed.get("ok", false)):
		# Someone typed over the message. Surface it, but keep whatever we last
		# knew — and never stomp human text unless the record is also stale
		# (enforced in _publish).
		last_error = "Someone edited the status message by hand." if bool(parsed.get("human_text", false)) \
			else str(parsed.get("error", "Unreadable directory"))
		record = {"__human_text": bool(parsed.get("human_text", false))}
		directory_error.emit(last_error)
		_finish(on_done, {"ok": false, "error": last_error})
		return
	var rec: Dictionary = parsed["record"]
	# A read that went backwards is a stale cache; ignoring it is what keeps two
	# racers agreeing about which write was last.
	if SimDirRecord.seq_regressed(rec, _highest_seq):
		_finish(on_done, {"ok": true, "record": record, "stale": true})
		return
	_highest_seq = maxi(_highest_seq, int(rec.get("seq", 0)))
	record = rec
	last_error = ""
	directory_changed.emit(record)
	_finish(on_done, {"ok": true, "record": record})


# ── The one button ───────────────────────────────────────────────────────────

## Read the directory, then either join whoever is live or claim the session.
## Resolves onto `election_result(won, record)`.
func play_together() -> void:
	if _busy:
		return
	if not is_configured():
		_fail("No community imported")
		return
	_busy = true
	_claim_attempts = 0
	_my_claim = ""
	_try_claim_cycle()


func _try_claim_cycle() -> void:
	refresh(func(res: Dictionary) -> void:
		if not bool(res.get("ok", false)) and not bool(record.get("__human_text", false)):
			_busy = false
			election_result.emit(false, {})
			return
		if SimDirRecord.live_host_other_than(record, _my_claim, _now()):
			_busy = false
			state = State.LOST
			election_result.emit(false, record)
			return
		_begin_claim())


func _begin_claim() -> void:
	_claim_attempts += 1
	if _claim_attempts > MAX_CLAIM_ATTEMPTS:
		_busy = false
		_fail("Could not settle who hosts — try again in a moment")
		election_result.emit(false, record)
		return
	_my_claim = SimDirRecord.mint_claim()
	var observed: Dictionary = record if bool(record.get("v", 0)) else SimDirRecord.blank()
	var claim: Dictionary = SimDirRecord.claim_record(observed, _host_block(true))
	_my_seq = int(claim["seq"])
	state = State.CLAIMING
	# no_retry: a 429 here must read as LOST, never as a retry that could land
	# after the rival's confirm read and mint a second host.
	# The continuation is a named method, not a lambda: GDScript lambdas cannot
	# contain `await`, and the confirm delay is the whole mechanism.
	_publish(claim, _on_claim_published, true)


func _on_claim_published(ok: bool) -> void:
	if not ok:
		_retry_claim_later()
		return
	state = State.CONFIRMING
	# Write NOTHING during the confirm window — that discipline is what makes
	# Discord's last-write-wins a valid arbiter.
	await get_tree().create_timer(SimDirRecord.CONFIRM_DELAY_SEC).timeout
	refresh(func(_r: Dictionary) -> void: _arbitrate())


func _arbitrate() -> void:
	var verdict: String = SimDirRecord.arbitrate(record, _my_claim, _now())
	match verdict:
		"won":
			_busy = false
			state = State.HOSTING
			_poll_accum = 0.0
			# Stand down at +8 s if a later live claim appeared. Turns the rare
			# double-host outcome from permanent into self-healing.
			_reconfirm_at = Time.get_ticks_msec() / 1000.0 + SimDirRecord.RECONFIRM_SEC
			set_process(true)
			election_result.emit(true, record)
		"lost":
			_busy = false
			state = State.LOST
			election_result.emit(false, record)
		_:
			_retry_claim_later()


func _retry_claim_later() -> void:
	# Random backoff so two racers do not resynchronise on the retry either.
	var wait := randf_range(1.0, 4.0)
	await get_tree().create_timer(wait).timeout
	_try_claim_cycle()


func _run_reconfirm() -> void:
	refresh(func(_r: Dictionary) -> void:
		if SimDirRecord.should_vacate(record, _my_claim, _my_seq, _now()):
			state = State.LOST
			_my_claim = ""
			election_result.emit(false, record))


# ── Write ────────────────────────────────────────────────────────────────────

## Called by the lobby once the ENet server is actually up, so the published
## address is real rather than predicted.
func publish_hosting(join_code: String, map_info: Dictionary, peers: int) -> void:
	if state != State.HOSTING or not is_configured():
		return
	_last_publish = {"code": join_code, "map": map_info, "peers": peers}
	_publish(SimDirRecord.claim_record(record, _host_block(false)))


func heartbeat() -> void:
	if state != State.HOSTING or not is_configured():
		return
	_publish(SimDirRecord.claim_record(record, _host_block(false)))


## Best effort — on a clean leave, tell everyone the seat is free rather than
## making them wait out STALE_SEC.
func vacate() -> void:
	_reconfirm_at = 0.0
	if state == State.HOSTING and is_configured():
		_publish(SimDirRecord.vacate_record(record))
	state = State.IDLE
	_my_claim = ""
	_my_seq = 0
	set_process(_polling)


func _host_block(claiming: bool) -> Dictionary:
	var session := get_node_or_null("/root/MultiplayerSession")
	var now := _now()
	var lan := ""
	var pub := ""
	var code := str(_last_publish.get("code", ""))
	var map_info: Dictionary = _last_publish.get("map", {}) as Dictionary
	var peers := int(_last_publish.get("peers", 0))
	if session != null:
		var port := int(session.get("host_port"))
		if not str(session.get("host_address")).is_empty():
			lan = "%s:%d" % [str(session.get("host_address")), port]
		if not str(session.get("wan_address")).is_empty():
			pub = "%s:%d" % [str(session.get("wan_address")), port]
		# Read the LIVE session state, not the cached publish: heartbeats keep
		# running with the lobby closed, and a stale player count or a refreshed
		# join code in the channel is exactly what makes a directory useless.
		if bool(session.call("is_host")):
			peers = int(session.call("peer_count"))
			var live_code := str(session.get("join_code"))
			if not live_code.is_empty():
				code = live_code
			if map_info.is_empty() and session.has_method("collect_map_info"):
				map_info = session.call("collect_map_info")
		elif code.is_empty():
			code = str(session.get("join_code"))
	var id := get_node_or_null("/root/DiscordIdentity")
	var who := str(id.call("display_name")) if id != null else ""
	if who.is_empty() and session != null:
		who = str(session.get("display_name"))
	var existing: Dictionary = record.get("host", {}) as Dictionary
	return {
		"claim": _my_claim,
		"user": str((id.call("user") as Dictionary).get("id", "")) if id != null else "",
		"name": who,
		"pub": pub,
		"lan": lan,
		"code": code,
		"map": map_info,
		"peers": peers,
		"started": now if claiming else int(existing.get("started", now)),
		"hb": now,
	}


## PATCH the directory message, minting it on first use. `on_done(ok)`.
func _publish(rec: Dictionary, on_done: Callable = Callable(), no_retry: bool = false) -> void:
	var hook := str(community.get("directory_webhook", ""))
	if not SimCommunity.is_webhook_url(hook):
		_fail("Community's directory webhook is not a Discord webhook URL")
		_done_bool(on_done, false)
		return
	# Note on stomping human text: every write here is either an explicit
	# "Play together" claim or a heartbeat from a session we already own, so we
	# DO overwrite a hand-edited message. Refusing would lock the whole
	# community out of hosting until someone tidied the channel by hand, which
	# is worse than losing one typed line — the read path already warns that it
	# happened. The directory message is machine-owned by contract; give it its
	# own channel.
	var http := _http_client()
	if http == null:
		_done_bool(on_done, false)
		return
	var payload := {
		"content": SimDirRecord.render(rec, community),
		# An in-game name could otherwise ping the whole server through the
		# status message.
		"allowed_mentions": {"parse": []},
	}
	var msg_id := str(community.get("directory_message_id", ""))
	if DiscordConfig.is_snowflake(msg_id):
		http.call("patch_json", "%s/messages/%s" % [hook, msg_id], payload,
			func(res: Dictionary) -> void: _on_publish(res, rec, on_done), "", no_retry)
		return
	# First run: mint the message, then remember its id so every later write is
	# an edit and the link stays constant.
	http.call("post_json", "%s?wait=true" % hook, payload,
		func(res: Dictionary) -> void: _on_minted(res, rec, on_done))


func _on_minted(res: Dictionary, rec: Dictionary, on_done: Callable) -> void:
	if not bool(res.get("ok", false)):
		_fail(str(res.get("error", "Could not create the directory message")))
		_done_bool(on_done, false)
		return
	var body: Dictionary = res.get("body", {}) as Dictionary
	var msg_id := str(body.get("id", ""))
	if DiscordConfig.is_snowflake(msg_id):
		community["directory_message_id"] = msg_id
		if str(community.get("directory_channel_id", "")).is_empty():
			community["directory_channel_id"] = str(body.get("channel_id", ""))
		SimCommunity.save_to_disk(community)
	_on_publish(res, rec, on_done)


func _on_publish(res: Dictionary, rec: Dictionary, on_done: Callable) -> void:
	if not bool(res.get("ok", false)):
		_fail(str(res.get("error", "Could not update the directory")))
		_done_bool(on_done, false)
		return
	record = rec
	_highest_seq = maxi(_highest_seq, int(rec.get("seq", 0)))
	last_error = ""
	directory_changed.emit(record)
	_done_bool(on_done, true)


# ── helpers ──────────────────────────────────────────────────────────────────

func _message_url() -> String:
	return "%s/messages/%s" % [
		str(community.get("directory_webhook", "")),
		str(community.get("directory_message_id", "")),
	]


static func _now() -> int:
	return int(Time.get_unix_time_from_system())


func _fail(reason: String, on_done: Callable = Callable()) -> void:
	last_error = reason
	if state in [State.READING, State.CLAIMING, State.CONFIRMING]:
		state = State.IDLE
	directory_error.emit(reason)
	_finish(on_done, {"ok": false, "error": reason})


func _finish(on_done: Callable, payload: Dictionary) -> void:
	if on_done.is_valid():
		on_done.call(payload)


func _done_bool(on_done: Callable, ok: bool) -> void:
	if on_done.is_valid():
		on_done.call(ok)

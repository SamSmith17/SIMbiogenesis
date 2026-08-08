class_name SimDirRecord
extends RefCounted

## The zero-infra session directory: ONE Discord webhook message, edited in
## place forever.
##
## This works because the webhook message endpoints need no authentication at
## all — `GET /webhooks/{id}/{token}/messages/{msg}` and `PATCH` on the same
## path — so a single message is a readable AND writable key-value store that
## every client can reach with no bot and no server of ours. The message is
## never re-created, so its Discord link is permanent: that link is the "stable
## link" the whole feature hangs on.
##
## This file is the pure half — render, parse, staleness, and the election
## arbitration. All of the concurrency correctness lives here precisely so it is
## testable offline.

const VERSION := 1
const FENCE := "```json"
const FENCE_END := "```"

## Host PATCHes `hb` this often; a reader calls the host dead after STALE_SEC
## (~3 missed heartbeats).
const HEARTBEAT_SEC := 45
const STALE_SEC := 150

## After PATCHing a claim, wait this long WITHOUT WRITING, then re-read.
## Discord serialises both PATCHes on one message and the last writer wins the
## stored content, so if both racers re-read after the same fixed delay with no
## intervening write, exactly one of them sees its own claim. That
## no-intervening-write discipline is what makes last-write-wins a valid
## arbiter — which is why a 429 on the claim PATCH must be treated as LOST and
## never retried inside this window.
const CONFIRM_DELAY_SEC := 2.5

## Second confirmation, before the winner accepts its first remote peer. If the
## record by then shows a different claim with a higher seq, vacate and join
## instead. Turns the (rare) double-host outcome from permanent into
## self-healing.
const RECONFIRM_SEC := 8.0

const MAX_CONTENT := 1900  # Discord's limit is 2000; leave room for the header.


static func blank() -> Dictionary:
	return {"v": VERSION, "seq": 0, "host": {}}


## Build a host block. `claim` is the random token that decides the election.
static func host_block(fields: Dictionary) -> Dictionary:
	return {
		"claim": str(fields.get("claim", "")),
		"user": str(fields.get("user", "")),
		"name": str(fields.get("name", "")),
		"pub": str(fields.get("pub", "")),
		"lan": str(fields.get("lan", "")),
		"code": str(fields.get("code", "")),
		"map": (fields.get("map", {}) as Dictionary).duplicate(true),
		"peers": int(fields.get("peers", 0)),
		"started": int(fields.get("started", 0)),
		"hb": int(fields.get("hb", 0)),
	}


static func mint_claim() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()


## The message content: a human-readable line for people reading the channel,
## then the machine block. Readers only parse the fenced JSON.
static func render(record: Dictionary, community: Dictionary = {}) -> String:
	var host: Dictionary = record.get("host", {}) as Dictionary
	var header := ""
	if host.is_empty():
		header = "⚫ **Nobody is playing right now.** Open SIMbiogenesis → Multiplayer → Play together to start a session."
	else:
		var map_label := str((host.get("map", {}) as Dictionary).get("label", "a site"))
		header = "🟢 **%s is hosting** — %s · %d %s online\nJoin from the game: Multiplayer → **Play together**." % [
			str(host.get("name", "Someone")),
			map_label,
			int(host.get("peers", 0)),
			"player" if int(host.get("peers", 0)) == 1 else "players",
		]
	var name := str(community.get("name", "")).strip_edges()
	if not name.is_empty():
		header = "**%s**\n%s" % [name, header]
	var body := JSON.stringify(record)
	var out := "%s\n%s\n%s\n%s" % [header, FENCE, body, FENCE_END]
	if out.length() > MAX_CONTENT:
		# Never truncate the machine block — drop the header instead.
		out = "%s\n%s\n%s" % [FENCE, body, FENCE_END]
	return out


## {ok, record} / {ok:false, error, human_text:bool}
##
## `human_text` distinguishes "someone typed over our message" from "garbage".
## The caller MUST NOT stomp a human-authored message unless the record is also
## missing/stale — otherwise a support conversation in that channel is silently
## overwritten.
static func parse(content: String) -> Dictionary:
	var start := content.find(FENCE)
	if start < 0:
		return {"ok": false, "error": "no directory block", "human_text": not content.strip_edges().is_empty()}
	var body_start := start + FENCE.length()
	var end := content.find(FENCE_END, body_start)
	if end < 0:
		return {"ok": false, "error": "unterminated directory block", "human_text": true}
	var parsed: Variant = JSON.parse_string(content.substr(body_start, end - body_start).strip_edges())
	if not (parsed is Dictionary):
		return {"ok": false, "error": "directory block is not JSON", "human_text": true}
	var rec: Dictionary = parsed as Dictionary
	if int(rec.get("v", 0)) != VERSION:
		return {"ok": false, "error": "directory version %d" % int(rec.get("v", 0)), "human_text": false}
	var host_v: Variant = rec.get("host", {})
	rec["host"] = host_block(host_v as Dictionary) if host_v is Dictionary and not (host_v as Dictionary).is_empty() else {}
	rec["seq"] = int(rec.get("seq", 0))
	return {"ok": true, "record": rec, "human_text": false}


static func has_host(record: Dictionary) -> bool:
	return not (record.get("host", {}) as Dictionary).is_empty()


static func is_stale(record: Dictionary, now_unix: int) -> bool:
	if not has_host(record):
		return true
	var hb := int((record.get("host", {}) as Dictionary).get("hb", 0))
	if hb <= 0:
		return true
	return (now_unix - hb) > STALE_SEC


## A live host that is not us.
static func live_host_other_than(record: Dictionary, my_claim: String, now_unix: int) -> bool:
	if is_stale(record, now_unix):
		return false
	return str((record.get("host", {}) as Dictionary).get("claim", "")) != my_claim


## Ignore a read whose seq went backwards — a stale cache or a client that
## wrote from an old read. Without this the two racers can disagree about which
## write was last.
static func seq_regressed(record: Dictionary, highest_seen: int) -> bool:
	return int(record.get("seq", 0)) < highest_seen


## The election verdict after CONFIRM_DELAY_SEC. Pure, so the race is testable.
##   "won"   — the record still carries our claim
##   "lost"  — someone else's claim is there
##   "retry" — nothing readable; caller backs off and starts over
static func arbitrate(record: Dictionary, my_claim: String, now_unix: int) -> String:
	if my_claim.is_empty():
		return "lost"
	if not has_host(record):
		return "retry"
	var claim := str((record.get("host", {}) as Dictionary).get("claim", ""))
	if claim == my_claim:
		return "won"
	# Someone else holds it. Only treat that as a loss while they are live —
	# a stale foreign claim means our PATCH was lost, so try again.
	return "lost" if not is_stale(record, now_unix) else "retry"


## Should a winner stand down at the RECONFIRM_SEC check?
static func should_vacate(record: Dictionary, my_claim: String, my_seq: int, now_unix: int) -> bool:
	if not has_host(record):
		return false
	var host: Dictionary = record.get("host", {}) as Dictionary
	if str(host.get("claim", "")) == my_claim:
		return false
	if is_stale(record, now_unix):
		return false
	# A live foreign claim that was written AFTER ours wins.
	return int(record.get("seq", 0)) > my_seq


## Next record to PATCH when claiming. seq strictly increases so a reader can
## order two writes.
static func claim_record(observed: Dictionary, host: Dictionary) -> Dictionary:
	return {
		"v": VERSION,
		"seq": int(observed.get("seq", 0)) + 1,
		"host": host_block(host),
	}


static func vacate_record(observed: Dictionary) -> Dictionary:
	return {"v": VERSION, "seq": int(observed.get("seq", 0)) + 1, "host": {}}


## Human summary for the lobby's Play tab.
static func status_text(record: Dictionary, now_unix: int) -> String:
	if not has_host(record):
		return "Nobody is playing — you can start a session."
	var host: Dictionary = record.get("host", {}) as Dictionary
	var who := str(host.get("name", "Someone"))
	if is_stale(record, now_unix):
		var age := now_unix - int(host.get("hb", now_unix))
		return "%s's session went quiet %s ago — you can take over." % [who, _ago(age)]
	var started := int(host.get("started", 0))
	var map_label := str((host.get("map", {}) as Dictionary).get("label", "a site"))
	var since := "" if started <= 0 else " · started %s ago" % _ago(now_unix - started)
	return "%s is hosting %s · %d online%s" % [who, map_label, int(host.get("peers", 0)), since]


static func _ago(seconds: int) -> String:
	var s := maxi(0, seconds)
	if s < 90:
		return "%ds" % s
	if s < 5400:
		return "%dm" % int(round(float(s) / 60.0))
	return "%.1fh" % (float(s) / 3600.0)

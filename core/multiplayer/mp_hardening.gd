class_name MpHardening
extends RefCounted

## Phase 6 private-beta hardening helpers — join-code expiry, password hash,
## trusted-key allowlist, per-peer rate limits, local telemetry log.

const DEFAULT_CODE_TTL_SEC := 4 * 3600
const TELEMETRY_PATH := "user://mp_telemetry.log"
const MAX_TELEMETRY_BYTES := 512_000

## Sliding-window rate limit (cost units / window).
const RATE_WINDOW_SEC := 5.0
const RATE_MAX_COST := 600
const COST_PRESENCE := 1
const COST_CHAT := 8
const COST_DESIGN_CHUNK := 2
const COST_DESIGN_START := 20
const COST_HELLO := 15


static func now_unix() -> int:
	return int(Time.get_unix_time_from_system())


static func expiry_unix(ttl_sec: int = DEFAULT_CODE_TTL_SEC) -> int:
	return now_unix() + maxi(60, ttl_sec)


static func is_expired(exp_unix: int, now: int = -1) -> bool:
	if exp_unix <= 0:
		return false  # no expiry embedded (bare ip:port)
	var t := now if now >= 0 else now_unix()
	return t > exp_unix


static func hash_password(password: String, salt: String) -> String:
	var raw := ("%s\n%s" % [salt, password]).to_utf8_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(raw)
	return Marshalls.raw_to_base64(ctx.finish())


static func password_matches(password: String, salt: String, expected_hash: String) -> bool:
	if expected_hash.is_empty():
		return password.strip_edges().is_empty()
	return hash_password(password, salt) == expected_hash


static func normalize_trusted_key(key: String) -> String:
	return key.strip_edges().to_lower()


static func parse_trusted_keys(text: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	for line in text.replace(",", "\n").split("\n"):
		var k := normalize_trusted_key(line)
		if k.is_empty() or seen.has(k):
			continue
		seen[k] = true
		out.append(k)
	return out


static func trusted_key_allowed(key: String, allowlist: PackedStringArray) -> bool:
	if allowlist.is_empty():
		return true
	var n := normalize_trusted_key(key)
	if n.is_empty():
		return false
	for k in allowlist:
		if str(k) == n:
			return true
	return false


static func mint_friend_key() -> String:
	return "%04x-%04x" % [randi() & 0xffff, randi() & 0xffff]


## Returns {ok, cost_total} or {ok:false, reason} when over limit.
static func rate_note(bucket: Dictionary, peer_id: int, cost: int, now_sec: float = -1.0) -> Dictionary:
	if peer_id <= 0 or cost <= 0:
		return {"ok": true, "cost_total": 0}
	var t := now_sec if now_sec >= 0.0 else Time.get_ticks_msec() / 1000.0
	var entry: Dictionary = bucket.get(peer_id, {}) as Dictionary
	var window_start := float(entry.get("t", t))
	var total := int(entry.get("c", 0))
	if t - window_start >= RATE_WINDOW_SEC:
		window_start = t
		total = 0
	total += cost
	bucket[peer_id] = {"t": window_start, "c": total}
	if total > RATE_MAX_COST:
		return {"ok": false, "reason": "rate_limit", "cost_total": total}
	return {"ok": true, "cost_total": total}


## ── Admission (Discord verification is async; rpc_hello is not) ──────────────
##
## A peer is ADMITTED once it has cleared every gate and appears in `peers` with
## `ready == true`. While a Discord check is in flight the peer is connected at
## the ENet level but must not be able to do anything, so these two predicates
## are consulted by `MultiplayerSession.peer_admitted()` — which in turn gates
## `note_peer_traffic()`, and through it presence, chat and every design
## transfer.
##
## Pure so the states are testable without a second peer.

const ADMISSION_TIMEOUT_SEC := 12.0


static func peer_is_admitted(peers: Dictionary, peer_id: int) -> bool:
	if peer_id == 1:
		return true  # the host is always itself
	if peer_id <= 1:
		return false
	var entry: Variant = peers.get(peer_id, null)
	if not (entry is Dictionary):
		return false
	return bool((entry as Dictionary).get("ready", false))


## {allow, pending, reason}
##
## `allow == false` with `pending == true` means "hold, do not kick": a slow
## Discord round-trip must never kick a legitimate joiner who sent presence
## early, whereas the rate-limit path in `rate_note` DOES kick. Keeping the two
## apart is the whole reason this returns a dictionary rather than a bool.
static func admission_decision(peers: Dictionary, pending: Dictionary, peer_id: int) -> Dictionary:
	if peer_is_admitted(peers, peer_id):
		return {"allow": true, "pending": false, "reason": ""}
	if pending.has(peer_id):
		return {"allow": false, "pending": true, "reason": "awaiting verification"}
	return {"allow": false, "pending": false, "reason": "not admitted"}


## Peer ids whose pending admission has run out of time.
static func expired_admissions(pending: Dictionary, now_ms: int,
		timeout_sec: float = ADMISSION_TIMEOUT_SEC) -> Array:
	var out: Array = []
	var budget_ms := int(maxf(1.0, timeout_sec) * 1000.0)
	for pid in pending:
		var entry: Dictionary = pending[pid] as Dictionary
		if now_ms - int(entry.get("started_ms", now_ms)) > budget_ms:
			out.append(int(pid))
	out.sort()
	return out


## ── Telemetry ────────────────────────────────────────────────────────────────

## Keys whose values must never reach `user://mp_telemetry.log` or any other
## on-disk log. Lives here rather than in the Discord module because redaction
## is a telemetry concern and this file owns telemetry — the dependency must not
## run the other way.
## Note the deliberate omission of a bare "code": HTTP status codes and UPnP
## result codes are both named `code` throughout this project, and redacting
## those would gut the diagnostics without protecting anything. The OAuth
## authorization code is instead never handed to a logger at all.
const SECRET_KEYS := [
	"token", "discord_token", "access_token", "refresh_token",
	"code_verifier", "client_secret", "webhook_url",
	"directory_webhook", "relay_webhook", "password", "join_code",
]


## Strip secrets before anything reaches disk.
##
## `log_event` writes whatever dict it is handed into a PLAINTEXT file, and the
## admission path now handles Discord bearer tokens. Redaction happens here, at
## the choke point, rather than at each call site — a call site that forgets is
## exactly the failure this guards against. Recurses through nested dicts and
## arrays because a token arrives inside a `hello` payload, not at the top level.
static func redact(value: Variant, depth: int = 0) -> Variant:
	if depth > 8:
		return "<deep>"
	if value is Dictionary:
		var out: Dictionary = {}
		for k in (value as Dictionary):
			var key := str(k).to_lower()
			if SECRET_KEYS.has(key):
				out[k] = "<redacted>"
			else:
				out[k] = redact((value as Dictionary)[k], depth + 1)
		return out
	if value is Array:
		var arr: Array = []
		for v in (value as Array):
			arr.append(redact(v, depth + 1))
		return arr
	return value


static func log_event(kind: String, detail: Dictionary = {}) -> void:
	var row := {
		"t": now_unix(),
		"kind": kind,
		"detail": redact(detail),
	}
	var line := JSON.stringify(row) + "\n"
	var existing := ""
	if FileAccess.file_exists(TELEMETRY_PATH):
		var rf := FileAccess.open(TELEMETRY_PATH, FileAccess.READ)
		if rf != null:
			existing = rf.get_as_text()
			rf.close()
	# Rotate when oversized — keep the tail.
	if existing.length() + line.length() > MAX_TELEMETRY_BYTES:
		existing = existing.substr(maxi(0, existing.length() - (MAX_TELEMETRY_BYTES / 2)))
	var wf := FileAccess.open(TELEMETRY_PATH, FileAccess.WRITE)
	if wf == null:
		return
	wf.store_string(existing + line)
	wf.close()

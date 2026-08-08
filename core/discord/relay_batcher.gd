class_name DiscordRelayBatcher
extends RefCounted

## Coalesces in-game chat into a small number of Discord webhook payloads.
##
## No HTTP here — `build_flush()` returns ready-to-POST payload dictionaries and
## the Node half does the sending. That keeps every rule below testable offline,
## including the one that matters most:
##
##   EVERY payload carries `allowed_mentions: {"parse": []}`.
##
## Without it, a player typing `@everyone` in the game pings the entire Discord
## server. That is not a theoretical griefing vector — it is the first thing a
## tester will try.
##
## Sizing is set by the webhook route budget (~5 requests / 2 s per webhook),
## which is shared by every member of the community, so the batcher spends at
## most two author-attributed executes per flush and collapses any remainder
## into one session-attributed message.

const FLUSH_SEC := 2.0
const MAX_EXECUTES_PER_FLUSH := 2
const MAX_CONTENT := 2000
const MAX_QUEUE := 40
const COOLDOWN_SEC := 60.0
const MAX_CONSECUTIVE_429 := 3

var session_name: String = "SIMbiogenesis"
var _queue: Array = []      # [{name, text, avatar}]
var _dropped: int = 0
var _consecutive_429: int = 0
var _cooldown_until: float = 0.0


func configure(p_session_name: String) -> void:
	session_name = p_session_name.strip_edges()
	if session_name.is_empty():
		session_name = "SIMbiogenesis"


func clear() -> void:
	_queue.clear()
	_dropped = 0
	_consecutive_429 = 0
	_cooldown_until = 0.0


func pending() -> int:
	return _queue.size()


func dropped() -> int:
	return _dropped


func is_cooling_down(now_sec: float) -> bool:
	return now_sec < _cooldown_until


## Queue one in-game message. Overflow is counted, not silently lost — the next
## flush says how many were dropped.
func enqueue(from_name: String, text: String, avatar: String = "") -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	if _queue.size() >= MAX_QUEUE:
		_dropped += 1
		return
	_queue.append({
		"name": from_name.strip_edges() if not from_name.strip_edges().is_empty() else "Player",
		"text": t,
		"avatar": avatar.strip_edges(),
	})


## Ready-to-POST payloads, oldest first. Empties the queue.
## Returns [] while cooling down or when there is nothing to send.
func build_flush(now_sec: float = 0.0) -> Array:
	if is_cooling_down(now_sec) or (_queue.is_empty() and _dropped <= 0):
		return []

	# Group consecutive runs by author so one person talking reads naturally,
	# while preserving overall order.
	var runs: Array = []
	for row_v in _queue:
		var row: Dictionary = row_v
		var name := str(row["name"])
		if not runs.is_empty() and str((runs[-1] as Dictionary)["name"]) == name:
			((runs[-1] as Dictionary)["lines"] as Array).append(str(row["text"]))
		else:
			runs.append({"name": name, "avatar": str(row["avatar"]), "lines": [str(row["text"])]})
	_queue.clear()

	var payloads: Array = []
	var i := 0
	while i < runs.size() and payloads.size() < MAX_EXECUTES_PER_FLUSH - 1:
		var run: Dictionary = runs[i]
		payloads.append(_payload(str(run["name"]), str(run["avatar"]),
			"\n".join(run["lines"] as Array)))
		i += 1

	# Everything left collapses into ONE session-attributed message so a busy
	# camp can never outrun the route budget.
	var tail: Array = []
	while i < runs.size():
		var run2: Dictionary = runs[i]
		for line in (run2["lines"] as Array):
			tail.append("**%s:** %s" % [str(run2["name"]), str(line)])
		i += 1
	if _dropped > 0:
		tail.append("_(%d message%s dropped — chat was faster than Discord allows)_" % [
			_dropped, "" if _dropped == 1 else "s"])
		_dropped = 0
	if not tail.is_empty():
		payloads.append(_payload(session_name, "", "\n".join(tail)))
	return payloads


## Put a failed batch back at the FRONT so ordering survives a 429.
func requeue_payload(payload: Dictionary) -> void:
	var content := str(payload.get("content", ""))
	if content.is_empty():
		return
	_queue.push_front({
		"name": str(payload.get("username", session_name)),
		"text": content,
		"avatar": str(payload.get("avatar_url", "")),
	})


## Returns the number of seconds to wait before retrying.
func note_429(retry_after: float, now_sec: float) -> float:
	_consecutive_429 += 1
	var wait := maxf(0.5, retry_after) + 0.25
	if _consecutive_429 >= MAX_CONSECUTIVE_429:
		wait = COOLDOWN_SEC
		_consecutive_429 = 0
	_cooldown_until = now_sec + wait
	return wait


func note_success() -> void:
	_consecutive_429 = 0


func _payload(username: String, avatar: String, content: String) -> Dictionary:
	var body := content
	if body.length() > MAX_CONTENT:
		body = body.substr(0, MAX_CONTENT - 1) + "…"
	var out := {
		"content": body,
		"username": username.substr(0, 80),
		# Non-negotiable. See the class docstring.
		"allowed_mentions": {"parse": []},
	}
	if not avatar.is_empty():
		out["avatar_url"] = avatar
	return out

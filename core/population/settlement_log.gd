class_name SettlementLog
extends RefCounted

## What has been happening in the settlement — a persistent, readable feed.
##
## Two problems this solves.
##
## **Transience.** Everything the population sim had to say went out as a
## toast: a few seconds on screen, then gone. At 1440x the clock a whole day
## passes in a minute, so the player fast-forwards past every event that
## mattered and arrives at the consequences with no account of the causes.
##
## **The destructive drain.** `NpcPopulationBridge.take_events()` (now
## retired) EMPTIED the array, and two consumers called it — the graph view
## (which toasts) and the challenge bake engine (which watches for collapse).
## Whichever ran first won, so during a bake the player's toasts silently
## vanished. A ring buffer with per-consumer CURSORS fixes that by
## construction: reading is not a mutation, and two readers cannot starve
## each other.
##
## Quiet by design: no sound, nothing to dismiss, nothing modal. Severity
## exists to sort and tint, never to interrupt.

const CAP := 400

## Ordering matters — `at_least` filters on it.
const INFO := 0
const NOTE := 1
const ALERT := 2

## One glyph per event kind, shared by EVERY surface that renders log lines —
## the toast chips, the first-person strip and the settlement feed — so the
## visual language cannot drift between them. An unknown kind gets the neutral
## dot; alarm keys (need_unmet|…, oncall|…) match by prefix.
const KIND_ICONS: Dictionary = {
	"departed": "👋", "lost": "🕯", "collapse_warning": "⚠",
	"collapsed": "🏚", "deserted": "🏜", "skill_earned": "🎓",
	"duty_sub": "🔁", "duty_cover": "🔁", "oncall_page": "📟",
}

static func icon_for(kind: String) -> String:
	if KIND_ICONS.has(kind):
		return str(KIND_ICONS[kind])
	# The relief suffix wins over the alarm prefix — a cleared alarm's key is
	# the alarm key PLUS "_ok", and it must read as good news.
	if kind.ends_with("_ok"):
		return "✓"
	if kind.begins_with("need_unmet") or kind.begins_with("oncall|"):
		return "⚠"
	return "·"


var entries: Array = []          # of {seq, abs_h, kind, severity, text, subject}
var _seq := 0
var _cursors: Dictionary = {}    # consumer name -> last seq handed out
## kind|subject -> true while an alarm of that identity is standing, so the
## relief line fires once and the alarm never repeats.
var _latched: Dictionary = {}


static func create_empty() -> SettlementLog:
	return SettlementLog.new()


## `meta` is optional presentation structure (e.g. {"title": …, "detail": …})
## for surfaces that render richer than one line — the toast chips split a
## headline from its detail. The `text` stays the complete readable sentence,
## so every plain-line consumer needs nothing new.
func add(kind: String, text: String, abs_h: float, severity: int = INFO,
		subject: String = "", meta: Dictionary = {}) -> void:
	_seq += 1
	var entry := {
		"seq": _seq, "abs_h": abs_h, "kind": kind,
		"severity": severity, "text": text, "subject": subject,
	}
	if not meta.is_empty():
		entry["meta"] = meta.duplicate()
	entries.append(entry)
	if entries.size() > CAP:
		entries = entries.slice(entries.size() - CAP)


## Raise a standing alarm ONCE. Returns true if it was actually new.
##
## Latching is the whole reason this is not just `add`: a blocked need flaps
## every RETRY_BACKOFF_H as the agent retries, so an unlatched alarm would
## strobe the feed with the same line several times an hour.
func latch(key: String, text: String, abs_h: float,
		severity: int = ALERT, subject: String = "") -> bool:
	if bool(_latched.get(key, false)):
		return false
	_latched[key] = true
	add(key, text, abs_h, severity, subject)
	return true


## Clear a standing alarm, optionally posting the relief. Returns true if the
## alarm was actually up.
func clear_latch(key: String, relief_text: String, abs_h: float,
		subject: String = "") -> bool:
	if not bool(_latched.get(key, false)):
		return false
	_latched.erase(key)
	if not relief_text.is_empty():
		add(key + "_ok", relief_text, abs_h, INFO, subject)
	return true


func is_latched(key: String) -> bool:
	return bool(_latched.get(key, false))


## Everything this consumer has not seen yet. NON-destructive for every other
## consumer — that is the fix for the two-readers-race.
func since(consumer: String) -> Array:
	var last := int(_cursors.get(consumer, 0))
	var out: Array = []
	for e in entries:
		if int((e as Dictionary)["seq"]) > last:
			out.append(e)
	_cursors[consumer] = _seq
	return out


## Most recent first, newest `count`, optionally filtered by minimum severity.
func recent(count: int = 50, at_least: int = INFO) -> Array:
	var out: Array = []
	for i in range(entries.size() - 1, -1, -1):
		var e: Dictionary = entries[i]
		if int(e.get("severity", INFO)) < at_least:
			continue
		out.append(e)
		if out.size() >= count:
			break
	return out


## Standing alarms, for a status strip that should read "2 problems" rather
## than making the player scroll a log to find out.
##
## NEWEST first and ONE entry per latch key: an alarm that latched, cleared
## and re-latched has several entries under the same kind, and returning them
## all both over-counted the "(+N more)" suffix and put the OLDEST line at
## index 0 — exactly the one a headline must not show.
func open_alarms() -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for i in range(entries.size() - 1, -1, -1):
		var d: Dictionary = entries[i]
		var kind := str(d.get("kind", ""))
		if not bool(_latched.get(kind, false)) or seen.has(kind):
			continue
		seen[kind] = true
		out.append(d)
	return out


func clear() -> void:
	entries = []
	_cursors = {}
	_latched = {}
	_seq = 0

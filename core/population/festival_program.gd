class_name FestivalProgram
extends RefCounted

## A venue's PROGRAMME: the time windows during which it pulls a crowd, and
## how hard. Lives on the SpaceRegistry record (`rec.program`, an Array of
## slots) so it saves with the space and needs no second file.
##
##   slot = {day: int (-1 = every day), start_h, end_h, draw: 0..1,
##           label: String, load_w: float}
##
## `end_h <= start_h` wraps midnight (a 22:00–02:00 set). Outside every slot a
## venue is CLOSED: it keeps a small residual draw (people still drift past a
## quiet stage) unless it has no programme at all, in which case it is simply
## always open at the record's base `draw`. Pure static: feed it a record and
## an hour, get back what the venue is doing.

const CLOSED_DRAW := 0.15
const MAX_SLOTS := 24


static func normalize_slot(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	var d: Dictionary = raw
	return {
		"day": clampi(int(d.get("day", -1)), -1, 365),
		"start_h": fposmod(float(d.get("start_h", 20.0)), 24.0),
		"end_h": fposmod(float(d.get("end_h", 23.0)), 24.0),
		"draw": clampf(float(d.get("draw", 1.0)), 0.0, 1.0),
		"label": str(d.get("label", "")),
		"load_w": maxf(float(d.get("load_w", 0.0)), 0.0),
	}


static func normalize(raw: Variant) -> Array:
	var out: Array = []
	if not (raw is Array):
		return out
	for s in raw:
		var n := normalize_slot(s)
		if not n.is_empty():
			out.append(n)
		if out.size() >= MAX_SLOTS:
			break
	return out


## True when `hour` (0..24) falls inside the slot, wrapping midnight.
static func slot_covers(slot: Dictionary, hour: float, day: int = -1) -> bool:
	var sd := int(slot.get("day", -1))
	if sd >= 0 and day >= 0 and sd != day:
		return false
	var a := float(slot.get("start_h", 0.0))
	var b := float(slot.get("end_h", 0.0))
	var h := fposmod(hour, 24.0)
	if b > a:
		return h >= a and h < b
	# Wraps midnight (or a 24 h slot when a == b).
	return h >= a or h < b


## Hours until the slot ends, measured from `hour`.
static func hours_left(slot: Dictionary, hour: float) -> float:
	var b := float(slot.get("end_h", 0.0))
	var h := fposmod(hour, 24.0)
	return fposmod(b - h, 24.0)


## What the venue is doing now: {active, draw, label, load_w, ends_h,
## programmed}. `programmed` is false for a record with no slots at all.
static func state_at(rec: Dictionary, hour: float, day: int = -1) -> Dictionary:
	var slots: Array = rec.get("program", [])
	var base := clampf(float(rec.get("draw", 0.5)), 0.0, 1.0)
	if slots.is_empty():
		return {"active": true, "draw": base, "label": "", "load_w": 0.0,
			"ends_h": -1.0, "programmed": false}
	var best: Dictionary = {}
	for s in slots:
		if not (s is Dictionary) or not slot_covers(s, hour, day):
			continue
		if best.is_empty() or float(s["draw"]) > float(best["draw"]):
			best = s
	if best.is_empty():
		return {"active": false, "draw": CLOSED_DRAW * base, "label": "", "load_w": 0.0,
			"ends_h": -1.0, "programmed": true}
	return {"active": true, "draw": float(best["draw"]), "label": str(best.get("label", "")),
		"load_w": float(best.get("load_w", 0.0)), "ends_h": hours_left(best, hour),
		"programmed": true}


## The next slot to start after `hour` (today), {} when none.
static func next_slot(rec: Dictionary, hour: float) -> Dictionary:
	var slots: Array = rec.get("program", [])
	var best: Dictionary = {}
	var best_wait := INF
	var h := fposmod(hour, 24.0)
	for s in slots:
		if not (s is Dictionary):
			continue
		var wait := fposmod(float(s["start_h"]) - h, 24.0)
		if wait < best_wait:
			best_wait = wait
			best = s
	return best


## "20:00–02:00 Headliner" style text for a slot.
static func slot_text(slot: Dictionary) -> String:
	var a := float(slot.get("start_h", 0.0))
	var b := float(slot.get("end_h", 0.0))
	var txt := "%02d:%02d–%02d:%02d" % [int(a), int(round((a - floor(a)) * 60.0)) % 60,
		int(b), int(round((b - floor(b)) * 60.0)) % 60]
	var lbl := str(slot.get("label", ""))
	if not lbl.is_empty():
		txt += " " + lbl
	return txt

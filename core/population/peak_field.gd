class_name PeakField
extends RefCounted

## Who is at PEAK EXPERIENCE right now, across the whole site, and the score.
##
## Owned by NpcPopulationBridge, which hands it one CHUNK per tier source per
## tick — {ids: PackedStringArray, pos: PackedVector2Array, vib: PackedByteArray
## (1 = vibing with needs met and morale up), sid: PackedStringArray (the venue
## they are at, "" for none)} — and pushes the result back to the tiers. The
## field, not either tier, is the authority: a person keeps their peak when
## their camp switches tier, and full and light people are judged by the same
## neighbourhood count.
##
## Neighbourhoods are COUNTS over a grid of NpcPeak.CELL_M cells: every
## occupied cell's 3x3 block is summed once, and each person reads their own
## cell's block — O(people + occupied cells), no pairwise distances, which is
## what keeps a 900-person festival tick to well under a millisecond.
##
## Time rules (the clock is not monotonic): a step BACK freezes the field
## (nothing scores, nothing ends); a forward jump past CATCHUP_H is coping,
## not partying — every peak is cleared without scoring.
##
## The score {total, by_day, best} only ever grows. It persists per map
## (to_dict / save / load_from).

const CATCHUP_H := 6.0
const MAX_EVENTS := 256
const SAVE_VERSION := 1

var active: Dictionary = {}      # id -> {"since": abs_h, "sid": String}
## The charge toward a peak (NpcPeak): id -> hours of rate integrated so far.
## Saved with the score ("live" block) so a reloaded world picks its crowd up
## mid-peak; dropped when the clock lands more than CATCHUP_H away.
var charge: Dictionary = {}
## How many peaks each person has had this session (keys their threshold).
var episode: Dictionary = {}
## Who is being FED by peakers right now: id -> peakers in their block.
var fed: Dictionary = {}
## The player's spread multiplier (PopTestPrefs.peak_contagion; 1 = shipped).
var contagion := 1.0
var _thr: Dictionary = {}
## A second, NON-consuming record of onsets for the ground ripples (the toast
## drains `_events`): each onset gets a serial; readers keep their own cursor.
var serial := 0
var _log: Array = []
const LOG_MAX := 128
var total := 0
var by_day: Dictionary = {}      # int day -> onsets that day
var best := 0                    # most people peaking at once
var _last_h := NAN
var _events: Array = []
var _changed := false


## Advance to `abs_h`. `boost_of` maps venue space id -> onset multiplier.
## `label_of` (optional) maps it to the venue's display name for the events.
func step(abs_h: float, chunks: Array, boost_of: Dictionary = {}, label_of: Dictionary = {}) -> void:
	if is_nan(_last_h):
		_last_h = abs_h
		return
	var dt := abs_h - _last_h
	if dt < 0.0:
		_last_h = abs_h          # scrub back: freeze
		return
	if dt > CATCHUP_H:
		if not active.is_empty():
			active = {}
			_changed = true
		charge = {}
		fed = {}
		_last_h = abs_h
		return
	if dt == 0.0:
		return
	_last_h = abs_h
	# 1. Cell counts: vibing people and current peakers.
	var vib_cells: Dictionary = {}
	var pk_cells: Dictionary = {}
	for ch in chunks:
		var c: Dictionary = ch
		var ids: PackedStringArray = c["ids"]
		var pos: PackedVector2Array = c["pos"]
		var vib: PackedByteArray = c["vib"]
		for k in ids.size():
			if vib[k] == 0:
				continue
			var cell := _cell(pos[k])
			vib_cells[cell] = int(vib_cells.get(cell, 0)) + 1
			if active.has(ids[k]):
				pk_cells[cell] = int(pk_cells.get(cell, 0)) + 1
	var vib_block := _block_sums(vib_cells)
	var pk_block := _block_sums(pk_cells)
	# 2. Hold / end / charge / onset.
	var seen: Dictionary = {}
	var day := int(floor(abs_h / 24.0))
	fed = {}
	for ch in chunks:
		var c2: Dictionary = ch
		var ids2: PackedStringArray = c2["ids"]
		var pos2: PackedVector2Array = c2["pos"]
		var vib2: PackedByteArray = c2["vib"]
		var sids: PackedStringArray = c2["sid"]
		for k in ids2.size():
			var id := ids2[k]
			seen[id] = true
			var vibing := vib2[k] == 1
			var cell2 := _cell(pos2[k])
			var others := int(vib_block.get(cell2, 0)) - (1 if vibing else 0)
			if active.has(id):
				var rec: Dictionary = active[id]
				if NpcPeak.holds(vibing, others, float(rec["since"]), abs_h):
					rec.erase("lapse")
				elif not rec.has("lapse"):
					rec["lapse"] = abs_h
				elif abs_h - float(rec["lapse"]) >= NpcPeak.GRACE_H:
					active.erase(id)
					# The next peak needs a fresh threshold, from empty.
					episode[id] = int(episode.get(id, 0)) + 1
					_thr.erase(id)
					charge.erase(id)
					_changed = true
				continue
			var sid := sids[k]
			var pk := int(pk_block.get(cell2, 0)) if vibing else 0
			var r := NpcPeak.rate_h(others, pk, float(boost_of.get(sid, 1.0)), contagion) if vibing else 0.0
			var q := NpcPeak.charge_step(float(charge.get(id, 0.0)), r, dt)
			if q < 0.002:
				charge.erase(id)
			else:
				charge[id] = q
			if r > 0.0 and pk > 0:
				fed[id] = pk
			if r > 0.0 and q >= _threshold(id):
				active[id] = {"since": abs_h, "sid": sid}
				charge.erase(id)
				total += 1
				by_day[day] = int(by_day.get(day, 0)) + 1
				_changed = true
				_events.append({"id": id, "name": NpcAgent.name_for(id), "pos": pos2[k],
					"sid": sid, "venue": str(label_of.get(sid, "")), "abs_h": abs_h})
				serial += 1
				_log.append({"serial": serial, "pos": pos2[k], "abs_h": abs_h})
				if _log.size() > LOG_MAX:
					_log.pop_front()
				if _events.size() > MAX_EVENTS:
					_events.pop_front()
	# People no longer on site (left, resized away) are no longer peaking.
	for id in active.keys():
		if not seen.has(id):
			active.erase(id)
	for id in charge.keys():
		if not seen.has(id):
			charge.erase(id)
	if _thr.size() > seen.size():
		for id in _thr.keys():
			if not seen.has(id):
				_thr.erase(id)
	best = maxi(best, active.size())


static func _cell(p: Vector2) -> Vector2i:
	return Vector2i(int(floor(p.x / NpcPeak.CELL_M)), int(floor(p.y / NpcPeak.CELL_M)))


## Each occupied cell's 3x3 block total (cells nobody stands in are never asked).
static func _block_sums(cells: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in cells:
		var c: Vector2i = key
		var s := 0
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				s += int(cells.get(Vector2i(c.x + dx, c.y + dz), 0))
		out[c] = s
	return out


## When `id` started peaking, or NAN when they are not.
func since_of(id: String) -> float:
	var d: Variant = active.get(id)
	return float((d as Dictionary)["since"]) if d is Dictionary else NAN


## 0..1: how close `id` is to FUCK YES (1 while peaking).
func buzz_of(id: String) -> float:
	if active.has(id):
		return 1.0
	var q := float(charge.get(id, 0.0))
	if q <= 0.0:
		return 0.0
	return clampf(q / _threshold(id), 0.0, 1.0)


## This person's current threshold (cached; a hash + log per person per tick
## adds up at festival scale).
func _threshold(id: String) -> float:
	var t: Variant = _thr.get(id)
	if t == null:
		t = NpcPeak.threshold(id, int(episode.get(id, 0)))
		_thr[id] = t
	return float(t)


## Peakers in `id`'s neighbourhood feeding their charge (0 = none).
func fed_by(id: String) -> int:
	return int(fed.get(id, 0))


func is_peaking(id: String) -> bool:
	return active.has(id)


func peaking_count() -> int:
	return active.size()


func today(abs_h: float) -> int:
	return int(by_day.get(int(floor(abs_h / 24.0)), 0))


## The last `n` onset events, NOT consumed (the bridge's log summary).
func peek_recent(n: int) -> Array:
	return _events.slice(maxi(_events.size() - n, 0))


## Onsets with a serial above `after` (the ripples' cursor), oldest first —
## never consumed. At most LOG_MAX back.
func events_since(after: int) -> Array:
	var out: Array = []
	for e in _log:
		if int((e as Dictionary)["serial"]) > after:
			out.append(e)
	return out


## Onset events since the last call (for the toast), oldest first.
func take_events() -> Array:
	var out := _events
	_events = []
	return out


## True once after anything persistent changed (the bridge debounces saves).
func take_changed() -> bool:
	var c := _changed
	_changed = false
	return c


func to_dict() -> Dictionary:
	var days := {}
	for d in by_day:
		days[str(d)] = int(by_day[d])
	var out := {"version": SAVE_VERSION, "total": total, "by_day": days, "best": best}
	# Who is peaking and how charged everyone is, at the field's own clock.
	# step() already clears all of it when the clock lands more than CATCHUP_H
	# away, so a stale block is harmless.
	if not is_nan(_last_h):
		out["live"] = {"h": _last_h, "active": active, "charge": charge, "episode": episode}
	return out


func from_dict(d: Dictionary) -> void:
	total = maxi(int(d.get("total", 0)), 0)
	best = maxi(int(d.get("best", 0)), 0)
	by_day = {}
	var days: Dictionary = d.get("by_day", {})
	for k in days:
		by_day[int(str(k))] = int(days[k])
	var live: Variant = d.get("live", null)
	if live is Dictionary and not is_nan(float((live as Dictionary).get("h", NAN))):
		var lv: Dictionary = live
		_last_h = float(lv["h"])
		active = {}
		var act: Variant = lv.get("active", {})
		if act is Dictionary:
			for id in act:
				var a: Variant = act[id]
				if a is Dictionary:
					var r: Dictionary = {"since": float((a as Dictionary).get("since", _last_h)),
						"sid": str((a as Dictionary).get("sid", ""))}
					if (a as Dictionary).has("lapse"):
						r["lapse"] = float((a as Dictionary)["lapse"])
					active[str(id)] = r
		charge = {}
		var ch: Variant = lv.get("charge", {})
		if ch is Dictionary:
			for id2 in ch:
				charge[str(id2)] = float(ch[id2])
		episode = {}
		var ep: Variant = lv.get("episode", {})
		if ep is Dictionary:
			for id3 in ep:
				episode[str(id3)] = int(ep[id3])
		_thr = {}


func save(path: String) -> bool:
	if path.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict()))
	return true


func load_from(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var v: Variant = JSON.parse_string(f.get_as_text())
	if not (v is Dictionary):
		return false
	from_dict(v)
	return true

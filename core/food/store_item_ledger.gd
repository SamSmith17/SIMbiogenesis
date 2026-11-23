class_name StoreItemLedger
extends RefCounted
## The ITEM ledger of one graph store (plans/FOOD_WASTE_REALISM_PLAN.md
## Phase 5): which discrete things — packaged products in a supply store,
## bottles and cans in a waste bin — the store's kg ARE. Kilograms stay the
## graph's authority (the tank timeline); this is the fine structure the
## unpack draws from FIFO, the 3D bins render, and the kcal density rides.
##
## Shape: a BASELINE (what the store held when the ledger started) plus an
## append-only EVENT log, so any question is a pure function of a time:
## `counts_at(t)` / `kg_at(t)` / `density_at(t)` fold baseline + the events
## at or before t. A scrub back is `truncate_after(t)` (the ResourceTimeline
## / CompositionTrack discipline); a render snapshot is `snapshot()` /
## `restore()`. Nothing here reads a clock or rolls dice: `take_fifo` is
## deterministic in (state, t), which is what keeps replays byte-identical.
##
## Event kinds:
##   item: {t, id, dc, dkg}            — dc items of product/archetype id,
##                                       dkg their (gross) kilograms, either sign
##   mix:  {t, kg0, kg_in, d_in}       — kg_in of material at d_in kcal/kg
##                                       flowed into a bulk store holding kg0
##                                       (the pantry's kcal density events)
##
## Old saves and stores filled before the ledger existed simply have none:
## every consumer falls back to bulk fractions / the generic density.

## Fold events older than this into the baseline when the log grows past
## MAX_EVENTS (a scrub can then not rewind past the fold — like the tank
## timelines' own 14-day window).
const KEEP_H := 14.0 * 24.0
const MAX_EVENTS := 4096

## Bumped on every mutation — the engine's change gate for persisting the
## compact state into the store's specs.
var rev := 0

var _base_t := -INF
var _base_counts: Dictionary = {}  # id -> int, in arrival order
var _base_kg := 0.0
var _base_density := -1.0          # kcal/kg of the baseline bulk, -1 = unknown
var _events: Array = []

# Monotone read cursor (rebuilt on any non-monotone read or edit).
var _cur_idx := 0
var _cur_t := -INF
var _cur_counts: Dictionary = {}
var _cur_kg := 0.0


## --- building the ledger --------------------------------------------------------

func set_baseline(t: float, counts: Dictionary, kg: float, density: float = -1.0) -> void:
	rev += 1
	_base_t = t
	_base_counts = {}
	for id in counts:
		var n := int(counts[id])
		if n > 0:
			_base_counts[str(id)] = n
	_base_kg = maxf(kg, 0.0)
	_base_density = density
	_events = []
	_reset_cursor()


func record(t: float, id: String, dcount: int, dkg: float) -> void:
	if dcount == 0 and absf(dkg) < 1e-12:
		return
	rev += 1
	_events.append({"t": t, "id": id, "dc": dcount, "dkg": dkg})
	if _events.size() > MAX_EVENTS:
		_fold(t - KEEP_H)
	_reset_cursor()


## kg_in of bulk material at d_in kcal/kg flowed into a store holding kg0.
func record_mix(t: float, kg0: float, kg_in: float, d_in: float) -> void:
	if kg_in <= 0.0:
		return
	rev += 1
	_events.append({"t": t, "kg0": maxf(kg0, 0.0), "kg_in": kg_in, "d_in": d_in})
	if _events.size() > MAX_EVENTS:
		_fold(t - KEEP_H)
	_reset_cursor()


func is_empty() -> bool:
	return _events.is_empty() and _base_counts.is_empty() and _base_t == -INF


## --- reads (pure in t) ------------------------------------------------------------

## {id: count} held at t, insertion-ordered (oldest id first).
func counts_at(t: float) -> Dictionary:
	_advance(t)
	var out: Dictionary = {}
	for id in _cur_counts:
		if int(_cur_counts[id]) > 0:
			out[id] = int(_cur_counts[id])
	return out


## Total item count at t.
func total_count_at(t: float) -> int:
	var n := 0
	for v in counts_at(t).values():
		n += int(v)
	return n


## The kg the ledger accounts for at t (baseline + item and mix events).
func kg_at(t: float) -> float:
	_advance(t)
	return maxf(_cur_kg, 0.0)


## kcal/kg of the bulk at t, folded over the mix events; `fallback` when the
## ledger has never seen a mix.
func density_at(t: float, fallback: float) -> float:
	var d := _base_density if _base_density > 0.0 else fallback
	for e in _events:
		if float(e.get("t", INF)) > t:
			break
		if not e.has("kg_in"):
			continue
		var kg0 := float(e["kg0"])
		var kg_in := float(e["kg_in"])
		d = (kg0 * d + kg_in * float(e["d_in"])) / maxf(kg0 + kg_in, 1e-9)
	return d


## Take up to want_kg of WHOLE items, oldest first (arrival order: the
## baseline's insertion order, then the event log's). Returns
## [{id, count, kg}] — kg is the items' share of the ledger kg, derived
## from per-item mass via `kg_of.call(id)`. Pure: the caller records the
## matching negative events itself once the step really ran.
func take_fifo(t: float, want_kg: float, kg_of: Callable) -> Array:
	var remaining: Dictionary = {}
	var order: Array = []
	for id in _base_counts:
		remaining[id] = int(_base_counts[id])
		order.append(id)
	for e in _events:
		if float(e.get("t", INF)) > t:
			break
		if not e.has("id"):
			continue
		var id := str(e["id"])
		remaining[id] = int(remaining.get(id, 0)) + int(e["dc"])
		if not order.has(id):
			order.append(id)
	var out: Array = []
	var budget := want_kg
	for id in order:
		var have := int(remaining.get(id, 0))
		if have <= 0:
			continue
		var unit_kg := maxf(float(kg_of.call(id)), 1e-6)
		var n := mini(have, int(floor(budget / unit_kg + 1e-9)))
		if n <= 0:
			break  # FIFO: the next-oldest item does not fit the budget
		out.append({"id": id, "count": n, "kg": unit_kg * float(n)})
		budget -= unit_kg * float(n)
	return out


## --- scrub, snapshot, persistence ---------------------------------------------------

## Drop everything after t (the clock scrubbed back). The baseline is the
## floor: a scrub past the baseline keeps it (like the tank timelines'
## retention window).
func truncate_after(t: float) -> void:
	var keep := 0
	for e in _events:
		if float(e.get("t", INF)) > t:
			break
		keep += 1
	if keep < _events.size():
		rev += 1
		_events.resize(keep)
		_reset_cursor()


func snapshot() -> Dictionary:
	return {
		"t": _base_t, "counts": _base_counts.duplicate(), "kg": _base_kg,
		"density": _base_density, "events": _events.duplicate(true),
	}


func restore(snap: Dictionary) -> void:
	if snap.is_empty():
		return
	rev += 1
	_base_t = float(snap.get("t", -INF))
	_base_counts = (snap.get("counts", {}) as Dictionary).duplicate()
	_base_kg = float(snap.get("kg", 0.0))
	_base_density = float(snap.get("density", -1.0))
	_events = (snap.get("events", []) as Array).duplicate(true)
	_reset_cursor()


## The compact state a store's specs carry across a save (just the NOW
## counts: a reload starts a fresh log from this baseline).
func persist_state(t: float, fallback_density: float = -1.0) -> Dictionary:
	return {"t": t, "counts": counts_at(t), "kg": kg_at(t),
		"density": density_at(t, fallback_density)}


## Rebuild from a persisted state (a loaded save).
func load_persisted(d: Dictionary) -> void:
	set_baseline(float(d.get("t", 0.0)), d.get("counts", {}), float(d.get("kg", 0.0)),
			float(d.get("density", -1.0)))


## --- internals -------------------------------------------------------------------

func _reset_cursor() -> void:
	_cur_idx = 0
	_cur_t = -INF
	_cur_counts = _base_counts.duplicate()
	_cur_kg = _base_kg


func _advance(t: float) -> void:
	if t < _cur_t:
		_reset_cursor()
	_cur_t = t
	while _cur_idx < _events.size():
		var e: Dictionary = _events[_cur_idx]
		if float(e.get("t", INF)) > t:
			break
		if e.has("id"):
			var id := str(e["id"])
			_cur_counts[id] = int(_cur_counts.get(id, 0)) + int(e["dc"])
			_cur_kg += float(e["dkg"])
		else:
			_cur_kg += float(e["kg_in"])
		_cur_idx += 1


## Fold events at or before `cut` into the baseline, keeping arrival order
## (a Godot Dictionary preserves insertion order).
func _fold(cut: float) -> void:
	var folded := 0
	for e in _events:
		if float(e.get("t", INF)) > cut:
			break
		if e.has("id"):
			var id := str(e["id"])
			_base_counts[id] = int(_base_counts.get(id, 0)) + int(e["dc"])
			if int(_base_counts[id]) <= 0:
				_base_counts.erase(id)
			_base_kg += float(e["dkg"])
		else:
			var kg0 := float(e["kg0"])
			var kg_in := float(e["kg_in"])
			var d := _base_density
			if d <= 0.0:
				d = float(e["d_in"])
			_base_density = (kg0 * d + kg_in * float(e["d_in"])) / maxf(kg0 + kg_in, 1e-9)
			_base_kg += kg_in
		_base_t = float(e["t"])
		folded += 1
	if folded > 0:
		_events = _events.slice(folded)
		_reset_cursor()

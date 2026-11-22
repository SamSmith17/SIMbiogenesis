class_name EnergySpanStore
extends RefCounted

## Minutes of solar, load and battery that survive a scrub.
##
## EnergyTimeline is the live battery's ring (14 days, one contiguous run). A
## scrub past its end used to stamp the power at the landing across every
## skipped minute, and the tracks only drew that ring, so the curves vanished
## or went flat the moment the window followed the playhead.
##
## This store keeps every minute already simulated, and fills the holes in the
## visible window both ways. Lived minutes (what the battery actually did) and
## a render win over a background fill. A graph edit clears the store; a scrub
## does not. State of charge is integrated from the nearest known minute with
## the same step the live tape uses, so an unchanged graph replays the same
## curve. Load keeps its average and its coincident peak apart, the same way
## the live tape does.
##
## Far from the playhead, or when the track is zoomed out past an hour per bin,
## samples are one per hour. Filled hours hold whatever the evaluator returns;
## the live evaluator holds the current aux across those hours.

const MINUTE_H := 1.0 / 60.0
const DETAIL_H := 14.0 * 24.0
const COARSE_H := 183.0 * 24.0
const MAX_MINUTES := 60 * 1440
const MAX_HOURS := 3 * 366 * 24

const KIND_FILLED := 0
const KIND_LIVED := 2

var generation: int = 0

var _mins: Array = []
var _hours: Array = []

var _open_idx := -1
var _open_solar := PackedFloat32Array()
var _open_aux := PackedFloat32Array()
var _open_load := PackedFloat32Array()
var _open_peak := PackedFloat32Array()
var _open_raw := PackedFloat32Array()
var _open_soc := PackedFloat32Array()

var _win0 := NAN
var _win1 := NAN
var _play := 0.0
var _bin_w := 1.0
var _window := false

var _phase := 0
var _gap_g := -1
var _gap_soc := 0.0
var _gap_dir := 0
var _gap_hour := false

var _mf := 0
var _mb := 0
var _mf_soc := 0.0
var _mb_soc := 0.0
var _m_on := false

var _hf := 0
var _hb := 0
var _hf_soc := 0.0
var _hb_soc := 0.0
var _h_on := false
var _min_flip := false
var _hour_flip := false


## A jump the clock did not earn by playing this tick. `frame_h` is the hours
## the battery tick itself would have advanced (sim step × time scale).
static func jump_is_scrub(jump_h: float, frame_h: float, step_h: float) -> bool:
	var limit := maxf(absf(frame_h) * 2.0, step_h * 2.0)
	return absf(jump_h) > limit + 1e-6


func clear() -> void:
	_close_open()
	_mins.clear()
	_hours.clear()
	generation += 1
	restart()


## The playhead jumped. The window stays; the fill walks to the new instant
## from the nearest minute it already has.
func retarget_playhead(playhead: float) -> void:
	_play = playhead
	restart()


func restart() -> void:
	_phase = 0
	_gap_g = -1
	_gap_dir = 0
	_gap_hour = false
	_m_on = false
	_h_on = false


func has_any() -> bool:
	return not _mins.is_empty() or not _hours.is_empty() or _open_idx >= 0


func minute_count() -> int:
	return _sample_count(_mins) + (0 if _open_idx < 0 else 0)


func hour_count() -> int:
	_flush_open()
	return _sample_count(_hours)


## The visible track. A playhead jump of more than an hour, or a change of bin
## width, starts the fill again from that playhead. Panning only moves the
## targets; minutes already stored stay, and the cursors keep walking.
func note_window(t0: float, t1: float, playhead: float, bin_w: float) -> void:
	var width := maxf(bin_w, MINUTE_H)
	if not _window:
		_win0 = t0
		_win1 = t1
		_play = playhead
		_bin_w = width
		_window = true
		restart()
		return
	var jumped := absf(playhead - _play) > 1.0 or absf(width - _bin_w) > 1e-6
	_win0 = t0
	_win1 = t1
	_play = playhead
	_bin_w = width
	if jumped:
		restart()


## Drop samples after `abs_h` (that instant stays) and fill again from there.
func truncate_after_hours(abs_h: float) -> void:
	_close_open()
	var g := _minute_of(abs_h)
	var cut := false
	if _cut_list(_mins, g):
		cut = true
	if _cut_list(_hours, _hour_of(abs_h)):
		cut = true
	if cut:
		generation += 1
	restart()


func has_minute(g: int) -> bool:
	return _covered(_mins, g)


func covers_minutes(g0: int, g1: int) -> bool:
	if g1 < g0:
		return true
	var g := g0
	while g <= g1:
		if not has_minute(g):
			return false
		g += 1
	return true


func sample_minute(g: int) -> Dictionary:
	_flush_open()
	var s := _span_holding(_mins, g)
	if s.is_empty():
		return {}
	var i := g - int(s["a"])
	return _sample_dict(s, i)


## SOC at an instant: the minute if one was stored, otherwise the hour that
## covers it. NAN when neither was.
func soc_at_hours(abs_h: float) -> float:
	var g := _minute_of(abs_h)
	if has_minute(g):
		return _minute_soc(g)
	var h := _hour_of(abs_h)
	if _covered(_hours, h):
		return _hour_soc(h)
	return NAN


## Copy a lived run over whatever a fill had written there. `base_g` is the
## minute index of element 0. Empty arrays are ignored.
func write_lived_run(base_g: int, soc: PackedFloat32Array, solar: PackedFloat32Array,
		aux: PackedFloat32Array, load: PackedFloat32Array, peak: PackedFloat32Array,
		raw: PackedFloat32Array) -> void:
	var n := soc.size()
	if n <= 0:
		return
	_close_open()
	var b := base_g + n - 1
	_excise(_mins, base_g, b)
	_insert_merged(_mins, base_g, b, KIND_LIVED, solar, aux, load, peak, raw, soc)
	generation += 1


## Evaluate holes until the budget runs out. `eval` is
## Callable(abs_h, soc) -> {solar_kw, aux_kw, load_kw, load_peak_kw, raw_kw}.
## `limits` is {cap, ceff, deff, min_kwh, max_c, max_d}. Returns how many new
## samples were written.
func pump(budget_us: int, eval: Callable, anchor_h: float, anchor_soc: float,
		limits: Dictionary) -> int:
	if not _window or not eval.is_valid() or budget_us <= 0:
		return 0
	var t0 := Time.get_ticks_usec()
	var wrote := 0
	while Time.get_ticks_usec() - t0 < budget_us:
		var step := _pump_one(eval, anchor_h, anchor_soc, limits)
		if step == 0:
			break
		if step == 2:
			wrote += 1
	if wrote > 0:
		generation += 1
	_evict(_minute_of(_play))
	_flush_open()
	return wrote


## Timeline bins for one channel over anchored bins i0 .. i0+n-1 of width `w`.
## Minutes win over an hour sample in the same hour. Load peaks lift only the
## top of the band.
func bins(channel: String, w: float, i0: int, n: int, cap_kwh: float) -> Dictionary:
	_flush_open()
	var out := TimelineBinning.empty(w, i0, n)
	if n <= 0 or w <= 0.0:
		return out
	var sum := PackedFloat32Array()
	var cnt := PackedInt32Array()
	sum.resize(n)
	cnt.resize(n)
	var mn: PackedFloat32Array = out["mn"]
	var mx: PackedFloat32Array = out["mx"]
	_accumulate(_mins, true, channel, w, i0, n, cap_kwh, mn, mx, sum, cnt)
	_accumulate(_hours, false, channel, w, i0, n, cap_kwh, mn, mx, sum, cnt)
	var me: PackedFloat32Array = out["mean"]
	for b in n:
		if cnt[b] > 0:
			me[b] = sum[b] / float(cnt[b])
		else:
			mn[b] = NAN
			mx[b] = NAN
			me[b] = NAN
	return out


# ---------------------------------------------------------------------------
# Fill
# ---------------------------------------------------------------------------

func _pump_one(eval: Callable, anchor_h: float, anchor_soc: float, limits: Dictionary) -> int:
	if _phase == 0:
		return _gap_step(eval, anchor_h, anchor_soc, limits)
	if _phase == 1:
		var r := _minute_out_step(eval, limits)
		if r != 0:
			return r
		_phase = 2
	return _hour_out_step(eval, limits)


func _gap_step(eval: Callable, _anchor_h: float, anchor_soc: float, limits: Dictionary) -> int:
	var play_g := _minute_of(_play)
	if _gap_dir == 0:
		var seed := _nearest_minute(play_g)
		if seed < 0:
			var seed_h := _nearest_hour(_hour_of(_play))
			if seed_h < 0:
				if _bin_w >= 1.0:
					_plant_hour(_hour_of(_play), anchor_soc, eval)
					_arm_outward(play_g, anchor_soc)
				else:
					_plant_minute(play_g, anchor_soc, eval)
					_arm_outward(play_g, anchor_soc)
				_phase = 1
				return 2
			_gap_g = seed_h * 60
			_gap_soc = _hour_soc(seed_h)
			_gap_hour = true
		else:
			_gap_g = seed
			_gap_soc = _minute_soc(seed)
			_gap_hour = _bin_w >= 1.0 or absf(_time_of_minute(seed) - _play) > DETAIL_H
		if (not _gap_hour and _gap_g == play_g) or (_gap_hour and _hour_of(_time_of_minute(_gap_g)) == _hour_of(_play)):
			_land_playhead(play_g, _gap_soc, eval)
			_arm_outward(play_g, _gap_soc)
			_phase = 1
			return 1
		_gap_dir = 1 if play_g > _gap_g else -1
		return 1
	if _gap_hour:
		return _gap_hour_step(eval, limits, play_g)
	return _gap_minute_step(eval, limits, play_g)


func _gap_minute_step(eval: Callable, limits: Dictionary, play_g: int) -> int:
	var nxt := _gap_g + _gap_dir
	var got := _ensure_minute(nxt, _gap_soc, _gap_dir, eval, limits)
	_gap_g = nxt
	_gap_soc = float(got["soc"])
	var arrived := (_gap_dir > 0 and nxt >= play_g) or (_gap_dir < 0 and nxt <= play_g)
	if arrived:
		_arm_outward(play_g, _gap_soc)
		_phase = 1
	return 2 if bool(got["wrote"]) else 1


func _gap_hour_step(eval: Callable, limits: Dictionary, play_g: int) -> int:
	var nxt := _gap_g + _gap_dir * 60
	var h := _hour_of(_time_of_minute(nxt))
	var got := _ensure_hour(h, _gap_soc, _gap_dir, eval, limits)
	_gap_g = h * 60
	_gap_soc = float(got["soc"])
	var play_h := _hour_of(_play)
	var arrived := (_gap_dir > 0 and h >= play_h) or (_gap_dir < 0 and h <= play_h)
	if arrived:
		_land_playhead(play_g, _gap_soc, eval)
		_arm_outward(play_g, _gap_soc)
		_phase = 1
	return 2 if bool(got["wrote"]) else 1


func _minute_out_step(eval: Callable, limits: Dictionary) -> int:
	if _bin_w >= 1.0 or not _m_on:
		return 0
	var a := maxf(_win0, _play - DETAIL_H)
	var b := minf(_win1, _play + DETAIL_H)
	if b < a:
		return 0
	var ga := _minute_of(a)
	var gb := _minute_of(b)
	var can_fwd := _mf < gb
	var can_back := _mb > ga
	if not can_fwd and not can_back:
		return 0
	var go_fwd := can_fwd and (not can_back or not _min_flip)
	_min_flip = not _min_flip
	if go_fwd:
		var nxt := _mf + 1
		var got := _ensure_minute(nxt, _mf_soc, 1, eval, limits)
		_mf = nxt
		_mf_soc = float(got["soc"])
		return 2 if bool(got["wrote"]) else 1
	var prev := _mb - 1
	var back := _ensure_minute(prev, _mb_soc, -1, eval, limits)
	_mb = prev
	_mb_soc = float(back["soc"])
	return 2 if bool(back["wrote"]) else 1


func _hour_out_step(eval: Callable, limits: Dictionary) -> int:
	if not _h_on:
		return 0
	var a := maxf(_win0, _play - COARSE_H)
	var b := minf(_win1, _play + COARSE_H)
	if b < a:
		return 0
	var ha := _hour_of(a)
	var hb := _hour_of(b)
	var can_fwd := _hf < hb
	var can_back := _hb > ha
	if not can_fwd and not can_back:
		return 0
	var go_fwd := can_fwd and (not can_back or not _hour_flip)
	_hour_flip = not _hour_flip
	if go_fwd:
		var nxt := _hf + 1
		if _hour_skipped(nxt):
			_hf = nxt
			_hf_soc = _soc_covering_hour(nxt, _hf_soc)
			return 1
		var got := _ensure_hour(nxt, _hf_soc, 1, eval, limits)
		_hf = nxt
		_hf_soc = float(got["soc"])
		return 2 if bool(got["wrote"]) else 1
	var prev := _hb - 1
	if _hour_skipped(prev):
		_hb = prev
		_hb_soc = _soc_covering_hour(prev, _hb_soc)
		return 1
	var back := _ensure_hour(prev, _hb_soc, -1, eval, limits)
	_hb = prev
	_hb_soc = float(back["soc"])
	return 2 if bool(back["wrote"]) else 1


func _arm_outward(play_g: int, soc: float) -> void:
	_mf = play_g
	_mb = play_g
	_mf_soc = soc
	_mb_soc = soc
	_m_on = true
	var h := _hour_of(_play)
	_hf = h
	_hb = h
	_hf_soc = soc
	_hb_soc = soc
	_h_on = true


func _land_playhead(play_g: int, soc: float, eval: Callable) -> void:
	if _bin_w < 1.0 and not has_minute(play_g):
		_plant_minute(play_g, soc, eval)


func _soc_covering_hour(h: int, fallback: float) -> float:
	if _covered(_hours, h):
		return _hour_soc(h)
	var last := -1
	var soc := fallback
	for s in _mins:
		var span: Dictionary = s
		var a := int(span["a"])
		var b := int(span["b"])
		var g0 := h * 60
		var g1 := g0 + 59
		if b < g0 or a > g1:
			continue
		var g := mini(b, g1)
		if g >= last:
			last = g
			soc = _minute_soc(g)
	return soc if last >= 0 else fallback


func _hour_skipped(h: int) -> bool:
	if _covered(_hours, h):
		return true
	return _any_minutes_in(h * 60, h * 60 + 59)


func _ensure_minute(g: int, from_soc: float, dir: int, eval: Callable, limits: Dictionary) -> Dictionary:
	if has_minute(g):
		return {"soc": _minute_soc(g), "wrote": false}
	var inp := _inputs(eval, _time_of_minute(g), from_soc)
	var soc := _integrate(from_soc, inp, dir, MINUTE_H, limits)
	_write_filled_minute(g, float(inp["solar_kw"]), float(inp["aux_kw"]), float(inp["load_kw"]),
		float(inp["load_peak_kw"]), float(inp["raw_kw"]), soc)
	return {"soc": soc, "wrote": true}


func _ensure_hour(h: int, from_soc: float, dir: int, eval: Callable, limits: Dictionary) -> Dictionary:
	if _covered(_hours, h):
		return {"soc": _hour_soc(h), "wrote": false}
	var inp := _inputs(eval, float(h), from_soc)
	var soc := _integrate(from_soc, inp, dir, 1.0, limits)
	_write_filled_hour(h, float(inp["solar_kw"]), float(inp["aux_kw"]), float(inp["load_kw"]),
		float(inp["load_peak_kw"]), float(inp["raw_kw"]), soc)
	return {"soc": soc, "wrote": true}


func _plant_minute(g: int, soc: float, eval: Callable) -> void:
	if has_minute(g):
		return
	var inp := _inputs(eval, _time_of_minute(g), soc)
	_write_filled_minute(g, float(inp["solar_kw"]), float(inp["aux_kw"]), float(inp["load_kw"]),
		float(inp["load_peak_kw"]), float(inp["raw_kw"]), soc)


func _plant_hour(h: int, soc: float, eval: Callable) -> void:
	if _covered(_hours, h):
		return
	var inp := _inputs(eval, float(h), soc)
	_write_filled_hour(h, float(inp["solar_kw"]), float(inp["aux_kw"]), float(inp["load_kw"]),
		float(inp["load_peak_kw"]), float(inp["raw_kw"]), soc)


func _inputs(eval: Callable, abs_h: float, soc: float) -> Dictionary:
	var raw: Variant = eval.call(abs_h, soc)
	var d: Dictionary = {}
	if raw is Dictionary:
		d = raw
	var solar := float(d.get("solar_kw", 0.0))
	var aux := float(d.get("aux_kw", 0.0))
	var load := float(d.get("load_kw", 0.0))
	var peak := float(d.get("load_peak_kw", load))
	if peak < load:
		peak = load
	return {
		"solar_kw": solar, "aux_kw": aux, "load_kw": load,
		"load_peak_kw": peak, "raw_kw": float(d.get("raw_kw", solar)),
	}


func _integrate(soc: float, inp: Dictionary, dir: int, dt: float, limits: Dictionary) -> float:
	var cap := float(limits.get("cap", 16.0))
	var ceff := float(limits.get("ceff", 1.0))
	var deff := float(limits.get("deff", 1.0))
	var mn := float(limits.get("min_kwh", 0.0))
	var max_c := float(limits.get("max_c", INF))
	var max_d := float(limits.get("max_d", INF))
	var solar := float(inp["solar_kw"])
	var aux := float(inp["aux_kw"])
	var load := float(inp["load_kw"])
	if dir >= 0:
		return EnergyTimeline.step_soc_lim(soc, solar, aux, load, dt, cap, ceff, deff, mn, max_c, max_d)
	return clampf(EnergyTimeline.unstep_soc(soc, solar, aux, load, dt, cap, ceff, deff, mn), 0.0, cap)


# ---------------------------------------------------------------------------
# Samples
# ---------------------------------------------------------------------------

func _write_filled_minute(g: int, solar: float, aux: float, load: float, peak: float,
		raw: float, soc: float) -> void:
	if _minute_covered(g):
		return
	if _open_idx >= 0 and _open_idx < _mins.size():
		var open: Dictionary = _mins[_open_idx]
		if int(open["kind"]) == KIND_FILLED and int(open["b"]) + 1 == g:
			_append_open(solar, aux, load, peak, raw, soc)
			open["b"] = g
			return
		_close_open()
	var prev := _span_ending_at(_mins, g - 1, KIND_FILLED)
	if prev >= 0:
		_adopt_open(prev)
		_append_open(solar, aux, load, peak, raw, soc)
		(_mins[prev] as Dictionary)["b"] = g
		return
	var span := _one_span(g, KIND_FILLED, solar, aux, load, peak, raw, soc)
	var idx := _insert_only(_mins, span)
	_adopt_open(idx)


func _write_filled_hour(h: int, solar: float, aux: float, load: float, peak: float,
		raw: float, soc: float) -> void:
	if _covered(_hours, h):
		return
	var prev := _span_ending_at(_hours, h - 1, KIND_FILLED)
	if prev >= 0:
		var s: Dictionary = _hours[prev]
		_append_span(s, solar, aux, load, peak, raw, soc)
		s["b"] = h
		return
	_insert_only(_hours, _one_span(h, KIND_FILLED, solar, aux, load, peak, raw, soc))


func _minute_covered(g: int) -> bool:
	if _open_idx >= 0 and _open_idx < _mins.size():
		var s: Dictionary = _mins[_open_idx]
		if g >= int(s["a"]) and g <= int(s["b"]):
			return true
	return _covered(_mins, g)


func _arm_arrays_from(s: Dictionary) -> void:
	_open_solar = s["solar"]
	_open_aux = s["aux"]
	_open_load = s["load"]
	_open_peak = s["peak"]
	_open_raw = s["raw"]
	_open_soc = s["soc"]


func _adopt_open(idx: int) -> void:
	_open_idx = idx
	_arm_arrays_from(_mins[idx])


func _append_open(solar: float, aux: float, load: float, peak: float, raw: float, soc: float) -> void:
	_open_solar.append(solar)
	_open_aux.append(aux)
	_open_load.append(load)
	_open_peak.append(peak)
	_open_raw.append(raw)
	_open_soc.append(soc)


func _append_span(s: Dictionary, solar: float, aux: float, load: float, peak: float,
		raw: float, soc: float) -> void:
	var a: PackedFloat32Array = s["solar"]
	var b: PackedFloat32Array = s["aux"]
	var c: PackedFloat32Array = s["load"]
	var d: PackedFloat32Array = s["peak"]
	var e: PackedFloat32Array = s["raw"]
	var f: PackedFloat32Array = s["soc"]
	a.append(solar)
	b.append(aux)
	c.append(load)
	d.append(peak)
	e.append(raw)
	f.append(soc)
	s["solar"] = a
	s["aux"] = b
	s["load"] = c
	s["peak"] = d
	s["raw"] = e
	s["soc"] = f


func _flush_open() -> void:
	if _open_idx < 0 or _open_idx >= _mins.size():
		return
	var s: Dictionary = _mins[_open_idx]
	s["solar"] = _open_solar
	s["aux"] = _open_aux
	s["load"] = _open_load
	s["peak"] = _open_peak
	s["raw"] = _open_raw
	s["soc"] = _open_soc


func _close_open() -> void:
	_flush_open()
	_open_idx = -1
	_open_solar = PackedFloat32Array()
	_open_aux = PackedFloat32Array()
	_open_load = PackedFloat32Array()
	_open_peak = PackedFloat32Array()
	_open_raw = PackedFloat32Array()
	_open_soc = PackedFloat32Array()


func _minute_soc(g: int) -> float:
	if _open_idx >= 0 and _open_idx < _mins.size():
		var s: Dictionary = _mins[_open_idx]
		if g >= int(s["a"]) and g <= int(s["b"]):
			var i := g - int(s["a"])
			if i >= 0 and i < _open_soc.size():
				return _open_soc[i]
	var held := _span_holding(_mins, g)
	if held.is_empty():
		return 0.0
	var j := g - int(held["a"])
	var soc: PackedFloat32Array = held["soc"]
	return soc[j] if j >= 0 and j < soc.size() else 0.0


func _hour_soc(h: int) -> float:
	var held := _span_holding(_hours, h)
	if held.is_empty():
		return 0.0
	var j := h - int(held["a"])
	var soc: PackedFloat32Array = held["soc"]
	return soc[j] if j >= 0 and j < soc.size() else 0.0


func _nearest_minute(g: int) -> int:
	var best := -1
	var best_d := 0
	for s in _mins:
		var span: Dictionary = s
		var a := int(span["a"])
		var b := int(span["b"])
		var pick := g
		if g < a:
			pick = a
		elif g > b:
			pick = b
		var d := absi(pick - g)
		if best < 0 or d < best_d:
			best = pick
			best_d = d
	if _open_idx >= 0 and _open_idx < _mins.size():
		var o: Dictionary = _mins[_open_idx]
		var oa := int(o["a"])
		var ob := int(o["b"])
		var op := g
		if g < oa:
			op = oa
		elif g > ob:
			op = ob
		var od := absi(op - g)
		if best < 0 or od < best_d:
			best = op
	return best


func _nearest_hour(h: int) -> int:
	var best := -1
	var best_d := 0
	for s in _hours:
		var span: Dictionary = s
		var a := int(span["a"])
		var b := int(span["b"])
		var pick := h
		if h < a:
			pick = a
		elif h > b:
			pick = b
		var d := absi(pick - h)
		if best < 0 or d < best_d:
			best = pick
			best_d = d
	return best


# ---------------------------------------------------------------------------
# Span list
# ---------------------------------------------------------------------------

func _excise(list: Array, a: int, b: int) -> void:
	var i := 0
	while i < list.size():
		var s: Dictionary = list[i]
		var sa := int(s["a"])
		var sb := int(s["b"])
		if sb < a or sa > b:
			i += 1
			continue
		var keep_left := sa < a
		var keep_right := sb > b
		if keep_left and keep_right:
			var right := _subspan(s, b + 1, sb)
			_shrink_span(s, sa, a - 1)
			list.insert(i + 1, right)
			i += 2
		elif keep_left:
			_shrink_span(s, sa, a - 1)
			i += 1
		elif keep_right:
			list[i] = _subspan(s, b + 1, sb)
			i += 1
		else:
			list.remove_at(i)


func _cut_list(list: Array, keep_through: int) -> bool:
	var changed := false
	var i := 0
	while i < list.size():
		var s: Dictionary = list[i]
		var sa := int(s["a"])
		var sb := int(s["b"])
		if sa > keep_through:
			list.remove_at(i)
			changed = true
			continue
		if sb > keep_through:
			_shrink_span(s, sa, keep_through)
			changed = true
		i += 1
	return changed


func _insert_merged(list: Array, a: int, b: int, kind: int, solar: PackedFloat32Array,
		aux: PackedFloat32Array, load: PackedFloat32Array, peak: PackedFloat32Array,
		raw: PackedFloat32Array, soc: PackedFloat32Array) -> void:
	var idx := 0
	while idx < list.size() and int((list[idx] as Dictionary)["a"]) < a:
		idx += 1
	var span := {
		"a": a, "b": b, "kind": kind,
		"solar": solar, "aux": aux, "load": load, "peak": peak, "raw": raw, "soc": soc,
	}
	if idx > 0:
		var prev: Dictionary = list[idx - 1]
		if int(prev["kind"]) == kind and int(prev["b"]) + 1 == a:
			_concat_span(prev, solar, aux, load, peak, raw, soc)
			prev["b"] = b
			span = prev
			a = int(prev["a"])
			idx -= 1
		else:
			list.insert(idx, span)
	else:
		list.insert(idx, span)
	var nxt := idx + 1
	if nxt < list.size():
		var right: Dictionary = list[nxt]
		if int(right["kind"]) == kind and int(span["b"]) + 1 == int(right["a"]):
			var rs: PackedFloat32Array = right["solar"]
			var ra: PackedFloat32Array = right["aux"]
			var rl: PackedFloat32Array = right["load"]
			var rp: PackedFloat32Array = right["peak"]
			var rr: PackedFloat32Array = right["raw"]
			var rc: PackedFloat32Array = right["soc"]
			_concat_span(span, rs, ra, rl, rp, rr, rc)
			span["b"] = int(right["b"])
			list.remove_at(nxt)


func _concat_span(s: Dictionary, solar: PackedFloat32Array, aux: PackedFloat32Array,
		load: PackedFloat32Array, peak: PackedFloat32Array, raw: PackedFloat32Array,
		soc: PackedFloat32Array) -> void:
	var a: PackedFloat32Array = s["solar"]
	var b: PackedFloat32Array = s["aux"]
	var c: PackedFloat32Array = s["load"]
	var d: PackedFloat32Array = s["peak"]
	var e: PackedFloat32Array = s["raw"]
	var f: PackedFloat32Array = s["soc"]
	a.append_array(solar)
	b.append_array(aux)
	c.append_array(load)
	d.append_array(peak)
	e.append_array(raw)
	f.append_array(soc)
	s["solar"] = a
	s["aux"] = b
	s["load"] = c
	s["peak"] = d
	s["raw"] = e
	s["soc"] = f


func _insert_only(list: Array, span: Dictionary) -> int:
	var a := int(span["a"])
	var idx := 0
	while idx < list.size() and int((list[idx] as Dictionary)["a"]) < a:
		idx += 1
	list.insert(idx, span)
	return idx


func _one_span(g: int, kind: int, solar: float, aux: float, load: float, peak: float,
		raw: float, soc: float) -> Dictionary:
	return {
		"a": g, "b": g, "kind": kind,
		"solar": PackedFloat32Array([solar]),
		"aux": PackedFloat32Array([aux]),
		"load": PackedFloat32Array([load]),
		"peak": PackedFloat32Array([peak]),
		"raw": PackedFloat32Array([raw]),
		"soc": PackedFloat32Array([soc]),
	}


func _subspan(s: Dictionary, a: int, b: int) -> Dictionary:
	var off := a - int(s["a"])
	var n := b - a + 1
	return {
		"a": a, "b": b, "kind": int(s["kind"]),
		"solar": (s["solar"] as PackedFloat32Array).slice(off, off + n),
		"aux": (s["aux"] as PackedFloat32Array).slice(off, off + n),
		"load": (s["load"] as PackedFloat32Array).slice(off, off + n),
		"peak": (s["peak"] as PackedFloat32Array).slice(off, off + n),
		"raw": (s["raw"] as PackedFloat32Array).slice(off, off + n),
		"soc": (s["soc"] as PackedFloat32Array).slice(off, off + n),
	}


func _shrink_span(s: Dictionary, a: int, b: int) -> void:
	var off := a - int(s["a"])
	var n := b - a + 1
	s["a"] = a
	s["b"] = b
	s["solar"] = (s["solar"] as PackedFloat32Array).slice(off, off + n)
	s["aux"] = (s["aux"] as PackedFloat32Array).slice(off, off + n)
	s["load"] = (s["load"] as PackedFloat32Array).slice(off, off + n)
	s["peak"] = (s["peak"] as PackedFloat32Array).slice(off, off + n)
	s["raw"] = (s["raw"] as PackedFloat32Array).slice(off, off + n)
	s["soc"] = (s["soc"] as PackedFloat32Array).slice(off, off + n)


func _span_ending_at(list: Array, g: int, kind: int) -> int:
	for i in list.size():
		var s: Dictionary = list[i]
		if int(s["b"]) == g and int(s["kind"]) == kind:
			return i
	return -1


func _covered(list: Array, g: int) -> bool:
	return not _span_holding(list, g).is_empty()


func _span_holding(list: Array, g: int) -> Dictionary:
	for s in list:
		var span: Dictionary = s
		if g >= int(span["a"]) and g <= int(span["b"]):
			return span
	return {}


func _sample_dict(s: Dictionary, i: int) -> Dictionary:
	var solar: PackedFloat32Array = s["solar"]
	var aux: PackedFloat32Array = s["aux"]
	var load: PackedFloat32Array = s["load"]
	var peak: PackedFloat32Array = s["peak"]
	var raw: PackedFloat32Array = s["raw"]
	var soc: PackedFloat32Array = s["soc"]
	if i < 0 or i >= soc.size():
		return {}
	return {
		"soc_kwh": soc[i], "solar_kw": solar[i], "aux_kw": aux[i],
		"load_kw": load[i], "load_peak_kw": peak[i], "raw_kw": raw[i],
	}


func _any_minutes_in(g0: int, g1: int) -> bool:
	for s in _mins:
		var span: Dictionary = s
		if int(span["b"]) >= g0 and int(span["a"]) <= g1:
			return true
	return false


func _sample_count(list: Array) -> int:
	var n := 0
	for s in list:
		var span: Dictionary = s
		n += int(span["b"]) - int(span["a"]) + 1
	return n


func _evict(play_g: int) -> void:
	while _sample_count(_mins) > MAX_MINUTES and _mins.size() > 1:
		if not _drop_farthest(_mins, play_g):
			break
	while _sample_count(_hours) > MAX_HOURS and _hours.size() > 1:
		if not _drop_farthest(_hours, _hour_of(_time_of_minute(play_g))):
			break


func _drop_farthest(list: Array, near: int) -> bool:
	var worst := -1
	var worst_d := -1
	for i in list.size():
		if i == _open_idx and list == _mins:
			continue
		var s: Dictionary = list[i]
		var a := int(s["a"])
		var b := int(s["b"])
		if near >= a and near <= b:
			continue
		var mid := (a + b) / 2
		var d := absi(mid - near)
		if d > worst_d:
			worst_d = d
			worst = i
	if worst < 0:
		return false
	list.remove_at(worst)
	if list == _mins and _open_idx > worst:
		_open_idx -= 1
	elif list == _mins and _open_idx == worst:
		_open_idx = -1
	return true


func _accumulate(list: Array, minutes: bool, channel: String, w: float, i0: int, n: int,
		cap: float, mn: PackedFloat32Array, mx: PackedFloat32Array, sum: PackedFloat32Array,
		cnt: PackedInt32Array) -> void:
	var load := channel == "load_kw"
	for s in list:
		var span: Dictionary = s
		var a := int(span["a"])
		var b := int(span["b"])
		var solar: PackedFloat32Array = span["solar"]
		var aux: PackedFloat32Array = span["aux"]
		var ld: PackedFloat32Array = span["load"]
		var peak: PackedFloat32Array = span["peak"]
		var soc: PackedFloat32Array = span["soc"]
		for k in range(b - a + 1):
			var idx := a + k
			if not minutes and _any_minutes_in(idx * 60, idx * 60 + 59):
				continue
			var t := _time_of_minute(idx) if minutes else float(idx)
			var bin := int(floor(t / w)) - i0
			if bin < 0 or bin >= n:
				continue
			var v := _channel_of(channel, solar[k], aux[k], ld[k], soc[k], cap)
			var spike := v
			if load:
				spike = peak[k]
			if cnt[bin] == 0:
				mn[bin] = v
				mx[bin] = maxf(v, spike)
				sum[bin] = v
			else:
				mn[bin] = minf(mn[bin], v)
				mx[bin] = maxf(mx[bin], maxf(v, spike))
				sum[bin] += v
			cnt[bin] = cnt[bin] + 1


func _channel_of(channel: String, solar: float, aux: float, load: float, soc: float, cap: float) -> float:
	match channel:
		"solar_kw":
			return solar
		"load_kw":
			return load
		"aux_kw":
			return aux
		"soc_kwh":
			return soc
		"soc_pct":
			return 100.0 * soc / maxf(cap, 0.001)
		"net_kw":
			return solar + aux - load
	return 0.0


func _minute_of(abs_h: float) -> int:
	return int(floor(abs_h / MINUTE_H))


func _hour_of(abs_h: float) -> int:
	return int(floor(abs_h))


func _time_of_minute(g: int) -> float:
	return float(g) * MINUTE_H

class_name BeatTracker
extends RefCounted

## Live beat tracking of a REAL track (StageMusic plays a silent copy of each
## stage's track LOOKAHEAD seconds ahead of the one you hear, on its own
## analysis bus; every frame it feeds the bass magnitude here). Pure — the
## selftest feeds it a synthetic set.
##
## What it finds, all on the analysis track's own (monotonic) clock:
##   - KICKS: onsets of the bass band (a rise past 1.45 × its own 0.25 s
##     average and past 12 % of the loudest kick so far, re-armed when it
##     falls back), at least MIN_GAP_S apart.
##   - TEMPO: every 0.5 s, every pair of kicks in the last WINDOW_S votes for
##     the periods it could be (its interval ÷ 1..8, inside MIN_BPM..MAX_BPM,
##     weight 1/k) — the best 2 ms bin is only the COARSE tempo; a least-
##     squares line through the kicks' (beat index, time) gives the period
##     and the phase. A small change is eased in, a big one has to win three
##     times running (a fill is not a tempo change).
##   - PHASE: beat(t) = ref_beat + (t − ref_t) / period, the newest fitted
##     kick pulled half way onto a whole beat each estimate.
##     It keeps running through a breakdown with no kicks — the crowd does.
##   - BREAKDOWNS and DROPS: the bass's slow loudness against its own peak.
##     Under 0.35 for 1.5 s is a breakdown; the first strong kick after one
##     (at least 2 s of it) is the DROP, snapped to the nearest beat.
## Because the analysis runs ahead, a query at the HEARD time already knows a
## drop up to LOOKAHEAD seconds before it is heard — which is how the DJ gets
## an arm up in time.

const MIN_BPM := 85.0
const MAX_BPM := 180.0
const MIN_GAP_S := 0.22
const WINDOW_S := 10.0
const ESTIMATE_S := 0.5
const BIN_S := 0.002
const ONSET_RATIO := 1.45
const ONSET_FLOOR := 0.12
const REARM_RATIO := 1.15
const BREAK_LOUD := 0.35
const BREAK_HOLD_S := 1.5
const DROP_MIN_BREAK_S := 2.0
const DROP_KICK := 0.55
const KEEP_S := 40.0

var lookahead := 5.0

var period := 0.0
var _ref_t := 0.0
var _ref_beat := 0.0
var _pending_period := 0.0
var _pending_n := 0

var _t := -INF
var _t0 := INF
var _base := 0.0
var _slow := 0.0
var _kick_peak := 0.0
var _loud_peak := 0.0
var _armed := true
var _last_onset := -INF
var _onsets := PackedFloat64Array()
var _onset_mag := PackedFloat32Array()
var _est_at := -INF

var _breaking := false
var _quiet_since := INF
var _break_start := -INF
var _breaks: Array = []          # [start, end] (end INF while open)
var drops := PackedFloat64Array()

var _en_t := PackedFloat64Array()   # energy samples at ~10 Hz
var _en_v := PackedFloat32Array()


## One analysis frame: `t` seconds on the analysis clock (increasing), `bass`
## the bass band's magnitude.
func feed(t: float, bass: float) -> void:
	if not (t > _t):
		return
	var first := _t == -INF
	var dt := 0.0 if first else minf(t - _t, 0.25)
	_t = t
	if first:
		_t0 = t
		_base = bass
		_slow = bass
	var a_base := 1.0 - exp(-dt / 0.25)
	var a_slow := 1.0 - exp(-dt / 1.0)
	var prev_base := _base
	_base = lerpf(_base, bass, a_base)
	_slow = lerpf(_slow, bass, a_slow)
	_kick_peak = maxf(bass, _kick_peak * exp(-dt / 30.0))
	_loud_peak = maxf(_slow, _loud_peak * exp(-dt / 45.0))
	# Kicks.
	if _armed and bass > prev_base * ONSET_RATIO and bass > ONSET_FLOOR * _kick_peak \
			and t - _last_onset >= MIN_GAP_S:
		_armed = false
		_last_onset = t
		_onsets.append(t)
		_onset_mag.append(bass / maxf(_kick_peak, 1e-6))
		_on_kick(t, bass)
	elif not _armed and bass < _base * REARM_RATIO:
		_armed = true
	# Loudness, breakdowns.
	var loud := _slow / maxf(_loud_peak, 1e-6)
	if _en_t.is_empty() or t - _en_t[_en_t.size() - 1] >= 0.1:
		_en_t.append(t)
		_en_v.append(loud)
	if t - _t0 > 4.0 and _loud_peak > 1e-4:
		if not _breaking:
			if loud < BREAK_LOUD:
				if _quiet_since == INF:
					_quiet_since = t
				elif t - _quiet_since >= BREAK_HOLD_S:
					_breaking = true
					_break_start = _quiet_since
					_breaks.append([_break_start, INF])
			else:
				_quiet_since = INF
	if t - _est_at >= ESTIMATE_S:
		_est_at = t
		_estimate(t)
	_prune(t)


func _on_kick(t: float, bass: float) -> void:
	if _breaking and t - _break_start >= DROP_MIN_BREAK_S \
			and bass >= DROP_KICK * _kick_peak:
		_breaking = false
		_quiet_since = INF
		(_breaks[_breaks.size() - 1] as Array)[1] = t
		drops.append(_snap(t))
	elif _breaking and bass >= DROP_KICK * _kick_peak:
		# A strong kick inside a short dip: not a breakdown after all.
		_breaking = false
		_quiet_since = INF
		_breaks.pop_back()


func _snap(t: float) -> float:
	if period <= 0.0:
		return t
	var b := roundf(beat_at(t))
	return _ref_t + (b - _ref_beat) * period


func _estimate(t: float) -> void:
	var lo := 60.0 / MAX_BPM
	var hi := 60.0 / MIN_BPM
	var n_bins := int((hi - lo) / BIN_S) + 1
	var votes := PackedFloat32Array()
	votes.resize(n_bins)
	var recent: Array = []
	for o in _onsets:
		if t - o <= WINDOW_S:
			recent.append(o)
	if recent.size() < 6:
		return
	for i in recent.size():
		for j in range(i + 1, recent.size()):
			var d := float(recent[j]) - float(recent[i])
			if d > 3.0:
				break
			for k in range(1, 9):
				var p := d / float(k)
				if p < lo:
					break
				if p <= hi:
					var bi := int((p - lo) / BIN_S)
					votes[bi] += 1.0 / float(k)
	var best := -1
	var best_v := 0.0
	for bi in n_bins:
		var s := 0.0
		for q in range(maxi(bi - 2, 0), mini(bi + 3, n_bins)):
			s += votes[q]
		if s > best_v:
			best_v = s
			best = bi
	if best < 0:
		return
	# Refine by FITTING, not by the histogram: kick times are quantised to
	# the analysis frame (60 Hz — single intervals read 0.467 or 0.483 s for
	# a 0.476 s beat), so the best bin sits on one of the two. Chain each
	# kick's beat index from its neighbour (robust to a coarse p0), then a
	# least-squares line through (index, time): the slope is the period and
	# the line puts every kick on the grid at once — frame jitter averages
	# out.
	var p0 := lo + (float(best) + 0.5) * BIN_S
	if period > 0.0 and absf(p0 - period) / period < 0.06:
		p0 = period
	var ns := PackedFloat64Array()
	var ts := PackedFloat64Array()
	var n_idx := 0.0
	var last := float(recent[0])
	ns.append(0.0)
	ts.append(last)
	for i in range(1, recent.size()):
		var o := float(recent[i])
		var x := (o - last) / p0
		var r := roundf(x)
		if r < 1.0 or absf(x - r) > 0.3:
			continue   # an off-beat hit: not part of the grid
		n_idx += r
		last = o
		ns.append(n_idx)
		ts.append(o)
	if ns.size() < 6:
		return
	var sn := 0.0
	var st := 0.0
	var snn := 0.0
	var snt := 0.0
	for i in ns.size():
		sn += ns[i]
		st += ts[i]
		snn += ns[i] * ns[i]
		snt += ns[i] * ts[i]
	var cnt := float(ns.size())
	var den := cnt * snn - sn * sn
	if absf(den) < 1e-9:
		return
	var p_new := (cnt * snt - sn * st) / den
	var a := (st - p_new * sn) / cnt
	if p_new < lo * 0.95 or p_new > hi * 1.05:
		return
	# The newest kick's place on the fitted grid.
	var t_fit := a + p_new * n_idx
	if period <= 0.0:
		period = p_new
		_ref_t = t_fit
		_ref_beat = 0.0
		return
	var b_fit := beat_at(t_fit)
	if absf(p_new - period) / period < 0.06:
		period = lerpf(period, p_new, 0.5)
		_pending_n = 0
	else:
		if _pending_n > 0 and absf(p_new - _pending_period) / _pending_period < 0.04:
			_pending_n += 1
		else:
			_pending_period = p_new
			_pending_n = 1
		if _pending_n >= 3:
			period = p_new
			_pending_n = 0
	# Phase lock: the fitted kick is a whole beat — move half way there, keeping
	# the count (the beat number never jumps by more than the correction).
	_ref_t = t_fit
	_ref_beat = lerpf(b_fit, roundf(b_fit), 0.5)


func _prune(t: float) -> void:
	var cut := t - KEEP_S
	while not _onsets.is_empty() and _onsets[0] < cut:
		_onsets.remove_at(0)
		_onset_mag.remove_at(0)
	while not _en_t.is_empty() and _en_t[0] < cut:
		_en_t.remove_at(0)
		_en_v.remove_at(0)
	while not drops.is_empty() and drops[0] < cut:
		drops.remove_at(0)
	while not _breaks.is_empty() and float((_breaks[0] as Array)[1]) < cut:
		_breaks.pop_front()


func synced() -> bool:
	return period > 0.0


func bpm() -> float:
	return 60.0 / period if period > 0.0 else 0.0


func beat_at(t: float) -> float:
	if period <= 0.0:
		return -1.0
	return _ref_beat + (t - _ref_t) / period


## Everything about the music at `t` (the HEARD time — behind the analysis
## head by `lookahead`). Same keys as BeatGrid.state.
func query(t: float) -> Dictionary:
	var energy := 1.0
	if not _en_t.is_empty():
		var i := _en_t.bsearch(t)
		energy = clampf(_en_v[clampi(i - 1, 0, _en_v.size() - 1)], 0.0, 1.0)
	var since := INF
	var until := INF
	for d in drops:
		if d <= t:
			since = t - d
		elif until == INF:
			until = d - t
	var breakdown := false
	for br in _breaks:
		var s := float((br as Array)[0])
		var e := float((br as Array)[1])
		if t >= s and t < e:
			breakdown = true
	var build := 0.0
	if until < INF:
		build = clampf(1.0 - until / maxf(lookahead, 0.5), 0.0, 1.0)
	return {
		"bpm": bpm(), "beat": beat_at(t), "energy": energy, "breakdown": breakdown,
		"build": build, "drop_pulse": exp(-since / BeatGrid.DROP_DECAY_S) if since < INF else 0.0,
		"until_drop": until, "since_drop": since, "synced": synced(),
	}

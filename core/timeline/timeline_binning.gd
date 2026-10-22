class_name TimelineBinning
extends RefCounted
## Zoom-stable downsampling for the timeline's tracks (pure).
##
## Why: the old lanes cut a fixed number of bins between the window's edges and
## kept ONE number per bin (a peak, a mean, or a few point samples). Every zoom
## or pan moved the bin boundaries in time, so an hourly or minute signal was
## sampled at a different phase each frame, and a sawtooth averaged away into a
## smooth curve at some zoom levels and came back at others.
##
## Now (the audio-editor overview approach):
##   * the bin WIDTH comes from a fixed ladder of round durations (LADDER), the
##     smallest one that gives at most one bin per ~3 px;
##   * bins are ANCHORED to absolute time: bin k covers [k·w, (k+1)·w) whatever
##     the window, so panning never resamples and zooming only changes anything
##     when the ladder steps;
##   * each bin is EXACT over its interval — min, mean and max of everything in
##     it, nothing skipped — so a fast oscillation zoomed out draws as its
##     envelope (the band between min and max) around the mean, never as a
##     different curve.
##
## A result is {w, i0, n, mn, mean, mx} (three PackedFloat32Array of n, NAN
## where nothing is known); bin k starts at (i0 + k) · w absolute hours.

## Bin widths in hours: 1, 2, 5, 10, 15, 30 min, 1, 2, 3, 6, 12 h, 1, 2, 4 d,
## 1, 2, 4 weeks, 8, 16, 32 weeks, ~1 year.
const LADDER := [1.0 / 60.0, 2.0 / 60.0, 5.0 / 60.0, 10.0 / 60.0, 0.25, 0.5,
	1.0, 2.0, 3.0, 6.0, 12.0, 24.0, 48.0, 96.0, 168.0, 336.0, 672.0,
	1344.0, 2688.0, 5376.0, 8766.0]
## Target screen width of one bin.
const PX_PER_BIN := 3.0
## Most function evaluations inside one bin (weather over a week-wide bin).
const MAX_POINTS_PER_BIN := 24


## The ladder width for a window of `span_h` drawn `width_px` wide, never finer
## than `min_w` (a source's own sample spacing).
static func bin_width(span_h: float, width_px: float, min_w: float = 0.0) -> float:
	var want := maxf(span_h / maxf(width_px / PX_PER_BIN, 1.0), min_w)
	for w in LADDER:
		if float(w) >= want - 1e-9:
			return float(w)
	return float(LADDER[LADDER.size() - 1]) * ceil(want / float(LADDER[LADDER.size() - 1]))


## {i0, n}: the anchored bins that cover [t0, t1).
static func grid(t0: float, t1: float, w: float) -> Dictionary:
	var i0 := int(floor(t0 / w))
	var i1 := int(ceil(t1 / w))
	return {"i0": i0, "n": maxi(i1 - i0, 0)}


static func empty(w: float, i0: int, n: int) -> Dictionary:
	var mn := PackedFloat32Array()
	mn.resize(n)
	mn.fill(NAN)
	return {"w": w, "i0": i0, "n": n, "mn": mn, "mean": mn.duplicate(), "mx": mn.duplicate()}


## Regularly sampled values (the energy timeline, a CSV clip): sample j holds
## from base_t + j·step to the next sample. Every sample in a bin counts.
static func from_regular(values: PackedFloat32Array, base_t: float, step: float,
		w: float, i0: int, n: int) -> Dictionary:
	var out := empty(w, i0, n)
	var cnt := values.size()
	if cnt == 0 or step <= 0.0:
		return out
	var mn: PackedFloat32Array = out["mn"]
	var me: PackedFloat32Array = out["mean"]
	var mx: PackedFloat32Array = out["mx"]
	for b in n:
		var tb0 := float(i0 + b) * w
		var tb1 := tb0 + w
		# Samples whose own step overlaps the bin (a bin narrower than a step
		# gets the one sample that holds there).
		var j0 := int(floor((tb0 - base_t) / step + 1e-9))
		var j1 := int(ceil((tb1 - base_t) / step - 1e-9)) - 1
		j0 = maxi(j0, 0)
		j1 = mini(j1, cnt - 1)
		if j1 < j0:
			continue
		var lo := INF
		var hi := -INF
		var sum := 0.0
		var k := 0
		for j in range(j0, j1 + 1):
			var v := values[j]
			if is_nan(v):
				continue
			lo = minf(lo, v)
			hi = maxf(hi, v)
			sum += v
			k += 1
		if k > 0:
			mn[b] = lo
			mx[b] = hi
			me[b] = sum / float(k)
	return out


## A continuous signal read by `f` (Callable(t_abs) -> float, NAN = unknown)
## that is linear between points `native` hours apart (hourly weather). Each bin
## evaluates its own edges and every native point inside — at most
## MAX_POINTS_PER_BIN, on a sub-grid anchored to absolute time so the same bin
## always reads the same instants. Mean = trapezoid over those points.
static func from_function(f: Callable, native: float, w: float, i0: int, n: int) -> Dictionary:
	var out := empty(w, i0, n)
	if not f.is_valid() or n <= 0:
		return out
	var mn: PackedFloat32Array = out["mn"]
	var me: PackedFloat32Array = out["mean"]
	var mx: PackedFloat32Array = out["mx"]
	var memo := {}
	var step := native
	if w / native > float(MAX_POINTS_PER_BIN):
		step = w / float(MAX_POINTS_PER_BIN)
	for b in n:
		var tb0 := float(i0 + b) * w
		var tb1 := tb0 + w
		var ts: Array = [tb0]
		var t: float = ceilf(tb0 / step - 1e-9) * step
		if t <= tb0 + 1e-9:
			t += step
		while t < tb1 - 1e-9:
			ts.append(t)
			t += step
		ts.append(tb1)
		var lo := INF
		var hi := -INF
		var area := 0.0
		var dur := 0.0
		var prev_t := NAN
		var prev_v := NAN
		for tt in ts:
			var key := snappedf(float(tt), 1e-6)
			var v: float
			if memo.has(key):
				v = memo[key]
			else:
				v = float(f.call(float(tt)))
				memo[key] = v
			if not is_nan(v) and not is_inf(v):
				lo = minf(lo, v)
				hi = maxf(hi, v)
				if not is_nan(prev_v):
					area += (v + prev_v) * 0.5 * (float(tt) - prev_t)
					dur += float(tt) - prev_t
			prev_t = float(tt)
			prev_v = v if not is_inf(v) else NAN
		if lo != INF:
			mn[b] = lo
			mx[b] = hi
			me[b] = area / dur if dur > 0.0 else (lo + hi) * 0.5
	return out


## Irregular readings that HOLD until the next one (a Home Assistant sensor):
## sorted `times` (abs hours) and `values`. A reading holds for at most
## `max_gap` hours and nothing is known after `until` (NOW). Mean = time-
## weighted over the covered part of the bin; min / max include the value held
## into the bin from before it.
static func from_steps(times: PackedFloat64Array, values: PackedFloat32Array,
		w: float, i0: int, n: int, max_gap: float = 6.0, until: float = INF) -> Dictionary:
	var out := empty(w, i0, n)
	var cnt := times.size()
	if cnt == 0 or n <= 0:
		return out
	var mn: PackedFloat32Array = out["mn"]
	var me: PackedFloat32Array = out["mean"]
	var mx: PackedFloat32Array = out["mx"]
	var t_start := float(i0) * w
	var j := maxi(times.bsearch(t_start, true) - 1, 0)
	for b in n:
		var tb0 := float(i0 + b) * w
		var tb1 := minf(tb0 + w, until)
		if tb1 <= tb0:
			break
		while j + 1 < cnt and times[j + 1] <= tb0:
			j += 1
		var lo := INF
		var hi := -INF
		var area := 0.0
		var dur := 0.0
		var k := j
		while k < cnt and times[k] < tb1:
			var seg_a := maxf(times[k], tb0)
			var seg_end := times[k] + max_gap
			if k + 1 < cnt:
				seg_end = minf(seg_end, times[k + 1])
			var seg_b := minf(seg_end, tb1)
			if seg_b > seg_a or (times[k] >= tb0 and times[k] < tb1):
				var v := values[k]
				lo = minf(lo, v)
				hi = maxf(hi, v)
				if seg_b > seg_a:
					area += v * (seg_b - seg_a)
					dur += seg_b - seg_a
			k += 1
		if lo != INF:
			mn[b] = lo
			mx[b] = hi
			me[b] = area / dur if dur > 0.0 else values[mini(k - 1, cnt - 1)]
	return out


## The range of a result's finite bins: Vector2(min of mn, max of mx), or
## (NAN, NAN) when it holds nothing.
static func value_range(b: Dictionary) -> Vector2:
	var lo := INF
	var hi := -INF
	for v in b.get("mn", PackedFloat32Array()):
		if not is_nan(v):
			lo = minf(lo, v)
	for v in b.get("mx", PackedFloat32Array()):
		if not is_nan(v):
			hi = maxf(hi, v)
	if lo == INF:
		return Vector2(NAN, NAN)
	return Vector2(lo, hi)


## Apply `fn` (Callable(float) -> float) to every value (unit conversion).
static func mapped(b: Dictionary, fn: Callable) -> Dictionary:
	var out := b.duplicate()
	for key in ["mn", "mean", "mx"]:
		var src: PackedFloat32Array = b.get(key, PackedFloat32Array())
		var dst := PackedFloat32Array()
		dst.resize(src.size())
		for i in src.size():
			dst[i] = NAN if is_nan(src[i]) else float(fn.call(src[i]))
		out[key] = dst
	return out

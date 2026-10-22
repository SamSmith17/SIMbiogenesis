class_name StreamRunoff
extends RefCounted

## When rain reaches a stream — pure, so the network, the selftest and any
## future reader agree, and every value is a function of the clock (it scrubs
## backwards like everything else on the water network).
##
## The rational method (StreamHydraulics.runoff_m3s, Q = C·i·A) is a PEAK: it
## assumes rain has fallen for at least the time of concentration Tc — the
## time water takes to run from the far edge of the catchment to the point.
## Read as a hydrograph it is: Q(t) = C · A · (mean rain intensity over the
## last Tc), which rises over Tc after rain starts, holds at C·i·A while it
## lasts and recedes over Tc after it stops (the rational-method hydrograph,
## Chow, Maidment & Mays 1988 §15.1). A point near the head of a channel has a
## short Tc and fills first; one far downstream fills later — the front of a
## storm visibly runs down the channel.
##
## Tc per station from Kirpich (1940), metric form
##     Tc [min] = 0.0195 · L^0.77 · S^-0.385      (L m, S m/m)
## with L the LONGEST flow path to the station from Hack's law (1957),
##     L [mi] = 1.4 · A [mi²]^0.6,
## floored at the station's own distance down the drawn channel, and S the fall
## of the channel over that length.
##
## Storms the player makes with the Rain tool are events {start_h, end_h,
## rate_mmh} over a patch of ground; the area of that patch draining to each
## station comes from the drainage grid (weighted_accumulate). A patch's water
## enters a channel at one station and has to TRAVEL from there: at a station
## further down it arrives `lag` later: the channel's travel time between the
## two, Σ ds / v with v the Manning velocity of a storm flow at each station
## (channel_travel_h). A difference of Tc is NOT a travel time: Tc jumps where
## a side catchment joins, and the water skipped ahead leaving dry gaps behind
## it. It then rises over the patch's own Tc and
## spreads by STORM_SPREAD of the lag on the way (a translated, attenuated
## hydrograph; its volume is the storm's whatever the spread). Averaging the
## storm over the downstream point's whole Tc instead put a trickle of it at
## the far end of a 4 km wash within minutes — no front.

const TC_MIN_H := 3.0 / 60.0
const TC_MAX_H := 8.0
const MIN_SLOPE := 0.002
const MAX_SLOPE := 0.3
## Rain history resolution for the window means (h): 5 sim-minutes.
const HISTORY_STEP_H := 5.0 / 60.0
## How much a storm's hydrograph widens per hour it travels down a channel.
const STORM_SPREAD := 0.3
## Rain the ground takes before a storm runs off at all (mm): the delay.
const INITIAL_LOSS_MM := 3.0
## Reservoir constant K as a share of the patch's Tc: the tail.
const RESERVOIR_K_TC := 1.0
## Slope assumed for a storm patch's own overland Tc.
const PATCH_SLOPE := 0.02
const MI_M := 1609.344
const MI2_M2 := 2.589988e6


static func kirpich_tc_h(length_m: float, slope: float) -> float:
	var s := clampf(slope, MIN_SLOPE, MAX_SLOPE)
	var minutes := 0.0195 * pow(maxf(length_m, 1.0), 0.77) * pow(s, -0.385)
	return clampf(minutes / 60.0, TC_MIN_H, TC_MAX_H)


## Longest flow path (m) to a point draining `area_m2` (Hack 1957).
static func hack_length_m(area_m2: float) -> float:
	if area_m2 <= 0.0:
		return 0.0
	return 1.4 * pow(area_m2 / MI2_M2, 0.6) * MI_M


## Tc (h) at every profile station: `s` arc length down the drawn channel,
## `ground` the ground along it, `bed` the carved bed, `area` the catchment.
static func station_tc_h(s: PackedFloat32Array, ground: PackedFloat32Array,
		bed: PackedFloat32Array, area: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := s.size()
	out.resize(n)
	var head := ground[0] if ground.size() > 0 else 0.0
	for i in n:
		var a := area[i] if i < area.size() else 0.0
		var length := maxf(hack_length_m(a), s[i])
		var fall := head - (bed[i] if i < bed.size() else head)
		var slope := fall / maxf(s[i], 1.0) if s[i] > 50.0 else MIN_SLOPE * 5.0
		out[i] = kirpich_tc_h(length, slope)
	return out


## Rain history ending at `now_h`, `samples` steps of HISTORY_STEP_H back, as
## a prefix sum: prefix[k] = Σ rain over the k most recent steps (mm/h · step).
## `rain_at(abs_h) -> float`.
static func history_prefix(rain_at: Callable, now_h: float, samples: int) -> PackedFloat32Array:
	var prefix := PackedFloat32Array()
	prefix.resize(samples + 1)
	var acc := 0.0
	for k in samples:
		acc += maxf(float(rain_at.call(now_h - (float(k) + 0.5) * HISTORY_STEP_H)), 0.0)
		prefix[k + 1] = acc
	return prefix


## Mean rain intensity (mm/h) over the last `tc_h` from a history prefix.
static func window_mean(prefix: PackedFloat32Array, tc_h: float) -> float:
	var k_f := tc_h / HISTORY_STEP_H
	var n := prefix.size() - 1
	if n <= 0:
		return 0.0
	var k := clampi(int(floor(k_f)), 0, n)
	var frac := clampf(k_f - float(k), 0.0, 1.0)
	var sum := prefix[k]
	if k < n:
		sum += (prefix[k + 1] - prefix[k]) * frac
	return sum / maxf(minf(k_f, float(n)), 1e-6)


## Mean rain (mm/h) over [t - tc_h, t] where t is `offset_h` before the end
## of the history (offset 0 = window_mean).
static func window_mean_offset(prefix: PackedFloat32Array, offset_h: float, tc_h: float) -> float:
	var n := prefix.size() - 1
	if n <= 0 or tc_h <= 0.0:
		return 0.0
	var k0 := clampf(offset_h / HISTORY_STEP_H, 0.0, float(n))
	var k1 := clampf((offset_h + tc_h) / HISTORY_STEP_H, 0.0, float(n))
	if k1 - k0 < 1e-6:
		return 0.0
	return (_prefix_at(prefix, k1) - _prefix_at(prefix, k0)) / (k1 - k0)


static func _prefix_at(prefix: PackedFloat32Array, k: float) -> float:
	var i := int(floor(k))
	var n := prefix.size() - 1
	if i >= n:
		return prefix[n]
	return lerpf(prefix[i], prefix[i + 1], k - float(i))


## A storm's share of the window mean (mm/h) at `now_h` for a station of
## time of concentration `tc_h`.
static func storm_mean(start_h: float, end_h: float, rate_mmh: float, now_h: float, tc_h: float) -> float:
	var a := maxf(start_h, now_h - tc_h)
	var b := minf(end_h, now_h)
	if b <= a or tc_h <= 0.0:
		return 0.0
	return rate_mmh * (b - a) / tc_h


## Rain rate (mm/h) the channel velocities are taken at, and their bounds.
const TRAVEL_RAIN_MMH := 25.0
const TRAVEL_MIN_Q_LPS := 50.0
const TRAVEL_V_MIN := 0.25
const TRAVEL_V_MAX := 3.0


## Cumulative travel time (h) down a channel from its first station: sum of
## ds / v, v the Manning velocity of TRAVEL_RAIN_MMH's runoff from each
## station's catchment (at least TRAVEL_MIN_Q_LPS), bounded. Monotone and
## continuous.
static func channel_travel_h(s: PackedFloat32Array, bed: PackedFloat32Array,
		area: PackedFloat32Array, bed_w: float, bank_slope: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := s.size()
	out.resize(n)
	for i in range(1, n):
		var a := area[i] if i < area.size() else 0.0
		var q := maxf(StreamHydraulics.runoff_m3s(TRAVEL_RAIN_MMH, a) * 1000.0, TRAVEL_MIN_Q_LPS)
		var slope := ChannelProfile._slope(s, bed, i)
		var v := clampf(float(StreamHydraulics.state(q, bed_w, bank_slope, slope)["velocity_ms"]),
			TRAVEL_V_MIN, TRAVEL_V_MAX)
		out[i] = out[i - 1] + (s[i] - s[i - 1]) / v / 3600.0
	return out


## Time of concentration (h) of a storm patch of `area_m2` on its own.
static func patch_tc_h(area_m2: float) -> float:
	return kirpich_tc_h(maxf(hack_length_m(area_m2), 10.0), PATCH_SLOPE)


## A storm's share of the rain feeding a station (mm/h equivalent) at
## `now_h`, for water that reaches the station `lag_h` after it falls.
##
## The pulse a storm sends down a channel is NOT its rain hyetograph:
##   * nothing runs off until the ground has taken its first INITIAL_LOSS_MM
##     (the initial abstraction of the SCS curve-number method, NRCS NEH 630
##     ch. 10) — a short DELAY, longer for gentle rain than for a cloudburst;
##   * the runoff then passes through a linear reservoir (storage S = K·Q,
##     Zoch 1934; the Clark unit hydrograph's routing step), so the flow rises
##     smoothly over K and drains on an exponential TAIL of the same K after the
##     rain stops. K is the patch's own Tc (Clark's storage constant is of the
##     order of Tc) plus STORM_SPREAD of the travel time, so a pulse arriving
##     from far up the channel is lower and longer. Volume is what ran off.
static func storm_arrival_mean(start_h: float, end_h: float, rate_mmh: float, now_h: float,
		lag_h: float, patch_tc_h_: float) -> float:
	if rate_mmh <= 0.0:
		return 0.0
	var eff_start := start_h + INITIAL_LOSS_MM / rate_mmh
	if eff_start >= end_h:
		return 0.0
	var k := RESERVOIR_K_TC * patch_tc_h_ + STORM_SPREAD * maxf(lag_h, 0.0)
	return reservoir_response(eff_start + lag_h, end_h + lag_h, rate_mmh, now_h, k)


## Outflow (same units as `rate`) of a linear reservoir of constant `k_h` fed
## `rate` from `a` to `b`: rate·(1 − e^(−(t−a)/k)) while it fills, then the
## level reached decaying as e^(−(t−b)/k).
static func reservoir_response(a: float, b: float, rate: float, t: float, k_h: float) -> float:
	if t <= a:
		return 0.0
	var k := maxf(k_h, 1e-4)
	if t <= b:
		return rate * (1.0 - exp(-(t - a) / k))
	return rate * (1.0 - exp(-(b - a) / k)) * exp(-(t - b) / k)


## Upstream sum of `weights` per cell (cells' own weight included), in the
## drainage grid's reversed pop order — FlowRouting.accumulate with weights.
static func weighted_accumulate(recv: PackedInt32Array, order: PackedInt32Array,
		weights: PackedFloat32Array) -> PackedFloat32Array:
	var acc := weights.duplicate()
	for k in range(order.size() - 1, -1, -1):
		var i := order[k]
		var t := recv[i]
		if t >= 0 and acc[i] != 0.0:
			acc[t] += acc[i]
	return acc


## Position of every cell in the drainage grid's pop order (order[rank[i]] == i).
static func order_rank(order: PackedInt32Array) -> PackedInt32Array:
	var rank := PackedInt32Array()
	rank.resize(order.size())
	for k in order.size():
		rank[order[k]] = k
	return rank


## weighted_accumulate with weight 1.0 on `sources` and 0 elsewhere — but only
## over the cells downstream of a source, upstream first (rank descending).
## Every other cell's sum is 0 either way and the additions into each cell
## happen in the same order, so the result is the dense one bit for bit; a
## storm patch touches a few thousand cells of a 400 000-cell grid.
static func sparse_accumulate(recv: PackedInt32Array, rank: PackedInt32Array,
		sources: PackedInt32Array) -> PackedFloat32Array:
	var acc := PackedFloat32Array()
	acc.resize(recv.size())
	var seen := {}
	var keys := PackedInt64Array()
	for c in sources:
		acc[c] = 1.0
		var i := c
		while i >= 0 and not seen.has(i):
			seen[i] = true
			keys.append(int(rank[i]) * 16777216 + i)
			i = recv[i]
	keys.sort()
	for k in range(keys.size() - 1, -1, -1):
		var i := int(keys[k] % 16777216)
		var t := recv[i]
		if t >= 0 and acc[i] != 0.0:
			acc[t] += acc[i]
	return acc

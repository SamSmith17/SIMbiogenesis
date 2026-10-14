class_name ChannelProfile
extends RefCounted

## The long profile of one channel — the bed elevation along its arc — pure.
##
## The DEM rarely contains the channel: a 5–47 m grid smears a 5 m stream into
## the valley side, and a mapped river often runs over a bump the DEM put in
## its way. Water cannot flow uphill, so the carved bed is the smoothed ground
## minus the channel depth, then a RUNNING MINIMUM downstream (with a tiny
## minimum grade, the Priority-Flood "+ε" idea of Barnes et al. 2014 applied in
## 1-D): every carved bed is non-increasing, so simulated water can actually
## run through it. Where honouring that would cut more than `max_cut_m` into
## the ground the bed is held at the cap instead and the station is flagged
## `blocked` — the editor paints those red and suggests a culvert.

## Station spacing along the arc (m). Matches the edit-tile cell (1.5 m) to
## within a factor of two, so the carve sees every bend.
const STEP_M := 2.0
## Boxcar smoothing radius (m) of the ground profile before the bed is taken —
## same order as TerrainRoadFlatten.PROFILE_SMOOTH_RADIUS_M (12 m): long enough
## to ride over DEM speckle, short enough to keep real knickpoints.
const SMOOTH_RADIUS_M := 12.0
## Minimum bed grade (m/m) — StreamHydraulics.MIN_SLOPE.
const MIN_GRADE := 0.0005
const DEFAULT_MAX_CUT_M := 8.0


## Resample a polyline at ~`step` metres. Returns {points, s} (arc length).
static func resample(line: PackedVector2Array, step: float = STEP_M) -> Dictionary:
	var pts := PackedVector2Array()
	var s := PackedFloat32Array()
	if line.size() < 2:
		return {"points": line, "s": PackedFloat32Array([0.0]) if line.size() == 1 else s}
	var acc := 0.0
	pts.append(line[0])
	s.append(0.0)
	for i in range(line.size() - 1):
		var a := line[i]
		var b := line[i + 1]
		var seg := a.distance_to(b)
		if seg < 1e-6:
			continue
		var n := maxi(int(ceil(seg / maxf(step, 0.1))), 1)
		for k in range(1, n + 1):
			var t := float(k) / float(n)
			pts.append(a.lerp(b, t))
			s.append(acc + seg * t)
		acc += seg
	return {"points": pts, "s": s}


## Compute the bed profile. `ground_fn(x, z) -> float` is the BASE ground (no
## channel layer). `floor_y` is the lowest the END of this channel may sit —
## the bed of whatever it drains into at the junction (NAN = none); the whole
## bed is held at or above it so a tributary never digs a pit at a confluence.
## Returns {points, s, ground, bed, blocked: PackedByteArray, length_m}.
static func compute(line: PackedVector2Array, ground_fn: Callable, depth_m: float,
		max_cut_m: float = DEFAULT_MAX_CUT_M, floor_y: float = NAN,
		step: float = STEP_M, smooth_radius_m: float = SMOOTH_RADIUS_M,
		bank_offset_m: float = 0.0) -> Dictionary:
	var rs := resample(line, step)
	var pts: PackedVector2Array = rs["points"]
	var s: PackedFloat32Array = rs["s"]
	var n := pts.size()
	var ground := PackedFloat32Array()
	ground.resize(n)
	# `low` = the lowest of the centreline and both banks (`bank_offset_m` to
	# either side). A mapped stream often runs along a valley SIDE the DEM
	# smeared, so the downhill bank sits lower than the centreline: clamping
	# the bed under the centreline alone left water spilling over that bank.
	var low := PackedFloat32Array()
	low.resize(n)
	for i in n:
		ground[i] = float(ground_fn.call(pts[i].x, pts[i].y))
		low[i] = ground[i]
		if bank_offset_m > 0.0:
			var a := pts[maxi(i - 1, 0)]
			var b := pts[mini(i + 1, n - 1)]
			var t := (b - a).normalized() if a.distance_squared_to(b) > 1e-9 else Vector2(1, 0)
			var off := Vector2(-t.y, t.x) * bank_offset_m
			low[i] = minf(low[i], minf(
				float(ground_fn.call(pts[i].x + off.x, pts[i].y + off.y)),
				float(ground_fn.call(pts[i].x - off.x, pts[i].y - off.y))))
	var sm := smooth(ground, s, smooth_radius_m)
	var bed := PackedFloat32Array()
	bed.resize(n)
	var blocked := PackedByteArray()
	blocked.resize(n)
	var prev := INF
	for i in n:
		# Never above the local ground less half a depth: smoothing can lift
		# the profile over a dip, and a bed above the ground carves nothing.
		var want := minf(sm[i] - depth_m, low[i] - 0.5 * depth_m)
		if i > 0:
			var ds := maxf(s[i] - s[i - 1], 0.0)
			want = minf(want, prev - MIN_GRADE * ds)
		var cap := ground[i] - maxf(max_cut_m, depth_m)
		if want < cap:
			want = cap
			blocked[i] = 1
		bed[i] = want
		prev = want
	if is_finite(floor_y):
		# Hold the bed up to the junction's bed so a tributary does not dig a
		# pit at the confluence — but NEVER above its own ground less half a
		# depth (a bed above the ground carves nothing and floats the water).
		# Where the two disagree the station is flagged: water ponds there.
		for i in n:
			var lifted := maxf(bed[i], minf(floor_y, low[i] - 0.5 * depth_m))
			if lifted > bed[i] + 1e-4 and floor_y > low[i] - 0.5 * depth_m:
				blocked[i] = 1
			bed[i] = lifted
	return {"points": pts, "s": s, "ground": ground, "bed": bed, "blocked": blocked,
		"length_m": s[n - 1] if n > 0 else 0.0}


## Boxcar mean of `v` over ±radius metres of arc (s ascending). O(n) with a
## sliding window.
static func smooth(v: PackedFloat32Array, s: PackedFloat32Array, radius: float) -> PackedFloat32Array:
	var n := v.size()
	var out := PackedFloat32Array()
	out.resize(n)
	if n == 0:
		return out
	var lo := 0
	var hi := 0
	var sum := 0.0
	for i in n:
		while hi < n and s[hi] <= s[i] + radius:
			sum += v[hi]
			hi += 1
		while lo < n and s[lo] < s[i] - radius:
			sum -= v[lo]
			lo += 1
		out[i] = sum / float(maxi(hi - lo, 1))
	return out


## True when bed[] never rises downstream (tolerance in metres).
static func is_monotone(bed: PackedFloat32Array, tol: float = 1e-4) -> bool:
	for i in range(1, bed.size()):
		if bed[i] > bed[i - 1] + tol:
			return false
	return true


## Bed elevation + local downstream slope at arc length `at_s` (clamped).
static func bed_at(profile: Dictionary, at_s: float) -> Vector2:
	var s: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = profile.get("bed", PackedFloat32Array())
	var n := s.size()
	if n == 0:
		return Vector2(NAN, 0.0)
	if n == 1 or at_s <= s[0]:
		return Vector2(bed[0], _slope(s, bed, 0))
	if at_s >= s[n - 1]:
		return Vector2(bed[n - 1], _slope(s, bed, n - 2))
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if s[mid] <= at_s:
			lo = mid
		else:
			hi = mid
	var t := (at_s - s[lo]) / maxf(s[hi] - s[lo], 1e-6)
	return Vector2(lerpf(bed[lo], bed[hi], t), _slope(s, bed, lo))


## Index of the station nearest arc length `at_s` (binary search).
static func station_index(profile: Dictionary, at_s: float) -> int:
	var s: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	var n := s.size()
	if n == 0:
		return 0
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if s[mid] <= at_s:
			lo = mid
		else:
			hi = mid
	return lo if absf(at_s - s[lo]) <= absf(s[hi] - at_s) else hi


## Downstream bed slope (positive = falling) around station i, averaged over
## ~20 m so one flat station does not stall the flow.
static func _slope(s: PackedFloat32Array, bed: PackedFloat32Array, i: int) -> float:
	var n := s.size()
	if n < 2:
		return StreamHydraulics.MIN_SLOPE
	var a := clampi(i - 5, 0, n - 1)
	var b := clampi(i + 5, 0, n - 1)
	if b == a:
		b = mini(a + 1, n - 1)
		a = maxi(b - 1, 0)
	var ds := s[b] - s[a]
	if ds <= 1e-6:
		return StreamHydraulics.MIN_SLOPE
	return maxf((bed[a] - bed[b]) / ds, StreamHydraulics.MIN_SLOPE)

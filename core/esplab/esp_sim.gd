class_name EspSim
extends RefCounted

## The board's simulated twin, as a PURE FUNCTION OF TIME (the ExtremeWeather
## / fire rule): what an entity reads at absolute hour t is what the real part
## would have published at its last update tick before t. Nothing is
## integrated, so it scrubs backwards, replays and needs no state.
##
## Per reading, in the order a real board does it:
##   1. the tick: every `update_s`, phased per unit (a hash), like a board
##      that booted at a random moment;
##   2. the physical value at that instant, from a `source(src, at_h)`
##      Callable (EspWorldProbe in the game, a function in the selftest);
##      NAN = nothing to read -> the entity is unavailable;
##   3. response lag: a first-order filter over the previous ticks
##      (weights exp(-j·dt/tau)), still pure;
##   4. the part's error: a fixed per-unit bias inside its datasheet accuracy
##      (BIAS_SHARE of ±(acc + acc_pct·|x|), so most units are within half
##      of the worst case), per-tick Gaussian noise, the range limits, the
##      resolution;
##   5. back to the raw signal the chip sees (the part's own default filters
##      inverted: a soil probe's volts, a flow meter's pulses / min), then
##      EVERY filter in the YAML in order (the part's, then the player's) —
##      exactly what ESPHome computes — then rounded to accuracy_decimals.
##
## Every random number is a hash of (unit, tick): the same unit at the same
## instant always reads the same.
##
## IDEAL readings (`ideal` true): no per-unit bias and no noise — the world
## value through the same resolution, range, lag and filters. That is what
## the comparison holds the real board against (the twin's bias is a random
## stand-in for an unknown real error, so comparing with it means nothing).
##
## CALIBRATION filters (a filter dict with `cal: true`) are written into the
## YAML for the real board and skipped here: they correct THAT unit's error,
## which the twin does not have.

const BIAS_SHARE := 0.5
const MAX_LAG_TICKS := 8


## The tick (index and hour) a reading at abs_h comes from.
static func tick_of(ent: Dictionary, unit: String, abs_h: float) -> Dictionary:
	var upd := maxf(1.0, float(ent.get("update_s", 60.0)))
	var phase := NpcHash.unit01(unit, "phase") * upd
	var s := abs_h * 3600.0 - phase
	var k := int(floor(s / upd))
	return {"k": k, "t": (float(k) * upd + phase) / 3600.0, "dt_h": upd / 3600.0}


## A unit's key: the board's node + the instance + the entity.
static func unit_key(node: String, ent: Dictionary) -> String:
	return "%s|%s|%s" % [node, str(ent.get("iid", "")), str(ent.get("k", ""))]


## The reading at abs_h: {value (float / bool / NAN), t (the tick's hour),
## available}.
static func reading(ent: Dictionary, unit: String, abs_h: float, source: Callable, ideal: bool = false) -> Dictionary:
	var tk := tick_of(ent, unit, abs_h)
	var v: Variant = value_at_tick(ent, unit, int(tk["k"]), source, ideal)
	var avail := not (v is float and is_nan(float(v)))
	return {"value": v, "t": float(tk["t"]), "available": avail}


static func value_at_tick(ent: Dictionary, unit: String, k: int, source: Callable, ideal: bool = false) -> Variant:
	var kind := str(ent.get("kind", "sensor"))
	var upd := maxf(1.0, float(ent.get("update_s", 60.0)))
	var phase := NpcHash.unit01(unit, "phase") * upd
	var t := (float(k) * upd + phase) / 3600.0
	var src := str(ent.get("src", ""))
	if src.begins_with("diag."):
		return _diag(src, unit, t, k, source)
	var x := _src(source, src, t)
	if kind != "sensor":
		if is_nan(x):
			return NAN
		return x if kind == "number" else x >= 0.5
	if is_nan(x):
		return NAN
	var sim: Dictionary = ent.get("sim", {})
	# 3. Response lag.
	var tau := float(sim.get("tau", 0.0))
	if tau > 0.0:
		var n := clampi(int(ceil(3.0 * tau / upd)), 1, MAX_LAG_TICKS)
		var acc := 0.0
		var wsum := 0.0
		for j in n:
			var xj := x if j == 0 else _src(source, src, t - float(j) * upd / 3600.0)
			if is_nan(xj):
				break
			var w := exp(-float(j) * upd / tau)
			acc += w * xj
			wsum += w
		if wsum > 0.0:
			x = acc / wsum
	# 4. The part's error.
	x = with_error(sim, unit, k, x, ideal)
	# 5. Raw signal, then every filter (calibration filters are the real
	# unit's, not the twin's).
	var all_f: Array = ent.get("filters", [])
	var part_n := int(ent.get("part_filters", 0))
	var raw := invert_filters(all_f.slice(0, part_n), x)
	var y := apply_filters(all_f, raw, ent, unit, k, source, ideal)
	if is_nan(y):
		return NAN
	var dec := int(ent.get("dec", 2))
	return snappedf(y, pow(10.0, -dec)) if dec >= 0 else y


## The part's error on a physical value.
static func with_error(sim: Dictionary, unit: String, k: int, x: float, ideal: bool = false) -> float:
	if not ideal:
		var acc := float(sim.get("acc", 0.0)) + float(sim.get("acc_pct", 0.0)) * 0.01 * absf(x)
		x += (NpcHash.unit01(unit, "bias") * 2.0 - 1.0) * acc * BIAS_SHARE
		var sd := float(sim.get("noise", 0.0))
		if sd > 0.0:
			x += sd * gauss(unit, k)
	if sim.has("lo"):
		x = maxf(x, float(sim["lo"]))
	if sim.has("hi"):
		x = minf(x, float(sim["hi"]))
	var res := float(sim.get("res", 0.0))
	if res > 0.0:
		x = roundf(x / res) * res
	return x


## A standard normal number from (unit, tick): Box-Muller on two hashes.
static func gauss(unit: String, k: int) -> float:
	var u1 := maxf(1e-9, NpcHash.unit01("%s#%d" % [unit, k], "n1"))
	var u2 := NpcHash.unit01("%s#%d" % [unit, k], "n2")
	return sqrt(-2.0 * log(u1)) * cos(TAU * u2)


# ------------------------------------------------------------------ filters

## ESPHome's calibrate_linear: the least-squares line through the points.
static func linear_fit(points: Array) -> Vector2:
	var n := float(points.size())
	if n < 2.0:
		return Vector2(1.0, 0.0)
	var sx := 0.0
	var sy := 0.0
	var sxx := 0.0
	var sxy := 0.0
	for p in points:
		var px := float(p[0])
		var py := float(p[1])
		sx += px
		sy += py
		sxx += px * px
		sxy += px * py
	var den := n * sxx - sx * sx
	if absf(den) < 1e-12:
		return Vector2(1.0, 0.0)
	var a := (n * sxy - sx * sy) / den
	return Vector2(a, (sy - a * sx) / n)


## The raw signal that the given filters turn into x (each step inverted, in
## reverse; clamps and averages pass through).
static func invert_filters(filters: Array, x: float) -> float:
	var y := x
	for i in range(filters.size() - 1, -1, -1):
		var f: Dictionary = filters[i]
		if f.has("offset"):
			y -= float(f["offset"])
		elif f.has("multiply"):
			var m := float(f["multiply"])
			y = y / m if absf(m) > 1e-12 else y
		elif f.has("calibrate_linear"):
			var ab := linear_fit(f["calibrate_linear"])
			y = (y - ab.y) / ab.x if absf(ab.x) > 1e-12 else y
	return y


## Every filter on a raw value, as ESPHome runs them. A moving average is the
## mean of this entity's previous published-stage values.
static func apply_filters(filters: Array, raw: float, ent: Dictionary = {}, unit: String = "",
		k: int = 0, source: Callable = Callable(), ideal: bool = false) -> float:
	var y := raw
	for i in filters.size():
		var f: Dictionary = filters[i]
		if bool(f.get("cal", false)):
			continue
		if f.has("offset"):
			y += float(f["offset"])
		elif f.has("multiply"):
			y *= float(f["multiply"])
		elif f.has("calibrate_linear"):
			var ab := linear_fit(f["calibrate_linear"])
			y = ab.x * y + ab.y
		elif f.has("clamp"):
			var c: Array = f["clamp"]
			y = clampf(y, float(c[0]), float(c[1]))
		elif f.has("sliding_window_moving_average") and source.is_valid():
			var w := int((f["sliding_window_moving_average"] as Dictionary).get("window_size", 5))
			var sum := y
			var n := 1
			var before := filters.slice(0, i)
			for j in range(1, maxi(w, 1)):
				var e2 := ent.duplicate()
				e2["filters"] = before
				e2["dec"] = -1
				var v: Variant = value_at_tick(e2, unit, k - j, source, ideal)
				if v is float and not is_nan(float(v)):
					sum += float(v)
					n += 1
			y = sum / float(n)
	return y


# ------------------------------------------------------------------ sources

static func _src(source: Callable, src: String, t: float) -> float:
	if not source.is_valid() or src == "":
		return NAN
	var v: Variant = source.call(src, t)
	if v is bool:
		return 1.0 if v else 0.0
	if v is int or v is float:
		return float(v)
	return NAN


static func _diag(src: String, unit: String, t: float, k: int, source: Callable) -> Variant:
	match src:
		"diag.uptime":
			var boot := _src(source, "diag.boot_h", t)
			return floorf(maxf(0.0, (t - (boot if not is_nan(boot) else t)) * 3600.0))
		"diag.wifi_signal":
			var base := _src(source, "diag.rssi", t)
			return roundf((base if not is_nan(base) else -60.0) + 2.0 * gauss(unit, k))
		"diag.status":
			return true
	return NAN


# ------------------------------------------------------------------ history

## What Home Assistant would record between t0 and t1: [[t, value]] at every
## tick whose published state differs from the last one (the recorder writes
## a state only when it changes). At most `max_points` ticks are evaluated
## (longer spans are thinned evenly; the first and last are kept).
static func series(ent: Dictionary, unit: String, t0: float, t1: float, source: Callable,
		max_points: int = 4000, ideal: bool = false) -> Array:
	var out: Array = []
	if t1 <= t0:
		return out
	var a := tick_of(ent, unit, t0)
	var b := tick_of(ent, unit, t1)
	var k0 := int(a["k"])
	var k1 := int(b["k"])
	var n := k1 - k0 + 1
	var stride := maxi(1, int(ceil(float(n) / float(maxi(max_points, 2)))))
	var last: Variant = null
	var upd := maxf(1.0, float(ent.get("update_s", 60.0)))
	var phase := NpcHash.unit01(unit, "phase") * upd
	var k := k0
	while k <= k1:
		var v: Variant = value_at_tick(ent, unit, k, source, ideal)
		var t := (float(k) * upd + phase) / 3600.0
		var same: bool = last != null and typeof(last) == typeof(v) and (last == v or (v is float and is_nan(float(v)) and is_nan(float(last))))
		if not same:
			out.append([t, v])
			last = v
		if k == k1:
			break
		k = mini(k + stride, k1)
	return out


## A reading as text, the way Home Assistant shows it ("21.3 °C", "on",
## "unavailable").
static func format(ent: Dictionary, r: Dictionary) -> String:
	if not bool(r.get("available", false)):
		return "unavailable"
	var v: Variant = r["value"]
	if v is bool:
		var kind := str(ent.get("kind", ""))
		if kind == "binary_sensor":
			match str(ent.get("dc", "")):
				"motion":
					return "detected" if v else "clear"
				"moisture":
					return "wet" if v else "dry"
				"connectivity":
					return "connected" if v else "disconnected"
		return "on" if v else "off"
	var dec := maxi(0, int(ent.get("dec", 1)))
	var s := String.num(float(v), dec)
	if dec > 0 and s.find(".") < 0:
		s += "." + "0".repeat(dec)
	var u := str(ent.get("unit", ""))
	return s + ((" " + u) if u != "" else "")

class_name BreakerTrip
extends RefCounted
## In-line AC breakers and fuses that trip (plans/SCADA_PROCESS_PLAN.md,
## Phase 3b). A breaker is an `acbreaker` item between a supply and its loads;
## GraphAcLoad already stops AC at one whose `closed` is false. This is the
## rule that opens it:
##
##   amps = watts through it ÷ its volts
##   over its rating for TRIP_DELAY_S of sim time  → trips
##   at INSTANT_X × its rating or more             → trips at once
##
## A real thermal-magnetic breaker follows an inverse-time curve (UL 489: it
## must hold 100 %, trip within an hour at 135 % and within minutes at 200 %,
## and its magnetic element trips in a cycle at ~5–10 ×). The two numbers
## here are a game-speed simplification of that curve, not the curve.
##
## A tripped breaker stays open until someone resets it (`reset`); a blown
## fuse (`fuse: true`) is replaced the same way.
##
## Pure and autoload-free.

const TYPE := "acbreaker"
const TRIP_DELAY_S := 20.0
const INSTANT_X := 2.0
const DEFAULT_VOLTS := 120.0


static func is_breaker(item: Dictionary) -> bool:
	return str(item.get("type", "")) == TYPE


static func rating_a(specs: Dictionary) -> float:
	return maxf(float(specs.get("rating_a", specs.get("max_amps", 20.0))), 0.1)


static func volts(specs: Dictionary) -> float:
	return maxf(float(specs.get("volts", DEFAULT_VOLTS)), 1.0)


static func is_closed(specs: Dictionary) -> bool:
	return bool(specs.get("closed", specs.get("on", true)))


static func amps(specs: Dictionary, watts: float) -> float:
	return maxf(watts, 0.0) / volts(specs)


## One look at a breaker carrying average `watts` at sim hour `now_h`.
## `peak_watts` < 0 means the average is also the peak (the old callers).
## The thermal element follows the average. The magnetic element trips this
## step when the coincident peak reaches INSTANT_X times the rating, even
## while the average is still under it. Returns the spec keys to write
## ({} = nothing changed): `live_amps`, `over_since_h` (-1 = not over), and
## on a trip `closed: false`, `tripped: true`, `trip_amps`.
static func step(specs: Dictionary, watts: float, now_h: float, peak_watts: float = -1.0) -> Dictionary:
	var out := {}
	if not is_closed(specs):
		if absf(float(specs.get("live_amps", 0.0))) > 0.001:
			out["live_amps"] = 0.0
		if float(specs.get("over_since_h", -1.0)) >= 0.0:
			out["over_since_h"] = -1.0
		return out
	var a := amps(specs, watts)
	var peak_a := a if peak_watts < 0.0 else amps(specs, peak_watts)
	var shown := maxf(a, peak_a)
	var rate := rating_a(specs)
	if absf(float(specs.get("live_amps", 0.0)) - shown) > 0.05:
		out["live_amps"] = snappedf(shown, 0.01)
	if peak_a >= rate * INSTANT_X:
		out["closed"] = false
		out["tripped"] = true
		out["trip_amps"] = snappedf(peak_a, 0.1)
		out["live_amps"] = 0.0
		out["over_since_h"] = -1.0
		return out
	var since := float(specs.get("over_since_h", -1.0))
	if a <= rate:
		if since >= 0.0:
			out["over_since_h"] = -1.0
		return out
	# Over on the average. A scrub back before the overload began starts the count again.
	if since < 0.0 or now_h < since:
		since = now_h
		out["over_since_h"] = now_h
	if a >= rate * INSTANT_X or (now_h - since) * 3600.0 >= TRIP_DELAY_S:
		out["closed"] = false
		out["tripped"] = true
		out["trip_amps"] = snappedf(a, 0.1)
		out["live_amps"] = 0.0
		out["over_since_h"] = -1.0
	return out


## The keys that close it again.
static func reset() -> Dictionary:
	return {"closed": true, "tripped": false, "over_since_h": -1.0, "trip_amps": 0.0}


static func make_specs(name: String, rate_a: float, fuse: bool = false, cost: float = 0.0) -> Dictionary:
	return {"name": name, "rating_a": rate_a, "volts": DEFAULT_VOLTS, "closed": true, "tripped": false,
		"fuse": fuse, "cost": cost}


## "Closed · 8.2 of 15 A" / "TRIPPED at 31 A" / "Open" / "Blown at 14 A".
static func state_words(specs: Dictionary) -> String:
	if bool(specs.get("tripped", false)):
		return "%s at %s A" % ["Blown" if bool(specs.get("fuse", false)) else "Tripped", UiText.num(float(specs.get("trip_amps", 0.0)), "", 2)]
	if not is_closed(specs):
		return "Open"
	return "%s of %s A" % [UiText.num(float(specs.get("live_amps", 0.0)), "", 2), UiText.num(rating_a(specs), "", 2)]

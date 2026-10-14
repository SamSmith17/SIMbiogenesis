class_name NpcPeak
extends RefCounted

## PEAK EXPERIENCE — "FUCK YES!" — the rules, pure static.
##
## A person can tip into a peak state when three things line up:
##   * they are VIBING: doing something social (a venue, a chat circle, a
##     shade or fireside hang, the DJ's set) — not asleep, not on a need,
##     not hiding in their tent;
##   * their needs are MET: no critical need past its threshold, nothing
##     blocked, and morale already Pretty Good or better (ELIGIBLE_MORALE);
##   * there is a social CRITICAL MASS: enough other vibing people right
##     around them (`mass`, over the 3x3 block of CELL_M cells).
## Then the onset rate — per hour — grows with the mass, with every peaker
## already in the neighbourhood (CONTAGION: this is what makes it visibly
## ripple through a crowd; the player scales it, `contagion`), and with the
## venue's moment (a live set, a set's closer, the burn coming down).
##
## The rate fills a CHARGE: each person integrates it (`charge += rate x dt`)
## toward their own threshold, drawn once per episode from Exp(1) by hash
## (`threshold`). That is exactly a Poisson onset with the same hazard — the
## statistics are unchanged — but "how close is this person to FUCK YES" is now
## a number, `buzz = charge / threshold`, which the body glow and the overhead
## readout show, and a peaker nearby is SEEN feeding it (the charge climbs
## faster). Charge leaks away (`CHARGE_LEAK_H`) while the rate is zero — out
## of the crowd, off to the toilet — so it is a state of the evening, not a
## savings account. Deterministic and dt-exact at any clock speed.
##
## A peak HOLDS while the person keeps vibing with needs met and a few people
## about (HOLD_MASS), for at least MIN_HOLD_H, and lifts their morale toward
## PEAK_MORALE (past the enrichment ceiling) while it lasts. Consumption is
## never touched.
##
## The whole field is run by PeakField (owned by the population bridge), the
## same for both tiers.

const LABEL := "FUCK YES!!!"
## The peak state's colour (the green the body glows).
const COLOR := Color(0.45, 1.0, 0.55)
## Neighbourhood: the 3x3 block of CELL_M cells around a person (~18 m across).
const CELL_M := 6.0
const ELIGIBLE_MORALE := 0.72
## Critical mass: no chance below MASS_MIN other vibing neighbours, full at
## MASS_FULL. A whole camp hanging out together can just get there; a stage
## crowd or the burn ring gets there readily; a chat of four never does.
const MASS_MIN := 5.0
const MASS_FULL := 20.0
## Onsets per hour at full mass with nobody peaking nearby. Rare on purpose:
## the FIRST person in a crowd to tip over is the spark; contagion does the
## rest.
const BASE_RATE_H := 0.12
## Each peaker in the neighbourhood (up to CONTAGION_CAP) adds this share —
## one doubles the odds, five make them six times: the spread you can watch.
## The player's multiplier (PopTestPrefs.peak_contagion) scales it: 0 = no
## spread at all (every peak is its own spark), 3 = wildfire.
const CONTAGION := 1.0
const CONTAGION_MULT_MAX := 4.0
const CONTAGION_CAP := 8
## Still peaking while at least this many others vibe nearby.
const HOLD_MASS := 2
const MIN_HOLD_H := 0.05
## A peak survives this long without the hold conditions — someone walking
## back to the same stage between visits, or stepping out of the crush for a
## minute, rides the high instead of switching off mid-stride.
const GRACE_H := 0.1
## While peaking, morale is pulled toward PEAK_MORALE at LIFT_PER_H.
const PEAK_MORALE := 0.95
const LIFT_PER_H := 0.4
## Venue moments multiply the onset rate.
const BOOST_LIVE_SET := 1.5
const BOOST_SET_PEAK := 2.5
const BOOST_BURN := 3.0


## Charge leaks away with this time constant (sim hours) while nothing is
## filling it.
const CHARGE_LEAK_H := 0.4
## A threshold is Exp(1), clamped so nobody pops on the spot or never can.
const THRESHOLD_MIN := 0.001
const THRESHOLD_MAX := 5.0


## 0..1 critical mass from the number of OTHER vibing people nearby.
static func mass(n_others: int) -> float:
	return smoothstep(MASS_MIN, MASS_FULL, float(n_others))


## Onsets per hour.
## `contagion_mult` is the player's spread multiplier (1 = as shipped).
static func rate_h(n_others: int, peakers: int, boost: float = 1.0, contagion_mult: float = 1.0) -> float:
	var p := mini(maxi(peakers, 0), CONTAGION_CAP)
	return BASE_RATE_H * mass(n_others) * (1.0 + CONTAGION * maxf(contagion_mult, 0.0) * float(p)) \
		* maxf(boost, 0.0)


## This person's threshold for episode `episode` (their n-th peak): Exp(1)
## by hash — which is what makes a charge model a Poisson onset.
static func threshold(agent_id: String, episode: int) -> float:
	var u := NpcHash.unit01(agent_id, "pkt%d" % episode)
	return clampf(-log(maxf(1.0 - u, 1e-9)), THRESHOLD_MIN, THRESHOLD_MAX)


## Charge after `dt_h` at `rate` per hour (leaking while the rate is zero).
static func charge_step(charge: float, rate: float, dt_h: float) -> float:
	if rate > 0.0:
		return charge + rate * maxf(dt_h, 0.0)
	return charge * exp(-maxf(dt_h, 0.0) / CHARGE_LEAK_H)


## Chance of an onset within dt hours at `rate` per hour.
static func onset_chance(rate: float, dt_h: float) -> float:
	return 1.0 - exp(-maxf(rate, 0.0) * maxf(dt_h, 0.0))


## Does this person tip over in this tick? (id, tick-second) hashed draw.
static func onset(agent_id: String, abs_h: float, rate: float, dt_h: float) -> bool:
	var u := NpcHash.unit01(agent_id, "pk%d" % int(floor(abs_h * 3600.0)))
	return u < onset_chance(rate, dt_h)


## Is a peak that began at `since_h` still holding?
static func holds(vibing: bool, n_others: int, since_h: float, abs_h: float) -> bool:
	if abs_h - since_h < MIN_HOLD_H:
		return true
	return vibing and n_others >= HOLD_MASS


## Morale after `dt_h` of peaking.
static func lift(morale: float, dt_h: float) -> float:
	if morale >= PEAK_MORALE:
		return morale
	return minf(morale + LIFT_PER_H * maxf(dt_h, 0.0), PEAK_MORALE)


## Every critical need under its threshold and nothing blocked.
static func needs_met(needs: Dictionary, blocked: Dictionary) -> bool:
	for n in NpcAgent.CRITICAL_NEEDS:
		if float(needs.get(n, 0.0)) >= float(NpcAgent.THRESHOLD.get(n, 1.0)):
			return false
	for k in blocked:
		if bool(blocked[k]):
			return false
	return true


## The crowd renderer's instance COLOR.a ("mood"):
##   not peaking: BUZZ_STEPS-quantised buzz in the integer part + morale x
##                MORALE_SCALE in the fraction  (0 .. < 32);
##   peaking:     PEAK_ALPHA_BASE + the sim hour the peak began relative to
##                the renderer's time_base, clamped at PEAK_REL_MIN so a peak
##                older than a rebase still reads as one  (62 .. 89).
## crowd_figure / crowd_card unpack it with the SAME numbers: `a >= 48` is a
## peak, `since = a - 64`; else `buzz = floor(a) / 31`, `morale = fract(a) /
## 0.999`. Float32 keeps ~1e-5 h at 89 — a peak's start to a tenth of a second.
const PEAK_ALPHA_BASE := 64.0
const PEAK_ALPHA_MIN := 48.0
const PEAK_REL_MIN := -2.0
const PEAK_REL_MAX := 25.0
const BUZZ_STEPS := 31
const MORALE_SCALE := 0.999

static func pack_mood(morale: float, peak_rel: float, buzz: float = 0.0) -> float:
	if is_nan(peak_rel):
		return float(buzz_q(buzz)) + clampf(morale, 0.0, 1.0) * MORALE_SCALE
	return PEAK_ALPHA_BASE + clampf(peak_rel, PEAK_REL_MIN, PEAK_REL_MAX)


## The inverse: {morale (0..1, 1 while peaking), peak_rel (NAN = not), buzz}.
static func unpack_mood(a: float) -> Dictionary:
	if a >= PEAK_ALPHA_MIN:
		return {"morale": 1.0, "peak_rel": a - PEAK_ALPHA_BASE, "buzz": 1.0}
	var q := floorf(a)
	return {"morale": clampf((a - q) / MORALE_SCALE, 0.0, 1.0), "peak_rel": NAN,
		"buzz": q / float(BUZZ_STEPS)}


## Buzz quantised to the steps the renderer carries (a change of step is
## what re-writes a crowd slot).
static func buzz_q(buzz: float) -> int:
	return clampi(int(round(clampf(buzz, 0.0, 1.0) * float(BUZZ_STEPS))), 0, BUZZ_STEPS)


## A venue's onset boost from its live state (NpcVenueState.resolve).
static func venue_boost(stype: String, st: Dictionary) -> float:
	if stype == "effigy":
		var ph := int(st.get("phase", -1))
		if bool(st.get("cheer", false)) or ph == VenueCrowd.EffigyPhase.CIRCLING:
			return BOOST_BURN
		return 1.0
	if stype == "stage" and bool(st.get("active", false)) and bool(st.get("programmed", false)):
		return BOOST_SET_PEAK if bool(st.get("peak", false)) else BOOST_LIVE_SET
	return 1.0

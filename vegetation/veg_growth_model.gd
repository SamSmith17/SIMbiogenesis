class_name VegGrowthModel
extends RefCounted

## Plant growth as a PURE FUNCTION of the calendar.
##
## A plant is four numbers — the growth-year it was born, its maturity age, its
## (individually jittered) lifespan, and a 0..1 seed — and everything it looks
## like on a given date follows from them:
##
##     elapsed = growth_year(date) − born
##     generation 0 lives  [0, lifespan)                 from a seedling
##     generation n ≥ 1    emerges over gap(seed) years, then lives on from a
##                         released-sapling age (REGEN_HEAD_START) to lifespan
##
## Nothing integrates, nothing mutates a record and nothing ticks, so growth
## scrubs backwards, survives a reload and costs no per-frame CPU. It replaces a
## forward-only "growth clock" + kill-and-reseed pass whose mature-stamped trees
## all sat exactly on their death age and were swapped for seedlings in one
## frame.
##
## vegetation/veg_growth.gdshaderinc is a LINE-FOR-LINE MIRROR of state() — the
## shader draws what this file computes. Edit both; the selftest pins this side.
## Leaf class: numbers only, no records, no settings (VegetationGrowth is the
## record/settings facade), so it has no dependencies beyond SeasonModel.

## INSTANCE_CUSTOM carries (born − BASE_YEAR): float32 has ~4 minutes of
## resolution a few hundred years either side of it.
const BASE_YEAR := 2000.0
const YEAR_LEN := 365.25

## Height: Chapman-Richards, H(x) = (1 − e^(−k·x))^p with x = age / maturity
## (Richards 1959, J. Exp. Bot. 10; Pienaar & Turnbull 1973, For. Sci. 19),
## normalised so it reaches exactly 1.0 AT maturity — a painted tree must be
## the previewed size, not 92 % of it. k/p give the usual sigmoid: slow
## establishment, fast pole stage, tapering toward the asymptote.
const CR_K := 3.0
const CR_P := 1.6
## Apparent size of a first-year seedling (a 30 m tree starts ~0.9 m).
const SEED_HEIGHT := 0.03
## Crown width and stem girth LAG height (a young tree is a slender whip), as
## powers of the height fraction. Diameter keeps increasing after height growth
## stops, so girth creeps on to OLD_GIRTH through the plateau.
const CROWN_EXP := 1.35
const GIRTH_EXP := 1.6
const OLD_GIRTH := 1.2
## Last fraction of the lifespan spent declining: foliage thins to a bare snag
## over the first LEAF_LOSS_FRAC of it, and the snag comes down over the last
## COLLAPSE_FRAC. Kept short so a stationary stand carries only a few percent
## of standing dead.
const DECLINE_FRAC := 0.04
const LEAF_LOSS_FRAC := 0.6
const COLLAPSE_FRAC := 0.15
## REGENERATION. A canopy gap is not bare ground waiting for a seed: the
## replacement is advance regeneration — a suppressed sapling already standing
## in the understory, released when the old tree comes down (gap-phase
## dynamics; Oliver & Larson 1996, Forest Stand Dynamics, ch. 5). So a later
## generation does not start from a seedling and the spot never stands empty:
## over `gap` years (GAP_MIN + GAP_SPAN·seed) the sapling rises from nothing to
## its released size, then grows on from age REGEN_HEAD_START × maturity.
## Generation 0 — a plant the player set out young — still starts as a seedling.
## 0.15 of the maturity age is a pole about a quarter of full height — the
## upper end of what stands suppressed under a closed canopy.
## (The first version left the spot EMPTY for 2–8 years and restarted every
## generation from a 3 % seedling: ~3 % of a generated forest was missing and
## ~8 % visibly small at any date.)
const GAP_MIN_Y := 2.0
const GAP_SPAN_Y := 2.0
const REGEN_HEAD_START := 0.15
## A lifespan is never allowed inside this multiple of the maturity age — the
## old system's bug was exactly lifespan == maturity.
const MIN_LIFE_MATURITY_RATIO := 1.25
## Individual lifespan = species lifespan × (MIN + SPAN·u).
const LIFESPAN_JITTER_MIN := 0.7
const LIFESPAN_JITTER_SPAN := 0.6
## The year's growth is laid down between leaf-out and late July (NH day of
## year); outside it the growth year stands still.
const FLUSH_START_DOY := 84.0
const FLUSH_END_DOY := 212.0


## Calendar date → continuous GROWTH year (e.g. 2026.31). Whole years tick over
## with the calendar, but the fraction follows the growing season: flat through
## winter, climbing through the spring flush. Damped toward plain linear time by
## latitude (the tropics grow all year), and shifted half a year in the southern
## hemisphere so its flush lands in ITS spring without a jump at New Year.
static func growth_year(year: int, day_of_year: float, latitude: float) -> float:
	var s := float(year) + clampf((day_of_year - 1.0) / YEAR_LEN, 0.0, 0.999999)
	var south := latitude < 0.0
	if south:
		s += 0.5
	var y0 := floorf(s)
	var lin := s - y0
	var flush := smoothstep(FLUSH_START_DOY, FLUSH_END_DOY, lin * YEAR_LEN)
	var t := y0 + lerpf(lin, flush, SeasonModel.seasonality_strength(latitude))
	if south:
		t -= 0.5
	return t


static func gap_years(seed01: float) -> float:
	return GAP_MIN_Y + GAP_SPAN_Y * clampf(seed01, 0.0, 1.0)


## Lifespan actually used: never inside the maturity guard.
static func effective_lifespan(maturity: float, lifespan: float) -> float:
	return maxf(lifespan, maturity * MIN_LIFE_MATURITY_RATIO)


## Length of every generation AFTER the first: the emergence gap plus the life
## left once the released sapling's head start is taken off.
static func cycle_years(maturity: float, lifespan: float, seed01: float) -> float:
	return gap_years(seed01) + effective_lifespan(maturity, lifespan) \
		- REGEN_HEAD_START * maturity


## Height fraction for x = age / maturity. Exactly 1.0 from maturity on.
static func height_curve(x: float) -> float:
	if x >= 1.0:
		return 1.0
	var cr := pow(1.0 - exp(-CR_K * maxf(x, 0.0)), CR_P) / pow(1.0 - exp(-CR_K), CR_P)
	return lerpf(SEED_HEIGHT, 1.0, cr)


## Everything a plant looks like at growth-year `t`.
##   height / crown / girth  scale factors (all exactly 1.0 at maturity)
##   leaf        1 = full foliage, 0 = bare snag
##   present     0 only at the instant between generations (height 0)
##   generation  which individual this is (0 = the one that was planted)
##   age         its age in years
## `maturity <= 0` is the IDENTITY (growth off — also what a plain mesh with no
## instance data reads). `lifespan <= 0` grows and holds forever (shrubs, grass).
## Before `born` the plant is a seedling, never a previous generation.
static func state(t: float, born: float, maturity: float, lifespan: float,
		seed01: float) -> Dictionary:
	if maturity <= 0.0:
		return {"height": 1.0, "crown": 1.0, "girth": 1.0, "leaf": 1.0,
			"present": 1.0, "generation": 0, "age": 0.0}
	var elapsed := maxf(t - born, 0.0)
	var gen := 0.0
	var age := elapsed
	var life := 0.0
	# 0..1 while a later generation's sapling is still rising out of the gap.
	var emerge := 1.0
	if lifespan > 0.0:
		life = effective_lifespan(maturity, lifespan)
		if elapsed >= life:
			var a0 := REGEN_HEAD_START * maturity
			var gap := gap_years(seed01)
			var cycle := gap + life - a0
			var e2 := elapsed - life
			var k := floorf(e2 / cycle)
			var r := e2 - k * cycle
			gen = 1.0 + k
			if r < gap:
				age = a0
				emerge = smoothstep(0.0, 1.0, r / gap)
			else:
				age = a0 + (r - gap)
	var h := height_curve(age / maturity)
	var crown := pow(h, CROWN_EXP) * emerge
	var girth := pow(h, GIRTH_EXP) * emerge
	h *= emerge
	var leaf := 1.0
	var present := 1.0 if h > 0.0 else 0.0
	if life > 0.0:
		var d0 := life * (1.0 - DECLINE_FRAC)
		if age > maturity:
			girth = lerpf(1.0, OLD_GIRTH, smoothstep(maturity, d0, age))
		if age > d0:
			var u := minf((age - d0) / (life - d0), 1.0)
			leaf = 1.0 - smoothstep(0.0, LEAF_LOSS_FRAC, u)
			var stand := 1.0 - smoothstep(1.0 - COLLAPSE_FRAC, 1.0, u)
			h *= stand
			crown *= stand
			girth *= stand
			if h <= 0.0:
				present = 0.0
	return {"height": h, "crown": crown, "girth": girth, "leaf": leaf,
		"present": present, "generation": int(gen), "age": age}


# ---- deterministic per-plant numbers -------------------------------------

## Stable 0..1 seed for a plant. Avalanched (Godot's String.hash is nearly
## sequential over similar strings — the NpcHash lesson), quantised to the
## centimetre so float noise in a saved position cannot re-roll a tree.
static func seed01(species: String, x: float, z: float) -> float:
	var h := hash("%s|%d|%d" % [species, roundi(x * 100.0), roundi(z * 100.0)])
	h = (h ^ (h >> 16)) * 0x45d9f3b
	h = (h ^ (h >> 16)) * 0x45d9f3b
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / float(0x1000000)


## Independent-enough 0..1 streams off the one seed (lifespan jitter, plateau
## position, cycle phase). Linear, so CPU and shader never need to agree on a
## chaotic hash.
static func sub_seed(seed: float, stream: int) -> float:
	return fposmod(seed * (5.71 + 3.66 * float(stream)) + 0.31 * float(stream + 1), 1.0)


static func jittered_lifespan(maturity: float, lifespan: float, seed: float) -> float:
	if lifespan <= 0.0:
		return 0.0
	return effective_lifespan(maturity,
		lifespan * (LIFESPAN_JITTER_MIN + LIFESPAN_JITTER_SPAN * sub_seed(seed, 0)))


## Birth year of a plant that should stand FULL SIZE at `t_now`: placed at a
## seed-chosen point of its full-size plateau (maturity … onset of decline), so
## a grove painted in one stroke dies decades-to-centuries apart, never at once.
## `lifespan_i` is the already-jittered lifespan; 0 = grow-and-hold.
static func established_born(t_now: float, maturity: float, lifespan_i: float,
		seed: float) -> float:
	if maturity <= 0.0:
		return t_now
	if lifespan_i <= 0.0:
		return t_now - maturity
	var d0 := effective_lifespan(maturity, lifespan_i) * (1.0 - DECLINE_FRAC)
	return t_now - (maturity + sub_seed(seed, 1) * maxf(d0 - maturity, 0.0))


const PROFILE_MATURE := "mature"
const PROFILE_MIXED := "mixed"
const PROFILE_YOUNG := "young"
## How far back a stationary stand's births are pushed so no date a player can
## reach precedes them (the clamp before `born` would show a field of seedlings).
const STATIONARY_PAST_Y := 2500.0


## Birth year for a plant with no stored birth (the generated forest).
##   mature  a STATIONARY uneven-aged stand: phase uniform over the whole life
##           cycle, so at any date most trees are full size, a few percent are
##           young, a few are declining — and it looks the same in 300 years.
##   mixed   ages uniform over the growth span at the site epoch.
##   young   a plantation: everything in its first 15 % at the site epoch.
static func derived_born(profile: String, epoch_y: float, maturity: float,
		lifespan_i: float, seed: float) -> float:
	if maturity <= 0.0:
		return epoch_y
	var u := sub_seed(seed, 2)
	match profile:
		PROFILE_YOUNG:
			return epoch_y - u * 0.15 * maturity
		PROFILE_MIXED:
			return epoch_y - u * maturity
	if lifespan_i <= 0.0:
		return epoch_y - maturity
	# Uniform phase over the REPEATING cycle (generations ≥ 1), which starts one
	# first-generation lifespan after birth.
	var cycle := cycle_years(maturity, lifespan_i, seed)
	return BASE_YEAR - effective_lifespan(maturity, lifespan_i) \
		- (u + ceilf(STATIONARY_PAST_Y / cycle)) * cycle

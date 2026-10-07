class_name VenueCrowd
extends RefCounted

## Where a crowd STANDS at a venue, and how — pure geometry over a person's
## slot index, shared by both population tiers so the full agents and the
## light cohort arrange themselves identically.
##
## Two venues have real choreography:
##
## THE EFFIGY (space type "effigy", tagged on the burn structure). Its phases
## are a pure function of the prop's FireTimeline record:
##   IDLE      no fire (or out / cold): people gather round it as they would
##             an art piece — a loose spiral at a respectful distance.
##   BURNING   lit, before the collapse: everyone comes. Concentric RINGS
##             round the structure from a safe radius outward, the front row
##             sitting or lying, the next sitting, the rest standing, the
##             rings spaced further apart and the people in them looser the
##             further out they are — a crowd that thins with distance.
##   CIRCLING  from the collapse for CIRCLE_H (45 min): everybody up and
##             moving COUNTER-CLOCKWISE round the fire in lanes, about half
##             of them dancing, the rest walking.
##   AFTER     the pile burns down: back to the loose spiral, socialising.
##
## THE STAGE. While a set is on, the crowd packs a FAN in front of the
## speakers — a half-disc anchored at the stage's front edge, densest at the
## front — and dances hard ("rave"). Off-set it is an ordinary venue.
##
## Orientation: Godot world XZ with north = −Z and east = +X. "Counter-
## clockwise seen from above" is the rotation that carries east toward north,
## i.e. `(cos a, −sin a)` with `a` increasing.

const GOLDEN_ANGLE := 2.399963229728653

# --- effigy ------------------------------------------------------------------
## The crowd's SAFE PERIMETER follows the structure: while it stands, its
## height plus ten feet (the fall radius); once it has collapsed, five feet
## off the edge of the pile — nobody ever stands IN the fire. A record that
## does not know its size (older saves) falls back to EFFIGY_SAFE_R_M.
const PERIMETER_STANDING_M := 3.048     # 10 ft beyond the height
const PERIMETER_PILE_M := 1.524         # 5 ft off the pile's edge
const EFFIGY_SAFE_R_M := 14.0
const DEFAULT_HEIGHT_M := EFFIGY_SAFE_R_M - PERIMETER_STANDING_M
const DEFAULT_FOOTPRINT_R_M := EFFIGY_SAFE_R_M - PERIMETER_PILE_M
## Per-person scatter inside a slot: nobody stands exactly on a lattice.
const SEAT_JITTER_M := 0.45
## Ring-to-ring gap, and how much each further ring adds to it.
const EFFIGY_ROW_GAP_M := 1.8
const EFFIGY_ROW_GAP_GROWTH_M := 0.5
## Along-ring spacing in the front row, and how much looser each ring is.
const EFFIGY_SEAT_M := 1.15
const EFFIGY_SEAT_GROWTH_M := 0.30
const EFFIGY_MAX_ROWS := 60
## The circle dance: 45 min from the collapse, one lap in six minutes
## (~0.4 m/s on a 24 m ring — a slow dance-walk), four lanes.
const CIRCLE_H := 0.75
const CIRCLE_LAP_H := 0.1
const CIRCLE_LANES := 4
const CIRCLE_LANE_M := 2.4
const CIRCLE_INNER_M := 3.0
## Outer lanes drift a little slower, so the lanes shear past each other.
const CIRCLE_LANE_SLOW := 0.08
## The idle / after spiral starts at this share of the safe radius.
const EFFIGY_GATHER_R := 0.8
const EFFIGY_GATHER_SEAT_M := 1.0
## Share of the front row lying rather than sitting; of the circle dancing.
const FRONT_ROW_LIE_SHARE := 0.4
const CIRCLE_DANCE_SHARE := 0.55

enum EffigyPhase { IDLE, BURNING, CIRCLING, AFTER }
const EFFIGY_PHASE_NAMES: Array = ["idle", "burning", "circling", "after"]

# --- stage -------------------------------------------------------------------
## The fan starts this far in front of the stage's front edge, and spans
## STAGE_FAN_SPAN either side of straight ahead — nobody stands level with
## the speakers, let alone behind them.
const STAGE_FAN_GAP_M := 4.0
const STAGE_SEAT_M := 1.0
const STAGE_FAN_SPAN := 2.2689280276   # 130 degrees

## Pose hints the venues emit (read by the pose machine and the cohort).
const POSE_STAND := "stand"
const POSE_SIT := "sit"
const POSE_LIE := "lie"
const POSE_DANCE := "dance"
const POSE_RAVE := "rave"
const POSE_WALK := "walk"
const POSE_CLAP := "clap"


# ---------------------------------------------------------------------------
# Effigy phases
# ---------------------------------------------------------------------------

## The safe radius for a phase, from the record's structure size.
static func safe_radius(fire_rec: Dictionary, phase: int) -> float:
	var h := float(fire_rec.get("height_m", -1.0))
	var fr := float(fire_rec.get("footprint_r_m", -1.0))
	if h <= 0.0:
		h = DEFAULT_HEIGHT_M
	if fr <= 0.0:
		fr = DEFAULT_FOOTPRINT_R_M
	match phase:
		EffigyPhase.BURNING:
			return maxf(h, fr) + PERIMETER_STANDING_M
		EffigyPhase.CIRCLING, EffigyPhase.AFTER:
			return fr + PERIMETER_PILE_M
	return fr + PERIMETER_STANDING_M


## {phase: EffigyPhase, name, ends_in_h (hours until the phase changes; -1 =
## open-ended), circle_t0 (abs hours the circling began; NAN otherwise),
## safe_r (the perimeter for that phase)}.
static func effigy_phase(fire_rec: Dictionary, t: float) -> Dictionary:
	var out := {"phase": EffigyPhase.IDLE, "name": "idle", "ends_in_h": -1.0, "circle_t0": NAN,
		"safe_r": safe_radius(fire_rec, EffigyPhase.IDLE)}
	if fire_rec.is_empty() or not FireTimeline.is_record(fire_rec):
		out["safe_r"] = EFFIGY_SAFE_R_M
		return out
	var st := FireTimeline.state_at(fire_rec, t)
	match int(st.get("phase", FireTimeline.Phase.NONE)):
		FireTimeline.Phase.BURNING, FireTimeline.Phase.COLLAPSING:
			out["phase"] = EffigyPhase.BURNING
			out["name"] = "burning"
			out["safe_r"] = safe_radius(fire_rec, EffigyPhase.BURNING)
			# Hours of burn left before the pile lands (a hold stretches it;
			# the caller re-reads the phase every step anyway).
			var left := FireTimeline.climb_h(fire_rec) + FireTimeline.COLLAPSE_H - float(st.get("burn_h", 0.0))
			out["ends_in_h"] = maxf(left, 1.0 / 60.0)
		FireTimeline.Phase.PILE:
			var age := float(st.get("age_h", 0.0))
			if age < CIRCLE_H:
				out["phase"] = EffigyPhase.CIRCLING
				out["name"] = "circling"
				out["ends_in_h"] = maxf(CIRCLE_H - age, 1.0 / 60.0)
				out["circle_t0"] = t - age
				out["safe_r"] = safe_radius(fire_rec, EffigyPhase.CIRCLING)
			else:
				out["phase"] = EffigyPhase.AFTER
				out["name"] = "after"
				out["safe_r"] = safe_radius(fire_rec, EffigyPhase.AFTER)
		_:
			pass
	return out


# ---------------------------------------------------------------------------
# Effigy slots
# ---------------------------------------------------------------------------

## Which ring a slot index lands in: {row, j (index within the row), n (the
## row's size), r (its radius), seat (its along-ring spacing)}. Rows are
## filled front to back; each ring holds as many people as its circumference
## allows at that ring's spacing.
static func effigy_row(index: int, safe_r: float = EFFIGY_SAFE_R_M) -> Dictionary:
	var k := maxi(index, 0)
	var r := safe_r
	for row in EFFIGY_MAX_ROWS:
		var seat := EFFIGY_SEAT_M + EFFIGY_SEAT_GROWTH_M * float(row)
		var n := maxi(int(floor(TAU * r / seat)), 8)
		if k < n or row == EFFIGY_MAX_ROWS - 1:
			return {"row": row, "j": k, "n": n, "r": r, "seat": seat}
		k -= n
		r += EFFIGY_ROW_GAP_M + EFFIGY_ROW_GAP_GROWTH_M * float(row)
	return {"row": EFFIGY_MAX_ROWS - 1, "j": 0, "n": 8, "r": r, "seat": EFFIGY_SEAT_M}


## Where slot `index` stands at an effigy in `phase` at abs hours `t`.
## `seed01` is the person's own 0..1 (position jitter only — never the row).
static func effigy_slot(centre: Vector2, index: int, phase: int, t: float,
		circle_t0: float, seed01: float = 0.5, safe_r: float = EFFIGY_SAFE_R_M) -> Vector2:
	# Two independent scatters from one seed (the second decorrelated by a
	# golden-ratio multiple), so radius and bearing do not jitter in step.
	var j1 := seed01 - 0.5
	var j2 := fposmod(seed01 * 7.3108, 1.0) - 0.5
	match phase:
		EffigyPhase.BURNING:
			var rw := effigy_row(index, safe_r)
			var n := int(rw["n"])
			# Alternate rows stagger by half a seat so people look between
			# the heads in front, not at the back of one; then each person
			# shuffles a little along and out — never INSIDE the perimeter.
			var a := TAU * (float(rw["j"]) + 0.5 * float(int(rw["row"]) % 2)) / float(n)
			a += j2 * 0.6 * float(rw["seat"]) / maxf(float(rw["r"]), 1.0)
			var r := float(rw["r"]) + 0.4 + j1 * SEAT_JITTER_M * 2.0
			r = maxf(r, safe_r + 0.2)
			return centre + Vector2(cos(a), -sin(a)) * r
		EffigyPhase.CIRCLING:
			var lane := index % CIRCLE_LANES
			var r := safe_r + CIRCLE_INNER_M + float(lane) * CIRCLE_LANE_M + j1 * 0.8
			var a0 := fposmod(float(index) * GOLDEN_ANGLE, TAU)
			var elapsed := (t - circle_t0) if not is_nan(circle_t0) else 0.0
			var omega := TAU / CIRCLE_LAP_H * (1.0 - CIRCLE_LANE_SLOW * float(lane)) * (1.0 + j2 * 0.1)
			var a := a0 + omega * maxf(elapsed, 0.0)
			return centre + Vector2(cos(a), -sin(a)) * r
		_:
			var p := gather_slot(centre, index, safe_r * EFFIGY_GATHER_R, EFFIGY_GATHER_SEAT_M)
			return p + Vector2(j1, j2) * SEAT_JITTER_M


## The loose spiral used round an idle effigy (and any art-like venue that
## wants a stand-off distance): Vogel spiral starting `inner_r` out.
static func gather_slot(centre: Vector2, index: int, inner_r: float, seat_m: float) -> Vector2:
	var k := maxi(index, 0)
	var r := inner_r + seat_m * sqrt(float(k))
	var a := float(k) * GOLDEN_ANGLE
	return centre + Vector2(cos(a), sin(a)) * r


## How slot `index` holds itself at the effigy in `phase`.
static func effigy_pose(index: int, phase: int, seed01: float = 0.5, safe_r: float = EFFIGY_SAFE_R_M) -> String:
	match phase:
		EffigyPhase.BURNING:
			var row := int(effigy_row(index, safe_r)["row"])
			if row == 0:
				return POSE_LIE if seed01 < FRONT_ROW_LIE_SHARE else POSE_SIT
			if row == 1:
				return POSE_SIT
			return POSE_STAND
		EffigyPhase.CIRCLING:
			return POSE_DANCE if seed01 < CIRCLE_DANCE_SHARE else POSE_WALK
		_:
			return POSE_CLAP if seed01 < 0.5 else POSE_STAND


## The circle's angular speed for a lane (rad per sim hour, positive = CCW).
static func circle_omega(lane: int) -> float:
	return TAU / CIRCLE_LAP_H * (1.0 - CIRCLE_LANE_SLOW * float(lane % CIRCLE_LANES))


# ---------------------------------------------------------------------------
# Stage
# ---------------------------------------------------------------------------

## The point the fan hangs off: the stage footprint's extent along `fwd`
## from its centre (so the crowd stands in FRONT of the stage, not on it).
## An empty footprint (a prop target) uses the centre itself.
static func stage_front(centre: Vector2, poly: PackedVector2Array, fwd: Vector2) -> Vector2:
	var f := fwd.normalized() if fwd.length() > 1e-6 else Vector2(0.0, 1.0)
	var reach := 0.0
	for v in poly:
		reach = maxf(reach, (v - centre).dot(f))
	return centre + f * reach


## Slot `index` in the fan in front of `front`, facing `fwd`: a Vogel spiral
## folded onto the half-disc ahead of the speakers, so it fills front-first
## and evenly.
static func stage_slot(front: Vector2, fwd: Vector2, index: int, seed01: float = 0.5) -> Vector2:
	var f := fwd.normalized() if fwd.length() > 1e-6 else Vector2(0.0, 1.0)
	var side := Vector2(-f.y, f.x)
	var k := maxi(index, 0)
	var a := fposmod(float(k) * GOLDEN_ANGLE, STAGE_FAN_SPAN) - STAGE_FAN_SPAN * 0.5
	# Area of a sector grows with r², so r ~ sqrt(k) keeps the seat spacing
	# even; the span factor makes a narrower fan reach further back.
	var r := STAGE_FAN_GAP_M + STAGE_SEAT_M * sqrt(float(k) * (TAU / STAGE_FAN_SPAN) + 1.0)
	var j1 := seed01 - 0.5
	var j2 := fposmod(seed01 * 7.3108, 1.0) - 0.5
	return front + f * (r * cos(a) + j1 * SEAT_JITTER_M) + side * (r * sin(a) + j2 * SEAT_JITTER_M)


## The stage's facing when nothing says: toward `toward` (the camps), else
## south (+Z) — a stage with no camps near it faces whoever walks up.
static func stage_facing(centre: Vector2, toward: Vector2) -> Vector2:
	var d := toward - centre
	return d.normalized() if d.length() > 1.0 else Vector2(0.0, 1.0)


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

## Where slot `index` stands at a venue. `state` is NpcVenueState.resolve's
## dict (phase / circle_t0 / active), `extra` carries the stage's
## {front: Vector2, fwd: Vector2}. Returns Vector2.INF when the venue has no
## choreography (caller falls back to the registry's packing slot).
static func venue_spot(space_type: String, centre: Vector2, index: int, state: Dictionary,
		t: float, seed01: float, extra: Dictionary = {}) -> Vector2:
	match space_type:
		"effigy":
			return effigy_slot(centre, index, int(state.get("phase", EffigyPhase.IDLE)), t,
				float(state.get("circle_t0", NAN)), seed01, float(state.get("safe_r", EFFIGY_SAFE_R_M)))
		"stage":
			if bool(state.get("active", true)) and bool(state.get("programmed", false)):
				var front: Vector2 = extra.get("front", centre)
				var fwd: Vector2 = extra.get("fwd", Vector2(0.0, 1.0))
				return stage_slot(front, fwd, index, seed01)
			return Vector2.INF
	return Vector2.INF


## The pose hint for slot `index` at a venue, "" = the pose machine's default
## for that space type.
static func venue_pose(space_type: String, index: int, state: Dictionary, seed01: float) -> String:
	match space_type:
		"effigy":
			return effigy_pose(index, int(state.get("phase", EffigyPhase.IDLE)), seed01,
				float(state.get("safe_r", EFFIGY_SAFE_R_M)))
		"stage":
			if bool(state.get("active", true)) and bool(state.get("programmed", false)):
				return POSE_RAVE
	return ""


## True when people at this venue must be RE-SEATED every step (the slot
## moves with time, or the phase can change under them).
static func venue_is_live(space_type: String) -> bool:
	return space_type == "effigy" or space_type == "stage"

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
##             an art piece — a loose spiral that starts OUTSIDE the radius
##             it would need if it were lit, so lighting it never leaves
##             anyone standing in the fall zone.
##   BURNING   lit — INCLUDING the pre-roll before the first flame, which
##             exists precisely so the rings form before anything is
##             alight: everyone comes. Concentric RINGS
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
## front — and dances hard ("rave"), arms going up for the set's closer
## (the PEAK, its last PEAK_H). One person — the DJ — stands ON the stage, in
## the middle, facing the way the speakers point (the bridge picks and
## places them; see perform_spot).
##
## LAYOUT. Any venue can be gathered ROUND (a fire, an art piece) or face ONE
## way (speakers, a screen): the record's `layout` ("" = by type: a stage is
## directional, everything else round) and `facing_deg`. A directional
## venue's crowd stands in the fan in front of it whether or not anything is
## on, facing back toward it.
##
## FRIEND GROUPS at an ordinary (round, non-choreographed) venue stand
## together: each group holds its own small F-formation at a hashed spot
## round the venue (group_spot), rather than people packing a spiral in
## arrival order.
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
## The idle / after spiral starts this far OUTSIDE the phase's safe radius.
## (It used to start at 0.8 of it — inside the perimeter by design, and for
## an effigy taller than ~8 m inside the burn radius before anything was
## lit, so the ignition caught people standing in the fall zone.)
const EFFIGY_GATHER_GAP_M := 1.0
const EFFIGY_GATHER_SEAT_M := 1.0
## Share of the front row lying rather than sitting; of the circle dancing.
const FRONT_ROW_LIE_SHARE := 0.4
const CIRCLE_DANCE_SHARE := 0.55

enum EffigyPhase { IDLE, BURNING, CIRCLING, AFTER }

## The BURN SEQUENCE inside BURNING. The pre-roll (lit, no flame yet) is split
## by fraction so any pre-roll length works (old 15-minute records too):
##   gather   — the crowd forms its rings                  (first 35 %)
##   flow     — the FIRE FLOW: performers circle inside    (to 80 %)
##   sandmen  — performers out, sandmen kneel at the line  (last 20 %)
## then `burn` from the first flame (the cheer is its last minutes). The
## fire PERIMETER (nav stamp, no-go circles, the sandmen's watch) holds from
## `sandmen` until the circle dance ends — not during gather / flow, when the
## performers dance inside it.
const STAGE_GATHER := "gather"
const STAGE_FLOW := "flow"
const STAGE_SANDMEN := "sandmen"
const STAGE_BURN := "burn"
const GATHER_FRAC := 0.35
const FLOW_END_FRAC := 0.80

# --- burn roles ------------------------------------------------------------------
## FIRE FLOW: performers on a slow counter-clockwise lane inside the crowd
## ring (a lap every FLOW_LAP_H), FLOW_MIN..FLOW_MAX of them by turnout.
const FLOW_LANE_FRAC := 0.62
const FLOW_LAP_H := 0.2
const FLOW_MIN := 10
const FLOW_MAX := 20
## SANDMEN: one every SANDMAN_SPACING_M round the safe line, kneeling just
## inside it facing the crowd (backs to the fire).
const SANDMAN_SPACING_M := 6.0
const SANDMAN_MIN := 8
const SANDMAN_MAX := 24
const SANDMAN_INSET_M := 0.6
## Inside this far within the line counts as crossing it.
const BREACH_INSET_M := 0.3
const EFFIGY_PHASE_NAMES: Array = ["idle", "burning", "circling", "after"]

# --- stage -------------------------------------------------------------------
## The fan starts this far in front of the stage's front edge (the venue's
## `crowd_gap_m` overrides it — Ctrl-focus "Crowd distance"), and spans
## STAGE_FAN_SPAN either side of straight ahead — nobody stands level with
## the speakers, let alone behind them.
const STAGE_FAN_GAP_M := 1.5
const STAGE_FAN_GAP_MAX_M := 40.0
## Fan packing: each person gets ~pi x STAGE_SEAT_M^2 of floor (1.2 m^2 at
## 0.62) — nearest neighbour ~1.1 m: a dancing crowd at a stage, close but
## with room to move. (1.0 gave ~3.1 m^2 each: a polite queue, not a crowd.)
const STAGE_SEAT_M := 0.62
## Scatter inside a fan seat, kept under half the spacing so two people
## never land on each other.
const STAGE_JITTER_M := 0.3
const STAGE_FAN_SPAN := 2.2689280276   # 130 degrees
## The golden-ratio conjugate: fract(k x PHI) spreads seat k's BEARING evenly
## across the fan. (Folding the golden ANGLE onto a 130 degree span instead —
## 137.5 deg mod 130 deg — stepped each seat only 7.5 deg from the last, so the
## fan came out as two spiral ARMS: "two arcs too far from the speakers".)
const PHI_CONJ := 0.6180339887498949

## Pose hints the venues emit (read by the pose machine and the cohort).
const POSE_STAND := "stand"
const POSE_SIT := "sit"
const POSE_LIE := "lie"
const POSE_DANCE := "dance"
const POSE_RAVE := "rave"
const POSE_WALK := "walk"
const POSE_CLAP := "clap"
const POSE_TALK := "talk"
## Dancing LIGHTLY: a sway on the spot, arms low — round a fire with a
## stage's music drifting over (the rave is the hard one at the speakers).
const POSE_SWAY := "sway"
## Arms up: the effigy's collapse, a set's closer.
const POSE_CHEER := "cheer"
## The DJ at the decks.
const POSE_DJ := "dj"
## On the ground with the legs out, propped on straight arms, torso and head
## UP — the relaxed sit (a person lying flat at a venue read as dead). Plain
## POSE_SIT is cross-legged on the ground everywhere except the portapotty.
const POSE_LOUNGE := "lounge"
## Looking up at the effigy.
const POSE_GAZE := "gaze"
## Burn roles: a sandman kneeling at the line, a sandman turning someone
## back, a fire-flow performer spinning poi.
const POSE_KNEEL := "kneel"
const POSE_REDIRECT := "redirect"
const POSE_FIREFLOW := "fire_flow"

## A lit effigy draws the site: this share of people TURN OUT for the burn
## (hashed per person per burn) — they stay up past bedtime, leave their
## routine, and come from anywhere on the map. It never wakes a sleeper.
const BURN_TURNOUT := 0.85
## An unlit effigy is a standing attraction (an art piece that IS the
## festival): its own pull, whatever a person's taste.
const EFFIGY_IDLE_PULL := 0.3
const EFFIGY_IDLE_DRAW := 0.9

## The moments a crowd reacts together: the last CHEER_LEAD_H before an
## effigy comes down, and the last PEAK_H of a stage set (its closer). Not
## everyone — a share cheers and the rest keep doing what they were.
const CHEER_LEAD_H := 0.04
const CHEER_SHARE := 0.85
const PEAK_H := 0.33
const PEAK_SHARE := 0.6

## Friend-group clusters round an ordinary venue: cluster spacing on the
## venue's spiral and how many distinct cluster spots it offers. A cluster is
## up to ~3.1 m across (five people in an F-formation), so neighbours sit
## GROUP_SEAT_M apart and the first one starts GROUP_CLEAR_M clear of the
## venue's footprint — nobody's circle stands in the art piece.
const GROUP_SEAT_M := 3.4
const GROUP_CLEAR_M := 1.8
const GROUP_SPOTS := 48

# --- fire circle -------------------------------------------------------------
## People gather ROUND a fire: concentric rings from FIRE_RING_GAP_M off the
## pit's edge (the venue's `crowd_gap_m` overrides it), seats FIRE_SEAT_M
## apart in the front ring and looser further out. The ring stands still: a
## lit fire is a place to CHAT with the people beside you (some sit), and
## when a stage's music carries over (`music_near`, within MUSIC_EARSHOT_M
## of a playing stage — the bridge decides) most of the ring sways to it on
## the spot. The heat is what brings them (the bridge's fire pull, see
## NpcComfort.fire_warmth). The turning dance ring the fire used to run is
## kept as fire_ring_slot's `moving` option, but no caller asks for it.
const FIRE_RING_GAP_M := 1.2
const FIRE_SEAT_M := 0.95
const FIRE_SEAT_GROWTH_M := 0.15
const FIRE_ROW_GAP_M := 1.0
const FIRE_MAX_ROWS := 12
const FIRE_LAP_H := 0.12
const FIRE_ROW_SLOW := 0.08
const FIRE_DANCE_SHARE := 0.85
## Round a lit fire with no music: this share stand and talk, the rest sit.
const FIRE_TALK_SHARE := 0.6
## With music in earshot: this share sway to it, the rest keep talking.
const FIRE_SWAY_SHARE := 0.7
## How far a playing stage's music carries for the people at a fire
## (StageMusic is full inside 14 m and gone by 520 m; past ~180 m it is a
## beat you notice, not one you move to).
const MUSIC_EARSHOT_M := 180.0
## Venue types whose groups face EACH OTHER (a conversation) rather than the
## venue's centre (an art piece, a fire, the temple).
const CONVERSE_TYPES: Array = ["center_camp", "workshop_social", "movement"]


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
	# IDLE keeps the BURNING perimeter: an unlit effigy can be lit at any
	# moment, and the crowd round it must already be outside the fall zone.
	return maxf(h, fr) + PERIMETER_STANDING_M


## {phase: EffigyPhase, name, ends_in_h (hours until the phase changes; -1 =
## open-ended), circle_t0 (abs hours the circling began; NAN otherwise),
## safe_r (the perimeter for that phase), preroll (lit, no flame yet),
## flame_in_h (hours to the first flame while in pre-roll)}.
## `fire_rec` may also be a SIZE-ONLY dict ({height_m, footprint_r_m}) for an
## effigy that has never been lit: the idle perimeter still follows its size.
static func effigy_phase(fire_rec: Dictionary, t: float) -> Dictionary:
	var out := {"phase": EffigyPhase.IDLE, "name": "idle", "ends_in_h": -1.0, "circle_t0": NAN,
		"safe_r": safe_radius(fire_rec, EffigyPhase.IDLE), "preroll": false, "flame_in_h": 0.0,
		"cheer": false}
	if fire_rec.is_empty() or not FireTimeline.is_record(fire_rec):
		return out
	var st := FireTimeline.state_at(fire_rec, t)
	out["stage"] = ""
	out["perimeter"] = false
	if bool(st.get("preroll", false)):
		# Lit, no flame yet: the crowd forms its rings NOW, at the burning
		# radius — and the sequence runs gather -> flow -> sandmen.
		out["phase"] = EffigyPhase.BURNING
		out["name"] = "burning"
		out["preroll"] = true
		var flame_in := float(st.get("flame_in_h", 0.0))
		out["flame_in_h"] = flame_in
		out["safe_r"] = safe_radius(fire_rec, EffigyPhase.BURNING)
		out["ends_in_h"] = flame_in + FireTimeline.climb_h(fire_rec) + FireTimeline.COLLAPSE_H
		out["cheer"] = false
		var pre := maxf(float(fire_rec.get("preroll_h", 0.0)), 1e-4)
		var frac := clampf(1.0 - flame_in / pre, 0.0, 1.0)
		if frac < GATHER_FRAC:
			out["stage"] = STAGE_GATHER
			out["stage_ends_in_h"] = (GATHER_FRAC - frac) * pre
		elif frac < FLOW_END_FRAC:
			out["stage"] = STAGE_FLOW
			out["stage_ends_in_h"] = (FLOW_END_FRAC - frac) * pre
			out["flow_t0"] = t - (frac - GATHER_FRAC) * pre
		else:
			out["stage"] = STAGE_SANDMEN
			out["stage_ends_in_h"] = flame_in
			out["perimeter"] = true
		out["burn_key"] = "%.4f" % float(fire_rec.get("ignited_h", 0.0))
		return out
	out["burn_key"] = "%.4f" % float(fire_rec.get("ignited_h", 0.0))
	match int(st.get("phase", FireTimeline.Phase.NONE)):
		FireTimeline.Phase.BURNING, FireTimeline.Phase.COLLAPSING:
			out["phase"] = EffigyPhase.BURNING
			out["name"] = "burning"
			out["safe_r"] = safe_radius(fire_rec, EffigyPhase.BURNING)
			# Hours of burn left before the pile lands (a hold stretches it;
			# the caller re-reads the phase every step anyway).
			var left := FireTimeline.climb_h(fire_rec) + FireTimeline.COLLAPSE_H - float(st.get("burn_h", 0.0))
			out["ends_in_h"] = maxf(left, 1.0 / 60.0)
			# The last minutes before it comes down: everybody up, arms up.
			out["cheer"] = left <= CHEER_LEAD_H
			out["stage"] = STAGE_BURN
			out["perimeter"] = true
		FireTimeline.Phase.PILE:
			var age := float(st.get("age_h", 0.0))
			if age < CIRCLE_H:
				out["phase"] = EffigyPhase.CIRCLING
				out["name"] = "circling"
				out["ends_in_h"] = maxf(CIRCLE_H - age, 1.0 / 60.0)
				out["circle_t0"] = t - age
				out["safe_r"] = safe_radius(fire_rec, EffigyPhase.CIRCLING)
				out["perimeter"] = true
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
			var p := gather_slot(centre, index, safe_r + EFFIGY_GATHER_GAP_M + SEAT_JITTER_M, EFFIGY_GATHER_SEAT_M)
			return p + Vector2(j1, j2) * SEAT_JITTER_M


## The loose spiral used round an idle effigy (and any art-like venue that
## wants a stand-off distance): Vogel spiral starting `inner_r` out.
static func gather_slot(centre: Vector2, index: int, inner_r: float, seat_m: float) -> Vector2:
	var k := maxi(index, 0)
	var r := inner_r + seat_m * sqrt(float(k))
	var a := float(k) * GOLDEN_ANGLE
	return centre + Vector2(cos(a), sin(a)) * r


## How slot `index` holds itself at the effigy in `phase`.
static func effigy_pose(index: int, phase: int, seed01: float = 0.5, safe_r: float = EFFIGY_SAFE_R_M,
		cheer: bool = false) -> String:
	match phase:
		EffigyPhase.BURNING:
			if cheer:
				return POSE_CHEER if seed01 < CHEER_SHARE else POSE_CLAP
			var row := int(effigy_row(index, safe_r)["row"])
			if row == 0:
				# Front row on the ground: propped up, or cross-legged — never
				# flat (a lying crowd at a burn read as casualties).
				return POSE_LOUNGE if seed01 < FRONT_ROW_LIE_SHARE else POSE_SIT
			if row == 1:
				return POSE_SIT
			return POSE_STAND
		EffigyPhase.CIRCLING:
			return POSE_DANCE if seed01 < CIRCLE_DANCE_SHARE else POSE_WALK
		_:
			# Round an unlit effigy (or the embers): people come to LOOK at it
			# and hang out — gazing up, sitting, lounging, talking, a few
			# dancing.
			if seed01 < 0.3:
				return POSE_GAZE
			if seed01 < 0.55:
				return POSE_SIT
			if seed01 < 0.7:
				return POSE_LOUNGE
			if seed01 < 0.9:
				return POSE_TALK
			return POSE_DANCE


## Does a downpour send people at this venue for cover? Ordinary venues and
## fire circles yes; an EFFIGY too unless a burn is on (an unlit effigy is a
## hang-out, not a show); a stage or other live venue holds its crowd.
static func rain_clears(space_type: String, event_active: bool) -> bool:
	if space_type == "fire_circle":
		return true
	if space_type == "effigy":
		return not event_active
	return not SpaceTypes.LIVE_VENUE_TYPES.has(space_type)


## Is this person part of the burn's turnout? (`burn_key` identifies the
## burn — NpcVenueState's.)
static func attends(agent_id: String, burn_key: String) -> bool:
	if burn_key.is_empty():
		return false
	return NpcHash.unit01(agent_id, "burn" + burn_key) < BURN_TURNOUT


## A point on a moving circle: {centre, r, a0 (radians), t0 (abs h), lap_h}
## at abs hours `t` — counter-clockwise seen from above.
static func orbit_point(orbit: Dictionary, t: float) -> Vector2:
	var c: Vector2 = orbit.get("centre", Vector2.ZERO)
	var lap := maxf(float(orbit.get("lap_h", FLOW_LAP_H)), 1e-4)
	var a := float(orbit.get("a0", 0.0)) + TAU * fposmod((t - float(orbit.get("t0", t))) / lap, 1.0)
	return c + Vector2(cos(a), -sin(a)) * float(orbit.get("r", 1.0))


## The counter-clockwise tangent at `p` on a circle round `centre`.
static func ccw_tangent(centre: Vector2, p: Vector2) -> Vector2:
	var d := p - centre
	if d.length() < 1e-4:
		return Vector2(0.0, -1.0)
	var n := d.normalized()
	# (cos a, -sin a) with a increasing: d/da = (-sin a, -cos a) = (n.y, -n.x).
	return Vector2(n.y, -n.x)


## The fire-flow lane for performer k of n: {centre, r, a0, t0, lap_h}.
static func flow_orbit(centre: Vector2, safe_r: float, k: int, n: int, t0: float) -> Dictionary:
	return {"centre": centre, "r": maxf(safe_r * FLOW_LANE_FRAC, 3.0),
		"a0": TAU * float(k) / float(maxi(n, 1)), "t0": t0, "lap_h": FLOW_LAP_H}


## How many performers / sandmen a burn gets.
static func flow_count(turnout: int) -> int:
	return clampi(int(round(float(turnout) / 30.0)), FLOW_MIN, FLOW_MAX)


static func sandman_count(safe_r: float) -> int:
	return clampi(int(round(TAU * safe_r / SANDMAN_SPACING_M)), SANDMAN_MIN, SANDMAN_MAX)


## Sandman k's post: just inside the safe line, facing OUT (the crowd), back
## to the fire. {pos, face}.
static func sandman_post(centre: Vector2, safe_r: float, k: int, n: int) -> Dictionary:
	var a := TAU * (float(k) + 0.5) / float(maxi(n, 1))
	var dir := Vector2(cos(a), -sin(a))
	return {"pos": centre + dir * (safe_r - SANDMAN_INSET_M), "face": centre + dir * (safe_r + 20.0)}


## Is a point inside a burn's line (crossing it)?
static func breaches(centre: Vector2, safe_r: float, p: Vector2) -> bool:
	return p.distance_to(centre) < safe_r - BREACH_INSET_M


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


## Slot `index` in the fan in front of `front`, facing `fwd`: a sunflower
## (Vogel) packing of the sector ahead of the speakers — radius ~ sqrt(k) for
## even density, bearing from the golden-ratio sequence for an even spread —
## so it fills front-first, evenly, `gap_m` off the front edge.
static func stage_slot(front: Vector2, fwd: Vector2, index: int, seed01: float = 0.5,
		gap_m: float = -1.0) -> Vector2:
	var f := fwd.normalized() if fwd.length() > 1e-6 else Vector2(0.0, 1.0)
	var side := Vector2(-f.y, f.x)
	var k := maxi(index, 0)
	var a := (fposmod(float(k) * PHI_CONJ + 0.5, 1.0) - 0.5) * STAGE_FAN_SPAN
	# A sector of span S and radius r holds S r^2 / 2 of floor; one seat per
	# pi c^2 gives r = c sqrt(2 pi k / S) — the span factor makes a narrower
	# fan reach further back. The fan's apex sits `gap` straight out from the
	# front edge, so NOBODY is nearer the speakers' line than the gap.
	var gap := gap_m if gap_m >= 0.0 else STAGE_FAN_GAP_M
	var r := STAGE_SEAT_M * (sqrt(float(k) * (TAU / STAGE_FAN_SPAN) + 1.0) - 0.5)
	var j1 := seed01 - 0.5
	var j2 := fposmod(seed01 * 7.3108, 1.0) - 0.5
	return front + f * (gap + r * cos(a) + absf(j1) * STAGE_JITTER_M) + side * (r * sin(a) + j2 * STAGE_JITTER_M)


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
	if space_type == "effigy":
		return effigy_slot(centre, index, int(state.get("phase", EffigyPhase.IDLE)), t,
			float(state.get("circle_t0", NAN)), seed01, float(state.get("safe_r", EFFIGY_SAFE_R_M)))
	var lay := str(extra.get("layout", layout_of(space_type, "")))
	if lay == SpaceRegistry.LAYOUT_DIRECTIONAL:
		# Speakers / a screen: the crowd stands in the cone in FRONT of it —
		# set or no set — never beside or behind it.
		var front: Vector2 = extra.get("front", centre)
		var fwd: Vector2 = extra.get("fwd", Vector2(0.0, 1.0))
		return stage_slot(front, fwd, index, seed01, float(extra.get("gap", -1.0)))
	if space_type == "fire_circle":
		# Round a fire: the ring of people warming themselves (still).
		var gf := float(extra.get("gap", -1.0))
		var rf := maxf(float(extra.get("r", 0.0)), 0.5) + (gf if gf >= 0.0 else FIRE_RING_GAP_M)
		return fire_ring_slot(centre, index, t, rf, seed01, false)
	if space_type == "stage":
		# A stage the player turned ROUND: a ring outside its footprint.
		var g := float(extra.get("gap", -1.0))
		var r_in := float(extra.get("r", 0.0)) + (g if g >= 0.0 else STAGE_FAN_GAP_M)
		return gather_slot(centre, index, r_in, STAGE_SEAT_M) \
			+ Vector2(seed01 - 0.5, fposmod(seed01 * 7.3108, 1.0) - 0.5) * SEAT_JITTER_M
	return Vector2.INF


## Is a fire circle's fire burning? (A firepit's state comes from the bridge;
## a fire circle with no such knowledge counts as lit.)
static func fire_lit(state: Dictionary) -> bool:
	return bool(state.get("lit", true))


## Is a stage's music carrying to this fire? (Stamped by the bridge; nothing
## stamped = no music.)
static func fire_music(state: Dictionary) -> bool:
	return bool(state.get("music_near", false))


## Does any music source reach `pos`? `sources` = Array of Vector2 (where the
## sound comes from — a playing stage's speakers). Pure, for the bridge.
static func music_reaches(pos: Vector2, sources: Array, radius: float = MUSIC_EARSHOT_M) -> bool:
	for s in sources:
		if s is Vector2 and pos.distance_to(s) <= radius:
			return true
	return false


## The ring a fire-circle slot stands in: {row, j, n, r}. Rows fill front to
## back, each holding what its circumference allows at its spacing.
static func fire_row(index: int, r_in: float) -> Dictionary:
	var k := maxi(index, 0)
	var r := r_in
	for row in FIRE_MAX_ROWS:
		var seat := FIRE_SEAT_M + FIRE_SEAT_GROWTH_M * float(row)
		var n := maxi(int(floor(TAU * r / seat)), 5)
		if k < n or row == FIRE_MAX_ROWS - 1:
			return {"row": row, "j": k, "n": n, "r": r}
		k -= n
		r += FIRE_ROW_GAP_M + 0.1 * float(row)
	return {"row": 0, "j": 0, "n": 5, "r": r_in}


## Where slot `index` stands round a fire at abs hours `t`: its ring seat,
## carried counter-clockwise round the fire while it burns (`moving`). A pure
## function of t, so both tiers draw the same dance and it scrubs.
static func fire_ring_slot(centre: Vector2, index: int, t: float, r_in: float, seed01: float,
		moving: bool) -> Vector2:
	var rw := fire_row(index, r_in)
	var row := int(rw["row"])
	var a := TAU * (float(rw["j"]) + 0.5 * float(row % 2)) / float(rw["n"])
	a += (fposmod(seed01 * 7.3108, 1.0) - 0.5) * 0.5 * FIRE_SEAT_M / maxf(float(rw["r"]), 1.0)
	if moving:
		a += fposmod(t / FIRE_LAP_H, 1.0) * TAU * (1.0 - FIRE_ROW_SLOW * float(row))
	var r := float(rw["r"]) + (seed01 - 0.5) * 0.4
	return centre + Vector2(cos(a), -sin(a)) * maxf(r, r_in - 0.1)


## True while a live venue's crowd is MOVING round it (the effigy's circle
## dance): the light tier steps it as arcs (S_CIRCLE). A fire's ring stands
## still — people chat and sway there, they do not lap it.
static func is_circling(space_type: String, state: Dictionary) -> bool:
	if space_type == "effigy":
		return int(state.get("phase", -1)) == EffigyPhase.CIRCLING
	return false


## The pose hint for slot `index` at a venue, "" = the pose machine's default
## for that space type.
static func venue_pose(space_type: String, index: int, state: Dictionary, seed01: float) -> String:
	match space_type:
		"fire_circle":
			if not fire_lit(state):
				# A cold pit by day is a hangout: half sit round it, half
				# stand and talk (a still ring of standing people read as a
				# crowd with nothing to do).
				return POSE_SIT if seed01 < 0.5 else POSE_TALK
			if fire_music(state):
				# A stage's music carries over: most sway to it, the rest
				# keep the conversation going.
				return POSE_SWAY if seed01 < FIRE_SWAY_SHARE else POSE_TALK
			# Warming up and chatting with whoever is beside you.
			return POSE_TALK if seed01 < FIRE_TALK_SHARE else POSE_SIT
		"effigy":
			return effigy_pose(index, int(state.get("phase", EffigyPhase.IDLE)), seed01,
				float(state.get("safe_r", EFFIGY_SAFE_R_M)), bool(state.get("cheer", false)))
		"stage":
			if bool(state.get("active", true)) and bool(state.get("programmed", false)):
				# The set's closer: most of the crowd throws its arms up.
				if bool(state.get("peak", false)) and seed01 < PEAK_SHARE:
					return POSE_CHEER
				return POSE_RAVE
	return ""


## True when people at this venue must be RE-SEATED every step (the slot
## moves with time, or the phase can change under them).
static func venue_is_live(space_type: String) -> bool:
	return space_type == "effigy" or space_type == "stage" or space_type == "fire_circle"


## A venue's crowd layout: the record's own choice, else by type — a stage
## faces one way, everything else is gathered round.
static func layout_of(space_type: String, layout: String) -> String:
	if layout == SpaceRegistry.LAYOUT_RING or layout == SpaceRegistry.LAYOUT_DIRECTIONAL:
		return layout
	return SpaceRegistry.LAYOUT_DIRECTIONAL if space_type == "stage" else SpaceRegistry.LAYOUT_RING


## Facing (compass degrees, north 0 / east 90, CelestialClock convention:
## north −Z, east +X) -> the XZ direction the speakers point.
static func fwd_from_deg(deg: float) -> Vector2:
	return Vector2(sin(deg_to_rad(deg)), -cos(deg_to_rad(deg)))


## ...and back: compass degrees of an XZ direction, 0..360.
static func deg_from_fwd(fwd: Vector2) -> float:
	return fposmod(rad_to_deg(atan2(fwd.x, -fwd.y)), 360.0)


## The performer's mark: the middle of the stage, raised to its deck, facing
## the way the speakers point. {pos, face (a point 10 m out front), elev}.
static func perform_spot(centre: Vector2, fwd: Vector2, deck_h: float) -> Dictionary:
	var f := fwd.normalized() if fwd.length() > 1e-6 else Vector2(0.0, 1.0)
	return {"pos": centre, "face": centre + f * 10.0, "elev": maxf(deck_h, 0.0)}


## How far off a ROUND venue's footprint its crowd starts: the venue's
## `crowd_gap_m` (extra "gap"), else by type — a fire's dance ring, a round
## stage, or (ordinary venues) the friend-group clusters' standoff.
static func round_gap(space_type: String, extra: Dictionary) -> float:
	var g := float(extra.get("gap", -1.0))
	if g >= 0.0:
		return g
	match space_type:
		"fire_circle":
			return FIRE_RING_GAP_M
		"stage":
			return STAGE_FAN_GAP_M
	return 1.0


## Where the FRONT of a round venue's crowd stands, from its centre (the
## Ctrl-focus ring shows this): the footprint radius + round_gap, and for an
## ordinary venue the clusters' own clearance.
static func front_ring_r(space_type: String, footprint_r: float, extra: Dictionary) -> float:
	var g := round_gap(space_type, extra)
	match space_type:
		"fire_circle":
			return maxf(footprint_r, 0.5) + g
		"stage":
			return footprint_r + g
	return maxf(footprint_r + g, 1.0) + GROUP_CLEAR_M - 1.5


## A friend group's spot at an ordinary (round) venue: the group's cluster on
## the venue's spiral from `inner_r` out, the member at their place in its
## F-formation. {pos, face}: a conversation venue faces the cluster's middle,
## everything else faces the venue. `cluster_k` is the group's cluster index
## at this venue (SpaceRegistry.cluster_index_for — lowest free, so no two
## groups share one); < 0 falls back to a hashed one of GROUP_SPOTS.
static func group_spot(space_type: String, centre: Vector2, inner_r: float, agent_id: String,
		cluster_k: int = -1) -> Dictionary:
	var g := NpcFriends.group_of(agent_id)
	var gk := str(g["key"])
	var k := cluster_k if cluster_k >= 0 else int(NpcHash.unit01(gk, "vg") * float(GROUP_SPOTS))
	var cluster := gather_slot(centre, k, maxf(inner_r, 1.0) + GROUP_CLEAR_M, GROUP_SEAT_M)
	var off := NpcFriends.formation_offset(gk, int(g["k"]), int(g["size"]), NpcHash.unit01(agent_id, "seat"))
	var face := cluster if CONVERSE_TYPES.has(space_type) else centre
	if int(g["size"]) <= 1:
		face = centre
	return {"pos": cluster + off, "face": face}

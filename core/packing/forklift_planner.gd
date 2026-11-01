class_name ForkliftPlanner
extends RefCounted

## Trip timing and parking for a forklift moving one handling unit.
## Pure static: the chore rows and the renderer both read these numbers.
## Speeds are typical warehouse figures for a counterbalance truck on
## rough ground (rated travel ~16-19 km/h on a floor; outdoors on dirt a
## careful operator runs well under half of that).

const SPEED_LOADED_MS := 1.8
const SPEED_EMPTY_MS := 2.6
const LIFT_SPEED_MS := 0.45      ## mast lift / lower, metres per second
const T_ENGAGE_S := 25.0         ## line up, slide the forks in, tilt back
const T_SETDOWN_S := 15.0        ## line up, lower, back out
const CARRY_LIFT_M := 0.25       ## travelling height of the load
const PARK_GAP_M := 0.8          ## clear space between the forks and the set-down unit


## Seconds for one trip: pick up, carry route_m, set down, drive back empty.
## lift_m is the height the unit is taken from or set onto (a stack).
static func trip_s(route_m: float, lift_m: float = 0.0) -> float:
	var r := maxf(route_m, 0.0)
	var lift := absf(lift_m) + CARRY_LIFT_M
	return T_ENGAGE_S + T_SETDOWN_S + 2.0 * lift / LIFT_SPEED_MS \
		+ r / SPEED_LOADED_MS + r / SPEED_EMPTY_MS


static func trip_hours(route_m: float, lift_m: float = 0.0) -> float:
	return trip_s(route_m, lift_m) / 3600.0


## Where the truck stands once it has backed off a unit set down at `drop`,
## approached from `from` (world XZ).
static func park_beside(drop: Vector2, from: Vector2) -> Vector2:
	var d := from - drop
	var dir := Vector2(0.0, 1.0) if d.length() < 0.01 else d.normalized()
	var back := absf(ForkliftBuilder.fork_reach_z()) + PARK_GAP_M
	return drop + dir * back


## Prop yaw (degrees) that points the forks (local -Z) from `at` toward `to`.
static func facing_yaw_deg(at: Vector2, to: Vector2) -> float:
	var d := to - at
	if d.length() < 0.001:
		return 0.0
	return rad_to_deg(atan2(-d.x, -d.y))


## Where the truck's origin stands while its forks hold a unit at `unit`,
## facing it from `toward`.
static func pickup_stance(unit: Vector2, toward: Vector2) -> Vector2:
	var d := toward - unit
	var dir := Vector2(0.0, 1.0) if d.length() < 0.01 else d.normalized()
	return unit + dir * (absf(ForkliftBuilder.fork_reach_z()) - ForkliftBuilder.FORK_LEN_M * 0.5)


## Can this truck take the unit at all.
static func can_carry(mass_kg: float) -> bool:
	return mass_kg > 0.0 and mass_kg <= ForkliftBuilder.CAPACITY_KG

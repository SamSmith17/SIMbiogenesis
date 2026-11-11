class_name FarmBotGeom
extends RefCounted

## Where the machine's coordinates are on the bed, for both kinds of robot.
##
## LINEAR (FarmBot's own): a gantry rolls along two straight tracks on the
## walls of a rectangular bed. Machine X = mm along the tracks from the bed's
## -X end, Y = mm across from its -Z side.
##
## RADIAL (for the keyhole beds in the greenhouses, GrowBed's keyhole layout):
## a truss arm pivots on a post in the compost basket at the centre and rides
## a curved rail on the outer ring's wall on a driven wheel; the carriage runs
## along the arm. Machine X = mm of arc along that rail (so the outer wheel's
## speed is X's speed, and FarmBotMotion's ramps hold unchanged: the arm turns
## at v / R, and a tool near the post moves slower than the rail), Y = mm out
## from the pivot. With the sweep "slot" the rail stops either side of the
## keyhole slot (the path in) and X = 0 is its start just past the slot;
## "full" bridges the slot and X = 0 is the slot's centre line. Angles follow
## GrowBed: 0 is +Z (the slot), a point is (sin a, cos a)·r.
##
## Z is the same for both: 0 at the top of the Z travel, negative down.

const RAIL_OUT_M := 0.03          # the rail just outside the outer wall's line
const RAIL_CLEAR_RAD := 0.012     # the rail stops this far past the slot's edge
const TOOL_R_PAD := 0.25          # tools hang this far inside the inner ring
const MIN_ARM_R := 0.3            # the carriage cannot reach closer to the post


static func is_radial(s: Dictionary) -> bool:
	return str(s.get("kind", "linear")) == "radial"


## How many arms share the rail (a linear robot has one gantry).
static func arm_count(s: Dictionary) -> int:
	if not is_radial(s):
		return 1
	return clampi(int(keyhole(s).get("arms", 1)), 1, 4)


## The keyhole's numbers (GrowBed's keys).
static func keyhole(s: Dictionary) -> Dictionary:
	var k: Dictionary = GrowBed.KEYHOLE_DEFAULTS.duplicate()
	var o: Variant = s.get("keyhole", {})
	if o is Dictionary:
		for key in (o as Dictionary).keys():
			k[key] = (o as Dictionary)[key]
	return k


## Ring beds: [{r0, r1, a0, a1, ring}], exactly GrowBed's.
static func rings(s: Dictionary) -> Array:
	return GrowBed._keyhole_rings(keyhole(s))


## The rail's radius (m).
static func rail_r(s: Dictionary) -> float:
	return float(keyhole(s)["outer_r"]) + RAIL_OUT_M


## Where the rail starts (rad, from +Z) and how far it runs.
static func sweep(s: Dictionary) -> Vector2:
	var k := keyhole(s)
	if str(k.get("sweep", "slot")) == "full":
		return Vector2(0.0, TAU)
	var rr := rail_r(s)
	var half := asin(clampf(float(k["slot_w"]) * 0.5 / rr, 0.0, 0.99)) + RAIL_CLEAR_RAD
	return Vector2(half, TAU - 2.0 * half)


## Machine X range (mm) and Y range (mm).
static func x_max_mm(s: Dictionary) -> float:
	if is_radial(s):
		return sweep(s).y * rail_r(s) * 1000.0
	return float((s["bed"] as Dictionary)["length_m"]) * 1000.0


static func y_range_mm(s: Dictionary) -> Vector2:
	if is_radial(s):
		return Vector2(MIN_ARM_R * 1000.0, float(keyhole(s)["outer_r"]) * 1000.0)
	return Vector2(0.0, float((s["bed"] as Dictionary)["width_m"]) * 1000.0)


## A bed point (m, the builder's frame) to machine mm (X, Y).
static func to_machine(s: Dictionary, x: float, z: float) -> Vector2:
	if is_radial(s):
		var sw := sweep(s)
		var a := fposmod(atan2(x, z), TAU)
		var off := fposmod(a - sw.x, TAU)
		if off > sw.y and sw.y < TAU - 0.0001:
			# Past the rail's end (in the slot): the nearer end.
			off = 0.0 if off - sw.y > (TAU - off) else sw.y
		return Vector2(off * rail_r(s) * 1000.0, sqrt(x * x + z * z) * 1000.0)
	var b: Dictionary = s["bed"]
	return Vector2((x + float(b["length_m"]) * 0.5) * 1000.0, (z + float(b["width_m"]) * 0.5) * 1000.0)


## Machine mm (X, Y) back to a bed point (m).
static func to_bed(s: Dictionary, X: float, Y: float) -> Vector2:
	if is_radial(s):
		var a := arm_angle(s, X)
		var r := Y / 1000.0
		return Vector2(sin(a) * r, cos(a) * r)
	var b: Dictionary = s["bed"]
	return Vector2(X / 1000.0 - float(b["length_m"]) * 0.5, Y / 1000.0 - float(b["width_m"]) * 0.5)


## The arm's angle (rad from +Z) at machine X.
static func arm_angle(s: Dictionary, X: float) -> float:
	return sweep(s).x + X / (rail_r(s) * 1000.0)


## Growing area (m²): the bed, or the keyhole's ring beds.
static func area_m2(s: Dictionary) -> float:
	if is_radial(s):
		var a := 0.0
		for r in rings(s):
			var rr: Dictionary = r
			a += 0.5 * (float(rr["a1"]) - float(rr["a0"])) * (pow(float(rr["r1"]), 2.0) - pow(float(rr["r0"]), 2.0))
		return a
	var b: Dictionary = s["bed"]
	return float(b["length_m"]) * float(b["width_m"])


## The radius tools hang at (the path inside the innermost ring).
static func tool_r(s: Dictionary) -> float:
	var inner := float(keyhole(s)["outer_r"])
	for r in rings(s):
		inner = minf(inner, float((r as Dictionary)["r0"]))
	return maxf(inner - TOOL_R_PAD, MIN_ARM_R + 0.15)


## The radius the seed trough rides at: over the path nearest the middle of
## the arm, so a seed is never far away.
static func trough_r(s: Dictionary) -> float:
	var rs := rings(s)
	var mid := 0.5 * (float(keyhole(s)["outer_r"]) + tool_r(s))
	var best := mid
	var best_d := INF
	for i in range(1, rs.size()):
		var pr := 0.5 * (float(rs[i - 1]["r0"]) + float(rs[i]["r1"]))
		if absf(pr - mid) < best_d:
			best_d = absf(pr - mid)
			best = pr
	return best


## What the gantry beam (linear) or the arm (radial) spans, m.
static func arm_len_m(s: Dictionary) -> float:
	return rail_r(s) if is_radial(s) else float((s["bed"] as Dictionary)["width_m"])

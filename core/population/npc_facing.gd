class_name NpcFacing
extends RefCounted

## Which way a STATIONARY person points, and the slow drift that stops a settled
## camp reading as a diorama.
##
## Pure static maths — no scene, no `randf()`, no state. World yaw follows the
## convention `NpcPopulationHost` already applies and `NpcRig.model_yaw_offset`
## is measured against: CelestialClock north is −Z and east is +X, so a bearing
## toward `d` is `atan2(-d.x, -d.y)`.
##
## ## The bug this exists to fix
##
## The host used to write yaw ONLY while the body was still moving:
##
##     var dir := sim_pos - Vector2(cur.x, cur.z)
##     if dir.length() > YAW_EPS_M:            # 0.25 m
##         yaw = lerp_angle(yaw, atan2(-dir.x, -dir.y), ...)
##
## `NpcAgent._step_traveling` sets `pos = target_pos` on arrival, the rendered
## body converges on it, `dir` falls under the threshold, and the yaw LATCHES on
## the approach heading for the whole work session. A non-brigade crew chore
## resolves to exactly one coordinate, so the whole crew walks one nav route to
## one point and freezes on one bearing — six people facing identically, which
## is what "when people work they all align" looks like from the outside. The
## separation pass then spreads their POSITIONS by pushes capped at 0.25 m, at
## or below the very threshold that would have re-triggered the write, so the
## facings never follow.
##
## The fix is not a bigger epsilon. It is that a stationary person has an
## ANCHOR — the thing they came here for — and their bearing is re-derived from
## it every tick. That re-derivation is what lets the separation spread finally
## reach the facings: at ~0.9 m personal spacing around a shared work point,
## inward bearings differ by tens of degrees on their own.

## Below this the anchor is effectively our own feet and its direction is
## meaningless noise. Deliberately larger than `NpcPopulationEngine.MAX_PUSH_M`
## (0.25) so one tick of crowding cannot flip a degenerate anchor into a
## "valid" one and snap a figure around. It can be this small — unlike the
## host's `YAW_EPS_M` this vector is a static geometric relationship, not a
## travel delta that shrinks asymptotically toward zero by design.
const MIN_ANCHOR_M := 0.35

## Idle drift, bounded in AMPLITUDE rather than rate. That choice is load
## bearing: beyond `FAR_DIST_M` the host poses at 0.25 s intervals and the
## slew collapses to a hard set, so a rate-limited drift would become a visible
## 4 Hz twitch while an amplitude-limited one stays a sub-pixel wobble.
const DRIFT_AMP_RAD := 0.11        # ±6.3°, 12.6° peak to peak
## Two incommensurate periods, so the sum never repeats on a countable beat.
const DRIFT_P1_H := 0.21
const DRIFT_P2_H := 0.083
## Weights sum to exactly 1.0 so the amplitude bound is provable, which is what
## the selftest pins rather than sampling and hoping.
const DRIFT_W1 := 0.68
const DRIFT_W2 := 0.32


## The bearing from `pos` toward `anchor`, or `phase` when there is no usable
## anchor. `phase` is the agent's own stable heading, so a camp with nothing to
## look at still faces every which way instead of all facing north.
static func base_yaw(pos: Vector2, anchor: Vector2, phase: float) -> float:
	if anchor == Vector2.INF or is_nan(anchor.x) or is_nan(anchor.y):
		return phase
	var d := anchor - pos
	if d.length() < MIN_ANCHOR_M:
		return phase
	return atan2(-d.x, -d.y)


## Bounded wander on the SIM clock, so it freezes when the world is paused and
## time-lapses when the world runs fast — consistent with every other animation
## in the stack. Deterministic in `(phase, abs_h)`: no randf, no real time.
static func drift(phase: float, abs_h: float) -> float:
	if is_nan(abs_h) or is_inf(abs_h):
		return 0.0
	return (sin(TAU * abs_h / DRIFT_P1_H + phase) * DRIFT_W1
		+ sin(TAU * abs_h / DRIFT_P2_H + phase * 2.7) * DRIFT_W2) * DRIFT_AMP_RAD


static func yaw_for(pos: Vector2, anchor: Vector2, phase: float,
		abs_h: float) -> float:
	return base_yaw(pos, anchor, phase) + drift(phase, abs_h)

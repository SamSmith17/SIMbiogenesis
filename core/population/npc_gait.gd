class_name NpcGait
extends RefCounted

## The cadence a walking body is DRAWN at (NPC life pass, Phase 1).
##
## At high sim speed a person's real stride rate is absurd (1440x: ~2500
## strides per real second on the crowd shader; the stick figure's playback
## caps at 12x = ~11 strides a second). Neither can be shown: the crowd's legs
## landed on a random phase every frame, and the stick figure's eased joints
## could not follow the swing and settled at its AVERAGE — both knees half
## bent, the feet trailing ~0.1 m behind the hips, the elbows bent forward —
## which read as everyone leaning forward, "pulled by the head".
##
## The same idea as the Pelton runner's display speed: the shown cadence is
## the true one up to KNEE_HZ, then saturates toward MAX_HZ, so a faster world
## still reads as faster walking but never strobes into an average.
## Pure and static: the stick figure, the crowd renderer and the rigged body
## all ask the same function.

## Below this many strides per real second the cadence is shown as it is
## (two times a normal 0.95 Hz walk: everything up to ~2x sim speed).
const KNEE_HZ := 1.9
## The fastest cadence ever drawn.
const MAX_HZ := 3.2


## Shown strides per real second for a true rate of `true_hz`.
static func display_hz(true_hz: float) -> float:
	if not (true_hz > KNEE_HZ):
		return maxf(true_hz, 0.0)
	var room := MAX_HZ - KNEE_HZ
	return KNEE_HZ + room * (1.0 - exp(-(true_hz - KNEE_HZ) / room))


## The factor that turns a true cadence into the shown one (1 below the knee).
static func display_scale(true_hz: float) -> float:
	if true_hz <= KNEE_HZ or true_hz <= 0.0:
		return 1.0
	return display_hz(true_hz) / true_hz

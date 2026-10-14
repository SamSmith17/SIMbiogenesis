class_name PlacedLightClock
extends RefCounted

## ONE effect clock for every J light: string chases, moving-head sweeps,
## lasers, strobes. Each node used to start its own timer when it was built, so
## two duplicated strings chased out of step and a row of moving heads could
## never sweep together.
##
## It is now the LIGHTS track of SimFxRate, the project-wide cosmetic clock: it
## time-lapses with the sim (sqrt of the speed multiple, capped at
## SimFxRate.FX_CAP_LIGHTS so a chase never becomes a strobe) and freezes dead
## while the sim is paused or scrubbing backwards. The OmniLights (sampled on
## the CPU at 15 Hz) and the bulb/tube/beam shaders (global uniform
## `fx_time_lights`) read the same number, so they cannot drift apart.
##
## The old per-light "Pause w/ sim" option chose between an always-running
## real track and a sim-paused one; every light now pauses with the sim, so
## the argument is accepted for compatibility and ignored.


static func now(main: Node, _pause_with_sim: bool = true) -> float:
	return SimFxRate.now(main, SimFxRate.SYS_LIGHTS)


## Selftests / harness: set the clock outright.
static func set_time(t: float) -> void:
	SimFxRate.reset(t)

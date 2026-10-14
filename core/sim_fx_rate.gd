class_name SimFxRate
extends RefCounted

## How fast COSMETIC motion runs — fire flicker and particles, crowd dance and
## sway loops, LED chases and moving-head sweeps — as a function of the sim
## clock. One curve and one set of clocks, so every system agrees:
##
##   * paused (time_scale == 0) or scrubbing BACKWARDS  -> rate 0, frozen dead;
##   * slower than real time                            -> linear slow-motion;
##   * faster than real time                            -> sqrt of the multiple,
##     capped per system.
##
## Sublinear on purpose: a 350x clock visibly LOOKS faster than a 36x one, but
## nothing animates at 350x (flames would turn to noise, a chase into a strobe,
## a dance loop into a blur). Samples: 1x -> 1, 36x -> 6, 100x -> 10,
## 350x -> 18.7 before the cap.
##
## There used to be five different "is the sim paused" tests that disagreed
## (|ts| < 1e-9, ts <= 0, ts == 0, a timeline-bar flag, an uncalled helper);
## `is_paused` is the one answer now.
##
## The clocks INTEGRATE delta x rate, so a speed change never makes a phase
## jump (multiplying TIME by a new rate would teleport every flame). They are
## advanced once per rendered frame by whoever asks first (Main pushes them as
## global shader uniforms each frame), clamped against hitches. The smoothed
## rate eases between speeds but drops to zero INSTANTLY on pause.

const FX_CAP_NPC := 12.0     # == NpcRig.MAX_PLAYBACK_RATE (bodies already used it)
const FX_CAP_FIRE := 6.0     # past ~6x flames read as noise
const FX_CAP_LIGHTS := 8.0   # chases, mover sweeps, gobo spin

const SYS_NPC := 0
const SYS_FIRE := 1
const SYS_LIGHTS := 2
const CAPS := [FX_CAP_NPC, FX_CAP_FIRE, FX_CAP_LIGHTS]
## Global shader uniform per system (declared in project.godot [shader_globals]).
const UNIFORMS := ["fx_time_npc", "fx_time_fire", "fx_time_lights"]

const REALTIME_SCALE := 1.0 / 3600.0   # time_scale is sim-HOURS per real second
const SMOOTH_TAU_S := 0.3
const MAX_STEP_S := 0.25
## Keep the clocks bounded: shader uniforms are float32, and a festival left
## running for days would otherwise quantise every loop into steps. No wrap
## point suits every loop period at once, so wrap at a large round number
## (float32 resolves ~8 ms there) and accept one phase glitch per ~2.3 real
## hours even at the 12x cap.
const WRAP_S := 100000.0

static var _t := [0.0, 0.0, 0.0]
static var _rate := [1.0, 1.0, 1.0]
static var _frame := -1
static var _last_ms := -1
static var _ts := REALTIME_SCALE
## Main, remembered by tick() so a caller with no handle on Main (the ash
## pile, a crowd renderer) can pass null and still read the live clock.
static var _main_wr: WeakRef = null


## The ONE "is the sim paused" query. A backward scrub counts: the population
## engine freezes during one, so cosmetic motion must too.
static func is_paused(main: Node) -> bool:
	return time_scale_of(main) <= 0.0


static func time_scale_of(main: Node) -> float:
	if main == null or not is_instance_valid(main):
		main = _main_wr.get_ref() as Node if _main_wr != null else null
	if main == null or not is_instance_valid(main) or not ("time_scale" in main):
		return REALTIME_SCALE
	return float(main.get("time_scale"))


## The clock's speed as a multiple of real time (1.0 = 1x).
static func multiple(time_scale: float) -> float:
	return time_scale / REALTIME_SCALE


## Pure target rate for a time scale and a cap (no smoothing).
static func target_rate(time_scale: float, cap: float) -> float:
	if not (time_scale > 0.0) or is_inf(time_scale):
		return 0.0  # paused, reversed, NaN, or the analemma "infinite" view
	var m := multiple(time_scale)
	if m <= 1.0:
		return m
	return minf(sqrt(m), cap)


## Smoothed live rate for a system (0 while paused). Advances the clocks.
static func rate(main: Node, sys: int) -> float:
	_advance(main)
	return float(_rate[sys])


## Live rate for an arbitrary cap — for callers outside the three systems.
static func rate_for_cap(main: Node, cap: float) -> float:
	return target_rate(time_scale_of(main), cap)


## The integrated cosmetic clock for a system, in seconds.
static func now(main: Node, sys: int) -> float:
	_advance(main)
	return float(_t[sys])


## Advance once per rendered frame; Main calls this and pushes the uniforms.
static func tick(main: Node) -> void:
	if main != null and (_main_wr == null or _main_wr.get_ref() != main):
		_main_wr = weakref(main)
	_advance(main)
	# The uniforms are DECLARED in project.godot [shader_globals]; registering
	# them at runtime is an error (and the list query is editor-only).
	for i in UNIFORMS.size():
		RenderingServer.global_shader_parameter_set(UNIFORMS[i], float(_t[i]))


## One frame's worth of integration given a real dt — pure enough to test.
static func step(dt: float, time_scale: float) -> void:
	_ts = time_scale
	var k := 1.0 - exp(-dt / SMOOTH_TAU_S)
	for i in CAPS.size():
		var want := target_rate(time_scale, float(CAPS[i]))
		var r: float = _rate[i]
		r = 0.0 if want <= 0.0 else lerpf(r, want, k)
		_rate[i] = r
		var t: float = _t[i] + dt * r
		if t > WRAP_S:
			t -= WRAP_S
		_t[i] = t


static func _advance(main: Node) -> void:
	var f := Engine.get_process_frames()
	if f == _frame:
		return
	_frame = f
	var ms := Time.get_ticks_msec()
	if _last_ms < 0:
		_last_ms = ms
	var dt := minf(float(ms - _last_ms) / 1000.0, MAX_STEP_S)
	_last_ms = ms
	step(dt, time_scale_of(main))


## Selftests / harness: set every clock and rate outright.
static func reset(t: float = 0.0, r: float = 1.0) -> void:
	_t = [t, t, t]
	_rate = [r, r, r]
	_frame = Engine.get_process_frames()
	_last_ms = Time.get_ticks_msec()

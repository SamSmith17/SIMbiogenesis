class_name PlacedLightClock
extends RefCounted

## ONE effect clock for every J light: string chases, moving-head sweeps,
## lasers, strobes. Each node used to start its own timer when it was built, so
## two duplicated strings chased out of step and a row of moving heads could
## never sweep together. Advanced once per rendered frame (whoever asks first),
## clamped against hitches.
##
## Two tracks: `real` always runs (LEDs keep chasing while the sim is paused,
## like real ones), `sim` stops while the world clock is frozen (the
## "Pause w/ sim" option).

const MAX_STEP_S := 0.25

static var _real := 0.0
static var _sim := 0.0
static var _last_ms := -1
static var _frame := -1


static func now(main: Node, pause_with_sim: bool) -> float:
	_advance(main)
	return _sim if pause_with_sim else _real


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
	_real += dt
	var frozen := main != null and is_instance_valid(main) and "time_scale" in main \
		and absf(float(main.get("time_scale"))) < 1e-9
	if not frozen:
		_sim += dt


## Selftests / harness: set the clock outright.
static func set_time(t: float) -> void:
	_real = t
	_sim = t
	_frame = Engine.get_process_frames()
	_last_ms = Time.get_ticks_msec()

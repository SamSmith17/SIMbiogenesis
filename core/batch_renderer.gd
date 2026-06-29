class_name BatchRenderer
extends Node

## Drives a chunked batch render of a simulated datastream into an EnergyTimeline.
##
## The "pre-render a day/week" feature: given a deterministic evaluator (a pure
## function of absolute time supplying solar/aux/load), integrate the battery
## curve over a selected range a bounded number of steps per frame so the UI
## stays responsive and can show progress. The owner (SolarUI) sets up the
## anchor + evaluator on the target EnergyTimeline, then calls start_render().

signal render_started()
signal render_progress(frac: float)
signal render_complete()

## Steps integrated per frame. 240 × (1 min/step) ≈ 4 sim-hours per frame, so a
## one-week render (~10k steps) completes in ~40 frames (<1 s) without a hitch.
const STEPS_PER_FRAME: int = 240

var _series: RefCounted = null
var _start_g: int = 0
var _target_g: int = 0
var _active: bool = false


func _ready() -> void:
	set_process(false)


func is_rendering() -> bool:
	return _active


## Begin rendering `series` (already anchored at start_abs) up to end_abs.
func start_render(series: RefCounted, start_abs: float, end_abs: float) -> void:
	if series == null:
		return
	_series = series
	_start_g = int(series.call("step_of", start_abs))
	_target_g = int(series.call("step_of", end_abs))
	_active = _target_g > _start_g
	if not _active:
		render_complete.emit()
		return
	set_process(true)
	render_started.emit()
	render_progress.emit(0.0)


func cancel() -> void:
	_active = false
	set_process(false)


## Render completion fraction in [0, 1]. 1.0 when idle.
func get_progress() -> float:
	if not _active or _series == null:
		return 1.0
	var total := maxi(1, _target_g - _start_g)
	var cur := int(_series.call("last_step")) - _start_g
	return clampf(float(cur) / float(total), 0.0, 1.0)


func _process(_delta: float) -> void:
	if not _active or _series == null:
		set_process(false)
		return
	var done: bool = bool(_series.call("fill_forward_chunk", _target_g, STEPS_PER_FRAME))
	render_progress.emit(get_progress())
	if done:
		_active = false
		set_process(false)
		render_complete.emit()

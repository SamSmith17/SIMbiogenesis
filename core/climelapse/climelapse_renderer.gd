class_name ClimelapseRenderer
extends Node

## Chunked climelapse bake: calendar keyframes then per-instance scale snapshots.

signal climelapse_started()
signal climelapse_progress(frac: float)
signal climelapse_complete()

enum Phase { KEYFRAMES, SCALE_BAKE, DONE }

const KEYFRAMES_PER_FRAME := 90
const SCALE_ENTRIES_PER_FRAME := 16000

var _series: ClimelapseSeries = null
var _scale_bake: ClimelapseScaleBake = null
var _manual_map: VegetationInstanceMap = null
var _auto_map: VegetationInstanceMap = null
var _growth_settings: Dictionary = {}
var _initial_growth_clock := 0.0
var _phase := Phase.DONE
var _bake_kf := 0
var _bake_layer := 0
var _bake_entry := 0
var _bake_manual: PackedFloat32Array = PackedFloat32Array()
var _bake_auto: PackedFloat32Array = PackedFloat32Array()


func _ready() -> void:
	set_process(false)


func is_rendering() -> bool:
	return _phase != Phase.DONE


func get_progress() -> float:
	if _phase == Phase.DONE:
		return 1.0
	if _series == null:
		return 0.0
	if _phase == Phase.KEYFRAMES:
		var span := maxf(1.0, _series.end_abs_h - _series.start_abs_h)
		var last_abs := _series.start_abs_h
		if _series.keyframe_count() > 0:
			last_abs = float((_series.keyframes.back() as Dictionary).get("abs_h", last_abs))
		return clampf((last_abs - _series.start_abs_h) / span, 0.0, 0.85)
	var total_entries := 0
	if _manual_map != null:
		total_entries += _manual_map.entry_count() * _series.keyframe_count()
	if _auto_map != null:
		total_entries += _auto_map.entry_count() * _series.keyframe_count()
	if total_entries <= 0:
		return 1.0
	var done := 0
	if _manual_map != null and _manual_map.entry_count() > 0:
		if _bake_layer == 0:
			done += _bake_kf * _manual_map.entry_count() + _bake_entry
		else:
			done += (_bake_kf + 1) * _manual_map.entry_count()
	if _auto_map != null and _auto_map.entry_count() > 0:
		var manual_total := 0
		if _manual_map != null:
			manual_total = _manual_map.entry_count() * _series.keyframe_count()
		if _bake_layer == 1 or (_bake_layer == 0 and \
				(_manual_map == null or _manual_map.entry_count() == 0)):
			done += manual_total + _bake_kf * _auto_map.entry_count() + _bake_entry
		elif _bake_layer == 0:
			done += _bake_kf * _auto_map.entry_count()
	return clampf(0.85 + 0.15 * float(done) / float(total_entries), 0.0, 1.0)


func start_render(series: ClimelapseSeries, scale_bake: ClimelapseScaleBake,
		manual_map: VegetationInstanceMap, auto_map: VegetationInstanceMap,
		growth_settings: Dictionary, initial_growth_clock_h: float) -> void:
	if series == null or scale_bake == null:
		return
	if series.end_abs_h <= series.start_abs_h:
		climelapse_complete.emit()
		return
	_series = series
	_scale_bake = scale_bake
	_manual_map = manual_map
	_auto_map = auto_map
	_growth_settings = growth_settings.duplicate(true)
	_initial_growth_clock = initial_growth_clock_h
	_phase = Phase.KEYFRAMES
	_bake_kf = 0
	_bake_layer = 0
	_bake_entry = 0
	set_process(true)
	climelapse_started.emit()
	climelapse_progress.emit(0.0)


func cancel() -> void:
	_phase = Phase.DONE
	set_process(false)


func _process(_delta: float) -> void:
	if _phase == Phase.KEYFRAMES:
		_process_keyframes()
	elif _phase == Phase.SCALE_BAKE:
		_process_scale_bake()
	else:
		set_process(false)


func _process_keyframes() -> void:
	_series.fill_forward_chunk(_initial_growth_clock, KEYFRAMES_PER_FRAME)
	if _series.is_complete():
		_begin_scale_bake()
	climelapse_progress.emit(get_progress())


func _begin_scale_bake() -> void:
	var kf := _series.keyframe_count()
	var mc := _manual_map.entry_count() if _manual_map != null else 0
	var ac := _auto_map.entry_count() if _auto_map != null else 0
	_scale_bake.clear()
	_scale_bake.keyframe_count = kf
	_scale_bake.manual_entry_count = mc
	_scale_bake.auto_entry_count = ac
	if mc > 0:
		_bake_manual.resize(mc * kf)
	if ac > 0:
		_bake_auto.resize(ac * kf)
	_bake_kf = 0
	_bake_entry = 0
	# Layer 0 = manual, 1 = auto. Skip straight to auto when there is no manual map.
	_bake_layer = 0 if mc > 0 else 1
	if mc == 0 and ac == 0:
		_finish()
		return
	_phase = Phase.SCALE_BAKE


func _process_scale_bake() -> void:
	var budget := SCALE_ENTRIES_PER_FRAME
	var st := _growth_settings.duplicate(true)
	var mc := _manual_map.entry_count() if _manual_map != null else 0
	var ac := _auto_map.entry_count() if _auto_map != null else 0
	var kf_total := _series.keyframe_count()
	while budget > 0 and _bake_kf < kf_total:
		st["growth_now_h"] = _series.growth_clock_at(_bake_kf)
		if _bake_layer == 0:
			if mc > 0:
				while _bake_entry < mc and budget > 0:
					_bake_manual[_bake_kf * mc + _bake_entry] = \
							_manual_map.scale_mult_at(_bake_entry, st)
					_bake_entry += 1
					budget -= 1
				if _bake_entry < mc:
					break
			_bake_entry = 0
			_bake_layer = 1
			if ac == 0:
				_bake_kf += 1
				_bake_layer = 0
			continue
		# Auto layer (also entered directly when mc == 0).
		if ac > 0:
			while _bake_entry < ac and budget > 0:
				_bake_auto[_bake_kf * ac + _bake_entry] = \
						_auto_map.scale_mult_at(_bake_entry, st)
				_bake_entry += 1
				budget -= 1
			if _bake_entry < ac:
				break
		_bake_entry = 0
		_bake_layer = 0
		_bake_kf += 1
	if _bake_kf >= kf_total:
		_scale_bake.manual_scales = _bake_manual
		_scale_bake.auto_scales = _bake_auto
		_finish()
	climelapse_progress.emit(get_progress())


func _finish() -> void:
	_phase = Phase.DONE
	set_process(false)
	climelapse_progress.emit(1.0)
	climelapse_complete.emit()

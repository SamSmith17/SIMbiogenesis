class_name AssetPackProgress
extends RefCounted

## Progress + cancel shared between a pack job on a worker thread and the UI
## polling it from _process. Every field goes through the mutex.

var _m := Mutex.new()
var _done := 0
var _total := 1
var _label := ""
var _cancel := false


func set_total(bytes: int) -> void:
	_m.lock()
	_total = maxi(bytes, 1)
	_m.unlock()


func advance(bytes: int, label: String = "") -> void:
	_m.lock()
	_done += bytes
	if not label.is_empty():
		_label = label
	_m.unlock()


func set_label(label: String) -> void:
	_m.lock()
	_label = label
	_m.unlock()


func cancel() -> void:
	_m.lock()
	_cancel = true
	_m.unlock()


func cancelled() -> bool:
	_m.lock()
	var c := _cancel
	_m.unlock()
	return c


## {fraction, done, total, label}
func snapshot() -> Dictionary:
	_m.lock()
	var d := {"fraction": clampf(float(_done) / float(_total), 0.0, 1.0), "done": _done,
		"total": _total, "label": _label}
	_m.unlock()
	return d

class_name CspLabOptimizer
extends RefCounted

## Finds a better concentrator by moving a few of its numbers: a coordinate
## search with golden-section steps on each chosen parameter in turn, two
## passes (the second narrowed round the first's answer), maximising one
## objective (CspLabSpec.OBJECTIVES). Every evaluation traces the same rays
## (a fixed seed — common random numbers), so two specs are compared on the
## same sunlight and the objective is a deterministic function of the spec.
##
## Stepped: `step()` runs one evaluation, so the modal can spread a search
## over frames and show its progress.
##
##   var opt := CspLabOptimizer.new(spec, [["receiver", "size_m", 0.01, 0.3]], "net_kw")
##   while not opt.done: opt.step()
##   opt.best_spec, opt.best_value, opt.start_value

const PHI := 0.6180339887
const ITERS := 9
const PASSES := 2

var objective := "net_kw"
var params: Array = []
var rays := 1500
var done := false
var start_value := 0.0
var best_value := -INF
var best_spec: Dictionary = {}
var evals := 0
var history: Array = []

var _pi := 0
var _pass := 0
var _it := 0
var _lo := 0.0
var _hi := 0.0
var _x1 := 0.0
var _x2 := 0.0
var _f1 := NAN
var _f2 := NAN
var _started := false


func _init(spec: Dictionary, p: Array, obj: String = "net_kw", ray_count: int = 1500) -> void:
	best_spec = CspLabSpec.resolve(spec)
	params = p
	objective = obj
	rays = ray_count
	if params.is_empty():
		done = true


static func value_of(d: Dictionary, obj: String) -> float:
	match obj:
		"optical":
			return float(d["eta_opt"])
		"suns":
			return float(d["C_mean"])
		"kw_per_m2":
			return float(d["q_net_kw"]) / maxf(float(d["A_ap"]), 1e-9)
	# Net heat (absorbed − losses), allowed below zero so a search started
	# where the receiver loses more than it gets still has a slope to climb.
	return float(d["q_net_kw"])


func evaluate(spec: Dictionary) -> float:
	evals += 1
	var d := CspLabDesign.solve(spec, {"rays": rays, "light": true, "no_cache": true})
	return value_of(d, objective)


func _with(x: float) -> Dictionary:
	var p: Array = params[_pi]
	var s := best_spec.duplicate(true)
	(s[str(p[0])] as Dictionary)[str(p[1])] = x
	return s


func _cur() -> float:
	var p: Array = params[_pi]
	return float((best_spec[str(p[0])] as Dictionary)[str(p[1])])


func progress() -> float:
	if done:
		return 1.0
	var per := float(ITERS + 2)
	var total := per * params.size() * PASSES
	return clampf((float(_pass) * params.size() * per + float(_pi) * per + float(_it)) / maxf(total, 1.0), 0.0, 1.0)


## One evaluation. Returns true once the search is finished.
func step() -> bool:
	if done:
		return true
	if not _started:
		_started = true
		start_value = evaluate(best_spec)
		best_value = start_value
		_begin_param()
		return false
	if is_nan(_f1):
		_f1 = evaluate(_with(_x1))
		_note(_x1, _f1)
		return false
	if is_nan(_f2):
		_f2 = evaluate(_with(_x2))
		_note(_x2, _f2)
		return false
	# Golden-section step toward the larger value.
	if _f1 > _f2:
		_hi = _x2
		_x2 = _x1
		_f2 = _f1
		_x1 = _hi - PHI * (_hi - _lo)
		_f1 = evaluate(_with(_x1))
		_note(_x1, _f1)
	else:
		_lo = _x1
		_x1 = _x2
		_f1 = _f2
		_x2 = _lo + PHI * (_hi - _lo)
		_f2 = evaluate(_with(_x2))
		_note(_x2, _f2)
	_it += 1
	if _it >= ITERS:
		_next_param()
	return done


func _note(x: float, f: float) -> void:
	var p: Array = params[_pi]
	history.append({"param": "%s.%s" % [str(p[0]), str(p[1])], "x": x, "value": f})
	if f > best_value:
		best_value = f
		(best_spec[str(p[0])] as Dictionary)[str(p[1])] = x


func _begin_param() -> void:
	var p: Array = params[_pi]
	var lo := float(p[2])
	var hi := float(p[3])
	if _pass > 0:
		var span := (hi - lo) * 0.2
		var c := _cur()
		lo = maxf(float(p[2]), c - span)
		hi = minf(float(p[3]), c + span)
	_lo = lo
	_hi = hi
	_x1 = _hi - PHI * (_hi - _lo)
	_x2 = _lo + PHI * (_hi - _lo)
	_f1 = NAN
	_f2 = NAN
	_it = 0


func _next_param() -> void:
	_pi += 1
	if _pi >= params.size():
		_pi = 0
		_pass += 1
		if _pass >= PASSES:
			done = true
			return
	_begin_param()

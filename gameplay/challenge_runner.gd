class_name ChallengeRunner
extends Node

## Systems-graph challenge lifecycle (Main child).

signal challenge_started(id: String, def: ChallengeDef)
signal challenge_tick(id: String, metrics: Dictionary, elapsed_h: float)
signal challenge_won(id: String, result: Dictionary)
signal challenge_failed(id: String, reason: String)
signal challenge_aborted(id: String)
signal challenge_toast(message: String, level: int)

const HighScoreStoreScript := preload("res://core/high_score_store.gd")
const ClosureMetricsScript := preload("res://system_graph/closure_metrics.gd")
const ChallengeCatalogScript := preload("res://gameplay/challenge_catalog.gd")

const EVAL_INTERVAL_S := 1.0
const TOAST_INFO := 0
const TOAST_OK := 1
const TOAST_WARN := 2
const TOAST_ERROR := 3

var _def: ChallengeDef = null
var _active := false
var _start_abs: float = -1.0
var _eval_acc: float = 0.0
var _ac_down_hours: float = 0.0
var _last_eval_abs: float = -1.0
var _last_metrics: Dictionary = {}
var _last_status: String = "idle"


func _ready() -> void:
	set_process(false)
	add_to_group("challenge_runner")


func is_active() -> bool:
	return _active and _def != null


func active_challenge_id() -> String:
	return _def.id if _def != null else ""


func active_def() -> ChallengeDef:
	return _def


func last_metrics() -> Dictionary:
	return _last_metrics.duplicate(true)


func last_status() -> String:
	return _last_status


func catalog() -> Array:
	return ChallengeCatalogScript.all_challenges()


func start_challenge_id(challenge_id: String) -> bool:
	var def: ChallengeDef = ChallengeCatalogScript.by_id(challenge_id)
	if def == null:
		challenge_toast.emit("Unknown challenge: %s" % challenge_id, TOAST_ERROR)
		return false
	return start_challenge(def)


func start_challenge(def: ChallengeDef) -> bool:
	if def == null or def.id.is_empty():
		return false
	if _active:
		abort_challenge()
	_def = def
	_active = true
	_ac_down_hours = 0.0
	_eval_acc = 0.0
	_last_status = "running"
	_last_metrics.clear()

	var main_node := _main()
	if main_node == null:
		_fail_internal("no_main")
		return false

	_start_abs = _resolve_start_abs(main_node, def)
	if main_node.has_method("set_absolute_hours"):
		main_node.call("set_absolute_hours", _start_abs)
	_last_eval_abs = _start_abs

	var td: Node = get_node_or_null("/root/TimeDirector")
	if td != null and td.has_method("set_explicit_mode"):
		td.call("set_explicit_mode", 2)

	set_process(true)
	challenge_started.emit(def.id, def)
	challenge_toast.emit("Challenge started: %s" % def.title, TOAST_INFO)
	var gv := _graph_view()
	if gv != null and gv.has_method("try_seed_puzzle_starter"):
		gv.call("try_seed_puzzle_starter", def.occupants)
	_evaluate(true)
	return true


func abort_challenge() -> void:
	if not _active:
		return
	var cid := active_challenge_id()
	_active = false
	_last_status = "aborted"
	set_process(false)
	challenge_aborted.emit(cid)
	challenge_toast.emit("Challenge aborted", TOAST_WARN)
	_def = null


func evaluate_now() -> Dictionary:
	return _evaluate(false)


func _process(delta: float) -> void:
	if not _active or _def == null:
		return
	_eval_acc += delta
	if _eval_acc < EVAL_INTERVAL_S:
		return
	_eval_acc = 0.0
	_evaluate(true)


func _evaluate(emit_tick: bool) -> Dictionary:
	var main_node := _main()
	var result := {
		"status": "idle",
		"elapsed_h": 0.0,
		"remaining_h": 0.0,
		"metrics": {},
		"reason": "",
	}
	if not _active or _def == null or main_node == null:
		return result

	var abs_h := _abs_hours(main_node)
	var elapsed := maxf(abs_h - _start_abs, 0.0)
	var dt_h := 0.0
	if _last_eval_abs >= 0.0:
		dt_h = maxf(abs_h - _last_eval_abs, 0.0)
	_last_eval_abs = abs_h

	var metrics := _closure_metrics()
	_last_metrics = metrics
	result["elapsed_h"] = elapsed
	result["remaining_h"] = maxf(_def.duration_hours - elapsed, 0.0)
	result["metrics"] = metrics

	if emit_tick:
		challenge_tick.emit(_def.id, metrics, elapsed)

	if _def.fail_on_starvation and bool(metrics.get("any_starved", false)):
		return _fail_result(result, "starvation")

	if not _def.fail_on_kinds.is_empty():
		var channels: Dictionary = metrics.get("channels", {}) as Dictionary
		for kind: String in _def.fail_on_kinds:
			var ch: Dictionary = channels.get(kind, {}) as Dictionary
			if str(ch.get("status", "")) == ClosureMetricsScript.STATUS_CRITICAL \
					or bool(ch.get("starved", false)):
				return _fail_result(result, "stockout_%s" % kind)

	if _def.max_ac_down_hours >= 0.0 and _def.track_ac_availability:
		if not _ac_available():
			_ac_down_hours += dt_h
		if _ac_down_hours > _def.max_ac_down_hours + 1e-6:
			return _fail_result(result, "ac_down")

	if elapsed + 1e-6 < _def.duration_hours:
		result["status"] = "running"
		_last_status = "running"
		return result

	return _check_win(result, metrics)


func _check_win(result: Dictionary, metrics: Dictionary) -> Dictionary:
	var channels: Dictionary = metrics.get("channels", {}) as Dictionary
	if _def.min_mean_closure_pct > 0.0:
		if float(metrics.get("mean_closure_pct", 0.0)) + 1e-6 < _def.min_mean_closure_pct:
			return _fail_result(result, "closure_low")
	if _def.min_water_closure_pct > 0.0:
		var wch: Dictionary = channels.get("water", {}) as Dictionary
		if float(wch.get("closure_pct", 0.0)) + 1e-6 < _def.min_water_closure_pct:
			return _fail_result(result, "water_closure_low")
	if _def.min_autonomy_days > 0.0:
		if float(metrics.get("min_autonomy_days", 0.0)) + 1e-6 < _def.min_autonomy_days:
			return _fail_result(result, "autonomy_low")
	if _def.require_no_starvation and bool(metrics.get("any_starved", false)):
		return _fail_result(result, "starvation")

	var score := float(metrics.get("score", 0.0))
	var lat_lon := _lat_lon()
	var best := HighScoreStoreScript.record_if_best(
			float(lat_lon.get("lat", 0.0)),
			float(lat_lon.get("lon", 0.0)),
			_def.id, score, {
				"mean_closure_pct": float(metrics.get("mean_closure_pct", 0.0)),
				"autonomy_person_days": float(metrics.get("autonomy_person_days", 0.0)),
				"elapsed_h": float(result.get("elapsed_h", 0.0)),
			})
	result["status"] = "won"
	result["score"] = score
	result["new_best"] = best > 0.0
	_last_status = "won"
	_active = false
	set_process(false)
	challenge_won.emit(_def.id, result)
	challenge_toast.emit(
			"Challenge complete: %s (score %.0f)" % [_def.title, score], TOAST_OK)
	return result


func _fail_result(result: Dictionary, reason: String) -> Dictionary:
	result["status"] = "failed"
	result["reason"] = reason
	_fail_internal(reason)
	return result


func _fail_internal(reason: String) -> void:
	if not _active:
		return
	var cid := active_challenge_id()
	_active = false
	_last_status = "failed"
	set_process(false)
	challenge_failed.emit(cid, reason)
	challenge_toast.emit("Challenge failed — %s" % ChallengeDef.reason_label(reason), TOAST_ERROR)


func _resolve_start_abs(main_node: Node, def: ChallengeDef) -> float:
	var now := _abs_hours(main_node)
	if def.use_driest_week:
		var driest := find_driest_week_start(main_node)
		if driest >= 0.0:
			return driest
	if def.start_month > 0 and def.start_day > 0:
		var yr := int(main_node.get("year")) if main_node.get("year") != null else 2024
		if main_node.has_method("get_absolute_hours") and "clock" in main_node:
			var clk: Variant = main_node.get("clock")
			if clk != null and clk.has_method("get_absolute_hours"):
				var saved_y: int = int(main_node.get("year"))
				var saved_m: int = int(main_node.get("month"))
				var saved_d: int = int(main_node.get("day"))
				var saved_t: float = float(main_node.get("day_time"))
				main_node.set("year", yr)
				main_node.set("month", def.start_month)
				main_node.set("day", def.start_day)
				main_node.set("day_time", 0.0)
				var target := float(main_node.call("get_absolute_hours"))
				main_node.set("year", saved_y)
				main_node.set("month", saved_m)
				main_node.set("day", saved_d)
				main_node.set("day_time", saved_t)
				return target
	return now


## Scan cached weather year for the driest contiguous 7-day precip window.
## Returns absolute hours at window start, or -1 if weather unavailable.
static func find_driest_week_start(main_node: Node) -> float:
	if main_node == null:
		return -1.0
	var tree: SceneTree = main_node.get_tree()
	if tree == null:
		return -1.0
	var ws: Node = tree.root.get_node_or_null("WeatherService")
	if ws == null or not ws.has_method("has_data") or not bool(ws.call("has_data")):
		return -1.0
	if not ws.has_method("sample"):
		return -1.0

	var year := int(main_node.get("year")) if main_node.get("year") != null else 2024
	if ws.has_method("effective_year"):
		year = int(ws.call("effective_year", year))

	var day_totals: PackedFloat32Array = PackedFloat32Array()
	day_totals.resize(365)
	var md_index: Array = []
	md_index.resize(365)
	var di := 0
	for month in range(1, 13):
		var dim := _days_in_month(month, year)
		for day in range(1, dim + 1):
			if di >= 365:
				break
			var day_sum := 0.0
			for hour in range(0, 24):
				var v: float = float(ws.call("sample", "precipitation", month, day, float(hour)))
				if is_nan(v) or v < 0.0:
					v = 0.0
				day_sum += v
			day_totals[di] = day_sum
			md_index[di] = {"month": month, "day": day}
			di += 1
	var n := di
	if n < 7:
		return -1.0

	var best_i := 0
	var best_sum := INF
	var window := 0.0
	for i in range(7):
		window += day_totals[i]
	best_sum = window
	for i in range(7, n):
		window += day_totals[i] - day_totals[i - 7]
		if window < best_sum:
			best_sum = window
			best_i = i - 6

	var md: Dictionary = md_index[best_i] as Dictionary
	var saved_y: int = int(main_node.get("year"))
	var saved_m: int = int(main_node.get("month"))
	var saved_d: int = int(main_node.get("day"))
	var saved_t: float = float(main_node.get("day_time"))
	main_node.set("year", year)
	main_node.set("month", int(md.get("month", 1)))
	main_node.set("day", int(md.get("day", 1)))
	main_node.set("day_time", 0.0)
	var abs_h := float(main_node.call("get_absolute_hours"))
	main_node.set("year", saved_y)
	main_node.set("month", saved_m)
	main_node.set("day", saved_d)
	main_node.set("day_time", saved_t)
	return abs_h


static func _days_in_month(month: int, year: int) -> int:
	match month:
		1, 3, 5, 7, 8, 10, 12:
			return 31
		4, 6, 9, 11:
			return 30
		2:
			var leap := (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0)
			return 29 if leap else 28
	return 30


func _main() -> Node:
	var p := get_parent()
	if p != null and p.has_method("get_absolute_hours"):
		return p
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("Main")


func _abs_hours(main_node: Node) -> float:
	if main_node != null and main_node.has_method("get_absolute_hours"):
		return float(main_node.call("get_absolute_hours"))
	return 0.0


func _lat_lon() -> Dictionary:
	var main_node := _main()
	if main_node == null:
		return {"lat": 0.0, "lon": 0.0}
	return {
		"lat": float(main_node.get("latitude")) if main_node.get("latitude") != null else 0.0,
		"lon": float(main_node.get("longitude")) if main_node.get("longitude") != null else 0.0,
	}


func _graph_view() -> Node:
	var main_node := _main()
	if main_node == null:
		return null
	var gv: Node = main_node.get_node_or_null("UILayer/SystemGraphView")
	if gv == null:
		gv = main_node.find_child("SystemGraphView", true, false)
	return gv


func _closure_metrics() -> Dictionary:
	var gv := _graph_view()
	if gv != null and gv.has_method("compute_closure_metrics"):
		return gv.call("compute_closure_metrics") as Dictionary
	return ClosureMetricsScript.compute(null, null, null, 0.0)


func _ac_available() -> bool:
	var main_node := _main()
	if main_node == null:
		return true
	var su: Node = main_node.get_node_or_null("UILayer/SolarUI")
	if su == null:
		su = main_node.find_child("SolarUI", true, false)
	if su != null and su.has_method("is_ac_output_enabled"):
		return bool(su.call("is_ac_output_enabled"))
	if su != null and su.has_method("is_power_available"):
		return bool(su.call("is_power_available"))
	return true

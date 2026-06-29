class_name LoadCalibrator
extends Node
## Samples a load's live HA power readings over a user-defined window and
## computes a simplified electrical-behavior curve for the simulation core.
##
## Why polling, not signal-driven?
##   HA only emits state_changed events when a sensor's value actually changes.
##   For a steady-state load (e.g. an LED at a fixed 36 W) no events arrive
##   between the initial subscribe response and the next genuine variation.
##   Relying on ha_live_updated therefore yields an empty buffer.  Instead we
##   poll specs.ha_live[role].value every _POLL_HZ ticks — that cache is
##   always up-to-date because HAEntityLinker writes to it on every push.
##
## Supported load types:
##   resistive   – assumes a single steady-state wattage (heater, LEDs, kettle)
##   inductive   – two-phase: surge (motor inrush) then steady run wattage
##                 (fridges, pumps, compressors)
##   battery     – constant charge wattage until the internal battery is full,
##                 then a near-zero idle draw (phones, laptops, EUCs, BMSes)
##   batch       – the whole sample window represents one "batch" of work
##                 (one cup of coffee, one wash cycle).  Energy / duration
##                 are recorded so the sim can replay the batch on demand.
##   unknown     – record raw stats only (min/avg/max).
##
## Calibration data is written back to the graph item's specs as:
##   specs.load_type        : String
##   specs.load_calibration : Dictionary  (see _finalize_*)
## The mean steady-state wattage is also pushed into specs.avg_watts so the
## existing simulation pathways immediately reflect calibrated behavior.

signal progress(remaining_s: float, samples: int, current_w: float, avg_w: float, peak_w: float)
signal completed(item_id: String, results: Dictionary)
signal cancelled(item_id: String)

const _POLL_HZ           := 5.0    # samples per second (200 ms cadence)
const _MAX_TRACE_SAMPLES := 600    # downsampled curve stored in result
const _SURGE_RATIO       := 1.5    # sample > run_avg × 1.5 ⇒ counted as surge
const _SURGE_MIN_DELTA_W := 50.0   # surge must exceed run by ≥ 50 W to count
const _IDLE_THRESHOLD_W  := 5.0    # below this is treated as battery-full / off

var _model:     GraphModel = null
var _ha_linker: Node       = null
var _ha_client: Node       = null

var _running:    bool   = false
var _item_id:    String = ""
var _power_role: String = "power"   # which ha_links role to read (default: power)
var _switch_eid: String = ""        # optional: HA switch entity to flip on/off
var _load_type:  String = "unknown"
var _duration_s: float  = 30.0
var _capacity_wh: float = 0.0       # battery only
var _batch_output: String = ""      # batch only — free-form description
var _batch_count:  float = 1.0      # batch only — units produced

var _started_at: float = 0.0
var _next_poll_t: float = 0.0
var _samples:    Array = []         # Array of {t: float, w: float}
var _last_w:     float = 0.0
var _sum_w:      float = 0.0
var _peak_w:     float = 0.0

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func setup(model: GraphModel, ha_linker: Node) -> void:
	_model = model
	_ha_linker = ha_linker


func is_running() -> bool:
	return _running


func current_item_id() -> String:
	return _item_id


## Returns a reference to the running sample buffer.  Caller must not mutate it.
## Each entry is a Dictionary {t: float (seconds since start), w: float (watts)}.
func get_samples() -> Array:
	return _samples


func get_duration_s() -> float:
	return _duration_s


func start(opts: Dictionary) -> bool:
	if _running:
		return false
	_item_id      = str(opts.get("item_id", ""))
	_load_type    = str(opts.get("load_type", "unknown"))
	_duration_s   = maxf(1.0, float(opts.get("duration_s", 30.0)))
	_power_role   = str(opts.get("power_role", "power"))
	_switch_eid   = str(opts.get("switch_entity", ""))
	_capacity_wh  = float(opts.get("capacity_wh", 0.0))
	_batch_output = str(opts.get("batch_output", ""))
	_batch_count  = maxf(0.001, float(opts.get("batch_count", 1.0)))
	if _item_id.is_empty() or _model == null:
		return false
	if _model.get_item(_item_id).is_empty():
		return false

	_samples.clear()
	_sum_w   = 0.0
	_peak_w  = 0.0
	_last_w  = 0.0
	_started_at  = Time.get_ticks_msec() / 1000.0
	_next_poll_t = 0.0
	_running = true

	_resolve_ha_client()
	if not _switch_eid.is_empty() and _ha_client != null \
			and _ha_client.has_method("call_service"):
		# force=true: calibration is an explicit user action; the SimMode
		# gate would otherwise suppress this in simulate mode.
		_ha_client.call_service("switch", "turn_on", _switch_eid, {}, true)

	# Seed an immediate sample so the graph has something to show on tick 0.
	_poll_sample()

	set_process(true)
	return true


func cancel() -> void:
	if not _running:
		return
	_running = false
	set_process(false)
	cancelled.emit(_item_id)


# ---------------------------------------------------------------------------
# Tick loop
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if not _running:
		return
	var elapsed := Time.get_ticks_msec() / 1000.0 - _started_at
	if elapsed >= _next_poll_t:
		_next_poll_t = elapsed + 1.0 / _POLL_HZ
		_poll_sample()
	var avg := _sum_w / float(maxi(_samples.size(), 1))
	var remaining := maxf(0.0, _duration_s - elapsed)
	progress.emit(remaining, _samples.size(), _last_w, avg, _peak_w)
	if elapsed >= _duration_s:
		_finish()


## Read the current cached HA value for the configured power role and append it
## as a sample.  Always succeeds (writes 0 W if no live cache yet) so the
## sample buffer is dense and evenly-timed regardless of HA push frequency.
func _poll_sample() -> void:
	if _model == null or _item_id.is_empty():
		return
	var item := _model.get_item(_item_id)
	if item.is_empty():
		return
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var live: Dictionary  = specs.get("ha_live", {}) as Dictionary
	var entry: Dictionary = (live.get(_power_role, {}) as Dictionary)
	var w: float = float(entry.get("value", 0.0))
	var t: float = Time.get_ticks_msec() / 1000.0 - _started_at
	_samples.append({"t": t, "w": w})
	_last_w = w
	_sum_w += w
	if w > _peak_w:
		_peak_w = w


func _finish() -> void:
	_running = false
	set_process(false)
	var results := _finalize()
	# Write calibration into the graph item.
	if _model != null and not _item_id.is_empty():
		var item := _model.get_item(_item_id)
		if not item.is_empty():
			var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			specs["load_type"]        = _load_type
			specs["load_calibration"] = results
			# Push the headline numbers into the existing sim fields.
			if results.has("avg_w"):
				specs["avg_watts"] = float(results["avg_w"])
			if results.has("peak_w"):
				specs["max_watts"] = maxf(float(specs.get("max_watts", 0.0)),
					float(results["peak_w"]))
			_model.update_item(_item_id, {"specs": specs})
	completed.emit(_item_id, results)


# ---------------------------------------------------------------------------
# Per-type curve fitting
# ---------------------------------------------------------------------------

func _finalize() -> Dictionary:
	var n: int = _samples.size()
	var min_w :=  INF
	var max_w := -INF
	var sum   := 0.0
	for s_v: Variant in _samples:
		var s: Dictionary = s_v
		var w: float = float(s.get("w", 0.0))
		sum += w
		if w < min_w: min_w = w
		if w > max_w: max_w = w
	if n == 0:
		min_w = 0.0
		max_w = 0.0
	var avg: float = sum / float(maxi(n, 1))

	var base: Dictionary = {
		"type":          _load_type,
		"duration_s":    _duration_s,
		"sample_count":  n,
		"min_w":         min_w if n > 0 else 0.0,
		"max_w":         max_w if n > 0 else 0.0,
		"avg_w":         avg,
		"peak_w":        max_w if n > 0 else 0.0,
		"calibrated_at": int(Time.get_unix_time_from_system()),
		"trace":         _downsample_trace(),
	}

	match _load_type:
		"resistive":
			# Single steady value — average is the model.
			base["steady_w"] = avg
		"inductive":
			# Split samples into "surge" vs "run" buckets.
			# Heuristic: anything below max × 0.7 contributes to the run-state
			# average; surge is anything > run × _SURGE_RATIO and over the
			# absolute floor.
			var run_sum := 0.0
			var run_cnt := 0
			for s_v2: Variant in _samples:
				var s2: Dictionary = s_v2
				if float(s2.get("w", 0.0)) <= max_w * 0.7:
					run_sum += float(s2.get("w", 0.0))
					run_cnt += 1
			var run_w: float = run_sum / float(maxi(run_cnt, 1))
			var surge_thr := maxf(run_w * _SURGE_RATIO, run_w + _SURGE_MIN_DELTA_W)
			var surge_first_t := -1.0
			var surge_last_t  := -1.0
			var surge_peak    := 0.0
			for s_v3: Variant in _samples:
				var s3: Dictionary = s_v3
				var w: float = float(s3.get("w", 0.0))
				if w >= surge_thr:
					if surge_first_t < 0.0:
						surge_first_t = float(s3.get("t", 0.0))
					surge_last_t = float(s3.get("t", 0.0))
					if w > surge_peak:
						surge_peak = w
			base["run_w"]            = run_w
			base["surge_w"]          = surge_peak if surge_peak > 0.0 else max_w
			base["surge_duration_s"] = maxf(0.0, surge_last_t - surge_first_t)
			base["had_surge"]        = surge_first_t >= 0.0
		"battery":
			# Average non-idle wattage = charge rate.  Capacity → ETA.
			var charge_sum := 0.0
			var charge_cnt := 0
			for s_v4: Variant in _samples:
				var s4: Dictionary = s_v4
				var w4 := float(s4.get("w", 0.0))
				if w4 > _IDLE_THRESHOLD_W:
					charge_sum += w4
					charge_cnt += 1
			var charge_w: float = charge_sum / float(maxi(charge_cnt, 1))
			base["charge_w"]   = charge_w
			base["capacity_wh"] = _capacity_wh
			if charge_w > 0.0 and _capacity_wh > 0.0:
				base["estimated_full_s"] = (_capacity_wh / charge_w) * 3600.0
			else:
				base["estimated_full_s"] = 0.0
		"batch":
			# Energy = ∫ p dt (W·s) → /3600 → Wh.  Duration = sample window.
			var energy_ws := 0.0
			for i: int in range(1, n):
				var pa: float = float(_samples[i - 1].get("w", 0.0))
				var pb: float = float(_samples[i].get("w", 0.0))
				var ta: float = float(_samples[i - 1].get("t", 0.0))
				var tb: float = float(_samples[i].get("t", 0.0))
				energy_ws += 0.5 * (pa + pb) * maxf(0.0, tb - ta)
			var batch_wh: float = energy_ws / 3600.0
			base["batch_energy_wh"]  = batch_wh
			base["batch_duration_s"] = _duration_s
			base["batch_output"]     = _batch_output
			base["batch_count"]      = _batch_count
			base["wh_per_unit"]      = batch_wh / _batch_count
		_:
			pass

	return base


## Downsample to at most _MAX_TRACE_SAMPLES evenly-spaced points so the curve
## can be saved with the calibration without bloating the save file.  Each
## bucket is averaged.  Result format: Array of [t, w] pairs.
func _downsample_trace() -> Array:
	var n: int = _samples.size()
	if n == 0:
		return []
	if n <= _MAX_TRACE_SAMPLES:
		var raw: Array = []
		for s_v: Variant in _samples:
			var s: Dictionary = s_v
			raw.append([float(s.get("t", 0.0)), float(s.get("w", 0.0))])
		return raw
	var bucket_n: int = int(ceil(float(n) / float(_MAX_TRACE_SAMPLES)))
	var out: Array = []
	var i := 0
	while i < n:
		var end := mini(i + bucket_n, n)
		var sum_t := 0.0
		var sum_w := 0.0
		var cnt := 0
		for j in range(i, end):
			sum_t += float(_samples[j].get("t", 0.0))
			sum_w += float(_samples[j].get("w", 0.0))
			cnt += 1
		out.append([sum_t / float(cnt), sum_w / float(cnt)])
		i = end
	return out


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _resolve_ha_client() -> void:
	if is_instance_valid(_ha_client):
		return
	var tr := get_tree()
	if tr == null:
		return
	_ha_client = tr.root.get_node_or_null("HAClient")
	if is_instance_valid(_ha_client):
		return
	for scene_child in tr.root.get_children():
		var candidate := scene_child.get_node_or_null("HAClient")
		if candidate != null:
			_ha_client = candidate
			return

extends Node

## ExtremeWeather — resolves which extreme-weather hazards are happening at any
## instant, as a PURE FUNCTION of absolute hours.
##
## Why not a CrisisEvent subclass. crisis_events/crisis_event_manager.gd is a
## stateful realtime FSM: it rolls triggers on real seconds and PAUSES every
## event whenever time_scale differs from 1x realtime (see its REALTIME_SCALE).
## That is right for a fire the player is standing next to, and wrong for
## weather — a three-day smoke event cannot blink out because the player fast-
## forwarded, and it must survive scrubbing the timeline backwards.
##
## This project's sun, moon, sky and weather are already pure functions of
## CelestialClock.get_absolute_hours(), which is exactly why the timeline scrubs
## in both directions for free. Extreme weather joins them: nothing is stored
## between frames, so replaying, scrubbing and prebaked challenge renders all
## agree by construction rather than by careful bookkeeping.
##
## Dependency direction is one-way: a crisis event may READ this director (a
## severe Red Flag raising fire probability would be a natural later feature);
## this director never reads crisis state.
##
## RESOLUTION LADDER, evaluated per hazard, highest-confidence first:
##   1. Alert spans   — NWS/IEM VTEC history, 1986..now, US only. Authoritative
##                      timing. Shaped into an hourly curve by layer 2.
##   2. Measured      — air-quality + weather series (added in the evaluator
##                      phase). Gives the curve its real peak, and can raise a
##                      hazard on its own below alert threshold.
##   3. Climatology   — deterministic synthesis, ONLY where layers 1 and 2 have
##                      no DATA (not merely no event), so a 1950s sim year still
##                      gets weather without inventing smoke onto a clean day.
##   4. blank()
##
## Offline / non-US / disabled behaviour: resolve_at() returns HazardState
## blank(), which is the identity element for every applier — so the world
## renders exactly as it did before this subsystem existed.

signal hazard_began(id: String, severity: float)
signal hazard_ended(id: String)
signal risk_profile_ready()
signal state_changed(state: Dictionary)

## IEM's VTEC record effectively begins in 1986.
const HIST_FIRST_YEAR := 1986

## resolve_at() memo granularity, in hours. Purely a performance device — the
## function is total and deterministic at any resolution, and the cache is
## dropped whenever anything it depends on changes.
const MEMO_QUANTUM_H := 1.0 / 60.0
## Sized so a prebaked-challenge sweep (up to 20160 samples, each on its own
## quantum) fits without thrashing. Memory stays small because a quiet
## instant memoizes as a pointer to ONE shared blank dict (most instants are
## quiet); eviction drops the oldest quarter in a batch instead of the old
## clear-on-full, which a single bake wiped ~40 times over.
const MEMO_MAX_ENTRIES := 24000
const MEMO_EVICT_BATCH := 6000

## How often the live state is re-evaluated from the clock (seconds, real time).
const TICK_INTERVAL := 0.25

## Fraction of an alert span spent ramping in / out. A weather event arrives
## and leaves; a rectangular pulse reads as a bug.
const RAMP_IN_FRAC := 0.15
const RAMP_OUT_FRAC := 0.25

var _main_node: Node = null
var _tick_acc := 0.0

## Insertion order of memo keys, for batched FIFO eviction.
var _memo_keys: Array[int] = []
## The ONE blank every quiet instant memoizes to — never mutate it.
var _memo_blank: Dictionary = HazardState.blank()
## Scratch objects reused across samples: _sample_at + _climatology_severity
## used to allocate a fresh CelestialClock (and an RNG) PER SAMPLE — pure
## churn on the hottest path in the subsystem (a bake calls them ~20k times).
## Safe to share: abs_hours_to_date is pure and the RNG is reseeded per use.
var _scratch_clock: CelestialClock = CelestialClock.new()
var _scratch_rng := RandomNumberGenerator.new()
## Climatology stats memo: the ~11,700-call synchronous WeatherService sweep
## used to run on every settings-tab open (sometimes twice). Keyed by site +
## sim year so relocation/new data recomputes.
var _climo_cache: Dictionary = {}
var _climo_cache_key := ""

## hazard id -> Array[{from_abs, to_abs, base, id}], sorted by from_abs.
var _spans: Dictionary = {}
var _spans_zone := ""
var _spans_requested_zone := ""

var _profile: Dictionary = {}
var _profile_zone := ""
var _profile_ready := false

## Site-relative heat threshold, derived from local climatology — 38 C is a
## heatwave in Portland and a Tuesday in Phoenix, so an absolute threshold would
## either never fire in one place or never stop firing in the other.
var _heat_threshold_c := NAN

## Manual override: {id, severity, from_abs, to_abs}. Never persisted — this is
## a testing/storytelling affordance, and a forced hazard surviving a reload
## would be indistinguishable from a bug.
var _forced: Dictionary = {}

var _memo: Dictionary = {}
var _state: Dictionary = {}
var _active_ids: Dictionary = {}


func _ready() -> void:
	_state = HazardState.blank()
	ExtremeWeatherPrefs.ensure_loaded()
	set_process(true)
	var svc := _alert_service()
	if svc != null and svc.has_signal("all_hist_years_ready"):
		svc.all_hist_years_ready.connect(_on_zone_history_ready)


func _process(delta: float) -> void:
	_tick_acc += delta
	if _tick_acc < TICK_INTERVAL:
		return
	_tick_acc = 0.0
	_resolve_main()
	if _main_node == null:
		return
	_maybe_request_history()
	# Build the climatology profile as soon as Main and the weather series are
	# up, rather than waiting on alert history. Most sites have no NWS zone at
	# all, and a zone that never resolves would otherwise leave the settings tab
	# reading "Loading…" forever with every hazard UNKNOWN.
	if not _profile_ready:
		var ws := get_node_or_null("/root/WeatherService")
		if ws != null and ws.has_method("has_data") and bool(ws.call("has_data")):
			refresh_risk_profile()
	var abs_h := _current_abs_hours()
	if is_nan(abs_h):
		return
	var next := resolve_at(abs_h)
	_diff_and_emit(next)
	_state = next


## --- public API --------------------------------------------------------------

## The hazard state at an arbitrary instant. Pure with respect to loaded data:
## calling it twice with the same argument returns the same dict, and calling it
## with a decreasing sequence returns the same values it returned going up.
func resolve_at(abs_hours: float) -> Dictionary:
	if not is_finite(abs_hours):
		return HazardState.blank()
	# A FORCED preview works with the master switch OFF: the Preview button
	# used to permanently flip GameplayRules.extreme_weather_enabled + the
	# per-hazard prefs just to be visible, then never restored either —
	# "not saved" was only half true. Disabled AND unforced still resolves
	# blank (the identity the selftest pins).
	if not is_enabled() and _forced.is_empty():
		return HazardState.blank()

	var key := int(round(abs_hours / MEMO_QUANTUM_H))
	if _memo.has(key):
		return _memo[key]

	var states: Array = []
	if is_enabled():
		var sample := _sample_at(abs_hours)
		for id: String in HazardCatalog.simulated_ids():
			if not ExtremeWeatherPrefs.is_active(id):
				continue
			var s := _resolve_hazard(id, abs_hours, sample)
			if HazardState.is_active(s):
				states.append(s)

	var forced := _forced_state_at(abs_hours)
	if not forced.is_empty():
		states.append(forced)

	# Quiet instant: memoize the ONE shared blank rather than a fresh dict —
	# most instants are quiet, so a 20k-sample sweep stores 20k pointers.
	var out := _memo_blank if states.is_empty() else HazardState.combine_all(states)
	if _memo.size() >= MEMO_MAX_ENTRIES:
		for _i in mini(MEMO_EVICT_BATCH, _memo_keys.size()):
			_memo.erase(_memo_keys.pop_front())
	_memo[key] = out
	_memo_keys.append(key)
	return out


## The state at the live playhead, refreshed on the tick.
func current() -> Dictionary:
	return _state if not _state.is_empty() else HazardState.blank()


func current_severity() -> float:
	return float(current().get("severity", 0.0))


func is_enabled() -> bool:
	var gr := GameplayRulesImpl.from_tree(get_tree())
	if gr == null:
		return false
	return gr.is_extreme_weather_enabled()


func set_enabled(on: bool) -> void:
	var gr := GameplayRulesImpl.from_tree(get_tree())
	if gr != null:
		gr.extreme_weather_enabled = on
	invalidate()


## Drop the memo and the live state. Call after ANY change to prefs, location,
## or loaded data — a cached severity outliving its inputs is the one way a pure
## function can still go wrong.
func invalidate() -> void:
	_memo.clear()
	_memo_keys.clear()
	_state = HazardState.blank()


## Force a hazard on for a window starting now — the review affordance that
## makes this feature testable at a site where nothing is currently happening.
## Deliberately not persisted.
func force_hazard(id: String, severity: float, duration_h: float = 6.0) -> void:
	if not HazardCatalog.is_simulated(id):
		push_warning("ExtremeWeather: '%s' has no resolver; cannot force it." % id)
		return
	var now := _current_abs_hours()
	if is_nan(now):
		# An unresolved clock used to plant the window at absolute hour ZERO —
		# year 1, where the preview would never be seen. Refuse loudly instead.
		push_warning("ExtremeWeather: clock not resolved yet — try Preview again in a moment.")
		return
	var dur := maxf(duration_h, 0.01)
	# Anchor the window so NOW sits at the START OF THE PLATEAU. The pulse is
	# still _span_shape-ramped (scrubbing back through it shows a real
	# arrival, and it fades out at the end), but the player pressing Preview
	# must see the full effect IMMEDIATELY — starting the ramp at `now` made a
	# 6 h preview invisible for its first sim-hour, which at low time scales
	# is minutes of real time staring at a clear sky (and read as "Preview is
	# broken" in the capture harness's severity dump).
	var lead := dur * RAMP_IN_FRAC
	_forced = {
		"id": id,
		"severity": clampf(severity, 0.0, 1.0),
		"from_abs": now - lead,
		"to_abs": now - lead + dur,
	}
	invalidate()


func clear_forced() -> void:
	_forced = {}
	invalidate()


func has_forced() -> bool:
	return not _forced.is_empty()


## Live info for the preview badge: {id, label, severity, from_abs, to_abs}.
## Empty when nothing is forced.
func forced_info() -> Dictionary:
	if _forced.is_empty():
		return {}
	return {
		"id": str(_forced["id"]),
		"label": HazardCatalog.display_name(str(_forced["id"])),
		"severity": float(_forced["severity"]),
		"from_abs": float(_forced["from_abs"]),
		"to_abs": float(_forced["to_abs"]),
	}


## Retune a running preview's severity without moving its window — the panel's
## severity slider is live while a preview runs.
func update_forced_severity(severity: float) -> void:
	if _forced.is_empty():
		return
	_forced["severity"] = clampf(severity, 0.0, 1.0)
	invalidate()


## {hazard_id -> risk entry}; empty until the zone history resolves. See
## HazardRiskProfile for the entry shape.
func risk_profile() -> Dictionary:
	return _profile


func is_risk_profile_ready() -> bool:
	return _profile_ready


## True when the profile came from real alert history rather than climatology.
func risk_profile_is_observed() -> bool:
	return not _spans_zone.is_empty()


func risk_profile_zone() -> String:
	return _profile_zone


## Recompute the profile from whatever data is currently loaded. Safe to call
## repeatedly; the settings tab calls it on open and on Refresh.
func refresh_risk_profile() -> void:
	_profile_ready = false
	var ugc := _zone()
	var svc := _alert_service()
	var vtec: Dictionary = {}
	if not ugc.is_empty() and svc != null and svc.has_method("has_zone_history") \
			and bool(svc.call("has_zone_history", ugc)):
		var events: Dictionary = svc.call("get_all_alert_events", ugc)
		var this_year := _current_year()
		vtec = HazardRiskProfile.from_vtec_history(events, HIST_FIRST_YEAR, this_year)
		_profile_zone = ugc
	var stats := _climatology_stats()
	# A heatwave is heat unusual FOR THIS SITE. Anchor a few degrees below the
	# site's own annual maximum: the hottest hours of a normal year sit at the
	# top of the ordinary range, and a heatwave is what exceeds it.
	var smax := float(stats.get("summer_max_c", NAN))
	_heat_threshold_c = (smax - 4.0) if is_finite(smax) else NAN
	var climo := HazardRiskProfile.from_climatology(stats)
	_profile = HazardRiskProfile.merge(vtec, climo) if not vtec.is_empty() else climo
	_profile_ready = true
	invalidate()
	risk_profile_ready.emit()


## --- resolution --------------------------------------------------------------

## One hazard's state at an instant, resolved down the four-layer ladder.
func _resolve_hazard(id: String, abs_hours: float, sample: Dictionary) -> Dictionary:
	var source := "none"
	var sev := 0.0

	# Layer 2 — measured drivers. Also SHAPES layer 1: a flat six-hour alert box
	# becomes an hourly curve with a real peak.
	var measured := 0.0
	if bool(sample.get("has_data", false)):
		measured = HazardEvaluators.evaluate(id, sample)
		if measured > 0.005:
			source = "aq" if bool(sample.get("has_aq", false)) else "weather"

	# Layer 1 — alert spans. Authoritative for TIMING wherever the site has an
	# NWS zone; the measured curve modulates its amplitude when available.
	var span := _span_covering(id, abs_hours)
	if not span.is_empty():
		var alert_sev := float(span.get("base", 0.45)) * _span_shape(span, abs_hours)
		if measured > 0.005:
			# Blend toward the measurement so a warning during a genuinely
			# extreme reading reads as extreme, not as a flat 0.75.
			alert_sev = maxf(alert_sev, alert_sev * 0.5 + measured * 0.7)
		if alert_sev > sev:
			sev = alert_sev
			source = "alert"

	sev = maxf(sev, measured)

	# Layer 3 — climatology synthesis, ONLY where layers 1 and 2 have no DATA
	# at this instant (not merely no event). Synthesising onto a day we can
	# actually measure would invent smoke over a verifiably clean sky.
	if sev <= 0.005 and not bool(sample.get("has_data", false)):
		sev = _climatology_severity(id, abs_hours)
		if sev > 0.005:
			source = "climatology"

	if sev <= 0.005:
		return HazardState.blank()
	# The Drama slider scales presentation only. It is applied here rather than
	# inside the profiles so the severity that reaches the ENERGY and LIFE
	# channels can be kept honest if that separation is ever wanted.
	sev = clampf(sev * ExtremeWeatherPrefs.intensity, 0.0, 1.0)
	return HazardEvaluators.state_for(id, sev, source)


## Deterministic pseudo-random synthesis for instants with no data at all —
## anything before the air-quality window (which begins in 2022) at a site with
## no alert history. Seeded by hazard + rounded site + sim DAY, never randf(),
## so it is a pure function of absolute hours and scrubs identically in both
## directions. This is what lets a 1950s sim year still have weather.
func _climatology_severity(id: String, abs_hours: float) -> float:
	if _profile.is_empty():
		return 0.0
	var entry: Dictionary = _profile.get(id, {}) as Dictionary
	if entry.is_empty():
		return 0.0
	var level := str(entry.get("level", HazardCatalog.RISK_NONE))
	var chance := HazardCatalog.risk_fill(level) * 0.06   # per-day probability
	if chance <= 0.0:
		return 0.0

	var day := floori(abs_hours / 24.0)
	var lat_q := 0.0
	var lon_q := 0.0
	if _main_node != null and is_instance_valid(_main_node):
		lat_q = roundf(float(_main_node.get("latitude")) * 4.0)
		lon_q = roundf(float(_main_node.get("longitude")) * 4.0)
	var rng := _scratch_rng
	rng.seed = hash("%s|%d|%d|%d" % [id, int(lat_q), int(lon_q), day])
	if rng.randf() > chance:
		return 0.0

	# Seasonality from the site's own alert history, when it has one.
	var month_gate := 1.0
	var hist: Array = entry.get("month_histogram", []) as Array
	if hist.size() == 12:
		var total := 0
		for n: Variant in hist:
			total += int(n)
		if total > 0:
			var dd: Dictionary = _scratch_clock.abs_hours_to_date(abs_hours)
			var m := clampi(int(dd.get("month", 1)), 1, 12)
			month_gate = clampf(float(int(hist[m - 1])) / (float(total) / 12.0), 0.0, 2.0)
			if month_gate <= 0.05:
				return 0.0

	# A within-day curve so a synthesised event arrives and leaves.
	var peak := rng.randf_range(0.35, 1.0)
	var centre := rng.randf_range(6.0, 20.0)
	var width := rng.randf_range(3.0, 9.0)
	var hour := abs_hours - float(day) * 24.0
	var t := clampf(1.0 - absf(hour - centre) / width, 0.0, 1.0)
	return clampf(peak * smoothstep(0.0, 1.0, t) * clampf(month_gate, 0.0, 1.0), 0.0, 1.0)


## One sample of every driver at an instant, assembled from AirQualityService
## (when the instant is inside its ~99-day window) and WeatherService (which
## covers every sim year via archive, forecast or its stochastic generator).
func _sample_at(abs_hours: float) -> Dictionary:
	var out: Dictionary = {"has_aq": false, "has_data": false}
	var dd: Dictionary = _scratch_clock.abs_hours_to_date(abs_hours)
	var month := int(dd.get("month", 6))
	var day := int(dd.get("day", 15))
	var hour := float(dd.get("day_time", 12.0))

	var aq := get_node_or_null("/root/AirQualityService")
	if aq != null and bool(aq.call("covers_time", abs_hours)):
		out["pm25"] = float(aq.call("pm25_ugm3", abs_hours))
		out["pm10"] = float(aq.call("pm10_ugm3", abs_hours))
		out["dust"] = float(aq.call("dust_ugm3", abs_hours))
		out["aod"] = float(aq.call("aerosol_optical_depth", abs_hours))
		out["us_aqi"] = float(aq.call("us_aqi", abs_hours))
		out["has_aq"] = true
		out["has_data"] = true

	var ws := get_node_or_null("/root/WeatherService")
	if ws != null and ws.has_method("has_data") and bool(ws.call("has_data")):
		out["wind_ms"] = float(ws.call("wind_speed_ms", month, day, hour))
		out["gust_ms"] = float(ws.call("wind_gust_ms", month, day, hour))
		out["temp_c"] = float(ws.call("temperature_c", month, day, hour))
		out["rain_mmh"] = float(ws.call("rain_rate_mmh", month, day, hour))
		out["humidity_pct"] = float(ws.call("humidity_pct", month, day, hour))
		out["has_data"] = true
	if is_finite(_heat_threshold_c):
		out["heat_threshold_c"] = _heat_threshold_c
	return out


## Ramp in, plateau, ramp out. Deterministic and pure in `abs_hours`, so a
## scrub through an event retraces exactly the curve it played forward.
func _span_shape(span: Dictionary, abs_hours: float) -> float:
	var a := float(span.get("from_abs", 0.0))
	var b := float(span.get("to_abs", 0.0))
	var dur := b - a
	if dur <= 0.0:
		return 0.0
	var t := clampf((abs_hours - a) / dur, 0.0, 1.0)
	if t < RAMP_IN_FRAC:
		return smoothstep(0.0, 1.0, t / RAMP_IN_FRAC)
	if t > 1.0 - RAMP_OUT_FRAC:
		return smoothstep(0.0, 1.0, (1.0 - t) / RAMP_OUT_FRAC)
	return 1.0


func _span_covering(id: String, abs_hours: float) -> Dictionary:
	var arr: Variant = _spans.get(id, null)
	if not (arr is Array):
		return {}
	var spans := arr as Array
	# Binary search for the last span starting at or before abs_hours, then walk
	# back over any that overlap it. Overlapping alerts are common (an advisory
	# upgraded to a warning mid-event), and the strongest should win.
	var lo := 0
	var hi := spans.size() - 1
	var idx := -1
	while lo <= hi:
		var mid := (lo + hi) / 2
		if float((spans[mid] as Dictionary)["from_abs"]) <= abs_hours:
			idx = mid
			lo = mid + 1
		else:
			hi = mid - 1
	var best: Dictionary = {}
	var probe := idx
	while probe >= 0 and probe > idx - 8:
		var s: Dictionary = spans[probe]
		if abs_hours <= float(s["to_abs"]):
			if best.is_empty() or float(s["base"]) > float(best["base"]):
				best = s
		probe -= 1
	return best


func _forced_state_at(abs_hours: float) -> Dictionary:
	if _forced.is_empty():
		return {}
	if abs_hours < float(_forced["from_abs"]) or abs_hours > float(_forced["to_abs"]):
		return {}
	# Same envelope real alert spans get: a rectangular pulse reads as a bug
	# (the whole reason _span_shape exists), and the preview's entire job is
	# to look like the real thing.
	var shaped := float(_forced["severity"]) * _span_shape(_forced, abs_hours)
	if shaped <= 0.005:
		return {}
	return HazardEvaluators.state_for(str(_forced["id"]), shaped, "forced")


## --- alert span index --------------------------------------------------------

func _maybe_request_history() -> void:
	var ugc := _zone()
	if ugc.is_empty() or ugc == _spans_requested_zone:
		return
	var svc := _alert_service()
	if svc == null:
		return
	_spans_requested_zone = ugc
	svc.call("request_all_hist_years", ugc, HIST_FIRST_YEAR, _current_year())


func _on_zone_history_ready(ugc: String) -> void:
	_build_span_index(ugc)
	refresh_risk_profile()


func _build_span_index(ugc: String) -> void:
	_spans = {}
	_spans_zone = ""
	var svc := _alert_service()
	if svc == null or ugc.is_empty():
		return
	if not svc.has_method("get_all_alert_events"):
		return
	var events: Dictionary = svc.call("get_all_alert_events", ugc)
	if events.is_empty():
		return

	var total := 0
	var nan_rows := 0
	for year_v: Variant in events.keys():
		var rows: Variant = events[year_v]
		if not (rows is Array):
			continue
		for row_v: Variant in (rows as Array):
			if not (row_v is Dictionary):
				continue
			var row := row_v as Dictionary
			total += 1
			var id := HazardCatalog.id_for_alert(
				str(row.get("phenomena", "")), str(row.get("event", "")))
			if id.is_empty():
				continue
			var a := float(row.get("onset_abs", NAN))
			var b := float(row.get("expires_abs", NAN))
			if not is_finite(a) or not is_finite(b) or b <= a:
				nan_rows += 1
				continue
			if not _spans.has(id):
				_spans[id] = []
			(_spans[id] as Array).append({
				"id": id, "from_abs": a, "to_abs": b,
				"base": HazardCatalog.severity_for_significance(
					str(row.get("significance", ""))),
			})

	# NwsAlertService converts IEM timestamps through Main's clock and returns
	# NAN when Main has not resolved. Every span being NAN therefore means "we
	# asked too early", which must be reported rather than silently rendered as
	# "this zone has no hazards" — the two are indistinguishable downstream.
	if total > 0 and nan_rows == total:
		push_warning(
			"ExtremeWeather: all %d alert rows for %s parsed to NAN (clock not ready?) — no span index built."
			% [total, ugc])
		return

	for id: String in _spans.keys():
		(_spans[id] as Array).sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
			return float(x["from_abs"]) < float(y["from_abs"]))
	_spans_zone = ugc
	invalidate()


## --- signals -----------------------------------------------------------------

## hazard_began / hazard_ended are derived by DIFFING the evaluated set, never
## by a trigger. That is what makes them correct under scrubbing: rewinding out
## of a smoke event emits `ended` exactly as fast-forwarding past it does.
func _diff_and_emit(next: Dictionary) -> void:
	var now_ids: Dictionary = {}
	var id := str(next.get("id", ""))
	if HazardState.is_active(next) and not id.is_empty():
		now_ids[id] = float(next.get("severity", 0.0))

	for k: String in now_ids.keys():
		if not _active_ids.has(k):
			hazard_began.emit(k, float(now_ids[k]))
	for k: String in _active_ids.keys():
		if not now_ids.has(k):
			hazard_ended.emit(k)

	_active_ids = now_ids
	if absf(float(next.get("severity", 0.0)) - float(_state.get("severity", 0.0))) > 0.005:
		state_changed.emit(next)


## --- environment helpers -----------------------------------------------------

func _resolve_main() -> void:
	if _main_node != null and is_instance_valid(_main_node):
		return
	_main_node = null
	var tree := get_tree()
	if tree == null:
		return
	for child in tree.root.get_children():
		if "day_time" in child and "sun" in child:
			_main_node = child
			_hook_location_changed()
			return
	var scene := tree.current_scene
	if scene != null and "day_time" in scene:
		_main_node = scene
		_hook_location_changed()


## Relocation must invalidate the risk profile + the site-relative heat
## threshold: they used to recompute ONLY when NWS zone history landed, which
## never fires at a non-US site — move from Portland to Phoenix outside the
## zone path and heat severity kept Portland's threshold until a manual
## "Refresh risk profile". The _process loop rebuilds the profile once the
## weather series covers the new site.
func _hook_location_changed() -> void:
	if _main_node == null or not _main_node.has_signal("location_changed"):
		return
	if not _main_node.is_connected("location_changed", _on_location_changed):
		_main_node.connect("location_changed", _on_location_changed)


func _on_location_changed(_lat: float, _lon: float) -> void:
	_profile_ready = false
	_climo_cache = {}
	_climo_cache_key = ""
	_heat_threshold_c = NAN
	invalidate()


func _current_abs_hours() -> float:
	if _main_node == null or not is_instance_valid(_main_node):
		return NAN
	var clk: Variant = _main_node.get("clock")
	if clk == null or not clk.has_method("get_absolute_hours"):
		return NAN
	return float(clk.get_absolute_hours())


func _current_year() -> int:
	if _main_node == null or not is_instance_valid(_main_node):
		return Time.get_date_dict_from_system().get("year", 2026)
	var y: Variant = _main_node.get("year")
	return int(y) if y != null else Time.get_date_dict_from_system().get("year", 2026)


func _zone() -> String:
	if _main_node == null or not is_instance_valid(_main_node):
		return ""
	var zs := get_node_or_null("/root/NwsZoneService")
	if zs == null or not zs.has_method("get_ugc_zone"):
		return ""
	var lat: Variant = _main_node.get("latitude")
	var lon: Variant = _main_node.get("longitude")
	if lat == null or lon == null:
		return ""
	return str(zs.call("get_ugc_zone", float(lat), float(lon)))


func _alert_service() -> Node:
	return get_node_or_null("/root/NwsAlertService")


## Climatology inputs for the non-US / no-history fallback. Everything here is
## derived from WeatherService's already-loaded year, so it costs no fetch.
func _climatology_stats() -> Dictionary:
	var out: Dictionary = {}
	if _main_node == null or not is_instance_valid(_main_node):
		return out
	var lat: Variant = _main_node.get("latitude")
	if lat != null:
		out["latitude"] = float(lat)
	var ws := get_node_or_null("/root/WeatherService")
	if ws == null or not ws.has_method("has_data") or not bool(ws.call("has_data")):
		return out

	# Memoized per site + sim year: this sweep is ~11,700 synchronous
	# WeatherService calls on the main thread, and the settings tab used to
	# re-run it on every open (sometimes twice — its own not-ready check plus
	# the Refresh button). Same site + year ⇒ same stats.
	var lon: Variant = _main_node.get("longitude")
	var cache_key := "%.4f|%.4f|%d" % [float(lat) if lat != null else 0.0,
		float(lon) if lon != null else 0.0, _current_year()]
	if cache_key == _climo_cache_key and not _climo_cache.is_empty():
		return _climo_cache.duplicate(true)

	# One pass over the loaded year at 3-hour steps: fine enough for maxima and
	# dry spells, ~2900 samples, and it only runs when the profile is refreshed.
	var max_wind := 0.0
	var summer_max := -100.0
	var winter_min := 100.0
	var hours_35 := 0.0
	var precip_total := 0.0
	var max_rain_24h := 0.0
	var snow_total := 0.0
	var dry_run := 0.0
	var longest_dry := 0.0
	var rolling_24: Array[float] = []

	for doy in range(0, 365):
		var md := _month_day_for_doy(doy)
		var day_rain := 0.0
		for step in range(0, 8):
			var hour := float(step) * 3.0
			var w := float(ws.call("wind_speed_ms", md.x, md.y, hour))
			if is_finite(w):
				max_wind = maxf(max_wind, w)
			var t := float(ws.call("temperature_c", md.x, md.y, hour))
			if is_finite(t):
				summer_max = maxf(summer_max, t)
				winter_min = minf(winter_min, t)
				if t > 35.0:
					hours_35 += 3.0
			var r := float(ws.call("rain_rate_mmh", md.x, md.y, hour))
			if is_finite(r):
				day_rain += r * 3.0
			var s := float(ws.call("snowfall_cm", md.x, md.y, hour))
			if is_finite(s):
				snow_total += s
		precip_total += day_rain
		rolling_24.append(day_rain)
		max_rain_24h = maxf(max_rain_24h, day_rain)
		# "Dry" at the daily scale is the conventional < 1 mm, not zero.
		if day_rain < 1.0:
			dry_run += 1.0
			longest_dry = maxf(longest_dry, dry_run)
		else:
			dry_run = 0.0

	out["annual_precip_mm"] = precip_total
	out["max_month_wind_ms"] = max_wind
	out["longest_dry_days"] = longest_dry
	out["summer_max_c"] = summer_max
	out["winter_min_c"] = winter_min
	out["annual_snow_cm"] = snow_total
	out["max_rain_24h_mm"] = max_rain_24h
	out["hours_above_35c"] = hours_35
	# Coastal proxy for the surge/hurricane gate. Absent DEM leaves the key out,
	# so those hazards stay UNKNOWN rather than being guessed from latitude.
	var loader := _find_terrain_loader()
	if loader != null and loader.has_method("get_min_elevation_m"):
		var e := float(loader.call("get_min_elevation_m"))
		if is_finite(e):
			out["min_elevation_m"] = e
	_climo_cache = out.duplicate(true)
	_climo_cache_key = cache_key
	return out


func _find_terrain_loader() -> Node:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.find_child("TerrainLoader", true, false)


## Month/day for a day-of-year in a non-leap year, as a Vector2i(month, day).
func _month_day_for_doy(doy: int) -> Vector2i:
	const DAYS: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	var d := doy
	for m in range(12):
		if d < DAYS[m]:
			return Vector2i(m + 1, d + 1)
		d -= DAYS[m]
	return Vector2i(12, 31)

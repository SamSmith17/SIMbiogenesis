class_name WeatherResampler
extends RefCounted

## k-NN / block-bootstrap hourly weather synthesizer (Phase 7a).
##
## An alternative engine to StochasticWeatherGenerator that, instead of fitting
## parametric distributions, assembles a synthetic year by stitching together real
## multi-day blocks lifted verbatim from the training archives. Each block is tagged
## by month, a standardized synoptic "regime" (storminess), and the wetness of the
## day preceding it; generation lays blocks down on a fixed weekly grid, choosing the
## block for each slot by deterministic k-nearest-neighbour matching against a regime
## AR(1) latent and the previous block's trailing wetness. A per-month, per-variable
## quantile-mapping pass corrects finite-sample bias (and carries the CMIP6 monthly
## climate delta as a distribution shift) for the smooth variables.
##
## Public contract is a drop-in match for StochasticWeatherGenerator so Phase 7b can
## select between the two engines:
##   train_from_multi_series / train_from_series, set_location, set_effective_hoy,
##   begin_year, generate_month(month, out, climate_delta, precip_factor), is_trained.
## Determinism: every random choice is seeded purely by (master_seed, target_year,
## slot) so the assembled year is reproducible and resumable from any month.
##
## IMPROVE(breadcrumbs — deeper structural work, not yet implemented):
## - Variable block lengths (5–14 d) chosen by regime / season instead of fixed BLOCK_LEN.
## - Seam smoothing or optimal nudging at block joins (temp/wind continuity).
## - Multivariate quantile mapping (preserve cross-variable rank correlation).
## - Synoptic cluster tags (k-means on composite vector) instead of scalar regime only.
## - Wet-spell-aware block rejection when prev-wet tag mismatches at year boundaries.

const HOURS_PER_YEAR := 8760
const DAYS_PER_YEAR := 365
const WET_DAY_MM := 0.1
const VAR_NAMES := StochasticWeatherGenerator.VAR_NAMES
const _DAYS_BEFORE_MONTH: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

const BLOCK_LEN := 7            # days per stitched block (plan grid step), within 5–14
const N_SLOTS := 53             # ceil(365 / 7) fixed weekly plan slots
const K_NEIGHBORS := 5          # candidate pool size for the weighted analog draw
const REGIME_PHI := 0.6         # AR(1) persistence of the synthetic regime latent
const PREV_WET_PENALTY := 1.25  # feature distance added when prev-wet tag mismatches
## Variables corrected by quantile mapping. Radiation (sw/df), precipitation and the
## circular wind direction are left as raw resampled archive values: radiation must
## keep df ≤ sw and night ≈ 0, precip is intermittent, direction is circular.
const _QM_VARS: Array[String] = [
	"temperature_2m", "wind_speed_10m", "cloud_cover", "relative_humidity_2m",
]

## Training archives kept by reference (PackedFloat32Array per variable per year).
var _series_by_year: Dictionary = {}
var _years: Array = []
var _temp_doy_mean: PackedFloat32Array = PackedFloat32Array()

## Block catalog (parallel arrays).
var _blk_year: PackedInt32Array = PackedInt32Array()
var _blk_start: PackedInt32Array = PackedInt32Array()
var _blk_regime: PackedFloat32Array = PackedFloat32Array()
var _blk_prev_wet: PackedByteArray = PackedByteArray()
var _blk_last_wet: PackedByteArray = PackedByteArray()      # wetness of block's last day
var _blocks_by_month: Array = []                            # 12 × Array[int] of catalog indices

var _trained: bool = false
var _lat: float = 45.0
var _lon: float = 0.0

## Per-year generation state.
var _master_seed: int = 0
var _target_year: int = 0
var _year_started: bool = false
var _last_completed_doy: int = -1
var _effective_hoy: int = 0
var _block_plan: PackedInt32Array = PackedInt32Array()      # N_SLOTS catalog indices


func train_from_series(series: Dictionary) -> bool:
	return train_from_multi_series({0: series})


func train_from_multi_series(series_by_year: Dictionary) -> bool:
	if series_by_year.is_empty():
		return false
	_years = series_by_year.keys()
	_years.sort()
	_series_by_year = series_by_year

	var has_temp := false
	for yr in _years:
		var t: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
		if t.size() >= HOURS_PER_YEAR:
			has_temp = true
			break
	if not has_temp:
		return false

	_compute_temp_doy_mean()
	_build_catalog()
	_trained = _blk_year.size() > 0
	return _trained


func set_location(lat: float, lon: float) -> void:
	_lat = clampf(lat, -89.9, 89.9)
	_lon = clampf(lon, -180.0, 180.0)


func set_effective_hoy(hoy: int) -> void:
	_effective_hoy = maxi(hoy, 0)


func is_trained() -> bool:
	return _trained


# ----------------------------------------------------------------------------
# Training
# ----------------------------------------------------------------------------

func _compute_temp_doy_mean() -> void:
	_temp_doy_mean = PackedFloat32Array()
	_temp_doy_mean.resize(DAYS_PER_YEAR)
	for doy in range(DAYS_PER_YEAR):
		var vals: Array[float] = []
		for yr in _years:
			var t: PackedFloat32Array = _series_by_year[yr].get("temperature_2m", PackedFloat32Array())
			var dm := _daily_mean_at_doy(t, doy)
			if not is_nan(dm):
				vals.append(dm)
		_temp_doy_mean[doy] = _mean(vals) if not vals.is_empty() else NAN


## Standardized daily storminess composite per training day (z_cloud + z_sqrtP +
## z_wind − z_temp_anom), pooled means/stds. Mirrors the parametric regime axis.
func _daily_composite_for_year(yr: Variant) -> PackedFloat32Array:
	var s: Dictionary = _series_by_year[yr]
	var temp: PackedFloat32Array = s.get("temperature_2m", PackedFloat32Array())
	var cloud: PackedFloat32Array = s.get("cloud_cover", PackedFloat32Array())
	var wind: PackedFloat32Array = s.get("wind_speed_10m", PackedFloat32Array())
	var precip: PackedFloat32Array = s.get("precipitation", PackedFloat32Array())
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	out.fill(NAN)
	for doy in range(DAYS_PER_YEAR):
		var base := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else NAN
		var td := _daily_mean_at_doy(temp, doy)
		if is_nan(td) or is_nan(base):
			continue
		var zt := ((td - base) - _cmp_t_mean) / _cmp_t_std
		var cd := _daily_mean_at_doy(cloud, doy)
		var zc := (((cd if not is_nan(cd) else _cmp_c_mean) - _cmp_c_mean) / _cmp_c_std)
		var wd := _daily_mean_at_doy(wind, doy)
		var zw := (((wd if not is_nan(wd) else _cmp_w_mean) - _cmp_w_mean) / _cmp_w_std)
		var zp := ((sqrt(_day_precip_sum(precip, doy)) - _cmp_p_mean) / _cmp_p_std)
		out[doy] = (zc + zp + zw - zt) / 2.0
	return out


var _cmp_c_mean := 0.0
var _cmp_c_std := 1.0
var _cmp_w_mean := 0.0
var _cmp_w_std := 1.0
var _cmp_p_mean := 0.0
var _cmp_p_std := 1.0
var _cmp_t_mean := 0.0
var _cmp_t_std := 1.0


func _compute_composite_stats() -> void:
	var c_sum := 0.0; var c_sq := 0.0; var c_n := 0
	var w_sum := 0.0; var w_sq := 0.0; var w_n := 0
	var p_sum := 0.0; var p_sq := 0.0; var p_n := 0
	var t_sum := 0.0; var t_sq := 0.0; var t_n := 0
	for yr in _years:
		var s: Dictionary = _series_by_year[yr]
		var temp: PackedFloat32Array = s.get("temperature_2m", PackedFloat32Array())
		var cloud: PackedFloat32Array = s.get("cloud_cover", PackedFloat32Array())
		var wind: PackedFloat32Array = s.get("wind_speed_10m", PackedFloat32Array())
		var precip: PackedFloat32Array = s.get("precipitation", PackedFloat32Array())
		for doy in range(DAYS_PER_YEAR):
			var base := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else NAN
			var td := _daily_mean_at_doy(temp, doy)
			if not is_nan(td) and not is_nan(base):
				var ta := td - base
				t_sum += ta; t_sq += ta * ta; t_n += 1
			var cd := _daily_mean_at_doy(cloud, doy)
			if not is_nan(cd):
				c_sum += cd; c_sq += cd * cd; c_n += 1
			var wd := _daily_mean_at_doy(wind, doy)
			if not is_nan(wd):
				w_sum += wd; w_sq += wd * wd; w_n += 1
			var sp := sqrt(_day_precip_sum(precip, doy))
			p_sum += sp; p_sq += sp * sp; p_n += 1
	_cmp_c_mean = c_sum / float(maxi(c_n, 1))
	_cmp_w_mean = w_sum / float(maxi(w_n, 1))
	_cmp_p_mean = p_sum / float(maxi(p_n, 1))
	_cmp_t_mean = t_sum / float(maxi(t_n, 1))
	_cmp_c_std = maxf(sqrt(maxf(c_sq / float(maxi(c_n, 1)) - _cmp_c_mean * _cmp_c_mean, 0.0)), 1e-3)
	_cmp_w_std = maxf(sqrt(maxf(w_sq / float(maxi(w_n, 1)) - _cmp_w_mean * _cmp_w_mean, 0.0)), 1e-3)
	_cmp_p_std = maxf(sqrt(maxf(p_sq / float(maxi(p_n, 1)) - _cmp_p_mean * _cmp_p_mean, 0.0)), 1e-3)
	_cmp_t_std = maxf(sqrt(maxf(t_sq / float(maxi(t_n, 1)) - _cmp_t_mean * _cmp_t_mean, 0.0)), 1e-3)


func _build_catalog() -> void:
	_compute_composite_stats()
	_blk_year = PackedInt32Array()
	_blk_start = PackedInt32Array()
	_blk_regime = PackedFloat32Array()
	_blk_prev_wet = PackedByteArray()
	_blk_last_wet = PackedByteArray()
	_blocks_by_month = []
	for _m in 12:
		_blocks_by_month.append([] as Array[int])

	var last_start := DAYS_PER_YEAR - BLOCK_LEN
	for yr in _years:
		var comp := _daily_composite_for_year(yr)
		var precip: PackedFloat32Array = _series_by_year[yr].get("precipitation", PackedFloat32Array())
		# Overlapping blocks (step 1) maximise the analog pool.
		for start in range(0, last_start + 1):
			var rsum := 0.0
			var rn := 0
			for d in range(BLOCK_LEN):
				var cv := comp[start + d]
				if not is_nan(cv):
					rsum += cv
					rn += 1
			var regime := rsum / float(maxi(rn, 1)) if rn > 0 else 0.0
			var prev_wet := 0
			if start > 0 and _day_precip_sum(precip, start - 1) >= WET_DAY_MM:
				prev_wet = 1
			var last_wet := 0
			if _day_precip_sum(precip, start + BLOCK_LEN - 1) >= WET_DAY_MM:
				last_wet = 1
			var idx := _blk_year.size()
			_blk_year.append(int(_year_index(yr)))
			_blk_start.append(start)
			_blk_regime.append(regime)
			_blk_prev_wet.append(prev_wet)
			_blk_last_wet.append(last_wet)
			var mo := _month_from_doy(start + BLOCK_LEN / 2)
			(_blocks_by_month[mo] as Array).append(idx)


# ----------------------------------------------------------------------------
# Generation
# ----------------------------------------------------------------------------

func begin_year(master_seed: int, target_year: int) -> void:
	_master_seed = master_seed
	_target_year = target_year
	_year_started = true
	_last_completed_doy = -1
	_build_block_plan()


func _build_block_plan() -> void:
	_block_plan = PackedInt32Array()
	_block_plan.resize(N_SLOTS)
	var regime := 0.0
	var innov_std := sqrt(maxf(1.0 - REGIME_PHI * REGIME_PHI, 1e-3))
	var prev_last_wet := 0
	for b in range(N_SLOTS):
		var rng_r := _slot_rng("regime", b)
		regime = REGIME_PHI * regime + rng_r.randfn() * innov_std
		regime = clampf(regime, -3.0, 3.0)
		var center := mini(b * BLOCK_LEN + BLOCK_LEN / 2, DAYS_PER_YEAR - 1)
		var mo := _month_from_doy(center)
		var chosen := _choose_block(mo, regime, prev_last_wet, b)
		_block_plan[b] = chosen
		prev_last_wet = int(_blk_last_wet[chosen]) if chosen >= 0 else 0


## k-NN weighted analog draw for one plan slot. Deterministic via _slot_rng.
func _choose_block(mo: int, target_regime: float, want_prev_wet: int, slot: int) -> int:
	var pool := _candidate_pool(mo)
	if pool.is_empty():
		return 0
	# Rank by feature distance, keep K nearest, draw one weighted by inverse distance.
	var scored: Array = []
	for idx in pool:
		var dr := absf(_blk_regime[idx] - target_regime)
		var dp := 0.0 if int(_blk_prev_wet[idx]) == want_prev_wet else PREV_WET_PENALTY
		scored.append({"idx": idx, "dist": dr + dp})
	scored.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(a.dist - b.dist) > 1e-6:
			return a.dist < b.dist
		return a.idx < b.idx
	)
	var k := mini(K_NEIGHBORS, scored.size())
	var weights: Array[float] = []
	var wsum := 0.0
	for i in k:
		var w := 1.0 / (1.0 + float(scored[i].dist))
		weights.append(w)
		wsum += w
	var rng := _slot_rng("pick", slot)
	var r := rng.randf() * wsum
	var acc := 0.0
	for i in k:
		acc += weights[i]
		if r <= acc:
			return int(scored[i].idx)
	return int(scored[k - 1].idx)


func _candidate_pool(mo: int) -> Array:
	var pool: Array = (_blocks_by_month[mo] as Array).duplicate()
	if pool.size() >= K_NEIGHBORS:
		return pool
	# Widen to neighbouring months (wrap) until we have enough analogs.
	for span in range(1, 6):
		var lo := (mo - span + 12) % 12
		var hi := (mo + span) % 12
		pool.append_array(_blocks_by_month[lo] as Array)
		pool.append_array(_blocks_by_month[hi] as Array)
		if pool.size() >= K_NEIGHBORS:
			break
	if pool.is_empty():
		for m in 12:
			pool.append_array(_blocks_by_month[m] as Array)
	return pool


func generate_month(
		month: int,
		out_series: Dictionary,
		climate_delta: Callable,
		precip_factor: Callable,
) -> void:
	assert(_trained and _year_started)
	var mo := clampi(month, 1, 12)
	var delta_t := _callable_float(climate_delta, mo)
	var pf := _callable_float(precip_factor, mo)
	if is_nan(delta_t):
		delta_t = 0.0
	if is_nan(pf) or pf <= 0.0:
		pf = 1.0

	var days := _days_in_month(mo)
	for d in range(days):
		var doy := _DAYS_BEFORE_MONTH[mo - 1] + d
		if doy <= _last_completed_doy:
			continue
		if not (_effective_hoy > 0 and doy * 24 < _effective_hoy):
			_fill_day(doy, out_series, delta_t, pf)
		_last_completed_doy = doy

	_quantile_correct_month(mo, out_series, delta_t)


func _fill_day(doy: int, out_series: Dictionary, delta_t: float, pf: float) -> void:
	var slot := mini(doy / BLOCK_LEN, N_SLOTS - 1)
	var offset := doy - slot * BLOCK_LEN
	var blk := _block_plan[slot] if slot < _block_plan.size() else 0
	var src_year: Variant = _years[_blk_year[blk]]
	var src_doy := mini(_blk_start[blk] + offset, DAYS_PER_YEAR - 1)
	var s: Dictionary = _series_by_year[src_year]

	for vname in VAR_NAMES:
		var src: PackedFloat32Array = s.get(vname, PackedFloat32Array())
		for h in range(24):
			var dst_idx := doy * 24 + h
			var src_idx := src_doy * 24 + h
			var v := src[src_idx] if src_idx < src.size() else NAN
			if vname == "temperature_2m" and not is_nan(v):
				v += delta_t
			elif vname == "precipitation" and not is_nan(v):
				v = maxf(v, 0.0) * pf
			_write(out_series, vname, dst_idx, v)


## Per-month quantile mapping: map this month's assembled values onto the pooled
## training distribution for the same month (temperature target shifted by delta_t),
## correcting finite-sample bootstrap bias while preserving hour-to-hour ordering.
func _quantile_correct_month(mo: int, out_series: Dictionary, delta_t: float) -> void:
	for vname in _QM_VARS:
		if not out_series.has(vname):
			continue
		var target := _training_month_values(vname, mo)
		if target.size() < 8:
			continue
		if vname == "temperature_2m" and absf(delta_t) > 1e-6:
			for i in target.size():
				target[i] += delta_t
		target.sort()
		_apply_quantile_map(out_series[vname], mo, target, vname)


func _apply_quantile_map(arr: PackedFloat32Array, mo: int, target_sorted: Array, vname: String) -> void:
	var entries: Array = []
	var days := _days_in_month(mo)
	for d in range(days):
		var doy := _DAYS_BEFORE_MONTH[mo - 1] + d
		for h in range(24):
			var idx := doy * 24 + h
			if idx < arr.size() and is_finite(arr[idx]):
				entries.append({"idx": idx, "val": arr[idx]})
	var n := entries.size()
	if n < 8:
		return
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(a.val - b.val) > 1e-9:
			return a.val < b.val
		return a.idx < b.idx
	)
	var m := target_sorted.size()
	for rank in range(n):
		var q := (float(rank) + 0.5) / float(n)
		var tpos := clampf(q * float(m) - 0.5, 0.0, float(m - 1))
		var lo := int(floor(tpos))
		var hi := mini(lo + 1, m - 1)
		var frac := tpos - float(lo)
		var mapped: float = lerpf(target_sorted[lo], target_sorted[hi], frac)
		arr[int(entries[rank].idx)] = _clamp_var(vname, mapped)


func _training_month_values(vname: String, mo: int) -> Array:
	var out: Array = []
	var days := _days_in_month(mo)
	for yr in _years:
		var arr: PackedFloat32Array = _series_by_year[yr].get(vname, PackedFloat32Array())
		for d in range(days):
			var doy := _DAYS_BEFORE_MONTH[mo - 1] + d
			for h in range(24):
				var idx := doy * 24 + h
				if idx < arr.size() and not is_nan(arr[idx]):
					out.append(arr[idx])
	return out


# ----------------------------------------------------------------------------
# Debug accessors (self-test)
# ----------------------------------------------------------------------------

func get_block_count() -> int:
	return _blk_year.size()


func get_plan_slot_count() -> int:
	return _block_plan.size()


## Catalog index used to source the given day-of-year in the current plan.
func get_plan_block_for_doy(doy: int) -> int:
	var slot := mini(doy / BLOCK_LEN, N_SLOTS - 1)
	return _block_plan[slot] if slot < _block_plan.size() else -1


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

func _year_index(yr: Variant) -> int:
	return _years.find(yr)


func _slot_rng(component: String, slot: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_master_seed ^ (_target_year * 7919) ^ (slot * 104729) ^ component.hash())
	return rng


func _write(out_series: Dictionary, vname: String, idx: int, val: float) -> void:
	if not out_series.has(vname):
		var arr := PackedFloat32Array()
		arr.resize(HOURS_PER_YEAR)
		arr.fill(NAN)
		out_series[vname] = arr
	var arr: PackedFloat32Array = out_series[vname]
	if idx < arr.size():
		arr[idx] = val if is_finite(val) else 0.0


static func _clamp_var(vname: String, v: float) -> float:
	match vname:
		"cloud_cover", "relative_humidity_2m":
			return clampf(v, 0.0, 100.0)
		"wind_speed_10m", "shortwave_radiation", "diffuse_radiation", "precipitation":
			return maxf(v, 0.0)
		_:
			return v


static func _month_from_doy(doy: int) -> int:
	var d := clampi(doy, 0, DAYS_PER_YEAR - 1)
	for mo in range(11, -1, -1):
		if d >= _DAYS_BEFORE_MONTH[mo]:
			return mo
	return 0


static func _days_in_month(month: int) -> int:
	match clampi(month, 1, 12):
		2: return 28
		4, 6, 9, 11: return 30
		_: return 31


static func _day_precip_sum(precip: PackedFloat32Array, doy: int) -> float:
	var sum := 0.0
	for h in range(24):
		var idx := doy * 24 + h
		if idx < precip.size():
			var v := precip[idx]
			if not is_nan(v):
				sum += maxf(v, 0.0)
	return sum


static func _daily_mean_at_doy(hourly: PackedFloat32Array, doy: int) -> float:
	var sum := 0.0
	var n := 0
	for h in range(24):
		var idx := doy * 24 + h
		if idx < hourly.size():
			var v := hourly[idx]
			if not is_nan(v):
				sum += v
				n += 1
	return sum / float(n) if n > 0 else NAN


static func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var s := 0.0
	for v in values:
		s += v
	return s / float(values.size())


static func _callable_float(fn: Callable, arg: Variant) -> float:
	var result: Variant = fn.call(arg)
	if result == null:
		return NAN
	if result is float or result is int:
		return float(result)
	return NAN

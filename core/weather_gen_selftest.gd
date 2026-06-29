extends SceneTree

## Headless self-test for StochasticWeatherGenerator determinism and plausibility.
## Phase 1: distributional metrics vs training reference (WeatherGenMetrics).

const HOURS := 8760
const Metrics := preload("res://core/weather_gen_metrics.gd")
## Equator/prime-meridian keeps geometric seasonality mild so it matches the
## (deliberately flat-season) synthetic reference; lon 0 aligns solar noon to h=12.
const TEST_LAT := 0.0
const TEST_LON := 0.0

var _checks := 0
var _fails := 0


func _initialize() -> void:
	print("weather_gen_selftest: starting")
	_run_all()
	if _fails > 0:
		push_error("weather_gen_selftest: %d/%d checks FAILED" % [_fails, _checks])
		quit(1)
	else:
		print("weather_gen_selftest: all %d checks passed" % _checks)
		quit(0)


func _run_all() -> void:
	var series := _synthetic_training_series()
	var gen := StochasticWeatherGenerator.new()
	_check("train_from_series", gen.train_from_series(series))

	var seed := 424242
	var year := 2032
	var out_a := _generate_full_year(gen, series, seed, year)
	gen = StochasticWeatherGenerator.new()
	_check("retrain", gen.train_from_series(series))
	var out_b := _generate_full_year(gen, series, seed, year)
	_check("determinism_same_seed", _series_equal(out_a, out_b))

	gen = StochasticWeatherGenerator.new()
	gen.train_from_series(series)
	var out_c := _generate_full_year(gen, series, seed + 1, year)
	_check("different_seed_differs", not _series_equal(out_a, out_c))

	_check_plausibility(out_a)

	var multi: Dictionary = {}
	for i in range(5):
		multi[2020 + i] = _synthetic_training_series_with_offset(float(i) * 2.0)
	gen = StochasticWeatherGenerator.new()
	_check("train_from_multi_series", gen.train_from_multi_series(multi))
	var out_multi := _generate_full_year(gen, multi[2022], seed, year)
	_check("multi_year_plausible", out_multi.has("temperature_2m"))

	_check_regime(gen, seed, year)
	_check_temp_ou(gen, out_multi)
	_check_precip_gamma(gen, out_multi)
	_check_wind_cloud(gen, out_multi)
	_check_radiation(out_multi)
	_check_humidity(gen, out_multi, multi)
	_check_distributional_metrics(out_multi, multi, 1.5)

	_check_resampler(multi)
	_check_generated_yearbook()

	var partial: Dictionary = {}
	gen = StochasticWeatherGenerator.new()
	gen.train_from_series(series)
	gen.set_location(TEST_LAT, TEST_LON)
	gen.begin_year(seed, year)
	gen.set_effective_hoy(4000)
	var delta_fn := func(_m: int) -> float: return 0.0
	var precip_fn := func(_m: int) -> float: return 1.0
	for mo in range(6, 13):
		gen.generate_month(mo, partial, delta_fn, precip_fn)
	var roundtrip := StochasticWeatherGenerator.series_from_dict(
		StochasticWeatherGenerator.series_to_dict(partial))
	_check("cache_roundtrip_nan", roundtrip.has("temperature_2m"))
	var rt_temp: PackedFloat32Array = roundtrip["temperature_2m"]
	_check("cache_roundtrip_null_slot", is_nan(rt_temp[0]))
	_check("cache_roundtrip_value_slot", not is_nan(rt_temp[5000]))


func _generate_full_year(gen: StochasticWeatherGenerator, _series: Dictionary, seed: int, year: int) -> Dictionary:
	gen.set_location(TEST_LAT, TEST_LON)
	gen.begin_year(seed, year)
	var out: Dictionary = {}
	var delta_fn := func(_m: int) -> float: return 1.5
	var precip_fn := func(_m: int) -> float: return 1.05
	for mo in range(1, 13):
		gen.generate_month(mo, out, delta_fn, precip_fn)
	return out


func _check(label: String, cond: bool) -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s" % label)
	else:
		print("PASS: %s" % label)


func _series_equal(a: Dictionary, b: Dictionary) -> bool:
	for vname in StochasticWeatherGenerator.VAR_NAMES:
		if not a.has(vname) or not b.has(vname):
			return false
		var aa: PackedFloat32Array = a[vname]
		var bb: PackedFloat32Array = b[vname]
		if aa.size() != bb.size():
			return false
		for i in aa.size():
			if is_nan(aa[i]) and is_nan(bb[i]):
				continue
			if absf(aa[i] - bb[i]) > 0.0001:
				return false
	return true


func _check_plausibility(series: Dictionary) -> void:
	var temp: PackedFloat32Array = series.get("temperature_2m", PackedFloat32Array())
	var precip: PackedFloat32Array = series.get("precipitation", PackedFloat32Array())
	var cloud: PackedFloat32Array = series.get("cloud_cover", PackedFloat32Array())
	var rh: PackedFloat32Array = series.get("relative_humidity_2m", PackedFloat32Array())
	var sw: PackedFloat32Array = series.get("shortwave_radiation", PackedFloat32Array())
	_check("temp_size", temp.size() == HOURS)
	for i in temp.size():
		if not is_nan(temp[i]):
			_check("temp_range", temp[i] > -60.0 and temp[i] < 60.0)
			break
	for i in precip.size():
		if precip[i] > 0.0:
			_check("precip_nonneg", precip[i] >= 0.0)
			break
	for i in cloud.size():
		if not is_nan(cloud[i]):
			_check("cloud_0_100", cloud[i] >= 0.0 and cloud[i] <= 100.0)
			break
	for i in rh.size():
		if not is_nan(rh[i]):
			_check("rh_0_100", rh[i] >= 0.0 and rh[i] <= 100.0)
			break
	var night_ok := true
	var night_idx := 172 * 24 + 3  # mid-year, 3 AM
	if night_idx < sw.size() and sw[night_idx] > 15.0:
		night_ok = false
	_check("night_sw_low", night_ok)


## Phase 2: the shared daily weather regime latent.
func _check_regime(gen: StochasticWeatherGenerator, seed: int, year: int) -> void:
	var phi: float = gen.get_regime_phi()
	_check("regime_phi_range", phi >= 0.0 and phi <= 0.95)

	var a: PackedFloat32Array = gen.debug_regime_series(seed, year)
	var b: PackedFloat32Array = gen.debug_regime_series(seed, year)
	var det_ok: bool = a.size() == b.size()
	if det_ok:
		for i in a.size():
			if absf(a[i] - b[i]) > 1e-6:
				det_ok = false
				break
	_check("regime_determinism_same_seed", det_ok)

	var c: PackedFloat32Array = gen.debug_regime_series(seed + 1, year)
	var differs := false
	for i in mini(a.size(), c.size()):
		if absf(a[i] - c[i]) > 1e-6:
			differs = true
			break
	_check("regime_different_seed_differs", differs)

	# No NaN/Inf, bounded by the generator clamp.
	var finite_ok := true
	for i in a.size():
		if not is_finite(a[i]) or absf(a[i]) > 3.6:
			finite_ok = false
			break
	_check("regime_finite_bounded", finite_ok)

	# Stationary spread ~1 and AR persistence present (not white noise, not locked).
	var mean := 0.0
	for i in a.size():
		mean += a[i]
	mean /= float(maxi(a.size(), 1))
	var var_sum := 0.0
	for i in a.size():
		var_sum += (a[i] - mean) * (a[i] - mean)
	var sd := sqrt(var_sum / float(maxi(a.size(), 1)))
	_check("regime_unit_scale", sd > 0.4 and sd < 2.2)
	var ac := Metrics.lag1_autocorr(a)
	print("  regime_phi=%.3f sd=%.3f lag1=%.3f" % [phi, sd, ac])
	_check("regime_autocorr_plausible", not is_nan(ac) and ac > 0.0 and ac < 0.97)

	# effective_hoy handoff: days before the cutover are skipped (NAN).
	var partial: PackedFloat32Array = gen.debug_regime_series(seed, year, 4000)
	var skipped_nan := is_nan(partial[0]) and is_nan(partial[100])
	var after_valid := not is_nan(partial[200])  # doy 200 * 24 = 4800 > 4000
	_check("regime_effective_hoy_skip", skipped_nan and after_valid)


## Phase 3: per-month OU temperature anomaly + regime cooling coupling.
func _check_temp_ou(gen: StochasticWeatherGenerator, generated: Dictionary) -> void:
	var theta_jun := gen.get_temp_ou_theta(5)
	var sigma_jul := gen.get_temp_ou_sigma(6)
	_check("temp_ou_theta_range", theta_jun >= 0.115 and theta_jun <= 0.75)
	_check("temp_ou_sigma_range", sigma_jul >= 0.5 and sigma_jul <= 12.0)
	print("  temp_ou_theta_jun=%.3f sigma_jul=%.2f" % [theta_jun, sigma_jul])

	var temp: PackedFloat32Array = generated.get("temperature_2m", PackedFloat32Array())
	var summer_min := Metrics.min_hourly_temp_in_doy_range(temp, 152, 243)
	print("  summer_min_hourly_c=%.2f" % summer_min)
	_check("temp_ou_no_subfreezing_summer", not is_nan(summer_min) and summer_min > 0.0)

	var safety_frac := Metrics.temp_safety_clamp_fraction(temp)
	print("  temp_safety_clamp_fraction=%.4f" % safety_frac)
	_check("temp_ou_no_safety_clamp_hits", safety_frac < 0.001)


func _check_precip_gamma(gen: StochasticWeatherGenerator, generated: Dictionary) -> void:
	var precip: PackedFloat32Array = generated.get("precipitation", PackedFloat32Array())
	var ratio := Metrics.wet_day_amount_p90_ratio(precip)
	print("  wet_day_p90_over_mean=%.2f" % ratio)
	_check("precip_gamma_heavy_tail", not is_nan(ratio) and ratio > 1.25)

	var k_sum := 0.0
	for mo in range(12):
		k_sum += gen.get_precip_gamma_k(mo)
	_check("precip_gamma_trained_k", k_sum > 0.0)

	var target_sum := 0.0
	for mo in range(12):
		target_sum += gen.get_month_wet_day_target(mo)
	print("  annual_wet_day_target=%.1f" % target_sum)
	_check("precip_month_wet_targets", target_sum > 30.0)


func _check_wind_cloud(gen: StochasticWeatherGenerator, generated: Dictionary) -> void:
	var cloud_phi := gen.get_cloud_ar_phi()
	print("  cloud_ar_phi=%.3f" % cloud_phi)
	_check("cloud_ar_phi_fitted", cloud_phi >= 0.15 and cloud_phi <= 0.92)

	var wind_phi_sum := 0.0
	var dir_phi_sum := 0.0
	for mo in range(12):
		wind_phi_sum += gen.get_wind_ar_phi(mo)
		dir_phi_sum += gen.get_wind_dir_phi(mo)
	print("  wind_ar_phi_sum=%.2f wind_dir_phi_sum=%.2f" % [wind_phi_sum, dir_phi_sum])
	_check("wind_ar_phi_trained", wind_phi_sum > 0.5)
	_check("wind_dir_phi_trained", dir_phi_sum > 1.0)

	var wind_h: PackedFloat32Array = generated.get("wind_speed_10m", PackedFloat32Array())
	var cloud_h: PackedFloat32Array = generated.get("cloud_cover", PackedFloat32Array())
	var wdir_h: PackedFloat32Array = generated.get("wind_direction_10m", PackedFloat32Array())
	var wind_daily := Metrics.daily_means_from_hourly(wind_h)
	var cloud_daily := Metrics.daily_means_from_hourly(cloud_h)
	var wdir_daily := Metrics.daily_means_from_hourly(wdir_h)
	var wind_ac := Metrics.lag1_autocorr(wind_daily)
	var cloud_ac := Metrics.lag1_autocorr(cloud_daily)
	var dir_ac := Metrics.directional_lag1_autocorr(wdir_daily)
	print("  wind_lag1=%.3f cloud_lag1=%.3f wdir_cos_lag1=%.3f" % [wind_ac, cloud_ac, dir_ac])
	_check("wind_daily_lag1_persistence", not is_nan(wind_ac) and wind_ac > 0.18)
	_check("cloud_daily_lag1_persistence", not is_nan(cloud_ac) and cloud_ac > 0.18)
	_check("wind_dir_circular_persistence", not is_nan(dir_ac) and dir_ac > 0.25)


## Phase 6a: physical radiation model — geometric clear sky, Kasten-Czeplak cloud
## attenuation, Erbs diffuse split.
func _check_radiation(generated: Dictionary) -> void:
	var sw: PackedFloat32Array = generated.get("shortwave_radiation", PackedFloat32Array())
	var df: PackedFloat32Array = generated.get("diffuse_radiation", PackedFloat32Array())

	var night_max := 0.0      # deep-night hours (00:00–04:00 local, sun well below horizon)
	var day_max := 0.0
	var diffuse_le_ghi := true
	var dayfrac_sum := 0.0
	var dayfrac_n := 0
	for doy in range(365):
		for h in range(24):
			var idx := doy * 24 + h
			if idx >= sw.size():
				continue
			var g := sw[idx]
			var d := df[idx]
			if is_nan(g) or is_nan(d):
				continue
			if d > g + 1.0:
				diffuse_le_ghi = false
			if h <= 4:
				night_max = maxf(night_max, g)
			if g > 5.0:
				day_max = maxf(day_max, g)
				dayfrac_sum += d / g
				dayfrac_n += 1
	var day_diffuse_frac := dayfrac_sum / float(maxi(dayfrac_n, 1))
	print("  rad night_max=%.2f day_max=%.1f mean_day_diffuse_frac=%.3f" \
		% [night_max, day_max, day_diffuse_frac])
	_check("rad_night_ghi_zero", night_max < 1.0)
	_check("rad_diffuse_le_ghi", diffuse_le_ghi)
	_check("rad_daytime_ceiling", day_max > 500.0 and day_max < 1200.0)
	_check("rad_diffuse_fraction_plausible", day_diffuse_frac > 0.08 and day_diffuse_frac < 0.9)


## Phase 6b: humidity from fitted T–Td (Magnus); RH anti-correlates with T diurnally.
func _check_humidity(gen: StochasticWeatherGenerator, generated: Dictionary, training_by_year: Dictionary) -> void:
	var slope_jun: float = gen.get_rh_td_slope(5)
	var intercept_jul: float = gen.get_rh_td_intercept(6)
	print("  rh_td_slope_jun=%.3f intercept_jul=%.2f hourly_track=%.3f" \
		% [slope_jun, intercept_jul, gen.get_rh_td_hourly_track()])
	_check("humidity_td_slope_plausible", slope_jun >= 0.55 and slope_jun <= 1.02)

	var temp_h: PackedFloat32Array = generated.get("temperature_2m", PackedFloat32Array())
	var rh_h: PackedFloat32Array = generated.get("relative_humidity_2m", PackedFloat32Array())
	var corr := Metrics.pearson_correlation_diurnal_anomaly(temp_h, rh_h)
	print("  rh_temp_diurnal_corr=%.3f" % corr)
	_check("humidity_rh_temp_negative_diurnal_corr", not is_nan(corr) and corr < -0.15)

	var ref_temp := _reference_hourly(training_by_year, "temperature_2m")
	var ref_rh := _reference_hourly(training_by_year, "relative_humidity_2m")
	var ref_corr := Metrics.pearson_correlation_diurnal_anomaly(ref_temp, ref_rh)
	_check("humidity_diurnal_corr_sign_matches_training", not is_nan(ref_corr) and corr * ref_corr > 0.0)


## Phase 7a: block-bootstrap / k-NN resampling engine (drop-in alternative).
func _check_resampler(training_by_year: Dictionary) -> void:
	var seed := 919191
	var year := 2033

	var r := WeatherResampler.new()
	_check("resampler_train", r.train_from_multi_series(training_by_year))
	_check("resampler_catalog_nonempty", r.get_block_count() > 0)

	var out_a := _resampler_full_year(r, seed, year)
	_check("resampler_plan_slots", r.get_plan_slot_count() == WeatherResampler.N_SLOTS)

	# Determinism: same seed reproduces, different seed diverges.
	var r2 := WeatherResampler.new()
	r2.train_from_multi_series(training_by_year)
	var out_b := _resampler_full_year(r2, seed, year)
	_check("resampler_determinism_same_seed", _series_equal(out_a, out_b))
	var out_c := _resampler_full_year(r2, seed + 1, year)
	_check("resampler_different_seed_differs", not _series_equal(out_a, out_c))

	# Every hour of the year is filled (no NaN gaps) and physically plausible.
	var temp: PackedFloat32Array = out_a.get("temperature_2m", PackedFloat32Array())
	var precip: PackedFloat32Array = out_a.get("precipitation", PackedFloat32Array())
	var sw: PackedFloat32Array = out_a.get("shortwave_radiation", PackedFloat32Array())
	var df: PackedFloat32Array = out_a.get("diffuse_radiation", PackedFloat32Array())
	var filled := true
	var temp_in_range := true
	var precip_nonneg := true
	var diffuse_le_ghi := true
	for i in HOURS:
		if i < temp.size():
			if is_nan(temp[i]):
				filled = false
			elif temp[i] < -90.0 or temp[i] > 65.0:
				temp_in_range = false
		if i < precip.size() and not is_nan(precip[i]) and precip[i] < 0.0:
			precip_nonneg = false
		if i < df.size() and i < sw.size() and not is_nan(df[i]) and not is_nan(sw[i]):
			if df[i] > sw[i] + 1.0:
				diffuse_le_ghi = false
	_check("resampler_full_year_filled", filled)
	_check("resampler_temp_in_range", temp_in_range)
	_check("resampler_precip_nonneg", precip_nonneg)
	_check("resampler_diffuse_le_ghi", diffuse_le_ghi)

	# Quantile mapping should pin monthly temperature close to the training mean
	# (plus the applied climate delta).
	var ref_temp := _reference_hourly(training_by_year, "temperature_2m")
	var gen_t := Metrics.monthly_means(temp)
	var ref_t := Metrics.monthly_means(ref_temp)
	var shifted := PackedFloat32Array()
	shifted.resize(12)
	for mo in range(12):
		shifted[mo] = ref_t[mo] + 1.5
	var temp_bias := Metrics.mean_abs_monthly_bias(gen_t, shifted)
	print("  resampler_temp_monthly_bias_c=%.2f" % temp_bias)
	_check("resampler_temp_qm_bias_small", temp_bias < 3.0)

	# Monthly wet-day counts in a plausible band relative to training.
	var ref_wet := Metrics.monthly_wet_day_counts(_reference_hourly(training_by_year, "precipitation"))
	var gen_wet := Metrics.monthly_wet_day_counts(precip)
	var wet_ok := true
	for mo in range(12):
		var tol := maxi(6, int(round(float(ref_wet[mo]) * 0.7)))
		if absi(int(gen_wet[mo]) - int(ref_wet[mo])) > tol:
			wet_ok = false
	_check("resampler_monthly_wet_plausible", wet_ok)

	# Daily temperature persistence (blocks are real consecutive days → persistent).
	var daily := Metrics.daily_means_from_hourly(temp)
	var ac := Metrics.lag1_autocorr(daily)
	print("  resampler_temp_lag1=%.3f" % ac)
	_check("resampler_temp_persistence", not is_nan(ac) and ac > 0.3)

	# Night GHI ≈ 0 (radiation lifted verbatim from real archive days).
	var night_max := 0.0
	for doy in range(365):
		for h in range(5):
			var idx := doy * 24 + h
			if idx < sw.size() and not is_nan(sw[idx]):
				night_max = maxf(night_max, sw[idx])
	_check("resampler_night_ghi_low", night_max < 50.0)

	# Block sources reference valid catalog entries / real training days.
	var src_ok := true
	for doy in range(0, 365, 30):
		var bi := r.get_plan_block_for_doy(doy)
		if bi < 0 or bi >= r.get_block_count():
			src_ok = false
	_check("resampler_block_sources_valid", src_ok)

	# effective_hoy: days before the cutover stay NaN, days after are filled.
	var r3 := WeatherResampler.new()
	r3.train_from_multi_series(training_by_year)
	r3.set_location(0.0, 0.0)
	r3.begin_year(seed, year)
	r3.set_effective_hoy(4000)
	var partial: Dictionary = {}
	var delta_fn := func(_m: int) -> float: return 0.0
	var precip_fn := func(_m: int) -> float: return 1.0
	for mo in range(1, 13):
		r3.generate_month(mo, partial, delta_fn, precip_fn)
	var ptemp: PackedFloat32Array = partial.get("temperature_2m", PackedFloat32Array())
	_check("resampler_effective_hoy_skip", is_nan(ptemp[0]) and is_nan(ptemp[3000]))
	_check("resampler_effective_hoy_fill", not is_nan(ptemp[5000]))


func _resampler_full_year(r: WeatherResampler, seed: int, year: int) -> Dictionary:
	r.set_location(TEST_LAT, TEST_LON)
	r.begin_year(seed, year)
	var out: Dictionary = {}
	var delta_fn := func(_m: int) -> float: return 1.5
	var precip_fn := func(_m: int) -> float: return 1.05
	for mo in range(1, 13):
		r.generate_month(mo, out, delta_fn, precip_fn)
	return out


## Compare generated year against multi-year training archives (distributional guardrails).
func _check_distributional_metrics(
		generated: Dictionary,
		training_by_year: Dictionary,
		climate_delta: float,
) -> void:
	var ref_precip := _reference_hourly(training_by_year, "precipitation")
	var gen_precip: PackedFloat32Array = generated.get("precipitation", PackedFloat32Array())
	var ref_wet := Metrics.monthly_wet_day_counts(ref_precip)
	var gen_wet := Metrics.monthly_wet_day_counts(gen_precip)
	var wet_ok := true
	for mo in range(12):
		var ref_c := int(ref_wet[mo])
		var gen_c := int(gen_wet[mo])
		var tol := maxi(4, int(round(float(ref_c) * 0.55)))
		if absi(gen_c - ref_c) > tol:
			wet_ok = false
			push_error("  monthly wet days mo=%d ref=%d gen=%d tol=%d" % [mo + 1, ref_c, gen_c, tol])
	_check("dist_monthly_wet_days", wet_ok)

	var ref_flags := Metrics.daily_wet_flags(ref_precip)
	var gen_flags := Metrics.daily_wet_flags(gen_precip)
	var ref_spells: Dictionary = Metrics.spell_lengths(ref_flags)
	var gen_spells: Dictionary = Metrics.spell_lengths(gen_flags)
	var ref_max_wet: int = Metrics.max_spell_length(ref_spells.get("wet", []))
	var gen_max_wet: int = Metrics.max_spell_length(gen_spells.get("wet", []))
	var ref_max_dry: int = Metrics.max_spell_length(ref_spells.get("dry", []))
	var gen_max_dry: int = Metrics.max_spell_length(gen_spells.get("dry", []))
	_check("dist_max_wet_spell", gen_max_wet <= maxi(ref_max_wet * 2 + 2, 14))
	_check("dist_max_dry_spell", gen_max_dry <= maxi(ref_max_dry * 2 + 2, 60))

	var ref_temp_h: PackedFloat32Array = _reference_hourly(training_by_year, "temperature_2m")
	var gen_temp_h: PackedFloat32Array = generated.get("temperature_2m", PackedFloat32Array())
	var ref_daily := Metrics.daily_means_from_hourly(ref_temp_h)
	var gen_daily := Metrics.daily_means_from_hourly(gen_temp_h)
	var seasons: Array = [
		{"name": "winter", "start": 0, "end": 90},
		{"name": "spring", "start": 91, "end": 181},
		{"name": "summer", "start": 182, "end": 273},
		{"name": "autumn", "start": 274, "end": 364},
	]
	var ac_ok := true
	for s in seasons:
		var ref_ac := Metrics.seasonal_lag1_autocorr(ref_daily, s.start, s.end)
		var gen_ac := Metrics.seasonal_lag1_autocorr(gen_daily, s.start, s.end)
		if is_nan(gen_ac):
			ac_ok = false
			continue
		# Generated AR(1) daily temps should show moderate persistence, not white noise or lock-in.
		if gen_ac < 0.15 or gen_ac > 0.96:
			ac_ok = false
			push_error("  temp lag1 %s gen=%.3f out of [0.15, 0.96]" % [s.name, gen_ac])
		# Compare to training only when reference is not artificially smooth (synthetic sine → ~0.98).
		elif not is_nan(ref_ac) and ref_ac < 0.92 and absf(gen_ac - ref_ac) > 0.40:
			ac_ok = false
			push_error("  temp lag1 %s ref=%.3f gen=%.3f" % [s.name, ref_ac, gen_ac])
	_check("dist_seasonal_temp_lag1", ac_ok)

	var ref_sw := Metrics.monthly_means(_reference_hourly(training_by_year, "shortwave_radiation"))
	var gen_sw := Metrics.monthly_means(generated.get("shortwave_radiation", PackedFloat32Array()))
	var ref_wind := Metrics.monthly_means(_reference_hourly(training_by_year, "wind_speed_10m"))
	var gen_wind := Metrics.monthly_means(generated.get("wind_speed_10m", PackedFloat32Array()))
	var ref_t := Metrics.monthly_means(ref_temp_h)
	var gen_t := Metrics.monthly_means(gen_temp_h)
	_check("dist_temp_monthly_bias_c", Metrics.mean_abs_monthly_bias(gen_t, ref_t) < 8.0)
	_check("dist_ghi_monthly_rel_bias", Metrics.mean_rel_monthly_bias(gen_sw, ref_sw) < 0.55)
	var wind_abs := Metrics.mean_abs_monthly_bias(gen_wind, ref_wind)
	var wind_rel := Metrics.mean_rel_monthly_bias(gen_wind, ref_wind)
	print("  wind_monthly_abs_bias_kmh=%.2f rel_bias=%.2f" % [wind_abs, wind_rel])
	_check("dist_wind_monthly_abs_bias_kmh", wind_abs < 18.0)
	_check("dist_wind_wind_in_plausible_range", _monthly_all_in_range(gen_wind, 1.0, 55.0))

	var ref_doy := Metrics.doy_daily_means_from_multi(training_by_year)
	var ref_spread := Metrics.doy_spread_from_multi(training_by_year)
	var pileup := Metrics.temp_anomaly_exceed_fraction(gen_temp_h, ref_doy, 10.0, climate_delta)
	_check("dist_temp_anomaly_pileup", pileup < 0.08)
	print("  anomaly_pileup_fraction=%.3f" % pileup)
	var legacy_pileup := Metrics.temp_clamp_pileup_fraction(gen_temp_h, ref_doy, ref_spread, climate_delta)
	print("  legacy_clamp_pileup_fraction=%.3f" % legacy_pileup)


static func _monthly_all_in_range(monthly: PackedFloat32Array, lo: float, hi: float) -> bool:
	for mo in range(monthly.size()):
		if monthly[mo] < lo or monthly[mo] > hi:
			return false
	return true


static func _reference_hourly(training_by_year: Dictionary, var_name: String) -> PackedFloat32Array:
	var acc := PackedFloat32Array()
	acc.resize(HOURS)
	acc.fill(0.0)
	var n := PackedInt32Array()
	n.resize(HOURS)
	n.fill(0)
	for yr in training_by_year.keys():
		var arr: PackedFloat32Array = training_by_year[yr].get(var_name, PackedFloat32Array())
		for i in mini(arr.size(), HOURS):
			if not is_nan(arr[i]):
				acc[i] += arr[i]
				n[i] += 1
	var mean := PackedFloat32Array()
	mean.resize(HOURS)
	for i in HOURS:
		if n[i] > 0:
			mean[i] = acc[i] / float(n[i])
		else:
			mean[i] = NAN
	return mean


func _synthetic_training_series() -> Dictionary:
	var series: Dictionary = {}
	for vname in StochasticWeatherGenerator.VAR_NAMES:
		var arr := PackedFloat32Array()
		arr.resize(HOURS)
		for i in HOURS:
			arr[i] = NAN
		series[vname] = arr

	var temp: PackedFloat32Array = series["temperature_2m"]
	var precip: PackedFloat32Array = series["precipitation"]
	var cloud: PackedFloat32Array = series["cloud_cover"]
	var sw: PackedFloat32Array = series["shortwave_radiation"]
	var df: PackedFloat32Array = series["diffuse_radiation"]
	var wind: PackedFloat32Array = series["wind_speed_10m"]
	var wdir: PackedFloat32Array = series["wind_direction_10m"]
	var rh: PackedFloat32Array = series["relative_humidity_2m"]

	for doy in range(365):
		for h in range(24):
			var idx := doy * 24 + h
			var season := sin(float(doy) / 365.0 * TAU)
			var diur := sin(float(h) / 24.0 * TAU - PI / 2.0)
			temp[idx] = 12.0 + 10.0 * season + 4.0 * diur
			cloud[idx] = clampf(40.0 + 20.0 * season, 0.0, 100.0)
			# RH derived from T–Td so training fit and generator share the same physics.
			var td := temp[idx] - 6.0 - 2.5 * maxf(diur, 0.0)
			rh[idx] = StochasticWeatherGenerator.rh_from_dewpoint_c(temp[idx], td)
			wind[idx] = 8.0 + 4.0 * abs(diur)
			wdir[idx] = 180.0
			# Physically-shaped reference: ~1000 W/m² clear-sky ceiling attenuated by
			# the same Kasten & Czeplak (1980) cloud law the generator now uses.
			var clear := 1000.0 * maxf(diur, 0.0)
			var cf := cloud[idx] / 100.0
			sw[idx] = maxf(clear * (1.0 - 0.75 * pow(cf, 3.4)), 0.0)
			df[idx] = sw[idx] * 0.25
			if h == 14 and doy % 7 == 0:
				precip[idx] = 0.5
			else:
				precip[idx] = 0.0
	return series


func _synthetic_training_series_with_offset(temp_offset: float) -> Dictionary:
	var series := _synthetic_training_series()
	var temp: PackedFloat32Array = series["temperature_2m"]
	for i in temp.size():
		if not is_nan(temp[i]):
			temp[i] += temp_offset
	return series


func _check_generated_yearbook() -> void:
	var rec := {"high": 30.0, "low": 10.0, "precip": 20.0}
	var hot := RecordBreakCounter.count_day(rec, 35.0, 5.0, 5.0)
	_check("yearbook_count_day_high", int(hot.get("highs", 0)) == 1)
	_check("yearbook_count_day_low", int(hot.get("lows", 0)) == 1)
	_check("yearbook_count_day_precip_ok", int(hot.get("precip", 0)) == 0)

	var temp := PackedFloat32Array()
	temp.resize(HOURS)
	temp.fill(15.0)
	var precip := PackedFloat32Array()
	precip.resize(HOURS)
	precip.fill(0.0)
	# July 15 (doy 195): inject a record-breaking hot day.
	const JUL15_DOY := 195
	for h in range(24):
		temp[JUL15_DOY * 24 + h] = 50.0
	var records := {"07-15": {"high": 40.0, "low": 0.0, "precip": 5.0}}
	var get_rec := func(m: int, d: int) -> Dictionary:
		return records.get("%02d-%02d" % [m, d], {}) as Dictionary
	var all_days := func(_m: int, _d: int) -> bool:
		return true
	var jul := RecordBreakCounter.count_month_from_hourly(
		temp, precip, 7, get_rec, all_days)
	_check("yearbook_jul_hot_day", int(jul.get("highs", 0)) >= 1)

	var jul2 := RecordBreakCounter.count_month_from_hourly(
		temp, precip, 7, get_rec, all_days)
	_check("yearbook_determinism", int(jul.get("highs", 0)) == int(jul2.get("highs", 0)))

	# Partial coverage: hot day on Jul 14 and Jul 15; only Jul 15 inside effective_hoy window.
	for h in range(24):
		temp[194 * 24 + h] = 55.0
	var eff_hoy := JUL15_DOY * 24
	const DOBS := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
	var partial_cov := func(m: int, d: int) -> bool:
		var doy: int = DOBS[clampi(m, 1, 12) - 1] + d - 1
		return doy * 24 >= eff_hoy
	var partial := RecordBreakCounter.count_month_from_hourly(
		temp, precip, 7, get_rec, partial_cov)
	_check("yearbook_effective_hoy_skips_early", int(partial.get("highs", 0)) == 1)

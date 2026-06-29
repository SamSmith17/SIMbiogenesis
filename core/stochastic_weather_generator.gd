class_name StochasticWeatherGenerator
extends RefCounted

## Parametric stochastic hourly weather synthesizer (WGEN-style, first-order).
## Trains from several ERA5/Open-Meteo archive years; baseline = multi-year mean,
## innovation scaled by warmest-vs-coldest year spread per day-of-year.
## Generates future years with CMIP6 monthly deltas embedded in the means.
##
## IMPROVE(breadcrumbs — deeper structural work, not yet implemented):
## - Joint multivariate residuals (copula / correlated draws) instead of independent AR legs.
## - Convective vs stratiform precipitation split; separate spell models per type.
## - Clearness-index (Kt) bins fit from training cloud deciles, not fixed Kasten attenuation.
## - Leap-year / Feb-29 calendar; southern-hemisphere season sign flip helper.
## - Sub-hourly variability envelope (gust factor tied to regime and precip).

const HOURS_PER_YEAR := 8760
const DAYS_PER_YEAR := 365
const WET_DAY_MM := 0.1
const _DAYS_BEFORE_MONTH: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]

const VAR_NAMES: Array[String] = [
	"shortwave_radiation",
	"diffuse_radiation",
	"wind_speed_10m",
	"wind_direction_10m",
	"temperature_2m",
	"relative_humidity_2m",
	"precipitation",
	"cloud_cover",
]

## Training stats (filled by train_from_series).
var _doy_hourly: Dictionary = {}       # var -> PackedFloat32Array size 8760 mean template
var _month_diurnal: Dictionary = {}    # var -> Array[PackedFloat32Array] 12 x 24
var _month_wet_prob: PackedFloat32Array = PackedFloat32Array()
var _markov_p_wet_given_wet: PackedFloat32Array = PackedFloat32Array()
var _markov_p_wet_given_dry: PackedFloat32Array = PackedFloat32Array()
var _wet_day_amount_mean: PackedFloat32Array = PackedFloat32Array()
## Gamma(shape=k, scale=theta) wet-day amount per month (Phase 4).
var _precip_gamma_k: PackedFloat32Array = PackedFloat32Array()
var _precip_gamma_theta: PackedFloat32Array = PackedFloat32Array()
## Target wet-day count per generated month (training mean per year).
var _month_wet_day_target: PackedFloat32Array = PackedFloat32Array()
var _temp_doy_mean: PackedFloat32Array = PackedFloat32Array()
var _temp_doy_spread: PackedFloat32Array = PackedFloat32Array()  # warmest−coldest year per doy
## Per-month OU mean-reversion for daily temperature anomaly (Phase 3).
## X_{t+1} = X_t + theta*(0 - X_t) + sigma*eps  (theta in (0,1], sigma in °C).
var _temp_ou_theta: PackedFloat32Array = PackedFloat32Array()
var _temp_ou_sigma: PackedFloat32Array = PackedFloat32Array()
var _temp_ar_phi: float = 0.6       # legacy global fallback; prefer _temp_ou_*
var _temp_daily_std: float = 2.0
var _cloud_doy_mean: PackedFloat32Array = PackedFloat32Array()
var _cloud_doy_spread: PackedFloat32Array = PackedFloat32Array()
var _cloud_ar_phi: float = 0.5
var _cloud_ar_sigma: PackedFloat32Array = PackedFloat32Array()  # per-month innov ° cloud units
var _cloud_wet_decay: float = 12.0   # post-wet-spell anomaly reduction (Phase 5)
var _wind_doy_mean: PackedFloat32Array = PackedFloat32Array()
var _wind_doy_spread: PackedFloat32Array = PackedFloat32Array()
## Per-month AR(1) on daily-mean wind anomaly (km/h); Weibull kept for sub-daily residual.
var _wind_ar_phi: PackedFloat32Array = PackedFloat32Array()
var _wind_ar_sigma: PackedFloat32Array = PackedFloat32Array()
## Circular AR(1) on wind direction (unit-vector form, Phase 5).
var _wind_dir_phi: PackedFloat32Array = PackedFloat32Array()
var _wind_dir_sigma: PackedFloat32Array = PackedFloat32Array()
var _precip_month_spread: PackedFloat32Array = PackedFloat32Array()  # wet-day count spread per month
var _wind_month_scale: PackedFloat32Array = PackedFloat32Array()
var _wind_month_shape: PackedFloat32Array = PackedFloat32Array()
var _wind_dir_month: PackedFloat32Array = PackedFloat32Array()
var _rh_doy_mean: PackedFloat32Array = PackedFloat32Array()
## Per-month T–Td linear fit: Td ≈ intercept + slope·T (Phase 6b, Magnus RH).
var _rh_td_slope: PackedFloat32Array = PackedFloat32Array()
var _rh_td_intercept: PackedFloat32Array = PackedFloat32Array()
var _rh_td_sigma: PackedFloat32Array = PackedFloat32Array()
## Fraction of hourly temperature anomaly passed to dew point (rest stays at daily value).
var _rh_td_hourly_track: float = 0.25
var _precip_hour_shape: Array[PackedFloat32Array] = []  # 12 months x 24 h weights
## Shared daily synoptic "weather regime" latent (Phase 2). Standardized z-axis:
## positive = stormier (more cloud/precip/wind, cooler). Drives cross-variable
## coupling; temp uses regime_temp in Phase 3 OU block.
var _regime_phi: float = 0.5            # AR(1) persistence fit from training composite
var _regime_innov_std: float = 0.87     # sqrt(1-phi^2) → unit stationary variance
var _trained: bool = false

## Observer location for physical radiation geometry (Phase 6a). Set before
## begin_year via set_location; defaults to a temperate mid-latitude so the
## radiation model never degenerates if a caller forgets to plumb it.
var _lat: float = 45.0
var _lon: float = 0.0

## Per-year generation state (persisted across incremental months).
var _master_seed: int = 0
var _target_year: int = 0
var _temp_ar: float = 0.0
var _cloud_ar: float = 0.0
var _wind_ar: float = 0.0
var _wind_dir_cx: float = 1.0
var _wind_dir_sx: float = 0.0
var _prev_wet: bool = false
var _wind_dir_seeded: bool = false
var _regime: float = 0.0
var _markov_wet: bool = false
var _year_started: bool = false
var _last_completed_doy: int = -1
## Hour-of-year before which days are skipped (no AR/Markov evolution, no writes).
var _effective_hoy: int = 0
var _effective_state_seeded: bool = false


func train_from_series(series: Dictionary) -> bool:
	return train_from_multi_series({0: series})


## Train from several archive years. Baseline stats use the multi-year mean;
## inter-year spread (warmest vs coldest sampled year) scales innovation noise.
func train_from_multi_series(series_by_year: Dictionary) -> bool:
	if series_by_year.is_empty():
		return false
	var years: Array = series_by_year.keys()
	years.sort()

	var has_temp := false
	for yr in years:
		var temp_arr: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
		if temp_arr.size() >= HOURS_PER_YEAR:
			has_temp = true
			break
	if not has_temp:
		return false

	var mean_series := _merge_series_mean(series_by_year)
	if mean_series.is_empty():
		return false

	_doy_hourly.clear()
	for vname in VAR_NAMES:
		_doy_hourly[vname] = mean_series.get(vname, PackedFloat32Array())

	_temp_doy_mean = PackedFloat32Array()
	_temp_doy_mean.resize(DAYS_PER_YEAR)
	_temp_doy_mean.fill(NAN)
	_temp_doy_spread = PackedFloat32Array()
	_temp_doy_spread.resize(DAYS_PER_YEAR)
	_temp_doy_spread.fill(0.0)
	_cloud_doy_mean = PackedFloat32Array()
	_cloud_doy_mean.resize(DAYS_PER_YEAR)
	_cloud_doy_mean.fill(NAN)
	_cloud_doy_spread = PackedFloat32Array()
	_cloud_doy_spread.resize(DAYS_PER_YEAR)
	_cloud_doy_spread.fill(0.0)
	_wind_doy_mean = PackedFloat32Array()
	_wind_doy_mean.resize(DAYS_PER_YEAR)
	_wind_doy_mean.fill(NAN)
	_wind_doy_spread = PackedFloat32Array()
	_wind_doy_spread.resize(DAYS_PER_YEAR)
	_wind_doy_spread.fill(0.0)

	for doy in range(DAYS_PER_YEAR):
		var t_vals: Array[float] = []
		var c_vals: Array[float] = []
		var w_vals: Array[float] = []
		for yr in years:
			var yr_series: Dictionary = series_by_year[yr]
			var td := _daily_mean_at_doy(
				yr_series.get("temperature_2m", PackedFloat32Array()), doy)
			var cd := _daily_mean_at_doy(
				yr_series.get("cloud_cover", PackedFloat32Array()), doy)
			var wd := _daily_mean_at_doy(
				yr_series.get("wind_speed_10m", PackedFloat32Array()), doy)
			if not is_nan(td):
				t_vals.append(td)
			if not is_nan(cd):
				c_vals.append(cd)
			if not is_nan(wd):
				w_vals.append(wd)
		if not t_vals.is_empty():
			_temp_doy_mean[doy] = _array_mean(t_vals)
			if t_vals.size() >= 2:
				_temp_doy_spread[doy] = _array_max(t_vals) - _array_min(t_vals)
		if not c_vals.is_empty():
			_cloud_doy_mean[doy] = _array_mean(c_vals)
			if c_vals.size() >= 2:
				_cloud_doy_spread[doy] = _array_max(c_vals) - _array_min(c_vals)
		if not w_vals.is_empty():
			_wind_doy_mean[doy] = _array_mean(w_vals)
			if w_vals.size() >= 2:
				_wind_doy_spread[doy] = _array_max(w_vals) - _array_min(w_vals)

	_rh_doy_mean = _daily_mean_from_hourly(
		mean_series.get("relative_humidity_2m", PackedFloat32Array()))

	_month_diurnal.clear()
	for vname in ["temperature_2m", "cloud_cover", "wind_speed_10m"]:
		_month_diurnal[vname] = _build_month_diurnal(mean_series.get(vname, PackedFloat32Array()))

	_month_wet_prob = PackedFloat32Array()
	_month_wet_prob.resize(12)
	_markov_p_wet_given_wet = PackedFloat32Array()
	_markov_p_wet_given_wet.resize(12)
	_markov_p_wet_given_dry = PackedFloat32Array()
	_markov_p_wet_given_dry.resize(12)
	_wet_day_amount_mean = PackedFloat32Array()
	_wet_day_amount_mean.resize(12)
	_wind_month_scale = PackedFloat32Array()
	_wind_month_scale.resize(12)
	_wind_month_shape = PackedFloat32Array()
	_wind_month_shape.resize(12)
	_wind_dir_month = PackedFloat32Array()
	_wind_dir_month.resize(12)
	_precip_hour_shape.resize(12)
	_precip_month_spread = PackedFloat32Array()
	_precip_month_spread.resize(12)
	_precip_month_spread.fill(0.0)
	_precip_gamma_k = PackedFloat32Array()
	_precip_gamma_k.resize(12)
	_precip_gamma_theta = PackedFloat32Array()
	_precip_gamma_theta.resize(12)
	_month_wet_day_target = PackedFloat32Array()
	_month_wet_day_target.resize(12)

	_train_precip_params(series_by_year, years)

	for mo in range(12):
		var wind_vals: Array[float] = []
		var dir_sin := 0.0
		var dir_cos := 0.0
		var dir_n := 0
		var ph: Array[float] = []
		ph.resize(24)
		ph.fill(0.0)

		for yr in years:
			var yr_series: Dictionary = series_by_year[yr]
			var precip: PackedFloat32Array = yr_series.get("precipitation", PackedFloat32Array())
			var wind: PackedFloat32Array = yr_series.get("wind_speed_10m", PackedFloat32Array())
			var wdir: PackedFloat32Array = yr_series.get("wind_direction_10m", PackedFloat32Array())

			for d in range(_days_in_month(mo + 1)):
				var doy := _DAYS_BEFORE_MONTH[mo] + d
				for h in range(24):
					var idx := doy * 24 + h
					if idx < precip.size():
						var pv := precip[idx]
						if not is_nan(pv):
							ph[h] += maxf(pv, 0.0)
					var wi := idx
					if wi < wind.size():
						var wv := wind[wi]
						if not is_nan(wv) and wv >= 0.0:
							wind_vals.append(wv)
					if wi < wdir.size():
						var dv := wdir[wi]
						if not is_nan(dv):
							dir_sin += sin(deg_to_rad(dv))
							dir_cos += cos(deg_to_rad(dv))
							dir_n += 1

		if not wind_vals.is_empty():
			wind_vals.sort()
			var median := wind_vals[wind_vals.size() / 2]
			_wind_month_scale[mo] = maxf(median, 0.5)
			_wind_month_shape[mo] = 2.0
		else:
			_wind_month_scale[mo] = 5.0
			_wind_month_shape[mo] = 2.0

		if dir_n > 0:
			_wind_dir_month[mo] = rad_to_deg(atan2(dir_sin / float(dir_n), dir_cos / float(dir_n)))
			if _wind_dir_month[mo] < 0.0:
				_wind_dir_month[mo] += 360.0
		else:
			_wind_dir_month[mo] = 180.0

		var ph_sum := 0.0
		for h in range(24):
			ph_sum += ph[h]
		var shape := PackedFloat32Array()
		shape.resize(24)
		if ph_sum > 0.0:
			for h in range(24):
				shape[h] = ph[h] / ph_sum
		else:
			for h in range(24):
				shape[h] = 1.0 / 24.0
		_precip_hour_shape[mo] = shape

	_train_temp_ou(series_by_year, years)
	_train_regime(series_by_year, years)
	_train_wind_cloud(series_by_year, years)
	_train_rh_td(series_by_year, years)

	_trained = true
	return true


## Precipitation Markov + Gamma training (Phase 4). Transitions counted on
## continuous day-of-year (includes month boundaries and Dec→Jan).
func _train_precip_params(series_by_year: Dictionary, years: Array) -> void:
	var n_years := maxi(years.size(), 1)
	var month_wet: Array[int] = []
	var month_dry: Array[int] = []
	var month_ww: Array[int] = []
	var month_wd: Array[int] = []
	var month_dw: Array[int] = []
	var month_dd: Array[int] = []
	var wet_amts: Array = []
	var yr_wet_counts: Array = []
	for _mo in 12:
		month_wet.append(0)
		month_dry.append(0)
		month_ww.append(0)
		month_wd.append(0)
		month_dw.append(0)
		month_dd.append(0)
		wet_amts.append([] as Array[float])
		yr_wet_counts.append([] as Array[float])

	for yr in years:
		var precip: PackedFloat32Array = series_by_year[yr].get("precipitation", PackedFloat32Array())
		var yr_month_wet: Array[int] = []
		yr_month_wet.resize(12)
		for _m in 12:
			yr_month_wet[_m] = 0

		for doy in range(DAYS_PER_YEAR):
			var day_p := _day_precip_sum(precip, doy)
			var is_wet := day_p >= WET_DAY_MM
			var mo := _month_from_doy(doy)
			if is_wet:
				month_wet[mo] += 1
				yr_month_wet[mo] += 1
				(wet_amts[mo] as Array).append(day_p)
			else:
				month_dry[mo] += 1

		for mo in 12:
			(yr_wet_counts[mo] as Array).append(float(yr_month_wet[mo]))

		for doy in range(1, DAYS_PER_YEAR):
			var prev_wet := _day_precip_sum(precip, doy - 1) >= WET_DAY_MM
			var cur_wet := _day_precip_sum(precip, doy) >= WET_DAY_MM
			var mo := _month_from_doy(doy)
			if prev_wet and cur_wet:
				month_ww[mo] += 1
			elif prev_wet:
				month_wd[mo] += 1
			elif cur_wet:
				month_dw[mo] += 1
			else:
				month_dd[mo] += 1

	for mo in range(12):
		var total := month_wet[mo] + month_dry[mo]
		_month_wet_prob[mo] = float(month_wet[mo]) / float(maxi(total, 1))
		_markov_p_wet_given_wet[mo] = float(month_ww[mo]) / float(maxi(month_ww[mo] + month_wd[mo], 1))
		_markov_p_wet_given_dry[mo] = float(month_dw[mo]) / float(maxi(month_dw[mo] + month_dd[mo], 1))
		var amts: Array = wet_amts[mo]
		var wet_sum := 0.0
		for a in amts:
			wet_sum += float(a)
		_wet_day_amount_mean[mo] = wet_sum / float(maxi(amts.size(), 1))
		_month_wet_day_target[mo] = float(month_wet[mo]) / float(n_years)

		var yrc: Array = yr_wet_counts[mo]
		if yrc.size() >= 2:
			_precip_month_spread[mo] = _array_max(yrc) - _array_min(yrc)

		var mu := _wet_day_amount_mean[mo]
		var var_amt := 0.0
		if amts.size() >= 2:
			for a in amts:
				var d := float(a) - mu
				var_amt += d * d
			var_amt /= float(amts.size())
		var k := 2.0
		var theta := maxf(mu / k, 0.05)
		if var_amt > mu * mu * 0.02 and mu > 0.01:
			k = clampf(mu * mu / var_amt, 0.35, 30.0)
			theta = clampf(var_amt / mu, 0.02, maxf(mu * 4.0, 0.1))
		else:
			k = clampf(2.0 + mu * 0.15, 1.0, 8.0)
			theta = maxf(mu / k, 0.05)
		_precip_gamma_k[mo] = k
		_precip_gamma_theta[mo] = theta


static func _month_from_doy(doy: int) -> int:
	var d := clampi(doy, 0, DAYS_PER_YEAR - 1)
	for mo in range(11, -1, -1):
		if d >= _DAYS_BEFORE_MONTH[mo]:
			return mo
	return 0


## Fit per-month OU parameters for the daily temperature anomaly (Phase 3).
## theta = 1 - phi from within-month lag-1 autocorrelation of (daily_mean - doy_mean).
func _train_temp_ou(series_by_year: Dictionary, years: Array) -> void:
	_temp_ou_theta = PackedFloat32Array()
	_temp_ou_theta.resize(12)
	_temp_ou_sigma = PackedFloat32Array()
	_temp_ou_sigma.resize(12)

	# Global fallback from pooled daily series (used if a month has sparse data).
	var daily_all: Array[float] = []
	for yr in years:
		var temp: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
		for doy in range(DAYS_PER_YEAR):
			var dm := _daily_mean_at_doy(temp, doy)
			var base := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else NAN
			if not is_nan(dm) and not is_nan(base):
				daily_all.append(dm - base)
	var global_phi := 0.6
	var global_sigma := 2.0
	if daily_all.size() > 2:
		global_phi = clampf(_lag1_autocorr_array(daily_all), 0.05, 0.88)
		global_sigma = maxf(_array_std(daily_all), 0.5)

	var spread_sum := 0.0
	var spread_n := 0
	for doy in range(DAYS_PER_YEAR):
		if _temp_doy_spread[doy] > 0.01:
			spread_sum += _temp_doy_spread[doy]
			spread_n += 1
	var spread_scale := (spread_sum / float(maxi(spread_n, 1))) * 0.35 if spread_n > 0 else 0.0
	global_sigma = maxf(global_sigma, spread_scale)
	_temp_ar_phi = global_phi
	_temp_daily_std = global_sigma

	for mo in range(12):
		var anomalies: Array[float] = []
		var prev_vals: Array[float] = []
		var cur_vals: Array[float] = []
		for yr in years:
			var temp: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
			var prev_anom := NAN
			for d in range(_days_in_month(mo + 1)):
				var doy := _DAYS_BEFORE_MONTH[mo] + d
				var dm := _daily_mean_at_doy(temp, doy)
				var base := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else NAN
				if is_nan(dm) or is_nan(base):
					prev_anom = NAN
					continue
				var anom := dm - base
				anomalies.append(anom)
				if not is_nan(prev_anom):
					prev_vals.append(prev_anom)
					cur_vals.append(anom)
				prev_anom = anom

		var phi_m := global_phi
		if prev_vals.size() >= 3:
			# Cap phi below 0.88 — smooth synthetic/archive days otherwise yield
			# phi→1 and near-zero theta, letting the anomaly drift for weeks.
			phi_m = clampf(_lag1_from_pairs(prev_vals, cur_vals), 0.05, 0.88)
		var theta_m := clampf(1.0 - phi_m, 0.12, 0.75)
		var sigma_m := global_sigma
		if anomalies.size() >= 2:
			sigma_m = maxf(_array_std(anomalies), 0.5)
			sigma_m = maxf(sigma_m * sqrt(maxf(1.0 - phi_m * phi_m, 0.08)), 0.5)
		sigma_m = maxf(sigma_m, spread_scale)
		_temp_ou_theta[mo] = theta_m
		_temp_ou_sigma[mo] = sigma_m


## Wind speed AR(1), circular wind direction, and cloud AR(1) training (Phase 5).
func _train_wind_cloud(series_by_year: Dictionary, years: Array) -> void:
	_wind_ar_phi = PackedFloat32Array()
	_wind_ar_phi.resize(12)
	_wind_ar_sigma = PackedFloat32Array()
	_wind_ar_sigma.resize(12)
	_wind_dir_phi = PackedFloat32Array()
	_wind_dir_phi.resize(12)
	_wind_dir_sigma = PackedFloat32Array()
	_wind_dir_sigma.resize(12)
	_cloud_ar_sigma = PackedFloat32Array()
	_cloud_ar_sigma.resize(12)

	# --- Cloud AR(1) phi + per-month innov + post-wet decay ---
	var cloud_prev: Array[float] = []
	var cloud_cur: Array[float] = []
	var all_cloud_anom: Array[float] = []
	var wet_anoms: Array[float] = []
	var dry_after_wet_anoms: Array[float] = []

	for yr in years:
		var cloud: PackedFloat32Array = series_by_year[yr].get("cloud_cover", PackedFloat32Array())
		var precip: PackedFloat32Array = series_by_year[yr].get("precipitation", PackedFloat32Array())
		var prev_anom := NAN
		var prev_wet := false
		for doy in range(DAYS_PER_YEAR):
			var dm := _daily_mean_at_doy(cloud, doy)
			var base := _cloud_doy_mean[doy] if doy < _cloud_doy_mean.size() else NAN
			var is_wet := _day_precip_sum(precip, doy) >= WET_DAY_MM
			if is_nan(dm) or is_nan(base):
				prev_anom = NAN
				prev_wet = is_wet
				continue
			var anom := dm - base
			all_cloud_anom.append(anom)
			if is_wet:
				wet_anoms.append(anom)
			elif prev_wet:
				dry_after_wet_anoms.append(anom)
			if not is_nan(prev_anom):
				cloud_prev.append(prev_anom)
				cloud_cur.append(anom)
			prev_anom = anom
			prev_wet = is_wet

	var global_cloud_phi := 0.55
	if cloud_prev.size() >= 3:
		global_cloud_phi = clampf(_lag1_from_pairs(cloud_prev, cloud_cur), 0.15, 0.92)
	_cloud_ar_phi = global_cloud_phi

	var wet_mean := _array_mean(wet_anoms) if not wet_anoms.is_empty() else 20.0
	var dry_after_mean := _array_mean(dry_after_wet_anoms) if not dry_after_wet_anoms.is_empty() else 8.0
	_cloud_wet_decay = clampf((wet_mean - dry_after_mean) * 0.4, 6.0, 28.0)

	for mo in range(12):
		var cloud_anoms: Array[float] = []
		for yr in years:
			var cloud: PackedFloat32Array = series_by_year[yr].get("cloud_cover", PackedFloat32Array())
			for d in range(_days_in_month(mo + 1)):
				var doy := _DAYS_BEFORE_MONTH[mo] + d
				var dm := _daily_mean_at_doy(cloud, doy)
				var base := _cloud_doy_mean[doy] if doy < _cloud_doy_mean.size() else NAN
				if not is_nan(dm) and not is_nan(base):
					cloud_anoms.append(dm - base)
		var sigma_c := maxf(_array_std(all_cloud_anom), 4.0)
		if cloud_anoms.size() >= 2:
			sigma_c = maxf(_array_std(cloud_anoms), 4.0)
		sigma_c = maxf(sigma_c * sqrt(maxf(1.0 - global_cloud_phi * global_cloud_phi, 0.08)), 4.0)
		_cloud_ar_sigma[mo] = sigma_c

	# --- Wind speed AR(1) per month (daily mean anomaly, km/h) ---
	var global_wind_prev: Array[float] = []
	var global_wind_cur: Array[float] = []
	var global_wind_anom: Array[float] = []
	for yr in years:
		var wind: PackedFloat32Array = series_by_year[yr].get("wind_speed_10m", PackedFloat32Array())
		var prev := NAN
		for doy in range(DAYS_PER_YEAR):
			var dm := _daily_mean_at_doy(wind, doy)
			var base := _wind_doy_mean[doy] if doy < _wind_doy_mean.size() else NAN
			if is_nan(dm) or is_nan(base):
				prev = NAN
				continue
			var anom := dm - base
			global_wind_anom.append(anom)
			if not is_nan(prev):
				global_wind_prev.append(prev)
				global_wind_cur.append(anom)
			prev = anom

	var global_w_phi := 0.55
	if global_wind_prev.size() >= 3:
		global_w_phi = clampf(_lag1_from_pairs(global_wind_prev, global_wind_cur), 0.08, 0.92)
	var global_w_sigma := maxf(_array_std(global_wind_anom), 0.8)

	for mo in range(12):
		var w_prev: Array[float] = []
		var w_cur: Array[float] = []
		var w_anoms: Array[float] = []
		for yr in years:
			var wind: PackedFloat32Array = series_by_year[yr].get("wind_speed_10m", PackedFloat32Array())
			var prev_anom := NAN
			for d in range(_days_in_month(mo + 1)):
				var doy := _DAYS_BEFORE_MONTH[mo] + d
				var dm := _daily_mean_at_doy(wind, doy)
				var base := _wind_doy_mean[doy] if doy < _wind_doy_mean.size() else NAN
				if is_nan(dm) or is_nan(base):
					prev_anom = NAN
					continue
				var anom := dm - base
				w_anoms.append(anom)
				if not is_nan(prev_anom):
					w_prev.append(prev_anom)
					w_cur.append(anom)
				prev_anom = anom

		var phi_w := global_w_phi
		if w_prev.size() >= 3:
			phi_w = clampf(_lag1_from_pairs(w_prev, w_cur), 0.08, 0.92)
		var sigma_w := global_w_sigma
		if w_anoms.size() >= 2:
			sigma_w = maxf(_array_std(w_anoms), 0.8)
		sigma_w = maxf(sigma_w * sqrt(maxf(1.0 - phi_w * phi_w, 0.08)), 0.8)
		_wind_ar_phi[mo] = phi_w
		_wind_ar_sigma[mo] = sigma_w

	# --- Circular AR(1) on wind direction (unit-vector components) ---
	for mo in range(12):
		var prev_cx: Array[float] = []
		var cur_cx: Array[float] = []
		var prev_sy: Array[float] = []
		var cur_sy: Array[float] = []
		var resid: Array[float] = []
		for yr in years:
			var wdir: PackedFloat32Array = series_by_year[yr].get("wind_direction_10m", PackedFloat32Array())
			var prev_u := NAN
			var prev_v := NAN
			for d in range(_days_in_month(mo + 1)):
				var doy := _DAYS_BEFORE_MONTH[mo] + d
				var dm := _daily_mean_at_doy(wdir, doy)
				if is_nan(dm):
					prev_u = NAN
					continue
				var rad := deg_to_rad(dm)
				var u := cos(rad)
				var v := sin(rad)
				if not is_nan(prev_u):
					prev_cx.append(prev_u)
					cur_cx.append(u)
					prev_sy.append(prev_v)
					cur_sy.append(v)
					resid.append(absf(atan2(v, u) - atan2(prev_v, prev_u)))
				prev_u = u
				prev_v = v

		var phi_d := 0.65
		if prev_cx.size() >= 3:
			var ph_u := clampf(_lag1_from_pairs(prev_cx, cur_cx), 0.05, 0.98)
			var ph_v := clampf(_lag1_from_pairs(prev_sy, cur_sy), 0.05, 0.98)
			phi_d = clampf((ph_u + ph_v) * 0.5, 0.15, 0.95)
		_wind_dir_phi[mo] = phi_d
		var sig_d := 0.12
		if resid.size() >= 2:
			sig_d = clampf(_array_std(resid), 0.04, 0.55)
		_wind_dir_sigma[mo] = sig_d


## Fit per-month temperature–dewpoint relationship from training archives (Phase 6b).
func _train_rh_td(series_by_year: Dictionary, years: Array) -> void:
	_rh_td_slope = PackedFloat32Array()
	_rh_td_slope.resize(12)
	_rh_td_intercept = PackedFloat32Array()
	_rh_td_intercept.resize(12)
	_rh_td_sigma = PackedFloat32Array()
	_rh_td_sigma.resize(12)

	var global_t: Array[float] = []
	var global_td: Array[float] = []
	for yr in years:
		var temp: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
		var rh: PackedFloat32Array = series_by_year[yr].get("relative_humidity_2m", PackedFloat32Array())
		for doy in range(DAYS_PER_YEAR):
			var tm := _daily_mean_at_doy(temp, doy)
			var rm := _daily_mean_at_doy(rh, doy)
			if is_nan(tm) or is_nan(rm):
				continue
			var td := dewpoint_from_rh_c(tm, rm)
			global_t.append(tm)
			global_td.append(td)

	var global_fit := _linear_fit(global_t, global_td)
	var g_slope := global_fit.x if is_finite(global_fit.x) else 0.88
	var g_intercept := global_fit.y if is_finite(global_fit.y) else 2.0
	g_slope = clampf(g_slope, 0.55, 1.02)
	var g_resid := _fit_residual_std(global_t, global_td, g_slope, g_intercept)

	for mo in range(12):
		var temps: Array[float] = []
		var tds: Array[float] = []
		for yr in years:
			var temp: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
			var rh: PackedFloat32Array = series_by_year[yr].get("relative_humidity_2m", PackedFloat32Array())
			for d in range(_days_in_month(mo + 1)):
				var doy := _DAYS_BEFORE_MONTH[mo] + d
				var tm := _daily_mean_at_doy(temp, doy)
				var rm := _daily_mean_at_doy(rh, doy)
				if is_nan(tm) or is_nan(rm):
					continue
				temps.append(tm)
				tds.append(dewpoint_from_rh_c(tm, rm))

		var slope := g_slope
		var intercept := g_intercept
		if temps.size() >= 8:
			var fit := _linear_fit(temps, tds)
			if is_finite(fit.x):
				slope = clampf(fit.x, 0.55, 1.02)
				intercept = fit.y
		_rh_td_slope[mo] = slope
		_rh_td_intercept[mo] = intercept
		var sig := g_resid
		if temps.size() >= 3:
			sig = _fit_residual_std(temps, tds, slope, intercept)
		_rh_td_sigma[mo] = clampf(sig, 0.3, 6.0)

	# Hourly dew point tracks only a fraction of the within-day temperature swing.
	var track_num := 0.0
	var track_den := 0.0
	for yr in years:
		var temp: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
		var rh: PackedFloat32Array = series_by_year[yr].get("relative_humidity_2m", PackedFloat32Array())
		for doy in range(DAYS_PER_YEAR):
			var tm := _daily_mean_at_doy(temp, doy)
			if is_nan(tm):
				continue
			var mo_d := _month_from_doy(doy)
			var td_base := _rh_td_intercept[mo_d] + _rh_td_slope[mo_d] * tm
			for h in range(24):
				var idx := doy * 24 + h
				if idx >= temp.size() or idx >= rh.size():
					continue
				var th := temp[idx]
				var rhh := rh[idx]
				if is_nan(th) or is_nan(rhh):
					continue
				var td_obs := dewpoint_from_rh_c(th, rhh)
				var dt := th - tm
				if absf(dt) < 0.05:
					continue
				track_num += (td_obs - td_base) * dt
				track_den += dt * dt
	if track_den > 1e-6:
		_rh_td_hourly_track = clampf(track_num / track_den, 0.08, 0.55)
	else:
		_rh_td_hourly_track = 0.25


static func _linear_fit(xs: Array[float], ys: Array[float]) -> Vector2:
	var n := mini(xs.size(), ys.size())
	if n < 2:
		return Vector2(NAN, NAN)
	var sum_x := 0.0
	var sum_y := 0.0
	var sum_xx := 0.0
	var sum_xy := 0.0
	for i in n:
		sum_x += xs[i]
		sum_y += ys[i]
		sum_xx += xs[i] * xs[i]
		sum_xy += xs[i] * ys[i]
	var denom := float(n) * sum_xx - sum_x * sum_x
	if absf(denom) < 1e-9:
		return Vector2(NAN, NAN)
	var slope := (float(n) * sum_xy - sum_x * sum_y) / denom
	var intercept := (sum_y - slope * sum_x) / float(n)
	return Vector2(slope, intercept)


static func _fit_residual_std(xs: Array[float], ys: Array[float], slope: float, intercept: float) -> float:
	var n := mini(xs.size(), ys.size())
	if n < 2:
		return 1.5
	var ss := 0.0
	for i in n:
		var resid := ys[i] - (intercept + slope * xs[i])
		ss += resid * resid
	return sqrt(ss / float(n))


## Magnus (Bolton 1980) saturation vapour pressure over liquid water [hPa].
static func sat_vapor_pressure_hpa(t_c: float) -> float:
	return 6.112 * exp(17.67 * t_c / (t_c + 243.5))


## Dew point [°C] from air temperature and relative humidity [%].
static func dewpoint_from_rh_c(t_c: float, rh_pct: float) -> float:
	rh_pct = clampf(rh_pct, 1.0, 100.0)
	var e := sat_vapor_pressure_hpa(t_c) * rh_pct / 100.0
	var ln_ratio := log(maxf(e / 6.112, 1e-9))
	return 243.5 * ln_ratio / (17.67 - ln_ratio)


## Relative humidity [%] from air temperature and dew point [°C].
static func rh_from_dewpoint_c(t_c: float, td_c: float) -> float:
	td_c = minf(td_c, t_c - 0.01)
	var es := maxf(sat_vapor_pressure_hpa(t_c), 1e-6)
	var e := sat_vapor_pressure_hpa(td_c)
	return clampf(100.0 * e / es, 1.0, 100.0)


static func _lag1_from_pairs(prev: Array[float], cur: Array[float]) -> float:
	var n := mini(prev.size(), cur.size())
	if n < 2:
		return NAN
	var mean_p := 0.0
	var mean_c := 0.0
	for i in n:
		mean_p += prev[i]
		mean_c += cur[i]
	mean_p /= float(n)
	mean_c /= float(n)
	var num := 0.0
	var den := 0.0
	for i in n:
		var b := prev[i] - mean_p
		var a := cur[i] - mean_c
		num += a * b
		den += b * b
	return num / maxf(den, 1e-9)


static func _lag1_autocorr_array(values: Array[float]) -> float:
	if values.size() < 3:
		return NAN
	var prev: Array[float] = []
	var cur: Array[float] = []
	for i in range(1, values.size()):
		prev.append(values[i - 1])
		cur.append(values[i])
	return _lag1_from_pairs(prev, cur)


static func _array_std(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var mean := 0.0
	for v in values:
		mean += v
	mean /= float(values.size())
	var var_sum := 0.0
	for v in values:
		var d := v - mean
		var_sum += d * d
	return sqrt(var_sum / float(values.size()))


## Fit the daily synoptic regime latent (Phase 2). The regime is a standardized
## composite of cloud + precip + wind − temperature-anomaly per day; we keep only
## its AR(1) persistence so generation can produce a deterministic unit-variance
## latent that nudges multiple variables together. Requires _temp_doy_mean filled.
func _train_regime(series_by_year: Dictionary, years: Array) -> void:
	# Pass 1: component means/stds across all valid training days.
	var c_sum := 0.0; var c_sq := 0.0; var c_n := 0
	var w_sum := 0.0; var w_sq := 0.0; var w_n := 0
	var p_sum := 0.0; var p_sq := 0.0; var p_n := 0
	var t_sum := 0.0; var t_sq := 0.0; var t_n := 0
	for yr in years:
		var s: Dictionary = series_by_year[yr]
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
			var sp := sqrt(_day_precip_sum(precip, doy))   # sqrt tames precip skew
			p_sum += sp; p_sq += sp * sp; p_n += 1

	var c_mean := c_sum / float(maxi(c_n, 1))
	var w_mean := w_sum / float(maxi(w_n, 1))
	var p_mean := p_sum / float(maxi(p_n, 1))
	var t_mean := t_sum / float(maxi(t_n, 1))
	var c_std := maxf(sqrt(maxf(c_sq / float(maxi(c_n, 1)) - c_mean * c_mean, 0.0)), 1e-3)
	var w_std := maxf(sqrt(maxf(w_sq / float(maxi(w_n, 1)) - w_mean * w_mean, 0.0)), 1e-3)
	var p_std := maxf(sqrt(maxf(p_sq / float(maxi(p_n, 1)) - p_mean * p_mean, 0.0)), 1e-3)
	var t_std := maxf(sqrt(maxf(t_sq / float(maxi(t_n, 1)) - t_mean * t_mean, 0.0)), 1e-3)

	# Pass 2: per-year composite series; mean then within-year lag-1 autocorr.
	# (Generation produces a unit-variance latent via _regime_innov_std, so only
	# the scale-invariant persistence phi is needed from training.)
	var comp_mean := 0.0; var comp_n := 0
	for yr in years:
		var s2: Dictionary = series_by_year[yr]
		var comp := _year_regime_composite(s2, c_mean, c_std, w_mean, w_std, p_mean, p_std, t_mean, t_std)
		for doy in range(comp.size()):
			if not is_nan(comp[doy]):
				comp_mean += comp[doy]; comp_n += 1
	comp_mean /= float(maxi(comp_n, 1))

	var num := 0.0; var den := 0.0
	for yr in years:
		var s3: Dictionary = series_by_year[yr]
		var comp := _year_regime_composite(s3, c_mean, c_std, w_mean, w_std, p_mean, p_std, t_mean, t_std)
		for doy in range(1, comp.size()):
			var cur := comp[doy]
			var prev := comp[doy - 1]
			if is_nan(cur) or is_nan(prev):
				continue
			num += (cur - comp_mean) * (prev - comp_mean)
			den += (prev - comp_mean) * (prev - comp_mean)

	if den > 1e-6:
		_regime_phi = clampf(num / den, 0.0, 0.95)
	else:
		_regime_phi = 0.5
	_regime_innov_std = sqrt(maxf(1.0 - _regime_phi * _regime_phi, 1e-3))


## Build the standardized regime composite (size DAYS_PER_YEAR) for one year.
## Positive = stormier: +cloud +precip +wind −temp-anomaly, each z-scored, then
## divided so the composite carries ~unit variance.
func _year_regime_composite(
		s: Dictionary,
		c_mean: float, c_std: float,
		w_mean: float, w_std: float,
		p_mean: float, p_std: float,
		t_mean: float, t_std: float) -> PackedFloat32Array:
	var temp: PackedFloat32Array = s.get("temperature_2m", PackedFloat32Array())
	var cloud: PackedFloat32Array = s.get("cloud_cover", PackedFloat32Array())
	var wind: PackedFloat32Array = s.get("wind_speed_10m", PackedFloat32Array())
	var precip: PackedFloat32Array = s.get("precipitation", PackedFloat32Array())
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	out.fill(NAN)
	# 4 z-scored terms summed → variance up to ~4; divide by 2 to target ~unit scale.
	const COMPOSITE_SCALE := 2.0
	for doy in range(DAYS_PER_YEAR):
		var base := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else NAN
		var td := _daily_mean_at_doy(temp, doy)
		if is_nan(td) or is_nan(base):
			continue
		var zt := ((td - base) - t_mean) / t_std
		var cd := _daily_mean_at_doy(cloud, doy)
		var zc := (((cd if not is_nan(cd) else c_mean) - c_mean) / c_std)
		var wd := _daily_mean_at_doy(wind, doy)
		var zw := (((wd if not is_nan(wd) else w_mean) - w_mean) / w_std)
		var zp := ((sqrt(_day_precip_sum(precip, doy)) - p_mean) / p_std)
		out[doy] = (zc + zp + zw - zt) / COMPOSITE_SCALE
	return out


func begin_year(master_seed: int, target_year: int) -> void:
	_master_seed = master_seed
	_target_year = target_year
	_reset_ar_state()
	_year_started = true
	_last_completed_doy = -1
	_effective_state_seeded = false


func set_effective_hoy(hoy: int) -> void:
	_effective_hoy = maxi(hoy, 0)


## Observer location used by the physical radiation model (Phase 6a).
func set_location(lat: float, lon: float) -> void:
	_lat = clampf(lat, -89.9, 89.9)
	_lon = clampf(lon, -180.0, 180.0)


func _reset_ar_state() -> void:
	_temp_ar = 0.0
	_cloud_ar = 0.0
	_wind_ar = 0.0
	_wind_dir_cx = 1.0
	_wind_dir_sx = 0.0
	_prev_wet = false
	_wind_dir_seeded = false
	_regime = 0.0
	_markov_wet = false


func is_trained() -> bool:
	return _trained


func get_regime_phi() -> float:
	return _regime_phi


func get_temp_ou_theta(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _temp_ou_theta.size():
		return _temp_ou_theta[month_idx]
	return clampf(1.0 - _temp_ar_phi, 0.08, 0.75)


func get_temp_ou_sigma(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _temp_ou_sigma.size():
		return _temp_ou_sigma[month_idx]
	return _temp_daily_std


func get_precip_gamma_k(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _precip_gamma_k.size():
		return _precip_gamma_k[month_idx]
	return 2.0


func get_month_wet_day_target(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _month_wet_day_target.size():
		return _month_wet_day_target[month_idx]
	return 0.0


func get_cloud_ar_phi() -> float:
	return _cloud_ar_phi


func get_wind_ar_phi(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _wind_ar_phi.size():
		return _wind_ar_phi[month_idx]
	return 0.55


func get_wind_dir_phi(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _wind_dir_phi.size():
		return _wind_dir_phi[month_idx]
	return 0.65


func get_rh_td_slope(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _rh_td_slope.size():
		return _rh_td_slope[month_idx]
	return 0.88


func get_rh_td_intercept(month_idx: int) -> float:
	if month_idx >= 0 and month_idx < _rh_td_intercept.size():
		return _rh_td_intercept[month_idx]
	return 2.0


func get_rh_td_hourly_track() -> float:
	return _rh_td_hourly_track


## Advance the regime latent one day. Deterministic via _day_rng("regime", doy);
## innovation scaled so the stationary variance stays ~1.
func _advance_regime(doy: int) -> void:
	var rng := _day_rng("regime", doy)
	_regime = _regime_phi * _regime + rng.randfn() * _regime_innov_std
	_regime = clampf(_regime, -3.5, 3.5)


## Testing hook: deterministic regime series for one year (no full generation).
## Mirrors begin_year + per-day advance, honoring the effective_hoy handoff.
func debug_regime_series(master_seed: int, target_year: int, effective_hoy: int = 0) -> PackedFloat32Array:
	var saved := [_master_seed, _target_year, _effective_hoy, _regime]
	_master_seed = master_seed
	_target_year = target_year
	_effective_hoy = maxi(effective_hoy, 0)
	_regime = 0.0
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	out.fill(NAN)
	for doy in range(DAYS_PER_YEAR):
		if _effective_hoy > 0 and doy * 24 < _effective_hoy:
			continue
		_advance_regime(doy)
		out[doy] = _regime
	_master_seed = saved[0]
	_target_year = saved[1]
	_effective_hoy = saved[2]
	_regime = saved[3]
	return out


## Fill one calendar month into out_series (var -> PackedFloat32Array 8760).
## climate_delta(month) -> °C shift; precip_factor(month) -> multiplier.
func generate_month(
		month: int,
		out_series: Dictionary,
		climate_delta: Callable,
		precip_factor: Callable,
) -> void:
	assert(_trained and _year_started)
	var mo := clampi(month, 1, 12)
	var days := _days_in_month(mo)

	for d in range(days):
		var doy := _DAYS_BEFORE_MONTH[mo - 1] + d
		if doy <= _last_completed_doy:
			continue
		_generate_day(doy, mo, out_series, climate_delta, precip_factor)
		_last_completed_doy = doy

	_reconcile_month_wet_count(mo, out_series, precip_factor)


func _generate_day(
		doy: int,
		mo: int,
		out_series: Dictionary,
		climate_delta: Callable,
		precip_factor: Callable,
) -> void:
	var day_hoy := doy * 24
	if _effective_hoy > 0 and day_hoy < _effective_hoy:
		return

	var mi := mo - 1
	var delta_t := _callable_float(climate_delta, mo)
	var pf := _callable_float(precip_factor, mo)
	if is_nan(delta_t):
		delta_t = 0.0
	if is_nan(pf) or pf <= 0.0:
		pf = 1.0

	# Fresh AR/Markov state at the first consumed day so hidden June evolution
	# (before the forecast handoff) cannot poison July temperatures.
	if _effective_hoy > 0 and day_hoy >= _effective_hoy and not _effective_state_seeded:
		_reset_ar_state()
		var rng_seed := _day_rng("precip", doy)
		_markov_wet = rng_seed.randf() < clampf(_month_wet_prob[mi], 0.02, 0.98)
		var mu_rad := deg_to_rad(_wind_dir_month[mi])
		_wind_dir_cx = cos(mu_rad)
		_wind_dir_sx = sin(mu_rad)
		_wind_dir_seeded = true
		_effective_state_seeded = true

	# --- Shared daily weather regime latent (Phase 2) ---
	# Deterministic AR(1); positive = stormier. Drives a small cross-variable
	# nudge here; later phases couple temp/wind/radiation through it too.
	_advance_regime(doy)

	# --- Precipitation Markov wet/dry (Phase 4: regime-coupled P(wet), Gamma amounts) ---
	var rng_p := _day_rng("precip", doy)
	var p_base := (_markov_p_wet_given_wet[mi] if _markov_wet else _markov_p_wet_given_dry[mi]) * pf
	var p_eff := clampf(p_base + _regime * 0.08, 0.02, 0.98)
	_markov_wet = rng_p.randf() < p_eff
	var day_precip := 0.0
	if _markov_wet:
		var gk := _precip_gamma_k[mi] if mi < _precip_gamma_k.size() else 2.0
		var gtheta := _precip_gamma_theta[mi] if mi < _precip_gamma_theta.size() else maxf(_wet_day_amount_mean[mi] * pf / 2.0, 0.05)
		day_precip = _sample_gamma(rng_p, gk, gtheta) * pf
		day_precip = maxf(day_precip, WET_DAY_MM)

	# --- Temperature OU daily anomaly (Phase 3) ---
	var rng_t := _day_rng("temp", doy)
	var base_t := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else 15.0
	if is_nan(base_t):
		base_t = 15.0
	var clim_t := base_t + delta_t
	var spread := _temp_doy_spread[doy] if doy < _temp_doy_spread.size() else 0.0
	var theta := get_temp_ou_theta(mi)
	var sigma := get_temp_ou_sigma(mi)
	if spread > 0.01:
		sigma = maxf(sigma, spread * 0.35)
	_temp_ar = _temp_ar + theta * (0.0 - _temp_ar) + rng_t.randfn() * sigma
	# Soft anomaly guard — prevents multi-week drift without tight daily margins.
	_temp_ar = clampf(_temp_ar, -3.0 * sigma, 3.0 * sigma)
	# Stormy regime (positive) → cooler; replaces the old wet-day −1.5 °C hack.
	var regime_temp := clampf(-_regime * 1.25, -2.8, 0.8)
	var daily_t := clim_t + _temp_ar + regime_temp
	# Soft daily guard — OU mean-reversion handles persistence; no tight AR clamp.
	daily_t = clampf(daily_t, clim_t - 22.0, clim_t + 22.0)

	# --- Cloud AR(1) with fitted phi + regime + post-wet decay (Phase 5) ---
	var rng_c := _day_rng("cloud", doy)
	var base_c := _cloud_doy_mean[doy] if doy < _cloud_doy_mean.size() else 40.0
	if is_nan(base_c):
		base_c = 40.0
	var c_spread := _cloud_doy_spread[doy] if doy < _cloud_doy_spread.size() else 0.0
	var cloud_sigma := _cloud_ar_sigma[mi] if mi < _cloud_ar_sigma.size() else 8.0
	if c_spread > 0.01:
		cloud_sigma = maxf(cloud_sigma, c_spread * 0.25)
	var cloud_innov := rng_c.randfn() * maxf(cloud_sigma, 4.0)
	_cloud_ar = _cloud_ar_phi * _cloud_ar + cloud_innov
	if _prev_wet and not _markov_wet:
		_cloud_ar -= _cloud_wet_decay
	var regime_cloud := _regime * 5.0
	var daily_cloud := clampf(base_c + _cloud_ar + (35.0 if _markov_wet else 0.0) + regime_cloud, 0.0, 100.0)
	_prev_wet = _markov_wet

	# --- Wind daily-mean AR(1) + regime; Weibull sub-daily residual (Phase 5) ---
	var rng_w := _day_rng("wind", doy)
	var base_w := _wind_doy_mean[doy] if doy < _wind_doy_mean.size() else _wind_month_scale[mi]
	if is_nan(base_w):
		base_w = _wind_month_scale[mi]
	var w_spread := _wind_doy_spread[doy] if doy < _wind_doy_spread.size() else 0.0
	var w_phi := _wind_ar_phi[mi] if mi < _wind_ar_phi.size() else 0.55
	var w_sigma := _wind_ar_sigma[mi] if mi < _wind_ar_sigma.size() else 1.5
	if w_spread > 0.01:
		w_sigma = maxf(w_sigma, w_spread * 0.3)
	_wind_ar = w_phi * _wind_ar + rng_w.randfn() * w_sigma
	_wind_ar = clampf(_wind_ar, -2.5 * w_sigma, 2.5 * w_sigma)
	var regime_wind := clampf(_regime * 1.8, -2.0, 4.0)
	var daily_wind := maxf(base_w + _wind_ar + regime_wind, 0.5)

	# --- Circular AR(1) wind direction (Phase 5) ---
	var rng_d := _day_rng("wdir", doy)
	if not _wind_dir_seeded:
		var mu0 := deg_to_rad(_wind_dir_month[mi])
		_wind_dir_cx = cos(mu0)
		_wind_dir_sx = sin(mu0)
		_wind_dir_seeded = true
	var mu_rad := deg_to_rad(_wind_dir_month[mi])
	var mu_c := cos(mu_rad)
	var mu_s := sin(mu_rad)
	var d_phi := _wind_dir_phi[mi] if mi < _wind_dir_phi.size() else 0.65
	var d_sigma := _wind_dir_sigma[mi] if mi < _wind_dir_sigma.size() else 0.12
	_wind_dir_cx = d_phi * _wind_dir_cx + (1.0 - d_phi) * mu_c + rng_d.randfn() * d_sigma
	_wind_dir_sx = d_phi * _wind_dir_sx + (1.0 - d_phi) * mu_s + rng_d.randfn() * d_sigma
	var dir_norm := sqrt(_wind_dir_cx * _wind_dir_cx + _wind_dir_sx * _wind_dir_sx)
	if dir_norm > 1e-6:
		_wind_dir_cx /= dir_norm
		_wind_dir_sx /= dir_norm
	else:
		_wind_dir_cx = mu_c
		_wind_dir_sx = mu_s
	var dir := rad_to_deg(atan2(_wind_dir_sx, _wind_dir_cx))
	if dir < 0.0:
		dir += 360.0

	# --- Humidity from fitted T–Td (Phase 6b; hourly RH via Magnus) ---
	var rng_h := _day_rng("rh", doy)
	var td_slope := _rh_td_slope[mi] if mi < _rh_td_slope.size() else 0.88
	var td_intercept := _rh_td_intercept[mi] if mi < _rh_td_intercept.size() else 2.0
	var td_sigma := _rh_td_sigma[mi] if mi < _rh_td_sigma.size() else 1.5

	var diur_t := _diurnal("temperature_2m", mi)
	var diur_c := _diurnal("cloud_cover", mi)
	var diur_w := _diurnal("wind_speed_10m", mi)
	var ph_shape := _precip_hour_shape[mi]
	var wb_k := maxf(_wind_month_shape[mi], 1.2)
	var wb_mean := _weibull_unit_mean(wb_k)

	var tpl_temp: PackedFloat32Array = _doy_hourly.get("temperature_2m", PackedFloat32Array())

	# Physical radiation geometry (Phase 6a): clear-sky from solar position, cloud
	# attenuation via Kasten & Czeplak (1980), diffuse split via Erbs et al. (1982).
	var dom := doy - _DAYS_BEFORE_MONTH[mi] + 1          # day-of-month (1-based)
	# Earth–Sun distance correction (Spencer 1971, leading term).
	var ecc := 1.0 + 0.033 * cos(TAU * float(doy) / 365.0)
	# Map local data hour to UTC via longitude mean-solar-time offset so the
	# clear-sky peak aligns with the local-time training grid (timezone=auto).
	var utc_offset_h := _lon / 15.0

	for h in range(24):
		var idx := doy * 24 + h
		if idx >= HOURS_PER_YEAR:
			continue
		# Additive diurnal: preserve the training year's absolute hourly deviation
		# from its daily mean. Multiplicative scaling (daily_t * ratio) turns any
		# negative daily_t from AR drift into sub-freezing hours — the July crash.
		var t := daily_t
		if idx < tpl_temp.size() and not is_nan(tpl_temp[idx]):
			var tpl_mean := _temp_doy_mean[doy] if doy < _temp_doy_mean.size() else NAN
			if not is_nan(tpl_mean):
				t = daily_t + (tpl_temp[idx] - tpl_mean)
			else:
				t = daily_t + (diur_t[h] - 1.0) * maxf(absf(clim_t) * 0.12, 4.0)
		else:
			t = daily_t + (diur_t[h] - 1.0) * maxf(absf(clim_t) * 0.12, 4.0)
		t += rng_t.randfn() * 0.3
		t = clampf(t, -55.0, 55.0)
		# Warm-season soft floor: prevent spurious sub-freezing hours when
		# climatology is temperate (OU anomaly + night diurnal can dip slightly below 0).
		if clim_t > 8.0:
			t = maxf(t, 0.5)
		var c := clampf(daily_cloud + (diur_c[h] - 1.0) * 15.0, 0.0, 100.0)
		var rng_wh := _day_rng("wind_h", doy * 24 + h)
		var wh := pow(maxf(rng_wh.randf(), 1e-6), 1.0 / wb_k)
		var w := maxf(daily_wind * diur_w[h] * (wh / wb_mean), 0.0)
		var td_daily := td_intercept + td_slope * daily_t
		if _markov_wet:
			td_daily += 1.8
		td_daily += clampf(_regime * 0.35, -0.5, 1.2)
		td_daily += rng_h.randfn() * td_sigma
		# Dew point follows the daily T–Td fit; only a fraction of the hourly T swing
		# is passed through so afternoon warming lowers RH (typical boundary layer).
		var td := td_daily + _rh_td_hourly_track * (t - daily_t)
		td = minf(td, t - 0.5)
		var rh := rh_from_dewpoint_c(t, td)
		var pr := day_precip * ph_shape[h] if _markov_wet else 0.0

		var cloud_frac := c / 100.0
		var sw := 0.0
		var df := 0.0
		var jd_utc := _julian_day_utc(_target_year, mo, dom, float(h) - utc_offset_h)
		var cos_z: float = SolarPosition.get_position(_lat, _lon, jd_utc).get("cos_zenith", 0.0)
		if cos_z > 0.02:
			# Haurwitz (1945) clear-sky global horizontal irradiance ceiling.
			var clear := 1098.0 * cos_z * exp(-0.057 / cos_z) * ecc
			# Kasten & Czeplak (1980): GHI = GHI_clear * (1 − 0.75·(N)^3.4), N in [0,1].
			var cloud_trans := 1.0 - 0.75 * pow(cloud_frac, 3.4)
			# Stormy regime damps transmittance slightly (thicker/optically deeper cloud).
			cloud_trans *= clampf(1.0 - maxf(_regime, 0.0) * 0.03, 0.6, 1.0)
			# Small deterministic clearness scatter (mean ≈ 1; does not bias monthly means).
			var rng_g := _day_rng("ghi", idx)
			var scatter := clampf(1.0 + rng_g.randfn() * 0.03, 0.85, 1.12)
			sw = maxf(clear * cloud_trans * scatter, 0.0)
			# Erbs et al. (1982) diffuse fraction from the clearness index Kt.
			var i0_horiz := 1361.0 * ecc * cos_z
			var kt := clampf(sw / maxf(i0_horiz, 1e-3), 0.0, 1.0)
			var diff_frac: float
			if kt <= 0.22:
				diff_frac = 1.0 - 0.09 * kt
			elif kt <= 0.80:
				diff_frac = 0.9511 - 0.1604 * kt + 4.388 * kt * kt \
					- 16.638 * kt * kt * kt + 12.336 * kt * kt * kt * kt
			else:
				diff_frac = 0.165
			df = clampf(diff_frac, 0.0, 1.0) * sw

		_write(out_series, "temperature_2m", idx, t)
		_write(out_series, "cloud_cover", idx, c)
		_write(out_series, "wind_speed_10m", idx, w)
		_write(out_series, "wind_direction_10m", idx, dir + rng_d.randfn() * 5.0)
		_write(out_series, "relative_humidity_2m", idx, rh)
		_write(out_series, "precipitation", idx, pr)
		_write(out_series, "shortwave_radiation", idx, maxf(sw, 0.0))
		_write(out_series, "diffuse_radiation", idx, maxf(df, 0.0))


func _diurnal(vname: String, month_idx: int) -> PackedFloat32Array:
	if _month_diurnal.has(vname):
		var months: Array = _month_diurnal[vname]
		if month_idx >= 0 and month_idx < months.size():
			var prof: Variant = months[month_idx]
			if prof is PackedFloat32Array:
				return prof as PackedFloat32Array
	return _flat_diurnal()


func _write(out_series: Dictionary, vname: String, idx: int, val: float) -> void:
	if not out_series.has(vname):
		var arr := PackedFloat32Array()
		arr.resize(HOURS_PER_YEAR)
		arr.fill(NAN)
		out_series[vname] = arr
	var arr: PackedFloat32Array = out_series[vname]
	if idx < arr.size():
		# Never write a non-finite value: generated weather is sampled into the
		# sky shader and DirectionalLight energy, where a NaN/Inf hangs the GPU.
		arr[idx] = val if is_finite(val) else 0.0


func _day_rng(component: String, doy: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(_master_seed ^ (_target_year * 7919) ^ (doy * 104729) ^ component.hash())
	return rng


## Marsaglia-Tsang Gamma(shape, scale) draw (scale = θ, mean = k·θ).
static func _sample_gamma(rng: RandomNumberGenerator, shape: float, scale: float) -> float:
	shape = maxf(shape, 0.35)
	scale = maxf(scale, 0.02)
	if shape < 1.0:
		return _sample_gamma(rng, shape + 1.0, scale) * pow(maxf(rng.randf(), 1e-9), 1.0 / shape)
	var d := shape - 1.0 / 3.0
	var c := 1.0 / sqrt(9.0 * d)
	while true:
		var x := rng.randfn()
		var v := 1.0 + c * x
		if v <= 0.0:
			continue
		v = v * v * v
		var u := maxf(rng.randf(), 1e-9)
		if u < 1.0 - 0.0331 * x * x * x * x:
			return d * v * scale
		if log(u) < 0.5 * x * x + d * (1.0 - v + log(maxf(v, 1e-9))):
			return d * v * scale
	return shape * scale


## Julian Day for a UTC calendar instant (Meeus, "Astronomical Algorithms" eq. 7.1,
## Gregorian calendar). hour_utc may be fractional or outside [0,24) — the fraction
## carries correctly into the day count.
static func _julian_day_utc(year: int, month: int, day: int, hour_utc: float) -> float:
	var y := year
	var m := month
	var d := float(day) + hour_utc / 24.0
	if m <= 2:
		y -= 1
		m += 12
	var a := floori(float(y) / 100.0)
	var b := 2 - a + floori(float(a) / 4.0)
	return floor(365.25 * float(y + 4716)) + floor(30.6001 * float(m + 1)) \
		+ d + float(b) - 1524.5


## Mean of Weibull(shape, scale=1) = Γ(1 + 1/shape).
static func _weibull_unit_mean(shape: float) -> float:
	return _gamma_lanczos(1.0 + 1.0 / maxf(shape, 1.2))


## Lanczos Γ(x) for x > 0 (Godot has no lgamma).
static func _gamma_lanczos(x: float) -> float:
	var c := [
		0.99999999999980993, 676.5203681218851, -1259.1392167224028,
		771.32342877765313, -176.61502916214059, 12.507343278686905,
		-0.13857109526572012, 9.984369578019571e-6, 1.505908729006556e-7,
	]
	if x < 0.5:
		return PI / (sin(PI * x) * _gamma_lanczos(1.0 - x))
	x -= 1.0
	var a: float = c[0]
	for i in range(1, 8):
		a += c[i] / (x + float(i))
	var t := x + 7.5
	return sqrt(TAU) * pow(t, x + 0.5) * exp(-t) * a


## Nudge generated month wet-day count toward training mean (deterministic).
func _reconcile_month_wet_count(mo: int, out_series: Dictionary, precip_factor: Callable) -> void:
	var mi := mo - 1
	var pf := _callable_float(precip_factor, mo)
	if is_nan(pf) or pf <= 0.0:
		pf = 1.0
	var days := _days_in_month(mo)
	var start_doy := _DAYS_BEFORE_MONTH[mi]
	var target := roundi(_month_wet_day_target[mi] * pf)
	target = clampi(target, 0, days)

	var precip: PackedFloat32Array = out_series.get("precipitation", PackedFloat32Array())
	var wet_days: Array[int] = []
	var dry_days: Array[int] = []
	for d in range(days):
		var doy := start_doy + d
		if _effective_hoy > 0 and doy * 24 < _effective_hoy:
			continue
		var day_p := _day_precip_sum(precip, doy)
		if day_p >= WET_DAY_MM:
			wet_days.append(doy)
		else:
			dry_days.append(doy)

	var deficit := target - wet_days.size()
	if deficit > 0:
		dry_days.sort_custom(func(a: int, b: int) -> bool:
			return _day_rng("precip_fix", a).randf() > _day_rng("precip_fix", b).randf()
		)
		for i in mini(deficit, dry_days.size()):
			_inject_wet_day(dry_days[i], mi, out_series, pf)
	elif deficit < 0:
		wet_days.sort_custom(func(a: int, b: int) -> bool:
			var pa := _day_precip_sum(precip, a)
			var pb := _day_precip_sum(precip, b)
			if absf(pa - pb) > 0.001:
				return pa < pb
			return _day_rng("precip_fix", a).randf() < _day_rng("precip_fix", b).randf()
		)
		for i in mini(-deficit, wet_days.size()):
			_clear_day_precip(wet_days[i], out_series)

	# Keep Markov wet state aligned with the reconciled last day of the month.
	var last_doy := start_doy + days - 1
	if _effective_hoy <= 0 or last_doy * 24 >= _effective_hoy:
		precip = out_series.get("precipitation", PackedFloat32Array())
		_markov_wet = _day_precip_sum(precip, last_doy) >= WET_DAY_MM


func _inject_wet_day(doy: int, mi: int, out_series: Dictionary, pf: float) -> void:
	var rng := _day_rng("precip_fix", doy)
	var gk := _precip_gamma_k[mi] if mi < _precip_gamma_k.size() else 2.0
	var gtheta := _precip_gamma_theta[mi] if mi < _precip_gamma_theta.size() else 0.5
	var day_precip := maxf(_sample_gamma(rng, gk, gtheta) * pf, WET_DAY_MM)
	var ph_shape := _precip_hour_shape[mi]
	for h in range(24):
		var idx := doy * 24 + h
		_write(out_series, "precipitation", idx, day_precip * ph_shape[h])


func _clear_day_precip(doy: int, out_series: Dictionary) -> void:
	for h in range(24):
		var idx := doy * 24 + h
		_write(out_series, "precipitation", idx, 0.0)


static func _days_in_month(month: int) -> int:
	match clampi(month, 1, 12):
		2:  return 28
		4, 6, 9, 11:  return 30
		_:  return 31


static func _flat_diurnal() -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(24)
	for h in range(24):
		a[h] = 1.0
	return a


static func _daily_mean_from_hourly(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	out.fill(NAN)
	if hourly.is_empty():
		return out
	for doy in range(DAYS_PER_YEAR):
		var sum := 0.0
		var n := 0
		for h in range(24):
			var idx := doy * 24 + h
			if idx < hourly.size():
				var v := hourly[idx]
				if not is_nan(v):
					sum += v
					n += 1
		if n > 0:
			out[doy] = sum / float(n)
	return out


static func _daily_values_from_hourly(hourly: PackedFloat32Array) -> Array[float]:
	var out: Array[float] = []
	for doy in range(DAYS_PER_YEAR):
		var sum := 0.0
		var n := 0
		for h in range(24):
			var idx := doy * 24 + h
			if idx < hourly.size():
				var v := hourly[idx]
				if not is_nan(v):
					sum += v
					n += 1
		if n > 0:
			out.append(sum / float(n))
	return out


static func _day_precip_sum(precip: PackedFloat32Array, doy: int) -> float:
	var sum := 0.0
	for h in range(24):
		var idx := doy * 24 + h
		if idx < precip.size():
			var v := precip[idx]
			if not is_nan(v):
				sum += maxf(v, 0.0)
	return sum


static func _build_month_diurnal(hourly: PackedFloat32Array) -> Array:
	var months: Array = []
	months.resize(12)
	for mo in range(12):
		var prof := PackedFloat32Array()
		prof.resize(24)
		var hour_sum: Array[float] = []
		hour_sum.resize(24)
		for h in range(24):
			hour_sum[h] = 0.0
		var hour_n: Array[int] = []
		hour_n.resize(24)
		for h in range(24):
			hour_n[h] = 0
		for d in range(_days_in_month(mo + 1)):
			var doy := _DAYS_BEFORE_MONTH[mo] + d
			var day_mean := 0.0
			var dn := 0
			for h in range(24):
				var idx := doy * 24 + h
				if idx < hourly.size():
					var v := hourly[idx]
					if not is_nan(v):
						day_mean += v
						dn += 1
			if dn <= 0:
				continue
			day_mean /= float(dn)
			for h in range(24):
				var idx := doy * 24 + h
				if idx < hourly.size():
					var v := hourly[idx]
					if not is_nan(v) and absf(day_mean) > 0.01:
						hour_sum[h] += v / day_mean
						hour_n[h] += 1
		for h in range(24):
			if hour_n[h] > 0:
				prof[h] = hour_sum[h] / float(hour_n[h])
			else:
				prof[h] = 1.0
		months[mo] = prof
	return months


static func _merge_series_mean(series_by_year: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for vname in VAR_NAMES:
		var acc := PackedFloat32Array()
		acc.resize(HOURS_PER_YEAR)
		acc.fill(0.0)
		var n := PackedInt32Array()
		n.resize(HOURS_PER_YEAR)
		n.fill(0)
		for yr in series_by_year.keys():
			var arr: PackedFloat32Array = series_by_year[yr].get(vname, PackedFloat32Array())
			for i in mini(arr.size(), HOURS_PER_YEAR):
				if not is_nan(arr[i]):
					acc[i] += arr[i]
					n[i] += 1
		var mean := PackedFloat32Array()
		mean.resize(HOURS_PER_YEAR)
		mean.fill(NAN)
		for i in HOURS_PER_YEAR:
			if n[i] > 0:
				mean[i] = acc[i] / float(n[i])
		out[vname] = mean
	return out


static func _daily_mean_at_doy(hourly: PackedFloat32Array, doy: int) -> float:
	if hourly.is_empty() or doy < 0 or doy >= DAYS_PER_YEAR:
		return NAN
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


static func _array_mean(values: Array[float]) -> float:
	if values.is_empty():
		return NAN
	var sum := 0.0
	for v in values:
		sum += v
	return sum / float(values.size())


static func _array_min(values: Array[float]) -> float:
	var mn := values[0]
	for v in values:
		mn = minf(mn, v)
	return mn


static func _array_max(values: Array[float]) -> float:
	var mx := values[0]
	for v in values:
		mx = maxf(mx, v)
	return mx


## Serialize one generated year for disk cache.
static func series_to_dict(series: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in series.keys():
		var arr: PackedFloat32Array = series[k]
		var packed: Array = []
		packed.resize(arr.size())
		for i in arr.size():
			var v := arr[i]
			# JSON cannot represent NaN; null round-trips back to NAN in series_from_dict.
			packed[i] = null if is_nan(v) else v
		out[k] = packed
	return out


static func series_from_dict(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d.keys():
		var raw: Variant = d[k]
		if not (raw is Array):
			continue
		var arr := PackedFloat32Array()
		arr.resize((raw as Array).size())
		for i in arr.size():
			arr[i] = _variant_to_float((raw as Array)[i])
		out[k] = arr
	return out


static func _variant_to_float(v: Variant) -> float:
	if v == null:
		return NAN
	if v is float or v is int:
		return float(v)
	return NAN


static func _callable_float(fn: Callable, arg: Variant) -> float:
	var result: Variant = fn.call(arg)
	return _variant_to_float(result)

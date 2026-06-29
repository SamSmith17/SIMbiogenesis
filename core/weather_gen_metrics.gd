class_name WeatherGenMetrics
extends RefCounted

## Pure static helpers for weather-gen distributional validation.
## Used by weather_gen_selftest.gd; no dependency on StochasticWeatherGenerator state.

const HOURS_PER_YEAR := 8760
const DAYS_PER_YEAR := 365
const WET_DAY_MM := 0.1
const _DAYS_BEFORE_MONTH: Array[int] = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


static func day_precip_sum(precip: PackedFloat32Array, doy: int) -> float:
	var sum := 0.0
	for h in range(24):
		var idx := doy * 24 + h
		if idx < precip.size():
			var v := precip[idx]
			if not is_nan(v):
				sum += maxf(v, 0.0)
	return sum


static func daily_wet_flags(precip: PackedFloat32Array, threshold: float = WET_DAY_MM) -> Array[bool]:
	var flags: Array[bool] = []
	flags.resize(DAYS_PER_YEAR)
	for doy in range(DAYS_PER_YEAR):
		flags[doy] = day_precip_sum(precip, doy) >= threshold
	return flags


static func monthly_wet_day_counts(precip: PackedFloat32Array) -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(12)
	for mo in range(12):
		var wet := 0
		for d in range(_days_in_month(mo + 1)):
			var doy := _DAYS_BEFORE_MONTH[mo] + d
			if day_precip_sum(precip, doy) >= WET_DAY_MM:
				wet += 1
		counts[mo] = wet
	return counts


static func spell_lengths(wet_flags: Array) -> Dictionary:
	var wet_spells: Array[int] = []
	var dry_spells: Array[int] = []
	var run := 0
	var in_wet := false
	if wet_flags.is_empty():
		return {"wet": wet_spells, "dry": dry_spells}
	in_wet = bool(wet_flags[0])
	for i in wet_flags.size():
		var w := bool(wet_flags[i])
		if w == in_wet:
			run += 1
		else:
			if in_wet:
				wet_spells.append(run)
			else:
				dry_spells.append(run)
			run = 1
			in_wet = w
	if run > 0:
		if in_wet:
			wet_spells.append(run)
		else:
			dry_spells.append(run)
	return {"wet": wet_spells, "dry": dry_spells}


static func max_spell_length(spells: Array) -> int:
	var mx := 0
	for s in spells:
		mx = maxi(mx, int(s))
	return mx


## p90 / mean of daily wet-day totals (heavy-tail guard for Gamma amounts).
static func wet_day_amount_p90_ratio(precip: PackedFloat32Array) -> float:
	var amounts: Array[float] = []
	for doy in range(DAYS_PER_YEAR):
		var d := day_precip_sum(precip, doy)
		if d >= WET_DAY_MM:
			amounts.append(d)
	if amounts.is_empty():
		return NAN
	amounts.sort()
	var mean := 0.0
	for a in amounts:
		mean += a
	mean /= float(amounts.size())
	if mean < 0.01:
		return NAN
	var p90_idx := clampi(int(floor(float(amounts.size() - 1) * 0.9)), 0, amounts.size() - 1)
	return amounts[p90_idx] / mean


static func daily_means_from_hourly(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	out.fill(NAN)
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


static func daily_min_max_from_hourly(hourly: PackedFloat32Array) -> Dictionary:
	var mins := PackedFloat32Array()
	var maxs := PackedFloat32Array()
	mins.resize(DAYS_PER_YEAR)
	maxs.resize(DAYS_PER_YEAR)
	mins.fill(NAN)
	maxs.fill(NAN)
	for doy in range(DAYS_PER_YEAR):
		var lo := INF
		var hi := -INF
		var n := 0
		for h in range(24):
			var idx := doy * 24 + h
			if idx < hourly.size():
				var v := hourly[idx]
				if not is_nan(v):
					lo = minf(lo, v)
					hi = maxf(hi, v)
					n += 1
		if n > 0:
			mins[doy] = lo
			maxs[doy] = hi
	return {"min": mins, "max": maxs}


static func lag1_autocorr(daily: PackedFloat32Array) -> float:
	var vals: Array[float] = []
	for doy in range(daily.size()):
		var v := daily[doy]
		if not is_nan(v):
			vals.append(v)
	if vals.size() < 3:
		return NAN
	var mean := 0.0
	for v in vals:
		mean += v
	mean /= float(vals.size())
	var num := 0.0
	var den := 0.0
	for i in range(1, vals.size()):
		var a := vals[i] - mean
		var b := vals[i - 1] - mean
		num += a * b
		den += b * b
	return num / maxf(den, 1e-9)


static func seasonal_lag1_autocorr(daily: PackedFloat32Array, doy_start: int, doy_end: int) -> float:
	var slice := PackedFloat32Array()
	var n := maxi(0, doy_end - doy_start + 1)
	slice.resize(n)
	for i in n:
		var doy := doy_start + i
		slice[i] = daily[doy] if doy < daily.size() else NAN
	return lag1_autocorr(slice)


## Mean cos(Δθ) between consecutive daily wind directions (0=random, 1=locked).
static func directional_lag1_autocorr(dirs_deg: PackedFloat32Array) -> float:
	var sum := 0.0
	var n := 0
	for i in range(1, dirs_deg.size()):
		var a := dirs_deg[i]
		var b := dirs_deg[i - 1]
		if is_nan(a) or is_nan(b):
			continue
		sum += cos(deg_to_rad(a - b))
		n += 1
	return sum / float(maxi(n, 1)) if n > 0 else NAN


## Pearson r between two aligned hourly series (skips NaN slots).
static func pearson_correlation_hourly(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var n := mini(a.size(), b.size())
	if n < 3:
		return NAN
	var xs: Array[float] = []
	var ys: Array[float] = []
	for i in n:
		if not is_nan(a[i]) and not is_nan(b[i]):
			xs.append(a[i])
			ys.append(b[i])
	var m := xs.size()
	if m < 3:
		return NAN
	var mx := 0.0
	var my := 0.0
	for i in m:
		mx += xs[i]
		my += ys[i]
	mx /= float(m)
	my /= float(m)
	var num := 0.0
	var den_x := 0.0
	var den_y := 0.0
	for i in m:
		var dx := xs[i] - mx
		var dy := ys[i] - my
		num += dx * dy
		den_x += dx * dx
		den_y += dy * dy
	var den := sqrt(den_x * den_y)
	return num / maxf(den, 1e-9)


## Pearson r on hourly anomalies (value − daily mean) — isolates the diurnal RH–T link.
static func pearson_correlation_diurnal_anomaly(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	var xs: Array[float] = []
	var ys: Array[float] = []
	for doy in range(DAYS_PER_YEAR):
		var sum_a := 0.0
		var sum_b := 0.0
		var n := 0
		for h in range(24):
			var idx := doy * 24 + h
			if idx >= a.size() or idx >= b.size():
				continue
			if is_nan(a[idx]) or is_nan(b[idx]):
				continue
			sum_a += a[idx]
			sum_b += b[idx]
			n += 1
		if n <= 0:
			continue
		var mean_a := sum_a / float(n)
		var mean_b := sum_b / float(n)
		for h in range(24):
			var idx := doy * 24 + h
			if idx >= a.size() or idx >= b.size():
				continue
			if is_nan(a[idx]) or is_nan(b[idx]):
				continue
			xs.append(a[idx] - mean_a)
			ys.append(b[idx] - mean_b)
	var m := xs.size()
	if m < 3:
		return NAN
	var mx := 0.0
	var my := 0.0
	for i in m:
		mx += xs[i]
		my += ys[i]
	mx /= float(m)
	my /= float(m)
	var num := 0.0
	var den_x := 0.0
	var den_y := 0.0
	for i in m:
		var dx := xs[i] - mx
		var dy := ys[i] - my
		num += dx * dy
		den_x += dx * dx
		den_y += dy * dy
	return num / maxf(sqrt(den_x * den_y), 1e-9)


static func monthly_hourly_mean(hourly: PackedFloat32Array, month_idx: int) -> float:
	var sum := 0.0
	var n := 0
	for d in range(_days_in_month(month_idx + 1)):
		var doy := _DAYS_BEFORE_MONTH[month_idx] + d
		for h in range(24):
			var idx := doy * 24 + h
			if idx < hourly.size():
				var v := hourly[idx]
				if not is_nan(v):
					sum += v
					n += 1
	return sum / float(maxi(n, 1))


static func monthly_means(hourly: PackedFloat32Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(12)
	for mo in range(12):
		out[mo] = monthly_hourly_mean(hourly, mo)
	return out


static func doy_daily_means_from_multi(series_by_year: Dictionary) -> PackedFloat32Array:
	var acc: Array[float] = []
	acc.resize(DAYS_PER_YEAR)
	acc.fill(0.0)
	var counts: Array[int] = []
	counts.resize(DAYS_PER_YEAR)
	counts.fill(0)
	for yr in series_by_year.keys():
		var hourly: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
		var daily := daily_means_from_hourly(hourly)
		for doy in range(DAYS_PER_YEAR):
			if not is_nan(daily[doy]):
				acc[doy] += daily[doy]
				counts[doy] += 1
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	for doy in range(DAYS_PER_YEAR):
		if counts[doy] > 0:
			out[doy] = acc[doy] / float(counts[doy])
		else:
			out[doy] = NAN
	return out


static func doy_spread_from_multi(series_by_year: Dictionary) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(DAYS_PER_YEAR)
	out.fill(0.0)
	for doy in range(DAYS_PER_YEAR):
		var vals: Array[float] = []
		for yr in series_by_year.keys():
			var hourly: PackedFloat32Array = series_by_year[yr].get("temperature_2m", PackedFloat32Array())
			var daily := daily_means_from_hourly(hourly)
			if not is_nan(daily[doy]):
				vals.append(daily[doy])
		if vals.size() >= 2:
			out[doy] = _array_max(vals) - _array_min(vals)
	return out


## Fraction of days where daily mean deviates from reference climatology by
## more than [max_anom_c] — detects anomaly drift / pile-up (Phase 3 OU guard).
static func temp_anomaly_exceed_fraction(
		gen_temp_hourly: PackedFloat32Array,
		ref_doy_mean: PackedFloat32Array,
		max_anom_c: float = 10.0,
		climate_delta: float = 0.0,
) -> float:
	var daily := daily_means_from_hourly(gen_temp_hourly)
	var exceed := 0
	var counted := 0
	for doy in range(DAYS_PER_YEAR):
		if is_nan(daily[doy]):
			continue
		var base := ref_doy_mean[doy] if doy < ref_doy_mean.size() else NAN
		if is_nan(base):
			continue
		counted += 1
		if absf(daily[doy] - base - climate_delta) > max_anom_c:
			exceed += 1
	return float(exceed) / float(maxi(counted, 1))


## Legacy margin pileup (tight clamp era); kept for comparison.
static func temp_clamp_pileup_fraction(
		gen_temp_hourly: PackedFloat32Array,
		ref_doy_mean: PackedFloat32Array,
		doy_spread: PackedFloat32Array,
		climate_delta: float = 0.0,
		edge_eps: float = 0.35,
) -> float:
	var mm := daily_min_max_from_hourly(gen_temp_hourly)
	var mins: PackedFloat32Array = mm["min"]
	var maxs: PackedFloat32Array = mm["max"]
	var pileup := 0
	var counted := 0
	for doy in range(DAYS_PER_YEAR):
		if is_nan(mins[doy]) or is_nan(maxs[doy]):
			continue
		var base := ref_doy_mean[doy] if doy < ref_doy_mean.size() else NAN
		if is_nan(base):
			continue
		var clim_t := base + climate_delta
		var spread := doy_spread[doy] if doy < doy_spread.size() else 0.0
		var t_margin := maxf(12.0, spread * 0.5 + 4.0) + 4.0
		var lo_bound := clim_t - t_margin
		var hi_bound := clim_t + t_margin
		counted += 1
		if mins[doy] <= lo_bound + edge_eps or maxs[doy] >= hi_bound - edge_eps:
			pileup += 1
	return float(pileup) / float(maxi(counted, 1))


## Fraction of hourly samples sitting on the wide physical safety clamp (±55 °C).
static func temp_safety_clamp_fraction(
		gen_temp_hourly: PackedFloat32Array,
		limit: float = 55.0,
		edge_eps: float = 0.05,
) -> float:
	var hits := 0
	var n := 0
	for i in mini(gen_temp_hourly.size(), HOURS_PER_YEAR):
		var v := gen_temp_hourly[i]
		if is_nan(v):
			continue
		n += 1
		if v <= -limit + edge_eps or v >= limit - edge_eps:
			hits += 1
	return float(hits) / float(maxi(n, 1))


## Minimum hourly temperature over a day-of-year range (inclusive).
static func min_hourly_temp_in_doy_range(
		hourly: PackedFloat32Array,
		doy_start: int,
		doy_end: int,
) -> float:
	var lo := INF
	for doy in range(maxi(0, doy_start), mini(DAYS_PER_YEAR, doy_end + 1)):
		for h in range(24):
			var idx := doy * 24 + h
			if idx < hourly.size():
				var v := hourly[idx]
				if not is_nan(v):
					lo = minf(lo, v)
	return lo if is_finite(lo) else NAN


static func mean_abs_monthly_bias(gen_monthly: PackedFloat32Array, ref_monthly: PackedFloat32Array) -> float:
	var sum := 0.0
	var n := 0
	for mo in range(mini(gen_monthly.size(), ref_monthly.size())):
		if ref_monthly[mo] == 0.0:
			continue
		sum += absf(gen_monthly[mo] - ref_monthly[mo])
		n += 1
	return sum / float(maxi(n, 1))


static func mean_rel_monthly_bias(gen_monthly: PackedFloat32Array, ref_monthly: PackedFloat32Array) -> float:
	var sum := 0.0
	var n := 0
	for mo in range(mini(gen_monthly.size(), ref_monthly.size())):
		var ref := ref_monthly[mo]
		if absf(ref) < 1e-6:
			continue
		sum += absf(gen_monthly[mo] - ref) / absf(ref)
		n += 1
	return sum / float(maxi(n, 1))


static func _days_in_month(month: int) -> int:
	match clampi(month, 1, 12):
		2:  return 28
		4, 6, 9, 11:  return 30
		_:  return 31


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

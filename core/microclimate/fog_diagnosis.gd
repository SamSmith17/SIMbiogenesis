class_name FogDiagnosis
extends RefCounted

## Automatic fog from the hourly weather data — no calibration required.
##
## Pure static. The resolver hands it a run of HOURLY rows (oldest → newest)
## and gets back a fog fraction 0..1 per hour; persistence and gap filling look
## along the run, so the answer for an hour is a pure function of the series,
## which is what makes it scrub backwards exactly (the ExtremeWeather rule).
##
## A row is { t_c, td_c, wind_ms, cloud, low, vis_m, sun_el } — cloud/low are
## 0..1, vis_m and low may be NAN. Three independent pieces of evidence, the
## worst wins:
##
## 1. GROUND CLOUD. ERA5 has no fog variable; a radiation fog shows up as
##    ~100 % LOW cloud at RH 100 % (dewpoint depression ≈ 0) — the cloud sits on
##    the ground. Measured at Walton OR, 2026-10-02/03: low cloud 99–100 % from
##    23 h to 08 h at T−Td ≤ 0.1 °C, gone by 10 h (T−Td 3.1 °C), against an
##    observed 22–23 h → 10–11 h fog. Rendered literally it is an overcast SKY,
##    so `ground_cloud` is reported for the caller to take back OUT of the
##    overhead cover.
## 2. MODEL VISIBILITY. Over CONUS the forecast feed is HRRR, whose own
##    visibility caught the same fog (100–500 m, 02 h → 11 h) while its T/RH
##    stayed 3–4 °C off saturation.
## 3. RADIATION-FOG INDEX, for data with neither (generated years, coarse
##    models): night × calm × clear-above × near-saturation. Radiation fog
##    needs all four — longwave cooling under a clear sky, little mixing, and
##    moisture (Gultepe et al. 2007, "Fog research: a review", Pure Appl.
##    Geophys. 164). Valley cold pools reach saturation hours before the grid
##    cell does, so a `cold_pool_bias_c` is subtracted from T−Td on calm clear
##    nights (Whiteman 2000, Mountain Meteorology ch. 8: nocturnal valley cold
##    pools run several °C under the surrounding air). With a 2 °C bias the
##    HRRR rows above form fog at 21–23 h instead of 02–06 h.
##
## Fog that has formed HOLDS until it burns off (sun up and T−Td past
## `burn_dep_c`) or the wind mixes it out, and one- or two-hour holes between
## foggy hours are filled — model fields flicker (HRRR's visibility jumped to
## 18.9 km for one hour mid-fog).

const DEFAULTS := {
	"cold_pool_bias_c": 0.0,
	"burn_dep_c": 3.0,       # T − Td at which a sunlit fog has burned off
	"wind_clear_ms": 6.0,    # mechanical mixing lifts / clears it
	"calm_lo_ms": 2.0,       # radiation index: full below …
	"calm_hi_ms": 4.5,       # … and gone above
	"sat_lo_c": 0.5,         # radiation index: full at T−Td below …
	"sat_hi_c": 2.0,         # … gone above
	"hold_h": 18,
	"gap_h": 2,
}

## Fog visibility: a barely-there fog (f→0) is the 1 km fog threshold, a dense
## valley fog (f = 1) about 80 m.
const VIS_THIN_M := 1000.0
const VIS_DENSE_M := 80.0


static func _ss(a: float, b: float, x: float) -> float:
	return smoothstep(a, b, x)


static func _p(params: Dictionary, k: String) -> float:
	return float(params.get(k, DEFAULTS[k]))


## Nocturnal cold-pool bias (°C) from the site's topographic position index
## (site elevation − mean of the surrounding ring, metres; negative = a hollow).
## 0.03 °C/m, capped at 3 °C — a 60 m-deep valley pools ~1.8 °C.
static func cold_pool_bias_for_tpi(tpi_m: float) -> float:
	if not is_finite(tpi_m) or tpi_m >= 0.0:
		return 0.0
	return clampf(-tpi_m * 0.03, 0.0, 3.0)


static func _night(sun_el: float) -> float:
	if not is_finite(sun_el):
		return 0.0
	return 1.0 - _ss(-4.0, 2.0, sun_el)


static func dep_eff(row: Dictionary, params: Dictionary = {}) -> float:
	var t := float(row.get("t_c", NAN))
	var td := float(row.get("td_c", NAN))
	if not (is_finite(t) and is_finite(td)):
		return NAN
	var dep := maxf(t - td, 0.0)
	var bias := _p(params, "cold_pool_bias_c")
	if bias <= 0.0:
		return dep
	var night := _night(float(row.get("sun_el", NAN)))
	return maxf(dep - bias * night * _calm(row, params) * _clear_above(row), 0.0)


static func _calm(row: Dictionary, params: Dictionary) -> float:
	var w := float(row.get("wind_ms", NAN))
	if not is_finite(w):
		return 0.5
	return 1.0 - _ss(_p(params, "calm_lo_ms"), _p(params, "calm_hi_ms"), w)


static func _clear_above(row: Dictionary) -> float:
	var cc := float(row.get("cloud", NAN))
	var low := float(row.get("low", NAN))
	if not is_finite(cc):
		return 0.5
	var above := maxf(cc - (low if is_finite(low) else 0.0), 0.0)
	return 1.0 - _ss(0.3, 0.7, above)


## Fog fraction for ONE hour, no persistence. Returns the three evidence terms
## too so the drawer can say WHY it thinks there is fog.
static func instant(row: Dictionary, params: Dictionary = {}) -> Dictionary:
	var t := float(row.get("t_c", NAN))
	var td := float(row.get("td_c", NAN))
	var dep := maxf(t - td, 0.0) if is_finite(t) and is_finite(td) else NAN
	var low := float(row.get("low", NAN))
	var f_ground := 0.0
	if is_finite(low) and is_finite(dep):
		f_ground = _ss(0.5, 0.9, low) * (1.0 - _ss(0.4, 1.5, dep))
	var f_vis := 0.0
	var vis := float(row.get("vis_m", NAN))
	if is_finite(vis) and vis < VIS_THIN_M:
		f_vis = 0.4 + 0.6 * clampf(log(VIS_THIN_M / maxf(vis, 1.0)) / log(10.0), 0.0, 1.0)
	var f_rad := 0.0
	var de := dep_eff(row, params)
	if is_finite(de):
		f_rad = _night(float(row.get("sun_el", NAN))) * _calm(row, params) \
			* _clear_above(row) * (1.0 - _ss(_p(params, "sat_lo_c"), _p(params, "sat_hi_c"), de))
	var f := maxf(f_ground, maxf(f_vis, f_rad))
	var src := "none"
	if f > 0.0:
		src = "ground_cloud" if f == f_ground else ("model_visibility" if f == f_vis else "radiation")
	return {"fog": f, "ground": f_ground, "vis": f_vis, "rad": f_rad,
		"dep_eff": de, "source": src}


## True when this hour ends a fog: burned off in sunshine or mixed out.
static func _clears(row: Dictionary, params: Dictionary) -> bool:
	var w := float(row.get("wind_ms", NAN))
	if is_finite(w) and w > _p(params, "wind_clear_ms"):
		return true
	var el := float(row.get("sun_el", NAN))
	if is_finite(el) and el > 0.0:
		var de := dep_eff(row, params)
		if is_finite(de) and de > _p(params, "burn_dep_c"):
			return true
	return false


## Fog per hour over a run of rows, with persistence and gap filling.
static func series(rows: Array, params: Dictionary = {}) -> PackedFloat32Array:
	var n := rows.size()
	var fi := PackedFloat32Array()
	fi.resize(n)
	var clears := PackedByteArray()
	clears.resize(n)
	for i in n:
		fi[i] = float(instant(rows[i], params)["fog"])
		clears[i] = 1 if _clears(rows[i], params) else 0
	# Hold: fog formed in the last `hold_h` hours persists until a clearing
	# hour intervenes. Walk back from each hour, stopping at the first clear.
	var hold_h := int(_p(params, "hold_h"))
	var fh := PackedFloat32Array()
	fh.resize(n)
	for i in n:
		var best := fi[i]
		if clears[i] == 0:
			for k in range(1, hold_h + 1):
				var j := i - k
				if j < 0 or clears[j + 1] == 1:
					break
				best = maxf(best, fi[j])
		fh[i] = best
	# Gap fill: an hour flanked by fog within `gap_h` on BOTH sides is fog.
	var gap := int(_p(params, "gap_h"))
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var a := 0.0
		var b := 0.0
		for k in range(1, gap + 1):
			a = maxf(a, fh[maxi(i - k, 0)])
			b = maxf(b, fh[mini(i + k, n - 1)])
		out[i] = maxf(fh[i], minf(a, b)) if clears[i] == 0 else fh[i]
	return out


## Visibility for a fog fraction, log-interpolated; a model visibility, when
## present and lower, wins.
static func visibility_for_fog(f: float, model_vis_m: float = NAN) -> float:
	if not is_finite(f) or f <= 0.001:
		return INF
	var v := exp(lerpf(log(VIS_THIN_M), log(VIS_DENSE_M), clampf(f, 0.0, 1.0)))
	if is_finite(model_vis_m) and model_vis_m > 0.0 and model_vis_m < v:
		v = maxf(model_vis_m, VIS_DENSE_M * 0.5)
	return v

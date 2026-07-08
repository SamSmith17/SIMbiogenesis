class_name WaterFlowModel
extends RefCounted

## Plausible seasonal water-flow visuals from rolling rain + snowmelt.
## Not hydraulically accurate — drives shader width/level/speed uniforms.

const WIDTH_DRY := 0.55
const WIDTH_WET := 1.0
const WIDTH_FLOOD := 2.1
const LEVEL_MAX_M := 0.65


static func compute(ws: Variant, month: int, day: int, hour: float,
		snow_depth_m: float) -> Dictionary:
	var rain_24h := 0.0
	var temp := 10.0
	if ws != null and typeof(ws) == TYPE_OBJECT:
		if ws.has_method("rain_24h_mm"):
			var r: float = ws.rain_24h_mm(month, day, hour)
			if is_finite(r):
				rain_24h = maxf(r, 0.0)
		if ws.has_method("temperature_c"):
			var tc: float = ws.temperature_c(month, day, hour)
			if is_finite(tc):
				temp = tc

	var rain_t := 0.0
	if rain_24h > 0.05:
		rain_t = clampf(log(rain_24h + 0.5) / log(25.0), 0.0, 1.0)

	var melt_t := 0.0
	if snow_depth_m > 0.03 and temp > SeasonModel.SNOW_T_THRESHOLD_C:
		var warm := clampf((temp - SeasonModel.MELT_T_BASE_C) / 14.0, 0.0, 1.0)
		var pack := clampf(snow_depth_m / 0.8, 0.0, 1.0)
		melt_t = pack * warm

	var hydro := maxf(rain_t, melt_t)

	var width_scale := lerpf(WIDTH_DRY, WIDTH_WET, rain_t)
	width_scale = maxf(width_scale, lerpf(WIDTH_DRY, WIDTH_FLOOD, melt_t))
	width_scale = clampf(width_scale, 0.42, WIDTH_FLOOD)

	var level_m := lerpf(0.0, LEVEL_MAX_M * 0.55, rain_t) + lerpf(0.0, LEVEL_MAX_M, melt_t)
	var speed_scale := lerpf(0.55, 1.85, hydro)
	var churn := lerpf(0.55, 1.55, hydro)
	var alpha := lerpf(0.84, 0.94, hydro * 0.65)

	return {
		"width_scale": width_scale,
		"level_m": level_m,
		"speed_scale": speed_scale,
		"churn": churn,
		"water_alpha": alpha,
		"hydro": hydro,
	}

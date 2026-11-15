class_name GreenhouseControl
extends RefCounted

## A greenhouse's built-in controller (pure): what it does with the vents,
## fans, heater and grow lights given the air it measures. The setpoints are
## the design's `control` block. Like a commercial greenhouse controller:
##  - vents open in proportion between vent_open_c and vent_full_c; a humid
##    house is aired (vents to FLUSH_VENT) when it is warm enough; in rain
##    the vents close to RAIN_VENT_MAX, in a gale to WIND_VENT_MAX;
##  - fans on above fan_on_c, off below fan_off_c (hysteresis);
##  - heater on below heat_on_c, off above heat_off_c (hysteresis);
##  - grow lights, inside the photoperiod centred on noon, while the sun's
##    light inside is below the lamps' and the day's light integral is short
##    of the target (or simply through the photoperiod with auto off).
## An override ({vent: 0..1, fans / heater / lights: 0 | 1}) wins over the
## controller; −1 or absent hands it back. The graph and the player's own
## automations drive these overrides.

const FLUSH_VENT := 0.15
const FLUSH_MARGIN_C := 2.0
const RAIN_MMH := 2.0
const RAIN_VENT_MAX := 0.3
const GALE_MS := 15.0
const WIND_VENT_MAX := 0.15


## m: GreenhouseClimate.model, st: its state (t_air, w, fans_on, heater_on,
## dli), ctx: {hour, t_out, wind, rain_mmh, ppfd_sun}.
static func decide(m: Dictionary, st: Dictionary, ctx: Dictionary, override: Dictionary = {}) -> Dictionary:
	var c: Dictionary = m["control"]
	var t := float(st.get("t_air", 20.0))
	var rh := GreenhouseClimate.rh_of(t, float(st.get("w", 0.01)))
	var lo := float(c["vent_open_c"])
	var hi := float(c["vent_full_c"])
	var vent := clampf((t - lo) / maxf(hi - lo, 0.1), 0.0, 1.0)
	if rh > float(c["rh_flush_pct"]) and t > float(c["heat_off_c"]) + FLUSH_MARGIN_C:
		vent = maxf(vent, FLUSH_VENT)
	if float(ctx.get("rain_mmh", 0.0)) > RAIN_MMH:
		vent = minf(vent, RAIN_VENT_MAX)
	if float(ctx.get("wind", 0.0)) > GALE_MS:
		vent = minf(vent, WIND_VENT_MAX)
	if (m["vents"] as Array).is_empty():
		vent = 0.0
	var fans := bool(st.get("fans_on", false))
	if int(m["fans"]) <= 0:
		fans = false
	elif t > float(c["fan_on_c"]):
		fans = true
	elif t < float(c["fan_off_c"]):
		fans = false
	var heater := bool(st.get("heater_on", false))
	if float(m["heater_w"]) <= 0.0:
		heater = false
	elif t < float(c["heat_on_c"]):
		heater = true
	elif t > float(c["heat_off_c"]):
		heater = false
	var lt: Dictionary = m["lights"]
	var lights := false
	if float(m["light_w"]) > 0.0:
		var pp := float(lt["photoperiod_h"])
		var h := fposmod(float(ctx.get("hour", 12.0)), 24.0)
		var in_day := absf(h - 12.0) < pp * 0.5 or pp >= 24.0
		if bool(c["lights_auto"]):
			lights = in_day and float(ctx.get("ppfd_sun", 0.0)) < float(m["ppfd_lights"]) \
				and float(st.get("dli", 0.0)) < float(lt["dli_target"])
		else:
			lights = in_day
	var o: Dictionary = override
	if o.has("vent") and float(o["vent"]) >= 0.0:
		vent = clampf(float(o["vent"]), 0.0, 1.0)
	if o.has("fans") and int(o["fans"]) >= 0:
		fans = int(o["fans"]) > 0 and int(m["fans"]) > 0
	if o.has("heater") and int(o["heater"]) >= 0:
		heater = int(o["heater"]) > 0 and float(m["heater_w"]) > 0.0
	if o.has("lights") and int(o["lights"]) >= 0:
		lights = int(o["lights"]) > 0 and float(m["light_w"]) > 0.0
	return {"vent": vent, "fans": fans, "heater": heater, "lights": lights}

class_name NpcComfort
extends RefCounted

## Weather as an ATTRACTOR on leisure time: where people choose to be when
## the sun, the cold or the rain makes where they were unpleasant.
##
##   heat     a hot, SUNNY middle of the day pulls people into shade — camp
##            shade structures, tarps, canopies, StarShades, tagged "shade"
##            spaces — and the hotter it is the stronger the pull (some sit,
##            some lie down: a siesta).
##   cold     a cold NIGHT pulls people to warmth: a lit firepit or fire
##            circle (standing round it, facing it), else their own tent.
##   rain     a HARD rain sends people under a tarp or into the place they
##            sleep. Fog and light rain do nothing — people at a festival
##            stand about in drizzle.
##
## A pull is a SHARE, not a switch: each friend group (NpcFriends) draws one
## hashed number per hour and responds when it falls under the pull, so a
## warm afternoon moves a few groups into the shade and a scorching one
## moves most of the site — never everybody at once, and never the same
## people every hour. Both tiers ask the same questions of the same hashes,
## so the full and light crowds agree (the equivalence contract).
##
## Pure: no scene access. The bridge samples the weather (WeatherService)
## and owns the list of shade / warmth spots; the tiers call `respond`.

const KIND_SHADE := "shade"
const KIND_WARM := "warm"
const KIND_SHELTER := "shelter"
const KINDS: Array = [KIND_SHADE, KIND_WARM, KIND_SHELTER]
## The routine blocks weather may redirect: leisure only. Meals, the
## toilet, washing, sleep and work keep their own rules.
const LEISURE_KINDS: Array = [NpcRoutine.SOCIAL, NpcRoutine.FREE, NpcRoutine.ENRICHMENT]

## HEAT: air temperature where the pull starts and where it is full. 26 °C
## is roughly where the WBGT comfort band ends for light activity in full
## sun (ISO 7243; the same thresholds NpcWeatherGate uses); 38 °C is a
## brutal playa afternoon.
const HEAT_FROM_C := 26.0
const HEAT_FULL_C := 38.0
## Direct sun (global horizontal irradiance) that counts as "sunny": the
## pull scales from nothing under heavy overcast to full at a clear midday.
const SUN_FROM_WM2 := 200.0
const SUN_FULL_WM2 := 700.0
## Even on the worst afternoon a few stay out (the dedicated, the sunburned).
const HEAT_MAX_SHARE := 0.85

## COLD: a night below 15 °C is jacket weather; at 2 °C nobody wants to be
## anywhere but the fire.
const COLD_FROM_C := 15.0
const COLD_FULL_C := 2.0
const COLD_MAX_SHARE := 0.8
## Below this irradiance (or outside DAY_FROM_H..DAY_TO_H with no irradiance
## data) it is night.
const NIGHT_WM2 := 5.0
const DAY_FROM_H := 6.5
const DAY_TO_H := 19.5

## RAIN: the met-office rain classes — light < 2.5 mm/h, moderate
## 2.5–7.6, heavy > 7.6 mm/h. Light rain and fog never send anyone in; the
## pull ramps through moderate and is (nearly) total in heavy rain.
const RAIN_FROM_MMH := 2.5
const RAIN_FULL_MMH := 7.6
const RAIN_MAX_SHARE := 0.95
## Of those sheltering from rain, this share go to their OWN bed (a tent or
## van) rather than the nearest tarp.
const RAIN_TO_BED_SHARE := 0.45

## How long one comfort stint lasts before the person re-decides (hashed per
## group per hour, so friends leave together).
const STINT_MIN_H := 0.45
const STINT_MAX_H := 1.0

## A lit fire's HEAT as a venue pull (fire_warmth): nobody seeks a fire
## above FIRE_WARM_FROM_C, everyone at FIRE_WARM_FULL_C; after dark a fire
## draws FIRE_NIGHT_BASE even on a mild night (light, company — the fire is
## the evening's living room), by day the chill counts FIRE_DAY_SCALE.
const FIRE_WARM_FROM_C := 22.0
const FIRE_WARM_FULL_C := 4.0
const FIRE_NIGHT_BASE := 0.25
const FIRE_DAY_SCALE := 0.5

## The cold's pull during the evening gathering block (see respond).
const EVENING_COLD_SCALE := 0.5

## A sitting / lying share under shade grows with the heat (a siesta).
const SHADE_LIE_AT_HEAT := 0.55


## {heat, cold, rain (each 0..1 — the SHARE of groups that respond), night}
## from a weather sample ({temp_c, ghi_wm2, rain_mmh}; any key may be
## missing — an unknown driver pulls nobody) at `hour` of the day.
static func pulls(weather: Dictionary, hour: float) -> Dictionary:
	var out := {"heat": 0.0, "cold": 0.0, "rain": 0.0, "night": false, "warmth": 0.0}
	if weather.is_empty():
		return out
	var h := fposmod(hour, 24.0)
	var has_sun := weather.has("ghi_wm2") and not is_nan(float(weather["ghi_wm2"]))
	var ghi := float(weather.get("ghi_wm2", 0.0)) if has_sun else 0.0
	var night := (ghi < NIGHT_WM2) if has_sun else (h < DAY_FROM_H or h >= DAY_TO_H)
	out["night"] = night
	if weather.has("temp_c") and not is_nan(float(weather["temp_c"])):
		var t := float(weather["temp_c"])
		if not night:
			# Sunny when we know the sun; a hot day with no irradiance data
			# is assumed sunny in the middle hours only.
			var sun := clampf((ghi - SUN_FROM_WM2) / (SUN_FULL_WM2 - SUN_FROM_WM2), 0.0, 1.0) \
				if has_sun else (1.0 if (h >= 10.5 and h < 17.0) else 0.0)
			var hot := clampf((t - HEAT_FROM_C) / (HEAT_FULL_C - HEAT_FROM_C), 0.0, 1.0)
			out["heat"] = smoothstep(0.0, 1.0, hot) * sun * HEAT_MAX_SHARE
		else:
			var cold := clampf((COLD_FROM_C - t) / (COLD_FROM_C - COLD_FULL_C), 0.0, 1.0)
			out["cold"] = smoothstep(0.0, 1.0, cold) * COLD_MAX_SHARE
	out["warmth"] = fire_warmth(float(weather.get("temp_c", NAN)), night)
	var rain := float(weather.get("rain_mmh", 0.0))
	if not is_nan(rain):
		out["rain"] = smoothstep(0.0, 1.0, clampf((rain - RAIN_FROM_MMH) / (RAIN_FULL_MMH - RAIN_FROM_MMH), 0.0, 1.0)) \
			* RAIN_MAX_SHARE
	return out


## How strongly a LIT fire's heat draws people, 0..1 — a venue pull (the
## bridge adds it to every burning fire circle), not a comfort stint: it
## works by day and night, on any temperature, scaled by how cold it is.
## Unknown temperature: the night base after dark, nothing by day. Kept
## apart from `cold` (the comfort stint's night-only share), which the
## selftests pin and the respond() draw reads.
static func fire_warmth(temp_c: float, night: bool) -> float:
	var chill := 0.0
	if not is_nan(temp_c):
		chill = smoothstep(0.0, 1.0, clampf((FIRE_WARM_FROM_C - temp_c)
			/ (FIRE_WARM_FROM_C - FIRE_WARM_FULL_C), 0.0, 1.0))
	if night:
		return clampf(FIRE_NIGHT_BASE + (1.0 - FIRE_NIGHT_BASE) * chill, 0.0, 1.0)
	return chill * FIRE_DAY_SCALE


## True when nothing is pulling anybody (the fast path both tiers take).
static func is_calm(p: Dictionary) -> bool:
	return float(p.get("heat", 0.0)) <= 0.0 and float(p.get("cold", 0.0)) <= 0.0 \
		and float(p.get("rain", 0.0)) <= 0.0


## Which comfort this person responds to in this hour ("" = none): rain
## first (it overrides everything), then the heat by day or the cold by
## night. The draw is the person's FRIEND GROUP's, so friends go together.
## `block` is the routine block being decided: in the evening's gathering
## block (ENRICHMENT) the cold pulls half as hard — a dance floor keeps you
## warm too, and a cold night must not empty the stage.
static func respond(agent_id: String, abs_h: float, p: Dictionary, block: String = "") -> String:
	if p.is_empty() or is_calm(p):
		return ""
	var u := NpcHash.unit01(NpcFriends.key_of(agent_id), "cmf%d" % int(floor(abs_h)))
	if u < float(p.get("rain", 0.0)):
		return KIND_SHELTER
	if u < float(p.get("heat", 0.0)):
		return KIND_SHADE
	var cold := float(p.get("cold", 0.0))
	if block == NpcRoutine.ENRICHMENT:
		cold *= EVENING_COLD_SCALE
	if u < cold:
		return KIND_WARM
	return ""


## Rain: does this person shelter in their own bed rather than under a tarp?
static func shelters_at_bed(agent_id: String, abs_h: float) -> bool:
	return NpcHash.unit01(NpcFriends.key_of(agent_id), "cmfbed%d" % int(floor(abs_h))) < RAIN_TO_BED_SHARE


## How long a comfort stint lasts (per group, per hour).
static func stint_h(agent_id: String, abs_h: float) -> float:
	var u := NpcHash.unit01(NpcFriends.key_of(agent_id), "cmfst%d" % int(floor(abs_h)))
	return lerpf(STINT_MIN_H, STINT_MAX_H, u)


## The pose a person takes at a comfort spot: under shade most sit, and the
## hotter it is the more lie down; round a fire about half sit; sheltering
## from rain people stand (or lie, in their own bed).
static func pose_for(kind: String, agent_id: String, heat: float = 0.0, at_bed: bool = false) -> String:
	var u := NpcHash.unit01(agent_id, "cmfpose")
	match kind:
		KIND_SHADE:
			if heat >= SHADE_LIE_AT_HEAT and u < 0.3:
				# Stretched out in the shade, but propped up — not flat.
				return VenueCrowd.POSE_LOUNGE
			return VenueCrowd.POSE_SIT if u < 0.75 else "talk"
		KIND_WARM:
			if at_bed:
				return VenueCrowd.POSE_LIE
			# Round a fire people talk to whoever is beside them.
			return VenueCrowd.POSE_SIT if u < 0.45 else VenueCrowd.POSE_TALK
		KIND_SHELTER:
			if at_bed:
				return VenueCrowd.POSE_LIE if u < 0.6 else VenueCrowd.POSE_SIT
			return "talk" if u < 0.5 else VenueCrowd.POSE_STAND
	return ""


## A seat round a fire at `centre` (ring radius `ring_r`): the friend group
## takes a hashed bearing and its members stand side by side along the ring,
## facing the fire.
static func seat_around(centre: Vector2, ring_r: float, agent_id: String) -> Dictionary:
	var g := NpcFriends.group_of(agent_id)
	var gk := str(g["key"])
	var r := maxf(ring_r, 0.8) + (NpcHash.unit01(agent_id, "cmfr") - 0.5) * 0.6
	var a0 := NpcHash.unit01(gk, "cmfa") * TAU
	var step := 0.85 / maxf(r, 0.5)
	var a := a0 + (float(g["k"]) - float(int(g["size"]) - 1) * 0.5) * step
	return {"pos": centre + Vector2(cos(a), sin(a)) * r, "face": centre}


## A spot under a shade footprint ({pos, yaw, size: Vector3 (x = length,
## z = width)}): the group's cluster at a hashed point inside the footprint,
## members in a tight F-formation facing its middle.
static func seat_under(spot: Dictionary, agent_id: String) -> Dictionary:
	var g := NpcFriends.group_of(agent_id)
	var gk := str(g["key"])
	var p: Vector2 = spot.get("pos", Vector2.ZERO)
	var yaw := float(spot.get("yaw", 0.0))
	var size: Vector3 = spot.get("size", Vector3(3.0, 2.5, 3.0))
	# Camp items' local +X maps to world (cos yaw, -sin yaw), +Z to (sin, cos).
	var ux := Vector2(cos(yaw), -sin(yaw))
	var uz := Vector2(sin(yaw), cos(yaw))
	var lx := (NpcHash.unit01(gk, "cmfux") - 0.5) * maxf(size.x - 1.6, 0.0) * 0.8
	var lz := (NpcHash.unit01(gk, "cmfuz") - 0.5) * maxf(size.z - 1.6, 0.0) * 0.8
	var c := p + ux * lx + uz * lz
	var off := NpcFriends.formation_offset(gk, int(g["k"]), int(g["size"]),
		NpcHash.unit01(agent_id, "seat")) * 0.8
	return {"pos": c + off, "face": c}


## Status words for a comfort stint.
static func status_for(kind: String, at_bed: bool = false) -> String:
	match kind:
		KIND_SHADE: return "out of the sun"
		KIND_WARM: return "warming up in the tent" if at_bed else "warming up by the fire"
		KIND_SHELTER: return "sheltering in the tent" if at_bed else "sheltering from the rain"
	return ""

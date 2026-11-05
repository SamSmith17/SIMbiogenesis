class_name CspLabSite
extends RefCounted

## Where a concentrator meets its site: the sun's direction, how the tracker
## turns to face it (and so where the sun sits in the optic's own frame),
## how much of the sky's light a concentrator can actually use, and the
## heat it makes.
##
## Concentrators are NOT solar panels. A flat PV panel takes the global
## light — the direct beam AND the diffuse sky (SolarUI's plane-of-array
## model). A concentrator only images the sun's disc, so it lives on the
## direct normal irradiance (DNI): CspTroughSource.dni_wm2, the project's one
## DNI model (Kasten–Young clear sky with aerosol, scaled by the measured
## clearness kt² where WeatherService has data, by cloud cover otherwise).
## The diffuse sky reaches the receiver only through étendue: an ideal
## concentrator of geometric ratio C accepts at most 1/C of isotropic sky
## light (Winston et al. 2005 ch. 2) — a tenth for a C = 10 lens, nothing
## for a dish. A hazy day that costs PV a third can cost a dish everything.
##
## World frame: +Y up, -Z north, +X east; azimuth clockwise from north.

const POLL_EFF_RAYS := 1200
## Live lookups (the world's runtimes and the graph's heat tick, `live`
## true) never trace a new sun angle in one go: a trace costs 5–40 ms
## (a CPC trough's many bounces, a 150-heliostat field), and at high speed
## the sun crosses a new 2.5° cell every second. Instead the trace is done
## in chunks of rays inside ONE budget per frame shared by every caller,
## and until it is done the lookup answers with the partial estimate or the
## nearest angle already traced. The finished value goes in the design's
## table like any other.
const LIVE_TRACE_BUDGET_US := 2500
const LIVE_CHUNK_MIN := 60
## A partial estimate is used once this many rays are in.
const LIVE_PARTIAL_MIN := 300
## Cells being traced live per design (older ones are dropped).
const LIVE_PENDING_MAX := 3
static var _live_frame := -1
static var _live_used_us := 0
const SIGMA := 5.670374419e-8


static func sun_world(az_deg: float, el_deg: float) -> Vector3:
	var az := deg_to_rad(az_deg)
	var el := deg_to_rad(el_deg)
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))


static func az_el(s: Vector3) -> Vector2:
	var el := rad_to_deg(asin(clampf(s.y, -1.0, 1.0)))
	var az := rad_to_deg(atan2(s.x, -s.z))
	if az < 0.0:
		az += 360.0
	return Vector2(az, el)


## The sun at a calendar instant (local clock time, the project's zone rule).
static func sun_at(lat: float, lon: float, year: int, month: int, day: int, hour: float) -> Dictionary:
	var clk := CelestialClock.new()
	clk.latitude = lat
	clk.longitude = lon
	var jd: float = clk._julian_day_utc_for(year, month, day, hour)
	var sp := SolarPosition.get_position(lat, lon, jd)
	var el := float(sp.get("elevation_deg", -90.0))
	var az := float(sp.get("azimuth_deg", 180.0))
	return {"az": az, "el": el, "s": sun_world(az, el)}


## The design sun: solar noon at an equinox (elevation 90° − |lat|, facing
## the equator). Ground-fixed fields (a tower, a linear Fresnel field) quote
## their headline numbers here; tracked optics at normal incidence.
static func design_sun(lat: float) -> Vector3:
	return noon_sun(lat, 0.0)


## Solar noon at a declination (deg, + = northern summer): facing the
## equator unless the sun passes north of the zenith (or south of it in the
## southern hemisphere).
static func noon_sun(lat: float, decl: float) -> Vector3:
	var el := 90.0 - absf(lat - decl)
	var az := 180.0 if lat >= decl else 0.0
	return sun_world(az, clampf(el, 5.0, 90.0))


## The sun at a declination and hour angle (deg, + = afternoon), as a world
## direction (+X east, +Y up, −Z north): the textbook spherical triangle.
static func sun_at_decl(lat: float, decl: float, hour_angle: float) -> Vector3:
	var p := deg_to_rad(lat)
	var dl := deg_to_rad(decl)
	var h := deg_to_rad(hour_angle)
	var east := -cos(dl) * sin(h)
	var north := cos(p) * sin(dl) - sin(p) * cos(dl) * cos(h)
	var up := sin(p) * sin(dl) + cos(p) * cos(dl) * cos(h)
	return Vector3(east, up, -north).normalized()


## The summer-solstice noon sun at a latitude: the highest the sun gets,
## the best moment for a level optic.
static func solstice_noon_sun(lat: float) -> Vector3:
	return noon_sun(lat, 23.44 if lat >= 0.0 else -23.44)


## The polar axis: toward the celestial pole, tilted up by |latitude|.
static func polar_axis(lat: float) -> Vector3:
	var la := deg_to_rad(absf(lat))
	return Vector3(0, sin(la), -cos(la)) if lat >= 0.0 else Vector3(0, sin(la), cos(la))


## The ground frame of a ground-fixed field: N–S rows keep the world axes,
## E–W rows turn the frame so the rows (local Z) run east.
static func field_basis(spec: Dictionary) -> Basis:
	var mode := str((spec["tracking"] as Dictionary)["mode"])
	if str(spec["type"]) == "linear_fresnel" and mode == "ew_horizontal":
		return Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
	return Basis.IDENTITY


static func is_field(spec: Dictionary) -> bool:
	return str(spec["type"]) == "tower" or str(spec["type"]) == "linear_fresnel"


## How the tracker faces the sun `s` (world). Returns:
##   basis      optic frame → world (columns = the optic's X, Y, Z)
##   stage      the first moving stage's basis (yaw / hour angle / the
##              one axis), world
##   sun_local  the sun in the optic frame
##   axes       [{dir, label, color}] the tracking axes (for the views)
##   angles     {name: degrees} for the readouts
##   up         false when the sun is below the horizon (stowed)
static func pose(spec: Dictionary, s: Vector3, lat: float) -> Dictionary:
	var t := str(spec["type"])
	var tk: Dictionary = spec["tracking"]
	var mode := str(tk["mode"])
	var mount := str((spec["structure"] as Dictionary)["mount"])
	var up := s.y > 0.0
	var out := {"up": up}
	if is_field(spec):
		var fb := field_basis(spec)
		out["basis"] = fb
		out["stage"] = fb
		out["sun_local"] = fb.transposed() * s
		var ae := az_el(s)
		out["angles"] = {"Sun azimuth": ae.x, "Sun elevation": ae.y}
		if t == "linear_fresnel":
			var st := (fb.transposed() * s)
			out["angles"]["Row tilt (centre)"] = rad_to_deg(atan2(st.x, maxf(st.y, 1e-6))) * 0.5
			out["axes"] = [{"dir": fb.z, "label": "Row axes (each mirror turns)", "color": Color(0.3, 0.85, 1.0)}]
		else:
			out["axes"] = [{"dir": Vector3.UP, "label": "Heliostat azimuth", "color": Color(0.3, 1.0, 0.45)},
				{"dir": Vector3.RIGHT, "label": "Heliostat elevation", "color": Color(1.0, 0.35, 0.3)}]
		return out
	var sv := s if up else Vector3(0, 1, 0)
	if mode == "two_axis":
		if mount == "polar_mount":
			var a := polar_axis(lat)
			var dec := asin(clampf(sv.dot(a), -1.0, 1.0))
			var perp := sv - a * sv.dot(a)
			var m := perp.normalized() if perp.length() > 1e-6 else Vector3.UP
			var stage := Basis(m.cross(a), m, a)
			var b := stage * Basis(Vector3.RIGHT, dec)
			out["stage"] = stage
			out["basis"] = b
			var m0 := (Vector3.UP - a * a.y).normalized()
			var ha := rad_to_deg(m0.signed_angle_to(m, a))
			out["angles"] = {"Hour angle": ha, "Declination": rad_to_deg(dec)}
			out["axes"] = [{"dir": a, "label": "Polar axis", "color": Color(0.85, 0.4, 1.0)},
				{"dir": stage.x, "label": "Declination axis", "color": Color(1.0, 0.35, 0.3)}]
		else:
			var ae2 := az_el(sv)
			var yaw := Basis(Vector3.UP, -deg_to_rad(ae2.x))
			var b2 := yaw * Basis(Vector3.RIGHT, -deg_to_rad(90.0 - ae2.y))
			out["stage"] = yaw
			out["basis"] = b2
			out["angles"] = {"Azimuth": ae2.x, "Elevation": ae2.y}
			out["axes"] = [{"dir": Vector3.UP, "label": "Azimuth axis", "color": Color(0.3, 1.0, 0.45)},
				{"dir": yaw.x, "label": "Elevation axis", "color": Color(1.0, 0.35, 0.3)}]
		out["sun_local"] = (out["basis"] as Basis).transposed() * s
		return out
	if mode == "level":
		# A water lens: the optical axis is plumb, always. It focuses only
		# what comes down near the vertical.
		out["stage"] = Basis.IDENTITY
		out["basis"] = Basis.IDENTITY
		out["sun_local"] = s
		out["angles"] = {"Incidence": rad_to_deg(acos(clampf(maxf(s.y, 0.0), 0.0, 1.0)))}
		out["axes"] = []
		return out
	if mode == "fixed":
		var tilt := float(tk["fixed_tilt_deg"])
		if tilt < 0.0:
			tilt = absf(lat)
		var tr := deg_to_rad(tilt)
		var eq := 1.0 if lat >= 0.0 else -1.0
		var yv := Vector3(0, cos(tr), sin(tr) * eq)
		var zv := Vector3(1, 0, 0)
		var b3 := Basis(yv.cross(zv), yv, zv)
		out["stage"] = b3
		out["basis"] = b3
		out["sun_local"] = b3.transposed() * s
		var c := maxf((b3.transposed() * s).y, 0.0)
		out["angles"] = {"Tilt": tilt, "Incidence": rad_to_deg(acos(c))}
		out["axes"] = []
		return out
	# One axis: horizontal N–S, horizontal E–W, or polar.
	var ax := Vector3(0, 0, 1)
	var label := "Tracking axis (N–S)"
	if mode == "ew_horizontal":
		ax = Vector3(1, 0, 0)
		label = "Tracking axis (E–W)"
	elif mode == "polar":
		ax = polar_axis(lat)
		label = "Tracking axis (polar)"
	var perp2 := sv - ax * sv.dot(ax)
	var nrm := perp2.normalized() if perp2.length() > 1e-6 else (Vector3.UP - ax * ax.y).normalized()
	var b4 := Basis(nrm.cross(ax), nrm, ax)
	out["stage"] = b4
	out["basis"] = b4
	out["sun_local"] = b4.transposed() * s
	var rest := (Vector3.UP - ax * ax.y).normalized()
	out["angles"] = {"Rotation": rad_to_deg(rest.signed_angle_to(nrm, ax)),
		"Incidence": rad_to_deg(asin(clampf(absf(s.dot(ax)), 0.0, 1.0)))}
	out["axes"] = [{"dir": ax, "label": label, "color": Color(0.3, 0.85, 1.0)}]
	return out


## The optical efficiency (captured / DNI·A_ap, before the receiver's
## absorptance) for a world sun. Two-axis optics always see the design
## value; one-axis, fixed and ground-fixed fields are traced at the sun's
## direction quantised to a few degrees and cached on the solved design.
static func optical_eff_at(d: Dictionary, s_world: Vector3, lat: float, live: bool = false) -> float:
	if s_world.y <= 0.0:
		return 0.0
	var spec: Dictionary = d["spec"]
	var mode := str((spec["tracking"] as Dictionary)["mode"])
	if mode == "two_axis" and not is_field(spec):
		return float(d["eta_capture"])
	var p := pose(spec, s_world, lat)
	var sl: Vector3 = p["sun_local"]
	var key := ""
	var q: Vector3
	if mode == "fixed" or mode == "level" or is_field(spec):
		var ae := az_el(s_world)
		var qa := snappedf(ae.x, 7.5)
		var qe := snappedf(ae.y, 2.5)
		key = "%d|%d" % [int(qa * 10.0), int(qe * 10.0)]
		q = (p["basis"] as Basis).transposed() * sun_world(qa, maxf(qe, 1.0))
	else:
		# One axis: only the longitudinal incidence matters.
		var th := snappedf(rad_to_deg(asin(clampf(sl.z, -1.0, 1.0))), 2.5)
		key = "L%d" % int(th * 10.0)
		var tr := deg_to_rad(th)
		q = Vector3(0, cos(tr), sin(tr))
	var cache: Dictionary = d["eff_cache"]
	if cache.has(key):
		return float(cache[key])
	var n := mini(int((spec["trace"] as Dictionary)["rays"]), POLL_EFF_RAYS)
	if live:
		return _live_eff(d, cache, key, q, n)
	var r := CspLabOptics.trace(d["geo"] as Dictionary, q, n, {"seed": 3})
	var e := float(r["captured"])
	cache[key] = e
	_eff_points(cache)[key] = q
	return e


static func _eff_points(cache: Dictionary) -> Dictionary:
	if not cache.has("@pts"):
		cache["@pts"] = {}
	return cache["@pts"] as Dictionary


static func _eff_pending(cache: Dictionary) -> Dictionary:
	if not cache.has("@pending"):
		cache["@pending"] = {}
	return cache["@pending"] as Dictionary


## A live lookup that is not in the table yet (see LIVE_TRACE_BUDGET_US).
static func _live_eff(d: Dictionary, cache: Dictionary, key: String, q: Vector3, n: int) -> float:
	var pend := _eff_pending(cache)
	if not pend.has(key):
		pend[key] = {"q": q, "n": n, "done": 0, "sum": 0.0, "order": Engine.get_process_frames()}
		while pend.size() > LIVE_PENDING_MAX:
			var oldest := ""
			var o_min := 1 << 62
			for k in pend:
				if int((pend[k] as Dictionary)["order"]) < o_min:
					o_min = int((pend[k] as Dictionary)["order"])
					oldest = str(k)
			pend.erase(oldest)
	advance_live(d, key)
	if cache.has(key):
		return float(cache[key])
	var p: Dictionary = pend.get(key, {})
	var done := int(p.get("done", 0))
	if done >= LIVE_PARTIAL_MIN:
		return float(p["sum"]) / float(done)
	# The nearest sun angle already traced (one-axis keys "L…" apart).
	var best := -2.0
	var val := -1.0
	var one_axis := key.begins_with("L")
	var pts := _eff_points(cache)
	for k in pts:
		if str(k).begins_with("L") != one_axis or not cache.has(k):
			continue
		var dt := (pts[k] as Vector3).dot(q)
		if dt > best:
			best = dt
			val = float(cache[k])
	if val >= 0.0:
		return val
	if done > 0:
		return float(p["sum"]) / float(done)
	return float(d.get("eta_capture", 0.0))


## Work through a design's live traces (`first` before the others) inside
## this frame's shared budget. The world's runtimes call it every frame, so
## a trace started at one poll is finished within a few frames.
static func advance_live(d: Dictionary, first: String = "") -> void:
	var cache: Dictionary = d.get("eff_cache", {}) as Dictionary
	if not cache.has("@pending"):
		return
	var pend: Dictionary = cache["@pending"]
	if pend.is_empty():
		return
	var f := Engine.get_process_frames()
	if f != _live_frame:
		_live_frame = f
		_live_used_us = 0
	var keys: Array = pend.keys()
	if not first.is_empty() and pend.has(first):
		keys.erase(first)
		keys.push_front(first)
	var geo: Dictionary = d["geo"]
	for k in keys:
		if cache.has(k):
			# Traced in full meanwhile (the designer's own lookups).
			pend.erase(k)
			continue
		var p: Dictionary = pend[k]
		var us_ray := float(cache.get("@us_ray", 15.0))
		while _live_used_us < LIVE_TRACE_BUDGET_US and int(p["done"]) < int(p["n"]):
			var left := float(LIVE_TRACE_BUDGET_US - _live_used_us)
			var chunk := clampi(int(left / maxf(us_ray, 0.5)), LIVE_CHUNK_MIN, int(p["n"]) - int(p["done"]))
			var t0 := Time.get_ticks_usec()
			var r := CspLabOptics.trace(geo, p["q"] as Vector3, chunk, {"seed": 3 + int(p["done"])})
			var dt := Time.get_ticks_usec() - t0
			_live_used_us += dt
			us_ray = lerpf(us_ray, float(dt) / float(chunk), 0.6)
			cache["@us_ray"] = us_ray
			p["sum"] = float(p["sum"]) + float(r["captured"]) * float(chunk)
			p["done"] = int(p["done"]) + chunk
		if int(p["done"]) >= int(p["n"]):
			cache[k] = float(p["sum"]) / float(p["done"])
			_eff_points(cache)[k] = p["q"]
			pend.erase(k)
		if _live_used_us >= LIVE_TRACE_BUDGET_US:
			return


## Receiver heat loss (W) at `t_c` in air `ta_c`: radiation from its hot
## area plus convection (an evacuated envelope keeps 5 % of it).
static func q_loss_w(d: Dictionary, t_c: float, ta_c: float) -> float:
	var g: Dictionary = d["geo"]
	var a := float(g["A_loss"])
	var tk := t_c + 273.15
	var ta := ta_c + 273.15
	var h := float(g["h_conv"]) * (0.05 if bool(g.get("envelope", false)) else 1.0)
	return float(g["eps"]) * SIGMA * a * (tk * tk * tk * tk - ta * ta * ta * ta) + h * a * (tk - ta)


## The heat for one instant: direct beam through the optic (the efficiency
## at this sun), plus the sky light étendue lets in, minus the receiver's
## losses at the working temperature. W.
static func heat_w(d: Dictionary, dni: float, dhi: float, eta_capture: float, ta_c: float) -> Dictionary:
	var g: Dictionary = d["geo"]
	var a := float(g["A_ap"])
	var alpha := float(g["alpha"])
	var c_g := maxf(float(g["C_g"]), 1.0)
	var trans := float(g["rho"])
	var beam := dni * a * eta_capture * alpha
	var diffuse := dhi * a * minf(1.0 / c_g, 1.0) * trans * alpha
	var op := float((d["spec"]["site"] as Dictionary)["op_temp_c"])
	var loss := q_loss_w(d, op, ta_c)
	return {"absorbed_w": beam + diffuse, "beam_w": beam, "diffuse_w": diffuse, "loss_w": loss,
		"useful_w": maxf(beam + diffuse - loss, 0.0)}


## What the placed concentrator does now (the graph tick and the modal's
## "at the site" line): {up, dni, dhi, eta, thermal_kw, steam_kg_h, angles}.
static func output_now(d: Dictionary, s_world: Vector3, weather: Dictionary, lat: float, live: bool = false) -> Dictionary:
	var ae := az_el(s_world)
	var el := ae.y
	var out := {"up": el > 0.0, "az": ae.x, "el": el, "dni": 0.0, "ghi": 0.0, "dhi": 0.0, "eta": 0.0,
		"thermal_kw": 0.0, "steam_kg_h": 0.0, "water_lph": 0.0}
	if el <= 0.0:
		return out
	var dni := CspTroughSource.dni_wm2(el, weather)
	var ghi := float(weather.get("ghi", 0.0)) if bool(weather.get("has_real", false)) \
		else dni * sin(deg_to_rad(el)) + SolarIrradiance.dhi_clear_sky_wm2(el, dni, float(weather.get("aod", SolarIrradiance.AOD_BASELINE)))
	var dhi := maxf(ghi - dni * sin(deg_to_rad(el)), 0.0)
	var eta := optical_eff_at(d, s_world, lat, live)
	var ta := float(weather.get("temp", (d["spec"]["site"] as Dictionary)["ambient_c"]))
	var h := heat_w(d, dni, dhi, eta, ta)
	out["dni"] = dni
	out["ghi"] = ghi
	out["dhi"] = dhi
	out["eta"] = eta
	out["thermal_kw"] = float(h["useful_w"]) / 1000.0
	out["absorbed_kw"] = float(h["absorbed_w"]) / 1000.0
	var steam := steam_kg_h(d, float(h["useful_w"]) / 1000.0)
	out["steam_kg_h"] = steam
	out["water_lph"] = steam
	return out


## Water at 20 °C boiled off at 1 atm by `kw` of heat (sensible heat to
## 100 °C + the latent heat, the same budget CspTroughSource uses). Zero
## when the working temperature is below boiling.
static func steam_kg_h(d: Dictionary, kw: float) -> float:
	var op := float((d["spec"]["site"] as Dictionary)["op_temp_c"])
	if op < 100.0 or kw <= 0.0:
		return 0.0
	var kj_per_kg := CspTroughSource.CP_WATER_KJ_PER_KG_K * (100.0 - 20.0) + CspTroughSource.H_FG_KJ_PER_KG
	return kw * 3600.0 / kj_per_kg


# ---------------------------------------------------------------------------
# A year at the site, stepped a few milliseconds at a time
# ---------------------------------------------------------------------------

class Year:
	var design: Dictionary
	var lat := 35.0
	var lon := -115.0
	var year := 2026
	var ws: Node = null
	var day_step := 2
	var month := 1
	var day := 1
	var hour := 0.5
	var done := false
	var thermal_kwh := PackedFloat64Array()
	var dni_kwh_m2 := PackedFloat64Array()
	var ghi_kwh_m2 := PackedFloat64Array()
	var beam_h_kwh_m2 := PackedFloat64Array()
	var run_hours := PackedFloat64Array()
	var peak_kw := 0.0
	var samples := 0

	func _init(d: Dictionary, la: float, lo: float, yr: int, w: Node) -> void:
		design = d
		lat = la
		lon = lo
		year = yr
		ws = w
		for _i in 12:
			thermal_kwh.append(0.0)
			dni_kwh_m2.append(0.0)
			ghi_kwh_m2.append(0.0)
			beam_h_kwh_m2.append(0.0)
			run_hours.append(0.0)

	func progress() -> float:
		return clampf((float(month - 1) + float(day - 1) / 31.0) / 12.0, 0.0, 1.0)

	## Work for at most `budget_ms`; true once the year is done.
	func step(budget_ms: float) -> bool:
		var t0 := Time.get_ticks_usec()
		while not done:
			_sample()
			_advance()
			if float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
				break
		return done

	func _sample() -> void:
		var sun := CspLabSite.sun_at(lat, lon, year, month, day, hour)
		var el := float(sun["el"])
		if el <= 0.0:
			return
		var weather := SolarIrradiance.sample_weather(lat, lon, month, day, hour, ws)
		var o := CspLabSite.output_now(design, sun["s"] as Vector3, weather, lat)
		# Each sampled day stands for its share of the month.
		var dim := CspLabSite.days_in_month(year, month)
		var k := float(dim) / ceilf(float(dim) / float(day_step))
		var mi := month - 1
		thermal_kwh[mi] += float(o["thermal_kw"]) * k
		dni_kwh_m2[mi] += float(o["dni"]) / 1000.0 * k
		ghi_kwh_m2[mi] += float(o["ghi"]) / 1000.0 * k
		beam_h_kwh_m2[mi] += float(o["dni"]) * sin(deg_to_rad(el)) / 1000.0 * k
		if float(o["thermal_kw"]) > 0.0:
			run_hours[mi] += k
		peak_kw = maxf(peak_kw, float(o["thermal_kw"]))
		samples += 1

	func _advance() -> void:
		hour += 1.0
		if hour < 24.0:
			return
		hour = 0.5
		day += day_step
		var dim := CspLabSite.days_in_month(year, month)
		if day > dim:
			day = 1
			month += 1
			if month > 12:
				done = true

	func result() -> Dictionary:
		var tot := 0.0
		var dni := 0.0
		var ghi := 0.0
		var bh := 0.0
		var hrs := 0.0
		for i in 12:
			tot += thermal_kwh[i]
			dni += dni_kwh_m2[i]
			ghi += ghi_kwh_m2[i]
			bh += beam_h_kwh_m2[i]
			hrs += run_hours[i]
		return {"monthly_kwh": thermal_kwh, "monthly_dni": dni_kwh_m2, "monthly_ghi": ghi_kwh_m2,
			"annual_kwh": tot, "annual_dni": dni, "annual_ghi": ghi, "run_hours": hrs,
			"direct_share": bh / ghi if ghi > 0.0 else 0.0, "peak_kw": peak_kw, "samples": samples}


static func days_in_month(y: int, m: int) -> int:
	match m:
		2:
			return 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28
		4, 6, 9, 11:
			return 30
	return 31

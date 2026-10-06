class_name MicroclimateResolver
extends Node

## Autoload `Microclimate`: the site-aware layer between the weather data and
## what the site LOOKS like. Like ExtremeWeather it is a PURE FUNCTION of
## absolute hours (given the loaded data and the map's profile), so it scrubs
## backwards, replays, and needs no state integrated over time — fog "holding"
## until it burns off is a scan along the hourly series, not a timer.
##
## Per integer hour it builds a feature row (weather + sun + visual-only
## corrections), runs FogDiagnosis and every rule over an 18-hour look-back
## window, and memoises the result. resolve_at() interpolates two hours, adds
## pinned observations at the exact instant and blends everything through
## MicroclimateProfile.blend.
##
## Precedence, strongest first:
##   1. live PREVIEW from the drawer (not persisted)
##   2. PINNED observations (ground truth for the moments the player saw)
##   3. RULES + NEAREST-match observations (combined, worst-fog wins)
##   4. the AUTOMATIC fog diagnosis (unless a look suppresses it)
## A stronger layer scales the ones beneath it by (1 − its weight).

signal profile_changed()
signal site_context_changed()

const TICK_INTERVAL := 0.25
const LOOKBACK_H := 18
const LOOKAHEAD_H := 3
const MEMO_MAX := 6000

var profile: MicroclimateProfile = MicroclimateProfile.new()
var enabled: bool = true

var _main: Node = null
var _scratch_clock: CelestialClock = CelestialClock.new()
var _profile_path: String = ""
var _site_key: String = ""
## Terrain context, WORLD units: valley floor Y at the site, its topographic
## position index (m, negative = hollow), and the site XZ.
var _floor_y: float = 0.0
var _tpi_m: float = 0.0
var _site_xz: Vector2 = Vector2.ZERO
var _has_terrain: bool = false

var _feat_memo: Dictionary = {}    # int hour → feature dict
var _hour_memo: Dictionary = {}    # int hour → hourly result
var _state: Dictionary = {}
var _preview: Dictionary = {}      # look dict, or {} for none
var _tick_acc := 0.0
var _data_sig := ""


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	_tick_acc += delta
	if _tick_acc < TICK_INTERVAL:
		return
	_tick_acc = 0.0
	_resolve_main()
	if _main == null:
		_state = {}
		return
	_ensure_site()
	# Some WeatherService loads (forecast / current-year cache hits) emit no
	# signal; a change in what is loaded must still drop hours memoised while
	# the data was missing.
	var ws := get_node_or_null("/root/WeatherService")
	if ws != null:
		var sig := "%s|%s|%s|%s" % [ws.call("has_data"), ws.call("has_forecast"),
			ws.call("has_current_year_archive"), ws.get("_sim_year")]
		if sig != _data_sig:
			_data_sig = sig
			invalidate()
	var h := _now_abs_hours()
	_state = resolve_at(h) if is_finite(h) else {}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## The resolved state at the live playhead (refreshed on the tick).
func current() -> Dictionary:
	return _state if not _state.is_empty() else blank_state()


static func blank_state() -> Dictionary:
	return {
		"active": false, "fog_sigma": 0.0, "fog_vis_m": INF, "fog_depth_m": 0.0,
		"fog_floor_y": 0.0, "fog_top_y": 0.0, "fog_color": Color(0.82, 0.84, 0.86),
		"haze_sigma": 0.0, "haze_color": Color(0.7, 0.72, 0.75), "cloud_delta": 0.0,
		"ground_cloud": 0.0, "dust": 0.0, "wind_vis_mult": 1.0, "light_mult": 1.0,
		"physics": false, "auto_fog": 0.0, "auto_source": "none",
		"contributors": [], "features": {},
	}


func invalidate() -> void:
	_feat_memo.clear()
	_hour_memo.clear()


func set_enabled(on: bool) -> void:
	enabled = on
	invalidate()


func save_profile() -> void:
	if _profile_path.is_empty():
		return
	profile.save_to(_profile_path)
	MicroclimateCorrections.set_physics(profile.corrections)
	invalidate()
	profile_changed.emit()


## Called by the drawer after editing the profile in memory.
func profile_edited(persist: bool = true) -> void:
	if persist:
		save_profile()
	else:
		MicroclimateCorrections.set_physics(profile.corrections)
		invalidate()
		profile_changed.emit()


## Live, non-persisted look from the drawer's sliders (weight 1, on top of
## everything). {} clears it.
func set_preview(look: Dictionary) -> void:
	_preview = look.duplicate()


func clear_preview() -> void:
	_preview = {}


func has_preview() -> bool:
	return not _preview.is_empty()


func profile_path() -> String:
	return _profile_path


func site_context() -> Dictionary:
	return {"floor_y": _floor_y, "tpi_m": _tpi_m, "has_terrain": _has_terrain,
		"cold_pool_bias_c": _cold_pool_bias(), "default_depth_m": _default_depth()}


## Feature row for an instant (hourly-interpolated), with the auto fog stamped.
func features_at(abs_h: float) -> Dictionary:
	var h0 := int(floor(abs_h))
	var r0 := _hour_result(h0)
	var f: Dictionary = (r0.get("features", {}) as Dictionary).duplicate()
	f["label"] = _label_for(abs_h)
	return f


## Per-hour summary over a span, for the timeline lane: [{h, fog, rules:{id:w}}].
func sweep(start_h: float, end_h: float) -> Array:
	var out: Array = []
	var a := int(floor(start_h))
	var b := int(ceil(end_h))
	if b - a > 24 * 40:
		b = a + 24 * 40
	for h in range(a, b + 1):
		var r := _hour_result(h)
		var fog := float(r.get("auto_fog", 0.0))
		var rw := {}
		for c in r.get("contribs", []):
			if str(c.get("kind", "")) == "rule":
				rw[str(c.get("id", ""))] = float(c.get("w", 0.0))
		out.append({"h": float(h), "auto_fog": fog, "rules": rw,
			"nearest": _sum_kind(r.get("contribs", []), "nearest")})
	return out


## One rule's weight per hour over a long span, in ONE pass (features sampled
## once, the fog series and the rule's hold run once along the whole span) —
## the drawer's "fires on N nights a year" count. Bypasses the hourly memos so
## a year-long sweep does not evict the hours around the playhead.
func sweep_rule(rule_id: String, start_h: float, end_h: float) -> Array:
	var rule: Dictionary = {}
	for r in profile.rules:
		if str(r.get("id", "")) == rule_id:
			rule = r
	var out: Array = []
	if rule.is_empty():
		return out
	var a := int(floor(start_h))
	var b := mini(int(ceil(end_h)), a + 24 * 400)
	var rows: Array = []
	var bias := _cold_pool_bias()
	for h in range(a, b + 1):
		var f := profile.apply_corrections(sample_features(float(h)), "visual")
		var de := FogDiagnosis.dep_eff(f, {"cold_pool_bias_c": bias})
		f["dep_eff_c"] = de if is_finite(de) else float(f.get("dep_c", NAN))
		rows.append(f)
	var fog := FogDiagnosis.series(rows, {"cold_pool_bias_c": bias})
	for i in rows.size():
		rows[i]["fog_auto"] = fog[i]
	var w := MicroclimateProfile.rule_series(rule, rows)
	for i in rows.size():
		out.append({"h": float(a + i), "w": w[i]})
	return out


func _sum_kind(contribs: Array, kind: String) -> float:
	var w := 0.0
	for c in contribs:
		if str(c.get("kind", "")) == kind:
			w = maxf(w, float(c.get("w", 0.0)))
	return w


## The full resolved state at an arbitrary instant. Pure w.r.t. loaded data.
func resolve_at(abs_h: float) -> Dictionary:
	if not enabled or not is_finite(abs_h):
		return blank_state()
	var h0 := int(floor(abs_h))
	var frac := abs_h - float(h0)
	var r0 := _hour_result(h0)
	var r1 := _hour_result(h0 + 1)

	var contribs: Array = []
	for c in r0.get("contribs", []):
		var d: Dictionary = c.duplicate()
		d["w"] = float(c["w"]) * (1.0 - frac)
		contribs.append(d)
	for c in r1.get("contribs", []):
		var d: Dictionary = c.duplicate()
		d["w"] = float(c["w"]) * frac
		contribs.append(d)
	contribs = _merge_same(contribs)

	var auto_f := lerpf(float(r0.get("auto_fog", 0.0)), float(r1.get("auto_fog", 0.0)), frac)
	var model_vis := float((r0.get("features", {}) as Dictionary).get("vis_m", NAN))

	# Layer 3 + 4: rules/nearest and the automatic fog.
	var mid := MicroclimateProfile.blend(contribs)
	var auto_on := bool(profile.settings.get("auto_fog", true))
	var auto_scale := float(profile.settings.get("auto_fog_scale", 1.0))
	if auto_on and auto_f > 0.0 and is_finite(auto_scale) and auto_scale > 0.0:
		var auto_w := smoothstep(0.0, 0.2, auto_f) * (1.0 - float(mid["suppress_auto"]))
		var auto_sigma := FogOptics.sigma_for_visibility(FogDiagnosis.visibility_for_fog(auto_f, model_vis))
		mid["fog_sigma"] = maxf(float(mid["fog_sigma"]), auto_w * auto_sigma * auto_scale)
	# Layer 2: pinned observations override what is beneath by their weight.
	var pinned := profile.pinned_contributions(abs_h)
	var out := mid
	if not pinned.is_empty():
		var pin := MicroclimateProfile.blend(pinned)
		var wp := 0.0
		for c in pinned:
			wp = maxf(wp, float(c["w"]))
		out = _over(mid, pin, wp)
		for c in pinned:
			contribs.append(c)
	# Layer 1: the live preview.
	if not _preview.is_empty():
		out = _over(out, MicroclimateProfile.blend([{"look": _preview, "w": 1.0}]), 1.0)
		contribs.append({"kind": "preview", "id": "preview", "w": 1.0})

	return _finish(out, r0, r1, frac, auto_f, contribs)


# ---------------------------------------------------------------------------
# HazardState views — how the rest of the game consumes this layer
# ---------------------------------------------------------------------------

## The VISUAL layer as a HazardState: haze, dust, sun dimming, visual wind.
## Combined with ExtremeWeather.current() by main.gd and the vegetation wind
## driver. Energy fields stay at the identity — see physics_hazard().
static func visual_hazard(st: Dictionary) -> Dictionary:
	var hz := HazardState.blank()
	if not bool(st.get("active", false)):
		return hz
	var haze_sigma := float(st.get("haze_sigma", 0.0))
	var dust := float(st.get("dust", 0.0))
	var wind_mult := float(st.get("wind_vis_mult", 1.0))
	var light := float(st.get("light_mult", 1.0))
	# How much of a 2 km view the haze takes — the haze_strength scale the
	# applier lerps colours and aerial perspective by.
	var haze_strength := 1.0 - exp(-haze_sigma * 2000.0)
	var sev := maxf(haze_strength, maxf(dust, maxf(1.0 - light, absf(wind_mult - 1.0) * 0.5)))
	if sev <= 0.005:
		return hz
	hz["id"] = "microclimate"
	hz["label"] = "Site weather"
	hz["source"] = "microclimate"
	hz["severity"] = clampf(sev, 0.0, 1.0)
	hz["visibility_m"] = minf(FogOptics.visibility_for_sigma(haze_sigma), HazardState.CLEAR_VISIBILITY_M)
	hz["haze_strength"] = haze_strength
	var hc: Color = st.get("haze_color", Color(0.7, 0.72, 0.75))
	hz["haze_color"] = hc
	hz["sun_energy_mult"] = light
	hz["wind_mult"] = maxf(wind_mult, 1.0 + dust * 0.8) if dust > 0.0 else wind_mult
	hz["gust_mult"] = hz["wind_mult"]
	if dust > 0.0:
		hz["particle_kind"] = "dust"
		hz["particle_density"] = dust
	return HazardState.sanitize(hz)


## The PHYSICS layer: only when a contributing look ticked "affects physics".
## Fog and haze become aerosol optical depth — extinction × the layer's
## thickness (τ = σ·Δz, Beer–Lambert along the vertical) — which is the one
## knob SolarIrradiance already turns DNI/DHI with.
static func physics_hazard(st: Dictionary) -> Dictionary:
	var hz := HazardState.blank()
	if not bool(st.get("active", false)) or not bool(st.get("physics", false)):
		return hz
	var tau := float(st.get("fog_sigma", 0.0)) * maxf(float(st.get("fog_depth_m", 0.0)), 0.0) \
		+ float(st.get("haze_sigma", 0.0)) * 1500.0
	if not is_finite(tau) or tau <= 0.001:
		return hz
	hz["id"] = "microclimate"
	hz["source"] = "microclimate"
	hz["severity"] = clampf(1.0 - exp(-tau), 0.006, 1.0)
	hz["aod"] = minf(tau, 6.0)
	return HazardState.sanitize(hz)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _over(under: Dictionary, over: Dictionary, w: float) -> Dictionary:
	var out := under.duplicate()
	w = clampf(w, 0.0, 1.0)
	for k in ["fog_sigma", "haze_sigma", "cloud_add", "dust", "light_mult", "wind_vis_mult"]:
		out[k] = lerpf(float(under[k]), float(over[k]), w)
	if is_finite(float(over["fog_depth_m"])):
		out["fog_depth_m"] = over["fog_depth_m"] if not is_finite(float(under["fog_depth_m"])) \
			else lerpf(float(under["fog_depth_m"]), float(over["fog_depth_m"]), w)
	for k in ["fog_color", "haze_color"]:
		var oc: Color = over[k]
		if oc.a > 0.0 or (oc.r + oc.g + oc.b) > 0.0:
			var uc: Color = under[k]
			out[k] = oc if (uc.r + uc.g + uc.b) <= 0.0 else uc.lerp(oc, w)
	out["physics"] = bool(under["physics"]) or (bool(over["physics"]) and w > 0.05)
	return out


func _merge_same(contribs: Array) -> Array:
	var by_id := {}
	var order: Array = []
	for c in contribs:
		var key := "%s:%s" % [str(c.get("kind", "")), str(c.get("id", ""))]
		if by_id.has(key):
			by_id[key]["w"] = float(by_id[key]["w"]) + float(c["w"])
		else:
			by_id[key] = c
			order.append(key)
	var out: Array = []
	for k in order:
		out.append(by_id[k])
	return out


func _finish(b: Dictionary, r0: Dictionary, r1: Dictionary, frac: float,
		auto_f: float, contribs: Array) -> Dictionary:
	var st := blank_state()
	var depth := float(b["fog_depth_m"])
	if not is_finite(depth):
		depth = _default_depth()
	var fog_sigma := float(b["fog_sigma"])
	var f0: Dictionary = r0.get("features", {})
	var cloud_raw := float(f0.get("cloud", NAN))
	var low := float(f0.get("low", NAN))
	# The part of the low cloud that is really fog on the ground comes back out
	# of the overhead cover — ERA5's 100 % "low cloud" at Walton was the fog.
	var ground := 0.0
	if is_finite(low) and is_finite(cloud_raw):
		ground = minf(low, cloud_raw) * clampf(lerpf(float(r0.get("ground", 0.0)),
			float(r1.get("ground", 0.0)), frac) * 1.5, 0.0, 1.0)
	var fog_col: Color = b["fog_color"]
	if (fog_col.r + fog_col.g + fog_col.b) <= 0.0:
		fog_col = Color(0.82, 0.84, 0.86)
	var haze_col: Color = b["haze_color"]
	if (haze_col.r + haze_col.g + haze_col.b) <= 0.0:
		haze_col = Color(0.7, 0.72, 0.75)
	st["fog_sigma"] = fog_sigma
	st["fog_vis_m"] = FogOptics.visibility_for_sigma(fog_sigma)
	st["fog_depth_m"] = depth
	st["fog_floor_y"] = _floor_y
	st["fog_top_y"] = _floor_y + depth
	st["fog_color"] = fog_col
	st["haze_sigma"] = float(b["haze_sigma"])
	st["haze_color"] = haze_col
	st["ground_cloud"] = ground
	st["cloud_delta"] = clampf(float(b["cloud_add"]) - ground, -1.0, 1.0)
	st["dust"] = float(b["dust"])
	st["wind_vis_mult"] = float(b["wind_vis_mult"])
	st["light_mult"] = float(b["light_mult"])
	st["physics"] = bool(b["physics"])
	st["auto_fog"] = auto_f
	st["auto_source"] = str(r0.get("auto_source", "none"))
	st["contributors"] = contribs
	st["features"] = f0
	st["active"] = fog_sigma > 1e-5 or float(b["haze_sigma"]) > 1e-6 or absf(float(st["cloud_delta"])) > 0.001 \
		or float(b["dust"]) > 0.001 or absf(float(b["wind_vis_mult"]) - 1.0) > 0.001 \
		or float(b["light_mult"]) < 0.999
	return st


## One hour's evaluation: features, auto fog over the look-back window, rule
## weights, nearest-match. Memoised; the memo is dropped on any profile or
## data change.
func _hour_result(h: int) -> Dictionary:
	if _hour_memo.has(h):
		return _hour_memo[h]
	var rows: Array = []
	for k in range(h - LOOKBACK_H, h + LOOKAHEAD_H + 1):
		rows.append(_features(k))
	var idx := LOOKBACK_H
	var params := {"cold_pool_bias_c": _cold_pool_bias()}
	var fog := FogDiagnosis.series(rows, params)
	var inst := FogDiagnosis.instant(rows[idx], params)
	# Stamp the auto fog onto each row so rules may test it.
	var stamped: Array = []
	for i in rows.size():
		var r: Dictionary = (rows[i] as Dictionary).duplicate()
		r["fog_auto"] = fog[i]
		stamped.append(r)
	var feats: Dictionary = stamped[idx]
	var contribs: Array = []
	for rule in profile.rules:
		var series := MicroclimateProfile.rule_series(rule, stamped)
		var w := series[idx]
		if w > 0.0:
			var look_id := str(rule.get("look", ""))
			contribs.append({"kind": "rule", "id": str(rule.get("id", "")),
				"name": str(rule.get("name", "")), "look": profile.looks.get(look_id, {}), "w": w})
	for c in profile.nearest_contributions(feats):
		contribs.append(c)
	var res := {
		"features": feats,
		"auto_fog": fog[idx],
		"auto_source": str(inst["source"]) if fog[idx] > 0.0 and float(inst["fog"]) > 0.0 \
			else ("held" if fog[idx] > 0.0 else "none"),
		"ground": float(inst["ground"]),
		"contribs": contribs,
	}
	if _hour_memo.size() >= MEMO_MAX:
		_hour_memo.clear()
	_hour_memo[h] = res
	return res


## The visual feature row for one hour. Physics corrections are already inside
## the WeatherService accessors; only the VISUAL ones are applied here.
func _features(h: int) -> Dictionary:
	if _feat_memo.has(h):
		return _feat_memo[h]
	var f := sample_features(float(h))
	f = profile.apply_corrections(f, "visual")
	var dep := float(f.get("dep_c", NAN))
	var de := FogDiagnosis.dep_eff(f, {"cold_pool_bias_c": _cold_pool_bias()})
	f["dep_eff_c"] = de if is_finite(de) else dep
	if _feat_memo.size() >= MEMO_MAX:
		_feat_memo.clear()
	_feat_memo[h] = f
	return f


## Raw feature row from WeatherService at an instant (no corrections beyond
## the physics ones the accessors carry).
func sample_features(abs_h: float) -> Dictionary:
	var clock := _clock()
	var dd: Dictionary = clock.abs_hours_to_date(abs_h)
	var month := int(dd.get("month", 6))
	var day := int(dd.get("day", 15))
	var hour := float(dd.get("day_time", 12.0))
	var f := {"hour": hour, "month": float(month)}
	var ws := get_node_or_null("/root/WeatherService")
	if ws != null and bool(ws.call("has_data")):
		var t := float(ws.call("temperature_c", month, day, hour))
		var td := float(ws.call("dew_point_c", month, day, hour))
		f["t_c"] = t
		f["td_c"] = td
		f["dep_c"] = (t - minf(td, t)) if is_finite(t) and is_finite(td) else NAN
		f["rh"] = float(ws.call("humidity_pct", month, day, hour))
		f["wind_ms"] = float(ws.call("wind_speed_ms", month, day, hour))
		f["gust_ms"] = float(ws.call("wind_gust_ms", month, day, hour))
		f["cloud"] = float(ws.call("cloud_cover_frac", month, day, hour))
		f["low"] = float(ws.call("low_cloud_frac", month, day, hour))
		var vis := float(ws.call("model_visibility_m", month, day, hour))
		f["vis_m"] = vis
		f["vis_km"] = vis / 1000.0 if is_finite(vis) else NAN
		f["rain_mmh"] = float(ws.call("rain_rate_mmh", month, day, hour))
		f["source"] = str(ws.call("get_sample_source", month, day, hour, false))
	var jd := clock.abs_hours_to_julian_day_utc(abs_h)
	var sp := SolarPosition.get_position(clock.latitude, clock.longitude, jd)
	f["sun_el"] = float(sp.get("elevation_deg", NAN))
	return f


func _label_for(abs_h: float) -> String:
	var dd: Dictionary = _clock().abs_hours_to_date(abs_h)
	var tod := float(dd.get("day_time", 0.0))
	return "%04d-%02d-%02d %02d:%02d" % [int(dd["year"]), int(dd["month"]), int(dd["day"]),
		int(tod), int((tod - floorf(tod)) * 60.0)]


func _clock() -> CelestialClock:
	if _main != null and is_instance_valid(_main):
		var c: Variant = _main.get("clock")
		if c is CelestialClock:
			return c
	return _scratch_clock


func _cold_pool_bias() -> float:
	var s := float(profile.settings.get("cold_pool_bias_c", NAN))
	if is_finite(s):
		return maxf(s, 0.0)
	return FogDiagnosis.cold_pool_bias_for_tpi(_tpi_m) if _has_terrain else 0.0


## A valley fog fills roughly the lower third of the hollow (TPI is measured
## at the valley floor, i.e. the full depth); on open ground it
## is a shallow 30 m radiation layer.
func _default_depth() -> float:
	var s := float(profile.settings.get("fog_depth_m", NAN))
	if is_finite(s) and s > 0.0:
		return s
	if _has_terrain and _tpi_m < 0.0:
		return clampf(-_tpi_m * 0.35, 25.0, 150.0)
	return 30.0


func _now_abs_hours() -> float:
	var c := _clock()
	if c == _scratch_clock:
		return NAN
	return c.get_absolute_hours()


func _resolve_main() -> void:
	if _main != null and is_instance_valid(_main):
		return
	_main = null
	var tree := get_tree()
	if tree == null:
		return
	for child in tree.root.get_children():
		if "day_time" in child and "sun" in child:
			_main = child
			break
	if _main != null:
		if _main.has_signal("location_changed") and not _main.is_connected("location_changed", _on_location_changed):
			_main.connect("location_changed", _on_location_changed)
		var ws := get_node_or_null("/root/WeatherService")
		if ws != null:
			for sig in ["weather_data_ready", "forecast_data_ready", "current_year_archive_ready"]:
				if ws.has_signal(sig) and not ws.is_connected(sig, _on_weather_changed):
					ws.connect(sig, _on_weather_changed)


func _on_weather_changed(_a = null, _b = null, _c = null) -> void:
	invalidate()


func _on_location_changed(_lat: float, _lon: float) -> void:
	_site_key = ""
	invalidate()


## Bind the profile and the terrain context to the current map (once per map,
## re-done when the terrain finishes loading).
func _ensure_site() -> void:
	var loader := _find_terrain_loader()
	var key := ""
	var path := ""
	if loader != null:
		var lat: Variant = loader.get("_lat")
		var lon: Variant = loader.get("_lon")
		if lat is float and lon is float and not (is_zero_approx(lat) and is_zero_approx(lon)):
			path = MicroclimateProfile.save_path_for_map(float(lat), float(lon))
	if path.is_empty():
		var sp := str(get_tree().current_scene.scene_file_path) if get_tree().current_scene != null else ""
		path = MicroclimateProfile.save_path_for_scene(sp)
	key = path
	# Only once the load has COMPLETED: the detail footing exists earlier, but
	# before the loader centres the world on the mean elevation it answers in
	# metres above sea level — at Walton that put the fog floor at y 119 while
	# the people stood at y −100, i.e. 220 m under a fog layer they never saw.
	var terrain_ready: bool = loader != null and loader.get("load_completed") == true
	if key == _site_key and (terrain_ready == _has_terrain):
		return
	if key != _site_key:
		_site_key = key
		_profile_path = path
		profile = MicroclimateProfile.load_from(path)
		MicroclimateCorrections.set_physics(profile.corrections)
		profile_changed.emit()
	_measure_terrain(loader if terrain_ready else null)
	invalidate()
	site_context_changed.emit()


## Where a cold pool collects: the LOWEST ground within ~1.5 km of the site
## marker (a 13×13 sample grid), not the marker itself — at Walton the marker
## sat partway up a slope ~200 m above the creek where the property is, and a
## fog layer hung from the marker floated over the people standing in it.
## The topographic position index (Weiss 2001: ground minus the mean of two
## rings at 1 km and 2.5 km, 12 points each) is then taken at that floor —
## the valley's depth, which sets the cold-pool bias and the fog depth.
## Samples off the built terrain are skipped.
func _measure_terrain(loader: Node) -> void:
	_has_terrain = false
	_tpi_m = 0.0
	_floor_y = 0.0
	if loader == null:
		return
	var xz := Vector2.ZERO
	if loader.has_method("_spawn_xz"):
		xz = loader.call("_spawn_xz")
	_site_xz = xz
	var half := float(loader.get("_half_extent")) if loader.get("_half_extent") != null else 3000.0
	var lim := half - 10.0
	var floor_y := INF
	var floor_xz := xz
	for i in range(-6, 7):
		for j in range(-6, 7):
			var p := xz + Vector2(float(i), float(j)) * 250.0
			if absf(p.x) > lim or absf(p.y) > lim:
				continue
			var y := float(loader.call("ground_height_at", p.x, p.y))
			if is_finite(y) and y < floor_y:
				floor_y = y
				floor_xz = p
	if not is_finite(floor_y):
		return
	var sum := 0.0
	var n := 0
	for r in [1000.0, 2500.0]:
		for i in 12:
			var a := TAU * float(i) / 12.0
			var p: Vector2 = floor_xz + Vector2(cos(a), sin(a)) * float(r)
			if absf(p.x) > lim or absf(p.y) > lim:
				continue
			var y := float(loader.call("ground_height_at", p.x, p.y))
			if is_finite(y):
				sum += y
				n += 1
	_floor_y = floor_y
	_tpi_m = floor_y - sum / float(n) if n > 0 else 0.0
	_has_terrain = true


func _find_terrain_loader() -> Node:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	return tree.current_scene.find_child("TerrainLoader", true, false)

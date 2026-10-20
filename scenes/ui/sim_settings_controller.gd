extends Node

## Shared simulation settings logic (date, location, clouds, lighting, live mode).
## TimelineUI and the legacy TimeUI delegate here.

signal live_mode_changed(enabled: bool)
signal simulation_started(initial_battery_soc: float, initial_load_kw: float, initial_solar_kw: float)
signal drone_settings_changed
signal connector_losses_changed(enabled: bool)
signal force_rainbow_changed(enabled: bool)
signal conduits_3d_visible_changed(enabled: bool)
signal conduit_flow_glow_changed(enabled: bool)

const REALTIME_SCALE: float = 1.0 / 3600.0
const LIVE_SYNC_INTERVAL: float = 10.0
## Settings → Environment → Horizon / Atmospheric haze. Each is a Main
## set_<key>/get_<key> pair saved under [rendering_adv] (apply_sky_setting).
const HORIZON_FLOAT_KEYS := ["horizon_height_deg", "horizon_softness_deg", "horizon_haze",
	"horizon_haze_height_deg", "horizon_match_haze", "haze_density_mult", "haze_aerial_mult",
	"haze_sun_glow_mult", "twilight_cool_bias", "late_day_clearing"]
const HORIZON_COLOR_KEYS := ["horizon_user_color", "day_haze_color", "sky_zenith_color", "sky_horizon_color"]

## Single source of truth for FPV drone flight defaults (m/s unless noted).
const DRONE_DEFAULTS := {
	"max_forward_speed": 65.0,
	"vertical_speed": 35.0,
	"acceleration": 45.0,
	"drag": 10.0,
	"steering_sensitivity": 2.5,
	"min_altitude": 0.5,
	"max_altitude": 8000.0,
	"tilt_intensity": 35.0,
	"tilt_speed": 8.0,
}


var main_node: Node3D = null
var live_mode_enabled: bool = false
var stored_time_scale: float = 0.016667
## Wave 8: opt-in connector loss simulation (wire I^2R loss + pipe friction
## derate + overload burnout). Default OFF so existing saves are unchanged.
var connector_losses_enabled: bool = false
## Show 3D conduit meshes in the world (conceptual / cords / pipes).
## Default OFF — wires are opt-in via the timeline "3D wires" chip (perf).
var conduits_3d_visible: bool = false
## Opt-in flow-glow overlay on conduits (off = quiet static look).
var conduit_flow_glow_enabled: bool = false
## Debug/test: force the antisolar rainbow on regardless of rain. The shader still
## only draws it when the geometry is right (sun low, arc above the horizon).
var force_rainbow: bool = false

var _live_mode_syncing: bool = false
var _live_sync_counter: float = 0.0
var _loc_updating: bool = false
var _solar_ui: Control = null
var _drone_settings: Dictionary = {}
## Settings changed at the LAUNCH HUB (no Main): every apply_* above a world
## writes to Main, so with none running the value would be lost. The hub's
## pages store theirs here as "section|key" -> value and persist_settings()
## writes them into sim_settings.cfg, where the next world's Main reads them
## (_load_persisted_settings). Stars and planets go straight to their own
## files (StarSystem.store_settings / PlanetSystem.store_settings).
var _hub_pending: Dictionary = {}


## No world is running: the hub's settings pages are open.
func is_hub() -> bool:
	return _valid_main() == null


func _hub_store(section: String, key: String, value: Variant) -> void:
	_hub_pending["%s|%s" % [section, key]] = value


## What the hub's pages show when there is no Main to read: the saved values
## (plus anything stored this session), keyed like get_state_snapshot().
func hub_snapshot() -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_CFG)
	var snap := {
		"graphics_quality": int(cfg.get_value("rendering", "graphics_quality", 2)),
		"shadow_quality": int(cfg.get_value("rendering", "shadow_quality", 2)),
		"shadow_opacity": float(cfg.get_value("rendering_adv", "shadow_opacity", 1.0)),
		"player_fov": float(cfg.get_value("camera", "player_fov", 50.0)),
	}
	for k in _hub_pending:
		var parts := str(k).split("|")
		if parts.size() == 2:
			snap[parts[1]] = _hub_pending[k]
	snap.merge(StarSystem.saved_settings())
	snap.merge(PlanetSystem.saved_settings())
	return snap


func _ready() -> void:
	_drone_settings = DRONE_DEFAULTS.duplicate(true)
	_load_drone_settings_from_disk()
	var tree := get_tree()
	if tree != null:
		tree.scene_changed.connect(_on_scene_changed)
	call_deferred("_resolve_main")
	set_process(true)


## Safety net: persist_settings() normally runs when the settings panel closes,
## but a player can quit via the OS window close button / Alt+F4 without ever
## closing that panel, silently dropping any changes made since it was last
## closed. Catch that path here too.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		persist_settings()


func reset_scene_binding() -> void:
	_on_scene_changed()


func _on_scene_changed() -> void:
	_detach_main_signals()
	main_node = null
	call_deferred("_resolve_main")
	call_deferred("_push_drone_settings_to_vehicles")


func _detach_main_signals() -> void:
	if main_node == null or not is_instance_valid(main_node):
		return
	if main_node.has_signal("location_changed") \
			and main_node.location_changed.is_connected(_on_main_location_changed):
		main_node.location_changed.disconnect(_on_main_location_changed)


func _invalidate_stale_main() -> void:
	if main_node != null and not is_instance_valid(main_node):
		main_node = null


func _valid_main() -> Node3D:
	_invalidate_stale_main()
	if main_node == null:
		_resolve_main()
	_invalidate_stale_main()
	return main_node


func _resolve_main() -> void:
	_invalidate_stale_main()
	if is_instance_valid(main_node):
		return
	main_node = null
	var tree := get_tree()
	if tree == null:
		return
	var scene := tree.current_scene
	if scene != null and scene.has_method("get_lunar_phase"):
		main_node = scene as Node3D
	elif tree.get_nodes_in_group("main_scene").size() > 0:
		main_node = tree.get_nodes_in_group("main_scene")[0] as Node3D
	if main_node != null:
		if main_node.has_signal("location_changed"):
			if not main_node.location_changed.is_connected(_on_main_location_changed):
				main_node.location_changed.connect(_on_main_location_changed)
		stored_time_scale = float(main_node.get("time_scale") if main_node.get("time_scale") != null else 0.016667)
		call_deferred("_initialize_sim_defaults")


func _process(delta: float) -> void:
	var main := _valid_main()
	if main == null:
		return
	if live_mode_enabled and not _live_mode_syncing:
		var ts: float = float(main.get("time_scale") if main.get("time_scale") != null else 0.0)
		if ts <= REALTIME_SCALE * 1.1:
			_live_sync_counter += delta
			if _live_sync_counter >= LIVE_SYNC_INTERVAL:
				_live_sync_counter = 0.0
				sync_to_system_time()


func refresh_from_main() -> Dictionary:
	var main := _valid_main()
	if main == null:
		return {}
	stored_time_scale = float(main.get("time_scale") if main.get("time_scale") != null else stored_time_scale)
	return get_state_snapshot()


func get_state_snapshot() -> Dictionary:
	var main := _valid_main()
	if main == null:
		return {}
	var snap := {
		"year": int(main.get("year")),
		"month": int(main.get("month")),
		"day": int(main.get("day")),
		"latitude": float(main.get("latitude")),
		"longitude": float(main.get("longitude")),
		"auto_dst": bool(main.get("auto_dst")),
		"manual_dst": bool(main.get("manual_dst")),
		"clouds_cutoff_ui": 1.0 - float(main.get("clouds_cutoff")),
		"clouds_weight": float(main.get("clouds_weight")),
		"sun_energy": float(main.get("sun_base_enegry")),
		"shadow_quality": main.get_shadow_quality_level() if main.has_method("get_shadow_quality_level") else 2,
		"graphics_quality": main.get_graphics_quality_level() if main.has_method("get_graphics_quality_level") else 2,
		"moon_energy": float(main.get("moon_base_enegry")),
		"live_mode": live_mode_enabled,
		"survival_active": not bool(main.get("gameplay_mechanics_paused")),
		"plant_growth_enabled": _main_bool("get_plant_growth_enabled", true),
		"analemma_diurnal_offset_min_per_day": _main_float("get_analemma_diurnal_offset_min_per_day", 0.0),
		"analemma_noon_offset_minutes": _main_float("get_analemma_noon_offset_minutes", 0.0),
		"show_sun_path": _main_bool("get_show_sun_path", true),
		"show_moon_path": _main_bool("get_show_moon_path", false),
		"show_planet_paths": _main_bool("get_show_planet_paths", false),
		"planet_path_frame": _main_int("get_planet_path_frame", 0),
		"analemma_star_reveal": _main_float("get_analemma_star_reveal", 0.75),
		"analemma_type": _main_int("get_analemma_type", 0),
		"analemma_path_thickness": float(main.get("analemma_path_thickness")) if "analemma_path_thickness" in main else 1.0,
		"analemma_solar_color": main.get("analemma_solar_color") if "analemma_solar_color" in main else Color(1.0, 0.9, 0.3),
		"analemma_lunar_color": main.get("analemma_lunar_color") if "analemma_lunar_color" in main else Color(0.7, 0.85, 1.0),
		"moon_phase_text": get_moon_phase_text(),
		"live_mode_status": get_live_mode_status(),
		"gameplay_status": get_gameplay_status(),
		"dst_status": get_dst_status_text(),
		"ambient_energy_mult": _main_float("get_ambient_energy_mult", 1.0),
		"ambient_sky_contribution": _main_float("get_ambient_sky_contribution", 0.15),
		"glow_intensity_mult": _main_float("get_glow_intensity_mult", 1.0),
		"glow_user_enabled": _main_bool("get_glow_user_enabled", true),
		"ssao_enabled": _main_bool("get_ssao_enabled", true),
		"ssil_enabled": _main_bool("get_ssil_enabled", true),
		"sdfgi_enabled": _main_bool("get_sdfgi_enabled", false),
		"volumetric_fog_enabled": _main_bool("get_volumetric_fog_enabled", false),
		"tonemap_mode": _main_int("get_tonemap_mode", Environment.TONE_MAPPER_ACES),
		"msaa_level": _main_int("get_msaa_level", 0),
		"tonemap_exposure": _main_float("get_tonemap_exposure", 1.0),
		"tonemap_white": _main_float("get_tonemap_white", 1.0),
		"fog_amount": _main_float("get_fog_amount", 0.2),
		"sun_size": _main_float("get_sun_size", 0.15),
		"moon_size": _main_float("get_moon_size", 0.05),
		"moon_glow": _main_float("get_moon_glow", 0.5),
		"sun_glow": _main_float("get_sun_glow", 1.4),
		"sun_glow_size": _main_float("get_sun_glow_size", 9.0),
		"sun_aureole": _main_float("get_sun_aureole", 0.8),
		"twilight_drama": _main_float("get_twilight_drama", 1.2),
		"twilight_length": _main_float("get_twilight_length", 1.0),
		"sun_warmth": _main_float("get_sun_warmth", 1.0),
		"airglow_strength": _main_float("get_airglow_strength", 0.25),
		"airglow_color": main.call("get_airglow_color") if main.has_method("get_airglow_color") else Color(0.16, 0.30, 0.22),
		"light_pollution": _main_float("get_light_pollution", 0.0),
		"light_pollution_color": main.call("get_light_pollution_color") if main.has_method("get_light_pollution_color") else Color(0.95, 0.62, 0.35),
		"moon_sky_glow": _main_float("get_moon_sky_glow", 1.0),
		"cirrus_user_scale": _main_float("get_cirrus_user_scale", 1.0),
		"cirrus_wave_frequency_scale": _main_float("get_cirrus_wave_frequency_scale", 1.0),
		"cirrus_wave_intensity_scale": _main_float("get_cirrus_wave_intensity_scale", 1.0),
		"cloud_shadows_enabled": _main_bool("get_cloud_shadows_enabled", true),
		"building_shadows_enabled": _main_bool("get_building_shadows_enabled", false),
		"shadow_opacity": _main_float("get_shadow_opacity", 1.0),
		"god_rays_enabled": _main_bool("get_god_rays_enabled", false),
		"player_fov": _main_float("get_player_fov", 50.0),
		"drone_fov": _main_float("get_drone_fov", 50.0),
	}
	for hk in HORIZON_FLOAT_KEYS + HORIZON_COLOR_KEYS:
		if main.has_method("get_" + hk):
			snap[hk] = main.call("get_" + hk)
	var star := _star_system()
	if star != null and star.has_method("get_settings"):
		snap.merge(star.get_settings())
	var planet := _planet_system()
	if planet != null and planet.has_method("get_settings"):
		snap.merge(planet.get_settings())
	snap.merge(get_solar_panel_settings())
	snap.merge(get_ha_connection_snapshot())
	snap.merge(get_drone_flight_settings())
	return snap


func apply_year(value: int) -> void:
	var main := _valid_main()
	if main == null:
		return
	_apply_calendar(main, value, int(main.month), int(main.day))


func apply_month(value: int) -> void:
	var main := _valid_main()
	if main == null:
		return
	_apply_calendar(main, int(main.year), value, int(main.day))


func apply_day(value: int) -> void:
	var main := _valid_main()
	if main == null:
		return
	var max_days := get_days_in_month(int(main.month), int(main.year))
	_apply_calendar(main, int(main.year), int(main.month), clampi(value, 1, max_days))


## Set calendar fields via set_absolute_hours so spinboxes and the timeline track
## always share one canonical timecode.
func _apply_calendar(main: Node, yr: int, mo: int, dy: int) -> void:
	if not main.has_method("get_absolute_hours") or not main.has_method("set_absolute_hours"):
		main.year = yr
		main.month = mo
		main.day = dy
		return
	var clk: Variant = main.get("clock")
	if clk == null or not clk.has_method("abs_hours_to_date"):
		main.year = yr
		main.month = mo
		main.day = dy
		return
	var cur: float = float(main.call("get_absolute_hours"))
	var dd: Dictionary = clk.abs_hours_to_date(cur)
	var tod: float = float(dd.get("day_time", 12.0))
	mo = clampi(mo, 1, 12)
	dy = clampi(dy, 1, get_days_in_month(mo, yr))
	var doy: int = clk.call("_calculate_day_of_year", mo, dy, yr)
	var abs_h: float = float(clk.call("_days_before_year", yr) + (doy - 1)) * 24.0 + tod
	main.call("set_absolute_hours", abs_h)
	update_day_max_for(mo, yr)


func get_days_in_month(month: int, year: int) -> int:
	if main_node != null and main_node.has_method("get_days_in_month"):
		return int(main_node.call("get_days_in_month", month, year))
	return 31


func update_day_max_for(month: int, year: int) -> int:
	var main := _valid_main()
	if main == null:
		return 31
	var max_days := get_days_in_month(month, year)
	if int(main.day) > max_days:
		main.day = max_days
	return max_days


func apply_latitude(value: float) -> void:
	if _loc_updating or main_node == null:
		return
	var lon := float(main_node.get("longitude"))
	if main_node.has_method("apply_location"):
		main_node.apply_location(value, lon)
	else:
		main_node.latitude = value


func apply_longitude(value: float) -> void:
	if _loc_updating or main_node == null:
		return
	var lat := float(main_node.get("latitude"))
	if main_node.has_method("apply_location"):
		main_node.apply_location(lat, value)
	else:
		main_node.longitude = value


func set_auto_dst(toggled_on: bool) -> void:
	if main_node == null:
		return
	main_node.auto_dst = toggled_on


func set_manual_dst(toggled_on: bool) -> void:
	if main_node == null:
		return
	main_node.manual_dst = toggled_on


func apply_clouds_cutoff_ui(value: float) -> void:
	if main_node == null:
		return
	main_node.clouds_cutoff = 1.0 - value
	if _solar_ui == null or not is_instance_valid(_solar_ui):
		var tree := get_tree()
		if tree != null:
			_solar_ui = tree.root.get_node_or_null("Main/UILayer/SolarUI")
			if _solar_ui == null and tree.current_scene != null:
				_solar_ui = tree.current_scene.get_node_or_null("UILayer/SolarUI")
	if _solar_ui != null and _solar_ui.has_method("set_cloud_cover_from_slider"):
		_solar_ui.set_cloud_cover_from_slider(value)


func apply_clouds_weight(value: float) -> void:
	if main_node == null:
		return
	main_node.clouds_weight = value


func apply_sun_energy(value: float) -> void:
	if main_node == null:
		return
	main_node.sun_base_enegry = value


func apply_shadow_quality(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_shadow_quality_level"):
		main.call("set_shadow_quality_level", int(value))
	elif main == null:
		_hub_store("rendering", "shadow_quality", int(value))

func apply_shadow_opacity(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_shadow_opacity"):
		main.call("set_shadow_opacity", value)
	elif main == null:
		_hub_store("rendering_adv", "shadow_opacity", value)


func apply_graphics_quality(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_graphics_quality_level"):
		main.set_graphics_quality_level(int(value))
	elif main == null:
		_hub_store("rendering", "graphics_quality", int(value))


func apply_moon_energy(value: float) -> void:
	if main_node == null:
		return
	main_node.moon_base_enegry = value


func apply_ambient_energy_mult(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_ambient_energy_mult"):
		main.call("set_ambient_energy_mult", value)


func apply_ambient_sky_contribution(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_ambient_sky_contribution"):
		main.call("set_ambient_sky_contribution", value)


func apply_glow_intensity_mult(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_glow_intensity_mult"):
		main.call("set_glow_intensity_mult", value)


func apply_glow_user_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_glow_user_enabled"):
		main.call("set_glow_user_enabled", on)


func apply_ssao_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_ssao_enabled"):
		main.call("set_ssao_enabled", on)


func apply_ssil_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_ssil_enabled"):
		main.call("set_ssil_enabled", on)


func apply_sdfgi_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_sdfgi_enabled"):
		main.call("set_sdfgi_enabled", on)


func apply_volumetric_fog_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_volumetric_fog_enabled"):
		main.call("set_volumetric_fog_enabled", on)


func apply_tonemap_mode(mode: int) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_tonemap_mode"):
		main.call("set_tonemap_mode", mode)


func apply_msaa_level(level: int) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_msaa_level"):
		main.call("set_msaa_level", level)


func apply_tonemap_exposure(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_tonemap_exposure"):
		main.call("set_tonemap_exposure", value)


func apply_tonemap_white(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_tonemap_white"):
		main.call("set_tonemap_white", value)


func apply_fog_amount(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_fog_amount"):
		main.call("set_fog_amount", value)


func apply_sun_size(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_sun_size"):
		main.call("set_sun_size", value)


func apply_moon_size(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_moon_size"):
		main.call("set_moon_size", value)


func apply_moon_glow(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_moon_glow"):
		main.call("set_moon_glow", value)


func apply_sun_glow(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_sun_glow"):
		main.call("set_sun_glow", value)


func apply_sun_glow_size(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_sun_glow_size"):
		main.call("set_sun_glow_size", value)


func apply_sun_aureole(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_sun_aureole"):
		main.call("set_sun_aureole", value)


## Night-sky / twilight knobs (sky.gdshader NIGHT + TWILIGHT blocks via Main).
func apply_sky_setting(key: String, value: Variant) -> void:
	var main := _valid_main()
	if main == null:
		return
	var setter := "set_" + key
	if main.has_method(setter):
		main.call(setter, value)


func apply_cirrus_scale(value: float) -> void:
	if main_node != null and main_node.has_method("set_cirrus_user_scale"):
		main_node.set_cirrus_user_scale(value)

func apply_cirrus_wave_frequency_scale(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_cirrus_wave_frequency_scale"):
		main.call("set_cirrus_wave_frequency_scale", value)

func apply_cirrus_wave_intensity_scale(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_cirrus_wave_intensity_scale"):
		main.call("set_cirrus_wave_intensity_scale", value)


func apply_cloud_shadows_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_cloud_shadows_enabled"):
		main.call("set_cloud_shadows_enabled", on)

func apply_building_shadows_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_building_shadows_enabled"):
		main.call("set_building_shadows_enabled", on)


func apply_god_rays_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_god_rays_enabled"):
		main.call("set_god_rays_enabled", on)


func apply_plant_growth_enabled(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_plant_growth_enabled"):
		main.call("set_plant_growth_enabled", on)


func apply_analemma_diurnal_offset(minutes: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_analemma_diurnal_offset_min_per_day"):
		main.call("set_analemma_diurnal_offset_min_per_day", minutes)


func apply_analemma_noon_offset(minutes: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_analemma_noon_offset_minutes"):
		main.call("set_analemma_noon_offset_minutes", minutes)


func apply_show_sun_path(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_show_sun_path"):
		main.call("set_show_sun_path", on)


func apply_show_moon_path(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_show_moon_path"):
		main.call("set_show_moon_path", on)


func apply_show_planet_paths(on: bool) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_show_planet_paths"):
		main.call("set_show_planet_paths", on)


func apply_analemma_star_reveal(amount: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_analemma_star_reveal"):
		main.call("set_analemma_star_reveal", amount)


func apply_planet_path_frame(frame: int) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_planet_path_frame"):
		main.call("set_planet_path_frame", frame)


func apply_analemma_type(type: int) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_analemma_type"):
		main.call("set_analemma_type", type)

func apply_analemma_path_thickness(thickness: float) -> void:
	var main := _valid_main()
	if main != null and "analemma_path_thickness" in main:
		main.set("analemma_path_thickness", thickness)

func apply_analemma_solar_color(col: Color) -> void:
	var main := _valid_main()
	if main != null and "analemma_solar_color" in main:
		main.set("analemma_solar_color", col)
		if main.has_method("_build_analemma_preview_mesh"):
			main.call("_build_analemma_preview_mesh")

func apply_analemma_lunar_color(col: Color) -> void:
	var main := _valid_main()
	if main != null and "analemma_lunar_color" in main:
		main.set("analemma_lunar_color", col)
		if main.has_method("_build_moon_preview_mesh"):
			main.call("_build_moon_preview_mesh")


func apply_player_fov(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_player_fov"):
		main.call("set_player_fov", value)
	elif main == null:
		_hub_store("camera", "player_fov", value)


func apply_drone_fov(value: float) -> void:
	var main := _valid_main()
	if main != null and main.has_method("set_drone_fov"):
		main.call("set_drone_fov", value)


func get_drone_flight_settings() -> Dictionary:
	return _drone_settings.duplicate(true)


func get_drone_flight_setting(key: String, fallback: float = 0.0) -> float:
	if _drone_settings.has(key):
		return float(_drone_settings[key])
	if DRONE_DEFAULTS.has(key):
		return float(DRONE_DEFAULTS[key])
	return fallback


func apply_drone_flight_setting(key: String, value: float) -> void:
	if not DRONE_DEFAULTS.has(key):
		return
	_drone_settings[key] = value
	_push_drone_settings_to_vehicles()
	drone_settings_changed.emit()



func _push_drone_settings_to_vehicles() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for node in tree.get_nodes_in_group("vehicles"):
		if node is FPVDrone:
			(node as FPVDrone).apply_flight_settings(_drone_settings)


func _persist_drone_to_cfg(cfg: ConfigFile) -> void:
	for key in DRONE_DEFAULTS:
		cfg.set_value("drone", key, float(_drone_settings.get(key, DRONE_DEFAULTS[key])))


func _load_drone_settings_from_disk() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_CFG) != OK or not cfg.has_section("drone"):
		return
	for key in DRONE_DEFAULTS:
		if cfg.has_section_key("drone", key):
			_drone_settings[key] = float(cfg.get_value("drone", key))


func apply_star_setting(key: String, value: Variant) -> void:
	var star := _star_system()
	var patch := {key: value}
	if star == null:
		# At the hub: straight into star_calibration.cfg, read by the next
		# world's StarSystem.
		if is_hub():
			StarSystem.store_settings(patch)
		return
	if star.has_method("apply_settings"):
		star.call("apply_settings", patch)


func upload_star_texture(source_path: String) -> bool:
	var star := _star_system()
	if star == null or not star.has_method("set_texture_from_path"):
		return false
	return bool(star.call("set_texture_from_path", source_path))


func reset_star_texture() -> void:
	var star := _star_system()
	if star != null and star.has_method("reset_texture_to_default"):
		star.call("reset_texture_to_default")


func apply_planet_setting(key: String, value: Variant) -> void:
	var planet := _planet_system()
	var patch := {key: value}
	if planet == null:
		if is_hub():
			PlanetSystem.store_settings(patch)
		return
	if planet.has_method("apply_settings"):
		planet.call("apply_settings", patch)


func set_all_planets_enabled(on: bool) -> void:
	var planet := _planet_system()
	if planet != null and planet.has_method("set_all_enabled"):
		planet.call("set_all_enabled", on)
	elif planet == null and is_hub():
		var patch := {}
		for pname in PlanetSystem.PLANET_NAMES:
			patch["%s_enabled" % pname] = on
		PlanetSystem.store_settings(patch)


func save_star_calibration() -> void:
	var star := _star_system()
	if star != null and star.has_method("save_calibration"):
		star.call("save_calibration")


func save_planet_prefs() -> void:
	var planet := _planet_system()
	if planet != null and planet.has_method("save_prefs"):
		planet.call("save_prefs")


func set_live_mode(enabled: bool) -> void:
	live_mode_enabled = enabled
	if live_mode_enabled:
		enable_live_mode()
	else:
		disable_live_mode()
	live_mode_changed.emit(live_mode_enabled)


func enable_live_mode() -> void:
	sync_to_system_time()
	stored_time_scale = REALTIME_SCALE
	if main_node != null and float(main_node.get("time_scale")) > 0.0:
		main_node.time_scale = stored_time_scale
	_auto_update_gameplay_pause()


func disable_live_mode() -> void:
	stored_time_scale = 1.0
	if main_node != null and float(main_node.get("time_scale")) > 0.0:
		main_node.time_scale = stored_time_scale
	_auto_update_gameplay_pause()


func sync_to_system_time() -> void:
	if main_node == null:
		return
	_live_mode_syncing = true
	var datetime: Dictionary = Time.get_datetime_dict_from_system()
	main_node.year = datetime.get("year", 2026)
	main_node.month = datetime.get("month", 1)
	main_node.day = datetime.get("day", 29)
	var hour: int = datetime.get("hour", 12)
	var minute: int = datetime.get("minute", 0)
	var second: int = datetime.get("second", 0)
	main_node.day_time = float(hour) + float(minute) / 60.0 + float(second) / 3600.0
	_live_mode_syncing = false


func set_connector_losses_enabled(enabled: bool) -> void:
	if connector_losses_enabled == enabled:
		return
	connector_losses_enabled = enabled
	connector_losses_changed.emit(enabled)


func set_conduits_3d_visible(enabled: bool) -> void:
	if conduits_3d_visible == enabled:
		return
	conduits_3d_visible = enabled
	conduits_3d_visible_changed.emit(enabled)
	_notify_conduit_manager_visibility()


func set_conduit_flow_glow_enabled(enabled: bool) -> void:
	if conduit_flow_glow_enabled == enabled:
		return
	conduit_flow_glow_enabled = enabled
	conduit_flow_glow_changed.emit(enabled)
	_notify_conduit_manager_flow_glow()


func _notify_conduit_manager_visibility() -> void:
	var main := _valid_main()
	if main == null:
		return
	var mgr := main.get_node_or_null("ConduitManager")
	if mgr != null and mgr.has_method("set_global_visibility"):
		mgr.call("set_global_visibility", conduits_3d_visible)


func _notify_conduit_manager_flow_glow() -> void:
	var main := _valid_main()
	if main == null:
		return
	var mgr := main.get_node_or_null("ConduitManager")
	if mgr != null and mgr.has_method("set_global_flow_glow"):
		mgr.call("set_global_flow_glow", conduit_flow_glow_enabled)


func set_force_rainbow(enabled: bool) -> void:
	if force_rainbow == enabled:
		return
	force_rainbow = enabled
	force_rainbow_changed.emit(enabled)


func set_survival_active(active: bool) -> void:
	set_gameplay_paused(not active)


func set_gameplay_paused(paused: bool) -> void:
	var gr := GameplayRulesImpl.from_node(main_node)
	if gr != null:
		gr.set_survival_paused(paused)
	if main_node != null:
		main_node.gameplay_mechanics_paused = paused


func notify_simulation_start() -> void:
	var solar_ui := _find_solar_ui()
	if solar_ui != null:
		simulation_started.emit(
			solar_ui.get_battery_percent(),
			solar_ui.current_load_kw,
			solar_ui.current_solar_kw)


func get_moon_phase_text() -> String:
	if main_node == null or not main_node.has_method("get_lunar_phase_name"):
		return ""
	var phase_name: String = main_node.get_lunar_phase_name()
	var phase_icon: String = _moon_phase_icon(main_node.get_lunar_phase())
	return "%s %s" % [phase_icon, phase_name]


func get_live_mode_status() -> Dictionary:
	if main_node == null:
		return {"text": "", "color": Color.WHITE}
	var ts: float = float(main_node.get("time_scale"))
	if live_mode_enabled:
		var speed_mult: float = ts / REALTIME_SCALE
		if speed_mult <= 1.1:
			return {"text": "LIVE - Real-time", "color": Color(0.3, 1.0, 0.5)}
		if speed_mult < 1000.0:
			return {"text": "%.0fx" % speed_mult, "color": Color(1.0, 0.8, 0.3)}
		return {"text": "%.0fkx" % (speed_mult / 1000.0), "color": Color(1.0, 0.8, 0.3)}
	return {"text": "Simulation Mode", "color": Color(0.6, 0.6, 0.6)}


func get_gameplay_status() -> Dictionary:
	if main_node == null:
		return {"text": "", "color": Color.WHITE}
	var paused: bool = bool(main_node.get("gameplay_mechanics_paused"))
	if paused:
		return {"text": "Survival paused", "color": Color(0.6, 0.6, 0.6)}
	return {"text": "Survival active", "color": Color(0.3, 1.0, 0.5)}


func get_dst_status_text() -> String:
	if main_node == null:
		return ""
	var is_dst: bool = main_node.is_dst_active()
	if bool(main_node.get("auto_dst")):
		return "DST: %s (auto)" % ("ON" if is_dst else "OFF")
	return "DST: %s (manual)" % ("ON" if is_dst else "OFF")


func get_latitude_hint(lat: float) -> String:
	var abs_lat: float = absf(lat)
	if abs_lat < 5.0:
		return "(Equator)"
	if abs_lat < 23.5:
		return "(Tropics)"
	if abs_lat < 35.0:
		return "(Subtropics)"
	if abs_lat < 50.0:
		return "(Temperate)"
	if abs_lat < 66.5:
		return "(Subarctic)"
	return "(Polar)"


func _initialize_sim_defaults() -> void:
	_load_persisted_settings()
	# Simulation mode by default — live mode (wall-clock 1× HA sync) is opt-in via settings.
	live_mode_enabled = false
	stored_time_scale = 0.016667
	# Deferred from _resolve_main: a scene change in the same frame frees Main
	# first, and get() on a freed node returns null (float(null) is the
	# "Nonexistent 'float' constructor" crash) - same guard as _process above.
	var main := _valid_main()
	var ts: Variant = main.get("time_scale") if main != null else null
	if ts is float and float(ts) > 0.0:
		# Leave an already-running time_scale untouched (save resume, etc.).
		stored_time_scale = float(ts)
	_auto_update_gameplay_pause()
	live_mode_changed.emit(false)


func _auto_update_gameplay_pause() -> void:
	if _is_time_beyond_realtime():
		set_gameplay_paused(true)


func _is_time_beyond_realtime() -> bool:
	if main_node == null:
		return false
	return float(main_node.get("time_scale")) > REALTIME_SCALE * 1.5


func _on_main_location_changed(lat: float, lon: float) -> void:
	_loc_updating = true
	# SpinBoxes in timeline/settings read snapshot on next refresh.
	_loc_updating = false


const SETTINGS_CFG := "user://sim_settings.cfg"


func persist_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_CFG)
	_persist_drone_to_cfg(cfg)
	if main_node == null:
		# The hub's pages: whatever was changed with no world running.
		for k in _hub_pending:
			var parts := str(k).split("|")
			if parts.size() == 2:
				cfg.set_value(parts[0], parts[1], _hub_pending[k])
		_hub_pending.clear()
		cfg.save(SETTINGS_CFG)
		return
	cfg.set_value("rendering", "clouds_cutoff", float(main_node.get("clouds_cutoff")))
	cfg.set_value("rendering", "clouds_weight", float(main_node.get("clouds_weight")))
	cfg.set_value("rendering", "sun_energy", float(main_node.get("sun_base_enegry")))
	cfg.set_value("rendering", "moon_energy", float(main_node.get("moon_base_enegry")))
	cfg.set_value("rendering", "shadow_quality",
		main_node.get_shadow_quality_level() if main_node.has_method("get_shadow_quality_level") else 2)
	cfg.set_value("rendering", "graphics_quality",
		main_node.get_graphics_quality_level() if main_node.has_method("get_graphics_quality_level") else 2)
	cfg.set_value("time", "auto_dst", bool(main_node.get("auto_dst")))
	cfg.set_value("time", "manual_dst", bool(main_node.get("manual_dst")))
	cfg.set_value("gameplay", "live_mode", live_mode_enabled)
	cfg.set_value("gameplay", "connector_losses_enabled", connector_losses_enabled)
	cfg.set_value("gameplay", "conduits_3d_visible", conduits_3d_visible)
	cfg.set_value("gameplay", "conduit_flow_glow_enabled", conduit_flow_glow_enabled)
	cfg.set_value("gameplay", "force_rainbow", force_rainbow)
	cfg.set_value("gameplay", "survival_active", not bool(main_node.get("gameplay_mechanics_paused")))
	if main_node.has_method("get_plant_growth_enabled"):
		cfg.set_value("gameplay", "plant_growth_enabled", main_node.call("get_plant_growth_enabled"))
	if main_node.has_method("get_analemma_diurnal_offset_min_per_day"):
		cfg.set_value("gameplay", "analemma_diurnal_offset_min_per_day",
			main_node.call("get_analemma_diurnal_offset_min_per_day"))
	if main_node.has_method("get_analemma_noon_offset_minutes"):
		cfg.set_value("gameplay", "analemma_noon_offset_minutes",
			main_node.call("get_analemma_noon_offset_minutes"))
	if main_node.has_method("get_show_sun_path"):
		cfg.set_value("gameplay", "show_sun_path", main_node.call("get_show_sun_path"))
	if main_node.has_method("get_show_moon_path"):
		cfg.set_value("gameplay", "show_moon_path", main_node.call("get_show_moon_path"))
	if main_node.has_method("get_show_planet_paths"):
		cfg.set_value("gameplay", "show_planet_paths", main_node.call("get_show_planet_paths"))
	if main_node.has_method("get_planet_path_frame"):
		cfg.set_value("gameplay", "planet_path_frame", main_node.call("get_planet_path_frame"))
	if main_node.has_method("get_analemma_star_reveal"):
		cfg.set_value("gameplay", "analemma_star_reveal", main_node.call("get_analemma_star_reveal"))
	if main_node.has_method("get_analemma_type"):
		cfg.set_value("gameplay", "analemma_type", main_node.call("get_analemma_type"))
	if "analemma_path_thickness" in main_node:
		cfg.set_value("gameplay", "analemma_path_thickness", main_node.get("analemma_path_thickness"))
	if "analemma_solar_color" in main_node:
		cfg.set_value("gameplay", "analemma_solar_color", main_node.get("analemma_solar_color"))
	if "analemma_lunar_color" in main_node:
		cfg.set_value("gameplay", "analemma_lunar_color", main_node.get("analemma_lunar_color"))
	if main_node.has_method("get_ambient_energy_mult"):
		cfg.set_value("rendering_adv", "ambient_energy_mult", main_node.call("get_ambient_energy_mult"))
		cfg.set_value("rendering_adv", "ambient_sky_contribution", main_node.call("get_ambient_sky_contribution"))
		cfg.set_value("rendering_adv", "glow_intensity_mult", main_node.call("get_glow_intensity_mult"))
		cfg.set_value("rendering_adv", "glow_user_enabled", main_node.call("get_glow_user_enabled"))
		cfg.set_value("rendering_adv", "ssao_enabled", main_node.call("get_ssao_enabled"))
		cfg.set_value("rendering_adv", "ssil_enabled", main_node.call("get_ssil_enabled"))
		cfg.set_value("rendering_adv", "sdfgi_enabled", main_node.call("get_sdfgi_enabled"))
		cfg.set_value("rendering_adv", "volumetric_fog_enabled", main_node.call("get_volumetric_fog_enabled"))
		cfg.set_value("rendering_adv", "tonemap_mode", main_node.call("get_tonemap_mode"))
		cfg.set_value("rendering_adv", "msaa_level", main_node.call("get_msaa_level"))
		cfg.set_value("rendering_adv", "tonemap_exposure", main_node.call("get_tonemap_exposure"))
		cfg.set_value("rendering_adv", "tonemap_white", main_node.call("get_tonemap_white"))
		cfg.set_value("rendering_adv", "fog_amount", main_node.call("get_fog_amount"))
		cfg.set_value("rendering_adv", "sun_size", main_node.call("get_sun_size"))
		cfg.set_value("rendering_adv", "moon_size", main_node.call("get_moon_size"))
		cfg.set_value("rendering_adv", "moon_glow", main_node.call("get_moon_glow"))
	if main_node.has_method("get_sun_glow"):
		cfg.set_value("rendering_adv", "sun_glow", main_node.call("get_sun_glow"))
		cfg.set_value("rendering_adv", "sun_glow_size", main_node.call("get_sun_glow_size"))
		cfg.set_value("rendering_adv", "sun_aureole", main_node.call("get_sun_aureole"))
	for sky_key in ["twilight_drama", "twilight_length", "sun_warmth", "airglow_strength", "airglow_color", "light_pollution", "light_pollution_color", "moon_sky_glow"] + HORIZON_FLOAT_KEYS + HORIZON_COLOR_KEYS:
		if main_node.has_method("get_" + sky_key):
			cfg.set_value("rendering_adv", sky_key, main_node.call("get_" + sky_key))
		if main_node.has_method("get_cirrus_user_scale"):
			cfg.set_value("rendering_adv", "cirrus_user_scale", main_node.call("get_cirrus_user_scale"))
		if main_node.has_method("get_cirrus_wave_frequency_scale"):
			cfg.set_value("rendering_adv", "cirrus_wave_frequency_scale", main_node.call("get_cirrus_wave_frequency_scale"))
		if main_node.has_method("get_cirrus_wave_intensity_scale"):
			cfg.set_value("rendering_adv", "cirrus_wave_intensity_scale", main_node.call("get_cirrus_wave_intensity_scale"))
		if main_node.has_method("get_cloud_shadows_enabled"):
			cfg.set_value("rendering_adv", "cloud_shadows_enabled", main_node.call("get_cloud_shadows_enabled"))
	if main_node.has_method("get_building_shadows_enabled"):
		cfg.set_value("rendering_adv", "building_shadows_enabled", main_node.call("get_building_shadows_enabled"))
	if main_node.has_method("get_shadow_opacity"):
		cfg.set_value("rendering_adv", "shadow_opacity", main_node.call("get_shadow_opacity"))
	if main_node.has_method("get_god_rays_enabled"):
		cfg.set_value("rendering_adv", "god_rays_enabled", main_node.call("get_god_rays_enabled"))
	if main_node.has_method("get_player_fov"):
		cfg.set_value("camera", "player_fov", main_node.call("get_player_fov"))
		cfg.set_value("camera", "drone_fov", main_node.call("get_drone_fov"))
	save_star_calibration()
	save_planet_prefs()
	save_ha_connection_from_panel()
	cfg.save(SETTINGS_CFG)


func _load_persisted_settings() -> void:
	if main_node == null:
		return
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_CFG) != OK:
		return
	if cfg.has_section_key("rendering", "clouds_cutoff"):
		main_node.clouds_cutoff = float(cfg.get_value("rendering", "clouds_cutoff"))
	if cfg.has_section_key("rendering", "clouds_weight"):
		main_node.clouds_weight = float(cfg.get_value("rendering", "clouds_weight"))
	if cfg.has_section_key("rendering", "sun_energy"):
		main_node.sun_base_enegry = float(cfg.get_value("rendering", "sun_energy"))
	if cfg.has_section_key("rendering", "moon_energy"):
		main_node.moon_base_enegry = float(cfg.get_value("rendering", "moon_energy"))
	if cfg.has_section_key("rendering", "shadow_quality") \
			and main_node.has_method("set_shadow_quality_level"):
		main_node.set_shadow_quality_level(int(cfg.get_value("rendering", "shadow_quality")))
	if cfg.has_section_key("rendering", "graphics_quality") \
			and main_node.has_method("set_graphics_quality_level"):
		main_node.set_graphics_quality_level(int(cfg.get_value("rendering", "graphics_quality")))
	if cfg.has_section_key("time", "auto_dst"):
		main_node.auto_dst = bool(cfg.get_value("time", "auto_dst"))
	if cfg.has_section_key("time", "manual_dst"):
		main_node.manual_dst = bool(cfg.get_value("time", "manual_dst"))
	if cfg.has_section_key("gameplay", "survival_active"):
		set_survival_active(bool(cfg.get_value("gameplay", "survival_active")))
	if cfg.has_section_key("gameplay", "plant_growth_enabled"):
		apply_plant_growth_enabled(bool(cfg.get_value("gameplay", "plant_growth_enabled")))
	if cfg.has_section_key("gameplay", "analemma_diurnal_offset_min_per_day"):
		apply_analemma_diurnal_offset(float(cfg.get_value("gameplay", "analemma_diurnal_offset_min_per_day")))
	if cfg.has_section_key("gameplay", "analemma_noon_offset_minutes"):
		apply_analemma_noon_offset(float(cfg.get_value("gameplay", "analemma_noon_offset_minutes")))
	if cfg.has_section_key("gameplay", "show_sun_path"):
		apply_show_sun_path(bool(cfg.get_value("gameplay", "show_sun_path")))
	if cfg.has_section_key("gameplay", "show_moon_path"):
		apply_show_moon_path(bool(cfg.get_value("gameplay", "show_moon_path")))
	if cfg.has_section_key("gameplay", "show_planet_paths"):
		apply_show_planet_paths(bool(cfg.get_value("gameplay", "show_planet_paths")))
	if cfg.has_section_key("gameplay", "planet_path_frame"):
		apply_planet_path_frame(int(cfg.get_value("gameplay", "planet_path_frame")))
	if cfg.has_section_key("gameplay", "analemma_star_reveal"):
		apply_analemma_star_reveal(float(cfg.get_value("gameplay", "analemma_star_reveal")))
	if cfg.has_section_key("gameplay", "analemma_type"):
		apply_analemma_type(int(cfg.get_value("gameplay", "analemma_type")))
	if cfg.has_section_key("gameplay", "analemma_path_thickness"):
		apply_analemma_path_thickness(float(cfg.get_value("gameplay", "analemma_path_thickness")))
	if cfg.has_section_key("gameplay", "analemma_solar_color"):
		apply_analemma_solar_color(cfg.get_value("gameplay", "analemma_solar_color") as Color)
	if cfg.has_section_key("gameplay", "analemma_lunar_color"):
		apply_analemma_lunar_color(cfg.get_value("gameplay", "analemma_lunar_color") as Color)
	if cfg.has_section_key("gameplay", "live_mode") and bool(cfg.get_value("gameplay", "live_mode")):
		set_live_mode(true)
	if cfg.has_section_key("gameplay", "connector_losses_enabled"):
		set_connector_losses_enabled(bool(cfg.get_value("gameplay", "connector_losses_enabled")))
	if cfg.has_section_key("gameplay", "conduits_3d_visible"):
		set_conduits_3d_visible(bool(cfg.get_value("gameplay", "conduits_3d_visible")))
	if cfg.has_section_key("gameplay", "conduit_flow_glow_enabled"):
		set_conduit_flow_glow_enabled(bool(cfg.get_value("gameplay", "conduit_flow_glow_enabled")))
	if cfg.has_section_key("gameplay", "force_rainbow"):
		set_force_rainbow(bool(cfg.get_value("gameplay", "force_rainbow")))
	_load_rendering_adv(cfg)


func _load_rendering_adv(cfg: ConfigFile) -> void:
	if main_node == null or not cfg.has_section("rendering_adv"):
		return
	if cfg.has_section_key("rendering_adv", "ambient_energy_mult"):
		apply_ambient_energy_mult(float(cfg.get_value("rendering_adv", "ambient_energy_mult")))
	if cfg.has_section_key("rendering_adv", "ambient_sky_contribution"):
		apply_ambient_sky_contribution(float(cfg.get_value("rendering_adv", "ambient_sky_contribution")))
	if cfg.has_section_key("rendering_adv", "glow_intensity_mult"):
		apply_glow_intensity_mult(float(cfg.get_value("rendering_adv", "glow_intensity_mult")))
	if cfg.has_section_key("rendering_adv", "glow_user_enabled"):
		apply_glow_user_enabled(bool(cfg.get_value("rendering_adv", "glow_user_enabled")))
	if cfg.has_section_key("rendering_adv", "ssao_enabled"):
		apply_ssao_enabled(bool(cfg.get_value("rendering_adv", "ssao_enabled")))
	if cfg.has_section_key("rendering_adv", "ssil_enabled"):
		apply_ssil_enabled(bool(cfg.get_value("rendering_adv", "ssil_enabled")))
	if cfg.has_section_key("rendering_adv", "sdfgi_enabled"):
		apply_sdfgi_enabled(bool(cfg.get_value("rendering_adv", "sdfgi_enabled")))
	if cfg.has_section_key("rendering_adv", "volumetric_fog_enabled"):
		apply_volumetric_fog_enabled(bool(cfg.get_value("rendering_adv", "volumetric_fog_enabled")))
	if cfg.has_section_key("rendering_adv", "tonemap_mode"):
		apply_tonemap_mode(int(cfg.get_value("rendering_adv", "tonemap_mode")))
	if cfg.has_section_key("rendering_adv", "msaa_level"):
		apply_msaa_level(int(cfg.get_value("rendering_adv", "msaa_level")))
	if cfg.has_section_key("rendering_adv", "tonemap_exposure"):
		apply_tonemap_exposure(float(cfg.get_value("rendering_adv", "tonemap_exposure")))
	if cfg.has_section_key("rendering_adv", "tonemap_white"):
		apply_tonemap_white(float(cfg.get_value("rendering_adv", "tonemap_white")))
	if cfg.has_section_key("rendering_adv", "fog_amount"):
		apply_fog_amount(float(cfg.get_value("rendering_adv", "fog_amount")))
	if cfg.has_section_key("rendering_adv", "sun_size"):
		apply_sun_size(float(cfg.get_value("rendering_adv", "sun_size")))
	if cfg.has_section_key("rendering_adv", "moon_size"):
		apply_moon_size(float(cfg.get_value("rendering_adv", "moon_size")))
	if cfg.has_section_key("rendering_adv", "moon_glow"):
		apply_moon_glow(float(cfg.get_value("rendering_adv", "moon_glow")))
	if cfg.has_section_key("rendering_adv", "sun_glow"):
		apply_sun_glow(float(cfg.get_value("rendering_adv", "sun_glow")))
	if cfg.has_section_key("rendering_adv", "sun_glow_size"):
		apply_sun_glow_size(float(cfg.get_value("rendering_adv", "sun_glow_size")))
	if cfg.has_section_key("rendering_adv", "sun_aureole"):
		apply_sun_aureole(float(cfg.get_value("rendering_adv", "sun_aureole")))
	for sky_key in ["twilight_drama", "twilight_length", "sun_warmth", "airglow_strength", "light_pollution", "moon_sky_glow"] + HORIZON_FLOAT_KEYS:
		if cfg.has_section_key("rendering_adv", sky_key):
			apply_sky_setting(sky_key, float(cfg.get_value("rendering_adv", sky_key)))
	for sky_col in ["airglow_color", "light_pollution_color"] + HORIZON_COLOR_KEYS:
		if cfg.has_section_key("rendering_adv", sky_col):
			var cv: Variant = cfg.get_value("rendering_adv", sky_col)
			if cv is Color:
				apply_sky_setting(sky_col, cv)
	if cfg.has_section_key("rendering_adv", "cirrus_user_scale"):
		apply_cirrus_scale(float(cfg.get_value("rendering_adv", "cirrus_user_scale")))
	if cfg.has_section_key("rendering_adv", "cirrus_wave_frequency_scale"):
		apply_cirrus_wave_frequency_scale(float(cfg.get_value("rendering_adv", "cirrus_wave_frequency_scale")))
	if cfg.has_section_key("rendering_adv", "cirrus_wave_intensity_scale"):
		apply_cirrus_wave_intensity_scale(float(cfg.get_value("rendering_adv", "cirrus_wave_intensity_scale")))
	if cfg.has_section_key("rendering_adv", "cloud_shadows_enabled"):
		apply_cloud_shadows_enabled(bool(cfg.get_value("rendering_adv", "cloud_shadows_enabled")))
	if cfg.has_section_key("rendering_adv", "building_shadows_enabled"):
		apply_building_shadows_enabled(bool(cfg.get_value("rendering_adv", "building_shadows_enabled")))
	if cfg.has_section_key("rendering_adv", "shadow_opacity"):
		apply_shadow_opacity(float(cfg.get_value("rendering_adv", "shadow_opacity")))
	if cfg.has_section_key("rendering_adv", "god_rays_enabled"):
		apply_god_rays_enabled(bool(cfg.get_value("rendering_adv", "god_rays_enabled")))
	if cfg.has_section_key("camera", "player_fov"):
		apply_player_fov(float(cfg.get_value("camera", "player_fov")))
	if cfg.has_section_key("camera", "drone_fov"):
		apply_drone_fov(float(cfg.get_value("camera", "drone_fov")))


func _main_float(method: String, default: float) -> float:
	var main := _valid_main()
	if main != null and main.has_method(method):
		return float(main.call(method))
	return default


func _main_bool(method: String, default: bool) -> bool:
	var main := _valid_main()
	if main != null and main.has_method(method):
		return bool(main.call(method))
	return default


func _main_int(method: String, default: int) -> int:
	var main := _valid_main()
	if main != null and main.has_method(method):
		return int(main.call(method))
	return default


func _star_system() -> Node:
	var main := _valid_main()
	if main == null:
		return null
	if main.has_method("get_star_system"):
		return main.call("get_star_system")
	return main.get_node_or_null("StarSystem")


func _planet_system() -> Node:
	var main := _valid_main()
	if main == null:
		return null
	if main.has_method("get_planet_system"):
		return main.call("get_planet_system")
	return main.get_node_or_null("PlanetSystem")


func _find_solar_ui() -> Control:
	var tree := get_tree()
	if tree == null:
		return null
	for child in tree.root.get_children():
		var solar := child.get_node_or_null("UILayer/SolarUI")
		if solar != null:
			return solar
	if tree.current_scene != null:
		return tree.current_scene.get_node_or_null("UILayer/SolarUI")
	return null


const HA_CONNECTION_CFG := "user://ha_connection.cfg"
const HA_URL_DEFAULT := "ws://YOUR_HA_IP:8123/api/websocket"
const HA_TOKEN_DEFAULT := "YOUR_LONG_LIVED_TOKEN"

## Pending HA fields edited in the settings panel (flushed on persist).
var _pending_ha_url : String = ""
var _pending_ha_token : String = ""
var _pending_ha_entities : String = ""
var _ha_fields_dirty : bool = false


func get_solar_panel_settings() -> Dictionary:
	var solar := _find_solar_ui()
	if solar != null and solar.has_method("get_panel_settings"):
		return solar.call("get_panel_settings") as Dictionary
	return {}


func apply_solar_panel_setting(key: String, value: Variant) -> void:
	var solar := _find_solar_ui()
	if solar != null and solar.has_method("apply_panel_setting"):
		solar.call("apply_panel_setting", key, value)


func get_ha_connection_snapshot() -> Dictionary:
	var cfg := ConfigFile.new()
	var url := HA_URL_DEFAULT
	var token := ""
	var entities := ""
	if cfg.load(HA_CONNECTION_CFG) == OK:
		url = str(cfg.get_value("connection", "url", HA_URL_DEFAULT))
		token = str(cfg.get_value("connection", "token", ""))
		entities = str(cfg.get_value("connection", "entities", ""))
	var client := _ha_client()
	var connected := false
	var authenticated := false
	if client != null:
		connected = bool(client.get("is_connected"))
		authenticated = bool(client.get("is_authenticated"))
	return {
		"ha_url": url,
		"ha_token": token,
		"ha_entities": entities,
		"ha_connected": connected,
		"ha_authenticated": authenticated,
	}


func set_pending_ha_connection(url: String, token: String, entities: String) -> void:
	_pending_ha_url = url.strip_edges()
	_pending_ha_token = token.strip_edges()
	_pending_ha_entities = entities.strip_edges()
	_ha_fields_dirty = true


func save_ha_connection(url: String, token: String, entities: String = "") -> void:
	var cfg := ConfigFile.new()
	cfg.load(HA_CONNECTION_CFG)
	cfg.set_value("connection", "url", url.strip_edges())
	cfg.set_value("connection", "token", token.strip_edges())
	if not entities.is_empty() or cfg.has_section_key("connection", "entities"):
		cfg.set_value("connection", "entities", entities.strip_edges())
	cfg.save(HA_CONNECTION_CFG)
	_pending_ha_url = url.strip_edges()
	_pending_ha_token = token.strip_edges()
	_pending_ha_entities = entities.strip_edges()
	_ha_fields_dirty = false


func save_ha_connection_from_panel() -> void:
	if not _ha_fields_dirty:
		return
	save_ha_connection(_pending_ha_url, _pending_ha_token, _pending_ha_entities)


func connect_ha(url: String, token: String, entities: String = "") -> void:
	save_ha_connection(url, token, entities)
	var client := _ha_client()
	if client == null or not client.has_method("connect_to_ha"):
		return
	client.call("connect_to_ha", url.strip_edges(), token.strip_edges())


func disconnect_ha() -> void:
	var client := _ha_client()
	if client != null and client.has_method("disconnect_from_ha"):
		client.call("disconnect_from_ha")


func subscribe_ha_entities(entities_text: String) -> void:
	save_ha_connection(_pending_ha_url, _pending_ha_token, entities_text)
	var client := _ha_client()
	if client == null or not bool(client.get("is_authenticated")):
		return
	var raw := entities_text.strip_edges()
	if raw.is_empty():
		return
	var raw_entities: PackedStringArray
	if "\n" in raw:
		raw_entities = raw.split("\n", false)
	else:
		raw_entities = raw.split(",", false)
	var cleaned: Array[String] = []
	for entity in raw_entities:
		var trimmed := str(entity).strip_edges()
		if not trimmed.is_empty():
			cleaned.append(trimmed)
	if cleaned.is_empty():
		return
	if client.has_method("subscribe_to_entities"):
		client.call("subscribe_to_entities", cleaned)
	if client.has_method("get_entity_states"):
		client.call("get_entity_states", cleaned)


func get_ha_status_text() -> String:
	var snap := get_ha_connection_snapshot()
	if snap.get("ha_connected", false) and snap.get("ha_authenticated", false):
		return "Connected and authenticated"
	if snap.get("ha_connected", false):
		return "Connected (authenticating…)"
	return "Disconnected"


func _ha_client() -> Node:
	var main := _valid_main()
	if main != null:
		return main.get_node_or_null("HAClient")
	return null


func _moon_phase_icon(phase: float) -> String:
	if phase < 0.0625 or phase >= 0.9375:
		return "🌑"
	if phase < 0.1875:
		return "🌒"
	if phase < 0.3125:
		return "🌓"
	if phase < 0.4375:
		return "🌔"
	if phase < 0.5625:
		return "🌕"
	if phase < 0.6875:
		return "🌖"
	if phase < 0.8125:
		return "🌗"
	return "🌘"

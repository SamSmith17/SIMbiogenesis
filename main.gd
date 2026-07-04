@tool
extends Node3D

## Realistic day/night cycle simulation with astronomically accurate moon phases and full date/time tracking.
## Supports real-world dates from year 1 to 9999, with proper sun/moon/star positions.

const HOURS_IN_DAY : float = 24.0
const DAYS_IN_YEAR : int = 365
const DAYS_IN_LEAP_YEAR : int = 366
const PLACED_PROPS_UI_SCRIPT := preload("res://scenes/ui/placed_props_ui.gd")

# ==================== DATE/TIME SYSTEM ====================

## Astronomy + timekeeping engine (see core/celestial_clock.gd). Owns the
## calendar, observer location, and all celestial math; Main delegates state
## to it and applies the results to lights, sky shader, and environment.
## Declared before the exported properties below so it already exists when
## their default initializers run the delegating setters during _init.
var clock : CelestialClock = CelestialClock.new()

## Year (1-9999) - defaults to current system year
@export_range( 1, 9999, 1 ) var year : int = 2026 :
	set( value ) :
		clock.year = value
		_force_planet_update()
		_update()
	get :
		return clock.year

## Month (1-12) - defaults to current system month
@export_range( 1, 12, 1 ) var month : int = 1 :
	set( value ) :
		clock.month = value
		_force_planet_update()
		_update()
	get :
		return clock.month

## Day of month (1-31, clamped to valid days for month) - defaults to current system day
@export_range( 1, 31, 1 ) var day : int = 26 :
	set( value ) :
		clock.day = value
		_force_planet_update()
		_update()
	get :
		return clock.day

## Time of day in hours (0-24)
@export_range( 0.0, HOURS_IN_DAY, 0.0001 ) var day_time : float = 12.0 :
	set( value ) :
		clock.day_time = value
		_force_planet_update()
		_update()
	get :
		return clock.day_time

## Day of year (1-365/366, calculated from month/day)
var day_of_year : int :
	get:
		return clock.day_of_year

## Absolute hours since year 1 Jan 1 00:00 — the canonical reversible timecode.
## Setting it scrubs the whole calendar + time-of-day and refreshes the sky.
func get_absolute_hours() -> float :
	return clock.get_absolute_hours()

func set_absolute_hours( h: float ) -> void :
	clock.set_absolute_hours( h )
	if not Engine.is_editor_hint() :
		_force_planet_update()
		_update()

# ==================== LOCATION ====================

## Latitude in degrees (-90 to 90). Default: Bombay Beach, CA.
## Full GPS precision (1e-7° ≈ 1 cm); prefer apply_location() so all location
## consumers (weather, persistence, other UIs) stay in sync.
@export_range( -90.0, 90.0, 0.0000001 ) var latitude : float = 33.3561 :
	set( value ) :
		clock.latitude = value
		_update()
	get :
		return clock.latitude

## Longitude in degrees (-180 to 180). Default: Bombay Beach, CA.
@export_range( -180.0, 180.0, 0.0000001 ) var longitude : float = -115.7366 :
	set( value ) :
		clock.longitude = value
		_update()
	get :
		return clock.longitude

## Emitted whenever the observer location changes (any source). UIs listen to
## stay in sync; WeatherService re-fetches on its own location poll.
signal location_changed( lat : float, lon : float )

## Automatically switch DST on/off based on US rules (2nd Sunday March - 1st Sunday November)
@export var auto_dst : bool = true :
	set( value ) :
		clock.auto_dst = value
		_update()
	get :
		return clock.auto_dst

## Manual DST override (only used when auto_dst is false)
@export var manual_dst : bool = false :
	set( value ) :
		clock.manual_dst = value
		_update()
	get :
		return clock.manual_dst

## Returns true if DST is currently active (either auto-calculated or manual)
func is_dst_active() -> bool :
	return clock.is_dst_active()

# ==================== ASTRONOMICAL PARAMETERS ====================

## Earth's axial tilt (causes seasons)
@export_range( -180.0, 180.0, 0.01 ) var planet_axial_tilt : float = 23.44 :
	set( value ) :
		clock.planet_axial_tilt = value
		_update()
	get :
		return clock.planet_axial_tilt

## Moon's orbital inclination to the ecliptic
@export_range( -180.0, 180.0, 0.01 ) var moon_orbital_inclination : float = 5.14 :
	set( value ) :
		moon_orbital_inclination = value
		_update_moon()

## Synodic month - time for moon to complete phase cycle
@export_range( 0.1, DAYS_IN_YEAR, 0.01 ) var moon_orbital_period : float = 29.530588 :
	set( value ) :
		clock.moon_orbital_period = value
		_update_moon()
	get :
		return clock.moon_orbital_period

## Day of the lunar cycle to start on (0 = new moon, ~14.76 = full moon)
@export_range( 0.0, 29.53, 0.01 ) var moon_phase_offset : float = 0.0 :
	set( value ) :
		clock.moon_phase_offset = value
		_update_moon()
	get :
		return clock.moon_phase_offset

# ==================== VISUAL SETTINGS ====================

@export_range( 0.0, 1.0, 0.01 ) var clouds_cutoff : float = 0.5 :
	set( value ) :
		# Reject non-finite: this is pushed to the sky shader, where NaN/Inf can hang the GPU.
		clouds_cutoff = clampf( value, 0.0, 1.0 ) if is_finite( value ) else 0.5
		_update_clouds()

@export_range( 0.0, 1.0, 0.01 ) var clouds_weight : float = 0.0 :
	set( value ) :
		clouds_weight = clampf( value, 0.0, 1.0 ) if is_finite( value ) else 0.0
		_update_clouds()

## High wispy cirrus streak clouds (independent of the cumulus layer above).
## 0 = none, ~0.35 = fair-weather wisps, 1 = heavily streaked sky. The live value is
## written by SolarUI from the weather (scaled by cirrus_user_scale below).
@export_range( 0.0, 1.0, 0.01 ) var cirrus_amount : float = 0.3 :
	set( value ) :
		cirrus_amount = clampf( value, 0.0, 1.0 ) if is_finite( value ) else 0.0
		_update_clouds()

## User multiplier over the weather-driven cirrus amount (gear slider). 1.0 = as the
## weather dictates, 0 = suppress cirrus, 2 = double. SolarUI reads this each tick.
var cirrus_user_scale : float = 1.0 :
	set( value ) :
		cirrus_user_scale = clampf( value, 0.0, 2.0 ) if is_finite( value ) else 1.0

## Weather light factor - set by SolarUI to attenuate sun/moon based on cloud cover
## 1.0 = clear sky full brightness, 0.15 = heavy overcast
## Setter rejects non-finite values: a NaN/Inf here would propagate into
## DirectionalLight3D.light_energy and hang the GPU driver (TDR), corrupting the
## whole desktop compositor. This is the first line of GPU-safety defense.
var weather_light_factor : float = 1.0 :
	set(value):
		weather_light_factor = clampf(value, 0.0, 4.0) if is_finite(value) else 1.0

## Atmospheric perspective/fog (0 = clear, 0.2 = light haze, 0.5 = moderate, 1 = heavy)
@export_range( 0.0, 1.0, 0.01 ) var fog_amount : float = 0.2 :
	set( value ) :
		fog_amount = value
		_update_environment()

## Dusk anti-washout control: reduces haze density while sun is still above the horizon.
## Higher values keep distant mountains darker from ~17:00 to sunset.
@export_range( 0.0, 0.00025, 0.00001 ) var pre_sunset_reduction_strength : float = 0.00010 :
	set( value ) :
		pre_sunset_reduction_strength = value
		_update_environment()

## Dusk color bias: 0 = warmer dusk haze, 1 = cooler blue-grey dusk haze.
## Increase this to push mountains toward realistic blue-dark silhouettes.
@export_range( 0.0, 1.0, 0.01 ) var twilight_cool_bias : float = 0.65 :
	set( value ) :
		twilight_cool_bias = value
		_update_environment()

@export var use_day_time_for_shader : bool = false :
	set( value ) :
		use_day_time_for_shader = value
		_update_shader()

## Time multiplier. 0 = paused, 1.0 = 1 hour per second, 0.01 = 1x real-time
@export_range( 0.0, 10.0, 0.0001 ) var time_scale : float = 0.01 :
	set( value ) :
		clock.time_scale = value
	get :
		return clock.time_scale

# ==================== GAMEPLAY MECHANICS ====================

## When true, survival mechanics (health drain, hydration loss, fire, fall damage) are disabled.
## Managed by TimeUI based on time speed and user toggle.
var gameplay_mechanics_paused : bool = true   # Off by default; TimeUI toggle can enable

# ==================== FIRE SETTINGS ====================

## Enable random fires (fires can still be triggered manually with F key when disabled)
@export var enable_random_fires : bool = false

## Spawn fire extinguisher pickups around the scene (disable to hide pickups)
@export var spawn_extinguisher_pickups : bool = false

## Optional per-map rules and crisis/pickup data. If null, rules autoload is filled from exports above.
@export var scenario_config : ScenarioConfig

## Fire spread range in meters (how far fire can jump to nearby objects)
@export_range( 1.0, 20.0, 0.5 ) var fire_spread_range : float = 3.0

## Fire engulf range in meters (how far fire can engulf nearby objects when intense)
@export_range( 1.0, 15.0, 0.5 ) var fire_engulf_range : float = 2.0

## Sun light intensity (0 = use node default)
@export_range( 0.0, 10.0, 0.01 ) var sun_base_enegry : float = 0.0 :
	set( value ) :
		sun_base_enegry = value
		_update_sun()

## Sun apparent size in the sky
@export_range( 0.02, 0.5, 0.01 ) var sun_size : float = 0.15 :
	set( value ) :
		sun_size = value
		_update_celestial_sizes()

## Sun corona glow strength (soft radial halo around the disc; 0 = hard disc only)
@export_range( 0.0, 4.0, 0.05 ) var sun_glow : float = 1.4 :
	set( value ) :
		sun_glow = value
		_update_celestial_sizes()

## Sun corona glow radius (multiple of the sun disc size)
@export_range( 1.0, 30.0, 0.5 ) var sun_glow_size : float = 9.0 :
	set( value ) :
		sun_glow_size = value
		_update_celestial_sizes()

## Broad atmospheric aureole washing the sky around the sun (Mie forward-scatter; sunset drama)
@export_range( 0.0, 3.0, 0.05 ) var sun_aureole : float = 0.8 :
	set( value ) :
		sun_aureole = value
		_update_celestial_sizes()

## Moon light intensity (0 = use node default)
@export_range( 0.0, 10.0, 0.01 ) var moon_base_enegry : float = 0.0 :
	set( value ) :
		moon_base_enegry = value
		_update_moon()

## Enable moon shadows (pale moonlight shadows on clear nights)
@export var moon_shadows_enabled : bool = true

## Moon shadow max distance (how far moon shadows render)
@export_range( 10.0, 500.0, 10.0 ) var moon_shadow_distance : float = 150.0

## Minimum moon brightness (0-1) required to cast shadows
## Full moon = 1.0, so 0.7 means shadows only near full moon
@export_range( 0.0, 1.0, 0.05 ) var moon_shadow_threshold : float = 0.5

## Shadow quality profile:
## 0 = Low (performance), 1 = Medium, 2 = High, 3 = Ultra (sharpest/longest shadows)
@export_range( 0, 3, 1 ) var shadow_quality : int = 2 :
	set( value ) :
		shadow_quality = clampi( value, 0, 3 )
		_apply_shadow_quality()

## Global graphics quality preset (distinct from per-light shadow_quality above).
## Bundles the heaviest GPU knobs the project formerly hardcoded in project.godot:
## directional shadow atlas size, soft-shadow filter quality, and TAA.
## 0 = Low, 1 = Medium, 2 = High. Default (High) reproduces the project baseline.
@export_range( 0, 2, 1 ) var graphics_quality : int = 2 :
	set( value ) :
		graphics_quality = clampi( value, 0, 2 )
		_apply_graphics_quality()

## Moon apparent size in the sky
@export_range( 0.01, 0.2, 0.005 ) var moon_size : float = 0.05 :
	set( value ) :
		moon_size = value
		_update_celestial_sizes()

## Moon glow intensity (0 = no glow, 1 = moderate, 2 = strong)
@export_range( 0.0, 2.0, 0.05 ) var moon_glow : float = 0.5 :
	set( value ) :
		moon_glow = value
		_update_celestial_sizes()

# ==================== CAMERA (user-tunable) ====================

## First-person player camera field of view, in degrees. 0 = leave the scene's
## own camera FOV untouched (per-map default). Non-zero overrides it.
var player_fov : float = 0.0 :
	set( value ) :
		if is_finite( value ) and value > 0.0 :
			player_fov = clampf( value, 30.0, 120.0 )
		else :
			player_fov = 0.0
		_apply_camera_fov()

## FPV drone camera field of view, in degrees (the drone reuses the player camera,
## so this is applied while mounted and reverted to player_fov on dismount).
## 0 = leave the scene default untouched.
var drone_fov : float = 0.0 :
	set( value ) :
		if is_finite( value ) and value > 0.0 :
			drone_fov = clampf( value, 30.0, 120.0 )
		else :
			drone_fov = 0.0
		_apply_camera_fov()

# ==================== ADVANCED RENDERING (user-tunable) ====================

## Multiplier over the automatic day/night ambient energy ramp.
var ambient_energy_mult : float = 1.0 :
	set( value ) :
		ambient_energy_mult = clampf( value, 0.0, 4.0 ) if is_finite( value ) else 1.0
		_update_environment()

## Sky contribution to ambient light (absolute, not ramped).
var ambient_sky_contribution : float = 0.15 :
	set( value ) :
		ambient_sky_contribution = clampf( value, 0.0, 1.0 ) if is_finite( value ) else 0.15
		_update_environment()

## Multiplier over the automatic day/night glow intensity ramp.
var glow_intensity_mult : float = 1.0 :
	set( value ) :
		glow_intensity_mult = clampf( value, 0.0, 4.0 ) if is_finite( value ) else 1.0
		_update_glow( _vegetation_night_factor )

## Master glow on/off (absolute toggle).
var glow_user_enabled : bool = true :
	set( value ) :
		glow_user_enabled = value
		_update_glow( _vegetation_night_factor )

var ssao_user_enabled : bool = true :
	set( value ) :
		ssao_user_enabled = value
		_apply_advanced_rendering_toggles()

# Default OFF: under Forward+ SSIL is real (it was a silent no-op on the old
# GL Compatibility renderer) and costs noticeably more than SSAO for a subtle
# effect on this outdoor scene. Users can enable it in gear settings (persisted).
var ssil_user_enabled : bool = false :
	set( value ) :
		ssil_user_enabled = value
		_apply_advanced_rendering_toggles()

var sdfgi_user_enabled : bool = false :
	set( value ) :
		sdfgi_user_enabled = value
		_apply_advanced_rendering_toggles()

var volumetric_fog_user_enabled : bool = false :
	set( value ) :
		volumetric_fog_user_enabled = value
		_apply_advanced_rendering_toggles()

## Crepuscular "god rays" (light shafts). Implemented via Godot's volumetric fog +
## a boosted directional-light volumetric energy, so the sun casts visible shafts,
## most dramatically at sunrise/sunset. Tuned thin so it adds shafts, not a grey haze.
var god_rays_enabled : bool = false :
	set( value ) :
		god_rays_enabled = value
		# _apply_advanced_rendering_toggles fully handles the volumetric-fog + sun
		# shaft setup; no need for the heavier full _update_environment() here.
		_apply_advanced_rendering_toggles()

## Drifting cloud shadows: the direct sun dims and brightens as clouds pass, synced
## to the sky's cloud density/drift. A cheap global light attenuation (no per-pixel
## ground projection), so it costs nothing beyond one noise sample per env update.
var cloud_shadows_enabled : bool = true :
	set( value ) :
		cloud_shadows_enabled = value
		_update_sun()

## How deeply a passing cloud can dim the direct sun (0 = off, 1 = strong).
var cloud_shadow_strength : float = 0.6 :
	set( value ) :
		cloud_shadow_strength = clampf( value, 0.0, 1.0 ) if is_finite( value ) else 0.6
		_update_sun()

## Lazily-created noise for the cloud-shadow drift (see _compute_cloud_shadow_factor).
var _cloud_shadow_noise : FastNoiseLite = null
## Cached cloud drift speed/direction (static sky-shader uniforms), read once.
var _cloud_shadow_speed : float = 2.0
var _cloud_shadow_dir : float = 0.2

# ACES over Linear (Forward+ default): an A/B screenshot comparison (vista/
# golden-hour/night, both maps) showed Linear leaves distant terrain visibly
# pale/washed-out under the real HDR pipeline — ACES fixed that with no
# regression elsewhere. AgX was also compared and was nearly indistinguishable
# from Linear in this scene, so it wasn't chosen. Gear-panel override persists.
var tonemap_mode : int = Environment.TONE_MAPPER_ACES :
	set( value ) :
		tonemap_mode = clampi( value, 0, 4 )
		_apply_tonemap_settings()

var tonemap_exposure : float = 1.0 :
	set( value ) :
		tonemap_exposure = clampf( value, 0.1, 4.0 ) if is_finite( value ) else 1.0
		_apply_tonemap_settings()

var tonemap_white : float = 1.0 :
	set( value ) :
		tonemap_white = clampf( value, 0.1, 16.0 ) if is_finite( value ) else 1.0
		_apply_tonemap_settings()

## Forward+ MSAA level, independent of the TAA implied by graphics_quality —
## some players prefer MSAA's sharper edges over TAA's smoothing/ghosting
## trade-off on wind-animated vegetation. 0=Off, 1=2x, 2=4x, 3=8x.
var msaa_level : int = 0 :
	set( value ) :
		msaa_level = clampi( value, 0, 3 )
		_apply_msaa_level()

# ==================== CALCULATED SUNRISE/SUNSET ====================

## Calculated sunrise hour for current date/location (read-only, in clock time)
var sunrise_hour : float :
	get :
		return clock.sunrise_hour

## Calculated sunset hour for current date/location (read-only, in clock time)
var sunset_hour : float :
	get :
		return clock.sunset_hour

## Convert solar time to clock time (reverse of get_solar_time)
func solar_time_to_clock_time( solar_time: float ) -> float :
	return clock.solar_time_to_clock_time( solar_time )

# ==================== NODE REFERENCES ====================

@onready var environment : WorldEnvironment = get_node_or_null( "WorldEnvironment" ) as WorldEnvironment
@onready var sun : DirectionalLight3D = get_node_or_null( "Sun" ) as DirectionalLight3D
@onready var moon : DirectionalLight3D = get_node_or_null( "Moon" ) as DirectionalLight3D
@onready var planet_system : Node3D = get_node_or_null( "PlanetSystem" ) as Node3D
@onready var star_system : StarSystem = get_node_or_null( "StarSystem" ) as StarSystem
@onready var structure : Node3D = get_node_or_null( "LinkageLab_Export2" ) as Node3D
@onready var player : CharacterBody3D = get_node_or_null( "Player" ) as CharacterBody3D
@onready var game_over_ui : CanvasLayer = get_node_or_null( "UILayer/GameOverUI" ) as CanvasLayer
@onready var interaction_ui : CanvasLayer = get_node_or_null( "UILayer/InteractionPromptUI" ) as CanvasLayer
@onready var euc_ui : CanvasLayer = get_node_or_null( "UILayer/EUCUI" ) as CanvasLayer
@onready var crisis_event_manager : Node = get_node_or_null( "CrisisEventManager" )
@onready var crisis_event_ui : CanvasLayer = get_node_or_null( "UILayer/CrisisEventUI" ) as CanvasLayer
@onready var save_load_ui : CanvasLayer = get_node_or_null( "UILayer/SaveLoadUI" ) as CanvasLayer
var toast_ui : ToastUI = null
var help_overlay_ui : HelpOverlayUI = null
@onready var location_picker : Control = get_node_or_null( "UILayer/LocationPickerUI" ) as Control
@onready var projection_canvas : Control = get_node_or_null( "UILayer/ProjectionCanvas" ) as Control
@onready var pov_warp_overlay : Control = get_node_or_null( "UILayer/POVWarpOverlay" ) as Control

## First-run / confirmed location: written when user sets location in LocationPickerUI
const _LOCATION_USER_CFG : String = "user://location_prefs.cfg"
var _location_picker_open : bool = false

var _moon_shadow_quality_distance_scale : float = 1.0
var _session_playtime_seconds : float = 0.0

# Player spawn position
var player_spawn_position : Vector3 = Vector3(0, 2, 0)
var _placed_props_ui : Control = null
var player_spawn_rotation : Vector3 = Vector3.ZERO


## Autoload singleton "SaveSystem" is not available as global identifier in @tool scripts; use /root lookup.
func _save_game_service() -> SaveGameService:
	var ml := Engine.get_main_loop()
	if ml == null or not ( ml is SceneTree ) :
		return null
	var n : Node = ( ml as SceneTree ).root.get_node_or_null( "SaveSystem" )
	if n == null :
		return null
	return n as SaveGameService


# ==================== INITIALIZATION ====================

## Initialize date and time from the system clock
func _init_from_system_time() -> void :
	clock.init_from_system_time()
	_update()

func _ready() -> void :
	# Add to group so planet system can find us
	add_to_group( "main_scene" )
	# Tool-mode guard: avoid runtime-only wiring while editing the scene in the editor.
	if Engine.is_editor_hint() :
		_update()
		return
	
	# Initialize date/time from system clock (only at runtime, not in editor)
	_init_from_system_time()

	# Restore the user's chosen location so it persists across playtests
	# (independent of save games). Default scene coords stand until first set.
	_load_location_prefs()

	_setup_toast_ui()
	_setup_help_overlay_ui()
	_maybe_show_first_run_help()

	_apply_scenario_rules()

	if is_instance_valid( sun ) :
		sun.position = Vector3( 0.0, 0.0, 0.0 )
		sun.rotation = Vector3( 0.0, 0.0, 0.0 )
		sun.rotation_order = EULER_ORDER_ZXY
		if sun_base_enegry == 0.0 :
			sun_base_enegry = sun.light_energy
	if is_instance_valid( moon ) :
		moon.position = Vector3( 0.0, 0.0, 0.0 )
		moon.rotation = Vector3( 0.0, 0.0, 0.0 )
		moon.rotation_order = EULER_ORDER_ZXY
		if moon_base_enegry == 0.0 :
			moon_base_enegry = moon.light_energy
	# Defer shadow setup to ensure all nodes are fully loaded
	call_deferred( "_setup_shadows" )
	# Disable expensive shadow maps on decorative string-light OmniLights
	call_deferred( "_disable_string_light_omni_shadows" )
	# Store initial player spawn position
	if is_instance_valid( player ) :
		player_spawn_position = player.global_position
		player_spawn_rotation = player.rotation
		# Connect player fall death signal
		if player.has_signal( "player_died" ) :
			if not player.is_connected( "player_died", Callable( self, "_on_player_died_with_message" ) ) :
				player.connect( "player_died", Callable( self, "_on_player_died_with_message" ) )
		# Re-apply the configured FOV whenever the player enters/leaves FPV drone
		# mode (both modes share the player's Camera3D).
		var fov_cb := Callable( self, "_on_vehicle_camera_change" )
		if player.has_signal( "mounted_vehicle" ) and not player.is_connected( "mounted_vehicle", fov_cb ) :
			player.connect( "mounted_vehicle", fov_cb )
		if player.has_signal( "dismounted_vehicle" ) and not player.is_connected( "dismounted_vehicle", fov_cb ) :
			player.connect( "dismounted_vehicle", fov_cb )
		_apply_camera_fov()
	# Connect game over UI respawn signal
	if is_instance_valid( game_over_ui ) and game_over_ui.has_signal( "respawn_requested" ) :
		var respawn_cb := Callable( self, "_respawn_player" )
		if not game_over_ui.is_connected( "respawn_requested", respawn_cb ) :
			game_over_ui.connect( "respawn_requested", respawn_cb )
	# Connect all death zones
	_connect_death_zones()
	# Setup interaction UI for player
	_setup_interaction_ui()
	# Setup crisis event UI
	_setup_crisis_event_ui()
	# Connect all EUC/vehicles
	_connect_vehicles()
	# Auto-generate collision for structures (deferred to ensure meshes are loaded)
	call_deferred( "_setup_auto_collision" )
	# Setup crisis event system (deferred to ensure structure is loaded)
	call_deferred( "_setup_crisis_events" )
	# Spawn fire extinguisher pickups at strategic locations
	call_deferred( "_spawn_fire_extinguisher_pickups" )
	_apply_advanced_rendering_toggles()
	_apply_tonemap_settings()
	_apply_msaa_level()
	_update()
	_setup_save_load_ui()
	_setup_location_picker()
	_setup_baked_placed_props_ui()
	_try_apply_pending_resume()


func _try_apply_pending_resume() -> void :
	var sg : SaveGameService = _save_game_service()
	if sg == null :
		return
	var data : Dictionary = sg.take_pending_resume_payload()
	if data.is_empty() :
		return
	if not _apply_save_snapshot( data ) :
		push_warning( "Save/Load: pending resume could not be applied." )
		show_toast( "Could not resume your save — data was invalid or incompatible.", ToastUI.Level.ERROR )


func _consume_save_payload( data: Dictionary ) -> bool :
	if data.is_empty() :
		return false
	var sg : SaveGameService = _save_game_service()
	if sg == null or not sg.validate_payload( data ) :
		return false
	var want : String = MapDefinition.normalize_scene_path( str( data.get( "scene_path", "" ) ).strip_edges() )
	if not MapDefinition.is_trusted_scene_path( want ) :
		want = MapDefinition.snapshot_scene_path( self )
	var want_file : String = MapDefinition.resolve_playable_scene_path( want )
	var cur : String = MapDefinition.normalize_scene_path( String( scene_file_path ).strip_edges() )
	# Every user location map shares one scene shell (generated_location.tscn), so
	# matching scene paths is NOT sufficient — a save from Washington and one from
	# Texas both report that same scene. For generated maps also compare the saved
	# coordinates; when the site differs we must rebuild the terrain, not just
	# stamp the saved time/position onto whatever world is currently loaded.
	var same_target : bool = ( want == cur )
	if same_target and want == MapDefinition.GENERATED_SCENE :
		same_target = _save_matches_current_site( data )
	if same_target :
		return _apply_save_snapshot( data )
	var payload : Dictionary = data.duplicate( true )
	payload["scene_path"] = want
	sg.set_pending_resume_payload( payload )
	# Generated maps can't receive args across change_scene_to_file, so hand the
	# saved site to the loader via MapContext and flag it as a resume (rebuild the
	# right terrain, but keep the restored player position instead of re-centring).
	if want == MapDefinition.GENERATED_SCENE :
		_set_map_context_from_save( data )
	var err : Error = get_tree().change_scene_to_file( want_file )
	if err != OK :
		sg.clear_pending_resume_payload()
		push_warning( "Save/Load: could not change scene to %s (err %d)" % [ want, err ] )
		show_toast( "Could not load that map — the scene failed to change.", ToastUI.Level.ERROR )
		return false
	return true


## True when the save's coordinates match the live world (same generated site).
## ~1e-4° ≈ 11 m tolerance absorbs float round-trips while still distinguishing
## genuinely different cities.
func _save_matches_current_site( data: Dictionary ) -> bool :
	var md : Variant = data.get( "main", {} )
	if not ( md is Dictionary ) :
		return true
	var d : Dictionary = md
	var slat : float = float( d.get( "latitude", latitude ) )
	var slon : float = float( d.get( "longitude", longitude ) )
	return absf( slat - latitude ) < 1e-4 and absf( slon - longitude ) < 1e-4


## Seed MapContext from a save payload so the generated-map loader rebuilds the
## saved site (from_resume keeps the restored player position).
func _set_map_context_from_save( data: Dictionary ) -> void :
	var ctx := get_node_or_null( "/root/MapContext" )
	if ctx == null or not ctx.has_method( "set_pending" ) :
		return
	var md : Variant = data.get( "main", {} )
	var d : Dictionary = md if md is Dictionary else {}
	var slat : float = float( d.get( "latitude", latitude ) )
	var slon : float = float( d.get( "longitude", longitude ) )
	var half : float = float( data.get( "half_extent_m", 0.0 ) )
	var label : String = str( data.get( "map_display_name", "" ) )
	ctx.set_pending( slat, slon, label, half, true )


func _apply_scenario_rules() -> void :
	var gr := GameplayRulesImpl.from_node( self )
	if gr == null :
		return
	if scenario_config != null :
		gr.apply_scenario( scenario_config )
	else :
		gr.apply_fallback_from_main( self )
	gr.sync_survival_paused_from_main( self )
	gr.sync_main_from_rules( self )


func _setup_location_picker() -> void :
	if not Engine.is_editor_hint() and is_instance_valid( location_picker ) :
		if location_picker.has_signal( "location_confirmed" ) :
			if not location_picker.location_confirmed.is_connected( _on_location_picker_confirmed ) :
				location_picker.location_confirmed.connect( _on_location_picker_confirmed )
		if location_picker.has_signal( "picker_dismissed" ) :
			if not location_picker.picker_dismissed.is_connected( _on_location_picker_dismissed ) :
				location_picker.picker_dismissed.connect( _on_location_picker_dismissed )


func _location_user_has_been_set() -> bool :
	var cfg : ConfigFile = ConfigFile.new()
	if cfg.load( _LOCATION_USER_CFG ) != OK :
		return false
	return bool( cfg.get_value( "location", "has_been_set", false ) ) == true

func _location_has_any_save() -> bool :
	var sg2 : SaveGameService = _save_game_service()
	if sg2 == null :
		return false
	return sg2.has_autosave() or sg2.has_any_manual_save()

## Single entry point for changing the observer location. Every UI (TimeUI
## SpinBoxes, LocationPickerUI map/coords) routes through here so the new
## coordinates drive the clock (sun/moon/stars are pure functions of it),
## persist across playtests, and notify listeners. WeatherService re-fetches on
## its own location poll once latitude/longitude change.
func apply_location( lat : float, lon : float, label : String = "", persist : bool = true ) -> void :
	latitude = lat
	longitude = lon
	if persist :
		_save_location_prefs( lat, lon, label )
	location_changed.emit( lat, lon )
	var ws := get_node_or_null( "/root/WeatherService" )
	if ws != null and ws.has_method( "notify_location_changed" ):
		ws.call( "notify_location_changed", lat, lon )
	# Refresh the nearest-NWS-station lookup immediately instead of waiting for its
	# ~10 s location poll, so the weather tooltip never shows a previous map's
	# station (e.g. Hanscom AFB from a prior Lincoln, MA map).
	var nz := get_node_or_null( "/root/NwsZoneService" )
	if nz != null and nz.has_method( "request_zone" ):
		nz.call( "request_zone", lat, lon )

func _save_location_prefs( lat : float, lon : float, label : String ) -> void :
	var cfg2 : ConfigFile = ConfigFile.new()
	cfg2.load( _LOCATION_USER_CFG )   # preserve any other keys
	var section := _location_prefs_section()
	cfg2.set_value( section, "has_been_set", true )
	cfg2.set_value( section, "latitude", lat )
	cfg2.set_value( section, "longitude", lon )
	cfg2.set_value( section, "label", label )
	var err2 : int = cfg2.save( _LOCATION_USER_CFG )
	if err2 != OK :
		push_warning( "Location prefs: could not write %s (err %d)" % [ _LOCATION_USER_CFG, err2 ] )

## Config section that scopes the remembered location to the ACTIVE map (by scene
## path). Each map keeps its own last-used location so a site chosen in one map
## never leaks into another — e.g. a generated Lincoln, MA map bleeding its
## coordinates (and NWS station) into the Bombay Beach Mars sandbox.
func _location_prefs_section() -> String :
	var path := String( scene_file_path ).strip_edges()
	if path.is_empty() :
		return "location"
	var key := path.replace( "res://", "" ).replace( "/", "_" ).replace( ".", "_" )
	return "location_" + key

## Apply the persisted location at startup so a chosen site survives across
## playtests independent of save games. No-op when nothing has been set yet for
## THIS map (keeps the scene's baked default until the user picks a location).
func _load_location_prefs() -> void :
	# Generated location maps get their coordinates from MapContext / the save
	# payload (authoritative), so they must NOT read the shared prefs — that would
	# briefly seat them at a previous generated map's location and fire a wasteful
	# weather/NWS fetch for the wrong site before the loader corrects it.
	if MapDefinition.normalize_scene_path( String( scene_file_path ) ) == MapDefinition.GENERATED_SCENE :
		return
	var cfg : ConfigFile = ConfigFile.new()
	if cfg.load( _LOCATION_USER_CFG ) != OK :
		return
	var section := _location_prefs_section()
	if not bool( cfg.get_value( section, "has_been_set", false ) ) :
		return
	var lat : Variant = cfg.get_value( section, "latitude", null )
	var lon : Variant = cfg.get_value( section, "longitude", null )
	if lat == null or lon == null :
		return
	# persist=false: we're loading the saved value, not re-writing it.
	apply_location( float( lat ), float( lon ), str( cfg.get_value( section, "label", "" ) ), false )

func _on_location_picker_confirmed( lat2 : float, lnn2 : float, plabel2 : String ) -> void :
	apply_location( lat2, lnn2, plabel2 )
	_location_picker_open = false
	_restore_player_mouse_after_ui()
	if _save_game_service() != null :
		request_autosave()

func _on_location_picker_dismissed() -> void :
	_location_picker_open = false
	_restore_player_mouse_after_ui()

func _release_player_mouse_for_ui() -> void :
	var player := get_node_or_null( "Player" )
	if player != null and player.has_method( "_release_mouse" ) :
		player.call( "_release_mouse" )

func _restore_player_mouse_after_ui() -> void :
	if _location_picker_open :
		return
	var player := get_node_or_null( "Player" )
	if player != null and player.has_method( "_capture_mouse" ) :
		player.call( "_capture_mouse" )

func _toggle_location_picker() -> void :
	if not is_instance_valid( location_picker ) or not location_picker.has_method( "show_picker" ) or not location_picker.has_method( "hide_picker" ) :
		return
	if location_picker.visible :
		location_picker.call( "hide_picker" )
		_location_picker_open = false
		_restore_player_mouse_after_ui()
	else :
		_release_player_mouse_for_ui()
		location_picker.call( "show_picker" )
		_location_picker_open = true

func _input( e : InputEvent ) -> void :
	if Engine.is_editor_hint() :
		return
	if e is not InputEventKey :
		return
	var key_event : InputEventKey = e as InputEventKey
	if not key_event.pressed or key_event.echo :
		return
	if key_event.keycode == KEY_P or key_event.physical_keycode == KEY_P :
		if is_instance_valid( pov_warp_overlay ) and pov_warp_overlay.has_method( "toggle_warp_mode" ) :
			pov_warp_overlay.call( "toggle_warp_mode" )
			get_viewport().set_input_as_handled()
			return

func _unhandled_input( e : InputEvent ) -> void :
	if Engine.is_editor_hint() :
		return
	if InputMap.has_action( "toggle_solar_ui" ) and e.is_action_pressed( "toggle_solar_ui" ) :
		var solar_node := get_node_or_null( "UILayer/SolarUI" )
		if solar_node != null :
			solar_node.visible = not solar_node.visible
		get_viewport().set_input_as_handled()
		return
	if e is not InputEventKey or not ( e as InputEventKey ).pressed or ( e as InputEventKey ).echo :
		return
	if InputMap.has_action( "placed_props_edit" ) and Input.is_action_just_pressed( "placed_props_edit" ) :
		_ensure_placed_props_ui()
		if _placed_props_ui != null and _placed_props_ui.has_method( "toggle_mode" ) :
			_placed_props_ui.call( "toggle_mode" )
		get_viewport().set_input_as_handled()
		return
	var key_event : InputEventKey = e as InputEventKey
	if key_event.keycode == KEY_P or key_event.physical_keycode == KEY_P :
		if is_instance_valid( pov_warp_overlay ) and pov_warp_overlay.has_method( "toggle_warp_mode" ) :
			pov_warp_overlay.call( "toggle_warp_mode" )
			get_viewport().set_input_as_handled()
			return
	if InputMap.has_action( "toggle_projection_canvas" ) and Input.is_action_just_pressed( "toggle_projection_canvas" ) :
		if is_instance_valid( projection_canvas ) :
			projection_canvas.visible = not projection_canvas.visible
			get_viewport().set_input_as_handled()
			return
	if InputMap.has_action( "toggle_location_picker" ) and Input.is_action_just_pressed( "toggle_location_picker" ) :
		_toggle_location_picker()
		get_viewport().set_input_as_handled()

func _setup_save_load_ui() -> void :
	if not is_instance_valid( save_load_ui ) :
		return
	if save_load_ui.has_signal( "continue_requested" ) :
		save_load_ui.continue_requested.connect( _on_save_load_continue )
	if save_load_ui.has_signal( "load_slot_requested" ) :
		save_load_ui.load_slot_requested.connect( _on_save_load_slot )
	if save_load_ui.has_signal( "save_slot_requested" ) :
		save_load_ui.save_slot_requested.connect( _on_save_slot )
	if save_load_ui.has_signal( "delete_slot_requested" ) :
		save_load_ui.delete_slot_requested.connect( _on_delete_slot )

func _on_save_load_continue() -> void :
	var sg : SaveGameService = _save_game_service()
	if sg == null :
		return
	var data : Dictionary = sg.load_continue_payload()
	if not _consume_save_payload( data ) :
		if is_instance_valid( save_load_ui ) and save_load_ui.has_method( "show_load_message" ) :
			save_load_ui.show_load_message( "No valid save to continue.", false )
		return

func _on_save_load_slot( slot_index: int ) -> void :
	var sg : SaveGameService = _save_game_service()
	if sg == null :
		return
	var data : Dictionary = sg.load_manual_slot( slot_index )
	if not _consume_save_payload( data ) :
		if is_instance_valid( save_load_ui ) and save_load_ui.has_method( "show_load_message" ) :
			save_load_ui.show_load_message( "Could not load that slot.", false )
		return

func _on_save_slot( slot_index: int ) -> void :
	var sg : SaveGameService = _save_game_service()
	if sg == null :
		return
	var snap : Dictionary = build_save_snapshot()
	if not sg.save_manual_slot( slot_index, snap ) :
		push_warning( "Save/Load: could not write slot %d." % slot_index )
		show_toast( "Save failed — could not write slot %d." % ( slot_index + 1 ), ToastUI.Level.ERROR )

func _on_delete_slot( slot_index: int ) -> void :
	var sg : SaveGameService = _save_game_service()
	if sg == null :
		return
	sg.delete_manual_slot( slot_index )

## Called periodically by SaveSystem autoload.
func request_autosave() -> void :
	if Engine.is_editor_hint() :
		return
	var sg : SaveGameService = _save_game_service()
	if sg == null :
		return
	if not sg.save_autosave( build_save_snapshot() ) :
		push_warning( "Save/Load: autosave failed to write." )
		show_toast( "Autosave failed — check disk space.", ToastUI.Level.WARN )


func build_save_snapshot() -> Dictionary :
	var main_state : Dictionary = {
		"year": year,
		"month": month,
		"day": day,
		"day_time": day_time,
		"time_scale": time_scale,
		"gameplay_mechanics_paused": gameplay_mechanics_paused,
		"latitude": latitude,
		"longitude": longitude,
		"auto_dst": auto_dst,
		"manual_dst": manual_dst,
	}
	var player_state : Dictionary = {}
	var health_state : Dictionary = {}
	if is_instance_valid( player ) :
		player_state = {
			"position": SaveSerialization.vec3_to_dict( player.global_position ),
			"rotation": SaveSerialization.vec3_to_dict( player.rotation ),
			"velocity": SaveSerialization.vec3_to_dict( player.velocity ),
			"extinguisher_count": player.extinguisher_count,
		}
		var cam_arm : Node3D = player.get_node_or_null( "CameraArm" )
		if cam_arm != null :
			player_state["camera_arm_rotation"] = SaveSerialization.vec3_to_dict( cam_arm.rotation )
		var cam3d : Camera3D = player.get_node_or_null( "CameraArm/Camera3D" ) as Camera3D
		var in_fpv : bool = player.is_fpv_drone_mode and is_instance_valid( player.current_vehicle ) and player.current_vehicle.has_method( "collect_save_state" )
		if in_fpv :
			player_state["is_fpv_drone_mode"] = true
			player_state["fpv_drone_path"] = str( get_path_to( player.current_vehicle ) )
			player_state["fpv_drone_state"] = player.current_vehicle.collect_save_state()
		else :
			player_state["is_fpv_drone_mode"] = false
			if cam3d != null :
				player_state["camera_rotation"] = SaveSerialization.vec3_to_dict( cam3d.rotation )
		var ph : Node = player.get_node_or_null( "PlayerHealth" )
		if ph != null and "current_health" in ph :
			health_state = {
				"current_health": ph.current_health,
				"current_hydration": ph.current_hydration,
			}
	var solar_state : Dictionary = {}
	var solar : Node = get_node_or_null( "UILayer/SolarUI" )
	if solar != null and solar.has_method( "collect_save_state" ) :
		solar_state = solar.collect_save_state()
	var mars_credits_state : Dictionary = {}
	var mcc : Node = get_node_or_null( "UILayer/MarsCollegeCreditsUI" )
	if mcc != null and mcc.has_method( "collect_save_state" ) :
		mars_credits_state = mcc.collect_save_state()
	var system_graph_state : Dictionary = {}
	var sg_view : Node = get_node_or_null( "UILayer/SystemGraphView" )
	if sg_view != null and sg_view.has_method( "collect_save_state" ) :
		system_graph_state = sg_view.collect_save_state()
	var rules_save : Dictionary = {}
	var gr_save := GameplayRulesImpl.from_node( self )
	if gr_save != null :
		rules_save = gr_save.to_save_dict()
	return {
		"save_version": SaveSerialization.SAVE_VERSION,
		"created_at_unix": Time.get_unix_time_from_system(),
		"playtime_seconds": _session_playtime_seconds,
		"scene_path": MapDefinition.snapshot_scene_path( self ),
		"main": main_state,
		"player": player_state,
		"health": health_state,
		"solar": solar_state,
		"mars_credits": mars_credits_state,
		"system_graph": system_graph_state,
		"gameplay_rules": rules_save,
	}


func _apply_save_snapshot( data: Dictionary ) -> bool :
	var sg : SaveGameService = _save_game_service()
	if sg == null or data.is_empty() :
		return false
	if not sg.validate_payload( data ) :
		push_warning( "Save/Load: invalid or incompatible save data." )
		show_toast( "Save data invalid or incompatible — could not load.", ToastUI.Level.ERROR )
		return false
	var main_d: Variant = data.get( "main", {} )
	if main_d is Dictionary :
		var md: Dictionary = main_d
		year = int( md.get( "year", year ) )
		month = int( md.get( "month", month ) )
		day = int( md.get( "day", day ) )
		day_time = float( md.get( "day_time", day_time ) )
		time_scale = float( md.get( "time_scale", time_scale ) )
		gameplay_mechanics_paused = bool( md.get( "gameplay_mechanics_paused", gameplay_mechanics_paused ) )
		# Route through apply_location so a loaded save also persists the location
		# and syncs every UI (TimeUI SpinBoxes, etc.) — keeps all paths unified.
		apply_location( float( md.get( "latitude", latitude ) ), float( md.get( "longitude", longitude ) ) )
		auto_dst = bool( md.get( "auto_dst", auto_dst ) )
		manual_dst = bool( md.get( "manual_dst", manual_dst ) )
	var gr_node := GameplayRulesImpl.from_node( self )
	if gr_node != null :
		gr_node.sync_survival_paused_from_main( self )
	var gr_d: Variant = data.get( "gameplay_rules", {} )
	if gr_d is Dictionary :
		var grdict: Dictionary = gr_d
		if not grdict.is_empty() and gr_node != null :
			gr_node.apply_save_state( grdict )
	if gr_node != null :
		gr_node.sync_main_from_rules( self )
	var solar_d: Variant = data.get( "solar", {} )
	var solar : Node = get_node_or_null( "UILayer/SolarUI" )
	if solar != null and solar_d is Dictionary and solar.has_method( "apply_save_state" ) :
		solar.apply_save_state( solar_d )
	var mcc_d: Variant = data.get( "mars_credits", {} )
	var mcc : Node = get_node_or_null( "UILayer/MarsCollegeCreditsUI" )
	if mcc != null and mcc_d is Dictionary and mcc.has_method( "apply_save_state" ) :
		mcc.apply_save_state( mcc_d )
	var sg_d: Variant = data.get( "system_graph", {} )
	var sg_view : Node = get_node_or_null( "UILayer/SystemGraphView" )
	if sg_view != null and sg_d is Dictionary and sg_view.has_method( "apply_save_state" ) :
		sg_view.apply_save_state( sg_d )
	if is_instance_valid( player ) :
		if player.is_riding and player.has_method( "_dismount_vehicle" ) :
			player._dismount_vehicle()
		var pd: Variant = data.get( "player", {} )
		if pd is Dictionary :
			var pdict: Dictionary = pd
			var restore_fpv: bool = bool( pdict.get( "is_fpv_drone_mode", false ) )
			var fpv_st: Variant = pdict.get( "fpv_drone_state", {} )
			if restore_fpv and not ( fpv_st is Dictionary ) :
				restore_fpv = false
			if restore_fpv and fpv_st is Dictionary :
				var fpd: Dictionary = fpv_st
				if fpd.is_empty() :
					restore_fpv = false
			player.global_position = SaveSerialization.dict_to_vec3( pdict.get( "position", {} ) )
			player.rotation = SaveSerialization.dict_to_vec3( pdict.get( "rotation", {} ) )
			player.velocity = SaveSerialization.dict_to_vec3( pdict.get( "velocity", {} ) )
			player.extinguisher_count = int( pdict.get( "extinguisher_count", player.extinguisher_count ) )
			var cam_arm : Node3D = player.get_node_or_null( "CameraArm" )
			if cam_arm != null and pdict.has( "camera_arm_rotation" ) :
				cam_arm.rotation = SaveSerialization.dict_to_vec3( pdict.get( "camera_arm_rotation", {} ) )
			var cam3d_restore : Camera3D = player.get_node_or_null( "CameraArm/Camera3D" ) as Camera3D
			if not restore_fpv and cam3d_restore != null and pdict.has( "camera_rotation" ) :
				cam3d_restore.rotation = SaveSerialization.dict_to_vec3( pdict.get( "camera_rotation", {} ) )
			player_spawn_position = player.global_position
			player_spawn_rotation = player.rotation
			if restore_fpv :
				var fpv_path: String = str( pdict.get( "fpv_drone_path", "" ) )
				var drone: Node = get_node_or_null( NodePath( fpv_path ) ) if fpv_path != "" else null
				if drone != null and drone.has_method( "restore_from_save" ) and fpv_st is Dictionary :
					if drone.restore_from_save( player, fpv_st ) and player.has_method( "apply_fpv_drone_restore_after_load" ) :
						player.apply_fpv_drone_restore_after_load( drone )
					else :
						push_warning( "Save/Load: FPV drone restore failed for path %s" % fpv_path )
				else :
					push_warning( "Save/Load: could not find FPV drone at path %s" % fpv_path )
			if player.has_method( "_capture_mouse" ) :
				player._capture_mouse()
		var hd: Variant = data.get( "health", {} )
		var ph : Node = player.get_node_or_null( "PlayerHealth" )
		if ph != null and hd is Dictionary :
			var hdict: Dictionary = hd
			if "current_health" in ph :
				ph.current_health = float( hdict.get( "current_health", ph.current_health ) )
			if "current_hydration" in ph :
				ph.current_hydration = float( hdict.get( "current_hydration", ph.current_hydration ) )
	var pt: Variant = data.get( "playtime_seconds", null )
	if pt != null :
		_session_playtime_seconds = float( pt )
	_update()
	if solar != null and solar.has_method( "refresh_after_save_load" ) :
		solar.refresh_after_save_load()
	var tu : Node = get_node_or_null( "UILayer/TimeUI" )
	if tu != null and tu.has_method( "refresh_controls_from_main" ) :
		tu.refresh_controls_from_main()
	if is_instance_valid( SimSettingsController ) :
		SimSettingsController.reset_scene_binding()
		SimSettingsController.refresh_from_main()
	var tl : Node = get_node_or_null( "UILayer/TimelineUI" )
	if tl != null and tl.has_method( "refresh_from_main" ) :
		tl.refresh_from_main()
	if is_instance_valid( save_load_ui ) and save_load_ui.has_method( "refresh_slot_list" ) :
		save_load_ui.refresh_slot_list()
	if is_instance_valid( save_load_ui ) and save_load_ui.has_method( "hide_panel" ) :
		save_load_ui.hide_panel()
	return true

func _setup_shadows() -> void :
	# Enable shadow casting on ALL mesh instances in the scene
	_enable_shadows_recursive( self )
	# Apply quality profile to directional lights
	_apply_shadow_quality()
	# Apply the global graphics preset (shadow atlas size, soft-shadow filter, TAA)
	_apply_graphics_quality()

func get_shadow_quality_name() -> String :
	match shadow_quality :
		0 :
			return "Low"
		1 :
			return "Medium"
		2 :
			return "High"
		3 :
			return "Ultra"
		_ :
			return "High"

func set_shadow_quality_level( level: int ) -> void :
	shadow_quality = clampi( level, 0, 3 )
	_apply_shadow_quality()

func get_shadow_quality_level() -> int :
	return shadow_quality

func get_graphics_quality_name() -> String :
	match graphics_quality :
		0 :
			return "Low"
		1 :
			return "Medium"
		2 :
			return "High"
		_ :
			return "High"

func set_graphics_quality_level( level: int ) -> void :
	graphics_quality = clampi( level, 0, 2 )
	_apply_graphics_quality()

func get_graphics_quality_level() -> int :
	return graphics_quality

func set_ambient_energy_mult( value: float ) -> void :
	ambient_energy_mult = value

func get_ambient_energy_mult() -> float :
	return ambient_energy_mult

func set_ambient_sky_contribution( value: float ) -> void :
	ambient_sky_contribution = value

func get_ambient_sky_contribution() -> float :
	return ambient_sky_contribution

func set_glow_intensity_mult( value: float ) -> void :
	glow_intensity_mult = value

func get_glow_intensity_mult() -> float :
	return glow_intensity_mult

func set_glow_user_enabled( on: bool ) -> void :
	glow_user_enabled = on

func get_glow_user_enabled() -> bool :
	return glow_user_enabled

func set_ssao_enabled( on: bool ) -> void :
	ssao_user_enabled = on

func get_ssao_enabled() -> bool :
	return ssao_user_enabled

func set_ssil_enabled( on: bool ) -> void :
	ssil_user_enabled = on

func get_ssil_enabled() -> bool :
	return ssil_user_enabled

func set_sdfgi_enabled( on: bool ) -> void :
	sdfgi_user_enabled = on

func get_sdfgi_enabled() -> bool :
	return sdfgi_user_enabled

func set_volumetric_fog_enabled( on: bool ) -> void :
	volumetric_fog_user_enabled = on

func get_volumetric_fog_enabled() -> bool :
	return volumetric_fog_user_enabled

func set_tonemap_mode( mode: int ) -> void :
	tonemap_mode = mode

func get_tonemap_mode() -> int :
	return tonemap_mode

func set_tonemap_exposure( value: float ) -> void :
	tonemap_exposure = value

func get_tonemap_exposure() -> float :
	return tonemap_exposure

func set_tonemap_white( value: float ) -> void :
	tonemap_white = value

func get_tonemap_white() -> float :
	return tonemap_white

func set_sun_size( value: float ) -> void :
	sun_size = value

func get_sun_size() -> float :
	return sun_size

func set_moon_size( value: float ) -> void :
	moon_size = value

func get_moon_size() -> float :
	return moon_size

func set_moon_glow( value: float ) -> void :
	moon_glow = value

func get_moon_glow() -> float :
	return moon_glow

func set_sun_glow( value: float ) -> void :
	sun_glow = value

func get_sun_glow() -> float :
	return sun_glow

func set_sun_glow_size( value: float ) -> void :
	sun_glow_size = value

func get_sun_glow_size() -> float :
	return sun_glow_size

func set_sun_aureole( value: float ) -> void :
	sun_aureole = value

func get_sun_aureole() -> float :
	return sun_aureole

func set_cirrus_amount( value: float ) -> void :
	cirrus_amount = value

func get_cirrus_amount() -> float :
	return cirrus_amount

func set_cirrus_user_scale( value: float ) -> void :
	cirrus_user_scale = value

func get_cirrus_user_scale() -> float :
	return cirrus_user_scale

func set_cloud_shadows_enabled( on: bool ) -> void :
	cloud_shadows_enabled = on

func get_cloud_shadows_enabled() -> bool :
	return cloud_shadows_enabled

func set_god_rays_enabled( on: bool ) -> void :
	god_rays_enabled = on

func get_god_rays_enabled() -> bool :
	return god_rays_enabled

# ---- Camera field of view (player + FPV drone share one Camera3D) ----

func _player_camera() -> Camera3D :
	if not is_instance_valid( player ) :
		return null
	return player.get_node_or_null( "CameraArm/Camera3D" ) as Camera3D

## Push the correct FOV onto the shared camera based on the current mode. The
## drone borrows the player's Camera3D, so it gets drone_fov while mounted and
## reverts to player_fov once the player is back on foot.
func _apply_camera_fov() -> void :
	var cam := _player_camera()
	if cam == null :
		return
	var drone_active : bool = false
	if is_instance_valid( player ) and player.get( "is_fpv_drone_mode" ) != null :
		drone_active = bool( player.get( "is_fpv_drone_mode" ) )
	var target : float = drone_fov if drone_active else player_fov
	if target > 0.0 and is_finite( target ) :
		cam.fov = clampf( target, 1.0, 179.0 )

func set_player_fov( value: float ) -> void :
	player_fov = value

func get_player_fov() -> float :
	if player_fov > 0.0 :
		return player_fov
	var cam := _player_camera()
	return cam.fov if cam != null else 50.0

func set_drone_fov( value: float ) -> void :
	drone_fov = value

func get_drone_fov() -> float :
	if drone_fov > 0.0 :
		return drone_fov
	return get_player_fov()

## Re-apply FOV when the player mounts/dismounts a vehicle (deferred so the
## mode flag has settled). Ignores the emitted vehicle argument.
func _on_vehicle_camera_change( _vehicle: Node3D = null ) -> void :
	call_deferred( "_apply_camera_fov" )

func set_fog_amount( value: float ) -> void :
	fog_amount = value

func get_fog_amount() -> float :
	return fog_amount

func get_star_system() -> StarSystem :
	return star_system

func get_planet_system() -> Node3D :
	return planet_system

func _force_planet_update() -> void :
	if is_instance_valid( planet_system ) and planet_system.has_method( "force_update" ) :
		planet_system.call( "force_update" )

func _apply_advanced_rendering_toggles() -> void :
	if not is_instance_valid( environment ) or environment.environment == null :
		return
	var env : Environment = environment.environment
	env.ssao_enabled = ssao_user_enabled
	env.ssil_enabled = ssil_user_enabled
	env.sdfgi_enabled = sdfgi_user_enabled
	# God rays ride on the volumetric fog pass, so enable it when either the plain
	# volumetric-fog toggle OR the god-rays toggle is on.
	env.volumetric_fog_enabled = volumetric_fog_user_enabled or god_rays_enabled
	if god_rays_enabled :
		# Thin fog + strong in-scattering length so the sun scatters into visible
		# shafts without fogging the whole scene into a grey wash.
		env.volumetric_fog_density = 0.018 if not volumetric_fog_user_enabled else maxf( env.volumetric_fog_density, 0.018 )
		env.volumetric_fog_length = 96.0
		env.volumetric_fog_detail_spread = 2.0
		env.volumetric_fog_gi_inject = 0.0
		env.volumetric_fog_ambient_inject = 0.0
		env.volumetric_fog_albedo = Color( 1.0, 0.95, 0.85 )
		if is_instance_valid( sun ) :
			# The directional light's contribution to the fog = the shafts themselves.
			sun.light_volumetric_fog_energy = 2.2
	elif is_instance_valid( sun ) :
		sun.light_volumetric_fog_energy = 1.0

func _apply_tonemap_settings() -> void :
	if not is_instance_valid( environment ) or environment.environment == null :
		return
	var env : Environment = environment.environment
	env.tonemap_mode = tonemap_mode as Environment.ToneMapper
	env.tonemap_exposure = tonemap_exposure
	env.tonemap_white = tonemap_white

func _apply_msaa_level() -> void :
	if Engine.is_editor_hint() :
		return
	var vp := get_viewport()
	if vp != null :
		vp.msaa_3d = msaa_level as Viewport.MSAA

func set_msaa_level( level: int ) -> void :
	msaa_level = level

func get_msaa_level() -> int :
	return msaa_level

## Apply the global graphics preset via RenderingServer + the active viewport.
## These are global/viewport knobs (not per-light), so they take effect immediately.
func _apply_graphics_quality() -> void :
	if Engine.is_editor_hint() :
		return
	var atlas_size : int = 2048
	var soft_quality : int = RenderingServer.SHADOW_QUALITY_SOFT_HIGH
	var taa : bool = true
	match graphics_quality :
		0 :  # Low
			atlas_size = 1024
			soft_quality = RenderingServer.SHADOW_QUALITY_SOFT_LOW
			taa = false
		1 :  # Medium
			atlas_size = 1536
			soft_quality = RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM
			taa = true
		2 :  # High (matches project.godot baseline)
			atlas_size = 2048
			soft_quality = RenderingServer.SHADOW_QUALITY_SOFT_HIGH
			taa = true
	RenderingServer.directional_shadow_atlas_set_size( atlas_size, true )
	RenderingServer.directional_soft_shadow_filter_set_quality( soft_quality )
	RenderingServer.positional_soft_shadow_filter_set_quality( soft_quality )
	var vp := get_viewport()
	if vp != null :
		vp.use_taa = taa

func _get_shadow_profile() -> Dictionary :
	match shadow_quality :
		0 :
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
				"max_distance": 90.0,
				"blur": 2.0,
				"bias": 0.085,
				"normal_bias": 3.4,
				"split_1": 0.15,
				"split_2": 0.4,
				"split_3": 0.7,
				"pancake": 24.0,
				"moon_distance_scale": 0.7
			}
		1 :
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS,
				"max_distance": 150.0,
				"blur": 1.2,
				"bias": 0.055,
				"normal_bias": 2.2,
				"split_1": 0.12,
				"split_2": 0.38,
				"split_3": 0.68,
				"pancake": 30.0,
				"moon_distance_scale": 0.9
			}
		2 :
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
				"max_distance": 230.0,
				"blur": 0.55,
				"bias": 0.03,
				"normal_bias": 1.0,
				"split_1": 0.08,
				"split_2": 0.25,
				"split_3": 0.58,
				"pancake": 40.0,
				"moon_distance_scale": 1.0
			}
		3 :
			return {
				"mode": DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,
				"max_distance": 320.0,
				"blur": 0.22,
				"bias": 0.018,
				"normal_bias": 0.55,
				"split_1": 0.06,
				"split_2": 0.2,
				"split_3": 0.52,
				"pancake": 50.0,
				"moon_distance_scale": 1.15
			}
		_ :
			return {}

func _apply_shadow_quality() -> void :
	var profile := _get_shadow_profile()
	if profile.is_empty() :
		return

	_moon_shadow_quality_distance_scale = profile.get( "moon_distance_scale", 1.0 )

	if is_instance_valid( sun ) :
		sun.shadow_enabled = true
		sun.shadow_opacity = 0.98
		sun.shadow_blur = profile.get( "blur", 0.55 )
		sun.shadow_bias = profile.get( "bias", 0.03 )
		sun.shadow_normal_bias = profile.get( "normal_bias", 1.0 )
		sun.directional_shadow_mode = profile.get( "mode", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS )
		sun.directional_shadow_blend_splits = true
		sun.directional_shadow_max_distance = profile.get( "max_distance", 230.0 )
		sun.directional_shadow_split_1 = profile.get( "split_1", 0.08 )
		sun.directional_shadow_split_2 = profile.get( "split_2", 0.25 )
		sun.directional_shadow_split_3 = profile.get( "split_3", 0.58 )
		sun.directional_shadow_pancake_size = profile.get( "pancake", 40.0 )

	if is_instance_valid( moon ) :
		moon.shadow_blur = profile.get( "blur", 0.55 ) + 0.15
		moon.shadow_bias = profile.get( "bias", 0.03 ) * 1.25
		moon.shadow_normal_bias = profile.get( "normal_bias", 1.0 ) * 1.2
		moon.directional_shadow_mode = profile.get( "mode", DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS )
		moon.directional_shadow_blend_splits = true
		moon.directional_shadow_split_1 = profile.get( "split_1", 0.08 )
		moon.directional_shadow_split_2 = profile.get( "split_2", 0.25 )
		moon.directional_shadow_split_3 = profile.get( "split_3", 0.58 )
		moon.directional_shadow_pancake_size = profile.get( "pancake", 40.0 )

## Disable shadow casting for decorative string-light OmniLight3D nodes.
## Each shadow-casting OmniLight requires 6 cubemap shadow passes, so turning
## these off removes a large GPU cost with minimal visual impact.
func _disable_string_light_omni_shadows() -> void :
	_disable_string_light_omni_shadows_recursive( self )

func _disable_string_light_omni_shadows_recursive( node : Node ) -> void :
	if node == null :
		return
	
	if node is OmniLight3D :
		var path_text : String = String( node.get_path() ).to_lower()
		if path_text.contains( "stringlights" ) :
			var omni : OmniLight3D = node as OmniLight3D
			omni.shadow_enabled = false
	
	for child in node.get_children() :
		_disable_string_light_omni_shadows_recursive( child )

## Auto-generate collision for imported meshes in the structure
func _setup_auto_collision() -> void :
	if Engine.is_editor_hint() :
		return
	
	# Structure collision
	if is_instance_valid( structure ) :
		_generate_collision_recursive( structure )
	
	# Terrain collision (walkable ground and mountain base)
	var terrain_root := get_node_or_null( "Terrain" )
	if terrain_root == null :
		# `main- maybe unstable.tscn` uses this imported terrain root name.
		terrain_root = get_node_or_null( "Soak site 3" )
	if terrain_root == null :
		# Extra fallback if the node is renamed in future scene revisions.
		terrain_root = get_node_or_null( "Soak Site 3" )
	if terrain_root != null :
		_generate_collision_recursive( terrain_root )
	
	# Distant mountain model collision (allow hiking/climbing slopes).
	# Filter out tiny decorative meshes to keep startup cost reasonable.
	var mountain_root := get_node_or_null( "Mars 2026 - Aerial Located smaller" )
	if mountain_root != null :
		_generate_collision_recursive( mountain_root, 25.0 )

	# Hidden meshes (like disabled terrain helper planes) should not keep collision.
	_strip_hidden_mesh_collision_recursive( self )
	
	# Imported GLB toilets often ship with tight StaticBody shells that block Area3D death zones.
	call_deferred( "_strip_portapotty_blocking_collision" )

## Remove StaticBody3D collision under portable-toilet hierarchies (visuals stay; traps stay triggerable).
func _strip_portapotty_blocking_collision() -> void :
	if Engine.is_editor_hint() :
		return
	for root_name : String in [ "Mars 2026 -Final", "Mars 2026 - 2-4-26", "LinkageLab_Export2" ] :
		var sub : Node = get_node_or_null( root_name )
		if sub != null :
			_strip_portapotty_collision_recursive( sub )


func _strip_portapotty_collision_recursive( node : Node ) -> void :
	if node == null :
		return
	var nm : String = String( node.name ).to_lower()
	if nm.contains( "portojohn" ) or nm.contains( "portapotty" ) or nm.contains( "porta potty" ) or nm.contains( "portable toilet" ) :
		_queue_free_static_bodies_under( node )
	for child in node.get_children() :
		_strip_portapotty_collision_recursive( child )


func _queue_free_static_bodies_under( root : Node ) -> void :
	var stack : Array[Node] = [ root ]
	var to_remove : Array[Node] = []
	while not stack.is_empty() :
		var n : Node = stack.pop_back()
		for ch in n.get_children() :
			if ch is StaticBody3D or ch is AnimatableBody3D :
				to_remove.append( ch )
			else :
				stack.append( ch )
	for sb in to_remove :
		if is_instance_valid( sb ) :
			sb.queue_free()

## Recursively generate collision for MeshInstance3D nodes
func _generate_collision_recursive( node : Node, min_mesh_extent : float = 0.0 ) -> void :
	if node == null :
		return
	
	if node is MeshInstance3D :
		var mesh_inst : MeshInstance3D = node as MeshInstance3D
		# Respect mesh visibility: hidden helper meshes should not become walkable colliders.
		if not mesh_inst.is_visible_in_tree() :
			for child in mesh_inst.get_children() :
				if child is StaticBody3D or child is AnimatableBody3D :
					child.queue_free()
			for child in node.get_children() :
				_generate_collision_recursive( child, min_mesh_extent )
			return
		# Skip if already has collision (check for StaticBody3D child)
		var has_collision := false
		for child in mesh_inst.get_children() :
			if child is StaticBody3D :
				has_collision = true
				break
		
		# Skip certain types of meshes by name
		var mesh_name := mesh_inst.name.to_lower()
		var skip_keywords := [ "light", "bulb", "halo", "glass", "window", "glow", "wire", "stringlight", "cable", "rope", "starshade", "shade_panel", "ibc_glow" ]
		var should_skip := false
		for keyword in skip_keywords :
			if mesh_name.contains( keyword ) :
				should_skip = true
				break
		if not should_skip and _collision_excluded_by_ancestor( mesh_inst ) :
			should_skip = true
		
		var too_small := false
		if min_mesh_extent > 0.0 and mesh_inst.mesh != null :
			var aabb_size : Vector3 = mesh_inst.get_aabb().size
			var max_extent : float = maxf( aabb_size.x, maxf( aabb_size.y, aabb_size.z ) )
			too_small = max_extent < min_mesh_extent
		
		# Generate collision if mesh doesn't have it and shouldn't be skipped
		if not has_collision and not should_skip and not too_small and mesh_inst.mesh != null :
			var static_body := StaticBody3D.new()
			static_body.name = "AutoCollision"
			var collision_shape := CollisionShape3D.new()
			collision_shape.shape = mesh_inst.mesh.create_trimesh_shape()
			static_body.add_child( collision_shape )
			mesh_inst.add_child( static_body )
	
	for child in node.get_children() :
		_generate_collision_recursive( child, min_mesh_extent )


## Remove collision children from hidden mesh nodes so invisible helper planes
## cannot block movement.
func _strip_hidden_mesh_collision_recursive( node : Node ) -> void :
	if node == null :
		return
	if node is MeshInstance3D :
		var mesh_inst : MeshInstance3D = node as MeshInstance3D
		if not mesh_inst.is_visible_in_tree() :
			for child in mesh_inst.get_children() :
				if child is StaticBody3D or child is AnimatableBody3D :
					child.queue_free()
	for child in node.get_children() :
		_strip_hidden_mesh_collision_recursive( child )


## Skip trimesh on props that snag the capsule (toilets use separate death Area3D).
func _collision_excluded_by_ancestor( mesh_inst : MeshInstance3D ) -> bool :
	var p : Node = mesh_inst
	while p != null :
		var pn : String = String( p.name ).to_lower()
		if (
			pn.contains( "portojohn" )
			or pn.contains( "portapotty" )
			or pn.contains( "porta potty" )
			or pn.contains( "portable toilet" )
			or pn.contains( "starshade" )
			or pn.contains( "linkagelab_export" )
			or pn.contains( "ibc_glow" )
		) :
			return true
		p = p.get_parent()
	return false

## Recursively enable shadow casting on all MeshInstance3D nodes
func _enable_shadows_recursive( node : Node ) -> void :
	if node == null :
		return
	if node is MeshInstance3D :
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	for child in node.get_children() :
		_enable_shadows_recursive( child )

## Set the in-game calendar and time-of-day from a Unix timestamp.
## Converts the absolute instant to the player's local timezone for sun/sky.
func set_world_time_from_unix( t_unix: int ) -> void :
	if Engine.is_editor_hint() :
		return
	clock.set_from_unix( t_unix )
	_force_planet_update()
	_update()

# Heavy environment recompute (sun/moon/planets/stars/clouds/sky shader/fog) is
# throttled to this interval instead of running every frame. Direct setter writes
# (UI date/time, location change, save-load) still force an immediate _update().
const _ENV_UPDATE_INTERVAL : float = 0.05  # ~20 Hz
var _env_update_accum : float = 0.0
var _vegetation_night_factor : float = 0.0
var _vegetation_sun_direction : Vector3 = Vector3.UP
## Seasonal phenology signals + weather-driven snow cover, cached in
## _update_environment() and read by VegetationEnvironmentSync / TerrainLoader.
var _season_signals : Dictionary = {
	"leaf_coverage": 1.0, "autumn": 0.0, "bud": 0.0, "summer": 1.0, "winter": 0.0
}
var _snow_amount : float = 0.0
var _weather_service_node : Node = null
## When true, _process discrete-steps one day per frame to its mean solar noon,
## tracing the analemma and advancing across successive years (set by TimelineUI's
## ∞ speed preset). time_scale is held at 0 so the sim is visual-only.
var analemma_mode : bool = false :
	set( value ) :
		var was : bool = analemma_mode
		analemma_mode = value
		if value != was :
			_on_analemma_mode_changed( value )

## Earliest year the ∞ analemma view cycles back to before wrapping — the start
## of the Open-Meteo ERA5 archive, so every pass down to 1940 still lands on a
## year with real historical weather.
const ANALEMMA_ARCHIVE_START_YEAR : int = 1940

## Distance (m) at which the white analemma guide path is drawn around the camera.
## Kept comfortably inside the default camera far plane (4000 m) so the whole
## figure-eight stays visible while reading as if painted on the sky dome.
const ANALEMMA_PATH_RADIUS : float = 2000.0

## Educational overlay: the white curve the sun traces at mean solar noon over a
## full year. Only shown in analemma mode. Rebuilt when the observer moves
## (the figure-eight's tilt and span are latitude-dependent).
var _analemma_path : MeshInstance3D = null
var _analemma_path_lat : float = INF
var _analemma_path_lon : float = INF

func _process( delta: float ) -> void :
	if not Engine.is_editor_hint() :
		# Analemma / ∞ view: each frame jumps to the next day's solar noon and
		# refreshes the world. Visual-only — time_scale is 0 so no other system
		# integrates (battery/energy stay frozen).
		if analemma_mode :
			_step_analemma()
			_session_playtime_seconds += delta
			return
		# Advance the clock directly so the date still rolls (clock.day_time setter
		# handles rollover both directions) WITHOUT triggering the per-frame
		# _update() inside main.gd's day_time setter. The visual recompute is
		# throttled below.
		clock.day_time += delta * time_scale
		_session_playtime_seconds += delta
		# Planets are tiny points, so the 20 Hz sky throttle below makes them
		# visibly jump at high speed while the sun/moon glide. Push them every
		# frame (cheap — 5 planets × a few uniforms); PlanetSystem eases each
		# rendered direction toward its freshly computed position per frame, so
		# the motion stays smooth even at Max speed.
		_update_planets()
		_env_update_accum += delta
		if _env_update_accum >= _ENV_UPDATE_INTERVAL :
			_env_update_accum = 0.0
			_update()

func _update() -> void :
	_update_sun()
	_update_moon()
	_update_planets()
	# StarSystem defers `_find_main_scene`; in `@tool` scenes it can also be a script placeholder
	# during editor load. `has_method`/`call` still see placeholder methods — use direct calls only
	# after `main_scene_ready` and normal tree membership.
	if (
		is_instance_valid( star_system )
		and star_system.is_inside_tree()
		and star_system is StarSystem
	) :
		var ss : StarSystem = star_system as StarSystem
		if ("main_scene_ready" in ss) and ss.main_scene_ready :
			ss.update_reference_stars()
			ss.update_stars()
	_update_clouds()
	_update_shader()
	_update_environment()
	_update_celestial_sizes()

# ==================== DATE CALCULATIONS ====================

## Get number of days in a month (public for UI access)
func get_days_in_month( m: int, y: int ) -> int :
	return clock.get_days_in_month( m, y )

# ==================== ASTRONOMICAL CALCULATIONS ====================

## Calculate Julian Day Number (days since Jan 1, 4713 BC)
func get_julian_day() -> float :
	return clock.get_julian_day()

## Calculate Equation of Time (correction for sun's position due to Earth's elliptical orbit)
func get_equation_of_time( jd: float ) -> float :
	return clock.get_equation_of_time( jd )

## Calculate sun's declination (angle from celestial equator)
func get_sun_declination( jd: float ) -> float :
	return clock.get_sun_declination( jd )

# ==================== SUN UPDATE ====================

## Convert local clock time to Local Apparent Solar Time
## This accounts for: timezone, longitude offset, DST, and Equation of Time
func get_solar_time() -> float :
	return clock.get_solar_time()

func _update_sun() -> void :
	if not is_instance_valid( sun ) :
		return

	var sun_direction : Vector3 = clock.get_sun_direction()

	# Point the DirectionalLight3D so its -Z axis aims FROM sun direction toward scene
	# We use look_at with a target behind the light and an appropriate up vector
	if sun_direction.length() > 0.001 :
		var up_vector : Vector3 = Vector3.UP
		# When sun is near zenith or nadir, use a different up vector to avoid gimbal lock
		if abs( sun_direction.y ) > 0.99 :
			up_vector = Vector3.FORWARD
		sun.look_at( sun.global_position - sun_direction, up_vector )

	# Fade light near horizon, boost when high in sky
	var horizon_fade : float = smoothstep( -0.1, 0.2, sun_direction.y )
	# Add extra intensity when sun is high (simulates less atmospheric scattering)
	var high_sun_boost : float = 1.0 + smoothstep( 0.3, 0.8, sun_direction.y ) * 0.3
	# Apply weather attenuation (clouds reduce direct sunlight) plus the drifting
	# cloud-shadow factor (a passing cloud briefly dims the direct sun).
	# Final clamp at the GPU boundary: a non-finite light_energy hard-hangs the
	# Vulkan renderer (full-desktop "shattered glass" + reboot), so never let one through.
	var sun_e : float = horizon_fade * high_sun_boost * sun_base_enegry * weather_light_factor * _compute_cloud_shadow_factor()
	sun.light_energy = clampf(sun_e, 0.0, 64.0) if is_finite(sun_e) else 0.0

## Global direct-sun attenuation that drifts with the visible clouds, giving the
## "sun ducked behind a cloud" dimming on partly-cloudy days. Returns 1.0 (no
## change) when disabled or when the sky is clear. Cheap: one noise sample.
func _compute_cloud_shadow_factor() -> float :
	if not cloud_shadows_enabled :
		return 1.0
	var coverage : float = clampf( 1.0 - clouds_cutoff, 0.0, 1.0 )
	if coverage <= 0.001 :
		return 1.0
	if _cloud_shadow_noise == null :
		_cloud_shadow_noise = FastNoiseLite.new()
		_cloud_shadow_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_cloud_shadow_noise.fractal_octaves = 2
		_cloud_shadow_noise.frequency = 0.5
		# Cache the static cloud drift uniforms once (they don't change at runtime),
		# rather than reading shader parameters every _update_sun() call.
		if is_instance_valid( environment ) and environment.environment != null \
				and environment.environment.sky != null \
				and environment.environment.sky.sky_material != null :
			var mat := environment.environment.sky.sky_material
			var sv = mat.get_shader_parameter( "clouds_speed" )
			var dv = mat.get_shader_parameter( "clouds_direction" )
			if sv != null :
				_cloud_shadow_speed = float( sv )
			if dv != null :
				_cloud_shadow_dir = float( dv )
	# Drift along the same bearing/speed as the sky-shader clouds (real engine
	# seconds, since the sky clouds scroll on TIME, not sim time).
	var t : float = float( Time.get_ticks_msec() ) / 1000.0 * maxf( _cloud_shadow_speed, 0.01 ) * 0.06
	var ang : float = _cloud_shadow_dir * TAU
	var n : float = _cloud_shadow_noise.get_noise_2d( cos( ang ) * t, sin( ang ) * t ) * 0.5 + 0.5
	# Only denser cloud patches cast a shadow; more coverage → shadowed more often.
	var shadow : float = smoothstep( 1.0 - coverage, 1.0 - coverage * 0.35, n )
	var factor : float = 1.0 - shadow * cloud_shadow_strength * coverage
	return clampf( factor, 0.12, 1.0 ) if is_finite( factor ) else 1.0

# ==================== MOON UPDATE ====================

## Calculate Julian Day in UTC from local clock time
## day_time is treated as local clock time, we convert to UTC
func get_julian_day_utc() -> float :
	return clock.get_julian_day_utc()

## Calculate Local Sidereal Time in degrees (using UTC-based Julian Day)
func get_local_sidereal_time( jd_utc: float ) -> float :
	return clock.get_local_sidereal_time( jd_utc )

## Calculate moon's ecliptic coordinates (longitude, latitude)
func get_moon_position( jd_utc: float ) -> Dictionary :
	return clock.get_moon_position( jd_utc )

## Convert ecliptic coordinates to equatorial (Right Ascension, Declination)
func ecliptic_to_equatorial( ecl_lon: float, ecl_lat: float ) -> Dictionary :
	return clock.ecliptic_to_equatorial( ecl_lon, ecl_lat )

func _update_moon() -> void :
	if not is_instance_valid( moon ) or not is_instance_valid( sun ):
		return

	var moon_direction : Vector3 = clock.get_moon_direction()

	# Point the DirectionalLight3D
	if moon_direction.length() > 0.001 :
		var up_vector : Vector3 = Vector3.UP
		if abs( moon_direction.y ) > 0.99 :
			up_vector = Vector3.FORWARD
		moon.look_at( moon.global_position - moon_direction, up_vector )

	# Get realistic phase brightness using improved model
	var phase_brightness : float = clock.get_lunar_phase_brightness()

	# Fade light near horizon (atmospheric extinction)
	var horizon_fade : float = smoothstep( -0.05, 0.15, moon_direction.y )

	# Apply weather attenuation (clouds block moonlight too).
	var final_brightness : float = horizon_fade * phase_brightness * weather_light_factor
	var moon_e : float = final_brightness * moon_base_enegry
	moon.light_energy = clampf(moon_e, 0.0, 64.0) if is_finite(moon_e) else 0.0

	# === DYNAMIC MOON SHADOWS ===
	# Enable shadows only when moon is bright enough and above horizon
	var moon_above_horizon : bool = moon_direction.y > 0.05
	var bright_enough_for_shadows : bool = phase_brightness >= moon_shadow_threshold
	var clear_enough_for_shadows : bool = weather_light_factor > 0.5  # Not too cloudy

	if moon_shadows_enabled and moon_above_horizon and bright_enough_for_shadows and clear_enough_for_shadows :
		moon.shadow_enabled = true
		# Shadow distance scales with brightness - fuller moon = longer shadows
		moon.directional_shadow_max_distance = moon_shadow_distance * _moon_shadow_quality_distance_scale * phase_brightness
		# Shadow opacity varies with brightness and weather
		# Full moon on clear night = ~0.6 opacity, dimmer = softer shadows
		var shadow_strength : float = phase_brightness * weather_light_factor * 0.6
		moon.shadow_opacity = clampf( shadow_strength, 0.1, 0.6 )
	else :
		moon.shadow_enabled = false

# ==================== PLANETS UPDATE ====================

func _update_planets() -> void :
	if not is_instance_valid( environment ) or not is_instance_valid( planet_system ) :
		return
	
	# Check if planet_system has the required method
	if not planet_system.has_method( "get_shader_data" ) :
		return
	
	var shader_data : Dictionary = planet_system.get_shader_data()
	var directions : Array = shader_data.get( "directions", [] )
	var colors : Array = shader_data.get( "colors", [] )
	var sizes : Array = shader_data.get( "sizes", [] )
	var enabled : Array = shader_data.get( "enabled", [] )
	var glows : Array = shader_data.get( "glows", [] )
	var glow_colors : Array = shader_data.get( "glow_colors", [] )
	
	var sky_material = environment.environment.sky.sky_material
	
	# Update each planet's shader parameters
	for i in range( min( 5, directions.size() ) ) :
		var dir_param := "planet_direction_%d" % i
		var color_param := "planet_color_%d" % i
		var size_param := "planet_size_%d" % i
		var enabled_param := "planet_enabled_%d" % i
		var glow_param := "planet_glow_%d" % i
		var glow_color_param := "planet_glow_color_%d" % i
		
		sky_material.set_shader_parameter( dir_param, directions[i] )
		sky_material.set_shader_parameter( color_param, Vector3( colors[i].r, colors[i].g, colors[i].b ) )
		sky_material.set_shader_parameter( size_param, sizes[i] )
		sky_material.set_shader_parameter( enabled_param, 1.0 if enabled[i] else 0.0 )
		sky_material.set_shader_parameter( glow_param, glows[i] if i < glows.size() else 0.0 )
		if i < glow_colors.size() :
			sky_material.set_shader_parameter( glow_color_param, Vector3( glow_colors[i].r, glow_colors[i].g, glow_colors[i].b ) )

# ==================== UTILITY FUNCTIONS ====================

func get_lunar_phase() -> float :
	return clock.get_lunar_phase()

func get_lunar_phase_name() -> String :
	return clock.get_lunar_phase_name()

func _update_clouds() -> void :
	if is_instance_valid( environment ) :
		environment.environment.sky.sky_material.set_shader_parameter( "clouds_cutoff", clouds_cutoff )
		environment.environment.sky.sky_material.set_shader_parameter( "clouds_weight", clouds_weight )
		environment.environment.sky.sky_material.set_shader_parameter( "cirrus_amount", cirrus_amount )

func _update_celestial_sizes() -> void :
	if is_instance_valid( environment ) :
		environment.environment.sky.sky_material.set_shader_parameter( "sun_size", sun_size )
		environment.environment.sky.sky_material.set_shader_parameter( "moon_size", moon_size )
		environment.environment.sky.sky_material.set_shader_parameter( "moon_glow", moon_glow )
		environment.environment.sky.sky_material.set_shader_parameter( "sun_glow", sun_glow )
		environment.environment.sky.sky_material.set_shader_parameter( "sun_glow_size", sun_glow_size )
		environment.environment.sky.sky_material.set_shader_parameter( "sun_aureole", sun_aureole )

func _update_environment() -> void :
	if not is_instance_valid( environment ) or not is_instance_valid( sun ) :
		return
	
	# Get sun direction to determine day/night
	var sun_direction = sun.to_global( Vector3( 0.0, 0.0, 1.0 ) ).normalized()
	var sun_height : float = sun_direction.y
	
	# Calculate night amount (0 = full day, 1 = full night)
	var night_amount : float = clamp( -sun_height + 0.1, 0.0, 1.0 )
	night_amount = smoothstep( 0.0, 0.5, night_amount )
	_vegetation_night_factor = night_amount
	if sun_direction.length_squared() > 1e-6 :
		_vegetation_sun_direction = sun_direction.normalized()
	_update_seasonal()
	
	# Sunset amount: broad indicator around dawn/dusk.
	var sunset_amount : float = clamp( 0.5 - abs( sun_height ), 0.0, 0.5 ) * 2.0
	# Golden-hour amount: narrower window close to horizon to avoid "pale/white"
	# haze hours before sunset.
	var golden_hour_amount : float = 1.0 - smoothstep( 0.08, 0.30, abs( sun_height ) )
	var twilight_amount : float = golden_hour_amount * ( 1.0 - night_amount * 0.7 )
	# Extra weighting while sun is still above the horizon (late afternoon to sunset).
	# This is where distant mountains were washing out too pale.
	var pre_sunset_amount : float = 0.0
	if sun_height > 0.0 :
		pre_sunset_amount = clampf(( 0.32 - sun_height ) / 0.30, 0.0, 1.0 )
	
	# === ATMOSPHERIC PERSPECTIVE ===
	# fog_aerial_perspective samples the sky shader's own rendered color per pixel
	# and blends it into distant geometry — essentially free since the sky is already
	# rendered.  Mountains naturally take on the sunset amber/grey-blue gradient without
	# any dedicated volumetric pass.
	#
	# Haze color: used for the exponential depth falloff curve.
	# Keep twilight haze predominantly cool/blue-grey so distant mountains shift darker/bluer.
	var day_haze    := Color( 0.68, 0.78, 0.94 )          # cool blue-grey, daytime
	var sunset_haze_cool := Color( 0.43, 0.48, 0.60 )     # blue-grey dusk haze (mountain silhouette tone)
	var sunset_haze_warm := Color( 0.52, 0.38, 0.26 )     # subtle warm horizon tint
	var warm_mix : float = ( 1.0 - twilight_cool_bias ) * twilight_amount * 0.35
	var sunset_haze : Color = sunset_haze_cool.lerp( sunset_haze_warm, warm_mix )
	var night_haze  := Color( 0.02, 0.015, 0.04 )         # near-black at night
	var atmo_haze_color : Color = day_haze.lerp( sunset_haze, twilight_amount ).lerp( night_haze, night_amount )
	environment.environment.fog_light_color = atmo_haze_color
	
	# Sun scatter: keep this moderate at twilight.
	# High values can over-brighten distant terrain into white bands.
	environment.environment.fog_sun_scatter = lerpf( 0.03, 0.12, twilight_amount )
	
	# Density: higher than the original so closer mountains (~300 units) pick up haze,
	# but low enough that far mountains don't become fully sky-colored.
	# Peaks at sunset (Rayleigh scattering is stronger near the horizon at low sun).
	var base_density : float = 0.00030
	var sunset_boost : float = 0.00003 * twilight_amount
	var pre_sunset_reduction : float = pre_sunset_reduction_strength * pre_sunset_amount
	var night_reduction : float = 0.00016 * night_amount
	environment.environment.fog_density = clampf( base_density + sunset_boost - pre_sunset_reduction - night_reduction, 0.00008, 0.0010 )
	
	# Aerial perspective: how much the fog color is replaced by the sky shader's color.
	# Reduce this at twilight/night so mountains keep more of their own dark albedo.
	# Day: 0.62, Twilight: ~0.36, Night baseline: ~0.26.
	var aerial_amount : float = lerpf( 0.62, 0.36, twilight_amount )
	# Further reduce during pre-sunset hours to avoid bright/pale distant ridges.
	aerial_amount -= 0.06 * pre_sunset_amount
	aerial_amount = lerpf( aerial_amount, 0.26, night_amount )
	# Moonlit nights can lift aerial perspective slightly, but should stay dark.
	var moon_visibility : float = 0.0
	if is_instance_valid( moon ) :
		var moon_direction_for_fog = moon.to_global( Vector3( 0.0, 0.0, 1.0 ) ).normalized()
		var moon_above_horizon_for_fog : float = clamp( moon_direction_for_fog.y, 0.0, 1.0 )
		moon_visibility = moon_above_horizon_for_fog * get_lunar_phase_brightness()
	aerial_amount += night_amount * moon_visibility * 0.02
	aerial_amount = clampf( aerial_amount, 0.22, 0.62 )
	environment.environment.fog_aerial_perspective = aerial_amount
	
	# Extend fog depth end far enough that density alone governs the falloff curve
	# rather than a hard clamp at 2365 units (the scene file default) turning
	# everything beyond that distance into a pure sky-colored blob.
	environment.environment.fog_depth_end = 8000.0
	
	# Keep fog out of the sky itself (otherwise it muddies the sky shader output)
	environment.environment.fog_sky_affect = 0.0
	
	# No height fog — it creates colour artifacts on elevated distant geometry
	environment.environment.fog_height_density = 0.0
	
	# Always enabled; atmospheric perspective is never zero in real desert air
	environment.environment.fog_enabled = true
	environment.environment.volumetric_fog_enabled = volumetric_fog_user_enabled
	environment.environment.ambient_light_sky_contribution = ambient_sky_contribution
	_apply_advanced_rendering_toggles()
	_apply_tonemap_settings()
	
	# Calculate moon's ambient contribution based on phase, position, and weather
	var moon_ambient_contribution : float = 0.0
	if is_instance_valid( moon ) and night_amount > 0.1 :
		var moon_direction = moon.to_global( Vector3( 0.0, 0.0, 1.0 ) ).normalized()
		var moon_above_horizon : float = clamp( moon_direction.y, 0.0, 1.0 )
		var phase_brightness : float = get_lunar_phase_brightness()
		# Keep night scenes dark even under full moon; moonlight should lift contrast
		# subtly, not flatten silhouettes.
		moon_ambient_contribution = moon_above_horizon * phase_brightness * night_amount * weather_light_factor * 0.018
		moon_ambient_contribution = minf( moon_ambient_contribution, 0.008 )
	
	# Dynamic ambient light - brighter during day, dimmer at night but with moon contribution
	var day_ambient : float = 0.3
	var night_ambient : float = 0.003 + moon_ambient_contribution
	environment.environment.ambient_light_energy = lerpf( day_ambient, night_ambient, night_amount ) * ambient_energy_mult

	_update_glow( night_amount )
	
	# fog_amount export can boost haze further (e.g. dusty/smoky conditions)
	# The baseline atmospheric perspective above is always active.
	if fog_amount > 0.01:
		environment.environment.fog_density += fog_amount * 0.00015

## Bloom / glow, driven by the same day->night signal as the rest of the
## environment.  This is the single post-process pass that turns the camp
## generator's emissive night-light MultiMesh into a field of coloured points
## visible from the air (the "Black Rock City from a drone" look) at a cost that
## is independent of how many markers exist.  It also gives the IBC tanks and the
## sun/moon discs a soft halo.
##
## Tuned to avoid the washed-out "dirty contacts" haze that earlier glow setups
## produced:
##   - glow_bloom = 0            : only HDR-bright pixels bloom, never the whole frame.
##   - SCREEN blend (not additive): brightens toward the source colour, no blowout.
##   - fine levels 1-4 only      : compact halos around lights, not a wide grey veil.
##   - HDR threshold ramps HIGH by day (only the very bright sun disc passes, so
##     daytime terrain never fuzzes) -> LOWER at night (so the colourful camp
##     markers and the IBC glow bloom).  Intensity ramps the same way.
func _update_glow( night_amount : float ) -> void :
	if not is_instance_valid( environment ) :
		return
	var env : Environment = environment.environment
	if env == null :
		return

	# Static, day/night-independent shape of the bloom (idempotent — cheap to set).
	env.glow_enabled = glow_user_enabled
	env.glow_normalized = true
	env.glow_bloom = 0.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	env.glow_mix = 0.02
	env.glow_strength = 0.85
	env.glow_hdr_scale = 2.0
	# Cap how hard a single very-bright pixel (the sun) can bloom, so its halo
	# stays a tasteful flare instead of a giant white smear.
	env.glow_hdr_luminance_cap = 8.0
	# Fine mips (1-4) give each light a compact bright core.  The wide mips (5-6)
	# are what produce the soft surrounding "glow" halo — but they are also what
	# create a full-screen hazy veil by day, so they are ramped in by night only.
	env.set( "glow_levels/1", 1.0 )
	env.set( "glow_levels/2", 1.0 )
	env.set( "glow_levels/3", 0.7 )
	env.set( "glow_levels/4", 0.4 )
	env.set( "glow_levels/5", lerpf( 0.0, 0.6, night_amount ) )
	env.set( "glow_levels/6", lerpf( 0.0, 0.25, night_amount ) )
	env.set( "glow_levels/7", 0.0 )

	# Day -> subtle (essentially just a small sun halo); night -> the camp lights,
	# IBC glow and moon bloom strongly into points of light.
	env.glow_intensity = lerpf( 0.30, 1.4, night_amount ) * glow_intensity_mult
	# Day -> high threshold (only the very bright sun disc passes, so mid-tone
	# terrain never blooms); night -> low so the saturated emissive markers
	# (cores up to ~14.0) bloom into coloured halos.
	env.glow_hdr_threshold = lerpf( 1.5, 0.6, night_amount )

## Get moon brightness based on phase using realistic non-linear scaling
## Based on the visible illuminated fraction and opposition surge effect
## Returns 0.0 at new moon, 1.0 at full moon
func get_lunar_phase_brightness() -> float :
	return clock.get_lunar_phase_brightness()


## Cached in _update_environment(); read by VegetationEnvironmentSync autoload.
func get_vegetation_night_factor() -> float :
	return _vegetation_night_factor


func get_vegetation_sun_direction() -> Vector3 :
	return _vegetation_sun_direction


## Recompute seasonal phenology + snow cover for the current clock date.
## Cheap phenology (pure math) plus a throttled-by-frequency snow estimate.
func _update_seasonal() -> void :
	var lat : float = latitude
	_season_signals = SeasonModel.season_signals( day_of_year, lat )
	if _weather_service_node == null or not is_instance_valid( _weather_service_node ) :
		_weather_service_node = get_node_or_null( "/root/WeatherService" )
	_snow_amount = SeasonModel.estimate_snow_cover(
		_weather_service_node, month, day, day_time, lat
	)


## Seasonal phenology signals (leaf_coverage/autumn/bud/summer/winter), read by
## VegetationEnvironmentSync. Cached in _update_environment().
func get_season_signals() -> Dictionary :
	return _season_signals


## Weather-driven ground snow cover, 0..1. Read by VegetationEnvironmentSync and
## TerrainLoader to drive snow shaders.
func get_snow_amount() -> float :
	return _snow_amount


## Advance one calendar day and snap to that day's MEAN solar noon. The sun
## retraces its analemma over each year, and the year advances naturally from one
## to the next so every winter pulls that year's *real* historical weather (snow,
## etc.). Once we run past the newest complete-archive year we wrap back to the
## start of the recent historical window, cycling through distinct real years
## rather than replaying one.
##
## Holding a FIXED MEAN solar time (not apparent solar noon) is what makes the sun
## trace the figure-eight: the equation of time (up to ~±16 min ≈ ±4° of hour
## angle) then shows up as the sun's day-to-day east/west wander, while the
## declination drives the ±23.4° north/south swing. Snapping to apparent solar
## noon instead pins the hour angle to 0 and collapses the analemma to a vertical
## line — the bug this replaces.
func _step_analemma() -> void :
	var start_year : int = clock.year
	var cur : float = clock.get_absolute_hours()
	var next_midnight : float = ( floor( cur / 24.0 ) + 1.0 ) * 24.0
	clock.set_absolute_hours( next_midnight )
	# Let the year roll forward; only wrap once we exhaust real historical data
	# so the analemma keeps landing on years the weather archive actually covers.
	var bounds : Vector2i = _analemma_year_bounds()
	if clock.year > bounds.y :
		clock.year = bounds.x
		clock.month = 1
		clock.day = 1
	# When the calendar year changed, force WeatherService to refetch that year's
	# archive right away so snow/weather match the new year without poll lag.
	if clock.year != start_year :
		_notify_weather_year_changed()
	# Fixed mean solar noon: the sun sits on (or near) the meridian each frame; its
	# N/S declination swing plus E/W equation-of-time wander over the year is the
	# analemma.
	clock.day_time = clock.mean_solar_time_to_clock_time( 12.0 )
	_force_planet_update()
	_update()
	# Keep the white guide curve rebuilt for the current site and pinned to the
	# camera so it reads as painted on the sky dome.
	_ensure_analemma_path()
	_position_analemma_path()

# ==================== ANALEMMA GUIDE PATH ====================

## Show/hide the white analemma guide when ∞ mode toggles.
func _on_analemma_mode_changed( active: bool ) -> void :
	if Engine.is_editor_hint() or not is_inside_tree() :
		return
	if active :
		_ensure_analemma_path()
		if is_instance_valid( _analemma_path ) :
			_analemma_path.visible = true
			_position_analemma_path()
	elif is_instance_valid( _analemma_path ) :
		_analemma_path.visible = false

## Build (or rebuild after the observer moves) the year-long sun-path mesh. The
## shape depends on latitude/longitude, so it is cached against those and only
## regenerated when they change.
func _ensure_analemma_path() -> void :
	if Engine.is_editor_hint() or not is_inside_tree() :
		return
	if is_instance_valid( _analemma_path ) \
			and is_equal_approx( _analemma_path_lat, clock.latitude ) \
			and is_equal_approx( _analemma_path_lon, clock.longitude ) :
		return
	if not is_instance_valid( _analemma_path ) :
		_analemma_path = MeshInstance3D.new()
		_analemma_path.name = "AnalemmaPath"
		_analemma_path.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_analemma_path.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_analemma_path.visible = analemma_mode
		add_child( _analemma_path )
	_build_analemma_mesh()
	_analemma_path_lat = clock.latitude
	_analemma_path_lon = clock.longitude

## Sample the sun direction at mean solar noon for every day of the year on a
## throwaway clock (pure — never touches the live clock), then stroke it as one
## closed white line-strip at ANALEMMA_PATH_RADIUS.
func _build_analemma_mesh() -> void :
	var tc := CelestialClock.new()
	tc.latitude = clock.latitude
	tc.longitude = clock.longitude
	tc.planet_axial_tilt = clock.planet_axial_tilt
	tc.auto_dst = clock.auto_dst
	tc.manual_dst = clock.manual_dst
	tc.year = clock.year

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color( 1.0, 1.0, 1.0 )
	mat.vertex_color_use_as_albedo = true
	mat.disable_receive_shadows = true

	var mesh := ImmediateMesh.new()
	mesh.surface_begin( Mesh.PRIMITIVE_LINE_STRIP, mat )
	var days : int = 365
	if tc._is_leap_year( tc.year ) :
		days = 366
	# One extra vertex wrapping to day 1 closes the loop cleanly.
	for i in range( days + 1 ) :
		var doy : int = ( i % days ) + 1
		_set_clock_to_doy( tc, doy )
		tc.day_time = tc.mean_solar_time_to_clock_time( 12.0 )
		var dir : Vector3 = tc.get_sun_direction()
		mesh.surface_set_color( Color( 1.0, 1.0, 1.0 ) )
		mesh.surface_add_vertex( dir * ANALEMMA_PATH_RADIUS )
	mesh.surface_end()
	_analemma_path.mesh = mesh

## Set a clock's month/day from a 1-based day-of-year (uses the clock's own
## month-length rules so leap years are handled).
func _set_clock_to_doy( c: CelestialClock, doy: int ) -> void :
	var m : int = 1
	var d : int = doy
	while m < 12 :
		var dim : int = c.get_days_in_month( m, c.year )
		if d <= dim :
			break
		d -= dim
		m += 1
	c.month = m
	c.day = clampi( d, 1, c.get_days_in_month( m, c.year ) )

## Pin the guide's origin to the active camera so its direction-based vertices sit
## on the sky dome regardless of where the player walks.
func _position_analemma_path() -> void :
	if not is_instance_valid( _analemma_path ) :
		return
	var vp := get_viewport()
	if vp == null :
		return
	var cam := vp.get_camera_3d()
	if cam != null :
		_analemma_path.global_position = cam.global_position

## Inclusive [min, max] sim-year range the ∞ analemma view cycles through: the
## full weather archive, from 1940 (the ERA5 archive start) up to the newest
## complete year — extended FORWARD through any generated future weather so the
## analemma also scrubs the projected years with their synthesized weather
## (snow/cloud/temperature) instead of stopping at real history.
func _analemma_year_bounds() -> Vector2i :
	var hi : int = int( Time.get_date_dict_from_system().year ) - 1
	if _weather_service_node == null or not is_instance_valid( _weather_service_node ) :
		_weather_service_node = get_node_or_null( "/root/WeatherService" )
	if _weather_service_node != null and _weather_service_node.has_method( "generated_years" ) :
		for y_v in _weather_service_node.call( "generated_years" ) :
			hi = maxi( hi, int( y_v ) )
	var lo : int = mini( ANALEMMA_ARCHIVE_START_YEAR, hi )
	return Vector2i( lo, hi )

## Nudge WeatherService to refresh immediately for the current year instead of
## waiting up to its ~3 s location poll (keeps analemma weather in step).
func _notify_weather_year_changed() -> void :
	if _weather_service_node == null or not is_instance_valid( _weather_service_node ) :
		_weather_service_node = get_node_or_null( "/root/WeatherService" )
	if _weather_service_node != null and _weather_service_node.has_method( "notify_location_changed" ) :
		_weather_service_node.notify_location_changed( latitude, longitude )

func _update_shader() -> void :
	if is_instance_valid( environment ) :
		environment.environment.sky.sky_material.set_shader_parameter(
			"overwritten_time",
			( day_of_year * HOURS_IN_DAY + day_time ) * 100.0 if use_day_time_for_shader else 0.0
		)

# ==================== DEATH/RESPAWN SYSTEM ====================

## Connect all death zones in the scene
func _connect_death_zones() -> void :
	var death_zones = get_tree().get_nodes_in_group( "death_zone" )
	for zone in death_zones :
		if zone.has_signal( "player_died" ) :
			zone.player_died.connect( _on_player_died_with_message )

## Called when player dies with a custom message (e.g., death zone, fall damage)
func _on_player_died_with_message( message: String = "" ) -> void :
	if is_instance_valid( game_over_ui ) :
		game_over_ui.show_game_over( message )

## Respawn the player at the spawn position
func _respawn_player() -> void :
	if is_instance_valid( player ) :
		player.global_position = player_spawn_position
		player.rotation = player_spawn_rotation
		player.velocity = Vector3.ZERO
		# Reset fall tracking
		player.is_falling = false
		player.fall_start_height = player_spawn_position.y
		player.highest_point_during_fall = player_spawn_position.y
		if "void_reference_y" in player:
			player.void_reference_y = player_spawn_position.y
		# Re-capture mouse for player control
		Input.set_mouse_mode( Input.MOUSE_MODE_CAPTURED )
		if player.has_method( "_capture_mouse" ) :
			player._capture_mouse()

# ==================== VEHICLE/EUC SYSTEM ====================

## Setup interaction UI reference for the player
func _setup_interaction_ui() -> void :
	if is_instance_valid( player ) and is_instance_valid( interaction_ui ) :
		player.interaction_ui = interaction_ui
	if is_instance_valid( player ) and is_instance_valid( euc_ui ) :
		player.euc_ui = euc_ui


## Instances the global HUD toast stack under UILayer (once per scene tree).
func _setup_toast_ui() -> void :
	var ui_layer := get_node_or_null( "UILayer" )
	if ui_layer == null :
		return
	var existing := ui_layer.get_node_or_null( "ToastUI" )
	if existing != null :
		toast_ui = existing as ToastUI
		return
	toast_ui = ToastUI.new()
	toast_ui.name = "ToastUI"
	ui_layer.add_child( toast_ui )


## Shows a HUD toast. level: ToastUI.Level (INFO/OK/WARN/ERROR).
func show_toast( text: String, level: ToastUI.Level = ToastUI.Level.INFO, duration: float = 5.0 ) -> void :
	if is_instance_valid( toast_ui ) :
		toast_ui.show_toast( text, level, duration )


## Instances the F1 controls/tips overlay under UILayer (once per scene tree).
func _setup_help_overlay_ui() -> void :
	var ui_layer := get_node_or_null( "UILayer" )
	if ui_layer == null :
		return
	var existing := ui_layer.get_node_or_null( "HelpOverlayUI" )
	if existing != null :
		help_overlay_ui = existing as HelpOverlayUI
		return
	help_overlay_ui = HelpOverlayUI.new()
	help_overlay_ui.name = "HelpOverlayUI"
	ui_layer.add_child( help_overlay_ui )


const _UI_PREFS_CFG : String = "user://ui_prefs.cfg"

## Auto-opens the help overlay once on this PC's first boot, staggered a beat
## after any terrain-load overlay clears so the two full-screen modals never
## stack. No-op on every later boot (persists a "seen" flag).
func _maybe_show_first_run_help( attempts_left: int = 120 ) -> void :
	var cfg := ConfigFile.new()
	if cfg.load( _UI_PREFS_CFG ) == OK and bool( cfg.get_value( "help", "first_run_seen", false ) ) :
		return
	var ui_layer := get_node_or_null( "UILayer" )
	var loading := ui_layer != null and ui_layer.get_node_or_null( "TerrainLoadOverlay" ) != null
	if loading and attempts_left > 0 :
		get_tree().create_timer( 0.5 ).timeout.connect( _maybe_show_first_run_help.bind( attempts_left - 1 ), CONNECT_ONE_SHOT )
		return
	var cfg2 := ConfigFile.new()
	cfg2.load( _UI_PREFS_CFG )
	cfg2.set_value( "help", "first_run_seen", true )
	var err := cfg2.save( _UI_PREFS_CFG )
	if err != OK :
		push_warning( "UI prefs: could not write %s (err %d)" % [ _UI_PREFS_CFG, err ] )
	if is_instance_valid( help_overlay_ui ) :
		help_overlay_ui.open()
	_queue_first_run_hint_toasts()


func _queue_first_run_hint_toasts() -> void :
	var hints := [
		"Press G to open the system graph and wire up your power grid.",
		"Aim your crosshair at a solar array and press Interact to add it to your grid.",
		"Press F1 anytime for controls and tips.",
	]
	for i in hints.size() :
		var delay : float = 4.0 + float( i ) * 5.0
		get_tree().create_timer( delay ).timeout.connect(
			show_toast.bind( hints[ i ], ToastUI.Level.INFO, 6.0 ), CONNECT_ONE_SHOT )


func _setup_baked_placed_props_ui() -> void :
	if find_child( "TerrainLoader", true, false ) != null :
		return
	_ensure_placed_props_ui()


func _ensure_placed_props_ui() -> void :
	if _placed_props_ui != null and is_instance_valid( _placed_props_ui ) :
		return
	var ui_layer := get_node_or_null( "UILayer" )
	if ui_layer == null :
		return
	var existing := ui_layer.get_node_or_null( "PlacedPropsUI" )
	if existing != null :
		_placed_props_ui = existing as Control
		return
	var edit_ui := Control.new()
	edit_ui.name = "PlacedPropsUI"
	edit_ui.set_anchors_and_offsets_preset( Control.PRESET_FULL_RECT )
	edit_ui.set_script( PLACED_PROPS_UI_SCRIPT )
	ui_layer.add_child( edit_ui )
	_placed_props_ui = edit_ui

## Setup crisis event UI
func _setup_crisis_event_ui() -> void :
	# Create crisis event UI if it doesn't exist
	if not is_instance_valid( crisis_event_ui ) :
		var ui_scene := preload( "res://crisis_events/crisis_event_ui.tscn" )
		if ui_scene != null :
			var ui := ui_scene.instantiate()
			if ui != null :
				# Add to UILayer
				var ui_layer := get_node_or_null( "UILayer" )
				if ui_layer != null :
					ui_layer.add_child( ui )
					crisis_event_ui = ui
				else :
					# Fallback: add directly to main
					add_child( ui )
					crisis_event_ui = ui

## Connect all EUC/vehicle nodes to the player
func _connect_vehicles() -> void :
	# Find all nodes with the euc_vehicle.gd script attached
	_connect_vehicles_recursive( self )
	# Also connect charging stations
	_connect_charging_stations_recursive( self )

func _connect_vehicles_recursive( node : Node ) -> void :
	if node == null :
		return
	
	# Check if this node has vehicle signals
	if node.has_signal( "player_entered_range" ) and node.has_signal( "player_exited_range" ) :
		node.player_entered_range.connect( _on_vehicle_player_entered )
		node.player_exited_range.connect( _on_vehicle_player_exited )
	
	for child in node.get_children() :
		_connect_vehicles_recursive( child )

func _connect_charging_stations_recursive( node : Node ) -> void :
	if node == null :
		return
	
	# Check if this node has charging station signals
	if node.has_signal( "euc_entered_range" ) and node.has_signal( "euc_exited_range" ) :
		node.euc_entered_range.connect( _on_charging_station_euc_entered )
		node.euc_exited_range.connect( _on_charging_station_euc_exited )
	
	for child in node.get_children() :
		_connect_charging_stations_recursive( child )

func _on_vehicle_player_entered( vehicle : Node3D ) -> void :
	if is_instance_valid( player ) and player.has_method( "on_vehicle_nearby" ) :
		player.on_vehicle_nearby( vehicle )

func _on_vehicle_player_exited( vehicle : Node3D ) -> void :
	if is_instance_valid( player ) and player.has_method( "on_vehicle_left_range" ) :
		player.on_vehicle_left_range( vehicle )

func _on_charging_station_euc_entered( station : Node3D, _euc : Node3D ) -> void :
	if is_instance_valid( player ) and player.has_method( "on_charging_station_nearby" ) :
		player.on_charging_station_nearby( station )

func _on_charging_station_euc_exited( station : Node3D ) -> void :
	if is_instance_valid( player ) and player.has_method( "on_charging_station_left_range" ) :
		player.on_charging_station_left_range( station )

# ==================== FIRE EXTINGUISHER PICKUP SYSTEM ====================

## Spawn fire extinguisher pickups at strategic locations in buildings
func _spawn_fire_extinguisher_pickups() -> void :
	if Engine.is_editor_hint() :
		return
	
	var gr_pickups := GameplayRulesImpl.from_node( self )
	if gr_pickups == null or not gr_pickups.is_fire_tools_enabled() :
		return
	
	var pickup_scene := load( "res://player_tools/fire_extinguisher_pickup.tscn" ) as PackedScene
	if pickup_scene == null :
		push_warning( "[Main] Could not load fire extinguisher pickup scene" )
		return
	
	var pickup_locations : Array = []
	if scenario_config != null and not scenario_config.extinguisher_pickups.is_empty() :
		pickup_locations = scenario_config.extinguisher_pickups
	else :
		# Define pickup locations (wall-mounted positions in buildings)
		# Format: Vector3 position, String display name
		pickup_locations = [
		# LinkageLab area - near charging station
		{ "position": Vector3( -7.0, 1.2, 21.0 ), "name": "LinkageLab Extinguisher" },
		# Near the Mars Aerial structure entrance
		{ "position": Vector3( -15.0, 1.2, 38.0 ), "name": "Mars Aerial Extinguisher 1" },
		# Another spot in the Mars Aerial area
		{ "position": Vector3( -10.0, 1.2, 45.0 ), "name": "Mars Aerial Extinguisher 2" },
		# Near Appa / golf cart area
		{ "position": Vector3( -18.0, 1.2, 55.0 ), "name": "Workshop Extinguisher" },
		]

	for loc in pickup_locations :
		var pickup := pickup_scene.instantiate() as Node3D
		if pickup != null :
			if pickup.has_method( "set" ) and "display_name" in pickup :
				pickup.display_name = loc["name"]
			# add_child BEFORE setting global_position — global transforms require the
			# node to be inside the tree (otherwise !is_inside_tree() warnings).
			add_child( pickup )
			pickup.global_position = loc["position"]

# ==================== CRISIS EVENT SYSTEM ====================

## Setup crisis event manager and scan for burnable meshes
func _setup_crisis_events() -> void :
	if Engine.is_editor_hint() :
		return
	
	# Create crisis event manager if it doesn't exist
	if not is_instance_valid( crisis_event_manager ) :
		var manager_script := load( "res://crisis_events/crisis_event_manager.gd" ) as GDScript
		if manager_script != null :
			var manager: Node = manager_script.new()
			manager.name = "CrisisEventManager"
			add_child( manager )
			crisis_event_manager = manager
	
	# Initialize crisis event manager
	if is_instance_valid( crisis_event_manager ) :
		# Register fire event type
		var fire_event_script := load( "res://crisis_events/fire/fire_event.gd" ) as GDScript
		if fire_event_script != null :
			crisis_event_manager.register_event_type( fire_event_script, 1.0, "Fire" )
		
		# Add to group for easy access
		crisis_event_manager.add_to_group( "crisis_event_manager" )
	
	var gr_crisis := GameplayRulesImpl.from_node( self )
	if gr_crisis == null or not gr_crisis.is_crisis_events_enabled() :
		return
	
	if scenario_config != null and not scenario_config.burnable_scan_node_paths.is_empty() :
		for path_str in scenario_config.burnable_scan_node_paths :
			var scan_root : Node = get_node_or_null( NodePath( path_str ) )
			if scan_root == null :
				scan_root = get_node_or_null( path_str )
			if is_instance_valid( scan_root ) :
				_scan_for_burnables( scan_root )
		return
	
	if is_instance_valid( structure ) :
		_scan_for_burnables( structure )
	
	var mars_aerial := get_node_or_null( "Mars 2026 - Aerial Located" )
	if is_instance_valid( mars_aerial ) :
		_scan_for_burnables( mars_aerial )

## Recursively scan for MeshInstance3D nodes and add BurnableComponent
func _scan_for_burnables( node : Node ) -> void :
	if node == null :
		return
	
	# Check if this is a MeshInstance3D
	if node is MeshInstance3D :
		var mesh_inst : MeshInstance3D = node as MeshInstance3D
		
		# Check if it already has a BurnableComponent
		var has_burnable := false
		for child in mesh_inst.get_children() :
			if child is BurnableComponent :
				has_burnable = true
				break
		
		# Check if it uses wood material
		if not has_burnable :
			var is_wood := _check_if_wood_material( mesh_inst )
			
			# Add BurnableComponent if it's wood
			if is_wood :
				var burnable_script := load( "res://crisis_events/fire/burnable_component.gd" ) as GDScript
				if burnable_script != null :
					var burnable_comp: Node3D = burnable_script.new()
					mesh_inst.add_child( burnable_comp )
					burnable_comp.name = "BurnableComponent"
	
	# Recursively check children
	for child in node.get_children() :
		_scan_for_burnables( child )

## Check if a mesh instance uses wood/plywood material
func _check_if_wood_material( mesh_inst : MeshInstance3D ) -> bool :
	# Check surface material overrides
	for i in range( mesh_inst.get_surface_override_material_count() ) :
		var mat := mesh_inst.get_surface_override_material( i )
		if mat != null :
			if _check_material_for_plywood( mat ) :
				return true
	
	# Check mesh material
	if mesh_inst.mesh != null :
		var mesh_mat := mesh_inst.mesh.surface_get_material( 0 )
		if mesh_mat != null :
			if _check_material_for_plywood( mesh_mat ) :
				return true
	
	return false

## Check if a material uses plywood texture
func _check_material_for_plywood( mat : Material ) -> bool :
	if mat == null :
		return false
	
	# Check material resource path
	var mat_path := mat.resource_path
	if "Wood034" in mat_path or "plywood" in mat_path.to_lower() :
		return true
	
	# Check if material uses the plywood texture
	if mat is StandardMaterial3D :
		var std_mat := mat as StandardMaterial3D
		# Check albedo texture
		if std_mat.albedo_texture != null :
			var tex_path := std_mat.albedo_texture.resource_path
			if "Mars 2026 - Aerial Located_14" in tex_path :
				return true
			if "Wood034" in tex_path or "plywood" in tex_path.to_lower() :
				return true
	
	return false

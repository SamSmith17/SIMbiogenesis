extends Control

## Solar power and battery UI with power consumption tracking.
## Simulates a battery bank that charges from solar and discharges to loads.
## Can optionally sync with Home Assistant entities for real data.

# Home Assistant entity bindings (leave empty to use simulated values)
@export_group("Home Assistant Integration")
@export var ha_battery_soc_entity: String = ""  ## HA entity for battery state of charge (expects 0-100%)
@export var ha_load_entity: String = ""  ## HA entity for current power load (expects watts or kW)
@export var ha_solar_entity: String = ""  ## HA entity for solar production (expects watts or kW)
@export var ha_daily_solar_entity: String = ""  ## HA entity for daily solar production (expects kWh)
@export var ha_solar_energy_entity: String = ""  ## HA entity for solar energy (kWh) - used for historical graph data
@export var ha_additional_subscribe_entities: PackedStringArray = []  ## Extra HA entities to auto-subscribe (monitoring only)
@export var ha_values_in_watts: bool = true  ## If true, HA load/solar values are in watts; if false, in kW

# Weather station entity bindings (Ecowitt / Home Assistant)
@export_group("Weather Station Integration")
@export var ha_solar_radiation_entity: String = ""  ## HA entity for solar radiation (W/m²)
@export var ha_lux_entity: String = ""  ## HA entity for light level (lux)
@export var ha_rain_rate_entity: String = ""  ## HA entity for rain rate (mm/h or in/h)
@export var ha_rain_state_entity: String = ""  ## HA entity for rain state (raining/not raining)
@export var ha_temperature_entity: String = ""  ## HA entity for outdoor temperature (°C or °F)
@export var ha_wind_speed_entity: String = ""  ## HA entity for wind speed (m/s or mph)
@export var ha_rain_rate_in_mm: bool = true  ## If true, rain rate is in mm/h; if false, in/h
@export var ha_temp_in_celsius: bool = true  ## If true, temperature is in °C; if false, °F
@export var ha_wind_in_ms: bool = true  ## If true, wind speed is in m/s; if false, mph

@onready var title_label : Label = $Panel/MarginContainer/VBoxContainer/TitleLabel
@onready var scoreboard_today : Label = $Panel/MarginContainer/VBoxContainer/ScoreboardRow/ColToday/ScoreboardToday
@onready var scoreboard_prev : Label = $Panel/MarginContainer/VBoxContainer/ScoreboardRow/ColPrev/ScoreboardPrev
@onready var scoreboard_best : Label = $Panel/MarginContainer/VBoxContainer/ScoreboardRow/ColBest/ScoreboardBest
@onready var scoreboard_best_hdr : Label = $Panel/MarginContainer/VBoxContainer/ScoreboardRow/ColBest/Hdr3
@onready var capture_label : Label = $Panel/MarginContainer/VBoxContainer/CaptureLabel
@onready var battery_bar : ProgressBar = $Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryBar
@onready var battery_percent : Label = $Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryPercent
@onready var battery_kwh : Label = $Panel/MarginContainer/VBoxContainer/BatteryKwhLabel
@onready var solar_value : Label = $Panel/MarginContainer/VBoxContainer/SolarContainer/SolarValue
@onready var aux_value : Label = $Panel/MarginContainer/VBoxContainer/AuxContainer/AuxValue
@onready var pot_icon : Label = $Panel/MarginContainer/VBoxContainer/PotentialContainer/PotIcon
@onready var potential_value : Label = $Panel/MarginContainer/VBoxContainer/PotentialContainer/PotentialValue
@onready var potential_label : Label = $Panel/MarginContainer/VBoxContainer/PotentialContainer/PotentialLabel
@onready var load_value : Label = $Panel/MarginContainer/VBoxContainer/LoadContainer/LoadValue
@onready var net_value : Label = $Panel/MarginContainer/VBoxContainer/NetContainer/NetValue
@onready var gen_value : Label = $Panel/MarginContainer/VBoxContainer/GenContainer/GenValue
@onready var net_icon : Label = $Panel/MarginContainer/VBoxContainer/NetContainer/NetIcon
# Daily kWh column (TODAY): counts up from local midnight, read off the
# EnergyTimeline so it rewinds with the clock like the battery does.
@onready var solar_today : Label = $Panel/MarginContainer/VBoxContainer/SolarContainer/SolarToday
@onready var aux_today : Label = $Panel/MarginContainer/VBoxContainer/AuxContainer/AuxToday
@onready var potential_today : Label = $Panel/MarginContainer/VBoxContainer/PotentialContainer/PotentialToday
@onready var gen_today : Label = $Panel/MarginContainer/VBoxContainer/GenContainer/GenToday
@onready var load_today : Label = $Panel/MarginContainer/VBoxContainer/LoadContainer/LoadToday
@onready var net_today : Label = $Panel/MarginContainer/VBoxContainer/NetContainer/NetToday
@onready var status_label : Label = $Panel/MarginContainer/VBoxContainer/StatusLabel
@onready var solar_graph : Control = $Panel/MarginContainer/VBoxContainer/SolarGraphContainer/SolarGraph
@onready var graph_peak_label : Label = $Panel/MarginContainer/VBoxContainer/SolarGraphContainer/GraphPeakLabel

# Entity link popup (created dynamically)
var _entity_link_popup: Window = null
var _entity_link_input: LineEdit = null
var _entity_link_target: String = ""  # Which field we're linking (battery_soc, load, solar, daily_solar, solar_energy)

# Historical data tracking
var _history_loaded: bool = false
var _history_request_pending: bool = false

# Graph title for click-to-link
@onready var graph_title : Label = $Panel/MarginContainer/VBoxContainer/GraphTitleContainer/GraphTitle

# Solar panel configuration - user-adjustable via settings panel
var PANEL_COUNT : int = 18
var PANEL_WATTAGE : float = 220.0
var PEAK_CAPACITY_KW : float = 3.96  # Recomputed when count/wattage changes

# Inverter clipping - PowMR LVM5K has 5 kW max solar input
var INVERTER_MAX_SOLAR_KW : float = 4.4

# Battery configuration
var BATTERY_CAPACITY_KWH : float = 16.0
const CHARGE_EFFICIENCY : float = 0.95  # Charging losses
const DISCHARGE_EFFICIENCY : float = 0.95  # Discharging losses
var MIN_BATTERY_PERCENT : float = 10.0  # Hard discharge floor (battery chemistry protection)

# SOC hysteretic protection — shut off AC output at shutdown %, restore at resume %
var battery_soc_shutdown_pct  : float = 10.0   # Trip inverter output off when SOC hits this
var battery_soc_resume_pct    : float = 20.0   # Re-enable output when SOC recovers to this
var _soc_protect_active       : bool  = false  # True while in low-SOC lockout

# Inverter overload protection (measured in real time, not simulation time)
var inverter_overload_watts    : float = 3500.0  # AC load trip threshold (W)
var inverter_overload_duration : float = 10.0    # Seconds above threshold before shutdown
var inverter_lockout_duration  : float = 30.0    # Seconds to remain off after overload trip
var _inverter_overload_elapsed : float = 0.0
var _inverter_lockout_remaining: float = 0.0

# Solar constants
const SOLAR_CONSTANT : float = 1361.0
const STC_IRRADIANCE : float = 1000.0

# Panel orientation (Bombay Beach, CA ~33°N latitude)
var panel_tilt_degrees : float = 0.0  # Horizontal by default; user-adjustable via settings
var panel_azimuth_degrees : float = 180.0  # Due south

# System efficiency factors (PowMR LVM5K inverter + 220W panels)
const INVERTER_EFFICIENCY : float = 0.93
const WIRING_LOSSES : float = 0.97
const MISMATCH_LOSSES : float = 0.97
const SOILING_FACTOR : float = 0.93  # Higher desert dust at Bombay Beach
const DEGRADATION : float = 0.99

# Real-world calibration factor derived from spring equinox field data (Bombay Beach, CA).
# Accounts for site-specific atmospheric haze (Salton Sea), panel quality vs nameplate,
# PowMR MPPT tracking losses, and installation-specific shading/orientation.
var SYSTEM_CALIBRATION : float = 0.85

# Temperature
const TEMP_COEFFICIENT : float = -0.004
const NOCT : float = 45.0

# High-accuracy solar physics mode (Meeus SPA + real GHI + optional shadow raycast)
var _high_accuracy_physics : bool = false
var _shadow_raycast_enabled : bool = false   # 3D raycast for terrain/vegetation shadow
var _shadow_sample_height : float = 4.0      # metres above world origin for the ray origin

# Weather simulation (affects solar output)
# 0 = clear sky, 1 = fully overcast (no direct sun)
enum WeatherType { CLEAR, PARTLY_CLOUDY, CLOUDY, RAINY }
var weather : WeatherType = WeatherType.CLEAR
var cloud_cover : float = 0.0  # 0.0 to 1.0 - instantaneous cloud factor
var _cloud_noise_time : float = 0.0
var _base_cloud_cover : float = 0.0  # Base cloud cover set by slider or weather button (0-1)
var _slider_is_driving : bool = false  # Suppress slider sync while user is dragging

# Meteorological cloud cover thresholds (oktas-based METAR scale)
const CLOUD_THRESHOLD_CLEAR_MAX : float = 0.20       # 0%-10%  -> Clear (0-1 okta)
const CLOUD_THRESHOLD_PARTLY_MAX : float = 0.50       # 10%-50% -> Partly Cloudy (2-4 oktas)
const CLOUD_THRESHOLD_CLOUDY_MAX : float = 0.90       # 50%-90% -> Cloudy/Broken (5-7 oktas)
# 90%-100% -> Overcast/Rainy (8 oktas)

# Representative cloud cover values when cycling weather via button
const CLOUD_REPR_CLEAR : float = 0.00
const CLOUD_REPR_PARTLY : float = 0.30
const CLOUD_REPR_CLOUDY : float = 0.70
const CLOUD_REPR_RAINY : float = 0.95
const PRECIP_RAIN_THRESHOLD_MMH : float = 0.01  # Open-Meteo hourly precipitation (mm)
const WIND_DISPLAY_LERP_SPEED : float = 1.25

# Rain / snow VFX (PrecipitationVfx on Main) + lightning
var _precip_vfx : PrecipitationVfx
var _lightning_vfx : LightningVfx
var daily_rain_inches : float = 0.0  # Current day's rain amount in inches
var rain_rate_per_hour : float = 0.0  # Inches per hour for current rain event
var is_ground_muddy : bool = false
var _last_rain_day : int = -1
const MUD_THRESHOLD_INCHES : float = 0.25  # Rain amount that causes mud
const PLAYER_MUD_SPEED_FACTOR : float = 0.25  # 1/4 speed when muddy

# ==================== AUTONOMOUS WEATHER SIMULATION ====================
# Simulates realistic weather patterns for Bombay Beach, CA (hot desert, BWh).
# Data interface: _wx_sim_cloud_cover holds the simulation's cloud cover target.
# In a future implementation, historical HA data can override this value when
# running backwards in time, providing seamless playback of recorded weather.

var _wx_sim_enabled : bool = true  # Synthetic weather sim fallback (no real data / offline)
## True once the user picks weather manually (button or slider). While false,
## real Open-Meteo archive weather drives the sky by default. Reset when the
## user returns to Auto mode.
var _user_weather_manual_override : bool = false
var _wx_sim_cloud_cover : float = 0.03  # Simulation's current cloud cover target (0-1)
var _wx_sim_hours_in_state : float = 0.0  # Hours spent in the current weather state
var _wx_sim_state_duration : float = 24.0  # Hours the current state should last
var _wx_sim_last_transition_day : int = -1

# Bombay Beach monthly climate data (index 0 = January, 11 = December)
# Mean cloud cover fraction derived from Salton Sea / Imperial Valley observations
const _WX_MONTHLY_CLOUD_COVER := [
	0.22, # Jan - winter fronts, highest cloud cover
	0.20, # Feb
	0.15, # Mar - drying out
	0.10, # Apr
	0.07, # May
	0.06, # Jun - peak summer, nearly always clear
	0.12, # Jul - monsoon moisture pulses
	0.14, # Aug - monsoon peak
	0.09, # Sep - monsoon fading
	0.08, # Oct
	0.14, # Nov - fall fronts begin
	0.20, # Dec - winter pattern
]
# Monthly probability of a rain event occurring on any given day
const _WX_MONTHLY_RAIN_CHANCE := [
	0.06, # Jan
	0.05, # Feb
	0.03, # Mar
	0.01, # Apr
	0.005, # May
	0.002, # Jun
	0.04, # Jul - monsoon thunderstorms
	0.05, # Aug
	0.03, # Sep
	0.01, # Oct
	0.03, # Nov
	0.05, # Dec
]
# Typical duration ranges in hours for each weather state [min, max]
const _WX_DURATION_CLEAR := Vector2(6.0, 72.0)
const _WX_DURATION_PARTLY := Vector2(3.0, 18.0)
const _WX_DURATION_CLOUDY := Vector2(2.0, 12.0)
const _WX_DURATION_RAINY := Vector2(1.0, 6.0)

# Original player speeds (stored when mud starts)
var _original_player_move_speed : float = -1.0
var _original_player_sprint_speed : float = -1.0

# Ground material references for wetness effect
var _ground_materials : Array[StandardMaterial3D] = []
var _original_ground_roughness : Array[float] = []
var _original_ground_albedo : Array[Color] = []

# Baseline load (always-on devices: fridge, network, etc.)
const BASELINE_LOAD_KW : float = 0.03  # Legacy constant — graph wired loads replace this
const _GRAPH_AC_LOAD_SCRIPT := preload("res://system_graph/graph_ac_load.gd")

# State tracking
var current_solar_kw : float = 0.0
var _raw_solar_kw : float = 0.0  # Solar before battery-full throttling
## Sum of non-solar EnergySource outputs (wind, hydro, …) from the
## "energy_sources" group; included in the battery/net energy balance.
var current_aux_generation_kw : float = 0.0
## Live DC generation (kW) summed from graph DC-electricity generators/wind/
## hydro items actually wired into a battery, pushed by SystemGraphView's
## DcPowerWiring aggregator each ~0.25s energy-sync tick (see
## system_graph/dc_power_wiring.gd). Folded into the aux term at point of use
## (not merged into current_aux_generation_kw itself, which _poll_aux_generation()
## resets every call on its own cadence) so the two channels don't clobber
## each other. Not persisted — re-derived every tick, same as
## current_aux_generation_kw.
var current_graph_dc_kw : float = 0.0
var current_load_kw : float = 0.0
var battery_kwh_stored : float = 8.0  # Start at 50% of 16 kWh
## Set by apply_save_state: the next graph capacity sync is initialisation (see
## apply_from_graph) and must keep the restored kWh.
var _soc_restored_pending := false
var last_time : float = -1.0

## Reversible SOC render-cache. Forward sim time appends integrated samples;
## scrubbing backward reads SOC back from the cache (the battery "uncharges").
## See core/energy_timeline.gd.
var energy_timeline := EnergyTimeline.new()
## Clock position of the previous _update_battery (forward-vs-backward test).
var _battery_last_abs_h: float = -INF
## How far live net power may drift from the cached sample before the cached
## future is thrown away and re-integrated (kW).
const BATTERY_CACHE_DIVERGE_KW: float = 0.05
var _power_available : bool = true
var _ac_shutdown_reason : String = ""
var _last_energy_day : int = -1

# ---- Observed-vs-simulated comparison (NLE batch render) ----
## Load source for batch-rendered simulated battery.
enum RenderLoadMode { CSV, MODELED }
var _render_load_mode : int = RenderLoadMode.CSV
## Resampled observed datastream (core/observed_series.gd) — null until imported.
var _observed_series : RefCounted = null
## Batch-rendered simulated curve over the selected range (separate EnergyTimeline).
var _sim_series := EnergyTimeline.new()
var _sim_series_ready : bool = false
var _sim_render_start_abs : float = 0.0
var _sim_render_end_abs : float = 0.0
## Chunked render driver (core/batch_renderer.gd), created lazily as a child.
var _batch_renderer : Node = null
## CSV clip loader for the observed track (separate from CsvPlaybackUI's player).
var _clip_player : Node = null
## Observed datastream span on the absolute-hours axis (NAN until imported).
var _observed_start_abs : float = NAN
var _observed_end_abs : float = NAN
var _observed_source_path : String = ""
## User in/out selection on the timeline (defaults to the full observed span).
var _sel_start_abs : float = NAN
var _sel_end_abs : float = NAN
## Split-screen observed-vs-simulated compare mode active.
var _compare_active : bool = false

## Emitted when the observed clip is (re)loaded — timeline UI redraws its track.
signal observed_clip_changed()
## Emitted on render start/progress/complete and compare toggle — UI refresh.
signal render_state_changed()

# Daily energy counters (kWh), integrated from power with explicit time deltas.
# These remain accurate even if simulation sampling frequency changes.
var daily_solar_generated_kwh : float = 0.0
var daily_aux_generated_kwh : float = 0.0
var daily_load_consumed_kwh : float = 0.0
## What the array could have made today (the "raw" channel: before battery-
## full curtailment and the DC caps) — the denominator of the capture score.
var daily_potential_kwh : float = 0.0
## A CSV clip's own "daily_load" reading wins over the timeline while mapped.
var _csv_daily_load_override : float = -1.0
## The day the scoreboard last counted (-1 = not yet since load).
var _scoreboard_day_start : float = -1.0
var daily_battery_charge_kwh : float = 0.0
var daily_battery_discharge_kwh : float = 0.0
## Completed sim-day total for the previous calendar sim day (for scoreboard)
var yesterday_solar_kwh : float = 0.0
## Best single-day kWh (sim) seen so far this session
var best_day_solar_kwh : float = 0.0

# 24-hour solar history for graph (one sample per simulated hour)
var solar_history : Array[float] = []
var load_history : Array[float] = []
var history_start_hour : int = 0  # The hour at index 0
const HISTORY_SIZE : int = 24

## CSV playback: distinct from live HA (📡). Mapped roles show 📂 during playback.
var _csv_playback_active: bool = false
var _csv_linked_roles: Dictionary = {}
var _csv_graph_source_path: String = ""

## Signal emitted when power availability changes (battery at minimum)
signal power_availability_changed(available: bool)
## Emitted when low-SOC or inverter overload cuts AC output (true = shutdown active).
signal ac_shutdown_changed(active: bool, reason: String)

var main_node : Node = null
var _cached_time_ui : Control = null
var _time_ui_lookup_ms : int = -100000

# Home Assistant integration
var ha_client: Node = null
var _ha_battery_soc_override: float = -1.0  # -1 = not overridden
var _ha_load_override: float = -1.0  # -1 = not overridden
var _ha_solar_override: float = -1.0  # -1 = not overridden
## Set by SystemGraphView when a controller node is destroyed by over-voltage fault.
var _graph_controller_destroyed: bool = false
## Delivered-power cap (W) from graph DC wiring; −1 = no cap. See
## set_graph_dc_limit_w / SystemGraphView._tick_dc_throttle.
var _graph_dc_limit_w: float = -1.0
## Per-controller caps from the graph's DC wiring, as a FUNCTION of the array's
## raw output (set_graph_dc_caps): [{frac, limit_w}] + the unrouted share. The
## delivered PV is sum(min(frac*raw, limit)) + unrouted*raw at ANY instant, so
## the live tick, the challenge bake and the controller cards all apply one
## rule. (A single watt figure frozen at the bake's first tick capped a whole
## day at whatever the sun was doing when Run was pressed.)
var _graph_dc_caps: Array = []
var _graph_dc_unrouted_frac: float = 1.0
var _graph_dc_caps_active: bool = false
## Per-panel geometric shade of the graph's site-placed PV
## (set_graph_pv_shade, GraphSolarShading): [{wmp, group, pos, s}] + the whole
## array's Wmp. The array output is scaled by the Wmp-weighted factor and the
## caps' shares re-split by it, live and in the batch render alike, so a shaded
## panel lowers what the battery gets — not just its own card.
var _pv_shade_receivers: Array = []
var _pv_shade_total_wmp: float = 0.0
## Array shade from the live factors (GraphSolarShading.array_shade); {} = none.
var _pv_shade_live: Dictionary = {}
## Counts SolarUI's 10 Hz sim ticks — the graph view syncs its cards when it
## moves, so every readout on a frame comes from the same tick.
var sim_tick_serial: int = 0
## Challenge playback: battery reads the baked _sim_series at the playhead.
var _playback_series_active: bool = false
## Tutorial runs: force a cloudless day (see _weather_at_abs).
var _clear_sky_override: bool = false
var _ha_daily_solar_override: float = -1.0  # -1 = not overridden (kWh)
var _ha_connected: bool = false

# Live Mode support
var _live_mode_active: bool = false  # Off by default; enable via timeline settings for HA 1× sync
var _simulation_mode: bool = false  # True when simulating forward from live data
var _sim_start_battery_soc: float = -1.0  # Starting battery SOC for simulation
var _sim_start_load_kw: float = -1.0  # Starting load for simulation
var _sim_start_solar_kw: float = -1.0  # Starting solar for simulation

# Weather Live Mode support
var _weather_live_mode: bool = false  # When true, use HA weather data; when false, use simulation
var _ha_solar_radiation_override: float = -1.0  # W/m² from HA (-1 = not overridden)
var _ha_lux_override: float = -1.0  # Lux from HA (-1 = not overridden)
var _ha_rain_rate_override: float = -1.0  # mm/h from HA (-1 = not overridden)
var _ha_rain_state_override: int = -1  # 0 = not raining, 1 = raining, -1 = not overridden
var _ha_temperature_override: float = -999.0  # °C from HA (-999 = not overridden)
var _ha_wind_speed_override: float = -1.0  # m/s from HA (-1 = not overridden)

# Simulated weather data (for display when not in live mode)
var _simulated_solar_radiation: float = 0.0  # W/m²
var _simulated_lux: float = 0.0  # Lux
var _simulated_rain_rate: float = 0.0  # mm/h
var _simulated_temperature: float = 25.0  # °C
var _simulated_wind_speed: float = 2.0  # m/s
var _target_wind_speed: float = 2.0  # m/s — smoothed into _simulated_wind_speed for display
var _simulated_wind_direction: float = NAN  # degrees, NAN = unknown
var _simulated_humidity: float = NAN       # percent, NAN = unknown
var _simulated_rain_24h_mm: float = NAN    # mm, NAN = unknown

# ---------------------------------------------------------------------------
# System graph: embedded mirror of the main SolarUI (no duplicate simulation)
# ---------------------------------------------------------------------------
## When true, this instance only mirrors the node set in set_graph_embed_mirror_from().
var _is_graph_embed: bool = false
var _graph_embed_mirror_from: Node = null
var _graph_embed_sync_acc: float = 0.0
const _GRAPH_EMBED_SYNC_INTERVAL: float = 0.1


func set_graph_embed_mirror_from(n: Node) -> void:
	_graph_embed_mirror_from = n
	_is_graph_embed = true


func _graph_embed_setup_mirror_mode() -> void:
	if solar_graph and not solar_graph.is_connected("draw", Callable(self, "_draw_solar_graph")):
		solar_graph.draw.connect(_draw_solar_graph)
	solar_history.clear()
	load_history.clear()
	for i in range(HISTORY_SIZE):
		solar_history.append(0.0)
		load_history.append(0.0)


## Copies Label / ProgressButton visuals from the main panel; copies graph state, redraws.
func _graph_embed_sync_from_source() -> void:
	var src: Node = _graph_embed_mirror_from
	if not is_instance_valid(src):
		return
	_graph_embed_copy_node_visuals(src, self)
	if src is Control:
		var sh: Variant = (src as Control).get("solar_history")
		if sh is Array:
			solar_history = (sh as Array).duplicate()
		var lh: Variant = (src as Control).get("load_history")
		if lh is Array:
			load_history = (lh as Array).duplicate()
		main_node = (src as Control).get("main_node") as Node
	if solar_graph:
		solar_graph.queue_redraw()


func _graph_embed_copy_node_visuals(a: Node, b: Node) -> void:
	if b is Control and b.name in ["ExportButton", "WeatherLinkButton"]:
		return
	if a is Label and b is Label:
		var al := a as Label
		var bl := b as Label
		bl.text = al.text
		bl.tooltip_text = al.tooltip_text
		# Resolved color (includes theme overrides); get_theme_color_override() is not on Label in all Godot versions.
		if al.has_theme_color_override("font_color"):
			bl.add_theme_color_override("font_color", al.get_theme_color("font_color"))
		return
	if a is ProgressBar and b is ProgressBar:
		var ap := a as ProgressBar
		var bp := b as ProgressBar
		bp.value = ap.value
		bp.max_value = ap.max_value
		bp.modulate = ap.modulate
		return
	if a is BaseButton and b is BaseButton:
		var ab := a as BaseButton
		var bb := b as BaseButton
		bb.text = ab.text
		bb.tooltip_text = ab.tooltip_text
		return
	if a is Range and b is Range:
		(b as Range).value = (a as Range).value
	for i in a.get_child_count():
		if i < b.get_child_count():
			_graph_embed_copy_node_visuals(a.get_child(i), b.get_child(i))


func _ready() -> void:
	# Only the primary SolarUI registers; the graph-embedded mirror does not
	# clobber the service (it is a secondary read-only instance).
	if not _is_graph_embed:
		ServiceLocator.provide(ServiceLocator.SOLAR_UI, self)
	if _is_graph_embed:
		_graph_embed_setup_mirror_mode()
		return
	add_to_group("power_system_provider")

	_load_panel_settings()
	
	battery_bar.max_value = 100.0
	_style_scoreboard()

	call_deferred("_setup_collapse")
	
	# Initialize solar history with zeros
	solar_history.clear()
	load_history.clear()
	for i in range(HISTORY_SIZE):
		solar_history.append(0.0)
		load_history.append(0.0)
	
	await get_tree().process_frame
	_find_main_node()
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb != null and apb.has_method("register_authority"):
		apb.call("register_authority", self)
	_connect_to_ha_client()
	_connect_to_time_ui()
	
	_find_ground_materials()
	
	# Connect graph drawing
	if solar_graph:
		solar_graph.draw.connect(_draw_solar_graph)
	
	# Setup clickable labels for HA entity linking
	_setup_clickable_labels()
	_create_entity_link_popup()
	_load_ha_entity_settings()
	# Start in Auto mode so the UI shows a real-weather indicator (🌎 / 🌤)
	# as soon as Open-Meteo data loads. Synthetic sim runs as fallback until
	# then; the HA live mode is always off at boot for deterministic startup.
	_weather_live_mode = false
	_wx_sim_enabled = true
	weather = WeatherType.CLEAR
	_base_cloud_cover = CLOUD_REPR_CLEAR
	cloud_cover = CLOUD_REPR_CLEAR
	_clear_weather_overrides()
	
	# Initialize weather data display
	_update_weather_data_display()

	# Refresh the weather button/caption when real Open-Meteo data arrives so
	# the user can see that real weather has taken over (it applies on the next
	# sim tick via _try_apply_open_meteo_weather).
	var ws := get_node_or_null("/root/WeatherService")
	if ws != null:
		if ws.has_signal("weather_data_ready") and not ws.weather_data_ready.is_connected(_on_weather_data_ready):
			ws.weather_data_ready.connect(_on_weather_data_ready)
		if ws.has_signal("forecast_data_ready") and not ws.forecast_data_ready.is_connected(_on_forecast_data_ready):
			ws.forecast_data_ready.connect(_on_forecast_data_ready)

func _on_weather_data_ready(_lat: float, _lon: float, _year: int) -> void:
	_update_weather_button()
	_update_weather_data_display()

func _on_forecast_data_ready(_lat: float, _lon: float) -> void:
	_update_weather_button()
	_update_weather_data_display()

func _find_main_node() -> void:
	var root : Window = get_tree().root
	for child in root.get_children():
		if "day_time" in child and "sun" in child:
			main_node = child
			break
	
	if main_node == null:
		var current_scene : Node = get_tree().current_scene
		if current_scene and "day_time" in current_scene:
			main_node = current_scene
	
	if main_node and _wx_sim_enabled:
		var params := _wx_get_monthly_params()
		_wx_sim_state_duration = _wx_pick_duration(weather, params)
		_wx_sim_hours_in_state = randf() * _wx_sim_state_duration * 0.5

func _connect_to_ha_client() -> void:
	"""Find and connect to HAClient for real-time data"""
	# Skip if no HA entities are configured
	if ha_battery_soc_entity == "" and ha_load_entity == "" and ha_solar_entity == "" and ha_daily_solar_entity == "":
		return
	
	var tree := get_tree()
	if tree == null:
		return
	
	# Find HAClient node
	var root := tree.root
	for child in root.get_children():
		var client = child.get_node_or_null("HAClient")
		if client:
			ha_client = client
			break
	
	if ha_client == null:
		return
	
	# Connect to sensor updates
	if ha_client.has_signal("sensor_updated"):
		if not ha_client.sensor_updated.is_connected(_on_ha_sensor_updated):
			ha_client.sensor_updated.connect(_on_ha_sensor_updated)
	
	# Connect to connection status
	if ha_client.has_signal("authentication_status_changed"):
		if not ha_client.authentication_status_changed.is_connected(_on_ha_auth_changed):
			ha_client.authentication_status_changed.connect(_on_ha_auth_changed)
	
	# Connect to history statistics
	if ha_client.has_signal("history_statistics_received"):
		if not ha_client.history_statistics_received.is_connected(_on_history_statistics_received):
			ha_client.history_statistics_received.connect(_on_history_statistics_received)
	
	# Connect to raw history
	if ha_client.has_signal("raw_history_received"):
		if not ha_client.raw_history_received.is_connected(_on_raw_history_received):
			ha_client.raw_history_received.connect(_on_raw_history_received)
	
	_ha_connected = true

func _on_ha_auth_changed(authenticated: bool) -> void:
	_ha_connected = authenticated
	if not authenticated:
		# Clear overrides when disconnected
		_ha_battery_soc_override = -1.0
		_ha_load_override = -1.0
		_ha_solar_override = -1.0
		_ha_daily_solar_override = -1.0
		_history_loaded = false
	else:
		# Request initial states for our entities
		_request_ha_initial_states()
		# Request solar history for graph (if energy or power sensor is configured)
		if ha_solar_energy_entity != "" or ha_solar_entity != "":
			call_deferred("_request_solar_history")

func _request_ha_initial_states() -> void:
	"""Request initial state for configured HA entities"""
	if ha_client == null:
		return
	
	var entities_to_request: Array[String] = []
	if ha_battery_soc_entity != "":
		entities_to_request.append(ha_battery_soc_entity)
	if ha_load_entity != "":
		entities_to_request.append(ha_load_entity)
	if ha_solar_entity != "":
		entities_to_request.append(ha_solar_entity)
	if ha_daily_solar_entity != "":
		entities_to_request.append(ha_daily_solar_entity)
	
	if entities_to_request.is_empty():
		return
	
	# Request each entity's state
	for entity_id in entities_to_request:
		if ha_client.has_method("get_single_entity_state"):
			ha_client.get_single_entity_state(entity_id)

## Get list of HA entity IDs that should be subscribed
func get_ha_entity_ids() -> Array[String]:
	"""Returns list of HA entity IDs configured for this UI"""
	var entities: Array[String] = []
	if ha_battery_soc_entity != "":
		entities.append(ha_battery_soc_entity)
	if ha_load_entity != "":
		entities.append(ha_load_entity)
	if ha_solar_entity != "":
		entities.append(ha_solar_entity)
	if ha_daily_solar_entity != "":
		entities.append(ha_daily_solar_entity)
	for extra_entity in ha_additional_subscribe_entities:
		if extra_entity != "":
			entities.append(extra_entity)
	return entities

# ==================== HA ENTITY CLICK-TO-LINK ====================

const HA_SETTINGS_PATH = "user://solar_ui_ha_entities.cfg"

func _setup_clickable_labels() -> void:
	"""Make value labels clickable for HA entity linking"""
	# Battery SOC
	if battery_percent:
		battery_percent.mouse_filter = Control.MOUSE_FILTER_STOP
		battery_percent.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		battery_percent.gui_input.connect(_on_battery_percent_clicked)
		battery_percent.tooltip_text = "Click to link to Home Assistant entity"
	
	# Solar value
	if solar_value:
		solar_value.mouse_filter = Control.MOUSE_FILTER_STOP
		solar_value.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		solar_value.gui_input.connect(_on_solar_value_clicked)
		solar_value.tooltip_text = "Click to link to Home Assistant entity"
	
	# Load value
	if load_value:
		load_value.mouse_filter = Control.MOUSE_FILTER_STOP
		load_value.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		load_value.gui_input.connect(_on_load_value_clicked)
		load_value.tooltip_text = "Click to link to Home Assistant entity"
	
	# Scoreboard: daily total (HA daily entity)
	if scoreboard_today:
		scoreboard_today.mouse_filter = Control.MOUSE_FILTER_STOP
		scoreboard_today.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		scoreboard_today.gui_input.connect(_on_daily_solar_clicked)
		scoreboard_today.tooltip_text = "Today's simulated daily total (or HA if linked). Click to link to Home Assistant entity"
	
	# Graph title (for solar energy history)
	if graph_title:
		graph_title.mouse_filter = Control.MOUSE_FILTER_STOP
		graph_title.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		graph_title.gui_input.connect(_on_graph_title_clicked)
		graph_title.tooltip_text = "Click to link to Home Assistant solar energy sensor for historical data"

func _on_solar_rad_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("solar_radiation", "Solar Radiation (W/m²)", 
			"sensor.wittboy_solar_radiation", ha_solar_radiation_entity)
		get_viewport().set_input_as_handled()

func _on_lux_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("lux", "Light Level (lux)", 
			"sensor.wittboy_lux", ha_lux_entity)
		get_viewport().set_input_as_handled()

func _on_rain_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Show rain rate entity popup (can also link rain state separately)
		_show_entity_link_popup("rain_rate", "Rain Rate (mm/h)", 
			"sensor.wittboy_rain_rate", ha_rain_rate_entity)
		get_viewport().set_input_as_handled()

func _on_temp_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("temperature", "Outdoor Temperature", 
			"sensor.wittboy_outdoor_temperature", ha_temperature_entity)
		get_viewport().set_input_as_handled()

func _on_wind_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("wind_speed", "Wind Speed", 
			"sensor.wittboy_wind_speed", ha_wind_speed_entity)
		get_viewport().set_input_as_handled()

func _on_battery_percent_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("battery_soc", "Battery State of Charge", 
			"sensor.battery_soc", ha_battery_soc_entity)
		get_viewport().set_input_as_handled()

func _on_solar_value_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("solar", "Solar Production (W or kW)", 
			"sensor.solar_production", ha_solar_entity)
		get_viewport().set_input_as_handled()

func _on_load_value_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("load", "Power Load (W or kW)", 
			"sensor.power_consumption", ha_load_entity)
		get_viewport().set_input_as_handled()

func _on_daily_solar_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("daily_solar", "Daily Solar Production (kWh)", 
			"sensor.solar_daily_energy", ha_daily_solar_entity)
		get_viewport().set_input_as_handled()

func _on_graph_title_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_show_entity_link_popup("solar_energy", "Solar Energy Sensor (kWh) - for historical graph", 
			"sensor.solar_production_total", ha_solar_energy_entity)
		get_viewport().set_input_as_handled()

func _create_entity_link_popup() -> void:
	"""Create the popup window for entity linking"""
	_entity_link_popup = Window.new()
	_entity_link_popup.title = "Link to Home Assistant"
	_entity_link_popup.size = Vector2i(400, 180)
	_entity_link_popup.unresizable = true
	_entity_link_popup.transient = true
	_entity_link_popup.exclusive = true
	_entity_link_popup.visible = false
	
	# Main container
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	_entity_link_popup.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)
	
	# Description label
	var desc_label = Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = "Enter Home Assistant entity ID:"
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(desc_label)
	
	# Entity input
	_entity_link_input = LineEdit.new()
	_entity_link_input.placeholder_text = "sensor.example_entity"
	_entity_link_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_entity_link_input)
	
	# Buttons container
	var btn_container = HBoxContainer.new()
	btn_container.add_theme_constant_override("separation", 10)
	btn_container.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(btn_container)
	
	# Clear button
	var clear_btn = Button.new()
	clear_btn.text = "🗑 Clear Link"
	clear_btn.pressed.connect(_on_entity_link_clear)
	btn_container.add_child(clear_btn)
	
	# Spacer
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_container.add_child(spacer)
	
	# Cancel button
	var cancel_btn = Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.pressed.connect(_on_entity_link_cancel)
	btn_container.add_child(cancel_btn)
	
	# Confirm button
	var confirm_btn = Button.new()
	confirm_btn.text = "✓ Link Entity"
	confirm_btn.pressed.connect(_on_entity_link_confirm)
	btn_container.add_child(confirm_btn)
	
	# Handle enter key
	_entity_link_input.text_submitted.connect(func(_text): _on_entity_link_confirm())
	
	# Handle close
	_entity_link_popup.close_requested.connect(_on_entity_link_cancel)
	
	# Add popup to tree
	add_child(_entity_link_popup)

func _show_entity_link_popup(target: String, title: String, placeholder: String, current_value: String) -> void:
	"""Show the entity link popup for a specific field"""
	if _entity_link_popup == null:
		return
	
	_entity_link_target = target
	_entity_link_popup.title = "Link: " + title
	_entity_link_input.placeholder_text = placeholder
	_entity_link_input.text = current_value if current_value != "" else ""
	
	# Update description
	var desc_label = _entity_link_popup.get_node_or_null("MarginContainer/VBoxContainer/DescLabel")
	if desc_label:
		desc_label.text = "Enter Home Assistant entity ID for:\n" + title
	
	# Center popup on screen
	var screen_size = DisplayServer.screen_get_size()
	var popup_size = _entity_link_popup.size
	_entity_link_popup.position = Vector2i(
		(screen_size.x - popup_size.x) / 2,
		(screen_size.y - popup_size.y) / 2
	)
	
	_entity_link_popup.show()
	_entity_link_input.grab_focus()
	_entity_link_input.select_all()

func _on_entity_link_confirm() -> void:
	"""Confirm entity linking"""
	var entity_id = _entity_link_input.text.strip_edges()
	var is_weather_entity := false
	
	# Apply to the correct field
	match _entity_link_target:
		"battery_soc":
			ha_battery_soc_entity = entity_id
		"solar":
			ha_solar_entity = entity_id
		"load":
			ha_load_entity = entity_id
		"daily_solar":
			ha_daily_solar_entity = entity_id
		"solar_energy":
			ha_solar_energy_entity = entity_id
			# Request historical data immediately if linked
			if entity_id != "" and ha_client and ha_client.is_authenticated:
				# Reset pending flag since we're linking a new entity
				_history_request_pending = false
				_request_solar_history()
		# Weather entities
		"solar_radiation":
			ha_solar_radiation_entity = entity_id
			is_weather_entity = true
		"lux":
			ha_lux_entity = entity_id
			is_weather_entity = true
		"rain_rate":
			ha_rain_rate_entity = entity_id
			is_weather_entity = true
		"rain_state":
			ha_rain_state_entity = entity_id
			is_weather_entity = true
		"temperature":
			ha_temperature_entity = entity_id
			is_weather_entity = true
		"wind_speed":
			ha_wind_speed_entity = entity_id
			is_weather_entity = true
	
	# Auto-subscribe if we have an entity (except solar_energy which uses history API)
	if entity_id != "" and _entity_link_target != "solar_energy":
		_subscribe_to_entity(entity_id)
	
	# Enable weather live mode automatically if a weather entity is linked
	if is_weather_entity and entity_id != "":
		_weather_live_mode = true
		_update_weather_link_button()
	
	# Save settings
	_save_ha_entity_settings()
	
	_entity_link_popup.hide()

func _on_entity_link_clear() -> void:
	"""Clear entity link"""
	# Clear the field
	match _entity_link_target:
		"battery_soc":
			ha_battery_soc_entity = ""
			_ha_battery_soc_override = -1.0
		"solar":
			ha_solar_entity = ""
			_ha_solar_override = -1.0
		"load":
			ha_load_entity = ""
			_ha_load_override = -1.0
		"daily_solar":
			ha_daily_solar_entity = ""
			_ha_daily_solar_override = -1.0
		"solar_energy":
			ha_solar_energy_entity = ""
			_history_loaded = false
			# Clear historical data from graph
			solar_history.clear()
			for i in range(HISTORY_SIZE):
				solar_history.append(0.0)
		# Weather entities
		"solar_radiation":
			ha_solar_radiation_entity = ""
			_ha_solar_radiation_override = -1.0
		"lux":
			ha_lux_entity = ""
			_ha_lux_override = -1.0
		"rain_rate":
			ha_rain_rate_entity = ""
			_ha_rain_rate_override = -1.0
		"rain_state":
			ha_rain_state_entity = ""
			_ha_rain_state_override = -1
		"temperature":
			ha_temperature_entity = ""
			_ha_temperature_override = -999.0
		"wind_speed":
			ha_wind_speed_entity = ""
			_ha_wind_speed_override = -1.0
	
	# Check if any weather entities are still linked
	if not _has_any_weather_entity_linked():
		_weather_live_mode = false
		_update_weather_link_button()
	
	# Save settings
	_save_ha_entity_settings()
	
	_entity_link_popup.hide()

func _on_entity_link_cancel() -> void:
	"""Cancel entity linking"""
	_entity_link_popup.hide()

func _subscribe_to_entity(entity_id: String) -> void:
	"""Subscribe to an HA entity"""
	if ha_client == null:
		_connect_to_ha_client()
	
	if ha_client == null:
		return
	
	# Check if already subscribed
	var subscribed_entities: Array = ha_client.get("subscribed_entities") if ha_client.get("subscribed_entities") != null else []
	if entity_id in subscribed_entities:
		# Already subscribed, just request current state
		if ha_client.has_method("get_single_entity_state"):
			ha_client.get_single_entity_state(entity_id)
		return
	
	# Subscribe to this entity
	if ha_client.has_method("subscribe_to_entities"):
		# Add to existing subscriptions
		var entities_to_sub: Array[String] = [entity_id]
		ha_client.subscribe_to_entities(entities_to_sub)
	
	# Request initial state
	if ha_client.has_method("get_single_entity_state"):
		ha_client.get_single_entity_state(entity_id)

# ==================== WEATHER LIVE MODE ====================

func _on_weather_link_button_pressed() -> void:
	"""Show weather entity link menu (legacy; timeline uses show_weather_link_menu)."""
	show_weather_link_menu_for_anchor(null)

func _has_any_weather_entity_linked() -> bool:
	"""Check if any weather entity is configured"""
	return ha_solar_radiation_entity != "" or ha_lux_entity != "" or \
		   ha_rain_rate_entity != "" or ha_rain_state_entity != "" or \
		   ha_temperature_entity != "" or ha_wind_speed_entity != ""

func _request_weather_entity_states() -> void:
	"""Request current state for all configured weather entities"""
	if ha_client == null or not ha_client.get("is_authenticated"):
		return
	
	var weather_entities: Array[String] = []
	if ha_solar_radiation_entity != "":
		weather_entities.append(ha_solar_radiation_entity)
	if ha_lux_entity != "":
		weather_entities.append(ha_lux_entity)
	if ha_rain_rate_entity != "":
		weather_entities.append(ha_rain_rate_entity)
	if ha_rain_state_entity != "":
		weather_entities.append(ha_rain_state_entity)
	if ha_temperature_entity != "":
		weather_entities.append(ha_temperature_entity)
	if ha_wind_speed_entity != "":
		weather_entities.append(ha_wind_speed_entity)
	
	for entity_id in weather_entities:
		if ha_client.has_method("get_single_entity_state"):
			ha_client.get_single_entity_state(entity_id)

func _clear_weather_overrides() -> void:
	"""Clear all weather HA overrides"""
	_ha_solar_radiation_override = -1.0
	_ha_lux_override = -1.0
	_ha_rain_rate_override = -1.0
	_ha_rain_state_override = -1
	_ha_temperature_override = -999.0
	_ha_wind_speed_override = -1.0

var _weather_link_menu: PopupMenu = null

## Position pop-up under `anchor` (e.g. timeline link button), or near top-center if null.
func show_weather_link_menu_for_anchor(anchor: Control) -> void:
	if _weather_link_menu != null:
		_weather_link_menu.queue_free()
		_weather_link_menu = null
	_create_weather_link_menu()
	if _weather_link_menu == null:
		return
	if anchor is Control and is_instance_valid(anchor) and (anchor as Control).is_visible_in_tree():
		var r := (anchor as Control).get_global_rect()
		_weather_link_menu.position = Vector2i(int(r.position.x), int(r.position.y + r.size.y))
	else:
		var vp := get_viewport()
		if vp:
			var vr := vp.get_visible_rect()
			_weather_link_menu.position = Vector2i(int(vr.position.x + 24), int(vr.position.y + 100))
	_weather_link_menu.popup()

func _create_weather_link_menu() -> void:
	"""Create the weather entity link popup menu"""
	_weather_link_menu = PopupMenu.new()
	_weather_link_menu.name = "WeatherLinkMenu"
	
	# Add menu items for each weather sensor with checkmarks for linked ones
	var solar_rad_text := "☀ Solar Radiation" + (" ✓" if ha_solar_radiation_entity != "" else "")
	var lux_text := "💡 Light Level" + (" ✓" if ha_lux_entity != "" else "")
	var rain_rate_text := "🌧 Rain Rate" + (" ✓" if ha_rain_rate_entity != "" else "")
	var rain_state_text := "🌧 Rain State" + (" ✓" if ha_rain_state_entity != "" else "")
	var temp_text := "🌡 Temperature" + (" ✓" if ha_temperature_entity != "" else "")
	var wind_text := "💨 Wind Speed" + (" ✓" if ha_wind_speed_entity != "" else "")
	
	_weather_link_menu.add_item(solar_rad_text, 0)
	_weather_link_menu.add_item(lux_text, 1)
	_weather_link_menu.add_item(rain_rate_text, 2)
	_weather_link_menu.add_item(rain_state_text, 3)
	_weather_link_menu.add_item(temp_text, 4)
	_weather_link_menu.add_item(wind_text, 5)
	_weather_link_menu.add_separator()
	
	# Live mode toggle
	if _weather_live_mode:
		_weather_link_menu.add_item("📡 Disable Live Mode", 7)
	else:
		var can_enable := _has_any_weather_entity_linked()
		_weather_link_menu.add_item("📡 Enable Live Mode" + (" (link entities first)" if not can_enable else ""), 6)
		if not can_enable:
			_weather_link_menu.set_item_disabled(_weather_link_menu.get_item_index(6), true)
	
	# Connect signal
	_weather_link_menu.id_pressed.connect(_on_weather_link_menu_item_selected)
	
	add_child(_weather_link_menu)

func _on_weather_link_menu_item_selected(id: int) -> void:
	"""Handle weather link menu selection"""
	match id:
		0:  # Solar Radiation
			_show_entity_link_popup("solar_radiation", "Solar Radiation (W/m²)", 
				"sensor.wittboy_solar_radiation", ha_solar_radiation_entity)
		1:  # Lux
			_show_entity_link_popup("lux", "Light Level (lux)", 
				"sensor.wittboy_lux", ha_lux_entity)
		2:  # Rain Rate
			_show_entity_link_popup("rain_rate", "Rain Rate (mm/h)", 
				"sensor.wittboy_rain_rate", ha_rain_rate_entity)
		3:  # Rain State
			_show_entity_link_popup("rain_state", "Rain State (on/off)", 
				"sensor.wittboy_rain_state", ha_rain_state_entity)
		4:  # Temperature
			_show_entity_link_popup("temperature", "Outdoor Temperature", 
				"sensor.wittboy_outdoor_temperature", ha_temperature_entity)
		5:  # Wind Speed
			_show_entity_link_popup("wind_speed", "Wind Speed", 
				"sensor.wittboy_wind_speed", ha_wind_speed_entity)
		6:  # Enable Live Mode
			if _has_any_weather_entity_linked():
				_weather_live_mode = true
				_request_weather_entity_states()
				_update_weather_button()
				_update_weather_link_button()
				_update_weather_data_display()
			else:
				pass
		7:  # Disable Live Mode
			_weather_live_mode = false
			_clear_weather_overrides()
			_update_weather_button()
			_update_weather_link_button()
			_update_weather_data_display()

func _update_weather_link_button() -> void:
	"""UI moved to timeline; this remains as a no-op for older call sites."""
	pass


## Single-line string for the bottom timeline weather strip.
func get_weather_status_bar_text() -> String:
	return _format_weather_status_bar()


func _format_weather_status_bar() -> String:
	var solar_rad: float; var lux: float; var rain_rate: float; var is_raining: bool; var temp: float; var wind: float
	if _weather_live_mode:
		solar_rad = _ha_solar_radiation_override if _ha_solar_radiation_override >= 0 else _simulated_solar_radiation
		lux = _ha_lux_override if _ha_lux_override >= 0 else _simulated_lux
		rain_rate = _ha_rain_rate_override if _ha_rain_rate_override >= 0 else _simulated_rain_rate
		is_raining = _is_actively_precipitating()
		temp = _ha_temperature_override if _ha_temperature_override > -900 else _simulated_temperature
		wind = _ha_wind_speed_override if _ha_wind_speed_override >= 0 else _simulated_wind_speed
	else:
		solar_rad = _simulated_solar_radiation
		lux = _simulated_lux
		rain_rate = _simulated_rain_rate
		is_raining = _is_actively_precipitating()
		temp = _simulated_temperature
		wind = _simulated_wind_speed
	var live_tag := " 📡" if _weather_live_mode else ""
	var lux_str: String = "%.0f" % lux if lux < 10000.0 else "%.1fk" % (lux / 1000.0)
	var rain_s: String
	if is_raining or rain_rate > 0.0:
		rain_s = "%.1fmm/h" % rain_rate
	else:
		rain_s = "dry"
	return "☀%.0f W/m²  •  💡%s lux  •  🌧%s  •  🌡%.0f°C  •  💨%.1f m/s%s" % [solar_rad, lux_str, rain_s, temp, wind, live_tag]


func get_weather_cycle_tooltip() -> String:
	if _weather_live_mode:
		return "Weather: LIVE from Home Assistant weather station"
	if _open_meteo_active:
		if _forecast_active:
			return "Weather: automatic — live Open-Meteo forecast (next 10 days)"
		if _generated_weather_active:
			return "Weather: automatic — stochastic generated scenario (CMIP6 embedded)"
		return "Weather: automatic — real Open-Meteo archive 🌎"
	return "Weather: automatic — synthetic fallback (no Open-Meteo data for this location)"


func get_weather_link_tooltip() -> String:
	if _weather_live_mode:
		return "Weather LIVE — click to link sensors or switch to sim"
	if _has_any_weather_entity_linked():
		return "Sensors linked — open menu to edit or go live"
	return "Link Home Assistant weather station entities"


func get_weather_link_modulate() -> Color:
	if _weather_live_mode:
		return Color(0.3, 1.0, 0.5)
	if _has_any_weather_entity_linked():
		return Color(0.6, 0.6, 0.6)
	return Color(0.4, 0.45, 0.55)


## Cycle weather (for timeline); mirrors old weather button.
func cycle_weather() -> void:
	_on_weather_button_pressed()


func _update_weather_data_display() -> void:
	"""No on-panel weather block; data is shown on TimelineUI."""
	_sync_timeline_weather_row()

func _apply_live_weather_to_simulation() -> void:
	"""Apply live weather data from HA to the simulation parameters"""
	if not _weather_live_mode:
		return
	
	# Determine weather type from live data
	var new_weather := WeatherType.CLEAR
	var new_cloud_cover := 0.0
	
	# Use rain state/rate to determine if raining
	var is_raining := false
	if _ha_rain_state_override == 1:
		is_raining = true
	elif _ha_rain_rate_override > 0.1:  # More than 0.1 mm/h
		is_raining = true
	
	if is_raining:
		new_weather = WeatherType.RAINY
		new_cloud_cover = 0.95
		# Set rain rate for simulation
		if _ha_rain_rate_override >= 0:
			var rain_mm_h := _ha_rain_rate_override
			# Convert mm/h to inches/h for simulation (1 inch = 25.4 mm)
			rain_rate_per_hour = rain_mm_h / 25.4
	else:
		# Use solar radiation or lux to estimate cloud cover
		var clear_sky_radiation := 1000.0  # Approximate clear sky W/m² at solar noon
		var clear_sky_lux := 100000.0  # Approximate clear sky lux
		
		if _ha_solar_radiation_override >= 0:
			# Estimate cloud cover from solar radiation
			# Lower radiation = more clouds
			var radiation_ratio := clampf(_ha_solar_radiation_override / clear_sky_radiation, 0.0, 1.0)
			new_cloud_cover = 1.0 - radiation_ratio
		elif _ha_lux_override >= 0:
			# Estimate cloud cover from lux
			var lux_ratio := clampf(_ha_lux_override / clear_sky_lux, 0.0, 1.0)
			new_cloud_cover = 1.0 - lux_ratio
		
		# Map cloud cover to weather type
		if new_cloud_cover < 0.15:
			new_weather = WeatherType.CLEAR
		elif new_cloud_cover < 0.5:
			new_weather = WeatherType.PARTLY_CLOUDY
		else:
			new_weather = WeatherType.CLOUDY
	
	# Apply weather if different
	if weather != new_weather:
		weather = new_weather
	
	# Override cloud_cover for more precise simulation
	cloud_cover = new_cloud_cover
	_base_cloud_cover = new_cloud_cover
	
	# Update sky visuals immediately
	_update_sky_visuals()
	_update_weather_lighting()
	_update_weather_button()

func _generate_simulated_weather_data() -> void:
	"""Generate plausible simulated weather data based on current simulation state"""
	if main_node == null:
		return
	
	var day_time_val: float = main_node.day_time if "day_time" in main_node else 12.0
	
	# Solar radiation follows sun position (rough approximation)
	var sun_height := _sun_direction().y
	
	# Base clear-sky radiation from sun height
	var base_radiation := maxf(0, sun_height * 1100.0)  # Up to ~1100 W/m² at zenith
	
	# Apply cloud cover
	_simulated_solar_radiation = base_radiation * (1.0 - cloud_cover * 0.85)
	
	# Lux from radiation (rough conversion: 1 W/m² solar ≈ 100-120 lux)
	_simulated_lux = _simulated_solar_radiation * 110.0
	
	# Rain rate based on weather type
	match weather:
		WeatherType.RAINY:
			_simulated_rain_rate = rain_rate_per_hour * 25.4  # Convert in/h to mm/h
		_:
			_simulated_rain_rate = 0.0
	
	# Temperature varies with time of day and weather
	var base_temp := _estimate_ambient_temp()
	# Clouds reduce temperature slightly
	_simulated_temperature = base_temp - cloud_cover * 5.0
	
	# Wind speed: deterministic pseudo-variation seeded by absolute time, so a
	# rewind/replay reconstructs the exact same series (no randf() — that would
	# make the simulation non-reproducible and break reversible scrubbing).
	var abs_h : float = float(main_node.call("get_absolute_hours")) if main_node.has_method("get_absolute_hours") else day_time_val
	var w := _det_unit(abs_h)
	match weather:
		WeatherType.CLEAR:
			_simulated_wind_speed = 1.0 + w * 3.0  # 1-4 m/s
		WeatherType.PARTLY_CLOUDY:
			_simulated_wind_speed = 2.0 + w * 4.0  # 2-6 m/s
		WeatherType.CLOUDY:
			_simulated_wind_speed = 3.0 + w * 5.0  # 3-8 m/s
		WeatherType.RAINY:
			_simulated_wind_speed = 4.0 + w * 8.0  # 4-12 m/s


## Deterministic unit-interval pseudo-noise from a continuous seed (hash of a
## sine). Reproducible for the same input — used in place of randf() so the
## synthetic-weather fallback can be rewound exactly.
func _det_unit(seed_val: float) -> float:
	var s : float = sin(seed_val * 12.9898) * 43758.5453
	return s - floor(s)

func _save_ha_entity_settings() -> void:
	"""Save HA entity mappings to config file"""
	var config = ConfigFile.new()
	# Power entities
	config.set_value("entities", "battery_soc", ha_battery_soc_entity)
	config.set_value("entities", "solar", ha_solar_entity)
	config.set_value("entities", "load", ha_load_entity)
	config.set_value("entities", "daily_solar", ha_daily_solar_entity)
	config.set_value("entities", "solar_energy", ha_solar_energy_entity)
	config.set_value("settings", "values_in_watts", ha_values_in_watts)
	
	# Weather entities
	config.set_value("weather_entities", "solar_radiation", ha_solar_radiation_entity)
	config.set_value("weather_entities", "lux", ha_lux_entity)
	config.set_value("weather_entities", "rain_rate", ha_rain_rate_entity)
	config.set_value("weather_entities", "rain_state", ha_rain_state_entity)
	config.set_value("weather_entities", "temperature", ha_temperature_entity)
	config.set_value("weather_entities", "wind_speed", ha_wind_speed_entity)
	config.set_value("weather_settings", "rain_rate_in_mm", ha_rain_rate_in_mm)
	config.set_value("weather_settings", "temp_in_celsius", ha_temp_in_celsius)
	config.set_value("weather_settings", "wind_in_ms", ha_wind_in_ms)
	config.set_value("weather_settings", "live_mode", _weather_live_mode)
	
	var error = config.save(HA_SETTINGS_PATH)
	if error != OK:
		pass
	else:
		pass

func _load_ha_entity_settings() -> void:
	"""Load HA entity mappings from config file"""
	var config = ConfigFile.new()
	var error = config.load(HA_SETTINGS_PATH)
	
	if error != OK:
		return
	
	# Load power entity mappings
	ha_battery_soc_entity = config.get_value("entities", "battery_soc", "")
	ha_solar_entity = config.get_value("entities", "solar", "")
	ha_load_entity = config.get_value("entities", "load", "")
	ha_daily_solar_entity = config.get_value("entities", "daily_solar", "")
	ha_solar_energy_entity = config.get_value("entities", "solar_energy", "")
	ha_values_in_watts = config.get_value("settings", "values_in_watts", true)
	
	# Load weather entity mappings
	ha_solar_radiation_entity = config.get_value("weather_entities", "solar_radiation", "")
	ha_lux_entity = config.get_value("weather_entities", "lux", "")
	ha_rain_rate_entity = config.get_value("weather_entities", "rain_rate", "")
	ha_rain_state_entity = config.get_value("weather_entities", "rain_state", "")
	ha_temperature_entity = config.get_value("weather_entities", "temperature", "")
	ha_wind_speed_entity = config.get_value("weather_entities", "wind_speed", "")
	ha_rain_rate_in_mm = config.get_value("weather_settings", "rain_rate_in_mm", true)
	ha_temp_in_celsius = config.get_value("weather_settings", "temp_in_celsius", true)
	ha_wind_in_ms = config.get_value("weather_settings", "wind_in_ms", true)
	_weather_live_mode = config.get_value("weather_settings", "live_mode", false)
	
	# Update weather link button state
	call_deferred("_update_weather_link_button")
	
	# Auto-subscribe to saved entities when HA connects
	call_deferred("_auto_subscribe_saved_entities")

func _auto_subscribe_saved_entities() -> void:
	"""Subscribe to all saved entities after a short delay"""
	await get_tree().create_timer(1.0).timeout
	
	if ha_client == null:
		_connect_to_ha_client()
	
	if ha_client == null:
		return
	
	# Collect all power entities to subscribe
	var entities_to_subscribe: Array[String] = []
	if ha_battery_soc_entity != "":
		entities_to_subscribe.append(ha_battery_soc_entity)
	if ha_solar_entity != "":
		entities_to_subscribe.append(ha_solar_entity)
	if ha_load_entity != "":
		entities_to_subscribe.append(ha_load_entity)
	if ha_daily_solar_entity != "":
		entities_to_subscribe.append(ha_daily_solar_entity)
	for extra_entity in ha_additional_subscribe_entities:
		if extra_entity != "":
			entities_to_subscribe.append(extra_entity)
	
	# Collect weather entities to subscribe
	if ha_solar_radiation_entity != "":
		entities_to_subscribe.append(ha_solar_radiation_entity)
	if ha_lux_entity != "":
		entities_to_subscribe.append(ha_lux_entity)
	if ha_rain_rate_entity != "":
		entities_to_subscribe.append(ha_rain_rate_entity)
	if ha_rain_state_entity != "":
		entities_to_subscribe.append(ha_rain_state_entity)
	if ha_temperature_entity != "":
		entities_to_subscribe.append(ha_temperature_entity)
	if ha_wind_speed_entity != "":
		entities_to_subscribe.append(ha_wind_speed_entity)
	
	# Subscribe if HA is authenticated
	if ha_client.get("is_authenticated"):
		if not entities_to_subscribe.is_empty():
			for entity_id in entities_to_subscribe:
				_subscribe_to_entity(entity_id)
		
		# Request historical solar data if configured (energy sensor or power sensor)
		if ha_solar_energy_entity != "" or ha_solar_entity != "":
			_request_solar_history()
		
		# Request weather data if in live mode
		if _weather_live_mode and _has_any_weather_entity_linked():
			_request_weather_entity_states()

var _history_request_time: float = 0.0
const HISTORY_REQUEST_TIMEOUT: float = 30.0  # Timeout after 30 seconds

func _request_solar_history() -> void:
	"""Request today's solar history from Home Assistant"""
	if ha_client == null or not ha_client.get("is_authenticated"):
		return
	
	# Check for stuck pending request (timeout after 30 seconds)
	if _history_request_pending:
		var current_time = Time.get_unix_time_from_system()
		if current_time - _history_request_time > HISTORY_REQUEST_TIMEOUT:
			_history_request_pending = false
		else:
			return
	
	# Determine which sensor to use for history
	var history_entity = ""
	var use_statistics = false
	
	if ha_solar_energy_entity != "":
		# Prefer the dedicated energy sensor (statistics API)
		history_entity = ha_solar_energy_entity
		use_statistics = true
	elif ha_solar_entity != "":
		# Fall back to the power sensor (raw history API)
		history_entity = ha_solar_entity
		use_statistics = false
	else:
		return
	
	_history_request_pending = true
	_history_request_time = Time.get_unix_time_from_system()
	
	if use_statistics:
		if ha_client.has_method("get_today_hourly_statistics"):
			ha_client.get_today_hourly_statistics(history_entity)
		else:
			_history_request_pending = false
	else:
		if ha_client.has_method("get_today_entity_history"):
			ha_client.get_today_entity_history(history_entity)
		else:
			_history_request_pending = false

func _on_history_statistics_received(statistic_id: String, statistics: Array) -> void:
	"""Handle received historical statistics from Home Assistant"""
	_history_request_pending = false
	
	if statistic_id != ha_solar_energy_entity:
		return
	
	if statistics.is_empty():
		return
	
	# Backfill the solar_history array with historical data
	# Statistics come as: [{"start": "2024-01-29T06:00:00Z", "sum": 1.5, "mean": 0.5, ...}, ...]
	# We need to extract the hourly energy production and convert to average power (kW)
	
	# Clear existing history
	solar_history.clear()
	for i in range(HISTORY_SIZE):
		solar_history.append(0.0)
	
	# Process each hourly statistic
	var last_sum: float = 0.0
	var first_entry: bool = true
	var entry_index: int = 0
	
	for stat in statistics:
		if not stat is Dictionary:
			continue
		
		# Safely get values with proper type conversion (HA may return null or different types)
		var start_time_raw = stat.get("start", "")
		var start_time: String = str(start_time_raw) if start_time_raw != null else ""
		
		var sum_raw = stat.get("sum")
		var current_sum: float = float(sum_raw) if sum_raw != null else 0.0
		
		var change_raw = stat.get("change")
		var change: float = float(change_raw) if change_raw != null else -1.0
		
		# Extract hour from start_time
		# HA returns Unix timestamp in MILLISECONDS, not ISO string
		var hour: int = -1
		
		# Check if it's a numeric timestamp (milliseconds)
		if start_time.is_valid_float():
			var timestamp_ms: float = float(start_time)
			var timestamp_sec: int = int(timestamp_ms / 1000.0)
			
			# Get UTC hour from timestamp
			var datetime_utc = Time.get_datetime_dict_from_unix_time(timestamp_sec)
			var utc_hour: int = datetime_utc.hour
			
			# Convert UTC hour to local hour
			var tz_info = Time.get_time_zone_from_system()
			var tz_offset_hours: int = int(-tz_info.bias / 60)  # bias is negative for east
			hour = (utc_hour + tz_offset_hours) % 24
		elif "T" in start_time:
			# Fallback for ISO format string
			var time_part = start_time.split("T")[1]
			var hour_str = time_part.split(":")[0]
			hour = hour_str.to_int()
		else:
			pass
		
		if hour < 0 or hour >= HISTORY_SIZE:
			continue
		
		# Calculate the energy produced during this hour
		var hourly_energy: float = 0.0
		
		# Prefer 'change' if available (energy produced during this hour)
		if change >= 0.0:
			hourly_energy = change
		elif not first_entry:
			# Calculate from cumulative sum difference
			hourly_energy = current_sum - last_sum
		
		# Store as average power (kW) - since it's kWh over 1 hour, kWh = kW average
		solar_history[hour] = maxf(hourly_energy, 0.0)
		
		last_sum = current_sum
		first_entry = false
		entry_index += 1
	
	_history_loaded = true
	
	# Force graph redraw with new data
	if solar_graph:
		solar_graph.queue_redraw()
	_update_graph()

func _on_raw_history_received(entity_id: String, history: Array) -> void:
	"""Handle received raw history from Home Assistant (for power sensors)"""
	_history_request_pending = false
	
	# Check if this is for our solar entity
	if entity_id != ha_solar_entity:
		return
	
	if history.is_empty():
		return
	
	# Clear existing history
	solar_history.clear()
	for i in range(HISTORY_SIZE):
		solar_history.append(0.0)
	
	# OPTIMIZED: Only take ONE reading per hour (first valid one)
	# This is much faster than averaging all readings
	var hours_found: Dictionary = {}  # hour -> true (to track which hours we've filled)
	
	for entry in history:
		if not entry is Dictionary:
			continue
		
		# Safely get values (HA may return different types)
		var state_raw = entry.get("s", entry.get("state", null))
		var state_str: String = str(state_raw) if state_raw != null else ""
		var timestamp = entry.get("lc", entry.get("last_changed", 0))
		
		if state_str == "" or state_str == "unavailable" or state_str == "unknown":
			continue
		
		# Extract hour from timestamp
		var hour: int = -1
		if timestamp is float or timestamp is int:
			var datetime = Time.get_datetime_dict_from_unix_time(int(timestamp))
			hour = datetime.hour
		elif timestamp is String and "T" in timestamp:
			var time_part = timestamp.split("T")[1]
			hour = time_part.split(":")[0].to_int()
		
		if hour < 0 or hour >= HISTORY_SIZE:
			continue
		
		# Skip if we already have a reading for this hour
		if hours_found.has(hour):
			continue
		
		var power_value = float(state_str)
		
		# Convert to kW if values are in watts
		if ha_values_in_watts and power_value > 100:
			power_value = power_value / 1000.0
		
		solar_history[hour] = maxf(power_value, 0.0)
		hours_found[hour] = true
		
		# Early exit if we have all hours up to current
		var current_hour = Time.get_datetime_dict_from_system().hour
		if hours_found.size() > current_hour:
			break
	
	_history_loaded = true
	
	# Force graph redraw with new data
	if solar_graph:
		solar_graph.queue_redraw()
	_update_graph()

func _get_link_tooltip(field_name: String, entity_id: String) -> String:
	"""Generate tooltip for a linkable field"""
	if entity_id != "":
		return "🔗 Linked to: %s\nClick to change" % entity_id
	else:
		return "Click to link %s to Home Assistant" % field_name

# ==================== LIVE MODE INTEGRATION ====================

func _connect_to_time_ui() -> void:
	"""Connect live mode / simulation signals (TimeUI shim + SimSettingsController)."""
	var tree := get_tree()
	if tree == null:
		return
	if is_instance_valid(SimSettingsController):
		if not SimSettingsController.live_mode_changed.is_connected(_on_live_mode_changed):
			SimSettingsController.live_mode_changed.connect(_on_live_mode_changed)
		if not SimSettingsController.simulation_started.is_connected(_on_simulation_started):
			SimSettingsController.simulation_started.connect(_on_simulation_started)
	for child in tree.root.get_children():
		var time_ui = child.get_node_or_null("UILayer/TimeUI")
		if time_ui:
			if time_ui.has_signal("live_mode_changed"):
				if not time_ui.live_mode_changed.is_connected(_on_live_mode_changed):
					time_ui.live_mode_changed.connect(_on_live_mode_changed)
			if time_ui.has_signal("simulation_started"):
				if not time_ui.simulation_started.is_connected(_on_simulation_started):
					time_ui.simulation_started.connect(_on_simulation_started)
			break

func _on_live_mode_changed(enabled: bool) -> void:
	"""Handle live mode toggle from TimeUI"""
	_live_mode_active = enabled
	
	if enabled:
		# Entering live mode - clear simulation mode, use HA data directly
		_simulation_mode = false
		_sim_start_battery_soc = -1.0
		_sim_start_load_kw = -1.0
		_sim_start_solar_kw = -1.0
		
		# Request historical solar data if not already loaded
		# Can use either energy sensor (statistics) or power sensor (raw history)
		if not _history_loaded and (ha_solar_energy_entity != "" or ha_solar_entity != ""):
			_request_solar_history()
	else:
		# Exiting live mode - clear HA overrides, use full simulation
		_simulation_mode = false
		_ha_battery_soc_override = -1.0
		_ha_load_override = -1.0
		_ha_solar_override = -1.0
		_ha_daily_solar_override = -1.0
		_history_loaded = false  # Reset history so it reloads next time

func _on_simulation_started(initial_battery_soc: float, initial_load_kw: float, initial_solar_kw: float) -> void:
	"""Handle simulation start from TimeUI - snapshot current HA values and simulate forward"""
	_simulation_mode = true
	
	# Snapshot current values as starting point for simulation
	# Use HA values if available, otherwise use current calculated values
	if _ha_battery_soc_override >= 0.0:
		_sim_start_battery_soc = _ha_battery_soc_override
		battery_kwh_stored = (_sim_start_battery_soc / 100.0) * BATTERY_CAPACITY_KWH
	else:
		_sim_start_battery_soc = initial_battery_soc
	
	if _ha_load_override >= 0.0:
		_sim_start_load_kw = _ha_load_override
	else:
		_sim_start_load_kw = initial_load_kw
	
	if _ha_solar_override >= 0.0:
		_sim_start_solar_kw = _ha_solar_override
	else:
		_sim_start_solar_kw = initial_solar_kw
	
	# Clear HA overrides so simulation can run
	_ha_battery_soc_override = -1.0
	_ha_load_override = -1.0
	_ha_solar_override = -1.0
	_ha_daily_solar_override = -1.0  # Daily total won't be accurate during simulation

func is_in_live_mode() -> bool:
	"""Returns true if in live mode at realtime speed (showing live HA data)"""
	return _live_mode_active and not _simulation_mode

func is_simulating_from_live() -> bool:
	"""Returns true if simulating forward from live data snapshot"""
	return _live_mode_active and _simulation_mode

func _on_ha_sensor_updated(entity_id: String, state: Dictionary) -> void:
	"""Handle incoming sensor data from Home Assistant"""
	# In simulation mode (fast-forward from live), ignore HA updates
	if _simulation_mode:
		return
	
	var state_value: String = state.get("state", "")
	
	# Skip unavailable/unknown states
	if state_value in ["unavailable", "unknown", ""]:
		return
	
	var numeric_value: float = state_value.to_float()
	
	# Check which entity this matches - Power entities
	if entity_id == ha_battery_soc_entity and ha_battery_soc_entity != "":
		# Battery SOC - expected as percentage (0-100)
		_ha_battery_soc_override = clampf(numeric_value, 0.0, 100.0)
		# Also update the actual battery storage to match
		battery_kwh_stored = (_ha_battery_soc_override / 100.0) * BATTERY_CAPACITY_KWH
	
	elif entity_id == ha_load_entity and ha_load_entity != "":
		# Load - convert to kW if needed
		if ha_values_in_watts:
			_ha_load_override = numeric_value / 1000.0  # W to kW
		else:
			_ha_load_override = numeric_value
	
	elif entity_id == ha_solar_entity and ha_solar_entity != "":
		# Solar production - convert to kW if needed
		if ha_values_in_watts:
			_ha_solar_override = numeric_value / 1000.0  # W to kW
		else:
			_ha_solar_override = numeric_value
	
	elif entity_id == ha_daily_solar_entity and ha_daily_solar_entity != "":
		# Daily solar production - always in kWh
		_ha_daily_solar_override = numeric_value
	
	# Weather entities
	elif entity_id == ha_solar_radiation_entity and ha_solar_radiation_entity != "":
		# Solar radiation in W/m²
		_ha_solar_radiation_override = maxf(numeric_value, 0.0)
		if _weather_live_mode:
			_apply_live_weather_to_simulation()
	
	elif entity_id == ha_lux_entity and ha_lux_entity != "":
		# Light level in lux
		_ha_lux_override = maxf(numeric_value, 0.0)
		if _weather_live_mode:
			_apply_live_weather_to_simulation()
	
	elif entity_id == ha_rain_rate_entity and ha_rain_rate_entity != "":
		# Rain rate - convert to mm/h if needed
		var rain_rate_val := numeric_value
		if not ha_rain_rate_in_mm:
			# Convert in/h to mm/h
			rain_rate_val = rain_rate_val * 25.4
		_ha_rain_rate_override = maxf(rain_rate_val, 0.0)
		if _weather_live_mode:
			_apply_live_weather_to_simulation()
	
	elif entity_id == ha_rain_state_entity and ha_rain_state_entity != "":
		# Rain state - can be boolean, "on"/"off", "raining"/"not raining", etc.
		var is_raining := false
		var state_lower := state_value.to_lower()
		if state_lower in ["on", "true", "1", "raining", "yes", "rain"]:
			is_raining = true
		elif numeric_value > 0:
			is_raining = true
		_ha_rain_state_override = 1 if is_raining else 0
		if _weather_live_mode:
			_apply_live_weather_to_simulation()
	
	elif entity_id == ha_temperature_entity and ha_temperature_entity != "":
		# Temperature - convert to Celsius if needed
		var temp_val := numeric_value
		if not ha_temp_in_celsius:
			# Convert Fahrenheit to Celsius
			temp_val = (temp_val - 32.0) * 5.0 / 9.0
		_ha_temperature_override = temp_val
	
	elif entity_id == ha_wind_speed_entity and ha_wind_speed_entity != "":
		# Wind speed - convert to m/s if needed
		var wind_val := numeric_value
		if not ha_wind_in_ms:
			# Convert mph to m/s
			wind_val = wind_val * 0.44704
		_ha_wind_speed_override = maxf(wind_val, 0.0)
	
	# Update weather data display
	_update_weather_data_display()


## Apply a mapped CSV playback reading directly to SolarUI overrides.
## Bypasses ha_* entity_id matching so CSV entities can differ from live HA links.
func apply_csv_playback_reading(role: String, value: float) -> void:
	match role:
		"battery_soc":
			_ha_battery_soc_override = clampf(value, 0.0, 100.0)
			battery_kwh_stored = (_ha_battery_soc_override / 100.0) * BATTERY_CAPACITY_KWH
		"solar":
			if ha_values_in_watts:
				_ha_solar_override = value / 1000.0
			else:
				_ha_solar_override = value
		"load":
			if ha_values_in_watts:
				_ha_load_override = value / 1000.0
			else:
				_ha_load_override = value
		"daily_solar":
			_ha_daily_solar_override = value
		"daily_load":
			_csv_daily_load_override = maxf(value, 0.0)
		_:
			pass


## Enable/disable CSV playback mode and record which SolarUI roles are CSV-mapped.
func set_csv_playback_active(active: bool, linked_roles: Dictionary = {}, source_path: String = "") -> void:
	_csv_playback_active = active
	_csv_linked_roles = linked_roles.duplicate() if active else {}
	_csv_graph_source_path = source_path if active else ""
	if not active:
		load_history.clear()
		for i in range(HISTORY_SIZE):
			load_history.append(0.0)
		_ha_battery_soc_override = -1.0
		_ha_solar_override = -1.0
		_ha_load_override = -1.0
		_ha_daily_solar_override = -1.0
		_csv_daily_load_override = -1.0


## Replace the 24h graph with hourly CSV profiles for the current playback day (values in kW).
func set_csv_day_graph(solar_kw_by_hour: Array, load_kw_by_hour: Array) -> void:
	solar_history.clear()
	load_history.clear()
	for i in range(HISTORY_SIZE):
		var sk: float = float(solar_kw_by_hour[i]) if i < solar_kw_by_hour.size() else 0.0
		var lk: float = float(load_kw_by_hour[i]) if i < load_kw_by_hour.size() else 0.0
		solar_history.append(maxf(sk, 0.0))
		load_history.append(maxf(lk, 0.0))
	if solar_graph:
		solar_graph.queue_redraw()


func _is_csv_linked_role(role: String) -> bool:
	return _csv_playback_active and bool(_csv_linked_roles.get(role, false))


func _source_link_icon(role: String, has_override: bool) -> String:
	if not has_override:
		return ""
	if _is_csv_linked_role(role):
		return " 📂"
	return " 📡"

const _SIM_UPDATE_INTERVAL : float = 0.1   # 10 Hz for simulation logic
const _UI_UPDATE_INTERVAL  : float = 0.25  # 4 Hz for display/graph updates
## Match timeline ~450× — above this, weather lighting lerp runs at UI Hz not every frame.
const _HIGH_SPEED_TIME_SCALE : float = 0.125
var _sim_accumulator : float = 0.0
var _ui_accumulator  : float = 0.0
var _lighting_accumulator : float = 0.0

# Smooth interpolation targets for weather lighting (computed at 10 Hz, applied every frame)
var _target_shadow_opacity : float = 1.0
var _target_shadow_blur : float = 0.0
var _target_light_attenuation : float = 1.0
var _current_shadow_opacity : float = 1.0
var _current_shadow_blur : float = 0.0
var _current_light_attenuation : float = 1.0
const _LIGHTING_LERP_SPEED : float = 8.0

# Moon shadow opacity is owned exclusively here (not by main.gd:_update_moon,
# which only controls shadow_enabled/max_distance) so there is a single writer —
# folds lunar phase brightness into the same smoothed cloud target the sun uses.
# Full moon + clear sky ≈ 0.6 opacity (softer than sun), same ceiling main.gd used.
var _current_moon_shadow_opacity : float = 0.3
const _MOON_SHADOW_OPACITY_PEAK : float = 0.6

func _process(delta: float) -> void:
	PerfSpan.begin("solar_ui")
	_perf_tick(delta)
	PerfSpan.end("solar_ui")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	if _is_graph_embed:
		if is_instance_valid(_graph_embed_mirror_from):
			_graph_embed_sync_acc += delta
			if _graph_embed_sync_acc >= _GRAPH_EMBED_SYNC_INTERVAL:
				_graph_embed_sync_acc = 0.0
				_graph_embed_sync_from_source()
		return

	if main_node == null:
		_find_main_node()
		return

	_sim_accumulator += delta
	_ui_accumulator  += delta

	if _sim_accumulator >= _SIM_UPDATE_INTERVAL:
		var sim_step := minf(_sim_accumulator, _SIM_UPDATE_INTERVAL * 2.0)
		_sim_accumulator -= _SIM_UPDATE_INTERVAL
		var _ts_now := float(main_node.get("time_scale") if "time_scale" in main_node else 0.0)
		# Open-Meteo still updates every tick so the display shows the correct
		# archive/forecast/generated value even while paused.
		_update_weather(sim_step)
		if not _open_meteo_active and not _weather_live_mode:
			_generate_simulated_weather_data()
		_calculate_solar_power()
		_apply_graph_pv_shade()
		_poll_aux_generation()
		_apply_soc_protection_before_load()
		_calculate_load_power()
		_apply_battery_full_throttle()
		# Graph DC current-limit throttle (charge controllers × battery bus V) —
		# applied last so neither solar path nor the battery-full lerp can
		# raise delivery back above the wiring's real cap.
		_apply_graph_dc_limit()
		_update_battery(sim_step)
		sim_tick_serial += 1

	if _ui_accumulator >= _UI_UPDATE_INTERVAL:
		_ui_accumulator -= _UI_UPDATE_INTERVAL
		# Scoreboard + 24h history are read-only views over the energy
		# timeline (dropped from the 10 Hz sim tick to this 4 Hz UI tick —
		# the underlying SOC integration above is unaffected).
		if main_node != null and main_node.has_method("get_absolute_hours"):
			_recompute_scoreboard_from_timeline(float(main_node.call("get_absolute_hours")))
		if not _csv_playback_active:
			_update_solar_history()
		_update_display()
		_update_graph()
		_update_weather_data_display()
		if _compare_active:
			_tick_compare_feed()

	# Overload protection — real-time, only while sim clock is running
	if main_node != null:
		var _ts: Variant = main_node.get("time_scale")
		if _ts != null and float(_ts) > 0.0:
			_update_inverter_overload(delta)

	# Smooth lighting every frame near realtime; at high speed, UI-rate is enough
	# (targets still update on the 10 Hz weather tick).
	_lighting_accumulator += delta
	var ts_abs := 0.0
	if main_node != null:
		var tsv: Variant = main_node.get("time_scale")
		if tsv != null:
			ts_abs = absf(float(tsv))
	var lighting_interval := _UI_UPDATE_INTERVAL if ts_abs >= _HIGH_SPEED_TIME_SCALE else 0.0
	if lighting_interval <= 0.0 or _lighting_accumulator >= lighting_interval:
		var light_dt := _lighting_accumulator if lighting_interval > 0.0 else delta
		_lighting_accumulator = 0.0
		_apply_smooth_weather_lighting(light_dt)

## True when real or simulated precipitation should drive rain VFX / status.
func _is_actively_precipitating() -> bool:
	if _weather_live_mode:
		if _ha_rain_state_override == 1:
			return true
		if _ha_rain_state_override == 0:
			return false
		if _ha_rain_rate_override >= 0.0:
			return _ha_rain_rate_override > PRECIP_RAIN_THRESHOLD_MMH
	if _open_meteo_active:
		return _simulated_rain_rate > PRECIP_RAIN_THRESHOLD_MMH
	return weather == WeatherType.RAINY

## Update weather/cloud simulation
func _update_weather(delta: float) -> void:
	# In live weather mode, apply live data first (overrides simulation)
	if _weather_live_mode and _has_any_weather_entity_linked():
		_apply_live_weather_to_simulation()
	
	var time_scale : float = 1.0
	if main_node and "time_scale" in main_node:
		time_scale = main_node.time_scale
	
	# delta * time_scale gives sim-hours (day_time is in hours, advanced by delta * time_scale)
	var sim_hours : float = delta * time_scale
	
	# Weather source priority: live HA > real Open-Meteo (forecast/archive) >
	# synthetic fallback. Real Open-Meteo weather drives automatically whenever a
	# dataset covers the sim location — there is no manual weather picker. The
	# synthetic sim only fills in for offline / uncovered locations.
	if not _weather_live_mode:
		var applied_real := _try_apply_open_meteo_weather()
		if not applied_real and _wx_sim_enabled:
			_wx_advance_simulation(sim_hours)
	
	# Advance cloud noise time (scaled by simulation speed)
	_cloud_noise_time += delta * time_scale * 0.1
	
	# Apply noise-based cloud variation around _base_cloud_cover, clamped to weather range
	if not _weather_live_mode:
		var noise_val : float = sin(_cloud_noise_time * 2.3) * 0.5 + sin(_cloud_noise_time * 5.7) * 0.3 + sin(_cloud_noise_time * 0.7) * 0.2
		var range_min : float
		var range_max : float
		var noise_amplitude : float
		match weather:
			WeatherType.CLEAR:
				range_min = 0.0
				range_max = CLOUD_THRESHOLD_CLEAR_MAX
				noise_amplitude = 0.05
			WeatherType.PARTLY_CLOUDY:
				range_min = CLOUD_THRESHOLD_CLEAR_MAX
				range_max = CLOUD_THRESHOLD_PARTLY_MAX
				noise_amplitude = 0.15
			WeatherType.CLOUDY:
				range_min = CLOUD_THRESHOLD_PARTLY_MAX
				range_max = CLOUD_THRESHOLD_CLOUDY_MAX
				noise_amplitude = 0.15
			WeatherType.RAINY:
				range_min = CLOUD_THRESHOLD_CLOUDY_MAX
				range_max = 1.0
				noise_amplitude = 0.05
		# clampf does NOT filter NaN (NaN<min and NaN>max are both false), so a
		# bad _base_cloud_cover would pass straight through and ultimately reach
		# DirectionalLight3D.light_energy → GPU hang. Sanitize the base first.
		if not is_finite(_base_cloud_cover):
			_base_cloud_cover = 0.0
		cloud_cover = clampf(_base_cloud_cover + noise_val * noise_amplitude, range_min, range_max)
		if not is_finite(cloud_cover):
			cloud_cover = 0.0
	
	_update_sky_visuals()
	_update_weather_lighting()
	_update_rain_system(delta)

## Update sky shader parameters from the current cloud_cover value.
func _update_sky_visuals() -> void:
	if main_node == null:
		return
	
	# clouds_cutoff: 1.0 = clear, 0.0 = maximum clouds — inverse of cloud_cover
	# The site's microclimate adjusts what the SKY shows only: it takes ERA5's
	# fog-as-100 %-low-cloud back out of the overhead deck (the fog is drawn on
	# the ground instead) and adds any calibrated cloud. cloud_cover itself —
	# which the PV and lighting physics read — is untouched.
	var sky_cover : float = cloud_cover
	var mc := get_node_or_null("/root/Microclimate")
	if mc != null and not _user_weather_manual_override:
		var st: Dictionary = mc.call("current")
		sky_cover = clampf(cloud_cover + float(st.get("cloud_delta", 0.0)), 0.0, 1.0)
	var target_cutoff : float = 1.0 - sky_cover
	# Storm darkness only when precipitation is active — scale with rate so drizzle
	# stays grey/overcast instead of near-black (full storm weight was drowning rain VFX).
	var target_weight : float = 0.0
	if _is_actively_precipitating():
		var storm := clampf((cloud_cover - 0.75) / 0.25, 0.0, 1.0)
		var rain_t := PrecipitationVfx.rain_intensity_t(_current_precip_rate_mmh())
		target_weight = storm * lerpf(0.2, 0.75, rain_t)
	
	if "clouds_cutoff" in main_node:
		main_node.clouds_cutoff = target_cutoff
	if "clouds_weight" in main_node:
		main_node.clouds_weight = target_weight
	# High wispy cirrus is most visible in fair / partly-cloudy skies and gets
	# masked out under heavy overcast or storms (the cumulus/nimbus layer dominates).
	# Ramps up from true zero at a perfectly clear cloud_cover so the sky can
	# actually go fully clear (previously a flat +0.15 floor meant cirrus never
	# fully vanished even at cloud_cover == 0). Scaled by the user's gear-panel
	# cirrus multiplier.
	if "cirrus_amount" in main_node:
		var cirrus_ramp : float = smoothstep(0.0, 0.55, cloud_cover)
		var cirrus : float = clampf(cirrus_ramp * 0.6, 0.0, 0.6) * (1.0 - smoothstep(0.6, 0.95, cloud_cover))
		var scale : float = 1.0
		if "cirrus_user_scale" in main_node:
			scale = float(main_node.cirrus_user_scale)
		main_node.cirrus_amount = clampf(cirrus * scale, 0.0, 1.0)
	if "rainbow_strength" in main_node:
		main_node.rainbow_strength = _compute_rainbow_strength()
	
	if not _slider_is_driving:
		_sync_time_ui_cloud_sliders(target_cutoff, target_weight)

## Sync the TimeUI cloud sliders to match weather-controlled values
func _sync_time_ui_cloud_sliders(cutoff: float, weight: float) -> void:
	if _cached_time_ui == null or not is_instance_valid(_cached_time_ui):
		var tree := get_tree()
		if tree == null:
			return
		# The legacy TimeUI is a hidden shim and is MISSING on every current
		# scene: without this negative cache the root walk below ran at 10 Hz
		# for the whole session. Re-looked every few seconds in case it lands.
		var now_ms := Time.get_ticks_msec()
		if now_ms - _time_ui_lookup_ms < 5000:
			return
		_time_ui_lookup_ms = now_ms
		_cached_time_ui = tree.root.get_node_or_null("Main/CanvasLayer/TimeUI")
		if _cached_time_ui == null:
			for child in tree.root.get_children():
				var canvas = child.get_node_or_null("CanvasLayer/TimeUI")
				if canvas:
					_cached_time_ui = canvas
					break

	if _cached_time_ui == null:
		return
	
	var cutoff_slider = _cached_time_ui.get_node_or_null("Panel/MarginContainer/ScrollContainer/VBoxContainer/CloudsSection/CloudsCutoffSlider")
	var weight_slider = _cached_time_ui.get_node_or_null("Panel/MarginContainer/ScrollContainer/VBoxContainer/CloudsSection/CloudsWeightSlider")
	
	if cutoff_slider and cutoff_slider is HSlider:
		cutoff_slider.set_value_no_signal(1.0 - cutoff)
	
	if weight_slider and weight_slider is HSlider:
		weight_slider.set_value_no_signal(weight)

## Compute target shadow/lighting values from cloud cover (called at 10 Hz).
## Actual application is smoothly interpolated every frame in _apply_smooth_weather_lighting.
func _update_weather_lighting() -> void:
	if main_node == null:
		return
	
	var attenuation := clampf(1.0 - cloud_cover * 0.85, 0.15, 1.0)
	if _is_actively_precipitating():
		var rain_t := PrecipitationVfx.rain_intensity_t(_current_precip_rate_mmh())
		# Light drizzle keeps more sun; heavy rain can dim further.
		attenuation = maxf(attenuation, lerpf(0.5, 0.18, rain_t))
	_target_light_attenuation = attenuation
	_target_shadow_opacity = clampf(1.0 - cloud_cover * 0.95, 0.05, 1.0)
	_target_shadow_blur = cloud_cover * 2.0

## Smoothly interpolate shadow/lighting values toward targets every frame to avoid strobing.
func _apply_smooth_weather_lighting(delta: float) -> void:
	if main_node == null:
		return
	
	var t := clampf(_LIGHTING_LERP_SPEED * delta, 0.0, 1.0)
	# Guard the cloud-derived targets: a non-finite value here lerps to NaN and
	# is forwarded to main.weather_light_factor → sun/moon light_energy → GPU hang.
	if not is_finite(_target_light_attenuation):
		_target_light_attenuation = 1.0
	if not is_finite(_target_shadow_opacity):
		_target_shadow_opacity = 1.0
	if not is_finite(_target_shadow_blur):
		_target_shadow_blur = 0.0
	_current_shadow_opacity = lerpf(_current_shadow_opacity, _target_shadow_opacity, t)
	_current_shadow_blur = lerpf(_current_shadow_blur, _target_shadow_blur, t)
	_current_light_attenuation = lerpf(_current_light_attenuation, _target_light_attenuation, t)
	if not is_finite(_current_light_attenuation):
		_current_light_attenuation = 1.0
	
	if not _weather_live_mode or _ha_wind_speed_override < 0.0:
		_simulated_wind_speed = lerpf(_simulated_wind_speed, _target_wind_speed,
			clampf(WIND_DISPLAY_LERP_SPEED * delta, 0.0, 1.0))
	
	var sun : DirectionalLight3D = main_node.get("sun") as DirectionalLight3D
	var moon : DirectionalLight3D = main_node.get("moon") as DirectionalLight3D
	
	if sun:
		sun.shadow_opacity = _current_shadow_opacity
		sun.shadow_blur = _current_shadow_blur
		main_node.weather_light_factor = _current_light_attenuation
	
	if moon:
		# Sole owner of moon.shadow_opacity (main.gd:_update_moon only toggles
		# shadow_enabled/max_distance) — folds lunar phase brightness into the
		# same smoothed cloud target the sun uses, so opacity glides instead of
		# fighting a second writer on a different clock.
		var moon_phase_brightness := 0.0
		if main_node.has_method("get_lunar_phase_brightness"):
			moon_phase_brightness = float(main_node.call("get_lunar_phase_brightness"))
		var target_moon_opacity := clampf(
			moon_phase_brightness * _current_light_attenuation * _MOON_SHADOW_OPACITY_PEAK, 0.1, _MOON_SHADOW_OPACITY_PEAK)
		if not is_finite(target_moon_opacity):
			target_moon_opacity = 0.1
		_current_moon_shadow_opacity = lerpf(_current_moon_shadow_opacity, target_moon_opacity, t)
		moon.shadow_opacity = _current_moon_shadow_opacity
		moon.shadow_blur = _current_shadow_blur

# ==================== RAIN SYSTEM ====================

## Find ground materials for wetness effects
func _find_ground_materials() -> void:
	_ground_materials.clear()
	_original_ground_roughness.clear()
	_original_ground_albedo.clear()
	
	var tree := get_tree()
	if tree == null:
		return
	
	# Find floor mesh and terrain
	var floor_mesh = tree.root.get_node_or_null("Main/FloorMesh")
	if floor_mesh and floor_mesh is MeshInstance3D:
		var mat = floor_mesh.get_surface_override_material(0)
		if mat == null and floor_mesh.mesh:
			mat = floor_mesh.mesh.surface_get_material(0)
		if mat and mat is StandardMaterial3D:
			_ground_materials.append(mat)
			_original_ground_roughness.append(mat.roughness)
			_original_ground_albedo.append(mat.albedo_color)

## "none" | "rain" | "snow" — frozen precip uses snowflakes, not rain streaks.
func _precip_kind() -> String:
	if not _is_actively_precipitating():
		return "none"
	if _open_meteo_active and main_node != null:
		var m := int(main_node.month)
		var d := int(main_node.day)
		var h := float(main_node.day_time)
		var t := WeatherService.temperature_c(m, d, h)
		if is_finite(t) and t <= SeasonModel.SNOW_T_THRESHOLD_C:
			return "snow"
		var sf := WeatherService.snowfall_cm(m, d, h)
		if not is_nan(sf) and sf > 0.01:
			return "snow"
	return "rain"


func _current_snowfall_cmh() -> float:
	if not _open_meteo_active or main_node == null:
		return 0.0
	var sf := WeatherService.snowfall_cm(int(main_node.month), int(main_node.day), float(main_node.day_time))
	return maxf(sf, 0.0) if not is_nan(sf) else 0.0


func _is_thunderstorm() -> bool:
	if not _is_actively_precipitating():
		return false
	if cloud_cover < 0.75:
		return false
	return _current_precip_rate_mmh() > 2.0


func _thunderstorm_intensity() -> float:
	var storm := clampf((cloud_cover - 0.75) / 0.25, 0.0, 1.0)
	var rain_t := PrecipitationVfx.rain_intensity_t(_current_precip_rate_mmh())
	return storm * rain_t


func _compute_rainbow_strength() -> float:
	if main_node == null or not is_instance_valid(main_node.sun):
		return 0.0
	# Debug/test override: force the bow on regardless of rain. The shader still gates
	# on geometry (sun low + arc above horizon), so it only shows when angles are right.
	var force := SimSettingsController != null and SimSettingsController.force_rainbow
	if not force and _precip_kind() != "rain":
		return 0.0
	var sun_dir: Vector3 = main_node.sun.to_global(Vector3(0.0, 0.0, 1.0)).normalized()
	# Loosen sun angle requirement so it can be seen closer to horizon
	if sun_dir.y < -0.05:
		return 0.0
	if force:
		return 1.0
	
	# Any rain during daytime creates a chance for a rainbow. 
	# Sun must be peeking through, so we require cloud_cover not to be 1.0 (fully overcast)
	var sun_visibility := 1.0 - clampf((cloud_cover - 0.8) / 0.2, 0.0, 1.0)
	if sun_visibility <= 0.01:
		return 0.0
	
	var rain_t := PrecipitationVfx.rain_intensity_t(_current_precip_rate_mmh())
	return rain_t * sun_visibility


func _ensure_environment_vfx() -> void:
	if main_node == null:
		return
	if _precip_vfx == null:
		_precip_vfx = main_node.get_node_or_null("PrecipitationVfx") as PrecipitationVfx
	if _lightning_vfx == null:
		_lightning_vfx = main_node.get_node_or_null("LightningVfx") as LightningVfx


## Active precipitation rate in mm/h (HA live, Open-Meteo/generated, or legacy synthetic).
func _current_precip_rate_mmh() -> float:
	if _weather_live_mode:
		if _ha_rain_rate_override >= 0.0:
			return _ha_rain_rate_override
		if _ha_rain_state_override == 1:
			return 2.0  # moderate default when only a rain-state sensor is linked
	if _open_meteo_active or _simulated_rain_rate > 0.0:
		return _simulated_rain_rate
	if weather == WeatherType.RAINY:
		return maxf(rain_rate_per_hour * 25.4, 0.5)
	return 0.0


## Update precipitation VFX, lightning, and ground-wetness each frame.
func _update_rain_system(delta: float) -> void:
	if main_node == null:
		return
	
	var current_day : int = main_node.day if "day" in main_node else 1
	
	# Reset rain accumulation on new day
	if current_day != _last_rain_day:
		# Check if we should clear mud (new non-rainy day)
		if weather != WeatherType.RAINY and is_ground_muddy:
			_clear_mud()
		
		# Reset daily rain
		daily_rain_inches = 0.0
		
		# If starting a rainy day, pick random rain amount
		if weather == WeatherType.RAINY:
			# Random rain between 0.1" and 2.0" per day
			var total_daily_rain : float = randf_range(0.1, 2.0)
			# Calculate rain rate (assume rain falls over ~8-12 hours)
			var rain_hours : float = randf_range(8.0, 12.0)
			rain_rate_per_hour = total_daily_rain / rain_hours
		
		_last_rain_day = current_day
	
	var precip_rate_mmh := _current_precip_rate_mmh()
	var kind := _precip_kind()
	var snow_cmh := _current_snowfall_cmh()
	if kind == "snow" and snow_cmh < 0.01 and precip_rate_mmh > PRECIP_RAIN_THRESHOLD_MMH:
		snow_cmh = maxf(precip_rate_mmh * 0.1, 0.05)
	var wind_down := Vector2(0.0, 1.0)
	# 10 m wind speed: slants the rain (light drops blow over, heavy ones fall
	# nearly straight) — 0 = still air when no weather data drives the scene.
	var wind_ms := 0.0
	if main_node != null and _open_meteo_active:
		var from_deg := WeatherService.wind_direction_deg(
			int(main_node.month), int(main_node.day), float(main_node.day_time))
		wind_down = WindMath.downwind_xz(from_deg)
		wind_ms = WeatherService.wind_speed_ms(
			int(main_node.month), int(main_node.day), float(main_node.day_time))
		if not is_finite(wind_ms):
			wind_ms = 0.0
	_ensure_environment_vfx()
	if _precip_vfx != null:
		_precip_vfx.update_frame(delta, kind, precip_rate_mmh, snow_cmh, wind_down,
			_get_rain_follow_position(), wind_ms)
	if _lightning_vfx != null:
		_lightning_vfx.set_storm_active(_is_thunderstorm(), _thunderstorm_intensity())
	
	# Accumulate rain if precipitating
	if _is_actively_precipitating():
		var time_scale : float = 1.0
		if main_node and "time_scale" in main_node:
			time_scale = main_node.time_scale
		
		# Add rain based on simulated time elapsed (rate in mm/h → inches).
		var simulated_hours : float = delta * time_scale
		daily_rain_inches += (precip_rate_mmh / 25.4) * simulated_hours
		
		# Check if we've hit mud threshold
		if daily_rain_inches >= MUD_THRESHOLD_INCHES and not is_ground_muddy:
			_apply_mud()

## Get player reference
func _get_player() -> CharacterBody3D:
	var tree := get_tree()
	if tree == null:
		return null
	
	var player = tree.root.get_node_or_null("Main/Player")
	if player and player is CharacterBody3D:
		return player
	
	# Search for player
	for child in tree.root.get_children():
		var p = child.get_node_or_null("Player")
		if p and p is CharacterBody3D:
			return p
	
	return null


## World position for the precipitation volume — centred on the active camera so
## flakes/streaks fill the sky as well as the ground half of the view.
func _get_rain_follow_position() -> Vector3:
	var player := _get_player()
	if player == null:
		return Vector3.ZERO
	var cam := player.get_node_or_null("CameraArm/Camera3D") as Camera3D
	if cam != null:
		return cam.global_position
	return player.global_position + Vector3(0, 1.6, 0)


## Apply mud effects (wet ground + slow player)
func _apply_mud() -> void:
	is_ground_muddy = true
	
	# Wet ground effect - reduce roughness, darken color
	for i in range(_ground_materials.size()):
		var mat := _ground_materials[i]
		# Wet ground is shinier (lower roughness)
		mat.roughness = _original_ground_roughness[i] * 0.3
		# Slightly metallic for water sheen
		mat.metallic = 0.2
		# Darken albedo (wet surfaces appear darker)
		var dark_color := _original_ground_albedo[i] * 0.6
		dark_color.a = 1.0
		mat.albedo_color = dark_color
	
	# Slow down player
	var player := _get_player()
	if player:
		# Store original speeds if not already stored
		if _original_player_move_speed < 0:
			_original_player_move_speed = player.move_speed
			_original_player_sprint_speed = player.sprint_speed
		
		# Apply mud speed penalty
		player.move_speed = _original_player_move_speed * PLAYER_MUD_SPEED_FACTOR
		player.sprint_speed = _original_player_sprint_speed * PLAYER_MUD_SPEED_FACTOR

## Clear mud effects (restore ground and player speed)
func _clear_mud() -> void:
	is_ground_muddy = false
	
	# Restore ground materials
	for i in range(_ground_materials.size()):
		var mat := _ground_materials[i]
		mat.roughness = _original_ground_roughness[i]
		mat.metallic = 0.0
		mat.albedo_color = _original_ground_albedo[i]
	
	# Restore player speed
	var player := _get_player()
	if player and _original_player_move_speed > 0:
		player.move_speed = _original_player_move_speed
		player.sprint_speed = _original_player_sprint_speed

## Apply battery-full throttling to solar output
## When battery is full, inverter reduces solar to only match current load
func _apply_battery_full_throttle() -> void:
	var battery_percent_val : float = (battery_kwh_stored / BATTERY_CAPACITY_KWH) * 100.0
	
	# When battery is nearly full (>95%), throttle solar to match load
	# What the array must cover once the battery takes nothing: the load less
	# any other generation already feeding the bus.
	var need_kw : float = maxf(current_load_kw - current_aux_generation_kw - current_graph_dc_kw, 0.0)
	if battery_percent_val >= 95.0 and _raw_solar_kw > need_kw:
		# Gradually increase throttling as battery fills
		var throttle_factor : float = (battery_percent_val - 95.0) / 5.0  # 0 at 95%, 1 at 100%
		throttle_factor = clampf(throttle_factor, 0.0, 1.0)
		# Blend between full solar and load-matched solar. The top-off margin
		# tapers to nothing at 100 %: a constant +0.1 kW read as "charging
		# 100 W" on a full battery while the SOC clamp threw it away.
		var top_off : float = 0.1 * (1.0 - throttle_factor)
		current_solar_kw = lerpf(_raw_solar_kw, need_kw + top_off, throttle_factor)
		current_solar_kw = maxf(current_solar_kw, 0.0)

## Set the weather type (affects cloud cover simulation)
func set_weather(new_weather: WeatherType) -> void:
	# Manual weather change disables autonomous simulation and opts out of
	# real Open-Meteo weather until the user returns to Auto.
	_wx_sim_enabled = false
	_user_weather_manual_override = true

	var was_rainy := (weather == WeatherType.RAINY)
	weather = new_weather
	_cloud_noise_time = randf() * 100.0
	
	if new_weather == WeatherType.RAINY and not was_rainy:
		var total_daily_rain : float = randf_range(0.1, 2.0)
		var rain_hours : float = randf_range(8.0, 12.0)
		rain_rate_per_hour = total_daily_rain / rain_hours
		daily_rain_inches = 0.0
	
	match new_weather:
		WeatherType.CLEAR:
			_base_cloud_cover = CLOUD_REPR_CLEAR
		WeatherType.PARTLY_CLOUDY:
			_base_cloud_cover = CLOUD_REPR_PARTLY
		WeatherType.CLOUDY:
			_base_cloud_cover = CLOUD_REPR_CLOUDY
		WeatherType.RAINY:
			_base_cloud_cover = CLOUD_REPR_RAINY
	
	_update_weather(0.0)

## Derive weather type from cloud cover. Precipitation is handled separately —
## overcast skies alone must not become RAINY.
func _weather_from_cloud_cover(cover: float) -> WeatherType:
	if cover < CLOUD_THRESHOLD_CLEAR_MAX:
		return WeatherType.CLEAR
	elif cover < CLOUD_THRESHOLD_PARTLY_MAX:
		return WeatherType.PARTLY_CLOUDY
	else:
		return WeatherType.CLOUDY

## Called by TimeUI when the user drags the cloud cover slider.
func set_cloud_cover_from_slider(cover: float) -> void:
	_wx_sim_enabled = false
	_user_weather_manual_override = true
	_base_cloud_cover = clampf(cover, 0.0, 1.0)
	_wx_sim_cloud_cover = _base_cloud_cover
	var new_weather := _weather_from_cloud_cover(_base_cloud_cover)
	
	if new_weather != weather:
		var was_rainy := (weather == WeatherType.RAINY)
		weather = new_weather
		_cloud_noise_time = randf() * 100.0
		if new_weather == WeatherType.RAINY and not was_rainy:
			var total_daily_rain : float = randf_range(0.1, 2.0)
			var rain_hours : float = randf_range(8.0, 12.0)
			rain_rate_per_hour = total_daily_rain / rain_hours
			daily_rain_inches = 0.0
		_update_weather_button()
	
	cloud_cover = _base_cloud_cover
	_slider_is_driving = true
	_update_sky_visuals()
	_update_weather_lighting()
	_slider_is_driving = false

# ==================== WEATHER SIMULATION ENGINE ====================

## Get seasonal climate parameters for the current month (0-indexed internally).
func _wx_get_monthly_params() -> Dictionary:
	var m : int = 0
	if main_node and "month" in main_node:
		m = clampi(int(main_node.month) - 1, 0, 11)
	return {
		"mean_cloud_cover": _WX_MONTHLY_CLOUD_COVER[m],
		"rain_chance": _WX_MONTHLY_RAIN_CHANCE[m],
	}

## Pick a random duration for a weather state, scaled by season.
## Clearer months get longer clear spells and shorter cloudy spells.
func _wx_pick_duration(weather_state: WeatherType, params: Dictionary) -> float:
	var dur_range : Vector2
	match weather_state:
		WeatherType.CLEAR:
			dur_range = _WX_DURATION_CLEAR
		WeatherType.PARTLY_CLOUDY:
			dur_range = _WX_DURATION_PARTLY
		WeatherType.CLOUDY:
			dur_range = _WX_DURATION_CLOUDY
		WeatherType.RAINY:
			dur_range = _WX_DURATION_RAINY
		_:
			dur_range = _WX_DURATION_CLEAR
	
	var mean_cc : float = params.mean_cloud_cover
	if weather_state == WeatherType.CLEAR:
		# Clearer months -> longer clear spells (scale up toward max)
		var clear_bias : float = 1.0 - mean_cc  # higher in clear months
		return lerpf(dur_range.x, dur_range.y, clear_bias * randf_range(0.5, 1.0))
	else:
		# Cloudier months -> longer cloudy spells
		var cloud_bias : float = mean_cc
		return lerpf(dur_range.x, dur_range.y, cloud_bias * randf_range(0.5, 1.0))

## Determine the next weather state based on current state and seasonal probabilities.
func _wx_pick_next_state(current: WeatherType, params: Dictionary) -> WeatherType:
	var mean_cc : float = params.mean_cloud_cover
	var rain_chance : float = params.rain_chance
	
	match current:
		WeatherType.CLEAR:
			# Chance to develop clouds proportional to monthly mean cloud cover
			if randf() < mean_cc * 1.5:
				return WeatherType.PARTLY_CLOUDY
			return WeatherType.CLEAR
		WeatherType.PARTLY_CLOUDY:
			# Can go either way - back to clear or build to cloudy
			var r := randf()
			if r < 0.4:
				return WeatherType.CLEAR
			elif r < 0.4 + mean_cc * 0.8:
				return WeatherType.CLOUDY
			return WeatherType.PARTLY_CLOUDY
		WeatherType.CLOUDY:
			# Can develop rain (rare in desert) or break up
			var r := randf()
			if r < rain_chance * 8.0:
				return WeatherType.RAINY
			elif r < 0.5:
				return WeatherType.PARTLY_CLOUDY
			return WeatherType.CLOUDY
		WeatherType.RAINY:
			# Rain is always short in the desert; transitions back to cloudy
			return WeatherType.CLOUDY
	return WeatherType.CLEAR

## Advance the weather simulation by sim_hours. Called from _update_weather().
## Sets _wx_sim_cloud_cover which feeds into _base_cloud_cover when autonomous.
func _wx_advance_simulation(sim_hours: float) -> void:
	if sim_hours <= 0.0:
		return
	
	_wx_sim_hours_in_state += sim_hours
	
	if _wx_sim_hours_in_state >= _wx_sim_state_duration:
		_wx_sim_hours_in_state = 0.0
		var params := _wx_get_monthly_params()
		var next_state := _wx_pick_next_state(weather, params)
		
		if next_state != weather:
			var was_rainy := (weather == WeatherType.RAINY)
			weather = next_state
			_cloud_noise_time = randf() * 100.0
			
			if next_state == WeatherType.RAINY and not was_rainy:
				var total_daily_rain : float = randf_range(0.1, 0.8)
				var rain_hours : float = randf_range(1.0, 4.0)
				rain_rate_per_hour = total_daily_rain / rain_hours
				daily_rain_inches = 0.0
			
			_update_weather_button()
		
		_wx_sim_state_duration = _wx_pick_duration(weather, params)
	
	# Set the simulation's target cloud cover based on weather state
	match weather:
		WeatherType.CLEAR:
			_wx_sim_cloud_cover = lerpf(_wx_sim_cloud_cover, CLOUD_REPR_CLEAR, clampf(sim_hours * 0.5, 0.0, 1.0))
		WeatherType.PARTLY_CLOUDY:
			_wx_sim_cloud_cover = lerpf(_wx_sim_cloud_cover, CLOUD_REPR_PARTLY, clampf(sim_hours * 0.3, 0.0, 1.0))
		WeatherType.CLOUDY:
			_wx_sim_cloud_cover = lerpf(_wx_sim_cloud_cover, CLOUD_REPR_CLOUDY, clampf(sim_hours * 0.3, 0.0, 1.0))
		WeatherType.RAINY:
			_wx_sim_cloud_cover = lerpf(_wx_sim_cloud_cover, CLOUD_REPR_RAINY, clampf(sim_hours * 0.5, 0.0, 1.0))
	
	_base_cloud_cover = _wx_sim_cloud_cover

## True while Open-Meteo data is driving the weather (for UI/debug).
var _open_meteo_active: bool = false
## True when _open_meteo_active and the data came from the forecast window
## (i.e. sim date is within the ~21-day real forecast range).
var _forecast_active: bool = false
## True when stochastic generated weather is the active sample source.
var _generated_weather_active: bool = false


## Drive weather from the WeatherService Open-Meteo archive dataset when one
## covers the sim location. Returns false (caller falls back to the synthetic
## state machine) when no data is available. Unlike
## set_cloud_cover_from_history this leaves _wx_sim_enabled untouched so the
## simulation resumes seamlessly if data coverage goes away.
func _try_apply_open_meteo_weather() -> bool:
	_open_meteo_active = false
	_forecast_active = false
	_generated_weather_active = false
	if main_node == null:
		return false
	# Keep the VISIBLE sky in step with the baked numbers during a clear-sky
	# run; otherwise the world could be overcast while the graph charges as if
	# it were not, which is precisely the link the run is meant to teach.
	if _clear_sky_override:
		cloud_cover = 0.0
		return false
	var ws := get_node_or_null("/root/WeatherService")
	if ws == null or not ws.has_method("covers"):
		return false
	var lat: Variant = main_node.get("latitude")
	var lon: Variant = main_node.get("longitude")
	if lat == null or lon == null or not bool(ws.call("covers", float(lat), float(lon))):
		return false
	var m: int = int(main_node.get("month")) if main_node.get("month") != null else 6
	var d: int = int(main_node.get("day")) if main_node.get("day") != null else 15
	var h: float = float(main_node.get("day_time")) if main_node.get("day_time") != null else 12.0

	var cover: float = float(ws.call("cloud_cover_frac", m, d, h))
	if is_nan(cover):
		return false
	_open_meteo_active = true
	if ws.has_method("get_sample_source"):
		var src := str(ws.call("get_sample_source", m, d, h, false))
		_forecast_active = src == "forecast"
		_generated_weather_active = src == "generated"
	elif ws.has_method("is_forecast_date"):
		_forecast_active = bool(ws.call("is_forecast_date", m, d))

	# Cloud cover + weather type (rain wins over the cover-derived type).
	_base_cloud_cover = clampf(cover, 0.0, 1.0)
	_wx_sim_cloud_cover = _base_cloud_cover
	var rain_mmh: float = float(ws.call("rain_rate_mmh", m, d, h))
	var new_weather: WeatherType
	var precipitating := not is_nan(rain_mmh) and rain_mmh > PRECIP_RAIN_THRESHOLD_MMH
	if precipitating:
		new_weather = WeatherType.RAINY
		rain_rate_per_hour = rain_mmh / 25.4  # mm/h → in/h
	else:
		new_weather = _weather_from_cloud_cover(_base_cloud_cover)
		if weather == WeatherType.RAINY:
			rain_rate_per_hour = 0.0
	if new_weather != weather:
		weather = new_weather
		_update_weather_button()

	# Real measurements override the synthetic sensor values.
	var t: float = float(ws.call("temperature_c", m, d, h))
	if not is_nan(t):
		_simulated_temperature = t
	var wind: float = float(ws.call("wind_speed_ms", m, d, h))
	if not is_nan(wind):
		_target_wind_speed = wind
	var rad: float = float(ws.call("solar_radiation_wm2", m, d, h))
	if not is_nan(rad):
		_simulated_solar_radiation = rad
		_simulated_lux = rad * 110.0
	if not is_nan(rain_mmh):
		_simulated_rain_rate = maxf(rain_mmh, 0.0)
	# New fields: humidity, wind direction, 24h rain.
	if ws.has_method("humidity_pct"):
		_simulated_humidity = float(ws.call("humidity_pct", m, d, h))
	if ws.has_method("wind_direction_deg"):
		_simulated_wind_direction = float(ws.call("wind_direction_deg", m, d, h))
	if ws.has_method("rain_24h_mm"):
		_simulated_rain_24h_mm = float(ws.call("rain_24h_mm", m, d, h))
	return true


## Provide cloud cover from an external data source (e.g., HA historical data).
## Call this instead of _wx_advance_simulation when playing back recorded weather.
func set_cloud_cover_from_history(cover: float) -> void:
	_wx_sim_enabled = false
	_base_cloud_cover = clampf(cover, 0.0, 1.0)
	_wx_sim_cloud_cover = _base_cloud_cover
	var new_weather := _weather_from_cloud_cover(_base_cloud_cover)
	if new_weather != weather:
		weather = new_weather
		_update_weather_button()

## The direction TO the sun, from the clock. Main only re-aims the sun
## DirectionalLight while the 3D world is drawn (it skips that work while the
## graph is open), so reading the light froze solar output at whatever it was
## when the graph opened — the sun "stopped" while the clock ran on. The clock's
## direction is the one the light is aimed from (main._update_sun), so this is
## the same value whenever the light IS current. ZERO when there is no sun.
func _sun_direction() -> Vector3:
	if main_node == null:
		return Vector3.ZERO
	var clock_obj: Variant = main_node.get("clock")
	if clock_obj is Object and (clock_obj as Object).has_method("get_sun_direction"):
		var d: Vector3 = (clock_obj as Object).call("get_sun_direction")
		if d.length() > 0.001:
			return d.normalized()
	if not "sun" in main_node:
		return Vector3.ZERO
	var sun := main_node.get("sun") as DirectionalLight3D
	if sun == null or not is_instance_valid(sun):
		return Vector3.ZERO
	return sun.global_transform.basis.z.normalized()


func _calculate_solar_power() -> void:
	if PANEL_COUNT <= 0 or PEAK_CAPACITY_KW <= 0.0:
		current_solar_kw = 0.0
		_raw_solar_kw = 0.0
		return
	# Use HA override if available
	if _ha_solar_override >= 0.0:
		current_solar_kw = _ha_solar_override
		_raw_solar_kw = _ha_solar_override
		return

	# High-accuracy mode: Meeus SPA + Erbs GHI decomposition + real ambient temp + optional shadow
	if _high_accuracy_physics:
		_calculate_solar_power_enhanced()
		return

	var sun_direction : Vector3 = _sun_direction()
	if sun_direction == Vector3.ZERO:
		current_solar_kw = 0.0
		_raw_solar_kw = 0.0
		return
	var sun_elevation_rad : float = asin(sun_direction.y)
	var sun_elevation_deg : float = rad_to_deg(sun_elevation_rad)
	
	if sun_elevation_deg < -2.0:
		current_solar_kw = 0.0
		_raw_solar_kw = 0.0
		return
	
	var dni : float = _calculate_dni(sun_elevation_deg)
	var dhi : float = _calculate_dhi(sun_elevation_deg, dni)
	var panel_normal : Vector3 = _get_panel_normal()
	
	var cos_incidence : float = sun_direction.dot(panel_normal)
	cos_incidence = maxf(cos_incidence, 0.0)
	
	var iam : float = _calculate_iam(cos_incidence)
	var beam_component : float = dni * cos_incidence * iam
	
	var tilt_rad : float = deg_to_rad(panel_tilt_degrees)
	var diffuse_factor : float = (1.0 + cos(tilt_rad)) / 2.0
	var diffuse_component : float = dhi * diffuse_factor
	
	var ground_albedo : float = 0.25
	var ghi : float = dni * maxf(sin(sun_elevation_rad), 0.0) + dhi
	var ground_reflected : float = ghi * ground_albedo * (1.0 - cos(tilt_rad)) / 2.0
	
	var poa_irradiance : float = beam_component + diffuse_component + ground_reflected
	poa_irradiance = minf(poa_irradiance, 1200.0)
	
	# Apply cloud cover effects
	# Clouds reduce direct beam significantly, but diffuse light still gets through
	if cloud_cover > 0.0:
		# Direct beam is heavily reduced by clouds
		var beam_reduction : float = 1.0 - cloud_cover * 0.95  # Up to 95% reduction
		beam_component *= beam_reduction
		
		# Diffuse actually increases slightly with light clouds, then decreases
		var diffuse_modifier : float = 1.0
		if cloud_cover < 0.3:
			diffuse_modifier = 1.0 + cloud_cover * 0.5  # Light clouds scatter more light
		else:
			diffuse_modifier = 1.15 - (cloud_cover - 0.3) * 0.7  # Heavy clouds reduce all
		diffuse_component *= diffuse_modifier
		
		# Ground reflected also affected
		ground_reflected *= (1.0 - cloud_cover * 0.5)
		
		# Recalculate POA with cloud effects
		poa_irradiance = beam_component + diffuse_component + ground_reflected
		poa_irradiance = maxf(poa_irradiance, 0.0)
	
	var ambient_temp : float = _estimate_ambient_temp()
	var cell_temp : float = ambient_temp + (poa_irradiance / 800.0) * (NOCT - 20.0)
	var temp_factor : float = 1.0 + TEMP_COEFFICIENT * (cell_temp - 25.0)
	temp_factor = clampf(temp_factor, 0.7, 1.05)
	
	var system_efficiency : float = INVERTER_EFFICIENCY * WIRING_LOSSES * MISMATCH_LOSSES * SOILING_FACTOR * DEGRADATION
	var irradiance_ratio : float = poa_irradiance / STC_IRRADIANCE
	var dc_power_kw : float = PEAK_CAPACITY_KW * irradiance_ratio * temp_factor
	
	current_solar_kw = dc_power_kw * system_efficiency * SYSTEM_CALIBRATION
	current_solar_kw = maxf(current_solar_kw, 0.0)
	
	# Apply inverter clipping (PowMR LVM5K max solar input)
	current_solar_kw = minf(current_solar_kw, INVERTER_MAX_SOLAR_KW)
	
	# Store raw solar before any throttling
	_raw_solar_kw = current_solar_kw


## High-accuracy solar power calculation.
## Uses Meeus Ch.25 SPA for sun position, Erbs GHI decomposition when real
## irradiance is available, real ambient temperature from WeatherService,
## and an optional 3D shadow raycast. Falls back gracefully at each step.
func _calculate_solar_power_enhanced() -> void:
	if PANEL_COUNT <= 0 or PEAK_CAPACITY_KW <= 0.0:
		current_solar_kw = 0.0
		_raw_solar_kw = 0.0
		return
	if main_node == null:
		current_solar_kw = 0.0
		_raw_solar_kw = 0.0
		return

	# --- Sun position: Meeus SPA preferred, DirectionalLight3D fallback ---
	var sun_el_deg : float = 0.0
	var sun_az_deg : float = 180.0

	var lat_v = main_node.get("latitude")
	var lon_v = main_node.get("longitude")
	var lat : float = float(lat_v) if lat_v != null else 33.36
	var lon : float = float(lon_v) if lon_v != null else -115.74

	var clock_obj = main_node.get("clock")
	if clock_obj != null and clock_obj.has_method("get_julian_day_utc"):
		var jd_utc : float = float(clock_obj.call("get_julian_day_utc"))
		var sp := SolarPosition.get_position(lat, lon, jd_utc)
		sun_el_deg = float(sp.get("elevation_deg", 0.0))
		sun_az_deg = float(sp.get("azimuth_deg", 180.0))
	else:
		# DirectionalLight3D fallback (already positioned from CelestialClock)
		var sun := main_node.get("sun") as DirectionalLight3D
		if sun == null:
			current_solar_kw = 0.0
			_raw_solar_kw = 0.0
			return
		var dir : Vector3 = -sun.global_transform.basis.z.normalized()
		sun_el_deg = rad_to_deg(asin(clamp(dir.y, -1.0, 1.0)))
		sun_az_deg = fmod(rad_to_deg(atan2(dir.x, -dir.z)) + 360.0, 360.0)

	if sun_el_deg < -2.0:
		current_solar_kw = 0.0
		_raw_solar_kw = 0.0
		return

	var has_real_ghi : bool = _open_meteo_active and _simulated_solar_radiation > 1.0
	# Live path: the hazard at the PLAYHEAD (no abs_hours), unlike
	# evaluate_solar_at below which must resolve at the instant being rendered.
	var live_aod : float = float(SolarIrradiance.decorate_with_hazard(
		{}, SolarIrradiance.hazard_at(self)).get("aod", SolarIrradiance.AOD_BASELINE))
	var kw : float = _compute_solar_kw(sun_el_deg, sun_az_deg, has_real_ghi,
		_simulated_solar_radiation, cloud_cover, _estimate_ambient_temp(), live_aod)

	# --- 3D shadow raycast (optional, ~0.1 ms per call) ---
	# _get_shadow_factor returns a binary 0/1, so scaling kW is exact. The
	# graph's per-panel shade supersedes this one-point test when it is on
	# (_apply_graph_pv_shade) — both would count the same tree twice.
	if _shadow_raycast_enabled and not is_graph_pv_shade_active():
		var sun_el_rad : float = deg_to_rad(sun_el_deg)
		var sun_az_rad : float = deg_to_rad(sun_az_deg)
		var sun_dir_3d := Vector3(
			cos(sun_el_rad) * sin(sun_az_rad),
			sin(sun_el_rad),
			-cos(sun_el_rad) * cos(sun_az_rad))
		kw *= _get_shadow_factor(sun_dir_3d)

	current_solar_kw = kw
	_raw_solar_kw = kw


## Pure POA→AC core shared by the live enhanced path and the batch-render
## evaluator. Given sun position + weather inputs, returns AC solar output (kW).
## No scene/clock/HA state — deterministic for any (time, weather) pair.
## When `has_real_ghi`, decomposes the measured GHI via Erbs (1982); otherwise
## uses geometric clear-sky DNI with a cloud correction.
## `aod` is the aerosol optical depth including any extreme-weather load; the
## default is ordinary clean air, so every existing call is unchanged.
##
## Note the real-GHI branch needs only to scale GHI: the Erbs correlation below
## then redistributes the remainder toward DIFFUSE on its own, because a lower
## clearness index implies a higher diffuse fraction. That reproduces the real
## behaviour of smoke — direct beam collapses, scattered light persists — with
## no extra term, and it is why tracking arrays and CSP suffer far more than a
## fixed tilted array under the same haze.
func _compute_solar_kw(sun_el_deg: float, sun_az_deg: float, has_real_ghi: bool,
		ghi_real: float, cloud_frac: float, t_amb: float,
		aod: float = SolarIrradiance.AOD_BASELINE) -> float:
	if sun_el_deg < -2.0:
		return 0.0
	var aero : float = SolarIrradiance.aerosol_ghi_factor(sun_el_deg, aod)
	var sun_el_rad  : float = deg_to_rad(sun_el_deg)
	var cos_z       : float = maxf(sin(sun_el_rad), 0.01)  # cos(zenith) = sin(elevation)
	var cos_inc     : float = SolarPosition.panel_cos_incidence(sun_az_deg, sun_el_deg, panel_azimuth_degrees, panel_tilt_degrees)
	var iam         : float = _calculate_iam(cos_inc)
	var tilt_rad    : float = deg_to_rad(panel_tilt_degrees)
	var diff_sky_f  : float = (1.0 + cos(tilt_rad)) / 2.0   # isotropic sky-diffuse view factor
	var diff_gnd_f  : float = (1.0 - cos(tilt_rad)) / 2.0   # ground-reflected view factor

	# --- POA irradiance ---
	var poa : float
	if has_real_ghi:
		# Real GHI from WeatherService (already includes cloud/atmosphere effects).
		# Decompose into DNI + DHI via Erbs correlation (Erbs et al. 1982).
		var ghi : float = ghi_real * aero
		var kt  : float = clampf(ghi / maxf(STC_IRRADIANCE * cos_z, 1.0), 0.0, 1.0)
		var dhi_frac : float
		if kt <= 0.22:
			dhi_frac = 1.0 - 0.09 * kt
		elif kt <= 0.80:
			dhi_frac = 0.9511 - 0.1604 * kt + 4.388 * kt * kt \
					 - 16.638 * pow(kt, 3.0) + 12.336 * pow(kt, 4.0)
		else:
			dhi_frac = 0.165
		var dhi : float = ghi * clampf(dhi_frac, 0.0, 1.0)
		var dni : float = maxf(ghi - dhi, 0.0) / cos_z
		poa = clampf(
			dni * cos_inc * iam + dhi * diff_sky_f + ghi * 0.25 * diff_gnd_f,
			0.0, 1200.0)
	else:
		# Geometric clear-sky DNI with cloud correction (same as standard path)
		var dni : float = SolarIrradiance.dni_clear_sky_wm2(sun_el_deg, aod) \
			if aod > SolarIrradiance.AOD_BASELINE else _calculate_dni(sun_el_deg)
		var dhi : float = SolarIrradiance.dhi_clear_sky_wm2(sun_el_deg, dni, aod) \
			if aod > SolarIrradiance.AOD_BASELINE else _calculate_dhi(sun_el_deg, dni)
		var beam : float = dni * cos_inc * iam
		var ghi_est : float = dni * cos_z + dhi
		if cloud_frac > 0.0:
			beam     *= 1.0 - cloud_frac * 0.95
			var dm : float = 1.0 + cloud_frac * 0.5 if cloud_frac < 0.3 else 1.15 - (cloud_frac - 0.3) * 0.7
			dhi      *= dm
			ghi_est  *= 1.0 - cloud_frac * 0.5
		poa = clampf(beam + dhi * diff_sky_f + ghi_est * 0.25 * diff_gnd_f, 0.0, 1200.0)

	# --- NOCT cell temperature + γ derating ---
	var t_cell   : float = t_amb + (poa / 800.0) * (NOCT - 20.0)
	var t_factor : float = clampf(1.0 + TEMP_COEFFICIENT * (t_cell - 25.0), 0.7, 1.05)

	# --- DC → AC output ---
	var sys_eff : float = INVERTER_EFFICIENCY * WIRING_LOSSES * MISMATCH_LOSSES * SOILING_FACTOR * DEGRADATION
	return clampf(
		PEAK_CAPACITY_KW * (poa / STC_IRRADIANCE) * t_factor * sys_eff * SYSTEM_CALIBRATION,
		0.0, INVERTER_MAX_SOLAR_KW)


# ==================== OBSERVED-VS-SIMULATED COMPARISON (public API) ====================
# Coordinates the NLE workflow: import a datastream as an observed clip, batch-
# render a simulated curve over a selected range, and drive the split-screen
# compare. The timeline UI calls these and reads back state for drawing.

## Import an HA datastream CSV as the observed comparison clip (parse-only — no
## world-clock takeover). Builds an ObservedSeries when parsing finishes.
func import_observed_csv(path: String) -> void:
	if path.is_empty():
		return
	_ensure_clip_player()
	_observed_source_path = path
	_clip_player.call("load_clip", path)


func _ensure_clip_player() -> void:
	if is_instance_valid(_clip_player):
		return
	var scr := load("res://core/csv_history_player.gd")
	_clip_player = scr.new()
	_clip_player.name = "ObservedClipPlayer"
	add_child(_clip_player)
	if _clip_player.has_method("setup"):
		_clip_player.call("setup", null, null, main_node)
	if _clip_player.has_signal("clip_ready"):
		_clip_player.connect("clip_ready", Callable(self, "_on_clip_ready"))


func _on_clip_ready(_start_unix: int, _end_unix: int, _count: int) -> void:
	if main_node == null:
		return
	var clock_obj = main_node.get("clock")
	if clock_obj == null:
		return
	var viw := true
	if get("ha_values_in_watts") != null:
		viw = bool(ha_values_in_watts)
	_observed_series = _clip_player.call("build_observed_series", clock_obj, BATTERY_CAPACITY_KWH, viw)
	if _observed_series == null or bool(_observed_series.call("is_empty")):
		_observed_series = null
		return
	_observed_start_abs = float(_observed_series.get("start_abs_hours"))
	_observed_end_abs = float(_observed_series.get("end_abs_hours"))
	# Default the in/out selection to the full observed span.
	_sel_start_abs = _observed_start_abs
	_sel_end_abs = _observed_end_abs
	_register_observed_range_with_director()
	# Drop-to-timeline behavior: jump the playhead to the clip start (so it's
	# on-screen) and pause, like parking the playhead on a dropped video clip.
	if main_node.has_method("set_absolute_hours"):
		main_node.call("set_absolute_hours", _observed_start_abs)
	if main_node.get("time_scale") != null:
		main_node.set("time_scale", 0.0)
	observed_clip_changed.emit()


func _register_observed_range_with_director() -> void:
	var td := get_node_or_null("/root/TimeDirector")
	if td != null and td.has_method("register_observed_range") and not is_nan(_observed_start_abs):
		td.call("register_observed_range", _observed_start_abs, _observed_end_abs)


# ---- Selection / state getters (read by the timeline UI) ----

func has_observed_clip() -> bool:
	return _observed_series != null

func get_observed_range_abs() -> Vector2:
	if is_nan(_observed_start_abs):
		return Vector2(NAN, NAN)
	return Vector2(_observed_start_abs, _observed_end_abs)

func get_selection_abs() -> Vector2:
	if is_nan(_sel_start_abs):
		return Vector2(NAN, NAN)
	return Vector2(_sel_start_abs, _sel_end_abs)

func set_selection_abs(a: float, b: float) -> void:
	_sel_start_abs = minf(a, b)
	_sel_end_abs = maxf(a, b)

func get_observed_source_path() -> String:
	return _observed_source_path

func set_render_load_mode(mode: int) -> void:
	_render_load_mode = mode

func get_render_load_mode() -> int:
	return _render_load_mode

func get_rendered_range_abs() -> Vector2:
	if not _sim_series_ready and not is_rendering():
		return Vector2(NAN, NAN)
	return Vector2(_sim_render_start_abs, _sim_render_end_abs)


## Downsampled waveform bins for NLE sensor tracks on the timeline UI.
func get_timeline_waveform_bins(source : String, channel : String,
		abs_start : float, abs_end : float, bin_count : int) -> PackedFloat32Array:
	var mode := "peak"
	var meta : Dictionary = TimelineTrackDef.lookup_channel(channel)
	if not meta.is_empty():
		mode = str(meta.get("mode", "peak"))
	match source:
		"sim":
			if _sim_series != null and not _sim_series.is_empty():
				return _sim_series.waveform_bins(abs_start, abs_end, bin_count, channel, mode)
		"observed":
			if _observed_series != null and not _observed_series.is_empty():
				return _observed_series.waveform_bins(abs_start, abs_end, bin_count, channel,
					BATTERY_CAPACITY_KWH, mode)
		_:
			if energy_timeline != null and not energy_timeline.is_empty():
				return energy_timeline.waveform_bins(abs_start, abs_end, bin_count, channel, mode)
			return _eval_waveform_bins(abs_start, abs_end, bin_count, channel, mode)
	return PackedFloat32Array()


func _eval_waveform_bins(abs_start : float, abs_end : float, bin_count : int,
		channel : String, mode : String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if bin_count < 1:
		return out
	out.resize(bin_count)
	for i in bin_count:
		var t0 := lerpf(abs_start, abs_end, float(i) / float(bin_count))
		var t1 := lerpf(abs_start, abs_end, float(i + 1) / float(bin_count))
		var mid := (t0 + t1) * 0.5
		var sample : Dictionary = evaluate_inputs_at(mid)
		sample["soc_kwh"] = battery_kwh_stored
		out[i] = EnergyTimeline.channel_value(sample, channel, BATTERY_CAPACITY_KWH)
	return out


## Battery capacity for timeline SOC scaling.
func get_timeline_capacity_kwh() -> float:
	return BATTERY_CAPACITY_KWH


## Render the current selection (or the full observed span). Returns false if
## there is nothing valid to render.
func start_batch_render() -> bool:
	var s := _sel_start_abs
	var e := _sel_end_abs
	if is_nan(s) or is_nan(e):
		var r := get_observed_range_abs()
		s = r.x
		e = r.y
	if is_nan(s) or is_nan(e) or e <= s:
		return false
	return _render_range(s, e)


func _render_range(start_abs: float, end_abs: float) -> bool:
	var min_kwh : float = BATTERY_CAPACITY_KWH * MIN_BATTERY_PERCENT / 100.0
	_sim_series.configure(BATTERY_CAPACITY_KWH, CHARGE_EFFICIENCY, DISCHARGE_EFFICIENCY, min_kwh)
	_sim_series.set_evaluator(make_render_evaluator())
	# Start the simulated battery at the observed SOC so divergence is pure model drift.
	var soc0 : float = battery_kwh_stored
	if _observed_series != null and bool(_observed_series.call("has_soc")):
		soc0 = float(_observed_series.call("soc_at", start_abs))
	var inp := evaluate_inputs_at(start_abs)
	_sim_series.clear()
	_sim_series.init_anchor(start_abs, soc0,
		float(inp.get("solar_kw", 0.0)), float(inp.get("aux_kw", 0.0)), float(inp.get("load_kw", 0.0)))
	_sim_render_start_abs = start_abs
	_sim_render_end_abs = end_abs
	_sim_series_ready = false
	_ensure_batch_renderer()
	_batch_renderer.call("start_render", _sim_series, start_abs, end_abs)
	render_state_changed.emit()
	return true


func _ensure_batch_renderer() -> void:
	if is_instance_valid(_batch_renderer):
		return
	var scr := load("res://core/batch_renderer.gd")
	_batch_renderer = scr.new()
	_batch_renderer.name = "BatchRenderer"
	add_child(_batch_renderer)
	_batch_renderer.connect("render_progress", Callable(self, "_on_render_progress"))
	_batch_renderer.connect("render_complete", Callable(self, "_on_render_complete"))


func _on_render_progress(_frac: float) -> void:
	render_state_changed.emit()


func _on_render_complete() -> void:
	_sim_series_ready = true
	render_state_changed.emit()


func is_rendering() -> bool:
	return _batch_renderer != null and bool(_batch_renderer.call("is_rendering"))


## Render completion fraction: -1 = idle/no render, [0,1] = in progress, 1 = done.
func get_render_progress() -> float:
	if _batch_renderer == null:
		return -1.0
	if bool(_batch_renderer.call("is_rendering")):
		return float(_batch_renderer.call("get_progress"))
	return 1.0 if _sim_series_ready else -1.0


# ---- Split-screen compare (drives ProjectionCanvas BL=sim / BR=observed) ----

func set_compare_active(active: bool) -> void:
	_compare_active = active
	var td := get_node_or_null("/root/TimeDirector")
	if td != null and td.has_method("set_compare_active"):
		td.call("set_compare_active", active)
	var pc := _find_projection_canvas()
	if pc != null and pc.has_method("set_compare_mode"):
		pc.call("set_compare_mode", active)
	if active:
		_tick_compare_feed()   # paint the first frame immediately
	render_state_changed.emit()


func is_compare_active() -> bool:
	return _compare_active


func _find_projection_canvas() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var sc := tree.current_scene
	if sc != null:
		var pc := sc.get_node_or_null("UILayer/ProjectionCanvas")
		if pc != null:
			return pc
	return tree.root.find_child("ProjectionCanvas", true, false)


## Push one synced compare frame to the projection canvas: BL from the rendered
## sim series, BR from the observed series, both sampled at the playhead and
## across a trailing 48 h window for the graphs.
func _tick_compare_feed() -> void:
	if main_node == null or not main_node.has_method("get_absolute_hours"):
		return
	var pc := _find_projection_canvas()
	if pc == null or not pc.has_method("feed_comparison"):
		return
	var abs_h : float = float(main_node.call("get_absolute_hours"))
	var day_start : float = floor(abs_h / 24.0) * 24.0
	var payload : Dictionary = {}
	if _sim_series_ready and not bool(_sim_series.is_empty()):
		var ss := _sim_series.sample_at(abs_h)
		payload["sim_soc_pct"] = float(ss.get("soc_kwh", 0.0)) / BATTERY_CAPACITY_KWH * 100.0
		payload["sim_solar_w"] = float(ss.get("solar_kw", 0.0)) * 1000.0
		payload["sim_load_w"]  = float(ss.get("load_kw", 0.0)) * 1000.0
		payload["sim_solar_kwh"] = _sim_series.integrate_channel(day_start, abs_h, "solar")
		payload["sim_load_kwh"]  = _sim_series.integrate_channel(day_start, abs_h, "load")
		payload["sim_solar_hist"] = _series_hist(_sim_series, "solar_kw", abs_h - 48.0, abs_h, 96)
		payload["sim_load_hist"]  = _series_hist(_sim_series, "load_kw", abs_h - 48.0, abs_h, 96)
	if _observed_series != null and not bool(_observed_series.call("is_empty")):
		var os : Dictionary = _observed_series.call("sample_at", abs_h)
		payload["obs_soc_pct"] = float(os.get("soc_kwh", 0.0)) / BATTERY_CAPACITY_KWH * 100.0
		payload["obs_solar_w"] = float(os.get("solar_kw", 0.0)) * 1000.0
		payload["obs_load_w"]  = float(os.get("load_kw", 0.0)) * 1000.0
		payload["obs_solar_kwh"] = float(_observed_series.call("integrate_channel", day_start, abs_h, "solar"))
		payload["obs_load_kwh"]  = float(_observed_series.call("integrate_channel", day_start, abs_h, "load"))
		payload["obs_solar_hist"] = _series_hist(_observed_series, "solar_kw", abs_h - 48.0, abs_h, 96)
		payload["obs_load_hist"]  = _series_hist(_observed_series, "load_kw", abs_h - 48.0, abs_h, 96)
	pc.call("feed_comparison", payload)


## Resample a series channel (kW) into an N-point watt history over [t0, t1].
func _series_hist(series: Object, channel: String, t0: float, t1: float, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var denom : float = float(maxi(n - 1, 1))
	for i in n:
		var t : float = t0 + (t1 - t0) * float(i) / denom
		var s : Dictionary = series.call("sample_at", t)
		out[i] = float(s.get(channel, 0.0)) * 1000.0
	return out


# ==================== BATCH-RENDER EVALUATOR ====================
# Pure functions of absolute time used to pre-compute a simulated datastream
# over a selected range (the deferred "pre-render a day/week" feature). They do
# NOT read or mutate the live clock, the scene sun, or any HA override, so a
# render is deterministic and reproducible (same inputs → same curve).

## A Callable(abs_hours) -> {solar_kw, aux_kw, load_kw} for EnergyTimeline.
func make_render_evaluator() -> Callable:
	return Callable(self, "evaluate_inputs_at")


# ==================== SIM PRE-RENDER (timeline Render button) ====================
# The SimRenderer fills the LIVE energy_timeline ahead of the playhead and
# registers the range in a SimRenderCache; inside a rendered range the battery
# reads the cache and never truncates it (CLAUDE.md "Sim pre-render + playback").

## Aux generation (kW) the render evaluator uses for the NEXT step: the
## stepper sets it from the flow engine's graph DC output after each
## render_step (hydro into the battery, one-step lag like the live 0.25 s
## sync). NAN = hold the live aux constant (the legacy batch render).
var render_aux_kw: float = NAN
## Whether the inverter is serving the loads in the render (the stepper's
## floor / resume hysteresis). false = loads shed, load reads 0 like the live
## `_calculate_load_power` does during low-SOC protection.
var render_ac_on: bool = true
var _render_cache: RefCounted = null


## The evaluator for a sim pre-render: solar as a pure function of the
## instant (SPA + weather + shade + DC caps), load = the SAME GraphAcLoad
## reading the live tick integrates (the model is handed in once; the legacy
## `_modeled_load_at` did a `find_child` per call), aux from `render_aux_kw`.
func make_sim_render_evaluator(model: Object) -> Callable:
	return func(abs_hours: float) -> Dictionary:
		var pair := _evaluate_solar_pair(abs_hours)
		var solar := pair.y
		var aux := evaluate_aux_at(abs_hours) if is_nan(render_aux_kw) else maxf(render_aux_kw, 0.0)
		var load := 0.0
		if render_ac_on:
			if model != null and get_tree() != null:
				load = float(_GRAPH_AC_LOAD_SCRIPT.compute_kw(model, get_tree()))
			else:
				load = _modeled_load_at(abs_hours)
		return {"solar_kw": solar, "aux_kw": aux, "load_kw": load, "raw_kw": pair.x}


## The SimRenderer's cache: while it covers the playhead, `_update_battery`
## reads the rendered SOC and readouts and never truncates the timeline.
func set_render_cache(cache: RefCounted) -> void:
	_render_cache = cache


func _in_rendered_range(abs_h: float) -> bool:
	return _render_cache != null and _render_cache.has_method("covers") \
		and bool(_render_cache.call("covers", abs_h))


## The SimRenderer's entry: the LIVE timeline, configured, anchored at the
## playhead if it was empty, cut there, and given the sim-render evaluator.
## Returns the timeline for the stepper to fill.
func prepare_live_timeline_for_render(abs_h: float, model: Object) -> EnergyTimeline:
	var aux_total := current_aux_generation_kw + current_graph_dc_kw
	energy_timeline.configure(BATTERY_CAPACITY_KWH, CHARGE_EFFICIENCY, DISCHARGE_EFFICIENCY,
		min_battery_kwh())
	if energy_timeline.is_empty():
		energy_timeline.init_anchor(abs_h, battery_kwh_stored, current_solar_kw, aux_total, current_load_kw)
	energy_timeline.truncate_after(abs_h)
	render_aux_kw = maxf(aux_total, 0.0)
	render_ac_on = not _soc_protect_active
	energy_timeline.set_evaluator(make_sim_render_evaluator(model))
	return energy_timeline


## The render is over (or cancelled): the live timeline goes back to having no
## evaluator (a backward scrub past its start fills with held inputs, as it
## always did) and the render inputs are cleared.
func end_render_evaluator() -> void:
	energy_timeline.set_evaluator(Callable())
	render_aux_kw = NAN
	render_ac_on = true


## After a render restores the world to the playhead: re-anchor the forward
## read so the next tick is a cache read, not a "forward from the render's
## end" step, and show the SOC the cache holds there.
func reseat_battery_at(abs_h: float) -> void:
	_battery_last_abs_h = abs_h
	if not energy_timeline.is_empty():
		battery_kwh_stored = clampf(energy_timeline.soc_at(abs_h), 0.0, BATTERY_CAPACITY_KWH)


# ==================== CHALLENGE PRE-BAKE / PLAYBACK ====================
# ChallengeBakeEngine drives _sim_series directly (its own frame budget, not
# BatchRenderer) — reusing the SIM clip lane the timeline already draws.

## Battery SOC floor in kWh (the hard clamp; "power failure" is SOC pinned
## here while net < 0 — SOC itself never reads below it).
func min_battery_kwh() -> float:
	return BATTERY_CAPACITY_KWH * MIN_BATTERY_PERCENT / 100.0


## Configure + anchor the sim series for a challenge bake at `start_abs` with
## a span-appropriate sample step (coarser than 1 min for month/year spans so
## the whole run fits MAX_SAMPLES). Anchors at the LIVE battery SOC. Returns
## the series for the engine to step.
func prepare_challenge_series(start_abs: float, step_h: float) -> EnergyTimeline:
	_sim_series.configure(BATTERY_CAPACITY_KWH, CHARGE_EFFICIENCY,
		DISCHARGE_EFFICIENCY, min_battery_kwh())
	_sim_series.set_evaluator(make_render_evaluator())
	_sim_series.clear()
	_sim_series.step_hours = maxf(step_h, 1.0 / 60.0)  # only ever set on a CLEARED buffer
	var inp := evaluate_inputs_at(start_abs)
	_sim_series.init_anchor(start_abs, battery_kwh_stored,
		float(inp.get("solar_kw", 0.0)), float(inp.get("aux_kw", 0.0)),
		float(inp.get("load_kw", 0.0)))
	_sim_render_start_abs = start_abs
	_sim_render_end_abs = start_abs
	_sim_series_ready = false
	render_state_changed.emit()
	return _sim_series


## Mark the baked span complete so the timeline's SIM clip lane draws it.
func finish_challenge_series(end_abs: float) -> void:
	_sim_render_end_abs = end_abs
	_sim_series_ready = true
	render_state_changed.emit()


## Release the challenge bake's series (restores the default 1-min step for
## the observed-vs-sim render feature).
func release_challenge_series() -> void:
	set_playback_series_active(false)
	_sim_series.clear()
	_sim_series.step_hours = 1.0 / 60.0
	_sim_series_ready = false
	render_state_changed.emit()


## While ON, the battery HUD/SOC reads the baked _sim_series at the playhead
## instead of integrating live — challenge playback scrubs the baked run
## without polluting the live EnergyTimeline history.
func set_playback_series_active(on: bool) -> void:
	_playback_series_active = on


## Force a perfectly clear day for the duration of a tutorial run. Affects both
## the baked physics (_weather_at_abs) and the visible sky
## (_try_apply_open_meteo_weather) so the two can't disagree.
func set_clear_sky_override(on: bool) -> void:
	if _clear_sky_override != on and _render_cache != null and _render_cache.has_method("invalidate_all"):
		_render_cache.call("invalidate_all")  # the rendered sun was the other sky's
	_clear_sky_override = on


func is_clear_sky_override() -> bool:
	return _clear_sky_override


## Re-anchor the live battery after a challenge run commits (win) or aborts:
## sets the SOC and clears the live timeline so it re-anchors next tick.
func reanchor_live_battery(soc_kwh: float) -> void:
	battery_kwh_stored = clampf(soc_kwh, 0.0, BATTERY_CAPACITY_KWH)
	energy_timeline.clear()


## Potential (pre-throttle) solar at an instant — the PV-utilization metric's
## denominator: what the sky offered, ignoring the graph DC current cap.
func evaluate_potential_solar_at(abs_hours: float) -> float:
	var saved := _graph_dc_limit_w
	var saved_caps := _graph_dc_caps_active
	_graph_dc_limit_w = -1.0
	_graph_dc_caps_active = false
	var kw := evaluate_solar_at(abs_hours)
	_graph_dc_limit_w = saved
	_graph_dc_caps_active = saved_caps
	return kw


## Battery inputs at an arbitrary absolute-hours instant.
func evaluate_inputs_at(abs_hours: float) -> Dictionary:
	var pair := _evaluate_solar_pair(abs_hours)
	var solar : float = pair.y
	var aux : float = evaluate_aux_at(abs_hours)
	var load : float
	if _render_load_mode == RenderLoadMode.CSV and _observed_series != null \
			and bool(_observed_series.call("has_load")):
		load = float(_observed_series.call("sample_at", abs_hours).get("load_kw", 0.0))
	else:
		load = _modeled_load_at(abs_hours)
	return {"solar_kw": solar, "aux_kw": aux, "load_kw": load, "raw_kw": pair.x}


## Auxiliary generation (wind/hydro + graph DC generation) at an absolute-
## hours instant, for the batch render. v1: the current summed aux output
## held constant across the render — strictly better than the old hardcoded
## 0. A fully time-varying model (each EnergySource weather-sampled at
## abs_hours) is future work.
func evaluate_aux_at(_abs_hours: float) -> float:
	return maxf(current_aux_generation_kw + current_graph_dc_kw, 0.0)


## Pure solar AC output (kW) at an absolute-hours instant, off the live clock.
## Sun via Meeus SPA at that instant; weather sampled at that instant.
func evaluate_solar_at(abs_hours: float) -> float:
	return _evaluate_solar_pair(abs_hours).y


## (max capture, delivered) kW at an instant: x = the shaded array output
## before the graph DC caps (the scoreboard's "possible" channel), y = what
## the wiring delivers (evaluate_solar_at). One sun + weather evaluation.
func _evaluate_solar_pair(abs_hours: float) -> Vector2:
	if main_node == null:
		return Vector2.ZERO
	var clock_obj = main_node.get("clock")
	if clock_obj == null or not clock_obj.has_method("abs_hours_to_julian_day_utc"):
		return Vector2.ZERO
	var lat_v = main_node.get("latitude")
	var lon_v = main_node.get("longitude")
	var lat : float = float(lat_v) if lat_v != null else 33.36
	var lon : float = float(lon_v) if lon_v != null else -115.74
	var jd_utc : float = float(clock_obj.call("abs_hours_to_julian_day_utc", abs_hours))
	var sp := SolarPosition.get_position(lat, lon, jd_utc)
	var el : float = float(sp.get("elevation_deg", 0.0))
	var az : float = float(sp.get("azimuth_deg", 180.0))
	if el < -2.0:
		return Vector2.ZERO
	var wx := _weather_at_abs(abs_hours)
	# _weather_at_abs decorates with the hazard resolved AT abs_hours, so a
	# rendered week carries each day's own smoke rather than today's.
	var kw := _compute_solar_kw(el, az, bool(wx["has_real"]), float(wx["ghi"]),
		float(wx["cloud"]), float(wx["temp"]),
		float(wx.get("aod", SolarIrradiance.AOD_BASELINE)))
	# The placed panels' shade at THIS instant's sun (each rendered hour casts
	# its own shadows), then the graph DC wiring's caps on that raw output —
	# the same two rules the live tick applies, so the baked series is what
	# the site and the wiring allow at every hour of the day.
	var shade := {}
	if is_graph_pv_shade_active():
		var el_r := deg_to_rad(el)
		var az_r := deg_to_rad(az)
		shade = _graph_pv_shade_at(Vector3(cos(el_r) * sin(az_r), sin(el_r),
			-cos(el_r) * cos(az_r)))
		kw *= clampf(float(shade.get("factor", 1.0)), 0.0, 1.0)
	return Vector2(kw, graph_dc_delivered_kw(kw, shade))


## Weather inputs at an arbitrary instant: {ghi, cloud, temp, has_real}.
## Samples WeatherService at the instant's calendar date (pure); falls back to
## a synthetic diurnal temperature when no real coverage.
func _weather_at_abs(abs_hours: float) -> Dictionary:
	var out := {"ghi": 0.0, "cloud": 0.0, "temp": 25.0, "has_real": false}
	if main_node == null:
		return out
	# Tutorial runs force a cloudless day so "sun up = battery charging" is
	# never muddied by a cloudy sim date. has_real=false + cloud=0 is exactly
	# the geometric clear-sky branch _compute_solar_kw already takes, so this
	# needs no separate model.
	if _clear_sky_override:
		out["temp"] = _synthetic_temp_at(fposmod(abs_hours, 24.0))
		return out
	var clock_obj = main_node.get("clock")
	if clock_obj == null or not clock_obj.has_method("abs_hours_to_date"):
		return out
	var dd : Dictionary = clock_obj.call("abs_hours_to_date", abs_hours)
	var m : int = int(dd.get("month", 6))
	var d : int = int(dd.get("day", 15))
	var h : float = float(dd.get("day_time", 12.0))
	var ws := get_node_or_null("/root/WeatherService")
	if ws != null and ws.has_method("covers"):
		var lat_v = main_node.get("latitude")
		var lon_v = main_node.get("longitude")
		if lat_v != null and lon_v != null and bool(ws.call("covers", float(lat_v), float(lon_v))):
			var cover : float = float(ws.call("cloud_cover_frac", m, d, h))
			if not is_nan(cover):
				out["cloud"] = clampf(cover, 0.0, 1.0)
				var rad : float = float(ws.call("solar_radiation_wm2", m, d, h))
				if not is_nan(rad) and rad > 1.0:
					out["ghi"] = rad
					out["has_real"] = true
				var t : float = float(ws.call("temperature_c", m, d, h))
				if not is_nan(t):
					out["temp"] = t
				# Extreme weather resolved AT THIS INSTANT, not at the live
				# playhead: this function is the batch-render/prebake twin of
				# SolarIrradiance.sample_weather and evaluates arbitrary times.
				# Using current() here would bake the present hazard across a
				# whole rendered week.
				return SolarIrradiance.decorate_with_hazard(
					out, SolarIrradiance.hazard_at(self, abs_hours))
	out["temp"] = _synthetic_temp_at(h)
	return SolarIrradiance.decorate_with_hazard(
		out, SolarIrradiance.hazard_at(self, abs_hours))


## Synthetic diurnal ambient temperature for a time-of-day (offline fallback).
## Min 15 °C at 5 AM, max 38 °C at 17:00 (extracted from _estimate_ambient_temp).
func _synthetic_temp_at(day_time: float) -> float:
	var hour_offset : float = day_time - 5.0
	if hour_offset < 0.0:
		hour_offset += 24.0
	var temp_min : float = 15.0
	var temp_max : float = 38.0
	var phase : float = (hour_offset / 24.0) * TAU - PI / 2.0
	return temp_min + (temp_max - temp_min) * (sin(phase) + 1.0) / 2.0


## Deterministic modeled load (kW) at an instant: baseline + time-scheduled
## scene lighting. First-order model for the "Modeled load" compare option;
## the default "CSV load" path feeds the observed load instead.
func _modeled_load_at(abs_hours: float) -> float:
	var tree := get_tree()
	if tree != null:
		var sgv := tree.root.find_child("SystemGraphView", true, false)
		if sgv != null and ("model" in sgv):
			var m: Variant = sgv.get("model")
			if m != null:
				return _GRAPH_AC_LOAD_SCRIPT.compute_kw(m, tree)
	return BASELINE_LOAD_KW


## kW a scene consumer draws at a given hour-of-day, by its schedule.
## AutoLight exposes turn_on_hour/turn_off_hour; other wattage devices are
## treated as night-on glow loads. Devices without a wattage export contribute 0.
func _scheduled_consumer_kw(consumer: Node, hour: float) -> float:
	var watt_v = consumer.get("wattage")
	if watt_v == null:
		return 0.0
	var w : float = float(watt_v)
	var on_v = consumer.get("turn_on_hour")
	var off_v = consumer.get("turn_off_hour")
	if on_v != null and off_v != null:
		var on : float = float(on_v)
		var off : float = float(off_v)
		var is_on : bool
		if on > off:   # window crosses midnight (e.g. 18:00 → 06:00)
			is_on = hour >= on or hour < off
		else:
			is_on = hour >= on and hour < off
		return (w / 1000.0) if is_on else 0.0
	# No schedule: assume a night-on glow device.
	var night : bool = hour < 6.0 or hour >= 19.0
	return (w / 1000.0) if night else 0.0


## Cast a ray from the panel position toward the sun.
## Returns 1.0 (no shadow) or 0.0 (sun blocked by terrain/vegetation).
## Only called when _shadow_raycast_enabled is true.
func _get_shadow_factor(sun_direction: Vector3) -> float:
	if not is_inside_tree():
		return 1.0
	var viewport := get_viewport()
	if viewport == null:
		return 1.0
	var world3d := viewport.get_world_3d()
	if world3d == null:
		return 1.0
	var space_state := world3d.direct_space_state
	if space_state == null:
		return 1.0

	# Ray origin: try group "solar_panel_location" first, then height above origin
	var origin := Vector3(0.0, _shadow_sample_height, 0.0)
	var panel_nodes : Array = get_tree().get_nodes_in_group("solar_panel_location")
	if panel_nodes.size() > 0 and panel_nodes[0] is Node3D:
		origin = (panel_nodes[0] as Node3D).global_position + Vector3(0.0, 0.5, 0.0)

	var query := PhysicsRayQueryParameters3D.create(origin, origin + sun_direction * 2000.0)
	query.collision_mask = 0xFFFF
	var result := space_state.intersect_ray(query)
	return 0.0 if not result.is_empty() else 1.0


func _calculate_load_power() -> void:
	# Inverter output is intentionally cut during low-SOC protection/lockout.
	# Force displayed AC load to zero so UI and graph mirror real availability.
	if not is_ac_output_enabled():
		current_load_kw = 0.0
		return

	# Use HA override while in live mode or during CSV / HA historical playback.
	var sm := get_node_or_null("/root/SimMode")
	var historical := sm != null and sm.has_method("is_historical") and bool(sm.call("is_historical"))
	if _ha_load_override >= 0.0 and (is_in_live_mode() or historical):
		current_load_kw = _ha_load_override
		return

	# Authoritative load: wired + ON items on the system graph canvas only.
	var tree := get_tree()
	if tree != null:
		var sgv := tree.root.find_child("SystemGraphView", true, false)
		if sgv != null and ("model" in sgv):
			var m: Variant = sgv.get("model")
			if m != null:
				current_load_kw = _GRAPH_AC_LOAD_SCRIPT.compute_kw(m, tree)
				return

	current_load_kw = 0.0

## Hysteretic SOC protection helper — updates _soc_protect_active.
## Shuts off output at battery_soc_shutdown_pct, restores at battery_soc_resume_pct.
func _apply_soc_hysteresis(battery_pct: float) -> void:
	var min_kwh := BATTERY_CAPACITY_KWH * battery_soc_shutdown_pct / 100.0
	var resume_kwh := BATTERY_CAPACITY_KWH * battery_soc_resume_pct / 100.0
	var was_active := _soc_protect_active
	if not _soc_protect_active:
		if battery_kwh_stored <= min_kwh + 1e-4 or battery_pct <= battery_soc_shutdown_pct:
			_soc_protect_active = true
	else:
		if battery_kwh_stored >= resume_kwh - 1e-4 or battery_pct >= battery_soc_resume_pct:
			_soc_protect_active = false
	if _soc_protect_active != was_active:
		if _soc_protect_active:
			_ac_shutdown_reason = "battery_soc"
			ac_shutdown_changed.emit(true, _ac_shutdown_reason)
		elif _ac_shutdown_reason == "battery_soc":
			_ac_shutdown_reason = ""
			ac_shutdown_changed.emit(false, "")
		_publish_ac_power_bus(true)


func _apply_soc_protection_before_load() -> void:
	var battery_pct := get_battery_percent()
	_apply_soc_hysteresis(battery_pct)
	_sync_power_available(battery_pct)


func _sync_power_available(battery_pct: float) -> void:
	var ac_enabled := is_ac_output_enabled()
	var new_power_available: bool = ac_enabled and \
		(battery_pct > MIN_BATTERY_PERCENT or current_solar_kw > current_load_kw)
	if new_power_available != _power_available:
		_power_available = new_power_available
		power_availability_changed.emit(_power_available)
	_publish_ac_power_bus(false)


func _publish_ac_power_bus(force: bool = false) -> void:
	var apb := get_node_or_null("/root/AcPowerBus")
	if apb == null or not apb.has_method("publish"):
		return
	var shut := _soc_protect_active or _inverter_lockout_remaining > 0.0 \
		or _graph_controller_destroyed
	var reason: String = _ac_shutdown_reason
	if _graph_controller_destroyed and reason.is_empty():
		reason = "controller_destroyed"
	apb.call("publish", _power_available, is_ac_output_enabled(), reason, shut, force)


func _ac_shutdown_reason_label() -> String:
	if _graph_controller_destroyed:
		return "Controller destroyed — over-voltage fault (reset in graph view)"
	if _soc_protect_active:
		return "Battery below %.0f%% — AC off until %.0f%%" % [
			battery_soc_shutdown_pct, battery_soc_resume_pct]
	if _inverter_lockout_remaining > 0.0:
		return "Inverter overload — AC off for %.0fs" % ceilf(_inverter_lockout_remaining)
	return ""


func _update_battery(_delta: float) -> void:
	# Graph DC generation (fuel generators, graph-only wind/hydro wired into
	# a battery) rides the same aux-generation term real scene EnergySource
	# output already uses — kept as a separate scalar (see
	# current_graph_dc_kw) and combined here at point of use.
	var aux_total := current_aux_generation_kw + current_graph_dc_kw
	# HA only drives the battery while genuinely LIVE. In SIMULATE/PLAYBACK
	# (including any scrubbing) the reversible EnergyTimeline owns SOC, so the
	# battery uncharges on rewind instead of being pinned to the live reading.
	var _sm := get_node_or_null("/root/SimMode")
	var _live_now : bool = _sm != null and bool(_sm.call("is_live"))
	# Skip battery simulation if HA is providing SOC (live mode only)
	if _live_now and _ha_battery_soc_override >= 0.0:
		# Battery is controlled by HA. Mirror the measured SOC into the timeline
		# so the user can later scrub back through real recorded history.
		if main_node != null and main_node.has_method("get_absolute_hours"):
			var abs_h_live : float = float(main_node.call("get_absolute_hours"))
			var min_kwh_live : float = BATTERY_CAPACITY_KWH * MIN_BATTERY_PERCENT / 100.0
			energy_timeline.configure(BATTERY_CAPACITY_KWH, CHARGE_EFFICIENCY, DISCHARGE_EFFICIENCY, min_kwh_live)
			var soc_live : float = (_ha_battery_soc_override / 100.0) * BATTERY_CAPACITY_KWH
			battery_kwh_stored = soc_live
			energy_timeline.record_measured(abs_h_live, soc_live,
				current_solar_kw, aux_total, current_load_kw, _raw_solar_kw)
		# Update availability
		var battery_percent_val : float = _ha_battery_soc_override
		_apply_soc_hysteresis(battery_percent_val)
		_sync_power_available(battery_percent_val)
		return

	if main_node == null:
		return

	# Reversible battery: the EnergyTimeline cache is the source of truth for
	# SOC. Forward motion integrates and appends new samples; backward motion
	# reads the cached curve, so the battery "uncharges" exactly as it charged.
	var abs_h : float = float(main_node.call("get_absolute_hours")) if main_node.has_method("get_absolute_hours") else 0.0
	# Challenge playback: the baked run owns SOC at the playhead. The live
	# timeline is NOT advanced (the playhead sweep would otherwise integrate a
	# whole span of bogus live samples into real history).
	if _playback_series_active and not bool(_sim_series.is_empty()):
		var ps := _sim_series.sample_at(abs_h)
		battery_kwh_stored = clampf(float(ps.get("soc_kwh", battery_kwh_stored)),
			0.0, BATTERY_CAPACITY_KWH)
		_apply_playback_readouts(abs_h, ps)
		var pb_pct : float = (battery_kwh_stored / BATTERY_CAPACITY_KWH) * 100.0
		_apply_soc_hysteresis(pb_pct)
		_sync_power_available(pb_pct)
		return
	var min_kwh : float = BATTERY_CAPACITY_KWH * MIN_BATTERY_PERCENT / 100.0
	energy_timeline.configure(BATTERY_CAPACITY_KWH, CHARGE_EFFICIENCY, DISCHARGE_EFFICIENCY, min_kwh)
	if energy_timeline.is_empty():
		energy_timeline.init_anchor(abs_h, battery_kwh_stored,
			current_solar_kw, aux_total, current_load_kw, _raw_solar_kw)
	# Inside a RENDERED range the timeline is authoritative: the render
	# integrated the same inputs as a pure function of time, and the live
	# `current_solar_kw` comes from the scene-sun path (cloud noise, the
	# battery-full lerp), so the divergence test below would cut every render
	# on its first tick. Readouts come from the cache too (same rule as the
	# challenge playback), or the cards and the SOC tell different stories.
	var rendered := _in_rendered_range(abs_h)
	if abs_h > energy_timeline.end_abs_hours():
		# Forward — integrate with exact live inputs (held across the step).
		energy_timeline.record_step(abs_h, current_solar_kw, aux_total, current_load_kw, _raw_solar_kw)
	elif abs_h < energy_timeline.start_abs_hours():
		# Scrubbed before the cache start — extend backward (best-effort).
		energy_timeline.seek(abs_h)
	elif rendered:
		pass  # pure read of the rendered curve, forward or back
	elif abs_h > _battery_last_abs_h + 1e-6 \
			and _battery_last_abs_h >= energy_timeline.start_abs_hours():
		# Moving FORWARD through samples cached on an earlier pass (the clock was
		# scrubbed or restored backward). They replay that pass's battery, so a
		# load switched on since then never reached the SOC: the readout said
		# "deficit" while the battery sat at 100 %. When the live inputs differ,
		# the cache ahead is stale — cut it at the previous tick and integrate
		# this step from what is happening now. Unchanged inputs keep replaying.
		var cached := energy_timeline.sample_at(abs_h)
		var cached_net := float(cached.get("solar_kw", 0.0)) + float(cached.get("aux_kw", 0.0)) \
			- float(cached.get("load_kw", 0.0))
		var live_net := current_solar_kw + aux_total - current_load_kw
		if absf(cached_net - live_net) > BATTERY_CACHE_DIVERGE_KW:
			var cut_at := _battery_last_abs_h if abs_h - _battery_last_abs_h <= 1.0 else abs_h
			energy_timeline.truncate_after(cut_at)
			energy_timeline.record_step(abs_h, current_solar_kw, aux_total, current_load_kw, _raw_solar_kw)
	# else: paused or moving back inside the cache — pure reversible read.
	_battery_last_abs_h = abs_h
	battery_kwh_stored = clampf(energy_timeline.soc_at(abs_h), 0.0, BATTERY_CAPACITY_KWH)
	if rendered:
		_apply_playback_readouts(abs_h, energy_timeline.sample_at(abs_h))
	# Scoreboard/24h-history are derived read-only views over the timeline —
	# they don't need to recompute at the same 10 Hz cadence as the actual SOC
	# integration above. Moved to the existing 4 Hz UI tick (see _process).
	last_time = float(main_node.get("day_time"))

	# Check power availability and emit signal if changed
	var battery_percent_val : float = (battery_kwh_stored / BATTERY_CAPACITY_KWH) * 100.0
	_apply_soc_hysteresis(battery_percent_val)
	_sync_power_available(battery_percent_val)

## During challenge playback every readout comes from the BAKED run at the
## playhead, not from the live tick: the live path computes the sun its own way
## and throttles against a battery the bake does not have, so the panel cards,
## the controller, the battery and the dashboard each told a different story.
## Raw = what the sky offered then (uncapped); solar = what the bake delivered,
## less whatever a full battery could not take (the series clamps SOC at full
## but keeps the generated figure — that energy was thrown away, not stored).
func _apply_playback_readouts(abs_h: float, ps: Dictionary) -> void:
	var solar := maxf(float(ps.get("solar_kw", 0.0)), 0.0)
	var aux := maxf(float(ps.get("aux_kw", 0.0)), 0.0)
	var load := maxf(float(ps.get("load_kw", 0.0)), 0.0)
	_raw_solar_kw = maxf(evaluate_potential_solar_at(abs_h), solar)
	if battery_kwh_stored >= BATTERY_CAPACITY_KWH - 1e-3 and solar + aux > load:
		solar = maxf(load - aux, 0.0)
	current_solar_kw = solar
	current_load_kw = load


## Inverter overload protection — call every frame with real-time delta.
## Trips AC output off when load exceeds inverter_overload_watts for
## inverter_overload_duration seconds.  Keeps output off for inverter_lockout_duration.
func _update_inverter_overload(delta: float) -> void:
	if _inverter_lockout_remaining > 0.0:
		_inverter_lockout_remaining -= delta
		if _inverter_lockout_remaining <= 0.0:
			_inverter_lockout_remaining = 0.0
			_inverter_overload_elapsed  = 0.0
			if _ac_shutdown_reason == "overload":
				_ac_shutdown_reason = ""
				ac_shutdown_changed.emit(false, "")
			_publish_ac_power_bus(true)
			# Lockout expired — force a power-available re-check next battery tick
			if not _power_available and not _soc_protect_active:
				_sync_power_available(get_battery_percent())
		return
	var load_watts : float = current_load_kw * 1000.0
	if load_watts > inverter_overload_watts:
		_inverter_overload_elapsed += delta
		if _inverter_overload_elapsed >= inverter_overload_duration:
			_inverter_overload_elapsed  = 0.0
			_inverter_lockout_remaining = inverter_lockout_duration
			if _ac_shutdown_reason.is_empty():
				_ac_shutdown_reason = "overload"
				ac_shutdown_changed.emit(true, _ac_shutdown_reason)
			_sync_power_available(get_battery_percent())
			_publish_ac_power_bus(true)
	else:
		_inverter_overload_elapsed = 0.0


## Sum the instantaneous output of all auxiliary EnergySource nodes (wind,
## hydro, …) in the "energy_sources" group. Sources flag themselves out of
## the balance via contribute_to_grid (e.g. SolarPanelSource, since SolarUI
## models the solar array internally).
## The group walk is cached (AUX_SOURCES_TTL_S): this runs at 10 Hz and
## `get_nodes_in_group` builds a fresh Array each call for a set that changes
## only when a source node enters or leaves the tree.
const AUX_SOURCES_TTL_S := 2.0
var _aux_sources: Array = []
var _aux_sources_at_ms := -100000


func _poll_aux_generation() -> void:
	current_aux_generation_kw = 0.0
	var tree := get_tree()
	if tree == null:
		return
	var now_ms := Time.get_ticks_msec()
	if now_ms - _aux_sources_at_ms > int(AUX_SOURCES_TTL_S * 1000.0):
		_aux_sources = tree.get_nodes_in_group("energy_sources")
		_aux_sources_at_ms = now_ms
	for source: Node in _aux_sources:
		if source == null or not is_instance_valid(source) or not source.is_inside_tree():
			continue
		var contributes: Variant = source.get("contribute_to_grid")
		if contributes != null and not bool(contributes):
			continue
		if source.has_method("get_current_power_kw"):
			current_aux_generation_kw += maxf(float(source.call("get_current_power_kw")), 0.0)


## Pushed by SystemGraphView each energy-sync tick with the live sum of
## graph DC-electricity generation (fuel generators, graph-only wind/hydro)
## actually wired into a battery — see system_graph/dc_power_wiring.gd. Kept
## as its own scalar (not merged into current_aux_generation_kw, which
## _poll_aux_generation() resets every call on a different cadence) and
## folded into the aux term only at the point of use in _update_battery().
func set_graph_dc_generation_kw(kw: float) -> void:
	current_graph_dc_kw = maxf(0.0, kw)


## Derive the scoreboard (today / yesterday / best kWh) from the reversible
## EnergyTimeline instead of running accumulators. This keeps the numbers
## correct under scrubbing in either direction: "today" is the current sim
## day's solar up to the playhead, "yesterday" is the full previous sim day.
func _recompute_scoreboard_from_timeline(abs_h: float) -> void:
	var day_start : float = floor(abs_h / 24.0) * 24.0
	daily_solar_generated_kwh = energy_timeline.integrate_channel(day_start, abs_h, "solar")
	daily_aux_generated_kwh   = energy_timeline.integrate_channel(day_start, abs_h, "aux")
	daily_potential_kwh = maxf(energy_timeline.integrate_channel(day_start, abs_h, "raw"),
		daily_solar_generated_kwh)
	if _csv_daily_load_override >= 0.0:
		daily_load_consumed_kwh = _csv_daily_load_override
	else:
		daily_load_consumed_kwh = energy_timeline.integrate_channel(day_start, abs_h, "load")
	var prev_start : float = day_start - 24.0
	var tl_start : float = energy_timeline.start_abs_hours()
	if energy_timeline.is_empty():
		pass
	elif tl_start <= prev_start + 1e-6:
		yesterday_solar_kwh = energy_timeline.integrate_channel(prev_start, day_start, "solar")
	elif tl_start < day_start and day_start != _scoreboard_day_start:
		# Only part of yesterday is cached (loaded, or the battery re-anchored,
		# mid-day). The saved figure belonged to the day BEFORE once a midnight
		# has passed, so take what was recorded rather than keep a stale number.
		yesterday_solar_kwh = energy_timeline.integrate_channel(tl_start, day_start, "solar")
	if day_start != _scoreboard_day_start and _scoreboard_day_start >= 0.0 \
			and tl_start >= day_start - 1e-6:
		yesterday_solar_kwh = 0.0   # jumped past a day the cache never saw
	_scoreboard_day_start = day_start
	best_day_solar_kwh = maxf(best_day_solar_kwh, daily_solar_generated_kwh)
	var cur_day : int = int(main_node.get("day")) if main_node != null and "day" in main_node else _last_energy_day
	_last_energy_day = cur_day

func _update_display() -> void:
	# Battery percentage and bar (show 📡 if linked to HA)
	var battery_percent_val : float = (battery_kwh_stored / BATTERY_CAPACITY_KWH) * 100.0
	battery_bar.value = battery_percent_val
	var battery_linked = _source_link_icon("battery_soc", _ha_battery_soc_override >= 0.0)
	if _soc_protect_active or _inverter_lockout_remaining > 0.0:
		battery_percent.text = "%.0f%%%s" % [battery_percent_val, battery_linked]
		battery_percent.add_theme_color_override("font_color", UITheme.C_ERROR)
		battery_percent.tooltip_text = _ac_shutdown_reason_label()
	else:
		battery_percent.text = "%.0f%%%s" % [battery_percent_val, battery_linked]
		battery_percent.remove_theme_color_override("font_color")
		battery_percent.tooltip_text = _get_link_tooltip("battery SOC", ha_battery_soc_entity)
	battery_kwh.text = "%.1f / %.0f kWh stored" % [battery_kwh_stored, BATTERY_CAPACITY_KWH]

	_update_score_card()
	_update_daily_column()
	
	# Update title to show mode and HA status
	if title_label:
		if _csv_playback_active:
			var csv_indicators: Array[String] = []
			if _is_csv_linked_role("battery_soc"):
				csv_indicators.append("🔋")
			if _is_csv_linked_role("solar"):
				csv_indicators.append("☀")
			if _is_csv_linked_role("load"):
				csv_indicators.append("⚡")
			if _is_csv_linked_role("daily_solar"):
				csv_indicators.append("📊")
			if csv_indicators.size() > 0:
				title_label.text = "⚡ Power · CSV playback %s" % "".join(csv_indicators)
			else:
				title_label.text = "⚡ Power · CSV playback"
			title_label.add_theme_color_override("font_color", Color(0.55, 0.85, 1.0))
		elif is_in_live_mode():
			# In live mode at realtime - show live indicator
			var ha_indicators: Array[String] = []
			if _ha_battery_soc_override >= 0.0:
				ha_indicators.append("🔋")
			if _ha_solar_override >= 0.0:
				ha_indicators.append("☀")
			if _ha_load_override >= 0.0:
				ha_indicators.append("⚡")
			if _ha_daily_solar_override >= 0.0:
				ha_indicators.append("📊")
			
			if ha_indicators.size() > 0:
				title_label.text = "⚡ Power · Live %s" % "".join(ha_indicators)
			else:
				title_label.text = "⚡ Power · Live"
			title_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
		elif is_simulating_from_live():
			# Simulating forward from live data
			title_label.text = "⚡ Power · Simulating ahead"
			title_label.add_theme_color_override("font_color", Color(1.0, 0.8, 0.3))
		else:
			# Normal simulation mode
			var ha_indicators: Array[String] = []
			if _ha_battery_soc_override >= 0.0:
				ha_indicators.append("🔋")
			if _ha_solar_override >= 0.0:
				ha_indicators.append("☀")
			if _ha_load_override >= 0.0:
				ha_indicators.append("⚡")
			if _ha_daily_solar_override >= 0.0:
				ha_indicators.append("📊")
			
			if _soc_protect_active or _inverter_lockout_remaining > 0.0:
				# The banner in the body says it; the title stays the title.
				title_label.text = "⚡ Power Scoreboard"
				title_label.remove_theme_color_override("font_color")
			elif ha_indicators.size() > 0:
				title_label.text = "⚡ Power · Home Assistant %s" % "".join(ha_indicators)
				title_label.remove_theme_color_override("font_color")
			else:
				title_label.text = "⚡ Power Scoreboard"
				title_label.remove_theme_color_override("font_color")
	
	# Color code battery bar
	if battery_percent_val > 60.0:
		_set_battery_fill(Color(0.3, 1.0, 0.3, 1.0))  # Green
	elif battery_percent_val > 30.0:
		_set_battery_fill(Color(1.0, 0.9, 0.2, 1.0))  # Yellow
	elif battery_percent_val > MIN_BATTERY_PERCENT:
		_set_battery_fill(Color(1.0, 0.5, 0.2, 1.0))  # Orange
	else:
		_set_battery_fill(Color(1.0, 0.2, 0.2, 1.0))  # Red
	
	# Solar power (show 📡 live HA or 📂 CSV playback when linked)
	var solar_linked = _source_link_icon("solar", _ha_solar_override >= 0.0)
	solar_value.text = "%s%s" % [_fmt_power(current_solar_kw), solar_linked]
	if current_solar_kw > 0.1:
		solar_value.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2, 1.0))
	else:
		solar_value.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1.0))
	solar_value.tooltip_text = _get_link_tooltip("solar", ha_solar_entity)

	# Auxiliary power (real scene wind/hydro/etc EnergySource output + graph
	# DC generation — fuel generators, graph-only wind/hydro wired into a
	# battery, see system_graph/dc_power_wiring.gd). Included in Net below.
	if aux_value:
		var aux_kw := current_aux_generation_kw + current_graph_dc_kw
		aux_value.text = _fmt_power(aux_kw)
		if aux_kw > 0.01:
			aux_value.add_theme_color_override("font_color", Color(0.686, 0.6, 1.0, 1.0))
		else:
			aux_value.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1.0))

	# Max array output before battery curtailment (see _apply_battery_full_throttle)
	if potential_value:
		var pot_kw: float = _raw_solar_kw
		potential_value.text = _fmt_power(pot_kw)
		var gap: float = _raw_solar_kw - current_solar_kw
		# Red when useful solar is being clipped; green when all available power is used
		if gap > 0.02 and _raw_solar_kw > 0.02:
			potential_value.add_theme_color_override("font_color", Color(0.95, 0.2, 0.25, 1.0))
			if pot_icon:
				pot_icon.add_theme_color_override("font_color", Color(0.95, 0.25, 0.25, 1.0))
			if potential_label:
				potential_label.add_theme_color_override("font_color", Color(0.9, 0.45, 0.45, 1.0))
		else:
			potential_value.add_theme_color_override("font_color", Color(0.25, 0.92, 0.4, 1.0))
			if pot_icon:
				pot_icon.add_theme_color_override("font_color", Color(0.3, 0.95, 0.45, 1.0))
			if potential_label:
				potential_label.add_theme_color_override("font_color", Color(0.75, 0.8, 0.82, 1.0))
	
	# Load power (show 📡 live HA or 📂 CSV playback when linked)
	var load_linked = _source_link_icon("load", _ha_load_override >= 0.0)
	if not is_ac_output_enabled():
		load_value.text = "Shed%s" % load_linked
		load_value.add_theme_color_override("font_color", Color(1.0, 0.28, 0.22, 1.0))
		load_value.tooltip_text = _ac_shutdown_reason_label()
	else:
		load_value.text = "%s%s" % [_fmt_power(current_load_kw), load_linked]
		if current_load_kw > 0.01:
			load_value.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3, 1.0))
		else:
			load_value.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5, 1.0))
		load_value.tooltip_text = _get_link_tooltip("load", ha_load_entity)
	
	# Battery percent tooltip
	battery_percent.tooltip_text = _get_link_tooltip("battery SOC", ha_battery_soc_entity)
	
	# Net power (solar + auxiliary sources such as wind/hydro + graph DC generation)
	var gen_now : float = current_solar_kw + current_aux_generation_kw + current_graph_dc_kw
	if gen_value:
		gen_value.text = _fmt_power(gen_now)
		gen_value.add_theme_color_override("font_color",
			UITheme.C_PRIMARY if gen_now > 0.01 else UITheme.C_TEXT_M)
	var net_power : float = gen_now - current_load_kw
	if net_power >= 0.0:
		net_value.text = "+" + _fmt_power(net_power)
		net_value.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3, 1.0))
	else:
		net_value.text = "−" + _fmt_power(-net_power)
		net_value.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))
	
	# Status message - show battery state and weather
	var weather_icon : String = _get_weather_icon()
	
	if battery_percent_val >= 99.9:
		status_label.text = "Full %s" % weather_icon
		status_label.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3, 1.0))
	elif battery_percent_val >= 95.0 and _raw_solar_kw > current_solar_kw + 0.5:
		# Solar is being throttled because battery is nearly full
		status_label.text = "Full — solar throttled %s" % weather_icon
		status_label.add_theme_color_override("font_color", Color(0.3, 0.9, 0.7, 1.0))
	elif battery_percent_val <= MIN_BATTERY_PERCENT:
		status_label.text = "Low battery %s" % weather_icon
		status_label.add_theme_color_override("font_color", Color(1.0, 0.3, 0.3, 1.0))
	elif net_power > 0.1:
		status_label.text = "Charging %s" % weather_icon
		status_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.2, 1.0))
	elif net_power < -0.01:
		status_label.text = "Discharging %s" % weather_icon
		status_label.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0, 1.0))
	else:
		status_label.text = "Idle %s" % weather_icon
		status_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
	# Critical state in ONE place, one look (AlertBanner): AC off first, then
	# a battery at its floor.
	if _alert != null:
		if _soc_protect_active or _inverter_lockout_remaining > 0.0:
			_alert.show_alert(AlertBanner.ERROR, "AC is off — %s" % _ac_shutdown_reason_label())
		elif battery_percent_val <= MIN_BATTERY_PERCENT:
			_alert.show_alert(AlertBanner.WARN, "Battery low — %.0f%% left" % battery_percent_val)
		else:
			_alert.clear()
	
	# Update rain display periodically
	_update_rain_display()

# ==================== SCOREBOARD FACE ====================
# TODAY / YESTERDAY / BEST DAY solar on top with a capture line (today's solar
# against what the array could have made), then each flow's power NOW beside
# its kWh TODAY — since local midnight on the sim clock, read off the
# EnergyTimeline so a scrub back rewinds the counters with the battery.


func _style_scoreboard() -> void:
	var vbox := get_node_or_null("Panel/MarginContainer/VBoxContainer")
	if vbox == null:
		return
	# Tabular figures: a counter that changes while you watch must not jitter.
	var num_font := UITheme.font("medium", true)
	for lbl in [scoreboard_today, scoreboard_prev, scoreboard_best,
			solar_value, aux_value, potential_value, gen_value, load_value, net_value,
			solar_today, aux_today, potential_today, gen_today, load_today, net_today,
			battery_percent]:
		if lbl != null:
			(lbl as Label).add_theme_font_override("font", num_font)
	# One icon column: emoji glyphs differ in width, which staggered the labels.
	for path in ["SolarContainer/SolarIcon", "AuxContainer/AuxIcon", "PotentialContainer/PotIcon",
			"GenContainer/GenIcon", "LoadContainer/LoadIcon", "NetContainer/NetIcon"]:
		var icon := vbox.get_node_or_null(path) as Label
		if icon != null:
			icon.custom_minimum_size.x = 20.0
			icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if potential_label:
		potential_label.tooltip_text = "Max capture: what the array could make right now, before the battery-full taper and the wiring's current caps. Green when Solar takes all of it; red when surplus is clipped."
	var tips := {
		"SolarContainer/SolarLabel": "Solar delivered to the battery and loads.",
		"AuxContainer/AuxLabel": "Wind, hydro and other generators wired into the battery.",
		"GenContainer/GenLabel": "Everything generated: solar + aux.",
		"LoadContainer/LoadLabel": "Power used by the AC loads.",
		"NetContainer/NetLabel": "Generated minus consumed. Positive charges the battery.",
		"EnergyHeader/HdrToday": "Energy since midnight on the sim clock. Resets at midnight.",
		"EnergyHeader/HdrNow": "Power at this moment.",
	}
	for path in tips:
		var l := vbox.get_node_or_null(path) as Label
		if l != null:
			l.mouse_filter = Control.MOUSE_FILTER_STOP
			l.tooltip_text = tips[path]
	if capture_label:
		capture_label.tooltip_text = "Today's solar as a share of what the array could have made today. Keep loads running and the battery hungry while the sun is up to score higher."


func _set_battery_fill(c: Color) -> void:
	if battery_bar:
		battery_bar.modulate = c


## kW for the NOW column: watts under 1 kW, two decimals above.
static func _fmt_power(kw: float) -> String:
	if absf(kw) < 1.0:
		return "%d W" % roundi(kw * 1000.0)
	return "%.2f kW" % kw


## kWh for the TODAY column: Wh under 1 kWh so the dawn count-up shows.
static func _fmt_energy(kwh: float) -> String:
	var a := absf(kwh)
	if a < 1.0:
		return "%d Wh" % roundi(kwh * 1000.0)
	if a < 100.0:
		return "%.1f kWh" % kwh
	return "%.0f kWh" % kwh


## The hero number (unit printed beside it).
static func _fmt_score(kwh: float) -> String:
	if kwh < 10.0:
		return "%.2f" % kwh
	if kwh < 1000.0:
		return "%.1f" % kwh
	return "%.0f" % kwh


func _today_solar_kwh() -> float:
	return _ha_daily_solar_override if _ha_daily_solar_override >= 0.0 else daily_solar_generated_kwh


func _update_score_card() -> void:
	if scoreboard_today == null:
		return
	var today := _today_solar_kwh()
	var linked := _source_link_icon("daily_solar", true) if _ha_daily_solar_override >= 0.0 else ""
	scoreboard_today.text = _fmt_score(today) + linked
	scoreboard_today.tooltip_text = _get_link_tooltip("daily solar (today)", ha_daily_solar_entity)
	if scoreboard_prev:
		scoreboard_prev.text = _fmt_score(yesterday_solar_kwh)
	var record := today > 0.05 and today >= best_day_solar_kwh - 1e-4
	if scoreboard_best:
		scoreboard_best.text = _fmt_score(maxf(best_day_solar_kwh, today))
	if scoreboard_best_hdr:
		scoreboard_best_hdr.text = "BEST DAY ★" if record else "BEST DAY"
	if capture_label == null:
		return
	var possible := maxf(daily_potential_kwh, today)
	var clipped := maxf(possible - today, 0.0)
	if possible < 0.005:
		capture_label.text = "Waiting for the sun"
		capture_label.add_theme_color_override("font_color", _CAPTURE_DIM)
		return
	var pct := clampf(today / possible, 0.0, 1.0) * 100.0
	var line := "%d%% captured · %s possible" % [floori(pct), _fmt_energy(possible)]
	if clipped >= 0.0005:
		line += " · %s clipped" % _fmt_energy(clipped)
	capture_label.text = line
	var col := _CAPTURE_DIM
	if pct >= 95.0:
		col = Color(0.4, 0.95, 0.5)
	elif pct < 80.0:
		col = Color(1.0, 0.7, 0.3)
	capture_label.add_theme_color_override("font_color", col)


const _CAPTURE_DIM := Color(0.55, 0.6, 0.65)


func _update_daily_column() -> void:
	var solar := _today_solar_kwh()
	var gen := solar + daily_aux_generated_kwh
	var net := gen - daily_load_consumed_kwh
	_set_daily(solar_today, solar, Color(1.0, 0.9, 0.2))
	_set_daily(aux_today, daily_aux_generated_kwh, Color(0.686, 0.6, 1.0))
	_set_daily(potential_today, maxf(daily_potential_kwh, solar), Color(0.35, 0.95, 0.4))
	_set_daily(gen_today, gen, UITheme.C_PRIMARY)
	_set_daily(load_today, daily_load_consumed_kwh, Color(1.0, 0.5, 0.3))
	if net_today:
		net_today.text = ("+" if net >= 0.0 else "−") + _fmt_energy(absf(net))
		net_today.add_theme_color_override("font_color",
			Color(0.3, 1.0, 0.3) if net >= 0.0 else Color(1.0, 0.3, 0.3))
		net_today.tooltip_text = "%.3f kWh generated − %.3f kWh consumed since midnight" % [gen, daily_load_consumed_kwh]
	if net_icon != null:
		net_icon.add_theme_color_override("font_color",
			Color(0.3, 1.0, 0.3) if net >= 0.0 else Color(1.0, 0.3, 0.3))


func _set_daily(lbl: Label, kwh: float, col: Color) -> void:
	if lbl == null:
		return
	lbl.text = _fmt_energy(kwh)
	lbl.add_theme_color_override("font_color", col if kwh >= 0.0005 else UITheme.C_TEXT_M)
	lbl.tooltip_text = "%.3f kWh since midnight" % kwh


func _get_weather_icon() -> String:
	var icon : String = ""
	match weather:
		WeatherType.CLEAR:
			icon = "☀"
		WeatherType.PARTLY_CLOUDY:
			icon = "⛅"
		WeatherType.CLOUDY:
			icon = "☁"
		WeatherType.RAINY:
			icon = "🌧"
	
	# Add mud indicator
	if is_ground_muddy:
		icon += "🐌"  # Snail = slow movement
	
	return icon

# Solar calculation helpers
func _calculate_dni(sun_elevation_deg: float) -> float:
	if sun_elevation_deg <= 0.0:
		var twilight_factor : float = maxf(0.0, (sun_elevation_deg + 2.0) / 2.0)
		return 50.0 * twilight_factor
	
	var zenith_deg : float = 90.0 - sun_elevation_deg
	var zenith_rad : float = deg_to_rad(zenith_deg)
	var air_mass : float = 1.0 / (cos(zenith_rad) + 0.50572 * pow(96.07995 - zenith_deg, -1.6364))
	air_mass = clampf(air_mass, 1.0, 38.0)
	
	var tau_r : float = exp(-0.0903 * pow(air_mass, 0.84))
	var tau_a : float = exp(-0.12 * pow(air_mass, 0.75))
	var tau_o : float = exp(-0.0127 * pow(air_mass, 0.26))
	var tau_w : float = exp(-0.009 * pow(air_mass, 0.75))
	
	var total_transmittance : float = tau_r * tau_a * tau_o * tau_w
	return SOLAR_CONSTANT * total_transmittance

func _calculate_dhi(sun_elevation_deg: float, dni: float) -> float:
	if sun_elevation_deg <= 0.0:
		return 20.0 * maxf(0.0, (sun_elevation_deg + 5.0) / 5.0)
	
	var sun_elevation_rad : float = deg_to_rad(sun_elevation_deg)
	var clearness_factor : float = 0.85
	var diffuse_fraction : float = 0.12 + 0.08 * (1.0 - clearness_factor)
	var ghi_estimate : float = dni * sin(sun_elevation_rad)
	var dhi : float = ghi_estimate * diffuse_fraction
	dhi = maxf(dhi, 30.0 * sin(sun_elevation_rad))
	return dhi

func _get_panel_normal() -> Vector3:
	var tilt_rad : float = deg_to_rad(panel_tilt_degrees)
	var azimuth_rad : float = deg_to_rad(panel_azimuth_degrees)
	var normal : Vector3 = Vector3(
		sin(tilt_rad) * sin(azimuth_rad),
		cos(tilt_rad),
		-sin(tilt_rad) * cos(azimuth_rad)
	)
	return normal.normalized()

func _calculate_iam(cos_incidence: float) -> float:
	if cos_incidence <= 0.0:
		return 0.0
	var b0 : float = 0.05
	var incidence_angle_rad : float = acos(cos_incidence)
	var incidence_angle_deg : float = rad_to_deg(incidence_angle_rad)
	if incidence_angle_deg > 85.0:
		return 0.0
	var iam : float = 1.0 - b0 * (1.0 / cos_incidence - 1.0)
	return clampf(iam, 0.0, 1.0)

func _estimate_ambient_temp() -> float:
	# Prefer real temperature from WeatherService when available.
	if _open_meteo_active and not is_nan(_simulated_temperature) and _simulated_temperature > -100.0:
		return _simulated_temperature
	# Fallback: synthetic diurnal cycle (min 15°C at 5 AM, max 38°C at 17:00).
	if main_node == null:
		return 25.0
	return _synthetic_temp_at(float(main_node.get("day_time")))

## Check if power is currently available from the system
func is_power_available() -> bool:
	return _power_available


## True when the inverter may deliver AC (not in low-SOC or overload lockout).
func is_ac_output_enabled() -> bool:
	return not _soc_protect_active and _inverter_lockout_remaining <= 0.0 \
		and not _graph_controller_destroyed


func set_graph_controller_destroyed(active: bool) -> void:
	if _graph_controller_destroyed == active:
		return
	_graph_controller_destroyed = active
	_publish_ac_power_bus(true)


## Delivered-power cap from the graph's DC wiring (SystemGraphView._tick_dc_
## throttle: Σ per-controller bus_V × max_charge_amps over the PV share routed
## through real controllers; see GraphDcElectrical). −1 = no cap (freeplay
## with no player-built controller+bank chain — behavior unchanged).
func set_graph_dc_limit_w(watts: float) -> void:
	_graph_dc_limit_w = watts
	_graph_dc_caps_active = false


## Per-controller form of the cap: `caps` = [{frac, limit_w}] — each real
## controller's share of the array (by Wmp) and its bus_V x max_charge_amps
## limit (< 0 = none); `unrouted_frac` = the share reaching the battery with no
## controller in the way (passes uncapped). Empty caps = no cap.
func set_graph_dc_caps(caps: Array, unrouted_frac: float) -> void:
	_graph_dc_caps = caps.duplicate(true)
	_graph_dc_unrouted_frac = clampf(unrouted_frac, 0.0, 1.0)
	_graph_dc_caps_active = not caps.is_empty()
	_graph_dc_limit_w = -1.0


## Per-panel shade of the graph's PV (SystemGraphView._dc_throttle_pass).
## `receivers` = [{wmp, group, pos, s}] for the site-placed panels (group =
## index into the caps last set, -1 = unrouted), `total_wmp` = the whole
## array's Wmp, placed or not. Empty receivers = no shade (the bootcamp
## sandbox, a graph with no placed panels).
func set_graph_pv_shade(receivers: Array, total_wmp: float) -> void:
	_pv_shade_receivers = receivers.duplicate(true)
	_pv_shade_total_wmp = maxf(total_wmp, 0.0)
	if _pv_shade_receivers.is_empty() or _pv_shade_total_wmp <= 0.0:
		_pv_shade_live = {}
	else:
		_pv_shade_live = GraphSolarShading.live_shade(_pv_shade_receivers, _pv_shade_total_wmp)


func is_graph_pv_shade_active() -> bool:
	return not _pv_shade_receivers.is_empty() and _pv_shade_total_wmp > 0.0


## The live array shade factor (1 = unshaded).
func graph_pv_shade_factor() -> float:
	return float(_pv_shade_live.get("factor", 1.0))


## Array shade at a sun direction, by ray-casting each placed panel against the
## world (the batch render: every rendered hour gets its own shadows).
func _graph_pv_shade_at(sun_dir: Vector3) -> Dictionary:
	if not is_graph_pv_shade_active():
		return {}
	var space: PhysicsDirectSpaceState3D = null
	if is_inside_tree():
		var vp := get_viewport()
		if vp != null and vp.get_world_3d() != null:
			space = vp.get_world_3d().direct_space_state
	if space == null:
		return _pv_shade_live
	var factors := GraphSolarShading.factors_at(_pv_shade_receivers, sun_dir,
		func(from: Vector3, to: Vector3) -> Dictionary:
			return GraphSolarShading.physics_intersect(space, from, to))
	return GraphSolarShading.array_shade(_pv_shade_receivers, factors, _pv_shade_total_wmp)


## Live tick: the array output carries the panels' shade (a measured HA
## reading already does).
func _apply_graph_pv_shade() -> void:
	if _ha_solar_override >= 0.0 or _pv_shade_live.is_empty():
		return
	var f := clampf(graph_pv_shade_factor(), 0.0, 1.0)
	if f >= 0.9999:
		return
	_raw_solar_kw *= f
	current_solar_kw *= f


## What the DC wiring lets through when the array makes `raw_kw`. `shade` is
## the array shade that raw already carries (null = the live one): it re-splits
## the controllers' shares so each is offered its own panels' output.
func graph_dc_delivered_kw(raw_kw: float, shade: Variant = null) -> float:
	var raw := maxf(raw_kw, 0.0)
	if _graph_dc_caps_active:
		var sh: Dictionary = _pv_shade_live if shade == null else shade as Dictionary
		var adj := GraphSolarShading.shaded_caps(_graph_dc_caps, _graph_dc_unrouted_frac, sh)
		return GraphDcElectrical.delivered_for_caps(raw, adj["caps"] as Array,
			float(adj["unrouted_frac"]))
	if _graph_dc_limit_w >= 0.0:
		return minf(raw, _graph_dc_limit_w / 1000.0)
	return raw


## The effective cap in watts at the current raw output (-1 = none).
func get_graph_dc_limit_w() -> float:
	if _graph_dc_caps_active:
		return graph_dc_delivered_kw(_raw_solar_kw) * 1000.0
	return _graph_dc_limit_w


func _apply_graph_dc_limit() -> void:
	if not _graph_dc_caps_active and _graph_dc_limit_w < 0.0:
		return
	current_solar_kw = minf(current_solar_kw, graph_dc_delivered_kw(_raw_solar_kw))


func is_soc_protect_active() -> bool:
	return _soc_protect_active

## True only for the canonical SolarUI that drives simulation/power state.
## Embedded mirror copies in the system graph return false.
func is_primary_power_source() -> bool:
	return not _is_graph_embed

## Get the current battery percentage
func get_battery_percent() -> float:
	return (battery_kwh_stored / BATTERY_CAPACITY_KWH) * 100.0

func get_battery_kwh_stored() -> float:
	return battery_kwh_stored

func get_battery_capacity_kwh() -> float:
	return BATTERY_CAPACITY_KWH

# ==================== SOLAR GRAPH ====================

var _last_history_hour : int = -1
var _hourly_samples : Array[float] = []

## Rebuild the 24h solar+load graph for the current sim day from the reversible
## EnergyTimeline. Because it reads the cache (not a running ring buffer), the
## graph retraces correctly when the user scrubs backward.
func _update_solar_history() -> void:
	if main_node == null:
		return
	var abs_h : float = float(main_node.call("get_absolute_hours")) if main_node.has_method("get_absolute_hours") else 0.0
	var day_start : float = floor(abs_h / 24.0) * 24.0
	while solar_history.size() < HISTORY_SIZE:
		solar_history.append(0.0)
	while load_history.size() < HISTORY_SIZE:
		load_history.append(0.0)
	for h in range(HISTORY_SIZE):
		var hs : float = day_start + float(h)
		if hs >= abs_h:
			# Hour not yet reached on the current sim day.
			solar_history[h] = 0.0
			load_history[h] = 0.0
			continue
		var he : float = minf(hs + 1.0, abs_h)
		var span : float = maxf(he - hs, 1e-6)
		solar_history[h] = energy_timeline.integrate_channel(hs, he, "solar") / span
		load_history[h]  = energy_timeline.integrate_channel(hs, he, "load") / span
	history_start_hour = 0
	_last_history_hour = int(main_node.day_time)

func _update_graph() -> void:
	if solar_graph:
		solar_graph.queue_redraw()
	
	# Update graph title to show history link status
	if graph_title:
		if _csv_playback_active:
			var fname := _csv_graph_source_path.get_file()
			if fname.is_empty():
				fname = "CSV datastream"
			graph_title.text = "SOLAR & LOAD (24h) 📂"
			graph_title.tooltip_text = (
				"Historical graph from CSV playback: %s\n"
				+ "Yellow = solar input, red = total AC load"
			) % fname
		else:
			var history_source = ""
			if ha_solar_energy_entity != "":
				history_source = ha_solar_energy_entity
			elif ha_solar_entity != "":
				history_source = ha_solar_entity + " (power)"
			
			if _history_loaded and history_source != "":
				graph_title.text = "SOLAR OUTPUT (24h) 📡"
				graph_title.tooltip_text = "🔗 Historical data from: %s\nClick to change energy sensor" % history_source
			elif _history_request_pending and history_source != "":
				graph_title.text = "SOLAR OUTPUT (24h) ⏳"
				graph_title.tooltip_text = "🔗 Loading history from: %s\nClick to change energy sensor" % history_source
			elif ha_solar_energy_entity != "":
				graph_title.text = "SOLAR OUTPUT (24h)"
				graph_title.tooltip_text = "🔗 Energy sensor: %s\nClick to change" % ha_solar_energy_entity
			elif ha_solar_entity != "":
				graph_title.text = "SOLAR OUTPUT (24h)"
				graph_title.tooltip_text = "Using power sensor for history: %s\nClick to link dedicated energy sensor" % ha_solar_entity
			else:
				graph_title.text = "SOLAR OUTPUT (24h)"
				graph_title.tooltip_text = "Click to link HA solar energy sensor for historical data\n(or uses linked power sensor automatically)"
	
	# Update peak and daily labels
	if graph_peak_label:
		var peak : float = 0.0
		for val in solar_history:
			peak = maxf(peak, val)
		if _csv_playback_active and _is_csv_linked_role("load"):
			for val in load_history:
				peak = maxf(peak, val)
			graph_peak_label.text = "Peak: %.1f kW (solar/load)" % peak
		else:
			graph_peak_label.text = "Peak: %.1f kW" % peak
	
func _draw_solar_graph() -> void:
	if solar_graph == null:
		return
	
	var graph_size : Vector2 = solar_graph.size
	var padding : float = 4.0
	var graph_width : float = graph_size.x - padding * 2
	var graph_height : float = graph_size.y - padding * 2
	
	# Find max value for scaling (minimum 1 kW to avoid division by zero)
	var max_val : float = INVERTER_MAX_SOLAR_KW  # Use inverter max as scale reference
	for val in solar_history:
		max_val = maxf(max_val, val)
	if _csv_playback_active:
		for val in load_history:
			max_val = maxf(max_val, val)
	
	# Colors
	var fill_color_top : Color = Color(1.0, 0.85, 0.1, 0.9)  # Bright yellow
	var fill_color_bottom : Color = Color(1.0, 0.5, 0.0, 0.3)  # Orange, transparent
	var line_color : Color = Color(1.0, 0.9, 0.3, 1.0)  # Yellow line
	var load_line_color : Color = Color(0.95, 0.25, 0.2, 1.0)  # Red load line
	var grid_color : Color = Color(0.3, 0.4, 0.5, 0.3)
	var current_time_color : Color = Color(1.0, 1.0, 1.0, 0.5)
	
	# Draw background
	var bg_rect : Rect2 = Rect2(Vector2.ZERO, graph_size)
	solar_graph.draw_rect(bg_rect, Color(0.05, 0.08, 0.12, 0.8))
	
	# Draw horizontal grid lines (every 2 kW)
	for i in range(0, int(max_val) + 1, 2):
		var y_pos : float = graph_size.y - padding - (float(i) / max_val) * graph_height
		solar_graph.draw_line(
			Vector2(padding, y_pos),
			Vector2(graph_size.x - padding, y_pos),
			grid_color, 1.0
		)
	
	# Draw vertical grid lines (every 6 hours)
	for hour in [0, 6, 12, 18, 24]:
		var x_pos : float = padding + (float(hour) / 24.0) * graph_width
		solar_graph.draw_line(
			Vector2(x_pos, padding),
			Vector2(x_pos, graph_size.y - padding),
			grid_color, 1.0
		)
	
	# Build polygon points for filled area
	var fill_points : PackedVector2Array = PackedVector2Array()
	var line_points : PackedVector2Array = PackedVector2Array()
	
	# Start at bottom left
	fill_points.append(Vector2(padding, graph_size.y - padding))
	
	# Add data points
	var has_area := false
	for i in range(HISTORY_SIZE):
		var x : float = padding + (float(i) + 0.5) / 24.0 * graph_width
		var val : float = solar_history[i] if i < solar_history.size() else 0.0
		if not is_finite(val):
			val = 0.0
		var y : float = graph_size.y - padding - (val / max_val) * graph_height
		y = clampf(y, padding, graph_size.y - padding)
		if y < graph_size.y - padding - 0.01:
			has_area = true
		
		fill_points.append(Vector2(x, y))
		line_points.append(Vector2(x, y))
	
	# End at bottom right
	fill_points.append(Vector2(padding + graph_width, graph_size.y - padding))
	
	# Draw filled area with gradient effect (approximate with solid color).
	# A day with no sun yet (night, or no panels) puts every point on the
	# baseline: a zero-area polygon Godot cannot triangulate, which logged
	# "Invalid polygon data, triangulation failed" on every redraw.
	if fill_points.size() >= 3 and has_area:
		var fill_colors : PackedColorArray = PackedColorArray()
		for i in range(fill_points.size()):
			# Gradient from top (bright) to bottom (dim)
			var t : float = (fill_points[i].y - padding) / graph_height
			fill_colors.append(fill_color_top.lerp(fill_color_bottom, t))
		solar_graph.draw_polygon(fill_points, fill_colors)
	
	# Draw the line on top
	if line_points.size() >= 2:
		solar_graph.draw_polyline(line_points, line_color, 2.0, true)
	
	# Draw AC load line (CSV playback)
	if _csv_playback_active and _is_csv_linked_role("load"):
		var load_points : PackedVector2Array = PackedVector2Array()
		for i in range(HISTORY_SIZE):
			var x : float = padding + (float(i) + 0.5) / 24.0 * graph_width
			var val : float = load_history[i] if i < load_history.size() else 0.0
			var y : float = graph_size.y - padding - (val / max_val) * graph_height
			y = clampf(y, padding, graph_size.y - padding)
			load_points.append(Vector2(x, y))
		if load_points.size() >= 2:
			solar_graph.draw_polyline(load_points, load_line_color, 2.0, true)
	
	# Draw current time indicator
	if main_node:
		var current_hour : float = main_node.day_time
		var time_x : float = padding + (current_hour / 24.0) * graph_width
		solar_graph.draw_line(
			Vector2(time_x, padding),
			Vector2(time_x, graph_size.y - padding),
			current_time_color, 2.0
		)
	
	# Draw hour labels
	var label_font : Font = ThemeDB.fallback_font
	var font_size : int = 9
	for hour in [0, 6, 12, 18]:
		var x_pos : float = padding + (float(hour) / 24.0) * graph_width
		var label_text : String = "%d:00" % hour
		solar_graph.draw_string(
			label_font,
			Vector2(x_pos + 2, graph_size.y - 2),
			label_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			font_size,
			Color(0.5, 0.6, 0.7, 0.8)
		)

func _on_weather_button_pressed() -> void:
	if _weather_live_mode:
		_weather_live_mode = false
		_clear_weather_overrides()
		_update_weather_link_button()
	
	# Cycle: Clear -> Partly Cloudy -> Cloudy -> Rainy -> Auto Sim
	if not _wx_sim_enabled:
		match weather:
			WeatherType.CLEAR:
				set_weather(WeatherType.PARTLY_CLOUDY)
			WeatherType.PARTLY_CLOUDY:
				set_weather(WeatherType.CLOUDY)
			WeatherType.CLOUDY:
				set_weather(WeatherType.RAINY)
			WeatherType.RAINY:
				enable_weather_simulation()
	else:
		# Currently in auto mode — first click switches to manual Clear
		_wx_sim_enabled = false
		set_weather(WeatherType.CLEAR)
	_update_weather_button()

## Re-enable autonomous weather simulation from the current state.
func enable_weather_simulation() -> void:
	_wx_sim_enabled = true
	# Returning to Auto re-enables real Open-Meteo weather (synthetic only fills
	# in when no real data covers the location).
	_user_weather_manual_override = false
	_wx_sim_cloud_cover = _base_cloud_cover
	_wx_sim_hours_in_state = 0.0
	_wx_sim_state_duration = _wx_pick_duration(weather, _wx_get_monthly_params())
	_update_weather_button()

func _update_rain_display() -> void:
	# Update weather line on timeline when it rains
	if weather == WeatherType.RAINY:
		_update_weather_button()

func get_weather_cycle_caption() -> String:
	var mud_indicator := " 🟤" if is_ground_muddy else ""
	var mode_indicator := ""
	if _weather_live_mode:
		mode_indicator = " 📡"
	elif _open_meteo_active:
		if _forecast_active:
			mode_indicator = " 🌤"
		elif _generated_weather_active:
			mode_indicator = " 🎲"
		else:
			mode_indicator = " 🌎"
	elif _wx_sim_enabled:
		mode_indicator = " 🔄"
	match weather:
		WeatherType.CLEAR:
			return "☀ Clear%s%s" % [mode_indicator, mud_indicator]
		WeatherType.PARTLY_CLOUDY:
			return "⛅ Partly%s%s" % [mode_indicator, mud_indicator]
		WeatherType.CLOUDY:
			return "☁ Cloudy%s%s" % [mode_indicator, mud_indicator]
		WeatherType.RAINY:
			var rain_text := "🌧 %.2f\"" % daily_rain_inches
			rain_text += mode_indicator
			if is_ground_muddy:
				rain_text += " 🟤"
			return rain_text
	return "☀ ?"


func get_weather_cycle_modulate() -> Color:
	match weather:
		WeatherType.CLEAR, WeatherType.PARTLY_CLOUDY, WeatherType.CLOUDY, WeatherType.RAINY:
			if _weather_live_mode:
				return Color(0.3, 1.0, 0.5, 1.0)
			if _open_meteo_active:
				if _forecast_active:
					return Color(0.2, 0.9, 0.6, 1.0)
				if _generated_weather_active:
					return Color(0.75, 0.55, 1.0, 1.0)
				return Color(0.4, 0.8, 1.0, 1.0)
			if _wx_sim_enabled:
				return Color(0.5, 0.9, 1.0, 1.0)
			if weather == WeatherType.CLEAR:
				return Color(1.0, 0.9, 0.3, 1.0)
			if weather == WeatherType.PARTLY_CLOUDY:
				return Color(0.9, 0.9, 0.7, 1.0)
			if weather == WeatherType.CLOUDY:
				return Color(0.7, 0.7, 0.8, 1.0)
			return Color(0.5, 0.6, 0.8, 1.0)
	return Color(0.9, 0.9, 0.9, 1.0)


func _update_weather_button() -> void:
	# Timeline shows cycle + status; we only refresh those nodes.
	_sync_timeline_weather_row()


func _sync_timeline_weather_row() -> void:
	var tl: Node = get_tree().root.get_node_or_null("Main/UILayer/TimelineUI")
	if tl == null and get_tree().current_scene:
		tl = get_tree().current_scene.get_node_or_null("UILayer/TimelineUI")
	if tl == null:
		return
	if tl.has_method("set_weather_cycle_display"):
		tl.call("set_weather_cycle_display", get_weather_cycle_caption(), get_weather_cycle_modulate(), get_weather_cycle_tooltip())
	if tl.has_method("set_weather_link_display"):
		tl.call("set_weather_link_display", get_weather_link_tooltip(), get_weather_link_modulate())
	if tl.has_method("set_weather_stats"):
		var solar_rad := _ha_solar_radiation_override if (_weather_live_mode and _ha_solar_radiation_override >= 0) else _simulated_solar_radiation
		var temp := _ha_temperature_override if (_weather_live_mode and _ha_temperature_override > -900.0) else _simulated_temperature
		var wind_ms := _ha_wind_speed_override if (_weather_live_mode and _ha_wind_speed_override >= 0) else _simulated_wind_speed
		var rain_rate := _ha_rain_rate_override if (_weather_live_mode and _ha_rain_rate_override >= 0) else _simulated_rain_rate
		tl.call("set_weather_stats",
			solar_rad,
			temp,
			_simulated_humidity,
			wind_ms,
			_simulated_wind_direction,
			rain_rate,
			_simulated_rain_24h_mm)

# ==================== PANEL SETTINGS (timeline settings tab) ====================

const PANEL_CONFIG_PATH = "user://solar_panel_config.cfg"
const COLLAPSED_BAR_HEIGHT : float = 44.0

var _expanded : bool = false
var _graph_has_solar : bool = false
var _collapse_btn : Button = null
var _body : VBoxContainer = null
## The scoreboard's critical-state banner (AC off, battery at its floor).
var _alert: AlertBanner = null
var _expanded_height : float = 610.0

func _load_panel_settings() -> void:
	var config = ConfigFile.new()
	if config.load(PANEL_CONFIG_PATH) != OK:
		return
	PANEL_COUNT = config.get_value("panel", "panel_count", PANEL_COUNT)
	PANEL_WATTAGE = config.get_value("panel", "panel_wattage", PANEL_WATTAGE)
	panel_tilt_degrees = config.get_value("panel", "panel_tilt", panel_tilt_degrees)
	panel_azimuth_degrees = config.get_value("panel", "panel_azimuth", panel_azimuth_degrees)
	BATTERY_CAPACITY_KWH = config.get_value("panel", "battery_capacity", BATTERY_CAPACITY_KWH)
	INVERTER_MAX_SOLAR_KW = config.get_value("panel", "inverter_max", INVERTER_MAX_SOLAR_KW)
	SYSTEM_CALIBRATION = config.get_value("panel", "calibration", SYSTEM_CALIBRATION)
	PEAK_CAPACITY_KW = PANEL_COUNT * PANEL_WATTAGE / 1000.0
	battery_kwh_stored = minf(battery_kwh_stored, BATTERY_CAPACITY_KWH)
	_high_accuracy_physics = config.get_value("panel", "high_accuracy", _high_accuracy_physics)
	_shadow_raycast_enabled = config.get_value("panel", "shadow_raycast", _shadow_raycast_enabled)

func _save_panel_settings() -> void:
	var config = ConfigFile.new()
	config.set_value("panel", "panel_count", PANEL_COUNT)
	config.set_value("panel", "panel_wattage", PANEL_WATTAGE)
	config.set_value("panel", "panel_tilt", panel_tilt_degrees)
	config.set_value("panel", "panel_azimuth", panel_azimuth_degrees)
	config.set_value("panel", "battery_capacity", BATTERY_CAPACITY_KWH)
	config.set_value("panel", "inverter_max", INVERTER_MAX_SOLAR_KW)
	config.set_value("panel", "calibration", SYSTEM_CALIBRATION)
	config.set_value("panel", "high_accuracy", _high_accuracy_physics)
	config.set_value("panel", "shadow_raycast", _shadow_raycast_enabled)
	config.save(PANEL_CONFIG_PATH)


## Apply aggregate panel/battery specs from a LinkageLab game bundle import.
func apply_from_graph(data: Dictionary) -> void:
	var pc := int(data.get("panel_count", 0))
	var pw := float(data.get("panel_watts", PANEL_WATTAGE))
	var pk := float(data.get("peak_kw", 0.0))
	var bk := float(data.get("battery_kwh", -1.0))
	# battery_count distinguishes "graph genuinely has 0 kWh of real batteries"
	# (bk==0.0 with no battery items — do NOT touch SolarUI's own capacity) from
	# "the graph's placed battery/smartbattery items sum to bk" (count>0 — this
	# IS the intended override). Without this, a graph with no explicit battery
	# node (relying on SolarUI's own battery) would zero BATTERY_CAPACITY_KWH on
	# every graph edit — clamping SOC to [0,0] forever (can't charge or discharge).
	var bcount := int(data.get("battery_count", 0))
	var bank_soc := float(data.get("battery_soc", -1.0))
	# The graph's real plane of array (placed arrays / deployed linkages) and
	# the wired controller's limits replace the config-file values when known.
	if data.has("tilt_deg"):
		panel_tilt_degrees = clampf(float(data["tilt_deg"]), 0.0, 90.0)
	if data.has("azimuth_deg"):
		panel_azimuth_degrees = fposmod(float(data["azimuth_deg"]), 360.0)
	if float(data.get("pv_limit_kw", 0.0)) > 0.0:
		INVERTER_MAX_SOLAR_KW = float(data["pv_limit_kw"])
	if float(data.get("ac_overload_w", 0.0)) > 0.0:
		inverter_overload_watts = float(data["ac_overload_w"])
	PANEL_COUNT = maxi(pc, 0)
	if pw > 0.0:
		PANEL_WATTAGE = pw
	PEAK_CAPACITY_KW = pk if pk > 0.0 else (PANEL_COUNT * PANEL_WATTAGE / 1000.0)
	# This is called from SystemGraphView._on_model_changed — i.e. on EVERY graph
	# model mutation, including the resource engine's own per-tick tank/state
	# writes (many times per second). `bank_soc` is itself a MIRROR of this same
	# SolarUI's battery_kwh_stored, written the other direction by
	# _sync_graph_energy_from_solar() on its own throttled interval. If we
	# repositioned battery_kwh_stored from bank_soc on every call here, we'd
	# constantly stomp the smoothly-integrating live value back to a stale mirror
	# snapshot — the true SOC would keep accumulating invisibly inside
	# energy_timeline while the displayed battery_kwh_stored stayed frozen at the
	# last mirrored value, until some call happened to observe + re-mirror the
	# now-far-diverged true value, producing a big visible jump. So: only
	# reposition SOC (and reset the timeline) when the battery HARDWARE actually
	# changed (added/removed/resized) — never on routine graph edits.
	var capacity_changed := false
	if bk >= 0.0 and bcount > 0:
		capacity_changed = absf(BATTERY_CAPACITY_KWH - bk) > 0.001
		BATTERY_CAPACITY_KWH = bk
		if capacity_changed and _soc_restored_pending:
			# The first capacity sync after a save RESTORE is initialisation, not
			# new hardware: SolarUI booted at the panel-config capacity, the
			# snapshot put back the saved kWh, and the graph's bank now states
			# the real capacity. The restored kWh is the truth — rescaling it by
			# a mirrored fraction (measured against the boot capacity) moved a
			# saved 5.09 kWh to 4.12 on every reload (--capture=worlds, Walton).
			battery_kwh_stored = minf(battery_kwh_stored, BATTERY_CAPACITY_KWH)
		elif capacity_changed:
			if bank_soc >= 0.0:
				battery_kwh_stored = BATTERY_CAPACITY_KWH * clampf(bank_soc, 0.0, 1.0)
			else:
				battery_kwh_stored = minf(battery_kwh_stored, BATTERY_CAPACITY_KWH)
		_soc_restored_pending = false
	if energy_timeline != null and (capacity_changed or energy_timeline.is_empty()):
		energy_timeline.clear()
		if main_node == null:
			_find_main_node()
		if main_node != null and main_node.has_method("get_absolute_hours"):
			var abs_h: float = float(main_node.call("get_absolute_hours"))
			var min_kwh: float = BATTERY_CAPACITY_KWH * MIN_BATTERY_PERCENT / 100.0
			energy_timeline.configure(
				BATTERY_CAPACITY_KWH, CHARGE_EFFICIENCY, DISCHARGE_EFFICIENCY, min_kwh)
			energy_timeline.init_anchor(abs_h, battery_kwh_stored,
				current_solar_kw, current_aux_generation_kw + current_graph_dc_kw, current_load_kw)


func set_graph_has_solar(has: bool) -> void:
	if _graph_has_solar == has:
		visible = has
		return
	_graph_has_solar = has
	visible = has
	if not has:
		_expanded = false
		if _body != null:
			_body.visible = false
	elif _collapse_btn == null:
		_expanded = false
	else:
		_expanded = true
		if _body != null:
			_body.visible = true
	if _collapse_btn != null:
		_update_collapse_btn_text()
		_apply_collapsed_size()


func apply_imported_solar(panel_count: int, panel_watts: float, tilt_deg: float,
		azimuth_deg: float, battery_kwh: float = -1.0) -> void:
	if panel_count > 0:
		PANEL_COUNT = panel_count
	if panel_watts > 0.0:
		PANEL_WATTAGE = panel_watts
	panel_tilt_degrees = clampf(tilt_deg, 0.0, 90.0)
	panel_azimuth_degrees = fposmod(azimuth_deg, 360.0)
	if battery_kwh > 0.0:
		BATTERY_CAPACITY_KWH = battery_kwh
		battery_kwh_stored = minf(battery_kwh_stored, BATTERY_CAPACITY_KWH)
	PEAK_CAPACITY_KW = PANEL_COUNT * PANEL_WATTAGE / 1000.0
	if energy_timeline != null:
		energy_timeline.clear()
	_save_panel_settings()

func get_panel_settings() -> Dictionary:
	return {
		"panel_count": PANEL_COUNT,
		"panel_wattage": PANEL_WATTAGE,
		"panel_tilt": panel_tilt_degrees,
		"panel_azimuth": panel_azimuth_degrees,
		"battery_capacity": BATTERY_CAPACITY_KWH,
		"inverter_max": INVERTER_MAX_SOLAR_KW,
		"calibration": SYSTEM_CALIBRATION,
		"high_accuracy_physics": _high_accuracy_physics,
		"shadow_raycast": _shadow_raycast_enabled,
	}

func apply_panel_setting(key: String, value: Variant) -> void:
	match key:
		"high_accuracy_physics", "shadow_raycast":
			_apply_setting(key, 1.0 if bool(value) else 0.0)
		_:
			_apply_setting(key, float(value))
	_save_panel_settings()

func _setup_collapse() -> void:
	if _collapse_btn != null:
		return
	var vbox := get_node_or_null("Panel/MarginContainer/VBoxContainer") as VBoxContainer
	if vbox == null or title_label == null:
		return
	_expanded_height = maxf(size.y, 520.0)
	custom_minimum_size.x = maxf(custom_minimum_size.x, PANEL_MIN_WIDTH)

	var header := HBoxContainer.new()
	header.name = "CollapseHeader"
	var title_idx := title_label.get_index()
	vbox.add_child(header)
	vbox.move_child(header, title_idx)

	_collapse_btn = Button.new()
	_collapse_btn.flat = true
	_collapse_btn.focus_mode = Control.FOCUS_NONE
	_collapse_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_collapse_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_collapse_btn.add_theme_font_size_override("font_size", 20)
	_collapse_btn.add_theme_color_override("font_color", Color(0.4, 0.8, 1.0))
	_collapse_btn.add_theme_color_override("font_hover_color", Color(0.55, 0.9, 1.0))
	_collapse_btn.pressed.connect(_on_collapse_toggled)
	header.add_child(_collapse_btn)

	title_label.visible = false
	_update_collapse_btn_text()

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", 8)
	var to_move: Array[Node] = []
	for i in range(header.get_index() + 1, vbox.get_child_count()):
		to_move.append(vbox.get_child(i))
	for n in to_move:
		n.reparent(_body)
	vbox.add_child(_body)
	_body.visible = _expanded
	_alert = AlertBanner.new()
	_body.add_child(_alert)
	_body.move_child(_alert, 0)
	_apply_collapsed_size()
	# Placement belongs to the HUD layout manager (top-left, under the
	# weather card); it tucks this into a pill when a tool needs the space.
	HudLayout.register(self, "scoreboard", "top_left", {
		"order": 10, "priority": 3, "title": "power scoreboard", "icon": "zap",
		"size": func() -> Vector2: return Vector2(_panel_width(), _panel_height() if _expanded else COLLAPSED_BAR_HEIGHT),
		"compact": _hud_compact_text,
	})
	# Hidden until the graph reports at least one solar panel.
	visible = _graph_has_solar

func _on_collapse_toggled() -> void:
	_expanded = not _expanded
	if _body != null:
		_body.visible = _expanded
	_update_collapse_btn_text()
	_apply_collapsed_size()

func _update_collapse_btn_text() -> void:
	if _collapse_btn == null:
		return
	if not _graph_has_solar:
		# No solar anywhere → the whole scoreboard is meaningless, so hide it
		# rather than surfacing a "no panels" nag. visible tracks _graph_has_solar
		# (set_graph_has_solar is the authority); re-assert it here so any stray
		# path that left the panel showing collapses back to hidden.
		visible = false
		return
	var title := title_label.text if title_label != null else "⚡ POWER SCOREBOARD"
	_collapse_btn.text = ("▾ " if _expanded else "▸ ") + title
	_collapse_btn.tooltip_text = "Click to collapse or expand the power panel"

## The tucked pill's one line: net power, battery, and AC state when it is off.
func _hud_compact_text() -> String:
	var net := current_solar_kw + current_aux_generation_kw + current_graph_dc_kw - current_load_kw
	var line := "%s%s · %s" % ["+" if net >= 0.0 else "", UiText.num(net * 1000.0, "W"), UiText.pct(get_battery_percent() / 100.0)]
	return line + ("" if _power_available else " · AC off")


## The scoreboard's width and expanded height, never smaller than what its
## content needs (the map scenes still carry the old 380 x 610 offsets).
const PANEL_MIN_WIDTH : float = 396.0

func _panel_width() -> float:
	var panel := get_node_or_null("Panel") as Control
	var need := panel.get_combined_minimum_size().x if panel != null else 0.0
	return maxf(maxf(size.x, PANEL_MIN_WIDTH), need)


func _panel_height() -> float:
	var panel := get_node_or_null("Panel") as Control
	var need := panel.get_combined_minimum_size().y if panel != null else 0.0
	return maxf(_expanded_height, need)


func _apply_collapsed_size() -> void:
	var h := _panel_height() if _expanded else COLLAPSED_BAR_HEIGHT
	offset_bottom = offset_top + h
	custom_minimum_size.y = h

func _apply_setting(key: String, val: float) -> void:
	match key:
		"panel_count":
			PANEL_COUNT = int(val)
			PEAK_CAPACITY_KW = PANEL_COUNT * PANEL_WATTAGE / 1000.0
		"panel_wattage":
			PANEL_WATTAGE = val
			PEAK_CAPACITY_KW = PANEL_COUNT * PANEL_WATTAGE / 1000.0
		"panel_tilt":
			panel_tilt_degrees = val
		"panel_azimuth":
			panel_azimuth_degrees = val
		"battery_capacity":
			BATTERY_CAPACITY_KWH = val
			battery_kwh_stored = minf(battery_kwh_stored, BATTERY_CAPACITY_KWH)
		"inverter_max":
			INVERTER_MAX_SOLAR_KW = val
		"calibration":
			SYSTEM_CALIBRATION = val
		"high_accuracy_physics":
			_high_accuracy_physics = val > 0.5
		"shadow_raycast":
			_shadow_raycast_enabled = val > 0.5

# ==================== SAVE / LOAD (game state snapshot) ====================

func collect_save_state() -> Dictionary:
	var hist: Array = []
	for v in solar_history:
		hist.append(float(v))
	return {
		"battery_kwh_stored": battery_kwh_stored,
		"last_time": last_time,
		"_last_energy_day": _last_energy_day,
		"yesterday_solar_kwh": yesterday_solar_kwh,
		"best_day_solar_kwh": best_day_solar_kwh,
		"daily_solar_generated_kwh": daily_solar_generated_kwh,
		"daily_load_consumed_kwh": daily_load_consumed_kwh,
		"daily_battery_charge_kwh": daily_battery_charge_kwh,
		"daily_battery_discharge_kwh": daily_battery_discharge_kwh,
		"solar_history": hist,
		"history_start_hour": history_start_hour,
		"weather": int(weather),
		"cloud_cover": cloud_cover,
		"_base_cloud_cover": _base_cloud_cover,
		"_cloud_noise_time": _cloud_noise_time,
		"_slider_is_driving": _slider_is_driving,
		"daily_rain_inches": daily_rain_inches,
		"rain_rate_per_hour": rain_rate_per_hour,
		"is_ground_muddy": is_ground_muddy,
		"_last_rain_day": _last_rain_day,
		"_wx_sim_enabled": _wx_sim_enabled,
		"_user_weather_manual_override": _user_weather_manual_override,
		"_wx_sim_cloud_cover": _wx_sim_cloud_cover,
		"_wx_sim_hours_in_state": _wx_sim_hours_in_state,
		"_wx_sim_state_duration": _wx_sim_state_duration,
		"_wx_sim_last_transition_day": _wx_sim_last_transition_day,
		"current_solar_kw": current_solar_kw,
		"_raw_solar_kw": _raw_solar_kw,
		"current_load_kw": current_load_kw,
		"_live_mode_active": _live_mode_active,
		"_simulation_mode": _simulation_mode,
		"_weather_live_mode": _weather_live_mode,
		"_simulated_solar_radiation": _simulated_solar_radiation,
		"_simulated_lux": _simulated_lux,
		"_simulated_rain_rate": _simulated_rain_rate,
		"_simulated_temperature": _simulated_temperature,
		"_simulated_wind_speed": _simulated_wind_speed,
	}


func apply_save_state(data: Dictionary) -> void:
	if data.is_empty():
		return
	battery_kwh_stored = float(data.get("battery_kwh_stored", battery_kwh_stored))
	_soc_restored_pending = data.has("battery_kwh_stored")
	last_time = float(data.get("last_time", -1.0))
	# Re-anchor the reversible SOC cache at the loaded battery level — the next
	# battery tick rebuilds the timeline forward from this known state.
	energy_timeline.clear()
	_last_energy_day = int(data.get("_last_energy_day", -1))
	yesterday_solar_kwh = float(data.get("yesterday_solar_kwh", 0.0))
	best_day_solar_kwh = float(data.get("best_day_solar_kwh", 0.0))
	daily_solar_generated_kwh = float(data.get("daily_solar_generated_kwh", 0.0))
	daily_load_consumed_kwh = float(data.get("daily_load_consumed_kwh", 0.0))
	daily_battery_charge_kwh = float(data.get("daily_battery_charge_kwh", 0.0))
	daily_battery_discharge_kwh = float(data.get("daily_battery_discharge_kwh", 0.0))
	history_start_hour = int(data.get("history_start_hour", 0))
	var hist_raw: Variant = data.get("solar_history", [])
	solar_history.clear()
	if hist_raw is Array:
		for x in hist_raw:
			solar_history.append(float(x))
	else:
		for i in range(HISTORY_SIZE):
			solar_history.append(0.0)
	while solar_history.size() < HISTORY_SIZE:
		solar_history.append(0.0)
	if solar_history.size() > HISTORY_SIZE:
		solar_history.resize(HISTORY_SIZE)
	var weather_val: int = int(data.get("weather", weather))
	weather = weather_val as WeatherType
	cloud_cover = clampf(float(data.get("cloud_cover", cloud_cover)), 0.0, 1.0)
	_base_cloud_cover = clampf(float(data.get("_base_cloud_cover", _base_cloud_cover)), 0.0, 1.0)
	if not is_finite(cloud_cover):
		cloud_cover = 0.0
	if not is_finite(_base_cloud_cover):
		_base_cloud_cover = 0.0
	_cloud_noise_time = float(data.get("_cloud_noise_time", _cloud_noise_time))
	_slider_is_driving = bool(data.get("_slider_is_driving", false))
	daily_rain_inches = float(data.get("daily_rain_inches", daily_rain_inches))
	rain_rate_per_hour = float(data.get("rain_rate_per_hour", rain_rate_per_hour))
	is_ground_muddy = bool(data.get("is_ground_muddy", is_ground_muddy))
	_last_rain_day = int(data.get("_last_rain_day", _last_rain_day))
	_wx_sim_enabled = bool(data.get("_wx_sim_enabled", _wx_sim_enabled))
	_user_weather_manual_override = bool(data.get("_user_weather_manual_override", false))
	_wx_sim_cloud_cover = float(data.get("_wx_sim_cloud_cover", _wx_sim_cloud_cover))
	_wx_sim_hours_in_state = float(data.get("_wx_sim_hours_in_state", _wx_sim_hours_in_state))
	_wx_sim_state_duration = float(data.get("_wx_sim_state_duration", _wx_sim_state_duration))
	_wx_sim_last_transition_day = int(data.get("_wx_sim_last_transition_day", _wx_sim_last_transition_day))
	current_solar_kw = float(data.get("current_solar_kw", current_solar_kw))
	_raw_solar_kw = float(data.get("_raw_solar_kw", _raw_solar_kw))
	current_load_kw = float(data.get("current_load_kw", current_load_kw))
	_live_mode_active = bool(data.get("_live_mode_active", _live_mode_active))
	_simulation_mode = bool(data.get("_simulation_mode", _simulation_mode))
	_weather_live_mode = bool(data.get("_weather_live_mode", _weather_live_mode))
	_simulated_solar_radiation = float(data.get("_simulated_solar_radiation", _simulated_solar_radiation))
	_simulated_lux = float(data.get("_simulated_lux", _simulated_lux))
	_simulated_rain_rate = float(data.get("_simulated_rain_rate", _simulated_rain_rate))
	_simulated_temperature = float(data.get("_simulated_temperature", _simulated_temperature))
	_simulated_wind_speed = float(data.get("_simulated_wind_speed", _simulated_wind_speed))
	battery_kwh_stored = clampf(battery_kwh_stored, 0.0, BATTERY_CAPACITY_KWH)


func refresh_after_save_load() -> void:
	_update_weather_button()
	_update_weather_data_display()
	_update_rain_display()
	_update_display()
	_update_graph()
	if main_node != null and is_instance_valid(main_node):
		_update_sky_visuals()
		_update_weather_lighting()
	if solar_graph != null and is_instance_valid(solar_graph):
		solar_graph.queue_redraw()

extends Control

@export_group("Projection Canvas Visibility")
@export var start_hidden: bool = true
@export var mirror_from_solar_ui_when_available: bool = true
@export_node_path("Control") var solar_ui_path: NodePath = NodePath("../../UILayer/SolarUI")

@export_group("Warp Calibration")
@export var warp_enabled: bool = true
@export var calibration_mode_enabled: bool = false
@export var warp_config_path: String = "user://projection_canvas_warp.cfg"
@export var warp_toggle_action_name: StringName = &"toggle_projection_warp"
@export var calibration_toggle_action_name: StringName = &"toggle_projection_calibration"
@export var warp_reset_action_name: StringName = &"reset_projection_warp"

@export_group("Home Assistant")
@export_node_path("Node") var ha_client_path: NodePath
@export var auto_subscribe_on_ready: bool = true
@export var request_initial_entity_states: bool = true

@export_group("Power Entities")
@export var ha_values_in_watts: bool = true
@export var ha_battery_soc_entity: String = ""
@export var ha_load_entity: String = ""
@export var ha_solar_entity: String = ""
@export var ha_daily_solar_entity: String = ""
@export var ha_daily_load_entity: String = ""

@export_group("Weather Entities")
@export var ha_solar_radiation_entity: String = ""
@export var ha_lux_entity: String = ""
@export var ha_rain_rate_entity: String = ""
@export var ha_rain_state_entity: String = ""
@export var ha_temperature_entity: String = ""
@export var ha_wind_speed_entity: String = ""
@export var ha_rain_rate_in_mm: bool = true
@export var ha_temp_in_celsius: bool = true
@export var ha_wind_in_ms: bool = true

@export_group("Device Rows")
@export var device_names: PackedStringArray = [
	"Device 01",
	"Device 02",
	"Device 03",
	"Device 04",
	"Device 05",
	"Device 06",
	"Device 07",
	"Device 08"
]
@export var device_entity_ids: PackedStringArray = ["", "", "", "", "", "", "", ""]
@export var device_max_watts: PackedFloat32Array = [4000.0, 4000.0, 4000.0, 4000.0, 4000.0, 4000.0, 4000.0, 4000.0]

@export_group("Simulated Comparison Values")
@export var simulated_battery_soc: float = 82.0
@export var simulated_solar_today_kwh: float = 18.4
@export var simulated_load_today_kwh: float = 14.1
@export var simulated_current_load_watts: float = 1850.0
@export var simulated_current_solar_watts: float = 2275.0
@export var simulated_weather_state: String = "Sunny"
@export var simulated_weather_temp_c: float = 24.0
@export var simulated_weather_wind_ms: float = 2.8
@export var simulated_device_watts: PackedFloat32Array = [350.0, 220.0, 110.0, 480.0, 160.0, 95.0, 210.0, 145.0]

enum AccentThemeMode {
	NEON_CYAN,
	NEON_AMBER,
	NEON_CRIMSON,
	NEON_AUTO_ALERT
}

@export_group("Visual Theme + Animation")
@export var accent_theme_mode: AccentThemeMode = AccentThemeMode.NEON_CYAN
@export var low_battery_alert_threshold: float = 20.0
@export var high_load_alert_watts: float = 4500.0
@export var value_animation_speed: float = 10.0

@export_group("Simulated View Camera")
@export_node_path("Camera3D") var source_camera_path: NodePath
@export var use_source_world_3d: bool = true
@export var sync_camera_transform: bool = false
@export var sim_camera_move_speed: float = 8.0
@export var sim_camera_fast_multiplier: float = 2.5
@export var sim_camera_look_sensitivity: float = 0.12
@export var sim_camera_fov_step: float = 2.0
@export var sim_camera_min_fov: float = 25.0
@export var sim_camera_max_fov: float = 100.0

@export_group("Timelapse Sync")
## Enable automatic speed/pause sync between the loaded timelapse video and the simulation.
@export var video_sync_enabled: bool = true
## The time_scale value at which the video plays at 1× speed (450× = 0.125).
## One video frame every 15 real seconds recorded at 450× gives time_scale = 0.125.
@export var video_reference_time_scale: float = 0.125
## Simulation day_time (hours 0–24) that corresponds to video frame 0.
## Set this to align the video start with the correct time of day in the simulation.
@export var video_start_hour: float = 0.0
## Keep TR video letterboxed instead of stretching when controls reduce panel height.
@export var timelapse_display_aspect: float = 1.7777778
## Optional explicit path to the shared TimelineUI controller.
@export_node_path("Node") var timeline_ui_path: NodePath = NodePath("../TimelineUI")

@export_group("Webcam")
@export var webcam_feed_id: int = -1
@export var webcam_use_camera_texture: bool = true
@export var webcam_config_path: String = "user://projection_canvas_webcam.cfg"
@export var prefer_obs_virtual_camera: bool = true
@export var obs_camera_name_patterns: PackedStringArray = PackedStringArray([
	"obs virtual camera",
	"obs virtual",
	"obs-camera",
	"obs camera",
	"obs-cam",
])

const QUADRANT_KEYS: Array[String] = ["TL", "TR", "BL", "BR"]
const WEBCAM_FEED_RETRY_SECONDS: float = 1.0
const WEBCAM_FEED_RETRY_COUNT: int = 30
const HANDLE_HALF_SIZE: float = 6.0
const WARP_CONFIG_VERSION: int = 1

@onready var source_preview: SubViewportContainer = $SourcePreview
@onready var source_subviewport: SubViewport = $SourcePreview/SourceSubViewport
@onready var calibration_overlay: Control = $CalibrationOverlay
@onready var warp_output_layer: Node2D = $WarpOutputLayer
@onready var active_quadrant_label: Label = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/ActiveQuadrantLabel
@onready var warp_enabled_check: CheckBox = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/WarpEnabledCheck
@onready var prev_quadrant_button: Button = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/ButtonsRow/PrevQuadrantButton
@onready var next_quadrant_button: Button = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/ButtonsRow/NextQuadrantButton
@onready var save_warp_button: Button = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/ButtonsRow2/SaveWarpButton
@onready var reset_warp_button: Button = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/ButtonsRow2/ResetWarpButton
@onready var exit_calibration_button: Button = $CalibrationOverlay/WarpControlPanel/WarpPanelMargin/WarpPanelVBox/ExitCalibrationButton

@onready var warp_quadrant_tl: Polygon2D = $WarpOutputLayer/WarpQuadrantTL
@onready var warp_quadrant_tr: Polygon2D = $WarpOutputLayer/WarpQuadrantTR
@onready var warp_quadrant_bl: Polygon2D = $WarpOutputLayer/WarpQuadrantBL
@onready var warp_quadrant_br: Polygon2D = $WarpOutputLayer/WarpQuadrantBR

@onready var tl_subviewport: SubViewport = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel/TLViewportContainer/TLSubViewport
@onready var tl_camera: Camera3D = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel/TLViewportContainer/TLSubViewport/TLCamera3D
@onready var tl_status_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLStatusLabel
@onready var tl_viewport_container: SubViewportContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel/TLViewportContainer
@onready var tl_margin: MarginContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin
@onready var tl_vbox: VBoxContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox
@onready var tl_panel: PanelContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView
@onready var tl_viewport_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLViewportPanel
@onready var tl_title_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTL_SimulatedView/TLMargin/TLVBox/TLTitle

@onready var tr_camera_texture_rect: TextureRect = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRCameraTexture
@onready var tr_video_stream_player: VideoStreamPlayer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRVideoStreamPlayer
@onready var tr_video_placeholder: ColorRect = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRVideoPlaceholder
@onready var tr_status_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRStatusLabel
@onready var tr_panel: PanelContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam
@onready var tr_margin: MarginContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin
@onready var tr_vbox: VBoxContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox
@onready var tr_video_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel
@onready var tr_video_host: Control = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost
@onready var tr_title_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRHeaderRow/TRTitle
@onready var tr_select_feed_button: Button = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRHeaderRow/TRSelectFeedButton
@onready var tr_load_video_button: Button = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRHeaderRow/TRLoadVideoButton
@onready var video_file_dialog: FileDialog = $VideoFileDialog
@onready var tr_feed_name_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRFeedNameLabel
@onready var tr_placeholder_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRVideoPanel/TRVideoHost/TRVideoPlaceholder/TRPlaceholderLabel
@onready var webcam_setup_dialog: Window = $WebcamSetupDialog
@onready var dialog_intro_label: Label = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogIntroLabel
@onready var dialog_current_feed_label: Label = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogCurrentFeedLabel
@onready var feed_option_button: OptionButton = $WebcamSetupDialog/DialogMargin/DialogVBox/FeedOptionButton
@onready var dialog_refresh_button: Button = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogRefreshButton
@onready var webcam_use_camera_texture_check: CheckBox = $WebcamSetupDialog/DialogMargin/DialogVBox/WebcamUseCameraTextureCheck
@onready var dialog_help_label: Label = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogHelpLabel
@onready var dialog_cancel_button: Button = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogButtons/DialogCancelButton
@onready var dialog_apply_button: Button = $WebcamSetupDialog/DialogMargin/DialogVBox/DialogButtons/DialogApplyButton

const _TR_SYNC_BAR := "SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRTimelapseSyncBar"
const _TR_SPEED_BAR := "SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantTR_LiveWebcam/TRMargin/TRVBox/TRTimelapseSpeedBar"
@onready var tr_video_play_pause_btn: Button = get_node_or_null(_TR_SYNC_BAR + "/TRVideoPlayPauseBtn")
@onready var tr_video_scrubber: HSlider = get_node_or_null(_TR_SYNC_BAR + "/TRVideoScrubber")
@onready var tr_video_time_label: Label = get_node_or_null(_TR_SYNC_BAR + "/TRVideoTimeLabel")
@onready var tr_video_slower_btn: Button = get_node_or_null(_TR_SPEED_BAR + "/TRVideoSlowerBtn")
@onready var tr_video_speed_label: Label = get_node_or_null(_TR_SPEED_BAR + "/TRVideoSpeedLabel")
@onready var tr_video_faster_btn: Button = get_node_or_null(_TR_SPEED_BAR + "/TRVideoFasterBtn")
@onready var tr_video_sync_btn: Button = get_node_or_null(_TR_SPEED_BAR + "/TRVideoSyncBtn")

@onready var bl_battery_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLBatteryPanel/BLBatteryVBox/BLBatteryValue
@onready var bl_panel: PanelContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison
@onready var bl_solar_today_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLSolarTodayPanel/BLSolarTodayVBox/BLSolarTodayValue
@onready var bl_load_today_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLLoadTodayPanel/BLLoadTodayVBox/BLLoadTodayValue
@onready var bl_current_load_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLCurrentLoadPanel/BLCurrentLoadVBox/BLCurrentLoadValue
@onready var bl_current_solar_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLCurrentSolarPanel/BLCurrentSolarVBox/BLCurrentSolarValue
@onready var bl_net_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLNetPanel/BLNetVBox/BLNetValue
@onready var bl_weather_state_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLWeatherPanel/BLWeatherMargin/BLWeatherGrid/BLWeatherStateValue
@onready var bl_weather_temp_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLWeatherPanel/BLWeatherMargin/BLWeatherGrid/BLWeatherTempValue
@onready var bl_weather_wind_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLWeatherPanel/BLWeatherMargin/BLWeatherGrid/BLWeatherWindValue
@onready var bl_connection_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLConnectionLabel

@onready var br_battery_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRBatteryPanel/BRBatteryVBox/BRBatteryValue
@onready var br_panel: PanelContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison
@onready var br_solar_today_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRSolarTodayPanel/BRSolarTodayVBox/BRSolarTodayValue
@onready var br_load_today_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRLoadTodayPanel/BRLoadTodayVBox/BRLoadTodayValue
@onready var br_current_load_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRCurrentLoadPanel/BRCurrentLoadVBox/BRCurrentLoadValue
@onready var br_current_solar_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRCurrentSolarPanel/BRCurrentSolarVBox/BRCurrentSolarValue
@onready var br_net_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRNetPanel/BRNetVBox/BRNetValue
@onready var br_weather_state_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRWeatherPanel/BRWeatherMargin/BRWeatherGrid/BRWeatherStateValue
@onready var br_weather_temp_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRWeatherPanel/BRWeatherMargin/BRWeatherGrid/BRWeatherTempValue
@onready var br_weather_wind_value: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRWeatherPanel/BRWeatherMargin/BRWeatherGrid/BRWeatherWindValue
@onready var br_connection_label: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRConnectionLabel
@onready var br_battery_delta: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRBatteryPanel/BRBatteryVBox/BRBatteryDelta
@onready var br_solar_today_delta: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRSolarTodayPanel/BRSolarTodayVBox/BRSolarTodayDelta
@onready var br_load_today_delta: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRLoadTodayPanel/BRLoadTodayVBox/BRLoadTodayDelta
@onready var br_current_load_delta: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRCurrentLoadPanel/BRCurrentLoadVBox/BRCurrentLoadDelta
@onready var br_current_solar_delta: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRCurrentSolarPanel/BRCurrentSolarVBox/BRCurrentSolarDelta
@onready var br_net_delta: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRNetPanel/BRNetVBox/BRNetDelta
@onready var bl_graph_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLGraphPanel
@onready var bl_graph_host: Control = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLGraphPanel/BLGraphMargin/BLGraphHost
@onready var bl_graph_solar_line: Line2D = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLGraphPanel/BLGraphMargin/BLGraphHost/BLGraphSolarLine
@onready var bl_graph_load_line: Line2D = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLGraphPanel/BLGraphMargin/BLGraphHost/BLGraphLoadLine
@onready var br_graph_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRGraphPanel
@onready var br_graph_host: Control = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRGraphPanel/BRGraphMargin/BRGraphHost
@onready var br_graph_solar_line: Line2D = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRGraphPanel/BRGraphMargin/BRGraphHost/BRGraphSolarLine
@onready var br_graph_load_line: Line2D = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRGraphPanel/BRGraphMargin/BRGraphHost/BRGraphLoadLine
@onready var bl_weather_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLWeatherPanel
@onready var br_weather_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRWeatherPanel
@onready var bl_devices_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel
@onready var br_devices_panel: Panel = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel
@onready var bl_weather_grid: GridContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLWeatherPanel/BLWeatherMargin/BLWeatherGrid
@onready var br_weather_grid: GridContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRWeatherPanel/BRWeatherMargin/BRWeatherGrid
@onready var bl_device_rows: VBoxContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows
@onready var br_device_rows: VBoxContainer = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows
@onready var bl_devices_header: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDevicesHeader
@onready var br_devices_header: Label = $SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDevicesHeader
@onready var sim_stat_panels: Array[Panel] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLBatteryPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLSolarTodayPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLLoadTodayPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLCurrentLoadPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLStatsGrid/BLCurrentSolarPanel
]
@onready var live_stat_panels: Array[Panel] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRBatteryPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRSolarTodayPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRLoadTodayPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRCurrentLoadPanel,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRStatsGrid/BRCurrentSolarPanel
]

@onready var sim_device_name_labels: Array[Label] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow01/BLDevice01Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow02/BLDevice02Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow03/BLDevice03Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow04/BLDevice04Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow05/BLDevice05Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow06/BLDevice06Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow07/BLDevice07Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow08/BLDevice08Name
]

@onready var sim_device_power_labels: Array[Label] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow01/BLDevice01Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow02/BLDevice02Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow03/BLDevice03Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow04/BLDevice04Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow05/BLDevice05Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow06/BLDevice06Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow07/BLDevice07Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow08/BLDevice08Power
]

@onready var sim_device_meter_bars: Array[ProgressBar] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow01/BLDevice01Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow02/BLDevice02Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow03/BLDevice03Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow04/BLDevice04Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow05/BLDevice05Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow06/BLDevice06Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow07/BLDevice07Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBL_Comparison/BLMargin/BLVBox/BLDevicesPanel/BLDevicesMargin/BLDevicesVBox/BLDeviceRows/BLDeviceRow08/BLDevice08Meter
]

@onready var actual_device_name_labels: Array[Label] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow01/BRDevice01Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow02/BRDevice02Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow03/BRDevice03Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow04/BRDevice04Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow05/BRDevice05Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow06/BRDevice06Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow07/BRDevice07Name,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow08/BRDevice08Name
]

@onready var actual_device_power_labels: Array[Label] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow01/BRDevice01Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow02/BRDevice02Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow03/BRDevice03Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow04/BRDevice04Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow05/BRDevice05Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow06/BRDevice06Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow07/BRDevice07Power,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow08/BRDevice08Power
]

@onready var actual_device_meter_bars: Array[ProgressBar] = [
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow01/BRDevice01Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow02/BRDevice02Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow03/BRDevice03Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow04/BRDevice04Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow05/BRDevice05Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow06/BRDevice06Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow07/BRDevice07Meter,
	$SourcePreview/SourceSubViewport/SourceCanvasRoot/QuadrantGrid/QuadrantBR_Comparison/BRMargin/BRVBox/BRDevicesPanel/BRDevicesMargin/BRDevicesVBox/BRDeviceRows/BRDeviceRow08/BRDevice08Meter
]

@onready var handle_tl_0: ColorRect = $CalibrationOverlay/HandleTL_0
@onready var handle_tl_1: ColorRect = $CalibrationOverlay/HandleTL_1
@onready var handle_tl_2: ColorRect = $CalibrationOverlay/HandleTL_2
@onready var handle_tl_3: ColorRect = $CalibrationOverlay/HandleTL_3
@onready var handle_tr_0: ColorRect = $CalibrationOverlay/HandleTR_0
@onready var handle_tr_1: ColorRect = $CalibrationOverlay/HandleTR_1
@onready var handle_tr_2: ColorRect = $CalibrationOverlay/HandleTR_2
@onready var handle_tr_3: ColorRect = $CalibrationOverlay/HandleTR_3
@onready var handle_bl_0: ColorRect = $CalibrationOverlay/HandleBL_0
@onready var handle_bl_1: ColorRect = $CalibrationOverlay/HandleBL_1
@onready var handle_bl_2: ColorRect = $CalibrationOverlay/HandleBL_2
@onready var handle_bl_3: ColorRect = $CalibrationOverlay/HandleBL_3
@onready var handle_br_0: ColorRect = $CalibrationOverlay/HandleBR_0
@onready var handle_br_1: ColorRect = $CalibrationOverlay/HandleBR_1
@onready var handle_br_2: ColorRect = $CalibrationOverlay/HandleBR_2
@onready var handle_br_3: ColorRect = $CalibrationOverlay/HandleBR_3

var _ha_client: Node = null
var _source_camera: Camera3D = null
var _actual_current_solar_watts: float = 0.0
var _actual_current_load_watts: float = 0.0
var _actual_daily_solar_kwh: float = 0.0
var _actual_daily_load_kwh: float = 0.0
var _actual_battery_soc: float = 0.0
var _actual_weather_state: String = "Unknown"
var _solar_ui: Node = null
var _solar_daily_label: Label = null
var _solar_power_label: Label = null
var _solar_load_label: Label = null
var _solar_net_label: Label = null
var _solar_battery_percent_label: Label = null
var _camera_texture: CameraTexture = null
var _active_webcam_feed_name: String = ""
var _saved_webcam_feed_name: String = ""
var _active_video_file_path: String = ""
var _webcam_feed_retry_remaining: int = 0
var _webcam_feed_retry_timer: float = 0.0
var _webcam_user_disabled_auto: bool = false

var _warp_polygons: Dictionary = {}
var _warp_default_points: Dictionary = {}
var _warp_default_uv: Dictionary = {}
var _warp_points: Dictionary = {}
var _handle_nodes: Dictionary = {}
var _active_quadrant_idx: int = 0
var _dragging_handle: bool = false
var _drag_quadrant: String = ""
var _drag_corner: int = -1
var _sim_camera_control_active: bool = false
var _sim_camera_look_dragging: bool = false
var _sim_camera_yaw: float = 0.0
var _sim_camera_pitch: float = 0.0
var _metric_targets: Dictionary = {}
var _metric_displayed: Dictionary = {}
var _metric_labels: Dictionary = {}
var _sim_solar_history: PackedFloat32Array = PackedFloat32Array()
var _sim_load_history: PackedFloat32Array = PackedFloat32Array()
var _actual_solar_history: PackedFloat32Array = PackedFloat32Array()
var _actual_load_history: PackedFloat32Array = PackedFloat32Array()
var _graph_sample_timer: float = 0.0
## Observed-vs-simulated compare mode: BL = batch-rendered sim, BR = imported
## observed datastream, both driven by SolarUI from the synced playhead. When
## active, the rolling-history sampler and live-solar mirror are suspended so the
## panels reflect the playhead instead of wall-clock-appended samples.
var _compare_active: bool = false

## Emitted when a video file is loaded or the start anchor changes.
signal video_clip_changed

## Absolute sim-hours at which video frame 0 aligns to sim time.
## NAN = fall back to day_time-based sync (legacy / no clip set yet).
var video_start_abs_hours: float = NAN
## Sim-hours covered by one full play-through of the loaded video (cached on load).
var _video_duration_sim_hours: float = 0.0

var _video_sync_main: Node = null
var _video_scrubber_updating: bool = false
var _video_last_timescale: float = 0.125
var _video_seek_accum: float = 0.0
var _tr_video_layout_guard: bool = false

const GRAPH_SAMPLE_COUNT: int = 96
const GRAPH_SAMPLE_INTERVAL_SECONDS: float = 30.0
const VIDEO_SYNC_SEEK_INTERVAL_SECONDS: float = 0.15
const VIDEO_SYNC_DRIFT_TOLERANCE_SECONDS: float = 0.20

func _ready() -> void:
	visible = not start_hidden
	_apply_layout_polish()
	_setup_warp_nodes()
	_initialize_metric_animation()
	_initialize_graph_history()
	_apply_device_editor_defaults()
	_load_webcam_config()
	_initialize_camera_extension()
	_resolve_source_camera()
	_resolve_solar_ui_fallback()
	_update_camera_status_label()
	_connect_webcam_ui_signals()
	_connect_warp_ui_signals()
	_connect_sim_camera_ui_signals()
	_sync_subviewport_input()
	_begin_webcam_feed_discovery()
	_resolve_ha_client()
	_load_warp_config()
	_apply_warp_visibility()
	_update_active_quadrant_ui()
	_cache_sim_camera_angles()
	_apply_accent_theme()
	_connect_video_sync_signals()
	_hide_tr_video_controls()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		_rescan_camera_feeds(true)


func _process(delta: float) -> void:
	if not visible and _sim_camera_control_active:
		_sim_camera_control_active = false
		_sim_camera_look_dragging = false
		_update_camera_status_label()
	_animate_metric_values(delta)
	_tick_graph_history(delta)
	_update_graph_lines()
	_sync_simulated_camera()
	_update_sim_camera_controls(delta)
	_sync_from_solar_ui_fallback()
	_update_webcam_status()
	_tick_webcam_feed_discovery(delta)
	_sync_subviewport_input()
	_layout_tr_video_content()
	_update_video_sync(delta)


func _input(event: InputEvent) -> void:
	if visible and not calibration_mode_enabled:
		_try_activate_sim_camera_from_click(event)
		_try_open_webcam_setup_from_click(event)

	if visible and _sim_camera_control_active and not calibration_mode_enabled:
		_handle_sim_camera_input(event)
		if _should_consume_sim_camera_event(event):
			get_viewport().set_input_as_handled()
			return

	if not calibration_mode_enabled:
		return

	if event is InputEventMouseMotion and _dragging_handle:
		var local_mouse: Vector2 = get_local_mouse_position()
		local_mouse.x = clampf(local_mouse.x, 0.0, size.x)
		local_mouse.y = clampf(local_mouse.y, 0.0, size.y)
		_set_warp_corner(_drag_quadrant, _drag_corner, local_mouse)
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_LEFT and not mouse_event.pressed and _dragging_handle:
			_dragging_handle = false
			_drag_quadrant = ""
			_drag_corner = -1
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	var key_event: InputEventKey = null
	if event is InputEventKey:
		key_event = event as InputEventKey

	var key_pressed: bool = key_event != null and key_event.pressed and not key_event.echo
	var toggle_warp_pressed: bool = event.is_action_pressed(warp_toggle_action_name) or (key_pressed and (key_event.keycode == KEY_F9 or key_event.physical_keycode == KEY_F9))
	var toggle_calibration_pressed: bool = event.is_action_pressed(calibration_toggle_action_name) or (key_pressed and (key_event.keycode == KEY_F10 or key_event.physical_keycode == KEY_F10))
	var reset_warp_pressed: bool = event.is_action_pressed(warp_reset_action_name) or (key_pressed and (key_event.keycode == KEY_F8 or key_event.physical_keycode == KEY_F8))

	if toggle_warp_pressed:
		warp_enabled = not warp_enabled
		_apply_warp_visibility()
		get_viewport().set_input_as_handled()
		return

	if toggle_calibration_pressed:
		calibration_mode_enabled = not calibration_mode_enabled
		if calibration_mode_enabled:
			warp_enabled = true
		_apply_warp_visibility()
		_update_active_quadrant_ui()
		get_viewport().set_input_as_handled()
		return

	if reset_warp_pressed:
		_reset_warp_to_defaults()
		get_viewport().set_input_as_handled()
		return

	if calibration_mode_enabled and key_event != null:
		if key_event.pressed and not key_event.echo and key_event.keycode == KEY_ENTER:
			_save_warp_config()
			get_viewport().set_input_as_handled()


func _setup_warp_nodes() -> void:
	_warp_polygons = {
		"TL": warp_quadrant_tl,
		"TR": warp_quadrant_tr,
		"BL": warp_quadrant_bl,
		"BR": warp_quadrant_br
	}

	_handle_nodes = {
		"TL": [handle_tl_0, handle_tl_1, handle_tl_2, handle_tl_3],
		"TR": [handle_tr_0, handle_tr_1, handle_tr_2, handle_tr_3],
		"BL": [handle_bl_0, handle_bl_1, handle_bl_2, handle_bl_3],
		"BR": [handle_br_0, handle_br_1, handle_br_2, handle_br_3]
	}

	var source_texture: Texture2D = source_subviewport.get_texture()
	for key in QUADRANT_KEYS:
		var poly: Polygon2D = _warp_polygons[key]
		poly.texture = source_texture
		_warp_default_points[key] = Array(poly.polygon)
		_warp_default_uv[key] = Array(poly.uv)
		_warp_points[key] = Array(poly.polygon)
		_apply_polygon_points(key)


func _connect_warp_ui_signals() -> void:
	if warp_enabled_check != null and not warp_enabled_check.toggled.is_connected(_on_warp_enabled_check_toggled):
		warp_enabled_check.toggled.connect(_on_warp_enabled_check_toggled)
	if prev_quadrant_button != null and not prev_quadrant_button.pressed.is_connected(_on_prev_quadrant_pressed):
		prev_quadrant_button.pressed.connect(_on_prev_quadrant_pressed)
	if next_quadrant_button != null and not next_quadrant_button.pressed.is_connected(_on_next_quadrant_pressed):
		next_quadrant_button.pressed.connect(_on_next_quadrant_pressed)
	if save_warp_button != null and not save_warp_button.pressed.is_connected(_save_warp_config):
		save_warp_button.pressed.connect(_save_warp_config)
	if reset_warp_button != null and not reset_warp_button.pressed.is_connected(_reset_warp_to_defaults):
		reset_warp_button.pressed.connect(_reset_warp_to_defaults)
	if exit_calibration_button != null and not exit_calibration_button.pressed.is_connected(_on_exit_calibration_pressed):
		exit_calibration_button.pressed.connect(_on_exit_calibration_pressed)

	for key in QUADRANT_KEYS:
		var handles: Array = _handle_nodes[key]
		for i in range(handles.size()):
			var handle: ColorRect = handles[i]
			if handle == null:
				continue
			handle.mouse_filter = Control.MOUSE_FILTER_STOP
			handle.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			if not handle.gui_input.is_connected(_on_warp_handle_gui_input):
				handle.gui_input.connect(_on_warp_handle_gui_input.bind(key, i))

	_update_handle_positions()


func _connect_sim_camera_ui_signals() -> void:
	if tl_viewport_container != null and not tl_viewport_container.gui_input.is_connected(_on_tl_viewport_gui_input):
		tl_viewport_container.gui_input.connect(_on_tl_viewport_gui_input)


func _on_warp_enabled_check_toggled(checked: bool) -> void:
	warp_enabled = checked
	_apply_warp_visibility()


func _on_prev_quadrant_pressed() -> void:
	_active_quadrant_idx = wrapi(_active_quadrant_idx - 1, 0, QUADRANT_KEYS.size())
	_update_active_quadrant_ui()


func _on_next_quadrant_pressed() -> void:
	_active_quadrant_idx = wrapi(_active_quadrant_idx + 1, 0, QUADRANT_KEYS.size())
	_update_active_quadrant_ui()


func _on_exit_calibration_pressed() -> void:
	calibration_mode_enabled = false
	_apply_warp_visibility()


func _on_warp_handle_gui_input(event: InputEvent, quadrant_key: String, corner_index: int) -> void:
	if not calibration_mode_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_active_quadrant_idx = QUADRANT_KEYS.find(quadrant_key)
			_update_active_quadrant_ui()
			_dragging_handle = true
			_drag_quadrant = quadrant_key
			_drag_corner = corner_index
			get_viewport().set_input_as_handled()


func _apply_warp_visibility() -> void:
	if source_preview != null:
		source_preview.visible = true
		source_preview.modulate.a = 0.0 if warp_enabled else 1.0
	if warp_output_layer != null:
		warp_output_layer.visible = warp_enabled
	if calibration_overlay != null:
		calibration_overlay.visible = calibration_mode_enabled
	if warp_enabled_check != null:
		warp_enabled_check.button_pressed = warp_enabled
	_update_handle_positions()
	_sync_subviewport_input()


func _update_active_quadrant_ui() -> void:
	var key := QUADRANT_KEYS[_active_quadrant_idx]
	_set_label_text(active_quadrant_label, "Active Quadrant: %s" % key)
	for k in QUADRANT_KEYS:
		var alpha := 1.0 if k == key else 0.42
		var handles: Array = _handle_nodes[k]
		for handle in handles:
			var c := (handle as ColorRect).color
			c.a = alpha
			(handle as ColorRect).color = c


func _set_warp_corner(quadrant_key: String, corner_index: int, point: Vector2) -> void:
	var points: Array = _warp_points[quadrant_key]
	points[corner_index] = point
	_warp_points[quadrant_key] = points
	_apply_polygon_points(quadrant_key)
	_update_handle_positions()


func _apply_polygon_points(quadrant_key: String) -> void:
	var poly: Polygon2D = _warp_polygons[quadrant_key]
	var points: Array = _warp_points[quadrant_key]
	poly.polygon = PackedVector2Array(points)
	poly.uv = PackedVector2Array(_warp_default_uv[quadrant_key])


func _update_handle_positions() -> void:
	for key in QUADRANT_KEYS:
		var points: Array = _warp_points[key]
		var handles: Array = _handle_nodes[key]
		for i in range(min(points.size(), handles.size())):
			var handle: ColorRect = handles[i]
			var p: Vector2 = points[i]
			handle.position = p - Vector2(HANDLE_HALF_SIZE, HANDLE_HALF_SIZE)


func _reset_warp_to_defaults() -> void:
	for key in QUADRANT_KEYS:
		_warp_points[key] = _warp_default_points[key].duplicate(true)
		_apply_polygon_points(key)
	_update_handle_positions()
	_save_warp_config()


func _load_warp_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(warp_config_path) != OK:
		return
	var version := int(cfg.get_value("warp", "version", 0))
	if version != WARP_CONFIG_VERSION:
		return

	for key in QUADRANT_KEYS:
		var packed: PackedVector2Array = cfg.get_value("warp", key, PackedVector2Array())
		if packed.size() != 4:
			continue
		_warp_points[key] = Array(packed)
		_apply_polygon_points(key)
	_update_handle_positions()


func _save_warp_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("warp", "version", WARP_CONFIG_VERSION)
	cfg.set_value("warp", "canvas_size", size)
	for key in QUADRANT_KEYS:
		cfg.set_value("warp", key, PackedVector2Array(_warp_points[key]))
	cfg.save(warp_config_path)


func _resolve_ha_client() -> void:
	if not ha_client_path.is_empty():
		_ha_client = get_node_or_null(ha_client_path)
	if _ha_client == null:
		_ha_client = get_tree().root.find_child("HAClient", true, false)

	if _ha_client == null:
		_set_label_text(br_connection_label, "Live Source: HAClient node not found")
		return

	if _ha_client.has_signal("sensor_updated") and not _ha_client.sensor_updated.is_connected(_on_ha_sensor_updated):
		_ha_client.sensor_updated.connect(_on_ha_sensor_updated)
	if _ha_client.has_signal("connection_status_changed") and not _ha_client.connection_status_changed.is_connected(_on_ha_connection_status_changed):
		_ha_client.connection_status_changed.connect(_on_ha_connection_status_changed)
	if _ha_client.has_signal("authentication_status_changed") and not _ha_client.authentication_status_changed.is_connected(_on_ha_auth_status_changed):
		_ha_client.authentication_status_changed.connect(_on_ha_auth_status_changed)

	if auto_subscribe_on_ready:
		_subscribe_to_exported_entities()


func _resolve_solar_ui_fallback() -> void:
	if solar_ui_path.is_empty():
		_solar_ui = null
		return

	_solar_ui = get_node_or_null(solar_ui_path)
	if _solar_ui == null:
		return

	_solar_daily_label = _solar_ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/ScoreboardRow/ColToday/ScoreboardToday")
	_solar_power_label = _solar_ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/SolarContainer/SolarValue")
	_solar_load_label = _solar_ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/LoadContainer/LoadValue")
	_solar_net_label = _solar_ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/NetContainer/NetValue")
	_solar_battery_percent_label = _solar_ui.get_node_or_null("Panel/MarginContainer/VBoxContainer/BatteryContainer/BatteryPercent")


func _resolve_source_camera() -> void:
	if source_camera_path.is_empty():
		_source_camera = null
		return
	var candidate := get_node_or_null(source_camera_path)
	if candidate is Camera3D:
		_source_camera = candidate as Camera3D
		if use_source_world_3d and tl_subviewport != null:
			tl_subviewport.world_3d = _source_camera.get_world_3d()
		if tl_camera != null and not sync_camera_transform:
			_cache_sim_camera_angles()
	else:
		_source_camera = null


func _sync_simulated_camera() -> void:
	if not sync_camera_transform:
		return
	if _source_camera == null:
		return
	if tl_camera == null:
		return
	tl_camera.global_transform = _source_camera.global_transform
	tl_camera.fov = _source_camera.fov
	tl_camera.near = _source_camera.near
	tl_camera.far = _source_camera.far
	if use_source_world_3d and tl_subviewport != null and tl_subviewport.world_3d != _source_camera.get_world_3d():
		tl_subviewport.world_3d = _source_camera.get_world_3d()
	_update_camera_status_label()


func _update_camera_status_label() -> void:
	if _sim_camera_control_active:
		_set_label_text(tl_status_label, "Sim Camera: Control Active (WASD + Space/Ctrl, drag look, wheel FOV, Esc to exit)")
		return
	if sync_camera_transform:
		if _source_camera == null:
			_set_label_text(tl_status_label, "Sim Camera: Sync waiting for source camera")
			return
		_set_label_text(tl_status_label, "Sim Camera: Synced to %s (click panel to take control)" % _source_camera.name)
		return
	_set_label_text(tl_status_label, "Sim Camera: Free mode (click panel to control)")


func _try_activate_sim_camera_from_click(event: InputEvent) -> void:
	if tl_viewport_container == null:
		return
	if event is not InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var panel_rect: Rect2 = tl_viewport_container.get_global_rect()
	if panel_rect.has_point(mb.global_position):
		_sim_camera_control_active = true
		_sim_camera_look_dragging = true
		_update_camera_status_label()
	else:
		_sim_camera_control_active = false
		_sim_camera_look_dragging = false
		_update_camera_status_label()


func _handle_sim_camera_input(event: InputEvent) -> void:
	if tl_camera == null:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_sim_camera_look_dragging = mb.pressed
			if not mb.pressed:
				_update_camera_status_label()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			tl_camera.fov = clampf(tl_camera.fov - sim_camera_fov_step, sim_camera_min_fov, sim_camera_max_fov)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			tl_camera.fov = clampf(tl_camera.fov + sim_camera_fov_step, sim_camera_min_fov, sim_camera_max_fov)
		return

	if event is InputEventMouseMotion and _sim_camera_look_dragging:
		var motion := event as InputEventMouseMotion
		_sim_camera_yaw -= motion.relative.x * sim_camera_look_sensitivity * 0.01
		_sim_camera_pitch = clampf(_sim_camera_pitch - motion.relative.y * sim_camera_look_sensitivity * 0.01, deg_to_rad(-89.0), deg_to_rad(89.0))
		_apply_sim_camera_rotation()
		return

	if event is InputEventKey:
		var key_event := event as InputEventKey
		if key_event.pressed and not key_event.echo and (key_event.keycode == KEY_ESCAPE or key_event.physical_keycode == KEY_ESCAPE):
			_sim_camera_control_active = false
			_sim_camera_look_dragging = false
			_update_camera_status_label()


func _update_sim_camera_controls(delta: float) -> void:
	if not _sim_camera_control_active:
		return
	if tl_camera == null:
		return

	var forward_input: float = 0.0
	if Input.is_key_pressed(KEY_W):
		forward_input += 1.0
	if Input.is_key_pressed(KEY_S):
		forward_input -= 1.0

	var strafe_input: float = 0.0
	if Input.is_key_pressed(KEY_D):
		strafe_input += 1.0
	if Input.is_key_pressed(KEY_A):
		strafe_input -= 1.0

	var vertical_input: float = 0.0
	if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_E):
		vertical_input += 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_Q):
		vertical_input -= 1.0

	var move_dir: Vector3 = Vector3.ZERO
	var forward: Vector3 = -tl_camera.global_basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	var right: Vector3 = tl_camera.global_basis.x
	right.y = 0.0
	if right.length_squared() > 0.0001:
		right = right.normalized()

	move_dir += forward * forward_input
	move_dir += right * strafe_input
	move_dir += Vector3.UP * vertical_input
	if move_dir.length_squared() <= 0.0001:
		return

	move_dir = move_dir.normalized()
	var speed: float = sim_camera_move_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= sim_camera_fast_multiplier
	tl_camera.global_position += move_dir * speed * delta


func _should_consume_sim_camera_event(event: InputEvent) -> bool:
	if not visible:
		return false
	if event is InputEventMouseMotion:
		return _sim_camera_look_dragging
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		return mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN
	if event is InputEventKey:
		var key_event := event as InputEventKey
		var code: Key = key_event.physical_keycode if key_event.physical_keycode != 0 else key_event.keycode
		return code in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E, KEY_SPACE, KEY_CTRL, KEY_SHIFT, KEY_ESCAPE]
	return false


func _cache_sim_camera_angles() -> void:
	if tl_camera == null:
		return
	var basis: Basis = tl_camera.global_basis
	var forward: Vector3 = -basis.z.normalized()
	_sim_camera_yaw = atan2(forward.x, forward.z)
	_sim_camera_pitch = asin(clampf(forward.y, -1.0, 1.0))


func _apply_sim_camera_rotation() -> void:
	if tl_camera == null:
		return
	tl_camera.global_basis = Basis(Vector3.UP, _sim_camera_yaw) * Basis(Vector3.RIGHT, _sim_camera_pitch)


func _on_tl_viewport_gui_input(event: InputEvent) -> void:
	if not visible or calibration_mode_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_try_activate_sim_camera_from_click(event)
			get_viewport().set_input_as_handled()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _sim_camera_control_active:
			_sim_camera_look_dragging = false
			_update_camera_status_label()
			get_viewport().set_input_as_handled()
			return
		if _sim_camera_control_active and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			_handle_sim_camera_input(event)
			get_viewport().set_input_as_handled()
			return


func _update_webcam_status() -> void:
	_refresh_active_webcam_feed_name()
	_update_webcam_feed_label()

	if tr_camera_texture_rect != null and tr_camera_texture_rect.visible and tr_camera_texture_rect.texture != null:
		_set_label_text(tr_status_label, "Feed Status: Active (%s)" % _get_webcam_feed_display_name())
		_set_placeholder_hint(false)
		return

	if tr_video_stream_player != null and tr_video_stream_player.visible and tr_video_stream_player.stream != null:
		_set_label_text(tr_status_label, "Feed Status: Active (Video stream)")
		_set_placeholder_hint(false)
		return

	if _get_available_camera_feed_count() > 0:
		_set_label_text(tr_status_label, "Feed Status: Click LIVE panel or INPUT to choose camera")
	else:
		_set_label_text(tr_status_label, "Feed Status: No camera feeds detected")

	var show_placeholder := tr_video_stream_player == null or tr_video_stream_player.stream == null
	show_placeholder = show_placeholder and (tr_camera_texture_rect == null or tr_camera_texture_rect.texture == null or not tr_camera_texture_rect.visible)
	if tr_video_placeholder != null:
		tr_video_placeholder.visible = show_placeholder
	_set_placeholder_hint(show_placeholder)


func _set_placeholder_hint(show_hint: bool) -> void:
	if tr_placeholder_label == null:
		return
	tr_placeholder_label.visible = show_hint
	if show_hint:
		tr_placeholder_label.text = "Click to select camera input"


func _sync_subviewport_input() -> void:
	if source_preview == null:
		return
	var allow_subviewport_ui := visible and not warp_enabled and not calibration_mode_enabled
	source_preview.mouse_filter = Control.MOUSE_FILTER_STOP if allow_subviewport_ui else Control.MOUSE_FILTER_IGNORE


func _begin_webcam_feed_discovery() -> void:
	_webcam_feed_retry_remaining = WEBCAM_FEED_RETRY_COUNT
	_webcam_feed_retry_timer = 0.0
	_rescan_camera_feeds(false)


func _tick_webcam_feed_discovery(delta: float) -> void:
	if _webcam_feed_retry_remaining <= 0:
		return
	if _is_webcam_feed_active():
		_webcam_feed_retry_remaining = 0
		return
	if _get_available_camera_feed_count() > 0 and webcam_feed_id >= 0 and _apply_webcam_configuration():
		_webcam_feed_retry_remaining = 0
		return

	_webcam_feed_retry_timer -= delta
	if _webcam_feed_retry_timer > 0.0:
		return

	_webcam_feed_retry_timer = WEBCAM_FEED_RETRY_SECONDS
	_webcam_feed_retry_remaining -= 1
	_rescan_camera_feeds(true)


func _rescan_camera_feeds(force_recreate_extension: bool) -> void:
	if force_recreate_extension and CameraServerBootstrap != null:
		if _camera_texture != null:
			_camera_texture.camera_feed_id = -1
		CameraServerBootstrap.rescan_feeds()
	_on_camera_feeds_ready(false)


func _get_camera_extension_status() -> String:
	if CameraServerBootstrap == null:
		return "Camera bootstrap not available"
	return CameraServerBootstrap.last_status_message


func _initialize_camera_extension() -> void:
	if CameraServerBootstrap == null:
		return
	if not CameraServerBootstrap.feeds_rescan_completed.is_connected(_on_bootstrap_feeds_rescan_completed):
		CameraServerBootstrap.feeds_rescan_completed.connect(_on_bootstrap_feeds_rescan_completed)
	_begin_webcam_feed_discovery()


func _on_bootstrap_feeds_rescan_completed(_feed_count: int, _feed_names: PackedStringArray, _status_message: String) -> void:
	_on_camera_feeds_ready(false)


func _is_webcam_feed_active() -> bool:
	return webcam_use_camera_texture and webcam_feed_id >= 0 and tr_camera_texture_rect != null and tr_camera_texture_rect.visible and tr_camera_texture_rect.texture != null


func _on_ha_connection_status_changed(connected: bool) -> void:
	if connected:
		_set_label_text(br_connection_label, "Live Source: Home Assistant Connected")
	else:
		_set_label_text(br_connection_label, "Live Source: Home Assistant Disconnected")


func _on_ha_auth_status_changed(authenticated: bool) -> void:
	if authenticated:
		_set_label_text(br_connection_label, "Live Source: Home Assistant Authenticated")


func _subscribe_to_exported_entities() -> void:
	if _ha_client == null:
		return
	if not _ha_client.has_method("subscribe_to_entities"):
		return

	var dedupe: Dictionary = {}
	for entity_id in _collect_entities_to_subscribe():
		if entity_id != "":
			dedupe[entity_id] = true

	var entity_list: Array[String] = []
	for key in dedupe.keys():
		entity_list.append(key)
	if entity_list.is_empty():
		return

	_ha_client.subscribe_to_entities(entity_list)
	if request_initial_entity_states and _ha_client.has_method("get_entity_states"):
		_ha_client.get_entity_states(entity_list)


func _collect_entities_to_subscribe() -> Array[String]:
	var entities: Array[String] = [
		ha_battery_soc_entity,
		ha_load_entity,
		ha_solar_entity,
		ha_daily_solar_entity,
		ha_daily_load_entity,
		ha_solar_radiation_entity,
		ha_lux_entity,
		ha_rain_rate_entity,
		ha_rain_state_entity,
		ha_temperature_entity,
		ha_wind_speed_entity
	]
	for entity_id in device_entity_ids:
		entities.append(entity_id)
	return entities


func _on_ha_sensor_updated(entity_id: String, state: Dictionary) -> void:
	var state_value: String = str(state.get("state", "")).strip_edges()
	if state_value in ["", "unknown", "unavailable"]:
		return

	if entity_id == ha_battery_soc_entity and ha_battery_soc_entity != "":
		_actual_battery_soc = clampf(_parse_state_to_float(state_value), 0.0, 100.0)
		_set_metric_target("actual_battery_soc", _actual_battery_soc)
		return

	if entity_id == ha_solar_entity and ha_solar_entity != "":
		var solar_raw := _parse_state_to_float(state_value)
		_actual_current_solar_watts = solar_raw if ha_values_in_watts else solar_raw * 1000.0
		_set_metric_target("actual_current_solar_watts", _actual_current_solar_watts)
		_set_metric_target("actual_net_watts", _actual_current_solar_watts - _actual_current_load_watts)
		return

	if entity_id == ha_load_entity and ha_load_entity != "":
		var load_raw := _parse_state_to_float(state_value)
		_actual_current_load_watts = load_raw if ha_values_in_watts else load_raw * 1000.0
		_set_metric_target("actual_current_load_watts", _actual_current_load_watts)
		_set_metric_target("actual_net_watts", _actual_current_solar_watts - _actual_current_load_watts)
		return

	if entity_id == ha_daily_solar_entity and ha_daily_solar_entity != "":
		_actual_daily_solar_kwh = _parse_state_to_float(state_value)
		_set_metric_target("actual_solar_today_kwh", _actual_daily_solar_kwh)
		return

	if entity_id == ha_daily_load_entity and ha_daily_load_entity != "":
		_actual_daily_load_kwh = _parse_state_to_float(state_value)
		_set_metric_target("actual_load_today_kwh", _actual_daily_load_kwh)
		return

	if entity_id == ha_temperature_entity and ha_temperature_entity != "":
		var temp_c := _parse_state_to_float(state_value)
		if not ha_temp_in_celsius:
			temp_c = (temp_c - 32.0) * 5.0 / 9.0
		_set_label_text(br_weather_temp_value, "%.1f C" % temp_c)
		return

	if entity_id == ha_wind_speed_entity and ha_wind_speed_entity != "":
		var wind_ms := _parse_state_to_float(state_value)
		if not ha_wind_in_ms:
			wind_ms = wind_ms * 0.44704
		_set_label_text(br_weather_wind_value, "%.1f m/s" % wind_ms)
		return

	if entity_id == ha_rain_state_entity and ha_rain_state_entity != "":
		var lower := state_value.to_lower()
		var raining := lower in ["on", "true", "1", "raining", "yes", "rain"]
		if not raining and _parse_state_to_float(state_value) > 0.0:
			raining = true
		_actual_weather_state = "Rainy" if raining else "Clear"
		_set_label_text(br_weather_state_value, _actual_weather_state)
		return

	if entity_id == ha_solar_radiation_entity and ha_solar_radiation_entity != "" and _actual_weather_state == "Unknown":
		var radiation := maxf(_parse_state_to_float(state_value), 0.0)
		if radiation > 450.0:
			_actual_weather_state = "Sunny"
		elif radiation > 180.0:
			_actual_weather_state = "Partly Cloudy"
		else:
			_actual_weather_state = "Cloudy"
		_set_label_text(br_weather_state_value, _actual_weather_state)
		return

	for i in range(min(device_entity_ids.size(), actual_device_power_labels.size())):
		if entity_id == device_entity_ids[i] and device_entity_ids[i] != "":
			_update_device_row(actual_device_power_labels, actual_device_meter_bars, i, _parse_state_to_float(state_value))
			return


func _update_device_row(power_labels: Array[Label], meter_bars: Array[ProgressBar], index: int, watts: float) -> void:
	if power_labels.is_empty() or meter_bars.is_empty():
		return
	var clamped_index := clampi(index, 0, power_labels.size() - 1)
	var safe_watts := maxf(watts, 0.0)
	if power_labels[clamped_index] != null:
		power_labels[clamped_index].text = "%d W" % int(round(safe_watts))
	if meter_bars[clamped_index] != null:
		meter_bars[clamped_index].value = safe_watts


# ==================== OBSERVED-VS-SIMULATED COMPARE ====================

## Enter/exit split-screen compare mode. SolarUI calls feed_comparison() each
## frame while active. Entering shows the canvas; exiting restores live mirroring.
func set_compare_mode(active: bool) -> void:
	_compare_active = active
	if active:
		visible = true
		_set_label_text(bl_connection_label, "Simulation Source: Batch render")
		_set_label_text(br_connection_label, "Observed Source: Imported datastream")
	else:
		_set_label_text(br_connection_label, "")


## Push one synced comparison frame. SolarUI samples both series at the playhead
## (instantaneous scalars + daily totals) and across the visible window (the 96-
## point history arrays); this stores them into the BL(sim)/BR(observed) panels.
## payload keys: sim_soc_pct, sim_solar_w, sim_load_w, sim_solar_kwh, sim_load_kwh,
## obs_soc_pct, obs_solar_w, obs_load_w, obs_solar_kwh, obs_load_kwh,
## sim_solar_hist, sim_load_hist, obs_solar_hist, obs_load_hist (PackedFloat32Array).
func feed_comparison(payload: Dictionary) -> void:
	if not _compare_active:
		return
	# Instantaneous panel values.
	simulated_battery_soc       = clampf(float(payload.get("sim_soc_pct", simulated_battery_soc)), 0.0, 100.0)
	simulated_current_solar_watts = maxf(float(payload.get("sim_solar_w", 0.0)), 0.0)
	simulated_current_load_watts  = maxf(float(payload.get("sim_load_w", 0.0)), 0.0)
	simulated_solar_today_kwh   = maxf(float(payload.get("sim_solar_kwh", 0.0)), 0.0)
	simulated_load_today_kwh    = maxf(float(payload.get("sim_load_kwh", 0.0)), 0.0)
	_actual_battery_soc         = clampf(float(payload.get("obs_soc_pct", _actual_battery_soc)), 0.0, 100.0)
	_actual_current_solar_watts = maxf(float(payload.get("obs_solar_w", 0.0)), 0.0)
	_actual_current_load_watts  = maxf(float(payload.get("obs_load_w", 0.0)), 0.0)
	_actual_daily_solar_kwh     = maxf(float(payload.get("obs_solar_kwh", 0.0)), 0.0)
	_actual_daily_load_kwh      = maxf(float(payload.get("obs_load_kwh", 0.0)), 0.0)

	# History arrays (already resampled across the window by SolarUI).
	if payload.has("sim_solar_hist"):
		_sim_solar_history = payload["sim_solar_hist"]
	if payload.has("sim_load_hist"):
		_sim_load_history = payload["sim_load_hist"]
	if payload.has("obs_solar_hist"):
		_actual_solar_history = payload["obs_solar_hist"]
	if payload.has("obs_load_hist"):
		_actual_load_history = payload["obs_load_hist"]

	# Drive the metric animators (BL sim + BR observed).
	_set_metric_target("sim_battery_soc", simulated_battery_soc)
	_set_metric_target("sim_solar_today_kwh", simulated_solar_today_kwh)
	_set_metric_target("sim_load_today_kwh", simulated_load_today_kwh)
	_set_metric_target("sim_current_solar_watts", simulated_current_solar_watts)
	_set_metric_target("sim_current_load_watts", simulated_current_load_watts)
	_set_metric_target("sim_net_watts", simulated_current_solar_watts - simulated_current_load_watts)
	_set_metric_target("actual_battery_soc", _actual_battery_soc)
	_set_metric_target("actual_solar_today_kwh", _actual_daily_solar_kwh)
	_set_metric_target("actual_load_today_kwh", _actual_daily_load_kwh)
	_set_metric_target("actual_current_solar_watts", _actual_current_solar_watts)
	_set_metric_target("actual_current_load_watts", _actual_current_load_watts)
	_set_metric_target("actual_net_watts", _actual_current_solar_watts - _actual_current_load_watts)
	_refresh_delta_indicators()
	_update_graph_lines()


func _sync_from_solar_ui_fallback() -> void:
	if _compare_active:
		return   # compare mode drives the panels from the playhead instead
	_refresh_simulated_panel()
	if not mirror_from_solar_ui_when_available:
		return
	if _solar_ui == null or not _solar_ui.visible:
		return

	if _solar_daily_label != null:
		simulated_solar_today_kwh = _parse_state_to_float(_solar_daily_label.text)
	if _solar_power_label != null:
		simulated_current_solar_watts = _parse_state_to_float(_solar_power_label.text)
	if _solar_load_label != null:
		simulated_current_load_watts = _parse_state_to_float(_solar_load_label.text)
	if _solar_battery_percent_label != null:
		simulated_battery_soc = clampf(_parse_state_to_float(_solar_battery_percent_label.text), 0.0, 100.0)
	_refresh_simulated_panel()


func _apply_device_editor_defaults() -> void:
	for i in range(actual_device_name_labels.size()):
		var default_name := "Device %02d" % (i + 1)
		if i < device_names.size() and device_names[i].strip_edges() != "":
			default_name = device_names[i]
		_set_label_text(actual_device_name_labels[i], default_name)
		_set_label_text(sim_device_name_labels[i], default_name)

		if i < device_max_watts.size():
			if actual_device_meter_bars[i] != null:
				actual_device_meter_bars[i].max_value = maxf(device_max_watts[i], 1.0)
			if sim_device_meter_bars[i] != null:
				sim_device_meter_bars[i].max_value = maxf(device_max_watts[i], 1.0)

	for i in range(min(simulated_device_watts.size(), sim_device_power_labels.size())):
		_update_device_row(sim_device_power_labels, sim_device_meter_bars, i, simulated_device_watts[i])

	_refresh_simulated_panel()
	_set_metric_target("actual_battery_soc", _actual_battery_soc)
	_set_metric_target("actual_solar_today_kwh", _actual_daily_solar_kwh)
	_set_metric_target("actual_load_today_kwh", _actual_daily_load_kwh)
	_set_metric_target("actual_current_load_watts", _actual_current_load_watts)
	_set_metric_target("actual_current_solar_watts", _actual_current_solar_watts)
	_set_metric_target("actual_net_watts", _actual_current_solar_watts - _actual_current_load_watts)
	_set_label_text(br_weather_state_value, _actual_weather_state)


func _refresh_simulated_panel() -> void:
	_set_label_text(bl_connection_label, "Simulation Source: Internal scenario model")
	_set_metric_target("sim_battery_soc", clampf(simulated_battery_soc, 0.0, 100.0))
	_set_metric_target("sim_solar_today_kwh", maxf(simulated_solar_today_kwh, 0.0))
	_set_metric_target("sim_load_today_kwh", maxf(simulated_load_today_kwh, 0.0))
	_set_metric_target("sim_current_load_watts", maxf(simulated_current_load_watts, 0.0))
	_set_metric_target("sim_current_solar_watts", maxf(simulated_current_solar_watts, 0.0))
	_set_metric_target("sim_net_watts", maxf(simulated_current_solar_watts, 0.0) - maxf(simulated_current_load_watts, 0.0))
	_set_label_text(bl_weather_state_value, simulated_weather_state)
	_set_label_text(bl_weather_temp_value, "%.1f C" % simulated_weather_temp_c)
	_set_label_text(bl_weather_wind_value, "%.1f m/s" % simulated_weather_wind_ms)
	_refresh_delta_indicators()
	_apply_accent_theme()


func _initialize_graph_history() -> void:
	_sim_solar_history.resize(GRAPH_SAMPLE_COUNT)
	_sim_load_history.resize(GRAPH_SAMPLE_COUNT)
	_actual_solar_history.resize(GRAPH_SAMPLE_COUNT)
	_actual_load_history.resize(GRAPH_SAMPLE_COUNT)

	for i in range(GRAPH_SAMPLE_COUNT):
		var t := float(i) / float(GRAPH_SAMPLE_COUNT - 1)
		var day_curve := maxf(0.0, sin(t * PI))
		_sim_solar_history[i] = day_curve * maxf(simulated_current_solar_watts * 1.2, 1000.0)
		_sim_load_history[i] = (0.45 + 0.2 * sin(t * TAU * 2.0 + 1.2)) * maxf(simulated_current_load_watts * 1.1, 900.0)
		_actual_solar_history[i] = _sim_solar_history[i] * 0.92
		_actual_load_history[i] = _sim_load_history[i] * 1.06

	_update_graph_lines()


func _tick_graph_history(delta: float) -> void:
	if _compare_active:
		return   # histories are filled by feed_comparison() from the series
	_graph_sample_timer += delta
	if _graph_sample_timer < GRAPH_SAMPLE_INTERVAL_SECONDS:
		return
	_graph_sample_timer = 0.0

	_append_history_point(_sim_solar_history, maxf(simulated_current_solar_watts, 0.0))
	_append_history_point(_sim_load_history, maxf(simulated_current_load_watts, 0.0))
	_append_history_point(_actual_solar_history, maxf(_actual_current_solar_watts, 0.0))
	_append_history_point(_actual_load_history, maxf(_actual_current_load_watts, 0.0))
	_update_graph_lines()


func _append_history_point(history: PackedFloat32Array, value: float) -> void:
	if history.size() <= 1:
		return
	for i in range(history.size() - 1):
		history[i] = history[i + 1]
	history[history.size() - 1] = value


func _update_graph_lines() -> void:
	_apply_graph_points(bl_graph_host, bl_graph_solar_line, bl_graph_load_line, _sim_solar_history, _sim_load_history)
	_apply_graph_points(br_graph_host, br_graph_solar_line, br_graph_load_line, _actual_solar_history, _actual_load_history)


func _apply_graph_points(host: Control, solar_line: Line2D, load_line: Line2D, solar_history: PackedFloat32Array, load_history: PackedFloat32Array) -> void:
	if host == null or solar_line == null or load_line == null:
		return
	if host.size.x < 4.0 or host.size.y < 4.0:
		return
	if solar_history.size() < 2 or load_history.size() < 2:
		return

	var max_val := 1.0
	for i in range(solar_history.size()):
		max_val = maxf(max_val, solar_history[i])
		max_val = maxf(max_val, load_history[i])

	var usable_height := host.size.y - 24.0
	var width := host.size.x
	var solar_points := PackedVector2Array()
	var load_points := PackedVector2Array()
	for i in range(solar_history.size()):
		var x := float(i) / float(solar_history.size() - 1) * width
		var sy := usable_height - (solar_history[i] / max_val) * usable_height
		var ly := usable_height - (load_history[i] / max_val) * usable_height
		solar_points.append(Vector2(x, sy))
		load_points.append(Vector2(x, ly))

	solar_line.points = solar_points
	load_line.points = load_points


func _apply_layout_polish() -> void:
	_style_quadrant_shells()
	_style_top_viewports()
	for stat_panel in sim_stat_panels:
		_style_stat_panel(stat_panel, false)
	for stat_panel in live_stat_panels:
		_style_stat_panel(stat_panel, true)
	_style_weather_section(bl_weather_panel, bl_weather_grid, false)
	_style_weather_section(br_weather_panel, br_weather_grid, true)
	_style_devices_section(bl_devices_panel, bl_device_rows, bl_devices_header, false)
	_style_devices_section(br_devices_panel, br_device_rows, br_devices_header, true)
	_style_graph_section(bl_graph_panel, bl_graph_host, false)
	_style_graph_section(br_graph_panel, br_graph_host, true)


func _style_quadrant_shells() -> void:
	if tl_panel != null:
		tl_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(false, 0.94))
	if tr_panel != null:
		tr_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(true, 0.94))
	if bl_panel != null:
		bl_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(false, 0.94))
	if br_panel != null:
		br_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(true, 0.94))


func _style_top_viewports() -> void:
	if tl_margin != null:
		tl_margin.add_theme_constant_override("margin_left", 8)
		tl_margin.add_theme_constant_override("margin_top", 8)
		tl_margin.add_theme_constant_override("margin_right", 8)
		tl_margin.add_theme_constant_override("margin_bottom", 8)
	if tr_margin != null:
		tr_margin.add_theme_constant_override("margin_left", 8)
		tr_margin.add_theme_constant_override("margin_top", 8)
		tr_margin.add_theme_constant_override("margin_right", 8)
		tr_margin.add_theme_constant_override("margin_bottom", 8)
	if tl_vbox != null:
		tl_vbox.add_theme_constant_override("separation", 4)
	if tr_vbox != null:
		tr_vbox.add_theme_constant_override("separation", 4)

	if tl_title_label != null:
		tl_title_label.add_theme_font_size_override("font_size", 20)
		tl_title_label.add_theme_color_override("font_color", Color(0.40, 0.80, 1.0, 1.0))
	if tr_title_label != null:
		tr_title_label.add_theme_font_size_override("font_size", 20)
		tr_title_label.add_theme_color_override("font_color", Color(0.50, 0.65, 0.8, 1.0))
	if tr_feed_name_label != null:
		tr_feed_name_label.add_theme_font_size_override("font_size", 11)
		tr_feed_name_label.add_theme_color_override("font_color", Color(0.55, 0.72, 0.88, 0.92))
	for btn in [tr_select_feed_button, tr_load_video_button]:
		if btn == null:
			continue
		btn.add_theme_font_size_override("font_size", 12)
		btn.add_theme_color_override("font_color", Color(0.82, 0.93, 1.0, 1.0))
		btn.add_theme_color_override("font_hover_color", Color(1.0, 1.0, 1.0, 1.0))
		btn.add_theme_stylebox_override("normal", _make_hud_panel_style(true, 0.98))
		btn.add_theme_stylebox_override("hover", _make_hud_panel_style(true, 1.0))
		btn.add_theme_stylebox_override("pressed", _make_hud_panel_style(true, 0.9))
	if tr_placeholder_label != null:
		tr_placeholder_label.add_theme_font_size_override("font_size", 14)
		tr_placeholder_label.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95, 0.95))

	if tl_viewport_panel != null:
		tl_viewport_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(false, 0.98))
	if tr_video_panel != null:
		tr_video_panel.add_theme_stylebox_override("panel", _make_hud_panel_style(true, 0.98))

	if tr_video_host != null:
		tr_video_host.clip_contents = true
	if tr_camera_texture_rect != null:
		tr_camera_texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr_camera_texture_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	if tr_video_stream_player != null:
		tr_video_stream_player.expand = true
	if tl_viewport_container != null:
		tl_viewport_container.stretch = true


func _style_stat_panel(panel: Panel, is_live_panel: bool) -> void:
	if panel == null:
		return
	panel.custom_minimum_size = Vector2(220.0, 112.0)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	panel.clip_contents = true

	var content_vbox: VBoxContainer = panel.get_child(0) as VBoxContainer
	if content_vbox != null:
		content_vbox.anchor_left = 0.0
		content_vbox.anchor_top = 0.0
		content_vbox.anchor_right = 1.0
		content_vbox.anchor_bottom = 1.0
		content_vbox.offset_left = 10.0
		content_vbox.offset_top = 8.0
		content_vbox.offset_right = -10.0
		content_vbox.offset_bottom = -8.0
		content_vbox.grow_horizontal = 2
		content_vbox.grow_vertical = 2
		content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content_vbox.add_theme_constant_override("separation", 4)
		var label_idx := 0
		for child in content_vbox.get_children():
			var label := child as Label
			if label == null:
				continue
			label.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			label.custom_minimum_size = Vector2(0.0, 18.0)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			if label.name.ends_with("Value"):
				label.add_theme_font_size_override("font_size", 22)
				label.custom_minimum_size = Vector2(0.0, 34.0)
			elif label.name.ends_with("Delta"):
				label.add_theme_font_size_override("font_size", 11)
				label.custom_minimum_size = Vector2(0.0, 14.0)
			else:
				label.add_theme_font_size_override("font_size", 12)
			label_idx += 1
		if label_idx == 2:
			var value_only_label := content_vbox.get_child(1) as Label
			if value_only_label != null:
				value_only_label.custom_minimum_size = Vector2(0.0, 54.0)

	var tint := Color(0.09, 0.16, 0.24, 1.0) if not is_live_panel else Color(0.12, 0.14, 0.24, 1.0)
	panel.add_theme_color_override("font_color", Color(0.86, 0.93, 1.0, 1.0))
	panel.self_modulate = tint
	panel.add_theme_stylebox_override("panel", _make_hud_panel_style(is_live_panel, 0.92))


func _style_weather_section(panel: Panel, grid: GridContainer, is_live_panel: bool) -> void:
	if panel == null or grid == null:
		return
	panel.custom_minimum_size = Vector2(0.0, 110.0)
	panel.add_theme_stylebox_override("panel", _make_hud_panel_style(is_live_panel, 0.88))
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 8)
	for child in grid.get_children():
		var label := child as Label
		if label == null:
			continue
		label.custom_minimum_size = Vector2(90, 0)
		if label.name.ends_with("Value"):
			label.add_theme_font_size_override("font_size", 18)
			label.add_theme_color_override("font_color", Color(0.72, 0.93, 1.0, 1.0) if not is_live_panel else Color(1.0, 0.82, 0.48, 1.0))
		else:
			label.add_theme_font_size_override("font_size", 11)
			label.add_theme_color_override("font_color", Color(0.54, 0.66, 0.78, 1.0))


func _style_devices_section(panel: Panel, rows: VBoxContainer, header: Label, is_live_panel: bool) -> void:
	if panel == null or rows == null:
		return
	panel.custom_minimum_size = Vector2(0.0, 248.0)
	panel.add_theme_stylebox_override("panel", _make_hud_panel_style(is_live_panel, 0.9))
	if header != null:
		header.add_theme_font_size_override("font_size", 13)
		header.add_theme_color_override("font_color", Color(0.63, 0.88, 1.0, 1.0) if not is_live_panel else Color(1.0, 0.80, 0.43, 1.0))
	rows.add_theme_constant_override("separation", 7)
	for row_node in rows.get_children():
		var row := row_node as HBoxContainer
		if row == null:
			continue
		row.add_theme_constant_override("separation", 10)
		row.custom_minimum_size = Vector2(0.0, 24.0)
		for child in row.get_children():
			if child is Label:
				var label := child as Label
				if label.name.ends_with("Name"):
					label.add_theme_font_size_override("font_size", 12)
					label.add_theme_color_override("font_color", Color(0.74, 0.82, 0.9, 1.0))
				else:
					label.add_theme_font_size_override("font_size", 12)
					label.add_theme_color_override("font_color", Color(0.78, 0.96, 1.0, 1.0) if not is_live_panel else Color(1.0, 0.84, 0.55, 1.0))
			elif child is ProgressBar:
				var bar := child as ProgressBar
				bar.custom_minimum_size = Vector2(0.0, 8.0)
				bar.add_theme_stylebox_override("background", _make_meter_background_style())
				bar.add_theme_stylebox_override("fill", _make_meter_fill_style(is_live_panel))


func _style_graph_section(panel: Panel, host: Control, is_live_panel: bool) -> void:
	if panel == null or host == null:
		return
	panel.add_theme_stylebox_override("panel", _make_hud_panel_style(is_live_panel, 0.9))
	host.clip_contents = true


func _make_hud_panel_style(is_live_panel: bool, alpha: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.10, 0.14, alpha) if not is_live_panel else Color(0.09, 0.09, 0.16, alpha)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.border_color = Color(0.20, 0.40, 0.60, 0.8) if not is_live_panel else Color(0.38, 0.43, 0.70, 0.85)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_right = 8
	style.corner_radius_bottom_left = 8
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.32)
	style.shadow_size = 5
	return style


func _make_meter_background_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.08, 0.12, 1.0)
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_right = 2
	style.corner_radius_bottom_left = 2
	return style


func _make_meter_fill_style(is_live_panel: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.30, 0.86, 1.0, 0.95) if not is_live_panel else Color(1.0, 0.72, 0.30, 0.95)
	style.corner_radius_top_left = 2
	style.corner_radius_top_right = 2
	style.corner_radius_bottom_right = 2
	style.corner_radius_bottom_left = 2
	return style


func _initialize_metric_animation() -> void:
	_metric_labels = {
		"sim_battery_soc": bl_battery_value,
		"sim_solar_today_kwh": bl_solar_today_value,
		"sim_load_today_kwh": bl_load_today_value,
		"sim_current_load_watts": bl_current_load_value,
		"sim_current_solar_watts": bl_current_solar_value,
		"sim_net_watts": bl_net_value,
		"actual_battery_soc": br_battery_value,
		"actual_solar_today_kwh": br_solar_today_value,
		"actual_load_today_kwh": br_load_today_value,
		"actual_current_load_watts": br_current_load_value,
		"actual_current_solar_watts": br_current_solar_value,
		"actual_net_watts": br_net_value
	}

	for key in _metric_labels.keys():
		_metric_targets[key] = 0.0
		_metric_displayed[key] = 0.0

	_refresh_simulated_panel()


func _set_metric_target(metric_key: String, value: float) -> void:
	if not _metric_targets.has(metric_key):
		return
	_metric_targets[metric_key] = value


func _animate_metric_values(delta: float) -> void:
	if _metric_targets.is_empty():
		return

	for key in _metric_targets.keys():
		var target: float = float(_metric_targets[key])
		var displayed: float = float(_metric_displayed.get(key, target))
		var next_value: float = lerpf(displayed, target, clampf(delta * value_animation_speed, 0.0, 1.0))
		if absf(next_value - target) < 0.005:
			next_value = target
		_metric_displayed[key] = next_value
		var label: Label = _metric_labels.get(key, null) as Label
		_set_label_text(label, _format_metric_value(key, next_value))

	_refresh_delta_indicators()
	_apply_accent_theme()


func _format_metric_value(metric_key: String, value: float) -> String:
	if metric_key.ends_with("battery_soc"):
		return "%.1f %%" % value
	if metric_key.ends_with("today_kwh"):
		return "%.2f kWh" % value
	return "%d W" % int(round(value))


func _refresh_delta_indicators() -> void:
	_set_delta_label(br_battery_delta, _metric_displayed.get("actual_battery_soc", 0.0) - _metric_displayed.get("sim_battery_soc", 0.0), "%%")
	_set_delta_label(br_solar_today_delta, _metric_displayed.get("actual_solar_today_kwh", 0.0) - _metric_displayed.get("sim_solar_today_kwh", 0.0), "kWh")
	_set_delta_label(br_load_today_delta, _metric_displayed.get("actual_load_today_kwh", 0.0) - _metric_displayed.get("sim_load_today_kwh", 0.0), "kWh")
	_set_delta_label(br_current_load_delta, _metric_displayed.get("actual_current_load_watts", 0.0) - _metric_displayed.get("sim_current_load_watts", 0.0), "W")
	_set_delta_label(br_current_solar_delta, _metric_displayed.get("actual_current_solar_watts", 0.0) - _metric_displayed.get("sim_current_solar_watts", 0.0), "W")
	_set_delta_label(br_net_delta, _metric_displayed.get("actual_net_watts", 0.0) - _metric_displayed.get("sim_net_watts", 0.0), "W")


func _set_delta_label(label: Label, delta_value: float, unit: String) -> void:
	if label == null:
		return
	var sign_prefix := "+" if delta_value >= 0.0 else "-"
	var magnitude := absf(delta_value)
	var value_text := ""
	if unit == "%%":
		value_text = "%s%.1f %%" % [sign_prefix, magnitude]
	elif unit == "kWh":
		value_text = "%s%.2f kWh" % [sign_prefix, magnitude]
	else:
		value_text = "%s%d %s" % [sign_prefix, int(round(magnitude)), unit]
	label.text = "DELTA %s" % value_text
	if delta_value > 0.0:
		label.add_theme_color_override("font_color", Color(0.50, 1.0, 0.65, 1.0))
	elif delta_value < 0.0:
		label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.45, 1.0))
	else:
		label.add_theme_color_override("font_color", Color(0.75, 0.85, 0.95, 1.0))


func _apply_accent_theme() -> void:
	var accent: Color = Color(0.30, 0.95, 1.0, 1.0)
	var glow: Color = Color(0.16, 0.32, 0.45, 1.0)

	match accent_theme_mode:
		AccentThemeMode.NEON_AMBER:
			accent = Color(1.0, 0.70, 0.26, 1.0)
			glow = Color(0.45, 0.28, 0.12, 1.0)
		AccentThemeMode.NEON_CRIMSON:
			accent = Color(1.0, 0.30, 0.35, 1.0)
			glow = Color(0.40, 0.10, 0.16, 1.0)
		AccentThemeMode.NEON_AUTO_ALERT:
			if _actual_battery_soc < low_battery_alert_threshold:
				accent = Color(1.0, 0.30, 0.35, 1.0)
				glow = Color(0.40, 0.10, 0.16, 1.0)
			elif _actual_current_load_watts > high_load_alert_watts:
				accent = Color(1.0, 0.70, 0.26, 1.0)
				glow = Color(0.45, 0.28, 0.12, 1.0)

	for label in [
		bl_battery_value, bl_solar_today_value, bl_load_today_value, bl_current_load_value, bl_current_solar_value,
		br_battery_value, br_solar_today_value, br_load_today_value, br_current_load_value, br_current_solar_value
	]:
		if label != null:
			(label as Label).add_theme_color_override("font_color", accent)
	for label in [bl_connection_label, br_connection_label, bl_weather_state_value, br_weather_state_value]:
		if label != null:
			(label as Label).add_theme_color_override("font_color", glow)


func _connect_webcam_ui_signals() -> void:
	if tr_video_placeholder != null and not tr_video_placeholder.gui_input.is_connected(_on_tr_video_placeholder_gui_input):
		tr_video_placeholder.gui_input.connect(_on_tr_video_placeholder_gui_input)
	if tr_select_feed_button != null and not tr_select_feed_button.pressed.is_connected(_on_tr_select_feed_button_pressed):
		tr_select_feed_button.pressed.connect(_on_tr_select_feed_button_pressed)
	if tr_load_video_button != null and not tr_load_video_button.pressed.is_connected(_on_tr_load_video_button_pressed):
		tr_load_video_button.pressed.connect(_on_tr_load_video_button_pressed)
	if video_file_dialog != null and not video_file_dialog.file_selected.is_connected(_on_video_file_selected):
		video_file_dialog.file_selected.connect(_on_video_file_selected)
	if dialog_refresh_button != null and not dialog_refresh_button.pressed.is_connected(_on_dialog_refresh_button_pressed):
		dialog_refresh_button.pressed.connect(_on_dialog_refresh_button_pressed)
	if dialog_cancel_button != null and not dialog_cancel_button.pressed.is_connected(_on_webcam_cancel_button_pressed):
		dialog_cancel_button.pressed.connect(_on_webcam_cancel_button_pressed)
	if dialog_apply_button != null and not dialog_apply_button.pressed.is_connected(_on_webcam_apply_button_pressed):
		dialog_apply_button.pressed.connect(_on_webcam_apply_button_pressed)
	if webcam_setup_dialog != null and not webcam_setup_dialog.close_requested.is_connected(_on_webcam_close_requested):
		webcam_setup_dialog.close_requested.connect(_on_webcam_close_requested)


func _try_open_webcam_setup_from_click(event: InputEvent) -> void:
	if event is not InputEventMouseButton:
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if tr_video_host == null:
		return
	if not tr_video_host.get_global_rect().has_point(mb.global_position):
		return
	_open_webcam_setup_dialog()


func _on_tr_select_feed_button_pressed() -> void:
	_open_webcam_setup_dialog()


func _on_tr_load_video_button_pressed() -> void:
	if video_file_dialog == null:
		return
	video_file_dialog.popup_centered()


func _on_video_file_selected(path: String) -> void:
	_load_video_file(path)


func _load_video_file(path: String) -> void:
	if tr_video_stream_player == null:
		return

	var stream: VideoStream = _make_video_stream(path)
	if stream == null:
		push_warning("ProjectionCanvas: Could not create video stream for: %s" % path)
		_set_label_text(tr_feed_name_label, "Error: unsupported video format")
		return

	_active_video_file_path = path

	# Lock TR panel to the selected video input.
	_webcam_user_disabled_auto = true
	webcam_use_camera_texture = false
	webcam_feed_id = -1
	if _camera_texture != null:
		_camera_texture.camera_feed_id = -1
	if tr_camera_texture_rect != null:
		tr_camera_texture_rect.visible = false

	tr_video_stream_player.stream = stream
	tr_video_stream_player.loop = true
	tr_video_stream_player.visible = true
	tr_video_stream_player.play()
	_video_seek_accum = 0.0

	# Snap start anchor to current playhead so the NLE clip is immediately visible.
	if _video_sync_main == null:
		_video_sync_main = _find_sim_main()
	if _video_sync_main != null and _video_sync_main.has_method("get_absolute_hours"):
		video_start_abs_hours = float(_video_sync_main.call("get_absolute_hours"))
	else:
		video_start_abs_hours = NAN
	# Cache duration after play() so the stream length is available.
	call_deferred("_cache_video_duration_and_notify")

	_apply_video_sync_speed()
	_seek_video_to_sim_time()
	_apply_webcam_configuration()

	if tr_video_placeholder != null:
		tr_video_placeholder.visible = false

	var filename := path.get_file()
	_set_label_text(tr_feed_name_label, filename)
	_set_label_text(tr_status_label, "Feed Status: Video file — %s (looping)" % filename)

	_save_webcam_config()


func _make_video_stream(path: String) -> VideoStream:
	var ext := path.get_extension().to_lower()
	if ext in ["ogv", "ogg"]:
		var s := VideoStreamTheora.new()
		s.file = path
		return s
	if ClassDB.class_exists("FFmpegVideoStream"):
		var s = ClassDB.instantiate("FFmpegVideoStream")
		if s != null:
			s.file = path
			return s as VideoStream
	var fallback := load(path)
	if fallback is VideoStream:
		return fallback as VideoStream
	return null


func _on_dialog_refresh_button_pressed() -> void:
	_rescan_camera_feeds(true)


func _on_tr_video_placeholder_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_open_webcam_setup_dialog()
		get_viewport().set_input_as_handled()


func _open_webcam_setup_dialog() -> void:
	if webcam_setup_dialog == null:
		return
	_rescan_camera_feeds(true)
	webcam_setup_dialog.popup_centered()


func _on_camera_feeds_ready(refresh_dialog_only: bool) -> void:
	_refresh_available_camera_feeds()
	_validate_saved_webcam_feed_id()
	if not refresh_dialog_only:
		_try_apply_saved_or_default_feed()
	_update_webcam_feed_label()
	_update_webcam_status()


func _refresh_available_camera_feeds() -> void:
	if feed_option_button == null:
		return

	CameraServer.monitoring_feeds = true

	feed_option_button.clear()
	feed_option_button.add_item("None (leave unconfigured)")
	feed_option_button.set_item_metadata(0, -1)

	var feeds: Array = CameraServer.feeds()
	for feed in feeds:
		var feed_id: int = int(feed.get_id())
		var feed_name: String = _get_feed_display_name(feed)
		feed_option_button.add_item("%s (id %d)" % [feed_name, feed_id])
		feed_option_button.set_item_metadata(feed_option_button.item_count - 1, feed_id)
		if feed_id == webcam_feed_id:
			feed_option_button.select(feed_option_button.item_count - 1)

	if webcam_use_camera_texture_check != null:
		webcam_use_camera_texture_check.button_pressed = webcam_use_camera_texture
	if webcam_feed_id < 0:
		feed_option_button.select(0)


func _try_apply_saved_or_default_feed() -> bool:
	if webcam_feed_id >= 0 and _apply_webcam_configuration():
		return true

	if _webcam_user_disabled_auto or not prefer_obs_virtual_camera:
		return false

	var preferred_feed_id := _find_preferred_obs_feed_id()
	if preferred_feed_id < 0:
		return false

	webcam_feed_id = preferred_feed_id
	webcam_use_camera_texture = true
	if not _apply_webcam_configuration():
		return false

	_save_webcam_config()
	_refresh_available_camera_feeds()
	return true


func _validate_saved_webcam_feed_id() -> void:
	if webcam_feed_id >= 0 and _find_feed_by_id(webcam_feed_id) != null:
		return

	var restored_id := _find_feed_id_by_name(_saved_webcam_feed_name)
	if restored_id >= 0:
		webcam_feed_id = restored_id
		return

	webcam_feed_id = -1


func _find_preferred_obs_feed_id() -> int:
	var feeds: Array = CameraServer.feeds()
	for feed in feeds:
		var feed_name: String = str(feed.get_name()).to_lower()
		for pattern in obs_camera_name_patterns:
			if feed_name.contains(pattern.to_lower()):
				return int(feed.get_id())
	return -1


func _find_feed_by_id(feed_id: int):
	for feed in CameraServer.feeds():
		if int(feed.get_id()) == feed_id:
			return feed
	return null


func _find_feed_id_by_name(feed_name: String) -> int:
	var target := feed_name.strip_edges().to_lower()
	if target == "":
		return -1
	for feed in CameraServer.feeds():
		if _get_feed_display_name(feed).to_lower() == target:
			return int(feed.get_id())
	return -1


func _get_feed_display_name(feed) -> String:
	var feed_name: String = str(feed.get_name()).strip_edges()
	if feed_name == "":
		feed_name = "Camera Feed %d" % int(feed.get_id())
	return feed_name


func _get_available_camera_feed_count() -> int:
	return CameraServer.feeds().size()


func _get_webcam_feed_display_name() -> String:
	if _active_webcam_feed_name.strip_edges() != "":
		return _active_webcam_feed_name
	if webcam_feed_id >= 0:
		return "Camera Feed %d" % webcam_feed_id
	return "none"


func _refresh_active_webcam_feed_name() -> void:
	_active_webcam_feed_name = ""
	if webcam_feed_id < 0:
		return
	var feed = _find_feed_by_id(webcam_feed_id)
	if feed != null:
		_active_webcam_feed_name = _get_feed_display_name(feed)


func _update_webcam_feed_label() -> void:
	var display_name := _get_webcam_feed_display_name()
	if tr_feed_name_label != null:
		if _is_webcam_feed_active():
			tr_feed_name_label.text = display_name
		elif _get_available_camera_feed_count() > 0:
			tr_feed_name_label.text = "Click LIVE panel or INPUT to choose camera"
		else:
			tr_feed_name_label.text = _get_camera_extension_status()
	if dialog_current_feed_label != null:
		dialog_current_feed_label.text = "Current input: %s" % display_name
	if dialog_help_label != null:
		if _get_available_camera_feed_count() > 0:
			dialog_help_label.text = "%s\nSelect a feed above and click Apply Feed." % _get_camera_extension_status()
		else:
			dialog_help_label.text = "%s\nStart OBS Virtual Camera, then click Refresh Feed List." % _get_camera_extension_status()


func _on_webcam_cancel_button_pressed() -> void:
	webcam_setup_dialog.hide()


func _on_webcam_close_requested() -> void:
	webcam_setup_dialog.hide()


func _on_webcam_apply_button_pressed() -> void:
	if feed_option_button == null:
		return
	var selected_index := feed_option_button.selected
	var selected_feed_id := -1
	if selected_index >= 0:
		selected_feed_id = int(feed_option_button.get_item_metadata(selected_index))
	webcam_feed_id = selected_feed_id
	if webcam_use_camera_texture_check != null:
		webcam_use_camera_texture = webcam_use_camera_texture_check.button_pressed
	_webcam_user_disabled_auto = selected_feed_id < 0
	_apply_webcam_configuration()
	_save_webcam_config()
	_update_webcam_feed_label()
	_update_webcam_status()
	if webcam_setup_dialog != null:
		webcam_setup_dialog.hide()


func _apply_webcam_configuration() -> bool:
	var stream_assigned := tr_video_stream_player != null and tr_video_stream_player.stream != null
	var camera_feed_applied := false

	if webcam_use_camera_texture and webcam_feed_id >= 0:
		camera_feed_applied = _apply_camera_feed_texture(webcam_feed_id)

	if tr_camera_texture_rect != null:
		tr_camera_texture_rect.visible = camera_feed_applied
	if tr_video_stream_player != null:
		tr_video_stream_player.visible = (not camera_feed_applied) and stream_assigned
	if tr_video_placeholder != null:
		tr_video_placeholder.visible = (not camera_feed_applied) and (not stream_assigned)

	_refresh_active_webcam_feed_name()
	return camera_feed_applied


func _apply_camera_feed_texture(feed_id: int) -> bool:
	var feeds: Array = CameraServer.feeds()
	var found := false
	for feed in feeds:
		if feed.get_id() == feed_id:
			found = true
			feed.set_active(true)
			break

	if not found:
		return false

	if _camera_texture == null:
		_camera_texture = CameraTexture.new()
	_camera_texture.camera_feed_id = feed_id
	tr_camera_texture_rect.texture = _camera_texture
	return true


func _load_webcam_config() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(webcam_config_path) != OK:
		return
	webcam_feed_id = int(cfg.get_value("webcam", "feed_id", webcam_feed_id))
	webcam_use_camera_texture = bool(cfg.get_value("webcam", "use_camera_texture", webcam_use_camera_texture))
	_saved_webcam_feed_name = str(cfg.get_value("webcam", "feed_name", ""))
	_webcam_user_disabled_auto = bool(cfg.get_value("webcam", "user_disabled_auto", false))
	_active_video_file_path = str(cfg.get_value("webcam", "video_file_path", ""))

	if _active_video_file_path != "" and FileAccess.file_exists(_active_video_file_path):
		call_deferred("_load_video_file", _active_video_file_path)


func _save_webcam_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("webcam", "feed_id", webcam_feed_id)
	cfg.set_value("webcam", "feed_name", _active_webcam_feed_name)
	cfg.set_value("webcam", "use_camera_texture", webcam_use_camera_texture)
	cfg.set_value("webcam", "user_disabled_auto", _webcam_user_disabled_auto)
	cfg.set_value("webcam", "video_file_path", _active_video_file_path)
	cfg.save(webcam_config_path)


func _parse_state_to_float(raw_state: String) -> float:
	var trimmed := raw_state.strip_edges()
	if trimmed.is_valid_float():
		return trimmed.to_float()

	const numeric_chars := "0123456789.-"
	var cleaned := ""
	for c in trimmed:
		if numeric_chars.contains(c):
			cleaned += c

	if cleaned.is_valid_float():
		return cleaned.to_float()
	return 0.0


func _set_label_text(label: Label, value: String) -> void:
	if label != null:
		label.text = value


# ---------------------------------------------------------------------------
# Timelapse video <-> simulation sync
# ---------------------------------------------------------------------------

## Hide the per-panel scrubber/speed bars and header buttons from the TR panel.
## Controls are moved to the main NLE timeline row instead.
func _hide_tr_video_controls() -> void:
	var sync_bar := get_node_or_null(_TR_SYNC_BAR)
	if sync_bar != null:
		(sync_bar as Control).visible = false
	var speed_bar := get_node_or_null(_TR_SPEED_BAR)
	if speed_bar != null:
		(speed_bar as Control).visible = false
	if tr_select_feed_button != null:
		tr_select_feed_button.visible = false
	if tr_load_video_button != null:
		tr_load_video_button.visible = false


## Public — returns the absolute-hours [start, end] of the loaded video clip,
## or Vector2(NAN, NAN) when no video is loaded or no anchor is set.
func get_video_clip_range_abs() -> Vector2:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return Vector2(NAN, NAN)
	if is_nan(video_start_abs_hours) or _video_duration_sim_hours <= 0.0:
		return Vector2(NAN, NAN)
	return Vector2(video_start_abs_hours, video_start_abs_hours + _video_duration_sim_hours)


## Snap the video start anchor to an explicit absolute-hours value (e.g. the
## current playhead). The video track on the NLE timeline updates immediately.
func set_video_start_abs_hours(h: float) -> void:
	video_start_abs_hours = h
	video_clip_changed.emit()


## Open the file-picker to load a video into the TR panel (called from TimelineUI).
func open_load_video_dialog() -> void:
	if video_file_dialog != null:
		video_file_dialog.popup_centered()


## Open the live-feed setup dialog (called from TimelineUI).
func open_live_feed_dialog() -> void:
	_open_webcam_setup_dialog()


## Called deferred after video starts playing so the stream length is readable.
func _cache_video_duration_and_notify() -> void:
	var d := _get_video_duration_seconds()
	_video_duration_sim_hours = d * video_reference_time_scale
	video_clip_changed.emit()


func _find_sim_main() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene := tree.current_scene
	if scene != null and scene.has_method("get_lunar_phase"):
		return scene
	return null


func _find_timeline_ui() -> Node:
	if not timeline_ui_path.is_empty():
		var by_path := get_node_or_null(timeline_ui_path)
		if by_path != null:
			return by_path
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.find_child("TimelineUI", true, false)


func _connect_video_sync_signals() -> void:
	if tr_video_play_pause_btn != null and not tr_video_play_pause_btn.pressed.is_connected(_on_video_play_pause_pressed):
		tr_video_play_pause_btn.pressed.connect(_on_video_play_pause_pressed)
	if tr_video_scrubber != null and not tr_video_scrubber.value_changed.is_connected(_on_video_scrubber_changed):
		tr_video_scrubber.value_changed.connect(_on_video_scrubber_changed)
	if tr_video_slower_btn != null and not tr_video_slower_btn.pressed.is_connected(_on_video_slower_pressed):
		tr_video_slower_btn.pressed.connect(_on_video_slower_pressed)
	if tr_video_faster_btn != null and not tr_video_faster_btn.pressed.is_connected(_on_video_faster_pressed):
		tr_video_faster_btn.pressed.connect(_on_video_faster_pressed)
	if tr_video_sync_btn != null and not tr_video_sync_btn.pressed.is_connected(_on_video_sync_pressed):
		tr_video_sync_btn.pressed.connect(_on_video_sync_pressed)


func _update_video_sync(delta: float) -> void:
	if not video_sync_enabled:
		return
	if _video_sync_main == null or not is_instance_valid(_video_sync_main):
		_video_sync_main = _find_sim_main()
	if _video_sync_main == null:
		return

	var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else 0.0)
	var dt: float = float(_video_sync_main.get("day_time") if _video_sync_main.get("day_time") != null else 0.0)

	if ts > 0.0:
		_video_last_timescale = ts

	var has_video := tr_video_stream_player != null and tr_video_stream_player.stream != null
	if has_video:
		# Pause sync
		var should_pause := ts == 0.0
		var was_paused := tr_video_stream_player.paused
		if tr_video_stream_player.paused != should_pause:
			tr_video_stream_player.paused = should_pause
		# Explicitly resume playback when simulation resumes.
		# Some backends need play() after paused -> unpaused transitions.
		if was_paused and not should_pause:
			tr_video_stream_player.play()
		# Compute expected video position. When an abs_hours anchor is set use
		# multi-day absolute time so the clip stays locked across speed changes.
		var abs_h: float = NAN
		if _video_sync_main.has_method("get_absolute_hours"):
			abs_h = float(_video_sync_main.call("get_absolute_hours"))
		var expected_seconds: float
		if not is_nan(video_start_abs_hours) and not is_nan(abs_h):
			expected_seconds = (abs_h - video_start_abs_hours) / maxf(video_reference_time_scale, 0.0001)
		else:
			expected_seconds = _sim_hour_to_video_seconds(dt)
		var expected_pos := _normalized_video_position(expected_seconds)
		var current_pos := tr_video_stream_player.stream_position
		var drift := absf(expected_pos - current_pos)
		var use_periodic_seek := not is_equal_approx(absf(ts), video_reference_time_scale)
		if should_pause:
			# Keep paused frame locked to simulation clock.
			if drift > VIDEO_SYNC_DRIFT_TOLERANCE_SECONDS:
				tr_video_stream_player.stream_position = expected_pos
			_video_seek_accum = 0.0
		elif use_periodic_seek:
			# At non-reference speeds, let decode run and correct often enough.
			_video_seek_accum += maxf(delta, 0.0)
			if _video_seek_accum >= VIDEO_SYNC_SEEK_INTERVAL_SECONDS or drift > VIDEO_SYNC_DRIFT_TOLERANCE_SECONDS:
				tr_video_stream_player.stream_position = expected_pos
				_video_seek_accum = 0.0
		else:
			# At reference speed (450x), native playback should already match.
			_video_seek_accum = 0.0

	# Update scrubber without triggering feedback
	if not _video_scrubber_updating and tr_video_scrubber != null:
		_video_scrubber_updating = true
		tr_video_scrubber.value = dt
		_video_scrubber_updating = false

	_update_video_control_labels(ts, dt)


func _update_video_control_labels(ts: float, dt: float) -> void:
	if tr_video_play_pause_btn != null:
		tr_video_play_pause_btn.text = "⏸" if ts > 0.0 else "▶"

	if tr_video_time_label != null:
		var hh := int(dt) % 24
		var mm := int((dt - floor(dt)) * 60.0)
		var ap := "AM" if hh < 12 else "PM"
		var disp := hh % 12
		if disp == 0:
			disp = 12
		tr_video_time_label.text = "%d:%02d %s" % [disp, mm, ap]

	if tr_video_speed_label != null:
		if ts == 0.0:
			tr_video_speed_label.text = "PAUSED"
		else:
			# Match against TimelineUI speed steps
			var best_i := 0
			var best_d := absf(ts - float(TimelineUI.SPEED_STEPS[0][1]))
			for i in range(1, TimelineUI.SPEED_STEPS.size()):
				var d := absf(ts - float(TimelineUI.SPEED_STEPS[i][1]))
				if d < best_d:
					best_d = d
					best_i = i
			tr_video_speed_label.text = "%s SYNC" % str(TimelineUI.SPEED_STEPS[best_i][0])


func _seek_video_to_sim_time() -> void:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return
	if _video_sync_main == null:
		_video_sync_main = _find_sim_main()
	if _video_sync_main == null:
		return
	var dt: float = float(_video_sync_main.get("day_time") if _video_sync_main.get("day_time") != null else 0.0)
	var pos := _normalized_video_position(_sim_hour_to_video_seconds(dt))
	tr_video_stream_player.stream_position = pos


func _apply_video_sync_speed() -> void:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return
	if _video_sync_main == null:
		_video_sync_main = _find_sim_main()
	var ts: float = video_reference_time_scale
	if _video_sync_main != null:
		ts = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else video_reference_time_scale)
	tr_video_stream_player.paused = ts == 0.0


func _sim_hour_to_video_seconds(sim_hour: float) -> float:
	# Example with default values: 450x -> 0.125 time_scale -> 1 sim hour maps to 8 video seconds.
	return maxf(0.0, (sim_hour - video_start_hour) / maxf(video_reference_time_scale, 0.0001))


func _normalized_video_position(pos_seconds: float) -> float:
	var duration := _get_video_duration_seconds()
	if duration > 0.001:
		return fposmod(pos_seconds, duration)
	return pos_seconds


func _get_video_duration_seconds() -> float:
	if tr_video_stream_player == null or tr_video_stream_player.stream == null:
		return 0.0
	var stream := tr_video_stream_player.stream
	if stream.has_method("get_length"):
		var len := float(stream.call("get_length"))
		if len > 0.0:
			return len
	if tr_video_stream_player.has_method("get_stream_length"):
		var alt := float(tr_video_stream_player.call("get_stream_length"))
		if alt > 0.0:
			return alt
	return 0.0


func _on_video_play_pause_pressed() -> void:
	var timeline := _find_timeline_ui()
	if timeline != null and timeline.has_method("toggle_play"):
		timeline.call("toggle_play")
		return
	if _video_sync_main == null or not is_instance_valid(_video_sync_main):
		_video_sync_main = _find_sim_main()
	if _video_sync_main == null:
		return
	var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else 0.0)
	if ts > 0.0:
		_video_last_timescale = ts
		_video_sync_main.set("time_scale", 0.0)
	else:
		var resume := _video_last_timescale if _video_last_timescale > 1e-6 else video_reference_time_scale
		_video_sync_main.set("time_scale", resume)


func _on_video_scrubber_changed(value: float) -> void:
	if _video_scrubber_updating:
		return
	if _video_sync_main == null or not is_instance_valid(_video_sync_main):
		_video_sync_main = _find_sim_main()
	if _video_sync_main != null:
		_video_sync_main.set("day_time", value)
	_seek_video_to_sim_time()


func _on_video_slower_pressed() -> void:
	var timeline := _find_timeline_ui()
	if timeline != null and timeline.has_method("speed_down"):
		timeline.call("speed_down")
	elif _video_sync_main != null and is_instance_valid(_video_sync_main):
		var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else video_reference_time_scale)
		var best_i := 0
		var best_d := absf(ts - float(TimelineUI.SPEED_STEPS[0][1]))
		for i in range(1, TimelineUI.SPEED_STEPS.size()):
			var d := absf(ts - float(TimelineUI.SPEED_STEPS[i][1]))
			if d < best_d:
				best_d = d
				best_i = i
		best_i = max(best_i - 1, 0)
		_video_sync_main.set("time_scale", float(TimelineUI.SPEED_STEPS[best_i][1]))


func _on_video_faster_pressed() -> void:
	var timeline := _find_timeline_ui()
	if timeline != null and timeline.has_method("speed_up"):
		timeline.call("speed_up")
	elif _video_sync_main != null and is_instance_valid(_video_sync_main):
		var ts: float = float(_video_sync_main.get("time_scale") if _video_sync_main.get("time_scale") != null else video_reference_time_scale)
		var best_i := 0
		var best_d := absf(ts - float(TimelineUI.SPEED_STEPS[0][1]))
		for i in range(1, TimelineUI.SPEED_STEPS.size()):
			var d := absf(ts - float(TimelineUI.SPEED_STEPS[i][1]))
			if d < best_d:
				best_d = d
				best_i = i
		best_i = min(best_i + 1, TimelineUI.SPEED_STEPS.size() - 1)
		_video_sync_main.set("time_scale", float(TimelineUI.SPEED_STEPS[best_i][1]))


func _on_video_sync_pressed() -> void:
	_seek_video_to_sim_time()


func _layout_tr_video_content() -> void:
	if _tr_video_layout_guard:
		return
	if tr_video_host == null or tr_video_stream_player == null:
		return
	var host_size := tr_video_host.size
	if host_size.x <= 1.0 or host_size.y <= 1.0:
		return
	var aspect := maxf(timelapse_display_aspect, 0.1)
	var host_aspect := host_size.x / host_size.y
	var target_size := host_size
	if host_aspect > aspect:
		target_size.x = host_size.y * aspect
	else:
		target_size.y = host_size.x / aspect
	var target_pos := (host_size - target_size) * 0.5

	_tr_video_layout_guard = true
	tr_video_stream_player.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tr_video_stream_player.position = target_pos
	tr_video_stream_player.size = target_size
	_tr_video_layout_guard = false

	_layout_tl_to_match_video_aspect()


## Letterbox the TL simulated-view SubViewportContainer to the same aspect ratio
## as the TR timelapse video so both panels share the same frame geometry.
func _layout_tl_to_match_video_aspect() -> void:
	if tl_viewport_panel == null or tl_viewport_container == null:
		return
	var host_size := tl_viewport_panel.size
	if host_size.x <= 1.0 or host_size.y <= 1.0:
		return
	var aspect := maxf(timelapse_display_aspect, 0.1)
	var host_aspect := host_size.x / host_size.y
	var target_size := host_size
	if host_aspect > aspect:
		target_size.x = host_size.y * aspect
	else:
		target_size.y = host_size.x / aspect
	var target_pos := (host_size - target_size) * 0.5
	tl_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	tl_viewport_container.position = target_pos
	tl_viewport_container.size = target_size
